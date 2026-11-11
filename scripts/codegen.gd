class_name CodeGen
extends RefCounted
## Turns a graph (see ops.gd) into one portable C99 file.
##
## Events (When program starts, Define Function, When program ends) start
## chains. A brick runs, then each chain on its last exit group runs to its end,
## in order. Values travel through variables: a function's variables are
## declared at its top (so every branch sees them); one that a function reads
## but never sets, or a Global one, is declared at file scope.
##
## Every generated line ends with "// brick <id>", so a C compiler's error line
## leads back to its brick (brick_of_line()).

const T = preload("res://scripts/node_defs.gd")
const MARK := "  // brick %d"

var nodes := {}          # id -> node
var layouts := {}        # id -> {"args", "outs", "groups"}
var funcs := {}          # name -> {"returns", "params"}
var types := {}          # variable -> type name
var origins := {}        # variable -> "Shared" / "Chain" / "Loop" / "Input"
var errors: Array = []   # [{node: id, msg}]  (0: the whole program)
var warnings: Array = []
## What each brick can see: id -> {variable: {"type", "origin"}}.
var scopes := {}

var _uses_math := false
var _uses_rand := false
var _uses_time := false
var _uses_string := false
var _includes := []
var _stack := {}
var _globals := {}
var _statics := []       # file-scope buffers (Read line)
var _ctx_of := {}        # id -> context
var _preds := {}         # id -> [[brick wired into it, its exit, the chain's place on that exit]]


## In a project (see ProjectBuild) each script is one .c file including the
## shared "cbricks.h" (every function's prototype and the runtime: arguments,
## trace, files). `ctx`: {"funcs": every function of the project, "file": this
## script's number, "standalone": false}. Without one, the script is checked
## on its own (tests, older single-file use).
var file_index := 0
var standalone := true
var exit_handlers: Array = []     # names of When program ends functions
var has_main := false
var has_init := false
var uses_net := false               # a Network brick or event: the build adds networking
var uses_graphics := false        # any raylib brick (the build adds raylib)
var records := {}                 # record -> [[field, type], ...] (project-wide)
var constants := {}               # constant -> type (project-wide)
var _init_lines := []             # file-scope values that need code (lists, records)
var _protos := []                 # Call C function declarations
var _init_name := "cb_init_main"
var _attached := false      # a Script object's file (the Scene tree)
var _scenes: Dictionary = {}  # the project's scenes (ProjectBuild.collect_scenes)
var _script_start := ""     # its When program starts' C function
var _class := ""                   # this script's class ("" : a plain script)
var _side := "Shared"              # where this script runs: Shared / Server / Client
var _always := false               # the script Runs while paused (its frame events go on while paused offline)
var _world_loader := false         # the project has a world file: main() makes its objects first
var _fields := {}                  # in a class script: field -> type (its own and inherited)

## {"code", "errors", "warnings", "scopes", "types", "exit_handlers", "has_main"}
func generate(graph: Dictionary, options: Dictionary = {}) -> Dictionary:
	_reset()
	file_index = int(options.get("file", 0))
	_script_name = str(options.get("script", "main.cbricks"))
	standalone = not options.has("funcs")
	for n in graph.get("nodes", []):
		if T.DEFS.has(n.get("type", "")):
			nodes[int(n.id)] = n
	funcs = T.collect_functions(nodes.values())
	if not standalone:
		funcs = options.funcs
	records = options.get("records", T.collect_records(nodes.values()))
	constants = options.get("constants", {})
	if standalone:
		for n in nodes.values():
			if n.type == "constant":
				constants[str(n.fields.get("name", ""))] = str(n.fields.get("type", "int"))
	_init_name = str(options.get("init_name", "cb_init_main"))
	_attached = bool(options.get("attached", false))
	_scenes = options.get("scenes", {})
	_script_start = ""
	_class = str(options.get("class", ""))
	_side = str(options.get("side", "Shared"))
	_always = bool(options.get("always", false))
	_world_loader = bool(options.get("world_loader", false))
	if _class != "":
		for fld in CBTypes.all_fields(_class):
			_fields[fld[0]] = fld[1]
	for id in nodes:
		layouts[id] = T.layout_for(nodes[id].type, _f(id), funcs)

	# --- entry points
	var contexts := []
	var seen_names := {}
	var starts := []
	for id in nodes:
		var n: Dictionary = nodes[id]
		var why := misplaced(str(n.type), _f(id), _class, _side)
		if why != "":
			_err(id, why)
			errors[errors.size() - 1]["context"] = true  # (greyed on the canvas: a brick in the wrong place)
			continue
		match n.type:
			"start":
				starts.append(id)
			"exit":
				contexts.append({"entry": id, "name": "on_exit_%d_%d" % [file_index, id], "ret": "void", "params": {}, "exit": true})
			"every_frame", "touched", "drawn", "clicked":
				var ev: Array = CBTypes.EVENTS[n.type]
				var eparams := {"self": _class}
				for ep in ev[1]:
					eparams[ep[1]] = ep[0]
				contexts.append({"entry": id, "name": ev[0], "ret": "void", "params": eparams, "method": true, "c_name": "%s_%s" % [CBTypes.cname(_class), ev[0]]})
			"player_joined", "player_left":
				uses_net = true
				contexts.append({"entry": id, "name": "on_%s_%d_%d" % [n.type, file_index, id], "ret": "void", "params": {"player": "int"}, "net_event": true, "joined": n.type == "player_joined"})
			"button_clicked":
				uses_graphics = true
				contexts.append({"entry": id, "name": "on_click_%d_%d" % [file_index, id], "ret": "void", "params": {"button": "Button"}, "click_event": str(_f(id).get("button", "")).strip_edges()})
			"frame_start", "frame_end":
				uses_graphics = true  # (frames are the Game loop's)
				contexts.append({"entry": id, "name": "on_%s_%d_%d" % [n.type, file_index, id], "ret": "void", "params": {"dt": "float"}, "frame_event": 0 if n.type == "frame_start" else 1})
			"player_key":
				uses_net = true
				uses_graphics = true  # (keys come from players' windows)
				var kname := str(_f(id).get("key", "SPACE"))
				contexts.append({"entry": id, "name": "on_key_%d_%d" % [file_index, id], "ret": "void", "params": {"player": "int"}, "net_event": true, "key": CBTypes.net_keys.find(kname), "pressed": str(_f(id).get("when", "Pressed")) == "Pressed"})
			"on_client_fired", "on_server_fired", "on_client_invoked":
				uses_net = true
				var to_server: bool = n.type != "on_server_fired"
				var invoked: bool = n.type == "on_client_invoked"
				var rname := str(_f(id).get("remote", ""))
				var r = CBTypes.remotes.get(rname)
				if r == null:
					_err(id, "pick a remote (add a Define Remote brick first)." if rname == "" else "there's no remote named '%s'." % rname, "remote")
					continue
				if invoked and str(r.direction) != "Ask server":
					_err(id, "the remote '%s' goes %s: On Client Invoked answers a question (make its Direction Ask server), or use On Client Fired." % [rname, str(r.direction).to_lower()], "remote")
					continue
				if not invoked and str(r.direction) == "Ask server":
					_err(id, "the remote '%s' is a question (Ask server): it arrives at On Client Invoked." % rname, "remote")
					continue
				if str(r.direction) == ("To clients" if to_server else "To server"):
					_err(id, "the remote '%s' goes %s: %s." % [rname, str(r.direction).to_lower(), "make it To server or Both" if to_server else "make it To clients or Both"], "remote")
					continue
				var rparams := {}
				for prm in r.params:
					rparams[str(prm[1])] = str(prm[0])
				if to_server:
					rparams["sender"] = "int"
				contexts.append({"entry": id, "name": "on_%s_%d_%d" % [rname, file_index, id], "ret": "void", "params": rparams, "remote": r, "to_server": to_server, "invoked": invoked})
			"created":
				contexts.append({"entry": id, "name": "created", "ret": "void", "params": {"self": _class}, "method": true, "c_name": "%s__created" % CBTypes.cname(_class)})
			"function":
				var fname := str(_f(id).get("name", ""))
				if not fname.is_valid_identifier() or fname == "main":
					_err(id, "'%s' can't be a function name: letters, digits and _, not starting with a digit." % fname)
					continue
				if seen_names.has(fname):
					_err(id, "there are two functions named '%s'." % fname)
					continue
				seen_names[fname] = true
				var params := {}
				for p in T.parse_params(_f(id).get("params", [])):
					params[p[1]] = p[0]
				for p in params:
					if not CBTypes.valid(params[p], records):
						_err(id, "input '%s' has an unknown type '%s'." % [p, params[p]])
				var ret := str(_f(id).get("returns", "void"))
				if ret != "void" and not CBTypes.valid(ret, records):
					_err(id, "it gives back an unknown type '%s'." % ret)
				if _class != "":
					var mparams := {"self": _class}
					mparams.merge(params)
					contexts.append({"entry": id, "name": fname, "ret": str(_f(id).get("returns", "void")), "params": mparams, "method": true, "c_name": "%s_%s" % [CBTypes.cname(_class), fname]})
				else:
					contexts.append({"entry": id, "name": fname, "ret": str(_f(id).get("returns", "void")), "params": params})
			"include":
				var h := str(_f(id).get("header", "")).strip_edges()
				if h == "":
					continue
				if not (h.begins_with("<") or h.begins_with("\"")):
					h = "<%s>" % h
				if h not in _includes:
					_includes.append(h)
	if not starts.is_empty() and _class == "" and _attached:
		# A Script object's file (the Scene tree): its When program starts runs once for
		# each such object, `parent` = the object it's under (Roblox's script.Parent).
		_script_start = "cb_script_start_%d" % file_index
		contexts.append({"entry": starts[0], "name": "script_start", "ret": "void", "params": {"parent": CBTypes.OBJECT}, "script_start": true})
		starts.clear()
	if not starts.is_empty() and _class != "":
		_err(starts[0], "When program starts can't be in a class's script (%s): put it in a plain script, e.g. main.cbricks." % _class)
		starts.clear()
	if starts.is_empty():
		if standalone and _script_start == "":
			_err(0, "No 'When program starts' brick: add one, it becomes main().")
	else:
		has_main = true
		contexts.append({"entry": starts[0], "name": "main", "ret": "int", "params": {}})

	# --- what each context writes / reads
	for ctx in contexts:
		ctx.reach = _reachable(ctx.entry)
		ctx.writes = []
		ctx.reads = []
		for id in ctx.reach:
			_ctx_of[id] = ctx
			for v in _writes(id):
				if v not in ctx.writes:
					ctx.writes.append(v)
			for v in _reads(id):
				if v not in ctx.reads:
					ctx.reads.append(v)
	_infer_types(contexts)
	# Variables belong to their chain (its event or function: Brickscript's chain
	# variables) unless they're made Shared: by Variable (Set) with Kind Shared, or an
	# output's new variable with Kind Shared. Nothing is shared by being read elsewhere.
	for id in nodes:
		if nodes[id].type == "var" and str(_f(id).get("mode")) == "Set" and str(_f(id).get("scope")) in ["Shared", "Global"]:  # (Global: older files)
			_globals[str(_f(id).get("name", ""))] = true
		for o in nodes[id].get("outs", {}).values():
			if o is Dictionary and str(o.get("kind", "")) in ["Shared", "Global"] and not bool(o.get("use", false)) and str(o.get("var", "")) != "":
				_globals[str(o.var)] = true
	for v in types:
		if _globals.has(v):
			origins[v] = "Shared"
	_check_reads(contexts)

	# --- bodies
	var bodies := []
	var main_code := ""
	for ctx in contexts:
		var body := _group(ctx.entry, "out", 1, ctx)
		var decls := ""
		for v in ctx.writes:
			if ctx.params.has(v) or _globals.has(v) or _fields.has(v):
				continue
			decls += "    %s %s = %s;\n" % [_ctype(v), v, CBTypes.zero(types.get(v, "int"))]
		decls += _frame(ctx)
		var enter := "    CB_TRACE(%d, %d);%s\n" % [file_index, ctx.entry, MARK % ctx.entry]
		if ctx.name == "main":
			main_code = decls + enter + body
			continue
		var sig := signature(ctx.name, ctx.ret, ctx.params)
		if ctx.get("script_start", false):
			sig = "void %s(void *parent_)" % _script_start
			decls = "    %s parent = (%s)parent_;\n" % [CBTypes.c_type(CBTypes.OBJECT), CBTypes.c_type(CBTypes.OBJECT)] + decls
		if ctx.get("method", false):
			var plist := []
			for pn in ctx.params:
				if pn != "self":
					plist.append([ctx.params[pn], pn])
			# An event's object inputs come as void * (the runtime's hooks), cast inside.
			var event_obj: bool = ctx.name.begins_with("on_") and CBTypes.EVENTS.values().any(func(e): return e[0] == ctx.name)
			sig = "%s %s(%s)" % [CBTypes.c_type(ctx.ret), ctx.c_name, ", ".join(["void *self_"] + plist.map(func(x): return ("void *%s_" % x[1]) if event_obj and CBTypes.is_class_type(x[0]) else "%s %s" % [CBTypes.c_type(x[0]), x[1]]))]
			if ctx.name == "created":
				sig = "static " + sig
			for x in plist:
				if event_obj and CBTypes.is_class_type(x[0]):
					decls = "    %s %s = (%s)%s_;\n" % [CBTypes.c_type(x[0]), x[1], CBTypes.c_type(x[0]), x[1]] + decls
			decls = "    %s *self = (%s *)self_;\n" % [CBTypes.cname(_class), CBTypes.cname(_class)] + decls
		if ctx.get("exit", false):
			exit_handlers.append(ctx.name)
		if ctx.has("frame_event"):
			# Registered at the start; the Game loop calls it every frame (cb_frame_events).
			sig = "static void %s(double dt)" % ctx.name
			_protos.append("static void %s(double dt);" % ctx.name)
			_init_lines.append("    cb_on_frame(%d, %d, %d, %s);  /* %s (%s script) */" % [int(ctx.frame_event), CBTypes.side_bits(_side), 1 if _always else 0, ctx.name, T.DEFS[nodes[ctx.entry].type].title, _side])
		if ctx.has("click_event"):
			# Registered at the start; the runtime calls it when a Button (of that name, or any) is clicked.
			sig = "static void %s(void *button_)" % ctx.name
			decls = "    cls_Button *button = (cls_Button *)button_;\n" + decls
			_protos.append("static void %s(void *button_);" % ctx.name)
			_init_lines.append("    cb_on_click(%d, %s, %s);  /* When button clicked%s (%s script) */" % [CBTypes.side_bits(_side), c_string(str(ctx.click_event)), ctx.name, (": " + str(ctx.click_event)) if str(ctx.click_event) != "" else "", _side])
		if ctx.has("remote"):
			# Registered at the start; the runtime calls it with the sender, its values read in order.
			sig = "static void %s(int %s)" % [ctx.name, "sender" if ctx.to_server else "sender_"]
			var reads := ""
			for prm in ctx.remote.params:
				reads += "    %s %s = %s;\n" % [CBTypes.c_type(str(prm[0])), prm[1], _msg_get(str(prm[0]))]
			if not ctx.to_server:
				reads = "    (void)sender_;\n" + reads
			decls = reads + decls
			_protos.append("static void %s(int sender%s);" % [ctx.name, "" if ctx.to_server else "_"])
			_init_lines.append("    cb_net_on_remote(%d, %d, %s);  /* %s: %s (%s script) */" % [int(ctx.remote.index), 4 if ctx.get("invoked", false) else (1 if ctx.to_server else 2), ctx.name, T.DEFS[nodes[ctx.entry].type].title, _f(ctx.entry).get("remote", ""), _side])
		if ctx.get("net_event", false):
			# Registered at the start (this file's init); the runtime calls it with a player's number.
			sig = "static void %s(int player)" % ctx.name
			_protos.append("static void %s(int player);" % ctx.name)
			if ctx.has("key"):
				_init_lines.append("    cb_net_on_key(%d, %s, %s);  /* Player Key: %s %s */" % [int(ctx.key), "true" if ctx.pressed else "false", ctx.name, _f(ctx.entry).get("key", "SPACE"), "pressed" if ctx.pressed else "released"])
			else:
				_init_lines.append("    cb_net_on_player(%s, %d, %s);  /* %s (%s script) */" % ["true" if ctx.joined else "false", CBTypes.side_bits(_side), ctx.name, T.DEFS[nodes[ctx.entry].type].title, _side])
		var tail := "    return %s;\n" % CBTypes.zero(ctx.ret) if ctx.ret != "void" else ""
		bodies.append("%s {%s\n%s%s}\n" % [sig, MARK % ctx.entry, decls + enter + body, tail])

	# --- scopes for the editor's variable dropdowns
	# Brickscript's way: a brick offers the variables made by what runs before it in
	# its chain (walking back along the wires), plus what's always there: Globals, the
	# class's fields, Constants, its function's inputs (Self, an event's values).
	_preds = {}
	for id in nodes:
		var links: Dictionary = nodes[id].get("links", {})
		for g in links:
			var targets: Array = links[g]
			for i in targets.size():
				var t := int(targets[i])
				if not _preds.has(t):
					_preds[t] = []
				_preds[t].append([id, str(g), i])
	var memo := {}
	var subtree_memo := {}
	for id in nodes:
		var ctx = _ctx_of.get(id)
		var seen := {}
		for v in _made_before(id, memo, subtree_memo):
			if types.has(v):
				seen[v] = {"type": types.get(v, "int"), "origin": "Shared" if _globals.has(v) else origins.get(v, "Chain")}
		for v in _globals:
			seen[v] = {"type": types.get(v, "int"), "origin": "Shared"}
		for fname in _fields:
			seen[fname] = {"type": _fields[fname], "origin": "Field"}
		if ctx != null:
			for p in ctx.params:
				seen[p] = {"type": ctx.params[p], "origin": "Self" if p == "self" else "Input"}
		for c in constants:
			seen[c] = {"type": constants[c], "origin": "Constant"}
		scopes[id] = seen
	# A variable read where the chain hasn't made it yet (Brickscript: "not usable here").
	for ctx in contexts:
		for id in ctx.reach:
			var names := []
			if nodes[id].type == "var" and str(_f(id).get("mode", "Set")) != "Set":
				names.append([str(_f(id).get("name", "")).strip_edges(), "name"])
			for a in layouts[id].args:
				if _arg_used(id, a) and _arg_spec(id, a[0]).has("var"):
					names.append([_arg_var(id, a[0]), a[0]])
			for pair in names:
				var v: String = pair[0]
				if v != "" and types.has(v) and not scopes[id].has(v):
					_warn(id, "'%s' isn't made before this brick in its chain (it's made later, or in another chain): here it still holds its starting value." % v)

	# --- assemble
	var out := PackedStringArray()
	out.append("/* Generated by C-Bricks from %s. Do not edit: it is rewritten from its graph. */" % str(ctx_script(graph)))
	out.append("#include \"cbricks.h\"")
	for h in _includes:
		out.append("#include %s" % h)
	out.append("")
	if not _protos.is_empty():
		out.append_array(_protos)
		out.append("")
	if not _globals.is_empty() or not _statics.is_empty():
		for g in _globals:
			var gt: String = types.get(g, "int")
			out.append("static %s %s = %s;" % [_ctype(g), g, CBTypes.static_zero(gt)])
			if CBTypes.needs_init(gt):
				_init_lines.append("    %s = %s;" % [g, CBTypes.zero(gt)])
		out.append_array(_statics)
		out.append("")
	if not _globals.is_empty() and not contexts.is_empty():
		var gv := []
		for g in _globals:
			gv.append(_var_entry(g, types.get(g, "int")))
		out.append("/* This file's globals, for the debugger */")
		out.append("static const cb_var cb_globals_[] = {\n    %s\n};" % ",\n    ".join(gv))
		out.append("")
	if not _init_lines.is_empty():
		has_init = true
		out.append("void %s(void) {  /* fresh values for this file's global lists / records */" % _init_name)
		out.append_array(_init_lines)
		out.append("}")
		out.append("")
	if _class != "" and not bodies.is_empty():
		# Inside a class's methods its fields are used by name: each one becomes self's member.
		var owners := {}
		for fld in CBTypes.all_fields(_class):
			owners[fld[0]] = CBTypes.cname(fld[2])
		for b in bodies:
			out.append(rewrite_fields(b, owners))
	else:
		out.append_array(bodies)
	if has_main:
		out.append("int main(int argc, char **argv) {" + MARK % starts[0])
		out.append("    cb_start(argc, argv);")
		if _world_loader:
			out.append("    cb_load_world();  /* world.cnworld's objects */")
		out.append("    cb_ready();  /* the program is ready: networking's Player Joined from here */")
		if main_code != "":
			out.append(main_code.trim_suffix("\n"))
		out.append("    return 0;")
		out.append("}")
	var code := "\n".join(out) + "\n"
	if standalone:
		code = ProjectBuild.header({}, _includes, {"exit_handlers": exit_handlers}, true) + "\n" + code.replace("#include \"cbricks.h\"\n", "") + "\n" + ProjectBuild.runtime("program", "1.0", ["main.cbricks"], exit_handlers, true)
	return {"code": code, "errors": errors, "warnings": warnings, "scopes": scopes, "types": types, "exit_handlers": exit_handlers, "has_main": has_main, "script_start": _script_start, "has_init": has_init, "uses_graphics": uses_graphics, "uses_net": uses_net}


var _script_name := "main.cbricks"


func ctx_script(_graph: Dictionary) -> String:
	return _script_name


## The debugger's view of a function: its variables (and the file's globals).
func _frame(ctx: Dictionary) -> String:
	var vars := []
	for p in ctx.params:
		vars.append(_var_entry(p, ctx.params[p]))
	for v in ctx.writes:
		if ctx.params.has(v) or _globals.has(v) or _fields.has(v):
			continue
		vars.append(_var_entry(v, types.get(v, "int")))
	if ctx.get("method", false):
		for fname in _fields:
			vars.append(_var_entry(fname, _fields[fname]))
	var globals := "cb_globals_, %d" % _globals.size() if not _globals.is_empty() else "NULL, 0"
	if vars.is_empty():
		return "    const cb_frame cb_here_ = { NULL, 0, %s };\n" % globals
	return "    const cb_var cb_vars_[] = {\n        %s\n    };\n    const cb_frame cb_here_ = { cb_vars_, %d, %s };\n" % [",\n        ".join(vars), vars.size(), globals]


func _var_entry(v: String, t: String) -> String:
	return "{ %s, %s, &%s, %s }" % [c_string(v), c_string(t), v, CBTypes.show_fn(t)]


## "int factorial(int n)"
static func signature(name: String, ret: String, params: Dictionary) -> String:
	var plist := []
	for p in params:
		plist.append("%s %s" % [CBTypes.c_type(params[p]), p])
	return "%s %s(%s)" % [CBTypes.c_type(ret), name, ", ".join(plist) if plist else "void"]


## The brick a line of generated code came from (0 if none).
static func brick_of_line(code: String, line: int) -> int:
	var lines := code.split("\n")
	if line < 1 or line > lines.size():
		return 0
	var at := lines[line - 1].rfind("// brick ")
	return lines[line - 1].substr(at + 9).to_int() if at >= 0 else 0


func _reset() -> void:
	nodes = {}; layouts = {}; funcs = {}; types = {}; origins = {}; scopes = {}
	errors = []; warnings = []; _includes = []; _stack = {}; _globals = {}; _statics = []; _ctx_of = {}; _preds = {}
	_uses_math = false; _uses_rand = false; _uses_time = false; _uses_string = false
	exit_handlers = []; has_main = false; has_init = false; uses_graphics = false; uses_net = false
	records = {}; constants = {}; _init_lines = []; _protos = []; _class = ""; _fields = {}; _side = "Shared"


func _f(id: int) -> Dictionary:
	return nodes[id].get("fields", {})


func _title(id: int) -> String:
	return T.title_of(nodes[id].type, _f(id)) if nodes.has(id) else "?"


## "Print (node 4) > value: ..." (Brickscript's problem format).
## Where a brick may go (2026-11-08): "" or why not, for its script's class ("" a plain script)
## and side (Shared / Server / Client). Codegen makes it a problem; the editor greys such a
## brick on the canvas (red outline) and in the palette. fields: the brick's settings (a
## family's mode); without them (the palette's entries) only the rules for every mode count.
static func misplaced(type: String, fields: Dictionary, cls: String, side: String, with_fields := true) -> String:
	var title: String = str(T.DEFS[type].title) if T.DEFS.has(type) else type
	match type:
		"exit":
			if cls != "":
				return "When program ends can't be in a class's script (%s): put it in a plain script." % cls
		"every_frame", "touched", "drawn", "clicked":
			if cls == "":
				return "%s belongs in a class's script (one with a Class brick)." % title
			if type == "touched" and not CBTypes.is_subclass(cls, "Shape3D"):
				return "When touched is for Shape3Ds: make %s extend Shape3D (or a class that does)." % cls
			if type == "clicked" and not CBTypes.is_subclass(cls, "Button"):
				return "When clicked is for Buttons: make %s extend Button (or use When button clicked in a plain script)." % cls
		"player_joined", "player_left":
			if cls != "":
				return "%s belongs in a plain script (not a class's): it runs once per player, not per object." % title
		"button_clicked":
			if cls != "":
				return "When button clicked belongs in a plain script (a class extending Button has When clicked)."
			if side == "Server":
				return "When button clicked runs on players' machines (the UI is theirs): not in a Server script (tell the server with Fire Server)."
		"frame_start", "frame_end":
			if cls != "":
				return "%s belongs in a plain script (not a class's: its objects have Every frame)." % title
		"player_key":
			if cls != "":
				return "Player Key belongs in a plain script (not a class's)."
			if side == "Client":
				return "Player Key runs where the game's rules run: not in a Client script (there, read your own keys with Input)."
		"on_client_fired", "on_server_fired", "on_client_invoked":
			if cls != "":
				return "%s belongs in a plain script (not a class's)." % title
			var to_server := type != "on_server_fired"
			if (to_server and side == "Client") or (not to_server and side == "Server"):
				return "%s runs on %s: it can't be in a %s script." % [title, "the server" if to_server else "players' machines", side]
		"created":
			if cls == "":
				return "When created belongs in a class's script (one with a Class brick)."
		"player_input":
			if side == "Client":
				return "Player Input reads players' keys where the game's rules run: not in a Client script (there, use Input / Key Direction)."
		"network":
			var op := str(fields.get("do", "Host"))
			if with_fields and op in ["Host", "Join", "Leave"] and side == "Server":
				return "%s is a player's choice: use it in a Client or Shared script (a Server script runs where the game's rules run)." % op
		"fire_server", "fire_clients":
			var to_server := type == "fire_server"
			if (to_server and side == "Server") or (not to_server and side == "Client"):
				return "%s is for %s: it can't be in a %s script." % [title, "a player's machine telling the server" if to_server else "the server telling players", side]
		"invoke_server":
			if side == "Server":
				return "Invoke Server is a player's machine asking the server: it can't be in a Server script."
		"player":
			if with_fields and str(fields.get("op", "Me")) == "Me" and side == "Server":
				return "Me is this machine's player, and a Server script serves every player: say which (e.g. Player Joined's player)."
		"ownership":
			if with_fields and str(fields.get("do", "Give to")) == "Give to" and side == "Client":
				return "Give to is the server's to decide: not in a Client script (ask it with Fire Server)."
	return ""


func _err(id: int, msg: String, input := "") -> void:
	if id == 0:
		errors.append({"node": 0, "msg": msg})
		return
	errors.append({"node": id, "msg": "%s (node %d)%s: %s" % [_title(id), id, " > " + input if input != "" else "", msg]})


func _warn(id: int, msg: String) -> void:
	warnings.append({"node": id, "msg": "%s (node %d): %s" % [_title(id), id, msg]})


func _links(id: int, group: String) -> Array:
	var out := []
	for t in nodes[id].get("links", {}).get(group, []):
		if nodes.has(int(t)):
			out.append(int(t))
	return out


func _reachable(entry: int) -> Array:
	var seen := [entry]
	var i := 0
	while i < seen.size():
		for g in layouts[seen[i]].groups:
			for t in _links(seen[i], g):
				if t not in seen:
					seen.append(t)
		i += 1
	return seen


func _out_used(id: int, o: Array) -> bool:
	return T.shown(o, _f(id), 4)


## Variable an output is kept in ("" = not kept).
func _out_var(id: int, name: String) -> String:
	for o in layouts[id].outs:
		if o[0] == name and _out_used(id, o):
			var data = nodes[id].get("outs", {}).get(name, {})
			return str(data.get("var", "") if data is Dictionary else data).strip_edges()
	return ""


func _arg_used(id: int, a: Array) -> bool:
	return T.shown(a, _f(id), 4)


func _arg_spec(id: int, name: String) -> Dictionary:
	var a = nodes[id].get("args", {}).get(name, {})
	return a if a is Dictionary else {"value": str(a)}


func _arg_var(id: int, name: String) -> String:
	return str(_arg_spec(id, name).get("var", "")).strip_edges() if _arg_spec(id, name).has("var") else ""


func _writes(id: int) -> Array:
	var out := []
	var n: Dictionary = nodes[id]
	if n.type == "var" and str(_f(id).get("mode", "Set")) == "Set":
		out.append(str(_f(id).get("name", "")).strip_edges())
	for o in layouts[id].outs:
		out.append(_out_var(id, o[0]))
	return out.filter(func(v): return v != "" and v.is_valid_identifier())


func _reads(id: int) -> Array:
	var out := []
	var n: Dictionary = nodes[id]
	if n.type == "var" and str(_f(id).get("mode", "Set")) != "Set":
		out.append(str(_f(id).get("name", "")).strip_edges())
	for a in layouts[id].args:
		if _arg_used(id, a) and _arg_spec(id, a[0]).has("var"):
			out.append(_arg_var(id, a[0]))
	return out.filter(func(v): return v.is_valid_identifier())


func _infer_types(contexts: Array) -> void:
	for c in constants:
		types[c] = constants[c]
		origins[c] = "Constant"
	for fname in _fields:
		types[fname] = _fields[fname]
		origins[fname] = "Field"
	for ctx in contexts:
		for p in ctx.params:
			if not types.has(p):
				types[p] = ctx.params[p]
				origins[p] = "Self" if p == "self" else "Input"
	for pass_i in 3:
		for ctx in contexts:
			for id in ctx.reach:
				var n: Dictionary = nodes[id]
				for o in layouts[id].outs:
					var v := _out_var(id, o[0])
					if v == "":
						continue
					var t := _out_type(id, o, ctx)
					if t != "" and (not types.has(v) or o[1] == T.ANY) and origins.get(v, "") not in ["Field", "Self", "Input", "Constant"]:
						types[v] = t
					if not origins.has(v):
						origins[v] = "Loop" if n.type in ["for", "repeat", "for_each"] else "Chain"
				if n.type == "var" and str(_f(id).get("mode", "Set")) == "Set":
					var v := str(_f(id).get("name", "")).strip_edges()
					if v != "" and not types.has(v):
						var t: String = _arg(id, "value", ctx)[2]
						types[v] = "int" if t in ["any", ""] else t
						origins[v] = "Chain"


func _out_type(id: int, o: Array, ctx: Dictionary) -> String:
	var f := _f(id)
	# Results whose full type name (a record, a list of...) comes from a setting.
	match nodes[id].type:
		"make_record":
			return str(f.get("of", ""))
		"call_c":
			return str(f.get("returns", "int"))
		"call":
			return str(funcs.get(str(f.get("function", "")), {}).get("returns", "int"))
		"load_texture":
			return "texture"
		"sound":
			return "sound"
		"music":
			return "music" if o[0] == "music" else "bool"
		"begin_mesh":
			return "mesh"
		"snapshot":
			return "texture" if o[0] == "texture" else "bool"
		"raycast":
			return {"hit": "Shape3D", "point": "vector3", "normal": "vector3", "distance": "float"}.get(str(o[0]), "")
		"nearest":
			return (str(f.get("of", "Shape3D")) if CBTypes.is_class_type(str(f.get("of", "Shape3D"))) else "Shape3D") if o[0] == "result" else "float"
		"mouse":
			return "int" if str(f.get("what", "Position")) == "Position" else "float"
		"new_object":
			return str(f.get("of", ""))
		"scene":
			var rc := str(_scenes.get(str(f.get("scene", "")), {}).get("root_class", ""))
			return rc if CBTypes.is_class_type(rc) else CBTypes.OBJECT
		"call_method":
			var cm = CBTypes.all_methods(str(f.get("class", ""))).get(str(f.get("method", "")))
			return str(cm.returns) if cm != null else ""
		"mesh_vertices":
			return "vector3 list"
		"network":
			return "string" if str(f.get("do", "Host")) == "Role" else "bool"
		"invoke_server":
			if o[0] == "answered":
				return "bool"
			var ir = CBTypes.remotes.get(str(f.get("remote", "")))
			return str(ir.answer) if ir != null else ""
		"player_input":
			return "vector2" if str(f.get("what", "Holds")) == "Direction" else "bool"
		"ownership":
			return {"Owner": "int", "Owned by": CBTypes.list_of(CBTypes.OBJECT)}.get(str(f.get("do", "Give to")), "bool")
		"player":
			return {"Me": "int", "Name": "string", "Is me": "bool", "In game": "bool", "Players": "int list"}.get(str(f.get("op", "Me")), "")
		"game_info":
			return "float" if str(f.get("what", "Frame time")) in ["Frame time", "Time"] else "int"
		"pause":
			return "float" if str(f.get("do", "Pause")) == "Time scale" else "bool"
	if o[1] != T.ANY:
		return T.type_name(o[1])
	match nodes[id].type:
		"convert":
			return str(f.get("to", "int"))
		"formula":
			return str(f.get("type", "int"))
		"read":
			return {"int": "int", "float": "float", "line": "string"}.get(str(f.get("as", "int")), "int")
		"args":
			return {"Count": "int", "At index": "string", "Option": "string", "Flag": "bool"}.get(str(f.get("what", "Option")), "string")
		"var":
			var name := str(f.get("name", ""))
			return _var_type(name, ctx) if types.has(name) or ctx.params.has(name) else ""
		"math", "minmax":
			var a := _arg(id, "a", ctx)
			var b := _arg(id, "b", ctx)
			return "float" if (a[1] == T.FLOAT or b[1] == T.FLOAT) else "int"
		"text":
			match str(f.get("op", "Join")):
				"Length", "Find", "To int": return "int"
				"To float": return "float"
				"Starts with", "Ends with": return "bool"
				"Split": return "string list"
			return "string"
		"list":
			var lt: String = _arg(id, "list", ctx)[2]
			match str(f.get("op", "Add")):
				"Make": return CBTypes.list_of(str(f.get("of", "int")))
				"Get": return CBTypes.elem(lt) if CBTypes.is_list(lt) else ""
				"Length", "Find": return "int"
				"Contains": return "bool"
			return ""
		"vector":
			var two := str(f.get("dims", "3D")) == "2D"
			if o[0] in ["x", "y", "z"]:
				return "float"
			return "float" if str(f.get("op", "Make")) in ["Length", "Distance", "Dot"] or (two and str(f.get("op", "")) == "Cross") else ("vector2" if two else "vector3")
		"map":
			var mt: String = _arg(id, "map", ctx)[2]
			var vt := CBTypes.map_value(mt)
			match str(f.get("op", "Set")):
				"Make": return CBTypes.map_of(str(f.get("of", "int")))
				"Get", "Get or": return vt
				"Has": return "bool"
				"Count": return "int"
				"Keys": return "string list"
				"Values": return CBTypes.list_of(vt) if vt != "" else ""
			return ""
		"for_each":
			var lt: String = _arg(id, "list", ctx)[2]
			return CBTypes.elem(lt) if CBTypes.is_list(lt) else ""
		"make_record":
			return str(f.get("of", ""))
		"field":
			return _field_type(id, ctx)
		"group":
			return "bool" if str(f.get("do", "Add")) == "Is in" else CBTypes.list_of(CBTypes.OBJECT)
		"metadata":
			return "bool" if str(f.get("do", "Get")) == "Has" else "string"
		"object":
			match str(f.get("op", "Exists")):
				"Exists", "Is a": return "bool"
				"As": return str(f.get("of", ""))
				"Class name", "Name": return "string"
				"Id": return "int"
				"Parent", "World": return CBTypes.OBJECT
				"Find": return str(f.get("of", "")) if CBTypes.is_class_type(str(f.get("of", ""))) else CBTypes.OBJECT
				"Children": return CBTypes.list_of(CBTypes.OBJECT)
			return ""
		"call_c":
			return str(f.get("returns", "int"))
	return "int"


## The type of the field a Record field brick names (from its record variable's type).
func _field_type(id: int, ctx: Dictionary) -> String:
	var rt: String = _arg(id, "record", ctx)[2]
	if CBTypes.is_class_type(rt):
		for fld in CBTypes.all_fields(rt):
			if fld[0] == str(_f(id).get("field", "")):
				return fld[1]
		return ""
	for fld in records.get(rt, []):
		if fld[0] == str(_f(id).get("field", "")):
			return fld[1]
	return ""


## Reads of names no brick makes: an error with a guess.
func _check_reads(contexts: Array) -> void:
	for ctx in contexts:
		for id in ctx.reach:
			var names := []
			if nodes[id].type == "var" and str(_f(id).get("mode", "Set")) != "Set":
				names.append([str(_f(id).get("name", "")).strip_edges(), "name"])
			for a in layouts[id].args:
				# (a blank object input is the brick's to judge: none, the world, this machine's player...)
				if _arg_used(id, a) and _arg_spec(id, a[0]).has("var") and not ((a[1] == T.OBJECT or a[0] == "player") and _arg_var(id, a[0]) == ""):
					names.append([_arg_var(id, a[0]), a[0]])
			for pair in names:
				var v: String = pair[0]
				if v == "":
					_err(id, "pick a variable.", pair[1])
				elif not (types.has(v) or ctx.params.has(v)):
					_err(id, "no variable named '%s' here%s" % [v, _did_you_mean(v)], pair[1])
				elif not (ctx.params.has(v) or v in ctx.writes or constants.has(v) or _fields.has(v) or _globals.has(v)):
					_err(id, "'%s' is a chain variable of another event or function: to share it, make it Shared where it's made (Variable (Set) or the output: Kind Shared)." % v, pair[1])


func _did_you_mean(v: String) -> String:
	var best := ""
	var best_d := maxi(1, v.length() / 3) + 1
	for k in types:
		var d := edit_distance(v.to_lower(), str(k).to_lower())
		if d < best_d:
			best_d = d
			best = k
	return ": did you mean '%s'?" % best if best != "" else "."


## Edits (insert, delete, replace, swap two neighbours) from `a` to `b`.
static func edit_distance(a: String, b: String) -> int:
	var n := a.length()
	var m := b.length()
	var d := []
	for i in n + 1:
		var row := PackedInt32Array()
		row.resize(m + 1)
		d.append(row)
		d[i][0] = i
	for j in m + 1:
		d[0][j] = j
	for i in range(1, n + 1):
		for j in range(1, m + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			var best: int = mini(mini(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost)
			if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
				best = mini(best, d[i - 2][j - 2] + 1)
			d[i][j] = best
	return d[n][m]


func _var_type(v: String, ctx: Dictionary) -> String:
	if ctx.params.has(v):
		return ctx.params[v]
	return types.get(v, "int")


func _ctype(v: String) -> String:
	return CBTypes.c_type(types.get(v, "int"))


# ------------------------------------------------------------------ statements

func _group(id: int, group: String, d: int, ctx: Dictionary) -> String:
	var s := ""
	for t in _links(id, group):
		s += _node(t, d, ctx)
	return s


func _node(id: int, d: int, ctx: Dictionary) -> String:
	if _stack.has(id):
		_err(id, "its wires loop back. Use While, For range or Repeat to run bricks again.")
		return ""
	_stack[id] = true
	var s := ""
	var note := str(nodes[id].get("note", "")).replace("*/", "* /").replace("\n", " ")
	if note != "":
		s += "    ".repeat(d) + "/* %s */%s\n" % [note, MARK % id]
	if nodes[id].type != "reroute":
		s += "    ".repeat(d) + "CB_TRACE(%d, %d);%s\n" % [file_index, id, MARK % id]
	s += _stmt(id, d, ctx)
	var groups: Array = layouts[id].groups
	if not groups.is_empty():
		s += _group(id, groups[-1], d, ctx)
	_stack.erase(id)
	return s


## Lines for brick `id` at depth `d`, each marked with the brick.
func _lines(id: int, d: int, text: String) -> String:
	var ind := "    ".repeat(d)
	var s := ""
	for line in text.split("\n"):
		s += ind + line + MARK % id + "\n"
	return s


func _stmt(id: int, d: int, ctx: Dictionary) -> String:
	var n: Dictionary = nodes[id]
	var f := _f(id)
	var ind := "    ".repeat(d)
	# Every brick marked "graphics" in NodeDefs is raylib's (the build adds raylib).
	if T.DEFS.get(n.type, {}).get("graphics", false):
		uses_graphics = true
		return _graphics(id, d, ctx)
	match n.type:
		"print":
			var v := _arg(id, "value", ctx)
			var nl := "\\n" if bool(f.get("newline", true)) else ""
			if v[1] in [T.LIST, T.RECORD, T.MAP, T.VEC3, T.VEC2, T.OBJECT]:
				return _lines(id, d, _show(v, "stdout") + ("\nputchar('\\n');" if nl != "" else ""))
			match v[1]:
				T.INT: return _lines(id, d, 'printf("%%d%s", %s);' % [nl, v[0]])
				T.FLOAT: return _lines(id, d, 'printf("%%g%s", %s);' % [nl, v[0]])
				T.BOOL: return _lines(id, d, 'printf("%%s%s", (%s) ? "true" : "false");' % [nl, v[0]])
			return _lines(id, d, 'printf("%%s%s", %s);' % [nl, v[0]])
		"var":
			var name := _ident(id, f.get("name", ""), "name")
			match str(f.get("mode", "Set")):
				"Get":
					return _assign(id, "copy", name, d)
				"Add":
					var t := _var_type(name, ctx)
					if constants.has(name):
						_err(id, "'%s' is a Constant: it can't change." % name)
					if t == "string":
						return _lines(id, d, "%s = cb_join(%s, %s);" % [name, name, _as_text(_arg(id, "value", ctx, "string"))])
					if t == "vector3":
						return _lines(id, d, "%s = cb_v3_add(%s, %s);" % [name, name, _arg(id, "value", ctx, t)[0]])
					if t == "vector2":
						return _lines(id, d, "%s = cb_v2_add(%s, %s);" % [name, name, _arg(id, "value", ctx, t)[0]])
					if CBTypes.is_list(t):
						return _lines(id, d, "*(%s *)cb_list_add(%s) = %s;" % [CBTypes.c_elem(t), name, _arg(id, "value", ctx, CBTypes.elem(t))[0]])
					if t == "bool" or records.has(t) or CBTypes.is_map(t):
						_err(id, "'%s' is a %s: Add works on numbers, text (joins) and lists (appends)." % [name, t])
					return _lines(id, d, "%s += %s;" % [name, _arg(id, "value", ctx, t)[0]])
			if constants.has(name):
				_err(id, "'%s' is a Constant: it can't change." % name)
			return _lines(id, d, "%s = %s;" % [name, _arg(id, "value", ctx, _var_type(name, ctx))[0]])
		"formula":
			var e := str(f.get("expression", "")).strip_edges()
			if e == "":
				_err(id, "type a formula.")
				return ""
			_uses_math = true
			return _assign(id, "result", e, d)
		"if", "while":
			var cond := _condition(id, ctx)
			if n.type == "while":
				return ind + "while (%s) {%s\n" % [cond, MARK % id] + _group(id, "loop", d + 1, ctx) + ind + "}" + MARK % id + "\n"
			var s := ind + "if (%s) {%s\n" % [cond, MARK % id] + _group(id, "true", d + 1, ctx)
			var els := _group(id, "false", d + 1, ctx)
			if els != "":
				s += ind + "} else {" + MARK % id + "\n" + els
			return s + ind + "}" + MARK % id + "\n"
		"for":
			var i := _out_var(id, "index")
			var hidden := i == ""
			if hidden:
				i = "i_%d" % id
			var step: String = _arg(id, "step", ctx)[0]
			var cmp := ">" if step.begins_with("-") else "<"
			var s := ind + "for (%s%s = %s; %s %s %s; %s += %s) {%s\n" % ["int " if hidden else "", i, _arg(id, "from", ctx)[0], i, cmp, _arg(id, "to", ctx)[0], i, step, MARK % id]
			return s + _group(id, "loop", d + 1, ctx) + ind + "}" + MARK % id + "\n"
		"repeat":
			var hid := "r_%d" % id
			var c := _out_var(id, "counter")
			var s := ind + "for (int %s = 0; %s < %s; %s++) {%s\n" % [hid, hid, _arg(id, "times", ctx)[0], hid, MARK % id]
			if c != "":
				s += ind + "    %s = %s;%s\n" % [c, hid, MARK % id]
			return s + _group(id, "loop", d + 1, ctx) + ind + "}" + MARK % id + "\n"
		"break", "continue":
			if not _in_loop(id, ctx):
				_err(id, "only works inside a loop's Loop body.")
			return _lines(id, d, n.type + ";")
		"reroute":
			return ""
		"return":
			if ctx.ret == "void":
				if str(f.get("gives", "A value")) == "A value" and ctx.name != "main" and not ctx.get("exit", false):
					_warn(id, "the function gives back nothing (its Gives back is void): the value is dropped.")
				return _lines(id, d, "return;")
			if str(f.get("gives", "A value")) == "Nothing":
				return _lines(id, d, "return %s;" % _zero(ctx.ret))
			return _lines(id, d, "return %s;" % _arg(id, "value", ctx, ctx.ret)[0])
		"wait":
			if ctx.get("method", false) and str(ctx.name) in ["on_frame", "on_touched", "on_drawn", "on_clicked"]:
				_err(id, "Wait can't be in an object's event (Every frame, When touched, When drawn, When clicked): it would hold up the whole world. Count time in a field instead (a timer: Add dt each frame).")
				return ""
			return _lines(id, d, "cb_wait(%s);" % str(_arg(id, "seconds", ctx, "float")[0]))
		"scene":
			var srel := str(f.get("scene", ""))
			if not _scenes.has(srel):
				_err(id, "pick a scene." if srel == "" else "there's no scene '%s' in the project." % srel, "scene")
				return ""
			var sfn := str(_scenes[srel].fn)
			if str(f.get("do", "Instance")) == "Change":
				return _lines(id, d, "cb_change_scene(%s);  /* %s */" % [sfn, srel])
			if _scenes[srel].roots.size() != 1:
				_err(id, "%s has %d objects at the top: Instance scene needs one (its root). Put them under one node (e.g. a Spatial3D)." % [srel, _scenes[srel].roots.size()], "scene")
				return ""
			var into := "cb_world()"
			var pspec = nodes[id].get("args", {}).get("parent", {})
			if pspec is Dictionary and str(pspec.get("var", "")) != "":
				into = _object_arg(id, "parent", ctx)
				if into == "":
					return ""
			var rc := str(_scenes[srel].root_class)
			var made := "%s(%s)" % [sfn, into]
			if CBTypes.is_class_type(rc):
				made = "(%s)%s" % [CBTypes.c_type(rc), made]
			return _assign(id, "root", made, d, true)
		"group":
			var gname := c_string(str(f.get("group", "")))
			match str(f.get("do", "Add")):
				"Objects in": return _assign(id, "result", "cb_objects_in_group(%s)" % gname, d)
			var go := _object_arg(id, "object", ctx)
			if go == "":
				return ""
			match str(f.get("do", "Add")):
				"Remove": return _lines(id, d, "cb_group_remove(%s, %s, %d, %d);" % [go, gname, file_index, id])
				"Is in": return _assign(id, "result", "cb_in_group(%s, %s, %d, %d)" % [go, gname, file_index, id], d)
			return _lines(id, d, "cb_group_add(%s, %s, %d, %d);" % [go, gname, file_index, id])
		"metadata":
			var mo := _object_arg(id, "object", ctx)
			if mo == "":
				return ""
			var key := _as_text(_arg(id, "key", ctx, "string"))
			match str(f.get("do", "Get")):
				"Set": return _lines(id, d, "cb_meta_set(%s, %s, %s, %d, %d);" % [mo, key, _as_text(_arg(id, "value", ctx, "string")), file_index, id])
				"Has": return _assign(id, "result", "cb_meta_has(%s, %s, %d, %d)" % [mo, key, file_index, id], d)
				"Remove": return _lines(id, d, "cb_meta_remove(%s, %s, %d, %d);" % [mo, key, file_index, id])
			return _assign(id, "result", "cb_meta_get(%s, %s, %d, %d)" % [mo, key, file_index, id], d)
		"new_object":
			var cls := str(f.get("of", ""))
			if not CBTypes.is_class_type(cls):
				_err(id, "pick a class (a script with a Class brick)." if cls == "" else "there's no class named '%s'." % cls, "of")
				return ""
			_check_side(id, str(CBTypes.classes.get(cls, {}).get("side", "Shared")), "the class %s" % cls, "of")
			var made := "(%s *)cb_new(&%s_class)" % [CBTypes.cname(cls), CBTypes.cname(cls)]
			if bool(f.get("world", true)):
				var v := _out_var(id, "object")
				if v != "":
					return _assign(id, "object", made, d, true) + _lines(id, d, "cb_set_parent(%s, cb_world(), %d, %d);" % [v, file_index, id])
				return _lines(id, d, "cb_set_parent(%s, cb_world(), %d, %d);" % [made, file_index, id])
			return _assign(id, "object", made, d, true)
		"destroy":
			var o := _object_arg(id, "object", ctx)
			return _lines(id, d, "cb_destroy(%s, %d, %d);" % [o, file_index, id]) if o != "" else ""
		"call_method":
			return _call_method(id, d, ctx)
		"object":
			return _object_op(id, d, ctx)
		"network":
			return _network(id, d, ctx)
		"player":
			return _player(id, d, ctx)
		"fire_server", "fire_clients":
			return _fire(id, d, ctx)
		"invoke_server":
			return _invoke(id, d, ctx)
		"answer":
			return _answer(id, d, ctx)
		"ownership":
			return _ownership(id, d, ctx)
		"call":
			var fname := str(f.get("function", ""))
			if not funcs.has(fname):
				_err(id, "pick a function to call." if fname == "" else "there's no function named '%s'." % fname, "function")
				return ""
			_check_side(id, str(funcs[fname].get("side", "Shared")), "the function '%s'" % fname, "function")
			var args := []
			for p in funcs[fname].params:
				args.append(_arg(id, p[1], ctx, p[0])[0])
			return _assign(id, "result", "%s(%s)" % [fname, ", ".join(args)], d, true)
		"read":
			var as_type := str(f.get("as", "int"))
			var v := _out_var(id, "value")
			var s := ""
			var prompt := str(f.get("prompt", ""))
			if prompt != "":
				s += 'printf("%%s", %s);\n' % c_string(prompt)
			if as_type == "line":
				_uses_string = true
				var buf := "line_%d" % id
				_statics.append("static char %s[1024];" % buf)
				s += 'if (fgets(%s, sizeof %s, stdin)) { %s[strcspn(%s, "\\n")] = 0; } else { %s[0] = 0; }' % [buf, buf, buf, buf, buf]
				if v != "":
					s += "\n%s = %s;" % [v, buf]
				return _lines(id, d, s)
			var fmt := "%d" if as_type == "int" else "%lf"
			var target := v if v != "" else "tmp_%d" % id
			if v == "":
				s += "%s tmp_%d = 0;\n" % ["int" if as_type == "int" else "double", id]
			elif types.get(v, "") != as_type:
				_err(id, "'%s' holds a %s, not a%s." % [v, types.get(v, "?"), "n int" if as_type == "int" else " float"], "value")
			s += 'if (scanf("%s", &%s) != 1) { %s = 0; }\n' % [fmt, target, target]
			s += "{ int c_; while ((c_ = getchar()) != '\\n' && c_ != EOF) { } }"
			return _lines(id, d, s)
		"time":
			_uses_time = true
			return _assign(id, "seconds", "(int)time(NULL)", d)
		"convert":
			var to := str(f.get("to", "int"))
			return _assign(id, "result", "(%s)(%s)" % [T.C_TYPES[to], _arg(id, "value", ctx)[0]], d)
		"math":
			var a := _arg(id, "a", ctx)
			var b := _arg(id, "b", ctx)
			var op: String = {"Add": "+", "Subtract": "-", "Multiply": "*", "Divide": "/", "Remainder": "%"}.get(str(f.get("op", "Add")), "+")
			if op == "%" and (a[1] == T.FLOAT or b[1] == T.FLOAT):
				_uses_math = true
				return _assign(id, "result", "fmod(%s, %s)" % [a[0], b[0]], d)
			if op == "/" and b[0].strip_edges() == "0":
				_err(id, "dividing by 0.", "b")
			return _assign(id, "result", "%s %s %s" % [a[0], op, b[0]], d)
		"math_func":
			_uses_math = true
			var fn := str(f.get("func", "sqrt"))
			if fn == "pow":
				return _assign(id, "result", "pow(%s, %s)" % [_arg(id, "x", ctx)[0], _arg(id, "exp", ctx)[0]], d)
			return _assign(id, "result", "%s(%s)" % [fn, _arg(id, "x", ctx)[0]], d)
		"minmax":
			var a: String = _arg(id, "a", ctx)[0]
			var b: String = _arg(id, "b", ctx)[0]
			var cmp := "<" if f.get("op", "min") == "min" else ">"
			return _assign(id, "result", "(%s %s %s) ? %s : %s" % [a, cmp, b, a, b], d)
		"random":
			_uses_rand = true
			var lo: String = _arg(id, "min", ctx)[0]
			var hi: String = _arg(id, "max", ctx)[0]
			return _assign(id, "result", "%s + rand() %% (%s - %s + 1)" % [lo, hi, lo], d)
		"compare":
			return _assign(id, "result", _compare(id, str(f.get("op", "==")), ctx), d)
		"logic":
			match str(f.get("op", "And")):
				"Not":
					return _assign(id, "result", "!(%s)" % _arg(id, "a", ctx)[0], d)
				"Or":
					return _assign(id, "result", "%s || %s" % [_arg(id, "a", ctx)[0], _arg(id, "b", ctx)[0]], d)
			return _assign(id, "result", "%s && %s" % [_arg(id, "a", ctx)[0], _arg(id, "b", ctx)[0]], d)
		"raw_c":
			return _lines(id, d, str(f.get("code", "")))
		"text":
			return _text(id, d, ctx)
		"list":
			return _list(id, d, ctx)
		"map":
			return _map(id, d, ctx)
		"vector":
			return _vector(id, d, ctx)
		"for_each":
			var l := _arg(id, "list", ctx)
			if not CBTypes.is_list(l[2]):
				_err(id, "pick a list variable.", "list")
				return ""
			var item := _out_var(id, "item")
			var index := _out_var(id, "index")
			var k := "fe_%d" % id
			var s := ind + "for (int %s = 0; %s < %s->count; %s++) {%s\n" % [k, k, l[0], k, MARK % id]
			if item != "":
				s += ind + "    %s = ((%s *)%s->data)[%s];%s\n" % [item, CBTypes.c_elem(l[2]), l[0], k, MARK % id]
			if index != "":
				s += ind + "    %s = %s;%s\n" % [index, k, MARK % id]
			return s + _group(id, "loop", d + 1, ctx) + ind + "}" + MARK % id + "\n"
		"make_record":
			var rt := str(f.get("of", ""))
			if not records.has(rt):
				_err(id, "pick a record type (made with Define Record)." if rt == "" else "there's no record named '%s'." % rt, "of")
				return ""
			return _assign(id, "result", "cb_make_%s()" % rt, d)
		"field":
			var r := _arg(id, "record", ctx)
			var fname := str(f.get("field", ""))
			if CBTypes.is_class_type(r[2]):
				var ft := _field_type(id, ctx)
				if ft == "":
					_err(id, "pick a field of %s." % r[2] if fname == "" else "%s has no field '%s'." % [r[2], fname], "field")
					return ""
				var owner := ""
				for fld in CBTypes.all_fields(r[2]):
					if fld[0] == fname:
						owner = fld[2]
				var at := "((%s *)cb_obj(%s, %d, %d))->f_%s" % [CBTypes.cname(owner), r[0], file_index, id, fname]
				if str(f.get("mode", "Get")) == "Set":
					return _lines(id, d, "%s = %s;" % [at, _arg(id, "value", ctx, ft)[0]])
				return _assign(id, "value", at, d)
			if not records.has(r[2]):
				_err(id, "pick a record or object variable.", "record")
				return ""
			if _field_type(id, ctx) == "":
				_err(id, "pick a field of %s." % r[2] if fname == "" else "%s has no field '%s'." % [r[2], fname], "field")
				return ""
			if str(f.get("mode", "Get")) == "Set":
				return _lines(id, d, "%s.%s = %s;" % [r[0], fname, _arg(id, "value", ctx, _field_type(id, ctx))[0]])
			return _assign(id, "value", "%s.%s" % [r[0], fname], d)
		"switch":
			var v := _arg(id, "value", ctx)
			var cases: Array = f.get("cases", [])
			var s := ""
			for i in cases.size():
				var c := str(cases[i])
				var cond := "strcmp(%s, %s) == 0" % [v[0], c_string(c)] if v[1] == T.STRING else "%s == %s" % [v[0], c if c.strip_edges() != "" else "0"]
				s += ind + "%sif (%s) {%s\n" % ["} else " if i > 0 else "", cond, MARK % id]
				s += _group(id, "case_%d" % i, d + 1, ctx)
			var dflt := _group(id, "default", d + 1, ctx)
			if cases.is_empty():
				return dflt.replace("\n" + "    ".repeat(d + 1), "\n" + ind) if dflt != "" else ""
			if dflt != "":
				s += ind + "} else {" + MARK % id + "\n" + dflt
			return s + ind + "}" + MARK % id + "\n"
		"sleep":
			return _lines(id, d, "cb_sleep_ms(%s);" % _arg(id, "ms", ctx)[0])
		"env":
			return _assign(id, "value", "cb_env(%s)" % _arg(id, "name", ctx)[0], d)
		"run_command":
			return _assign(id, "code", "cb_run(%s)" % _arg(id, "command", ctx)[0], d, true)
		"terminal":
			match str(f.get("mode", "Color")):
				"Clear screen": return _lines(id, d, 'fputs("\\033[2J\\033[H", stdout);')
				"Reset": return _lines(id, d, 'fputs("\\033[0m", stdout);')
				"Hide cursor": return _lines(id, d, 'fputs("\\033[?25l", stdout);')
				"Show cursor": return _lines(id, d, 'fputs("\\033[?25h", stdout);')
				"Move cursor": return _lines(id, d, 'printf("\\033[%%d;%%dH", %s, %s);' % [_arg(id, "row", ctx)[0], _arg(id, "column", ctx)[0]])
			var names := ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
			var cname := str(f.get("color", "green"))
			var bright := cname.begins_with("bright ")
			var code := (90 if bright else 30) + maxi(0, names.find(cname.trim_prefix("bright "))) + (10 if bool(f.get("background", false)) else 0)
			return _lines(id, d, 'fputs("\\033[%dm", stdout);' % code)
		"call_c":
			return _call_c(id, d, ctx)
		"args":
			match str(f.get("what", "Option")):
				"Count": return _assign(id, "result", "cb_arg_count()", d)
				"At index": return _assign(id, "result", "cb_arg(%s)" % _arg(id, "index", ctx)[0], d)
				"Flag": return _assign(id, "result", "cb_flag(%s)" % _arg(id, "name", ctx)[0], d)
			return _assign(id, "result", "cb_option(%s)" % _arg(id, "name", ctx)[0], d)
		"quit":
			return _lines(id, d, "exit(%s);" % _arg(id, "code", ctx)[0])
		"read_file":
			return _assign(id, "text", "cb_read_file(%s)" % _arg(id, "path", ctx)[0], d)
		"write_file":
			var call := "cb_write_file(%s, %s, %s)" % [_arg(id, "path", ctx)[0], _arg(id, "text", ctx)[0], "true" if f.get("mode", "Write") == "Append" else "false"]
			return _assign(id, "ok", call, d, true)
		"file_exists":
			return _assign(id, "result", "cb_file_exists(%s)" % _arg(id, "path", ctx)[0], d)
		"assert":
			return _lines(id, d, "cb_assert(%s, %d, %d, %s);" % [_condition(id, ctx), file_index, id, _arg(id, "message", ctx)[0]])
		"debug_log":
			var v := _arg(id, "value", ctx)
			var fmt: String = {T.INT: "%d", T.FLOAT: "%g", T.BOOL: "%s"}.get(v[1], "%s")
			var val: String = "(%s) ? \"true\" : \"false\"" % v[0] if v[1] == T.BOOL else v[0]
			return _lines(id, d, 'if (cb_verbose) { fprintf(stderr, "[debug] %s\\n", %s); }' % [fmt, val])
	return ""


func _in_loop(id: int, ctx: Dictionary) -> bool:
	# Inside a loop if some loop's body leads to it.
	for other in ctx.reach:
		if nodes[other].type in ["while", "for", "repeat"]:
			var todo: Array = _links(other, "loop")
			var seen := {}
			while not todo.is_empty():
				var x: int = todo.pop_back()
				if x == id:
					return true
				if seen.has(x):
					continue
				seen[x] = true
				for g in layouts[x].groups:
					todo.append_array(_links(x, g))
	return false


## If / While's comparison of A (and B).
func _condition(id: int, ctx: Dictionary) -> String:
	var op := str(_f(id).get("operator", "is true"))
	if op == "is true":
		return _bare(_arg(id, "a", ctx, "bool")[0])
	if op == "is false":
		return "!(%s)" % _arg(id, "a", ctx, "bool")[0]
	return _compare(id, op, ctx)


func _compare(id: int, op: String, ctx: Dictionary) -> String:
	var a := _arg(id, "a", ctx)
	var b := _arg(id, "b", ctx)
	if a[1] == T.STRING or b[1] == T.STRING:
		if a[1] != b[1] and a[1] != T.ANY and b[1] != T.ANY:
			_err(id, "a string can only be compared with a string.")
		_uses_string = true
		return "strcmp(%s, %s) %s 0" % [a[0], b[0], op]
	return "%s %s %s" % [a[0], op, b[0]]


## `variable = expr;` for output `out`; a bare statement or nothing when it isn't kept.
func _assign(id: int, out: String, expr: String, d: int, keep_side_effects := false) -> String:
	var v := _out_var(id, out)
	if constants.has(v):
		_err(id, "'%s' is a Constant: it can't change." % v, out)
		return ""
	if v == "":
		return _lines(id, d, expr + ";") if keep_side_effects else ""
	if not v.is_valid_identifier():
		_err(id, "'%s' is not a valid variable name." % v, out)
		return ""
	return _lines(id, d, "%s = %s;" % [v, expr])


## A value as text (for Join, To text, Format of one): numbers and bools formatted.
func _as_text(v: Array) -> String:
	match v[1]:
		T.INT: return "cb_format(\"%%d\", %s)" % v[0]
		T.FLOAT: return "cb_format(\"%%g\", %s)" % v[0]
		T.BOOL: return "((%s) ? \"true\" : \"false\")" % v[0]
		T.VEC3: return "cb_v3_text(%s)" % v[0]
		T.VEC2: return "cb_v2_text(%s)" % v[0]
	return v[0]


## Printing a list or a record ([1, 2, 3], Point(x: 1, y: 2)).
func _show(v: Array, stream: String) -> String:
	if v[1] == T.LIST:
		return "cb_show_list(%s, %s, %s);" % [stream, v[0], CBTypes.show_fn(CBTypes.elem(v[2]))]
	if v[1] == T.MAP:
		return "cb_show_map(%s, %s, %s);" % [stream, v[0], CBTypes.show_fn(CBTypes.map_value(v[2]))]
	return "%s(%s, &%s);" % [CBTypes.show_fn(v[2]), stream, v[0]]


func _text(id: int, d: int, ctx: Dictionary) -> String:
	var f := _f(id)
	var t := func() -> String: return _as_text(_arg(id, "text", ctx, "string"))
	var arg := func(n: String) -> String: return _arg(id, n, ctx, "string")[0]
	match str(f.get("op", "Join")):
		"Join": return _assign(id, "result", "cb_join(%s, %s)" % [t.call(), _as_text(_arg(id, "more", ctx, "string"))], d)
		"Length": return _assign(id, "result", "cb_len(%s)" % t.call(), d)
		"Substring": return _assign(id, "result", "cb_substr(%s, %s, %s)" % [t.call(), _arg(id, "start", ctx)[0], _arg(id, "length", ctx)[0]], d)
		"Find": return _assign(id, "result", "cb_find(%s, %s)" % [t.call(), arg.call("what")], d)
		"Replace": return _assign(id, "result", "cb_replace(%s, %s, %s)" % [t.call(), arg.call("what"), arg.call("with")], d)
		"Upper case": return _assign(id, "result", "cb_upper(%s)" % t.call(), d)
		"Lower case": return _assign(id, "result", "cb_lower(%s)" % t.call(), d)
		"Trim": return _assign(id, "result", "cb_trim(%s)" % t.call(), d)
		"Split": return _assign(id, "result", "cb_split(%s, %s)" % [t.call(), arg.call("separator")], d)
		"Join list":
			var l := _arg(id, "list", ctx)
			if l[2] != "string list":
				_err(id, "Join list needs a string list.", "list")
			return _assign(id, "result", "cb_join_list(%s, %s)" % [l[0], arg.call("separator")], d)
		"To text": return _assign(id, "result", _as_text(_arg(id, "value", ctx)), d)
		"To int": return _assign(id, "result", "cb_to_int(%s)" % t.call(), d)
		"To float": return _assign(id, "result", "cb_to_float(%s)" % t.call(), d)
		"Starts with": return _assign(id, "result", "cb_starts_with(%s, %s)" % [t.call(), arg.call("what")], d)
		"Ends with": return _assign(id, "result", "cb_ends_with(%s, %s)" % [t.call(), arg.call("what")], d)
	# Format: each {} takes the next value, printed by its type.
	var fmt := str(f.get("format", "")).replace("%", "%%")
	var values := []
	var parts := fmt.split("{}")
	var out := parts[0]
	var names := ["first", "second", "third", "fourth"]
	for i in range(1, parts.size()):
		if i > names.size():
			_err(id, "a Format takes at most 4 values ({} {} {} {}).", "format")
			break
		var v := _arg(id, names[i - 1], ctx)
		match v[1]:
			T.INT: out += "%d"
			T.FLOAT: out += "%g"
			T.BOOL:
				out += "%s"
				v = ["(%s) ? \"true\" : \"false\"" % v[0], T.STRING, "string"]
			T.STRING: out += "%s"
			T.VEC3:
				out += "%s"
				v = ["cb_v3_text(%s)" % v[0], T.STRING, "string"]
			T.VEC2:
				out += "%s"
				v = ["cb_v2_text(%s)" % v[0], T.STRING, "string"]
			_:
				_err(id, "a list, map or record can't go in a Format: print it, or format its parts.", names[i - 1])
				out += "%s"
		values.append(v[0])
		out += parts[i]
	return _assign(id, "result", "cb_format(%s%s)" % [c_string(out), "".join(values.map(func(x): return ", " + x))], d)


func _list(id: int, d: int, ctx: Dictionary) -> String:
	var f := _f(id)
	var op := str(f.get("op", "Add"))
	if op == "Make":
		var of := str(f.get("of", "int"))
		if not CBTypes.valid(of, records) or CBTypes.is_list(of):
			_err(id, "a list can hold int, float, bool, string or a record.", "of")
			return ""
		return _assign(id, "result", "cb_list_new(sizeof(%s))" % CBTypes.c_type(of), d)
	var l := _arg(id, "list", ctx)
	if not CBTypes.is_list(l[2]):
		_err(id, "pick a list variable.", "list")
		return ""
	var e := CBTypes.elem(l[2])
	var ce := CBTypes.c_type(e)
	var at := func(fn: String) -> String: return "%s(%s, %s, %d, %d)" % [fn, l[0], _arg(id, "index", ctx)[0], file_index, id]
	var value := func() -> String: return _arg(id, "value", ctx, e)[0]
	match op:
		"Add": return _lines(id, d, "*(%s *)cb_list_add(%s) = %s;" % [ce, l[0], value.call()])
		"Insert": return _lines(id, d, "*(%s *)%s = %s;" % [ce, at.call("cb_list_insert"), value.call()])
		"Get": return _assign(id, "result", "*(%s *)%s" % [ce, at.call("cb_list_at")], d)
		"Set": return _lines(id, d, "*(%s *)%s = %s;" % [ce, at.call("cb_list_at"), value.call()])
		"Remove": return _lines(id, d, "cb_list_remove(%s, %s, %d, %d);" % [l[0], _arg(id, "index", ctx)[0], file_index, id])
		"Length": return _assign(id, "result", "%s->count" % l[0], d)
		"Clear": return _lines(id, d, "cb_list_clear(%s);" % l[0])
		"Reverse": return _lines(id, d, "cb_list_reverse(%s);" % l[0])
		"Sort":
			if not CBTypes.is_basic(e):
				_err(id, "only lists of numbers, bools or text can be sorted.", "list")
				return ""
			return _lines(id, d, "qsort(%s->data, (size_t)%s->count, %s->elem, cb_cmp_%s);" % [l[0], l[0], l[0], e])
		"Find", "Contains":
			if not CBTypes.is_basic(e):
				_err(id, "Find / Contains work on lists of numbers, bools or text.", "list")
				return ""
			var v := _out_var(id, "result")
			var k := "k_%d" % id
			var item := "((%s *)%s->data)[%s]" % [ce, l[0], k]
			var eq := "strcmp(%s, %s) == 0" % [item, value.call()] if e == "string" else "%s == (%s)" % [item, value.call()]
			if v == "":
				return ""
			var found := "%s = %s; break;" % [v, k] if op == "Find" else "%s = true; break;" % v
			return _lines(id, d, "%s = %s;\nfor (int %s = 0; %s < %s->count; %s++) {\n    if (%s) { %s }\n}" % [v, "-1" if op == "Find" else "false", k, k, l[0], k, eq, found])
	return ""


## Bricks that draw, read the keyboard / mouse or load media: a dedicated server
## (--server: no window) skips them (their outputs keep their values).
const WINDOW_ONLY := ["look", "clear", "draw", "input", "mouse", "mouse_mode", "key_direction", "load_texture", "camera3d", "draw3d", "shape3d", "snapshot", "finish_mesh", "mesh_vertices", "sound", "music", "view2d"]


## Graphics bricks (they call cbricks_gfx.c, which calls the target's backend). Colors are names or #rrggbb, read by cb_color() (cbricks_gfx.c).
func _graphics(id: int, d: int, ctx: Dictionary) -> String:
	if nodes[id].type not in WINDOW_ONLY:
		return _graphics_brick(id, d, ctx)
	var inner := _graphics_brick(id, d + 1, ctx)
	if inner == "":
		return ""
	var ind := "    ".repeat(d)
	return ind + "if (!cb_headless) {  /* (a dedicated server has no window) */%s\n" % (MARK % id) + inner + ind + "}%s\n" % (MARK % id)


func _graphics_brick(id: int, d: int, ctx: Dictionary) -> String:
	var f := _f(id)
	var ind := "    ".repeat(d)
	var a := func(n: String) -> String: return _arg(id, n, ctx)[0]
	var color := func() -> String: return "cb_color(%s)" % a.call("color")
	match nodes[id].type:
		"window":
			return _lines(id, d, "cb_wait_hook = cb_wait_world;  /* Wait keeps the window and the world running */\ncb_window_opened();  /* (a Close window before it is forgotten) */\nif (cb_headless) {  /* a dedicated server: no window, the world at this rate */\n    cb_headless_fps(%s);\n} else {\n    if (!cb_open_window(%s, %s, %s, %s, %s)) { fprintf(stderr, \"Open window: couldn't open a window (no display, or its OpenGL is too old).\\n\"); exit(1); }\n    if (!cb_key_hook) cb_key_hook = cb_window_key;  /* (players' keys, in a network game; --press: a test's) */\n}" % [a.call("fps"), a.call("width"), a.call("height"), a.call("title"), a.call("fps"), "true" if bool(f.get("esc_closes", true)) else "false"])
		"game_loop":
			var s := ind + "while (cb_loop_go()) {  /* until the window is closed (or Close window) */%s\n" % (MARK % id)
			s += ind + "    cb_frame_begin();  /* the frame, and the world: Every frame, moves, touches, drawing */%s\n" % (MARK % id)
			s += _group(id, "frame", d + 1, ctx)
			s += ind + "    cb_frame_end();%s\n" % (MARK % id)
			s += ind + "}%s\n" % (MARK % id)
			return s + _lines(id, d, "if (!cb_headless) cb_window_end();")
		"look":
			match str(f.get("what", "Shading")):
				"Splatting": return _lines(id, d, "cb_graphics_setting(1, %d);" % maxi(CBProject.SPLATS.find(str(f.get("splat", "off"))), 0))
				"Pixel size": return _lines(id, d, "cb_graphics_setting(2, (int)(%s));" % a.call("pixel"))
			return _lines(id, d, "cb_graphics_setting(0, %d);" % maxi(CBProject.SHADINGS.find(str(f.get("shading", "lit"))), 0))
		"close_window":
			return _lines(id, d, "cb_close_window();  /* the Game loop ends after this frame */")
		"pause":
			match str(f.get("do", "Pause")):
				"Resume": return _lines(id, d, "cb_pause(false);")
				"Is paused": return _assign(id, "result", "cb_is_paused()", d)
				"Set time scale": return _lines(id, d, "cb_set_time_scale(%s);" % a.call("scale"))
				"Time scale": return _assign(id, "result", "cb_get_time_scale()", d)
			return _lines(id, d, "cb_pause(true);  /* (offline: the world stops; in a network game it only says so) */")
		"view2d":
			return _lines(id, d, "cb_begin_2d(%s, %s, %s);" % [_v2(id, "center", ctx), a.call("zoom"), a.call("rotation")]) + _group(id, "draw", d, ctx) + _lines(id, d, "cb_end_2d();")
		"music":
			var mdo := str(f.get("do", "Play"))
			if mdo == "Load":
				return _assign(id, "music", "cb_music_load(%s, %s)" % [a.call("path"), "true" if bool(f.get("loop", true)) else "false"], d)
			var mu := _arg(id, "music", ctx)
			if mu[2] != "music":
				_err(id, "pick a music variable (made by Music: Load).", "music")
				return ""
			match mdo:
				"Stop": return _lines(id, d, "cb_music_stop(%s);" % mu[0])
				"Pause": return _lines(id, d, "cb_music_pause(%s);" % mu[0])
				"Resume": return _lines(id, d, "cb_music_resume(%s);" % mu[0])
				"Volume": return _lines(id, d, "cb_music_volume(%s, (double)(%s));" % [mu[0], a.call("volume")])
				"Playing": return _assign(id, "result", "cb_music_playing(%s)" % mu[0], d)
			return _lines(id, d, "cb_music_play(%s);" % mu[0])
		"clear":
			return _lines(id, d, "cb_clear(%s);" % color.call())
		"draw":
			var shape := str(f.get("shape", "Rectangle"))
			var rot: String = a.call("rotation") if shape in ["Rectangle", "Text", "Texture", "Sprite"] else "0"
			var turned := not (rot.is_valid_float() and rot.to_float() == 0.0)
			match shape:
				"Rectangle" when turned:
					return _lines(id, d, "cb_draw_rect_turned(%s, %s, %s, %s, %s, %s);" % [a.call("x"), a.call("y"), a.call("width"), a.call("height"), rot, color.call()])
				"Text" when turned:
					return _lines(id, d, "cb_draw_text_turned(%s, %s, %s, %s, %s, %s);" % [_as_text(_arg(id, "text", ctx, "string")), a.call("x"), a.call("y"), a.call("size"), rot, color.call()])
				"Texture", "Sprite":
					var tx := _arg(id, "texture", ctx)
					if tx[2] != "texture":
						_err(id, "pick a texture variable (made by Load texture).", "texture")
						return ""
					if shape == "Sprite":
						return _lines(id, d, "cb_draw_sprite(%s, %s, %s, %s, %s, %s, %s, %s, %s);" % [tx[0], a.call("x"), a.call("y"), a.call("frame"), a.call("columns"), a.call("rows"), a.call("scale"), rot, color.call()])
					if turned:
						return _lines(id, d, "cb_draw_sprite(%s, %s, %s, 0, 1, 1, 1, %s, %s);" % [tx[0], a.call("x"), a.call("y"), rot, color.call()])
			match shape:
				"Outline": return _lines(id, d, "cb_draw_rect_lines(%s, %s, %s, %s, %s);" % [a.call("x"), a.call("y"), a.call("width"), a.call("height"), color.call()])
				"Circle": return _lines(id, d, "cb_draw_circle(%s, %s, (double)(%s), %s);" % [a.call("x"), a.call("y"), a.call("radius"), color.call()])
				"Line": return _lines(id, d, "cb_draw_line(%s, %s, %s, %s, %s);" % [a.call("x"), a.call("y"), a.call("x2"), a.call("y2"), color.call()])
				"Text": return _lines(id, d, "cb_draw_text(%s, %s, %s, %s, %s);" % [_as_text(_arg(id, "text", ctx, "string")), a.call("x"), a.call("y"), a.call("size"), color.call()])
				"Texture":
					var t := _arg(id, "texture", ctx)
					if t[2] != "texture":
						_err(id, "pick a texture variable (made by Load texture).", "texture")
						return ""
					return _lines(id, d, "cb_draw_texture(%s, %s, %s, %s);" % [t[0], a.call("x"), a.call("y"), color.call()])
			return _lines(id, d, "cb_draw_rect(%s, %s, %s, %s, %s);" % [a.call("x"), a.call("y"), a.call("width"), a.call("height"), color.call()])
		"input":
			var key := "CB_KEY_" + str(f.get("key", "SPACE"))
			var button := "CB_MOUSE_" + str(f.get("button", "LEFT"))
			match str(f.get("when", "Key down")):
				"Key pressed": return _assign(id, "result", "cb_key_pressed(%s)" % key, d)
				"Key released": return _assign(id, "result", "cb_key_released(%s)" % key, d)
				"Mouse down": return _assign(id, "result", "cb_mouse_down(%s)" % button, d)
				"Mouse pressed": return _assign(id, "result", "cb_mouse_pressed(%s)" % button, d)
				"Mouse over UI": return _assign(id, "result", "cb_mouse_over_ui()", d)
			return _assign(id, "result", "cb_key_down(%s)" % key, d)
		"mouse":
			match str(f.get("what", "Position")):
				"Movement":
					return _assign(id, "x", "(double)cb_mouse_motion().x", d) + _assign(id, "y", "(double)cb_mouse_motion().y", d)
				"Wheel":
					return _assign(id, "x", "cb_mouse_wheel()", d)
			return _assign(id, "x", "cb_mouse_x()", d) + _assign(id, "y", "cb_mouse_y()", d)
		"mouse_mode":
			return _lines(id, d, {"Visible": "cb_cursor(0);", "Captured": "cb_capture_mouse();", "Hidden": "cb_cursor(1);"}.get(str(f.get("mode", "Captured")), "cb_capture_mouse();"))
		"raycast":
			var ign := "NULL"
			if _arg_var(id, "ignore") != "":
				var ig := _arg(id, "ignore", ctx)
				if not CBTypes.is_class_type(ig[2]):
					_err(id, "pick an object variable, or leave it blank.", "ignore")
					return ""
				ign = ig[0]
			# Hit / Nothing hit like an If's True / False, then Next (each exit grows).
			var k := "rc_%d" % id
			var outs := {"hit": "(cls_Shape3D *)%s_hit" % k, "point": "%s_point" % k, "normal": "%s_normal" % k, "distance": "%s_dist" % k}
			var s := ind + "{%s\n" % (MARK % id)
			s += ind + "    Vector3 %s_point, %s_normal;%s\n" % [k, k, MARK % id]
			s += ind + "    double %s_dist;%s\n" % [k, MARK % id]
			s += ind + "    void *%s_hit = cb_raycast(%s, %s, %s, &%s_point, &%s_normal, &%s_dist);%s\n" % [k, _v3(id, "from", ctx), _v3(id, "to", ctx), ign, k, k, k, MARK % id]
			for o in outs:
				var v := _out_var(id, o)
				s += ind + ("    %s = %s;%s\n" % [v, outs[o], MARK % id] if v != "" else "    (void)%s;%s\n" % [outs[o].trim_prefix("(cls_Shape3D *)"), MARK % id])
			var on_hit := _group(id, "hit", d + 2, ctx)
			var on_miss := _group(id, "missed", d + 2, ctx)
			if on_hit != "" or on_miss != "":
				s += ind + "    if (%s_hit) {%s\n" % [k, MARK % id] + on_hit
				s += ind + "    } else {%s\n" % (MARK % id) + on_miss
				s += ind + "    }%s\n" % (MARK % id)
			return s + ind + "}" + MARK % id + "\n"
		"key_direction":
			var key := func(n: String, dflt: String) -> String: return "cb_key_down(CB_KEY_%s)" % str(f.get(n, dflt))
			return _assign(id, "result", "cb_key_direction(%s, %s, %s, %s)" % [key.call("left", "A"), key.call("right", "D"), key.call("forward", "W"), key.call("back", "S")], d)
		"can_see":
			var who := _object_arg(id, "who", ctx)
			var tgt := _object_arg(id, "target", ctx)
			if who == "" or tgt == "":
				return ""
			var s := ind + "if (cb_can_see(%s, %s, %s, %s, %d, %d)) {%s\n" % [who, tgt, a.call("range"), a.call("view"), file_index, id, MARK % id]
			s += _group(id, "seen", d + 1, ctx)
			s += ind + "} else {%s\n" % (MARK % id) + _group(id, "unseen", d + 1, ctx)
			return s + ind + "}" + MARK % id + "\n"
		"nearest":
			var of := str(f.get("of", "Shape3D"))
			if not CBTypes.is_class_type(of):
				_err(id, "pick a class.", "of")
				return ""
			var ex := "NULL"
			if _arg_var(id, "except") != "":
				ex = _object_arg(id, "except", ctx)
				if ex == "":
					return ""
			var k := "nr_%d" % id
			var s := ind + "{%s\n" % (MARK % id)
			s += ind + "    double %s_dist;%s\n" % [k, MARK % id]
			s += ind + "    void *%s = cb_nearest(&%s_class, %s, %s, %s, &%s_dist);%s\n" % [k, CBTypes.cname(of), _v3(id, "from", ctx), a.call("range"), ex, k, MARK % id]
			var rv := _out_var(id, "result")
			var dv := _out_var(id, "distance")
			s += ind + ("    %s = (%s *)%s;%s\n" % [rv, CBTypes.cname(of), k, MARK % id] if rv != "" else "    (void)%s;%s\n" % [k, MARK % id])
			s += ind + ("    %s = %s_dist;%s\n" % [dv, k, MARK % id] if dv != "" else "    (void)%s_dist;%s\n" % [k, MARK % id])
			return s + ind + "}" + MARK % id + "\n"
		"shake_camera":
			return _lines(id, d, "cb_shake(%s, %s);" % [a.call("strength"), a.call("duration")])
		"move_collide":
			var pa := _arg(id, "part", ctx)
			if not CBTypes.is_class_type(pa[2]) or not CBTypes.is_subclass(pa[2], "Shape3D"):
				_err(id, "pick a Shape3D variable (Self, in a class that extends Shape3D).", "part")
				return ""
			return _assign(id, "blocked", "cb_move_collide(%s, %s, %d, %d)" % [pa[0], _v3(id, "motion", ctx), file_index, id], d, true)
		"game_info":
			match str(f.get("what", "Frame time")):
				"Time": return _assign(id, "result", "cb_game_time()", d)
				"Width": return _assign(id, "result", "cb_screen_width()", d)
				"Height": return _assign(id, "result", "cb_screen_height()", d)
				"FPS": return _assign(id, "result", "cb_fps()", d)
			return _assign(id, "result", "cb_frame_time()", d)
		"load_texture":
			return _assign(id, "texture", "cb_load_texture(%s)" % a.call("path"), d)
		"player_input":
			uses_net = true
			if misplaced("player_input", {}, _class, _side) != "":
				return ""  # (a problem already: misplaced)
			var who := _player_arg(id, ctx)
			if who == "":
				return ""
			if who.begins_with("cb_net_player_here("):
				who = "cb_net_player_soft(%s)" % who.trim_prefix("cb_net_player_here(").split(",")[0]  # (no player: no keys)
			var held := func(k: String, dflt: String) -> String: return "cb_net_key_held(%s, %d, %d, %d)" % [who, CBTypes.net_keys.find(str(f.get(k, dflt))), file_index, id]
			if str(f.get("what", "Holds")) == "Direction":
				return _assign(id, "result", "cb_key_direction(%s, %s, %s, %s)" % [held.call("left", "A"), held.call("right", "D"), held.call("forward", "W"), held.call("back", "S")], d)
			return _assign(id, "result", held.call("key", "SPACE"), d)
		"camera3d":
			return _lines(id, d, "cb_camera(%s, %s, %s, %s);" % [_v3(id, "position", ctx), _v3(id, "target", ctx), a.call("fov"), "true" if str(f.get("projection", "Perspective")) == "Orthographic" else "false"])
		"draw3d":
			return _lines(id, d, "cb_begin_3d();") + _group(id, "draw", d, ctx) + _lines(id, d, "cb_end_3d();")
		"shape3d":
			var shape := str(f.get("shape", "Box"))
			match shape:
				"Line": return _lines(id, d, "cb_draw_line3d(%s, %s, %s);" % [_v3(id, "at", ctx), _v3(id, "to", ctx), color.call()])
				"Grid": return _lines(id, d, "cb_draw_grid(%s, (double)(%s));" % [a.call("lines"), a.call("spacing")])
				"Wire box": return _lines(id, d, "cb_draw_wire_box(%s, %s, %s);" % [_v3(id, "at", ctx), _v3(id, "size", ctx), color.call()])
				"Mesh":
					var m := _mesh_arg(id, ctx)
					if m == "":
						return ""
					return _lines(id, d, "cb_draw_mesh(%s, %s, %s, %s, %s);" % [m, _v3(id, "at", ctx), _v3(id, "size", ctx), a.call("turn"), color.call()])
			var kind: int = ["Box", "Sphere", "Cylinder", "Plane"].find(shape)
			return _lines(id, d, "cb_draw_shape(%d, %s, %s, %s, %s);" % [maxi(kind, 0), _v3(id, "at", ctx), _v3(id, "size", ctx), a.call("turn"), color.call()])
		"snapshot":
			var cam := _arg(id, "camera", ctx)
			if not CBTypes.is_class_type(cam[2]) or not CBTypes.is_subclass(cam[2], "Camera3D"):
				_err(id, "pick a Camera3D variable (Node: Find as Camera3D, or New object Camera3D).", "camera")
				return ""
			var subject := "NULL"  # no variable picked: everything
			if _arg_var(id, "subject") != "":
				var subj := _arg(id, "subject", ctx)
				if not CBTypes.is_class_type(subj[2]):
					_err(id, "pick an object variable, or leave it blank for everything.", "subject")
					return ""
				subject = subj[0]
			var common := "%s, %s, %s, %s, %s" % [cam[0], a.call("width"), a.call("height"), "true" if bool(f.get("transparent", false)) else "false", subject]
			if str(f.get("into", "File")) == "Texture":
				return _assign(id, "texture", "cb_snapshot_texture(%s, %d, %d)" % [common, file_index, id], d, true)
			return _assign(id, "ok", "cb_snapshot_file(%s, %s, %d, %d)" % [common, _arg(id, "path", ctx, "string")[0], file_index, id], d, true)
		"begin_mesh":
			var v := _out_var(id, "mesh")
			if v == "":
				_err(id, "name the mesh's variable (Mesh).", "mesh")
				return ""
			return _lines(id, d, "%s = cb_mesh_begin(%s);" % [v, v])
		"add_mesh":
			var m := _mesh_arg(id, ctx)
			if m == "":
				return ""
			match str(f.get("kind", "Triangle")):
				"Quad": return _lines(id, d, "cb_mesh_quad(%s, %s, %s, %s, %s, %s);" % [m, _v3(id, "a", ctx), _v3(id, "b", ctx), _v3(id, "c", ctx), _v3(id, "d", ctx), color.call()])
				"Shape":
					var kind: int = ["Box", "Sphere", "Cylinder", "Plane"].find(str(f.get("shape", "Box")))
					return _lines(id, d, "cb_mesh_shape(%s, %d, %s, %s, %s);" % [m, maxi(kind, 0), _v3(id, "at", ctx), _v3(id, "size", ctx), color.call()])
			return _lines(id, d, "cb_mesh_triangle(%s, %s, %s, %s, %s);" % [m, _v3(id, "a", ctx), _v3(id, "b", ctx), _v3(id, "c", ctx), color.call()])
		"finish_mesh":
			var m := _mesh_arg(id, ctx)
			if m == "":
				return ""
			return _lines(id, d, "cb_mesh_finish(%s, %s, %s, %d, %d);" % [m, "true" if str(f.get("shading", "Flat")) == "Smooth" else "false", "true" if str(f.get("sides", "Both sides")) == "Both sides" else "false", file_index, id])
		"mesh_vertices":
			var m := _mesh_arg(id, ctx)
			if m == "":
				return ""
			if str(f.get("mode", "Get")) == "Set":
				var l := _arg(id, "value", ctx)
				if l[2] != "vector3 list":
					_err(id, "Set needs a vector3 list.", "value")
					return ""
				return _lines(id, d, "cb_mesh_set_points(%s, %s, %d, %d);" % [m, l[0], file_index, id])
			return _assign(id, "points", "cb_mesh_points(%s)" % m, d)
		"sound":
			if str(f.get("mode", "Play")) == "Load":
				return _assign(id, "sound", "cb_sound_load(%s)" % a.call("path"), d)
			var snd := _arg(id, "sound", ctx)
			if snd[2] != "sound":
				_err(id, "pick a sound variable (made by Sound: Load).", "sound")
				return ""
			return _lines(id, d, "cb_sound_play(%s);" % snd[0])
	return ""


## Call C function: declared from its Inputs / Gives back, or by its Header.
func _call_c(id: int, d: int, ctx: Dictionary) -> String:
	var f := _f(id)
	var fname := str(f.get("name", "")).strip_edges()
	if not fname.is_valid_identifier():
		_err(id, "'%s' isn't a C function name." % fname, "name")
		return ""
	var params := T.parse_params(f.get("args", []))
	var ret := str(f.get("returns", "void"))
	var header := str(f.get("header", "")).strip_edges()
	if header != "":
		if not (header.begins_with("<") or header.begins_with("\"")):
			header = "\"%s\"" % header
		if header not in _includes:
			_includes.append(header)
	elif not funcs.has(fname):
		var pd := {}
		for p in params:
			pd[p[1]] = p[0]
		var proto := signature(fname, ret, pd) + ";  /* Call C function */"
		if proto not in _protos:
			_protos.append(proto)
	var args := []
	for p in params:
		args.append(_arg(id, p[1], ctx, p[0])[0])
	var call := "%s(%s)" % [fname, ", ".join(args)]
	if ret == "void":
		return _lines(id, d, call + ";")
	return _assign(id, "result", call, d, true)


# ------------------------------------------------------------------ values

## [expr, type] for input `name`. `want` (a type name) types an Anything literal
## that has no type of its own.
func _arg(id: int, name: String, ctx: Dictionary, want := "") -> Array:
	var spec := _arg_spec(id, name)
	if spec.has("var"):
		var v := str(spec.var).strip_edges()
		if v == "":
			return ["0", T.ANY, "any"]
		var vt := _var_type(v, ctx)
		if want != vt and CBTypes.is_class_type(want) and CBTypes.is_class_type(vt):
			if not CBTypes.is_subclass(vt, want):
				_err(id, "'%s' is a %s, and a %s is wanted here." % [v, vt, want], name)
			return ["((%s *)%s)" % [CBTypes.cname(want), v], T.OBJECT, want]  # a Gem where a Shape3D is wanted
		return [v, T.type_from_name(vt), vt]
	var atype := T.ANY
	var text := ""
	for a in layouts[id].args:
		if a[0] == name:
			atype = a[1]
			text = str(a[2])
	text = str(spec.get("value", text))
	var lt := str(spec.get("type", ""))
	if lt != "":
		atype = T.type_from_name(lt)
	elif atype == T.ANY and want != "" and (CBTypes.is_basic(want) or CBTypes.is_vector(want) or CBTypes.is_vector2(want)):
		atype = T.type_from_name(want)
	var lit := literal(text, atype)
	return [lit[0], lit[1], T.type_name(lit[1])]


## "x, y, z" (or "(x, y, z)", each part a number or an expression) as a Vector3
## (dims 2: "x, y" as a Vector2). One part: the same number in each; none: zero.
static func vector_literal(t: String, dims := 3) -> String:
	var s := t.strip_edges()
	if s.begins_with("(") and s.ends_with(")"):
		s = s.substr(1, s.length() - 2)
	var parts := PackedStringArray()
	var depth := 0
	var cur := ""
	for ch in s:
		if ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
		if ch == "," and depth == 0:
			parts.append(cur.strip_edges())
			cur = ""
		else:
			cur += ch
	parts.append(cur.strip_edges())
	if parts.size() == 1:
		if parts[0] == "":
			return "cb_v3(0, 0, 0)" if dims == 3 else "cb_v2(0, 0)"
		parts = PackedStringArray([parts[0], parts[0], parts[0]])
	while parts.size() < 3:
		parts.append("0")
	for k in 3:
		if parts[k] == "":
			parts[k] = "0"
	if dims == 2:
		return "cb_v2(%s, %s)" % [parts[0], parts[1]]
	return "cb_v3(%s, %s, %s)" % [parts[0], parts[1], parts[2]]


## A typed-in value as C. Number and bool values may be C expressions; text is quoted.
static func literal(text: String, ptype: int) -> Array:
	var t := text.strip_edges()
	match ptype:
		T.INT:
			return [t if t != "" else "0", T.INT]
		T.FLOAT:
			if t == "":
				return ["0.0", T.FLOAT]
			return [t + ".0" if t.is_valid_int() else t, T.FLOAT]
		T.BOOL:
			return [t if t != "" else "false", T.BOOL]
		T.STRING:
			return [c_string(text), T.STRING]
		T.VEC3:
			return [vector_literal(t), T.VEC3]
		T.VEC2:
			return [vector_literal(t, 2), T.VEC2]
	if t.is_valid_int():
		return [t, T.INT]
	if t.is_valid_float():
		return [t, T.FLOAT]
	if t == "true" or t == "false":
		return [t, T.BOOL]
	return [c_string(text), T.STRING]


func _ident(id: int, raw, input: String) -> String:
	var s := str(raw).strip_edges()
	if not s.is_valid_identifier():
		_err(id, "'%s' is not a valid variable name." % s if s != "" else "pick a variable.", input)
		return "invalid_"
	return s


func _zero(ty: String) -> String:
	return CBTypes.zero(ty)


static func _bare(e: String) -> String:
	if not (e.begins_with("(") and e.ends_with(")")):
		return e
	var depth := 0
	for i in e.length():
		if e[i] == "(":
			depth += 1
		elif e[i] == ")":
			depth -= 1
			if depth == 0 and i < e.length() - 1:
				return e
	return e.substr(1, e.length() - 2)


static func c_string(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		var ch := s[i]
		if ch == "\\" and i + 1 < s.length():
			out += ch + s[i + 1]
			i += 2
			continue
		match ch:
			"\\": out += "\\\\"
			"\"": out += "\\\""
			"\n": out += "\\n"
			"\t": out += "\\t"
			_: out += ch
		i += 1
	return "\"" + out + "\""


func _map(id: int, d: int, ctx: Dictionary) -> String:
	var f := _f(id)
	var op := str(f.get("op", "Set"))
	if op == "Make":
		var of := str(f.get("of", "int"))
		if not CBTypes.valid(of, records) or CBTypes.is_container(of):
			_err(id, "a map can hold int, float, bool, string or a record.", "of")
			return ""
		return _assign(id, "result", "cb_map_new(sizeof(%s))" % CBTypes.c_type(of), d)
	var m := _arg(id, "map", ctx)
	if not CBTypes.is_map(m[2]):
		_err(id, "pick a map variable.", "map")
		return ""
	var vt := CBTypes.map_value(m[2])
	var cv := CBTypes.c_type(vt)
	var key := func() -> String: return _arg(id, "key", ctx, "string")[0]
	match op:
		"Set": return _lines(id, d, "*(%s *)cb_map_put(%s, %s) = %s;" % [cv, m[0], key.call(), _arg(id, "value", ctx, vt)[0]])
		"Get": return _assign(id, "result", "*(%s *)cb_map_get(%s, %s, %d, %d)" % [cv, m[0], key.call(), file_index, id], d)
		"Get or":
			var v := _out_var(id, "result")
			if v == "":
				return ""
			var k := "mk_%d" % id
			return _lines(id, d, "{\n    int %s = cb_map_find(%s, %s);\n    %s = %s >= 0 ? ((%s *)%s->values->data)[%s] : %s;\n}" % [k, m[0], key.call(), v, k, cv, m[0], k, _arg(id, "default", ctx, vt)[0]])
		"Has": return _assign(id, "result", "cb_map_find(%s, %s) >= 0" % [m[0], key.call()], d)
		"Remove": return _lines(id, d, "cb_map_remove(%s, %s);" % [m[0], key.call()])
		"Count": return _assign(id, "result", "%s->keys->count" % m[0], d)
		"Keys": return _assign(id, "result", "cb_map_keys(%s)" % m[0], d)
		"Values": return _assign(id, "result", "cb_map_values(%s)" % m[0], d)
		"Clear": return _lines(id, d, "cb_map_clear(%s);" % m[0])
	return ""


func _vector(id: int, d: int, ctx: Dictionary) -> String:
	var op := str(_f(id).get("op", "Make"))
	var two := str(_f(id).get("dims", "3D")) == "2D"
	var vt := "vector2" if two else "vector3"
	var p := "cb_v2" if two else "cb_v3"
	var a := func() -> String: return _arg(id, "a", ctx, vt)[0]
	var b := func() -> String: return _arg(id, "b", ctx, vt)[0]
	if op != "Make":
		var at: Array = _arg(id, "a", ctx, vt)
		if at[1] != (T.VEC2 if two else T.VEC3):
			_err(id, "A needs a %s (a variable, or %s)." % [vt, "x, y" if two else "x, y, z"], "a")
			return ""
	match op:
		"Make":
			if two:
				return _assign(id, "result", "cb_v2(%s, %s)" % [_arg(id, "x", ctx)[0], _arg(id, "y", ctx)[0]], d)
			return _assign(id, "result", "cb_v3(%s, %s, %s)" % [_arg(id, "x", ctx)[0], _arg(id, "y", ctx)[0], _arg(id, "z", ctx)[0]], d)
		"Split":
			var s := ""
			for part in (["x", "y"] if two else ["x", "y", "z"]):
				s += _assign(id, part, "(double)(%s).%s" % [a.call(), part], d)
			return s
		"Add": return _assign(id, "result", "%s_add(%s, %s)" % [p, a.call(), b.call()], d)
		"Subtract": return _assign(id, "result", "%s_sub(%s, %s)" % [p, a.call(), b.call()], d)
		"Scale": return _assign(id, "result", "%s_scale(%s, %s)" % [p, a.call(), _arg(id, "factor", ctx)[0]], d)
		"Length": return _assign(id, "result", "%s_length(%s)" % [p, a.call()], d)
		"Normalize": return _assign(id, "result", "%s_normalize(%s)" % [p, a.call()], d)
		"Distance": return _assign(id, "result", "%s_length(%s_sub(%s, %s))" % [p, p, a.call(), b.call()], d)
		"Lerp": return _assign(id, "result", "%s_lerp(%s, %s, %s)" % [p, a.call(), b.call(), _arg(id, "t", ctx)[0]], d)
		"Dot": return _assign(id, "result", "%s_dot(%s, %s)" % [p, a.call(), b.call()], d)
		"Cross": return _assign(id, "result", "%s_cross(%s, %s)" % [p, a.call(), b.call()], d)
	return ""

## A vector3 input as C (a variable must be a vector3).
func _v2(id: int, name: String, ctx: Dictionary) -> String:
	var v := _arg(id, name, ctx, "vector2")
	if v[1] != T.VEC2:
		_err(id, "%s needs a vector2 (a variable, or x, y)." % name.capitalize(), name)
	return v[0]


func _v3(id: int, name: String, ctx: Dictionary) -> String:
	var v := _arg(id, name, ctx, "vector3")
	if v[1] != T.VEC3:
		_err(id, "%s needs a vector3 (a variable, or x, y, z)." % name.capitalize(), name)
	return v[0]


## The mesh variable a mesh brick works on ("" and a problem when it isn't one).
func _mesh_arg(id: int, ctx: Dictionary) -> String:
	var m := _arg(id, "mesh", ctx)
	if m[2] != "mesh":
		_err(id, "pick a mesh variable (made by Begin mesh).", "mesh")
		return ""
	return m[0]


## An object input (a variable of a class); "" and a problem when it isn't one.
func _object_arg(id: int, name: String, ctx: Dictionary) -> String:
	var o := _arg(id, name, ctx)
	if not CBTypes.is_class_type(o[2]):
		_err(id, "pick an object variable (made by New object).", name)
		return ""
	return o[0]


func _call_method(id: int, d: int, ctx: Dictionary) -> String:
	var f := _f(id)
	var cls := str(f.get("class", ""))
	var m := str(f.get("method", ""))
	if not CBTypes.is_class_type(cls):
		_err(id, "pick the object's class." if cls == "" else "there's no class named '%s'." % cls, "class")
		return ""
	var methods := CBTypes.all_methods(cls)
	if not methods.has(m):
		_err(id, "pick a method of %s." % cls if m == "" else "%s has no method '%s'%s" % [cls, m, ": its methods are " + ", ".join(methods.keys()) + "." if not methods.is_empty() else " (it has none)."], "method")
		return ""
	var o := _arg(id, "object", ctx)
	if not CBTypes.is_class_type(o[2]):
		_err(id, "pick an object variable (made by New object).", "object")
		return ""
	if not CBTypes.is_subclass(o[2], cls):
		_err(id, "'%s' is a %s, not a %s: pick its class or a parent class of it." % [o[0], o[2], cls], "object")
		return ""
	var info: Dictionary = methods[m]
	var args := [o[0]]
	for p in info.params:
		args.append(_arg(id, p[1], ctx, p[0])[0])
	var call := "((const %s_vt *)((cb_object *)cb_obj(%s, %d, %d))->cls->vt)->%s(%s)" % [CBTypes.cname(info.declared), o[0], file_index, id, m, ", ".join(args)]
	return _assign(id, "result", call, d, true)


func _object_op(id: int, d: int, ctx: Dictionary) -> String:
	var f := _f(id)
	var op := str(f.get("op", "Exists"))
	var o := _arg(id, "object", ctx) if op not in ["World", "Find"] else ["NULL", T.OBJECT, CBTypes.OBJECT]
	if not CBTypes.is_class_type(o[2]):
		_err(id, "pick an object variable.", "object")
		return ""
	var checked := "((cb_object *)cb_obj(%s, %d, %d))" % [o[0], file_index, id]
	var of := str(f.get("of", ""))
	if op == "Find" and of == "":
		of = CBTypes.OBJECT
	if op in ["Is a", "As"] and not CBTypes.is_class_type(of):
		_err(id, "pick a class." if of == "" else "there's no class named '%s'." % of, "of")
		return ""
	match op:
		"Exists": return _assign(id, "result", "cb_alive(%s)" % o[0], d)
		"Is a": return _assign(id, "result", "cb_is_a(%s, &%s_class)" % [o[0], CBTypes.cname(of)], d)
		"As": return _assign(id, "result", "(%s *)cb_as(%s, &%s_class)" % [CBTypes.cname(of), o[0], CBTypes.cname(of)], d)
		"Class name": return _assign(id, "result", "%s->cls->name" % checked, d)
		"Id": return _assign(id, "result", "%s->id" % checked, d)
		"Name": return _assign(id, "result", "%s->name" % checked, d)
		"Set name": return _lines(id, d, "%s->name = %s;" % [checked, _arg(id, "name", ctx, "string")[0]])
		"Parent": return _assign(id, "result", "(Node *)%s->parent" % checked, d)
		"Set parent":
			var p := _arg(id, "parent", ctx)
			if p[0] != "0" and not CBTypes.is_class_type(p[2]):
				_err(id, "pick an object variable (or leave it blank: under nothing).", "parent")
				return ""
			return _lines(id, d, "cb_set_parent(%s, %s, %d, %d);" % [o[0], p[0] if p[0] != "0" else "NULL", file_index, id])
		"Children": return _assign(id, "result", "cb_children(%s, %d, %d)" % [o[0], file_index, id], d)
		"World": return _assign(id, "result", "(Node *)cb_world()", d)
		"Find":
			if not CBTypes.is_class_type(of):
				_err(id, "there's no class named '%s'." % of, "of")
				return ""
			return _assign(id, "result", "(%s *)cb_as(cb_find_object(%s), &%s_class)" % [CBTypes.cname(of), _arg(id, "name", ctx, "string")[0], CBTypes.cname(of)], d)
	return ""


## Host / Join / Leave, the role (Brickscript's network bricks; cb_net.c).
func _network(id: int, d: int, ctx: Dictionary) -> String:
	uses_net = true
	var op := str(_f(id).get("do", "Host"))
	if misplaced("network", _f(id), _class, _side) != "":
		return ""  # (a problem already: misplaced)
	match op:
		"Host": return _assign(id, "result", "cb_net_host(%s)" % _arg(id, "port", ctx, "int")[0], d, true)
		"Join": return _assign(id, "result", "cb_net_join(%s, %s, %s)" % [_arg(id, "address", ctx, "string")[0], _arg(id, "port", ctx, "int")[0], _arg(id, "timeout", ctx, "float")[0]], d, true)
		"Leave": return _lines(id, d, "cb_net_leave();")
		"Role": return _assign(id, "result", "cb_net_role_name()", d)
	return _assign(id, "result", "cb_net_is_server()", d)


## Fire Server / Fire Clients: the remote's values written in order, then sent.
func _fire(id: int, d: int, ctx: Dictionary) -> String:
	uses_net = true
	var to_server: bool = nodes[id].type == "fire_server"
	var rname := str(_f(id).get("remote", ""))
	var r = CBTypes.remotes.get(rname)
	if r == null:
		_err(id, "pick a remote (add a Define Remote brick first)." if rname == "" else "there's no remote named '%s'." % rname, "remote")
		return ""
	if misplaced(str(nodes[id].type), {}, _class, _side) != "":
		return ""  # (a problem already: misplaced)
	if str(r.direction) == "Ask server":
		_err(id, "the remote '%s' is a question (Ask server): ask it with Invoke Server." % rname, "remote")
		return ""
	if str(r.direction) == ("To clients" if to_server else "To server"):
		_err(id, "the remote '%s' goes %s: %s." % [rname, str(r.direction).to_lower(), "make it To server or Both" if to_server else "make it To clients or Both"], "remote")
		return ""
	var lines := PackedStringArray(["cb_msg_begin(%d);  /* %s */" % [int(r.index), rname]])
	for prm in r.params:
		var ty := str(prm[0])
		var v := _arg(id, str(prm[1]), ctx, ty)
		if CBTypes.is_class_type(ty) and not CBTypes.is_class_type(v[2]) and v[0] != "0":
			_err(id, "pick an object variable (a %s), or leave it blank: none." % ty, str(prm[1]))
			return ""
		lines.append(_msg_put(ty, v[0] if v[0] != "0" or not CBTypes.is_class_type(ty) else "NULL"))
	if to_server:
		lines.append("cb_net_fire_server(%d, %d);" % [file_index, id])
	elif str(_f(id).get("to", "All")) == "One player":
		var spec := _arg_spec(id, "player")
		if not spec.has("var") or str(spec.var).strip_edges() == "":
			_err(id, "say which player (e.g. On Client Fired's sender, or Player Joined's player).", "player")
			return ""
		var who := _arg(id, "player", ctx, "int")
		if who[2] != "int":
			_err(id, "pick a player (a number: e.g. On Client Fired's sender, Player Joined's player).", "player")
			return ""
		lines.append("cb_net_fire_clients(%s, false, %d, %d);" % [who[0], file_index, id])
	else:
		lines.append("cb_net_fire_clients(0, true, %d, %d);" % [file_index, id])
	return _lines(id, d, "\n".join(lines))


## Invoke Server: the remote's values written like Fire Server's, then asked; the answer
## read back (its zero value when none came).
func _invoke(id: int, d: int, ctx: Dictionary) -> String:
	uses_net = true
	var rname := str(_f(id).get("remote", ""))
	var r = CBTypes.remotes.get(rname)
	if r == null:
		_err(id, "pick a remote (a Define Remote brick whose Direction is Ask server)." if rname == "" else "there's no remote named '%s'." % rname, "remote")
		return ""
	if str(r.direction) != "Ask server":
		_err(id, "the remote '%s' goes %s: Invoke Server asks a question (make its Direction Ask server), or use Fire Server." % [rname, str(r.direction).to_lower()], "remote")
		return ""
	if misplaced("invoke_server", {}, _class, _side) != "":
		return ""  # (a problem already: misplaced)
	if ctx.get("method", false) and str(ctx.name) in ["on_frame", "on_touched", "on_drawn", "on_clicked"]:
		_err(id, "Invoke Server waits for its answer: it can't be in an object's event (Every frame, When touched, When drawn), it would hold up the whole world. Ask from a script's chain, or Fire Server and answer with Fire Clients.")
		return ""
	var lines := PackedStringArray(["cb_msg_begin(%d);  /* %s (a question) */" % [int(r.index), rname]])
	for prm in r.params:
		var ty := str(prm[0])
		var v := _arg(id, str(prm[1]), ctx, ty)
		if CBTypes.is_class_type(ty) and not CBTypes.is_class_type(v[2]) and v[0] != "0":
			_err(id, "pick an object variable (a %s), or leave it blank: none." % ty, str(prm[1]))
			return ""
		lines.append(_msg_put(ty, v[0] if v[0] != "0" or not CBTypes.is_class_type(ty) else "NULL"))
	var at := str(r.answer)
	var av := _out_var(id, "answer")
	var okv := _out_var(id, "answered")
	var got := PackedStringArray()
	var none := PackedStringArray()
	if av != "":
		got.append("    %s = %s;" % [av, _msg_get(at)])
		none.append("    %s = %s;" % [av, _zero(at)])
	if okv != "":
		got.append("    %s = true;" % okv)
		none.append("    %s = false;" % okv)
	var call := "cb_net_invoke(%s, %d, %d)" % [_arg(id, "timeout", ctx, "float")[0], file_index, id]
	if got.is_empty():
		lines.append("(void)%s;" % call)
	else:
		lines.append("if (%s) {\n%s\n} else {\n%s\n}" % [call, "\n".join(got), "\n".join(none)])
	return _lines(id, d, "\n".join(lines))


## Answer: inside an On Client Invoked chain, the answer to its question.
func _answer(id: int, d: int, ctx: Dictionary) -> String:
	uses_net = true
	if not ctx.get("invoked", false):
		_err(id, "Answer belongs in an On Client Invoked chain (it answers that question).")
		return ""
	var at := str(ctx.remote.answer)
	var v := _arg(id, "value", ctx, at)
	if CBTypes.is_class_type(at):
		if v[0] != "0" and not CBTypes.is_class_type(v[2]):
			_err(id, "the answer is a %s: pick an object variable, or leave it blank (none)." % at, "value")
			return ""
	elif v[2] not in [at, "any"] and not (at == "float" and v[2] == "int"):
		_err(id, "the remote '%s' answers a %s, not a %s." % [str(_f(ctx.entry).get("remote", "")), at, v[2]], "value")
		return ""
	return _lines(id, d, "cb_answer_begin();\n%s\ncb_net_answer(%d, %d);" % [_msg_put(at, v[0] if v[0] != "0" or not CBTypes.is_class_type(at) else "NULL"), file_index, id])


static func _msg_put(ty: String, expr: String) -> String:
	match ty:
		"int": return "cb_msg_put_int(%s);" % expr
		"float": return "cb_msg_put_float(%s);" % expr
		"bool": return "cb_msg_put_bool(%s);" % expr
		"string": return "cb_msg_put_text(%s);" % expr
		"vector3": return "cb_msg_put_v3(%s);" % expr
		"vector2": return "cb_msg_put_v2(%s);" % expr
	return "cb_msg_put_object(%s);" % expr


static func _msg_get(ty: String) -> String:
	match ty:
		"int": return "cb_msg_int()"
		"float": return "cb_msg_float()"
		"bool": return "cb_msg_bool()"
		"string": return "cb_msg_text()"
		"vector3": return "cb_msg_v3()"
		"vector2": return "cb_msg_v2()"
	return "(%s)cb_msg_object(&%s_class)" % [CBTypes.c_type(ty), CBTypes.cname(ty)]


## Give to / Owner / Mine? / Owned by (Brickscript's ownership; players are numbers).
func _ownership(id: int, d: int, ctx: Dictionary) -> String:
	uses_net = true
	var op := str(_f(id).get("do", "Give to"))
	if op == "Owned by":
		var who := _player_arg(id, ctx)
		return _assign(id, "result", "cb_net_owned_by(%s)" % who, d) if who != "" else ""
	var o := _object_arg(id, "object", ctx)
	if o == "":
		return ""
	match op:
		"Owner": return _assign(id, "result", "cb_net_owner(%s, %d, %d)" % [o, file_index, id], d)
		"Is mine": return _assign(id, "result", "cb_net_mine(%s, %d, %d)" % [o, file_index, id], d)
	if misplaced("ownership", _f(id), _class, _side) != "":
		return ""  # (a problem already: misplaced)
	var who := "0"
	if _arg_var(id, "player") != "" or str(_arg_spec(id, "player").get("value", "")) != "":
		var pl := _arg(id, "player", ctx, "int")
		if pl[2] != "int":
			_err(id, "pick a player (a number), or leave it blank: no one's.", "player")
			return ""
		who = pl[0]
	return _lines(id, d, "cb_net_give(%s, %s, %d, %d);" % [o, who, file_index, id])


## Players (numbers: the host, or you offline, is 1): Me, a player's name, is it me,
## is it in the game, every player.
func _player(id: int, d: int, ctx: Dictionary) -> String:
	uses_net = true
	var op := str(_f(id).get("op", "Me"))
	match op:
		"Me":
			if misplaced("player", _f(id), _class, _side) != "":
				return ""  # (a problem already: misplaced)
			return _assign(id, "result", "cb_net_me()", d)
		"Players": return _assign(id, "result", "cb_net_players()", d)
	var who := _player_arg(id, ctx)
	if who == "":
		return ""
	match op:
		"Is me": return _assign(id, "result", "(%s) == cb_net_me() && cb_net_me() != 0" % who, d)
		"In game": return _assign(id, "result", "cb_net_in_game(%s)" % who, d)
	return _assign(id, "result", "cb_net_player_name(%s)" % who, d)


## A Player input. Blank (the user's rule): the player the script's object is under
## (a Script object inside a player: its `parent`), else this machine's player; a
## Server script without a parent must say which.
func _player_arg(id: int, ctx: Dictionary) -> String:
	var spec := _arg_spec(id, "player")
	if (spec.has("var") and str(spec.var).strip_edges() == "") or (not spec.has("var") and str(spec.get("value", "")).strip_edges() == ""):
		if ctx.params.has("parent"):
			return "cb_net_player_here(parent, %d, %d)" % [file_index, id]
		if ctx.params.has("self"):
			return "cb_net_player_here(self, %d, %d)" % [file_index, id]  # a class's method: the object's owner
		if _side == "Server":
			_err(id, "say which player (e.g. Player Joined's player): a Server script serves every player.", "player")
			return ""
		return "cb_net_player_here(NULL, %d, %d)" % [file_index, id]
	var p := _arg(id, "player", ctx, "int")
	if p[2] != "int":
		_err(id, "pick a player: a number (e.g. Player Joined's player).", "player")
		return ""
	return p[0]


## A script may use what runs where it runs: Shared things everywhere, a Server
## script's only on the server, a Client script's only on clients (Brickscript's
## LocalScript / ServerScript rule).
func _check_side(id: int, their_side: String, what: String, input: String) -> void:
	if their_side == "Shared" or their_side == _side:
		return
	if _side == "Shared":
		_err(id, "%s is in a %s script, and this Shared script runs on both sides: make this script %s too, or move %s to a Shared script." % [what.left(1).to_upper() + what.substr(1), their_side, their_side, what], input)
	else:
		_err(id, "%s is in a %s script, and this script runs on the %s: they never run in the same place." % [what.left(1).to_upper() + what.substr(1), their_side, _side.to_lower()], input)


## A method's C with its class's field names turned into self's members ("hp" ->
## "(((cls_Character *)self)->f_hp)"). Only whole names: not after "." or "->" (another
## struct's member), not in strings, characters or comments.
static func rewrite_fields(code: String, owners: Dictionary) -> String:
	var out := ""
	var i := 0
	var n := code.length()
	var last := ""   # the last non-space character outside strings / comments
	var prev2 := ""  # the one before it
	while i < n:
		var c := code[i]
		if c == "\"" or c == "'":
			var j := i + 1
			while j < n and code[j] != c:
				j += 2 if code[j] == "\\" else 1
			out += code.substr(i, j + 1 - i)
			i = j + 1
			prev2 = last
			last = c
			continue
		if c == "/" and i + 1 < n and code[i + 1] == "/":
			var e := code.find("\n", i)
			e = n if e < 0 else e
			out += code.substr(i, e - i)
			i = e
			continue
		if c == "/" and i + 1 < n and code[i + 1] == "*":
			var e := code.find("*/", i + 2)
			e = n if e < 0 else e + 2
			out += code.substr(i, e - i)
			i = e
			continue
		if c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z"):
			var j := i + 1
			while j < n and (code[j] == "_" or code[j].is_valid_identifier() or code[j].is_valid_int()):
				j += 1
			var word := code.substr(i, j - i)
			var member := last == "." or (last == ">" and prev2 == "-")
			if owners.has(word) and not member:
				out += "(((%s *)self)->f_%s)" % [owners[word], word]
			else:
				out += word
			i = j
			prev2 = last
			last = "a"
			continue
		out += c
		if c != " " and c != "\t" and c != "\n":
			prev2 = last
			last = c
		i += 1
	return out


## The variables made before a brick runs: by the bricks wired into it and what runs
## before them, by earlier chains on the same exit (they run to their end first), and,
## on a brick's last exit (Next, Done...), by its other exits' chains (they ran first).
func _made_before(id: int, memo: Dictionary, subtree_memo: Dictionary) -> Dictionary:
	if memo.has(id):
		return memo[id]
	memo[id] = {}  # a wire loop: stop here
	var out := {}
	for pr in _preds.get(id, []):
		var pid: int = pr[0]
		if not nodes.has(pid):
			continue
		out.merge(_made_before(pid, memo, subtree_memo))
		for v in _writes(pid):
			out[v] = true
		var links: Dictionary = nodes[pid].get("links", {})
		var groups: Array = layouts[pid].groups if layouts.has(pid) else []
		if not groups.is_empty() and str(pr[1]) == str(groups.back()):
			for g in groups:
				if g != groups.back():
					for t in links.get(g, []):
						out.merge(_chain_writes(int(t), subtree_memo))
		var same: Array = links.get(pr[1], [])
		for j in int(pr[2]):
			out.merge(_chain_writes(int(same[j]), subtree_memo))
	memo[id] = out
	return out


## Every variable a chain makes (the brick and everything wired after it).
func _chain_writes(id: int, subtree_memo: Dictionary) -> Dictionary:
	if subtree_memo.has(id):
		return subtree_memo[id]
	subtree_memo[id] = {}
	var out := {}
	if not nodes.has(id):
		return out
	for v in _writes(id):
		out[v] = true
	var links: Dictionary = nodes[id].get("links", {})
	for g in links:
		for t in links[g]:
			out.merge(_chain_writes(int(t), subtree_memo))
	subtree_memo[id] = out
	return out
