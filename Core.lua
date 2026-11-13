-- Scoring, group inspection and fight reading. No UI in here.
local ADDON, ns = ...
local Data = ns.Data

local SAME_SPEC_OVERLAP = 0.5 -- share of damage that must come from the same spells
local INSPECT_GAP = 1.5 -- seconds between two inspect requests
local INSPECT_MAX_AGE = 600
local METER_DELAY, METER_ATTEMPTS = 3, 3 -- the game unlocks meter values a moment after combat
local HEAVY_ARMOR_LEVEL = 40 -- ponytail: vanilla rule (mail/plate from 40); the spell check below overrides it
local ARMOR_SKILL = { [3] = 8737, [4] = 750 } -- Classic spell ids of the Mail and Plate Mail skills

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
		classes = f[10], stats = parseSparse(f[11]), name = f[12], source = f[13], suffixes = f[14],
	}
end

-- Item id, enchant id and random-suffix id from an item link.
-- The suffix sits in the classic suffix field or, as this client stores suffixes as item
-- bonuses, among the bonus ids further back; any later field that names a known suffix counts.
function ns.ParseLink(link)
	local itemString = link:match("item:[%-%d:]+")
	if not itemString then return nil end
	local fields = { strsplit(":", itemString) }
	local suffix
	for i = 8, #fields do
		local value = tonumber(fields[i])
		if value and Data.suffixes[math.abs(value)] then
			suffix = math.abs(value)
			break
		end
	end
	return tonumber(fields[2]), tonumber(fields[3]), suffix
end

local function weighted(stats, profile, scale)
	local total = 0
	for stat, value in pairs(stats) do
		local w = profile.w[stat]
		if w then total = total + w * (scale and math.floor(value * scale) or value) end
	end
	return total
end

local suffixStats = {} -- parsed suffix allocations, kept because the shop list scores thousands

-- Value of one item in a slot for a weight profile, in the profile's own unit.
function ns.ItemScore(item, profile, slot, enchant, suffix)
	local total = weighted(item.stats, profile)
	local dpsWeight = profile[DPS_WEIGHT[slot]]
	if dpsWeight then total = total + dpsWeight * item.dps end
	if suffix and item.rpp > 0 then
		suffixStats[suffix] = suffixStats[suffix] or parseSparse(Data.suffixes[suffix] or "")
		total = total + weighted(suffixStats[suffix], profile, item.rpp / 10000)
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
				-- Only a suffix this item can roll counts: other link fields may hold the same number.
				if suffix and not ("," .. item.suffixes .. ","):find("," .. suffix .. ",", 1, true) then suffix = nil end
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
		return item.armor ~= HEAVY_ARMOR[class] or level >= HEAVY_ARMOR_LEVEL or IsSpellKnown(ARMOR_SKILL[item.armor]) == true
	end
	return true
end

-- Whether this character can use an item right now, by the game's own verdict: its tooltip
-- prints in red whatever stands in the way (weapon or armor type not learned, level, class,
-- skill). The class rules above only say what a class can ever learn.
-- Returns true or false, or nil while the game has not loaded the item yet: the verdict would
-- be a guess, so such an item is asked for and left out until its data arrives.
-- Where the game offers no tooltip data at all, everything counts as usable.
local USABLE_TRIES = 25 -- candidates checked per slot before giving up
local usableCache = {}
local waitingForItems = false -- something drawn lacked item data; redraw when it arrives

local function isRed(color)
	return type(color) == "table" and color.r > 0.9 and color.g < 0.3 and color.b < 0.3
end

function ns.CanUse(id)
	if usableCache[id] ~= nil then return usableCache[id] end
	if not C_TooltipInfo or not C_TooltipInfo.GetItemByID then return true end
	if not C_Item.IsItemDataCachedByID(id) then
		C_Item.RequestLoadItemDataByID(id)
		waitingForItems = true
		return nil
	end
	local ok, verdict = pcall(function()
		local data = C_TooltipInfo.GetItemByID(id)
		if type(data) ~= "table" or type(data.lines) ~= "table" or #data.lines == 0 then return true end
		for _, line in ipairs(data.lines) do
			if line.leftText == RETRIEVING_ITEM_INFO then return nil end
			if line.isValidInvSlot == false or line.isValidItemType == false or isRed(line.leftColor) or isRed(line.rightColor) then
				return false
			end
		end
		return true
	end)
	if not ok then return true end
	if verdict == nil then
		waitingForItems = true
		return nil
	end
	usableCache[id] = verdict
	return verdict
end

-- What was learned since the last look (a weapon skill, a level) may change the verdicts.
function ns.ForgetUsable()
	usableCache = {}
end

-- Walks every item of the given lists (item type -> ids) that the character could wear in an
-- upgrade slot and calls fn(slot, item, replaced): replaced is the score of what it would
-- replace there. Returns the per-slot details of the equipped gear.
local function forCandidates(links, class, level, profile, lists, fn)
	local _, equipped = ns.GearScore(links, profile)
	local worn = {}
	for _, entry in pairs(equipped) do
		if entry.id then worn[entry.id] = true end
	end
	local function scoreOf(slot) return equipped[slot] and equipped[slot].score or 0 end
	for _, slot in ipairs(UPGRADE_SLOTS) do
		local shown = slot
		if slot == 11 and scoreOf(12) < scoreOf(11) then shown = 12 end -- replace the weaker ring
		for _, id in ipairs(lists[SLOT_TYPE[slot]] or {}) do
			if not worn[id] and C_Item.DoesItemExistByID(id) then -- skip what this client does not have
				local item = ns.Item(id)
				if item and usable(item, class, level, slot) then
					local replaced = scoreOf(shown)
					if item.hand == TWO_HAND then replaced = replaced + scoreOf(17) end
					fn(shown, item, replaced)
				end
			end
		end
	end
	return equipped
end

-- Best obtainable item per slot compared with what is equipped, biggest gain first.
function ns.Upgrades(links, class, level, profile)
	local better = {} -- slot -> every candidate that beats the equipped item
	local equipped = forCandidates(links, class, level, profile, Data.slots, function(slot, item, replaced)
		local gain = ns.ItemScore(item, profile, slot) - replaced
		if gain > 0 then
			better[slot] = better[slot] or {}
			table.insert(better[slot], { item = item, gain = gain })
		end
	end)
	local results = {}
	for slot, list in pairs(better) do
		table.sort(list, function(a, b) return a.gain > b.gain end)
		for i = 1, math.min(USABLE_TRIES, #list) do
			local entry = list[i]
			if ns.CanUse(entry.item.id) == true then
				results[#results + 1] = {
					slot = slot, equipped = equipped[slot] and equipped[slot].name or "empty", item = entry.item, gain = entry.gain,
					seen = GearOrSkillSeen ~= nil and GearOrSkillSeen[entry.item.id] == true,
				}
				break
			end
		end
	end
	table.sort(results, function(a, b) return a.gain > b.gain end)
	return results
end

-- Auction house upgrades, priced by the Auctionator addon. --------------------------------

local SHOP_PER_SLOT = 2
local OLD_PRICE_DAYS = 3 -- same threshold as Auctionator users know from MoneyTalks

-- Auctionator's functions for other addons, or nil when it is not loaded.
function ns.Auctionator()
	return Auctionator and Auctionator.API and Auctionator.API.v1
end

-- Calls one of them if this Auctionator build has it. Returns success and the result.
local function ask(name, ...)
	local api = ns.Auctionator()
	if not api or type(api[name]) ~= "function" then return false end
	return pcall(api[name], ADDON, ...)
end

local function price(id)
	local ok, copper = ask("GetAuctionPriceByItemID", id)
	if not ok or type(copper) ~= "number" or copper <= 0 then return nil end
	local _, age = ask("GetAuctionAgeByItemID", id)
	local sells = select(11, C_Item.GetItemInfo(id))
	if sells == nil then waitingForItems = true end -- the vendor value comes with the item data
	return copper, type(age) == "number" and age or nil, type(sells) == "number" and sells > 0 and sells or nil
end

-- Upgrades Auctionator has seen at the auction house.
-- byValue: order by gain per copper lost instead of by gain.
-- Each row: slot, id, name, search (text to look for), gain, price, old (price older than a few
-- days), loss (the net cost: price minus what a vendor pays back, nil if unknown) and, for items with a
-- random suffix, upTo = true and suffix = the name of the best one ("of the Eagle"): the gain is
-- that suffix's and the price that of the cheapest one on sale, since Auctionator's stored
-- price does not say which suffix it was.
function ns.ShopList(links, class, level, profile, byValue)
	local rows = {}
	local function add(slot, item, gain, suffix)
		if gain < 1 then return end -- would show as +0
		local copper, age, sells = price(item.id)
		if not copper then return end
		rows[#rows + 1] = {
			slot = slot, id = item.id, name = item.name, search = item.name, gain = gain, price = copper,
			upTo = suffix ~= nil, suffix = suffix and Data.suffixNames[suffix],
			old = age ~= nil and age > OLD_PRICE_DAYS, loss = sells and math.max(copper - sells, 0) or nil,
		}
	end
	forCandidates(links, class, level, profile, Data.slots, function(slot, item, replaced)
		add(slot, item, ns.ItemScore(item, profile, slot) - replaced)
	end)
	forCandidates(links, class, level, profile, Data.suffixed, function(slot, item, replaced)
		local best, bestSuffix = 0, nil
		for suffix in item.suffixes:gmatch("%d+") do
			local gain = ns.ItemScore(item, profile, slot, nil, tonumber(suffix)) - replaced
			if gain > best then best, bestSuffix = gain, tonumber(suffix) end
		end
		if bestSuffix then add(slot, item, best, bestSuffix) end
	end)
	local function worth(row) return row.gain / math.max(row.loss or row.price, 1) end
	table.sort(rows, function(a, b)
		if byValue and worth(a) ~= worth(b) then return worth(a) > worth(b) end
		if a.gain ~= b.gain then return a.gain > b.gain end
		return a.name < b.name
	end)
	local kept, perSlot = {}, {}
	for _, row in ipairs(rows) do
		local slotName = ns.SLOT_NAME[row.slot]
		if (perSlot[slotName] or 0) < SHOP_PER_SLOT and ns.CanUse(row.id) == true then
			perSlot[slotName] = (perSlot[slotName] or 0) + 1
			kept[#kept + 1] = row
		end
	end
	return kept
end

-- Hands the rows to Auctionator: saved as its shopping list "GearOrSkill" and, with the
-- auction house open, searched right away. Returns a sentence for the user.
function ns.ShopSearch(rows)
	local terms, seen = {}, {}
	for _, row in ipairs(rows) do
		if not seen[row.search] then
			seen[row.search] = true
			terms[#terms + 1] = row.search
		end
	end
	if #terms == 0 then return "Nothing to search for." end
	local saved = ask("CreateShoppingList", "GearOrSkill", terms)
	local atAuctionHouse = AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown()
	if atAuctionHouse and ask("MultiSearch", terms) then
		return "Searching for " .. #terms .. " items in Auctionator."
	elseif saved then
		return "Saved as shopping list \"GearOrSkill\" in Auctionator. Open the auction house to search it."
	end
	return "This Auctionator version offers no shopping lists to other addons."
end

-- Value of everything a character has besides gear, in the profile's unit.
-- Returns the value and whether it comes from the simulator.
-- With a calibration (Calibration.lua, max level only): the simulated worth of the whole
-- reference character minus the worth of its gear. That covers base stats, talents and the
-- raid buffs the reference character has.
-- Otherwise: the primary stats on the character sheet minus what the gear adds to them.
-- ponytail: that fallback is too low for casters, whose spells have a large base damage, so
-- gear differences look bigger than they are. It goes away as wowsims adds reference characters.
local SIM_LEVEL = 60
local SHEET_STAT = { [1] = 0, [2] = 1, [3] = 2, [4] = 3, [5] = 13 } -- UnitStat index -> database stat
function ns.BaseValue(links, profile)
	local _, class = UnitClass("player")
	local calibration = ns.Calibration and ns.Calibration[class] and ns.Calibration[class][profile.name]
	if calibration and UnitLevel("player") >= SIM_LEVEL then
		return math.max(0, calibration.total - ns.GearScore(calibration.ref, profile)), true
	end
	local primary, sheet = { w = {} }, 0
	for unitStat, stat in pairs(SHEET_STAT) do
		local w = profile.w[stat]
		if w then
			local _, effective = UnitStat("player", unitStat)
			if isSecret(effective) or not effective then return 0, false end
			primary.w[stat] = w
			sheet = sheet + w * effective
		end
	end
	return math.max(0, sheet - ns.GearScore(links, primary)), false
end

-- Remembers items seen on other players: proof that they can be obtained.
function ns.RecordSeen(links)
	GearOrSkillSeen = GearOrSkillSeen or {}
	for _, link in pairs(links) do
		local id = ns.ParseLink(link)
		if id then GearOrSkillSeen[id] = true end
	end
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
-- Returns rows { name, guid, level, damage, gear, rest }, the number of players left out, and
-- whether the gear estimate is calibrated with the simulator.
function ns.Compare(fight, profile)
	local me = fight.me
	local rows, leftOut = {}, 0
	if not me then return rows, leftOut, false end
	local myLinks = ns.ReadGear("player")
	local myScore = myLinks and profile and ns.GearScore(myLinks, profile) or 0
	local base, calibrated = 0, false
	if myScore > 0 then base, calibrated = ns.BaseValue(myLinks, profile) end
	for _, other in ipairs(fight.others) do
		if other.class == me.class then
			if ns.Overlap(me, other) >= SAME_SPEC_OVERLAP then
				local row = { name = other.name, guid = other.guid, level = other.level, damage = other.total / me.total - 1 }
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
	return rows, leftOut, calibrated
end

-- Level of every group member by guid: a higher level explains damage that is neither gear nor play.
local function groupLevels()
	local levels = {}
	local prefix, count = "party", GetNumGroupMembers() - 1
	if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
	for i = 0, math.max(count, 0) do
		local unit = i == 0 and "player" or prefix .. i
		local guid, level = UnitGUID(unit), UnitLevel(unit)
		if guid and not isSecret(guid) and not isSecret(level) and type(level) == "number" and level > 0 then
			levels[guid] = level
		end
	end
	return levels
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

local function readSession(sessionType)
	local meterType = Enum.DamageMeterType.DamageDone
	local session = C_DamageMeter.GetCombatSessionFromType(sessionType, meterType)
	local sources = type(session) == "table" and session.combatSources
	if type(sources) ~= "table" or #sources == 0 then return nil, false end
	local fight = { others = {}, time = GetTime() }
	local levels = groupLevels()
	if not isSecret(session.durationSeconds) then fight.duration = session.durationSeconds end
	for _, src in ipairs(sources) do
		local entry, locked = readSource(src, sessionType, meterType)
		if locked then return nil, true end
		if entry and entry.total > 0 then
			entry.level = levels[entry.guid]
			if src.isLocalPlayer then fight.me = entry else fight.others[#fight.others + 1] = entry end
		end
	end
	return fight, false
end

-- Reads the last fight from the built-in damage meter.
-- Returns a fight table, or nil plus true while the game still locks the values.
function ns.ReadFight()
	if not C_DamageMeter then return nil, false end
	local fight, locked = readSession(Enum.DamageMeterSessionType.Current)
	if fight or locked then return fight, locked end
	-- ponytail: in case the meter empties the current fight when combat ends, fall back to its
	-- running total. That compares players across all fights since the meter was reset.
	fight, locked = readSession(Enum.DamageMeterSessionType.Overall)
	if fight then fight.overall = true end
	return fight, locked
end

-- ns.fightProblem says why no fight could be read, for the window to show.
local function afterFight(attempt)
	if InCombatLockdown() then return end
	local ok, fight, locked = pcall(ns.ReadFight)
	if not ok then
		ns.fightProblem = "Reading the damage meter failed: " .. tostring(fight)
	elseif locked and attempt < METER_ATTEMPTS then
		C_Timer.After(METER_DELAY, function() afterFight(attempt + 1) end)
		return
	elseif locked then
		ns.fightProblem = "The game kept the damage meter values locked after the fight."
	elseif fight and fight.me then
		ns.lastFight, ns.fightProblem = fight, nil
		if ns.OnFight then ns.OnFight(fight) end
		return
	end
	if ns.OnGear then ns.OnGear() end -- redraw, so the reason shows
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
		local _, class = UnitClass(unit)
		if UnitExists(unit) and not UnitIsUnit(unit, "player") and not isSecret(class) and class == myClass then
			local guid = UnitGUID(unit)
			local cached = not isSecret(guid) and ns.gearCache[guid]
			if not cached or GetTime() - cached.time > INSPECT_MAX_AGE then queue[#queue + 1] = unit end
		end
	end
	nextInspect()
end

local function onInspectReady(guid)
	if isSecret(guid) then return end
	if not waitingFor or guid ~= waitingFor.guid then
		-- Someone else asked (you or another addon inspected your target): just note the items.
		local target = UnitGUID("target")
		if not isSecret(target) and target == guid then
			local links = ns.ReadGear("target")
			if links then ns.RecordSeen(links) end
		end
		return
	end
	local unit = waitingFor.unit
	waitingFor = nil
	local current = UnitGUID(unit)
	if not isSecret(current) and current == guid then
		local links = ns.ReadGear(unit)
		if links and next(links) then
			ns.gearCache[guid] = { links = links, time = GetTime() }
			ns.RecordSeen(links)
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

local redrawPending = false
local frame = CreateFrame("Frame")
for _, event in ipairs({
	"INSPECT_READY", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED",
	"PLAYER_LEVEL_UP", "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT",
}) do
	frame:RegisterEvent(event)
end
frame:SetScript("OnEvent", function(_, event, arg, success)
	if event == "INSPECT_READY" then
		onInspectReady(arg)
	elseif event == "PLAYER_REGEN_ENABLED" then
		C_Timer.After(METER_DELAY, function() afterFight(1) end)
		ns.QueueInspects()
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if ns.OnGear then ns.OnGear() end
	elseif event == "PLAYER_LEVEL_UP" then
		ns.ForgetUsable()
		if ns.OnGear then ns.OnGear() end
	elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
		-- Item data arrives in bursts; if something drawn was waiting for it, redraw once, shortly
		-- after, so prices and verdicts fill in.
		-- A failed load is ignored: asking again on the redraw would loop forever.
		if success ~= false and waitingForItems and not redrawPending then
			redrawPending = true
			C_Timer.After(0.5, function()
				redrawPending, waitingForItems = false, false
				if ns.OnGear then ns.OnGear() end
			end)
		end
	else
		ns.QueueInspects()
	end
end)
