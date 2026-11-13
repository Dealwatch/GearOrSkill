#!/usr/bin/env python3
"""Builds Calibration.lua: how much a whole reference character is worth per weight profile.

Usage: python3 tools/calibrate.py <path-to-wowsims-forever> <path-to-wowsimcli> [output-file]

For every weight profile whose spec ships a reference character (builds/*.build.json), the
simulator runs it as it is and again with some armor taken off. The damage lost per point of
gear score lost tells how much damage one point of gear score brings, so the character's
whole damage can be expressed in the unit of the addon's gear score. The addon uses that
total, minus the score of the reference gear, as the part of a character that is not gear.

Gear is scored by the addon's own code (Core.lua), so the calibration always fits what the
addon computes in game. Needs Data.lua to be built first and the Python package "lupa".

The file is rewritten only when its content changes.
"""
import copy
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import lupa.lua51 as lupa  # the game runs Lua 5.1

from build_data import enum, lua_string, read_profiles

ITERATIONS = 10000
SEED = 1  # fixed, so the same simulator and inputs give the same file
# Armor taken off for the extra runs, as inventory slots: two separate halves, no weapons or
# trinkets, whose worth is not in their stats.
REMOVED = [[1, 5, 7, 10], [15, 9, 6, 8]]
# Other combinations, used only to check the result: the addon's estimate for each must land
# within TOLERANCE percentage points of the simulator, or the profile is left uncalibrated.
HELD_OUT = [[5], [11, 12], [2, 3], [5, 9, 8, 11]]
TOLERANCE = 2.0
# The simulator changes a little every day. Rounding keeps those ripples from causing a
# release each time, at an error far below what the estimate can resolve anyway.
ROUND_TO = 100
# Order of equipment in a simulator character -> the game's inventory slot numbers.
SLOTS = [1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18]


def simulate(cli, build, player, iterations=ITERATIONS):
    request = {
        "raid": {
            "parties": [{"players": [player], "buffs": build.get("partyBuffs", {})}],
            "buffs": build.get("raidBuffs", {}),
            "debuffs": build.get("debuffs", {}),
        },
        "encounter": build["encounter"],
        "simOptions": {"iterations": iterations, "randomSeed": SEED},
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump(request, f)
        f.flush()
        result = subprocess.run([str(cli), "sim", "--infile", f.name], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)["raidMetrics"]["dps"]["avg"]


def pair(profiles, builds):
    """Matches weight presets to reference characters of one spec by name, then one-to-one."""
    def key(text):
        return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")

    pairs, left_profiles, left_builds = [], list(profiles), list(builds)
    for profile in profiles:
        match = [b for b in left_builds if key(profile["preset"]) in key(b.name.split(".")[0])]
        if len(match) == 1:
            pairs.append((profile, match[0]))
            left_profiles.remove(profile)
            left_builds.remove(match[0])
    if len(left_profiles) == 1 and len(left_builds) == 1:
        pairs.append((left_profiles[0], left_builds[0]))
    return pairs


def calibrate(cli, score, profile, path):
    """Returns (total value, reference links by slot), or None when the build cannot be used."""
    build = json.loads(path.read_text())
    player = build.get("player", {})
    items = player.get("equipment", {}).get("items")
    if not items or "encounter" not in build or player.get("rotation", {}).get("type") != "TypeAPL":
        return None
    links = {
        SLOTS[i]: "item:%d:%d:0:0:0:0:%d" % (item["id"], item.get("enchant", 0), item.get("randomSuffix", 0))
        for i, item in enumerate(items) if item.get("id")
    }
    dps, value = simulate(cli, build, player), score(links)

    def without(group):
        """Damage and gear score with those slots emptied."""
        stripped, kept = copy.deepcopy(player), dict(links)
        for slot in group:
            stripped["equipment"]["items"][SLOTS.index(slot)] = {}
            kept.pop(slot, None)
        return simulate(cli, build, stripped), score(kept)

    lost_dps = lost_value = 0
    for group in REMOVED:
        group_dps, group_value = without(group)
        lost_dps += dps - group_dps
        lost_value += value - group_value
    if dps <= 0 or lost_dps <= 0 or lost_value <= 0:
        return None  # a healer, or a build the simulator does not play
    total = round(dps * lost_value / lost_dps / ROUND_TO) * ROUND_TO
    base = total - value
    for group in HELD_OUT:
        group_dps, group_value = without(group)
        simulated, estimated = 100 * (group_dps / dps - 1), 100 * ((base + group_value) / total - 1)
        if abs(simulated - estimated) > TOLERANCE:
            print("%s: estimate %.1f%% vs simulator %.1f%% without slots %s, left uncalibrated"
                  % (profile["name"], estimated, simulated, group), file=sys.stderr)
            return None
    return total, links


def addon_scorer():
    """The addon's own gear scoring, loaded outside the game."""
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.execute('local Stub = dofile("tests/wowstub.lua"); return Stub.Load({ "Data.lua", "Core.lua" })')
    gear_score = lua.eval("function(ns, links, profile) return (ns.GearScore(links, profile)) end")

    def scorer(cls, name):
        profile = next(p for p in ns.Data.profiles[cls].values() if p.name == name)
        return lambda links: gear_score(ns, lua.table_from(links), profile)

    return scorer


def main():
    sim, cli = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
    target = Path(sys.argv[3]) if len(sys.argv) > 3 else Path(__file__).resolve().parent.parent / "Calibration.lua"
    stats = enum((sim / "proto/common.proto").read_text(), "Stat")
    scorer = addon_scorer()
    out = ["-- Generated by tools/calibrate.py with the simulator of https://github.com/wowsims/forever. Do not edit.",
           "local _, ns = ...", "ns.Calibration = {"]
    done = []
    for cls, profiles in sorted(read_profiles(sim, stats).items()):
        lines = []
        for spec_dir in sorted({p["dir"] for p in profiles}):
            in_spec = [p for p in profiles if p["dir"] == spec_dir]
            for profile, path in pair(in_spec, sorted(spec_dir.glob("builds/*.build.json"))):
                result = calibrate(cli, scorer(cls, profile["name"]), profile, path)
                if result:
                    total, links = result
                    ref = ", ".join('[%d] = "%s"' % kv for kv in sorted(links.items()))
                    lines.append("\t\t[%s] = { total = %d, ref = { %s } }," % (lua_string(profile["name"]), total, ref))
                    done.append("%s %s = %d" % (cls, profile["name"], total))
        if lines:
            out += ["\t%s = {" % cls] + lines + ["\t},"]
    out.append("}")
    body = "\n".join(out) + "\n"
    assert done, "no profile could be calibrated"
    if target.exists() and target.read_text() == body:
        print("Calibration.lua unchanged (%s)" % "; ".join(done))
        return
    target.write_text(body)
    print("Calibration.lua written (%s)" % "; ".join(done))


if __name__ == "__main__":
    main()
