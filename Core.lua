-- Scoring, group inspection and fight reading. No UI in here.
local _, ns = ...
local Data = ns.Data

local SAME_SPEC_OVERLAP = 0.5 -- share of damage that must come from the same spells
local INSPECT_GAP = 1.5 -- seconds between two inspect requests
local INSPECT_MAX_AGE = 600
local METER_DELAY, METER_ATTEMPTS = 3, 3 -- the game unlocks meter values a moment after combat
local HEAVY_ARMOR_LEVEL = 40 -- ponytail: vanilla rule (mail/plate from 40); confirm for Forever in game

-- Inventory slot -> item type in the database. Shirt (4) and tabard (19) carry no stats.
local SLOT_TYPE = {
	[1] = 1, [2] = 2, [3] = 3, [15] = 4, [5] = 5, [9] = 6, [10] = 7, [6] = 8, [7] = 9, [8] = 10,
	[11] = 11, [12] = 11, [13] = 12, [14] = 12, [16] = 13, [17] = 13, [18] = 14,
}
ns.SLOT_NAME = {
	[1] = "Head", [2] = "Neck", [3] = "Shoulder", [15] = "Back", [5] = "Chest", [9] = "Wrist", [10] = "Hands",
	[6] = "Waist", [7] = "Legs", [8] = "Feet", [11] = "Ring", [12] = "Ring", [13] = "Trinket", [14] = "Trinket",
	[16] = "Main hand", [17] = "Off hand", [18] = "Ranged",
}
-- Slots that get upgrade suggestions. ponytail: no trinkets (their value is in effects, not
-- stats) and no off-hand (needs dual-wield rules per spec); add when the scoring covers them.
local UPGRADE_SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 16, 18 }
local DPS_WEIGHT = { [16] = "mh", [17] = "oh", [18] = "rg" }
local TWO_HAND = 4
local HEAVY_ARMOR = { HUNTER = 3, SHAMAN = 3, WARRIOR = 4, PALADIN = 4 }

ns.gearCache = {} -- guid -> { links = {slot -> link}, time = seconds }
ns.lastFight = nil

local function isSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end
ns.isSecret = isSecret

local function parseSparse(text)
	local t = {}
	for k, v in text:gmatch("(%d+):([%-%d%.e]+)") do t[tonumber(k)] = tonumber(v) end
	return t
end

-- Database entry for an item id, or nil. Parsed on demand to keep memory low.
function ns.Item(id)
	local raw = Data.items[id]
	if not raw then return nil end
	local f = {}
	for field in raw:gmatch("[^%^]+") do f[#f + 1] = field end
	return {
		id = id, type = tonumber(f[1]), armor = tonumber(f[2]), weapon = tonumber(f[3]), hand = tonumber(f[4]),
		ranged = tonumber(f[5]), reqLvl = tonumber(f[6]), ilvl = tonumber(f[7]), dps = tonumber(f[8]), rpp = tonumber(f[9]),
		classes = f[10], stats = parseSparse(f[11]), name = f[12], source = f[13],
	}
end

-- Item id, enchant id and random-suffix id from an item link.
function ns.ParseLink(link)
	local id, enchant, suffix = link:match("item:(%d+):(%d*):%-?%d*:%-?%d*:%-?%d*:%-?%d*:(%-?%d*)")
	if not id then
		id = link:match("item:(%d+)")
	end
	return tonumber(id), tonumber(enchant), suffix and tonumber(suffix) and math.abs(tonumber(suffix))
end

local function weighted(stats, profile, scale)
	local total = 0
	for stat, value in pairs(stats) do
		local w = profile.w[stat]
		if w then total = total + w * (scale and math.floor(value * scale) or value) end
	end
	return total
end

-- Value of one item in a slot for a weight profile, in the profile's own unit.
function ns.ItemScore(item, profile, slot, enchant, suffix)
	local total = weighted(item.stats, profile)
	local dpsWeight = profile[DPS_WEIGHT[slot]]
	if dpsWeight then total = total + dpsWeight * item.dps end
	if suffix and Data.suffixes[suffix] and item.rpp > 0 then
		total = total + weighted(parseSparse(Data.suffixes[suffix]), profile, item.rpp / 10000)
	end
	if enchant and Data.enchants[enchant] then
		total = total + weighted(parseSparse(Data.enchants[enchant]), profile)
	end
	return total
end

-- Reads the item links of a unit. Returns slot -> link, or nil when the game locks them.
function ns.ReadGear(unit)
	local links = {}
	for slot in pairs(SLOT_TYPE) do
		local link = GetInventoryItemLink(unit, slot)
		if isSecret(link) then return nil end
		links[slot] = link
	end
	return links
end

-- Scores a set of links. Returns total, per-slot details and how many items the database lacks.
function ns.GearScore(links, profile)
	local total, slots, unknown = 0, {}, 0
	for slot in pairs(SLOT_TYPE) do
		local link = links[slot]
		if link then
			local id, enchant, suffix = ns.ParseLink(link)
			local item = id and ns.Item(id)
			local entry = { id = id, name = link:match("%[(.-)%]") or (item and item.name) or "?", score = 0 }
			if item then
				entry.score = ns.ItemScore(item, profile, slot, enchant, suffix)
				entry.hand = item.hand
			else
				unknown = unknown + 1
			end
			slots[slot] = entry
			total = total + entry.score
		end
	end
	return total, slots, unknown
end

local function usable(item, class, level, slot)
	if item.reqLvl > level then return false end
	if item.classes ~= "-" and not item.classes:find(class, 1, true) then return false end
	if item.type == 13 then
		local skill = Data.weapons[class] and Data.weapons[class][item.weapon]
		if not skill or item.hand == 3 then return false end
		return item.hand ~= TWO_HAND or skill == 2
	elseif item.type == 14 then
		return Data.ranged[class] ~= nil and Data.ranged[class][item.ranged] == true
	elseif item.armor > 0 then
		if item.armor > (Data.armor[class] or 0) then return false end
		return item.armor ~= HEAVY_ARMOR[class] or level >= HEAVY_ARMOR_LEVEL
	end
	return true
end

-- Best obtainable item per slot compared with what is equipped, biggest gain first.
function ns.Upgrades(links, class, level, profile)
	local _, equipped = ns.GearScore(links, profile)
	local worn = {}
	for _, entry in pairs(equipped) do
		if entry.id then worn[entry.id] = true end
	end
	local function scoreOf(slot) return equipped[slot] and equipped[slot].score or 0 end
	local results = {}
	for _, slot in ipairs(UPGRADE_SLOTS) do
		local shown = slot
		if slot == 11 and scoreOf(12) < scoreOf(11) then shown = 12 end -- replace the weaker ring
		local best, bestGain = nil, 0
		for _, id in ipairs(Data.slots[SLOT_TYPE[slot]] or {}) do
			if not worn[id] then
				local item = ns.Item(id)
				if item and usable(item, class, level, slot) then
					local replaced = scoreOf(shown)
					if item.hand == TWO_HAND then replaced = replaced + scoreOf(17) end
					local gain = ns.ItemScore(item, profile, slot) - replaced
					if gain > bestGain then best, bestGain = item, gain end
				end
			end
		end
		if best then
			results[#results + 1] = {
				slot = shown, equipped = equipped[shown] and equipped[shown].name or "empty", item = best, gain = bestGain,
			}
		end
	end
	table.sort(results, function(a, b) return a.gain > b.gain end)
	return results
end

-- Value of everything a character has besides gear, in the profile's unit: the primary stats
-- on the character sheet minus what the gear adds to them.
-- ponytail: covers primary stats only, so it is too low for casters whose spells have a large
-- base damage; gear differences then look bigger than they are. A simulation would fix that.
local SHEET_STAT = { [1] = 0, [2] = 1, [3] = 2, [4] = 3, [5] = 13 } -- UnitStat index -> database stat
function ns.BaseValue(links, profile)
	local primary, sheet = { w = {} }, 0
	for unitStat, stat in pairs(SHEET_STAT) do
		local w = profile.w[stat]
		if w then
			local _, effective = UnitStat("player", unitStat)
			if isSecret(effective) or not effective then return 0 end
			primary.w[stat] = w
			sheet = sheet + w * effective
		end
	end
	return math.max(0, sheet - ns.GearScore(links, primary))
end

-- Share of damage two players get from the same spells, 0..1.
function ns.Overlap(a, b)
	if a.total <= 0 or b.total <= 0 then return 0 end
	local shared = 0
	for spell, amount in pairs(a.spells) do
		local other = b.spells[spell]
		if other then shared = shared + math.min(amount / a.total, other / b.total) end
	end
	return shared
end

-- Players of your class who play like you, compared with you.
-- Returns rows { name, guid, damage, gear, rest } and the number of players left out.
function ns.Compare(fight, profile)
	local me = fight.me
	local rows, leftOut = {}, 0
	if not me then return rows, leftOut end
	local myLinks = ns.ReadGear("player")
	local myScore = myLinks and profile and ns.GearScore(myLinks, profile) or 0
	local base = myScore > 0 and ns.BaseValue(myLinks, profile) or 0
	for _, other in ipairs(fight.others) do
		if other.class == me.class then
			if ns.Overlap(me, other) >= SAME_SPEC_OVERLAP then
				local row = { name = other.name, guid = other.guid, damage = other.total / me.total - 1 }
				local cached = ns.gearCache[other.guid]
				if cached and myScore > 0 then
					-- ponytail: assumes damage grows in step with character value and that both
					-- players share the same base; ignores talents and buffs. Replace with a
					-- wowsims export if this proves too rough.
					row.gear = (base + ns.GearScore(cached.links, profile)) / (base + myScore) - 1
					row.rest = row.damage - row.gear
				end
				rows[#rows + 1] = row
			else
				leftOut = leftOut + 1
			end
		end
	end
	table.sort(rows, function(a, b) return a.damage > b.damage end)
	return rows, leftOut
end

local function readSource(src, sessionType, meterType)
	local guid = src.sourceGUID
	if src.isLocalPlayer then guid = UnitGUID("player") end
	if isSecret(guid) or isSecret(src.totalAmount) or isSecret(src.name) then return nil, true end
	if type(guid) ~= "string" or guid:sub(1, 7) ~= "Player-" then return nil, false end
	local entry = { guid = guid, name = src.name, class = src.classFilename, total = src.totalAmount, spells = {} }
	local detail = C_DamageMeter.GetCombatSessionSourceFromType(sessionType, meterType, guid)
	for _, spell in ipairs(type(detail) == "table" and detail.combatSpells or {}) do
		if isSecret(spell.spellID) or isSecret(spell.totalAmount) then return nil, true end
		entry.spells[spell.spellID] = (entry.spells[spell.spellID] or 0) + spell.totalAmount
	end
	return entry, false
end

-- Reads the last fight from the built-in damage meter.
-- Returns a fight table, or nil plus true while the game still locks the values.
function ns.ReadFight()
	if not C_DamageMeter then return nil, false end
	local sessionType, meterType = Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.DamageDone
	local session = C_DamageMeter.GetCombatSessionFromType(sessionType, meterType)
	local sources = type(session) == "table" and session.combatSources
	if type(sources) ~= "table" or #sources == 0 then return nil, false end
	local fight = { others = {}, time = GetTime() }
	if not isSecret(session.durationSeconds) then fight.duration = session.durationSeconds end
	for _, src in ipairs(sources) do
		local entry, locked = readSource(src, sessionType, meterType)
		if locked then return nil, true end
		if entry and entry.total > 0 then
			if src.isLocalPlayer then fight.me = entry else fight.others[#fight.others + 1] = entry end
		end
	end
	return fight, false
end

local function afterFight(attempt)
	if InCombatLockdown() then return end
	local ok, fight, locked = pcall(ns.ReadFight)
	if not ok then return end
	if locked and attempt < METER_ATTEMPTS then
		C_Timer.After(METER_DELAY, function() afterFight(attempt + 1) end)
	elseif fight and fight.me then
		ns.lastFight = fight
		if ns.OnFight then ns.OnFight(fight) end
	end
end

-- Inspecting: one group member of your class at a time, never in combat.
local queue, waitingFor = {}, nil

local function nextInspect()
	if waitingFor or InCombatLockdown() then return end
	local unit = table.remove(queue, 1)
	if not unit then return end
	local guid = UnitGUID(unit)
	if isSecret(guid) or not guid or not CanInspect(unit) then return nextInspect() end
	waitingFor = { unit = unit, guid = guid }
	NotifyInspect(unit)
	C_Timer.After(INSPECT_GAP * 3, function() -- give up on an answer that never comes
		if waitingFor and waitingFor.guid == guid then
			waitingFor = nil
			nextInspect()
		end
	end)
end

function ns.QueueInspects()
	if InCombatLockdown() or not IsInGroup() then return end
	local _, myClass = UnitClass("player")
	local prefix, count = "party", GetNumGroupMembers() - 1
	if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
	queue = {}
	for i = 1, count do
		local unit = prefix .. i
		if UnitExists(unit) and not UnitIsUnit(unit, "player") and select(2, UnitClass(unit)) == myClass then
			local guid = UnitGUID(unit)
			local cached = not isSecret(guid) and ns.gearCache[guid]
			if not cached or GetTime() - cached.time > INSPECT_MAX_AGE then queue[#queue + 1] = unit end
		end
	end
	nextInspect()
end

local function onInspectReady(guid)
	if not waitingFor or isSecret(guid) or guid ~= waitingFor.guid then return end
	local unit = waitingFor.unit
	waitingFor = nil
	local current = UnitGUID(unit)
	if not isSecret(current) and current == guid then
		local links = ns.ReadGear(unit)
		if links and next(links) then
			ns.gearCache[guid] = { links = links, time = GetTime() }
			if ns.OnGear then ns.OnGear() end
		end
	end
	C_Timer.After(INSPECT_GAP, nextInspect)
end

-- The weight profile chosen for this character (saved), or the first one of the class.
function ns.Profile()
	local _, class = UnitClass("player")
	local list = Data.profiles[class]
	if not list then return nil end
	GearOrSkillDB = GearOrSkillDB or {}
	return list[GearOrSkillDB.profile] or list[1], list
end

local frame = CreateFrame("Frame")
for _, event in ipairs({ "INSPECT_READY", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED" }) do
	frame:RegisterEvent(event)
end
frame:SetScript("OnEvent", function(_, event, arg)
	if event == "INSPECT_READY" then
		onInspectReady(arg)
	elseif event == "PLAYER_REGEN_ENABLED" then
		C_Timer.After(METER_DELAY, function() afterFight(1) end)
		ns.QueueInspects()
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if ns.OnGear then ns.OnGear() end
	else
		ns.QueueInspects()
	end
end)
