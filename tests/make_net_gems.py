# Generates examples/net_gems (a network game: 2-4 players collect gems in one arena) and
# its test copy: python3 tests/make_net_gems.py <out dir> [auto]
#   examples/net_gems                 the example (then laid out: tests/layout_example.gd -- net_gems)
#   tests/cases/net_gems_auto auto    + gems in a row in player 2's lane, 3 gems win, respawns in
#                                       a corner, screenshots of each client at the end
# Offline it's single-player (H hosts on port 7000, J joins 127.0.0.1:7000); or run it with
# --host 7000, --server 7000 (no window) and --join 127.0.0.1:7000 --name ada.
# Every part of stage 3: the do-it-yourself starter player (the server's Player Joined
# instances scenes/hero.cbscene, Give To; its Client script greets on the owner's machine), Player Direction (blank: the Runner's owner),
# the world copied to players (Synced score), remotes (picked, winner: Fire Clients ->
# On Server Fired), Player Left, Mine-style "my runner" (Me), a HUD of UI nodes (a Panel, Labels).
import json, sys, os
out_dir = sys.argv[1]
auto = len(sys.argv) > 2
V = lambda v: {"var": v}; I = lambda x: {"type": "int", "value": str(x)}; F = lambda x: {"type": "float", "value": str(x)}
S = lambda x: {"type": "string", "value": x}; B = lambda x: {"type": "bool", "value": x}; V3 = lambda x: {"type": "vector3", "value": x}
E = lambda t, x: {"type": t, "value": x}  # an expression typed in
NONE = {"var": ""}
WIN = 3 if auto else 10


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


class G:
    def __init__(self): self.nodes = []; self.n = 0
    def add(self, t, fields=None, args=None, outs=None, links=None, note=None):
        self.n += 1
        d = {"id": self.n, "type": t, "pos": [0, 0], "size": [0, 0], "fields": fields or {}, "args": args or {},
             "outs": {k: {"var": v, "use": False} for k, v in (outs or {}).items()}, "links": links or {}}
        if note: d["note"] = note
        self.nodes.append(d); return self.n
    def link(self, i, group, ids): next(x for x in self.nodes if x["id"] == i)["links"][group] = ids
    def chain(self, ids):
        for a, b in zip(ids, ids[1:]):
            t = next(x for x in self.nodes if x["id"] == a)["type"]
            self.link(a, "done" if t in ["for", "for_each", "while", "repeat"] else "next", [b])  # (a loop goes on from Done)
        return ids[0]
    def dump(self, rel, side=None):
        g = {"format": "c-bricks", "version": 4, "next_id": self.n + 1, "nodes": self.nodes}
        if side: g["side"] = side
        path = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(g, open(path, "w"), indent="\t")


def say(g, fmt, *values):
    args = {k: v for k, v in zip(["first", "second", "third", "fourth"], values)}
    line = "line_%d" % (g.n + 1)
    return [g.add("text", {"op": "Format", "format": fmt}, args, {"result": line}), g.add("print", {"newline": True}, {"value": V(line)})]


# ---- remotes: the server tells everyone who picked a gem, and who won
r = G()
r.add("remote", {"name": "picked", "direction": "To clients", "values": [["who", "int"], ["score", "int"]]}, note="A gem was picked up: by whom, their score now")
r.add("remote", {"name": "winner", "direction": "To clients", "values": [["who", "int"]]}, note="Someone reached %d gems: the scores start again" % WIN)
r.dump("scripts/remotes.cbricks")

# ---- Runner: a player's piece. The server moves it with its owner's keys (Player Direction).
ru = G()
ru.add("class", {"name": "Runner", "extends": "Shape3D", "fields": [["speed", "float"], ["score", "int"]], "synced": "score"},
       note="A player's runner: scenes/hero.cbscene's root (the server makes one for each player in Player Joined and gives it to them). Its score is Synced: every machine sees it")
cr = ru.add("created")
ru.link(cr, "out", [ru.chain([ru.add("var", {"mode": "Set", "name": "speed"}, {"value": F(6)}),
                              ru.add("var", {"mode": "Set", "name": "size"}, {"value": V3("0.8, 1.6, 0.8")}),
                              ru.add("var", {"mode": "Set", "name": "shape"}, {"value": S("Cylinder")})])])
ef = ru.add("every_frame", note="On the server only (players' machines get its position)")
dr = ru.add("player_input", {"what": "Direction"}, {"player": NONE}, {"result": "dir"}, note="Blank Player: this runner's owner")
sp = ru.add("vector", {"op": "Split", "dims": "2D"}, {"a": V("dir")}, {"x": "dx", "y": "dz"})
mv = ru.add("vector", {"op": "Make"}, {"x": E("float", "dx * speed * dt"), "y": F(0), "z": E("float", "dz * speed * dt")}, {"result": "step"})
ad = ru.add("var", {"mode": "Add", "name": "position"}, {"value": V("step")})
sp2 = ru.add("vector", {"op": "Split"}, {"a": V("position")}, {"x": "px", "y": "py", "z": "pz"}, note="Stay inside the walls")
cl = ru.add("vector", {"op": "Make"}, {"x": E("float", "fmax(-9.2, fmin(9.2, px))"), "y": V("py"), "z": E("float", "fmax(-9.2, fmin(9.2, pz))")}, {"result": "position"})
ru.link(ef, "out", [ru.chain([dr, sp, mv, ad, sp2, cl])])
ru.dump("scripts/runner.cbricks")

# ---- Gem: spins; a Runner touching it scores, everyone's told; the first to WIN wins
g = G()
g.add("class", {"name": "Gem", "extends": "Shape3D", "fields": [], "synced": ""}, note="A gem: the server makes them, players' machines see them")
cr = g.add("created")
g.link(cr, "out", [g.chain([g.add("var", {"mode": "Set", "name": "color"}, {"value": S("#40e0ff")}),
                            g.add("var", {"mode": "Set", "name": "size"}, {"value": V3("0.5")}),
                            g.add("var", {"mode": "Set", "name": "rotation"}, {"value": V3("45, 0, 45")})])])
ef = g.add("every_frame")
g.link(ef, "out", [g.add("var", {"mode": "Add", "name": "rotation"}, {"value": V3("0, 120 * dt, 0")})])
tc = g.add("touched", note="On the server: other is what touched this gem")
asr = g.add("object", {"op": "As", "of": "Runner"}, {"object": V("other")}, {"result": "runner"})
ok = g.add("object", {"op": "Exists"}, {"object": V("runner")}, {"result": "by_runner"})
cond = g.add("if", {"operator": "is true"}, {"a": V("by_runner")})
gs = g.add("field", {"mode": "Get", "field": "score"}, {"record": V("runner")}, {"value": "score"})
inc = g.add("math", {"op": "Add"}, {"a": V("score"), "b": I(1)}, {"result": "score"})
ss = g.add("field", {"mode": "Set", "field": "score"}, {"record": V("runner"), "value": V("score")})
own = g.add("ownership", {"do": "Owner"}, {"object": V("runner")}, {"result": "who"})
fp = g.add("fire_clients", {"remote": "picked", "to": "All"}, {"who": V("who"), "score": V("score")})
won = g.add("if", {"operator": ">="}, {"a": V("score"), "b": I(WIN)}, note="A winner: tell everyone, start again")
wn = g.add("player", {"op": "Name"}, {"player": V("who")}, {"result": "wname"})
fw = g.add("fire_clients", {"remote": "winner", "to": "All"}, {"who": V("who")})
everyone = g.add("player", {"op": "Players"}, {}, {"result": "everyone"})
each = g.add("for_each", {}, {"list": V("everyone")}, {"item": "p"})
pn = g.add("player", {"op": "Name"}, {"player": V("p")}, {"result": "pname"})
fr = g.add("object", {"op": "Find", "of": "Runner"}, {"name": V("pname")}, {"result": "theirs"})
fe = g.add("object", {"op": "Exists"}, {"object": V("theirs")}, {"result": "has_runner"})
fi = g.add("if", {"operator": "is true"}, {"a": V("has_runner")})
g.link(fi, "true", [g.add("field", {"mode": "Set", "field": "score"}, {"record": V("theirs"), "value": I(0)})])
g.link(each, "loop", [g.chain([pn, fr, fe, fi])])
g.link(won, "true", [g.chain([wn] + say(g, "[server] {} wins", V("wname")) + [fw, everyone, each])])
if auto:
    jump = [g.add("var", {"mode": "Set", "name": "position"}, {"value": V3("-8, 0.8, 8")}, note="(the test: a corner nobody goes to)")]
else:
    jump = [g.add("random", {}, {"min": I(-8), "max": I(8)}, {"result": "rx"}),
            g.add("random", {}, {"min": I(-8), "max": I(8)}, {"result": "rz"}),
            g.add("vector", {"op": "Make"}, {"x": V("rx"), "y": F(0.8), "z": V("rz")}, {"result": "position"}, note="Jump somewhere else")]
g.link(cond, "true", [g.chain([gs, inc, ss, own, fp, won] + jump)])
g.link(tc, "out", [g.chain([asr, ok, cond])])
g.dump("scripts/gem.cbricks")

# ---- the Hero scene's Client script: a welcome on its owner's machine (the do-it-yourself starter player)
wl = G()
st = wl.add("start", note="In the Hero scene: runs on the machine of the player it's given to")
nm = wl.add("player", {"op": "Name"}, {}, {"result": "me"}, note="Blank Player: the owner of the Runner it's in")
wl.link(st, "out", [wl.chain([nm] + say(wl, "Welcome, {}! WASD to run, collect %d gems to win." % WIN, V("me")))])
wl.dump("scripts/welcome.cbricks", "Client")

# ---- players' machines: what the server tells them
ev = G()
pk = ev.add("on_server_fired", {"remote": "picked"})
pn = ev.add("player", {"op": "Name"}, {"player": V("who")}, {"result": "pname"})
ev.link(pk, "out", [ev.chain([pn] + say(ev, "[picked] {} has {} gems", V("pname"), V("score")))])
wi = ev.add("on_server_fired", {"remote": "winner"})
wn = ev.add("player", {"op": "Name"}, {"player": V("who")}, {"result": "wname"})
banner = ev.add("object", {"op": "Find", "of": "Label"}, {"name": S("Banner")}, {"result": "banner"})
bt = ev.add("text", {"op": "Format", "format": "{} wins! Again..."}, {"first": V("wname")}, {"result": "btext"})
bs = ev.add("field", {"mode": "Set", "field": "text"}, {"record": V("banner"), "value": V("btext")})
ev.link(wi, "out", [ev.chain([wn, banner, bt, bs] + say(ev, "[winner] {} wins!", V("wname")))])
ev.dump("scripts/events.cbricks", "Client")

# ---- the server's rules: players coming and going
rl = G()
pj = rl.add("player_joined", note="Each player gets a Hero (the do-it-yourself starter player): the scene's Runner, theirs")
mk = rl.add("scene", {"do": "Instance", "scene": "scenes/hero.cbscene"}, {"parent": NONE}, {"root": "runner"})
pn = rl.add("player", {"op": "Name"}, {"player": V("player")}, {"result": "pname"})
sn = rl.add("object", {"op": "Set name"}, {"object": V("runner"), "name": V("pname")})
gv = rl.add("ownership", {"do": "Give to"}, {"object": V("runner"), "player": V("player")}, note="Theirs: Player Direction reads their keys; the scene's Welcome runs on their machine")
lane = rl.add("vector", {"op": "Make"}, {"x": F(-6), "y": F(0.8), "z": E("float", "-6.0 + 3.0 * (player % 5)")}, {"result": "spot"}, note="A lane each (players are numbers)")
pos = rl.add("field", {"mode": "Set", "field": "position"}, {"record": V("runner"), "value": V("spot")})
cols = rl.add("list", {"op": "Make", "of": "string"}, {}, {"result": "colors"})
adds = [rl.add("list", {"op": "Add"}, {"list": V("colors"), "value": S(c)}) for c in ["#1e88e5", "#e53935", "#fdd835", "#8e24aa", "#fb8c00"]]
pick = rl.add("list", {"op": "Get"}, {"list": V("colors"), "index": E("int", "(player - 1) % 5")}, {"result": "color"})
col = rl.add("field", {"mode": "Set", "field": "color"}, {"record": V("runner"), "value": V("color")})
rl.link(pj, "out", [rl.chain([mk, pn, sn, gv, lane, pos, cols] + adds + [pick, col] + say(rl, "[server] a runner for {}", V("pname")) + say(rl, "[server] {} joined", V("pname")))])
pl = rl.add("player_left", note="What they own goes with them")
pn = rl.add("player", {"op": "Name"}, {"player": V("player")}, {"result": "pname"})
ob = rl.add("ownership", {"do": "Owned by"}, {"player": V("player")}, {"result": "theirs"})
each = rl.add("for_each", {}, {"list": V("theirs")}, {"item": "thing"})
rl.link(each, "loop", [rl.add("destroy", {}, {"object": V("thing")})])
rl.link(pl, "out", [rl.chain([pn, ob, each] + say(rl, "[server] {} left", V("pname")))])
rl.dump("scripts/rules.cbricks", "Server")

# ---- main: the window, the gems (where the rules run), each machine's camera and HUD
m = G()
st = m.add("start")
win = m.add("window", {}, {"width": I(960), "height": I(540), "title": S("Net Gems"), "fps": I(60)})
qa_t = m.add("args", {"what": "Option"}, {"name": S("quit-after")}, {"result": "qa_text"}, note="--quit-after N: stop after N seconds (tests)")
qa = m.add("text", {"op": "To float"}, {"text": V("qa_text")}, {"result": "quit_after"})
rules = m.add("network", {"do": "Is server"}, {}, {"result": "rules"})
rif = m.add("if", {"operator": "is true"}, {"a": V("rules")}, note="Where the rules run: the gems")
loop = m.add("for", {}, {"from": I(0), "to": I(5 if auto else 7), "step": I(1)}, {"index": "i"})
gem = m.add("new_object", {"of": "Gem", "world": True}, {}, {"object": "gem"})
if auto:
    spot = [m.add("vector", {"op": "Make"}, {"x": E("float", "i + 2.0"), "y": F(0.8), "z": F(0)}, {"result": "spot"}, note="(the test: in a row in player 2's lane)")]
else:
    spot = [m.add("random", {}, {"min": I(-8), "max": I(8)}, {"result": "rx"}),
            m.add("random", {}, {"min": I(-8), "max": I(8)}, {"result": "rz"}),
            m.add("vector", {"op": "Make"}, {"x": V("rx"), "y": F(0.8), "z": V("rz")}, {"result": "spot"})]
setp = m.add("field", {"mode": "Set", "field": "position"}, {"record": V("gem"), "value": V("spot")})
m.link(loop, "loop", [m.chain([gem] + spot + [setp])])
m.link(rif, "true", [loop])
gl = m.add("game_loop", note="The world runs itself; each frame: this machine's camera and HUD")
m.link(st, "out", [m.chain([win, qa_t, qa, rules, rif, gl])])
# frame: the role, H / J offline, this machine's camera and HUD
frame = []
role = m.add("network", {"do": "Role"}, {}, {"result": "role"})
frame.append(role)
off = m.add("if", {"operator": "=="}, {"a": V("role"), "b": S("offline")}, note="Single-player: H hosts, J joins")
kh = m.add("input", {"when": "Key pressed", "key": "H"}, {}, {"result": "host_key"})
hif = m.add("if", {"operator": "is true"}, {"a": V("host_key")})
m.link(hif, "true", [m.chain([m.add("network", {"do": "Host"}, {"port": I(7000)}, {"result": "hosted"})] + say(m, "Hosting on port 7000: {}", V("hosted")))])
kj = m.add("input", {"when": "Key pressed", "key": "J"}, {}, {"result": "join_key"})
jif = m.add("if", {"operator": "is true"}, {"a": V("join_key")})
m.link(jif, "true", [m.chain([m.add("network", {"do": "Join"}, {"address": S("127.0.0.1"), "port": I(7000), "timeout": F(3)}, {"result": "joined"})] + say(m, "Joined 127.0.0.1:7000: {}", V("joined")))])
m.link(off, "true", [m.chain([kh, hif, kj, jif])])
frame.append(off)
player_side = m.add("if", {"operator": "!="}, {"a": V("role"), "b": S("server")}, note="A player's machine (not a dedicated server)")
me = m.add("player", {"op": "Me"}, {}, {"result": "me"})
mname = m.add("player", {"op": "Name"}, {"player": V("me")}, {"result": "mname"})
mine = m.add("object", {"op": "Find", "of": "Runner"}, {"name": V("mname")}, {"result": "mine"})
has = m.add("object", {"op": "Exists"}, {"object": V("mine")}, {"result": "has_mine"})
follow = m.add("if", {"operator": "is true"}, {"a": V("has_mine")}, note="The camera follows my runner")
cam = m.add("object", {"op": "Find", "of": "Camera3D"}, {"name": S("Camera")}, {"result": "cam"})
mp = m.add("field", {"mode": "Get", "field": "position"}, {"record": V("mine")}, {"value": "mpos"})
eye = m.add("vector", {"op": "Add"}, {"a": V("mpos"), "b": V3("0, 9, 10")}, {"result": "eye"})
ce = m.add("field", {"mode": "Set", "field": "position"}, {"record": V("cam"), "value": V("eye")})
ct = m.add("field", {"mode": "Set", "field": "target"}, {"record": V("cam"), "value": V("mpos")})
m.link(follow, "true", [m.chain([cam, mp, eye, ce, ct])])
text0 = m.add("var", {"mode": "Set", "name": "scores"}, {"value": S("")}, note="Everyone's score")
everyone = m.add("player", {"op": "Players"}, {}, {"result": "everyone"})
each = m.add("for_each", {}, {"list": V("everyone")}, {"item": "p"})
pn = m.add("player", {"op": "Name"}, {"player": V("p")}, {"result": "pname"})
fr = m.add("object", {"op": "Find", "of": "Runner"}, {"name": V("pname")}, {"result": "theirs"})
fe = m.add("object", {"op": "Exists"}, {"object": V("theirs")}, {"result": "has_theirs"})
fi = m.add("if", {"operator": "is true"}, {"a": V("has_theirs")})
sc = m.add("field", {"mode": "Get", "field": "score"}, {"record": V("theirs")}, {"value": "their_score"})
part = m.add("text", {"op": "Format", "format": "{}: {}    "}, {"first": V("pname"), "second": V("their_score")}, {"result": "part"})
addp = m.add("var", {"mode": "Add", "name": "scores"}, {"value": V("part")})
m.link(fi, "true", [m.chain([sc, part, addp])])
m.link(each, "loop", [m.chain([pn, fr, fe, fi])])
hint = m.add("var", {"mode": "Set", "name": "hint"}, {"value": S("")})
hif2 = m.add("if", {"operator": "=="}, {"a": V("role"), "b": S("offline")})
m.link(hif2, "true", [m.add("var", {"mode": "Set", "name": "hint"}, {"value": S("   (H: host, J: join)")})])
hud = m.add("object", {"op": "Find", "of": "Label"}, {"name": S("Hud")}, {"result": "hud"})
line = m.add("text", {"op": "Format", "format": "Gems  {}{}"}, {"first": V("scores"), "second": V("hint")}, {"result": "hud_text"})
seth = m.add("field", {"mode": "Set", "field": "text"}, {"record": V("hud"), "value": V("hud_text")})
m.link(player_side, "true", [m.chain([me, mname, mine, has, follow, text0, everyone, each, hint, hif2, hud, line, seth])])
frame.append(player_side)
t = m.add("game_info", {"what": "Time"}, {}, {"result": "t"})
qend = m.add("formula", {"type": "bool", "expression": "quit_after > 0 && t > quit_after"}, {}, {"result": "done"})
qif = m.add("if", {"operator": "is true"}, {"a": V("done")})
ending = say(m, "[final] {}: {}", V("role"), V("scores"))
if auto:
    shot = m.add("text", {"op": "Format", "format": "net_gems_{}.png"}, {"first": V("mname")}, {"result": "shot"})
    raw = m.add("raw_c", {"code": "if (strcmp(role, \"server\") != 0) cb_screenshot(shot);"})
    ending = [shot, raw] + ending
m.link(qif, "true", [m.chain(ending + [m.add("quit", {}, {"code": I(0)})])])
frame += [t, qend, qif]
m.link(gl, "frame", [m.chain(frame)])
m.dump("main.cbricks")

scene = {"format": "c-bricks-scene", "version": 4, "next_id": 20, "objects": [
    {"id": 1, "class": "Camera3D", "name": "Camera", "parent": 0, "fields": {"fov": "55", "position": "0, 16, 14"}},
    {"id": 2, "class": "Light3D", "name": "Sun", "parent": 0, "fields": {"rotation": "-55, 34, 0"}},
    {"id": 14, "class": "Environment", "name": "Environment", "parent": 0, "fields": {"sky": "#87ceeb"}},
    {"id": 3, "class": "Shape3D", "name": "Floor", "parent": 0, "fields": {"size": "20, 0.2, 20", "position": "0, -0.1, 0", "color": "#5aa846"}},
    {"id": 4, "class": "Spatial3D", "name": "Walls", "parent": 0, "fields": {}},
    {"id": 5, "class": "Shape3D", "name": "North wall", "parent": 4, "fields": {"position": "0, 0.6, -10.3", "size": "21.2, 1.6, 0.6", "color": "#a1887f"}},
    {"id": 6, "class": "Shape3D", "name": "South wall", "parent": 4, "fields": {"position": "0, 0.6, 10.3", "size": "21.2, 1.6, 0.6", "color": "#a1887f"}},
    {"id": 7, "class": "Shape3D", "name": "West wall", "parent": 4, "fields": {"position": "-10.3, 0.6, 0", "size": "0.6, 1.6, 20", "color": "#a1887f"}},
    {"id": 8, "class": "Shape3D", "name": "East wall", "parent": 4, "fields": {"position": "10.3, 0.6, 0", "size": "0.6, 1.6, 20", "color": "#a1887f"}},
    # the HUD (UI, 2026-11-07): each machine's own, in window pixels, on top
    {"id": 15, "class": "Panel", "name": "Scores", "parent": 0, "fields": {"anchor": "top_left", "offset": "12, 12", "size": "560, 40", "radius": "8", "color": "#ffffffc0"}},
    {"id": 9, "class": "Label", "name": "Hud", "parent": 15, "fields": {"anchor": "left", "offset": "12, 0", "size": "540, 24", "font_size": "24", "color": "#1b1b1b", "text": ""}},
    {"id": 10, "class": "Label", "name": "Banner", "parent": 0, "fields": {"anchor": "top", "offset": "0, 64", "size": "600, 34", "font_size": "34", "align": "center", "color": "#b8860b", "text": ""}},
]}
scene["objects"] = rooted(scene["objects"])
scene["next_id"] = max(o["id"] for o in scene["objects"]) + 1
json.dump(scene, open(os.path.join(out_dir, "main.cbscene"), "w"), indent="\t")
# The Hero scene: a player's Runner with its Client script (the do-it-yourself starter player).
os.makedirs(os.path.join(out_dir, "scenes"), exist_ok=True)
json.dump({"format": "c-bricks-scene", "version": 4, "next_id": 3, "objects": [
    {"id": 1, "class": "Runner", "name": "Runner", "parent": 0, "fields": {}},
    {"id": 2, "class": "LocalScript", "name": "Welcome", "parent": 1, "script": "scripts/welcome.cbricks", "fields": {}},
]}, open(os.path.join(out_dir, "scenes", "hero.cbscene"), "w"), indent="\t")
if os.path.exists(os.path.join(out_dir, "scripts", "spawner.cbricks")):
    os.remove(os.path.join(out_dir, "scripts", "spawner.cbricks"))
open(os.path.join(out_dir, "project.cbproj"), "w").write('[project]\n\nname="Net Gems"\nversion="1.0"\n\n[run]\n\nargs=""\n\n[build]\n\ntarget="native"\n')
if auto:
    cfg = {
        "peers": ["--server 47318 --quit-after 7.5", "--join 127.0.0.1:47318 --name ada --press D:0.5:3.5 --quit-after 3.8", "--join 127.0.0.1:47318 --name bob --quit-after 5.0", "--name solo --quit-after 1.0"],
        "peer_delay": 0.4,
        "expect_peer0_order": ["[server] a runner for ada", "[server] ada joined", "[server] a runner for bob", "[server] bob joined", "[server] ada wins"],
        "expect_peer0_contains": ["[server] ada left", "[server] bob left"],
        "expect_peer0_missing": ["Welcome"],
        "expect_peer1_order": ["Welcome, ada!", "[picked] ada has 1 gems", "[picked] ada has 2 gems", "[picked] ada has 3 gems", "[winner] ada wins!", "[picked] ada has 1 gems", "[final] client: ada: 2    bob: 0"],
        "expect_peer1_missing": ["Welcome, bob"],
        # (bob outlasts ada by 1.6 s: ada's last line still has him, his own has only himself; they
        # used to leave 0.2 s apart and the order flipped under a software-rendered display)
        "expect_peer2_order": ["Welcome, bob!", "[winner] ada wins!", "[final] client: bob: 0"],
        "expect_peer2_missing": ["Welcome, ada"],
        "expect_peer3_order": ["[server] a runner for solo", "Welcome, solo!", "[final] offline: solo: 0"],  # single-player: you're player 1, your Hero's Welcome runs here
    }
    lines = ["; examples/net_gems played by a dedicated server and two clients (port 47318; tests/make_net_gems.py",
             "; makes it: change it there): gems in a row in ada's lane, ada holds D (--press), picks 3 and wins",
             "; (winner, scores reset), picks 2 more; bob only watches. Screenshots net_gems_ada.png /",
             "; net_gems_bob.png of each client at the end (look at them).", "[case]"]
    for k, v in cfg.items():
        lines.append("%s=%s" % (k, json.dumps(v)))
    open(os.path.join(out_dir, "case.cfg"), "w").write("\n".join(lines) + "\n")
