#!/usr/bin/env python3
"""Renders the addon window outside the game, for a visual check of layout changes.

Usage (from the repo root): python3 tools/render_ui.py <output-dir>

Loads the real addon code against tests/wowstub.lua with the sample state from
tests/sample.lua and writes one HTML page per view. Open them in a browser or
screenshot them. Fonts differ from the game, so treat text widths as approximate.
Needs the "lupa" Python package.
"""
import html
import sys
from pathlib import Path

import lupa.lua51 as lupa  # the game runs Lua 5.1

SETUP = """
local Stub = dofile("tests/wowstub.lua")
local ns = Stub.Load({ "Data.lua", "Calibration.lua", "Core.lua", "UI.lua", "Probe.lua" })
dofile("tests/sample.lua")(Stub, ns)
GearOrSkillDB = { profile = 2 }
Stub.Fire("PLAYER_REGEN_ENABLED")
Stub.Fire("INSPECT_READY", Stub.guids.thrallix)
Stub.RunTimers()
SlashCmdList.GEARORSKILL("")
return Stub, ns
"""

VIEWS = [
    ("me", 'ns.ShowTab("Me")'),
    ("group", 'ns.ShowTab("Group")'),
    ("fight", 'ns.ShowTab("Fight")'),
    ("me-level-20", 'Stub.state.level = 20; ns.ShowTab("Me")'),
    ("group-level-20", 'ns.ShowTab("Group")'),
    ("no-fight", 'Stub.state.level = 60; ns.lastFight = nil; ns.ShowTab("Group")'),
]

PAGE = """<!doctype html><meta charset="utf-8"><title>GearOrSkill %s</title>
<style>
body{margin:0;padding:24px;background:#26302a}
#win{position:relative;width:%dpx;height:%dpx;font-family:Arial,sans-serif}
#win div{position:absolute;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.15}
</style><div id="win">
%s
</div>
"""


def rgba(color):
    r, g, b, a = (color[i] for i in (1, 2, 3, 4))
    return "rgba(%d,%d,%d,%.2f)" % (r * 255, g * 255, b * 255, a)


def render(regions, ox, oy):
    out = []
    for region in regions.values():
        x, y = region.x - ox, region.y - oy
        if region.kind == "texture":
            if region.color:
                out.append('<div style="left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx;background:%s"></div>'
                           % (x, y, region.w, region.h, rgba(region.color)))
            continue
        style = "left:%.1fpx;top:%.1fpx;font-size:%dpx;color:%s" % (x, y, region.size, rgba(region.color))
        if region.w:
            style += ";width:%.1fpx;text-align:%s" % (region.w, (region.justify or "LEFT").lower())
        elif region.anchor in ("CENTER", "TOP", "BOTTOM"):
            style += ";transform:translateX(-50%)"
        out.append('<div class="t" style="%s">%s</div>' % (style, html.escape(region.text or "")))
    return "\n".join(out)


def main():
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    stub, ns = lua.execute(SETUP)
    lua.globals().Stub, lua.globals().ns = stub, ns
    for name, action in VIEWS:
        lua.execute(action)
        regions, x, y, w, h = stub.Dump(lua.globals().GearOrSkillFrame)
        (target / (name + ".html")).write_text(PAGE % (name, w, h, render(regions, x, y)))
        print("wrote", target / (name + ".html"))


if __name__ == "__main__":
    main()
