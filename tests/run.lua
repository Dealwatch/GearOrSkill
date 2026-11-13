-- Test suite. Run from the repo root: lua tests/run.lua
local Stub = dofile("tests/wowstub.lua")
local ns = Stub.Load({ "Data.lua", "Calibration.lua", "Measured.lua", "Core.lua", "UI.lua", "Probe.lua" })
dofile("tests/sample.lua")(Stub, ns)
local S = Stub.state

local function eq(got, want, what)
	if got ~= want then error(("%s: got %s, want %s"):format(what, tostring(got), tostring(want)), 2) end
end
local function near(got, want, what)
	if math.abs(got - want) > 0.005 then error(("%s: got %s, want %s"):format(what, tostring(got), tostring(want)), 2) end
end
local function chat() return table.concat(Stub.printed, "\n") end
local function has(text) assert(chat():find(text, 1, true), "missing in chat: " .. text .. "\n" .. chat()) end
local function texts()
	local out = {}
	for _, region in ipairs((Stub.Dump(GearOrSkillFrame))) do
		if region.kind == "text" then out[#out + 1] = region.text end
	end
	return table.concat(out, "\n")
end
local function shows(text) assert(texts():find(text, 1, true), "missing in window: " .. text .. "\n" .. texts()) end
local function case(name) Stub.printed, Stub.timers = {}, {}; io.write("ok so far, now: " .. name .. "\n") end

case("item links and database entries")
local id, enchant, suffix = ns.ParseLink("|cff1eff00|Hitem:1640:34:0:0:0:0:12721:0:60|h[Monstrous War Axe of the Monkey]|h|r")
eq(id, 1640, "item id"); eq(enchant, 34, "enchant id"); eq(suffix, 12721, "suffix id")
eq(ns.ParseLink("|Hitem:18490::::::::60|h[Insightful Hood]|h"), 18490, "item id from a short link")
local hood = ns.Item(18490)
eq(hood.name, "Insightful Hood", "item name"); eq(hood.type, 1, "item type"); eq(hood.stats[3], 15, "intellect")
eq(ns.Item(-1), nil, "unknown item")

case("scoring")
eq(ns.ItemScore(hood, { w = { [3] = 2, [18] = 1 } }, 1), 15 * 2 + 14, "weighted stats")
local axe = ns.Item(1640)
eq(ns.ItemScore(axe, { w = { [1] = 1 } }, 16, nil, 12721), math.floor(6666 * axe.rpp / 10000), "random suffix stats")
eq(ns.ItemScore(axe, { w = {}, mh = 2 }, 16), 2 * axe.dps, "weapon DPS counts in the main hand")
eq(ns.ItemScore(axe, { w = {}, mh = 2 }, 17), 0, "and not in the off hand without an off-hand weight")
local total, slots, unknown = ns.GearScore({ [1] = "|Hitem:18490::::::::60|h[Insightful Hood]|h", [2] = "|Hitem:999999999:0|h[Mystery]|h" }, { w = { [3] = 1 } })
eq(total, 15, "gear total"); eq(unknown, 1, "items missing from the database"); eq(slots[2].name, "Mystery", "name from link")

case("a caster suffix lowers the weapon damage, as in game")
local battering, magic = ns.Item(3198), 12918
eq(ns.Data.suffixNames[magic], "of Magic", "suffix name"); eq(battering.dps, 15.3, "normal damage per second")
eq(battering.casterDps, 11.4, "damage per second with a caster suffix (the game shows 11.3)")
local dpsOnly = { w = {}, mh = 1 }
eq(ns.ItemScore(battering, dpsOnly, 16, nil, magic), 11.4, "scored with the lowered damage")
eq(ns.ItemScore(battering, dpsOnly, 16, nil, 12721), 15.3, "a physical suffix keeps the normal damage")
local enhancement = ns.Data.profiles.SHAMAN[2]
local greathammer
for id, raw in pairs(ns.Data.items) do
	if raw:find("^Ironforge Greathammer^", 1, true) then greathammer = ns.Item(id) end
end
assert(ns.ItemScore(battering, enhancement, 16, nil, magic) < ns.ItemScore(greathammer, enhancement, 16),
	"for Enhancement, Battering Hammer of Magic is worse than Ironforge Greathammer")

case("upgrade suggestions respect class, level and availability")
local profile = ns.Profile()
eq(profile.name, "Elemental: Testing", "default profile is the first of the class")
GearOrSkillDB.profile = 2
profile = ns.Profile()
eq(profile.name, "Enhancement: Pre-BiS", "saved profile")
local function checkUpgrades(level)
	local upgrades = ns.Upgrades(S.gear.player, "SHAMAN", level, profile)
	assert(#upgrades > 0, "no upgrades at level " .. level)
	for i, u in ipairs(upgrades) do
		local item = u.item
		assert(u.gain > 0 and (i == 1 or u.gain <= upgrades[i - 1].gain), "gains must be positive and sorted")
		assert(item.reqLvl <= level, item.name .. " needs a higher level")
		assert(item.ilvl <= ns.Data.maxItemLevel, item.name .. " is above the item level limit")
		assert(item.classes == "-" or item.classes:find("SHAMAN", 1, true), item.name .. " is for another class")
		assert(item.armor <= 3, item.name .. " is plate")
		assert(item.type ~= 12, "trinkets are not suggested")
		if level < 40 then assert(item.armor ~= 3, item.name .. " is mail below level 40") end
		if item.type == 13 then assert(ns.Data.weapons.SHAMAN[item.weapon], item.name .. " is a weapon Shamans cannot use") end
	end
	return upgrades
end
local at60 = checkUpgrades(60)
checkUpgrades(20)

case("upgrade suggestions ask the client: missing items, armor skills, items seen on players")
local top = at60[1].item
S.missingItems[top.id] = true
for _, u in ipairs(ns.Upgrades(S.gear.player, "SHAMAN", 60, profile)) do
	assert(u.item.id ~= top.id, "an item the client does not have was suggested")
end
S.missingItems = {}
-- The tooltip verdict: an item shown in red is skipped and the next best one of the slot is offered.
ns.ForgetUsable()
local topSlot, runnerUp = at60[1].slot, nil
S.cannotUse[top.id] = true
for _, u in ipairs(ns.Upgrades(S.gear.player, "SHAMAN", 60, profile)) do
	assert(u.item.id ~= top.id, "an item the tooltip marks as unusable was suggested")
	if u.slot == topSlot then runnerUp = u end
end
assert(runnerUp and runnerUp.gain <= at60[1].gain, "the slot should fall back to its next best item")
eq(ns.CanUse(top.id), false, "verdict from the tooltip")
S.cannotUse = {}
eq(ns.CanUse(top.id), false, "verdicts are remembered")
ns.ForgetUsable()
eq(ns.CanUse(top.id), true, "until forgotten, for example after learning a skill")
S.notLoaded[top.id] = true
ns.ForgetUsable()
eq(ns.CanUse(top.id), nil, "an item the game has not loaded gets no verdict")
assert(Stub.requested[top.id], "and is asked for")
for _, u in ipairs(ns.Upgrades(S.gear.player, "SHAMAN", 60, profile)) do
	assert(u.item.id ~= top.id, "an item without a verdict was suggested")
end
Stub.timers = {}
Stub.Fire("ITEM_DATA_LOAD_RESULT", top.id, true)
eq(#Stub.timers, 1, "its arrival schedules a redraw")
Stub.RunTimers()
S.notLoaded = {}
S.halfLoaded[top.id] = true
eq(ns.CanUse(top.id), nil, "a tooltip without its slot line is still filling in: no verdict yet")
S.halfLoaded = {}
eq(ns.CanUse(top.id), true, "and it is judged for real once loaded")
eq(ns.Upgrades(S.gear.player, "SHAMAN", 60, profile)[1].item.id, top.id, "and suggested again")
local function wearsMail(level)
	for _, u in ipairs(ns.Upgrades({}, "SHAMAN", level, profile)) do
		if u.item.armor == 3 then return true end
	end
	return false
end
assert(not wearsMail(30), "no mail at 30 without the skill")
S.knownSpells[8737] = true
assert(wearsMail(30), "mail at 30 once the client says the skill is known")
S.knownSpells = {}
eq(at60[1].seen, false, "nothing seen yet")
ns.RecordSeen({ [1] = Stub.link(top.name) })
eq(ns.Upgrades(S.gear.player, "SHAMAN", 60, profile)[1].seen, true, "seen item is marked")
GearOrSkillSeen = nil

case("group members of the same class are inspected after a fight, never in combat")
S.inCombat = true
ns.QueueInspects()
eq(Stub.inspected, nil, "no inspect in combat")
S.inCombat = false
Stub.Fire("PLAYER_REGEN_ENABLED")
eq(Stub.inspected, "party1", "first inspect request")
Stub.Fire("INSPECT_READY", Stub.guids.thrallix)
assert(ns.gearCache[Stub.guids.thrallix], "gear was not cached")
Stub.RunTimers()
eq(Stub.inspected, "party2", "next group member of the same class")
assert(GearOrSkillSeen[ns.ParseLink(S.gear.party1[5])], "inspected gear is remembered as seen")
S.units.target, S.gear.target = S.units.party3, { [1] = Stub.link("Insightful Hood") }
Stub.Fire("INSPECT_READY", S.units.party3.guid)
assert(GearOrSkillSeen[18490], "a manual inspect of the target is remembered too")
S.units.target, S.gear.target = nil, nil
has("Thrallix: gear +"); has("damage +33%")

case("spell overlap decides who plays the same spec")
local fight = assert(ns.lastFight, "fight was not recorded")
eq(#fight.others, 3, "other players in the fight"); eq(fight.me.total, 60000, "own damage")
local rows, leftOut = ns.Compare(fight, profile)
eq(#rows, 1, "comparable players"); eq(rows[1].name, "Thrallix", "comparable player"); eq(leftOut, 1, "same class, other spec")
near(rows[1].damage, 0.33, "damage difference")

case("item data arriving redraws once per burst, only when something waited for it")
Stub.Fire("GET_ITEM_INFO_RECEIVED", 1, true) -- settle whatever earlier cases left waiting
Stub.RunTimers()
Stub.Fire("GET_ITEM_INFO_RECEIVED", 1640, true)
eq(#Stub.timers, 0, "nothing was waiting, so no redraw")
S.notLoaded[1640] = true
eq(ns.CanUse(1640), nil, "an unloaded item makes the window wait")
Stub.Fire("GET_ITEM_INFO_RECEIVED", 999999999, false)
eq(#Stub.timers, 0, "no redraw for a failed load")
Stub.Fire("GET_ITEM_INFO_RECEIVED", 1640, true)
Stub.Fire("GET_ITEM_INFO_RECEIVED", 1641, true)
eq(#Stub.timers, 1, "one redraw for a burst of loaded items")
Stub.RunTimers()
S.notLoaded = {}
ns.ForgetUsable()

case("gear difference and the part it does not explain")
rows = ns.Compare(fight, profile)
assert(rows[1].gear and rows[1].gear > 0, "Thrallix has better gear in the sample")
near(rows[1].rest, rows[1].damage - rows[1].gear, "unexplained part")
local mine, theirs = ns.GearScore(S.gear.player, profile), ns.GearScore(S.gear.party1, profile)
assert(rows[1].gear < theirs / mine - 1, "the part that is not gear must dampen the gear difference")

case("gear estimate: calibrated at max level, character sheet below")
local calibration = ns.Calibration.SHAMAN["Enhancement: Pre-BiS"]
local base, calibrated = ns.BaseValue(S.gear.player, profile)
eq(calibrated, true, "calibrated at level 60")
eq(base, calibration.total - ns.GearScore(calibration.ref, profile), "base is the reference character minus its gear")
assert(select(2, ns.GearScore(calibration.ref, profile)) and select(3, ns.GearScore(calibration.ref, profile)) == 0, "every reference item is in the database")
near(rows[1].gear, (base + theirs) / (base + mine) - 1, "gear difference uses the calibrated base")
S.level = 59
local sheet, fromSim = ns.BaseValue(S.gear.player, profile)
eq(fromSim, false, "below max level the character sheet is used"); assert(sheet > 0, "sheet value")
S.level = 60
GearOrSkillDB.profile = 1
eq(select(2, ns.BaseValue(S.gear.player, ns.Profile())), true, "Elemental is calibrated too")
GearOrSkillDB.profile = 2
for class, list in pairs(ns.Calibration) do
	for name in pairs(list) do
		local found = false
		for _, p in ipairs(ns.Data.profiles[class]) do found = found or p.name == name end
		assert(found, "calibration for a profile that does not exist: " .. name)
	end
end

case("levels: another level is recorded and pointed out")
S.units.party1.level = 58
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.RunTimers()
eq(ns.lastFight.me.level, 60, "own level"); eq(ns.Compare(ns.lastFight, profile)[1].level, 58, "level of the other player")
SlashCmdList.GEARORSKILL("")
ns.ShowTab("Group")
shows("Lvl in yellow: another level than yours.")
S.units.party1.level = nil
ns.lastFight = fight
ns.ShowTab("Group")
assert(not texts():find("Lvl in yellow", 1, true), "no level note when everyone has your level")
ns.ShowTab("Me")
SlashCmdList.GEARORSKILL("")

case("meter values locked right after combat are read on a retry")
ns.lastFight, S.lockedReads = nil, 1
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.RunTimers()
assert(ns.lastFight, "fight was not recorded after the retry")

case("meter values that stay locked leave the last fight alone and say why")
ns.lastFight, S.lockedReads = nil, 100
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.RunTimers()
eq(ns.lastFight, nil, "no fight from locked values")
eq(ns.fightProblem, "The game kept the damage meter values locked after the fight.", "reason for the window")
S.lockedReads = 0

case("a failing meter read is reported, an empty current fight falls back to the running total")
S.meterError = "boom"
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.RunTimers()
assert(ns.fightProblem:find("Reading the damage meter failed", 1, true) and ns.fightProblem:find("boom", 1, true), ns.fightProblem)
SlashCmdList.GEARORSKILL("")
ns.ShowTab("Group"); shows("Reading the damage meter failed")
S.meterError, S.currentEmpty = nil, true
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.RunTimers()
eq(ns.fightProblem, nil, "problem cleared by a good read"); eq(ns.lastFight.overall, true, "running total used")
ns.ShowTab("Group"); shows("all fights 1:42")
S.currentEmpty = nil
ns.lastFight = fight

case("window: height follows the content, and a drawing error is shown instead of a broken tab")
ns.ShowTab("Me")
local _, _, _, _, meHeight = Stub.Dump(GearOrSkillFrame)
ns.ShowTab("Group")
local _, _, _, _, groupHeight = Stub.Dump(GearOrSkillFrame)
assert(groupHeight < meHeight and groupHeight > 150, "group tab should be shorter than the me tab: " .. groupHeight .. " vs " .. meHeight)
local realCompare = ns.Compare
ns.Compare = function() error("kaputt") end
Stub.printed = {}
ns.ShowTab("Group")
shows("This tab ran into an error"); has("kaputt")
ns.Compare = realCompare
ns.ShowTab("Me")
SlashCmdList.GEARORSKILL("")

case("window: tabs, profile switch, click through to the spell view")
SlashCmdList.GEARORSKILL("")
assert(GearOrSkillFrame:IsShown(), "window did not open")
shows("Enhancement: Pre-BiS"); shows("Hit"); shows("BEST UPGRADES FOR YOUR LEVEL"); shows("Gear score")
shows("seen: a player you inspected wears it")
ns.ShowTab("Group")
shows("Thrallix"); shows("+33%"); shows("1 player(s) of your class left out")
shows("The gear estimate is calibrated with the simulator for your profile.")
local clicked
for _, button in ipairs(Stub.Buttons(GearOrSkillFrame)) do
	if button.w and button.w > 400 then button.scripts.OnClick(); clicked = true; break end
end
assert(clicked, "no player row to click")
shows("You vs Thrallix"); shows("Stormstrike"); shows("Biggest gap: Stormstrike. Thrallix gets 12 points more")
ns.ShowTab("Me")
for _, button in ipairs(Stub.Buttons(GearOrSkillFrame)) do
	if button.w == 330 then button.scripts.OnClick() end
end
shows("Elemental: Testing")
GearOrSkillDB.profile = 2
SlashCmdList.GEARORSKILL("")
assert(not GearOrSkillFrame:IsShown(), "window did not close")

case("window: class without weights, and no fight yet")
S.units.player.class, S.units.player.className = "MAGE", "Mage"
ns.lastFight = nil
SlashCmdList.GEARORSKILL("")
shows("wowsims has no stat weights for this class yet.")
ns.ShowTab("Group"); shows("No fight recorded yet")
ns.ShowTab("Fight"); shows("No fight recorded yet")
SlashCmdList.GEARORSKILL("")
S.units.player.class, S.units.player.className = "SHAMAN", "Shaman"
ns.lastFight = fight

case("shop: needs Auctionator; lists what it has a price for, at most two per slot")
SlashCmdList.GEARORSKILL("")
ns.ShowTab("Shop")
shows("Auctionator is not installed or not turned on.")
Auctionator = Stub.Auctionator
local shop = ns.ShopList(S.gear.player, "SHAMAN", 60, profile, false)
assert(#shop > 0, "no shop rows")
local perSlot, fixed, suffixed = {}, nil, nil
local _, wornSlots = ns.GearScore(S.gear.player, profile)
for i, row in ipairs(shop) do
	eq(row.price, Stub.auctionPrice(row.id), "price comes from Auctionator")
	eq(row.loss, math.max(row.price - S.sellPrice(row.id), 0), "loss is price minus vendor value")
	eq(row.old, row.id % 6 > 3, "old price flag")
	assert(row.gain >= 1 and (i == 1 or row.gain <= shop[i - 1].gain), "gains at least 1 and sorted")
	local slotName = ns.SLOT_NAME[row.slot]
	perSlot[slotName] = (perSlot[slotName] or 0) + 1
	assert(perSlot[slotName] <= 2, "more than two rows for " .. slotName)
	if not row.upTo then fixed = fixed or row end
end
-- Random-suffix items matter while leveling: at 20 they make the list, at 60 fixed items beat them.
for _, row in ipairs(ns.ShopList(S.gear.player, "SHAMAN", 20, profile, false)) do
	if row.upTo then suffixed = suffixed or row end
end
assert(fixed and suffixed, "the sample should yield both fixed and random-suffix items")
local item, best, bestName = ns.Item(suffixed.id), 0, nil
for suffix in item.suffixes:gmatch("%d+") do
	local score = ns.ItemScore(item, profile, suffixed.slot, nil, tonumber(suffix))
	if score > best then best, bestName = score, ns.Data.suffixNames[tonumber(suffix)] end
end
eq(suffixed.suffix, bestName, "a suffix item names its best suffix")
near(suffixed.gain, best - (wornSlots[suffixed.slot] and wornSlots[suffixed.slot].score or 0), "a suffix item shows the gain of its best suffix")
eq(ns.Item(fixed.id).suffixes, "-", "fixed items have no suffix options")

S.cannotUse[shop[1].id] = true
ns.ForgetUsable()
for _, row in ipairs(ns.ShopList(S.gear.player, "SHAMAN", 60, profile, false)) do
	assert(row.id ~= shop[1].id, "the shop listed an item the tooltip marks as unusable")
end
S.cannotUse = {}
ns.ForgetUsable()

case("shop: sorting by value for money, and nothing without prices")
local byValue = ns.ShopList(S.gear.player, "SHAMAN", 60, profile, true)
for i = 2, #byValue do
	local a, b = byValue[i - 1], byValue[i]
	assert(a.gain / math.max(a.loss, 1) >= b.gain / math.max(b.loss, 1), "value order broken at row " .. i)
end
local realPrice = Stub.auctionPrice
Stub.auctionPrice = function() return nil end
eq(#ns.ShopList(S.gear.player, "SHAMAN", 60, profile, false), 0, "no prices, no rows")
ns.ShowTab("Shop"); shows("Auctionator knows no price for anything better than your gear.")
Stub.auctionPrice = realPrice

case("shop: hand-off to Auctionator, with the auction house closed, open, and an old build")
local message = ns.ShopSearch(shop)
assert(message:find("Saved as shopping list", 1, true), message)
eq(#Stub.lists.GearOrSkill, #shop, "one search term per row"); eq(Stub.lists.GearOrSkill[1], shop[1].name, "terms are item names")
eq(#Stub.searches, 0, "no live search while the auction house is closed")
AuctionHouseFrame = { IsShown = function() return true end }
message = ns.ShopSearch(shop)
assert(message:find("Searching for " .. #shop .. " items", 1, true), message)
eq(#Stub.searches, 1, "live search with the auction house open")
local api = Stub.Auctionator.API.v1
local create, multi = api.CreateShoppingList, api.MultiSearch
api.CreateShoppingList, api.MultiSearch = nil, nil
assert(ns.ShopSearch(shop):find("offers no shopping lists", 1, true), "old build message")
api.CreateShoppingList, api.MultiSearch = create, multi
eq(ns.ShopSearch({}), "Nothing to search for.", "empty list")

case("shop tab: table, sort toggle and search button")
ns.ShowTab("Shop")
shows("Auction house upgrades"); shows("Sorted by gain."); shows(shop[1].name); shows("Search these in Auctionator")
S.level = 20
ns.ShowTab("Shop"); shows("up to +"); shows('best as "of ')
S.level = 60
ns.ShowTab("Shop")
for _, button in ipairs(Stub.Buttons(GearOrSkillFrame)) do
	if button.h == 18 then button.scripts.OnClick() end
end
shows("Sorted by value for money.")
for _, button in ipairs(Stub.Buttons(GearOrSkillFrame)) do
	if button.w == 220 then button.scripts.OnClick() end
end
shows("Searching for ")
ns.ShowTab("Me")
SlashCmdList.GEARORSKILL("")
Auctionator, AuctionHouseFrame = nil, nil

case("a class without published weights uses the measured ones, until wowsims publishes")
S.units.player.class, S.units.player.className = "HUNTER", "Hunter"
GearOrSkillDB.profile = nil
local hunter = ns.Profile()
eq(hunter.name, "BM", "first measured Hunter profile"); eq(hunter.measured, true, "marked as measured")
assert(hunter.w[1] > hunter.w[15] and hunter.rg > 1, "agility and ranged weapon damage carry weight for a Hunter")
local hunterUpgrades = ns.Upgrades({}, "HUNTER", 60, hunter)
local ranged
for _, u in ipairs(hunterUpgrades) do
	assert(u.item.classes == "-" or u.item.classes:find("HUNTER", 1, true), u.item.name .. " is for another class")
	if u.slot == 18 then ranged = u.item end
end
assert(ranged and ns.Data.ranged.HUNTER[ranged.ranged], "a Hunter gets a ranged weapon suggested")
SlashCmdList.GEARORSKILL("")
ns.ShowTab("Me")
shows("BM"); shows("ranged weapon DPS"); shows("measured by GearOrSkill with the wowsims simulator")
SlashCmdList.GEARORSKILL("")
ns.Data.profiles.HUNTER = { { name = "From wowsims", w = { [1] = 1 } } }
eq(ns.Profile().name, "From wowsims", "published weights take over by themselves")
ns.Data.profiles.HUNTER = nil
S.units.player.class, S.units.player.className = "SHAMAN", "Shaman"
GearOrSkillDB.profile = 2

case("probe: gear of player and target")
S.units.target = S.units.party1
S.gear.target = S.gear.party1
SlashCmdList.GEARORSKILL("probe")
Stub.Fire("INSPECT_READY", Stub.guids.thrallix)
Stub.RunTimers()
has("Armor skills at level 60: mail no, plate no")
has("Weapons you can use, by tooltip: ")
SlashCmdList.GEARORSKILL("probe tooltip 1318")
has("Item 1318: loaded true, usable by the addon's check: true"); has("2: type 21 [Two-Hand]")
SlashCmdList.GEARORSKILL("probe tooltip")
has("Usage: /gos probe tooltip <item id>")
has("[OK]|r Your gear: 9 items, 9 with readable stats")
has("[OK]|r Target Thrallix: 9 items, 9 with readable stats")
has("Target talents: spec id 0, talent data no")

case("probe: inspect never answers")
SlashCmdList.GEARORSKILL("probe")
Stub.RunTimers()
has("[BLOCKED]|r Target: no inspect answer after 5 seconds")

case("probe: meter readable, locked then readable, locked for good, in combat")
SlashCmdList.GEARORSKILL("probe meter")
has("[OK]|r Meter, this fight: other players damage 3/3, spells 3/3")
Stub.printed, S.lockedReads = {}, 2
SlashCmdList.GEARORSKILL("probe meter")
eq(#Stub.printed, 0, "verdict must wait for the retry")
Stub.RunTimers()
has("[OK]|r Meter, overall: other players damage 3/3, spells 3/3")
Stub.printed, S.lockedReads = {}, 100
SlashCmdList.GEARORSKILL("probe meter")
Stub.RunTimers()
has("[BLOCKED]|r Meter, this fight: other players damage 0/3, spells 0/3")
S.lockedReads, S.inCombat = 0, true
SlashCmdList.GEARORSKILL("probe meter")
has("[INFO]|r Meter: in combat")
S.inCombat = false
case("probe: Auctionator missing, then present with one function absent")
SlashCmdList.GEARORSKILL("probe auctionator")
has("[INFO]|r Auctionator is not loaded")
Auctionator = { Constants = { IsLegacyAH = false }, API = { v1 = {
	GetAuctionPriceByItemID = function(caller, id) assert(caller == "GearOrSkill" and type(id) == "number") return 1200 end,
	GetAuctionPriceByItemLink = function(_, link) return link:find("Treant") and 5000 or nil end,
	GetAuctionAgeByItemLink = function() return 1 end,
	GetVendorPriceByItemID = function() return 800 end,
	IsAuctionDataExactByItemLink = function(_, link) return link:find("Treant") ~= nil end,
	CreateShoppingList = function() end,
	RegisterForDBUpdate = function() end,
} } }
SlashCmdList.GEARORSKILL("probe auctionator")
has("[PARTIAL]|r Auctionator functions: missing MultiSearchExact")
has("Auctionator prices random-suffix items together, per base item")
has("Auctionator knows a price for 1 of your 9 equipped items, 1 of them exact")
Auctionator = nil

for _, line in ipairs(GearOrSkillProbeLog) do
	assert(not line:find("error", 1, true), "probe hit an error: " .. line)
end

io.write("all tests passed\n")
