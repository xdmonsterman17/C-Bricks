extends RefCounted
## What every view of the editor shares (after Brickscript's flow_context.gd):
## the graph being edited, the theme, the selected brick, and how to tell the
## main panel about changes.

const BrickTheme = preload("res://scripts/editor/brick_theme.gd")
const T = preload("res://scripts/node_defs.gd")

## What a change needs redrawn (flags for notify_changed()).
enum Redraw { NONE = 0, CANVAS = 1, PROPERTIES = 2, PALETTE = 8, ALL = 11 }

## The selected brick or frame changed (0: none).
signal selection_changed(id: int)
## A world object's field changed while something is being dragged (the 2D / 3D screens):
## Properties shows it at once; the change is saved (and undoable) when the drag ends.
signal world_live(id: int, field: String, text: String)

var graph: Dictionary = {}
var graph_path: String = ""
var brick_theme: BrickTheme = BrickTheme.new()
## func(redraw: int, action: String): a view changed the graph.
var on_changed: Callable = Callable()
## func(text: String): a refused edit's reason, for the status bar.
var on_status: Callable = Callable()
## func(type: String): add a brick of that type in view.
var on_add_type: Callable = Callable()
## Id of the brick or frame shown in Properties (0: none).
var selected: int = 0
## A palette entry whose information Properties shows (while nothing is selected).
var info_type: String = ""
## The last compile's scopes: id -> {variable: {"type", "origin"}}.
var scopes: Dictionary = {}
## Every variable the last compile found: name -> type.
var types: Dictionary = {}
## The project's records (Define Record): name -> [[field, type], ...].
var records: Dictionary = {}
## The scene being edited (CBProject.read_scene of scene_path), the object picked in
## the Scene tree, and what to call after changing it (the panel saves the file and
## rebuilds): (action). world_flat: the scene with its copies of other scenes opened
## out (WorldValues.expand: what the 2D / 3D screens draw); refresh_flat() remakes it.
var world: Dictionary = {}
var scene_path: String = ""
var world_flat: Dictionary = {}
var world_object: Dictionary = {}
var on_world_changed: Callable = Callable()
## The Scene dock's New scene button: ask a name, make it, open it.
var on_new_scene: Callable = Callable()
## A Script object was renamed (Properties): its file follows (a safe name); call(o).
var on_script_object_renamed: Callable = Callable()
## Script objects (the Scene tree): a script's Side (rel path -> "Server" / "Client" / "Shared"),
## changing it (rel path, side), opening it in the Node screen (rel path).
var script_side: Callable = Callable()
var on_script_side: Callable = Callable()
var on_open_script: Callable = Callable()
## Opening a scene for editing (rel path).
var on_open_scene: Callable = Callable()
## Renders the world to images (Camera snapshots, the Scene tree's thumbnails): a WorldSnapshot.
var snapshotter: Node = null
var project_dir: String = ""
## The debugger: the brick the program is paused at (in this script; 0: none),
## and the variables' values then (name -> value text).
var paused_brick: int = 0
var debug_values: Dictionary = {}
## func(id: int): turn the breakpoint on that brick on / off (set by the panel).
var on_toggle_breakpoint: Callable = Callable()
## func(name: String): open the script defining a function and show it.
var on_goto_function: Callable = Callable()
## func(old: String, new: String): a function was renamed (other scripts' calls follow).
var on_function_renamed: Callable = Callable()


func breakpoints() -> Array:
	return graph.get("breakpoints", []) if has_graph() else []
## Bricks a C compiler complained about: id -> the message (outlined in red).
var error_bricks: Dictionary = {}
## Bricks in the wrong place (2026-11-08): id -> why (the Target can't do them, or they don't
## belong in this script: CodeGen.misplaced). Greyed on the canvas with a red outline.
var misplaced_bricks: Dictionary = {}
## The open script's class ("" a plain script) and the project's Target: what the palette greys.
var script_class: String = ""
var target_id: String = "native"


## Commits a text box being edited inside `area` (it saves when it loses focus)
## before `area` is rebuilt, so what was typed isn't lost.
static func commit_focused(area: Control) -> void:
	if area.get_viewport() == null:
		return
	var focused: Control = area.get_viewport().gui_get_focus_owner()
	if focused != null and area.is_ancestor_of(focused):
		focused.release_focus()


func has_graph() -> bool:
	return not graph.is_empty()


func notify_changed(redraw: int, action: String = "Edit") -> void:
	if on_changed.is_valid():
		on_changed.call(redraw, action)


func select(id: int) -> void:
	if id > 0:
		world_object = {}
	if id != selected or info_type != "":
		selected = id
		info_type = ""
		selection_changed.emit(id)


func refresh_flat() -> void:
	world_flat = WorldValues.expand(world, project_dir)


## The scene's own entry for an object of world_flat (a copy's inner object: the copy).
func raw_of(flat: Dictionary) -> Dictionary:
	var id := int(flat.get("owner", flat.get("id", 0)))
	for o in world.get("objects", []):
		if int(o.id) == id:
			return o
	return {}


## world_flat's object for an entry of the scene (a copy: its root, drawn).
func flat_of(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {}
	for o in world_flat.get("objects", []):
		if int(o.id) == int(raw.id):
			return o
	return raw


## The Scene tree picked an object of the scene ({}: none): Properties shows it.
func show_world_object(o: Dictionary) -> void:
	world_object = o
	selected = 0
	info_type = ""
	selection_changed.emit(0)


func show_info(type: String) -> void:
	selected = 0
	info_type = type
	selection_changed.emit(0)


func selected_node() -> Dictionary:
	return Ops.node_by_id(graph, selected) if selected > 0 else {}


func can_use(type: String) -> bool:
	return has_graph() and not (T.DEFS[type].get("unique", false) and Ops.has_type(graph, type)) and blocked(type) == ""


## Why a brick can't be added to the open script ("" it can): the Target can't do it, or it
## doesn't belong in this kind of script (a class's, a Server / Client one).
func blocked(type: String) -> String:
	if not has_graph():
		return ""
	var why := ProjectBuild.target_cant(type, target_id)
	if why == "":
		why = CodeGen.misplaced(type, {}, script_class, str(graph.get("side", "Shared")), false)
	return why


## The variables usable at brick `id` that fit `ptype` (a NodeDefs type),
## sorted: [{"name", "type", "origin"}].
func variables_at(id: int, ptype: int = T.ANY, writable_only: bool = false) -> Array:
	var seen: Dictionary = scopes.get(id, {})
	if seen.is_empty():
		for v in types:
			seen[v] = {"type": types[v], "origin": "Chain"}
	var out := []
	for v in seen:
		if writable_only and seen[v].origin == "Input":
			pass
		if T.is_compatible(ptype, T.type_from_name(seen[v].type)):
			out.append({"name": v, "type": seen[v].type, "origin": seen[v].origin})
	out.sort_custom(func(a, b): return a.name < b.name)
	return out
