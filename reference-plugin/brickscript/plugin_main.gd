@tool
extends EditorPlugin

## Editor entry point for Brickscript: adds the "Brickscript" main-screen tab
## (placed right after Script) and hosts the wire editor panel in it.
##
## Network Context Engine support is optional. It is detected only through the
## `NetworkEngine` autoload entry in the project settings, never by referencing
## that plugin's scripts, so this plugin loads and works without it.

const NodeTypes = preload("core/node_types.gd")
const FlowEditorPanel = preload("editor/flow_editor_panel.gd")
const BrickFile = preload("core/brick_file.gd")
const FileTint = preload("editor/file_tint.gd")
const SceneDockIcons = preload("editor/scene_dock_icons.gd")
const Locate = preload("runtime/brick_debug_locate.gd")
const NodeInspector = preload("editor/node_inspector.gd")
const MultiplayerScene = preload("editor/multiplayer_scene.gd")
## The runtime half of debugging (runtime/brick_debug.gd): reports the game's
## errors in brickscripts while it runs under the debugger.
const DEBUG_AUTOLOAD: String = "BrickscriptDebug"
const DEBUG_AUTOLOAD_PATH: String = "res://addons/brickscript/runtime/brick_debug.gd"
const NEW_FILE_NAME: String = "new_brickscript"
## On a script node: "local" or "server" (shared by name with the Network
## Context Engine, which keeps ServerScript nodes off clients).
const SCRIPT_NODE_META: StringName = &"script_node"
const LAYOUT_SECTION: String = "Brickscript"
const LAYOUT_OPEN_FILE: String = "open_file"
const LAYOUT_VIEWS: String = "views"
## Server brickscripts are tinted orange in the FileSystem, local ones light blue.
const SERVER_COLOR: Color = FlowEditorPanel.SERVER_COLOR
const LOCAL_COLOR: Color = FlowEditorPanel.LOCAL_COLOR


## FileSystem > right-click > Create New > Brickscript (local / server /
## shared)... The server one is offered only while the Network Context
## Engine is there.
class NewBrickMenu extends EditorContextMenuPlugin:
	var on_create_local: Callable = Callable()
	var on_create_server: Callable = Callable()
	var on_create_shared: Callable = Callable()
	var network_available: Callable = Callable()

	func _popup_menu(_paths: PackedStringArray) -> void:
		add_context_menu_item("Brickscript (local)...", on_create_local, load("res://addons/brickscript/icons/brickscript.svg"))
		if network_available.call():
			add_context_menu_item("Brickscript (server)...", on_create_server, load("res://addons/brickscript/icons/brickscript_server.svg"))
		add_context_menu_item("Brickscript (shared functions)...", on_create_shared, load("res://addons/brickscript/icons/brickscript.svg"))

## Scene dock > right-click a node > Add LocalScript (Brickscript)... / Add
## ServerScript (Brickscript)... (a script node: a child running a new
## brickscript for the node; the server one only while the Network Context
## Engine is there). The callbacks get the selected nodes.
class SceneBrickMenu extends EditorContextMenuPlugin:
	var on_add_local: Callable = Callable()
	var on_add_server: Callable = Callable()
	var network_available: Callable = Callable()

	func _popup_menu(paths: PackedStringArray) -> void:
		if paths.size() != 1:
			return
		add_context_menu_item("Add LocalScript (Brickscript)...", on_add_local, load("res://addons/brickscript/icons/brickscript.svg"))
		if network_available.call():
			add_context_menu_item("Add ServerScript (Brickscript)...", on_add_server, load("res://addons/brickscript/icons/brickscript_server.svg"))

## Receives runtime errors from the game (runtime/brick_debug.gd) and tells
## the panel when a new run starts.
class BrickDebugger extends EditorDebuggerPlugin:
	var on_error: Callable = Callable()
	var on_trace: Callable = Callable()
	var on_run: Callable = Callable()

	func _has_capture(capture: String) -> bool:
		return capture == "brickscript"

	func _capture(message: String, data: Array, _session_id: int) -> bool:
		if message.ends_with("error") and data.size() >= 4:
			on_error.call(str(data[0]), int(data[1]), int(data[2]), str(data[3]))
			return true
		if message.ends_with("trace") and data.size() >= 2:
			on_trace.call(str(data[0]), data[1] as Array)
			return true
		return false

	func _setup_session(session_id: int) -> void:
		get_session(session_id).started.connect(func() -> void: on_run.call())

const NETWORK_AUTOLOAD_SETTING: String = "autoload/NetworkEngine"
const PLUGIN_NAME: String = "Brickscript"
## Godot has no API for tab order. Its main-screen buttons live in this
## container, each named after its plugin's untranslated name; moving ours only
## changes where it is drawn (buttons are wired to their screen by index).
const TAB_CONTAINER_NAME: String = "EditorMainScreenButtons"
const TAB_AFTER: String = "Script"
## Project metadata (per project, outside the repo) remembering the Focus button.
const METADATA_SECTION: String = "brickscript"
const FOCUS_KEY: String = "focus_mode"

var _panel: FlowEditorPanel = null
var _new_brick_menu: NewBrickMenu = null
var _scene_brick_menu: SceneBrickMenu = null
## Hides character nodes' Script row, shows Exports on the node they're shown on.
var _node_inspector: NodeInspector = null
var _file_tint: FileTint = null
## Hides the script button of Brickscript's own nodes in the Scene dock.
var _dock_icons: SceneDockIcons = null
var _debugger: BrickDebugger = null
## "Multiplayer 3D Scene" in the Scene dock's Create Root Node buttons (null:
## not found there).
var _root_button: Button = null
## The script editor's current script when last looked at (see _process).
var _seen_script: Script = null
var _network_available: bool = false
## Focus mode: hide the editor docks (Godot's distraction-free mode) while
## this tab is shown.
var _focus: bool = true
## What distraction-free mode was before we turned it on; null if we didn't.
var _restore_distraction_free: Variant = null
## The editor's split containers (dock widths and heights) as they were before
## focus mode: ending distraction-free mode lays the docks out at their
## defaults, so they're put back. Container -> [split_offset, split_offsets].
var _saved_splits: Dictionary = {}


func _enable_plugin() -> void:
	_register_debug_autoload()


func _disable_plugin() -> void:
	if ProjectSettings.has_setting("autoload/" + DEBUG_AUTOLOAD):
		remove_autoload_singleton(DEBUG_AUTOLOAD)


func _register_debug_autoload() -> void:
	if not ProjectSettings.has_setting("autoload/" + DEBUG_AUTOLOAD) and ResourceLoader.exists(DEBUG_AUTOLOAD_PATH):
		add_autoload_singleton(DEBUG_AUTOLOAD, DEBUG_AUTOLOAD_PATH)


func _enter_tree() -> void:
	# Also here, for a plugin enabled before the runtime script existed.
	_register_debug_autoload()
	# .brick files are read and written by BrickscriptFileLoader / Saver, which
	# Godot registers itself (class_name); see core/brick_loader.gd.
	_new_brick_menu = NewBrickMenu.new()
	_new_brick_menu.on_create_local = _create_brick_file.bind(&"local")
	_new_brick_menu.on_create_server = _create_brick_file.bind(&"server")
	_new_brick_menu.on_create_shared = _create_brick_file.bind(&"shared")
	_new_brick_menu.network_available = is_network_available
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM_CREATE, _new_brick_menu)
	_scene_brick_menu = SceneBrickMenu.new()
	_scene_brick_menu.on_add_local = func(nodes: Array) -> void: add_script_node(nodes[0], &"local")
	_scene_brick_menu.on_add_server = func(nodes: Array) -> void: add_script_node(nodes[0], &"server")
	_scene_brick_menu.network_available = is_network_available
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _scene_brick_menu)
	_panel = FlowEditorPanel.new()
	_panel.name = "Brickscript"
	_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EditorInterface.get_editor_main_screen().add_child(_panel)
	_focus = EditorInterface.get_editor_settings().get_project_metadata(METADATA_SECTION, FOCUS_KEY, true)
	_panel.set_focus(_focus)
	_panel.focus_toggled.connect(_on_focus_toggled)
	_make_visible(false)
	ProjectSettings.settings_changed.connect(_on_settings_changed)
	_refresh_network_availability()
	# The tab button is created after _enter_tree.
	_place_tab.call_deferred()
	# Brickscripts seen before they loaded as scripts are still listed as
	# graphs: have the editor look at them again after its first scan.
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_refresh_brick_types, CONNECT_ONE_SHOT)
	# Path / group guesses remember the project's file list until it changes.
	NodeTypes.cache_walks = true
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(NodeTypes.forget_files)
	_debugger = BrickDebugger.new()
	_debugger.on_error = func(path: String, brick: int, line: int, text: String) -> void:
		if is_instance_valid(_panel):
			_panel.add_runtime_error(path, brick, line, text)
	_debugger.on_trace = func(path: String, bricks: Array) -> void:
		if is_instance_valid(_panel):
			_panel.show_trace(path, bricks)
	_debugger.on_run = func() -> void:
		if is_instance_valid(_panel):
			_panel.clear_runtime_errors()
	add_debugger_plugin(_debugger)
	# Clicking an error in Godot's debugger opens the script at its line in the
	# script editor (without emitting editor_script_changed); for a
	# brickscript, show the brick here instead. Watched in _process.
	set_process(true)
	_file_tint = FileTint.new()
	_file_tint.color = SERVER_COLOR
	_file_tint.matches = BrickFile.is_server_path
	_file_tint.other_color = LOCAL_COLOR
	_file_tint.other_matches = func(path: String) -> bool: return BrickFile.is_brick_path(path) and not BrickFile.is_server_path(path)
	# Brickscripts load as scripts, so Godot would show its script icon.
	var local_icon: Texture2D = load("res://addons/brickscript/icons/brickscript.svg")
	var server_icon: Texture2D = load("res://addons/brickscript/icons/brickscript_server.svg")
	_file_tint.icon_of = func(path: String) -> Texture2D:
		if not BrickFile.is_script_path(path):
			return null
		return server_icon if BrickFile.is_server_path(path) else local_icon
	add_child(_file_tint)
	# Characters, PlayerService, Players, Menus, Object values...: shown like
	# Godot's own nodes (no script button); a user's own script keeps it, and
	# so do LocalScript / ServerScript nodes (their brickscript).
	_dock_icons = SceneDockIcons.new()
	_dock_icons.matches = func(path: String) -> bool: return path.begins_with("res://addons/brickscript/runtime/") and path.ends_with(".gd")
	add_child(_dock_icons)
	_node_inspector = NodeInspector.new()
	_node_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_node_inspector)
	# Brickscripts must be files: a copy built into a scene is put back.
	scene_changed.connect(_on_scene_changed)
	EditorInterface.get_inspector().property_edited.connect(_on_property_edited)
	add_tool_menu_item(MultiplayerScene.TOOL_MENU_TEXT, _on_new_multiplayer_scene)
	# (The Scene dock's buttons are made after the plugins start.)
	_add_root_button.call_deferred()
	_start_job.call_deferred()


## Tests that need the real editor (its theme and fonts size the bricks):
## `godot --editor --path . -- --brickscript-job=res://tests/<job>.gd [args]`
## runs that script's `static func run(panel, args: PackedStringArray) -> int`
## (it may await) with the Brickscript tab shown, once the editor has scanned
## the project, then quits with what it returns. Nothing happens without it.
func _start_job() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var job_path: String = ""
	for arg: String in args:
		if arg.begins_with("--brickscript-job="):
			job_path = arg.trim_prefix("--brickscript-job=")
	if job_path.is_empty():
		return
	var filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	while filesystem.is_scanning() or filesystem.get_filesystem() == null:
		await get_tree().process_frame
	for i: int in 30:
		await get_tree().process_frame
	EditorInterface.set_main_screen_editor("Brickscript")
	await get_tree().process_frame
	var job: GDScript = load(job_path) as GDScript
	var code: int = 1
	if job == null:
		push_error("Brickscript job %s couldn't be loaded" % job_path)
	else:
		code = await job.call(&"run", _panel, args)
	get_tree().quit(code)


func _exit_tree() -> void:
	_saved_splits.clear()
	remove_tool_menu_item(MultiplayerScene.TOOL_MENU_TEXT)
	if is_instance_valid(_root_button):
		_root_button.queue_free()
	_root_button = null
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if EditorInterface.get_inspector().property_edited.is_connected(_on_property_edited):
		EditorInterface.get_inspector().property_edited.disconnect(_on_property_edited)
	if _node_inspector != null:
		remove_inspector_plugin(_node_inspector)
		_node_inspector = null
	for menu: EditorContextMenuPlugin in [_new_brick_menu, _scene_brick_menu]:
		if menu != null:
			remove_context_menu_plugin(menu)
	_new_brick_menu = null
	_scene_brick_menu = null
	_leave_focus()
	if _debugger != null:
		remove_debugger_plugin(_debugger)
		_debugger = null
	set_process(false)
	if is_instance_valid(_file_tint):
		_file_tint.queue_free()
	_file_tint = null
	if is_instance_valid(_dock_icons):
		_dock_icons.queue_free()
	_dock_icons = null
	var filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if filesystem.filesystem_changed.is_connected(_refresh_brick_types):
		filesystem.filesystem_changed.disconnect(_refresh_brick_types)
	if filesystem.filesystem_changed.is_connected(NodeTypes.forget_files):
		filesystem.filesystem_changed.disconnect(NodeTypes.forget_files)
	NodeTypes.cache_walks = false
	NodeTypes.forget_files()
	if ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)
	if is_instance_valid(_panel):
		_panel.clear_history()
		_panel.queue_free()
	_panel = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_panel):
		_panel.visible = visible
	if visible:
		_enter_focus()
	else:
		_leave_focus()


func _on_focus_toggled(on: bool) -> void:
	_focus = on
	EditorInterface.get_editor_settings().set_project_metadata(METADATA_SECTION, FOCUS_KEY, on)
	if on and is_instance_valid(_panel) and _panel.visible:
		_enter_focus()
	elif not on:
		_leave_focus()


## Hides the docks and collapses the bottom panel (its tab buttons stay, and
## Godot reopens it for errors). The bottom panel isn't reopened on leaving:
## Godot has no way to ask which tab was open.
func _enter_focus() -> void:
	if not _focus:
		return
	hide_bottom_panel()
	if not EditorInterface.distraction_free_mode:
		_save_splits()
		_restore_distraction_free = false
		EditorInterface.distraction_free_mode = true


## Brings the docks back, unless the user already changed the mode themselves.
func _leave_focus() -> void:
	if _restore_distraction_free == null:
		return
	if EditorInterface.distraction_free_mode:
		EditorInterface.distraction_free_mode = _restore_distraction_free
	_restore_distraction_free = null
	# Now, and again once the editor has laid the docks out.
	_restore_splits()
	_restore_splits_later()


## The editor's split containers (not the ones in this tab's own panel).
func _editor_splits() -> Array[SplitContainer]:
	var found: Array[SplitContainer] = []
	for node: Node in EditorInterface.get_base_control().find_children("*", "SplitContainer", true, false):
		if not (is_instance_valid(_panel) and (_panel == node or _panel.is_ancestor_of(node))):
			found.append(node as SplitContainer)
	return found


func _save_splits() -> void:
	_saved_splits.clear()
	for split: SplitContainer in _editor_splits():
		_saved_splits[split] = [split.split_offset, split.get(&"split_offsets") if &"split_offsets" in split else null]


func _restore_splits() -> void:
	for split: Variant in _saved_splits:
		if not is_instance_valid(split):
			continue
		var saved: Array = _saved_splits[split]
		if saved[1] != null:
			(split as SplitContainer).set(&"split_offsets", saved[1])
		(split as SplitContainer).split_offset = saved[0]


func _restore_splits_later() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	await tree.process_frame
	await tree.process_frame
	if is_instance_valid(self):
		_restore_splits()


func _get_plugin_name() -> String:
	return PLUGIN_NAME


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"GraphEdit", &"EditorIcons")


## Opening a brickscript (double-clicking it, or a runtime error in it)
## edits it here. .bricklocal / .brickserver load as scripts; older graphs
## (.brick, .tres) as BrickscriptFlowGraph.
func _handles(object: Object) -> bool:
	return object is BrickscriptFlowGraph or object is Script and BrickFile.is_script_path((object as Script).resource_path)


func _edit(object: Object) -> void:
	if not is_instance_valid(_panel) or object == null:
		return
	if object is Script:
		var path: String = (object as Script).resource_path
		if path != _panel.graph_path:
			_panel.save_if_needed()
			_panel.open_file(path)
		EditorInterface.set_main_screen_editor(PLUGIN_NAME)
		return
	var graph: BrickscriptFlowGraph = object as BrickscriptFlowGraph
	if graph == null or graph == _panel.context.graph:
		return
	_panel.save_if_needed()
	_panel.edit_graph(graph, graph.resource_path)
	EditorInterface.set_main_screen_editor(PLUGIN_NAME)


## The script editor's current script just became a brickscript (opened at
## a line, e.g. from an error in the debugger): show that line's brick here.
func _process(_delta: float) -> void:
	var current: Script = EditorInterface.get_script_editor().get_current_script()
	if current == _seen_script:
		return
	_seen_script = current
	_on_script_opened(current)


func _on_script_opened(script: Script) -> void:
	if _is_built_in(script) and script.has_source_code() and script.source_code.begins_with(BrickFile.Compiler.HEADER):
		# "Make Unique" on a node's brickscript copies its generated code into
		# the scene: a plain GDScript from then on, cut off from its graph.
		_toast("This script is a copy of a brickscript's generated code, built into the scene. Brickscripts must be files: "
			+ "its bricks can't be edited here, and changes to the brickscript won't reach it. Put the .bricklocal / .brickserver back on the node.")
		return
	if script == null or not BrickFile.is_script_path(script.resource_path) or not is_instance_valid(_panel):
		return
	var editor: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	var code: CodeEdit = editor.get_base_editor() as CodeEdit if editor != null else null
	var line: int = code.get_caret_line() + 1 if code != null else 0
	var brick: int = Locate.brick_at_line(script.source_code, line)
	_panel.save_if_needed()
	_panel.show_brick(script.resource_path, brick)
	EditorInterface.set_main_screen_editor(PLUGIN_NAME)


## Makes the editor re-read brickscripts whose listed type is out of date.
func _refresh_brick_types() -> void:
	var filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	for path: String in FlowEditorPanel.brickscript_files("res://"):
		if BrickFile.is_script_path(path) and filesystem.get_file_type(path) != "Script":
			filesystem.update_file(path)


## Create New > Brickscript (local / server / shared)...: an empty
## .bricklocal / .brickserver / .brickshared (Used by Both) in the chosen
## folder (with a free name), opened in the Brickscript tab.
func _create_brick_file(paths: Array, where: StringName) -> void:
	var folder: String = str(paths[0]) if not paths.is_empty() else "res://"
	if not DirAccess.dir_exists_absolute(folder):
		folder = folder.get_base_dir()
	var shared: bool = where == &"shared"
	if shared:
		where = &"local"
	var extension: String = BrickFile.extension_for(where, shared)
	var path: String = folder.path_join("%s.%s" % [NEW_FILE_NAME, extension])
	var n: int = 2
	while FileAccess.file_exists(path):
		path = folder.path_join("%s_%d.%s" % [NEW_FILE_NAME, n, extension])
		n += 1
	if not is_instance_valid(_panel):
		return
	_panel.save_if_needed()
	if _panel.create_file(path, where, shared) == OK:
		EditorInterface.set_main_screen_editor(PLUGIN_NAME)


## Add LocalScript / ServerScript: a script node (a child Node named
## LocalScript / ServerScript, marked with SCRIPT_NODE_META) running a new
## `<node>_local.bricklocal` / `<node>_server.brickserver` that acts for the
## node (its "this node"), added to the edited scene (undoable) and opened.
## (The _local / _server names keep the two from pairing by file name.)
func add_script_node(node: Node, where: StringName, open: bool = true) -> Node:
	var root: Node = EditorInterface.get_edited_scene_root()
	var path: String = _new_file_for(node, BrickFile.extension_for(where), "_%s" % where)
	var graph: BrickscriptFlowGraph = BrickFile.new_graph(where)
	graph.script_node = true
	# What "this node" is, until the scene is saved and says so itself.
	graph.body_type = {"class": StringName(node.get_class())}
	var carried: Script = node.get_script() as Script
	if carried != null and not _is_built_in(carried):
		graph.body_type["script"] = carried.resource_path
	if BrickFile.save_graph(graph, path) != OK:
		push_error("Brickscript: could not create %s" % path)
		return null
	EditorInterface.get_resource_filesystem().update_file(path)
	var script: Script = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as Script
	var child: Node = Node.new()
	child.name = "ServerScript" if where == &"server" else "LocalScript"
	child.set_script(script)
	child.set_meta(SCRIPT_NODE_META, String(where))
	var undo_redo: EditorUndoRedoManager = get_undo_redo()
	undo_redo.create_action("Add %s" % child.name, UndoRedo.MERGE_DISABLE, node)
	undo_redo.add_do_method(node, &"add_child", child, true)
	undo_redo.add_do_property(child, &"owner", root if root != null else node)
	undo_redo.add_do_reference(child)
	undo_redo.add_undo_method(node, &"remove_child", child)
	undo_redo.commit_action()
	if open:
		_open_in_tab(path)
	return child


## A free `<node name><suffix>.<extension>` next to the edited scene.
func _new_file_for(node: Node, extension: String, suffix: String = "") -> String:
	var root: Node = EditorInterface.get_edited_scene_root()
	var folder: String = root.scene_file_path.get_base_dir() if root != null and not root.scene_file_path.is_empty() else "res://"
	var base: String = String(node.name).to_snake_case()
	if not base.is_valid_ascii_identifier():
		base = NEW_FILE_NAME
	base += suffix
	var path: String = folder.path_join("%s.%s" % [base, extension])
	var n: int = 2
	while FileAccess.file_exists(path):
		path = folder.path_join("%s_%d.%s" % [base, n, extension])
		n += 1
	return path


## Before a scene is saved: no built-in brickscript copies in it.
func _apply_changes() -> void:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null:
		_put_back_copies(root)


func _on_scene_changed(root: Node) -> void:
	if root != null:
		_put_back_copies(root)
	# The start page puts the open scene's brickscripts first.
	if _panel != null and _panel.is_visible_in_tree() and not _panel.has_graph():
		_panel.refresh_start()


## "Make Unique" / a built-in script in the Inspector: checked at once.
func _on_property_edited(property: String) -> void:
	if property != "script" and not property.begins_with("metadata/"):
		return
	var edited: Node = EditorInterface.get_inspector().get_edited_object() as Node
	if edited != null:
		_put_back_copies(edited)


func _put_back_copies(root: Node) -> void:
	var fixed: PackedStringArray = put_back_built_in_copies(root)
	if fixed.is_empty():
		return
	EditorInterface.mark_scene_as_unsaved()
	_toast("Brickscripts must be files: a copy built into the scene can't be edited as bricks and does nothing when the game runs. Put the file back on: %s." % ", ".join(fixed))


## Puts each brickscript built into a scene under `root` (its generated code
## copied by "Make Unique" or made built-in: as a node's script or its
## server_script metadata) back to the file it was made from, and returns
## the nodes' names. The generated code names its file (_brickscript_from_file).
static func put_back_built_in_copies(root: Node) -> PackedStringArray:
	var fixed: PackedStringArray = []
	var waiting: Array[Node] = [root]
	var file_of: RegEx = RegEx.create_from_string("_brickscript_from_file\\(\"([^\"]+)\"\\)")
	while not waiting.is_empty():
		var node: Node = waiting.pop_back()
		waiting.append_array(node.get_children())
		for slot: String in ["script", "meta"]:
			var script: GDScript = (node.get_script() if slot == "script" else node.get_meta(BrickFile.SERVER_SCRIPT_META) if node.has_meta(BrickFile.SERVER_SCRIPT_META) else null) as GDScript
			if script == null or not _is_built_in(script) or not script.source_code.begins_with(BrickFile.Compiler.HEADER):
				continue
			var found: RegExMatch = file_of.search(script.source_code)
			var path: String = found.get_string(1) if found != null else ""
			if path.is_empty() or not ResourceLoader.exists(path):
				continue
			if slot == "script":
				node.set_script(load(path))
			else:
				node.set_meta(BrickFile.SERVER_SCRIPT_META, load(path))
			fixed.append(String(node.name))
	return fixed


## Whether a script is built into a scene (no file of its own).
static func _is_built_in(script: Script) -> bool:
	return script != null and (script.resource_path.is_empty() or script.resource_path.contains("::"))


func _add_root_button() -> void:
	_root_button = MultiplayerScene.add_root_button(func() -> void: MultiplayerScene.make_root())


## Project > Tools > New Multiplayer Scene...: asks where to save it.
func _on_new_multiplayer_scene() -> void:
	var dialog: EditorFileDialog = EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.title = "New Multiplayer Scene"
	dialog.add_filter("*.tscn", "Scene")
	# (Not inside an addon: where the FileSystem dock is often left.)
	var folder: String = EditorInterface.get_current_directory()
	dialog.current_dir = "res://" if folder.begins_with("res://addons/") else folder
	dialog.current_file = "multiplayer_scene.tscn"
	dialog.file_selected.connect(_make_scene_file)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog, Vector2i(800, 500))


func _make_scene_file(path: String) -> void:
	# (The next frame: opening and saving a scene while the dialog's signal
	# runs crashes the editor, and saving's progress bar can't be used in a
	# deferred call.)
	await get_tree().process_frame
	var result: Error = MultiplayerScene.make_file(path)
	if result != OK:
		_toast("Couldn't save the scene at %s: %s." % [path, error_string(result)])


func _toast(text: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(text, EditorToaster.SEVERITY_WARNING)


func _open_in_tab(path: String) -> void:
	if not is_instance_valid(_panel):
		return
	_panel.save_if_needed()
	_panel.open_file(path)
	EditorInterface.set_main_screen_editor(PLUGIN_NAME)


## Ctrl+S and running the game save the graph and regenerate its script.
func _save_external_data() -> void:
	if is_instance_valid(_panel):
		_panel.save_if_needed()


## The editor's layout (saved when it closes) remembers the brickscript open
## in the tab, so it opens again next time.
func _get_window_layout(configuration: ConfigFile) -> void:
	if is_instance_valid(_panel):
		configuration.set_value(LAYOUT_SECTION, LAYOUT_OPEN_FILE, _panel.graph_path)
		# Where each brickscript was scrolled / zoomed to (files still there).
		var views: Dictionary = _panel.view_states()
		for path: String in views.keys():
			if not FileAccess.file_exists(path):
				views.erase(path)
		configuration.set_value(LAYOUT_SECTION, LAYOUT_VIEWS, views)


func _set_window_layout(configuration: ConfigFile) -> void:
	if not is_instance_valid(_panel):
		return
	var views: Variant = configuration.get_value(LAYOUT_SECTION, LAYOUT_VIEWS, {})
	if views is Dictionary:
		_panel.set_view_states(views)
	var path: String = str(configuration.get_value(LAYOUT_SECTION, LAYOUT_OPEN_FILE, ""))
	if not path.is_empty() and FileAccess.file_exists(path) and _panel.graph_path != path:
		_panel.open_file(path)


func _get_unsaved_status(for_scene: String) -> String:
	if for_scene.is_empty() and is_instance_valid(_panel) and _panel.dirty:
		return "Save changes to the Brickscript graph %s before closing?" % (_panel.graph_path.get_file() if not _panel.graph_path.is_empty() else "(unsaved)")
	return ""


## True when the Network Context Engine's autoload is registered, i.e. network
## blocks may be offered.
func is_network_available() -> bool:
	return _network_available


# Enabling or disabling the Network Context Engine adds or removes its autoload
# entry, which emits settings_changed.
func _on_settings_changed() -> void:
	_refresh_network_availability()


func _refresh_network_availability() -> void:
	_network_available = ProjectSettings.has_setting(NETWORK_AUTOLOAD_SETTING)
	if is_instance_valid(_panel):
		_panel.set_network_available(_network_available)


## Moves the tab right after Script, or before 2D if Script is missing. If the
## editor layout ever changes, the tab simply stays where Godot put it.
func _place_tab() -> void:
	var containers: Array[Node] = EditorInterface.get_base_control().find_children(TAB_CONTAINER_NAME, "HBoxContainer", true, false)
	if containers.is_empty():
		return
	var container: Node = containers[0]
	var tab: Node = container.get_node_or_null(NodePath(PLUGIN_NAME))
	if tab == null:
		return
	var after: Node = container.get_node_or_null(NodePath(TAB_AFTER))
	if after != null:
		container.move_child(tab, after.get_index() + (0 if tab.get_index() < after.get_index() else 1))
	else:
		container.move_child(tab, 0)
