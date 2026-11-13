#!/usr/bin/env python3
"""Builds Data.lua from a checkout of https://github.com/wowsims/forever.

Usage: python3 tools/build_data.py <path-to-wowsims-forever> [output-file]

The file is rewritten only when its content changes, so its "built" date
marks the last real data change.
"""
import datetime
import json
import re
import sys
from pathlib import Path

# What counts as obtainable, on top of the simulator's own phase per item:
# - a raid drop, once its raid is open (RAID_OPENS);
# - anything else up to MAX_ITEM_LEVEL, which keeps raid-tier quest, vendor and PvP
#   rewards out while their raids are closed.
# ponytail: the database marks every item as phase 1, so these two tables carry the
# schedule by hand. Drop them once wowsims tags phases for real.
MAX_ITEM_LEVEL = 66

# Raids by zone name as the database spells it -> day their drops can be obtained.
# None: no date announced, stays hidden. The daily build opens a raid on its day.
# Dates: https://www.icy-veins.com/wow-forever/roadmap
RAID_OPENS = {
    "Onyxia's Lair": "2026-12-09", "Barrow Deeps": "2026-12-09", "Hyjal Summit": "2026-12-09",
    "Molten Core": None, "Blackwing Lair": None, "Zul'Gurub": None, "Ruins of Ahn'Qiraj": None,
    "Ahn'Qiraj": None, "Naxxramas": None,
}
# ponytail: many quest rewards carry no required level. Assume they are for characters about
# five levels below their item level, which keeps endgame rewards away from low levels.
ITEM_LEVEL_LEAD = 5

GENERIC_SPEC_DIRS = {"dps", "healer", "shared"}
PSEUDO_KEYS = {"PseudoStatMainHandDps": "mh", "PseudoStatOffHandDps": "oh", "PseudoStatRangedDps": "rg"}
TRINKET = 12


def enum(proto, name):
    body = re.search(r"enum %s \{(.*?)\n\}" % name, proto, re.S).group(1)
    return {key: int(value) for key, value in re.findall(r"^\s*(\w+) = (\d+);", body, re.M)}


def words(camel):
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", camel)


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def sparse(values):
    """{stat index: value} as "index:value,..."; "-" when empty."""
    pairs = sorted((int(k), v) for k, v in values.items() if v)
    return ",".join("%d:%s" % (k, ("%g" % v)) for k, v in pairs) or "-"


def read_profiles(sim, stats):
    """EP weight presets per class: {"SHAMAN": [{"name", "w", "mh", ...}]}"""
    profiles = {}
    for path in sorted(sim.glob("ui/specs/*/*/presets.ts")):
        class_dir, spec_dir = path.parts[-3], path.parts[-2]
        text = path.read_text()
        for name, stat_block, pseudo_block in re.findall(
            r"makePresetEpWeights\(\s*'([^']+)',\s*Stats\.fromMap\(\s*\{([^}]*)\}(?:,\s*\{([^}]*)\})?", text
        ):
            weights = {stats[k]: float(v) for k, v in re.findall(r"\[Stat\.(\w+)\]:\s*(-?[\d.]+)", stat_block)}
            if not weights:
                continue
            label = name if spec_dir in GENERIC_SPEC_DIRS else "%s: %s" % (spec_dir.capitalize(), name)
            profile = {"name": label, "w": weights, "dir": path.parent, "preset": name}
            for key, value in re.findall(r"\[PseudoStat\.(\w+)\]:\s*(-?[\d.]+)", pseudo_block):
                if key in PSEUDO_KEYS:
                    profile[PSEUDO_KEYS[key]] = float(value)
            profiles.setdefault(class_dir.upper(), []).append(profile)
    return profiles


def read_capabilities(sim, proto):
    text = (sim / "ui/sim/player/classes/capabilities_auto_gen.ts").read_text()
    armor_ids, weapon_ids, ranged_ids = enum(proto, "ArmorType"), enum(proto, "WeaponType"), enum(proto, "RangedWeaponType")

    def block(name):
        return re.search(r"export const %s[^=]*= \{(.*?)\n\};" % name, text, re.S).group(1)

    def rows(name):
        return re.findall(r"\[Class\.Class(\w+)\]: \[(.*)\],", block(name))

    armor = {c.upper(): max(armor_ids[a] for a in re.findall(r"ArmorType\.(\w+)", row)) for c, row in rows("CLASS_ARMOR_TYPES")}
    weapons = {
        c.upper(): {weapon_ids[w]: (2 if two == "true" else 1) for w, two in re.findall(r"WeaponType\.(\w+), canUseTwoHand: (\w+)", row)}
        for c, row in rows("CLASS_WEAPON_TYPES")
    }
    ranged = {c.upper(): sorted(ranged_ids[r] for r in re.findall(r"RangedWeaponType\.(\w+)", row)) for c, row in rows("CLASS_RANGED_WEAPON_TYPES")}
    return armor, weapons, ranged


def obtainable_source(item, ilvl, zones, phase, today):
    """The first source the item can be obtained from on that day, or None."""
    if item.get("phase", 1) > phase:
        return None
    for source in item.get("sources") or []:
        zone = zones.get(source.get("drop", {}).get("zoneId"))
        if zone in RAID_OPENS:
            opens = RAID_OPENS[zone]
            if opens and opens <= today:
                return source
        elif ilvl <= MAX_ITEM_LEVEL:
            return source
    return None


def source_text(source, db, professions):
    if not source:
        return "-"
    kind, info = next(iter(source.items()))
    zone = db["zone"].get(info.get("zoneId"))
    if kind == "drop":
        who = db["npc"].get(info.get("npcId")) or (info.get("otherName") or "").strip()
        return ", ".join(part for part in (who, zone) if part) or "Drop"
    if kind == "quest":
        return "Quest: %s" % info["name"] if info.get("name") else "Quest"
    if kind == "soldBy":
        return "Vendor: " + ", ".join(part for part in (info.get("npcName"), zone) if part) if info.get("npcName") else "Vendor"
    if kind == "crafted":
        return "Crafted: %s" % professions.get(info.get("profession"), "profession")
    if kind == "rep":
        faction = db["faction"].get(info.get("repFactionId"))
        return "Reputation: %s" % faction if faction else "Reputation"
    if kind == "pvp":
        return "PvP"
    return kind


def build(sim, today):
    proto = (sim / "proto/common.proto").read_text()
    phase = int(re.search(r"CURRENT_PHASE = Phase\.Phase(\d+)", (sim / "ui/sim/constants/other.ts").read_text()).group(1))
    stats = enum(proto, "Stat")
    classes = {v: k[len("Class"):].upper() for k, v in enum(proto, "Class").items()}
    professions = {v: k for k, v in enum(proto, "Profession").items()}

    main = json.loads((sim / "assets/database/db.json").read_text())
    leftover = json.loads((sim / "assets/database/leftover_db.json").read_text())
    db = {
        "zone": {z["id"]: z["name"] for z in main["zones"]},
        "npc": {n["id"]: n["name"] for n in main["npcs"]},
        "faction": {f["id"]: f["name"] for f in main["factions"] + leftover.get("factions", [])},
    }

    profiles = read_profiles(sim, stats)
    armor, weapons, ranged = read_capabilities(sim, proto)

    items, slots = {}, {}
    for item in main["items"] + leftover["items"]:
        if not item.get("type") or not item.get("scalingOptions"):
            continue
        scaling = next(iter(item["scalingOptions"].values()))
        item_stats = scaling.get("stats") or {}
        dps = round(scaling.get("unroundedDps") or 0, 1)
        ilvl = scaling.get("ilvl") or 0
        source = obtainable_source(item, ilvl, db["zone"], phase, today)
        fields = [
            item["type"], item.get("armorType", 0), item.get("weaponType", 0), item.get("handType", 0),
            item.get("rangedWeaponType", 0), item.get("reqLvl") or max(1, ilvl - ITEM_LEVEL_LEAD), ilvl, "%g" % dps, scaling.get("randPropPoints", 0),
            ",".join(classes[c] for c in item.get("classAllowlist") or [] if c in classes) or "-",
            sparse(item_stats), item["name"], source_text(source or (item.get("sources") or [None])[0], db, professions),
        ]
        items[item["id"]] = "^".join(str(f).replace("^", " ") for f in fields)
        is_candidate = (
            source and item.get("quality", 0) >= 2 and not item.get("randomSuffixOptions")
            and item["type"] != TRINKET and (item_stats or dps)
        )
        if is_candidate:
            slots.setdefault(item["type"], []).append(item["id"])

    # Guard against a silent format change upstream: better no update than an empty one.
    assert len(items) > 5000, "only %d items parsed" % len(items)
    assert len(profiles) >= 5, "only %d classes have weights" % len(profiles)
    assert len(armor) == len(weapons) == 9, "class capabilities not parsed"

    out = ["-- Generated by tools/build_data.py from https://github.com/wowsims/forever. Do not edit.", "local _, ns = ...", "ns.Data = {"]
    out.append("\tmaxItemLevel = %d," % MAX_ITEM_LEVEL)
    out.append("\tstatNames = {")
    for name, index in sorted(stats.items(), key=lambda kv: kv[1]):
        out.append("\t\t[%d] = %s," % (index, lua_string(words(name[len("Stat"):]).replace(" Rating", ""))))
    out.append("\t},")
    out.append("\tprofiles = {")
    for cls in sorted(profiles):
        out.append("\t\t%s = {" % cls)
        for p in profiles[cls]:
            extra = "".join(", %s = %g" % (k, p[k]) for k in ("mh", "oh", "rg") if k in p)
            w = ", ".join("[%d] = %g" % (k, v) for k, v in sorted(p["w"].items()))
            out.append("\t\t\t{ name = %s, w = { %s }%s }," % (lua_string(p["name"]), w, extra))
        out.append("\t\t},")
    out.append("\t},")
    out.append("\tarmor = { %s }," % ", ".join("%s = %d" % kv for kv in sorted(armor.items())))
    out.append("\tweapons = {")
    for cls in sorted(weapons):
        out.append("\t\t%s = { %s }," % (cls, ", ".join("[%d] = %d" % kv for kv in sorted(weapons[cls].items()))))
    out.append("\t},")
    out.append("\tranged = {")
    for cls in sorted(ranged):
        out.append("\t\t%s = { %s }," % (cls, ", ".join("[%d] = true" % r for r in ranged[cls])))
    out.append("\t},")
    out.append("\tsuffixes = {")
    for suffix in sorted(main["randomSuffixes"], key=lambda s: s["id"]):
        out.append('\t\t[%d] = "%s",' % (suffix["id"], sparse(dict(enumerate(suffix["stats"])))))
    out.append("\t},")
    out.append("\tenchants = {")
    seen = set()
    for enchant in sorted(main["enchants"] + leftover.get("enchants", []), key=lambda e: e["effectId"]):
        text = sparse(dict(enumerate(enchant.get("stats") or [])))
        if text != "-" and enchant["effectId"] not in seen:
            seen.add(enchant["effectId"])
            out.append('\t\t[%d] = "%s",' % (enchant["effectId"], text))
    out.append("\t},")
    out.append("\tslots = {")
    for slot in sorted(slots):
        out.append("\t\t[%d] = { %s }," % (slot, ", ".join(str(i) for i in sorted(slots[slot]))))
    out.append("\t},")
    out.append("\titems = {")
    for item_id in sorted(items):
        out.append("\t\t[%d] = %s," % (item_id, lua_string(items[item_id])))
    out.append("\t},")
    out.append("}")
    summary = "%d items, %d upgrade candidates, weights for %s" % (
        len(items), sum(len(v) for v in slots.values()),
        ", ".join("%s (%d)" % (c, len(p)) for c, p in sorted(profiles.items())),
    )
    return "\n".join(out) + "\n", summary


def main():
    sim = Path(sys.argv[1])
    target = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "Data.lua"
    body, summary = build(sim, datetime.date.today().isoformat())
    built_line = re.compile(r'^ns\.Data\.built = "[^"]*"\n', re.M)
    if target.exists() and built_line.sub("", target.read_text()) == body:
        print("Data.lua unchanged (%s)" % summary)
        return
    target.write_text(body + 'ns.Data.built = "%s"\n' % datetime.date.today().isoformat())
    print("Data.lua written (%s)" % summary)


if __name__ == "__main__":
    main()
