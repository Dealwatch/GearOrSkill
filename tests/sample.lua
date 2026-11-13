-- Sample game state shared by the tests and the UI renderer: a level 60 Enhancement Shaman
-- in a group with a better-geared Shaman, an Elemental Shaman and a Rogue.
return function(Stub, ns)
	local S = Stub.state
	local ids = {}
	for id, raw in pairs(ns.Data.items) do
		local name = raw:match("%^([^%^]+)%^[^%^]+$")
		ids[name] = ids[name] or id
	end
	local function link(name, enchant, suffix)
		local id = assert(ids[name], "sample item missing from Data.lua: " .. name)
		return ("|cff0070dd|Hitem:%d:%d:0:0:0:0:%d:0:60|h[%s]|h|r"):format(id, enchant or 0, suffix or 0, name)
	end
	Stub.link = link

	local ME, THRALLIX, ZAPPI, STABBY = "Player-1-00000001", "Player-1-00000002", "Player-1-00000003", "Player-1-00000004"
	Stub.guids = { me = ME, thrallix = THRALLIX, zappi = ZAPPI }
	S.class, S.className, S.level = "SHAMAN", "Shaman", 60
	S.units = {
		player = { guid = ME, name = "You", class = "SHAMAN", className = "Shaman" },
		party1 = { guid = THRALLIX, name = "Thrallix", class = "SHAMAN", className = "Shaman" },
		party2 = { guid = ZAPPI, name = "Zappi", class = "SHAMAN", className = "Shaman" },
		party3 = { guid = STABBY, name = "Stabby", class = "ROGUE", className = "Rogue" },
	}
	S.gear = {
		player = {
			[1] = link("Mask of the Unforgiven"), [2] = link("Onyxia Tooth Pendant"), [3] = link("Truestrike Shoulders"),
			[5] = link("Onyxia Scale Breastplate"), [6] = link("Clutch of Andros"), [7] = link("Outrider's Chain Leggings"),
			[8] = link("Greaves of Withering Despair"), [10] = link("Chromatic Gauntlets"), [16] = link("Treant's Bane"),
		},
		party1 = {
			[1] = link("Mask of the Unforgiven"), [2] = link("Onyxia Tooth Pendant"), [3] = link("Truestrike Shoulders"),
			[5] = link("Dawn Armor"), [6] = link("Belt of Preserved Heads"), [7] = link("Outrider's Chain Leggings"),
			[8] = link("Kayser's Boots of Precision"), [10] = link("Voone's Vice Grips"), [16] = link("Fist of Cenarius"),
		},
		party2 = { [1] = link("Insightful Hood") },
	}
	S.sources = {
		{ classFilename = "SHAMAN", isLocalPlayer = true, name = "You", sourceGUID = ME, totalAmount = 60000 },
		{ classFilename = "SHAMAN", isLocalPlayer = false, name = "Thrallix", sourceGUID = THRALLIX, totalAmount = 79800 },
		{ classFilename = "SHAMAN", isLocalPlayer = false, name = "Zappi", sourceGUID = ZAPPI, totalAmount = 54000 },
		{ classFilename = "ROGUE", isLocalPlayer = false, name = "Stabby", sourceGUID = STABBY, totalAmount = 90000 },
	}
	S.spellNames = {
		[1] = "Melee", [2] = "Windfury Attack", [3] = "Stormstrike", [4] = "Earth Shock", [5] = "Searing Totem",
		[6] = "Lightning Shield", [7] = "Lightning Bolt", [8] = "Chain Lightning", [9] = "Sinister Strike",
	}
	S.spells = {
		[ME] = { { 1, 24600 }, { 2, 13200 }, { 3, 10800 }, { 4, 7200 }, { 5, 4200 } },
		[THRALLIX] = { { 1, 26334 }, { 2, 19152 }, { 3, 23940 }, { 4, 7182 }, { 6, 3192 } },
		[ZAPPI] = { { 7, 38000 }, { 8, 12000 }, { 4, 4000 } },
		[STABBY] = { { 9, 60000 }, { 1, 30000 } },
	}
	S.duration, S.lockedReads, S.inCombat, S.inGroup = 102, 0, false, true
end
