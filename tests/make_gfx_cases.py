#!/usr/bin/env python3
# The graphics-settings cases (2026-11-11, Project Settings > Graphics): each is tests/cases/world_light_fog (a
# camera over a row of boxes going away, a floor, a screenshot at frame 30) with project.cbproj's [graphics] set:
#   gfx_splat_full   every shape a cloud of round splats        gfx_splat_mixed  only the boxes marked `splat`
#   gfx_splat_square square splats, sparser                     gfx_pixel        4 x 4 pixels: an 80 x 50 frame
#   gfx_toon / gfx_unlit / gfx_wire   the shading styles        gfx_window       MSAA + VSync + a resizable window
#   gfx_post / gfx_post_pixel   the Environment's post effects (2026-11-11, round 2)
# The runner checks each screenshot's size and that it isn't blank (expect_png); look at them too.
# Run it again after changing tests/make_world_cases.py's world_light_fog.
import json, os, shutil
T = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(T, "cases", "world_light_fog")

CASES = {
    "gfx_splat_full": ({"splat": "full", "splat_size": 0.12, "splat_density": 90}, None, (320, 200), "every box and the floor as round splats"),
    "gfx_splat_mixed": ({"splat": "mixed", "splat_size": 0.12, "splat_density": 90}, "even", (320, 200), "the even boxes (and not the floor) as splats; the others solid"),
    "gfx_splat_square": ({"splat": "full", "splat_shape": "square", "splat_size": 0.1, "splat_density": 40}, None, (320, 200), "square splats, sparser and bigger"),
    "gfx_pixel": ({"pixel": 4}, None, (80, 50), "pixel size 4: the frame is 80 x 50, stretched up in the window"),
    "gfx_toon": ({"shading": "toon"}, None, (320, 200), "toon shading: three steps of light"),
    "gfx_unlit": ({"shading": "unlit"}, None, (320, 200), "unlit: flat colours"),
    "gfx_wire": ({"shading": "wire"}, None, (320, 200), "wireframe"),
    "gfx_window": ({"msaa": True, "vsync": True, "window": "resizable"}, None, (320, 200), "MSAA, VSync and a resizable window"),
    # Post effects are the Environment's fields (vignette, scanlines, grain, posterize), not project settings.
    "gfx_post": ({}, None, (320, 200), "an Environment's vignette 0.8, scanlines 0.5, grain 0.4 and posterize 6 (levels a channel)",
                 {"vignette": "0.8", "scanlines": "0.5", "grain": "0.4", "posterize": "6"}),
    "gfx_post_pixel": ({"pixel": 2}, None, (160, 100), "pixel size 2 with scanlines 0.6 and a vignette 0.5: the effects run on the small frame",
                       {"vignette": "0.5", "scanlines": "0.6"}),
    # Round 3 (2026-11-11): the other post effects, PS1 vertex snapping, and settings changed while it runs
    "gfx_post_more": ({}, None, (320, 200), "bloom 0.8, a CRT curve 0.6, outline 0.8 and dither 0.9 over posterize 8",
                      {"bloom": "0.8", "curve": "0.6", "outline": "0.8", "dither": "0.9", "posterize": "8"}),
    "gfx_snap": ({"pixel": 2}, None, (160, 100), "PS1 vertex snapping (a 40 x 25 grid) with dither at pixel size 2",
                 {"snap": "4", "dither": "0.6", "posterize": "16"}),
    # A floor far bigger than the point cap: its points are thinned evenly (and grow), not cut off at the far triangles
    "gfx_splat_big": ({"splat": "full", "splat_size": 0.12, "splat_density": 90}, None, (320, 200), "a 200 x 200 floor in full splatting: over the point cap, still covered to the horizon",
                      {}, {"Floor": {"size": "200, 0.2, 200", "position": "0, -0.6, 0"}}),
    "gfx_runtime": ({}, None, (160, 100), "frame 5: Graphics setting bricks set toon shading and pixel size 2; Field bricks set the Environment's vignette and outline",
                    {}),
}

for name, spec in CASES.items():
    gfx, mark, size, what = spec[:4]
    env = spec[4] if len(spec) > 4 else {}
    objs = spec[5] if len(spec) > 5 else {}
    D = os.path.join(T, "cases", name)
    if os.path.isdir(D):
        shutil.rmtree(D)
    os.makedirs(D)
    shutil.copy(os.path.join(SRC, "main.cbricks"), D)
    scene = json.load(open(os.path.join(SRC, "main.cbscene")))
    for o in scene["objects"]:
        if o["class"] == "Environment":
            o["fields"].update(env)
        if o["name"] in objs:
            o["fields"].update(objs[o["name"]])
        if mark == "even" and o["name"].startswith("Box") and int(o["name"][3:]) % 2 == 0:
            o["fields"]["splat"] = "true"
    json.dump(scene, open(os.path.join(D, "main.cbscene"), "w"), indent="\t")
    if name == "gfx_runtime":
        g = json.load(open(os.path.join(D, "main.cbricks")))
        def node(i, t, fields, args, outs=None, links=None):
            return {"id": i, "type": t, "pos": [0, 0], "size": [0, 0], "fields": fields, "args": args, "outs": outs or {}, "links": links or {}}
        F = lambda v: {"type": "float", "value": v}
        g["nodes"] += [
            node(30, "if", {"operator": "=="}, {"a": {"var": "frames"}, "b": {"type": "int", "value": "5"}}, links={"true": [31, 32, 33, 34, 35]}),
            node(31, "look", {"what": "Shading", "shading": "toon"}, {}),
            node(32, "look", {"what": "Pixel size"}, {"pixel": {"type": "int", "value": "2"}}),
            node(33, "object", {"op": "Find", "of": "Environment"}, {"name": {"type": "string", "value": "Environment"}}, outs={"result": {"var": "env5", "use": False}}),
            node(34, "field", {"mode": "Set", "field": "vignette"}, {"record": {"var": "env5"}, "value": F("0.6")}),
            node(35, "field", {"mode": "Set", "field": "outline"}, {"record": {"var": "env5"}, "value": F("0.7")}),
        ]
        g["nodes"][3]["links"]["frame"].insert(1, 30)  # the game loop's Frame chains: count, then (new) the frame-5 settings
        g["next_id"] = 40
        json.dump(g, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
    lines = ['[project]', '', 'name="Graphics settings"', 'version="1.0"', '', '[graphics]', '']
    for k, v in gfx.items():
        lines.append('%s=%s' % (k, json.dumps(v)))
    open(os.path.join(D, "project.cbproj"), "w").write("\n".join(lines) + "\n")
    open(os.path.join(D, "case.cfg"), "w").write("""; Graphics settings (%s): %s.
; The light-and-fog world with a screenshot at frame 30 (world_light_fog.png: look at it).
; Generated by tests/make_gfx_cases.py: change it there.
[case]
expect_contains=["[light] #ffc070 x 1.4, fog 0.09 '#d8d0c8'"]
expect_missing=["warning"]
expect_png=[["world_light_fog.png", %d, %d, 12]]
""" % (name, what, size[0], size[1]))
    print("wrote tests/cases/" + name)
