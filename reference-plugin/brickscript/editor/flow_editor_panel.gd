@tool
extends VBoxContainer

## Main-screen panel of Brickscript's wire editor, created and freed by
## plugin_main.gd. Until a brickscript is open it shows a start page (new /
## open, and the project's brickscripts). Then: toolbar on top, node palette
## (left; only the bricks the graph's context can use), wire canvas (middle),
## Properties (right: the selected node, Inputs then Outputs), problems
## (bottom; click one to jump to its node). Variables are made by bricks; a
## graph that still lists variables gets them as Set Var bricks when opened. Every change recompiles, so
## problems show up at once. Saving writes the graph (.bricklocal /
## .brickserver). Those files are scripts to Godot (brick_file.gd), so no .gd
## is written: saving rebuilds the loaded script, and nodes using it update.
## Older .brick graphs still write `<name>.gd` next to them.
##
## Undo / redo: every change is recorded as the graph's snapshot before and
## after it (flow_ops.gd snapshot()), in the editor's own history (Ctrl+Z /
## Ctrl+Shift+Z); outside the editor (tests) in a plain UndoRedo.

const Context = preload("flow_context.gd")
const Canvas = preload("flow_canvas.gd")
const Palette = preload("flow_palette.gd")
const Inspector = preload("flow_inspector.gd")
const Compiler = preload("../core/flow_compiler.gd")
const Ops = preload("../core/flow_ops.gd")
const BrickFile = preload("../core/brick_file.gd")
const Library = preload("../core/flow_library.gd")
const NodeTypes = preload("../core/node_types.gd")
const Types = preload("../core/flow_types.gd")

## Open accepts both kinds, and older .brick / .tres graphs.
const GRAPH_FILTERS: PackedStringArray = ["*.bricklocal, *.brickserver, *.brick ; Brickscript", "*.tres ; Brickscript graph (older)"]
const SAVE_FILTERS: Dictionary[StringName, String] = {&"local": "*.bricklocal ; Local brickscript", &"server": "*.brickserver ; Server brickscript", &"shared": "*.brickshared ; Shared brickscript"}
## Folders the start page doesn't look in for brickscripts.
const SKIPPED_FOLDERS: PackedStringArray = [".godot", ".git", ".import"]
## EditorUndoRedoManager.GLOBAL_HISTORY (not referenced by name: the class only
## exists in editor builds, and the panel also runs in headless tests).
const GLOBAL_HISTORY: int = 0
const SERVER_COLOR: Color = Color(1.0, 0.62, 0.3)
## Meta on an edited graph: the file it came from.
const PATH_META: StringName = &"_brickscript_path"
const LOCAL_COLOR: Color = Color(0.55, 0.82, 1.0)

## The Focus button was toggled (plugin_main.gd hides the editor docks).
signal focus_toggled(on: bool)

var context: Context = Context.new()
## Path of the graph being edited; "" until first saved.
var graph_path: String = ""
var dirty: bool = false

var _network_available: bool = false
var _compiler: RefCounted = Compiler.new()
## Redraw flags waiting for the deferred rebuild.
var _pending_redraw: int = 0
var _node_reference: RegEx = RegEx.create_from_string("\\(node (\\d+)\\)")
## The editor's EditorUndoRedoManager, or a plain UndoRedo outside the editor.
var _undo_redo: Object = null
## The graph as it was after the last recorded change.
var _last_snapshot: Dictionary = {}

var _title: Label = null
var _base_type: LineEdit = null
## Local / Server (graph.context).
var _runs_on: OptionButton = null
var _runs_on_label: Label = null
## Acts for: its parent (a script node) / the node it's on.
var _acts_for: OptionButton = null
var _mode: Label = null
var _focus: Button = null
var _trace: Button = null
var _status_icon: TextureRect = null
var _status: Label = null
var _palette: Palette = null
var _canvas: Canvas = null
## Where each brickscript's canvas was looked at: path -> {"scroll", "zoom"}.
## Kept while the editor runs; the plugin saves it in the editor layout.
var _views: Dictionary = {}
## A view waiting for the canvas to have a size (scroll is clamped to it).
var _pending_view: Dictionary = {}
## The open brickscript's view isn't checked for bricks yet (the canvas had
## no size): _bricks_into_view once it has.
var _view_unchecked: bool = false
var _inspector: Inspector = null
var _problems: ItemList = null
## Errors the running game reported (runtime/brick_debug.gd), newest last:
## {"path", "brick", "line", "text"}. Cleared when the game runs again.
var runtime_errors: Array[Dictionary] = []
## Toolbar parts and areas shown only while a graph is open.
var _graph_tools: Array[Control] = []
var _body: Array[Control] = []
var _start: Control = null
var _start_list: ItemList = null
## The start page's filter: only paths containing its words are listed.
var _start_filter: LineEdit = null
var _start_new_server: Button = null
var _new_menu: MenuButton = null


func _init() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		_undo_redo = Engine.get_singleton(&"EditorInterface").call(&"get_editor_undo_redo")
	else:
		_undo_redo = UndoRedo.new()
	context.on_changed = _on_changed
	context.on_add_type = func(type: StringName) -> void: _canvas.add_node_in_view(type)
	context.selection_changed.connect(func(_id: int) -> void: _queue_redraw(Context.Redraw.PROPERTIES))
	_build_toolbar()
	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	_palette = Palette.new()
	_palette.context = context
	_palette.add_requested.connect(func(type: StringName) -> void: _canvas.add_node_in_view(type))
	split.add_child(_framed(_palette))
	_body.append(split)
	var right_split: HSplitContainer = HSplitContainer.new()
	split.add_child(right_split)
	_canvas = Canvas.new()
	_canvas.context = context
	_palette.canvas = _canvas
	_canvas.resized.connect(func() -> void:
		if not _pending_view.is_empty() and _canvas.size.x > 0.0:
			_apply_view(_pending_view)
		elif _view_unchecked and _canvas.size.x > 0.0:
			_bricks_into_view())
	right_split.add_child(_framed(_canvas, 1))
	_inspector = Inspector.new()
	_inspector.context = context
	_inspector.custom_minimum_size.x = 290
	_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_split.add_child(_framed(_inspector))
	_problems = ItemList.new()
	_problems.custom_minimum_size.y = 72
	_problems.tooltip_text = "Click a problem to jump to its node."
	_problems.item_selected.connect(_on_problem_selected)
	add_child(_framed(_problems))
	_body.append(_problems.get_parent())
	_build_start()
	close_graph()


## The plain UndoRedo (outside the editor) is an Object, not reference
## counted: free it with the panel, or it and every snapshot it holds leak.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _undo_redo is UndoRedo:
		_undo_redo.free()


#region Public

func set_network_available(available: bool) -> void:
	_network_available = available
	context.network_available = available
	_new_menu.get_popup().set_item_disabled(1, not available)
	if _start_new_server != null:
		_start_new_server.visible = available
	if has_graph():
		_queue_redraw(Context.Redraw.PALETTE)
	_mode.text = "Networked" if available else "Single-player"
	_mode.tooltip_text = "Network Context Engine detected" if available else "Install the Network Context Engine to unlock network nodes"


func is_network_available() -> bool:
	return _network_available


## Shows the Focus button as on / off without reporting it as a click.
func set_focus(on: bool) -> void:
	_focus.set_pressed_no_signal(on)


## Whether a graph is open (otherwise the start page shows).
func has_graph() -> bool:
	return context.graph != null


## A new graph that isn't saved anywhere yet (Save asks where).
func new_graph(graph_context: StringName = &"local") -> void:
	edit_graph(BrickFile.new_graph(graph_context), "")


## Closes the graph (unsaved changes are dropped) and shows the start page.
func close_graph() -> void:
	_remember_view()
	context.graph = null
	context.graph_path = ""
	context.parent_note = ""
	context.selected = 0
	context.info_type = &""
	graph_path = ""
	dirty = false
	_show_body(false)
	refresh_start()


## Makes an empty brickscript file at `path` (its extension sets where it
## runs; one is added if missing) and opens it. `shared`: a .brickshared
## (graph_context local: Used by Both; server: Server only).
func create_file(path: String, graph_context: StringName, shared: bool = false) -> Error:
	if shared and not BrickFile.is_shared_path(path) or not shared and BrickFile.context_of_path(path) != graph_context:
		path += "." + BrickFile.extension_for(graph_context, shared)
	var graph: BrickscriptFlowGraph = BrickFile.new_graph(graph_context)
	graph.shared = shared
	# New brickscripts are script nodes (a LocalScript / ServerScript node
	# acting for its parent); a shared one acts for no node.
	graph.script_node = not shared
	var err: Error = BrickFile.save_graph(graph, path)
	if err != OK:
		_set_status(&"StatusError", "Could not create %s: %s" % [path, error_string(err)])
		return err
	_update_filesystem(path)
	edit_graph(graph, path)
	return OK


func edit_graph(graph: BrickscriptFlowGraph, path: String) -> void:
	_remember_view()
	context.graph = graph
	# (Worked out again by _refresh_parent_type for a file.)
	context.parent_note = ""
	context.selected = 0
	context.info_type = &""
	graph_path = path
	context.graph_path = path
	# Undo may need to switch back to it (the graph isn't a resource at its
	# path: to Godot that path is a script).
	graph.set_meta(PATH_META, path)
	# The extension decides where a .bricklocal / .brickserver runs.
	var path_context: StringName = BrickFile.context_of_path(path)
	if not path_context.is_empty():
		graph.context = path_context
	_show_body(true)
	_show_runtime_bricks()
	# Listed script variables (older graphs) become Set Var bricks, so they
	# can be seen and edited: there is no variables list any more.
	var converted: int = Ops.variables_to_bricks(graph) + Ops.upgrade_graph(graph)
	dirty = converted > 0 or _refresh_parent_type(graph)
	_last_snapshot = Ops.snapshot(graph)
	_base_type.text = graph.base_type
	_show_context()
	_pending_redraw = 0
	_redraw(Context.Redraw.ALL)
	_recompile()
	_update_title()
	if converted > 0:
		_set_status(&"StatusWarning", "Updated %d variable(s) to Constant / Export / Variable (Set) bricks. Save to keep it." % converted)
	if _views.has(path):
		# After the canvas has updated its scroll range for this graph.
		_apply_view.call_deferred(_views[path])
	else:
		_bricks_into_view.call_deferred()


## Every brickscript's last view (path -> {"scroll", "zoom"}), the open one's
## as it is now.
func view_states() -> Dictionary:
	_remember_view()
	return _views.duplicate(true)


func set_view_states(views: Dictionary) -> void:
	for path: Variant in views:
		if views[path] is Dictionary and (views[path] as Dictionary).has("scroll") and (views[path] as Dictionary).has("zoom"):
			_views[str(path)] = views[path]
	if _views.has(graph_path):
		_apply_view(_views[graph_path])


func _remember_view() -> void:
	if has_graph() and not graph_path.is_empty():
		_views[graph_path] = {"scroll": _canvas.scroll_offset, "zoom": _canvas.zoom} if _pending_view.is_empty() else _pending_view


func _apply_view(view: Dictionary) -> void:
	_pending_view = {} if _canvas.size.x > 0.0 else view
	_canvas.zoom = float(view["zoom"])
	_canvas.scroll_offset = view["scroll"]
	_bricks_into_view()


## An empty-looking canvas reads as an empty brickscript: when none of its
## bricks is in view, scroll to them (once the canvas has a size).
func _bricks_into_view() -> void:
	_view_unchecked = _canvas.size.x <= 0.0
	if _view_unchecked or not has_graph() or not is_inside_tree():
		return
	# (A couple of frames on: the canvas moves its scroll into its new range
	# after the bricks and its size settle.)
	for _frame: int in 2:
		await get_tree().process_frame
	if has_graph() and is_inside_tree():
		_canvas.bring_bricks_into_view()


## The generated script's path for an older .brick graph ("" otherwise:
## .bricklocal / .brickserver are the script).
func script_path() -> String:
	return "" if graph_path.is_empty() else BrickFile.script_path_for(graph_path)


## Saves the graph (and for an older .brick, its generated script if it
## compiles). Asks for a path first if the graph was never saved.
func save() -> Error:
	if not has_graph():
		return ERR_UNCONFIGURED
	if graph_path.is_empty():
		var graph_context: StringName = context.graph.context
		var shared: bool = context.graph.shared
		_ask_path(FileDialog.FILE_MODE_SAVE_FILE, func(path: String) -> void:
			var extension: String = BrickFile.extension_for(graph_context, shared)
			graph_path = path if path.get_extension().to_lower() == extension else path + "." + extension
			context.graph_path = graph_path
			_show_context()
			save(), [SAVE_FILTERS[&"shared" if shared else graph_context]])
		return ERR_UNCONFIGURED
	var graph: BrickscriptFlowGraph = context.graph
	if BrickFile.is_script_path(graph_path):
		return _save_brickscript(graph)
	graph.take_over_path(graph_path)
	var err: Error = ResourceSaver.save(graph, graph_path)
	if err != OK:
		_set_status(&"StatusError", "Could not save %s: %s" % [graph_path, error_string(err)])
		return err
	dirty = false
	_update_title()
	var source: String = _compiler.compile(graph)
	if source.is_empty():
		_set_status(&"StatusWarning", "Graph saved. Script not written: fix the problems below first.")
		return OK
	err = _write_script(script_path(), source)
	if err == OK:
		_set_status(&"StatusSuccess", "Saved %s and %s" % [graph_path.get_file(), script_path().get_file()])
	return err


## .bricklocal / .brickserver: write the graph, then rebuild the script
## loaded from it (if anything loaded it), so nodes running it update.
func _save_brickscript(graph: BrickscriptFlowGraph) -> Error:
	_refresh_parent_type(graph)
	var err: Error = BrickFile.save_graph(graph, graph_path)
	if err != OK:
		_set_status(&"StatusError", "Could not save %s: %s" % [graph_path, error_string(err)])
		return err
	BrickFile.refresh_loaded_script(graph, graph_path)
	_update_filesystem(graph_path)
	dirty = false
	_update_title()
	if _compiler.compile(graph).is_empty():
		_set_status(&"StatusWarning", "Saved %s. Fix the problems below: until then it reports them when the game runs." % graph_path.get_file())
	else:
		_set_status(&"StatusSuccess", "Saved %s" % graph_path.get_file())
	return OK


## The parent's node type (what ".." is), from the scenes that use this
## brickscript, and for a server brickscript carried by a node (its
## `server_script` metadata) that node's type; stored in the graph for the
## game's compile. True if either changed.
func _refresh_parent_type(graph: BrickscriptFlowGraph) -> bool:
	if graph_path.is_empty():
		return false
	var body: Dictionary = {}
	if graph.script_node:
		# A script node works for its parent (Self.Parent): its type from the scenes.
		body = context.guess_path("..")["type"]
		if body.is_empty():
			body = graph.body_type
	elif graph.context == &"server" and BrickFile.body_script_for(graph_path).is_empty():
		body = NodeTypes.carrier_of_server_script(graph_path)
		if body.is_empty():
			# Not in a saved scene (yet): keep what was stored when it was made.
			body = graph.body_type
	var guess: Dictionary = context.guess_path("..")
	var found: Dictionary = guess["type"]
	var note: String = NodeTypes.mixed_note(guess)
	context.parent_note = "Self.Parent is a %s here: the type its parents share (%s). What only some have is used by name." % [NodeTypes.describe(found), note] if not note.is_empty() else ""
	var changed: bool = _refresh_path_types(graph, guess["types"])
	changed = _refresh_root_types(graph) or changed
	if found == graph.parent_type and body == graph.body_type:
		return changed
	graph.parent_type = found
	graph.body_type = body
	return true


## Typed-in node paths keep the node type their picker found; brought up to
## date with the scenes (a path the scenes don't have keeps what it had).
func _refresh_path_types(graph: BrickscriptFlowGraph, types: Dictionary) -> bool:
	var changed: bool = false
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		for input: StringName in node.inputs:
			var data: Dictionary = node.inputs[input]
			var path: String = str(data.get("value", "")).strip_edges()
			if int(data.get("type", -1)) != Types.ValueType.NODE or data.has("var") or path in [".", ".."] or not types.has(path):
				continue
			if data.get("node", {}) != types[path]:
				data["node"] = types[path]
				changed = true
	return changed


## Get root bricks with no Type get the one the scenes say (clear it to have
## it found again).
func _refresh_root_types(graph: BrickscriptFlowGraph) -> bool:
	var changed: bool = false
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null or node.type != &"get_root" or not str(node.settings.get(&"node_class", "")).strip_edges().is_empty():
			continue
		var of: Dictionary = Ops.input_of(node, &"of")
		if of.has("var"):
			continue
		var found: Dictionary = NodeTypes.root_type_guess(context.scene_script_path(), str(of.get("value", ".")), str(node.settings.get(&"root", "")) == Library.ROOT_OF[1])
		if found.is_empty():
			continue
		node.settings[&"node_class"] = String(found.get("class", &"Node"))
		if found.has("script"):
			node.settings[&"node_script"] = found["script"]
		changed = true
	return changed


func save_if_needed() -> void:
	if has_graph() and dirty and not graph_path.is_empty():
		save()


## Undo / redo the last change (the editor's Ctrl+Z / Ctrl+Shift+Z do this
## too). Brickscript's steps live in the editor's global history: the panel
## isn't part of any scene.
func undo() -> void:
	_history().undo()


func redo() -> void:
	_history().redo()


## Forgets the undo steps (when the plugin goes away, so the editor's history
## holds no calls into a freed panel).
func clear_history() -> void:
	if _undo_redo is UndoRedo:
		(_undo_redo as UndoRedo).clear_history()
	elif _undo_redo != null:
		_undo_redo.call(&"clear_history", GLOBAL_HISTORY, false)


func _history() -> UndoRedo:
	if _undo_redo is UndoRedo:
		return _undo_redo
	return _undo_redo.call(&"get_history_undo_redo", GLOBAL_HISTORY)

#endregion


#region Changes

func _on_changed(redraw: int, action: String = "Edit") -> void:
	if not has_graph():
		return
	dirty = true
	_queue_redraw(redraw)
	_recompile()
	_update_title()
	_record(action)


## Adds the change since the last one to the undo history (not done again
## now: the change already happened).
func _record(action: String) -> void:
	var before: Dictionary = _last_snapshot
	var after: Dictionary = Ops.snapshot(context.graph)
	if after == before:
		return
	_last_snapshot = after
	var graph: BrickscriptFlowGraph = context.graph
	if _undo_redo is UndoRedo:
		var undo_redo: UndoRedo = _undo_redo
		undo_redo.create_action("Brickscript: " + action)
		undo_redo.add_do_method(_restore.bind(graph, after))
		undo_redo.add_undo_method(_restore.bind(graph, before))
		undo_redo.commit_action(false)
	else:
		_undo_redo.call(&"create_action", "Brickscript: " + action, UndoRedo.MERGE_DISABLE, self, false, false)
		_undo_redo.call(&"add_do_method", self, &"_restore", graph, after)
		_undo_redo.call(&"add_undo_method", self, &"_restore", graph, before)
		_undo_redo.call(&"commit_action", false)


## Puts `graph` back to a snapshot (switching to it if another graph is open).
func _restore(graph: BrickscriptFlowGraph, data: Dictionary) -> void:
	if graph != context.graph:
		edit_graph(graph, graph.get_meta(PATH_META, graph.resource_path))
	Ops.restore(graph, data)
	_last_snapshot = data
	_show_context()
	if context.selected_node() == null:
		context.selected = 0
	_base_type.text = graph.base_type
	dirty = true
	_pending_redraw = 0
	_redraw(Context.Redraw.ALL)
	_recompile()
	_update_title()


## Rebuilding frees the widget that reported the change, so never do it in the
## middle of its signal.
func _queue_redraw(redraw: int) -> void:
	if redraw == Context.Redraw.NONE:
		return
	if _pending_redraw == 0:
		_flush_redraw.call_deferred()
	_pending_redraw |= redraw


func _flush_redraw() -> void:
	var redraw: int = _pending_redraw
	_pending_redraw = 0
	if has_graph():
		_redraw(redraw)


func _redraw(redraw: int) -> void:
	if redraw & Context.Redraw.PALETTE:
		_palette.rebuild()
	if redraw & Context.Redraw.CANVAS:
		_canvas.rebuild()
	if redraw & Context.Redraw.PROPERTIES:
		_inspector.rebuild()


func _on_problem_selected(index: int) -> void:
	var runtime: Variant = _problems.get_item_metadata(index)
	if runtime is Dictionary:
		show_brick(runtime["path"], runtime["brick"])
		return
	var found: RegExMatch = _node_reference.search(_problems.get_item_text(index))
	if found != null:
		_canvas.show_node(int(found.get_string(1)))


#region Trace

## Trace on / off: saved as a project setting the game reads when it starts
## (brick_file.gd trace_enabled()).
func set_trace(on: bool) -> void:
	_trace.set_pressed_no_signal(on)
	if bool(ProjectSettings.get_setting(BrickFile.TRACE_SETTING, false)) == on:
		return
	# Off is the default: drop the setting rather than store false.
	ProjectSettings.set_setting(BrickFile.TRACE_SETTING, true if on else null)
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		ProjectSettings.save()
	_set_status(&"PlayStart" if on else &"StatusSuccess", "Trace on: bricks light up as they run (from the next run)." if on else "Trace off.")


## Bricks of `path` that just ran in the game: lit up if it's open.
func show_trace(path: String, bricks: Array) -> void:
	if has_graph() and path == graph_path:
		_canvas.flash(bricks)

#endregion


#region Runtime errors

## A runtime error from the game: listed first under Problems, and its brick
## outlined in red while its brickscript is open.
func add_runtime_error(path: String, brick: int, line: int, text: String) -> void:
	var error: Dictionary = {"path": path, "brick": brick, "line": line, "text": text}
	if runtime_errors.has(error):
		return
	runtime_errors.append(error)
	_show_runtime_bricks()
	if has_graph():
		_recompile()
	else:
		_problems.clear()
		_list_runtime_errors()
		_show_body(false)


## The game runs again: forget the last run's errors.
func clear_runtime_errors() -> void:
	if runtime_errors.is_empty():
		return
	runtime_errors.clear()
	_show_runtime_bricks()
	if has_graph():
		_recompile()


## Opens `path` (if it isn't open) and selects and centres brick `brick`.
func show_brick(path: String, brick: int) -> void:
	if path != graph_path:
		open_file(path)
	if brick > 0:
		_flush_redraw()
		_canvas.show_node(brick)


func _list_runtime_errors() -> void:
	for error: Dictionary in runtime_errors:
		var title: String = "line %d" % error["line"]
		if error["path"] == graph_path and has_graph() and context.graph.node_by_id(error["brick"]) != null:
			title = "%s (node %d)" % [Library.get_definition(context.graph.node_by_id(error["brick"]).type).get("title", "?"), error["brick"]]
		elif error["brick"] > 0:
			title = "node %d" % error["brick"]
		_add_problem(&"StatusError", "Runtime error in %s, %s: %s" % [str(error["path"]).get_file(), title, error["text"]])
		_problems.set_item_metadata(_problems.item_count - 1, error)
		_problems.set_item_tooltip(_problems.item_count - 1, "The game hit this while running. Click to show the brick.")


func _show_runtime_bricks() -> void:
	context.runtime_bricks.clear()
	for error: Dictionary in runtime_errors:
		if error["path"] == graph_path and error["brick"] > 0:
			context.runtime_bricks[error["brick"]] = error["text"]
	if has_graph():
		_queue_redraw(Context.Redraw.CANVAS)

#endregion

#endregion


#region Compile, status, files

func _recompile() -> void:
	_compiler.source_path = graph_path
	_compiler.compile(context.graph)
	context.scopes = _compiler.scopes
	context.made_shared = _compiler.made_shared
	_problems.clear()
	_list_runtime_errors()
	for error: String in _compiler.errors:
		_add_problem(&"StatusError", error)
	for warning: String in _compiler.warnings:
		_add_problem(&"StatusWarning", warning)
	if not _compiler.errors.is_empty():
		_set_status(&"StatusError", "%d problem(s): the script can't be generated yet" % _compiler.errors.size())
	elif not _compiler.warnings.is_empty():
		_set_status(&"StatusWarning", "Ready, with %d warning(s)" % _compiler.warnings.size())
	else:
		_set_status(&"StatusSuccess", "Ready")


func _add_problem(icon_name: StringName, text: String) -> void:
	var problem_icon: Texture2D = context.brick_theme.icon(icon_name)
	if problem_icon != null:
		_problems.add_item(text, problem_icon)
	else:
		_problems.add_item(text)


func _set_status(icon_name: StringName, text: String) -> void:
	_status_icon.texture = context.brick_theme.icon(icon_name)
	_status.text = text
	_status.tooltip_text = text


func _update_title() -> void:
	var server: bool = context.graph != null and context.graph.context == &"server"
	var shared: bool = context.graph != null and context.graph.shared
	var tag: String = ("  [shared, server only]" if server else "  [shared]") if shared else ("  [server]" if server else "")
	_title.text = "%s%s%s" % ["(unsaved graph)" if graph_path.is_empty() else graph_path.get_file(), tag, " *" if dirty else ""]
	if server:
		_title.add_theme_color_override(&"font_color", SERVER_COLOR)
	else:
		_title.remove_theme_color_override(&"font_color")


## The Runs on dropdown follows the graph; a server graph's is tinted. A
## .bricklocal / .brickserver file's extension decides it, so it can't be
## changed there (older .brick files and unsaved graphs can).
func _show_context() -> void:
	var server: bool = context.graph.context == &"server"
	var shared: bool = context.graph.shared
	# A shared brickscript says who may call it: everyone (Both) or the server.
	_runs_on_label.text = "Used by" if shared else "Runs on"
	_runs_on.set_item_text(0, "Both" if shared else "Local")
	_runs_on.set_item_text(1, "Server only" if shared else "Server")
	_runs_on.select(1 if server else 0)
	_acts_for.select(0 if context.graph.script_node else 1)
	_acts_for.disabled = shared
	_base_type.editable = not context.graph.script_node
	_base_type.text = "Node" if context.graph.script_node else String(context.graph.base_type)
	_base_type.tooltip_text = "A script node is a plain Node: it acts for its parent, whose type the scenes give." if context.graph.script_node else "Node class the generated script extends (e.g. Node2D, CharacterBody3D)"
	_runs_on.disabled = not BrickFile.context_of_path(graph_path).is_empty()
	_runs_on.tooltip_text = "Set by the file type (.%s)." % graph_path.get_extension() if _runs_on.disabled \
		else ("Both: local and server brickscripts may call it (only bricks that work on either side). Server only: server brickscripts may (server bricks allowed)." if shared else "Where the generated script runs.")
	if server:
		_runs_on.add_theme_color_override(&"font_color", SERVER_COLOR)
		_runs_on.add_theme_color_override(&"font_disabled_color", SERVER_COLOR)
	else:
		_runs_on.remove_theme_color_override(&"font_color")
		_runs_on.remove_theme_color_override(&"font_disabled_color")
	_update_title()


## Writes the generated script, but never over a script Brickscript didn't
## generate.
func _write_script(path: String, source: String) -> Error:
	if FileAccess.file_exists(path):
		var existing: FileAccess = FileAccess.open(path, FileAccess.READ)
		var first_line: String = existing.get_line() if existing != null else ""
		if first_line != Compiler.HEADER:
			_set_status(&"StatusError", "Not overwriting %s: it was not generated by Brickscript." % path.get_file())
			return ERR_ALREADY_EXISTS
	var script: GDScript = load(path) as GDScript if ResourceLoader.exists(path) else GDScript.new()
	if script == null:
		script = GDScript.new()
	script.source_code = source
	script.take_over_path(path)
	var err: Error = ResourceSaver.save(script, path)
	if err != OK:
		_set_status(&"StatusError", "Could not write %s: %s" % [path, error_string(err)])
		return err
	script.reload(true)
	_update_filesystem(path)
	return OK


## Tells the editor's FileSystem about a new or changed file.
func _update_filesystem(path: String) -> void:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var filesystem: Object = Engine.get_singleton(&"EditorInterface").call(&"get_resource_filesystem")
		filesystem.call(&"update_file", path)


func _open() -> void:
	_ask_path(FileDialog.FILE_MODE_OPEN_FILE, open_file, GRAPH_FILTERS)


## Opens a brickscript file (saving the open one first if it has a file).
func open_file(path: String) -> void:
	var graph: BrickscriptFlowGraph = BrickFile.load_graph(path) if BrickFile.is_script_path(path) else ResourceLoader.load(path) as BrickscriptFlowGraph
	if graph == null:
		_set_status(&"StatusError", "%s is not a Brickscript wire graph." % path.get_file())
		refresh_start()
		return
	save_if_needed()
	edit_graph(graph, path)


## New local / server brickscript: asks where to save it, then opens it.
func _ask_new(graph_context: StringName) -> void:
	_ask_path(FileDialog.FILE_MODE_SAVE_FILE, func(path: String) -> void:
		save_if_needed()
		create_file(path, graph_context), [SAVE_FILTERS[graph_context]])


## Shows the editor's file dialog (a plain one outside the editor).
func _ask_path(mode: int, on_chosen: Callable, filters: PackedStringArray) -> void:
	var dialog: Window = ClassDB.instantiate(&"EditorFileDialog") if ClassDB.class_exists(&"EditorFileDialog") else FileDialog.new()
	dialog.set(&"file_mode", mode)
	dialog.set(&"access", FileDialog.ACCESS_RESOURCES)
	for graph_filter: String in filters:
		dialog.call(&"add_filter", graph_filter.get_slice(" ; ", 0), graph_filter.get_slice(" ; ", 1))
	dialog.connect(&"file_selected", func(path: String) -> void:
		on_chosen.call(path)
		dialog.queue_free())
	dialog.connect(&"canceled", dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)

#endregion


#region Layout

## The toolbar: four groups (file buttons; the brickscript's settings; the
## status; Trace, Focus and the network) that wrap onto another row when the
## tab is too narrow for one, instead of pushing the canvas and Properties
## off the screen.
func _build_toolbar() -> void:
	var bar: HFlowContainer = HFlowContainer.new()
	add_child(bar)
	var files: HBoxContainer = _toolbar_group(bar)
	var settings: HBoxContainer = _toolbar_group(bar)
	var status: HBoxContainer = _toolbar_group(bar)
	# The status takes the row's free space (and clips a long message).
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.custom_minimum_size.x = 160
	var toggles: HBoxContainer = _toolbar_group(bar)
	_new_menu = MenuButton.new()
	_new_menu.text = "New"
	_new_menu.flat = true
	_new_menu.icon = context.brick_theme.icon(&"New")
	_new_menu.get_popup().add_item("Local brickscript... (.bricklocal)", 0)
	_new_menu.get_popup().set_item_tooltip(0, "Runs on every machine (each player's game, and the server).")
	_new_menu.get_popup().add_item("Server brickscript... (.brickserver)", 1)
	_new_menu.get_popup().set_item_tooltip(1, "Runs only where the game has server authority. Needs the Network Context Engine.")
	_new_menu.get_popup().id_pressed.connect(func(id: int) -> void: _ask_new(BrickscriptFlowGraph.CONTEXTS[id]))
	files.add_child(_new_menu)
	for spec: Array in [["Open", &"Load", _open, ""], ["Save", &"Save", save, ""],
			["", &"UndoRedo", undo, "Undo (Ctrl+Z)"], ["", &"Redo", redo, "Redo (Ctrl+Shift+Z)"], ["Close", &"Close", _close_pressed, "Close this brickscript (save first)"],
			["Frame", &"GraphFrame", func() -> void: _canvas.add_frame_here(), "Add a comment frame: around the selected bricks, or in the middle of the view"],
			["Arrange", &"HBoxContainer", func() -> void: _canvas.arrange_chains(), "Space the chains: each brick two grid squares after the one it follows (the selected bricks' chains, or all)"]]:
		var button: Button = Button.new()
		button.text = spec[0]
		button.flat = true
		button.icon = context.brick_theme.icon(spec[1])
		button.tooltip_text = spec[3]
		if button.icon == null and button.text.is_empty():
			button.text = spec[3].get_slice(" ", 0)
		button.pressed.connect(func() -> void: spec[2].call())
		files.add_child(button)
		if spec[0] != "Open":
			_graph_tools.append(button)
	_title = Label.new()
	settings.add_child(_title)
	var separator: VSeparator = VSeparator.new()
	settings.add_child(separator)
	var extends_label: Label = Label.new()
	extends_label.text = "Extends"
	settings.add_child(extends_label)
	_base_type = LineEdit.new()
	_base_type.custom_minimum_size.x = 140
	_base_type.tooltip_text = "Node class the generated script extends (e.g. Node2D, CharacterBody3D)"
	var commit_base: Callable = func() -> void:
		var type: StringName = StringName(_base_type.text.strip_edges())
		if ClassDB.class_exists(type) and ClassDB.is_parent_class(type, &"Node"):
			if type != context.graph.base_type:
				context.graph.base_type = type
				_on_changed(Context.Redraw.NONE, "Change base type")
		else:
			_base_type.text = context.graph.base_type
	_base_type.text_submitted.connect(func(_typed: String) -> void: commit_base.call())
	_base_type.focus_exited.connect(commit_base)
	settings.add_child(_base_type)
	var runs_on_label: Label = Label.new()
	runs_on_label.text = "Runs on"
	_runs_on_label = runs_on_label
	settings.add_child(runs_on_label)
	_runs_on = OptionButton.new()
	_runs_on.add_item("Local", 0)
	_runs_on.set_item_tooltip(0, "Runs on every machine (each player's game, and the server).")
	_runs_on.add_item("Server", 1)
	_runs_on.set_item_tooltip(1, "Runs only where the game has server authority: the host / server, or offline single-player. Saved as <name>.brickserver, it becomes the server part of <name>.local.gd.")
	_runs_on.item_selected.connect(func(index: int) -> void:
		var wanted: StringName = BrickscriptFlowGraph.CONTEXTS[index]
		if wanted != context.graph.context:
			context.graph.context = wanted
			_show_context()
			_on_changed(Context.Redraw.NONE, "Change where it runs"))
	settings.add_child(_runs_on)
	var acts_label: Label = Label.new()
	acts_label.text = "Acts for"
	settings.add_child(acts_label)
	_acts_for = OptionButton.new()
	_acts_for.name = "ActsFor"
	_acts_for.add_item("Script node", 0)
	_acts_for.set_item_tooltip(0, "On a LocalScript / ServerScript node of its own (the default for new brickscripts): Self is the script node, Self.Parent the node it works for.")
	_acts_for.add_item("The node", 1)
	_acts_for.set_item_tooltip(1, "Attached to the node itself (older brickscripts): Self is that node (for a server brickscript: the node it's the server part of).")
	_acts_for.item_selected.connect(func(index: int) -> void:
		var wanted: bool = index == 0
		if wanted != context.graph.script_node:
			context.graph.script_node = wanted
			# Paths keep naming the same nodes (a script node's start at itself).
			Ops.script_node_paths(context.graph, wanted)
			_show_context()
			_on_changed(Context.Redraw.ALL, "Change what it acts for"))
	settings.add_child(_acts_for)
	_graph_tools.append_array([_title, separator, extends_label, _base_type, runs_on_label, _runs_on, acts_label, _acts_for])
	_status_icon = TextureRect.new()
	_status_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	status.add_child(_status_icon)
	# Takes the free space and clips: a long message must not push Trace / Focus off the bar.
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	status.add_child(_status)
	toggles.add_child(VSeparator.new())
	_trace = Button.new()
	_trace.toggle_mode = true
	_trace.flat = true
	_trace.text = "Trace"
	_trace.icon = context.brick_theme.icon(&"PlayStart")
	_trace.tooltip_text = "Light up bricks as they run, in games you play from the editor (F5 / F6). Takes effect from the next run; the game runs a little slower while it's on."
	_trace.button_pressed = bool(ProjectSettings.get_setting(BrickFile.TRACE_SETTING, false))
	_trace.toggled.connect(set_trace)
	toggles.add_child(_trace)
	toggles.add_child(VSeparator.new())
	_focus = Button.new()
	_focus.toggle_mode = true
	_focus.flat = true
	_focus.text = "Focus"
	_focus.icon = context.brick_theme.icon(&"DistractionFree")
	_focus.tooltip_text = "Hide the editor's docks (Scene, FileSystem, Inspector...) while this tab is open. Your layout comes back when you switch tabs."
	_focus.toggled.connect(func(on: bool) -> void: focus_toggled.emit(on))
	toggles.add_child(_focus)
	toggles.add_child(VSeparator.new())
	_mode = Label.new()
	_mode.mouse_filter = Control.MOUSE_FILTER_PASS
	toggles.add_child(_mode)
	set_network_available(false)


## One group of the toolbar: an HBoxContainer in the wrapping bar.
func _toolbar_group(bar: HFlowContainer) -> HBoxContainer:
	var group: HBoxContainer = HBoxContainer.new()
	bar.add_child(group)
	return group


func _close_pressed() -> void:
	save_if_needed()
	close_graph()


func _show_body(open: bool) -> void:
	for area: Control in _body + _graph_tools:
		area.visible = open
	# Runtime errors stay in view on the start page too.
	_problems.get_parent().visible = open or not runtime_errors.is_empty()
	_start.visible = not open
	if open:
		return
	_problems.clear()
	_list_runtime_errors()
	_set_status(&"Node", "Open or make a brickscript to start.")


## The start page: what to do while no brickscript is open.
func _build_start() -> void:
	var center: CenterContainer = CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(center)
	_start = center
	var column: VBoxContainer = VBoxContainer.new()
	column.custom_minimum_size = Vector2(460, 0)
	column.add_theme_constant_override(&"separation", 10)
	center.add_child(column)
	var heading: Label = Label.new()
	heading.text = "No brickscript open"
	heading.add_theme_font_size_override(&"font_size", 22)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(heading)
	var hint: Label = Label.new()
	hint.text = "Make a new one, open a file, or pick one of the project's brickscripts below. Double-clicking a .bricklocal / .brickserver file in the FileSystem opens it here too."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)
	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)
	for spec: Array in [["New local brickscript...", func() -> void: _ask_new(&"local")], ["New server brickscript...", func() -> void: _ask_new(&"server")], ["Open...", _open]]:
		var button: Button = Button.new()
		button.text = spec[0]
		button.pressed.connect(spec[1])
		buttons.add_child(button)
		if spec[0].contains("server"):
			_start_new_server = button
			button.visible = _network_available
			button.add_theme_color_override(&"font_color", SERVER_COLOR)
		elif spec[0].contains("local"):
			button.add_theme_color_override(&"font_color", LOCAL_COLOR)
	var list_title: HBoxContainer = HBoxContainer.new()
	column.add_child(list_title)
	var list_label: Label = Label.new()
	list_label.text = "Brickscripts in this project"
	list_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_title.add_child(list_label)
	var refresh: Button = Button.new()
	refresh.flat = true
	refresh.icon = context.brick_theme.icon(&"Reload")
	refresh.tooltip_text = "Look again"
	refresh.pressed.connect(refresh_start)
	list_title.add_child(refresh)
	_start_filter = LineEdit.new()
	_start_filter.placeholder_text = "Filter: part of a name or folder"
	_start_filter.clear_button_enabled = true
	_start_filter.right_icon = context.brick_theme.icon(&"Search")
	_start_filter.text_changed.connect(func(_text: String) -> void: refresh_start())
	# Enter opens the selected one (the first match when nothing is picked).
	_start_filter.text_submitted.connect(func(_text: String) -> void: _open_start_pick())
	column.add_child(_start_filter)
	_start_list = ItemList.new()
	_start_list.custom_minimum_size.y = 320
	_start_list.tooltip_text = "Double-click (or Enter) to open. The open scene's brickscripts come first."
	_start_list.item_activated.connect(func(index: int) -> void: open_file(_start_list.get_item_metadata(index)))
	column.add_child(_framed(_start_list))
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and not has_graph():
			refresh_start())


## Lists the project's brickscripts on the start page (server ones tinted):
## the open scene's first, then the rest by path; with a filter, only the
## paths holding each of its words.
func refresh_start() -> void:
	if _start_list == null:
		return
	_start_list.clear()
	var paths: PackedStringArray = brickscript_files("res://")
	var all: int = paths.size()
	var in_scene: PackedStringArray = scene_brickscripts(EditorInterface.get_edited_scene_root() if Engine.is_editor_hint() else null)
	paths = start_order(paths, in_scene, _start_filter.text if _start_filter != null else "")
	for path: String in paths:
		var server: bool = BrickFile.is_server_path(path)
		# (The mark first: a long path is cut off at the end.)
		var index: int = _start_list.add_item("%s%s   %s" % ["In this scene:  " if in_scene.has(path) else "", path.trim_prefix("res://"), "(server)" if server else ""])
		_start_list.set_item_metadata(index, path)
		_start_list.set_item_tooltip(index, path + ("\n(on a node of the open scene)" if in_scene.has(path) else ""))
		_start_list.set_item_custom_fg_color(index, SERVER_COLOR if server else LOCAL_COLOR)
	if paths.is_empty():
		_start_list.add_item("(none yet)" if all == 0 else "(none match the filter)", null, false)


## `paths` filtered by every word of `filter` (any case) and sorted, the ones
## in `first` (the open scene's) at the top.
static func start_order(paths: PackedStringArray, first: PackedStringArray, filter: String) -> PackedStringArray:
	var words: PackedStringArray = filter.to_lower().split(" ", false)
	var top: PackedStringArray = []
	var rest: PackedStringArray = []
	for path: String in paths:
		var lower: String = path.to_lower()
		if Array(words).all(func(word: String) -> bool: return lower.contains(word)):
			(top if first.has(path) else rest).append(path)
	top.sort()
	rest.sort()
	return top + rest


## The brickscripts the nodes of `root`'s scene run (instanced scenes' too).
static func scene_brickscripts(root: Node) -> PackedStringArray:
	var found: PackedStringArray = []
	if root == null:
		return found
	var nodes: Array[Node] = [root]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		var script: Script = node.get_script() as Script
		if script != null and BrickFile.is_brick_path(script.resource_path) and not found.has(script.resource_path):
			found.append(script.resource_path)
		nodes.append_array(node.get_children())
	return found


func _open_start_pick() -> void:
	var picked: PackedInt32Array = _start_list.get_selected_items()
	var index: int = picked[0] if not picked.is_empty() else 0
	if index < _start_list.item_count and _start_list.is_item_selectable(index):
		open_file(_start_list.get_item_metadata(index))


## Every brickscript file under `folder`.
static func brickscript_files(folder: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return found
	for file: String in dir.get_files():
		if BrickFile.is_brick_path(file):
			found.append(folder.path_join(file))
	for sub: String in dir.get_directories():
		if not SKIPPED_FOLDERS.has(sub) and not FileAccess.file_exists(folder.path_join(sub).path_join(".gdignore")):
			found.append_array(brickscript_files(folder.path_join(sub)))
	return found


## Puts an area in an outlined frame.
func _framed(area: Control, padding: int = -1) -> PanelContainer:
	var frame: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = context.brick_theme.frame_style()
	if padding >= 0:
		style.set_content_margin_all(padding)
	frame.add_theme_stylebox_override(&"panel", style)
	frame.size_flags_horizontal = area.size_flags_horizontal
	frame.size_flags_vertical = area.size_flags_vertical
	frame.add_child(area)
	return frame

#endregion
