-- The window: tabs "Me", "Group", "Fight" and "Shop". Everything is redrawn from scratch on change.
local _, ns = ...
local Data = ns.Data

local W, H, PAD, TOP = 560, 566, 14, 62
local INNER = W - 2 * PAD - 24 -- drawable width inside the content panel
local MAX_WEIGHTS, MAX_UPGRADES, MAX_SPELLS, MAX_PLAYERS, MAX_SHOP = 8, 5, 10, 8, 8
local NOTABLE = 0.05 -- differences below 5% are treated as noise

local C = {
	text = { 0.91, 0.90, 0.88 }, dim = { 0.60, 0.60, 0.56 }, gold = { 1, 0.82, 0 },
	ok = { 0.25, 0.75, 0.25 }, bad = { 1, 0.35, 0.29 }, me = { 0.35, 0.56, 0.85 }, other = { 0.79, 0.64, 0.15 },
	track = { 0.15, 0.15, 0.18 }, weight = { 0.48, 0.42, 0.16 }, stripe = { 1, 1, 1, 0.03 }, flag = { 1, 0.35, 0.29, 0.10 },
	line = { 0.17, 0.17, 0.20 },
}

local tab, selected = "Me", nil -- selected: guid of the player shown in the Fight tab
local shopByValue, shopNote = false, nil -- Shop tab: sort order, and the answer to the last search
local draw = {}

local main = CreateFrame("Frame", "GearOrSkillFrame", UIParent)
main:SetSize(W, H)
main:SetPoint("TOP", UIParent, "TOP", 0, -90) -- anchored at the top: the height follows the content
main:SetFrameStrata("HIGH")
main:EnableMouse(true)
main:SetMovable(true)
main:SetClampedToScreen(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", main.StartMoving)
main:SetScript("OnDragStop", main.StopMovingOrSizing)
main:Hide()
tinsert(UISpecialFrames, "GearOrSkillFrame") -- closes with Escape

local function fill(parent, layer, color, inset)
	local t = parent:CreateTexture(nil, layer)
	t:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
	t:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset)
	t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	return t
end

local function label(parent, font, text, color, point, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(font)
	fs:SetPoint(point, parent, point, x, y)
	fs:SetText(text)
	fs:SetTextColor(color[1], color[2], color[3])
	return fs
end

fill(main, "BACKGROUND", { 0.29, 0.27, 0.22 }, 0)
fill(main, "BORDER", { 0.06, 0.06, 0.08, 0.97 }, 1)
label(main, GameFontNormalLarge, "GearOrSkill", C.gold, "TOPLEFT", PAD, -11)

local close = CreateFrame("Button", nil, main)
close:SetSize(24, 24)
close:SetPoint("TOPRIGHT", main, "TOPRIGHT", -6, -6)
label(close, GameFontHighlightLarge, "x", C.dim, "CENTER", 0, 1)
close:SetScript("OnClick", function() main:Hide() end)

local content = CreateFrame("Frame", nil, main)
content:SetPoint("TOPLEFT", main, "TOPLEFT", PAD, -TOP)
content:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -PAD, PAD)
fill(content, "BACKGROUND", C.line, 0)
fill(content, "BORDER", { 0.09, 0.09, 0.11 }, 1)

-- Pools: regions are created once and reused on every redraw.
local pools = { text = {}, rect = {}, click = {} }
local used = { text = 0, rect = 0, click = 0 }

local function take(kind, create)
	used[kind] = used[kind] + 1
	local region = pools[kind][used[kind]]
	if not region then
		region = create()
		pools[kind][used[kind]] = region
	end
	region:ClearAllPoints()
	region:Show()
	return region
end

local function text(x, y, width, str, color, justify, font, wrap)
	local fs = take("text", function() return content:CreateFontString(nil, "OVERLAY") end)
	fs:SetFontObject(font or GameFontHighlight)
	fs:SetPoint("TOPLEFT", content, "TOPLEFT", x + 12, -(y + 10))
	fs:SetWidth(width)
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(wrap == true)
	fs:SetText(str)
	color = color or C.text
	fs:SetTextColor(color[1], color[2], color[3])
	return fs
end

-- A sentence that wraps across the panel instead of being cut off. Returns the y below it.
-- Small and grey by default, for footnotes.
local function note(y, str, color, font)
	local fs = text(0, y, INNER, str, color or C.dim, "LEFT", font or GameFontDisableSmall, true)
	return y + math.ceil(fs:GetStringHeight()) + 2
end

-- level: draw order among rectangles (0 backdrop stripes, 1 bar tracks, 2 bar fills).
local function rect(x, y, width, height, color, level)
	local t = take("rect", function() return content:CreateTexture(nil, "ARTWORK") end)
	t:SetDrawLayer("ARTWORK", level or 0)
	t:SetPoint("TOPLEFT", content, "TOPLEFT", x + 12, -(y + 10))
	t:SetSize(math.max(width, 1), height)
	t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
end

local function bar(x, y, width, height, fraction, color)
	rect(x, y, width, height, C.track, 1)
	if fraction > 0 then rect(x, y, width * math.min(fraction, 1), height, color, 2) end
end

local function click(x, y, width, height, fn)
	local b = take("click", function() return CreateFrame("Button", nil, content) end)
	b:SetPoint("TOPLEFT", content, "TOPLEFT", x + 12, -(y + 10))
	b:SetSize(width, height)
	b:SetScript("OnClick", fn)
end

local function section(y, title)
	text(0, y, INNER, title:upper(), C.dim, "LEFT", GameFontDisableSmall)
end

local function percent(x)
	return string.format("%+d%%", math.floor(x * 100 + 0.5))
end

local function share(x)
	return string.format("%d%%", math.floor(x * 100 + 0.5))
end

local function number(n)
	local s = tostring(math.floor(n + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function classColor(class)
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	return c and { c.r, c.g, c.b } or C.text
end

local function clear()
	for kind, pool in pairs(pools) do
		for i = 1, #pool do pool[i]:Hide() end
		used[kind] = 0
	end
end

-- Every draw function returns how far down its content reaches; the window is sized to fit.
local function Refresh()
	clear()
	local ok, bottom = pcall(draw[tab])
	if not ok then
		-- Show the problem instead of a half-drawn tab; the full text goes to chat for reporting.
		local problem = tostring(bottom)
		clear()
		text(0, 0, INNER, "This tab ran into an error", C.bad, "LEFT", GameFontNormalLarge)
		bottom = note(30, problem, C.text, GameFontHighlight)
		bottom = note(bottom + 4, "The message is in the chat window too.")
		print("|cff33ff99GoS|r " .. problem)
	end
	main:SetHeight(TOP + 10 + bottom + 14 + PAD)
end

function draw.Me()
	local profile, list = ns.Profile()
	local className, class = UnitClass("player")
	local level = UnitLevel("player")
	if not profile then
		text(0, 0, INNER, className .. ", level " .. level, classColor(class), "LEFT", GameFontNormalLarge)
		local y = note(30, "wowsims has no stat weights for this class yet.", C.text, GameFontHighlight)
		return note(y + 2, "Gear cannot be rated until it does. The Fight tab still works.", C.dim, GameFontHighlight)
	end
	local links = ns.ReadGear("player") or {}
	local total, _, unknown = ns.GearScore(links, profile)
	text(0, 0, 330, profile.name, classColor(class), "LEFT", GameFontNormalLarge)
	text(INNER - 180, 2, 180, "Gear score  " .. number(total), C.gold, "RIGHT")
	if #list > 1 then
		text(0, 20, 330, "Click to switch profile", C.dim, "LEFT", GameFontDisableSmall)
		click(0, 0, 330, 32, function()
			GearOrSkillDB.profile = (GearOrSkillDB.profile or 1) % #list + 1
			Refresh()
		end)
	end

	section(44, "What each stat point is worth")
	local weights = {}
	for stat, value in pairs(profile.w) do
		if value > 0 then weights[#weights + 1] = { Data.statNames[stat] or "?", value } end
	end
	table.sort(weights, function(a, b) return a[2] > b[2] end)
	local y, top = 62, weights[1] and weights[1][2] or 1
	for i = 1, math.min(MAX_WEIGHTS, #weights) do
		text(0, y, 120, weights[i][1])
		bar(126, y + 2, INNER - 126 - 46, 9, weights[i][2] / top, C.weight)
		text(INNER - 40, y, 40, string.format("%.1f", weights[i][2]), C.text, "RIGHT")
		y = y + 18
	end
	if profile.mh then
		text(0, y + 2, INNER, "One point of main-hand weapon DPS is worth " .. string.format("%.1f", profile.mh) .. ".", C.dim)
		y = y + 18
	end

	y = y + 12
	section(y, "Best upgrades for your level")
	y = y + 18
	text(0, y, 70, "Slot", C.dim)
	text(74, y, 146, "Equipped", C.dim)
	text(224, y, 230, "Upgrade and where to get it", C.dim)
	text(INNER - 50, y, 50, "Gain", C.dim, "RIGHT")
	rect(0, y + 16, INNER, 1, C.line)
	y = y + 20
	local upgrades = ns.Upgrades(links, class, level, profile)
	local anySeen = false
	for i = 1, math.min(MAX_UPGRADES, #upgrades) do
		local u = upgrades[i]
		if i % 2 == 0 then rect(-6, y - 2, INNER + 12, 34, C.stripe) end
		text(0, y, 70, ns.SLOT_NAME[u.slot])
		text(74, y, 146, u.equipped, C.dim)
		text(224, y, 230, u.item.name)
		text(224, y + 15, 230, u.item.source, C.dim, "LEFT", GameFontDisableSmall)
		text(INNER - 50, y, 50, "+" .. number(u.gain), C.ok, "RIGHT")
		if u.seen then
			anySeen = true
			text(INNER - 50, y + 15, 50, "seen", C.ok, "RIGHT", GameFontDisableSmall)
		end
		y = y + 34
	end
	if #upgrades == 0 then
		text(0, y, INNER, "Nothing better found for your level.", C.dim)
		y = y + 20
	end
	local notes = { "Weights and items: wowsims, data of " .. Data.built .. ". Weights are measured for level 60." }
	if anySeen then notes[#notes + 1] = "seen: a player you inspected wears it, so it can be obtained." end
	if unknown > 0 then notes[#notes + 1] = unknown .. " equipped item(s) are not in the database and count as zero." end
	y = y + 8
	for _, line in ipairs(notes) do y = note(y, line) end
	return y
end

local function fightHeader(fight, left, right)
	text(0, 0, 250, left, C.text, "LEFT", GameFontNormalLarge)
	local duration = fight.duration and string.format("%d:%02d", math.floor(fight.duration / 60), math.floor(fight.duration % 60))
	local scope = fight.overall and "all fights" or "last fight"
	text(INNER - 270, 3, 270, scope .. (duration and (" " .. duration) or "") .. ", " .. right, C.dim, "RIGHT")
end

local function noFight()
	text(0, 0, INNER, "No fight recorded yet", C.text, "LEFT", GameFontNormalLarge)
	local y = note(30, "Fight something in a group. This fills in a few seconds after combat ends.", C.text, GameFontHighlight)
	if C_CVar and C_CVar.GetCVarBool("damageMeterEnabled") == false then
		y = note(y + 2, "The built-in damage meter is off. Turn it on in the game options first.", C.bad, GameFontHighlight)
	end
	if ns.fightProblem then y = note(y + 2, ns.fightProblem, C.bad, GameFontHighlight) end
	return y
end

function draw.Group()
	local fight = ns.lastFight
	if not fight then return noFight() end
	local _, class = UnitClass("player")
	local rows, leftOut, calibrated = ns.Compare(fight, (ns.Profile()))
	fightHeader(fight, "Players like you", "same class, same spells")
	local y = 34
	local myLevel, otherLevels = fight.me.level or UnitLevel("player"), false
	text(0, y, 116, "Player", C.dim)
	text(118, y, 30, "Lvl", C.dim, "RIGHT")
	text(150, y, 80, "Gear", C.dim, "RIGHT")
	text(236, y, 80, "Damage", C.dim, "RIGHT")
	text(316, y, 140, "Not explained by gear", C.dim, "RIGHT")
	rect(0, y + 16, INNER, 1, C.line)
	y = y + 22
	text(0, y, 116, "You", classColor(class))
	text(118, y, 30, tostring(myLevel), C.dim, "RIGHT")
	text(150, y, 80, "baseline", C.dim, "RIGHT")
	text(236, y, 80, number(fight.me.total), C.dim, "RIGHT")
	y = y + 22
	for i = 1, math.min(MAX_PLAYERS, #rows) do
		local row = rows[i]
		if i % 2 == 1 then rect(-6, y - 3, INNER + 12, 22, C.stripe) end
		local differs = row.level ~= nil and row.level ~= myLevel
		otherLevels = otherLevels or differs
		text(0, y, 116, row.name, classColor(class))
		text(118, y, 30, row.level and tostring(row.level) or "?", differs and C.gold or C.dim, "RIGHT")
		text(150, y, 80, row.gear and percent(row.gear) or "not seen", row.gear and C.text or C.dim, "RIGHT")
		text(236, y, 80, percent(row.damage), C.text, "RIGHT")
		if row.rest then
			local color = row.rest > NOTABLE and C.bad or row.rest < -NOTABLE and C.ok or C.text
			text(316, y, 140, percent(row.rest), color, "RIGHT")
			bar(INNER - 42, y + 3, 42, 8, math.abs(row.rest) / 0.5, color)
		end
		click(-6, y - 3, INNER + 12, 22, function()
			selected, tab = row.guid, "Fight"
			ns.ShowTab()
		end)
		y = y + 22
	end
	if #rows == 0 then
		y = note(y, "Nobody else of your class played the same way in this fight.", C.dim, GameFontHighlight) + 4
	end
	y = y + 12
	local notes = {
		"Gear: damage difference expected from the items alone, by the weights of your profile.",
		"Not explained by gear: rotation, talents, buffs, time on target.",
		calibrated and "The gear estimate is calibrated with the simulator for your profile."
			or "Rough gear estimate: the simulator has no reference character for your profile or level yet.",
		"Red: the other player gets more out of the gear. Green: you do. Click a player for the spell view.",
	}
	if otherLevels then notes[#notes + 1] = "Lvl in yellow: another level than yours. Level alone changes damage, so that gap is not only gear and play." end
	if leftOut > 0 then notes[#notes + 1] = leftOut .. " player(s) of your class left out: they use different spells." end
	for _, line in ipairs(notes) do y = note(y, line) end
	return y
end

function draw.Fight()
	local fight = ns.lastFight
	if not fight then return noFight() end
	local rows = ns.Compare(fight, (ns.Profile()))
	local other
	for _, candidate in ipairs(fight.others) do
		for _, row in ipairs(rows) do
			if row.guid == candidate.guid and (candidate.guid == selected or not other) then other = candidate end
		end
	end
	if not other then
		text(0, 0, INNER, "Nobody to compare with", C.text, "LEFT", GameFontNormalLarge)
		return note(30, "Nobody else of your class played the same way in the last fight.", C.dim, GameFontHighlight)
	end
	local me = fight.me
	fightHeader(fight, "You vs " .. other.name, "share of total damage")
	local spells, seen = {}, {}
	for _, source in ipairs({ me, other }) do
		for id in pairs(source.spells) do
			if not seen[id] then
				seen[id] = true
				local mine, theirs = (me.spells[id] or 0) / me.total, (other.spells[id] or 0) / other.total
				spells[#spells + 1] = { id = id, mine = mine, theirs = theirs }
			end
		end
	end
	table.sort(spells, function(a, b) return math.max(a.mine, a.theirs) > math.max(b.mine, b.theirs) end)
	local gap
	for _, s in ipairs(spells) do
		if not gap or s.theirs - s.mine > gap.theirs - gap.mine then gap = s end
	end
	local y = 34
	text(0, y, 170, "Spell", C.dim)
	text(170, y, 70, "You", C.me, "RIGHT")
	text(246, y, 80, other.name, C.other, "RIGHT")
	text(332, y, 50, "Diff", C.dim, "RIGHT")
	rect(0, y + 16, INNER, 1, C.line)
	y = y + 22
	local barX, barW = 394, INNER - 394
	for i = 1, math.min(MAX_SPELLS, #spells) do
		local s = spells[i]
		local diff = math.floor((s.mine - s.theirs) * 100 + 0.5)
		if s == gap and s.theirs - s.mine > NOTABLE then
			rect(-6, y - 4, INNER + 12, 26, C.flag)
		elseif i % 2 == 0 then
			rect(-6, y - 4, INNER + 12, 26, C.stripe)
		end
		text(0, y, 170, C_Spell.GetSpellName(s.id) or ("Spell " .. s.id))
		text(170, y, 70, s.mine > 0 and share(s.mine) or "not used", s.mine > 0 and C.text or C.dim, "RIGHT")
		text(246, y, 80, s.theirs > 0 and share(s.theirs) or "not used", s.theirs > 0 and C.text or C.dim, "RIGHT")
		text(332, y, 50, string.format("%+d", diff), diff <= -NOTABLE * 100 and C.bad or C.text, "RIGHT")
		bar(barX, y + 1, barW, 5, s.mine / 0.6, C.me)
		bar(barX, y + 8, barW, 5, s.theirs / 0.6, C.other)
		y = y + 26
	end
	y = y + 8
	if gap and gap.theirs - gap.mine > NOTABLE then
		local name = C_Spell.GetSpellName(gap.id) or ("Spell " .. gap.id)
		local points = math.floor((gap.theirs - gap.mine) * 100 + 0.5)
		return note(y, "Biggest gap: " .. name .. ". " .. other.name .. " gets " .. points .. " points more of the damage from it.")
	end
	return note(y, "No spell stands out. You both spread your damage the same way.")
end

local function money(copper)
	local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
	if gold > 0 then return gold .. "g " .. silver .. "s" end
	if silver > 0 then return silver .. "s " .. copper % 100 .. "c" end
	return copper .. "c"
end

function draw.Shop()
	local profile = ns.Profile()
	local _, class = UnitClass("player")
	text(0, 0, 300, "Auction house upgrades", C.text, "LEFT", GameFontNormalLarge)
	text(INNER - 200, 3, 200, "prices stored by Auctionator", C.dim, "RIGHT")
	if not profile then
		return note(30, "wowsims has no stat weights for this class yet, so items cannot be rated.", C.dim, GameFontHighlight)
	elseif not ns.Auctionator() then
		local y = note(30, "Auctionator is not installed or not turned on.", C.text, GameFontHighlight)
		return note(y + 2, "This tab reads the prices Auctionator has stored. The other tabs work without it.", C.dim, GameFontHighlight)
	end
	local rows = ns.ShopList(ns.ReadGear("player") or {}, class, UnitLevel("player"), profile, shopByValue)
	if #rows == 0 then
		local y = note(30, "Auctionator knows no price for anything better than your gear.", C.text, GameFontHighlight)
		return note(y + 2, "Open the auction house, let Auctionator scan, then look again.", C.dim, GameFontHighlight)
	end
	text(0, 24, INNER, shopByValue and "Sorted by value for money. Click to sort by gain." or "Sorted by gain. Click to sort by value for money.", C.dim, "LEFT", GameFontDisableSmall)
	click(0, 20, INNER, 18, function()
		shopByValue = not shopByValue
		Refresh()
	end)
	local y = 48
	text(0, y, 70, "Slot", C.dim)
	text(74, y, 196, "Item", C.dim)
	text(274, y, 70, "Gain", C.dim, "RIGHT")
	text(350, y, 72, "Price", C.dim, "RIGHT")
	text(424, y, 84, "Net cost", C.dim, "RIGHT")
	rect(0, y + 16, INNER, 1, C.line)
	y = y + 20
	local shown, anyOld, anyUpTo = {}, false, false
	for i = 1, math.min(MAX_SHOP, #rows) do
		local row = rows[i]
		shown[i] = row
		anyOld, anyUpTo = anyOld or row.old, anyUpTo or row.upTo
		if i % 2 == 0 then rect(-6, y - 2, INNER + 12, 30, C.stripe) end
		text(0, y, 70, ns.SLOT_NAME[row.slot])
		text(74, y, 196, row.name)
		if row.upTo then text(74, y + 14, 196, "best as \"" .. row.suffix .. "\"", C.dim, "LEFT", GameFontDisableSmall) end
		text(274, y, 70, (row.upTo and "up to +" or "+") .. number(row.gain), C.ok, "RIGHT")
		text(350, y, 72, money(row.price) .. (row.old and " *" or ""), C.text, "RIGHT")
		local lost = not row.loss and "?" or row.loss == 0 and "free" or money(row.loss)
		text(424, y, 84, lost, not row.loss and C.dim or row.loss == 0 and C.ok or C.text, "RIGHT")
		y = y + 30
	end
	y = y + 6
	rect(0, y, 220, 24, C.line)
	text(0, y + 5, 220, "Search these in Auctionator", C.gold, "CENTER")
	click(0, y, 220, 24, function()
		shopNote = ns.ShopSearch(shown)
		Refresh()
	end)
	y = y + 34
	if shopNote then y = note(y, shopNote, C.text, GameFontHighlight) + 4 end
	local notes = { "Net cost: the price minus what a vendor pays you when you sell the item on. ? means not loaded yet." }
	if anyUpTo then notes[#notes + 1] = "up to: the gain with the suffix named under the item; other suffixes are worth less to you. The price is that of the cheapest suffix on sale, so pick the right one in Auctionator." end
	if anyOld then notes[#notes + 1] = "* the price is older than three days." end
	for _, line in ipairs(notes) do y = note(y, line) end
	return y
end

local tabs = {}
function ns.ShowTab(name)
	if name then shopNote = nil end
	tab = name or tab
	for key, button in pairs(tabs) do
		local on = key == tab
		button.label:SetTextColor(unpack(on and C.gold or C.dim))
		button.back:SetColorTexture(on and 0.09 or 0.07, on and 0.09 or 0.07, on and 0.11 or 0.09, 1)
	end
	Refresh()
end

for i, name in ipairs({ "Me", "Group", "Fight", "Shop" }) do
	local button = CreateFrame("Button", nil, main)
	button:SetSize(86, 24)
	button:SetPoint("TOPLEFT", main, "TOPLEFT", PAD + (i - 1) * 88, -(TOP - 24))
	fill(button, "BACKGROUND", C.line, 0)
	button.back = fill(button, "BORDER", { 0.07, 0.07, 0.09 }, 1)
	button.label = label(button, GameFontHighlight, name, C.dim, "CENTER", 0, 0)
	button:SetScript("OnClick", function() ns.ShowTab(name) end)
	tabs[name] = button
end

local function toggle()
	if main:IsShown() then
		main:Hide()
	else
		main:Show()
		ns.QueueInspects()
		ns.ShowTab()
	end
end
GearOrSkill_Toggle = toggle -- for the addon menu at the minimap (see the .toc)

function ns.OnGear()
	if main:IsShown() then Refresh() end
end

function ns.OnFight(fight)
	local profile = ns.Profile()
	local rows = ns.Compare(fight, profile)
	for i = 1, math.min(3, #rows) do
		local row = rows[i]
		print("|cff33ff99GoS|r " .. row.name .. ": " .. (row.gear and ("gear " .. percent(row.gear) .. ", ") or "") .. "damage " .. percent(row.damage))
	end
	if main:IsShown() then Refresh() end
end

SLASH_GEARORSKILL1 = "/gos"
SlashCmdList.GEARORSKILL = function(arg)
	local command, rest = (arg or ""):match("^(%S*)%s*(.*)$")
	if command == "probe" then
		ns.Probe(rest)
	else
		toggle()
	end
end
