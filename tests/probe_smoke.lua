-- Smoke test for Probe.lua with a stubbed game API. Run from the repo root: lua tests/probe_smoke.lua

-- A stand-in for the client's secret values: any use other than issecretvalue() raises an error.
local function boom() error("secret value was used") end
local SECRET = setmetatable({}, {
	__concat = boom, __tostring = boom, __len = boom, __index = boom, __eq = boom, __lt = boom, __le = boom, __call = boom,
})

local onEvent, timers, printed = nil, {}, {}
local ME, OTHER = "Player-1-00000001", "Player-1-00000002"
local inCombat, inspectAnswers = false, true
local lockedReads = 0 -- how many more meter reads return locked values for other players

local function runTimers()
	while #timers > 0 do table.remove(timers, 1)() end
end

date = os.date
function print(msg) printed[#printed + 1] = msg end
function issecretvalue(v) return rawequal(v, SECRET) end
function GetBuildInfo() return "1.60.1", "70938", "Nov 12 2026", 16001 end
function GetInventoryItemLink(_, slot) if slot <= 4 then return "[Item" .. slot .. "]" end end
function UnitIsPlayer() return true end
function UnitName() return "Thrallix" end
function InCombatLockdown() return inCombat end
function IsInGroup() return true end
function CanInspect() return true end
function UnitGUID(unit) return unit == "player" and ME or OTHER end
function NotifyInspect() end
function CreateFrame()
	return { RegisterEvent = function() end, SetScript = function(_, _, fn) onEvent = fn end }
end
SlashCmdList = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_CVar = { GetCVarBool = function() return true end }
C_Item = { GetItemStats = function(link) if link ~= "[Item4]" then return { ITEM_MOD_STRENGTH_SHORT = 5 } end end }
C_SpecializationInfo = { GetInspectSpecialization = function() return 0 end }
C_Traits = { HasValidInspectData = function() return false end }
C_Spell = { GetSpellName = function() return "Stormstrike" end }
Enum = { DamageMeterType = { DamageDone = 0 }, DamageMeterSessionType = { Overall = 0, Current = 1 } }
C_DamageMeter = {
	IsDamageMeterAvailable = function() return true, "" end,
	GetCombatSessionFromType = function()
		local locked = lockedReads > 0
		lockedReads = lockedReads - 1
		return { totalAmount = 300, combatSources = {
			{ classFilename = "SHAMAN", isLocalPlayer = true, name = "Me", sourceGUID = ME, totalAmount = 200 },
			{ classFilename = "SHAMAN", isLocalPlayer = false, name = locked and SECRET or "Thrallix",
				sourceGUID = locked and SECRET or OTHER, totalAmount = locked and SECRET or 100 },
		} }
	end,
	GetCombatSessionSourceFromType = function()
		return { combatSpells = { { spellID = 17364, totalAmount = 120 } } }
	end,
}

dofile("Probe.lua")

local function output()
	return table.concat(printed, "\n")
end
local function has(text) assert(output():find(text, 1, true), "missing in chat: " .. text .. "\n" .. output()) end
local function hasNot(text) assert(not output():find(text, 1, true), "unexpected in chat: " .. text .. "\n" .. output()) end
local function scenario(name) printed = {}; timers = {}; io.write("-- " .. name .. "\n") end
local function done() for _, line in ipairs(printed) do io.write(line, "\n") end end

scenario("gear of player and target, everything readable")
SlashCmdList.GEARORSKILL("")
onEvent(nil, "INSPECT_READY", OTHER)
runTimers()
has("[OK]|r Your gear: 4 items, 3 with readable stats")
has("[OK]|r Target Thrallix: 4 items, 3 with readable stats")
has("Target talents: spec id 0, talent data no")
hasNot("no inspect answer")
done()

scenario("inspect never answers")
SlashCmdList.GEARORSKILL("")
runTimers()
has("[BLOCKED]|r Target: no inspect answer after 5 seconds")
done()

scenario("meter after a fight, everything readable")
onEvent(nil, "PLAYER_REGEN_ENABLED")
runTimers()
has("[OK]|r Meter, this fight: other players damage 1/1, spells 1/1")
done()

scenario("meter locked at first, readable on retry")
lockedReads = 2 -- both sessions of the first attempt
SlashCmdList.GEARORSKILL("meter")
assert(#printed == 0, "verdict must wait for the retry")
runTimers()
has("[OK]|r Meter, overall: other players damage 1/1, spells 1/1")
done()

scenario("meter stays locked for other players")
lockedReads = 100
SlashCmdList.GEARORSKILL("meter")
runTimers()
has("[BLOCKED]|r Meter, this fight: other players damage 0/1, spells 0/1")
lockedReads = 0
done()

scenario("meter asked during combat")
inCombat = true
SlashCmdList.GEARORSKILL("meter")
has("[INFO]|r Meter: in combat")
inCombat = false
done()

for _, line in ipairs(GearOrSkillProbeLog) do
	assert(not line:find("error", 1, true), "probe hit an error: " .. line)
end
assert(table.concat(GearOrSkillProbeLog, "\n"):find("spell 1: 17364 Stormstrike = 120", 1, true), "spell details missing in saved log")
io.write("probe smoke test passed\n")
