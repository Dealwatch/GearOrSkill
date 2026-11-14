# GearOrSkill

A World of Warcraft: Forever addon that answers one question: when another player of your class and spec does more damage than you, how much of the gap is gear and how much is how you play?

**Status:** early. The logic is covered by tests outside the game, but the addon has not been verified in the live client yet. See [Known limits](#known-limits).

## What it shows

Open the window with `/gos` or from the addon menu at the minimap.

- **Me**: what each stat point is worth for your spec, your gear score, and the best upgrades you can get at your level with where they come from. Upgrades marked "seen" are worn by a player you inspected, so they can be obtained.
- **Group**: after each fight, every group member of your class who uses the same spells as you, with their level, their gear difference, their damage difference, and the part gear does not explain. Players of another level are marked, since level alone changes damage.
- **Fight**: you against one of those players, spell by spell, as a share of total damage. The biggest gap is highlighted.

- **Shop**: upgrades the [Auctionator](https://www.curseforge.com/wow/addons/auctionator) addon has seen at the auction house, with their price and their net cost: the price minus what a vendor pays you when you sell the item on. One click hands the list to Auctionator, which searches it live. Auctionator is optional; without it only this tab stays empty.

The Group and Fight tabs need the game's built-in damage meter to be turned on.

## Install with WowUp

1. In WowUp, select your Forever installation.
2. Choose **Install from URL** and paste `https://github.com/Dealwatch/GearOrSkill`.

WowUp then updates the addon by itself whenever a new release appears. WowUp 2.24.0 or later is needed for Forever.

## Where the data comes from

Stat weights, item stats, item sources and class equipment rules are generated from the open-source simulator [wowsims/forever](https://github.com/wowsims/forever). A daily job rebuilds `Data.lua` from it and publishes a new release only when something changed, so the addon follows the simulator by about a day. New classes and specs appear by themselves once wowsims publishes weights for them.

Weapon effects (procs, use effects) are not in the weights. Where the simulator plays an effect, the daily job measures what it is worth (`Effects.lua`): the real weapon against a plain twin that is given the same stats and damage. Weapons whose effect the simulator does not play yet are marked with a star in the window and measured again every week, so they get a value once wowsims implements them. The first measurement of all weapons takes several daily runs.

The same job runs the simulator to calibrate the gear estimate (`Calibration.lua`): it takes armor off a reference character and measures how much damage is lost per point of gear score. Each calibration is checked against other gear combinations and dropped if it misses the simulator by more than two percentage points.

## Known limits

- Stat weights come from wowsims where it publishes them: currently Druid, Paladin, Priest, Rogue, Shaman and Warrior. For Hunters, where wowsims has a simulator but no published weights, the daily job measures them with that simulator; they are marked as measured in the window and give way by themselves once wowsims publishes its own. Mage and Warlock get the Fight tab only.
- Weights are measured for level 60. Below that they are a rough guide.
- Effects are rated for weapons only, and only for profiles with a reference character in the simulator (currently Shaman, damage Priest and Hunter) and for effects the simulator plays, which today is mostly high-level weapons. Everything else with an effect carries a star: its gain covers stats and weapon damage only. Set bonuses are not rated.
- The gear difference is an estimate, not a simulation of both players. It is calibrated with the simulator at level 60 where wowsims ships a reference character (currently Shaman and damage Priest); elsewhere it is a rougher estimate from the character sheet. It ignores talents, buffs, set bonuses and item effects, and the calibration assumes a raid-buffed character.
- Upgrade suggestions leave out trinkets and off-hand items. They hide items the game client does not have, items of a later simulator phase, drops from raids that are not open yet (opening dates are in `tools/build_data.py`) and other items above item level 66. Some rewards that cannot be obtained yet may still appear.
- What a character can use is taken from the game's own tooltip: an item it prints in red (weapon or armor type not learned, level, class) is not suggested. Mail and plate are also held back until level 40 unless the client reports the armor skill as known.
- The Shop tab shows Auctionator's stored prices, which are as old as its last scan. An item with a random suffix is listed as its best variant for your profile ("Claymore of Agility"), but Auctionator stores one price per item for all suffixes, so its price is shown as "from" the cheapest variant; the search in Auctionator is exact and shows that variant at its real price. Soulbound items never appear, since they are never on sale.
- Players are matched by the spells they use, because the game does not tell addons another player's spec.
- Spell data is read after combat ends; the game locks it during a fight.

## Checking what the game allows

`/gos probe` checks whether the client lets addons read gear (yours and your target's), `/gos probe meter` checks the damage meter after a fight, `/gos probe auctionator` checks what the Auctionator addon offers, and `/gos probe tooltip <item id>` prints what the game's tooltip data says about one item. Each prints one line per question, marked `[OK]`, `[PARTIAL]`, `[BLOCKED]` or `[INFO]`. Details are saved to `WTF/Account/<account>/SavedVariables/GearOrSkill.lua` on logout or `/reload`.

## Development

Tests run outside the game against a small stand-in for the client (Lua 5.1):

```bash
lua5.1 tests/run.lua
```

```bash
python3 tests/test_build_data.py
```

Rebuild the data from a wowsims checkout:

```bash
python3 tools/build_data.py /path/to/wowsims-forever
```

Recalibrate with a built simulator (`make bin/wowsimcli` in the wowsims checkout; needs `lupa`):

```bash
python3 tools/calibrate.py /path/to/wowsims-forever /path/to/wowsims-forever/bin/wowsimcli
```

Measure weights for classes without published ones (a few minutes):

```bash
python3 tools/measure_weights.py /path/to/wowsims-forever /path/to/wowsims-forever/bin/wowsimcli
```

Measure weapon effects (keeps earlier results and handles 400 weapons per run; `--all` starts afresh):

```bash
python3 tools/measure_effects.py /path/to/wowsims-forever /path/to/wowsims-forever/bin/wowsimcli
```

Render the window to HTML pages for a visual check (needs the Python package `lupa`):

```bash
python3 tools/render_ui.py /tmp/gearorskill-ui
```

Releases: raise `## Version` in `GearOrSkill.toc` and push to `main`. The workflow tests, packages and publishes any version that has no release yet.

## Credits

All game data in this addon comes from [wowsims/forever](https://github.com/wowsims/forever) (MIT license).
