# Generates examples/gem_hunt (objects: a world file, a Player class and a Gem class) and
# its test copies: python3 tests/make_gem_hunt.py <out dir> [test [auto]]
#   examples/gem_hunt                        the example (then laid out: tests/layout_example.gd -- gem_hunt)
#   tests/cases/gem_hunt_shot test           + a screenshot at frame 40 and a quit
#   tests/cases/gem_hunt_auto test auto      + D held, 2 s rounds, gems in a row to the right, a screenshot at frame 150
import json, sys, os
out_dir = sys.argv[1]
test = len(sys.argv) > 2
auto = len(sys.argv) > 3
V=lambda v:{"var":v}; I=lambda x:{"type":"int","value":str(x)}; F=lambda x:{"type":"float","value":str(x)}
S=lambda x:{"type":"string","value":x}; B=lambda x:{"type":"bool","value":x}; V3=lambda x:{"type":"vector3","value":x}

class G:
    def __init__(self): self.nodes=[]; self.n=0
    def add(self, t, fields=None, args=None, outs=None, links=None, note=None):
        self.n+=1
        d={"id":self.n,"type":t,"pos":[0,0],"size":[0,0],"fields":fields or {},"args":args or {},"outs":{k:{"var":v,"use":False} for k,v in (outs or {}).items()},"links":links or {}}
        if note: d["note"]=note
        self.nodes.append(d); return self.n
    def link(self, i, group, ids): next(x for x in self.nodes if x["id"]==i)["links"][group]=ids
    def dump(self, path, side=None):
        g={"format":"c-bricks","version":4,"next_id":self.n+1,"nodes":self.nodes}
        if side: g["side"]=side
        json.dump(g,open(path,"w"),indent="\t")

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

os.makedirs(os.path.join(out_dir,"scripts"),exist_ok=True)
ROUND = 2 if auto else 60

# ---- Player: moves with WASD, the camera follows, the HUD shows the score and time
p=G()
p.add("class",{"name":"Player","extends":"Shape3D","fields":[["speed","float"],["score","int"],["time_left","float"]],"synced":"score"},note="The player: a Part that moves itself")
cr=p.add("created")
p.link(cr,"out",[p.add("var",{"mode":"Set","name":"speed"},{"value":F(6)}), p.add("var",{"mode":"Set","name":"time_left"},{"value":F(ROUND)})])
ef=p.add("every_frame",note="dt: the frame's length in seconds")
body=[]
body.append(p.add("var",{"mode":"Add","name":"time_left"},{"value":{"type":"float","value":"-dt"}}))
keys=[]
for k,v in [("W","kw"),("S","ks"),("A","ka")]:
    keys.append(p.add("input",{"when":"Key down","key":k},{},{"result":v}))
keys.append(p.add("var",{"mode":"Set","name":"kd"},{"value":B("true")}) if auto else p.add("input",{"when":"Key down","key":"D"},{},{"result":"kd"}))
body+=keys
body.append(p.add("vector",{"op":"Make"},{"x":{"type":"float","value":"(kd ? 1.0 : 0.0) - (ka ? 1.0 : 0.0)"},"y":F(0),"z":{"type":"float","value":"(ks ? 1.0 : 0.0) - (kw ? 1.0 : 0.0)"}},{"result":"dir"}))
playing=p.add("if",{"operator":">"},{"a":V("time_left"),"b":F(0)})
p.link(playing,"true",[
    p.add("vector",{"op":"Normalize"},{"a":V("dir")},{"result":"dir"}),
    p.add("vector",{"op":"Scale"},{"a":V("dir"),"factor":{"type":"float","value":"speed * dt"}},{"result":"step"}),
    p.add("var",{"mode":"Add","name":"position"},{"value":V("step")}),
    p.add("vector",{"op":"Split"},{"a":V("position")},{"x":"px","y":"py","z":"pz"},note="Stay inside the walls"),
    p.add("vector",{"op":"Make"},{"x":{"type":"float","value":"fmax(-9.2, fmin(9.2, px))"},"y":V("py"),"z":{"type":"float","value":"fmax(-9.2, fmin(9.2, pz))"}},{"result":"position"}),
])
body.append(playing)
cam=p.add("object",{"op":"Find","of":"Camera3D"},{"name":S("Camera")},{"result":"cam"},note="The camera follows the player")
body.append(cam)
body.append(p.add("vector",{"op":"Add"},{"a":V("position"),"b":V3("0, 7, 9")},{"result":"eye"}))
body.append(p.add("field",{"mode":"Set","field":"position"},{"record":V("cam"),"value":V("eye")}))
body.append(p.add("field",{"mode":"Set","field":"target"},{"record":V("cam"),"value":V("position")}))
body.append(p.add("object",{"op":"Find","of":"Label"},{"name":S("Hud")},{"result":"hud"}))
body.append(p.add("formula",{"expression":"time_left > 0 ? (int)ceil(time_left) : 0","type":"int"},{},{"result":"secs"}))
over=p.add("if",{"operator":">"},{"a":V("secs"),"b":I(0)})
p.link(over,"true",[p.add("text",{"op":"Format","format":"Gems: {}     Time: {}     (WASD)"},{"first":V("score"),"second":V("secs")},{"result":"line"}),
                    p.add("field",{"mode":"Set","field":"text"},{"record":V("hud"),"value":V("line")})])
p.link(over,"false",[p.add("text",{"op":"Format","format":"Time's up! Gems: {}"},{"first":V("score")},{"result":"line"}),
                     p.add("field",{"mode":"Set","field":"text"},{"record":V("hud"),"value":V("line")})])
body.append(over)
p.link(ef,"out",body)
fn=p.add("function",{"name":"add_point","returns":"void","params":[]},note="Called by a Gem when it's picked up")
p.link(fn,"out",[p.add("var",{"mode":"Add","name":"score"},{"value":I(1)})])
p.dump(os.path.join(out_dir,"scripts/player.cbricks"))

# ---- Gem: spins; touched by the Player, gives a point and jumps elsewhere
g=G()
g.add("class",{"name":"Gem","extends":"Shape3D","fields":[],"synced":""},note="A gem: a tilted box that spins")
cr=g.add("created")
g.link(cr,"out",[g.add("var",{"mode":"Set","name":"color"},{"value":S("#40e0ff")}),
                 g.add("var",{"mode":"Set","name":"size"},{"value":V3("0.5")}),
                 g.add("var",{"mode":"Set","name":"rotation"},{"value":V3("45, 0, 45")})])
ef=g.add("every_frame")
g.link(ef,"out",[g.add("var",{"mode":"Add","name":"rotation"},{"value":V3("0, 120 * dt, 0")})])
tc=g.add("touched",note="other: the Part that touched this gem")
isp=g.add("object",{"op":"As","of":"Player"},{"object":V("other")},{"result":"who"})
there=g.add("object",{"op":"Exists"},{"object":V("who")},{"result":"by_player"})
cond=g.add("if",{"operator":"is true"},{"a":V("by_player")})
g.link(cond,"true",[g.add("call_method",{"class":"Player","method":"add_point"},{"object":V("who")}),
                    g.add("random",{},{"min":I(-8),"max":I(8)},{"result":"rx"}),
                    g.add("random",{},{"min":I(-8),"max":I(8)},{"result":"rz"}),
                    g.add("vector",{"op":"Make"},{"x":V("rx"),"y":F(0.8),"z":V("rz")},{"result":"position"})])
g.link(tc,"out",[isp,there,cond])
g.dump(os.path.join(out_dir,"scripts/gem.cbricks"))

# ---- main: the window, the gems, the Game loop (the world runs itself)
m=G()
st=m.add("start")
main=[m.add("window",{},{"width":I(960),"height":I(540),"title":S("Gem Hunt"),"fps":I(60)})]
loop=m.add("for",{},{"from":I(0),"to":I(8),"step":I(1)},{"index":"i"},note="Eight gems, each somewhere random")
gem=m.add("new_object",{"of":"Gem","world":True},{},{"object":"gem"})
if auto:
    pos=m.add("vector",{"op":"Make"},{"x":{"type":"float","value":"i + 1.5"},"y":F(0.8),"z":F(0)},{"result":"spot"})
else:
    rx=m.add("random",{},{"min":I(-8),"max":I(8)},{"result":"rx"})
    rz=m.add("random",{},{"min":I(-8),"max":I(8)},{"result":"rz"})
    pos=m.add("vector",{"op":"Make"},{"x":V("rx"),"y":F(0.8),"z":V("rz")},{"result":"spot"})
setp=m.add("field",{"mode":"Set","field":"position"},{"record":V("gem"),"value":V("spot")})
m.link(loop,"loop",[gem]+([] if auto else [rx,rz])+[pos,setp])
main.append(loop)
frame=[]
if test:
    main.append(m.add("var",{"mode":"Set","name":"frames"},{"value":I(0)}))
    frame.append(m.add("var",{"mode":"Add","name":"frames"},{"value":I(1)}))
    snap=m.add("if",{"operator":"=="},{"a":V("frames"),"b":I(150 if auto else 40)})
    m.link(snap,"true",[m.add("raw_c",{"code":"cb_screenshot(\"gems.png\");"}),
                        m.add("object",{"op":"Find","of":"Player"},{"name":S("Player")},{"result":"pl"}),
                        m.add("field",{"mode":"Get","field":"score"},{"record":V("pl")},{"value":"final"}),
                        m.add("print",{"newline":True},{"value":V("final")}),
                        m.add("quit",{},{"code":I(0)})])
    frame.append(snap)
gl=m.add("game_loop",note="The world moves and draws itself: the Player and the Gems do the rest")
m.link(gl,"frame",frame)
main.append(gl)
m.link(st,"out",main)
m.dump(os.path.join(out_dir,"main.cbricks"))

world={"format":"c-bricks-scene","version":4,"next_id":20,"objects":[
 {"id":1,"class":"Camera3D","name":"Camera","parent":0,"fields":{"fov":"55"}},
 {"id":2,"class":"Light3D","name":"Sun","parent":0,"fields":{"rotation":"-55, 34, 0"}},
 {"id":11,"class":"Environment","name":"Environment","parent":0,"fields":{"sky":"#87ceeb"}},
 {"id":3,"class":"Shape3D","name":"Floor","parent":0,"fields":{"size":"20, 0.2, 20","position":"0, -0.1, 0","color":"#5aa846"}},
 {"id":4,"class":"Spatial3D","name":"Walls","parent":0,"fields":{}},
 {"id":5,"class":"Shape3D","name":"North wall","parent":4,"fields":{"position":"0, 0.6, -10.3","size":"21.2, 1.6, 0.6","color":"#a1887f"}},
 {"id":6,"class":"Shape3D","name":"South wall","parent":4,"fields":{"position":"0, 0.6, 10.3","size":"21.2, 1.6, 0.6","color":"#a1887f"}},
 {"id":7,"class":"Shape3D","name":"West wall","parent":4,"fields":{"position":"-10.3, 0.6, 0","size":"0.6, 1.6, 20","color":"#a1887f"}},
 {"id":8,"class":"Shape3D","name":"East wall","parent":4,"fields":{"position":"10.3, 0.6, 0","size":"0.6, 1.6, 20","color":"#a1887f"}},
 {"id":9,"class":"Player","name":"Player","parent":0,"fields":{"position":"0, 0.8, 0","size":"0.8, 1.6, 0.8","shape":"Cylinder","color":"#1e88e5"}},
 {"id":15,"class":"Panel","name":"HudBack","parent":0,"fields":{"anchor":"top_left","offset":"12, 12","size":"520, 46","radius":"8","color":"#ffffffc0"}},
 {"id":10,"class":"Label","name":"Hud","parent":15,"fields":{"anchor":"left","offset":"12, 0","size":"500, 30","font_size":"30","color":"#1b1b1b"}},
]}
world["format"] = "c-bricks-scene"
world["objects"] = rooted(world["objects"])
world["next_id"] = max(o["id"] for o in world["objects"]) + 1
if os.path.exists(os.path.join(out_dir, "world.cnworld")):
    os.remove(os.path.join(out_dir, "world.cnworld"))
json.dump(world,open(os.path.join(out_dir,"main.cbscene"),"w"),indent="\t")
open(os.path.join(out_dir,"project.cbproj"),"w").write('[project]\n\nname="Gem Hunt"\nversion="1.0"\n\n[run]\n\nargs=""\n\n[build]\n\ntarget="native"\n')
