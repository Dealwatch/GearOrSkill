-- A small stand-in for the game client, enough to load the addon outside the game.
-- It lays out frames like the client does, so tests can check and render the real UI code.
-- Unknown widget methods raise an error on purpose: a typo must not pass silently.
local Stub = { timers = {}, printed = {}, frames = {}, now = 1000 }

local function boom() error("secret value was used", 2) end
Stub.SECRET = setmetatable({}, {
	__concat = boom, __tostring = boom, __len = boom, __index = boom, __eq = boom, __lt = boom, __le = boom, __call = boom,
})

local ANCHOR = {
	TOPLEFT = { 0, 0 }, TOP = { 0.5, 0 }, TOPRIGHT = { 1, 0 }, LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 },
	RIGHT = { 1, 0.5 }, BOTTOMLEFT = { 0, 1 }, BOTTOM = { 0.5, 1 }, BOTTOMRIGHT = { 1, 1 },
}
local FONT_SIZE = { GameFontNormalLarge = 16, GameFontHighlightLarge = 16, GameFontHighlight = 12, GameFontNormal = 12, GameFontDisableSmall = 10 }
for name, size in pairs(FONT_SIZE) do _G[name] = { fontName = name, size = size } end

local Region = {}
Region.__index = function(_, key)
	local method = Region[key]
	if method == nil and type(key) == "string" and key:match("^%u") then
		error("widget method not in the stub: " .. key, 2)
	end
	return method
end

local function newRegion(kind, parent, layer)
	Stub.created = (Stub.created or 0) + 1
	local r = setmetatable({ kind = kind, parent = parent, layer = layer, sub = 0, seq = Stub.created, points = {}, shown = true, scripts = {}, children = {} }, Region)
	if parent then parent.children[#parent.children + 1] = r end
	return r
end

function Region:SetSize(w, h) rawset(self, "w", w); rawset(self, "h", h) end
function Region:SetWidth(w) rawset(self, "w", w) end
function Region:SetHeight(h) rawset(self, "h", h) end
function Region:ClearAllPoints() rawset(self, "points", {}) end
function Region:SetPoint(point, a, b, c, d)
	local rel, relPoint, x, y = self.parent, point, 0, 0
	if type(a) == "table" then rel, relPoint, x, y = a, b or point, c or 0, d or 0 elseif type(a) == "number" then x, y = a, b or 0 end
	assert(ANCHOR[point] and ANCHOR[relPoint], "bad anchor point")
	self.points[#self.points + 1] = { point, rel, relPoint, x, y }
end
function Region:Show() rawset(self, "shown", true) end
function Region:Hide() rawset(self, "shown", false) end
function Region:IsShown() return self.shown end
function Region:SetScript(name, fn) self.scripts[name] = fn end
function Region:GetScript(name) return self.scripts[name] end
function Region:RegisterEvent(event) Stub.frames[#Stub.frames + 1] = { self, event } end
function Region:CreateTexture(_, layer) return newRegion("texture", self, layer or "ARTWORK") end
function Region:CreateFontString(_, layer) return newRegion("text", self, layer or "OVERLAY") end
function Region:SetDrawLayer(layer, sub) rawset(self, "layer", layer); rawset(self, "sub", sub or 0) end
function Region:SetColorTexture(r, g, b, a) rawset(self, "color", { r, g, b, a or 1 }) end
function Region:SetFontObject(font) assert(type(font) == "table" and font.size, "unknown font object"); rawset(self, "font", font) end
function Region:SetText(text) assert(type(text) == "string", "SetText needs a string"); rawset(self, "text", text) end
function Region:SetTextColor(r, g, b) assert(r and g and b, "SetTextColor needs r, g, b"); rawset(self, "color", { r, g, b, 1 }) end
function Region:SetJustifyH(j) rawset(self, "justify", j) end
function Region:SetWordWrap(wrap) rawset(self, "wrap", wrap) end
for _, name in ipairs({ "SetFrameStrata", "EnableMouse", "SetMovable", "SetClampedToScreen", "RegisterForDrag", "StartMoving", "StopMovingOrSizing" }) do
	Region[name] = function() end
end

UIParent = newRegion("frame")
UIParent:SetSize(1024, 768)
UISpecialFrames = {}
function CreateFrame(kind, name, parent)
	local f = newRegion(kind == "Button" and "button" or "frame", parent)
	if name then _G[name] = f end
	return f
end

-- Layout: absolute rectangle of a region in pixels, y pointing down.
local function rectOf(r)
	if r == UIParent then return 0, 0, r.w, r.h end
	local p = r.points
	assert(#p > 0, "region without anchor")
	local function at(point)
		local rx, ry, rw, rh = rectOf(point[2])
		local f = ANCHOR[point[3]]
		return rx + f[1] * rw + point[4], ry + f[2] * rh - point[5]
	end
	local w, h = r.w, r.h
	if r.kind == "text" then h = h or (r.font.size + 2) end
	if #p >= 2 then
		local x1, y1 = at(p[1])
		local x2, y2 = at(p[2])
		return math.min(x1, x2), math.min(y1, y2), math.abs(x2 - x1), math.abs(y2 - y1)
	end
	local ax, ay = at(p[1])
	local f = ANCHOR[p[1][1]]
	return ax - f[1] * (w or 0), ay - f[2] * (h or 0), w, h
end

-- Everything visible under a frame, back to front, with absolute coordinates.
function Stub.Dump(root)
	local order = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4 }
	local out = {}
	local function walk(r)
		if not r.shown then return end
		local own = {}
		for _, child in ipairs(r.children) do
			if child.kind == "texture" or child.kind == "text" then own[#own + 1] = child end
		end
		table.sort(own, function(a, b)
			if a.layer ~= b.layer then return order[a.layer] < order[b.layer] end
			if a.sub ~= b.sub then return a.sub < b.sub end
			return a.seq < b.seq
		end)
		for _, region in ipairs(own) do
			if region.shown then
				local x, y, w, h = rectOf(region)
				out[#out + 1] = {
					kind = region.kind, x = x, y = y, w = w, h = h, text = region.text, color = region.color,
					size = region.font and region.font.size, justify = region.justify, anchor = region.points[1][1],
				}
			end
		end
		for _, child in ipairs(r.children) do
			if child.kind == "frame" or child.kind == "button" then walk(child) end
		end
	end
	walk(root)
	local x, y, w, h = rectOf(root)
	return out, x, y, w, h
end

-- Shown buttons under a frame, for clicking in tests.
function Stub.Buttons(root)
	local out = {}
	local function walk(r)
		if not r.shown then return end
		if r.kind == "button" and r.scripts.OnClick then out[#out + 1] = r end
		for _, child in ipairs(r.children) do walk(child) end
	end
	walk(root)
	return out
end

function Stub.Fire(event, ...)
	for _, entry in ipairs(Stub.frames) do
		if entry[2] == event and entry[1].scripts.OnEvent then entry[1].scripts.OnEvent(entry[1], event, ...) end
	end
end

function Stub.RunTimers()
	while #Stub.timers > 0 do table.remove(Stub.timers, 1)() end
end

-- Game state the tests change.
Stub.state = {
	class = "SHAMAN", className = "Shaman", level = 60, inCombat = false, inGroup = true,
	gear = {}, -- unit -> { slot -> link }
	units = {}, -- unit -> { guid, name, class }
	sources = {}, -- meter sources of the current fight
	spells = {}, -- guid -> { { spellID, totalAmount }, ... }
	lockedReads = 0, -- how many more meter reads return locked values for other players
	duration = 102,
	sheet = { 240, 130, 260, 170, 120 }, -- character sheet: strength, agility, stamina, intellect, spirit
	missingItems = {}, -- item ids this client does not have
	knownSpells = {},
}
local S = Stub.state

date = os.date
tinsert = table.insert
function strsplit(sep, text)
	local fields = {}
	for field in (text .. sep):gmatch("(.-)%" .. sep) do fields[#fields + 1] = field end
	return unpack(fields)
end
unpack = unpack or table.unpack
function print(msg) Stub.printed[#Stub.printed + 1] = msg end
function issecretvalue(v) return rawequal(v, Stub.SECRET) end
function GetBuildInfo() return "1.60.1", "70938", "Nov 12 2026", 16001 end
function GetTime() return Stub.now end
function InCombatLockdown() return S.inCombat end
function IsInGroup() return S.inGroup end
function IsInRaid() return false end
function GetNumGroupMembers() local n = 1 for unit in pairs(S.units) do if unit:find("^party") then n = n + 1 end end return n end
function UnitExists(unit) return S.units[unit] ~= nil end
function UnitIsUnit(a, b) return a == b end
function UnitIsPlayer(unit) return S.units[unit] ~= nil end
function UnitGUID(unit) return S.units[unit] and S.units[unit].guid end
function UnitName(unit) return S.units[unit] and S.units[unit].name end
function UnitClass(unit) local u = S.units[unit] if u then return u.className or u.class, u.class end end
function UnitLevel(unit) return S.units[unit] and S.units[unit].level or S.level end
function UnitStat(_, index) local value = S.sheet[index] or 0 return value, value, 0, 0 end
function CanInspect(unit) return S.units[unit] ~= nil end
function NotifyInspect(unit) Stub.inspected = unit end
function GetInventoryItemLink(unit, slot) return S.gear[unit] and S.gear[unit][slot] end
RAID_CLASS_COLORS = { SHAMAN = { r = 0, g = 0.44, b = 0.87 }, ROGUE = { r = 1, g = 0.96, b = 0.41 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
SlashCmdList = {}
C_Timer = { After = function(_, fn) Stub.timers[#Stub.timers + 1] = fn end }
C_CVar = { GetCVarBool = function() return true end }
C_Item = {
	GetItemStats = function(link) if not link:find("Shirt") then return { ITEM_MOD_STRENGTH_SHORT = 5 } end end,
	DoesItemExistByID = function(id) return not S.missingItems[id] end,
	GetItemInfo = function(id) return nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, S.sellPrice and S.sellPrice(id) end,
}
function IsSpellKnown(id) return S.knownSpells[id] == true end
C_SpecializationInfo = { GetInspectSpecialization = function() return 0 end }
C_Traits = { HasValidInspectData = function() return false end }
C_Spell = { GetSpellName = function(id) return S.spellNames and S.spellNames[id] or ("Spell " .. id) end }
Enum = { DamageMeterType = { DamageDone = 0 }, DamageMeterSessionType = { Overall = 0, Current = 1 } }
C_DamageMeter = {
	IsDamageMeterAvailable = function() return true, "" end,
	GetCombatSessionFromType = function()
		local locked = S.lockedReads > 0
		S.lockedReads = S.lockedReads - 1
		local sources = {}
		for i, src in ipairs(S.sources) do
			local hide = locked and not src.isLocalPlayer
			sources[i] = {
				classFilename = src.classFilename, isLocalPlayer = src.isLocalPlayer, name = hide and Stub.SECRET or src.name,
				sourceGUID = hide and Stub.SECRET or src.sourceGUID, totalAmount = hide and Stub.SECRET or src.totalAmount,
			}
		end
		return { totalAmount = 0, durationSeconds = S.duration, combatSources = sources }
	end,
	GetCombatSessionSourceFromType = function(_, _, guid)
		local spells = {}
		for i, spell in ipairs(S.spells[guid] or {}) do spells[i] = { spellID = spell[1], totalAmount = spell[2] } end
		return { combatSpells = spells }
	end,
}

-- Loads the addon files in .toc order, each with the shared addon table like the client does.
function Stub.Load(files)
	local ns = {}
	for _, file in ipairs(files) do
		local chunk = assert(loadfile(file))
		chunk("GearOrSkill", ns)
	end
	return ns
end

return Stub
