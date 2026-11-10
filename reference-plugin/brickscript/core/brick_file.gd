@tool
extends RefCounted

## Brickscript's file types: a graph as readable text. A header line,
## then the graph as plain data (flow_ops.gd snapshot(): nodes, wires,
## frames, ...) in Godot's own value text (var_to_str), so it reads and diffs
## well. Reading never creates objects: Ops.decode_data refuses text that
## would (plain str_to_var builds any Object or Resource a file describes).
## `format` is bumped when the data changes shape.
##
## The extension says where it runs: `<name>.bricklocal` (every machine) or
## `<name>.brickserver` (only where the game has server authority; the
## Network Context Engine adds it as the server part of nodes running
## `<name>.bricklocal`). To Godot these files ARE scripts: brick_loader.gd
## loads one as a GDScript compiled from its graph (load_script()), so a node
## or scene uses the brickscript itself as its script, and no .gd is written.
## The Brickscript tab reads and writes the graph with load_graph() /
## save_graph(). Older `.brick` files load as graphs and generate `<name>.gd`.
##
## brick_loader.gd / brick_saver.gd have a class_name, so Godot registers
## them itself, in the editor and in the game.

const Ops = preload("flow_ops.gd")
const Compiler = preload("flow_compiler.gd")
## Preloaded rather than named: a new class_name is only known once the
## editor has scanned it.
const ServerGraph = preload("brick_server_graph.gd")
## A node's own server script, kept in its metadata (shared convention with
## the Network Context Engine, like the file names): lets a node whose local
## script is built into the scene have a server brickscript.
const SERVER_SCRIPT_META: StringName = &"server_script"

const LOCAL_EXTENSION: String = "bricklocal"
const SERVER_EXTENSION: String = "brickserver"
## A shared brickscript (functions any brickscript calls; it says itself
## whether it's Used by Both or Server only).
const SHARED_EXTENSION: String = "brickshared"
## Older files (context stored inside).
const EXTENSION: String = "brick"
const EXTENSIONS: PackedStringArray = [LOCAL_EXTENSION, SERVER_EXTENSION, SHARED_EXTENSION, EXTENSION]
const HEADER: String = "# Brickscript graph. Edit it in the Brickscript tab; this file is rewritten on save."
## declared_members() by path: {"time", "members"}.
static var _members_cache: Dictionary = {}
## 2: Node inputs default to the parent (older files keep "this node").
## 3: players are Players: Player Joined / leaves give `player` (was
## `peer`), Give To's input is `player` (Ops.players_upgrade()).
## 4: Get / Set Character are Get / Set property, the Character brick is Get
## Character (Ops.character_bricks_upgrade()).
## 5: a script node's paths start at the script node (Self), its parent is
## Self.Parent (Ops.script_node_paths()).
## 6: Change property is Set property's Add mode (Ops.change_property_upgrade()).
## 7: Get / Set property are Property, Set Var is Variable, with Mode Get /
## Set / Add (Ops.access_modes_upgrade()).
const FORMAT: int = 7


## The file's text for `graph`.
static func to_text(graph: BrickscriptFlowGraph) -> String:
	return "%s\n%s\n" % [HEADER, var_to_str({"format": FORMAT, "graph": Ops.snapshot(graph)})]


## A graph from a file's text, or null if it isn't a Brickscript graph this
## version understands.
## A server graph is a BrickscriptServerGraph (its own icon).
static func from_text(text: String) -> BrickscriptFlowGraph:
	if not text.begins_with(HEADER):
		return null
	var data: Variant = Ops.decode_data(text.trim_prefix(HEADER).strip_edges())
	if not data is Dictionary or int(data.get("format", 0)) < 1 or int(data.get("format", 0)) > FORMAT or not data.get("graph") is Dictionary:
		return null
	var snapshot: Dictionary = data["graph"]
	for key: String in ["base_type", "nodes", "variables", "next_node_id", "next_variable_id"]:
		if not snapshot.has(key):
			return null
	var graph: BrickscriptFlowGraph = ServerGraph.new() if snapshot.get("context", &"local") == &"server" else BrickscriptFlowGraph.new()
	Ops.restore(graph, snapshot)
	if int(data["format"]) < 2:
		Ops.keep_this_node(graph)
	if int(data["format"]) < 3:
		Ops.players_upgrade(graph)
	if int(data["format"]) < 4:
		Ops.character_bricks_upgrade(graph)
	# (Renamed bricks before the paths move: script_node_paths() finds Node
	# inputs from the bricks as they are now.)
	if int(data["format"]) < 6:
		Ops.change_property_upgrade(graph)
	if int(data["format"]) < 7:
		Ops.access_modes_upgrade(graph)
	if int(data["format"]) < 5 and graph.script_node and not graph.shared:
		Ops.script_node_paths(graph, true)
	return graph



## A new, empty graph for a context (a server one is a BrickscriptServerGraph).
static func new_graph(graph_context: StringName = &"local") -> BrickscriptFlowGraph:
	return ServerGraph.new() if graph_context == &"server" else BrickscriptFlowGraph.new()


## Whether `path` is a brickscript that loads as a script (.bricklocal /
## .brickserver / .brickshared; older .brick files load as graphs).
static func is_script_path(path: String) -> bool:
	var extension: String = path.get_extension().to_lower()
	return extension == LOCAL_EXTENSION or extension == SERVER_EXTENSION or extension == SHARED_EXTENSION


## Whether `path` is a shared brickscript (.brickshared).
static func is_shared_path(path: String) -> bool:
	return path.get_extension().to_lower() == SHARED_EXTENSION


## The graph in a brickscript file (its extension sets the context), or null.
static func load_graph(path: String) -> BrickscriptFlowGraph:
	if not FileAccess.file_exists(path):
		return null
	var graph: BrickscriptFlowGraph = from_text(FileAccess.get_file_as_string(path))
	if graph == null:
		return null
	var path_context: StringName = context_of_path(path)
	if path_context == &"server" and not graph is ServerGraph:
		var server_graph: BrickscriptFlowGraph = new_graph(&"server")
		Ops.restore(server_graph, Ops.snapshot(graph))
		graph = server_graph
	if not path_context.is_empty():
		graph.context = path_context
	if is_shared_path(path):
		graph.shared = true
	return graph


## Writes `graph` to a brickscript file.
static func save_graph(graph: BrickscriptFlowGraph, path: String) -> Error:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(to_text(graph))
	file.close()
	return OK


## The GDScript source a brickscript runs as. A graph with problems still
## gives a script (extending its base type), which reports them when its
## node is ready, so a scene using it loads and says what to fix.
static func script_source(graph: BrickscriptFlowGraph, path: String) -> String:
	var compiler: RefCounted = Compiler.new()
	compiler.source_path = path
	compiler.trace = trace_enabled()
	var source: String = compiler.compile(graph) if graph != null else ""
	if not source.is_empty():
		return source
	var problems: String = "; ".join(compiler.errors) if graph != null else "the file isn't a Brickscript graph"
	var base_type: StringName = graph.base_type if graph != null and ClassDB.class_exists(graph.base_type) and ClassDB.is_parent_class(graph.base_type, &"Node") else &"Node"
	return "%s\nextends %s\n\n\nfunc _ready() -> void:\n\tpush_error(%s)\n" % [Compiler.HEADER, base_type,
		var_to_str("Brickscript %s can't run (open it in the Brickscript tab): %s" % [path.get_file(), problems])]


## Project setting: light up bricks as they run (Trace on the toolbar).
const TRACE_SETTING: String = "brickscript/debug/trace_bricks"


## Whether brickscripts loaded now should report each brick as it runs: only
## in a debug game run from the editor (its debugger attached), with Trace on.
static func trace_enabled() -> bool:
	return OS.is_debug_build() and not Engine.is_editor_hint() and EngineDebugger.is_active() and bool(ProjectSettings.get_setting(TRACE_SETTING, false))


## A brickscript file as a GDScript (what brick_loader.gd returns).
static func load_script(path: String) -> GDScript:
	var script: GDScript = GDScript.new()
	script.source_code = script_source(load_graph(path), path)
	script.reload()
	return script


## After saving: the already loaded script of `path` (if any) is rebuilt from
## `graph`, so open scenes and nodes running it update.
static func refresh_loaded_script(graph: BrickscriptFlowGraph, path: String) -> void:
	if not ResourceLoader.has_cached(path):
		return
	var script: GDScript = ResourceLoader.get_cached_ref(path) as GDScript
	if script == null:
		return
	script.source_code = script_source(graph, path)
	script.reload(true)


## Constants, Exports and Shared variables of a brickscript file, as members
## for the node bricks (see Compiler.declared_members()). Cached until the
## file changes; other brickscripts aren't looked into while working it out.
static func declared_members(path: String) -> Array[Dictionary]:
	var time: int = FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0
	if _members_cache.has(path) and _members_cache[path]["time"] == time:
		return _members_cache[path]["members"]
	var graph: BrickscriptFlowGraph = load_graph(path)
	var members: Array[Dictionary] = []
	if graph != null:
		var compiler: RefCounted = Compiler.new()
		compiler.foreign = false
		compiler.source_path = path
		compiler.compile(graph)
		members = compiler.declared_members()
	_members_cache[path] = {"time": time, "members": members}
	return members


## The local script a server brickscript is the server part of: its
## `<name>.bricklocal`, `<name>.local.gd` or `<name>.gd` ("" if none).
static func body_script_for(server_path: String) -> String:
	if not server_path.get_extension().to_lower() == SERVER_EXTENSION and not server_path.ends_with(".server.brick"):
		return ""
	var base: String = server_path.get_basename().trim_suffix(".server")
	for candidate: String in [base + "." + LOCAL_EXTENSION, base + ".local.gd", base + ".gd"]:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


## What a server brickscript's "this node" is: the node running its paired
## local script (that script's base type, and the script), else `stored` (the
## graph's body_type: a node carrying it as its own server script), else
## plain Node.
static func body_type_for(server_path: String, stored: Dictionary = {}) -> Dictionary:
	var local: String = body_script_for(server_path)
	if local.is_empty():
		return stored.duplicate() if not stored.is_empty() else {"class": &"Node"}
	if is_script_path(local):
		var graph: BrickscriptFlowGraph = load_graph(local)
		return {"class": graph.base_type if graph != null else &"Node", "script": local}
	var script: Script = load(local) as Script
	return {"class": script.get_instance_base_type() if script != null else &"Node", "script": local}


## Whether `path` is a Brickscript file (any of EXTENSIONS).
static func is_brick_path(path: String) -> bool:
	return EXTENSIONS.has(path.get_extension().to_lower())


## The context a path's extension sets (&"local" / &"server"), or &"" when
## the file decides (.brick, or no file yet).
static func context_of_path(path: String) -> StringName:
	match path.get_extension().to_lower():
		LOCAL_EXTENSION:
			return &"local"
		SERVER_EXTENSION:
			return &"server"
	return &""


## The extension new files of a context get (a shared graph: .brickshared).
static func extension_for(graph_context: StringName, shared: bool = false) -> String:
	if shared:
		return SHARED_EXTENSION
	return SERVER_EXTENSION if graph_context == &"server" else LOCAL_EXTENSION


## The generated script's path for an older .brick file (`<name>.gd`); ""
## for .bricklocal / .brickserver, which are scripts themselves.
static func script_path_for(path: String) -> String:
	return "" if is_script_path(path) else path.get_basename() + ".gd"


## Whether a graph file runs only on the server (by its extension, or for
## .brick by the `.server.brick` naming used before).
static func is_server_path(path: String) -> bool:
	var extension: String = path.get_extension().to_lower()
	return extension == SERVER_EXTENSION or extension == EXTENSION and path.get_basename().ends_with(".server")
