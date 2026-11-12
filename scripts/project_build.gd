class_name ProjectBuild
extends RefCounted
## Turns a whole project into C: one .c file per script, plus
##   cbricks.h          the standard headers, the runtime's API and every function's
##                     prototype, so scripts call each other's functions
##   cbricks_runtime.c  main()'s helper: the command-line flags every C-Bricks program
##                     understands (--help, --trace, --seed, --input...), program
##                     arguments for the Program Arguments brick, files, asserts
## All of it portable C99 (hosted), so the folder builds anywhere.

const T = preload("res://scripts/node_defs.gd")

## The flags every program built with C-Bricks takes (also its --help).
const FLAGS := [
	["-h, --help", "show this help and exit"],
	["--version", "show the program's name and version and exit"],
	["--trace", "print each brick as it runs, to stderr ([trace] script:brick)"],
	["-v, --verbose", "show Debug log bricks' output (stderr)"],
	["--seed N", "seed Random Int with N: the same numbers every run (tests)"],
	["--input FILE", "read stdin from FILE (tests: typed answers in a file)"],
	["--output FILE", "write stdout to FILE"],
	["--cd DIR", "change to DIR first (assets are found from there)"],
	["--max-steps N", "stop with exit code 124 after N bricks have run (catches endless loops)"],
	["--time", "print the run's CPU / wall time and bricks run at exit (stderr)"],
	["--debug FILE", "debugger: pause on breakpoints, read commands from FILE (the editor uses it)"],
	["--break S:B", "a breakpoint at script S, brick B (main.cbricks:7; several with commas)"],
	["--click X:Y:T", "a left click at window pixel X, Y, T seconds after the window opened (tests; several with commas)"],
	["--", "pass everything after it to the program as it is"],
]
## More flags in projects that use networking (cb_net.c).
const NET_FLAGS := [
	["--host PORT", "host a network game on PORT: a server with your player (player 1)"],
	["--server PORT", "run a dedicated server on PORT (no player of its own)"],
	["--join A:PORT", "join the game at address A, port PORT (e.g. 127.0.0.1:7000)"],
	["--name NAME", "your player's name in network games (default: your user name)"],
	["--press K:A:B", "hold key K from A to B seconds after the start (tests; e.g. D:0.5:1.5, several with commas)"],
]


## C file name of a script: "scripts/util.cbricks" -> "scripts__util.c".
static func c_name(rel: String) -> String:
	var base := rel.trim_suffix("." + CBProject.SCRIPT_EXT).replace("/", "__")
	var out := ""
	for ch in base:
		out += ch if (ch.is_valid_identifier() or ch.is_valid_int()) else "_"
	if out == "cbricks_runtime" or out == "":
		out = "script_" + out
	return out + ".c"


## Generates the project's C. `open_graphs`: {absolute script path: graph} for
## scripts open in the editor (their unsaved state wins over the file).
## Returns {"files": {name: text}, "sources": [.c names], "scripts": {path: {...}},
##          "errors": [{script, node, msg}], "warnings": [...]}
static func generate(dir: String, open_graphs: Dictionary = {}, target := "native") -> Dictionary:
	var cf := CBProject.load_config(dir)
	var program := str(cf.get_value("project", "name", dir.get_file()))
	var version := str(cf.get_value("project", "version", "1.0"))
	var paths := CBProject.list_scripts(dir)
	for p in open_graphs:
		if p not in paths and p.begins_with(dir):
			paths.append(p)
	var graphs := {}
	for p in paths:
		graphs[p] = open_graphs[p] if open_graphs.has(p) else CBProject.read_script(p)
	return generate_graphs(program, version, dir, paths, graphs, target, int(cf.get_value("dos", "screen", 0)), str(cf.get_value("graphics", "backend", "auto")), CBProject.graphics_settings(cf))


## target: the build's target id (it picks the graphics backend unless backend_pick names one:
## "auto", "raylib", "dos"); dos_screen: MS-DOS's screen width (0: the smallest of 320 / 640 / 800
## the Open window's size fits).
static func generate_graphs(program: String, version: String, dir: String, paths: PackedStringArray, graphs: Dictionary, target := "native", dos_screen := 0, backend_pick := "auto", gfx := {}) -> Dictionary:
	var errors := []
	var warnings := []
	var class_of := collect_classes(dir, paths, graphs, errors)  # script path -> its class
	# Scenes: every .cbscene (the Main scene first); has_world: there's a scene to build.
	var scenes := collect_scenes(dir, errors) if dir != "" else {}
	var main_scene := CBProject.rel_path(dir, CBProject.world_path(dir)) if dir != "" else ""
	var has_world: bool = not scenes.is_empty()
	var all_objects := []
	for rel in scenes:
		all_objects.append_array(scenes[rel].data.objects)
	# Every function of the project (not a class's methods), and where it is.
	var funcs := {}
	var where := {}
	for p in paths:
		if class_of.has(p):
			continue
		for n in graphs[p].get("nodes", []):
			if n.type != "function":
				continue
			var fname := str(n.fields.get("name", ""))
			var info: Dictionary = T.collect_functions([n]).get(fname, {})
			if funcs.has(fname) and where[fname] != p:
				errors.append({"script": p, "node": int(n.id), "msg": "Define Function (node %d): '%s' is already a function in %s." % [int(n.id), fname, CBProject.rel_path(dir, where[fname])]})
				continue
			info["side"] = str(graphs[p].get("side", "Shared"))
			funcs[fname] = info
			where[fname] = p
	# Records and constants: project-wide.
	var records := {}
	var record_where := {}
	var remotes := {}         # Define Remote: name -> {direction, params, script, node}
	var constants := {}       # name -> type
	var const_defs := []      # [name, C value]
	for p in paths:
		for n in graphs[p].get("nodes", []):
			var f: Dictionary = n.get("fields", {})
			if n.type == "record":
				var rname := str(f.get("name", ""))
				var title := "Define Record (node %d)" % int(n.id)
				if not rname.is_valid_identifier() or CBTypes.is_basic(rname) or rname.begins_with("cb_"):
					errors.append({"script": p, "node": int(n.id), "msg": "%s: '%s' can't be a record name (letters, digits and _)." % [title, rname]})
					continue
				if records.has(rname):
					errors.append({"script": p, "node": int(n.id), "msg": "%s: there's already a record named '%s' (%s)." % [title, rname, CBProject.rel_path(dir, record_where[rname])]})
					continue
				records[rname] = T.collect_records([n])[rname]
				record_where[rname] = p
			elif n.type == "remote":
				var rn := str(f.get("name", "")).strip_edges()
				var rtitle := "Define Remote (node %d)" % int(n.id)
				if not rn.is_valid_identifier():
					errors.append({"script": p, "node": int(n.id), "msg": "%s: '%s' can't be a remote's name (letters, digits and _)." % [rtitle, rn]})
					continue
				if remotes.has(rn):
					errors.append({"script": p, "node": int(n.id), "msg": "%s: there's already a remote named '%s' (%s)." % [rtitle, rn, CBProject.rel_path(dir, remotes[rn].script)]})
					continue
				remotes[rn] = {"direction": str(f.get("direction", "To server")), "params": T.parse_params(f.get("values", [])), "script": p, "node": int(n.id), "answer": str(f.get("answer", "bool"))}
			elif n.type == "constant":
				var cname := str(f.get("name", ""))
				if not cname.is_valid_identifier():
					errors.append({"script": p, "node": int(n.id), "msg": "Constant (node %d): '%s' can't be a constant's name." % [int(n.id), cname]})
					continue
				var ty := str(f.get("type", "int"))
				var spec = n.get("args", {}).get("value", {})
				var text := str(spec.get("value", "0")) if spec is Dictionary else str(spec)
				constants[cname] = ty
				const_defs.append([cname, CodeGen.literal(text, T.type_from_name(ty))[0]])
	for r in records:
		for fld in records[r]:
			if not CBTypes.valid(fld[1], records):
				errors.append({"script": record_where[r], "node": 0, "msg": "Record %s: field '%s' has an unknown type '%s'." % [r, fld[0], fld[1]]})
	if record_order(records).size() < records.size():
		errors.append({"script": "", "node": 0, "msg": "Records contain each other in a circle (a record can hold a list of itself, not itself)."})
	check_classes(records, errors)
	# Remotes: numbered in name order (the same on every machine of a build); their values sendable.
	var remote_names := remotes.keys()
	remote_names.sort()
	for i in remote_names.size():
		var r: Dictionary = remotes[remote_names[i]]
		r["index"] = i
		var seen := {}
		for prm in r.params:
			var ty := str(prm[0])
			var title := "Define Remote (node %d): %s's value '%s'" % [int(r.node), remote_names[i], prm[1]]
			if prm[1] in ["sender", "player"] or seen.has(prm[1]):
				errors.append({"script": r.script, "node": r.node, "msg": "%s: %s." % [title, "the name is taken (sender / player are the bricks' own)" if not seen.has(prm[1]) else "two values have that name"]})
			elif not (CBTypes.is_basic(ty) or CBTypes.is_vector(ty) or CBTypes.is_vector2(ty) or CBTypes.is_class_type(ty)):
				errors.append({"script": r.script, "node": r.node, "msg": "%s is a %s: a remote carries numbers, bools, text, vectors and objects (not lists, maps or records yet)." % [title, ty]})
			seen[prm[1]] = true
		if str(r.direction) == "Ask server":
			var at := str(r.answer)
			if not (CBTypes.is_basic(at) or CBTypes.is_vector(at) or CBTypes.is_vector2(at) or CBTypes.is_class_type(at)):
				errors.append({"script": r.script, "node": r.node, "msg": "Define Remote (node %d): %s's Answer is a %s: an answer is a number, bool, text, vector or object." % [int(r.node), remote_names[i], at]})
	CBTypes.remotes = remotes
	# The keys players' machines send (Player Key / Player Input): one list for the build.
	var keys := {}
	for p in paths:
		for n in graphs[p].get("nodes", []):
			var nf: Dictionary = n.get("fields", {})
			if n.type == "player_key" or (n.type == "player_input" and str(nf.get("what", "Holds")) == "Holds"):
				keys[str(nf.get("key", "SPACE"))] = true
			elif n.type == "player_input":
				for k in [["left", "A"], ["right", "D"], ["forward", "W"], ["back", "S"]]:
					keys[str(nf.get(k[0], k[1]))] = true
	CBTypes.net_keys = keys.keys()
	CBTypes.net_keys.sort()
	if CBTypes.net_keys.size() > 64:
		errors.append({"script": "", "node": 0, "msg": "Player Key / Player Input name %d keys: at most 64 can be sent." % CBTypes.net_keys.size()})
	var files := {}
	var sources := []
	var scripts := {}
	var exits := []
	var includes := []
	var mains := []
	var rels := []
	var inits := []
	var graphics := false
	var net := false
	for p in paths:
		rels.append(CBProject.rel_path(dir, p))
	# The Scene tree's Script objects: their files' When program starts run once per object.
	var attached := {}  # script rel path -> true
	for srel in scenes:
		for o in scenes[srel].data.objects:
			if CBTypes.is_script_object(o):
				var rel := str(o.get("script", ""))
				var at := rels.find(rel)
				if at < 0:
					errors.append({"script": scenes[srel].path, "node": 0, "world_id": int(o.id), "msg": "%s: %s (%s): its script '%s' isn't in the project." % [srel, str(o.get("name", "")), str(o["class"]), rel]})
				elif class_of.has(paths[at]):
					errors.append({"script": scenes[srel].path, "node": 0, "world_id": int(o.id), "msg": "%s: %s (%s): %s is the class %s's script: add an object of that class instead." % [srel, str(o.get("name", "")), str(o["class"]), rel, class_of[paths[at]]]})
				else:
					attached[rel] = true
	var script_starts := {}  # rel -> C function
	for i in paths.size():
		var p: String = paths[i]
		var gen := CodeGen.new()
		var name := c_name(rels[i])
		var res := gen.generate(graphs[p], {"funcs": funcs, "file": i, "script": rels[i], "records": records, "constants": constants, "init_name": "cb_init_" + name.get_basename(), "class": class_of.get(p, ""), "side": str(graphs[p].get("side", "Shared")), "always": bool(graphs[p].get("always", false)), "world_loader": has_world, "attached": attached.has(rels[i]), "scenes": scenes})
		if res.get("script_start", "") != "":
			script_starts[rels[i]] = res.script_start
		files[name] = res.code
		if class_of.has(p) and class_of[p] in class_order(true, true):  # (a class whose parents are known)
			files[name] += class_machinery(class_of[p])
		sources.append(name)
		exits.append_array(res.exit_handlers)
		if res.has_init:
			inits.append("cb_init_" + name.get_basename())
		graphics = graphics or res.uses_graphics
		net = net or res.uses_net
		if res.has_main:
			mains.append(p)
		for e in res.errors:
			errors.append({"script": p, "node": e.node, "msg": e.msg, "context": bool(e.get("context", false))})
		for w in res.warnings:
			warnings.append({"script": p, "node": w.node, "msg": w.msg})
		scripts[p] = {"class": class_of.get(p, ""), "c": name, "rel": rels[i], "result": res}
	# No When program starts (user, 2026-11-07: a project doesn't start with a main script):
	# a main() of the build's own runs the Main scene (cbricks_main.c, below).
	for m in mains.slice(1):
		errors.append({"script": m, "node": 0, "msg": "%s: only one script may have 'When program starts' (%s has one too)." % [CBProject.rel_path(dir, m), CBProject.rel_path(dir, mains[0])]})
	# The project's own C: every .c / .h in the folder is compiled in as it is.
	var user_c := []
	if dir != "" and DirAccess.dir_exists_absolute(dir):
		for rel in CBProject.list_assets(dir):
			var ext := rel.get_extension().to_lower()
			if ext != "c" and ext != "h":
				continue
			var fname := rel.get_file()
			if files.has(fname) or fname in RESERVED_FILES:
				errors.append({"script": "", "node": 0, "msg": "%s: a file of that name is made by C-Bricks; rename yours." % rel})
				continue
			files[fname] = FileAccess.get_file_as_string(dir.path_join(rel))
			user_c.append(rel)
			if ext == "c":
				sources.append(fname)
	# The world's built-in classes (Part, Camera...) make a project a graphics one;
	# networking's (Player, Players) a network one.
	for c in CBTypes.classes:
		if not CBTypes.is_builtin(c) and CBTypes.lineage(c).any(func(x): return CBTypes.is_world_builtin(x)):
			graphics = true
	for p in paths:
		for n in graphs[p].get("nodes", []):
			var nf: Dictionary = n.get("fields", {})
			for k in ["of", "class", "extends"]:
				if CBTypes.is_world_builtin(str(nf.get(k, ""))):
					graphics = true
	for o in all_objects:
		if CBTypes.lineage(str(o.get("class", ""))).any(func(x): return CBTypes.is_world_builtin(x)):
			graphics = true
	var order := class_order(graphics, net)
	files["cbricks.h"] = header(funcs, includes, {"exit_handlers": exits, "records": records, "constants": const_defs, "inits": inits, "graphics": graphics, "net": net, "classes": order, "world": has_world, "scenes": scenes, "gfx": gfx}, false)
	if has_world:
		var sides := {}
		for i in paths.size():
			sides[rels[i]] = str(graphs[paths[i]].get("side", "Shared"))
		files["cbricks_scene.c"] = scenes_file(scenes, main_scene, errors, script_starts, sides)
		sources.append("cbricks_scene.c")
	if mains.is_empty():
		files["cbricks_main.c"] = default_main(program, has_world, graphics)
		sources.append("cbricks_main.c")
	var backend := resolve_backend(backend_pick, target)
	if graphics:
		files["cbricks_gfx.c"] = FileAccess.get_file_as_string(GFX_RUNTIME)
		sources.append("cbricks_gfx.c")
		if backend == "dos":  # MS-DOS: its own backend (software 2D into a VGA / VESA screen), PNG reading / writing from stb
			files["cbricks_backend.c"] = "#define CB_DOS_SCREEN %d\n" % dos_screen + FileAccess.get_file_as_string(BACKENDS["dos"])
			for h in ["stb_image.h", "stb_image_write.h"]:
				files[h] = FileAccess.get_file_as_string(STB_DIR.path_join(h))
			files["cbricks_audio.h"] = dos_audio_header(dir)
		else:
			files["cbricks_backend.c"] = FileAccess.get_file_as_string(BACKENDS["raylib"])
		sources.append("cbricks_backend.c")
		var builtins_c := "/* Generated by C-Bricks: the world's built-in classes (Part, Camera...). Do not edit. */\n#include \"cbricks.h\"\n"
		for c in order:
			if CBTypes.is_world_builtin(c):
				builtins_c += class_machinery(c)
		files["cbricks_world.c"] = builtins_c
		sources.append("cbricks_world.c")
	# A network game's machines must run the same build: its id is a hash of the C.
	var build := ""
	if net:
		var names := files.keys()
		names.sort()
		var all_c := program + "\n" + version
		for fname in names:
			all_c += "\n" + str(files[fname])
		build = "%s %s %s" % [program.left(24), version.left(12), all_c.md5_text().left(12)]
		files["cbricks_socket.c"] = FileAccess.get_file_as_string(SOCKET_RUNTIME)
		sources.append("cbricks_socket.c")
	files["cbricks_runtime.c"] = runtime(program, version, rels, exits, false, inits, build, order, remotes)
	sources.append("cbricks_runtime.c")
	if true:
		files["cbricks_data.c"] = data_file(records, order)
		sources.append("cbricks_data.c")
	return {"files": files, "sources": sources, "scripts": scripts, "errors": errors, "warnings": warnings, "main": mains[0] if not mains.is_empty() else "", "records": records, "constants": constants, "user_c": user_c, "graphics": graphics, "net": net, "classes": CBTypes.classes.duplicate(true), "needs": collect_needs(paths, graphs, scenes), "backend": backend, "backend_pick": backend_pick}


## The project's audio files and the names MS-DOS plays them under (2026-11-08): entries
## {"from": path in the project, "pcm": "a0000001.wav" or "", "fm": "f0000001.imf" or "", "fm_src": path or ""}.
## A build for MS-DOS converts each WAV / OGG / MP3 (Toolchains.dos_audio) to an 8-bit, mono, 22 kHz
## WAV of that 8.3 name in audio/ beside the program, and copies each FM music file (IMF / WLF / DRO /
## VGM) there; the backend maps a brick's path to them. A music file with an FM file of the same name
## beside it (theme.ogg, theme.mid) plays the FM one (user, 2026-11-08: music on the FM chip, sounds
## as PCM); an FM file named in a brick plays on the FM chip too.
const AUDIO_EXTS := ["wav", "ogg", "oga", "mp3"]
const FM_EXTS := ["imf", "wlf", "dro", "vgm", "mid", "midi"]
static func dos_audio_list(dir: String) -> Array:
	var out := []
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return out
	var rels := Array(CBProject.list_assets(dir))
	rels.sort()
	var fm_names := {}
	var fm_files := rels.filter(func(r): return str(r).get_extension().to_lower() in FM_EXTS)
	for i in fm_files.size():
		var fe := str(fm_files[i]).get_extension().to_lower()
		fm_names[str(fm_files[i])] = "f%07d.%s" % [i + 1, "mid" if fe == "midi" else fe]
	var n := 0
	for r in rels:
		if str(r).get_extension().to_lower() not in AUDIO_EXTS:
			continue
		n += 1
		var entry := {"from": str(r), "pcm": "a%07d.wav" % n, "fm": "", "fm_src": ""}
		for ext in FM_EXTS:  # a sibling: theme.ogg + theme.imf
			var sib: String = str(r).get_basename() + "." + ext
			if fm_names.has(sib):
				entry["fm"] = fm_names[sib]
				entry["fm_src"] = sib
				break
		out.append(entry)
	for r in fm_files:
		out.append({"from": str(r), "pcm": "", "fm": fm_names[str(r)], "fm_src": str(r)})
	return out


static func dos_audio_header(dir: String) -> String:
	var from := PackedStringArray()
	var pcm := PackedStringArray()
	var fm := PackedStringArray()
	for e in dos_audio_list(dir):
		from.append(CodeGen.c_string(e.from))
		pcm.append(CodeGen.c_string(e.pcm) if e.pcm != "" else "0")
		fm.append(CodeGen.c_string(e.fm) if e.fm != "" else "0")
	from.append("0")
	pcm.append("0")
	fm.append("0")
	return "/* Generated by C-Bricks: this project's audio files, the converted PCM MS-DOS plays them as (audio/<name>, beside the program) and the FM music file that plays instead, if any. Do not edit. */\nstatic const char *const cb_dos_audio_from[] = { %s };\nstatic const char *const cb_dos_audio_pcm[] = { %s };\nstatic const char *const cb_dos_audio_fm[] = { %s };\n" % [", ".join(from), ", ".join(pcm), ", ".join(fm)]


## What each brick and scene object needs of a target (2026-11-08, the MS-DOS plan's step 3):
## [{"cap", "script", "node", "world_id", "what"}], caps as in Toolchains.caps().
static func collect_needs(paths: PackedStringArray, graphs: Dictionary, scenes: Dictionary) -> Array:
	var out := []
	for p in paths:
		for n in graphs[p].get("nodes", []):
			for c in brick_caps(str(n.type)):
				out.append({"cap": c, "script": p, "node": int(n.id), "world_id": 0, "what": "%s (node %d)" % [T.title_of(str(n.type), n.get("fields", {})), int(n.id)]})
	for srel in scenes:
		for o in scenes[srel].data.objects:
			var cls := str(o.get("class", ""))
			var line := CBTypes.lineage(cls)
			if not line.any(func(x): return CBTypes.is_world_builtin(x)) or CBTypes.is_script_object(o):
				continue
			var what := "%s: %s (%s)" % [srel, str(o.get("name", "")), cls]
			out.append({"cap": "graphics", "script": scenes[srel].path, "node": 0, "world_id": int(o.id), "what": what})
			if "Spatial3D" in line:
				out.append({"cap": "3d", "script": scenes[srel].path, "node": 0, "world_id": int(o.id), "what": what})
	return out


## What a brick needs of a target ("graphics", "3d", "network": Toolchains.caps()).
static func brick_caps(type: String) -> Array:
	var def: Dictionary = T.DEFS.get(type, {})
	var cat := str(def.get("cat", ""))
	var caps := []
	if bool(def.get("graphics", false)) or cat in ["graphics", "game", "audio", "ui", "3d"] or type in ["frame_start", "frame_end", "button_clicked", "player_key"]:
		caps.append("graphics")
	if cat == "3d":
		caps.append("3d")
	if cat == "network" or type in ["player_joined", "player_left", "player_key"]:
		caps.append("network")
	return caps


## Why the target can't do a brick ("" it can).
static func target_cant(type: String, id: String) -> String:
	var have := Toolchains.caps(id)
	var names := {"graphics": "graphics", "3d": "3D", "network": "networking"}
	for c in brick_caps(type):
		if c not in have:
			return "%s can't do %s%s: pick another Target (at the top)." % [Toolchains.target(id).name, names[c], ""]
	return ""


## Problems for what the target can't do: one per brick or object, naming it.
static func target_problems(build: Dictionary, id: String) -> Array:
	var caps := Toolchains.caps(id)
	var out := []
	var names := {"graphics": "graphics (a window, drawing, input, sound, UI, the scene)", "3d": "3D", "network": "networking"}
	if bool(build.get("graphics", false)):
		var why := backend_problem(resolve_backend(str(build.get("backend_pick", "auto")), id), id) if str(build.get("backend_pick", "auto")) != "auto" else ""
		if why != "":
			out.append({"context": true, "script": "", "node": 0, "world_id": 0, "msg": "Graphics backend: %s" % why})
	for need: Dictionary in build.get("needs", []):
		if need.cap in caps:
			continue
		out.append({"context": true, "script": need.script, "node": need.node, "world_id": need.world_id, "msg": "%s: %s can't do %s%s. Pick another target (Target, at the top)." % [need.what, Toolchains.target(id).name, names.get(need.cap, need.cap), ""]})
	return out


## Records in an order where each comes after the records it holds by value.
## main() for a project without a When program starts (Godot's way: running the project
## runs its Main scene): the world made (its Script objects' When program starts run),
## then, in a graphics project, a window (800 x 450, the project's name, 60 frames a
## second) and the Game loop until it's closed: the world runs and draws itself.
static func default_main(program: String, has_world: bool, graphics: bool) -> String:
	var lines := PackedStringArray([
		"/* Generated by C-Bricks: main() for a project with no 'When program starts' brick: it runs the",
		"   Main scene (its Script objects start when it's made)%s. Do not edit. */" % (", in a window with the Game loop" if graphics else ""),
		"#include \"cbricks.h\"",
		"",
		"int main(int argc, char **argv) {",
		"    cb_start(argc, argv);",
	])
	if has_world:
		lines.append("    cb_load_world();  /* the Main scene */")
	lines.append("    cb_ready();  /* networking's Player Joined from here */")
	if graphics:
		lines.append_array([
			"    cb_wait_hook = cb_wait_world;  /* Wait keeps the window and the world running */",
			"    cb_window_opened();",
			"    if (cb_headless) {  /* a dedicated server: no window */",
			"        cb_headless_fps(60);",
			"    } else {",
			"        if (!cb_open_window(800, 450, %s, 60, true)) { fprintf(stderr, \"couldn't open a window (no display, or its OpenGL is too old).\\n\"); exit(1); }" % CodeGen.c_string(program),
			"        if (!cb_key_hook) cb_key_hook = cb_window_key;",
			"    }",
			"    while (cb_loop_go()) {  /* the Game loop: the world's frames until the window closes */",
			"        cb_frame_begin();",
			"        cb_frame_end();",
			"    }",
			"    if (!cb_headless) cb_window_end();",
		])
	lines.append_array(["    return 0;", "}", ""])
	return "\n".join(lines)


static func record_order(records: Dictionary) -> Array:
	var out := []
	var left := records.keys()
	var progress := true
	while not left.is_empty() and progress:
		progress = false
		for r in left.duplicate():
			var ready := true
			for fld in records[r]:
				if records.has(fld[1]) and fld[1] not in out:
					ready = false
			if ready:
				out.append(r)
				left.erase(r)
				progress = true
	return out


## cbricks_data.c: each record's maker (fields at zero, its lists and texts ready) and printer.
static func data_file(records: Dictionary, classes: Array = []) -> String:
	var out := PackedStringArray(["/* Generated by C-Bricks: the project's records and lists of objects. Do not edit. */", "#include \"cbricks.h\"", ""])
	for c in [CBTypes.OBJECT] + classes:
		out.append("void cb_show_%s_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_object); }" % c)
		out.append("void cb_show_%s_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_object); }" % c)
	out.append("")
	for r in record_order(records):
		out.append("%s cb_make_%s(void) {" % [r, r])
		out.append("    %s r;" % r)
		out.append("    memset(&r, 0, sizeof r);")
		for f in records[r]:
			if f[1] == "string":
				out.append("    r.%s = \"\";" % f[0])
			elif CBTypes.needs_init(f[1]):
				out.append("    r.%s = %s;" % [f[0], CBTypes.zero(f[1])])
		out.append("    return r;")
		out.append("}")
		out.append("")
		out.append("void cb_show_%s(FILE *f, const void *value) {" % r)
		out.append("    const %s *r = (const %s *)value;" % [r, r])
		var first := true
		out.append("    fputs(\"%s(\", f);" % r)
		for f in records[r]:
			out.append("    fputs(\"%s%s: \", f);" % ["" if first else ", ", f[0]])
			first = false
			if CBTypes.is_list(f[1]):
				out.append("    cb_show_list(f, r->%s, %s);" % [f[0], CBTypes.show_fn(CBTypes.elem(f[1]))])
			elif CBTypes.is_map(f[1]):
				out.append("    cb_show_map(f, r->%s, %s);" % [f[0], CBTypes.show_fn(CBTypes.map_value(f[1]))])
			elif f[1] == "string":
				out.append("    fputc('\"', f); cb_show_string(f, &r->%s); fputc('\"', f);" % f[0])
			else:
				out.append("    %s(f, &r->%s);" % [CBTypes.show_fn(f[1]), f[0]])
		out.append("    fputc(')', f);")
		out.append("}")
		out.append("")
		out.append("void cb_show_%s_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_%s); }" % [r, r])
		out.append("void cb_show_%s_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_%s); }" % [r, r])
		out.append("")
	return "\n".join(out) + "\n"


## Writes the generated files into `out_dir` (only the ones that changed, so
## compilers and file watchers see real changes). Returns the .c paths.
static func write(result: Dictionary, out_dir: String) -> PackedStringArray:
	DirAccess.make_dir_recursive_absolute(out_dir)
	for f in DirAccess.get_files_at(out_dir):
		if (f.ends_with(".c") or f.ends_with(".h")) and not result.files.has(f):
			DirAccess.remove_absolute(out_dir.path_join(f))
	var srcs := PackedStringArray()
	for name in result.files:
		var path := out_dir.path_join(name)
		if not FileAccess.file_exists(path) or FileAccess.get_file_as_string(path) != result.files[name]:
			var fa := FileAccess.open(path, FileAccess.WRITE)
			if fa != null:
				fa.store_string(result.files[name])
				fa.close()
		if name.ends_with(".c"):
			srcs.append(path)
	return srcs


static func header(funcs: Dictionary, includes: Array, extra: Dictionary, standalone: bool) -> String:
	var lines := PackedStringArray()
	if not standalone:
		lines.append("/* Generated by C-Bricks: shared by every file of the program. Do not edit. */")
		lines.append("#ifndef CNODES_H")
		lines.append("#define CNODES_H")
	lines.append_array([
		"#if defined(_MSC_VER) && !defined(_CRT_SECURE_NO_WARNINGS)",
		"#define _CRT_SECURE_NO_WARNINGS  /* MSVC: plain scanf / fopen, no _s variants */",
		"#endif",
		"#include <stdio.h>",
		"#include <stdlib.h>",
		"#include <stdbool.h>",
		"#include <string.h>",
		"#include <stddef.h>",
		"#include <math.h>",
		"#include <time.h>",
		"#ifdef __DJGPP__  /* MS-DOS: DJGPP's libm has no C99 fmin / fmax (a Formula may use them) */",
		"static double cb_fmin(double a, double b) { return a < b || b != b ? a : b; }",
		"static double cb_fmax(double a, double b) { return a > b || b != b ? a : b; }",
		"#define fmin cb_fmin",
		"#define fmax cb_fmax",
		"#endif",
	])
	for h in includes:
		lines.append("#include %s" % h)
	if extra.get("graphics", false):
		lines.append_array([
			"/* Graphics (2026-11-08): C-Bricks' own types; only the backend (cbricks_backend.c) sees its library */",
			gfx_defines(extra.get("gfx", {})),
			"typedef struct cb_rgba { unsigned char r, g, b, a; } cb_rgba;  /* a color */",
			"typedef struct cb_rect { float x, y, width, height; } cb_rect;",
			"typedef struct cb_texture { int id; int width; int height; } cb_texture;  /* id 0: not loaded */",
			"typedef struct cb_sound { int id; unsigned int frames; } cb_sound;",
			"typedef struct cb_music { int id; float length; bool looping; } cb_music;",
			"typedef struct cb_mesh cb_mesh;",
			"enum { CB_MOUSE_LEFT = 0, CB_MOUSE_RIGHT = 1, CB_MOUSE_MIDDLE = 2 };",
			"enum {  /* keys (raylib's numbers: its backend passes them through) */",
			"    CB_KEY_NULL = 0, CB_KEY_SPACE = 32, CB_KEY_ZERO = 48, CB_KEY_ONE = 49, CB_KEY_TWO = 50, CB_KEY_THREE = 51, CB_KEY_FOUR = 52, CB_KEY_FIVE = 53,",
			"    CB_KEY_SIX = 54, CB_KEY_SEVEN = 55, CB_KEY_EIGHT = 56, CB_KEY_NINE = 57, CB_KEY_A = 65, CB_KEY_B = 66, CB_KEY_C = 67, CB_KEY_D = 68,",
			"    CB_KEY_E = 69, CB_KEY_F = 70, CB_KEY_G = 71, CB_KEY_H = 72, CB_KEY_I = 73, CB_KEY_J = 74, CB_KEY_K = 75, CB_KEY_L = 76,",
			"    CB_KEY_M = 77, CB_KEY_N = 78, CB_KEY_O = 79, CB_KEY_P = 80, CB_KEY_Q = 81, CB_KEY_R = 82, CB_KEY_S = 83, CB_KEY_T = 84,",
			"    CB_KEY_U = 85, CB_KEY_V = 86, CB_KEY_W = 87, CB_KEY_X = 88, CB_KEY_Y = 89, CB_KEY_Z = 90, CB_KEY_ESCAPE = 256, CB_KEY_ENTER = 257,",
			"    CB_KEY_TAB = 258, CB_KEY_BACKSPACE = 259, CB_KEY_RIGHT = 262, CB_KEY_LEFT = 263, CB_KEY_DOWN = 264, CB_KEY_UP = 265, CB_KEY_F1 = 290, CB_KEY_F2 = 291,",
			"    CB_KEY_F3 = 292, CB_KEY_F4 = 293, CB_KEY_F5 = 294, CB_KEY_LEFT_SHIFT = 340, CB_KEY_LEFT_CONTROL = 341,",
			"};",
		])
	lines.append_array([
		"#ifndef RL_VECTOR2_TYPE  /* raylib's Vector2's layout (a backend may include raylib.h first) */",
		"typedef struct Vector2 { float x; float y; } Vector2;",
		"#define RL_VECTOR2_TYPE",
		"#endif",
		"#ifndef RL_VECTOR3_TYPE  /* raylib's Vector3 (the same struct when raylib.h is in) */",
		"typedef struct Vector3 { float x; float y; float z; } Vector3;",
		"#define RL_VECTOR3_TYPE",
		"#endif",
		"",
		"/* C-Bricks runtime (cbricks_runtime.c) */",
		"extern bool cb_verbose;",
		"void cb_start(int argc, char **argv);",
		"typedef struct cb_var { const char *name; const char *type; const void *ptr; void (*show)(FILE *, const void *); } cb_var;",
		"typedef struct cb_frame { const cb_var *vars; int count; const cb_var *globals; int global_count; } cb_frame;",
		"void cb_trace_hit(int file, int brick, const cb_frame *frame);",
		"int cb_arg_count(void);",
		"const char *cb_arg(int index);",
		"const char *cb_option(const char *name);",
		"bool cb_flag(const char *name);",
		"const char *cb_read_file(const char *path);",
		"bool cb_write_file(const char *path, const char *text, bool append);",
		"bool cb_file_exists(const char *path);",
		"void cb_assert(bool ok, int file, int brick, const char *message);",
		"",
		"/* Memory: every string and list is kept until the program ends, then freed. */",
		"typedef struct cb_list { int count; int cap; size_t elem; char *data; struct cb_list *next_list; } cb_list;",
		"void *cb_alloc(size_t size);",
		"cb_list *cb_list_new(size_t elem);",
		"void *cb_list_add(cb_list *list);",
		"void *cb_list_insert(cb_list *list, int index, int file, int brick);",
		"void *cb_list_at(cb_list *list, int index, int file, int brick);",
		"void cb_list_remove(cb_list *list, int index, int file, int brick);",
		"void cb_list_clear(cb_list *list);",
		"void cb_list_reverse(cb_list *list);",
		"typedef struct cb_map { cb_list *keys; cb_list *values; cb_list *slots; } cb_map;",
		"cb_map *cb_map_new(size_t elem);",
		"int cb_map_find(const cb_map *map, const char *key);",
		"void *cb_map_put(cb_map *map, const char *key);",
		"void *cb_map_get(cb_map *map, const char *key, int file, int brick);",
		"void cb_map_remove(cb_map *map, const char *key);",
		"void cb_map_clear(cb_map *map);",
		"cb_list *cb_map_keys(const cb_map *map);",
		"cb_list *cb_map_values(const cb_map *map);",
		"int cb_cmp_int(const void *a, const void *b);",
		"int cb_cmp_float(const void *a, const void *b);",
		"int cb_cmp_bool(const void *a, const void *b);",
		"int cb_cmp_string(const void *a, const void *b);",
		"/* Text */",
		"const char *cb_join(const char *a, const char *b);",
		"const char *cb_format(const char *format, ...);",
		"int cb_len(const char *text);",
		"const char *cb_substr(const char *text, int start, int length);",
		"int cb_find(const char *text, const char *what);",
		"const char *cb_replace(const char *text, const char *what, const char *with);",
		"const char *cb_upper(const char *text);",
		"const char *cb_lower(const char *text);",
		"const char *cb_trim(const char *text);",
		"cb_list *cb_split(const char *text, const char *separator);",
		"const char *cb_join_list(const cb_list *list, const char *separator);",
		"int cb_to_int(const char *text);",
		"double cb_to_float(const char *text);",
		"bool cb_starts_with(const char *text, const char *what);",
		"bool cb_ends_with(const char *text, const char *what);",
		"/* Showing values (Print, the debugger) */",
		"void cb_show_int(FILE *f, const void *value);",
		"void cb_show_float(FILE *f, const void *value);",
		"void cb_show_bool(FILE *f, const void *value);",
		"void cb_show_string(FILE *f, const void *value);",
		"void cb_show_list(FILE *f, const cb_list *list, void (*show)(FILE *, const void *));",
		"/* Objects (cbricks_runtime.c): a class's fields and methods are in its script's files */",
		"typedef struct cb_field { const char *name; const char *type; size_t offset; int synced; void (*show)(FILE *, const void *); } cb_field;  /* synced: 0 no, 1 smooth, 2 jump */",
		"typedef struct cb_class { const char *name; const struct cb_class *parent; size_t size; const void *vt; const cb_field *fields; int field_count; void (*init)(void *self); void (*created)(void *self);",
		"    void (*frame)(void *self, double dt); void (*touched)(void *self, void *other); void (*drawn)(void *self); int side; void (*clicked)(void *self); int always; } cb_class;  /* side: 1 Server, 2 Client, 3 Shared; clicked: a Button's When clicked; always: its script Runs while paused */",
		"typedef struct cb_object { const cb_class *cls; int id; const char *name; struct cb_object *parent; cb_list *children; cb_list *groups; struct cb_map *meta;",
		"    int net_id; unsigned long scene_key; int owner; int scene_of; } cb_object;  /* net_id: a client's copy of the server's object number id (0: its own); scene_key: its place in the Main scene; owner: a player's number (Give to), 0 no one's; scene_of: 1 + the scene whose instance (made while running) this is the root of */",
		"void *cb_new(const cb_class *cls);",
		"void *cb_new_replica(const cb_class *cls);",
		"void *cb_obj(void *object, int file, int brick);",
		"bool cb_alive(const void *object);",
		"void cb_destroy(void *object, int file, int brick);",
		"void cb_set_parent(void *child, void *parent, int file, int brick);",
		"bool cb_is_a(const void *object, const cb_class *cls);",
		"void *cb_as(void *object, const cb_class *cls);",
		"int cb_object_count(void);",
		"cb_list *cb_children(void *object, int file, int brick);",
		"void *cb_world(void);",
		"void cb_world_adopt(void *root);",
		"void cb_on_frame(int when, int side, int always, void (*fn)(double dt));",
		"void cb_frame_events(int when, double dt, bool frozen);",
		"int cb_world_objects(void ***out);",
		"void cb_world_step(double dt, bool frozen);",
		"void *cb_find_object(const char *name);",
		"void cb_group_add(void *object, const char *group, int file, int brick);",
		"void cb_group_remove(void *object, const char *group, int file, int brick);",
		"bool cb_in_group(void *object, const char *group, int file, int brick);",
		"cb_list *cb_objects_in_group(const char *group);",
		"void cb_meta_set(void *object, const char *key, const char *value, int file, int brick);",
		"const char *cb_meta_get(void *object, const char *key, int file, int brick);",
		"bool cb_meta_has(void *object, const char *key, int file, int brick);",
		"void cb_meta_remove(void *object, const char *key, int file, int brick);",
		"void cb_scene_enter(void);",
		"void cb_scene_key_push(int id);",
		"void cb_scene_key_pop(void);",
		"void *cb_scene_new(const cb_class *cls, int id);",
		"bool cb_scene_fresh(const void *object);",
		"void cb_scene_keys(bool on);",
		"extern void *(*cb_scene_match_hook)(unsigned long key, const cb_class *cls);",
		"void cb_scene_leave(void);",
		"void cb_scene_run(void (*start)(void *parent_), void *parent);",
		"void cb_change_scene(void *(*scene)(void *parent_));",
		"void cb_world_busy(int delta);",
		"void cb_scene_pending(void);",
		"extern void (*cb_wait_hook)(double seconds);",
		"extern void (*cb_poll_hook)(void);",
		"extern void (*cb_ready_hook)(void);",
		"extern int cb_side_bits;",
		"extern int cb_online;",
		"extern double cb_world_scale;",
		"extern bool cb_headless;",
		"extern double (*cb_clock_hook)(void);",
		"double cb_now(void);",
		"bool cb_side_runs(int side);",
		"void cb_ready(void);",
		"extern void (*cb_scene_client_hook)(void *root, int scene);",
		"extern void (*cb_scene_clients_run)(int scene, void *root);",
		"void cb_scene_client(void (*start)(void *parent_), void *parent, void *root, int scene);",
		"extern int (*cb_key_hook)(int key);",
		"void cb_wait(double seconds);",
		"void cb_show_object(FILE *f, const void *value);",
		"/* Vectors */",
		"Vector3 cb_v3(double x, double y, double z);",
		"Vector3 cb_v3_add(Vector3 a, Vector3 b);",
		"Vector3 cb_v3_sub(Vector3 a, Vector3 b);",
		"Vector3 cb_v3_scale(Vector3 a, double k);",
		"double cb_v3_length(Vector3 a);",
		"Vector3 cb_v3_normalize(Vector3 a);",
		"Vector3 cb_v3_lerp(Vector3 a, Vector3 b, double t);",
		"double cb_v3_dot(Vector3 a, Vector3 b);",
		"Vector3 cb_v3_cross(Vector3 a, Vector3 b);",
		"const char *cb_v3_text(Vector3 a);",
		"void cb_show_vector3(FILE *f, const void *value);",
		"void cb_show_vector3_list(FILE *f, const void *value);",
		"void cb_show_vector3_map(FILE *f, const void *value);",
		"Vector2 cb_v2(double x, double y);",
		"Vector2 cb_v2_add(Vector2 a, Vector2 b);",
		"Vector2 cb_v2_sub(Vector2 a, Vector2 b);",
		"Vector2 cb_v2_scale(Vector2 a, double k);",
		"double cb_v2_length(Vector2 a);",
		"Vector2 cb_v2_normalize(Vector2 a);",
		"Vector2 cb_v2_lerp(Vector2 a, Vector2 b, double t);",
		"double cb_v2_dot(Vector2 a, Vector2 b);",
		"double cb_v2_cross(Vector2 a, Vector2 b);",
		"const char *cb_v2_text(Vector2 a);",
		"void cb_show_vector2(FILE *f, const void *value);",
		"void cb_show_vector2_list(FILE *f, const void *value);",
		"void cb_show_vector2_map(FILE *f, const void *value);",
		"void cb_show_map(FILE *f, const cb_map *map, void (*show)(FILE *, const void *));",
		"/* System */",
		"void cb_sleep_ms(int ms);",
		"const char *cb_env(const char *name);",
		"int cb_run(const char *command);",
		"void cb_show_int_list(FILE *f, const void *value);",
		"void cb_show_float_list(FILE *f, const void *value);",
		"void cb_show_bool_list(FILE *f, const void *value);",
		"void cb_show_string_list(FILE *f, const void *value);",
		"void cb_show_int_map(FILE *f, const void *value);",
		"void cb_show_float_map(FILE *f, const void *value);",
		"void cb_show_bool_map(FILE *f, const void *value);",
		"void cb_show_string_map(FILE *f, const void *value);",
		"/* Before every brick: trace, step counting, the debugger (each function has a cb_here_ frame). */",
		"#ifdef CB_NO_TRACE",
		"#define CB_TRACE(file, brick) ((void)cb_here_)",
		"#else",
		"#define CB_TRACE(file, brick) cb_trace_hit((file), (brick), &cb_here_)",
		"#endif",
	])
	if extra.get("graphics", false):
		lines.append_array([
			"/* Graphics bricks (cbricks_gfx.c) */",
			"cb_rgba cb_color(const char *name);",
			"void cb_show_texture(FILE *f, const void *value);",
			"void cb_show_sound(FILE *f, const void *value);",
			"void cb_show_music(FILE *f, const void *value);",
			"bool cb_open_window(int width, int height, const char *title, int fps, bool esc_closes);",
			"void cb_window_end(void);",
			"void cb_clear(cb_rgba c);",
			"void cb_draw_rect(int x, int y, int width, int height, cb_rgba c);",
			"void cb_draw_rect_lines(int x, int y, int width, int height, cb_rgba c);",
			"void cb_draw_circle(int x, int y, double radius, cb_rgba c);",
			"void cb_draw_line(int x1, int y1, int x2, int y2, cb_rgba c);",
			"void cb_draw_text(const char *text, int x, int y, int size, cb_rgba c);",
			"void cb_draw_texture(cb_texture t, int x, int y, cb_rgba tint);",
			"cb_texture cb_load_texture(const char *path);",
			"cb_sound cb_sound_load(const char *path);",
			"void cb_sound_play(cb_sound s);",
			"void cb_music_pause(cb_music m);",
			"void cb_music_resume(cb_music m);",
			"void cb_music_volume(cb_music m, double volume);",
			"bool cb_music_playing(cb_music m);",
			"bool cb_key_down(int key);",
			"bool cb_key_pressed(int key);",
			"bool cb_key_released(int key);",
			"bool cb_mouse_down(int button);",
			"bool cb_mouse_pressed(int button);",
			"int cb_mouse_x(void);",
			"int cb_mouse_y(void);",
			"double cb_mouse_wheel(void);",
			"void cb_cursor(int mode);",
			"int cb_screen_width(void);",
			"int cb_screen_height(void);",
			"int cb_fps(void);",
			"void cb_draw_line3d(Vector3 a, Vector3 b, cb_rgba c);",
			"void cb_draw_grid(int lines, double spacing);",
			"void cb_draw_wire_box(Vector3 at, Vector3 size, cb_rgba c);",
			"void cb_camera(Vector3 position, Vector3 target, double fov, bool ortho);",
			"void cb_begin_3d(void);",
			"void cb_end_3d(void);",
			"/* 3D, meshes, lights (the backend) */",
			"double cb_shake_remaining(void);  /* seconds of Shake Camera left (tests) */",
			"void cb_draw_shape(int kind, Vector3 at, Vector3 size, double turn, cb_rgba color);",
			"cb_mesh *cb_mesh_new(void);",
			"cb_mesh *cb_mesh_begin(cb_mesh *mesh);",
			"/* front = the side where a, b, c go round CLOCKWISE (Add to mesh: (0,0,0) (1,0,0) (0,0,1) faces up) */",
			"void cb_mesh_triangle(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, cb_rgba color);",
			"void cb_mesh_quad(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, Vector3 d, cb_rgba color);",
			"void cb_mesh_shape(cb_mesh *mesh, int kind, Vector3 at, Vector3 size, cb_rgba color);",
			"void cb_mesh_finish(cb_mesh *mesh, bool smooth, bool both_sides, int file, int brick);",
			"void cb_draw_mesh(cb_mesh *mesh, Vector3 at, Vector3 size, double turn, cb_rgba tint);",
			"void cb_show_mesh(FILE *f, const void *value);",
			"void cb_set_light(Vector3 direction, double ambient);",
			"void cb_set_light_color(cb_rgba color, double energy);",
			"void cb_set_fog(cb_rgba color, double density);",
			"void cb_set_ambient(cb_rgba color, double fog_start);",
			"void cb_be_post(double vignette, double scanlines, double grain, double posterize, double bloom, double curve, double outline, double dither, double snap);",
			"void cb_be_set_look(int what, int value);",
			"int cb_be_splat_mode(void);",
			"void cb_graphics_setting(int what, int value);  /* 0 shading (lit toon unlit wire), 1 splatting (off mixed full), 2 pixel size */",
			"/* The backend (cbricks_backend.c): what a graphics library does for C-Bricks. */",
			"bool cb_be_open(int width, int height, const char *title, int fps, bool esc_closes);",
			"void cb_be_close(void);",
			"bool cb_be_should_close(void);",
			"bool cb_be_ready(void);",
			"void cb_be_begin_frame(void);",
			"void cb_be_end_frame(void);",
			"void cb_be_flush(void);",
			"int cb_be_width(void);",
			"int cb_be_height(void);",
			"int cb_be_fps(void);",
			"double cb_be_frame_time(void);",
			"double cb_be_time(void);",
			"bool cb_be_screenshot(const char *path);",
			"bool cb_be_key_down(int key);",
			"bool cb_be_key_pressed(int key);",
			"bool cb_be_key_released(int key);",
			"bool cb_be_mouse_down(int button);",
			"bool cb_be_mouse_pressed(int button);",
			"bool cb_be_mouse_released(int button);",
			"Vector2 cb_be_mouse_pos(void);",
			"Vector2 cb_be_mouse_delta(void);",
			"double cb_be_mouse_wheel(void);",
			"void cb_be_cursor(int mode);",
			"bool cb_be_cursor_hidden(void);",
			"void cb_be_clear(cb_rgba c);",
			"void cb_be_rect(cb_rect r, Vector2 origin, double rotation, cb_rgba c);",
			"void cb_be_rect_lines(cb_rect r, double thick, cb_rgba c);",
			"void cb_be_rect_rounded(cb_rect r, double roundness, cb_rgba c);",
			"void cb_be_rect_rounded_lines(cb_rect r, double roundness, double thick, cb_rgba c);",
			"void cb_be_circle(Vector2 at, double radius, cb_rgba c);",
			"void cb_be_line(Vector2 a, Vector2 b, cb_rgba c);",
			"void cb_be_gradient_v(cb_rect r, cb_rgba top, cb_rgba bottom);",
			"void cb_be_text(const char *text, Vector2 at, Vector2 origin, double rotation, double size, cb_rgba c);",
			"Vector2 cb_be_text_size(const char *text, double size);",
			"void cb_be_begin_2d(Vector2 center, double zoom, double rotation);",
			"void cb_be_end_2d(void);",
			"cb_texture cb_be_texture_load(const char *path);",
			"void cb_be_texture(cb_texture t, cb_rect src, cb_rect dst, Vector2 origin, double rotation, cb_rgba tint);",
			"cb_sound cb_be_sound_load(const char *path);",
			"void cb_be_sound_play(cb_sound s);",
			"cb_music cb_be_music_load(const char *path, bool loop);",
			"void cb_be_music_play(cb_music m);",
			"void cb_be_music_stop(cb_music m);",
			"void cb_be_music_pause(cb_music m);",
			"void cb_be_music_resume(cb_music m);",
			"void cb_be_music_volume(cb_music m, double volume);",
			"bool cb_be_music_playing(cb_music m);",
			"void cb_be_music_update(void);",
			"void cb_be_music_forget_all(void);",
			"void cb_be_begin_3d(Vector3 position, Vector3 target, double fov, bool ortho);",
			"void cb_be_splat(bool on);  /* the shapes / meshes drawn next are point splats (an object's splat field, or Full splatting) */",
			"void cb_be_end_3d(void);",
			"void cb_be_push(void);",
			"void cb_be_pop(void);",
			"void cb_be_translate(double x, double y, double z);",
			"void cb_be_rotate(double degrees, double x, double y, double z);",
			"void cb_be_scale(double x, double y, double z);",
			"void cb_be_line3d(Vector3 a, Vector3 b, cb_rgba c);",
			"void cb_be_grid(int lines, double spacing);",
			"void cb_be_wire_box(Vector3 at, Vector3 size, cb_rgba c);",
			"void cb_be_target_begin(int width, int height);",
			"void cb_be_target_end(void);",
			"bool cb_be_target_save(const char *path);",
			"cb_texture cb_be_target_texture(void);",
			"void cb_be_target_free(void);",
			"/* The world (cbricks_gfx.c): run by the Game loop */",
			"void cb_world_physics(double dt);",
			"void cb_frame_begin(void);",
			"void cb_frame_end(void);",
			"void cb_wait_world(double seconds);",
			"void cb_headless_fps(int fps);",
			"int cb_window_key(int key);",
			"bool cb_headless_frame(void);",
			"void cb_close_window(void);",
			"void cb_pause(bool on);",
			"bool cb_is_paused(void);",
			"void cb_set_time_scale(double scale);",
			"double cb_get_time_scale(void);",
			"void cb_on_click(int side, const char *name, void (*fn)(void *button));",
			"bool cb_mouse_over_ui(void);",
			"bool cb_screenshot(const char *path);",
			"extern const char *cb_click_spec;",
			"void cb_window_opened(void);",
			"bool cb_loop_go(void);",
			"double cb_frame_time(void);",
			"double cb_game_time(void);",
			"void cb_world_draw(void);",
			"void *cb_raycast(Vector3 from, Vector3 to, void *ignore, Vector3 *point, Vector3 *normal, double *distance);",
			"bool cb_move_collide(void *part, Vector3 motion, int file, int brick);",
			"Vector2 cb_key_direction(bool left, bool right, bool forward, bool back);",
			"void cb_capture_mouse(void);",
			"Vector2 cb_mouse_motion(void);",
			"bool cb_can_see(void *who, void *target, double range, double view, int file, int brick);",
			"void *cb_nearest(const cb_class *cls, Vector3 from, double range, void *except, double *distance);",
			"void cb_shake(double strength, double duration);",
			"bool cb_snapshot_file(void *camera, int width, int height, bool transparent, void *subject, const char *path, int file, int brick);",
			"cb_texture cb_snapshot_texture(void *camera, int width, int height, bool transparent, void *subject, int file, int brick);",
			"/* 2D drawing (cbricks_gfx.c): turned shapes, sprite sheets, the 2D view, music */",
			"void cb_draw_rect_turned(int x, int y, int width, int height, double rotation, cb_rgba color);",
			"void cb_draw_text_turned(const char *text, int x, int y, int size, double rotation, cb_rgba color);",
			"void cb_draw_sprite(cb_texture texture, int x, int y, int frame, int columns, int rows, double scale, double rotation, cb_rgba tint);",
			"void cb_begin_2d(Vector2 center, double zoom, double rotation);",
			"void cb_end_2d(void);",
			"cb_music cb_music_load(const char *path, bool loop);",
			"void cb_music_play(cb_music music);",
			"void cb_music_stop(cb_music music);",
			"/* Mesh points (cbricks_gfx.c): a vector3 list */",
			"cb_list *cb_mesh_points(const cb_mesh *mesh);",
			"void cb_mesh_set_points(cb_mesh *mesh, const cb_list *points, int file, int brick);",
		])
	for c in extra.get("constants", []):
		lines.append("#define %s (%s)" % [c[0], c[1]])
	var cls: Array = extra.get("classes", [])
	if not standalone:
		lines.append("")
		lines.append("/* Objects: every class starts with its parent (Object: cb_object) */")
		lines.append("typedef cb_object Node;")
		lines.append("extern const cb_class Node_class;")
		lines.append("void cb_show_Node_list(FILE *f, const void *value);")
		lines.append("void cb_show_Node_map(FILE *f, const void *value);")
		for c in cls:
			lines.append("typedef struct %s %s;" % [CBTypes.cname(c), CBTypes.cname(c)])
	var recs: Dictionary = extra.get("records", {})
	if not recs.is_empty():
		lines.append("")
		lines.append("/* The project's records (cbricks_data.c makes and shows them) */")
		for r in record_order(recs):
			lines.append("typedef struct %s {" % r)
			for f in recs[r]:
				lines.append("    %s %s;" % [CBTypes.c_type(f[1]), f[0]])
			lines.append("} %s;" % r)
			lines.append("%s cb_make_%s(void);" % [r, r])
			lines.append("void cb_show_%s(FILE *f, const void *value);" % r)
			lines.append("void cb_show_%s_list(FILE *f, const void *value);" % r)
			lines.append("void cb_show_%s_map(FILE *f, const void *value);" % r)
	for c in cls:
		lines.append_array(class_declarations(c))
	if extra.get("net", false):
		lines.append_array([
			"",
			"/* Networking (cbricks_runtime.c: cb_net.c; the socket in cbricks_socket.c) */",
			"void cb_net_init(const char *build);",
			"void cb_net_option(const char *flag, const char *value);",
			"void cb_net_poll(void);",
			"void cb_net_on_player(bool joined, int side, void (*fn)(int player));",
			"bool cb_net_host(int port);",
			"bool cb_net_join(const char *address, int port, double timeout);",
			"void cb_net_leave(void);",
			"const char *cb_net_role_name(void);",
			"bool cb_net_is_server(void);",
			"/* Players are numbers (the host, or you offline, is 1; 0: none) */",
			"int cb_net_me(void);",
			"bool cb_net_in_game(int player);",
			"const char *cb_net_player_name(int player);",
			"cb_list *cb_net_players(void);",
			"int cb_net_player_here(void *parent, int file, int brick);",
			"int cb_net_player_soft(void *start);",
			"/* Remotes: Fire writes the values, then sends; a handler reads them in order */",
			"void cb_net_on_remote(int remote, int side, void (*fn)(int sender));",
			"void cb_msg_begin(int remote);",
			"void cb_msg_put_int(int v);",
			"void cb_msg_put_float(double v);",
			"void cb_msg_put_bool(bool v);",
			"void cb_msg_put_text(const char *v);",
			"void cb_msg_put_v3(Vector3 v);",
			"void cb_msg_put_v2(Vector2 v);",
			"void cb_msg_put_object(const void *v);",
			"void cb_net_fire_server(int file, int brick);",
			"bool cb_net_invoke(double timeout, int file, int brick);",
			"void cb_answer_begin(void);",
			"void cb_net_answer(int file, int brick);",
			"void cb_net_fire_clients(int player, bool all, int file, int brick);",
			"int cb_msg_int(void);",
			"double cb_msg_float(void);",
			"bool cb_msg_bool(void);",
			"const char *cb_msg_text(void);",
			"Vector3 cb_msg_v3(void);",
			"Vector2 cb_msg_v2(void);",
			"void *cb_msg_object(const cb_class *cls);",
			"/* Players' keys (Player Key / Player Input) and ownership (Give to / Owner / Mine?) */",
			"void cb_net_on_key(int key, bool pressed, void (*fn)(int player));",
			"bool cb_net_key_held(int player, int key, int file, int brick);",
			"void cb_net_give(void *object, int player, int file, int brick);",
			"int cb_net_owner(void *object, int file, int brick);",
			"cb_list *cb_net_owned_by(int player);",
			"bool cb_net_mine(void *object, int file, int brick);",
		])
	for i in extra.get("inits", []):
		lines.append("void %s(void);" % i)
	if extra.get("world", false):
		lines.append("void cb_load_world(void);  /* the Main scene's objects (cbricks_scene.c) */")
		var sc: Dictionary = extra.get("scenes", {})
		for rel in sc:
			lines.append("void *%s(void *parent_);  /* %s: makes its objects under parent_, gives its root */" % [sc[rel].fn, rel])
	if not funcs.is_empty() or not extra.get("exit_handlers", []).is_empty():
		lines.append("")
		lines.append("/* The program's functions */")
		for fname in funcs:
			var params := {}
			for p in funcs[fname].params:
				params[p[1]] = p[0]
			lines.append(CodeGen.signature(fname, funcs[fname].returns, params) + ";")
		for e in extra.get("exit_handlers", []):
			lines.append("void %s(void);" % e)
	if not standalone:
		lines.append("")
		lines.append("#endif")
	return "\n".join(lines) + "\n"


static func runtime(program: String, version: String, scripts: Array, exits: Array, standalone: bool, inits: Array = [], net_build := "", classes: Array = [], remotes: Dictionary = {}) -> String:
	var dirs := []  # each remote's ways, by its number: 1 to the server, 2 to clients
	dirs.resize(remotes.size())
	for rn in remotes:
		dirs[int(remotes[rn].index)] = {"To server": 1, "To clients": 2, "Ask server": 4}.get(str(remotes[rn].direction), 3)
	var files := PackedStringArray()
	for r in scripts:
		files.append(CodeGen.c_string(str(r)))
	var help := PackedStringArray()
	for f in FLAGS + (NET_FLAGS if net_build != "" else []):
		help.append("    \"  %-15s %s\\n\"" % [f[0], f[1]])
	var regs := PackedStringArray()
	for i in range(exits.size() - 1, -1, -1):
		regs.append("    atexit(%s);" % exits[i])
	for f in inits:
		regs.append("    %s();" % f)
	if net_build != "":
		regs.append("    cb_net_init(%s);  /* the role the flags ask for; you are player 1 offline */" % CodeGen.c_string(net_build))
	var text := "\n".join(PackedStringArray([
		"/* C-Bricks runtime, generated part: this program's name, scripts and start-up. */",
		"#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)",
		"#define _POSIX_C_SOURCE 200809L  /* nanosleep, chdir */",
		"#endif",
		"" if standalone else "#include \"cbricks.h\"",
		"#define CB_NET 1  /* this program uses networking: --host, --server, --join, --name */" if net_build != "" else "",
		"",
		"static const char *cb_program = %s;" % CodeGen.c_string(program),
		"static const char *cb_version = %s;" % CodeGen.c_string(version),
		"static const char *cb_files[] = { %s };" % ", ".join(files),
		"static const char *cb_help =",
		"\n".join(help) + ";",
		"",
		("/* Every class, for networking (a class is sent as its number here). */\nstatic const cb_class *const cb_net_classes[] = { &Node_class%s };\nstatic const int cb_net_class_count = %d;\n/* Every remote's ways (by its number): 1 to the server, 2 to clients, 3 both, 4 a question to the server (Invoke). */\nstatic const int cb_net_remote_ways[] = { %s };\nstatic const int cb_net_remote_count = %d;\n/* The keys players' machines send (Player Key / Player Input), by their place. */\nstatic const int cb_net_keys[] = { %s };\nstatic const char *const cb_net_key_names[] = { %s };\nstatic const int cb_net_key_count = %d;\n" % ["".join(classes.map(func(c): return ", &%s_class" % CBTypes.cname(c))), classes.size() + 1, ", ".join(dirs.map(func(x): return str(x))) if not dirs.is_empty() else "0", dirs.size(), ", ".join(CBTypes.net_keys.map(func(k): return "CB_KEY_" + str(k))) if not CBTypes.net_keys.is_empty() else "0", ", ".join(CBTypes.net_keys.map(func(k): return "\"%s\"" % k)) if not CBTypes.net_keys.is_empty() else "\"\"", CBTypes.net_keys.size()]) if net_build != "" else "",
		"/* Each file's global lists / records, and When program ends (cb_start calls it). */",
		"static void cb_register(void) {",
		"\n".join(regs) if not regs.is_empty() else "    /* nothing */",
		"}",
		"",
	]))
	text += "\n" + FileAccess.get_file_as_string(CORE_RUNTIME) + FileAccess.get_file_as_string(DATA_RUNTIME) + FileAccess.get_file_as_string(OBJECT_RUNTIME)
	if net_build != "":
		text += FileAccess.get_file_as_string(NET_RUNTIME)
	return text


## Project Settings > Graphics as C defines (cbricks.h): the raylib backend reads them (the MS-DOS one ignores them).
static func gfx_defines(g: Dictionary) -> String:
	var d := CBProject.graphics_settings(ConfigFile.new())
	d.merge(g, true)
	return "\n".join([
		"/* Graphics settings (Project Settings > Graphics) */",
		"#define CB_SHADING %d  /* 0 lit, 1 toon, 2 unlit, 3 wireframe */" % CBProject.SHADINGS.find(d.shading),
		"#define CB_SPLAT %d  /* 0 no splatting, 1 mixed (an object's splat field), 2 full */" % CBProject.SPLATS.find(d.splat),
		"#define CB_SPLAT_SIZE %s  /* world units across */" % String.num(d.splat_size, 4),
		"#define CB_SPLAT_DENSITY %s  /* points per square world unit */" % String.num(d.splat_density, 2),
		"#define CB_SPLAT_ROUND %d" % (1 if d.splat_shape == "round" else 0),
		"#define CB_PIXEL %d  /* low-res: window pixels per drawn pixel */" % int(d.pixel),
		"#define CB_MSAA %d" % (1 if d.msaa else 0),
		"#define CB_VSYNC %d" % (1 if d.vsync else 0),
		"#define CB_WINDOW %d  /* 0 fixed, 1 resizable, 2 fullscreen, 3 borderless */" % CBProject.WINDOWS.find(d.window),
	])


## Colors and handle printing for graphics projects (the backend draws them).
const GFX_RUNTIME := "res://scripts/runtime/cb_gfx.c"
## Graphics backends (2026-11-08): the one file that talks to a graphics library.
## The graphics backends (Project Settings ▸ Graphics backend): id -> [name, the targets it can build for ("" = every
## target but the ones another backend owns)]. "auto" picks by target.
const BACKEND_NAMES := {"auto": "Automatic (by target)", "raylib": "raylib (window, OpenGL)", "dos": "MS-DOS software renderer (VGA / VESA)"}


## The backend a build uses: the project's pick, else the target's own.
static func resolve_backend(pick: String, target: String) -> String:
	if pick in ["raylib", "dos"]:
		return pick
	return "dos" if target == "dos" else "raylib"


## Why a backend can't build for a target ("" if it can).
static func backend_problem(backend: String, target: String) -> String:
	if backend == "dos" and target != "dos":
		return "the MS-DOS software renderer only builds for the MS-DOS target (DJGPP): pick Automatic or raylib in Project Settings ▸ Graphics backend, or change the Target."
	if backend == "raylib" and target == "dos":
		return "raylib has no MS-DOS port: pick Automatic or the MS-DOS software renderer in Project Settings ▸ Graphics backend, or change the Target."
	return ""


const BACKENDS := {"raylib": "res://scripts/runtime/cb_be_raylib.c", "dos": "res://scripts/runtime/cb_be_dos.c"}
const STB_DIR := "res://thirdparty/raylib/src/external"

## Flags, arguments, files, asserts, trace, the debugger: plain C, after the generated part.
const CORE_RUNTIME := "res://scripts/runtime/cb_runtime.c"
## Memory, lists, text, value printing and system calls: plain C, appended to the runtime.
const DATA_RUNTIME := "res://scripts/runtime/cb_data.c"
## Objects: classes' instances, New / Destroy, the live table (appended after cb_data.c).
const OBJECT_RUNTIME := "res://scripts/runtime/cb_object.c"
## Networking: roles, players, the protocol (appended after cb_object.c in network projects).
const NET_RUNTIME := "res://scripts/runtime/cb_net.c"
## Networking: the UDP socket and a clock, its own file (cbricks_socket.c): the OS headers stay apart.
const SOCKET_RUNTIME := "res://scripts/runtime/cb_socket.c"
## File names C-Bricks makes: a project's own .c / .h can't use them.
const RESERVED_FILES := ["cbricks.h", "cbricks_runtime.c", "cbricks_data.c", "cbricks_gfx.c", "cbricks_world.c", "cbricks_scene.c", "cbricks_socket.c"]


# ------------------------------------------------------------------ classes

## Finds the class scripts (a Class brick each) and fills CBTypes.classes.
## Returns {script path: class name}.
static func collect_classes(dir: String, paths: PackedStringArray, graphs: Dictionary, errors: Array) -> Dictionary:
	CBTypes.classes = CBTypes.builtin_entries()
	var class_of := {}
	for p in paths:
		var nodes: Array = graphs[p].get("nodes", [])
		var decl: Dictionary = {}
		for n in nodes:
			if n.type == "class":
				decl = n
		if decl.is_empty():
			continue
		var f: Dictionary = decl.get("fields", {})
		var cname := str(f.get("name", "")).strip_edges()
		var title := "Class (node %d)" % int(decl.id)
		if not cname.is_valid_identifier() or CBTypes.is_basic(cname) or cname.begins_with("cb_") or cname in [CBTypes.OBJECT, CBTypes.VECTOR, CBTypes.MESH, "main"] or CBTypes.HANDLES.has(cname):
			errors.append({"script": p, "node": int(decl.id), "msg": "%s: '%s' can't be a class name (letters, digits and _)." % [title, cname]})
			continue
		if CBTypes.is_world_builtin(cname):
			errors.append({"script": p, "node": int(decl.id), "msg": "%s: '%s' is a built-in class of the world: extend it instead (Extends %s)." % [title, cname, cname]})
			continue
		if CBTypes.classes.has(cname):
			errors.append({"script": p, "node": int(decl.id), "msg": "%s: there's already a class named '%s' (%s)." % [title, cname, CBProject.rel_path(dir, CBTypes.classes[cname].script)]})
			continue
		var info := {"extends": str(f.get("extends", CBTypes.OBJECT)).strip_edges(), "fields": [], "synced": [], "script": p, "node": int(decl.id), "methods": {}, "created": false, "side": str(graphs[p].get("side", "Shared")), "always": bool(graphs[p].get("always", false))}
		if info.extends == "":
			info.extends = CBTypes.OBJECT
		for fp in T.parse_params(f.get("fields", [])):
			info.fields.append([fp[1], fp[0]])
		for sname in str(f.get("synced", "")).split(",", false):
			info.synced.append(sname.strip_edges())
		for n in nodes:
			if n.type == "function":
				var fname := str(n.fields.get("name", ""))
				var fi: Dictionary = T.collect_functions([n]).get(fname, {})
				if fname.begins_with("on_") and fname in CBTypes.EVENTS.values().map(func(e): return e[0]):
					errors.append({"script": p, "node": int(n.id), "msg": "Define Function (node %d): '%s' is the name of an object event's method: use the %s brick, or another name." % [int(n.id), fname, {"on_frame": "Every frame", "on_touched": "When touched", "on_drawn": "When drawn", "on_clicked": "When clicked"}[fname]]})
					continue
				if not fi.is_empty():
					info.methods[fname] = fi
			elif n.type == "created":
				info.created = true
			elif CBTypes.EVENTS.has(n.type):
				var ev: Array = CBTypes.EVENTS[n.type]
				info.methods[ev[0]] = {"params": ev[1], "returns": "void", "event": true}
		CBTypes.classes[cname] = info
		class_of[p] = cname
	return class_of


const RESERVED_FIELDS := ["base", "cls", "id", "name", "parent", "children", "self", "self_", "vt"]


## Class problems that need every class and record known: parents, fields, overrides.
static func check_classes(records: Dictionary, errors: Array) -> void:
	for c in CBTypes.classes:
		var info: Dictionary = CBTypes.classes[c]
		if info.get("builtin", false):
			continue
		var where := {"script": info.script, "node": info.node}
		var e := func(msg: String) -> void: errors.append({"script": where.script, "node": where.node, "msg": "Class %s: %s" % [c, msg]})
		if info.extends != CBTypes.OBJECT and not CBTypes.classes.has(info.extends):
			e.call("it extends '%s', which isn't a class." % info.extends)
			continue
		if c in CBTypes.lineage(info.extends):
			e.call("its parents lead back to itself (%s)." % " > ".join(CBTypes.lineage(info.extends)))
			continue
		var parent_fields := {}
		for pf in CBTypes.all_fields(info.extends):
			parent_fields[pf[0]] = pf[2]
		for fld in info.fields:
			if fld[0] in RESERVED_FIELDS:
				e.call("'%s' can't be a field's name (every object has it: base, cls, id, name, parent, children, self)." % fld[0])
			elif parent_fields.has(fld[0]):
				e.call("field '%s' is already a field of %s." % [fld[0], parent_fields[fld[0]]])
			elif not CBTypes.valid(fld[1], records):
				e.call("field '%s' has an unknown type '%s'." % [fld[0], fld[1]])
		var names := CBTypes.all_fields(c).map(func(x): return x[0])
		for sname in info.synced:
			var bare := str(sname).trim_suffix("!")
			if bare not in names:
				e.call("Synced names '%s', which isn't one of its fields." % bare)
				continue
			var fty := ""
			for fx in CBTypes.all_fields(c):
				if fx[0] == bare:
					fty = fx[1]
			if not (CBTypes.is_basic(fty) or CBTypes.is_vector(fty) or CBTypes.is_vector2(fty) or CBTypes.is_class_type(fty)):
				e.call("Synced field '%s' (%s): networking sends numbers, bools, text, vectors and objects (not lists, maps or records yet)." % [bare, fty])
		var inherited := CBTypes.all_methods(info.extends)
		for m in info.methods:
			if inherited.has(m):
				var mine: Dictionary = info.methods[m]
				var theirs: Dictionary = inherited[m]
				if str(mine.params) != str(theirs.params) or mine.returns != theirs.returns:
					e.call("its method '%s' replaces %s's, so it needs the same inputs and Gives back." % [m, theirs.declared])


## Classes, each after its parent (the world's built-in ones only for graphics projects,
## networking's for network projects).
static func class_order(builtins := false, _net := false) -> Array:  # (_net: networking has no built-in classes now)
	var out := []
	var names := CBTypes.classes.keys().filter(func(c): return (builtins and CBTypes.is_world_builtin(c)) or not CBTypes.is_builtin(c))
	names.sort()
	var progress := true
	while progress:
		progress = false
		for c in names:
			if c in out:
				continue
			var parent := str(CBTypes.classes[c].extends)
			if parent == CBTypes.OBJECT or parent in out:
				out.append(c)
				progress = true
			elif not CBTypes.classes.has(parent):
				progress = progress  # an unknown parent: reported by check_classes
	return out


## A method's C name: "Enemy_hit"; its signature takes the object as void *self_.
static func method_signature(cls: String, m: String, info: Dictionary, name_only := false) -> String:
	var plist := ["void *self_"]
	for p in info.params:
		if info.get("event", false) and CBTypes.is_class_type(p[0]):
			plist.append("void *%s_" % p[1])  # the runtime's hook type; cast inside
		else:
			plist.append("%s %s" % [CBTypes.c_type(p[0]), p[1]])
	return "%s %s_%s(%s)" % [CBTypes.c_type(info.returns), CBTypes.cname(cls), m, ", ".join(plist)]


## cbricks.h for one class: its struct, its function table, its methods.
static func class_declarations(c: String) -> PackedStringArray:
	var info: Dictionary = CBTypes.classes[c]
	var out := PackedStringArray([""])
	out.append("struct %s {  /* class %s */" % [CBTypes.cname(c), c])
	out.append("    %s base;  /* %s */" % [CBTypes.cname(info.extends), info.extends])
	for fld in info.fields:
		out.append("    %s f_%s;" % [CBTypes.c_type(fld[1]), fld[0]])  # f_: no #define of a field name reaches it
	out.append("};")
	# The function table: the parent's first, then the methods this class adds.
	var own_new := []
	var inherited := CBTypes.all_methods(info.extends) if info.extends != CBTypes.OBJECT else {}
	for m in info.methods:
		if not inherited.has(m):
			own_new.append(m)
	var cc := CBTypes.cname(c)
	out.append("typedef struct %s_vt {" % cc)
	if info.extends != CBTypes.OBJECT:
		out.append("    %s_vt base;" % CBTypes.cname(info.extends))
	for m in own_new:
		var mi: Dictionary = info.methods[m]
		var plist := ["void *self"]
		for p in mi.params:
			plist.append("void *%s" % p[1] if mi.get("event", false) and CBTypes.is_class_type(p[0]) else "%s %s" % [CBTypes.c_type(p[0]), p[1]])
		out.append("    %s (*%s)(%s);" % [CBTypes.c_type(mi.returns), m, ", ".join(plist)])
	if info.extends == CBTypes.OBJECT and own_new.is_empty():
		out.append("    char cb_none_;  /* no methods */")
	out.append("} %s_vt;" % cc)
	out.append("extern const cb_class %s_class;" % cc)
	out.append("void cb_show_%s_list(FILE *f, const void *value);" % c)
	out.append("void cb_show_%s_map(FILE *f, const void *value);" % c)
	for m in info.methods:
		out.append(method_signature(c, m, info.methods[m]) + ";")
	return out


## Appended to a class's own .c: its fields' table, its setup, its function table and its class.
static func class_machinery(c: String) -> String:
	var info: Dictionary = CBTypes.classes[c]
	var out := PackedStringArray(["", "/* ---- class %s (extends %s) ---- */" % [c, info.extends]])
	# fields: name, type, where, synced, printer
	var entries := []
	for fld in info.fields:
		var how := 2 if (fld[0] + "!") in info.synced else (1 if fld[0] in info.synced else 0)  # name! : jumps, never glides
		entries.append("{ \"%s\", \"%s\", offsetof(%s, f_%s), %d, %s }" % [fld[0], fld[1], CBTypes.cname(c), fld[0], how, CBTypes.show_fn(fld[1])])
	if not entries.is_empty():
		out.append("static const cb_field %s_fields_[] = {\n    %s\n};" % [CBTypes.cname(c), ",\n    ".join(entries)])
	# setup: fresh values the zeroed memory doesn't give (text, lists, maps, records)
	var inits := []
	for fld in info.fields:
		var dflt := str(fld[2]) if fld.size() > 2 else ""
		if dflt != "" and (CBTypes.is_basic(fld[1]) or CBTypes.is_vector(fld[1]) or CBTypes.is_vector2(fld[1])):
			inits.append("    self->f_%s = %s;" % [fld[0], CodeGen.literal(dflt, T.type_from_name(fld[1]))[0]])
		elif fld[1] == "string":
			inits.append("    self->f_%s = \"\";" % fld[0])
		elif CBTypes.needs_init(fld[1]):
			inits.append("    self->f_%s = %s;" % [fld[0], CBTypes.zero(fld[1])])
	if not inits.is_empty():
		out.append("static void %s_init_(void *self_) {\n    %s *self = (%s *)self_;\n%s\n}" % [CBTypes.cname(c), CBTypes.cname(c), CBTypes.cname(c), "\n".join(inits)])
	out.append("static const %s_vt %s_vt_ = %s;" % [CBTypes.cname(c), CBTypes.cname(c), _vt_initializer(c, c)])
	var all := CBTypes.all_methods(c)
	var cc := CBTypes.cname(c)
	var hook := func(m: String) -> String: return "%s_%s" % [CBTypes.cname(all[m].impl), m] if all.has(m) else "NULL"
	out.append("const cb_class %s_class = { \"%s\", %s, sizeof(%s), &%s_vt_, %s, %d, %s, %s, %s, %s, %s, %d, %s, %d };" % [
		cc, c, "&%s_class" % CBTypes.cname(info.extends), cc, cc,
		"%s_fields_" % cc if not entries.is_empty() else "NULL", entries.size(),
		"%s_init_" % cc if not inits.is_empty() else "NULL",
		"%s__created" % cc if info.created else "NULL",
		hook.call("on_frame"), hook.call("on_touched"), hook.call("on_drawn"), CBTypes.side_bits(str(info.get("side", "Shared"))), hook.call("on_clicked"), 1 if bool(info.get("always", false)) else 0])
	return "\n".join(out) + "\n"


## `level`'s part of `cls`'s function table: its parent's part first, then the
## methods `level` adds, each pointing at the class whose version runs for `cls`.
static func _vt_initializer(cls: String, level: String) -> String:
	var info: Dictionary = CBTypes.classes[level]
	var parts := []
	if info.extends != CBTypes.OBJECT:
		parts.append(_vt_initializer(cls, info.extends))
	var inherited := CBTypes.all_methods(info.extends) if info.extends != CBTypes.OBJECT else {}
	var all := CBTypes.all_methods(cls)
	for m in info.methods:
		if not inherited.has(m):
			parts.append("%s_%s" % [CBTypes.cname(all[m].impl), m])
	if parts.is_empty():
		parts.append("0")
	return "{ %s }" % ", ".join(parts)


## cbricks_scene.c: the world file's objects, made at the start (parents first),
## each one's When created run, then its fields set from the file.
## Every scene of the project: rel path -> {"path", "data", "fn": its C function,
## "roots": its top-level objects, "root_class": its root's class ("" if not one root)}.
## A scene holding itself (directly or through others) is a problem.
static func collect_scenes(dir: String, errors: Array) -> Dictionary:
	var out := {}
	var i := 0
	for path in CBProject.list_scenes(dir):
		var rel := CBProject.rel_path(dir, path)
		var data := CBProject.read_scene(path)
		var ident := ""
		for ch in rel.get_basename():
			ident += ch if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") else "_"
		var roots: Array = data.objects.filter(func(o): return int(o.parent) == 0 and not CBTypes.is_script_object(o))
		out[rel] = {"path": path, "data": data, "fn": "cb_scene_%d_%s" % [i, ident], "roots": roots, "root_class": ""}
		i += 1
	for rel in out:
		out[rel].root_class = _root_class(out, rel, [])
	# Scenes inside themselves.
	for rel in out:
		var chain := _scene_loop(out, rel, [rel])
		if not chain.is_empty():
			errors.append({"script": out[rel].path, "node": 0, "msg": "%s holds itself: %s (a scene can't be inside itself)." % [rel, " > ".join(chain)]})
	return out


static func _root_class(scenes: Dictionary, rel: String, seen: Array) -> String:
	if not scenes.has(rel) or rel in seen or scenes[rel].roots.size() != 1:
		return ""
	var r: Dictionary = scenes[rel].roots[0]
	if r.has("scene"):
		return _root_class(scenes, str(r.scene), seen + [rel])
	return str(r.get("class", ""))


static func _scene_loop(scenes: Dictionary, rel: String, chain: Array) -> Array:
	if not scenes.has(rel):
		return []
	for o in scenes[rel].data.objects:
		if o.has("scene"):
			var inner := str(o.scene)
			if inner == chain[0]:
				return chain + [inner]
			if inner not in chain:
				var found := _scene_loop(scenes, inner, chain + [inner])
				if not found.is_empty():
					return found
	return []


## cbricks_scene.c: one function per scene (makes its objects under a parent, parents
## first; copies of other scenes by calling theirs, then the root's overrides; its
## Script objects queued to run when the outermost scene is done) and cb_load_world
## (the Main scene under the world).
static func scenes_file(scenes: Dictionary, main_rel: String, errors: Array, script_starts: Dictionary = {}, sides: Dictionary = {}) -> String:
	var out := PackedStringArray(["/* Generated by C-Bricks from the project's scenes (.cbscene). Do not edit. */", "#include \"cbricks.h\"", ""])
	for rel in script_starts:
		out.append("void %s(void *parent_);  /* %s's When program starts */" % [script_starts[rel], rel])
	out.append("")
	for rel in scenes:
		out.append_array(_scene_function(scenes, rel, errors, script_starts, sides, scenes.keys().find(rel)))
		out.append("")
	# Each scene's Client Script objects, for its instances made while a network game runs:
	# run on the machine whose player owns the instance, `parent` = the instance's root.
	var names := scenes.keys()
	out.append("static void cb_scene_clients(int scene, void *root) {")
	out.append("    switch (scene) {")
	for i in names.size():
		var lines := PackedStringArray()
		for o in scenes[names[i]].data.objects:
			if CBTypes.is_script_object(o) and str(sides.get(str(o.get("script", "")), "Shared")) == "Client" and script_starts.has(str(o.get("script", ""))):
				lines.append("        %s(root);  /* %s */" % [script_starts[str(o.script)], str(o.get("name", ""))])
		if not lines.is_empty():
			out.append("    case %d:  /* %s */" % [i, names[i]])
			out.append_array(lines)
			out.append("        break;")
	out.append("    default:")
	out.append("        (void)root;")
	out.append("    }")
	out.append("}")
	out.append("")
	out.append("void cb_load_world(void) {")
	out.append("    cb_scene_clients_run = cb_scene_clients;")
	if scenes.has(main_rel):
		out.append("    cb_scene_keys(true);  /* its objects are known by their places (networking) */")
		out.append("    %s(NULL);  /* %s, the Main scene: its root is the world */" % [scenes[main_rel].fn, main_rel])
		out.append("    cb_scene_keys(false);")
	out.append("}")
	return "\n".join(out) + "\n"


## A world-file value as C for a field of type `ty` ("" and a problem when it can't be one).
static func _field_value(ty: String, text: String) -> String:
	if ty == "string":
		return CodeGen.c_string(text)
	if CBTypes.is_basic(ty) or CBTypes.is_vector(ty) or CBTypes.is_vector2(ty):
		return CodeGen.literal(text, T.type_from_name(ty))[0]
	return ""


static func _scene_function(scenes: Dictionary, rel: String, errors: Array, script_starts: Dictionary, sides: Dictionary = {}, index := 0) -> PackedStringArray:
	var sc: Dictionary = scenes[rel]
	var objects: Array = sc.data.objects
	var out := PackedStringArray(["void *%s(void *parent_) {  /* %s */" % [sc.fn, rel], "    void *root = NULL;", "    (void)parent_;", "    cb_scene_enter();"])
	var by_id := {}
	for o in objects:
		by_id[int(o.id)] = o
	var done := {}
	var order := []
	var progress := true
	while progress:
		progress = false
		for o in objects:
			var pid := int(o.parent)
			if not done.has(int(o.id)) and (pid == 0 or done.has(pid) or not by_id.has(pid)):
				done[int(o.id)] = true
				order.append(o)
				progress = true
	var e := func(o: Dictionary, msg: String) -> void: errors.append({"script": sc.path, "node": 0, "world_id": int(o.id), "msg": "%s: %s (%s): %s" % [rel, str(o.get("name", "")), str(o.get("scene", o.get("class", ""))), msg]})
	var parent_of := func(o: Dictionary) -> String:
		var pid := int(o.parent)
		if pid != 0 and not by_id.has(pid):
			e.call(o, "its parent (object %d) isn't in the scene." % pid)
		return "w%d" % pid if pid != 0 and by_id.has(pid) and not CBTypes.is_script_object(by_id[pid]) else "parent_"
	for o in order:
		var v := "w%d" % int(o.id)
		if CBTypes.is_script_object(o):
			if script_starts.has(str(o.get("script", ""))):
				var side := str(sides.get(str(o.script), "Shared"))
				var run := "cb_scene_run(%s, %s);" % [script_starts[str(o.script)], parent_of.call(o)]
				if side == "Client":  # on players' machines (in an instance made while a game runs: its owner's)
					run = "cb_scene_client(%s, %s, root, %d);" % [script_starts[str(o.script)], parent_of.call(o), index]
				elif side != "Shared":  # a Server script only where the game's rules run
					run = "if (cb_side_runs(%d)) %s" % [CBTypes.side_bits(side), run]
				out.append("    %s  /* %s (%s): its When program starts, once this scene is made */" % [run, str(o.get("name", "")), str(o["class"])])
			continue
		var cls := ""
		var fresh := PackedStringArray()
		if o.has("scene"):
			var inner := str(o.scene)
			if not scenes.has(inner):
				e.call(o, "there's no scene '%s' in the project." % inner)
				continue
			if scenes[inner].roots.size() != 1:
				e.call(o, "%s has %d objects at the top: a scene placed in another needs one (its root)." % [inner, scenes[inner].roots.size()])
				continue
			cls = str(scenes[inner].root_class)
			out.append("    cb_scene_key_push(%d);  /* (its objects' places: inside this copy) */" % int(o.id))
			out.append("    void *%s = %s(%s);  /* a copy of %s */" % [v, scenes[inner].fn, parent_of.call(o), inner])
			out.append("    cb_scene_key_pop();")
			fresh.append("    ((cb_object *)%s)->name = %s;" % [v, CodeGen.c_string(str(o.get("name", inner.get_file().get_basename())))])
		else:
			cls = str(o.get("class", ""))
			if not CBTypes.is_class_type(cls):
				e.call(o, "there's no class named '%s'." % cls)
				continue
			var cc := CBTypes.cname(cls)
			out.append("    %s *%s = (%s *)cb_scene_new(&%s_class, %d);" % [cc, v, cc, cc, int(o.id)])
			fresh.append("    ((cb_object *)%s)->name = %s;" % [v, CodeGen.c_string(str(o.get("name", cls)))])
		var fields := {}
		for fld in CBTypes.all_fields(cls):
			fields[fld[0]] = fld
		for fname in o.fields:
			if not fields.has(fname):
				e.call(o, "%s has no field '%s'." % [cls, fname])
				continue
			var ty: String = fields[fname][1]
			var value := _field_value(ty, str(o.fields[fname]))
			if value == "":
				e.call(o, "field '%s' is a %s: a scene sets numbers, bools, text and vectors (vector3, vector2): set this one from a brick." % [fname, ty])
				continue
			fresh.append("    ((%s *)%s)->f_%s = %s;" % [CBTypes.cname(fields[fname][2]), v, fname, value])
		for g in o.get("groups", []):
			if str(g).strip_edges() != "":
				out.append("    cb_group_add(%s, %s, 0, 0);" % [v, CodeGen.c_string(str(g).strip_edges())])
		var meta: Dictionary = o.get("meta", {})
		for k in meta:
			out.append("    cb_meta_set(%s, %s, %s, 0, 0);" % [v, CodeGen.c_string(str(k)), CodeGen.c_string(str(meta[k]))])
		if not o.has("scene"):
			fresh.append("    cb_set_parent(%s, %s, 0, 0);" % [v, parent_of.call(o)])
		# Its name, fields and parent: not on a client's copy of the server's object (the server's win).
		if not fresh.is_empty():
			out.append("    if (cb_scene_fresh(%s)) {" % v)
			for line in fresh:
				out.append("    " + line)
			out.append("    }")
		if int(o.parent) == 0:
			out.append("    if (!root) root = %s;" % v)
	if objects.size() > order.size():
		errors.append({"script": sc.path, "node": 0, "msg": "%s: some objects are under each other in a circle." % rel})
	out.append("    if (!parent_) cb_world_adopt(root);  /* made under nothing (the Main scene, Change scene): its root is the world */")
	out.append("    cb_scene_leave();")
	out.append("    return root;")
	out.append("}")
	return out
