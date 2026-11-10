# Generates the network scenario cases in tests/cases/net_*/ (several processes per case:
# the runner's `peers` mode). Change them here, then: python3 tests/make_net_cases.py
#   net_join      a dedicated server and three clients: Player Joined / Left on every
#                 machine, numbers, unique names (a second ada is ada_2), Leave back to
#                 single-player, a client that exits (its goodbye reaches the others)
#   net_host      a host (its own player is player 1) and a client
#   net_sides     Script objects run where their Side says (server / client / offline),
#                 a Server script's Player Joined only where the rules run, a blank
#                 Player in a Client script = this machine's player
#   net_world     the world copied to players: made / changed / renamed / destroyed objects,
#                 Synced fields (text, numbers, vectors gliding, object references), the Main
#                 scene matched, a late Join replacing single-player's world, group local
#   net_world_3d  a graphics game's dedicated server without a window, a client with one
#   net_remotes   Define Remote, Fire Server / On Client Fired, Fire Clients (all / one) / On
#                 Server Fired, values (text, players, objects), Synced changes arriving first
#   net_invoke    (port 47320) Invoke Server / On Client Invoked / Answer: an int answer, no Answer (an empty
#                 one at once), an object answer (a Token made, given and answered: it's there),
#                 a slow answer past the Timeout (Answered false), two clients at once
#   net_spin      (port 47321) a Shape3D spinning 120 degrees a second on a dedicated server, seen
#                 by a client with a window: its rotation glides steadily (it used to glide one
#                 update and snap the next: user, "gems rotations get super buggy/fast/jittery")
#   net_ui        (port 47323) UI nodes stay on their machine: the server's runtime Label isn't
#                 sent (its Shape3D is)
#   net_pause     (port 47324) time scale and Pause in a network game: the server's 0.5 is the
#                 client's too; Pause doesn't freeze a shared world (server or client), Paused? says so
#   net_keys      players' keys on the server (Player Key, Player Input with --press), Give to /
#                 Owner / Mine?, an instanced Avatar scene's Client script on its owner's machine
#   net_problems  the bricks' problems (Host in a Server script, Me / a blank Player in a
#                 Server script, Player Joined in a class's script)
import json, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases")
V = lambda v: {"var": v}
I = lambda x: {"type": "int", "value": str(x)}
F = lambda x: {"type": "float", "value": str(x)}
S = lambda x: {"type": "string", "value": x}
NONE = {"var": ""}


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


class Script:
    def __init__(self, side="Shared"):
        self.nodes, self.n, self.side = [], 0, side

    def b(self, t, fields=None, args=None, outs=None, links=None):
        self.n += 1
        self.nodes.append({"id": self.n, "type": t, "pos": [0, 0], "size": [0, 0], "fields": fields or {}, "args": args or {},
                           "outs": {k: {"var": v, "use": False} for k, v in (outs or {}).items()}, "links": links or {}})
        return self.n

    def chain(self, ids):
        """Links each brick's Next to the one after it; gives the first."""
        for a, b in zip(ids, ids[1:]):
            next(x for x in self.nodes if x["id"] == a)["links"]["next"] = [b]
        return ids[0]

    def say(self, fmt, *values):
        """Format + Print: "[label] {}" with values (inputs); gives [format id, print id]."""
        args = {k: v for k, v in zip(["first", "second", "third", "fourth"], values)}
        line = "line_%d" % (self.n + 1)
        f = self.b("text", {"op": "Format", "format": fmt}, args, {"result": line})
        p = self.b("print", {"newline": True}, {"value": V(line)})
        return [f, p]

    def data(self):
        d = {"format": "c-bricks", "version": 4, "next_id": self.n + 1, "nodes": self.nodes}
        if self.side != "Shared":
            d["side"] = self.side
        return d


def write_case(name, comment, cfg, scripts, scene=None, project_name=None, extra=None):
    d = os.path.join(ROOT, name)
    os.makedirs(d, exist_ok=True)
    for root, _dirs, files in os.walk(d):
        for f in files:
            if f.endswith((".cbricks", ".cbscene", ".cfg", ".cbproj")):
                os.remove(os.path.join(root, f))
    for path, sc in scripts.items():
        full = os.path.join(d, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        json.dump(sc.data(), open(full, "w"), indent="\t")
    if scene is not None:
        scene = rooted(scene)
        json.dump({"format": "c-bricks-scene", "version": 4, "next_id": max(o["id"] for o in scene) + 1, "objects": scene}, open(os.path.join(d, "main.cbscene"), "w"), indent="\t")
    for rel, data in (extra or {}).items():
        full = os.path.join(d, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, "w").write(data if isinstance(data, str) else json.dumps(data, indent="\t"))
    open(os.path.join(d, "project.cbproj"), "w").write('[project]\n\nname="%s"\nversion="1.0"\n' % (project_name or name))
    lines = ["; " + l for l in comment.strip().split("\n")]
    lines.append("; Generated by tests/make_net_cases.py: change it there.")
    lines.append("[case]")
    for k, v in cfg.items():
        lines.append("%s=%s" % (k, json.dumps(v)))
    open(os.path.join(d, "case.cfg"), "w").write("\n".join(lines) + "\n")


def player_events(s, prefix=""):
    """Player Joined: "[joined] name #number"; Player Left: "[left] name"."""
    j = s.b("player_joined")
    name = s.b("player", {"op": "Name"}, {"player": V("player")}, {"result": "who"})
    s.chain([name] + s.say(prefix + "[joined] {} #{}", V("who"), V("player")))
    s.nodes[j - 1]["links"]["out"] = [name]
    l = s.b("player_left")
    lname = s.b("player", {"op": "Name"}, {"player": V("player")}, {"result": "gone"})
    s.chain([lname] + s.say(prefix + "[left] {}", V("gone")))
    s.nodes[l - 1]["links"]["out"] = [lname]


def net_join():
    s = Script()
    start = s.b("start")
    role = s.b("network", {"do": "Role"}, {}, {"result": "role"})
    stay = s.b("args", {"what": "Option"}, {"name": S("stay")}, {"result": "stay_text"})
    secs = s.b("text", {"op": "To float"}, {"text": V("stay_text")}, {"result": "stay"})
    wait = s.b("wait", {}, {"seconds": V("stay")})
    flag = s.b("args", {"what": "Flag"}, {"name": S("leave")}, {"result": "leave"})
    cond = s.b("if", {"operator": "is true"}, {"a": V("leave")})
    leave = s.b("network", {"do": "Leave"})
    role2 = s.b("network", {"do": "Role"}, {}, {"result": "role_after"})
    s.chain([leave, role2] + s.say("[after leave] {}", V("role_after")))
    s.nodes[cond - 1]["links"]["true"] = [leave]
    role3 = s.b("network", {"do": "Role"}, {}, {"result": "role_end"})
    done = s.say("[done] {}", V("role_end"))
    s.chain([role] + s.say("[role] {}", V("role")) + [stay, secs, wait, flag, cond, role3] + done)
    s.nodes[start - 1]["links"]["out"] = [role]
    player_events(s)
    port = "127.0.0.1:47311"
    write_case("net_join", """A dedicated server and three clients on this machine (port 47311), started 0.3 s apart:
ada (stays 1.2 s, then exits: its goodbye), bob (2.2 s), a second ada (named ada_2; Leave
after 0.3 s: back to single-player as player 1). Player Joined runs for the players
already there; every machine sees the same numbers and names.""", {
        "peers": ["--server 47311 --stay 3.2", "--join %s --name ada --stay 1.2" % port, "--join %s --name bob --stay 2.2" % port,
                  "--join %s --name ada --stay 0.3 --leave" % port],
        "peer_delay": 0.3,
        "expect_peer0_order": ["[role] server", "[joined] ada #2", "[joined] bob #3", "[joined] ada_2 #4", "[left] ada_2", "[left] ada", "[left] bob", "[done] server"],
        "expect_peer0_missing": ["#1"],
        "expect_peer1_order": ["[joined] ada #2", "[role] client", "[joined] bob #3", "[joined] ada_2 #4", "[left] ada_2", "[done] client"],
        "expect_peer2_order": ["[joined] ada #2", "[joined] bob #3", "[role] client", "[joined] ada_2 #4", "[left] ada_2", "[left] ada", "[done] client"],
        "expect_peer3_order": ["[joined] ada #2", "[joined] bob #3", "[joined] ada_2 #4", "[role] client", "[left] ada\n", "[left] bob", "[left] ada_2", "[joined] ada #1", "[after leave] offline", "[done] offline"],
    }, {"main.cbricks": s})
    write_case("net_host", """A host (a server with its own player: player 1) and a client on port 47313: the client's
welcome lists the host's player first; the host sees the client come and go.""", {
        "peers": ["--host 47313 --name hana --stay 1.4", "--join 127.0.0.1:47313 --name bob --stay 0.5"],
        "peer_delay": 0.3,
        "expect_peer0_order": ["[joined] hana #1", "[role] host", "[joined] bob #2", "[left] bob", "[done] host"],
        "expect_peer1_order": ["[joined] hana #1", "[joined] bob #2", "[role] client", "[done] client"],
    }, {"main.cbricks": s}, project_name="net_join")


def net_sides():
    main = Script()
    start = main.b("start")
    role = main.b("network", {"do": "Role"}, {}, {"result": "role"})
    srv = main.b("network", {"do": "Is server"}, {}, {"result": "rules"})
    stay = main.b("args", {"what": "Option"}, {"name": S("stay")}, {"result": "stay_text"})
    secs = main.b("text", {"op": "To float"}, {"text": V("stay_text")}, {"result": "stay"})
    wait = main.b("wait", {}, {"seconds": V("stay")})
    role2 = main.b("network", {"do": "Role"}, {}, {"result": "role_end"})
    main.chain([role, srv] + main.say("[main] {} rules here: {}", V("role"), V("rules")) + [stay, secs, wait, role2] + main.say("[done] {}", V("role_end")))
    main.nodes[start - 1]["links"]["out"] = [role]
    server = Script("Server")
    st = server.b("start")
    server.nodes[st - 1]["links"]["out"] = [server.chain(server.say("[server script] runs"))]
    j = server.b("player_joined")
    nm = server.b("player", {"op": "Name"}, {"player": V("player")}, {"result": "who"})
    server.chain([nm] + server.say("[server sees] {}", V("who")))
    server.nodes[j - 1]["links"]["out"] = [nm]
    client = Script("Client")
    ct = client.b("start")
    me = client.b("player", {"op": "Name"}, {}, {"result": "me_name"})  # blank: this machine's player
    isme = client.b("player", {"op": "Me"}, {}, {"result": "me"})
    client.chain([me, isme] + client.say("[client script] I am {} #{}", V("me_name"), V("me")))
    client.nodes[ct - 1]["links"]["out"] = [me]
    shared = Script()
    sh = shared.b("start")
    shared.nodes[sh - 1]["links"]["out"] = [shared.chain(shared.say("[module script] runs"))]
    scene = [
        {"id": 1, "class": "Node", "name": "Game", "parent": 0, "fields": {}},
        {"id": 2, "class": "Script", "name": "Rules", "parent": 1, "script": "scripts/rules.cbricks", "fields": {}},
        {"id": 3, "class": "LocalScript", "name": "Hud", "parent": 1, "script": "scripts/hud.cbricks", "fields": {}},
        {"id": 4, "class": "ModuleScript", "name": "Common", "parent": 1, "script": "scripts/common.cbricks", "fields": {}},
    ]
    write_case("net_sides", """Scripts run where their Side says: the Scene's Script (Server) object on the dedicated
server, its LocalScript (Client) on the client, its ModuleScript (Shared) on both; offline
(single-player: its own server and client) all three. A Server script's Player Joined
runs only where the game's rules run. A blank Player in a Client script: this machine's player.
The server stays longest; then a fourth peer (dee) is still in when it closes: back to
single-player, where both sides run (so the Server script's Player Joined runs there too).""", {
        "peers": ["--server 47312 --stay 1.6", "--join 127.0.0.1:47312 --name cy --stay 0.6", "--name solo --stay 0.2", "--join 127.0.0.1:47312 --name dee --stay 3"],
        "peer_delay": 0.3,
        "expect_peer0_order": ["[server script] runs", "[module script] runs", "[main] server rules here: true", "[server sees] cy", "[done] server"],
        "expect_peer0_missing": ["[client script]"],
        "expect_peer1_order": ["[client script] I am cy #2", "[module script] runs", "[main] client rules here: false", "[done] client"],
        "expect_peer1_missing": ["[server script]", "[server sees]"],
        "expect_peer2_order": ["[server script] runs", "[client script] I am solo #1", "[module script] runs", "[server sees] solo", "[main] offline rules here: true", "[done] offline"],
        "expect_peer3_order": ["[client script] I am dee #3", "[main] client rules here: false", "[net] the server closed the game", "[server sees] dee", "[done] offline"],
    }, {"main.cbricks": main, "scripts/rules.cbricks": server, "scripts/hud.cbricks": client, "scripts/common.cbricks": shared}, scene)


def net_problems():
    main = Script()
    st = main.b("start")
    main.nodes[st - 1]["links"]["out"] = [main.chain(main.say("[main] runs"))]
    server = Script("Server")
    s2 = server.b("start")
    host = server.b("network", {"do": "Host"}, {"port": I(7000)}, {"result": "ok"})
    me = server.b("player", {"op": "Me"}, {}, {"result": "me"})
    blank = server.b("player", {"op": "Name"}, {}, {"result": "who"})
    server.chain([host, me, blank])
    server.nodes[s2 - 1]["links"]["out"] = [host]
    server_fn = Script("Server")
    fn = server_fn.b("function", {"name": "greet", "returns": "void", "params": []})
    server_fn.nodes[fn - 1]["links"]["out"] = [server_fn.b("player", {"op": "Name"}, {}, {"result": "n"})]
    cls = Script()
    cls.b("class", {"name": "Thing", "extends": "Node", "fields": [], "synced": ""})
    pj = cls.b("player_joined")
    cls.nodes[pj - 1]["links"]["out"] = [cls.b("print", {"newline": True}, {"value": S("hi")})]
    listy = Script()
    listy.b("class", {"name": "Bag", "extends": "Node", "fields": [["items", "int list"]], "synced": "items"})
    rem = Script("Client")  # remote mistakes, in a Client script
    rem.b("remote", {"name": "up", "direction": "To server", "values": [["n", "int"], ["sender", "string"], ["bag", "int list"]]})
    rem.b("remote", {"name": "down", "direction": "To clients", "values": []})
    rs = rem.b("start")
    f1 = rem.b("fire_server", {"remote": "down"})
    f2 = rem.b("fire_clients", {"remote": "down"})
    f3 = rem.b("fire_server", {"remote": "nowhere"})
    f4 = rem.b("fire_server", {"remote": "q"})
    rem.chain([f1, f2, f4, f3])
    rem.nodes[rs - 1]["links"]["out"] = [f1]
    rem.b("on_client_fired", {"remote": "up"})
    rk = rem.b("player_key", {"when": "Pressed", "key": "SPACE"})
    rem.nodes[rk - 1]["links"]["out"] = [rem.b("print", {"newline": True}, {"value": S("never")})]
    rme = rem.b("player", {"op": "Me"}, {}, {"result": "me"})
    rpi = rem.b("player_input", {"what": "Holds", "key": "SPACE"}, {"player": V("me")}, {"result": "h"})
    rwd = rem.b("object", {"op": "World"}, {}, {"result": "w"})
    rgv = rem.b("ownership", {"do": "Give to"}, {"object": V("w"), "player": V("me")})
    next(x for x in rem.nodes if x["id"] == f3)["links"]["next"] = [rem.chain([rme, rpi, rwd, rgv])]
    ask = Script("Server")  # Invoke's mistakes (2026-11-07), in a Server script
    ask.b("remote", {"name": "q", "direction": "Ask server", "values": [], "answer": "int"})
    ask.b("remote", {"name": "badq", "direction": "Ask server", "values": [], "answer": "int list"})
    ast = ask.b("start")
    i1 = ask.b("invoke_server", {"remote": "q"}, {}, {"answer": "a"})
    i3 = ask.b("answer", {}, {"value": I(1)})
    ask.chain([i1, i3])
    ask.nodes[ast - 1]["links"]["out"] = [i1]
    oq = ask.b("on_client_fired", {"remote": "q"})
    ocu = ask.b("on_client_invoked", {"remote": "down"})
    oqi = ask.b("on_client_invoked", {"remote": "q"})
    ask.nodes[oqi - 1]["links"]["out"] = [ask.b("answer", {}, {"value": S("text")})]
    asker = Script()  # Invoke in an object's event
    asker.b("class", {"name": "Asker", "extends": "Node", "fields": [], "synced": ""})
    ef = asker.b("every_frame")
    asker.nodes[ef - 1]["links"]["out"] = [asker.b("invoke_server", {"remote": "q"}, {}, {})]
    asker.b("clicked")  # (UI, 2026-11-07: Asker extends Node, not Button)
    asker.b("button_clicked", {"button": ""})  # (a class's script)
    ask.b("button_clicked", {"button": ""})  # (a Server script)
    own = Script()  # a project's own Player class: fine (players are numbers, no class of that name)
    own.b("class", {"name": "Player", "extends": "Node", "fields": [["hp", "int"]], "synced": ""})
    scene = [{"id": 1, "class": "Node", "name": "Game", "parent": 0, "fields": {}},
             {"id": 2, "class": "Script", "name": "Rules", "parent": 1, "script": "scripts/rules.cbricks", "fields": {}}]
    write_case("net_problems", """The Network bricks' problems: Host in a Server script (a player's choice), Me in a Server
script, a blank Player in a Server script's function (no object to be under: say which),
Player Joined in a class's script; a class of the project's own named Player is no problem
(players are numbers).""", {
        "expect_problems": ["Host is a player's choice", "Me is this machine's player", "say which player", "Player Joined belongs in a plain script", "Synced field 'items' (int list)", "the remote 'down' goes to clients", "Fire Clients is for the server telling players", "there's no remote named 'nowhere'", "On Client Fired runs on the server", "value 'sender': the name is taken", "value 'bag' is a int list", "Player Key runs where the game's rules run", "Player Input reads players' keys where the game's rules run", "Give to is the server's to decide",
                             "Invoke Server is a player's machine asking", "is a question (Ask server): ask it with Invoke Server", "Answer belongs in an On Client Invoked chain",
                             "is a question (Ask server): it arrives at On Client Invoked", "On Client Invoked answers a question", "answers a int, not a string",
                             "badq's Answer is a int list", "Invoke Server waits for its answer: it can't be in an object's event",
                             "When clicked is for Buttons: make Asker extend Button", "When button clicked belongs in a plain script", "When button clicked runs on players' machines"],
    }, {"main.cbricks": main, "scripts/rules.cbricks": server, "scripts/greet.cbricks": server_fn, "scripts/thing.cbricks": cls, "scripts/hero.cbricks": own, "scripts/bag.cbricks": listy, "scripts/remotes.cbricks": rem,
        "scripts/ask.cbricks": ask, "scripts/asker.cbricks": asker}, scene)


def net_world():
    s = Script()
    start = s.b("start")
    srv = s.b("network", {"do": "Role"}, {}, {"result": "role"})
    branch = s.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    s.chain([srv, branch])
    s.nodes[start - 1]["links"]["out"] = [srv]
    # --- the server: changes the world over 3.5 s
    crate = s.b("object", {"op": "Find", "of": "Node"}, {"name": S("Crate")}, {"result": "crate"})
    kill = s.b("destroy", {}, {"object": V("crate")})
    sign = s.b("object", {"op": "Find", "of": "Sign"}, {"name": S("Sign")}, {"result": "sign"})
    st = s.b("field", {"mode": "Set", "field": "text"}, {"record": V("sign"), "value": S("hello")})
    ball = s.b("new_object", {"of": "Ball", "world": True}, {}, {"object": "b"})
    sb = s.b("field", {"mode": "Set", "field": "ball"}, {"record": V("sign"), "value": V("b")})
    x1 = s.b("field", {"mode": "Set", "field": "x"}, {"record": V("b"), "value": I(1)})
    l1 = s.b("field", {"mode": "Set", "field": "label"}, {"record": V("b"), "value": S("one")})
    sec = s.b("field", {"mode": "Set", "field": "secret"}, {"record": V("b"), "value": I(42)})
    w1 = s.b("wait", {}, {"seconds": F(1.0)})
    x2 = s.b("field", {"mode": "Set", "field": "x"}, {"record": V("b"), "value": I(2)})
    l2 = s.b("field", {"mode": "Set", "field": "label"}, {"record": V("b"), "value": S("two")})
    p2 = s.b("field", {"mode": "Set", "field": "pos"}, {"record": V("b"), "value": {"type": "vector3", "value": "1, 0, 0"}})
    sp2 = s.b("field", {"mode": "Set", "field": "spot"}, {"record": V("b"), "value": {"type": "vector3", "value": "2, 0, 0"}})
    nm = s.b("object", {"op": "Set name"}, {"object": V("b"), "name": S("Bally")})
    pal = s.b("new_object", {"of": "Ball", "world": True}, {}, {"object": "pal"})
    fr = s.b("field", {"mode": "Set", "field": "friend"}, {"record": V("b"), "value": V("pal")})
    w2 = s.b("wait", {}, {"seconds": F(1.0)})
    kp = s.b("destroy", {}, {"object": V("pal")})
    x3 = s.b("field", {"mode": "Set", "field": "x"}, {"record": V("b"), "value": I(3)})
    l3 = s.b("field", {"mode": "Set", "field": "label"}, {"record": V("b"), "value": S("three")})
    w3 = s.b("wait", {}, {"seconds": F(1.5)})
    s.nodes[branch - 1]["links"]["true"] = [s.chain([crate, kill, sign, st, ball, sb, x1, l1, sec, w1, x2, l2, p2, sp2, nm, pal, fr, w2, kp, x3, l3, w3] + s.say("[server] done"))]
    # --- a client: --late: starts single-player, joins after 1.2 s (Join brick)
    late = s.b("args", {"what": "Flag"}, {"name": S("late")}, {"result": "late"})
    lif = s.b("if", {"operator": "is true"}, {"a": V("late")})
    lw = s.b("wait", {}, {"seconds": F(1.2)})
    lj = s.b("network", {"do": "Join"}, {"address": S("127.0.0.1"), "port": I(47314), "timeout": F(3)}, {"result": "joined"})
    s.nodes[lif - 1]["links"]["true"] = [s.chain([lw, lj] + s.say("[late] joined {}", V("joined")))]
    tag = s.b("args", {"what": "Option"}, {"name": S("tag")}, {"result": "tag"})
    r1 = s.b("call", {"function": "report"}, {"tag": {"type": "string", "value": "1"}, "who": V("tag")})
    cw1 = s.b("wait", {}, {"seconds": F(1.1)})
    r2 = s.b("call", {"function": "report"}, {"tag": {"type": "string", "value": "2"}, "who": V("tag")})
    cw2 = s.b("wait", {}, {"seconds": F(1.0)})
    r3 = s.b("call", {"function": "report"}, {"tag": {"type": "string", "value": "3"}, "who": V("tag")})
    s.nodes[branch - 1]["links"]["false"] = [s.chain([late, lif, tag, r1, cw1, r2, cw2, r3])]
    # --- report(who, tag): what this machine's world says
    fn = s.b("function", {"name": "report", "returns": "void", "params": [["who", "string"], ["tag", "string"]]})
    fsign = s.b("object", {"op": "Find", "of": "Sign"}, {"name": S("Sign")}, {"result": "sg"})
    ftext = s.b("field", {"mode": "Get", "field": "text"}, {"record": V("sg")}, {"value": "text"})
    fcr = s.b("object", {"op": "Find", "of": "Node"}, {"name": S("Crate")}, {"result": "cr"})
    fcre = s.b("object", {"op": "Exists"}, {"object": V("cr")}, {"result": "crate_there"})
    fla = s.b("object", {"op": "Find", "of": "Node"}, {"name": S("Lamp")}, {"result": "la"})
    flae = s.b("object", {"op": "Exists"}, {"object": V("la")}, {"result": "lamp_there"})
    line1 = s.say("[{}{}] sign={} crate={}", V("who"), V("tag"), V("text"), V("crate_there"))
    line1b = s.say("[{}{}] lamp={}", V("who"), V("tag"), V("lamp_there"))
    fb = s.b("field", {"mode": "Get", "field": "ball"}, {"record": V("sg")}, {"value": "bl"})
    fbe = s.b("object", {"op": "Exists"}, {"object": V("bl")}, {"result": "has_ball"})
    bif = s.b("if", {"operator": "is true"}, {"a": V("has_ball")})
    bn = s.b("object", {"op": "Name"}, {"object": V("bl")}, {"result": "bname"})
    bx = s.b("field", {"mode": "Get", "field": "x"}, {"record": V("bl")}, {"value": "bx"})
    blab = s.b("field", {"mode": "Get", "field": "label"}, {"record": V("bl")}, {"value": "blabel"})
    bpos = s.b("field", {"mode": "Get", "field": "pos"}, {"record": V("bl")}, {"value": "bpos"})
    bsec = s.b("field", {"mode": "Get", "field": "secret"}, {"record": V("bl")}, {"value": "bsecret"})
    bfr = s.b("field", {"mode": "Get", "field": "friend"}, {"record": V("bl")}, {"value": "bfriend"})
    bspot = s.b("field", {"mode": "Get", "field": "spot"}, {"record": V("bl")}, {"value": "bspot"})
    bfre = s.b("object", {"op": "Exists"}, {"object": V("bfriend")}, {"result": "friend_there"})
    l2 = s.say("[{}{}] ball {} x={}", V("who"), V("tag"), V("bname"), V("bx"))
    l3 = s.say("[{}{}] label={} pos={}", V("who"), V("tag"), V("blabel"), V("bpos"))
    l4 = s.say("[{}{}] friend={} secret={}", V("who"), V("tag"), V("friend_there"), V("bsecret"))
    l5 = s.say("[{}{}] spot={}", V("who"), V("tag"), V("bspot"))
    s.nodes[bif - 1]["links"]["true"] = [s.chain([bn, bx, blab, bpos, bsec, bfr, bspot, bfre] + l2 + l3 + l4 + l5)]
    s.nodes[fn - 1]["links"]["out"] = [s.chain([fsign, ftext, fcr, fcre, fla, flae] + line1 + line1b + [fb, fbe, bif])]
    # classes
    ballc = Script()
    ballc.b("class", {"name": "Ball", "extends": "Node", "fields": [["x", "int"], ["label", "string"], ["pos", "vector3"], ["friend", "Ball"], ["secret", "int"], ["spot", "vector3"]], "synced": "x, label, pos, friend, spot!"})
    cr = ballc.b("created")
    ballc.nodes[cr - 1]["links"]["out"] = [ballc.b("print", {"newline": True}, {"value": S("[created] a Ball")})]
    signc = Script()
    signc.b("class", {"name": "Sign", "extends": "Node", "fields": [["text", "string"], ["ball", "Ball"]], "synced": "text, ball"})
    hud = Script("Client")
    hs = hud.b("start")
    hn = hud.b("object", {"op": "Name"}, {"object": V("parent")}, {"result": "pname"})
    hud.nodes[hs - 1]["links"]["out"] = [hud.chain([hn] + hud.say("[hud] under {}", V("pname")))]
    scene = [
        {"id": 1, "class": "Sign", "name": "Sign", "parent": 0, "fields": {"text": "offline"}},
        {"id": 2, "class": "LocalScript", "name": "Hud", "parent": 1, "script": "scripts/hud.cbricks", "fields": {}},
        {"id": 3, "class": "Node", "name": "Crate", "parent": 0, "fields": {}},
        {"id": 4, "class": "Node", "name": "Lamp", "parent": 0, "fields": {}, "groups": ["local"]},
    ]
    port = "127.0.0.1:47314"
    write_case("net_world", """The world copied to players (port 47314): a dedicated server destroys the scene's Crate,
sets the Sign's text, makes a Ball (When created: on the server only) and changes it (x,
label, pos gliding, a rename, a friend Ball made then destroyed). Client a joins at the
start (--join: the Main scene's Sign is matched, its LocalScript still runs under it); b
starts single-player and Joins 1.2 s later (the whole world at once; its own Crate goes).
Lamp is in the group local: never sent, every machine keeps its own. secret isn't Synced;
spot is Synced with "!" (spot!): it jumps, so a2 sees exactly (2, 0, 0) while pos still glides.""", {
        "peers": ["--server 47314", "--join %s --name ada --tag a" % port, "--name bob --tag b --late"],
        "peer_delay": 0.3,
        "expect_peer0_order": ["[created] a Ball", "[created] a Ball", "[server] done"],
        "expect_peer0_missing": ["[hud]", "[a1]"],
        "expect_peer1_order": ["[hud] under Sign", "[a1] sign=hello crate=false", "[a1] lamp=true", "[a1] ball Ball x=1", "[a1] label=one pos=(0, 0, 0)", "[a1] friend=false secret=0",
                               "[a2] ball Bally x=2", "[a2] label=two pos=", "[a2] friend=true secret=0", "[a2] spot=(2, 0, 0)",
                               "[a3] ball Bally x=3", "[a3] label=three pos=(1, 0, 0)", "[a3] friend=false"],
        "expect_peer1_missing": ["[created]"],
        "expect_peer2_order": ["[hud] under Sign", "[late] joined true", "[b1] sign=hello crate=false", "[b1] lamp=true", "[b1] ball Bally x=2", "[b1] label=two pos=(1, 0, 0)", "[b1] friend=true",
                               "[b3] ball Bally x=3"],
        "expect_peer2_missing": ["[created]"],
    }, {"main.cbricks": s, "scripts/ball.cbricks": ballc, "scripts/sign.cbricks": signc, "scripts/hud.cbricks": hud}, scene)


def net_world_3d():
    s = Script()
    start = s.b("start")
    win = s.b("window", {}, {"width": I(320), "height": I(200), "title": S("net world"), "fps": I(60)})
    wid = s.b("game_info", {"what": "Width"}, {}, {"result": "w"})
    role = s.b("network", {"do": "Role"}, {}, {"result": "role"})
    loop = s.b("game_loop")
    lim = s.b("var", {"mode": "Set", "name": "limit"}, {"value": F(2.5)})
    isr = s.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    s.nodes[isr - 1]["links"]["true"] = [s.b("var", {"mode": "Set", "name": "limit"}, {"value": F(4.0)})]  # the server outlasts its client
    s.chain([win, wid, role] + s.say("[{}] window width {}", V("role"), V("w")) + [lim, isr, loop])
    s.nodes[start - 1]["links"]["out"] = [win]
    t = s.b("game_info", {"what": "Time"}, {}, {"result": "t"})
    late = s.b("compare", {"op": ">"}, {"a": V("t"), "b": V("limit")}, {"result": "late"})
    lif = s.b("if", {"operator": "is true"}, {"a": V("late")})
    s.chain([t, late, lif])
    s.nodes[loop - 1]["links"]["frame"] = [t]
    mv = s.b("object", {"op": "Find", "of": "Mover"}, {"name": S("Mover")}, {"result": "m"})
    pos = s.b("field", {"mode": "Get", "field": "position"}, {"record": V("m")}, {"value": "p"})
    px = s.b("vector", {"op": "Split", "dims": "3D"}, {"a": V("p")}, {"x": "px"})
    far = s.b("compare", {"op": ">"}, {"a": V("px"), "b": F(1.0)}, {"result": "moved"})
    steps = s.b("field", {"mode": "Get", "field": "steps"}, {"record": V("m")}, {"value": "steps"})
    mine = s.b("compare", {"op": ">"}, {"a": V("steps"), "b": I(0)}, {"result": "stepped"})
    q = s.b("quit", {}, {"code": I(0)})
    s.nodes[lif - 1]["links"]["true"] = [s.chain([mv, pos, px, far, steps, mine] + s.say("[{}] mover moved: {}, its Every frame ran here: {}", V("role"), V("moved"), V("stepped")) + [q])]
    mover = Script()
    mover.b("class", {"name": "Mover", "extends": "Shape3D", "fields": [["steps", "int"]], "synced": ""})
    ef = mover.b("every_frame")
    vec = mover.b("vector", {"op": "Make", "dims": "3D"}, {"x": V("dt"), "y": F(0), "z": F(0)}, {"result": "step"})
    add = mover.b("var", {"mode": "Add", "name": "position"}, {"value": V("step")})
    cnt = mover.b("var", {"mode": "Add", "name": "steps"}, {"value": I(1)})
    mover.nodes[ef - 1]["links"]["out"] = [mover.chain([vec, add, cnt])]
    scene = [
        {"id": 1, "class": "Camera3D", "name": "Camera3D", "parent": 0, "fields": {"position": "0, 4, 8"}},
        {"id": 2, "class": "Mover", "name": "Mover", "parent": 0, "fields": {"color": "RED"}},
    ]
    write_case("net_world_3d", """A graphics game's dedicated server runs without a window (--server: Game info's width is
0; the Game loop runs the world on its own clock): its Mover (a scene Part) moves in its
Every frame; the client (a window) sees it move through the Synced position, and its copy's
Every frame doesn't run there.""", {
        "peers": ["--server 47315", "--join 127.0.0.1:47315 --name ada"],
        "peer_delay": 0.4,
        "expect_peer0_order": ["[server] window width 0", "[server] mover moved: true, its Every frame ran here: true"],
        "expect_peer1_order": ["[client] window width 320", "[client] mover moved: true, its Every frame ran here: false"],
    }, {"main.cbricks": s, "scripts/mover.cbricks": mover}, scene)


def net_remotes():
    main = Script()
    st = main.b("start")
    role = main.b("network", {"do": "Role"}, {}, {"result": "role"})
    isr = main.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    main.chain([role, isr])
    main.nodes[st - 1]["links"]["out"] = [role]
    main.nodes[isr - 1]["links"]["true"] = [main.chain([main.b("wait", {}, {"seconds": F(2.6)})] + main.say("[server] done"))]
    me = main.b("player", {"op": "Name"}, {}, {"result": "me"})
    txt = main.b("text", {"op": "Format", "format": "hi from {}"}, {"first": V("me")}, {"result": "line"})
    fire = main.b("fire_server", {"remote": "chat"}, {"text": V("line")})
    stay = main.b("args", {"what": "Option"}, {"name": S("stay")}, {"result": "stay_text"})
    secs = main.b("text", {"op": "To float"}, {"text": V("stay_text")}, {"result": "stay"})
    w = main.b("wait", {}, {"seconds": V("stay")})
    main.nodes[isr - 1]["links"]["false"] = [main.chain([me, txt, fire, stay, secs, w] + main.say("[client] done"))]
    defs = Script()
    defs.b("remote", {"name": "chat", "direction": "To server", "values": [["text", "string"]]})
    defs.b("remote", {"name": "said", "direction": "To clients", "values": [["who", "int"], ["text", "string"], ["board", "Board"]]})
    defs.b("remote", {"name": "whisper", "direction": "To clients", "values": [["text", "string"]]})
    server = Script("Server")
    oc = server.b("on_client_fired", {"remote": "chat"})
    bd = server.b("object", {"op": "Find", "of": "Board"}, {"name": S("Board")}, {"result": "b"})
    sc = server.b("field", {"mode": "Get", "field": "score"}, {"record": V("b")}, {"value": "score"})
    inc = server.b("math", {"op": "+"}, {"a": V("score"), "b": I(1)}, {"result": "score2"})
    ss = server.b("field", {"mode": "Set", "field": "score"}, {"record": V("b"), "value": V("score2")})
    said = server.b("fire_clients", {"remote": "said", "to": "All"}, {"who": V("sender"), "text": V("text"), "board": V("b")})
    sn = server.b("player", {"op": "Name"}, {"player": V("sender")}, {"result": "sname"})
    wt = server.b("text", {"op": "Format", "format": "welcome, {}"}, {"first": V("sname")}, {"result": "wline"})
    wh = server.b("fire_clients", {"remote": "whisper", "to": "One player"}, {"player": V("sender"), "text": V("wline")})
    server.nodes[oc - 1]["links"]["out"] = [server.chain([bd, sc, inc, ss, said, sn, wt, wh] + server.say("[server] {} said: {}", V("sname"), V("text")))]
    client = Script("Client")
    os1 = client.b("on_server_fired", {"remote": "said"})
    wn = client.b("player", {"op": "Name"}, {"player": V("who")}, {"result": "wname"})
    bs = client.b("field", {"mode": "Get", "field": "score"}, {"record": V("board")}, {"value": "bscore"})
    client.nodes[os1 - 1]["links"]["out"] = [client.chain([wn, bs] + client.say("[said] {}: {} (score {})", V("wname"), V("text"), V("bscore")))]
    os2 = client.b("on_server_fired", {"remote": "whisper"})
    client.nodes[os2 - 1]["links"]["out"] = [client.chain(client.say("[whisper] {}", V("text")))]
    board = Script()
    board.b("class", {"name": "Board", "extends": "Node", "fields": [["score", "int"]], "synced": "score"})
    scene = [{"id": 1, "class": "Board", "name": "Board", "parent": 0, "fields": {}}]
    port = "127.0.0.1:47316"
    write_case("net_remotes", """Remotes (port 47316): each client fires chat (To server) with its line; the server's On
Client Fired adds 1 to the Board's Synced score, tells everyone who said what (Fire Clients
All: said, with the Player, the text and the Board itself as values) and whispers to the
sender only (Fire Clients One player). The score read in On Server Fired is already the new
one (Synced changes arrive before a message sent after them). bob joins after ada's line:
he never hears it, and nobody hears another's whisper.""", {
        "peers": ["--server 47316", "--join %s --name ada --stay 1.6" % port, "--join %s --name bob --stay 1.2" % port],
        "peer_delay": 0.4,
        "expect_peer0_order": ["[server] ada said: hi from ada", "[server] bob said: hi from bob", "[server] done"],
        "expect_peer0_missing": ["[said]", "[whisper]"],
        "expect_peer1_order": ["[said] ada: hi from ada (score 1)", "[whisper] welcome, ada", "[said] bob: hi from bob (score 2)", "[client] done"],
        "expect_peer1_missing": ["welcome, bob"],
        "expect_peer2_order": ["[said] bob: hi from bob (score 2)", "[whisper] welcome, bob", "[client] done"],
        "expect_peer2_missing": ["hi from ada", "welcome, ada"],
    }, {"main.cbricks": main, "scripts/remotes.cbricks": defs, "scripts/server.cbricks": server, "scripts/client.cbricks": client, "scripts/board.cbricks": board}, scene)


def net_keys():
    main = Script()
    st = main.b("start")
    win = main.b("window", {}, {"width": I(320), "height": I(200), "title": S("net keys"), "fps": I(60)})
    role = main.b("network", {"do": "Role"}, {}, {"result": "role"})
    lim = main.b("var", {"mode": "Set", "name": "limit"}, {"value": F(1.9)})  # clients report while both are in
    qa = main.b("var", {"mode": "Set", "name": "quit_at"}, {"value": F(2.6)})
    dn = main.b("var", {"mode": "Set", "name": "done"}, {"value": {"type": "bool", "value": "false"}})
    isr = main.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    # the server reports while everyone's there, and outlasts its clients
    main.nodes[isr - 1]["links"]["true"] = [main.chain([main.b("var", {"mode": "Set", "name": "limit"}, {"value": F(2.0)}), main.b("var", {"mode": "Set", "name": "quit_at"}, {"value": F(4.0)})])]
    loop = main.b("game_loop")
    main.chain([win, role, lim, qa, dn, isr, loop])
    main.nodes[st - 1]["links"]["out"] = [win]
    t = main.b("game_info", {"what": "Time"}, {}, {"result": "t"})
    late = main.b("formula", {"type": "bool", "expression": "t > limit && !done"}, {}, {"result": "late"})
    lif = main.b("if", {"operator": "is true"}, {"a": V("late")})
    over = main.b("compare", {"op": ">"}, {"a": V("t"), "b": V("quit_at")}, {"result": "over"})
    oif = main.b("if", {"operator": "is true"}, {"a": V("over")})
    main.nodes[oif - 1]["links"]["true"] = [main.b("quit", {}, {"code": I(0)})]
    main.chain([t, late, lif, over, oif])
    main.nodes[loop - 1]["links"]["frame"] = [t]
    rep = []
    for who in ["ada", "bob"]:
        f = main.b("object", {"op": "Find", "of": "Avatar"}, {"name": S(who)}, {"result": "av_" + who})
        p = main.b("field", {"mode": "Get", "field": "position"}, {"record": V("av_" + who)}, {"value": "pos_" + who})
        x = main.b("vector", {"op": "Split", "dims": "3D"}, {"a": V("pos_" + who)}, {"x": "x_" + who})
        mv = main.b("compare", {"op": ">"}, {"a": V("x_" + who), "b": F(1.0)}, {"result": "moved_" + who})
        mi = main.b("ownership", {"do": "Is mine"}, {"object": V("av_" + who)}, {"result": "mine_" + who})
        ow = main.b("ownership", {"do": "Owner"}, {"object": V("av_" + who)}, {"result": "owner_" + who})
        on = main.b("player", {"op": "Name"}, {"player": V("owner_" + who)}, {"result": "oname_" + who})
        rep += [f, p, x, mv, mi, ow, on] + main.say("[{}] %s's avatar: moved right %s, owner {}, mine {}" % (who, "{}"), V("role"), V("moved_" + who), V("oname_" + who), V("mine_" + who))
    main.nodes[lif - 1]["links"]["true"] = [main.chain(rep + [main.b("var", {"mode": "Set", "name": "done"}, {"value": {"type": "bool", "value": "true"}})])]
    rules = Script("Server")
    for when in ["Pressed", "Released"]:
        k = rules.b("player_key", {"when": when, "key": "SPACE"})
        n = rules.b("player", {"op": "Name"}, {"player": V("player")}, {"result": "who"})
        rules.nodes[k - 1]["links"]["out"] = [rules.chain([n] + rules.say("[key] {} %s SPACE" % when.lower(), V("who")))]
    # The do-it-yourself starter player (user, 2026-11-07): an Avatar scene with a Client
    # script in it; the server's Player Joined instances it and gives it to the player.
    spawner = Script("Server")
    pj = spawner.b("player_joined")
    mk = spawner.b("scene", {"do": "Instance", "scene": "scenes/avatar.cbscene"}, {"parent": NONE}, {"root": "av"})
    nm = spawner.b("player", {"op": "Name"}, {"player": V("player")}, {"result": "pname"})
    sn = spawner.b("object", {"op": "Set name"}, {"object": V("av"), "name": V("pname")})
    gv = spawner.b("ownership", {"do": "Give to"}, {"object": V("av"), "player": V("player")})
    spawner.nodes[pj - 1]["links"]["out"] = [spawner.chain([mk, nm, sn, gv] + spawner.say("[starter] an avatar for {}", V("pname")))]
    hello = Script("Client")
    h0 = hello.b("start")
    hn = hello.b("player", {"op": "Name"}, {}, {"result": "me"})  # blank: the owner of the avatar it's in
    hello.nodes[h0 - 1]["links"]["out"] = [hello.chain([hn] + hello.say("[hello] this is {}'s machine", V("me")))]
    avatar = Script()
    avatar.b("class", {"name": "Avatar", "extends": "Shape3D", "fields": [], "synced": ""})
    ef = avatar.b("every_frame")
    dr = avatar.b("player_input", {"what": "Direction"}, {"player": NONE}, {"result": "dir"})  # blank: its owner
    sp = avatar.b("vector", {"op": "Split", "dims": "2D"}, {"a": V("dir")}, {"x": "dx", "y": "dy"})
    mv = avatar.b("vector", {"op": "Make", "dims": "3D"}, {"x": {"type": "float", "value": "dx * dt * 3"}, "y": F(0), "z": {"type": "float", "value": "dy * dt * 3"}}, {"result": "step"})
    ad = avatar.b("var", {"mode": "Add", "name": "position"}, {"value": V("step")})
    avatar.nodes[ef - 1]["links"]["out"] = [avatar.chain([dr, sp, mv, ad])]
    scene = [
        {"id": 1, "class": "Node", "name": "Main", "parent": 0, "fields": {}},
        {"id": 2, "class": "Camera3D", "name": "Camera3D", "parent": 1, "fields": {"position": "0, 6, 8"}},
    ]
    avatar_scene = {"format": "c-bricks-scene", "version": 4, "next_id": 3, "objects": [
        {"id": 1, "class": "Avatar", "name": "Avatar", "parent": 0, "fields": {}},
        {"id": 2, "class": "LocalScript", "name": "Hello", "parent": 1, "script": "scripts/hello.cbricks", "fields": {}},
    ]}
    port = "127.0.0.1:47317"
    write_case("net_keys", """Players' keys and ownership (port 47317; keys simulated with --press, a client needs no
one at its keyboard): a Server script's Player Joined instances scenes/avatar.cbscene for each
player (named after them, Give to: the do-it-yourself starter player); the Client script in that
scene greets on its owner's machine only (its blank Player: the owner). ada holds D (0.2 to 1.4 s): her Avatar's Every frame, on
the server, moves it with Player Direction (blank: its owner); bob holds nothing. ada taps
SPACE: Player Pressed / Released on the server. Mine? on each machine.""", {
        "peers": ["--server 47317", "--join %s --name ada --press D:0.2:1.4,SPACE:0.5:0.7" % port, "--join %s --name bob" % port],
        "peer_delay": 0.4,
        "expect_peer0_contains": ["[starter] an avatar for ada", "[starter] an avatar for bob", "[key] ada pressed SPACE", "[key] ada released SPACE",
                                  "[server] ada's avatar: moved right true, owner ada, mine false", "[server] bob's avatar: moved right false, owner bob, mine false"],
        "expect_peer0_missing": ["[hello]", "bob pressed"],
        "expect_peer1_contains": ["[hello] this is ada's machine", "[client] ada's avatar: moved right true, owner ada, mine true", "[client] bob's avatar: moved right false, owner bob, mine false"],
        "expect_peer1_missing": ["[starter]", "[key]", "this is bob's"],
        "expect_peer2_contains": ["[hello] this is bob's machine", "[client] ada's avatar: moved right true, owner ada, mine false", "[client] bob's avatar: moved right false, owner bob, mine true"],
        "expect_peer2_missing": ["this is ada's"],
    }, {"main.cbricks": main, "scripts/rules.cbricks": rules, "scripts/spawner.cbricks": spawner, "scripts/hello.cbricks": hello, "scripts/avatar.cbricks": avatar}, scene, extra={"scenes/avatar.cbscene": avatar_scene})
    # The same game hosted (the host instances every avatar: only its own player's Client
    # script runs there, the client's runs on the client).
    write_case("net_keys_host", """net_keys' game with a host (ada, player 1) and a client (bob): the host makes both
avatars; the Avatar scene's Client script runs for ada's on the host and for bob's on bob's
machine only (owned Client Script objects). (After the host quits, bob is single-player: his
own Server script spawns him again there.)""", {
        "peers": ["--host 47319 --name ada", "--join 127.0.0.1:47319 --name bob"],
        "peer_delay": 0.4,
        "expect_peer0_contains": ["[starter] an avatar for ada", "[starter] an avatar for bob", "[hello] this is ada's machine"],
        "expect_peer0_missing": ["this is bob's"],
        "expect_peer1_contains": ["[hello] this is bob's machine"],
        "expect_peer1_missing": ["this is ada's"],
    }, {"main.cbricks": main, "scripts/rules.cbricks": rules, "scripts/spawner.cbricks": spawner, "scripts/hello.cbricks": hello, "scripts/avatar.cbricks": avatar}, scene, extra={"scenes/avatar.cbscene": avatar_scene})


def net_invoke():
    main = Script()
    st = main.b("start")
    role = main.b("network", {"do": "Role"}, {}, {"result": "role"})
    isr = main.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    main.chain([role, isr])
    main.nodes[st - 1]["links"]["out"] = [role]
    main.nodes[isr - 1]["links"]["true"] = [main.chain([main.b("wait", {}, {"seconds": F(3.4)})] + main.say("[server] done"))]
    me = main.b("player", {"op": "Name"}, {}, {"result": "me"})
    a1 = main.b("invoke_server", {"remote": "price"}, {"item": S("sword"), "timeout": F(3)}, {"answer": "cost", "answered": "ok"})
    a2 = main.b("invoke_server", {"remote": "price"}, {"item": S("rock"), "timeout": F(3)}, {"answer": "cost2", "answered": "ok2"})
    a3 = main.b("invoke_server", {"remote": "token"}, {"timeout": F(3)}, {"answer": "tok"})
    tn = main.b("object", {"op": "Name"}, {"object": V("tok")}, {"result": "tname"})
    mine = main.b("ownership", {"do": "Is mine"}, {"object": V("tok")}, {"result": "mine"})
    a4 = main.b("invoke_server", {"remote": "slow"}, {"timeout": F(0.3)}, {"answered": "ok4"})
    stay = main.b("args", {"what": "Option"}, {"name": S("stay")}, {"result": "stay_text"})
    secs = main.b("text", {"op": "To float"}, {"text": V("stay_text")}, {"result": "stay"})
    w = main.b("wait", {}, {"seconds": V("stay")})
    main.nodes[isr - 1]["links"]["false"] = [main.chain([me, a1] + main.say("[{}] sword: {} ({})", V("me"), V("cost"), V("ok")) + [a2]
        + main.say("[{}] rock: {} ({})", V("me"), V("cost2"), V("ok2")) + [a3, tn, mine] + main.say("[{}] got {}, mine: {}", V("me"), V("tname"), V("mine"))
        + [a4] + main.say("[{}] slow answered: {}", V("me"), V("ok4")) + [stay, secs, w] + main.say("[{}] done", V("me")))]
    defs = Script()
    defs.b("remote", {"name": "price", "direction": "Ask server", "values": [["item", "string"]], "answer": "int"})
    defs.b("remote", {"name": "token", "direction": "Ask server", "values": [], "answer": "Token"})
    defs.b("remote", {"name": "slow", "direction": "Ask server", "values": [], "answer": "bool"})
    server = Script("Server")
    op = server.b("on_client_invoked", {"remote": "price"})
    sn = server.b("player", {"op": "Name"}, {"player": V("sender")}, {"result": "sname"})
    sw = server.b("if", {"operator": "=="}, {"a": V("item"), "b": S("sword")})
    server.nodes[sw - 1]["links"]["true"] = [server.chain([server.b("answer", {}, {"value": I(100)})] + server.say("[server] priced {} for {}", V("item"), V("sname")))]
    server.nodes[sw - 1]["links"]["false"] = [server.chain(server.say("[server] no price for {}", V("item")))]
    server.nodes[op - 1]["links"]["out"] = [server.chain([sn, sw])]
    ot = server.b("on_client_invoked", {"remote": "token"})
    tsn = server.b("player", {"op": "Name"}, {"player": V("sender")}, {"result": "tsname"})
    nt = server.b("new_object", {"of": "Token", "world": True}, {}, {"object": "t"})
    nm = server.b("text", {"op": "Format", "format": "token-{}"}, {"first": V("tsname")}, {"result": "tn"})
    setn = server.b("object", {"op": "Set name"}, {"object": V("t"), "name": V("tn")})
    give = server.b("ownership", {"do": "Give to"}, {"object": V("t"), "player": V("sender")})
    ans = server.b("answer", {}, {"value": V("t")})
    server.nodes[ot - 1]["links"]["out"] = [server.chain([tsn, nt, nm, setn, give, ans])]
    osl = server.b("on_client_invoked", {"remote": "slow"})
    server.nodes[osl - 1]["links"]["out"] = [server.chain([server.b("wait", {}, {"seconds": F(0.8)}), server.b("answer", {}, {"value": {"type": "bool", "value": "true"}})] + server.say("[server] answered slow"))]
    token = Script()
    token.b("class", {"name": "Token", "extends": "Node", "fields": [], "synced": ""})
    port = "127.0.0.1:47320"
    write_case("net_invoke", """Invoke (port 47320): each client asks price (sword: the server Answers 100; rock: no
Answer, so Answered false and 0 at once, not after the Timeout), token (the server makes a
Token, names it, gives it to the asker and Answers it: the client's copy is already there,
and it's theirs) and slow (the server Waits 0.8 s before answering; the client's Timeout
is 0.3: Answered false). Two clients ask at once.""", {
        "peers": ["--server 47320", "--join %s --name ada --stay 1.6" % port, "--join %s --name bob --stay 1.2" % port],
        "peer_delay": 0.4,
        "expect_peer0_contains": ["[server] priced sword for ada", "[server] no price for rock", "[server] priced sword for bob", "[server] answered slow", "[server] done"],
        "expect_peer1_order": ["[ada] sword: 100 (true)", "[ada] rock: 0 (false)", "[ada] got token-ada, mine: true", "[ada] slow answered: false", "[ada] done"],
        "expect_peer1_contains": ["Invoke Server: no answer in time"],
        "expect_peer2_order": ["[bob] sword: 100 (true)", "[bob] rock: 0 (false)", "[bob] got token-bob, mine: true", "[bob] slow answered: false", "[bob] done"],
    }, {"main.cbricks": main, "scripts/remotes.cbricks": defs, "scripts/server.cbricks": server, "scripts/token.cbricks": token})


def net_spin():
    main = Script()
    st = main.b("start")
    win = main.b("window", {}, {"width": I(160), "height": I(120), "title": S("spin"), "fps": I(60)})
    vars_ = [main.b("var", {"mode": "Set", "name": n}, {"value": F(v)}) for n, v in [("last", 0), ("max_step", 0), ("min_step", 0), ("frames", 0), ("jerks", 0)]]
    role = main.b("network", {"do": "Role"}, {}, {"result": "role"})
    loop = main.b("game_loop")
    main.chain([win] + vars_ + [role, loop])
    main.nodes[st - 1]["links"]["out"] = [win]
    # each frame (clients): the spinner's copy's rotation.y, the step since the last frame
    isc = main.b("if", {"operator": "=="}, {"a": V("role"), "b": S("client")})
    fnd = main.b("object", {"op": "Find", "of": "Shape3D"}, {"name": S("Spinner")}, {"result": "sp"})
    ex = main.b("object", {"op": "Exists"}, {"object": V("sp")}, {"result": "there"})
    thr = main.b("if", {"operator": "is true"}, {"a": V("there")})
    rot = main.b("field", {"mode": "Get", "field": "rotation"}, {"record": V("sp")}, {"value": "rot"})
    ry = main.b("formula", {"expression": "rot.y", "type": "float"}, {}, {"result": "ry"})
    cnt = main.b("var", {"mode": "Add", "name": "frames"}, {"value": F(1)})
    stp = main.b("formula", {"expression": "frames > 20 ? ry - last : 0", "type": "float"}, {}, {"result": "step"})
    mx = main.b("formula", {"expression": "step > max_step ? step : max_step", "type": "float"}, {}, {"result": "max_step"})
    mn = main.b("formula", {"expression": "step < min_step ? step : min_step", "type": "float"}, {}, {"result": "min_step"})
    ls = main.b("var", {"mode": "Set", "name": "last"}, {"value": V("ry")})
    # a jerk: a frame where it turned at under a third or over 2.5 times its speed (120 / s)
    fdt = main.b("game_info", {"what": "Frame time"}, {}, {"result": "fdt"})
    jk = main.b("formula", {"expression": "jerks + ((frames > 20 && fdt > 0 && (step / fdt < 40.0 || step / fdt > 300.0)) ? 1 : 0)", "type": "float"}, {}, {"result": "jerks"})
    main.nodes[thr - 1]["links"]["true"] = [main.chain([rot, ry, cnt, stp, mx, mn, ls, fdt, jk])]
    main.nodes[isc - 1]["links"]["true"] = [main.chain([fnd, ex, thr])]
    t = main.b("game_info", {"what": "Time"}, {}, {"result": "t"})
    end = main.b("if", {"operator": ">"}, {"a": V("t"), "b": F(2.6)})
    steady = main.b("formula", {"expression": "min_step > -0.5 && frames > 60 && jerks < (frames - 20) / 10", "type": "bool"}, {}, {"result": "steady"})
    main.nodes[end - 1]["links"]["true"] = [main.chain([steady] + main.say("[spin] {} steady: {} ({} frames, {} jerky)", V("role"), V("steady"), V("frames"), V("jerks")) + main.say("[spin] biggest step {}, smallest {}", V("max_step"), V("min_step")) + [main.b("close_window")])]
    main.nodes[loop - 1]["links"]["frame"] = [isc, t, end]
    spinner = Script()
    spinner.b("class", {"name": "Spinner", "extends": "Shape3D", "fields": [], "synced": ""})
    ef = spinner.b("every_frame")
    spinner.nodes[ef - 1]["links"]["out"] = [spinner.b("var", {"mode": "Add", "name": "rotation"}, {"value": {"type": "vector3", "value": "0, 120 * dt, 0"}})]
    scene = [{"id": 1, "class": "Spinner", "name": "Spinner", "parent": 0, "fields": {"rotation": "45, 0, 45"}},
             {"id": 2, "class": "Camera3D", "name": "Camera", "parent": 0, "fields": {"position": "0, 2, 4"}}]
    port = "127.0.0.1:47321"
    write_case("net_spin", """A spinning Shape3D (port 47321): the dedicated server turns it 120 degrees a second (4
between updates), a client with a window reads its copy's rotation every frame: it moves
forward steadily (never back; under a tenth of its frames turn at under a third or over 2.5
times its speed: without gliding, a copy turns 4 degrees every other frame). User: "gems rotations get
super buggy/fast/jittery"; the snap distance (4 world units) was used for degrees too, so it
glided one update and jumped the next.""", {
        "peers": ["--server 47321", "--join %s --name ada" % port],
        "peer_delay": 0.4,
        "expect_peer1_contains": ["[spin] client steady: true"],
    }, {"main.cbricks": main, "scripts/spinner.cbricks": spinner}, scene)


def net_ui():
    main = Script()
    st = main.b("start")
    win = main.b("window", {}, {"width": I(160), "height": I(120), "title": S("net ui"), "fps": I(60)})
    role = main.b("network", {"do": "Role"}, {}, {"result": "role"})
    isr = main.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    main.chain([win, role, isr])
    main.nodes[st - 1]["links"]["out"] = [win]
    lab = main.b("new_object", {"of": "Label", "world": True}, {}, {"object": "lab"})
    ln = main.b("object", {"op": "Set name"}, {"object": V("lab"), "name": S("ServerLabel")})
    box = main.b("new_object", {"of": "Shape3D", "world": True}, {}, {"object": "box"})
    bn = main.b("object", {"op": "Set name"}, {"object": V("box"), "name": S("ServerBox")})
    main.nodes[isr - 1]["links"]["true"] = [main.chain([lab, ln, box, bn] + main.say("[server] made a Label and a Shape3D"))]
    loop = main.b("game_loop")
    main.nodes[isr - 1]["links"]["next"] = [loop]
    t = main.b("game_info", {"what": "Time"}, {}, {"result": "t"})
    end = main.b("if", {"operator": ">"}, {"a": V("t"), "b": F(1.5)})
    fl = main.b("object", {"op": "Find", "of": "Label"}, {"name": S("ServerLabel")}, {"result": "l"})
    le = main.b("object", {"op": "Exists"}, {"object": V("l")}, {"result": "has_l"})
    fb = main.b("object", {"op": "Find", "of": "Shape3D"}, {"name": S("ServerBox")}, {"result": "b"})
    be = main.b("object", {"op": "Exists"}, {"object": V("b")}, {"result": "has_b"})
    main.nodes[end - 1]["links"]["true"] = [main.chain([fl, le, fb, be] + main.say("[{}] label here: {}, box here: {}", V("role"), V("has_l"), V("has_b")) + [main.b("close_window")])]
    main.nodes[loop - 1]["links"]["frame"] = [main.chain([t, end])]
    port = "127.0.0.1:47323"
    write_case("net_ui", """UI stays on its machine (port 47323): a dedicated server makes a Label and a Shape3D in the
world while running; its client gets the Shape3D, not the Label (each machine builds its own UI).""", {
        "peers": ["--server 47323", "--join %s --name ada" % port],
        "peer_delay": 0.4,
        "expect_peer0_contains": ["[server] made a Label and a Shape3D", "[server] label here: true, box here: true"],
        "expect_peer1_contains": ["[client] label here: false, box here: true"],
    }, {"main.cbricks": main})


def net_pause():
    main = Script()
    st = main.b("start")
    win = main.b("window", {}, {"width": I(160), "height": I(120), "title": S("net pause"), "fps": I(60)})
    role = main.b("network", {"do": "Role"}, {}, {"result": "role"})
    f0 = main.b("var", {"mode": "Set", "name": "frames"}, {"value": I(0)})
    w0 = main.b("var", {"mode": "Set", "name": "world_t"}, {"value": F(0)})
    isr = main.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    tick = main.b("new_object", {"of": "Ticker", "world": True}, {}, {"object": "tk"})
    main.nodes[isr - 1]["links"]["true"] = [main.chain([main.b("pause", {"do": "Set time scale"}, {"scale": F(0.5)}), main.b("pause", {"do": "Pause"}), tick])]
    loop = main.b("game_loop")
    main.chain([win, role, f0, w0, isr, loop])
    main.nodes[st - 1]["links"]["out"] = [win]
    fr = [main.b("var", {"mode": "Add", "name": "frames"}, {"value": I(1)}), main.b("game_info", {"what": "Frame time"}, {}, {"result": "dt"}),
          main.b("var", {"mode": "Add", "name": "world_t"}, {"value": V("dt")}), main.b("game_info", {"what": "Time"}, {}, {"result": "t"})]
    # the client: pauses at frame 10; measures from frame 20 to 70
    isc = main.b("if", {"operator": "==", }, {"a": V("role"), "b": S("client")})
    p10 = main.b("if", {"operator": "=="}, {"a": V("frames"), "b": I(10)})
    main.nodes[p10 - 1]["links"]["true"] = [main.b("pause", {"do": "Pause"})]
    m20 = main.b("if", {"operator": "=="}, {"a": V("frames"), "b": I(20)})
    main.nodes[m20 - 1]["links"]["true"] = [main.chain([main.b("var", {"mode": "Set", "name": "w20"}, {"value": V("world_t")}), main.b("var", {"mode": "Set", "name": "t20"}, {"value": V("t")}),
                                                        main.b("call", {"function": "get_steps"}, {}, {"result": "s20"})])]
    m70 = main.b("if", {"operator": "=="}, {"a": V("frames"), "b": I(70)})
    rep = [main.b("pause", {"do": "Time scale"}, {}, {"result": "ts"}), main.b("pause", {"do": "Is paused"}, {}, {"result": "isp"}),
           main.b("call", {"function": "get_steps"}, {}, {"result": "s70"}),
           main.b("formula", {"type": "float", "expression": "(world_t - w20) / (t - t20)"}, {}, {"result": "ratio"}),
           main.b("formula", {"type": "bool", "expression": "ratio > 0.4 && ratio < 0.6"}, {}, {"result": "half"}),
           main.b("formula", {"type": "bool", "expression": "s70 > s20 + 30"}, {}, {"result": "ran"})]
    main.nodes[m70 - 1]["links"]["true"] = [main.chain(rep + main.say("[client] time scale {}, its frames at half speed: {}", V("ts"), V("half")) + main.say("[client] Paused? {}, When frame starts still ran: {}", V("isp"), V("ran")) + [main.b("close_window")])]
    main.nodes[isc - 1]["links"]["true"] = [main.chain([p10, m20, m70])]
    # the server: paused itself, the world (its Ticker) runs on
    iss = main.b("if", {"operator": "=="}, {"a": V("role"), "b": S("server")})
    end = main.b("if", {"operator": ">"}, {"a": V("t"), "b": F(3.0)})
    tk2 = main.b("object", {"op": "Find", "of": "Ticker"}, {"name": S("Ticker")}, {"result": "tk2"})
    tks = main.b("field", {"mode": "Get", "field": "ticks"}, {"record": V("tk2")}, {"value": "ticks"})
    ran = main.b("formula", {"type": "bool", "expression": "ticks > 30"}, {}, {"result": "ticked"})
    sp = main.b("pause", {"do": "Is paused"}, {}, {"result": "sp"})
    main.nodes[end - 1]["links"]["true"] = [main.chain([tk2, tks, ran, sp] + main.say("[server] Paused? {}, the world still ran: {}", V("sp"), V("ticked")) + [main.b("close_window")])]
    main.nodes[iss - 1]["links"]["true"] = [end]
    main.nodes[loop - 1]["links"]["frame"] = [main.chain(fr + [isc, iss])]
    steps = Script()  # When frame starts, counted (a client's script: not frozen online)
    fn0 = steps.b("function", {"name": "reset_steps", "returns": "void", "params": []})
    steps.nodes[fn0 - 1]["links"]["out"] = [steps.b("var", {"mode": "Set", "name": "steps", "scope": "Shared"}, {"value": I(0)})]
    fs = steps.b("frame_start")
    steps.nodes[fs - 1]["links"]["out"] = [steps.b("var", {"mode": "Add", "name": "steps"}, {"value": I(1)})]
    fg = steps.b("function", {"name": "get_steps", "returns": "int", "params": []})
    steps.nodes[fg - 1]["links"]["out"] = [steps.b("return", {"gives": "A value"}, {"value": V("steps")})]
    ticker = Script()
    ticker.b("class", {"name": "Ticker", "extends": "Node", "fields": [["ticks", "int"]], "synced": ""})
    ef = ticker.b("every_frame")
    ticker.nodes[ef - 1]["links"]["out"] = [ticker.b("var", {"mode": "Add", "name": "ticks"}, {"value": I(1)})]
    port = "127.0.0.1:47324"
    write_case("net_pause", """Pause and time scale in a network game (port 47324): the dedicated server sets time scale 0.5
and pauses; its Ticker's Every frame runs on (a shared world isn't frozen; Paused? true). The client
gets the world's speed: its Time scale reads 0.5 and its frame time is half the real time; it pauses
too: Paused? true, its When frame starts runs on.""", {
        "peers": ["--server 47324", "--join %s --name ada" % port],
        "peer_delay": 0.4,
        "expect_peer0_contains": ["[server] Paused? true, the world still ran: true"],
        "expect_peer1_contains": ["[client] time scale 0.5, its frames at half speed: true", "[client] Paused? true, When frame starts still ran: true"],
    }, {"main.cbricks": main, "scripts/steps.cbricks": steps, "scripts/ticker.cbricks": ticker})


if __name__ == "__main__":
    net_join()
    net_sides()
    net_problems()
    net_world()
    net_world_3d()
    net_remotes()
    net_keys()
    net_invoke()
    net_spin()
    net_ui()
    net_pause()
    print("wrote tests/cases/net_join, net_host, net_sides, net_problems, net_world, net_world_3d, net_remotes, net_keys, net_invoke, net_spin")
