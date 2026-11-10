@tool
extends RefCounted

## What every view of the wire editor shares: the graph being edited, the
## theme, the selected node, and how to tell the main panel about changes.

const BrickTheme = preload("brick_theme.gd")
const Types = preload("../core/flow_types.gd")
const Ops = preload("../core/flow_ops.gd")
const Library = preload("../core/flow_library.gd")
const NodeTypes = preload("../core/node_types.gd")
const Compiler = preload("../core/flow_compiler.gd")
const BrickFile = preload("../core/brick_file.gd")

## What a change needs redrawn (flags for notify_changed()). VARIABLES is
## kept for callers but redraws nothing now (there is no variables list).
enum Redraw { NONE = 0, CANVAS = 1, PROPERTIES = 2, VARIABLES = 4, PALETTE = 8, ALL = 15 }

## The selected node changed (0: none).
signal selection_changed(node_id: int)

var graph: BrickscriptFlowGraph = null
## The open graph's file ("" while unsaved): for guessing node types from the
## scenes that use it.
var graph_path: String = ""
var brick_theme: BrickTheme = BrickTheme.new()
## func(redraw: int, action: String): a view changed the graph; `redraw` =
## Redraw flags of the views that must be rebuilt (the one that made the
## change usually updates itself, so typing isn't interrupted); `action` names
## the change in the undo history.
var on_changed: Callable = Callable()
## Id of the node shown in Properties, 0 for none.
var selected: int = 0
## A palette entry whose information Properties shows (while no node is
## selected), or &"".
var info_type: StringName = &""
## func(type: StringName): add a node of that type in view (set by the panel).
var on_add_type: Callable = Callable()
## The compiler's `scopes` from the last compile: what each node can see.
var scopes: Dictionary[int, Dictionary] = {}
## The compiler's `made_shared`: Shared variables Set Var makes (name -> type).
var made_shared: Dictionary[String, int] = {}
## Bricks of the open graph the running game reported an error at: id ->
## the error (the canvas outlines them in red).
var runtime_bricks: Dictionary[int, String] = {}
## Whether the Network Context Engine is installed (network bricks offered).
var network_available: bool = false
## The scenes that put this brickscript under parents of different types
## ("Node3D in a.tscn, CharacterBody3D in b.tscn"; "" when they agree): the
## parent is then the type they share (Properties says so).
var parent_note: String = ""


## Commits a text box being edited inside `area` (it saves on losing focus)
## before `area` is rebuilt; otherwise what was typed would be lost.
static func commit_focused(area: Control) -> void:
	if area.get_viewport() == null:
		return
	var focused: Control = area.get_viewport().gui_get_focus_owner()
	if focused != null and area.is_ancestor_of(focused):
		focused.release_focus()


## Whether the palette and add menu offer `type` for the open graph: only
## bricks for its context (local / server), network ones only with the
## Network Context Engine.
func can_use(type: StringName) -> bool:
	return graph != null and Library.usable_in(type, graph.context, network_available, graph.shared)


func notify_changed(redraw: int, action: String = "Edit") -> void:
	if on_changed.is_valid():
		on_changed.call(redraw, action)


func select(node_id: int) -> void:
	if node_id != selected or info_type != &"":
		selected = node_id
		info_type = &""
		selection_changed.emit(node_id)


## Shows what a node type is and does in Properties (from the palette).
func show_info(type: StringName) -> void:
	selected = 0
	info_type = type
	selection_changed.emit(0)


func selected_node() -> BrickscriptFlowNode:
	return graph.node_by_id(selected) if graph != null and selected > 0 else null


## Variables usable at a node, for its dropdowns: [{name, type, origin}],
## chain variables first, then event values, then script variables. From the
## last compile, plus a walk back along the node's wires (Ops.upstream_names). Only
## those that fit one of `allowed` ([] = any), and with `writable_only`, only
## those a node may write. A node not wired to an event sees the script's.
func variables_at(node_id: int, allowed: Array = [], writable_only: bool = false) -> Array[Dictionary]:
	var scope: Dictionary = scopes.get(node_id, {}).duplicate()
	if scope.is_empty() and graph != null:
		for variable: BrickscriptVariable in graph.variables:
			if variable != null:
				scope[variable.name] = {"type": variable.type, "writable": variable.kind == BrickscriptVariable.Kind.SHARED, "origin": ["Constant", "Export", "Shared", "chain"][variable.kind]}
		for name: String in made_shared:
			scope[name] = {"type": made_shared[name], "writable": true, "origin": "Shared"}
		# Constants / Exports are declared by bricks without wires.
		for other: BrickscriptFlowNode in graph.nodes:
			if Library.DECLARATIONS.has(other.type):
				scope[str(other.settings.get(&"name", ""))] = {"type": int(Ops.input_of(other, &"value").get("type", Types.ValueType.ANY)), "writable": false, "origin": Library.DECLARATIONS[other.type]}
	# Also walk back along the wires: chain variables made upstream are usable
	# even before the chain is wired to an event (then there is no compiled
	# scope). The compiler's types win where it knows them.
	var node: BrickscriptFlowNode = graph.node_by_id(node_id) if graph != null else null
	if node != null:
		var upstream: Dictionary = Ops.upstream_names(graph, node)
		for name: String in upstream:
			if not scope.has(name):
				scope[name] = upstream[name]
	var result: Array[Dictionary] = []
	for origin_group: Array in [["chain"], ["event"], ["Constant", "Export", "Shared"]]:
		var names: Array = scope.keys().filter(func(name: String) -> bool: return origin_group.has(scope[name]["origin"]))
		names.sort()
		for name: String in names:
			var entry: Dictionary = scope[name]
			if writable_only and not entry["writable"]:
				continue
			if not allowed.is_empty() and not allowed.any(func(wanted: int) -> bool: return Types.fits(entry["type"], wanted)):
				continue
			result.append({"name": name, "type": entry["type"], "origin": entry["origin"], "node": entry.get("node", {})})
	return result


## The node type a node brick's Node input holds: a Node variable's type,
## Self's for "." (self_type()), the graph's parent type for "..", else {}.
func node_type_of(node: BrickscriptFlowNode, input: StringName) -> Dictionary:
	var data: Dictionary = Ops.input_of(node, input)
	if data.has("var"):
		for entry: Dictionary in variables_at(node.id):
			if entry["name"] == str(data["var"]):
				return entry.get("node", {})
		return {}
	match str(data.get("value", "")).strip_edges():
		".":
			return self_type()
		"..":
			return graph.parent_type
	return {}


## "This node": the brickscript's own (base type and variables), for a
## script node its parent, or for a server brickscript the node it's the
## server part of.
func this_node_type() -> Dictionary:
	if graph.script_node:
		return graph.body_type.duplicate() if not graph.body_type.is_empty() else {"class": &"Node"}
	if graph.context == &"server":
		return BrickFile.body_type_for(graph_path, graph.body_type)
	return {"class": graph.base_type, "self": true}


## Self (the path "."): the brickscript's own node (its base type and
## variables); a script node itself, which works for its parent
## (this_node_type()); for a server brickscript the node it's the server
## part of.
func self_type() -> Dictionary:
	if graph.script_node and not graph.shared:
		return {"class": &"Node", "self": true}
	return this_node_type()


## The script whose scenes say what paths lead to: this one, or for a server
## brickscript its paired local script.
func scene_script_path() -> String:
	if graph.script_node:
		return graph_path
	return BrickFile.body_script_for(graph_path) if graph.context == &"server" else graph_path


## What the scenes say a node path from Self is (NodeTypes
## guess_from_scenes): for a script node, paths start at the script node.
func guess_path(node_path: String) -> Dictionary:
	return NodeTypes.guess_from_scenes(scene_script_path(), node_path)


## What the node in a node brick's input has (members, see node_types.gd):
## for this node, this brickscript's own variables first.
func members_for(node: BrickscriptFlowNode, input: StringName) -> Array[Dictionary]:
	return members_of(node, node_type_of(node, input))


## The node a brick names in its own settings (When signal received: Node
## path, Type, Script): this node for a blank path without a Type.
func node_type_of_settings(node: BrickscriptFlowNode) -> Dictionary:
	var path: String = str(node.settings.get(&"path", "")).strip_edges()
	var class_text: String = str(node.settings.get(&"node_class", "")).strip_edges()
	var script: String = str(node.settings.get(&"node_script", "")).strip_edges()
	if (path.is_empty() or path == ".") and class_text.is_empty() and script.is_empty():
		return self_type()
	if path == ".." and class_text.is_empty() and script.is_empty() and graph.script_node:
		return graph.parent_type
	if class_text.is_empty() and script.is_empty():
		return {}
	var node_type: Dictionary = {"class": StringName(class_text) if not class_text.is_empty() else &"Node"}
	if not script.is_empty():
		node_type["script"] = script
	return node_type


## Members of a node type, as seen from `node`: for this node, this
## brickscript's own variables and signals first.
func members_of(node: BrickscriptFlowNode, node_type: Dictionary) -> Array[Dictionary]:
	if not node_type.get("self", false):
		return Compiler.members_of_type(node_type)
	var result: Array[Dictionary] = own_signals()
	for entry: Dictionary in variables_at(node.id):
		if entry["origin"] in ["Constant", "Export", "Shared"]:
			result.append({"name": entry["name"], "kind": "property", "type": entry["type"], "node": entry.get("node", {}), "native": false,
				"writable": entry["origin"] == "Shared", "origin": entry["origin"], "own": true})
	result.append_array(NodeTypes.class_members(node_type.get("class", graph.base_type)))
	return result


## The signals this brickscript emits (its Emit signal bricks), as members.
func own_signals() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	for other: BrickscriptFlowNode in graph.nodes:
		var name: String = str(other.settings.get(&"signal", "")).strip_edges()
		if other.type != &"emit_signal" or name.is_empty() or seen.has(name):
			continue
		seen[name] = true
		var args: Array[int] = []
		var names: PackedStringArray = []
		for spec: Dictionary in Ops.input_specs(other):
			var data: Dictionary = Ops.input_of(other, spec["name"])
			args.append(Types.ValueType.ANY if data.has("var") else int(data.get("type", Types.ValueType.ANY)))
			names.append("value_%d" % (names.size() + 1))
		result.append({"name": name, "kind": "signal", "type": -1, "node": {}, "native": false, "writable": false, "origin": "Signal", "own": true,
			"args": args, "arg_names": names, "arg_nodes": [], "required": args.size()})
	return result


## "Self (Node2D)", "Sprite2D (enemy.bricklocal)" or "some Node".
func describe_node_type(node_type: Dictionary) -> String:
	if node_type.get("self", false):
		return "Self (%s)" % node_type.get("class", graph.base_type)
	return "some Node (no Type)" if node_type.is_empty() else NodeTypes.describe(node_type)


## Input Map actions: the project's own first, then the built-in ui_* ones.
func action_names() -> PackedStringArray:
	var own: PackedStringArray = []
	var built_in: PackedStringArray = []
	for property: Dictionary in ProjectSettings.get_property_list():
		var name: String = property["name"]
		if name.begins_with("input/"):
			name = name.trim_prefix("input/")
			(built_in if name.begins_with("ui_") else own).append(name)
	own.sort()
	built_in.sort()
	return own + built_in
