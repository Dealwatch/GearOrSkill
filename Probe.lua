-- API probe: answers "what can an addon read in the Forever client?" before we build on it.
-- Usage: /gos (gear of you + your target), /gos meter (damage meter), /gos clear.
-- The meter probe also runs by itself 2 seconds after every fight.
-- Everything printed is also kept in the GearOrSkillProbeLog saved variable.

local MAX_LOG = 500
local FIRST_SLOT, LAST_SLOT = 1, 19
local pendingGUID

local function isSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- Secret values must not be compared, measured or saved, so replace them before use.
local function show(v)
	if isSecret(v) then return "<secret>" end
	return tostring(v)
end

local function log(msg)
	print("|cff33ff99GoS|r " .. msg)
	GearOrSkillProbeLog = GearOrSkillProbeLog or {}
	if #GearOrSkillProbeLog < MAX_LOG then
		GearOrSkillProbeLog[#GearOrSkillProbeLog + 1] = date("%H:%M:%S ") .. msg
	end
end

-- Runs a probe and records the error instead of losing it.
local function try(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then log(label .. ": ERROR " .. show(err)) end
end

local function probeGear(unit)
	local links, withStats, sample = 0, 0, nil
	for slot = FIRST_SLOT, LAST_SLOT do
		local link = GetInventoryItemLink(unit, slot)
		if isSecret(link) then
			log(unit .. " slot " .. slot .. ": link is secret")
		elseif link then
			links = links + 1
			local stats = C_Item.GetItemStats(link)
			if isSecret(stats) then
				log(unit .. " slot " .. slot .. ": stats are secret")
			elseif stats and next(stats) then
				withStats = withStats + 1
				if not sample then
					local parts = {}
					for stat, value in pairs(stats) do
						parts[#parts + 1] = stat .. "=" .. show(value)
					end
					sample = link .. " " .. table.concat(parts, ", ")
				end
			end
		end
	end
	log(unit .. " gear: " .. links .. " item links, " .. withStats .. " with readable stats")
	if sample then log(unit .. " sample: " .. sample) end
end

local function probeInspectExtras(unit)
	log("inspect spec id: " .. show(C_SpecializationInfo.GetInspectSpecialization(unit)))
	log("inspect talent data valid: " .. show(C_Traits.HasValidInspectData()))
end

local function probeSpells(sessionType, meterType, guid, label)
	local source = C_DamageMeter.GetCombatSessionSourceFromType(sessionType, meterType, guid)
	if isSecret(source) or isSecret(source.combatSpells) then
		log(label .. " spells: secret")
		return
	end
	log(label .. " spells: " .. #source.combatSpells .. " entries")
	for i = 1, math.min(3, #source.combatSpells) do
		local spell = source.combatSpells[i]
		local name = "?"
		if not isSecret(spell.spellID) then
			name = C_Spell.GetSpellName(spell.spellID) or "?"
		end
		log(label .. " spell " .. i .. ": id=" .. show(spell.spellID) .. " (" .. show(name) .. ") amount=" .. show(spell.totalAmount))
	end
end

local function probeSession(sessionName, sessionType)
	local meterType = Enum.DamageMeterType.DamageDone
	local session = C_DamageMeter.GetCombatSessionFromType(sessionType, meterType)
	if isSecret(session) or isSecret(session.combatSources) then
		log("meter " .. sessionName .. ": secret")
		return
	end
	log("meter " .. sessionName .. ": " .. #session.combatSources .. " sources, total=" .. show(session.totalAmount))
	for i = 1, math.min(5, #session.combatSources) do
		local src = session.combatSources[i]
		local label = sessionName .. " #" .. i
		log(label .. ": class=" .. show(src.classFilename) .. " me=" .. show(src.isLocalPlayer)
			.. " name=" .. show(src.name) .. " guid=" .. (isSecret(src.sourceGUID) and "<secret>" or "readable")
			.. " amount=" .. show(src.totalAmount))
		-- Check for secret first: a secret value may not be used as a condition.
		if not isSecret(src.sourceGUID) and src.sourceGUID then
			try(label .. " spells", probeSpells, sessionType, meterType, src.sourceGUID, label)
		end
	end
end

local function probeMeter()
	if not C_DamageMeter then
		log("meter: C_DamageMeter does not exist")
		return
	end
	local available, reason = C_DamageMeter.IsDamageMeterAvailable()
	log("meter available: " .. show(available) .. " " .. show(reason))
	try("meter Current", probeSession, "Current", Enum.DamageMeterSessionType.Current)
	try("meter Overall", probeSession, "Overall", Enum.DamageMeterSessionType.Overall)
end

local function probeTarget()
	if not UnitIsPlayer("target") then
		log("no player targeted, skipping inspect probe")
		return
	end
	if InCombatLockdown() then
		log("in combat, skipping inspect probe")
		return
	end
	local inspectable = CanInspect("target")
	log("target can be inspected: " .. show(inspectable))
	if not isSecret(inspectable) and inspectable then
		pendingGUID = UnitGUID("target")
		NotifyInspect("target")
		log("inspect requested, waiting for answer")
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event, guid)
	if event == "PLAYER_REGEN_ENABLED" then
		-- ponytail: fixed 2s wait; if values are still secret then, run /gos meter by hand.
		C_Timer.After(2, function() try("meter", probeMeter) end)
	elseif pendingGUID and not isSecret(guid) and guid == pendingGUID then
		pendingGUID = nil
		if UnitGUID("target") == guid then
			try("target gear", probeGear, "target")
			try("inspect extras", probeInspectExtras, "target")
		else
			log("target changed before the inspect answer arrived")
		end
	end
end)

SLASH_GEARORSKILL1 = "/gos"
SlashCmdList.GEARORSKILL = function(arg)
	if arg == "clear" then
		GearOrSkillProbeLog = {}
		print("GoS log cleared")
	elseif arg == "meter" then
		try("meter", probeMeter)
	else
		try("player gear", probeGear, "player")
		try("target", probeTarget)
	end
end
