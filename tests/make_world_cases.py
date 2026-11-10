# Generates tests/cases/world_classes: the small built-in classes drawn by the runtime
# (2026-11-07): python3 tests/make_world_cases.py
#   2D: a Spatial2D "Group" (moved, turned 30 degrees, scaled 1.5) holding a Shape2D box
#   and a Shape2D circle, a Text2D title, a Sprite2D from icon.png, a Camera2D (zoom 1,
#   at the window's middle: the view doesn't move); 3D: an Environment (sky), a Light3D
#   (turned), a Camera3D, a Spatial3D "Rig" scaled 2 holding a Shape3D "Cube" one unit
#   to its right (so it's drawn 2 units right, 2 big), and a Shape3D floor.
#   world_classes.png at frame 30 (look at it); the Node bricks see the classes.
# And tests/cases/world_light_fog (2026-11-07): a Light3D's color and energy (a warm sun,
#   1.4 strong) and an Environment's fog (0.09, its color blank: the sky's), over a row of
#   white boxes going away from the camera: the far ones fade into the sky.
#   world_light_fog.png at frame 30 (look at it); the fields read back.
# And tests/cases/draw_2d (2026-11-07): Draw's turned shapes and sprite frames, a Draw 2D
#   view (zoomed, centred on a point), and a Sprite2D node showing frame 2 of a 2 x 2 sheet
#   (sheet.png: red, green / blue, yellow cells). draw_2d.png at frame 10 (look at it).
# And tests/cases/move_collide (2026-11-07, user: "the player and enemies seem to clip through
#   objects way too commonly"): Move and collide with a turned mover against a wall (its
#   own box doesn't turn: it used to grow into the wall and walk through), and a mover
#   already inside a wall (out: free; deeper: refused). No window.
# And tests/cases/no_main, no_main_3d (2026-11-07, user: "can we make it so the main script is
#   not made automatically"): projects without a When program starts: the build's own main()
#   makes the Main scene (its Script objects start); in a 3D one it opens a window and runs the
#   Game loop (a script's When frame ends closes it after 3 frames).
# And tests/cases/ui_basic (2026-11-07, UI step 1): Control, Label, Panel, Bar, Image; anchors
#   (corners, edges, center, full), a Label inside a Panel, a Label under a Spatial3D (not moved
#   by it), a hidden Control hiding its Label, a zoomed Camera2D (moves the 2D, not the UI), a
#   Draw brick under the UI, a Label's text set by a brick. ui_basic.png at frame 10 (look at it).
# And tests/cases/ui_containers (UI step 4): a class Menu extending VBox (padding, fill,
#   separation) in a Panel: Play, a hidden Options (no room), Quit, a Label; an HBox toolbar of
#   squares (no fill). A --click where Quit should be clicks Quit (the layout, checked by
#   position); ui_containers.png (look at it).
# And tests/cases/time_effects (2026-11-08, user: "camera shake is also paused and affected by time
#   scale ... test other things"): Shake Camera's time left stands still while paused and
#   drains at the time scale's rate; Wait counts the world's time (half speed: twice as long;
#   paused: until something resumes it); Game info's Time is the real clock (paused or slowed,
#   it goes on).
# And tests/cases/pause (2026-11-08): offline, Pause game freezes the world (a class's Every
#   frame, a script's When frame starts, frame time 0) but not what Runs while paused (a class's
#   and a script's), nor the Game loop's Frame chains; Resume; time scale 0.5 halves the world's
#   time against real time.
import json, os, struct, zlib

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "world_classes")
V = lambda v: {"var": v}; I = lambda x: {"type": "int", "value": str(x)}; S = lambda x: {"type": "string", "value": x}


def png(w, h, pixel):
    raw = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))
    def chunk(t, data):
        c = struct.pack(">I", len(data)) + t + data
        return c + struct.pack(">I", zlib.crc32(t + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def rooted(objects, name="Main"):
    """One root per scene (2026-11-07): the objects at the top go under a root named `name`: a Spatial3D when
    the scene has 3D things (user: "make every Main object a spatial object"), else a Node."""
    tops = [o for o in objects if int(o.get("parent", 0)) == 0]
    if len(tops) == 1 and tops[0].get("class") not in ("Script", "LocalScript", "ModuleScript"):
        return objects
    rid = max([int(o["id"]) for o in objects] + [0]) + 1
    for o in tops:
        o["parent"] = rid
    return [{"id": rid, "class": ("Spatial3D" if any(o.get("class") in ("Spatial3D", "Shape3D", "Mesh3D", "Camera3D", "Light3D") for o in objects) else "Node"), "name": name, "parent": 0, "fields": {}}] + objects


nodes = []
def b(t, fields=None, args=None, outs=None, links=None):
    i = len(nodes) + 1
    nodes.append({"id": i, "type": t, "pos": [0, 0], "size": [0, 0], "fields": fields or {}, "args": args or {},
                  "outs": {k: {"var": v, "use": False} for k, v in (outs or {}).items()}, "links": links or {}})
    return i
def link(i, g, ids): nodes[i - 1]["links"][g] = ids

st = b("start")
win = b("window", {}, {"width": I(320), "height": I(200), "title": S("world classes"), "fps": I(60)})
fr0 = b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)})
gl = b("game_loop")
link(st, "out", [win, fr0, gl])
add = b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})
at = b("if", {"operator": "=="}, {"a": V("frames"), "b": I(30)})
link(gl, "frame", [add, at])
shot = b("raw_c", {"code": "cb_screenshot(\"world_classes.png\");"})
cube = b("node" if False else "object", {"op": "Find", "of": "Shape3D"}, {"name": S("Cube")}, {"result": "cube"})
isa = b("object", {"op": "Is a", "of": "Spatial3D"}, {"object": V("cube")}, {"result": "spatial"})
txt = b("object", {"op": "Find", "of": "Text2D"}, {"name": S("Title")}, {"result": "title"})
cls = b("object", {"op": "Class name"}, {"object": V("title")}, {"result": "tcls"})
fmt = b("text", {"op": "Format", "format": "[world] cube is a Spatial3D: {}, title is a {}"}, {"first": V("spatial"), "second": V("tcls")}, {"result": "line"})
pr = b("print", {"newline": True}, {"value": V("line")})
q = b("quit", {}, {"code": I(0)})
link(at, "true", [shot, cube, isa, txt, cls, fmt, pr, q])

scene = {"format": "c-bricks-scene", "version": 4, "next_id": 20, "objects": [
    {"id": 1, "class": "Environment", "name": "Environment", "parent": 0, "fields": {"sky": "#203040"}},
    {"id": 2, "class": "Light3D", "name": "Sun", "parent": 0, "fields": {"rotation": "-55, 34, 0"}},
    {"id": 3, "class": "Camera3D", "name": "Camera", "parent": 0, "fields": {"position": "1, 4, 9", "target": "1, 0, 0", "fov": "50"}},
    {"id": 4, "class": "Shape3D", "name": "Floor", "parent": 0, "fields": {"size": "12, 0.2, 6", "position": "0, -0.6, 0", "color": "#5aa846"}},
    {"id": 5, "class": "Spatial3D", "name": "Rig", "parent": 0, "fields": {"scale": "2, 2, 2"}},
    {"id": 6, "class": "Shape3D", "name": "Cube", "parent": 5, "fields": {"position": "1, 0, 0", "color": "ORANGE"}},
    {"id": 7, "class": "Shape3D", "name": "Marker", "parent": 0, "fields": {"position": "-2, 0, 0", "size": "0.5, 0.5, 0.5", "shape": "Sphere", "color": "RED"}},
    {"id": 8, "class": "Spatial2D", "name": "Group", "parent": 0, "fields": {"position": "90, 120", "rotation": "30", "scale": "1.5, 1.5"}},
    {"id": 9, "class": "Shape2D", "name": "Box", "parent": 8, "fields": {"position": "30, 0", "size": "30, 16", "color": "RED"}},
    {"id": 10, "class": "Shape2D", "name": "Dot", "parent": 8, "fields": {"position": "-30, 0", "size": "20, 20", "shape": "Circle", "color": "YELLOW"}},
    {"id": 11, "class": "Text2D", "name": "Title", "parent": 0, "fields": {"position": "10, 8", "text": "2D on 3D", "size": "20", "color": "WHITE"}},
    {"id": 12, "class": "Sprite2D", "name": "Icon", "parent": 0, "fields": {"position": "280, 160", "texture": "icon.png"}},
    {"id": 13, "class": "Camera2D", "name": "View", "parent": 0, "fields": {"position": "160, 100", "zoom": "1"}},
]}
os.makedirs(D, exist_ok=True)
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
scene["objects"] = rooted(scene["objects"])
scene["next_id"] = max(o["id"] for o in scene["objects"]) + 1
json.dump(scene, open(os.path.join(D, "main.cbscene"), "w"), indent="\t")
open(os.path.join(D, "icon.png"), "wb").write(png(24, 24, lambda x, y: (40, 200, 255, 255) if (x // 6 + y // 6) % 2 == 0 else (255, 255, 255, 255)))
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="World classes"\nversion="1.0"\n')
open(os.path.join(D, "case.cfg"), "w").write("""; The small built-in classes drawn by the runtime: a turned, scaled Spatial2D holding a Shape2D box
; and circle, a Text2D, a Sprite2D (icon.png, checkered), a Camera2D; an Environment's sky, a Light3D,
; a Camera3D, a Spatial3D scaled 2 holding a Cube (drawn 2 units right, 2 big). world_classes.png at
; frame 30 (look at it). Generated by tests/make_world_cases.py: change it there.
[case]
expect_contains=["[world] cube is a Spatial3D: true, title is a Text2D"]
""")
print("wrote tests/cases/world_classes")


# ------------------------------------------------------------------ world_light_fog
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "world_light_fog")
nodes = []
st = b("start")
win = b("window", {}, {"width": I(320), "height": I(200), "title": S("light and fog"), "fps": I(60)})
fr0 = b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)})
gl = b("game_loop")
link(st, "out", [win, fr0, gl])
add = b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})
at = b("if", {"operator": "=="}, {"a": V("frames"), "b": I(30)})
link(gl, "frame", [add, at])
shot = b("raw_c", {"code": "cb_screenshot(\"world_light_fog.png\");"})
sun = b("object", {"op": "Find", "of": "Light3D"}, {"name": S("Sun")}, {"result": "sun"})
lc = b("field", {"mode": "Get", "field": "color"}, {"record": V("sun")}, {"value": "lcolor"})
le = b("field", {"mode": "Get", "field": "energy"}, {"record": V("sun")}, {"value": "lenergy"})
env = b("object", {"op": "Find", "of": "Environment"}, {"name": S("Environment")}, {"result": "env"})
fd = b("field", {"mode": "Get", "field": "fog"}, {"record": V("env")}, {"value": "fog"})
fc = b("field", {"mode": "Get", "field": "fog_color"}, {"record": V("env")}, {"value": "fogc"})
fmt = b("text", {"op": "Format", "format": "[light] {} x {}, fog {} '{}'"}, {"first": V("lcolor"), "second": V("lenergy"), "third": V("fog"), "fourth": V("fogc")}, {"result": "line"})
pr = b("print", {"newline": True}, {"value": V("line")})
hz = b("field", {"mode": "Get", "field": "horizon"}, {"record": V("env")}, {"value": "hz"})
ac = b("field", {"mode": "Get", "field": "ambient_color"}, {"record": V("env")}, {"value": "ac"})
fst = b("field", {"mode": "Get", "field": "fog_start"}, {"record": V("env")}, {"value": "fst"})
fmt2 = b("text", {"op": "Format", "format": "[environment] horizon {}, ambient {}, fog from {}"}, {"first": V("hz"), "second": V("ac"), "third": V("fst")}, {"result": "line2"})
pr2 = b("print", {"newline": True}, {"value": V("line2")})
close = b("close_window")
link(at, "true", [shot, sun, lc, le, env, fd, fc, fmt, pr, hz, ac, fst, fmt2, pr2, close])

objs = [
    {"id": 1, "class": "Environment", "name": "Environment", "parent": 0, "fields": {"sky": "#5a7fb0", "horizon": "#e8d8c8", "ambient": "0.3", "ambient_color": "#b0c0ff", "fog": "0.09", "fog_start": "6", "fog_color": "#d8d0c8"}},
    {"id": 2, "class": "Light3D", "name": "Sun", "parent": 0, "fields": {"rotation": "-50, 30, 0", "color": "#ffc070", "energy": "1.4"}},
    {"id": 3, "class": "Camera3D", "name": "Camera", "parent": 0, "fields": {"position": "0, 2.5, 6", "target": "0, 0.5, -10", "fov": "55"}},
    {"id": 4, "class": "Shape3D", "name": "Floor", "parent": 0, "fields": {"size": "8, 0.2, 80", "position": "0, -0.6, -30", "color": "#5aa846"}},
]
for k in range(8):
    objs.append({"id": 10 + k, "class": "Shape3D", "name": "Box%d" % k, "parent": 0, "fields": {"position": "%d, 0.5, %d" % (-1 if k % 2 else 1, -k * 6), "color": "WHITE"}})
scene = {"format": "c-bricks-scene", "version": 4, "objects": rooted(objs)}
scene["next_id"] = max(o["id"] for o in scene["objects"]) + 1
os.makedirs(D, exist_ok=True)
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
json.dump(scene, open(os.path.join(D, "main.cbscene"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="Light and fog"\nversion="1.0"\n')
open(os.path.join(D, "case.cfg"), "w").write("""; A Light3D's color and energy and an Environment's fog (its color blank: the sky's), over a row of
; white boxes going away: lit warm, the far ones fading into the fog (from 6 units on), a gradient sky
; (blue to a pale horizon), a bluish ambient light on the shaded sides. world_light_fog.png at frame 30
; (look at it). Generated by tests/make_world_cases.py: change it there.
[case]
expect_contains=["[light] #ffc070 x 1.4, fog 0.09 '#d8d0c8'", "[environment] horizon #e8d8c8, ambient #b0c0ff, fog from 6"]
""")
print("wrote tests/cases/world_light_fog")


# ------------------------------------------------------------------ draw_2d
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "draw_2d")
F = lambda x: {"type": "float", "value": str(x)}
V2 = lambda x: {"type": "vector2", "value": x}
nodes = []
st = b("start")
win = b("window", {}, {"width": I(320), "height": I(200), "title": S("draw 2d"), "fps": I(60)})
tex = b("load_texture", {}, {"path": S("sheet.png")}, {"texture": "sheet"})
fr0 = b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)})
gl = b("game_loop")
link(st, "out", [win, tex, fr0, gl])
add = b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})
draws = []
# a row of the 4 frames, unturned (top-left at x, y), scale 2 (16 px cells -> 32 px)
for k in range(4):
    draws.append(b("draw", {"shape": "Sprite"}, {"texture": V("sheet"), "x": I(10 + k * 40), "y": I(10), "frame": I(k), "columns": I(2), "rows": I(2), "scale": F(2), "rotation": F(0), "color": S("WHITE")}))
draws.append(b("draw", {"shape": "Rectangle"}, {"x": I(20), "y": I(70), "width": I(60), "height": I(20), "rotation": F(45), "color": S("MAROON")}))
draws.append(b("draw", {"shape": "Outline"}, {"x": I(20), "y": I(70), "width": I(60), "height": I(20), "color": S("BLACK")}))
draws.append(b("draw", {"shape": "Text"}, {"text": S("turned"), "x": I(100), "y": I(70), "size": I(20), "rotation": F(-20), "color": S("DARKBLUE")}))
draws.append(b("draw", {"shape": "Texture"}, {"texture": V("sheet"), "x": I(190), "y": I(60), "rotation": F(30), "color": S("WHITE")}))
v2 = b("view2d", {}, {"center": V2("0, 0"), "zoom": F(3), "rotation": F(0)})
link(v2, "draw", [b("draw", {"shape": "Rectangle"}, {"x": I(-5), "y": I(-5), "width": I(10), "height": I(10), "rotation": F(0), "color": S("ORANGE")}),
                  b("draw", {"shape": "Circle"}, {"x": I(12), "y": I(0), "radius": F(3), "color": S("DARKGREEN")})])
draws.append(v2)
at = b("if", {"operator": "=="}, {"a": V("frames"), "b": I(10)})
link(gl, "frame", [add] + draws + [at])
shot = b("raw_c", {"code": "cb_screenshot(\"draw_2d.png\");"})
sp = b("object", {"op": "Find", "of": "Sprite2D"}, {"name": S("Sheet")}, {"result": "spr"})
fget = b("field", {"mode": "Get", "field": "frame"}, {"record": V("spr")}, {"value": "sframe"})
fmt = b("text", {"op": "Format", "format": "[draw_2d] sprite frame {}"}, {"first": V("sframe")}, {"result": "line"})
pr = b("print", {"newline": True}, {"value": V("line")})
link(at, "true", [shot, sp, fget, fmt, pr, b("close_window")])

objs = [
    {"id": 1, "class": "Environment", "name": "Environment", "parent": 0, "fields": {"sky": "#e8e8e0"}},
    {"id": 2, "class": "Sprite2D", "name": "Sheet", "parent": 0, "fields": {"position": "270, 160", "texture": "sheet.png", "columns": "2", "rows": "2", "frame": "2", "scale": "3, 3"}},
]
scene = {"format": "c-bricks-scene", "version": 4, "objects": rooted(objs)}
scene["next_id"] = max(o["id"] for o in scene["objects"]) + 1
os.makedirs(D, exist_ok=True)
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
json.dump(scene, open(os.path.join(D, "main.cbscene"), "w"), indent="\t")
cells = [(220, 40, 40, 255), (40, 180, 60, 255), (40, 80, 220, 255), (240, 200, 30, 255)]
open(os.path.join(D, "sheet.png"), "wb").write(png(32, 32, lambda x, y: cells[(y // 16) * 2 + x // 16]))
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="Draw 2D"\nversion="1.0"\n')
open(os.path.join(D, "case.cfg"), "w").write("""; Draw's turned shapes and sprite frames, a Draw 2D view, a Sprite2D's sheet frame. draw_2d.png at
; frame 10 (look at it: frames red, green, blue, yellow in a row; a maroon box turned 45 degrees in its
; black unturned outline; turned blue text; the sheet turned 30; an orange square in the middle, 3x, with
; a green dot right of it; a blue Sprite2D bottom right). Generated by tests/make_world_cases.py.
[case]
expect_contains=["[draw_2d] sprite frame 2"]
""")
print("wrote tests/cases/draw_2d")


# ------------------------------------------------------------------ move_collide
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "move_collide")
nodes = []
st = b("start")
seq = []
def mk(name, pos, size, solid, rot="0, 0, 0"):
    seq.extend([b("new_object", {"of": "Shape3D", "world": True}, {}, {"object": name}),
                b("field", {"mode": "Set", "field": "position"}, {"record": V(name), "value": {"type": "vector3", "value": pos}}),
                b("field", {"mode": "Set", "field": "size"}, {"record": V(name), "value": {"type": "vector3", "value": size}}),
                b("field", {"mode": "Set", "field": "rotation"}, {"record": V(name), "value": {"type": "vector3", "value": rot}}),
                b("field", {"mode": "Set", "field": "solid"}, {"record": V(name), "value": {"type": "bool", "value": "true" if solid else "false"}})])
def report(label, who, blocked):
    seq.extend([b("field", {"mode": "Get", "field": "position"}, {"record": V(who)}, {"value": "at"}),
                b("formula", {"expression": "(double)at.z", "type": "float"}, {}, {"result": "z"}),
                b("text", {"op": "Format", "format": "[%s] blocked {}, z {}" % label}, {"first": V(blocked), "second": V("z")}, {"result": "line"}),
                b("print", {"newline": True}, {"value": V("line")})])
mk("wall", "0, 1, -5", "4, 2, 1", True)
# 1. turned 45 degrees, touching the wall's face (z -4.5): pushing on stops there
mk("turned", "0, 0.9, -4.05", "0.8, 1.8, 0.8", False, "0, 45, 0")
seq.append(b("move_collide", {}, {"part": V("turned"), "motion": {"type": "vector3", "value": "0, 0, -1"}}, {"blocked": "b1"}))
report("turned mover into the wall", "turned", "b1")
# turning on the spot at the wall doesn't free it either
seq.append(b("field", {"mode": "Set", "field": "rotation"}, {"record": V("turned"), "value": {"type": "vector3", "value": "0, 30, 0"}}))
seq.append(b("move_collide", {}, {"part": V("turned"), "motion": {"type": "vector3", "value": "0, 0, -0.5"}}, {"blocked": "b2"}))
report("turned again, pushing on", "turned", "b2")
# 2. already inside the wall (its middle is at z -5): deeper is refused, out is free
mk("stuck", "1.8, 0.9, -4.7", "0.8, 1.8, 0.8", False)
seq.append(b("move_collide", {}, {"part": V("stuck"), "motion": {"type": "vector3", "value": "0, 0, -0.3"}}, {"blocked": "b3"}))
report("inside, deeper", "stuck", "b3")
seq.append(b("move_collide", {}, {"part": V("stuck"), "motion": {"type": "vector3", "value": "0, 0, 1"}}, {"blocked": "b4"}))
report("inside, out", "stuck", "b4")
for a, c in zip(seq, seq[1:]):
    link(a, "next", [c])
link(st, "out", [seq[0]])
os.makedirs(D, exist_ok=True)
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="Move and collide"\nversion="1.0"\n')
open(os.path.join(D, "case.cfg"), "w").write("""; Move and collide (tests/make_world_cases.py: change it there). A mover turned 45 degrees touching a
; wall's face stays there when pushed (its own box doesn't turn: the box around the turned shape used to
; reach into the wall, which then counted as "already inside" and was walked through: the user's Arena
; players and enemies went through walls); turning again at the wall doesn't free it; a mover already
; inside a wall can't go deeper but moves out freely.
[case]
expect_output="[turned mover into the wall] blocked true, z -4.0999\n[turned again, pushing on] blocked true, z -4.0999\n[inside, deeper] blocked true, z -4.7\n[inside, out] blocked false, z -3.7"
""")
print("wrote tests/cases/move_collide")


# ------------------------------------------------------------------ no_main, no_main_3d
def no_main(case, three_d):
    global nodes
    D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", case)
    os.makedirs(os.path.join(D, "scripts"), exist_ok=True)
    for f in os.listdir(D):
        if f.endswith(".cbricks"):
            os.remove(os.path.join(D, f))
    nodes = []
    st = b("start")
    nm = b("object", {"op": "Name"}, {"object": V("parent")}, {"result": "pname"})
    fmt = b("text", {"op": "Format", "format": "[script] started under {}"}, {"first": V("pname")}, {"result": "line"})
    pr = b("print", {"newline": True}, {"value": V("line")})
    link(st, "out", [nm]); link(nm, "next", [fmt]); link(fmt, "next", [pr])
    if three_d:
        fe = b("frame_end")
        cnt = b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})
        at = b("if", {"operator": "=="}, {"a": V("frames"), "b": I(3)})
        link(fe, "out", [cnt]); link(cnt, "next", [at])
        say = b("print", {"newline": True}, {"value": S("[script] 3 frames in the default window: closing it")})
        cl = b("close_window")
        link(at, "true", [say]); link(say, "next", [cl])
        zero = b("var", {"mode": "Set", "name": "frames", "scope": "Shared"}, {"value": I(0)})
        link(pr, "next", [zero])
    json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "scripts", "hello.cbricks"), "w"), indent="\t")
    objs = [{"id": 1, "class": "Node", "name": "Main", "parent": 0, "fields": {}},
            {"id": 2, "class": "ModuleScript", "name": "Hello", "parent": 1, "script": "scripts/hello.cbricks", "fields": {}}]
    if three_d:
        objs[0]["class"] = "Spatial3D"
        objs += [{"id": 3, "class": "Shape3D", "name": "Box", "parent": 1, "fields": {"color": "ORANGE"}},
                 {"id": 4, "class": "Camera3D", "name": "Camera", "parent": 1, "fields": {"position": "2, 2, 3"}}]
    json.dump({"format": "c-bricks-scene", "version": 4, "next_id": len(objs) + 1, "objects": objs}, open(os.path.join(D, "main.cbscene"), "w"), indent="\t")
    open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="%s"\nversion="1.0"\n' % case)
    want = ["[script] started under Main"] + (["[script] 3 frames in the default window: closing it"] if three_d else [])
    open(os.path.join(D, "case.cfg"), "w").write("""; A project with no When program starts (tests/make_world_cases.py: change it there): the build's own
; main() makes the Main scene, so its Script object (a ModuleScript) starts with parent = Main%s.
[case]
expect_order=%s
""" % (";\n; a 3D one: main() opens a window and runs the Game loop, the script's When frame ends closes it" if three_d else "", json.dumps([w + "\n" for w in want])))
    print("wrote tests/cases/" + case)

no_main("no_main", False)
no_main("no_main_3d", True)


# ------------------------------------------------------------------ ui_basic
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "ui_basic")
nodes = []
st = b("start")
win = b("window", {}, {"width": I(320), "height": I(200), "title": S("ui"), "fps": I(60)})
fr0 = b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)})
gl = b("game_loop")
link(st, "out", [win]); link(win, "next", [fr0]); link(fr0, "next", [gl])
add = b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})
under = b("draw", {"shape": "Rectangle"}, {"x": I(0), "y": I(0), "width": I(320), "height": I(60), "rotation": {"type": "float", "value": "0"}, "color": S("MAROON")})
sc = b("object", {"op": "Find", "of": "Label"}, {"name": S("Score")}, {"result": "score"})
tx = b("text", {"op": "Format", "format": "Score: {}"}, {"first": V("frames")}, {"result": "stext"})
setx = b("field", {"mode": "Set", "field": "text"}, {"record": V("score"), "value": V("stext")})
at = b("if", {"operator": "=="}, {"a": V("frames"), "b": I(10)})
link(gl, "frame", [add]); link(add, "next", [under]); link(under, "next", [sc]); link(sc, "next", [tx]); link(tx, "next", [setx]); link(setx, "next", [at])
shot = b("raw_c", {"code": "cb_screenshot(\"ui_basic.png\");"})
gt = b("field", {"mode": "Get", "field": "text"}, {"record": V("score")}, {"value": "now"})
fmt = b("text", {"op": "Format", "format": "[ui] {}"}, {"first": V("now")}, {"result": "line"})
pr = b("print", {"newline": True}, {"value": V("line")})
link(at, "true", [shot]); link(shot, "next", [gt]); link(gt, "next", [fmt]); link(fmt, "next", [pr]); link(pr, "next", [b("close_window")])
objs = [
    {"id": 1, "class": "Node", "name": "Main", "parent": 0, "fields": {}},
    {"id": 2, "class": "Camera2D", "name": "View", "parent": 1, "fields": {"position": "0, 0", "zoom": "2"}},
    {"id": 3, "class": "Shape2D", "name": "Dot", "parent": 1, "fields": {"position": "0, 0", "size": "20, 20", "color": "BLUE", "shape": "Circle"}},
    {"id": 4, "class": "Panel", "name": "Frame", "parent": 1, "fields": {"anchor": "full", "offset": "4, 4", "color": "#ffffff10", "border": "1", "border_color": "#ffffff80"}},
    {"id": 5, "class": "Panel", "name": "HudBack", "parent": 1, "fields": {"anchor": "top_left", "offset": "8, 8", "size": "140, 40", "border": "2", "border_color": "WHITE", "radius": "8"}},
    {"id": 6, "class": "Label", "name": "Score", "parent": 5, "fields": {"anchor": "left", "offset": "10, 0", "size": "120, 16", "font_size": "16", "color": "YELLOW"}},
    {"id": 7, "class": "Bar", "name": "Health", "parent": 1, "fields": {"anchor": "bottom", "offset": "0, -10", "size": "150, 14", "value": "70"}},
    {"id": 8, "class": "Image", "name": "Icon", "parent": 1, "fields": {"anchor": "top_right", "offset": "-8, 8", "size": "32, 32", "texture": "icon.png"}},
    {"id": 9, "class": "Label", "name": "Middle", "parent": 1, "fields": {"anchor": "center", "size": "200, 20", "align": "center", "text": "PAUSED"}},
    {"id": 10, "class": "Spatial3D", "name": "Rig", "parent": 1, "fields": {"position": "50, 0, 0"}},
    {"id": 11, "class": "Label", "name": "Tag", "parent": 10, "fields": {"anchor": "bottom_left", "offset": "8, -8", "size": "100, 12", "font_size": "12", "text": "under 3D", "color": "LIME"}},
    {"id": 12, "class": "Control", "name": "Hidden", "parent": 1, "fields": {"visible": "false", "anchor": "center"}},
    {"id": 13, "class": "Label", "name": "Never", "parent": 12, "fields": {"text": "NEVER SHOWN", "color": "RED"}},
    {"id": 15, "class": "Button", "name": "Go", "parent": 1, "fields": {"anchor": "top", "offset": "0, 58", "size": "90, 24", "text": "Go", "radius": "6"}},
    {"id": 16, "class": "Button", "name": "Nope", "parent": 1, "fields": {"anchor": "bottom_right", "offset": "-8, -34", "size": "70, 22", "font_size": "14", "text": "Off", "disabled": "true"}},
    {"id": 14, "class": "Label", "name": "Right", "parent": 1, "fields": {"anchor": "right", "offset": "-8, 0", "size": "60, 14", "font_size": "14", "align": "right", "text": "right"}},
]
os.makedirs(D, exist_ok=True)
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
json.dump({"format": "c-bricks-scene", "version": 4, "next_id": 17, "objects": objs}, open(os.path.join(D, "main.cbscene"), "w"), indent="\t")
open(os.path.join(D, "icon.png"), "wb").write(png(16, 16, lambda x, y: (40, 200, 255, 255) if (x // 4 + y // 4) % 2 == 0 else (255, 255, 255, 255)))
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="UI"\nversion="1.0"\n')
open(os.path.join(D, "case.cfg"), "w").write("""; The UI (tests/make_world_cases.py: change it there): ui_basic.png at frame 10 (look at it): a faint
; frame round the window (full, inset 4), a rounded bordered Panel top-left over the maroon Draw strip with
; a yellow "Score: 10" in it (a brick sets it), a green Bar at the bottom middle 70% full, the checkered
; Image top-right, "PAUSED" in the middle, "right" at the right edge, a lime "under 3D" bottom-left (its
; Spatial3D parent doesn't move it); a blue dot in the middle drawn 2x by the Camera2D; no NEVER SHOWN.
[case]
expect_contains=["[ui] Score: 10"]
""")
print("wrote tests/cases/ui_basic")


# ------------------------------------------------------------------ ui_containers
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "ui_containers")
os.makedirs(os.path.join(D, "scripts"), exist_ok=True)
nodes = []
st = b("start")
win = b("window", {}, {"width": I(320), "height": I(200), "title": S("containers"), "fps": I(60)})
gl = b("game_loop")
link(st, "out", [win]); link(win, "next", [gl])
t = b("game_info", {"what": "Time"}, {}, {"result": "t"})
at = b("if", {"operator": ">"}, {"a": V("t"), "b": F(0.6)})
link(gl, "frame", [t]); link(t, "next", [at])
shot = b("raw_c", {"code": "cb_screenshot(\"ui_containers.png\");"})
link(at, "true", [shot]); link(shot, "next", [b("close_window")])
bc = b("button_clicked", {"button": ""})
bn = b("object", {"op": "Name"}, {"object": V("button")}, {"result": "which"})
bf = b("text", {"op": "Format", "format": "[clicked] {}"}, {"first": V("which")}, {"result": "cl"})
link(bc, "out", [bn]); link(bn, "next", [bf]); link(bf, "next", [b("print", {"newline": True}, {"value": V("cl")})])
main_nodes = nodes
nodes = []
mc = b("class", {"name": "Menu", "extends": "VBox", "fields": [["title", "string"]], "synced": ""})
cr = b("created")
link(cr, "out", [b("print", {"newline": True}, {"value": S("[menu] a Menu (a VBox of the project's own) was made")})])
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "scripts", "menu.cbricks"), "w"), indent="\t")
nodes = main_nodes
objs = [
    {"id": 1, "class": "Node", "name": "Main", "parent": 0, "fields": {}},
    {"id": 2, "class": "Panel", "name": "MenuBack", "parent": 1, "fields": {"anchor": "left", "offset": "10, 0", "size": "152, 130", "radius": "6"}},
    {"id": 3, "class": "Menu", "name": "Menu", "parent": 2, "fields": {"anchor": "full", "padding": "6", "separation": "6", "fill": "true"}},
    {"id": 4, "class": "Button", "name": "Play", "parent": 3, "fields": {"size": "10, 30", "text": "Play"}},
    {"id": 5, "class": "Button", "name": "Options", "parent": 3, "fields": {"size": "10, 30", "text": "Options", "visible": "false"}},
    {"id": 6, "class": "Button", "name": "Quit", "parent": 3, "fields": {"size": "10, 30", "text": "Quit"}},
    {"id": 7, "class": "Label", "name": "Footer", "parent": 3, "fields": {"size": "100, 14", "font_size": "12", "align": "center", "text": "v1.0"}},
    {"id": 8, "class": "HBox", "name": "Toolbar", "parent": 1, "fields": {"anchor": "top_right", "offset": "-8, 8", "size": "120, 30", "separation": "4"}},
    {"id": 9, "class": "Panel", "name": "Red", "parent": 8, "fields": {"size": "24, 24", "color": "RED"}},
    {"id": 10, "class": "Panel", "name": "Green", "parent": 8, "fields": {"size": "24, 30", "color": "GREEN"}},
    {"id": 11, "class": "Panel", "name": "Blue", "parent": 8, "fields": {"size": "40, 24", "color": "BLUE"}},
]
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
json.dump({"format": "c-bricks-scene", "version": 4, "next_id": 12, "objects": objs}, open(os.path.join(D, "main.cbscene"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="Containers"\nversion="1.0"\n')
# Quit's place: MenuBack at (10, 35) 152 x 130 (left: middle of 200 high); Menu fills it; padding 6:
# Play at y 41 (30 high), Options hidden (no room), Quit at y 41 + 30 + 6 = 77 .. 107, x 16 .. 156.
open(os.path.join(D, "case.cfg"), "w").write("""; VBox / HBox (tests/make_world_cases.py: change it there): a Menu (a class extending VBox) lays out
; Play, a hidden Options (no room), Quit and a Label, stretched across (fill), 6 apart, 6 in; the click at
; Quit's computed place (86, 92) clicks Quit; an HBox of three squares top-right, each its own size.
; ui_containers.png (look at it).
[case]
args="--click 86:92:0.2"
expect_order=["[menu] a Menu (a VBox of the project's own) was made", "[clicked] Quit"]
expect_missing=["[clicked] Play", "[clicked] Options"]
""")
print("wrote tests/cases/ui_containers")


# ------------------------------------------------------------------ pause
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "pause")
os.makedirs(os.path.join(D, "scripts"), exist_ok=True)
def script(path, build, always=False):
    global nodes
    nodes = []
    build()
    g = {"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}
    if always:
        g["always"] = True
    json.dump(g, open(os.path.join(D, path), "w"), indent="\t")
def counter_class(name):
    def build():
        b("class", {"name": name, "extends": "Node", "fields": [["ticks", "int"]], "synced": ""})
        ef = b("every_frame")
        link(ef, "out", [b("var", {"mode": "Add", "name": "ticks"}, {"value": I(1)})])
    return build
script("scripts/ticker.cbricks", counter_class("Ticker"))
script("scripts/spinner.cbricks", counter_class("Spinner"), always=True)
def frame_counter(var):
    def build():
        init = b("function", {"name": "reset_" + var, "returns": "void", "params": []})  # (declares the Shared counter)
        link(init, "out", [b("var", {"mode": "Set", "name": var, "scope": "Shared"}, {"value": I(0)})])
        fs = b("frame_start")
        link(fs, "out", [b("var", {"mode": "Add", "name": var}, {"value": I(1)})])
        fn = b("function", {"name": "get_" + var, "returns": "int", "params": []})
        link(fn, "out", [b("return", {"gives": "A value"}, {"value": V(var)})])
    return build
script("scripts/plain.cbricks", frame_counter("plain_n"))
script("scripts/steady.cbricks", frame_counter("steady_n"), always=True)
nodes = []
st = b("start")
seq = [b("window", {}, {"width": I(160), "height": I(120), "title": S("pause"), "fps": I(60)}),
       b("new_object", {"of": "Ticker", "world": True}, {}, {"object": "tick"}),
       b("new_object", {"of": "Spinner", "world": True}, {}, {"object": "spin"}),
       b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)}),
       b("var", {"mode": "Set", "name": "world_t"}, {"value": F(0)}),
       b("game_loop")]
for a_, c_ in zip(seq, seq[1:]):
    link(a_, "next", [c_])
link(st, "out", [seq[0]])
gl = seq[-1]
fr = [b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)}), b("game_info", {"what": "Frame time"}, {}, {"result": "dt"}), b("var", {"mode": "Add", "name": "world_t"}, {"value": V("dt")})]
def at_frame(n, chain):
    i = b("if", {"operator": "=="}, {"a": V("frames"), "b": I(n)})
    for a_, c_ in zip(chain, chain[1:]):
        link(a_, "next", [c_])
    link(i, "true", [chain[0]])
    fr.append(i)
def snap(tag):
    return [b("field", {"mode": "Get", "field": "ticks"}, {"record": V("tick")}, {"value": "t_" + tag}),
            b("field", {"mode": "Get", "field": "ticks"}, {"record": V("spin")}, {"value": "s_" + tag}),
            b("call", {"function": "get_plain_n"}, {}, {"result": "p_" + tag}),
            b("call", {"function": "get_steady_n"}, {}, {"result": "q_" + tag})]
def say(fmt, *vals):
    args = {k: v for k, v in zip(["first", "second", "third", "fourth"], vals)}
    t = b("text", {"op": "Format", "format": fmt}, args, {"result": "line%d" % len(nodes)})
    return [t, b("print", {"newline": True}, {"value": V("line%d" % (len(nodes) - 1))})]
at_frame(5, snap("a") + [b("pause", {"do": "Pause"})])
at_frame(15, snap("b") + [b("formula", {"expression": "t_b == t_a && p_b == p_a", "type": "bool"}, {}, {"result": "stopped"}),
                          b("formula", {"expression": "s_b > s_a + 5 && q_b > q_a + 5", "type": "bool"}, {}, {"result": "went_on"}),
                          b("pause", {"do": "Is paused"}, {}, {"result": "is_p"})]
          + say("[pause] stopped (Every frame, When frame starts): {}; Runs while paused went on: {}; Paused? {}; frame time {}", V("stopped"), V("went_on"), V("is_p"), V("dt"))
          + [b("pause", {"do": "Resume"})])
at_frame(25, snap("c") + [b("formula", {"expression": "t_c > t_b + 5 && p_c > p_b + 5", "type": "bool"}, {}, {"result": "moving"})]
          + say("[pause] resumed: the world moves again: {}", V("moving"))
          + [b("pause", {"do": "Set time scale"}, {"scale": F(0.5)}), b("game_info", {"what": "Time"}, {}, {"result": "real0"}), b("var", {"mode": "Set", "name": "world0"}, {"value": V("world_t")})])
at_frame(85, [b("game_info", {"what": "Time"}, {}, {"result": "real1"}),
              b("formula", {"expression": "(world_t - world0) / (real1 - real0)", "type": "float"}, {}, {"result": "ratio"}),
              b("formula", {"expression": "ratio > 0.4 && ratio < 0.6", "type": "bool"}, {}, {"result": "half"})]
          + say("[scale] time scale 0.5: the world's time runs at half speed: {}", V("half")) + [b("close_window")])
for a_, c_ in zip(fr, fr[1:]):
    link(a_, "next", [c_])
link(gl, "frame", [fr[0]])
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="Pause"\nversion="1.0"\n')
open(os.path.join(D, "case.cfg"), "w").write("""; Pause game, offline (tests/make_world_cases.py: change it there): paused at frame 5, the world stops
; (a Ticker's Every frame, a plain script's When frame starts; frame time 0) but not what Runs while paused
; (a Spinner class's and a script's), nor the Game loop's Frame chains (this one); resumed at frame 15;
; time scale 0.5 from frame 25: the world's time (Frame time added up) is half the real time.
[case]
expect_order=["[pause] stopped (Every frame, When frame starts): true; Runs while paused went on: true; Paused? true; frame time 0", "[pause] resumed: the world moves again: true", "[scale] time scale 0.5: the world's time runs at half speed: true"]
""")
print("wrote tests/cases/pause")


# ------------------------------------------------------------------ time_effects
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases", "time_effects")
os.makedirs(os.path.join(D, "scripts"), exist_ok=True)
def chain(ids):
    for a_, c_ in zip(ids, ids[1:]):
        link(a_, "next", [c_])
    return ids[0]
def build_resumer():
    # Runs while paused: after 30 paused frames it resumes (a Wait in the main chain is held until then)
    init = b("function", {"name": "reset_pn", "returns": "void", "params": []})
    link(init, "out", [b("var", {"mode": "Set", "name": "pn", "scope": "Shared"}, {"value": I(0)})])
    fs = b("frame_start")
    isp = b("pause", {"do": "Is paused"}, {}, {"result": "p"})
    pi = b("formula", {"expression": "p ? 1 : 0", "type": "int"}, {}, {"result": "pi"})
    iff = b("if", {"operator": "=="}, {"a": V("pi"), "b": I(1)})
    add = b("var", {"mode": "Add", "name": "pn"}, {"value": I(1)})
    go = b("formula", {"expression": "pn >= 30 ? 1 : 0", "type": "int"}, {}, {"result": "go"})
    iff2 = b("if", {"operator": "=="}, {"a": V("go"), "b": I(1)})
    link(iff2, "true", [chain([b("pause", {"do": "Resume"}), b("var", {"mode": "Set", "name": "pn"}, {"value": I(0)})])])
    link(fs, "out", [chain([isp, pi, iff])])
    link(iff, "true", [chain([add, go, iff2])])
script("scripts/resumer.cbricks", build_resumer, always=True)
nodes = []
st = b("start")
seq = [b("window", {}, {"width": I(160), "height": I(120), "title": S("time effects"), "fps": I(60)}),
       b("new_object", {"of": "Ticker", "world": True}, {}, {"object": "tick"}),
       b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)}),
       b("game_loop")]
Dsave = D
chain(seq)
link(st, "out", [seq[0]])
gl = seq[-1]
fr = [b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})]
def left():
    return b("formula", {"expression": "cb_shake_remaining()", "type": "float"}, {}, {"result": "left"})
def now(var):
    return b("game_info", {"what": "Time"}, {}, {"result": var})
at_frame(3, [b("shake_camera", {}, {"strength": F(0.1), "duration": F(20)})])
at_frame(5, [left(), b("var", {"mode": "Set", "name": "sa"}, {"value": V("left")}), b("pause", {"do": "Pause"})])
at_frame(15, [left(), b("var", {"mode": "Set", "name": "sb"}, {"value": V("left")}), now("r15"),
              b("formula", {"expression": "sb == sa && sa > 19", "type": "bool"}, {}, {"result": "still"}),
              b("pause", {"do": "Resume"})]
          + say("[shake] paused: the shake's time stands still: {}", V("still")))
at_frame(25, [left(), b("var", {"mode": "Set", "name": "sc"}, {"value": V("left")}), now("r25"),
              b("formula", {"expression": "(sb - sc) / (r25 - r15)", "type": "float"}, {}, {"result": "rate1"}),
              b("formula", {"expression": "rate1 > 0.7 && rate1 < 1.3", "type": "bool"}, {}, {"result": "full"})]
          + say("[shake] time scale 1: it drains at the real rate: {}", V("full"))
          + [b("pause", {"do": "Set time scale"}, {"scale": F(0.5)}), now("real0")])
at_frame(85, [left(), b("var", {"mode": "Set", "name": "sd"}, {"value": V("left")}), now("real1"),
              b("formula", {"expression": "(sc - sd) / (real1 - real0)", "type": "float"}, {}, {"result": "rate2"}),
              b("formula", {"expression": "rate2 > 0.4 && rate2 < 0.6", "type": "bool"}, {}, {"result": "half"})]
          + say("[shake] time scale 0.5: it drains at half the real rate: {}", V("half"))
          # Wait counts the world's time: 0.2 s at half speed takes about 0.4 s of the real clock
          + [now("w0"), b("wait", {}, {"seconds": F(0.2)}), now("w1"),
             b("formula", {"expression": "(w1 - w0) > 0.3 && (w1 - w0) < 0.6", "type": "bool"}, {}, {"result": "slow_wait"})]
          + say("[wait] time scale 0.5: Wait 0.2 takes about 0.4 real seconds: {}", V("slow_wait"))
          + [b("pause", {"do": "Set time scale"}, {"scale": F(1)}),
             # paused, a Wait lasts until something resumes (the resumer script does, after 30 frames);
             # Game info's Time is the real clock: it went on meanwhile
             b("pause", {"do": "Pause"}), now("p0"), b("wait", {}, {"seconds": F(0.05)}), now("p1"),
             b("pause", {"do": "Is paused"}, {}, {"result": "still_p"}),
             b("formula", {"expression": "(p1 - p0) > 0.35 && !still_p", "type": "bool"}, {}, {"result": "held"})]
          + say("[wait] paused: Wait lasts until Resume, and Time (the real clock) kept going: {}", V("held"))
          + [b("close_window")])
chain(fr)
link(gl, "frame", [fr[0]])
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
script("scripts/ticker.cbricks", counter_class("Ticker"))
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="Time effects"\nversion="1.0"\n')
open(os.path.join(D, "case.cfg"), "w").write("""; Time scale and Pause beyond Every frame (tests/make_world_cases.py: change it there): Shake Camera's
; time left stands still while paused and drains at the time scale's rate; Wait counts the world's time
; (half speed: twice as long; paused: until a script that Runs while paused resumes); Game info's Time is
; the real clock.
[case]
expect_order=["[shake] paused: the shake's time stands still: true", "[shake] time scale 1: it drains at the real rate: true", "[shake] time scale 0.5: it drains at half the real rate: true", "[wait] time scale 0.5: Wait 0.2 takes about 0.4 real seconds: true", "[wait] paused: Wait lasts until Resume, and Time (the real clock) kept going: true"]
""")
print("wrote tests/cases/time_effects")


# ------------------------------------------------------------------ dos/sound (MS-DOS only: tests/dos/, run by the runner's dos check)
import struct, math
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dos", "sound")
os.makedirs(os.path.join(D, "assets"), exist_ok=True)
def wav(rate, bits, channels, seconds, hz):
    n = int(rate * seconds)
    data = bytearray()
    for i in range(n):
        v = math.sin(2 * math.pi * hz * i / rate) * 0.6
        for c in range(channels):
            data += bytes([int(128 + v * 127)]) if bits == 8 else struct.pack("<h", int(v * 32767))
    blk = channels * bits // 8
    return b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * blk, blk, bits) + b"data" + struct.pack("<I", len(data)) + bytes(data)
open(os.path.join(D, "assets", "tone.wav"), "wb").write(wav(11025, 8, 1, 0.5, 440))      # 8-bit mono, resampled up
open(os.path.join(D, "assets", "blip.wav"), "wb").write(wav(44100, 16, 2, 0.25, 880))   # 16-bit stereo, resampled down
nodes = []
st = b("start")
seq = [b("window", {}, {"width": I(160), "height": I(120), "title": S("dos sound"), "fps": I(60)}),
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/tone.wav")}, {"music": "song"}),
       b("sound", {"mode": "Load"}, {"path": S("assets/blip.wav")}, {"sound": "blip"}),
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/missing.wav")}, {"music": "nope"}),
       # OGG and MP3 (noise.ogg, pudinha.mp3: copied from Emscripten's test sounds, MIT): converted by the editor's build, not read on DOS
       b("sound", {"mode": "Load"}, {"path": S("assets/noise.ogg")}, {"sound": "noise"}),
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/pudinha.mp3")}, {"music": "tune"}),
       b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)}),
       b("game_loop")]
chain(seq)
link(st, "out", [seq[0]])
gl = seq[-1]
fr = [b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})]
at_frame(2, [b("print", {"newline": False}, {"value": S("[load] ")}), b("print", {"newline": False}, {"value": V("song")}), b("print", {"newline": False}, {"value": S(", ")}),
             b("print", {"newline": False}, {"value": V("blip")}), b("print", {"newline": False}, {"value": S(", missing: ")}), b("print", {"newline": True}, {"value": V("nope")}),
             b("music", {"do": "Play"}, {"music": V("song")}), b("sound", {"mode": "Play"}, {"sound": V("blip")})])
at_frame(3, [b("print", {"newline": False}, {"value": S("[convert] ")}), b("print", {"newline": False}, {"value": V("noise")}), b("print", {"newline": False}, {"value": S(", ")}), b("print", {"newline": True}, {"value": V("tune")}),
             b("sound", {"mode": "Play"}, {"sound": V("noise")}), b("music", {"do": "Play"}, {"music": V("tune")})])
at_frame(10, [b("music", {"do": "Playing"}, {"music": V("song")}, {"result": "p1"})] + say("[music] playing 0.15 s in: {}", V("p1")))
at_frame(20, [b("music", {"do": "Pause"}, {"music": V("song")}), b("music", {"do": "Playing"}, {"music": V("song")}, {"result": "p2"})] + say("[music] paused: playing? {}", V("p2")))
at_frame(30, [b("music", {"do": "Resume"}, {"music": V("song")}), b("music", {"do": "Playing"}, {"music": V("song")}, {"result": "p3"})] + say("[music] resumed: playing? {}", V("p3")))
at_frame(90, [b("music", {"do": "Playing"}, {"music": V("song")}, {"result": "p4"})] + say("[music] after its 0.5 s ran out: playing? {}", V("p4")) + [b("close_window")])
chain(fr)
link(gl, "frame", [fr[0]])
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="DosSound"\nversion="1.0"\n')
print("wrote tests/dos/sound")


# ------------------------------------------------------------------ dos/fm (MS-DOS only: FM music on the OPL chip)
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dos", "fm")
os.makedirs(os.path.join(D, "assets"), exist_ok=True)
VOICE = [(0x01, 0x20), (0x20, 0x01), (0x23, 0x01), (0x40, 0x10), (0x43, 0x00), (0x60, 0xF0), (0x63, 0xF0), (0x80, 0x77), (0x83, 0x77), (0xC0, 0x01)]  # one OPL2 voice
def imf(ticks_on, ticks_off, notes):   # type 0: (register, value, delay) records at 560 Hz
    out = b""
    recs = [(r, v, 0) for r, v in VOICE]
    for lo, hi in notes:
        recs += [(0xA0, lo, 0), (0xB0, hi, ticks_on), (0xB0, hi & ~0x20, ticks_off)]
    for r, v, d in recs:
        out += struct.pack("<BBH", r, v, d)
    return b"\x00\x00\x00\x00" + out
open(os.path.join(D, "assets", "song.imf"), "wb").write(imf(224, 112, [(0x44, 0x32), (0x8B, 0x32)]))         # 2 x 336 ticks = 1.2 s
open(os.path.join(D, "assets", "theme.imf"), "wb").write(imf(224, 112, [(0x44, 0x32), (0x8B, 0x32)]))        # the FM version of theme.wav (1.2 s)
open(os.path.join(D, "assets", "theme.wav"), "wb").write(wav(11025, 8, 1, 0.1, 440))                          # a 0.1 s WAV: if this plays, the FM version didn't win
def vgm():
    d = bytearray(0x100)
    d[0:4] = b"Vgm "
    struct.pack_into("<I", d, 0x08, 0x151)
    struct.pack_into("<I", d, 0x34, 0xCC)        # the data starts at 0x34 + 0xCC = 0x100
    struct.pack_into("<I", d, 0x50, 3579545)     # a YM3812's clock
    for r, v in VOICE + [(0xA0, 0x44), (0xB0, 0x32)]:
        d += bytes([0x5A, r, v])
    d += bytes([0x61]) + struct.pack("<H", 22050)   # half a second
    d += bytes([0x5A, 0xB0, 0x12, 0x61]) + struct.pack("<H", 22050) + bytes([0x66])   # key off, another half: 1.0 s
    struct.pack_into("<I", d, 0x04, len(d) - 4)
    return bytes(d)
open(os.path.join(D, "assets", "tune.vgm"), "wb").write(vgm())
def dro2():   # DOSBox raw OPL v2.0: pairs of (index, value), a codemap, short / long delay codes
    cm = [0x20, 0x23, 0x40, 0x43, 0x60, 0x63, 0x80, 0x83, 0xA0, 0xB0, 0xC0, 0x01]
    idx = {r: i for i, r in enumerate(cm)}
    pairs = [(idx[r], v) for r, v in VOICE] + [(idx[0xA0], 0x44), (idx[0xB0], 0x32), (0x7F, 2), (0x7E, 31), (idx[0xB0], 0x12)]   # long delay 3 x 256 ms + short 32 ms = 800 ms
    d = b"DBRAWOPL" + struct.pack("<HH", 2, 0) + struct.pack("<II", len(pairs), 800) + bytes([0, 0, 0, 0x7E, 0x7F, len(cm)]) + bytes(cm)
    for i, v in pairs:
        d += bytes([i, v])
    return d
open(os.path.join(D, "assets", "box.dro"), "wb").write(dro2())
nodes = []
st = b("start")
seq = [b("window", {}, {"width": I(160), "height": I(120), "title": S("dos fm"), "fps": I(60)}),
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/theme.wav")}, {"music": "theme"}),   # its FM version plays
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/song.imf")}, {"music": "imf"}),
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/tune.vgm")}, {"music": "vgm"}),
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/box.dro")}, {"music": "dro"}),
       b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)}),
       b("game_loop")]
chain(seq)
link(st, "out", [seq[0]])
gl = seq[-1]
fr = [b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})]
def p(*parts):
    out = []
    for i, x in enumerate(parts):
        out.append(b("print", {"newline": i == len(parts) - 1}, {"value": x}))
    return out
at_frame(2, p(S("[fm] theme.wav (its FM version): "), V("theme")) + p(S("[fm] song.imf: "), V("imf")) + p(S("[fm] tune.vgm: "), V("vgm")) + p(S("[fm] box.dro: "), V("dro"))
             + [b("music", {"do": "Play"}, {"music": V("theme")})])
at_frame(10, [b("music", {"do": "Playing"}, {"music": V("theme")}, {"result": "p1"})] + say("[fm] playing: {}", V("p1")))
at_frame(20, [b("music", {"do": "Pause"}, {"music": V("theme")}), b("music", {"do": "Playing"}, {"music": V("theme")}, {"result": "p2"})] + say("[fm] paused: playing? {}", V("p2")))
at_frame(30, [b("music", {"do": "Resume"}, {"music": V("theme")}), b("music", {"do": "Volume"}, {"music": V("theme"), "volume": F(0.5)}), b("music", {"do": "Playing"}, {"music": V("theme")}, {"result": "p3"})] + say("[fm] resumed, volume 0.5: playing? {}", V("p3"))
          + [b("music", {"do": "Play"}, {"music": V("vgm")})])
at_frame(150, [b("music", {"do": "Playing"}, {"music": V("theme")}, {"result": "p4"}), b("music", {"do": "Playing"}, {"music": V("vgm")}, {"result": "p5"})] + say("[fm] later: theme (stopped by the next song) playing? {}, vgm playing? {}", V("p4"), V("p5")) + [b("close_window")])
chain(fr)
link(gl, "frame", [fr[0]])
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="DosFm"\nversion="1.0"\n')
print("wrote tests/dos/fm")


# ------------------------------------------------------------------ dos/midi (MS-DOS only: a MIDI file played on the OPL chip with DMXOPL's bank)
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dos", "midi")
os.makedirs(os.path.join(D, "assets"), exist_ok=True)
def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    return bytes(reversed(out))
def midi():   # format 0, 480 ticks a quarter, 120 bpm: a chord, a bass note, a drum beat, a bend; the last event at 1920 ticks = 2.0 s
    ev = []   # (tick, bytes)
    ev.append((0, bytes([0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])))
    ev.append((0, bytes([0xC0, 0])))            # channel 1: piano
    ev.append((0, bytes([0xC1, 33])))           # channel 2: an electric bass
    for n in (60, 64, 67):
        ev.append((0, bytes([0x90, n, 96])))
        ev.append((960, bytes([0x80, n, 0])))
    ev.append((480, bytes([0xE0, 0x00, 0x50])))  # a bend up on channel 1
    ev.append((0, bytes([0x91, 36, 110])))
    ev.append((1920, bytes([0x81, 36, 0])))
    for t, n in ((0, 36), (480, 38), (960, 36), (1440, 38)):
        ev.append((t, bytes([0x99, n, 100])))
        ev.append((t + 120, bytes([0x89, n, 0])))
    ev.sort(key=lambda e: e[0])
    trk = b""
    last = 0
    for t, e in ev:
        trk += vlq(t - last) + e
        last = t
    trk += vlq(0) + bytes([0xFF, 0x2F, 0x00])
    return b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(trk)) + trk
open(os.path.join(D, "assets", "march.mid"), "wb").write(midi())
nodes = []
st = b("start")
seq = [b("window", {}, {"width": I(160), "height": I(120), "title": S("dos midi"), "fps": I(60)}),
       b("music", {"do": "Load", "loop": False}, {"path": S("assets/march.mid")}, {"music": "march"}),
       b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)}),
       b("game_loop")]
chain(seq)
link(st, "out", [seq[0]])
gl = seq[-1]
fr = [b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)})]
at_frame(2, p(S("[midi] march.mid: "), V("march")) + [b("music", {"do": "Play"}, {"music": V("march")})])
at_frame(20, [b("music", {"do": "Playing"}, {"music": V("march")}, {"result": "p1"})] + say("[midi] playing: {}", V("p1")))
at_frame(200, [b("music", {"do": "Playing"}, {"music": V("march")}, {"result": "p2"})] + say("[midi] after its 2 s: playing? {}", V("p2")) + [b("close_window")])
chain(fr)
link(gl, "frame", [fr[0]])
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="DosMidi"\nversion="1.0"\n')
print("wrote tests/dos/midi")


# ------------------------------------------------------------------ dos/input (MS-DOS only: the keyboard and mouse as DOSBox-X's window sends them)
# The runner's dos check starts this under a private Xvfb display with SDL's X11 driver and sends real key and
# mouse events with xdotool; the program prints one line a frame: "[in] A SPACE-pressed SPACE-released UP ENTER
# SHIFT F5 CTRL mouse-left mouse-clicked mouse-right x y wheel", and closes on Q.
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dos", "input")
os.makedirs(D, exist_ok=True)
nodes = []
st = b("start")
KEYS = [("Key down", "A"), ("Key pressed", "SPACE"), ("Key released", "SPACE"), ("Key down", "UP"), ("Key down", "ENTER"), ("Key down", "LEFT_SHIFT"),
        ("Key down", "F5"), ("Key down", "LEFT_CONTROL"), ("Mouse down", "LEFT"), ("Mouse pressed", "LEFT"), ("Mouse down", "RIGHT")]
seq = [b("window", {}, {"width": I(320), "height": I(200), "title": S("dos input"), "fps": I(60)}), b("game_loop")]
chain(seq)
link(st, "out", [seq[0]])
gl = seq[-1]
fr = []
for i, (when, key) in enumerate(KEYS):
    fr.append(b("input", {"when": when, "key": key, "button": key}, {}, {"result": "k%d" % i}))
fr.append(b("mouse", {"what": "Position"}, {}, {"x": "mx", "y": "my"}))
fr.append(b("mouse", {"what": "Wheel"}, {}, {"x": "wheel"}))
fr.append(b("input", {"when": "Key pressed", "key": "Q"}, {}, {"result": "quit"}))
fr.append(b("print", {"newline": False}, {"value": S("[in]")}))
for i in range(len(KEYS)):
    fr.append(b("text", {"op": "Format", "format": " {}"}, {"first": V("k%d" % i)}, {"result": "t%d" % i}))
    fr.append(b("print", {"newline": False}, {"value": V("t%d" % i)}))
fr.append(b("text", {"op": "Format", "format": " {} {} {}"}, {"first": V("mx"), "second": V("my"), "third": V("wheel")}, {"result": "tm"}))
fr.append(b("print", {"newline": True}, {"value": V("tm")}))
fr.append(b("if", {"operator": "=="}, {"a": V("quit"), "b": {"type": "bool", "value": "true"}}))
chain(fr[:-1])
link(fr[-2], "next", [fr[-1]])
link(fr[-1], "true", [b("close_window")])
link(gl, "frame", [fr[0]])
json.dump({"format": "c-bricks", "version": 4, "next_id": len(nodes) + 1, "nodes": nodes}, open(os.path.join(D, "main.cbricks"), "w"), indent="\t")
open(os.path.join(D, "project.cbproj"), "w").write('[project]\n\nname="DosInput"\nversion="1.0"\n')
print("wrote tests/dos/input")
