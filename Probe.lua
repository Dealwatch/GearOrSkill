-- API probe: answers "what can an addon read in the Forever client?"
-- Usage: /gos probe (your gear + your target's gear), /gos probe meter (damage meter after a fight),
-- /gos probe auctionator (what Auctionator offers other addons), /gos probe clear.
-- Chat shows one verdict per question; the details go to the GearOrSkillProbeLog saved variable.
local ADDON, ns = ...

local MAX_LOG = 500
local FIRST_SLOT, LAST_SLOT = 1, 19
local UNSTATTED_SLOTS = 2 -- shirt and tabard never carry stats
local INSPECT_TIMEOUT = 5
local METER_DELAY, METER_ATTEMPTS = 3, 3 -- the game unlocks meter values a moment after combat

local PREFIX = "|cff33ff99GoS|r "
local TAG = {
	ok = "|cff40c040[OK]|r ",
	partial = "|cffffd200[PARTIAL]|r ",
	blocked = "|cffff4040[BLOCKED]|r ",
	info = "|cffa0a0a0[INFO]|r ",
}

local pendingGUID

local function isSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- Secret values must not be compared, measured or saved, so replace them before use.
local function show(v)
	if isSecret(v) then return "<secret>" end
	return tostring(v)
end

local function save(line)
	GearOrSkillProbeLog = GearOrSkillProbeLog or {}
	if #GearOrSkillProbeLog < MAX_LOG then
		GearOrSkillProbeLog[#GearOrSkillProbeLog + 1] = date("%H:%M:%S ") .. line
	end
end

-- One verdict line: shown in chat and saved.
local function say(tag, msg)
	print(PREFIX .. TAG[tag] .. msg)
	save("[" .. tag .. "] " .. msg)
end

-- A detail line: saved only, to keep chat readable.
local function note(msg)
	save("    " .. msg)
end

-- Runs a probe and reports the error instead of losing it.
local function try(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then say("blocked", label .. ": error: " .. show(err)) end
end

local function probeClient()
	local version, build, _, interface = GetBuildInfo()
	say("info", "Client " .. show(version) .. " (" .. show(build) .. "), interface " .. show(interface))
end

-- What a shopping list on top of Auctionator could rely on: which of its functions exist in
-- this build, and whether it prices items with a random suffix ("of the Monkey") one by one.
local AUCTIONATOR_FUNCTIONS = {
	"GetAuctionPriceByItemID", "GetAuctionPriceByItemLink", "GetAuctionAgeByItemLink", "GetVendorPriceByItemID",
	"IsAuctionDataExactByItemLink", "CreateShoppingList", "MultiSearchExact", "RegisterForDBUpdate",
}
local function probeAuctionator()
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if not api then
		say("info", "Auctionator is not loaded")
		return
	end
	local missing = {}
	for _, name in ipairs(AUCTIONATOR_FUNCTIONS) do
		if type(api[name]) ~= "function" then missing[#missing + 1] = name end
	end
	say(#missing == 0 and "ok" or "partial", "Auctionator functions: " .. (#missing == 0 and "all present" or "missing " .. table.concat(missing, ", ")))
	local legacy = Auctionator.Constants and Auctionator.Constants.IsLegacyAH
	say("info", "Auctionator prices random-suffix items " .. (legacy == true and "one by one" or legacy == false and "together, per base item" or "in an unknown way"))
	local items, priced, exact = 0, 0, 0
	for slot = FIRST_SLOT, LAST_SLOT do
		local link = GetInventoryItemLink("player", slot)
		if link and not isSecret(link) then
			items = items + 1
			local id = tonumber(link:match("item:(%d+)"))
			local okID, byID = pcall(api.GetAuctionPriceByItemID, ADDON, id)
			local okLink, byLink = pcall(api.GetAuctionPriceByItemLink, ADDON, link)
			local okExact, isExact = pcall(api.IsAuctionDataExactByItemLink, ADDON, link)
			if okLink and byLink then priced = priced + 1 end
			if okExact and isExact == true then exact = exact + 1 end
			note("slot " .. slot .. ": " .. link .. " by id=" .. show(okID and byID) .. " by link=" .. show(okLink and byLink) .. " exact=" .. show(okExact and isExact))
		end
	end
	say("info", "Auctionator knows a price for " .. priced .. " of your " .. items .. " equipped items, " .. exact .. " of them exact")
end

local function probeArmorSkills()
	local function known(id) return IsSpellKnown(id) == true and "yes" or "no" end
	say("info", "Armor skills at level " .. show(UnitLevel("player")) .. ": mail " .. known(8737) .. ", plate " .. known(750))
end

-- Does the game's tooltip tell what this character cannot use? Checks the first weapon of
-- each kind the class can learn; the equipped kind should come out as usable.
local WEAPON_NAMES = { [1] = "axe", [2] = "dagger", [3] = "fist", [4] = "mace", [6] = "polearm", [8] = "staff", [9] = "sword" }
local function probeUsable()
	if not C_TooltipInfo or not C_TooltipInfo.GetItemByID then
		say("info", "Tooltip check: the game offers no tooltip data to addons")
		return
	end
	local _, class = UnitClass("player")
	local level, found, loading = UnitLevel("player"), {}, false
	for _, id in ipairs(ns.Data.slots[13] or {}) do
		local item = ns.Item(id)
		local kind = item and WEAPON_NAMES[item.weapon] and (item.hand == 4 and "two-hand " or "") .. WEAPON_NAMES[item.weapon]
		if kind and found[kind] == nil and item.reqLvl <= level and ns.Data.weapons[class] and ns.Data.weapons[class][item.weapon] then
			local usable = ns.CanUse(id)
			found[kind] = usable == nil and "not loaded" or usable and "yes" or "no"
			if usable == nil then loading = true end
			note("tooltip check " .. kind .. ": " .. item.name .. " (" .. id .. ") usable=" .. found[kind])
		end
	end
	local parts = {}
	for kind, verdict in pairs(found) do parts[#parts + 1] = kind .. " " .. verdict end
	table.sort(parts)
	say("info", "Weapons you can use, by tooltip: " .. table.concat(parts, ", ") .. (loading and ". Run /gos probe again for those not loaded" or ""))
end

local function probeGear(unit, who)
	local links, withStats, secrets = 0, 0, 0
	for slot = FIRST_SLOT, LAST_SLOT do
		local link = GetInventoryItemLink(unit, slot)
		if isSecret(link) then
			secrets = secrets + 1
		elseif link then
			links = links + 1
			local stats = C_Item.GetItemStats(link)
			if isSecret(stats) then
				secrets = secrets + 1
			elseif type(stats) == "table" and next(stats) then
				withStats = withStats + 1
				local parts = {}
				for stat, value in pairs(stats) do
					parts[#parts + 1] = stat .. "=" .. show(value)
				end
				note(unit .. " slot " .. slot .. ": " .. link .. " " .. table.concat(parts, ", "))
			else
				note(unit .. " slot " .. slot .. ": " .. link .. " no stats")
			end
		end
	end
	local msg = who .. ": " .. links .. " items, " .. withStats .. " with readable stats"
	if secrets > 0 or links == 0 or withStats == 0 then
		say("blocked", msg .. (secrets > 0 and (", " .. secrets .. " locked") or ""))
	elseif withStats < links - UNSTATTED_SLOTS then
		say("partial", msg .. " (item data still loading, run /gos probe again)")
	else
		say("ok", msg)
	end
end

local function probeTalents(unit)
	local spec = C_SpecializationInfo.GetInspectSpecialization(unit)
	local valid = C_Traits.HasValidInspectData()
	say("info", "Target talents: spec id " .. show(spec) .. ", talent data " .. (isSecret(valid) and "locked" or valid and "yes" or "no"))
end

local function probeTarget()
	if not UnitIsPlayer("target") then
		say("info", "No player targeted, so the gear of other players was not checked")
		return
	end
	if InCombatLockdown() then
		say("info", "In combat, so the gear of other players was not checked")
		return
	end
	local inspectable = CanInspect("target")
	local guid = UnitGUID("target")
	if isSecret(inspectable) or isSecret(guid) then
		say("blocked", "Target: identity is locked")
	elseif not inspectable then
		say("info", "Target cannot be inspected right now (too far away?)")
	else
		pendingGUID = guid
		NotifyInspect("target")
		C_Timer.After(INSPECT_TIMEOUT, function()
			if pendingGUID == guid then
				pendingGUID = nil
				say("blocked", "Target: no inspect answer after " .. INSPECT_TIMEOUT .. " seconds")
			end
		end)
	end
end

-- Returns: can the damage total be read, can the spell list be read.
local function readSource(sessionType, meterType, src, label)
	local amountOK = not isSecret(src.totalAmount)
	local guid = src.sourceGUID
	if src.isLocalPlayer then guid = UnitGUID("player") end
	note(label .. ": class=" .. show(src.classFilename) .. " name=" .. show(src.name) .. " amount=" .. show(src.totalAmount))
	if isSecret(guid) or guid == nil then
		note(label .. ": id is locked, spells cannot be requested")
		return amountOK, false
	end
	local source = C_DamageMeter.GetCombatSessionSourceFromType(sessionType, meterType, guid)
	local spells = type(source) == "table" and source.combatSpells
	if type(spells) ~= "table" or #spells == 0 then
		note(label .. ": no spell list")
		return amountOK, false
	end
	local spellsOK = true
	for i = 1, #spells do
		local spell = spells[i]
		if isSecret(spell.spellID) or isSecret(spell.totalAmount) then
			spellsOK = false
		elseif i <= 5 then
			note(label .. " spell " .. i .. ": " .. spell.spellID .. " " .. show(C_Spell.GetSpellName(spell.spellID)) .. " = " .. spell.totalAmount)
		end
	end
	note(label .. ": " .. #spells .. " spells, readable=" .. tostring(spellsOK))
	return amountOK, spellsOK
end

-- Returns a verdict tag, a message, and whether anything was still locked.
local function readSession(name, sessionType)
	local meterType = Enum.DamageMeterType.DamageDone
	local session = C_DamageMeter.GetCombatSessionFromType(sessionType, meterType)
	local sources = type(session) == "table" and session.combatSources
	if type(sources) ~= "table" or #sources == 0 then
		return "info", "Meter, " .. name .. ": no data yet", false
	end
	local mine, others, othersAmount, othersSpells = "", 0, 0, 0
	local locked = false
	for i = 1, #sources do
		local src = sources[i]
		local amountOK, spellsOK = readSource(sessionType, meterType, src, name .. " #" .. i)
		if not (amountOK and spellsOK) then locked = true end
		if not src.isLocalPlayer then
			others = others + 1
			if amountOK then othersAmount = othersAmount + 1 end
			if spellsOK then othersSpells = othersSpells + 1 end
		elseif not (amountOK and spellsOK) then
			mine = "; your own: damage " .. (amountOK and "yes" or "no") .. ", spells " .. (spellsOK and "yes" or "no")
		end
	end
	if others == 0 then
		return mine == "" and "info" or "blocked", "Meter, " .. name .. ": no other players in this data" .. mine, locked
	end
	local msg = "Meter, " .. name .. ": other players damage " .. othersAmount .. "/" .. others
		.. ", spells " .. othersSpells .. "/" .. others .. mine
	if othersAmount == others and othersSpells == others and mine == "" then
		return "ok", msg, locked
	elseif othersAmount == 0 and othersSpells == 0 then
		return "blocked", msg, locked
	end
	return "partial", msg, locked
end

local probeMeter
probeMeter = function(attempt)
	if not C_DamageMeter then
		say("blocked", "Meter: the game offers no damage meter data to addons")
		return
	end
	if InCombatLockdown() then
		say("info", "Meter: in combat, values are locked. Run /gos probe meter after the fight")
		return
	end
	if attempt == 1 then
		local available, reason = C_DamageMeter.IsDamageMeterAvailable()
		note("meter available=" .. show(available) .. " reason=" .. show(reason)
			.. " enabled=" .. show(C_CVar.GetCVarBool("damageMeterEnabled")))
	end
	local results, locked = {}, false
	for _, s in ipairs({ { "this fight", Enum.DamageMeterSessionType.Current }, { "overall", Enum.DamageMeterSessionType.Overall } }) do
		local ok, tag, msg, sessionLocked = pcall(readSession, s[1], s[2])
		if not ok then tag, msg, sessionLocked = "blocked", "Meter, " .. s[1] .. ": error: " .. show(tag), false end
		results[#results + 1] = { tag, msg }
		locked = locked or sessionLocked
	end
	if locked and attempt < METER_ATTEMPTS then
		note("values still locked, attempt " .. attempt .. " of " .. METER_ATTEMPTS)
		C_Timer.After(METER_DELAY, function() try("Meter", probeMeter, attempt + 1) end)
		return
	end
	for _, r in ipairs(results) do say(r[1], r[2]) end
end

local function onInspectReady(guid)
	if not pendingGUID or isSecret(guid) or guid ~= pendingGUID then return end
	pendingGUID = nil
	local current = UnitGUID("target")
	if isSecret(current) or current ~= guid then
		say("info", "Target changed before the inspect answer arrived, run /gos probe again")
		return
	end
	try("Target gear", probeGear, "target", "Target " .. show(UnitName("target")))
	try("Target talents", probeTalents, "target")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("INSPECT_READY")
frame:SetScript("OnEvent", function(_, _, guid) try("Event", onInspectReady, guid) end)

function ns.Probe(arg)
	if arg == "clear" then
		GearOrSkillProbeLog = {}
		print(PREFIX .. "log cleared")
	elseif arg == "auctionator" then
		try("Auctionator", probeAuctionator)
	elseif arg == "meter" then
		try("Meter", probeMeter, 1)
	else
		try("Client", probeClient)
		try("Armor skills", probeArmorSkills)
		try("Tooltip check", probeUsable)
		try("Your gear", probeGear, "player", "Your gear")
		try("Target", probeTarget)
	end
end
