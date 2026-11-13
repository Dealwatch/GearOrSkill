# GearOrSkill

A World of Warcraft: Forever addon that answers one question: when another player of your class and spec does more damage than you, how much of the gap is gear and how much is how you play?

**Status:** early. The repository currently holds only an API probe that checks what the Forever client lets addons read.

## Running the probe

1. Download this repository as a ZIP and unpack it into the `Interface/AddOns` folder of your Forever installation.
2. Rename the unpacked folder to `GearOrSkill`.
3. Enable the built-in damage meter: Esc > Options > Advanced Options > Damage Meter.
4. In game, join a group, target another player and type `/gos`.
5. Fight something together. In a group the damage meter probe runs by itself a few seconds after each of the first three fights. `/gos meter` runs it by hand.

Chat shows one line per question, marked `[OK]`, `[PARTIAL]`, `[BLOCKED]` or `[INFO]`. The details behind each line are saved to `WTF/Account/<account>/SavedVariables/GearOrSkill.lua` when you log out or reload the UI. `/gos clear` empties that log.

## Development

Run the smoke test from the repository root:

```bash
lua tests/probe_smoke.lua
```
