#!/usr/bin/env python3
"""Builds Effects.lua: what the effect of a weapon is worth, where the simulator plays it.

Usage: python3 tools/measure_effects.py <path-to-wowsims-forever> <path-to-wowsimcli> [--all] [output-file]

Stats and weapon damage are rated by weights; a proc or use effect is not in them. For every
weight profile with a reference character, each weapon with an effect is simulated twice in
that character's hands: the real weapon, and a plain twin of the same kind, hands and speed
that is given the weapon's stats and damage as bonuses. The twin has everything but the
effect, so the difference in damage is the effect. A weapon without such a twin is left out.
Before a profile is measured, a few weapons without any effect go through the same
procedure; if they do not come out at zero, the profile is skipped. It is stored in points of gear score, using the damage one
point is worth for that profile (Calibration.lua, Measured.lua).

Where the simulator does not play an effect yet, the difference is zero; the addon then says
that the effect is not rated. Such weapons are measured again every Monday, so they get a
value by themselves once wowsims implements them.

Measuring is slow, so a run handles at most MAX_PER_RUN new weapons and keeps earlier results;
the daily job catches up over a few days. --all measures everything afresh.
Needs Data.lua, Calibration.lua and Measured.lua to be built first, and the Python package "lupa".
"""
import copy
import datetime
import json
import sys
from pathlib import Path

import lupa.lua51 as lupa  # the game runs Lua 5.1

from build_data import enum, lua_string, read_capabilities, read_profiles
from calibrate import pair, simulate
from measure_weights import MEASURED_CLASSES, parse, title

ITERATIONS = 5000
MAX_PER_RUN = 400  # weapon measurements per run, two simulations each
MIN_DPS = 1.0  # smaller differences are not an effect worth showing (an unplayed one measures about 0.1)
CONTROLS = 4  # effect-free weapons measured per profile first; they must come out below MIN_DPS
# An item's values the twin can be given; one with anything else (weapon skill, bonus against
# beasts) is no clean control.
PLAIN_FIELDS = {"ilvl", "randPropPoints", "stats", "weaponDamageMin", "weaponDamageMax", "unroundedDps"}
WEAPON, RANGED = 13, 14
MAIN_HAND_SLOT, OFF_HAND_SLOT, RANGED_SLOT = 14, 15, 16  # places in a simulator character's equipment
OFF_HAND_ONLY, TWO_HAND = 3, 4
MAIN_HAND_DPS, RANGED_DPS = 0, 2  # places in the simulator's weapon damage bonuses


def scaling(item):
    return next(iter(item["scalingOptions"].values()))


def references(sim, cli, stats, generated):
    """Yields (class, profile name, build, player, damage per point) for every profile that has
    a reference character and a known worth per point."""
    published = read_profiles(sim, stats)
    for cls, profiles in sorted(published.items()):
        for spec_dir in sorted({p["dir"] for p in profiles}):
            in_spec = [p for p in profiles if p["dir"] == spec_dir]
            for profile, path in pair(in_spec, sorted(spec_dir.glob("builds/*.build.json"))):
                calibration = generated.Calibration[cls] and generated.Calibration[cls][profile["name"]]
                build = json.loads(path.read_text())
                if calibration and "encounter" in build:
                    yield cls, profile["name"], build, build["player"], calibration.per, profile
    for cls in MEASURED_CLASSES:
        measured = generated.Measured[cls.upper()]
        if cls.upper() in published or not measured:
            continue
        by_name = {p.name: p for p in measured.values()}
        for spec_dir in sorted(p for p in (sim / "ui/specs" / cls).iterdir() if (p / "defaults.siml").exists()):
            defaults = parse(cli, spec_dir / "defaults.siml")
            for build_path in sorted(spec_dir.glob("builds/*.siml")):
                profile = by_name.get(title(build_path.stem))
                if profile:
                    player = {**defaults.get("player", {}), **parse(cli, build_path)["player"]}
                    yield cls.upper(), profile.name, defaults, player, profile.per, {"mh": profile.mh, "rg": profile.rg}


def candidates(items, cls, weapons, ranged, class_ids, profile, controls=False):
    """Weapons with an effect this class can use. Ranged ones only where ranged damage counts,
    melee ones not for profiles that only shoot.
    controls=True gives the opposite set instead: weapons with stats and nothing else, which
    must measure as having no effect."""
    for item in items:
        if item.get("randomSuffixOptions") or item.get("quality", 0) < 2:
            continue
        if controls:
            if item.get("itemEffects") or not scaling(item).get("stats") or not set(scaling(item)) <= PLAIN_FIELDS:
                continue
        elif not item.get("itemEffects"):
            continue
        if item.get("classAllowlist") and class_ids[cls] not in item["classAllowlist"]:
            continue
        if item.get("type") == WEAPON and item.get("handType") != OFF_HAND_ONLY:
            if profile.get("rg") and not profile.get("mh"):
                continue  # a ranged profile does not swing its melee weapon; a melee effect is worth nothing to it
            skill = weapons[cls].get(item.get("weaponType"))
            if skill and (item.get("handType") != TWO_HAND or skill == 2) and scaling(item).get("unroundedDps"):
                yield item
        elif item.get("type") == RANGED and profile.get("rg") and item.get("rangedWeaponType") in ranged[cls]:
            if scaling(item).get("unroundedDps"):
                yield item


def twin_of(item, plain):
    """A plain weapon to stand in for the item: same kind, same hands and exactly the same speed.
    None if there is none: kind and speed change the damage by themselves, so a twin that
    differs in either would pass that off as an effect."""
    kind = "rangedWeaponType" if item["type"] == RANGED else "weaponType"
    pool = [p for p in plain if p.get("type") == item["type"] and p.get(kind) == item.get(kind)
            and p.get("handType") == item.get("handType") and abs(p["weaponSpeed"] - item["weaponSpeed"]) < 0.01]
    if not pool:
        return None
    return min(pool, key=lambda p: (abs(scaling(p)["unroundedDps"] - scaling(item)["unroundedDps"]), p["id"]))


def effect_dps(cli, build, player, item, twin, sizes):
    """Damage per second the item's effect adds: the real item against its twin with equal stats."""
    slot, damage = (RANGED_SLOT, RANGED_DPS) if item["type"] == RANGED else (MAIN_HAND_SLOT, MAIN_HAND_DPS)
    real = copy.deepcopy(player)
    equipment = real["equipment"]["items"]
    equipment.extend({} for _ in range(RANGED_SLOT + 1 - len(equipment)))
    equipment[slot] = {"id": item["id"]}
    if item.get("handType") == TWO_HAND:
        equipment[OFF_HAND_SLOT] = {}
    emulated = copy.deepcopy(real)
    emulated["equipment"]["items"][slot] = {"id": twin["id"]}
    bonus = emulated.setdefault("bonusStats", {})
    stats = bonus.setdefault("stats", [])
    stats.extend([0] * (sizes["stats"] - len(stats)))
    for index, value in (scaling(item).get("stats") or {}).items():
        stats[int(index)] += value
    weapon = bonus.setdefault("pseudoStats", [])
    weapon.extend([0] * (sizes["pseudoStats"] - len(weapon)))
    weapon[damage] += scaling(item)["unroundedDps"] - scaling(twin)["unroundedDps"]
    return simulate(cli, build, real, ITERATIONS) - simulate(cli, build, emulated, ITERATIONS)


def main():
    arguments = [a for a in sys.argv[1:] if a != "--all"]
    afresh = "--all" in sys.argv
    sim, cli = Path(arguments[0]), Path(arguments[1]).resolve()
    root = Path(__file__).resolve().parent.parent
    target = Path(arguments[2]) if len(arguments) > 2 else root / "Effects.lua"

    proto = (sim / "proto/common.proto").read_text()
    stats = enum(proto, "Stat")
    sizes = {"stats": max(stats.values()) + 1, "pseudoStats": max(enum(proto, "PseudoStat").values()) + 1}
    class_ids = {name[len("Class"):].upper(): value for name, value in enum(proto, "Class").items()}
    _, weapons, ranged = read_capabilities(sim, proto)
    items = json.loads((sim / "assets/database/db.json").read_text())["items"] + \
        json.loads((sim / "assets/database/leftover_db.json").read_text())["items"]
    items = [i for i in items if i.get("scalingOptions")]
    plain = [i for i in items if i.get("type") in (WEAPON, RANGED) and not i.get("itemEffects")
             and not scaling(i).get("stats") and not i.get("randomSuffixOptions") and scaling(i).get("unroundedDps")]

    # What the other generated files and the last run of this one say.
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    generated = lua.eval("{}")
    load = lua.eval("function(path, ns) local chunk = loadfile(path); if chunk then chunk('GearOrSkill', ns) end end")
    for name in ("Calibration.lua", "Measured.lua") + (() if afresh else (str(target),)):
        load(str(root / name) if not Path(name).is_absolute() else name, generated)
    known = {}
    for cls, profiles in (generated.Effects or {}).items():
        for name, values in profiles.items():
            known[(cls, name)] = dict(values.items())
    # Monday: try again what the simulator did not play. Until re-measured, the old zero stays.
    recheck = datetime.date.today().weekday() == 0

    budget, pending, result = MAX_PER_RUN, 0, {}
    for cls, name, build, player, per_point, profile in references(sim, cli, stats, generated):
        values = result.setdefault((cls, name), dict(known.get((cls, name), {})))
        todo = [(item, twin_of(item, plain)) for item in sorted(candidates(items, cls, weapons, ranged, class_ids, profile), key=lambda i: i["id"])
                if item["id"] not in values or (recheck and values[item["id"]] == 0)]
        todo = [(item, twin) for item, twin in todo if twin]  # no twin: cannot be measured, stays unrated
        if not todo or budget <= 0:
            pending += len(todo)
            continue
        # The method must find nothing where there is nothing: check it on effect-free weapons of
        # this profile before trusting what it finds on the others.
        controls = [i for i in sorted(candidates(items, cls, weapons, ranged, class_ids, profile, controls=True), key=lambda i: i["id"])
                    if twin_of(i, plain)]
        controls = controls[::max(1, len(controls) // CONTROLS)][:CONTROLS]
        off = [(i["name"], gained) for i in controls
               for gained in [effect_dps(cli, build, player, i, twin_of(i, plain), sizes)] if abs(gained) >= MIN_DPS]
        if off or not controls:
            print("%s %s: control weapons without an effect measured %s, profile skipped" % (cls, name, off or "nothing"), file=sys.stderr)
            pending += len(todo)
            continue
        for item, twin in todo:
            if budget <= 0:
                pending += 1
                continue
            budget -= 1
            gained = effect_dps(cli, build, player, item, twin, sizes)
            values[item["id"]] = round(gained / per_point) if gained >= MIN_DPS else 0

    out = ["-- Generated by tools/measure_effects.py with the simulator of https://github.com/wowsims/forever. Do not edit.",
           "-- Worth of a weapon's effect in points of gear score, per weight profile. 0: measured, but the",
           "-- simulator does not play the effect (yet).",
           "local _, ns = ...", "ns.Effects = {"]
    for cls in sorted({key[0] for key in result}):
        out.append("\t%s = {" % cls)
        for (c, name), values in sorted(result.items()):
            if c == cls:
                out.append("\t\t[%s] = { %s }," % (lua_string(name), ", ".join("[%d] = %d" % kv for kv in sorted(values.items()))))
        out.append("\t},")
    out.append("}")
    body = "\n".join(out) + "\n"
    rated = sum(1 for values in result.values() for v in values.values() if v > 0)
    summary = "%d measured now, %d weapons with a rated effect, %d left for later runs" % (MAX_PER_RUN - budget, rated, pending)
    if target.exists() and target.read_text() == body:
        print("Effects.lua unchanged (%s)" % summary)
        return
    target.write_text(body)
    print("Effects.lua written (%s)" % summary)


if __name__ == "__main__":
    main()
