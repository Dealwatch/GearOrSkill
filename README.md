# GearOrSkill

A World of Warcraft: Forever addon that answers one question: when another player of your class and spec does more damage than you, how much of the gap is gear and how much is how you play?

**Status:** early. The logic is covered by tests outside the game, but the addon has not been verified in the live client yet. See [Known limits](#known-limits).

## What it shows

Open the window with `/gos` or from the addon menu at the minimap.

- **Me**: what each stat point is worth for your spec, your gear score, and the best upgrades you can get at your level with where they come from.
- **Group**: after each fight, every group member of your class who uses the same spells as you, with their gear difference, their damage difference, and the part gear does not explain.
- **Fight**: you against one of those players, spell by spell, as a share of total damage. The biggest gap is highlighted.

The Group and Fight tabs need the game's built-in damage meter to be turned on.

## Install with WowUp

1. In WowUp, select your Forever installation.
2. Choose **Install from URL** and paste `https://github.com/Dealwatch/GearOrSkill`.

WowUp then updates the addon by itself whenever a new release appears. WowUp 2.24.0 or later is needed for Forever.

## Where the data comes from

Stat weights, item stats, item sources and class equipment rules are generated from the open-source simulator [wowsims/forever](https://github.com/wowsims/forever). A daily job rebuilds `Data.lua` from it and publishes a new release only when something changed, so the addon follows the simulator by about a day.

## Known limits

- Stat weights exist only where wowsims publishes them: currently Druid, Paladin, Priest, Rogue, Shaman and Warrior. Other classes get the Fight tab only.
- Weights are measured for level 60. Below that they are a rough guide.
- The gear difference is an estimate from stat weights, not a simulation. It ignores talents, buffs, set bonuses and item effects.
- Upgrade suggestions leave out trinkets and off-hand items, and hide items above item level 66 and drops from raids that are not open. Some rewards that cannot be obtained yet may still appear.
- Players are matched by the spells they use, because the game does not tell addons another player's spec.
- Spell data is read after combat ends; the game locks it during a fight.

## Checking what the game allows

`/gos probe` checks whether the client lets addons read gear (yours and your target's), and `/gos probe meter` checks the damage meter after a fight. Each prints one line per question, marked `[OK]`, `[PARTIAL]`, `[BLOCKED]` or `[INFO]`. Details are saved to `WTF/Account/<account>/SavedVariables/GearOrSkill.lua` on logout or `/reload`.

## Development

Tests run outside the game against a small stand-in for the client (Lua 5.1):

```bash
lua5.1 tests/run.lua
```

Rebuild the data from a wowsims checkout:

```bash
python3 tools/build_data.py /path/to/wowsims-forever
```

Render the window to HTML pages for a visual check (needs the Python package `lupa`):

```bash
python3 tools/render_ui.py /tmp/gearorskill-ui
```

Releases: raise `## Version` in `GearOrSkill.toc` and push to `main`. The workflow tests, packages and publishes any version that has no release yet.

## Credits

All game data in this addon comes from [wowsims/forever](https://github.com/wowsims/forever) (MIT license).
