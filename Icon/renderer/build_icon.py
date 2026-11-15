#!/usr/bin/env python3
"""Assemble an Icon Composer .icon from rendered layers.

  build_icon.py <layersDir> <out.icon>
      one 'object' layer (everything in a single group)

  build_icon.py <layersDir> <out.icon> --split <topDir> <midDir> [--group-shadow 0.25]
      one group per server unit, for real depth: layersDir/object.png is the full stack (the bottom
      unit's layer), topDir/object.png has only the top unit, midDir/object.png the top + middle.
      Icon Composer allows 4 groups: top unit, middle unit, bottom unit, and one for the effects.
"""
import argparse, json, os, shutil
ENV = os.environ

ap = argparse.ArgumentParser()
ap.add_argument("layers"); ap.add_argument("out")
ap.add_argument("--split", nargs=2, metavar=("TOP", "MID"))
ap.add_argument("--group-shadow", type=float, default=0.0)
a = ap.parse_args()

shutil.rmtree(a.out, ignore_errors=True); os.makedirs(a.out + "/Assets")
def srgb(r, g, b): return "srgb:%.5f,%.5f,%.5f,1.00000" % (r, g, b)
def put(src, name): shutil.copy(src, f"{a.out}/Assets/{name}.png")
def layer(name, blend=None, glass=False):
    d = {"glass": glass, "image-name": f"{name}.png", "name": name}
    if blend: d["blend-mode"] = blend
    return d
def group(layers, shadow=0.0):
    return {"layers": layers,
            "shadow": {"kind": "neutral", "opacity": shadow} if shadow else {"kind": "none", "opacity": 0},
            "translucency": {"enabled": False, "value": 0.5}}

for f in ("shadow", "glow", "streaks", "backlight", "vignette"): put(f"{a.layers}/{f}.png", f)

if a.split:
    top, mid = a.split
    put(f"{top}/object.png", "unit-1-top"); put(f"{mid}/object.png", "unit-2-middle"); put(f"{a.layers}/object.png", "unit-3-bottom")
    gs = a.group_shadow
    groups = [   # frontmost first
        group([layer("glow", "screen"), layer("unit-1-top")], gs),
        group([layer("unit-2-middle")], gs),
        group([layer("unit-3-bottom")]),
        group([layer("shadow"), layer("streaks", "screen"), layer("backlight", "screen"), layer("vignette")]),
    ]
else:
    put(f"{a.layers}/object.png", "object")
    groups = [group([layer("glow", "screen"), layer("object")]), group([layer("shadow")]),
              group([layer("streaks", "screen")]), group([layer("backlight", "screen"), layer("vignette")])]

FILL = {"linear-gradient": [srgb(*[float(v) for v in ENV.get("BG_TOP", "0.19,0.20,0.235").split(",")]),
                                srgb(*[float(v) for v in ENV.get("BG_BOT", "0.03,0.03,0.04").split(",")])],
           "orientation": {"start": {"x": float(ENV.get("BG_SX", 0.2)), "y": 0}, "stop": {"x": float(ENV.get("BG_EX", 0.8)), "y": 1}}}
json.dump({
  "fill": FILL,
  # the system re-tints these for the dark and tinted icon styles; give them their own, deeper grounds
  "fill-specializations": [
    {"value": FILL},
    {"appearance": "dark", "value": {"linear-gradient": [srgb(0.10, 0.105, 0.12), srgb(0.02, 0.02, 0.03)],
                                      "orientation": FILL["orientation"]}},
    {"appearance": "tinted", "value": {"solid": srgb(0.015, 0.015, 0.02)}},
  ],
  "groups": groups,
  "supported-platforms": {"squares": "shared"},
}, open(a.out + "/icon.json", "w"), indent=2)
print("built", a.out)
