# Generates examples/stress_test (and its test copy): python3 tests/make_stress_test.py <out dir> [test]
#   examples/stress_test                  the example (then laid out in the app: tests/layout_example.gd)
#   tests/cases/stress_test_shot test     + at frame 60 a screenshot, the object count and a quit
# A 3D load test for a computer's GPU: many moving objects under a lit, orbiting camera. UP / DOWN add or remove 250
# objects, SPACE changes what is drawn (gem mesh / sphere / box), 1-4 shading (lit, toon, unlit, wire), 5 / 6 splatting
# off / full. The HUD shows the frame rate, the object count and the triangles drawn a frame.
import json, sys, os
out_dir = sys.argv[1]
bench = len(sys.argv) > 2 and sys.argv[2] == 'bench'  # + a 4th mode on SPACE: the gem mesh drawn as one batch
auto = len(sys.argv) > 2 and sys.argv[2] == 'autobench'  # bench, then every mode timed in turn (count from argv[3]) and a screenshot of each
batch_test = len(sys.argv) > 2 and sys.argv[2] == 'batch'  # the test copy: 130 gems, all batched, screenshot + draw counts
bench = bench or auto or batch_test
test_shot = len(sys.argv) > 2 and (batch_test or not bench)
test_splat = test_shot and sys.argv[2] == 'splat'
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
def key(k,out,when="Pressed"): return node("input",{"when":when,"key":k},{},{"result":out})
def formula(expr,out,ty="float"): return node("formula",{"expression":expr,"type":ty},{},{"result":out})
def setv(name,val): return node("var",{"mode":"Set","name":name},{"value":val})
def cond(op,a,b=None):
    args={"a":a}
    if b is not None: args["b"]=b
    return node("if",{"operator":op},args)
def text(x,y,size,color,value): return node("draw",{"shape":"Text"},{"text":value,"x":I(x),"y":I(y),"size":I(size),"color":S(color)})

node("constant",{"name":"STEP","type":"int"},{"value":I(250)},note="Objects added or removed by one press of UP / DOWN")
node("constant",{"name":"MOST","type":"int"},{"value":I(20000)},note="The most objects")
node("constant",{"name":"ACROSS","type":"int"},{"value":I(50)},note="Objects in a row of the field")

# ---- start: window, the gem mesh, the starting load
main=[]
main.append(node("window",{},{"width":I(960),"height":I(540),"title":S("Stress test"),"fps":I(1000)},note="A very high frame cap: the frame rate shown is what the computer can do"))
main.append(node("begin_mesh",{},{},{"mesh":"gem"},note="One object: 8 triangles"))
top,bot="0, 0.35, 0","0, -0.35, 0"
eq=["0.25, 0, 0","0, 0, 0.25","-0.25, 0, 0","0, 0, -0.25"]
cols=["#40e0ff","#00bcd4"]
for i in range(4):
    a,b=eq[i],eq[(i+1)%4]
    main.append(node("add_mesh",{"kind":"Triangle"},{"mesh":V("gem"),"a":V3(top),"b":V3(a),"c":V3(b),"color":S(cols[i%2])}))
    main.append(node("add_mesh",{"kind":"Triangle"},{"mesh":V("gem"),"a":V3(bot),"b":V3(b),"c":V3(a),"color":S(cols[(i+1)%2])}))
main.append(node("finish_mesh",{"shading":"Flat","sides":"One side"},{"mesh":V("gem")}))
main.append(setv("count",I(int(sys.argv[3]) if auto and len(sys.argv) > 3 else (130 if batch_test else 1000))))
main.append(setv("what",I(3 if batch_test else 0)))
main.append(setv("lastswap",F(-1)))
if test_shot or auto: main.append(setv("frames",I(0)))

# ---- the game loop
fr=[]
if auto:
    fr.append(node("var",{"mode":"Add","name":"frames"},{"value":I(1)}))
    fr.append(formula("(frames / 60) % 4","what","int"))
fr.append(node("game_info",{"what":"Time"},{},{"result":"t"}))
fr.append(node("game_info",{"what":"FPS"},{},{"result":"fps"}))
up=key("UP","kup"); dn=key("DOWN","kdn"); sp=key("SPACE","ksp")
fr += [up,dn,sp]
more=cond("is true",V("kup")); link(more,"true",[formula("fmin(count + STEP, MOST)","count","int")])
less=cond("is true",V("kdn")); link(less,"true",[formula("fmax(count - STEP, 0)","count","int")])
# SPACE swaps the drawing, at most every 0.3 s (a tap could swap twice at 100+ fps: the key is read every frame)
swap=cond("is true",V("ksp")); gap=cond(">",V("since"),F(0.3)); link(gap,"true",[formula("(what + 1) %% %d" % (4 if bench else 3),"what","int"),node("var",{"mode":"Set","name":"lastswap"},{"value":V("t")})]); link(swap,"true",[formula("t - lastswap","since"),gap])
fr += [more,less,swap]
for k,mode in [("ONE","lit"),("TWO","toon"),("THREE","unlit"),("FOUR","wire")]:
    kk=key(k,"k"+k.lower()); c=cond("is true",V("k"+k.lower()))
    link(c,"true",[node("look",{"what":"Shading","shading":mode})])
    fr += [kk,c]
for k,mode in [("FIVE","off"),("SIX","full")]:
    kk=key(k,"k"+k.lower()); c=cond("is true",V("k"+k.lower()))
    link(c,"true",[node("look",{"what":"Splatting","splat":mode})])
    fr += [kk,c]
# the camera circles the field, high up
fr.append(formula("sin(t * 0.25) * 45.0","cx"))
fr.append(formula("cos(t * 0.25) * 45.0","cz"))
fr.append(node("camera3d",{"projection":"Perspective"},{"position":V3("cx, 26, cz"),"target":V3("0, 0, 0"),"fov":F(60)}))
fr.append(node("clear",{},{"color":S("#1b2838")}))
d3=node("draw3d")
dl=[]
dl.append(node("shape3d",{"shape":"Plane"},{"at":V3("0, 0, 0"),"size":V3("90, 1, 90"),"turn":F(0),"color":S("#37474f")}))
fl=node("for",{},{"from":I(0),"to":V("count"),"step":I(1)},{"index":"i"},note="Every object: its place on a grid, bobbing and turning")
body=[]
body.append(formula("(i % ACROSS - ACROSS / 2) * 1.6","gx"))
body.append(formula("(i / ACROSS - ACROSS / 2) * 1.6","gz"))
body.append(formula("sin(t * 2.0 + i * 0.37) * 1.5 + 2.0","gy"))
body.append(node("vector",{"op":"Make"},{"x":V("gx"),"y":V("gy"),"z":V("gz")},{"result":"at"}))
body.append(formula("t * 90.0 + i * 7.0","spin"))
pick0=cond("==",V("what"),I(0)); link(pick0,"true",[node("shape3d",{"shape":"Mesh"},{"mesh":V("gem"),"at":V("at"),"size":V3("2"),"turn":V("spin"),"color":S("WHITE")})])
pick1=cond("==",V("what"),I(1)); link(pick1,"true",[node("shape3d",{"shape":"Sphere"},{"at":V("at"),"size":V3("0.7"),"turn":V("spin"),"color":S("#ffb300")})])
pick2=cond("==",V("what"),I(2)); link(pick2,"true",[node("shape3d",{"shape":"Box"},{"at":V("at"),"size":V3("0.6"),"turn":V("spin"),"color":S("#ef5350")})])
body += [pick0,pick1,pick2]
link(fl,"loop",body)
if bench:   # the same gems, one batched draw (cb_draw_mesh_batch, from C: a scene's MultiMesh3D is drawn by the world, after the script)
    b3=cond("==",V("what"),I(3))
    code=('static cb_instance *cbi; static int cbn; int i_; if (count > cbn) { cbn = count; cbi = (cb_instance *)realloc(cbi, sizeof(cb_instance) * (size_t)cbn); } '
          'for (i_ = 0; i_ < count; i_++) { cb_instance *o = &cbi[i_]; o->x = (float)((i_ % ACROSS - ACROSS / 2) * 1.6); o->z = (float)((i_ / ACROSS - ACROSS / 2) * 1.6); '
          'o->y = (float)(sin(t * 2.0 + i_ * 0.37) * 1.5 + 2.0); o->sx = o->sy = o->sz = 2.0f; o->turn = (float)(t * 90.0 + i_ * 7.0); o->color.r = o->color.g = o->color.b = o->color.a = 255; } '
          'cb_draw_mesh_batch(gem, cbi, count);')
    link(b3,"true",[node("raw_c",{"code":code})])
    dl.append(b3)
    nb=cond("!=",V("what"),I(3)); link(nb,"true",[fl]); dl.append(nb)   # (no per-object loop in the batched mode)
else:
    dl.append(fl)
link(d3,"draw",dl)
fr.append(d3)
fr.append(formula("count * (what == 0 || what == 3 ? 8 : (what == 1 ? 256 : 12))","tris","int"))
fr.append(node("text",{"op":"Format","format":"{} fps     {} objects     ~{} triangles"},{"first":V("fps"),"second":V("count"),"third":V("tris")},{"result":"hud"}))
fr.append(text(14,10,28,"WHITE",V("hud")))
fr.append(text(14,46,18,"#b0bec5",S("UP / DOWN: more or fewer     SPACE: gem / sphere / box%s" % (" / gem batched" if bench else ""))))
fr.append(text(14,70,18,"#b0bec5",S("1-4: shading (lit, toon, unlit, wire)     5 / 6: splatting off / full")))
if test_shot:
    fr.append(node("var",{"mode":"Add","name":"frames"},{"value":I(1)}))
    if test_splat:  # the Graphics setting brick, at run time, must splat the Draw shape / Draw mesh bricks
        sp5=cond("==",V("frames"),I(5)); link(sp5,"true",[node("look",{"what":"Splatting","splat":"full"})]); fr.append(sp5)
    snap=cond("==",V("frames"),I(60))
    shot=[node("raw_c",{"code":"cb_screenshot(\"stress.png\");"})]
    if batch_test: shot.append(node("raw_c",{"code":"extern long cb_batch_draws, cb_batch_objects; printf(\"batch %ld %ld\\n\", cb_batch_draws / frames, cb_batch_objects / frames);"}))
    if test_splat: shot.append(node("raw_c",{"code":"extern long cb_be_splat_points(void); printf(\"splats %s\\n\", cb_be_splat_points() > 0 ? \"yes\" : \"no\");"}))
    link(snap,"true",shot+[node("print",{"newline":True},{"value":V("count")}),node("quit",{},{"code":I(0)})])
    fr.append(snap)
if auto:
    rep=('static double t0; static int seg_; if (frames % 60 == 59) { double now = cb_game_time(); char png_[32]; if (seg_ > 0 || 1) printf("mode %d (%s): %.1f fps (%d objects)\\n", what, what == 0 ? "gem objects" : what == 1 ? "spheres" : what == 2 ? "boxes" : "gem batch", 59.0 / (now - t0), count); '
         'sprintf(png_, "mode%d.png", what); cb_screenshot(png_); t0 = cb_game_time(); seg_++; } if (frames == 60 * 4) cb_close_window();')
    fr.append(node("raw_c",{"code":rep}))
loop=node("game_loop")
link(loop,"frame",fr)
main.append(loop)
st=node("start"); link(st,"out",main)
os.makedirs(out_dir, exist_ok=True)
json.dump({"format":"c-bricks","version":3,"next_id":nid[0]+1,"nodes":nodes},open(os.path.join(out_dir,"main.cbricks"),"w"),indent="\t")
open(os.path.join(out_dir,"project.cbproj"),"w").write('[project]\n\nname="Stress Test"\nversion="1.0"\n\n[run]\n\nargs=""\n\n[build]\n\ntarget="native"\n')
print(len(nodes),"bricks")
