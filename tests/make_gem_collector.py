# Generates examples/gem_collector (and its test copies): python3 tests/make_gem_collector.py <out dir> [test [auto]]
#   examples/gem_collector                       the example (then laid out in the app: tests/layout_example.gd)
#   tests/cases/gem_collector_shot test          + a screenshot at frame 40 and a quit
#   tests/cases/gem_collector_auto test auto     + D held, 2 s rounds, a screenshot of the Time's up screen
import json, sys, os
out_dir = sys.argv[1]
test_shot = len(sys.argv) > 2  # a test copy: screenshot at frame 40, then quit
auto = len(sys.argv) > 3  # holds D, 2 s rounds, screenshot at frame 150 (game over)
# DOS=1: the MS-DOS example (tests/make_dos_examples.py): a 320 x 200 window (VGA), 30 frames a second, a coarser
# ground (software 3D on an emulated PC is slow: pixels and triangles are what cost)
dos = os.environ.get("DOS") == "1"
W, H, Q = (320, 200, 2) if dos else (960, 540, 1)
nodes=[]; nid=[0]
def node(t,fields=None,args=None,outs=None,links=None,note=None):
    nid[0]+=1; i=nid[0]
    o={k:{"var":v,"use":False} for k,v in (outs or {}).items()}
    n={"id":i,"type":t,"pos":[0,0],"size":[0,0],"fields":fields or {},"args":args or {},"outs":o,"links":links or {}}
    if note: n["note"]=note
    nodes.append(n); return i
def link(i,group,ids): next(n for n in nodes if n["id"]==i)["links"][group]=ids
V=lambda v:{"var":v}
F=lambda x:{"type":"float","value":str(x)}
I=lambda x:{"type":"int","value":str(x)}
B=lambda x:{"type":"bool","value":x}
S=lambda x:{"type":"string","value":x}
V3=lambda x:{"type":"vector3","value":x}
def key(k,out,when="Key down"): return node("input",{"when":when,"key":k},{},{"result":out})
def formula(expr,out,ty="float"): return node("formula",{"expression":expr,"type":ty},{},{"result":out})
def setv(name,val): return node("var",{"mode":"Set","name":name},{"value":val})
def addv(name,val): return node("var",{"mode":"Add","name":name},{"value":val})
def cond(op,a,b=None):
    args={"a":a}
    if b is not None: args["b"]=b
    return node("if",{"operator":op},args)
def call(fn,args,out): return node("call",{"function":fn},args,{"result":out})
def text(x,y,size,color,value): return node("draw",{"shape":"Text"},{"text":value,"x":I(x),"y":I(y),"size":I(size),"color":S(color)})

# ---- constants
node("constant",{"name":"ROUND_TIME","type":"float"},{"value":F(2 if auto else 60)},note="Seconds per round")
node("constant",{"name":"SPEED","type":"float"},{"value":F(6)},note="Units per second")
node("constant",{"name":"GEM_COUNT","type":"int"},{"value":I(8)})

# ---- height(x, z): the ground's height anywhere
fh=node("function",{"name":"height","returns":"float","params":[["x","float"],["z","float"]]},note="The rolling hills: used for the ground mesh, the player and the gems")
h1=formula("sin(x * 0.45) * 0.6 + cos(z * 0.35) * 0.5","hy")
h2=node("return",{"gives":"A value"},{"value":V("hy")})
link(fh,"out",[h1,h2])

# ---- new_gem(): a random spot above the ground
fg=node("function",{"name":"new_gem","returns":"vector3","params":[]},note="A gem somewhere in the arena, floating above the ground")
g1=node("random",{},{"min":I(-9),"max":I(9)},{"result":"rx"})
g2=node("random",{},{"min":I(-9),"max":I(9)},{"result":"rz"})
g3=call("height",{"x":V("rx"),"z":V("rz")},"gy")
g4=node("vector",{"op":"Make"},{"x":V("rx"),"y":{"type":"float","value":"gy + 0.9"},"z":V("rz")},{"result":"spot"})
g5=node("return",{"gives":"A value"},{"value":V("spot")})
link(fg,"out",[g1,g2,g3,g4,g5])

# ---- When program starts: window, meshes, the round
main=[]
main.append(node("window",{},{"width":I(W),"height":I(H),"title":S("Gem Collector"),"fps":I(30 if dos else 60)}))
# the ground: a 20 x 20 grid of quads, Smooth, then bent into hills with Mesh vertices
main.append(node("begin_mesh",{},{},{"mesh":"ground"},note="The arena floor: a flat grid first"))
fx=node("for",{},{"from":I(-10),"to":I(8 if dos else 10),"step":I(Q)},{"index":"gx"})
fz=node("for",{},{"from":I(-10),"to":I(8 if dos else 10),"step":I(Q)},{"index":"gz"})
q=node("add_mesh",{"kind":"Quad"},{"mesh":V("ground"),"a":V3("gx, 0, gz"),"b":V3("gx + %d, 0, gz" % Q),"c":V3("gx + %d, 0, gz + %d" % (Q, Q)),"d":V3("gx, 0, gz + %d" % Q),"color":S("#5aa846")})
link(fx,"loop",[fz]); link(fz,"loop",[q])
main.append(fx)
main.append(node("finish_mesh",{"shading":"Smooth","sides":"One side"},{"mesh":V("ground")}))
main.append(node("mesh_vertices",{"mode":"Get"},{"mesh":V("ground")},{"points":"flat_points"},note="Then every point is lifted to height(x, z)"))
main.append(node("list",{"op":"Make","of":"vector3"},{},{"result":"hills"}))
fe=node("for_each",{},{"list":V("flat_points")},{"item":"p","index":""})
s1=node("vector",{"op":"Split"},{"a":V("p")},{"x":"px","y":"","z":"pz"})
s2=call("height",{"x":V("px"),"z":V("pz")},"lift")
s3=node("vector",{"op":"Make"},{"x":V("px"),"y":V("lift"),"z":V("pz")},{"result":"hp"})
s4=node("list",{"op":"Add"},{"list":V("hills"),"value":V("hp")})
link(fe,"loop",[s1,s2,s3,s4])
main.append(fe)
main.append(node("mesh_vertices",{"mode":"Set"},{"mesh":V("ground"),"value":V("hills")}))
# the walls: four boxes
main.append(node("begin_mesh",{},{},{"mesh":"walls"}))
for at,size in [("0, 0.6, -10.3","21.2, 1.6, 0.6"),("0, 0.6, 10.3","21.2, 1.6, 0.6"),("-10.3, 0.6, 0","0.6, 1.6, 20"),("10.3, 0.6, 0","0.6, 1.6, 20")]:
    main.append(node("add_mesh",{"kind":"Shape","shape":"Box"},{"mesh":V("walls"),"at":V3(at),"size":V3(size),"color":S("#a1887f")}))
main.append(node("finish_mesh",{"shading":"Flat","sides":"One side"},{"mesh":V("walls")}))
# the hero: a body, a head and a nose (its front is +z)
main.append(node("begin_mesh",{},{},{"mesh":"hero"},note="The player: shapes in one mesh"))
main.append(node("add_mesh",{"kind":"Shape","shape":"Cylinder"},{"mesh":V("hero"),"at":V3("0, 0.5, 0"),"size":V3("0.7, 1, 0.7"),"color":S("#1e88e5")}))
main.append(node("add_mesh",{"kind":"Shape","shape":"Sphere"},{"mesh":V("hero"),"at":V3("0, 1.3, 0"),"size":V3("0.6"),"color":S("#ffcc80")}))
main.append(node("add_mesh",{"kind":"Shape","shape":"Box"},{"mesh":V("hero"),"at":V3("0, 1.3, 0.32"),"size":V3("0.14, 0.14, 0.2"),"color":S("#e53935")}))
main.append(node("finish_mesh",{"shading":"Flat","sides":"One side"},{"mesh":V("hero")}))
# a gem: an octahedron of 8 triangles (corners clockwise seen from outside)
main.append(node("begin_mesh",{},{},{"mesh":"gem"},note="A gem: 8 triangles, faceted"))
top,bot="0, 0.35, 0","0, -0.35, 0"
eq=["0.25, 0, 0","0, 0, 0.25","-0.25, 0, 0","0, 0, -0.25"]
cols=["#40e0ff","#00bcd4"]
for i in range(4):
    a,b=eq[i],eq[(i+1)%4]
    main.append(node("add_mesh",{"kind":"Triangle"},{"mesh":V("gem"),"a":V3(top),"b":V3(a),"c":V3(b),"color":S(cols[i%2])}))
    main.append(node("add_mesh",{"kind":"Triangle"},{"mesh":V("gem"),"a":V3(bot),"b":V3(b),"c":V3(a),"color":S(cols[(i+1)%2])}))
main.append(node("finish_mesh",{"shading":"Flat","sides":"One side"},{"mesh":V("gem")}))
# the gems and the round
main.append(node("list",{"op":"Make","of":"vector3"},{},{"result":"gems"}))
rp=node("for",{},{"from":I(0),"to":V("GEM_COUNT"),"step":I(1)},{"index":""})
link(rp,"loop",[call("new_gem",{},"ng0"), node("list",{"op":"Add"},{"list":V("gems"),"value":V("ng0")})])
main.append(rp)
main.append(call("height",{"x":F(0),"z":F(0)},"h0"))
main.append(setv("pos",V3("0, h0, 0")))
main.append(setv("facing",F(0)))
main.append(setv("score",I(0)))
main.append(setv("best",I(0)))
main.append(setv("time_left",V("ROUND_TIME")))
main.append(setv("over",B("false")))
if test_shot: main.append(setv("frames",I(0)))

# ---- the game loop
fr=[]
fr.append(node("game_info",{"what":"Frame time"},{},{"result":"dt"}))
fr.append(node("game_info",{"what":"Time"},{},{"result":"t"}))
play=cond("is false",V("over"))
fr.append(play)
p=[]
p.append(addv("time_left",{"type":"float","value":"-dt"}))
p += [key("W","kw"),key("S","ks"),key("A","ka"),(setv("kd",B("true")) if auto else key("D","kd"))]
p.append(formula("(kd ? 1.0 : 0.0) - (ka ? 1.0 : 0.0)","dx"))
p.append(formula("(ks ? 1.0 : 0.0) - (kw ? 1.0 : 0.0)","dz"))
p.append(node("vector",{"op":"Make"},{"x":V("dx"),"y":F(0),"z":V("dz")},{"result":"dir"},note="WASD: a direction on the ground"))
p.append(node("vector",{"op":"Normalize"},{"a":V("dir")},{"result":"dir"}))
p.append(node("vector",{"op":"Scale"},{"a":V("dir"),"factor":{"type":"float","value":"SPEED * dt"}},{"result":"step"}))
p.append(addv("pos",V("step")))
turn=cond("is true",{"type":"bool","value":"dx != 0 || dz != 0"})
link(turn,"true",[formula("atan2(dx, dz) * 180.0 / 3.14159265","facing")])
p.append(turn)
p.append(node("vector",{"op":"Split"},{"a":V("pos")},{"x":"px","y":"","z":"pz"},note="Stay inside the walls, on the ground"))
p.append(formula("fmax(-9.4, fmin(9.4, px))","px"))
p.append(formula("fmax(-9.4, fmin(9.4, pz))","pz"))
p.append(call("height",{"x":V("px"),"z":V("pz")},"py"))
p.append(node("vector",{"op":"Make"},{"x":V("px"),"y":V("py"),"z":V("pz")},{"result":"pos"}))
gl=node("for_each",{},{"list":V("gems")},{"item":"g","index":"gi"},note="Touching a gem: a point, and it jumps somewhere else")
gd=node("vector",{"op":"Distance"},{"a":V("pos"),"b":V("g")},{"result":"dist"})
near=cond("<",V("dist"),F(1.4))
link(near,"true",[addv("score",I(1)), call("new_gem",{},"ng"), node("list",{"op":"Set"},{"list":V("gems"),"index":V("gi"),"value":V("ng")})])
link(gl,"loop",[gd,near])
p.append(gl)
end=cond("<=",V("time_left"),F(0))
rec=cond(">",V("score"),V("best"))
link(rec,"true",[setv("best",V("score"))])
link(end,"true",[setv("over",B("true")),rec])
p.append(end)
link(play,"true",p)
restart=cond("is true",V("kr"))
link(restart,"true",[setv("score",I(0)),setv("time_left",V("ROUND_TIME")),setv("over",B("false"))])
link(play,"false",[key("R","kr","Key pressed"),restart])
# camera follows; draw
fr.append(node("vector",{"op":"Add"},{"a":V("pos"),"b":V3("0, 7, 9")},{"result":"eye"}))
fr.append(node("camera3d",{"projection":"Perspective"},{"position":V("eye"),"target":V("pos"),"fov":F(55)}))
fr.append(node("clear",{},{"color":S("#87ceeb")}))
d3=node("draw3d")
dl=[]
dl.append(node("shape3d",{"shape":"Mesh"},{"mesh":V("ground"),"at":V3("0, 0, 0"),"size":V3("1"),"turn":F(0),"color":S("WHITE")}))
dl.append(node("shape3d",{"shape":"Mesh"},{"mesh":V("walls"),"at":V3("0, 0, 0"),"size":V3("1"),"turn":F(0),"color":S("WHITE")}))
dl.append(node("shape3d",{"shape":"Mesh"},{"mesh":V("hero"),"at":V("pos"),"size":V3("1"),"turn":V("facing"),"color":S("WHITE")}))
ge=node("for_each",{},{"list":V("gems")},{"item":"shown","index":""})
link(ge,"loop",[node("vector",{"op":"Add"},{"a":V("shown"),"b":V3("0, sin(t * 3.0 + shown.x) * 0.15, 0")},{"result":"bob"}),
                node("shape3d",{"shape":"Mesh"},{"mesh":V("gem"),"at":V("bob"),"size":V3("1"),"turn":{"type":"float","value":"t * 120.0"},"color":S("WHITE")})])
dl.append(ge)
link(d3,"draw",dl)
fr.append(d3)
fr.append(formula("time_left > 0 ? (int)ceil(time_left) : 0","secs","int"))
fr.append(node("text",{"op":"Format","format":"Gems: {}     Time: {}     Best: {}"},{"first":V("score"),"second":V("secs"),"third":V("best")},{"result":"hud"}))
if dos:
    fr.append(text(4,2,16,"#1b1b1b",V("hud")))
    fr.append(text(4,20,16,"#37474f",S("WASD: move")))
else:
    fr.append(text(18,14,30,"#1b1b1b",V("hud")))
    fr.append(text(18,52,18,"#37474f",S("WASD to move. Collect the gems before the time runs out!")))
over=cond("is true",V("over"))
link(over,"true",[node("draw",{"shape":"Rectangle"},{"x":I(0),"y":I(60 if dos else 190),"width":I(W),"height":I(60 if dos else 150),"color":S("#000000aa")}),
                  node("text",{"op":"Format","format":"Time's up! Gems collected: {}"},{"first":V("score")},{"result":"msg"}),
                  text(12 if dos else 270,70 if dos else 220,16 if dos else 36,"WHITE",V("msg")),
                  text(60 if dos else 355,96 if dos else 280,16 if dos else 26,"GOLD",S("Press R to play again"))])
fr.append(over)
if test_shot:
    fr.append(addv("frames",I(1)))
    snap=cond("==",V("frames"),I(150 if auto else 40))
    link(snap,"true",[node("raw_c",{"code":"cb_screenshot(\"gems.png\");"}),node("print",{"newline":True},{"value":V("hud")}),node("print",{"newline":True},{"value":V("pos")}),node("print",{"newline":True},{"value":V("facing")}),node("quit",{},{"code":I(0)})])
    fr.append(snap)
loop=node("game_loop")
link(loop,"frame",fr)
main.append(loop)
st=node("start"); link(st,"out",main)
os.makedirs(out_dir, exist_ok=True)
json.dump({"format":"c-bricks","version":3,"next_id":nid[0]+1,"nodes":nodes},open(os.path.join(out_dir,"main.cbricks"),"w"),indent="\t")
open(os.path.join(out_dir,"project.cbproj"),"w").write('[project]\n\nname="Gem Collector"\nversion="1.0"\n\n[run]\n\nargs=""\n\n[build]\n\ntarget="native"\n')
print(len(nodes),"bricks")
