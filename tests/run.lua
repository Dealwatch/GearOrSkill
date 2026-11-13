-- Test suite. Run from the repo root: lua tests/run.lua
local Stub = dofile("tests/wowstub.lua")
local ns = Stub.Load({ "Data.lua", "Core.lua", "UI.lua", "Probe.lua" })
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
checkUpgrades(60)
checkUpgrades(20)

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
has("Thrallix: gear +"); has("damage +33%")

case("spell overlap decides who plays the same spec")
local fight = assert(ns.lastFight, "fight was not recorded")
eq(#fight.others, 3, "other players in the fight"); eq(fight.me.total, 60000, "own damage")
local rows, leftOut = ns.Compare(fight, profile)
eq(#rows, 1, "comparable players"); eq(rows[1].name, "Thrallix", "comparable player"); eq(leftOut, 1, "same class, other spec")
near(rows[1].damage, 0.33, "damage difference")

case("gear difference and the part it does not explain")
rows = ns.Compare(fight, profile)
assert(rows[1].gear and rows[1].gear > 0, "Thrallix has better gear in the sample")
near(rows[1].rest, rows[1].damage - rows[1].gear, "unexplained part")
local mine, theirs = ns.GearScore(S.gear.player, profile), ns.GearScore(S.gear.party1, profile)
assert(rows[1].gear < theirs / mine - 1, "base stats must dampen the gear difference")
assert(ns.BaseValue(S.gear.player, profile) > 0, "base value from the character sheet")

case("meter values locked right after combat are read on a retry")
ns.lastFight, S.lockedReads = nil, 1
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.RunTimers()
assert(ns.lastFight, "fight was not recorded after the retry")

case("meter values that stay locked leave the last fight alone")
ns.lastFight, S.lockedReads = nil, 100
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.RunTimers()
eq(ns.lastFight, nil, "no fight from locked values")
S.lockedReads = 0
ns.lastFight = fight

case("window: tabs, profile switch, click through to the spell view")
SlashCmdList.GEARORSKILL("")
assert(GearOrSkillFrame:IsShown(), "window did not open")
shows("Enhancement: Pre-BiS"); shows("Hit"); shows("BEST UPGRADES FOR YOUR LEVEL"); shows("Gear score")
ns.ShowTab("Group")
shows("Thrallix"); shows("+33%"); shows("1 player(s) of your class left out")
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

case("probe: gear of player and target")
S.units.target = S.units.party1
S.gear.target = S.gear.party1
SlashCmdList.GEARORSKILL("probe")
Stub.Fire("INSPECT_READY", Stub.guids.thrallix)
Stub.RunTimers()
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
for _, line in ipairs(GearOrSkillProbeLog) do
	assert(not line:find("error", 1, true), "probe hit an error: " .. line)
end

io.write("all tests passed\n")
