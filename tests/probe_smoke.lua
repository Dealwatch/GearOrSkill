-- Smoke test for Probe.lua with a stubbed game API. Run from the repo root: lua tests/probe_smoke.lua
local SECRET = {}
local onEvent, timers = nil, {}

date = os.date
function issecretvalue(v) return v == SECRET end
function GetInventoryItemLink(_, slot) if slot <= 2 then return "[Item" .. slot .. "]" end end
function UnitIsPlayer() return true end
function InCombatLockdown() return false end
function CanInspect() return true end
function UnitGUID() return "Player-1-00000002" end
function NotifyInspect() end
function CreateFrame()
	return { RegisterEvent = function() end, SetScript = function(_, _, fn) onEvent = fn end }
end
SlashCmdList = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_Item = { GetItemStats = function() return { ITEM_MOD_STRENGTH_SHORT = 5 } end }
C_SpecializationInfo = { GetInspectSpecialization = function() return 0 end }
C_Traits = { HasValidInspectData = function() return false end }
C_Spell = { GetSpellName = function() return "Stormstrike" end }
Enum = { DamageMeterType = { DamageDone = 0 }, DamageMeterSessionType = { Overall = 0, Current = 1 } }
C_DamageMeter = {
	IsDamageMeterAvailable = function() return true, "" end,
	GetCombatSessionFromType = function()
		return { totalAmount = 300, combatSources = {
			{ classFilename = "SHAMAN", isLocalPlayer = true, name = "Me", sourceGUID = "Player-1-00000001", totalAmount = 200 },
			{ classFilename = "SHAMAN", isLocalPlayer = false, name = SECRET, sourceGUID = SECRET, totalAmount = 100 },
		} }
	end,
	GetCombatSessionSourceFromType = function()
		return { combatSpells = { { spellID = 17364, totalAmount = 120 } } }
	end,
}

dofile("Probe.lua")
SlashCmdList.GEARORSKILL("")
onEvent(nil, "INSPECT_READY", "Player-1-00000002")
onEvent(nil, "PLAYER_REGEN_ENABLED")
timers[1]()

local out = table.concat(GearOrSkillProbeLog, "\n")
local function has(text) assert(out:find(text, 1, true), "missing in log: " .. text) end
has("player gear: 2 item links, 2 with readable stats")
has("target gear: 2 item links, 2 with readable stats")
has("inspect talent data valid: false")
has("Current #1 spell 1: id=17364 (Stormstrike) amount=120")
has("name=<secret> guid=<secret>")
assert(not out:find("ERROR", 1, true), "probe logged an error:\n" .. out)
print("probe smoke test passed")
