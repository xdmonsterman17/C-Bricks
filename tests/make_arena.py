# Generates examples/arena (a networked first-person shooter, 2026-11-07: objects, scenes,
# mouse look, Raycast shots, Move and collide, enemies, players over the network) and its
# test copies:
#   python3 tests/make_arena.py <out dir> [test [auto]]
#   examples/arena                       the example (then laid out: tests/layout_example.gd -- arena)
#   tests/cases/arena_shot test          + a screenshot at frame 40 and a quit
#   tests/cases/arena_auto test auto     + no mouse / keys: one slow enemy straight ahead, firing by
#                                          itself (--autofire); a screenshot and the score at frame 150
#   tests/cases/arena_menu menu          starts on the title menu (arena_menu.png at frame 8), a
#                                          --click on Play: playing; --scores shows the scoreboard;
#                                          arena.png at frame 150 (look at both); case.cfg written here
#   tests/cases/arena_net net            a dedicated server and two clients (port 47322): ada's
#                                          Fighter fires by itself (--autofire), bob watches from
#                                          behind her; case.cfg written here; screenshots
#                                          arena_ada.png / arena_bob.png (look at them)
#
# How it's built (the user, 2026-11-07: "each player should have a local and server script
# under it, the server script handles the movement, and the local script handles the input"):
#   scenes/fighter.cbscene    a player's Fighter (its root) holding two Script objects:
#     Input  (LocalScript, scripts/fighter_input.cbricks, Client): on its owner's machine only:
#            mouse look and WASD read there, sent to the server every frame (Fire Server input);
#            that player's camera (their own yaw / pitch at once) and HUD; hides its own body
#     Brain  (Script, scripts/fighter_server.cbricks, Server): where the rules run: keeps each
#            player's input on their Fighter (On Client Fired input) and every frame moves,
#            shoots and respawns the Fighters
#   scripts/rules.cbricks      (Server) a Fighter per player (Player Joined: Instance, Give To),
#                             gone with them (Player Left)
#   scripts/fighter.cbricks    the Fighter class (data, hurt), scripts/enemy.cbricks, spark.cbricks
# Offline it's single-player (you are the server and player 1); H hosts on port 7000, J joins
# 127.0.0.1:7000; or --host 7000, --server 7000 (no window), --join ADDRESS:7000 --name ada.
import json, sys, os
out_dir = sys.argv[1]
test = len(sys.argv) > 2 and sys.argv[2] in ("test", "net", "menu")
net = len(sys.argv) > 2 and sys.argv[2] == "net"
menu = len(sys.argv) > 2 and sys.argv[2] == "menu"  # (the title menu's test: it starts on the menu)
auto = net or menu or len(sys.argv) > 3
title_shown = menu or not test  # the example starts on its title menu; the other tests start playing
V=lambda v:{"var":v}; I=lambda x:{"type":"int","value":str(x)}; F=lambda x:{"type":"float","value":str(x)}
S=lambda x:{"type":"string","value":x}; B=lambda x:{"type":"bool","value":x}
V3=lambda x:{"type":"vector3","value":x}; V2=lambda x:{"type":"vector2","value":x}
FX=lambda e:{"type":"float","value":e}
NONE={"var":""}

class G:
    def __init__(self): self.nodes=[]; self.n=0
    def add(self, t, fields=None, args=None, outs=None, links=None, note=None):
        self.n+=1
        d={"id":self.n,"type":t,"pos":[0,0],"size":[0,0],"fields":fields or {},"args":args or {},"outs":{k:{"var":v,"use":False} for k,v in (outs or {}).items()},"links":links or {}}
        if note: d["note"]=note
        self.nodes.append(d); return self.n
    def link(self, i, group, ids): next(x for x in self.nodes if x["id"]==i)["links"][group]=ids
    def chain(self, ids):
        for a, b in zip(ids, ids[1:]):
            t = next(x for x in self.nodes if x["id"] == a)["type"]
            self.link(a, "done" if t in ["for", "for_each", "while", "repeat"] else "next", [b])  # (a loop goes on from Done)
        return ids[0]
    def dump(self, rel, side=None):
        g={"format":"c-bricks","version":4,"next_id":self.n+1,"nodes":self.nodes}
        if side: g["side"]=side
        path=os.path.join(out_dir,rel)
        os.makedirs(os.path.dirname(path),exist_ok=True)
        json.dump(g,open(path,"w"),indent="\t")
    # helpers
    def setv(self, name, val, note=None, shared=False):
        f={"mode":"Set","name":name}
        if shared: f["scope"]="Shared"
        return self.add("var",f,{"value":val},note=note)
    def addv(self, name, val): return self.add("var",{"mode":"Add","name":name},{"value":val})
    def formula(self, expr, out, ty="float", note=None): return self.add("formula",{"expression":expr,"type":ty},{},{"result":out},note=note)
    def cond(self, op, a, b=None, note=None):
        args={"a":a}
        if b is not None: args["b"]=b
        return self.add("if",{"operator":op},args,note=note)
    def find(self, cls, name, out): return self.add("object",{"op":"Find","of":cls},{"name":name if isinstance(name, dict) else S(name)},{"result":out})
    def exists(self, obj, out): return self.add("object",{"op":"Exists"},{"object":V(obj)},{"result":out})
    def getf(self, obj, field, out): return self.add("field",{"mode":"Get","field":field},{"record":V(obj)},{"value":out})
    def setf(self, obj, field, val): return self.add("field",{"mode":"Set","field":field},{"record":V(obj),"value":val})
    def say(self, fmt, *values):
        args={k:v for k,v in zip(["first","second","third","fourth"],values)}
        line="line_%d"%(self.n+1)
        return [self.add("text",{"op":"Format","format":fmt},args,{"result":line}), self.add("print",{"newline":True},{"value":V(line)})]

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
for f in os.listdir(os.path.join(out_dir,"scripts")):  # the generator owns the scripts (player.cbricks became fighter*.cbricks)
    if f.endswith(".cbricks"):
        os.remove(os.path.join(out_dir,"scripts",f))

# ---------------------------------------------------------------- remotes
r=G()
r.add("remote",{"name":"input","direction":"To server","values":[["walk","vector2"],["yaw","float"],["pitch","float"],["trigger","bool"]]},
      note="A player's machine, every frame: which way its keys push, where its mouse looks, whether it's shooting")
r.add("remote",{"name":"hurt","direction":"To clients","values":[["amount","int"]]},note="The server tells a bitten player's machine (its camera shakes, the screen flashes red)")
r.add("remote",{"name":"hit","direction":"To clients","values":[["killed","bool"]]},note="The server tells a shooter their shot landed (a hit marker; red: it went down)")
r.dump("scripts/remotes.cbricks")

# ---------------------------------------------------------------- Fighter: a player's body (data; the scripts in its scene drive it)
p=G()
p.add("class",{"name":"Fighter","extends":"Shape3D","fields":[["walk","vector2"],["yaw","float"],["pitch","float"],["trigger","bool"],["cooldown","float"],
      ["health","int"],["score","int"],["down","float"],["home","vector3"]],"synced":"health, score, down"},
      note="A player's body: scenes/fighter.cbscene's root. Its Input script (on the player's machine) sends walk / yaw / pitch / trigger; its Brain script (on the server) moves it")
cr=p.add("created",note="On the server (players' machines get a copy)")
visor=p.add("new_object",{"of":"Shape3D","world":False},{},{"object":"visor"},note="A visor: shows where it faces")
p.link(cr,"out",[p.chain([p.setv("size",V3("0.8, 1.8, 0.8")), p.setv("health",I(100)), visor,
                          p.setf("visor","position",V3("0, 0.55, -0.42")), p.setf("visor","size",V3("0.6, 0.2, 0.1")), p.setf("visor","color",S("#212121")),
                          p.add("object",{"op":"Set parent"},{"object":V("visor"),"parent":V("self")})])])
hurt=p.add("function",{"name":"hurt","returns":"void","params":[["amount","int"]]},note="An enemy bit it (on the server): its player's machine is told")
own=p.add("ownership",{"do":"Owner"},{"object":V("self")},{"result":"who"})
tell=p.add("fire_clients",{"remote":"hurt","to":"One player"},{"player":V("who"),"amount":V("amount")})
p.link(hurt,"out",[p.chain([p.addv("health",{"type":"int","value":"-amount"}), own, tell])])
p.dump("scripts/fighter.cbricks")

# ---------------------------------------------------------------- Input: the player's machine (a LocalScript in the Fighter scene)
c=G()
st=c.add("start",note="Runs on the machine of the player this Fighter was given to; parent: the Fighter")
mine=c.add("object",{"op":"As","of":"Fighter"},{"object":V("parent")},{"result":"me"})
setme=c.setv("mine",V("me"),note="Kept (Shared) for the frame events",shared=True)
y0=c.setv("yaw",F(0),shared=True); p0=c.setv("pitch",F(0),shared=True); t0=c.setv("shake_cd",F(0),shared=True)
nm=c.add("player",{"op":"Name"},{},{"result":"my_name"},note="Blank Player: the owner of the Fighter it's in")
h0=c.setv("hit_t",F(0),shared=True); f0=c.setv("flash_t",F(0),shared=True)
start_chain=[mine,setme,y0,p0,t0,h0,f0,nm]+c.say("Welcome, {}! Mouse to look, WASD to move, click to shoot.",V("my_name"))
c.link(st,"out",[c.chain(start_chain)])
# When frame starts: read this machine's input, look at once, send it
fs=c.add("frame_start",note="This machine's input, every frame: sent to the server (nothing while the title menu is up)")
have=c.exists("mine","have")
hif=c.cond("is true",V("have"))
title=c.find("Panel","Title","title")
tv=c.getf("title","visible","menu_up")
mif=c.cond("is true",V("menu_up"),note="The menu's up: stand still (the server keeps the last input it got)")
c.link(mif,"true",[c.add("fire_server",{"remote":"input"},{"walk":V2("0, 0"),"yaw":V("yaw"),"pitch":V("pitch"),"trigger":B("false")})])
if auto:
    rd=[c.setv("mx",F(0)), c.setv("my",F(0)), c.setv("keys",V2("0, 0")),
        c.add("args",{"what":"Flag"},{"name":S("autofire")},{"result":"fire"},note="(the test: --autofire shoots by itself)")]
else:
    rd=[c.add("mouse",{"what":"Movement"},{},{"x":"mx","y":"my"},note="Mouse look"),
        c.add("key_direction",{"left":"A","right":"D","forward":"W","back":"S"},{},{"result":"keys"}),
        c.add("input",{"when":"Mouse down","button":"LEFT"},{},{"result":"fire"})]
rd+=[c.formula("yaw - mx * 0.0025","yaw"), c.formula("fmax(-1.4, fmin(1.4, pitch - my * 0.0025))","pitch"),
     c.add("fire_server",{"remote":"input"},{"walk":V("keys"),"yaw":V("yaw"),"pitch":V("pitch"),"trigger":V("fire")},note="The server moves and shoots with it")]
kick=c.cond("is true",{"type":"bool","value":"fire && shake_cd <= 0"},note="A little kick when shooting (the server decides what's hit)")
c.link(kick,"true",[c.chain([c.add("shake_camera",{},{"strength":F(0.04),"duration":F(0.1)}), c.setv("shake_cd",F(0.2))])])
rd+=[c.addv("shake_cd",FX("-dt")), kick]
c.link(mif,"false",[c.chain(rd)])
c.link(hif,"true",[c.chain([title,tv,mif])])
c.link(fs,"out",[c.chain([have,hif])])
# When frame ends: the camera (my own yaw / pitch, at once) and the HUD
fe=c.add("frame_end",note="After everything moved: my camera and my HUD")
have2=c.exists("mine","have")
hif2=c.cond("is true",V("have"))
cam=[c.getf("mine","position","at"),
     c.add("vector",{"op":"Add"},{"a":V("at"),"b":V3("0, 0.6, 0")},{"result":"eye"},note="Eye height"),
     c.add("vector",{"op":"Make","dims":"3D"},{"x":FX("-sin(yaw) * cos(pitch)"),"y":FX("sin(pitch)"),"z":FX("-cos(yaw) * cos(pitch)")},{"result":"look"}),
     c.find("Camera3D","Camera","cam"), c.setf("cam","position",V("eye")),
     c.add("vector",{"op":"Add"},{"a":V("eye"),"b":V("look")},{"result":"aim"}), c.setf("cam","target",V("aim")),
     c.setf("mine","visible",B("false")),
     c.add("object",{"op":"Children"},{"object":V("mine")},{"result":"parts"})]
each=c.add("for_each",{},{"list":V("parts")},{"item":"part"},note="My own body and visor aren't drawn on my screen (the server never changes visible)")
asb=c.add("object",{"op":"As","of":"Shape3D"},{"object":V("part")},{"result":"bit"})
isb=c.cond("is true",{"type":"bool","value":"bit != NULL"})
c.link(isb,"true",[c.setf("bit","visible",B("false"))])
c.link(each,"loop",[c.chain([asb,isb])])
cam.append(each)
hud=[c.getf("mine","health","hp"), c.getf("mine","score","pts"), c.find("Label","Score","score_label"),
      c.add("text",{"op":"Format","format":"Score: {}"},{"first":V("pts")},{"result":"line"}),
      c.setf("score_label","text",V("line")),
      c.find("Bar","Health","health_bar"), c.formula("hp","hpf"), c.setf("health_bar","value",V("hpf")),
      c.find("Panel","Message","msg")]
dead=c.cond("<=",V("hp"),I(0),note="Caught: the server brings it back 3 s later (the Message panel counts down meanwhile)")
c.link(dead,"true",[c.chain([c.getf("mine","down","down"), c.formula("(int)ceil(3.0 - down) > 1 ? (int)ceil(3.0 - down) : 1","secs","int"),
                             c.find("Label","Caught","caught"), c.add("text",{"op":"Format","format":"You were caught! Back in {}..."},{"first":V("secs")},{"result":"ctext"}),
                             c.setf("caught","text",V("ctext")), c.setf("msg","visible",B("true"))])])
c.link(dead,"false",[c.setf("msg","visible",B("false"))])
hud.append(dead)
# the hit marker and the red flash fade out (timers set by the server's messages)
hud+=[c.addv("hit_t",FX("-dt")), c.find("Label","HitMarker","marker"), c.formula("hit_t > 0","marking","bool"), c.setf("marker","visible",V("marking")),
      c.addv("flash_t",FX("-dt")), c.find("Panel","Flash","flash"), c.formula("flash_t > 0","flashing","bool"), c.setf("flash","visible",V("flashing"))]
# the scoreboard: Tab held (tests: --scores), not on the menu; rows sorted by score
tab=c.add("input",{"when":"Key down","key":"TAB"},{},{"result":"tab"})
sflag=c.add("args",{"what":"Flag"},{"name":S("scores")},{"result":"scores_flag"},note="(tests: --scores shows it)")
show=c.formula("(tab || scores_flag) && !menu_up2","show","bool")
board=c.find("Panel","Scores","board")
hud+=[c.find("Panel","Title","title2"), c.getf("title2","visible","menu_up2"), tab, sflag, show, board, c.setf("board","visible",V("show"))]
fill=c.cond("is true",V("show"))
keys=[c.add("list",{"op":"Make","of":"int"},{},{"result":"ranks"}), c.add("player",{"op":"Players"},{},{"result":"everyone"})]
ek=c.add("for_each",{},{"list":V("everyone")},{"item":"pl"},note="score * 100 + player: sorted, the best last")
kn=c.add("player",{"op":"Name"},{"player":V("pl")},{"result":"pname"})
kf=c.find("Fighter",V("pname"),"theirs")
ke=c.exists("theirs","has_theirs")
ki=c.cond("is true",V("has_theirs"))
c.link(ki,"true",[c.chain([c.getf("theirs","score","their_score"), c.formula("their_score * 100 + pl","key","int"), c.add("list",{"op":"Add"},{"list":V("ranks"),"value":V("key")})])])
c.link(ek,"loop",[c.chain([kn,kf,ke,ki])])
keys+=[ek, c.add("list",{"op":"Sort"},{"list":V("ranks")}), c.add("list",{"op":"Reverse"},{"list":V("ranks")}), c.add("list",{"op":"Length"},{"list":V("ranks")},{"result":"count"})]
rows=c.add("for",{},{"from":I(0),"to":I(8),"step":I(1)},{"index":"i"},note="Eight rows: the first count shown")
rn=c.add("text",{"op":"Format","format":"Row{}"},{"first":V("i")},{"result":"rname"})
rf=c.find("HBox",V("rname"),"row")
used=c.formula("i < count","used","bool")
rv=c.setf("row","visible",V("used"))
ri=c.cond("is true",V("used"))
c.link(ri,"true",[c.chain([c.add("list",{"op":"Get"},{"list":V("ranks"),"index":V("i")},{"result":"k"}),
                           c.formula("k % 100","who","int"), c.formula("k / 100","their_pts","int"),
                           c.add("player",{"op":"Name"},{"player":V("who")},{"result":"wname"}),
                           c.find("Fighter",V("wname"),"wf"), c.getf("wf","health","whp"),
                           c.add("text",{"op":"Format","format":"Name{}"},{"first":V("i")},{"result":"n1"}), c.find("Label",V("n1"),"l1"), c.setf("l1","text",V("wname")),
                           c.add("text",{"op":"Format","format":"Pts{}"},{"first":V("i")},{"result":"n2"}), c.find("Label",V("n2"),"l2"),
                           c.add("text",{"op":"Format","format":"{}"},{"first":V("their_pts")},{"result":"t2"}), c.setf("l2","text",V("t2")),
                           c.add("text",{"op":"Format","format":"Hp{}"},{"first":V("i")},{"result":"n3"}), c.find("Label",V("n3"),"l3"),
                           c.add("text",{"op":"Format","format":"{}"},{"first":V("whp")},{"result":"t3"}), c.setf("l3","text",V("t3"))])])
c.link(rows,"loop",[c.chain([rn,rf,used,rv,ri])])
c.link(fill,"true",[c.chain(keys+[rows])])
hud.append(fill)
c.link(hif2,"true",[c.chain(cam+hud)])
c.link(fe,"out",[c.chain([have2,hif2])])
# the server says I was bitten
hu=c.add("on_server_fired",{"remote":"hurt"})
c.link(hu,"out",[c.chain([c.add("shake_camera",{},{"strength":F(0.25),"duration":F(0.3)}), c.setv("flash_t",F(0.2))])])
# the server says my shot landed: a hit marker (red when it went down)
hh=c.add("on_server_fired",{"remote":"hit"})
hm=c.find("Label","HitMarker","marker2")
hc=c.cond("is true",V("killed"))
c.link(hc,"true",[c.setf("marker2","color",S("#ff5252"))])
c.link(hc,"false",[c.setf("marker2","color",S("WHITE"))])
c.link(hh,"out",[c.chain([c.setv("hit_t",F(0.15)),hm,hc])])
c.dump("scripts/fighter_input.cbricks","Client")

# ---------------------------------------------------------------- Brain: where the rules run (a Script in the Fighter scene)
s=G()
oc=s.add("on_client_fired",{"remote":"input"},note="A player's input: kept on their Fighter (any client can send anything: only their own)")
sn=s.add("player",{"op":"Name"},{"player":V("sender")},{"result":"who"})
sf=s.find("Fighter",V("who"),"f")
se=s.exists("f","is_there")
si=s.cond("is true",V("is_there"))
s.link(si,"true",[s.chain([s.setf("f","walk",V("walk")), s.setf("f","yaw",V("yaw")), s.setf("f","pitch",FX("fmax(-1.4, fmin(1.4, pitch))")), s.setf("f","trigger",V("trigger"))])])
s.link(oc,"out",[s.chain([sn,sf,se,si])])
fs=s.add("frame_start",note="Every frame, every player's Fighter: move, shoot, come back after being caught")
everyone=s.add("player",{"op":"Players"},{},{"result":"everyone"})
each=s.add("for_each",{},{"list":V("everyone")},{"item":"pl"})
pn=s.add("player",{"op":"Name"},{"player":V("pl")},{"result":"pname"})
pf=s.find("Fighter",V("pname"),"f")
pe=s.exists("f","has_f")
pi=s.cond("is true",V("has_f"))
hp=s.getf("f","health","hp")
alive=s.cond(">",V("hp"),I(0))
move=[s.getf("f","walk","walk"), s.getf("f","yaw","yaw"), s.getf("f","pitch","pitch"),
      s.add("vector",{"op":"Make","dims":"3D"},{"x":FX("(walk.x * cos(yaw) + walk.y * sin(yaw)) * 6.0 * dt"),"y":F(0),"z":FX("(walk.y * cos(yaw) - walk.x * sin(yaw)) * 6.0 * dt")},{"result":"step"},note="WASD, turned by where they look"),
      s.add("move_collide",{},{"part":V("f"),"motion":V("step")},{"blocked":""},note="Walls and crates stop them"),
      s.add("vector",{"op":"Make","dims":"3D"},{"x":F(0),"y":FX("yaw * 57.29578"),"z":F(0)},{"result":"turn"}), s.setf("f","rotation",V("turn")),
      s.getf("f","cooldown","cd"), s.formula("cd - dt","cd"), s.setf("f","cooldown",V("cd")), s.getf("f","trigger","trig")]
can=s.cond("is true",{"type":"bool","value":"trig && cd <= 0"},note="A shot through their crosshair")
shot=[s.setf("f","cooldown",F(0.2)), s.getf("f","position","at"),
      s.add("vector",{"op":"Add"},{"a":V("at"),"b":V3("0, 0.6, 0")},{"result":"eye"}),
      s.add("vector",{"op":"Make","dims":"3D"},{"x":FX("-sin(yaw) * cos(pitch) * 100"),"y":FX("sin(pitch) * 100"),"z":FX("-cos(yaw) * cos(pitch) * 100")},{"result":"reach"}),
      s.add("vector",{"op":"Add"},{"a":V("eye"),"b":V("reach")},{"result":"ray_end"})]
ray=s.add("raycast",{},{"from":V("eye"),"to":V("ray_end"),"ignore":V("f")},{"hit":"target","point":"spot"})
spark=s.add("new_object",{"of":"Spark","world":True},{},{"object":"flash"})
as1=s.add("object",{"op":"As","of":"Enemy"},{"object":V("target")},{"result":"enemy"})
up=s.add("object",{"op":"Parent"},{"object":V("target")},{"result":"holder"},note="Hit its visor? Then its body")
as2=s.add("object",{"op":"As","of":"Enemy"},{"object":V("holder")},{"result":"enemy2"})
e1=s.exists("enemy","is_enemy"); c1=s.cond("is true",V("is_enemy"))
e2=s.exists("enemy2","is_enemy2"); c2=s.cond("is true",V("is_enemy2"))
s.link(c2,"true",[s.setv("enemy",V("enemy2"))])
c3=s.cond("is true",{"type":"bool","value":"is_enemy || is_enemy2"})
dmg=s.add("call_method",{"class":"Enemy","method":"damage"},{"object":V("enemy"),"amount":I(25)},{"result":"killed"})
k=s.cond("is true",V("killed"))
s.link(k,"true",[s.chain([s.getf("f","score","pts"), s.formula("pts + 1","pts","int"), s.setf("f","score",V("pts"))] + s.say("[server] {} got one ({})",V("pname"),V("pts")))])
tell=s.add("fire_clients",{"remote":"hit","to":"One player"},{"player":V("pl"),"killed":V("killed")},note="The shooter's hit marker")
s.link(c3,"true",[s.chain([dmg,k,tell])])
s.link(ray,"hit",[s.chain([spark, s.setf("flash","position",V("spot")), as1, up, as2, e1, c1, e2, c2, c3])])
shot.append(ray)
s.link(can,"true",[s.chain(shot)])
move.append(can)
s.link(alive,"true",[s.chain(move)])
back=[s.getf("f","down","down"), s.formula("down + dt","down"), s.setf("f","down",V("down"))]
up2=s.cond(">=",V("down"),F(3),note="3 seconds after being caught: back home, healed")
s.link(up2,"true",[s.chain([s.setf("f","health",I(100)), s.setf("f","down",F(0)), s.getf("f","home","home"), s.setf("f","position",V("home"))])])
back.append(up2)
s.link(alive,"false",[s.chain(back)])
s.link(pi,"true",[s.chain([hp,alive])])
s.link(each,"loop",[s.chain([pn,pf,pe,pi])])
s.link(fs,"out",[s.chain([everyone,each])])
s.dump("scripts/fighter_server.cbricks","Server")

# ---------------------------------------------------------------- rules: players coming and going (Server)
rl=G()
pj=rl.add("player_joined",note="Each player gets a Fighter (scenes/fighter.cbscene): theirs, so its Input script runs on their machine")
mk=rl.add("scene",{"do":"Instance","scene":"scenes/fighter.cbscene"},{"parent":NONE},{"root":"f"})
pn=rl.add("player",{"op":"Name"},{"player":V("player")},{"result":"pname"})
nmf=rl.add("object",{"op":"Set name"},{"object":V("f"),"name":V("pname")})
gv=rl.add("ownership",{"do":"Give to"},{"object":V("f"),"player":V("player")})
cnt=rl.add("formula",{"expression":"spawned % 3","type":"int"},{},{"result":"slot"},note="Three places to start from, in turn")
spot=rl.add("vector",{"op":"Make","dims":"3D"},{"x":FX("1.5 * slot"),"y":F(0.9),"z":FX("8.0 + 2.5 * slot")},{"result":"spot"})
cols=rl.add("list",{"op":"Make","of":"string"},{},{"result":"colors"})
adds=[rl.add("list",{"op":"Add"},{"list":V("colors"),"value":S(x)}) for x in ["#1e88e5","#43a047","#fdd835","#8e24aa","#fb8c00"]]
pick=rl.add("list",{"op":"Get"},{"list":V("colors"),"index":{"type":"int","value":"(player - 1) % 5"}},{"result":"color"})
rl.link(pj,"out",[rl.chain([mk,pn,nmf,gv,cnt,spot,rl.setf("f","home",V("spot")),rl.setf("f","position",V("spot")),cols]+adds+[pick,rl.setf("f","color",V("color")),rl.addv("spawned",I(1))]+rl.say("[server] {} joined",V("pname")))])
pl=rl.add("player_left",note="What they own goes with them")
pn2=rl.add("player",{"op":"Name"},{"player":V("player")},{"result":"pname"})
ob=rl.add("ownership",{"do":"Owned by"},{"player":V("player")},{"result":"theirs"})
eo=rl.add("for_each",{},{"list":V("theirs")},{"item":"thing"})
rl.link(eo,"loop",[rl.add("destroy",{},{"object":V("thing")})])
rl.link(pl,"out",[rl.chain([pn2,ob,eo]+rl.say("[server] {} left",V("pname")))])
st=rl.add("start",note="(a Script object: where the rules run)")
rl.link(st,"out",[rl.setv("spawned",I(0),shared=True)])
rl.dump("scripts/rules.cbricks","Server")

# ---------------------------------------------------------------- Enemy (the server runs it)
e=G()
e.add("class",{"name":"Enemy","extends":"Shape3D","fields":[["hp","int"],["speed","float"],["bite","float"],["bar","Shape3D"]],"synced":"hp"},note="A block that chases the nearest Fighter, its health in a bar over its head")
cr=e.add("created")
visor=e.add("new_object",{"of":"Shape3D","world":False},{},{"object":"visor"},note="A visor: shows where it faces")
e.link(cr,"out",[e.chain([e.setv("color",S("#d32f2f")), e.setv("size",V3("1, 1.8, 1")), e.setv("solid",B("true")), e.setv("hp",I(100)), e.setv("speed",F(2.2 if not auto else 0.6)),
                 visor, e.setf("visor","position",V3("0, 0.5, -0.5")), e.setf("visor","size",V3("0.7, 0.22, 0.1")), e.setf("visor","color",S("#ffeb3b")),
                 e.add("object",{"op":"Set parent"},{"object":V("visor"),"parent":V("self")}),
                 e.add("new_object",{"of":"Shape3D","world":False},{},{"object":"bar"},note="Its health bar (a thin 3D bar over its head)"),
                 e.setf("bar","position",V3("0, 1.2, 0")), e.setf("bar","size",V3("1, 0.12, 0.12")), e.setf("bar","color",S("#ff5252")),
                 e.add("object",{"op":"Set parent"},{"object":V("bar"),"parent":V("self")})])])
ef=e.add("every_frame",note="On the server (players' machines get its copy)")
nf=e.add("nearest",{"of":"Fighter"},{"from":V("position"),"range":F(0),"except":NONE},{"result":"prey","distance":""},note="The nearest player")
here=e.exists("prey","has_prey")
chase=e.cond("is true",V("has_prey"))
body=[e.getf("prey","position","goal"), e.getf("prey","health","their_health"),
      e.add("vector",{"op":"Subtract"},{"a":V("goal"),"b":V("position")},{"result":"to"}),
      e.add("vector",{"op":"Make","dims":"3D"},{"x":FX("to.x"),"y":F(0),"z":FX("to.z")},{"result":"flat"}),
      e.add("vector",{"op":"Length"},{"a":V("flat")},{"result":"dist"}),
      e.add("vector",{"op":"Make","dims":"3D"},{"x":F(0),"y":FX("atan2(-flat.x, -flat.z) * 57.29578"),"z":F(0)},{"result":"rotation"})]
near=e.cond(">",V("dist"),F(1.3))
e.link(near,"true",[e.chain([e.add("vector",{"op":"Normalize"},{"a":V("flat")},{"result":"dir"}),
                    e.add("vector",{"op":"Scale"},{"a":V("dir"),"factor":FX("speed * dt")},{"result":"step"}),
                    e.add("move_collide",{},{"part":V("self"),"motion":V("step")},{"blocked":""})])])
body.append(near)
body.append(e.addv("bite",FX("-dt")))
biting=e.cond("is true",{"type":"bool","value":"dist < 1.6 && bite <= 0 && their_health > 0"})
e.link(biting,"true",[e.chain([e.add("call_method",{"class":"Fighter","method":"hurt"},{"object":V("prey"),"amount":I(10)}), e.setv("bite",F(1))])])
body.append(biting)
e.link(chase,"true",[e.chain(body)])
sz=e.add("vector",{"op":"Make","dims":"3D"},{"x":FX("fmax(0.05, hp / 100.0)"),"y":F(0.12),"z":F(0.12)},{"result":"bar_size"},note="The bar shows its health")
e.link(ef,"out",[e.chain([nf,here,chase,sz,e.setf("bar","size",V("bar_size"))])])
dm=e.add("function",{"name":"damage","returns":"bool","params":[["amount","int"]]},note="Shot: true when it went down (it comes back at the far wall)")
gone=e.cond("<=",{"type":"int","value":"hp - amount"},I(0))
e.link(gone,"true",[e.chain([e.setv("hp",I(100)),
                    e.add("random",{},{"min":I(-12),"max":I(12)},{"result":"rx"}),
                    e.add("vector",{"op":"Make","dims":"3D"},{"x":V("rx"),"y":F(0.9),"z":F(-13)},{"result":"position"}),
                    e.add("return",{"gives":"A value"},{"value":B("true")})])])
e.link(dm,"out",[e.chain([gone, e.addv("hp",{"type":"int","value":"-amount"}), e.add("return",{"gives":"A value"},{"value":B("false")})])])
e.dump("scripts/enemy.cbricks")

# ---------------------------------------------------------------- Spark (made by the server, copied to everyone)
k=G()
k.add("class",{"name":"Spark","extends":"Shape3D","fields":[["life","float"]],"synced":""},note="Where a shot hit: gone after a moment")
cr=k.add("created")
k.link(cr,"out",[k.chain([k.setv("size",V3("0.14")), k.setv("color",S("#ffeb3b")), k.setv("life",F(0.12))])])
ef=k.add("every_frame")
over=k.cond("<=",V("life"),F(0))
k.link(over,"true",[k.add("destroy",{},{"object":V("self")})])
k.link(ef,"out",[k.chain([k.addv("life",FX("-dt")),over])])
k.dump("scripts/spark.cbricks")

# ---------------------------------------------------------------- main: the window, the enemies (where the rules run), host / join, tests
m=G()
st=m.add("start")
main=[m.add("window",{"esc_closes":False},{"width":I(960),"height":I(540),"title":S("Arena"),"fps":I(60)},note="Escape opens the menu (not closes the window)"),
      m.add("args",{"what":"Option"},{"name":S("quit-after")},{"result":"qa_text"},note="--quit-after N: stop after N seconds (tests)"),
      m.add("text",{"op":"To float"},{"text":V("qa_text")},{"result":"quit_after"}),
      m.add("network",{"do":"Is server"},{},{"result":"rules"})]
rif=m.cond("is true",V("rules"),note="Where the rules run: the enemies")
if auto:
    one=m.add("new_object",{"of":"Enemy","world":True},{},{"object":"foe"},note="Test: one enemy straight ahead")
    m.link(rif,"true",[m.chain([one, m.setf("foe","position",V3("0, 0.9, 2"))])])
else:
    loop=m.add("for",{},{"from":I(0),"to":I(5),"step":I(1)},{"index":""},note="Five enemies along the far side")
    foe=m.add("new_object",{"of":"Enemy","world":True},{},{"object":"foe"})
    rx=m.add("random",{},{"min":I(-12),"max":I(12)},{"result":"rx"})
    rz=m.add("random",{},{"min":I(-13),"max":I(-6)},{"result":"rz"})
    pos=m.add("vector",{"op":"Make","dims":"3D"},{"x":V("rx"),"y":F(0.9),"z":V("rz")},{"result":"spot"})
    m.link(loop,"loop",[m.chain([foe,rx,rz,pos,m.setf("foe","position",V("spot"))])])
    m.link(rif,"true",[loop])
main.append(rif)
if title_shown:
    main.append(m.add("pause",{"do":"Pause"},note="On the title menu: the world waits (offline)"))
main.append(m.setv("frames",I(0)))
r0=m.add("network",{"do":"Role"},{},{"result":"role0"})
gone=m.cond("!=",V("role0"),S("offline"),note="Started in a network game (--join, --host): no menu")
m.link(gone,"true",[m.chain([m.find("Panel","Title","t0"), m.setf("t0","visible",B("false")), m.add("pause",{"do":"Resume"})] + ([] if auto else [m.add("mouse_mode",{"mode":"Captured"})]))])
main+=[r0,gone]
gl=m.add("game_loop",note="The world runs itself; the Fighters' scripts and the Enemies do the rest")
main.append(gl)
m.link(st,"out",[m.chain(main)])
frame=[m.addv("frames",I(1)), m.add("network",{"do":"Role"},{},{"result":"role"})]
# the title menu (UI): Escape toggles it; Host / Join only offline
esc=m.add("input",{"when":"Key pressed","key":"ESCAPE"},{},{"result":"esc"})
tp=m.find("Panel","Title","title")
eif=m.cond("is true",V("esc"),note="Escape: the menu (and the mouse back), or the game again")
up=m.getf("title","visible","menu_up")
tog=m.cond("is true",V("menu_up"))
m.link(tog,"true",[m.chain([m.setf("title","visible",B("false")), m.add("mouse_mode",{"mode":"Captured"}), m.add("pause",{"do":"Resume"})])])
m.link(tog,"false",[m.chain([m.setf("title","visible",B("true")), m.add("mouse_mode",{"mode":"Visible"}), m.add("pause",{"do":"Pause"},note="Offline the world stops behind the menu; in a network game it runs on")])])
m.link(eif,"true",[m.chain([up,tog])])
off=m.add("compare",{"op":"!="},{"a":V("role"),"b":S("offline")},{"result":"online"})
hb=m.find("Button","Host","host_b"); jb=m.find("Button","Join","join_b")
frame+=[esc,tp,eif,off,hb,m.setf("host_b","disabled",V("online")),jb,m.setf("join_b","disabled",V("online"))]
def play_and(g, extra, label):
    """Hide the menu, capture the mouse (mouse look), then `extra`."""
    return g.chain(extra + [g.find("Panel","Title","t2"), g.setf("t2","visible",B("false")), g.add("mouse_mode",{"mode":"Captured"}), g.add("pause",{"do":"Resume"})] + g.say(label))
bp=m.add("button_clicked",{"button":"Play"},note="The menu's buttons (When button clicked: no class needed)")
m.link(bp,"out",[play_and(m,[],"Playing single-player")])
bh=m.add("button_clicked",{"button":"Host"})
hosted=m.add("network",{"do":"Host"},{"port":I(7000)},{"result":"hosted"})
m.link(bh,"out",[play_and(m,[hosted],"Hosting on port 7000")])
bj=m.add("button_clicked",{"button":"Join"})
joined=m.add("network",{"do":"Join"},{"address":S("127.0.0.1"),"port":I(7000),"timeout":F(3)},{"result":"joined"})
m.link(bj,"out",[play_and(m,[joined],"Joined 127.0.0.1:7000")])
bq=m.add("button_clicked",{"button":"Quit"})
m.link(bq,"out",[m.add("close_window")])
# the end: --quit-after (network tests), or (single-player tests) a frame count
me=m.add("player",{"op":"Me"},{},{"result":"me"})
mn=m.add("player",{"op":"Name"},{"player":V("me")},{"result":"mname"})
t=m.add("game_info",{"what":"Time"},{},{"result":"t"})
end_at=150 if auto else 40
qend=m.formula("quit_after > 0 ? t > quit_after : %s" % ("frames == %d" % end_at if test and not net else "false"),"done","bool")
qif=m.cond("is true",V("done"))
ending=[m.find("Fighter",V("mname"),"pl"), m.exists("pl","has_pl")]
sc_if=m.cond("is true",V("has_pl"))
m.link(sc_if,"true",[m.getf("pl","score","final")])
ending.append(sc_if)
if menu:
    mshot=m.cond("==",V("frames"),I(8))
    m.link(mshot,"true",[m.add("raw_c",{"code":"cb_screenshot(\"arena_menu.png\");"})])
    frame.append(mshot)
if test:
    if net:
        ending+=[m.add("text",{"op":"Format","format":"arena_{}.png"},{"first":V("mname")},{"result":"shot"}),
                 m.add("raw_c",{"code":"if (strcmp(role, \"server\") != 0) cb_screenshot(shot);"})]
        ending+=m.say("[final] {} {}: score {}",V("role"),V("mname"),V("final"))
    else:
        ending+=[m.add("raw_c",{"code":"cb_screenshot(\"arena.png\");"})]
        ending+=m.say("score {}",V("final"))
ending.append(m.add("close_window"))
m.link(qif,"true",[m.chain(ending)])
frame+=[me,mn,t,qend,qif]
m.link(gl,"frame",[m.chain(frame)])
m.dump("main.cbricks")

# ---------------------------------------------------------------- scenes
objs=[
 {"class":"Camera3D","name":"Camera","parent":0,"fields":{"fov":"75","position":"0, 1.5, 8","target":"0, 1.5, 7"},"groups":["local"]},
 {"class":"Light3D","name":"Sun","parent":0,"fields":{"rotation":"-59.8, 30.9, 0"}},
 {"class":"Shape3D","name":"Floor","parent":0,"fields":{"size":"30, 0.2, 30","position":"0, -0.1, 0","color":"#455a64"}},
 {"class":"Spatial3D","name":"Walls","parent":0,"fields":{}},
 {"class":"Environment","name":"Environment","parent":0,"fields":{"sky":"#1d2b3a","ambient":"0.45","fog":"0.02"}},
]
walls=[("North wall","0, 1.5, -15","30.6, 3, 0.6"),("South wall","0, 1.5, 15","30.6, 3, 0.6"),("West wall","-15, 1.5, 0","0.6, 3, 30"),("East wall","15, 1.5, 0","0.6, 3, 30")]
crates=[("Crate","-5, 0.75, -3","1.5, 1.5, 1.5"),("Crate 2","4, 0.75, -6","1.5, 1.5, 1.5"),("Crate 3","7, 1, 2","2, 2, 2"),("Crate 4","-8, 0.75, 4","1.5, 1.5, 3"),("Pillar","0, 2, -9","1, 4, 1"),("Low wall","-2, 0.5, 4","4, 1, 0.5")]
nid=1
for o in objs:
    o["id"]=nid; nid+=1
walls_id=4
for n,pos,size in walls:
    objs.append({"id":nid,"class":"Shape3D","name":n,"parent":walls_id,"fields":{"position":pos,"size":size,"color":"#78909c","solid":"true"}}); nid+=1
for n,pos,size in crates:
    objs.append({"id":nid,"class":"Shape3D","name":n,"parent":0,"fields":{"position":pos,"size":size,"color":"#a1887f","solid":"true"}}); nid+=1
objs.append({"id":nid,"class":"Script","name":"Rules","parent":0,"script":"scripts/rules.cbricks","fields":{}}); nid+=1
# The HUD (UI, 2026-11-07): in window pixels, on top, each machine's own (never sent).
hud_id=nid
objs.append({"id":nid,"class":"Control","name":"HUD","parent":0,"fields":{"anchor":"full"}}); nid+=1
objs.append({"id":nid,"class":"Panel","name":"Flash","parent":hud_id,"fields":{"anchor":"full","color":"#ff000050","visible":"false"}}); nid+=1
back_id=nid
objs.append({"id":nid,"class":"Panel","name":"Stats","parent":hud_id,"fields":{"anchor":"top_left","offset":"12, 12","size":"230, 64","radius":"8","color":"#00000090"}}); nid+=1
objs.append({"id":nid,"class":"Label","name":"Score","parent":back_id,"fields":{"anchor":"top_left","offset":"12, 8","size":"200, 22","font_size":"22","text":"Score: 0"}}); nid+=1
objs.append({"id":nid,"class":"Bar","name":"Health","parent":back_id,"fields":{"anchor":"bottom_left","offset":"12, -10","size":"206, 14","value":"100","color":"#e53935"}}); nid+=1
objs.append({"id":nid,"class":"Label","name":"Crosshair","parent":hud_id,"fields":{"anchor":"center","size":"40, 36","font_size":"36","align":"center","text":"+"}}); nid+=1
objs.append({"id":nid,"class":"Label","name":"HitMarker","parent":hud_id,"fields":{"anchor":"center","offset":"0, 1","size":"60, 40","font_size":"40","align":"center","text":"x","visible":"false"}}); nid+=1
# the scoreboard (Tab): a Panel, a VBox of rows (HBoxes: name, score, health)
sb_id=nid
objs.append({"id":nid,"class":"Panel","name":"Scores","parent":hud_id,"fields":{"anchor":"center","size":"440, 292","radius":"10","color":"#000000c0","border":"1","border_color":"#ffffff50","visible":"false"}}); nid+=1
rows_id=nid
objs.append({"id":nid,"class":"VBox","name":"Rows","parent":sb_id,"fields":{"anchor":"full","padding":"14","separation":"4"}}); nid+=1
head_id=nid
objs.append({"id":nid,"class":"HBox","name":"Head","parent":rows_id,"fields":{"size":"400, 30"}}); nid+=1
for name, w, text in [("HName",230,"Player"),("HPts",80,"Score"),("HHp",80,"Health")]:
    objs.append({"id":nid,"class":"Label","name":name,"parent":head_id,"fields":{"size":"%d, 26" % w,"font_size":"22","color":"#ffeb3b","text":text}}); nid+=1
for i in range(8):
    row_id=nid
    objs.append({"id":nid,"class":"HBox","name":"Row%d" % i,"parent":rows_id,"fields":{"size":"400, 26","visible":"false"}}); nid+=1
    for name, w in [("Name",230),("Pts",80),("Hp",80)]:
        objs.append({"id":nid,"class":"Label","name":"%s%d" % (name, i),"parent":row_id,"fields":{"size":"%d, 22" % w,"font_size":"20","text":""}}); nid+=1
msg_id=nid
objs.append({"id":nid,"class":"Panel","name":"Message","parent":hud_id,"fields":{"anchor":"center","offset":"0, -90","size":"620, 56","radius":"10","color":"#000000b0","border":"2","border_color":"#ffeb3b","visible":"false"}}); nid+=1
objs.append({"id":nid,"class":"Label","name":"Caught","parent":msg_id,"fields":{"anchor":"center","size":"600, 30","font_size":"30","align":"center","color":"#ffeb3b","text":"You were caught! Back in a moment..."}}); nid+=1
# the title menu (UI): shown when the example starts, and on Escape
title_id=nid
objs.append({"id":nid,"class":"Panel","name":"Title","parent":0,"fields":{"anchor":"full","color":"#0b1520d8","visible":"true" if title_shown else "false"}}); nid+=1
objs.append({"id":nid,"class":"Label","name":"Logo","parent":title_id,"fields":{"anchor":"top","offset":"0, 70","size":"500, 70","font_size":"72","align":"center","color":"#ffeb3b","text":"ARENA"}}); nid+=1
menu_id=nid
objs.append({"id":nid,"class":"VBox","name":"Menu","parent":title_id,"fields":{"anchor":"center","offset":"0, 30","size":"260, 206","separation":"10"}}); nid+=1
for name in ["Play","Host","Join","Quit"]:
    objs.append({"id":nid,"class":"Button","name":name,"parent":menu_id,"fields":{"size":"260, 44","font_size":"24","text":name if name != "Join" else "Join (127.0.0.1)","radius":"8"}}); nid+=1
objs.append({"id":nid,"class":"Label","name":"Hint","parent":title_id,"fields":{"anchor":"bottom","offset":"0, -24","size":"900, 20","font_size":"20","align":"center","color":"#ffffffa0","text":"Mouse: look   WASD: move   Click: shoot   Tab: scores   Esc: menu"}}); nid+=1
for old in ["world.cnworld"]:
    if os.path.exists(os.path.join(out_dir, old)):
        os.remove(os.path.join(out_dir, old))
objs=rooted(objs)
json.dump({"format":"c-bricks-scene","version":4,"next_id":max(o["id"] for o in objs)+1,"objects":objs},open(os.path.join(out_dir,"main.cbscene"),"w"),indent="\t")
os.makedirs(os.path.join(out_dir,"scenes"),exist_ok=True)
fighter=[{"id":1,"class":"Fighter","name":"Fighter","parent":0,"fields":{"color":"#1e88e5"}},
         {"id":2,"class":"LocalScript","name":"Input","parent":1,"script":"scripts/fighter_input.cbricks","fields":{}},
         {"id":3,"class":"Script","name":"Brain","parent":1,"script":"scripts/fighter_server.cbricks","fields":{}}]
json.dump({"format":"c-bricks-scene","version":4,"next_id":4,"objects":fighter},open(os.path.join(out_dir,"scenes","fighter.cbscene"),"w"),indent="\t")
open(os.path.join(out_dir,"project.cbproj"),"w").write('[project]\n\nname="Arena"\nversion="1.0"\n\n[run]\n\nargs=""\n\n[build]\n\ntarget="native"\n')
graphs=[r,p,c,s,rl,e,k,m]
print("arena:", sum(len(x.nodes) for x in graphs), "bricks,", len(objs), "world objects")

if net:
    port = "127.0.0.1:47322"
    cfg = {
        "peers": ["--server 47322 --quit-after 7.0", "--join %s --name ada --autofire --quit-after 4.6" % port, "--join %s --name bob --quit-after 3.4 --scores" % port],
        "peer_delay": 0.4,
        "expect_peer0_order": ["[server] ada joined", "[server] bob joined"],
        "expect_peer0_contains": ["[server] ada got one (1)", "[server] ada left", "[server] bob left"],
        "expect_peer0_missing": ["Welcome", "bob got one"],
        "expect_peer1_order": ["Welcome, ada!", "[final] client ada: score"],
        "expect_peer1_missing": ["Welcome, bob", "ada: score 0"],
        "expect_peer2_order": ["Welcome, bob!", "[final] client bob: score 0"],
        "expect_peer2_missing": ["Welcome, ada"],
    }
    lines = ["; examples/arena over the network (tests/make_arena.py <dir> net: change it there): a dedicated",
             "; server (port 47322, no window) and two clients. Each gets a Fighter (scenes/fighter.cbscene:",
             "; Player Joined, Instance, Give To); its Input script runs only on its owner's machine and sends",
             "; the input (Fire Server), its Brain script moves and shoots on the server. ada fires by itself",
             "; (--autofire) at the enemy ahead and scores; bob watches from behind her (her Fighter in view) and leaves first. Screenshots",
             "; arena_ada.png / arena_bob.png at the end (look at them).", "[case]"]
    for k2, v in cfg.items():
        lines.append("%s=%s" % (k2, json.dumps(v)))
    open(os.path.join(out_dir, "case.cfg"), "w").write("\n".join(lines) + "\n")

if menu:
    open(os.path.join(out_dir, "case.cfg"), "w").write("""; examples/arena's title menu (tests/make_arena.py <dir> menu: change it there): it starts on the menu
; (arena_menu.png at frame 8: ARENA, Play / Host / Join / Quit, the hint line), a --click at Play's place
; (the Menu VBox: 260 x 206 in the middle, 30 px low: Play's middle is 480, 219) starts the game: the menu
; goes, the mouse is captured; --autofire scores; --scores shows the Tab scoreboard; arena.png at frame 150.
[case]
args="--name solo --click 480:219:1.2 --autofire --scores"
expect_order=["[server] solo joined", "Welcome, solo!", "Playing single-player", "[server] solo got one (1)", "score "]
expect_missing=["score 0"]
""")
