# Generates examples/tv (2026-11-20): python3 tests/make_tv.py <out dir> [test]
#   examples/tv        the example (then laid out in the app: tests/layout_example.gd tv)
#   tests/cases/tv_shot test   + at frame 45 a screenshot, then a quit (the case checks the picture isn't blank)
# A little television in a dark room: the screen is an ordinary Shape3D whose Texture field names a Video object, so it plays
# media/channel.mpg (made by tests/make_clip.py: our own MPEG-1 encoder, no ffmpeg). SPACE pauses / plays, R restarts, UP / DOWN change
# the volume, L turns looping on / off; the TV sways so you can see the picture on a 3D object. Replace media/channel.mpg with your
# own MPEG-1 file (ffmpeg -i in.mp4 -c:v mpeg1video -c:a mp2 -f mpeg out.mpg) and it plays that.
import json, sys, os, subprocess
out_dir = sys.argv[1]
test_shot = len(sys.argv) > 2 and sys.argv[2] == 'test'
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
def cond(op,a,b=None):
    args={"a":a}
    if b is not None: args["b"]=b
    return node("if",{"operator":op},args)
def getf(rec,field,out): return node("field",{"mode":"Get","field":field},{"record":V(rec)},{"value":out})
def setf(rec,field,val): return node("field",{"mode":"Set","field":field},{"record":V(rec),"value":val})
def find(cls,name,out): return node("object",{"op":"Find","of":cls},{"name":S(name)},{"result":out})
def text(x,y,size,color,value): return node("draw",{"shape":"Text"},{"text":value,"x":I(x),"y":I(y),"size":I(size),"color":S(color)})

main=[]
main.append(node("window",{},{"width":I(960),"height":I(540),"title":S("TV"),"fps":I(60)}))
main.append(find("Video","Channel","chan"))
main.append(find("Spatial3D","TV","tv"))
if test_shot: main.append(node("var",{"mode":"Set","name":"frames"},{"value":I(0)}))

fr=[]
fr.append(node("game_info",{"what":"Time"},{},{"result":"t"}))
fr.append(node("game_info",{"what":"FPS"},{},{"result":"fps"}))
# the TV sways, so the picture is seen from changing angles
fr.append(formula("sin(t * 0.6) * 28.0","sway"))
fr.append(node("vector",{"op":"Make"},{"x":F(0),"y":V("sway"),"z":F(0)},{"result":"rot"}))
fr.append(setf("tv","rotation",V("rot")))
# SPACE: pause / play
sp=key("SPACE","ksp"); fr.append(sp)
tog=cond("is true",V("ksp"))
pl=getf("chan","playing","pl")
flip=cond("is true",V("pl")); link(flip,"true",[setf("chan","playing",B("false"))]); link(flip,"false",[setf("chan","playing",B("true"))])
link(tog,"true",[pl,flip]); fr.append(tog)
# R: back to the start (time is where it is: setting it seeks)
kr=key("R","kr"); fr.append(kr)
rr=cond("is true",V("kr")); link(rr,"true",[setf("chan","time",F(0)),setf("chan","playing",B("true"))]); fr.append(rr)
# UP / DOWN: volume
ku=key("UP","kup"); kd=key("DOWN","kdn"); fr += [ku,kd]
vol=getf("chan","volume","vol"); fr.append(vol)
vu=cond("is true",V("kup")); link(vu,"true",[formula("fmin(vol + 0.1, 1.0)","vol"),setf("chan","volume",V("vol"))])
vd=cond("is true",V("kdn")); link(vd,"true",[formula("fmax(vol - 0.1, 0.0)","vol"),setf("chan","volume",V("vol"))])
fr += [vu,vd]
# L: loop on / off
kl=key("L","kl"); fr.append(kl)
lp=cond("is true",V("kl"))
gl_=getf("chan","loop","lp")
lf=cond("is true",V("lp")); link(lf,"true",[setf("chan","loop",B("false"))]); link(lf,"false",[setf("chan","loop",B("true"))])
link(lp,"true",[gl_,lf]); fr.append(lp)
# the screen of text
fr.append(getf("chan","time","vt")); fr.append(getf("chan","duration","vd")); fr.append(getf("chan","playing","vp")); fr.append(getf("chan","loop","vl"))
fr.append(formula("floor(vt * 10.0) / 10.0","shown_t"))
fr.append(formula("floor(vd * 10.0) / 10.0","shown_d"))
fr.append(formula("floor(vol * 10.0 + 0.5)","shown_v","int"))
fr.append(node("text",{"op":"Format","format":"{} / {} s     volume {}/10"},{"first":V("shown_t"),"second":V("shown_d"),"third":V("shown_v")},{"result":"hud"}))
fr.append(text(16,12,24,"WHITE",V("hud")))
fr.append(text(16,46,18,"#b0bec5",S("SPACE: pause / play     R: restart     UP / DOWN: volume     L: loop on / off")))
if test_shot:
    fr.append(node("var",{"mode":"Add","name":"frames"},{"value":I(1)}))
    snap=cond("==",V("frames"),I(45))
    link(snap,"true",[node("raw_c",{"code":"cb_screenshot(\"tv.png\");"}),node("quit",{},{"code":I(0)})])
    fr.append(snap)
loop=node("game_loop"); link(loop,"frame",fr); main.append(loop)
st=node("start"); link(st,"out",main)

objs=[
 {"id":1,"class":"Spatial3D","name":"Room","parent":0,"fields":{}},
 {"id":2,"class":"Environment","name":"Environment","parent":1,"fields":{"sky":"#050508","ambient":"0.6","ambient_color":"#7a88aa","fog":"0.04","fog_color":"#030305","vignette":"0.35","grain":"0.04"}},
 {"id":3,"class":"Camera3D","name":"Camera","parent":1,"fields":{"position":"0, 1.5, 4.6","target":"0, 1.25, 0","fov":"48"}},
 {"id":4,"class":"Light3D","name":"Moonlight","parent":1,"fields":{"rotation":"-45, 30, 0","color":"#9aa8d0","energy":"1.1"}},
 {"id":5,"class":"Shape3D","name":"Floor","parent":1,"fields":{"size":"12, 0.2, 12","position":"0, -0.1, 0","color":"#2a2a31"}},
 {"id":6,"class":"Shape3D","name":"BackWall","parent":1,"fields":{"size":"12, 6, 0.2","position":"0, 3, -3","color":"#22222a"}},
 {"id":7,"class":"Shape3D","name":"Stand","parent":1,"fields":{"size":"1.6, 0.8, 0.9","position":"0, 0.4, 0","color":"#3a2f28"}},
 {"id":8,"class":"Video","name":"Channel","parent":1,"fields":{"file":"media/channel.mpg","loop":"true"}},
 {"id":9,"class":"Spatial3D","name":"TV","parent":1,"fields":{"position":"0, 1.75, 0"}},
 {"id":10,"class":"Shape3D","name":"Body","parent":9,"fields":{"size":"2.3, 1.7, 0.75","color":"#2b2b30"}},
 {"id":11,"class":"Shape3D","name":"Screen","parent":9,"fields":{"size":"2.0, 1.5, 0.02","position":"0, 0, 0.38","texture":"Channel"}},
 {"id":12,"class":"Shape3D","name":"AntennaLeft","parent":9,"fields":{"shape":"Cylinder","size":"0.02, 0.55, 0.02","position":"-0.14, 1.12, -0.02","rotation":"0, 0, 28","color":"#b0b0b8"}},
 {"id":13,"class":"Shape3D","name":"AntennaRight","parent":9,"fields":{"shape":"Cylinder","size":"0.02, 0.55, 0.02","position":"0.14, 1.12, -0.02","rotation":"0, 0, -28","color":"#b0b0b8"}},
]
os.makedirs(os.path.join(out_dir,"media"), exist_ok=True)
json.dump({"format":"c-bricks","version":4,"next_id":nid[0]+1,"nodes":nodes},open(os.path.join(out_dir,"main.cbricks"),"w"),indent="\t")
json.dump({"format":"c-bricks-scene","version":4,"next_id":len(objs)+1,"objects":objs},open(os.path.join(out_dir,"main.cbscene"),"w"),indent="\t")
open(os.path.join(out_dir,"project.cbproj"),"w").write('[project]\n\nname="TV"\nversion="1.0"\n\n[run]\n\nargs=""\n\n[build]\n\ntarget="native"\n')
clip=os.path.join(out_dir,"media","channel.mpg")
if not os.path.exists(clip):
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "make_clip.py"), clip, "ball", "6"], check=True, stderr=subprocess.DEVNULL)
print(len(nodes),"bricks")
