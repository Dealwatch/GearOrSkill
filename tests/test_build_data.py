"""Checks the availability rule of tools/build_data.py. Run: python3 tests/test_build_data.py"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
from build_data import MAX_ITEM_LEVEL, nearly_same, obtainable_source  # noqa: E402

ZONES = {1: "Stratholme", 2: "Onyxia's Lair", 3: "Naxxramas"}
dungeon, onyxia, naxx, quest = {"drop": {"zoneId": 1}}, {"drop": {"zoneId": 2}}, {"drop": {"zoneId": 3}}, {"quest": {"name": "x"}}


def check(sources, ilvl=60, phase=1, today="2026-11-13", item_phase=1):
    return obtainable_source({"sources": sources, "phase": item_phase}, ilvl, ZONES, phase, today)


assert check([dungeon]) is dungeon, "dungeon drops are obtainable"
assert check([quest], ilvl=MAX_ITEM_LEVEL + 1) is None, "raid-tier quest rewards are hidden"
assert check([onyxia], ilvl=80) is None, "a raid is closed before its day"
assert check([onyxia], ilvl=80, today="2026-12-09") is onyxia, "and open from its day, whatever the item level"
assert check([naxx], today="2099-01-01") is None, "a raid without a date stays closed"
assert check([naxx, dungeon]) is dungeon, "the first obtainable source wins"
assert check([dungeon], item_phase=2) is None, "items of a later phase are hidden"
assert check([dungeon], item_phase=2, phase=2) is dungeon, "until the simulator reaches that phase"
assert check([]) is None, "no source, not obtainable"
line = '{ name = "BM", w = { [1] = %s, [17] = 3.8 }, rg = %s },'
assert nearly_same(line % ("2.95", "10.25"), line % ("3", "10.4"), 0.05), "one step or 2 % is the same data"
assert not nearly_same(line % ("2.95", "10.25"), line % ("3.1", "10.25"), 0.05), "three steps is new data"
assert not nearly_same(line % ("2.95", "10.25"), line.replace("[17] = 3.8", "[18] = 3.8") % ("2.95", "10.25"), 0.05), "another stat is new data"
assert not nearly_same(line % ("2.95", "10.25"), "", 0.05), "a different shape is new data"
print("build_data tests passed")
