extends Control
## The C-Bricks window (after Brickscript's flow_editor_panel.gd), working on a
## project folder (see CBProject). Until a project is open it shows the project
## manager: recent projects, the examples, New / Open Project. Then: toolbar on
## top; on the left the project's files (top) and the brick palette; the
## script tabs over the wire canvas; Properties on the right; below them
## Problems (every script's; click one to jump to its brick), the program's
## Console and the generated C. Every change regenerates the project's C, so
## problems show up at once.
##
## Each open script has its own undo history (snapshots before / after every
## change, Ctrl+Z / Ctrl+Shift+Z). Build and Run save every script first.

const Context = preload("res://scripts/editor/context.gd")
const Canvas = preload("res://scripts/editor/canvas.gd")
const Palette = preload("res://scripts/editor/palette.gd")
const Inspector = preload("res://scripts/editor/inspector.gd")
const ProjectDock = preload("res://scripts/editor/project_dock.gd")
const BrickTheme = preload("res://scripts/editor/brick_theme.gd")
const BrickView = preload("res://scripts/editor/brick_view.gd")
const T = preload("res://scripts/node_defs.gd")

const SETTINGS := "user://settings.cfg"
const MAX_RECENT := 16
const ERROR_LINE := "(?m)^(?:[^\\n:]*[/\\\\])?([A-Za-z0-9_.\\-]+\\.c):(\\d+):(?:(\\d+):)? *(?:fatal )?(error|warning): *(.*)$"
const TRACE_LINE := "^\\[trace\\] (.+):(\\d+)$"

var context: Context = Context.new()
var project_dir: String = ""

## Open scripts: {"path", "graph", "dirty", "undo": UndoRedo, "snapshot", "view", "errors": {id: msg}}
var _tabs: Array = []
var _scene_paths: Array = []          # the scenes open over the Scene tree (absolute paths)
var _cur: int = -1
var _pending_redraw: int = 0
var _build: Dictionary = {}          # last ProjectBuild.generate()
const BACKEND_IDS := ["auto", "raylib", "dos"]
const DOS_SCREENS := [0, 320, 640, 800]
const DOS_SCREEN_NAMES := ["Auto (fits the window's size)", "VGA 320 x 200", "VESA 640 x 480", "VESA 800 x 600"]
var _compile_problems: Array = []    # [{script, node, msg, kind}] from the C compiler
var _target_problems: Array = []     # [{script, node, world_id, msg}]: what the Target can't do (Build stops; Build All skips that target)
var _recent: PackedStringArray = []
var _thread: Thread = null
var _proc: Dictionary = {}
var _stderr_tail: String = ""
var _trace_re := RegEx.create_from_string(TRACE_LINE)
var _flash_pending: Array = []
var _file_mode: String = ""
# The debugger: the program's command file, and what it last paused at.
var _debug_cmd: String = ""
var _paused_script: String = ""     # absolute path ("" while running / not running)
var _paused_brick: int = 0
var _dbg_lines: Array = []          # [var] / [global] lines of the pause being read
var _dbg_reading: bool = false
var _debug_tab: Control = null
var _debug_state: Label = null
var _debug_tree: Tree = null
var _dbg_continue: Button = null
var _dbg_step: Button = null
var _dbg_over: Button = null
var _dbg_out: Button = null
var _paused_depth := 0               # calls deep the program paused at (0: main)
var _watches := PackedStringArray()  # watch expressions (project.cbproj [debug] watches)
var _dbg_vars: Array = []            # [name, type, value text] of the last pause, globals first
var _watch_edit: LineEdit = null
var _dbg_stop: Button = null

var _title: Label = null
var _target: OptionButton = null
var _status_icon: TextureRect = null
var _status: Label = null
var _dock: ProjectDock = null
var _left_split: VSplitContainer = null   # Scene above FileSystem
var _left_area: Control = null         # the left column: Scene / FileSystem, or the palette (Node)
var _palette_frame: Control = null
var _screens: Dictionary = {}         # "2D" / "3D" / "Script" -> its area
var _screen_buttons: Dictionary = {}
var _screen := "Script"               # the main screen showing (saved)
var _view_3d: WorldView3D = null
var _view_2d: WorldView2D = null
var _vsplit: VSplitContainer = null
var _hsplit: HSplitContainer = null
var _rsplit: HSplitContainer = null
## Panel sizes (px): the left frame's width, Properties' width, the bottom
## panel's height. Saved when a divider is dragged; these are the first ones.
var _panel_sizes := {"left": 260, "inspector": 320, "bottom": 200}
var _palette: Palette = null
var _world_dock: WorldDock = null
var _canvas: Canvas = null
var _inspector: Inspector = null
var _tab_bar: TabBar = null
var _bottom: TabContainer = null
var _problems: Tree = null
var _console: RichTextLabel = null
var _stdin: LineEdit = null
var _code_pick: OptionButton = null
var _code_view: CodeEdit = null
var _build_btn: Button = null
var _run_btn: Button = null
var _all_btn: Button = null
var _stop_btn: Button = null
var _trace_btn: Button = null
var _graph_tools: Array = []
var _node_bar: HBoxContainer = null
## Each open scene's undo history (user, 2026-11-07: viewport moves couldn't be undone):
## path -> {"undo": [snapshots], "redo": [snapshots], "last": the scene as last saved}.
var _scene_hist := {}
## Examples (user, 2026-11-08: "when the user saves it should ask them to save it as a seperate
## project somewhere on their computer"): opened as a scratch copy here (fresh each time, not
## a recent project); Save asks for a name and a folder and continues there; leaving it with
## changes asks first.
const EXAMPLE_SCRATCH := "user://example"
const NEW_HINT := "Makes a folder with project.cbproj and assets/ (no scripts yet: add nodes to the Main scene; running it runs that scene)."
var _saving_example := false
var _progress_dialog: AcceptDialog = null
var _progress_bar: ProgressBar = null
var _progress_label: Label = null
var _body: Array = []
var _start: Control = null
var _start_list: ItemList = null  # Recent Projects
var _example_list: ItemList = null  # Example Projects
var _start_filter: LineEdit = null
var _file_dialog: FileDialog = null
var _settings_dialog: AcceptDialog = null
var _tc_manager: ToolchainManager = null  # (the Toolchains window's downloads)
var _tc_rows := {}  # tool id -> its row's widgets
var _project_dialog: AcceptDialog = null
var _new_dialog: ConfirmationDialog = null


func _ready() -> void:
	theme = BrickTheme.make_app_theme()
	set_anchors_preset(PRESET_FULL_RECT)
	_load_settings()
	context.on_changed = _on_changed
	context.on_status = func(text: String) -> void: _set_status("status_warning", text)
	context.on_add_type = func(type: String) -> void: _canvas.add_node_in_view(type)
	context.on_toggle_breakpoint = toggle_breakpoint
	context.on_goto_function = goto_function
	context.on_function_renamed = _on_function_renamed
	context.selection_changed.connect(func(_id: int) -> void: _queue_redraw(Context.Redraw.PROPERTIES))
	var bg := Panel.new()
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	var column := VBoxContainer.new()
	column.set_anchors_preset(PRESET_FULL_RECT)
	column.offset_left = 6
	column.offset_right = -6
	column.offset_top = 4
	column.offset_bottom = -6
	add_child(column)
	_build_toolbar(column)
	# Left column | (middle over the bottom panel) | Properties: the bottom panel
	# (Problems / Console...) sits between FileSystem and Properties, as in Godot.
	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	split.clip_contents = true
	column.add_child(split)
	_body.append(split)
	_hsplit = split
	# Left: Godot's docks, Scene (the world's tree) on top and FileSystem below; on the
	# Node screen the brick palette takes their place.
	_left_area = Control.new()
	_left_area.custom_minimum_size.x = 140
	_left_area.size_flags_vertical = SIZE_EXPAND_FILL
	split.add_child(_left_area)
	_left_split = VSplitContainer.new()
	_left_split.set_anchors_preset(PRESET_FULL_RECT)
	_left_area.add_child(_left_split)
	_world_dock = WorldDock.new()
	_world_dock.context = context
	_world_dock.size_flags_vertical = SIZE_EXPAND_FILL
	_left_split.add_child(_framed(_dock_box("Scene", "file_mesh", _world_dock, "The objects the world starts with (world.cnworld): select one to see it in the 2D / 3D screens and Properties. Bricks find them by name: Object (Find)."), 4))
	_dock = ProjectDock.new()
	_dock.context = context
	_dock.size_flags_vertical = SIZE_EXPAND_FILL
	_dock.script_activated.connect(open_script)
	_dock.path_changed.connect(_on_path_changed)
	_dock.changed.connect(func() -> void:
		_recompile()
		if has_project():  # (the Main scene may have changed)
			_world_dock.show_scenes(_scene_paths, context.scene_path, CBProject.world_path(project_dir)))
	_left_split.add_child(_framed(_dock_box("FileSystem", "project", _dock, "The project's folder: scripts and assets"), 4))
	context.on_world_changed = _on_world_changed
	context.on_new_scene = func() -> void:
		if has_project():
			_dock._ask_new_scene("")
	context.on_script_object_renamed = _on_script_object_renamed
	context.script_side = func(rel: String) -> String: return str(_script_graph(project_dir.path_join(rel)).get("side", "Shared"))
	context.on_script_side = _set_script_side
	context.on_open_script = func(rel: String) -> void: open_script(project_dir.path_join(rel))
	context.on_open_scene = func(rel: String) -> void: open_scene(project_dir.path_join(rel))
	_world_dock.scene_picked.connect(func(p: String) -> void: open_scene.call_deferred(p, false))
	_world_dock.scene_closed.connect(func(p: String) -> void: close_scene.call_deferred(p))
	var snap := WorldSnapshot.new()
	add_child(snap)
	context.snapshotter = snap
	var right_split := HSplitContainer.new()
	split.add_child(right_split)
	_rsplit = right_split
	var vsplit := VSplitContainer.new()
	vsplit.size_flags_horizontal = SIZE_EXPAND_FILL
	vsplit.size_flags_vertical = SIZE_EXPAND_FILL
	right_split.add_child(vsplit)
	_vsplit = vsplit
	for sc in [_vsplit, _hsplit, _rsplit, _left_split]:
		sc.dragged.connect(func(_offset: int) -> void: _remember_panel_sizes.call_deferred())
	# Middle: the main screens' switcher (2D, 3D, Node: Godot's), the script tabs under it
	# (only on the Node screen), then the screen showing.
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = SIZE_EXPAND_FILL
	middle.size_flags_vertical = SIZE_EXPAND_FILL
	# Small enough that the bottom panel (Problems / Console / Generated C) always fits.
	middle.custom_minimum_size.y = 100
	middle.add_theme_constant_override(&"separation", 2)
	vsplit.add_child(middle)
	var switcher := HBoxContainer.new()
	switcher.alignment = BoxContainer.ALIGNMENT_CENTER
	middle.add_child(switcher)
	for which in [["2D", "2D", "file_image", "The game window and its Labels (2D)"], ["3D", "3D", "file_mesh", "The world in 3D: select and move its objects"], ["Script", "Bricks", "script", "The scripts' bricks (C-Bricks' visual scripting)"]]:
		var b := Button.new()
		b.text = which[1]
		b.icon = context.brick_theme.icon(which[2])
		b.toggle_mode = true
		b.tooltip_text = which[3]
		# Not `flat` (a flat Button draws no stylebox): the others look flat by their own boxes.
		var off := StyleBoxEmpty.new()
		off.set_content_margin_all(4)
		var hover := StyleBoxFlat.new()
		hover.bg_color = Color(1, 1, 1, 0.06)
		hover.set_corner_radius_all(3)
		hover.set_content_margin_all(4)
		b.add_theme_stylebox_override(&"normal", off)
		b.add_theme_stylebox_override(&"hover", hover)
		b.add_theme_stylebox_override(&"focus", StyleBoxEmpty.new())
		# The screen showing: an accent tint, an underline and accent text (Godot's main screen buttons).
		var on := StyleBoxFlat.new()
		on.bg_color = Color(BrickTheme.ACCENT, 0.18)
		on.border_color = BrickTheme.ACCENT
		on.border_width_bottom = 2
		on.set_corner_radius_all(3)
		on.set_content_margin_all(4)
		b.add_theme_stylebox_override(&"pressed", on)
		b.add_theme_stylebox_override(&"hover_pressed", on)
		b.add_theme_color_override(&"font_pressed_color", BrickTheme.ACCENT)
		b.add_theme_color_override(&"font_hover_pressed_color", BrickTheme.ACCENT)
		b.add_theme_color_override(&"icon_pressed_color", BrickTheme.ACCENT)
		b.pressed.connect(switch_screen.bind(which[0]))
		switcher.add_child(b)
		_screen_buttons[which[0]] = b

	_tab_bar = TabBar.new()
	_tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	_tab_bar.clip_tabs = true
	_tab_bar.max_tab_width = 180
	_tab_bar.tab_changed.connect(func(i: int) -> void:
		if i != _cur and i >= 0 and i < _tabs.size():  # (closing the last tab reports -1)
			_switch_tab(i))
	_tab_bar.tab_close_pressed.connect(close_tab)
	_tab_bar.size_flags_horizontal = SIZE_EXPAND_FILL
	# The Node screen's toolbar (user, 2026-11-07): the script tabs, then the brick tools
	# (only shown on Node).
	_node_bar = HBoxContainer.new()
	_node_bar.add_child(_tab_bar)
	for spec in [["Close", "close", func() -> void: close_tab(_cur), "Close this script's tab (Ctrl+W; it's saved first)"],
			["Find", "search", open_find, "Find a brick in any script (Ctrl+F)"],
			["Frame", "frame", func() -> void: _canvas.add_frame_here(), "Add a comment frame: around the selected bricks, or in the middle of the view"],
			["Arrange", "arrange", func() -> void: _canvas.arrange_chains(), "Space the chains: each brick two grid squares after the one it follows (the selected bricks' chains, or all)"]]:
		var button := Button.new()
		button.text = spec[0]
		button.flat = true
		button.icon = context.brick_theme.icon(spec[1])
		button.tooltip_text = spec[3]
		button.pressed.connect(func() -> void: spec[2].call())
		_node_bar.add_child(button)
		_graph_tools.append(button)
	middle.add_child(_node_bar)
	var screens := Control.new()
	screens.size_flags_horizontal = SIZE_EXPAND_FILL
	screens.size_flags_vertical = SIZE_EXPAND_FILL
	screens.clip_contents = true
	middle.add_child(screens)
	# Node: the brick palette in the left column (in place of Scene / FileSystem), the canvas here.
	_palette = Palette.new()
	_palette.context = context
	_palette.size_flags_vertical = SIZE_EXPAND_FILL
	_palette.add_requested.connect(func(type: String) -> void: _canvas.add_node_in_view(type))
	_palette_frame = _framed(_palette, 4)
	_palette_frame.set_anchors_preset(PRESET_FULL_RECT)
	_left_area.add_child(_palette_frame)
	var center := VBoxContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	center.add_theme_constant_override(&"separation", 0)
	screens.add_child(center)
	_canvas = Canvas.new()
	_canvas.context = context
	_palette.canvas = _canvas
	center.add_child(_framed(_canvas, 1))
	_view_3d = WorldView3D.new()
	_view_3d.context = context
	var frame_3d := _framed(_view_3d, 1)
	frame_3d.set_anchors_preset(PRESET_FULL_RECT)
	screens.add_child(frame_3d)
	_view_2d = WorldView2D.new()
	_view_2d.context = context
	var frame_2d := _framed(_view_2d, 1)
	frame_2d.set_anchors_preset(PRESET_FULL_RECT)
	screens.add_child(frame_2d)
	_screens = {"Script": center, "3D": frame_3d, "2D": frame_2d}
	switch_screen(_screen)
	_inspector = Inspector.new()
	_inspector.context = context
	_inspector.custom_minimum_size.x = 150
	_inspector.size_flags_vertical = SIZE_EXPAND_FILL
	right_split.add_child(_framed(_inspector))
	_build_bottom(vsplit)
	_build_start(column)
	_build_dialogs()
	get_tree().set_auto_accept_quit(false)
	get_window().close_requested.connect(_quit)
	get_window().files_dropped.connect(func(files: PackedStringArray) -> void: _dock.import_files(files))
	get_window().min_size = Vector2i(640, 420)
	close_project()
	# example copies no longer in Recent Projects (left over) go
	var scratch := ProjectSettings.globalize_path(EXAMPLE_SCRATCH)
	for d in (DirAccess.get_directories_at(scratch) if DirAccess.dir_exists_absolute(scratch) else PackedStringArray()):
		if not scratch.path_join(d) in _recent:
			_remove_tree(scratch.path_join(d))
	var last := _recent[0] if not _recent.is_empty() else ""
	if last != "" and CBProject.is_project(last):
		open_project(last)
	if not Toolchains.can_execute():
		_log_info("Running in a browser: building is off, but Export downloads the C project as a .zip.")


# ======================================================================= projects

func has_graph() -> bool:
	return _cur >= 0


func has_project() -> bool:
	return project_dir != ""


func open_project(dir: String) -> void:
	dir = dir.trim_suffix("/")
	if dir.get_file() == CBProject.FILE:
		dir = dir.get_base_dir()
	if not CBProject.is_project(dir):
		_set_status("status_error", "%s is not a C-Bricks project (no %s)." % [dir, CBProject.FILE])
		_forget_recent(dir)
		return
	close_project()
	project_dir = dir
	var cf := CBProject.load_config(dir)
	var tid := str(cf.get_value("build", "target", "native"))
	for i in Toolchains.TARGETS.size():
		if Toolchains.TARGETS[i].id == tid:
			_target.select(i)
	_trace_btn.set_pressed_no_signal(bool(cf.get_value("run", "trace", false)))
	_watches = PackedStringArray(cf.get_value("debug", "watches", PackedStringArray()))
	# An old project's world.cnworld becomes main.cbscene (the Main scene).
	var renamed := CBProject.upgrade_names(dir)  # (a C-Nodes project: its files renamed)
	var upgraded := CBProject.upgrade_world(dir)
	context.project_dir = dir
	_scene_paths.clear()
	_scene_hist.clear()
	open_scene(CBProject.world_path(dir), false)
	_view_2d.rebuild(dir)
	_dbg_vars = []
	_fill_watches()
	_dock.set_project(dir)
	_show_body(true)
	_add_recent(dir)
	_recompile()
	var scripts := CBProject.list_scripts(dir)
	var first: String = _build.get("main", "")
	if first == "" and not scripts.is_empty():
		first = scripts[0]
	if first != "":
		open_script(first)
	else:
		switch_screen("3D")  # (no scripts yet: a new project starts with its Main scene)
	_update_title()
	_update_target_state()
	_set_status("status_success", "Opened %s" % CBProject.project_name(dir))
	if renamed:
		_log_info("Upgraded this project from C-Nodes: project.cnproj, .cnodes and .cnscene files are now project.cbproj, .cbricks and .cbscene.")
	if upgraded:
		_log_info("Upgraded this project: world.cnworld is now main.cbscene, the Main scene.")


func close_project() -> void:
	if has_project():
		save_all()
	_scene_paths.clear()
	_scene_hist.clear()
	context.scene_path = ""
	for t in _tabs:
		t.undo.free()
	_tabs.clear()
	_cur = -1
	if _tab_bar != null:
		_tab_bar.clear_tabs()
	context.graph = {}
	context.selected = 0
	context.info_type = ""
	context.error_bricks = {}
	context.misplaced_bricks = {}
	Ops.extra_funcs = {}
	_compile_problems.clear()
	project_dir = ""
	_build = {}
	if _dock != null:
		_dock.set_project("")
	_show_body(false)
	refresh_start()
	_update_title()


## Opens an example: copied into Documents/Projects/C-Bricks first (so it's yours).
## An example (user, 2026-11-08): a new copy every time (in the app's data, numbered), opened
## and put in Recent Projects, where it carries on where it was left. Save asks where to keep
## it as a project of your own.
func open_example(res_dir: String) -> void:
	var base := ProjectSettings.globalize_path(EXAMPLE_SCRATCH).path_join(res_dir.trim_suffix("/").get_file())
	var to := base
	var n := 2
	while DirAccess.dir_exists_absolute(to):
		to = "%s-%d" % [base, n]
		n += 1
	DirAccess.make_dir_recursive_absolute(to.get_base_dir())
	if CBProject.copy_dir(res_dir, to) != OK:
		_set_status("status_error", "Couldn't open the example (copying it to %s)" % to)
		return
	open_project(to)
	_log_info("A new copy of the example (in Recent Projects as an example copy): change it and run it as you like. Save asks where to keep it as a project of your own.")
	_set_status("status_info", "A new copy of %s: Save asks where to keep it as your project." % CBProject.project_name(to))


## Whether the open project is an example's scratch copy.
func _is_example() -> bool:
	return has_project() and project_dir.begins_with(ProjectSettings.globalize_path(EXAMPLE_SCRATCH))


static func _remove_tree(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


# ======================================================================= scripts (tabs)

func open_script(path: String) -> void:
	if path.get_file() == CBProject.WORLD_FILE or path.get_extension() == CBProject.SCENE_EXT:
		open_scene(path)
		return
	if _screen != "Script":
		switch_screen("Script")
	for i in _tabs.size():
		if _tabs[i].path == path:
			_switch_tab(i)
			return
	var graph := CBProject.read_script(path)
	if graph.is_empty():
		_set_status("status_error", "%s is not a C-Bricks script." % path.get_file())
		return
	var tab := {"path": path, "graph": graph, "dirty": false, "undo": UndoRedo.new(), "snapshot": graph.duplicate(true), "view": {}, "errors": {}}
	_tabs.append(tab)
	_tab_bar.add_tab(path.get_file())
	_tab_bar.set_tab_tooltip(_tabs.size() - 1, CBProject.rel_path(project_dir, path))
	_switch_tab(_tabs.size() - 1)
	if graph.has("view"):
		_apply_view.call_deferred({"scroll": Vector2(graph.view.scroll[0], graph.view.scroll[1]), "zoom": float(graph.view.zoom)})
	else:
		_bricks_into_view.call_deferred()


func _tab() -> Dictionary:
	return _tabs[_cur] if _cur >= 0 and _cur < _tabs.size() else {}


func _switch_tab(i: int) -> void:
	Context.commit_focused(self)
	if has_graph():
		_tab().view = {"scroll": _canvas.scroll_offset, "zoom": _canvas.zoom}
	_cur = i
	if _tab_bar.current_tab != i:
		_tab_bar.current_tab = i
	var t := _tab()
	context.graph = t.graph
	context.graph_path = t.path
	context.selected = 0
	context.info_type = ""
	context.error_bricks = t.errors
	context.paused_brick = _paused_brick if t.path == _paused_script else 0
	_recompile()
	_queue_redraw(Context.Redraw.ALL)
	if not t.view.is_empty():
		_apply_view.call_deferred(t.view)
	_update_title()


func close_tab(i: int) -> void:
	if i < 0 or i >= _tabs.size():
		return
	var t: Dictionary = _tabs[i]
	if t.dirty:
		_save_tab(t)
	t.undo.free()
	_tabs.remove_at(i)
	_tab_bar.remove_tab(i)
	_cur = -1
	if _tabs.is_empty():
		context.graph = {}
		context.selected = 0
		_canvas.clear_connections()
		for v in _canvas.views() + _canvas.frame_views():
			v.queue_free()
		_inspector.rebuild()
		_recompile()
		_update_title()
		return
	_switch_tab(mini(i, _tabs.size() - 1))


func save() -> void:
	if _is_example():  # (an example: kept here for now, then asked where to keep it)
		save_all()
		_ask_save_example()
		return
	if has_graph():
		_save_tab(_tab())
		_set_status("status_success", "Saved %s" % _tab().path.get_file())


func save_all() -> void:
	for t in _tabs:
		if t.dirty:
			_save_tab(t)


func _save_tab(t: Dictionary) -> void:
	var data: Dictionary = t.graph.duplicate(true)
	if has_graph() and t.path == _tab().path:
		data["view"] = {"scroll": [_canvas.scroll_offset.x, _canvas.scroll_offset.y], "zoom": _canvas.zoom}
	if CBProject.write_script(t.path, data) != OK:
		_set_status("status_error", "Could not save %s" % t.path)
		return
	t.dirty = false
	_update_title()


## The dock renamed / deleted a file or folder: tabs follow it.
## A Script object renamed in Properties: its file gets a safe version of the name
## ("Script Test" -> scripts/script-test.cbricks); scenes, tabs and builds follow.
func _on_script_object_renamed(o: Dictionary) -> void:
	var old_rel := str(o.get("script", ""))
	if old_rel == "" or not has_project():
		return
	var file := CBProject.safe_name(str(o.name)) + "." + CBProject.SCRIPT_EXT
	var to_rel := file if old_rel.get_base_dir() == "" else old_rel.get_base_dir() + "/" + file
	if to_rel == old_rel:
		return
	var from_abs := project_dir.path_join(old_rel)
	var to_abs := project_dir.path_join(to_rel)
	if FileAccess.file_exists(to_abs):
		_set_status("status_info", "%s already exists: the script keeps its file %s." % [to_rel, old_rel])
		return
	if DirAccess.rename_absolute(from_abs, to_abs) != OK:
		_set_status("status_info", "Couldn't rename %s." % old_rel)
		return
	CBProject.repoint(project_dir, old_rel, to_rel)  # the other scenes' Script objects
	for x in context.world.get("objects", []):
		if str(x.get("script", "")) == old_rel:
			x["script"] = to_rel  # (this scene: saved with the rename)
	_set_status("status_info", "Renamed %s to %s." % [old_rel, to_rel])
	_on_path_changed(from_abs, to_abs)
	if _dock != null:
		_dock.refresh()


func _on_path_changed(from: String, to: String) -> void:
	for i in range(_tabs.size() - 1, -1, -1):
		var p: String = _tabs[i].path
		if p == from or p.begins_with(from + "/"):
			if to == "":
				_tabs[i].dirty = false
				close_tab(i)
			else:
				_tabs[i].path = to + p.substr(from.length())
	# Scenes open over the Scene tree follow too (a deleted one closes).
	for i in range(_scene_paths.size() - 1, -1, -1):
		var sp: String = _scene_paths[i]
		if sp == from or sp.begins_with(from + "/"):
			if to == "":
				if sp == context.scene_path:
					context.scene_path = ""
				_scene_paths.remove_at(i)
			else:
				_scene_paths[i] = to + sp.substr(from.length())
				if context.scene_path == sp:
					context.scene_path = _scene_paths[i]
	if has_project():
		if _scene_paths.is_empty() or context.scene_path == "":
			open_scene(CBProject.world_path(project_dir), false)
		else:
			_world_dock.show_scenes(_scene_paths, context.scene_path, CBProject.world_path(project_dir))
	_update_title()
	_recompile()


func undo() -> void:
	if _screen != "Script":
		_scene_step(true)
		return
	if has_graph() and _tab().undo.has_undo():
		_tab().undo.undo()
		_set_status("status_info", "Undo: " + _tab().undo.get_current_action_name())


func redo() -> void:
	if _screen != "Script":
		_scene_step(false)
		return
	if has_graph() and _tab().undo.has_redo():
		_tab().undo.redo()
		_set_status("status_info", "Redo: " + _tab().undo.get_current_action_name())


# ======================================================================= changes

func _on_changed(redraw: int, action: String = "Edit") -> void:
	if not has_graph():
		return
	_tab().dirty = true
	_queue_redraw(redraw)
	_recompile()
	_update_title()
	_record(action)


func _record(action: String) -> void:
	var t := _tab()
	var before: Dictionary = t.snapshot
	var after: Dictionary = t.graph.duplicate(true)
	if after == before:
		return
	t.snapshot = after
	t.undo.create_action(action)
	t.undo.add_do_method(_restore.bind(t, after))
	t.undo.add_undo_method(_restore.bind(t, before))
	t.undo.commit_action(false)


func _restore(t: Dictionary, data: Dictionary) -> void:
	t.graph.clear()
	t.graph.merge(data.duplicate(true))
	t.snapshot = data
	t.dirty = true
	if has_graph() and t.path == _tab().path:
		if context.selected_node().is_empty() and Ops.frame_by_id(context.graph, context.selected).is_empty():
			context.selected = 0
		_recompile()
		_queue_redraw(Context.Redraw.ALL)
	_update_title()


func _queue_redraw(redraw: int) -> void:
	if redraw == Context.Redraw.NONE:
		return
	if _pending_redraw == 0:
		_flush_redraw.call_deferred()
	_pending_redraw |= redraw


func _flush_redraw() -> void:
	var redraw := _pending_redraw
	_pending_redraw = 0
	if has_graph():
		_redraw(redraw)
	elif redraw & Context.Redraw.PROPERTIES:
		# No script open (only scenes): a pick in the Scene tree / 2D / 3D screens still has to show in
		# Properties (user, 2026-11-09: it sometimes didn't answer for plain objects).
		_inspector.rebuild()


func _redraw(redraw: int) -> void:
	if redraw & Context.Redraw.PALETTE:
		_palette.rebuild()
	if redraw & Context.Redraw.CANVAS:
		_canvas.rebuild()
	if redraw & Context.Redraw.PROPERTIES:
		_inspector.rebuild()


## Regenerates the whole project's C (open scripts as they are in the editor).
func _recompile() -> void:
	if not has_project():
		return
	var open := {}
	for t in _tabs:
		open[t.path] = t.graph
	_build = ProjectBuild.generate(project_dir, open, _current_target() if _target != null else "native")
	_target_problems = ProjectBuild.target_problems(_build, _current_target()) if _target != null else []
	# Bricks in the wrong place (greyed on the canvas) and what the palette greys (2026-11-08).
	var cur_path: String = _tab().path if has_graph() else ""
	var misplaced := {}
	for e in _build.errors + _target_problems:
		if bool(e.get("context", false)) and str(e.script) == cur_path and int(e.node) > 0:
			misplaced[int(e.node)] = str(e.msg)
	var old_misplaced := context.misplaced_bricks
	var palette_key := [context.target_id, context.script_class, context.graph.get("side", "") if has_graph() else ""]
	context.misplaced_bricks = misplaced
	context.target_id = _current_target() if _target != null else "native"
	context.script_class = str(_build.scripts.get(cur_path, {}).get("class", "")) if cur_path != "" else ""
	if has_graph() and palette_key != [context.target_id, context.script_class, context.graph.get("side", "")]:
		_queue_redraw(Context.Redraw.PALETTE | Context.Redraw.CANVAS)
	elif has_graph() and old_misplaced != misplaced:
		_queue_redraw(Context.Redraw.CANVAS)
	# The other scripts' functions, for Call Function.
	var extra := {}
	for p in _build.scripts:
		if has_graph() and p == _tab().path:
			continue
		var g: Dictionary = open.get(p, {})
		if g.is_empty():
			g = CBProject.read_script(p)
		extra.merge(T.collect_functions(g.get("nodes", [])))
	Ops.extra_funcs = extra
	context.records = _build.get("records", {})
	if _world_dock != null:
		_world_dock.rebuild()
	if has_graph() and _build.scripts.has(_tab().path):
		var res: Dictionary = _build.scripts[_tab().path].result
		context.scopes = res.scopes
		context.types = res.types
	if _dock.main_script != _build.get("main", ""):
		_dock.main_script = _build.get("main", "")
		_dock.refresh()
	_fill_code_pick()
	_problems.clear()
	_problems.create_item()
	var count_errors := 0
	for p in _compile_problems:
		_add_problem("status_error" if p.kind == "error" else "status_warning", p.msg, p.script, p.node)
	for e in _build.errors + _target_problems:
		_add_problem("status_error", _where(e.script) + e.msg if not str(e.script).ends_with(CBProject.SCENE_EXT) else e.msg, e.script, e.node, int(e.get("world_id", 0)))
		count_errors += 1
	for w in _build.warnings:
		_add_problem("status_warning", _where(w.script) + w.msg, w.script, w.node)
	var n_problems := _problems.get_root().get_child_count()
	_bottom.set_tab_title(0, "Problems (%d)" % n_problems if n_problems > 0 else "Problems")
	if count_errors > 0 and _build.errors.is_empty():
		_set_status("status_error", "%d problem(s): %s can't build this project" % [count_errors, Toolchains.target(_current_target()).name])
	elif count_errors > 0:
		_set_status("status_error", "%d problem(s): the C can't be generated yet" % count_errors)
	elif not _build.warnings.is_empty():
		_set_status("status_warning", "Ready, with %d warning(s)" % _build.warnings.size())
	else:
		var lines := 0
		for f in _build.files.values():
			lines += f.count("\n")
		_set_status("status_success", "Ready · %d script(s), %d lines of C" % [_build.scripts.size(), lines])


## "scripts/util.cbricks: " for a problem in a script other than the open one.
func _where(script: String) -> String:
	if script == "" or (has_graph() and script == _tab().path):
		return ""
	return CBProject.rel_path(project_dir, script) + ": "


## One problem: a row of the Problems list (a Tree, so long problems wrap).
func _add_problem(icon_name: String, text: String, script: String, node_id: int, world_id := 0) -> void:
	var it := _problems.create_item(_problems.get_root())
	it.set_text(0, text)
	it.set_icon(0, context.brick_theme.icon(icon_name))
	it.set_autowrap_mode(0, TextServer.AUTOWRAP_WORD_SMART)
	it.set_metadata(0, [script, node_id, world_id])
	it.set_tooltip_text(0, "Click to show the brick." if node_id > 0 else "")


## The text of the index-th problem ("" if there's none).
func problem_text(index: int) -> String:
	var root := _problems.get_root()
	return root.get_child(index).get_text(0) if root != null and index >= 0 and index < root.get_child_count() else ""


func _on_problem_selected(index: int = -1) -> void:
	var root := _problems.get_root()
	var it: TreeItem = root.get_child(index) if index >= 0 and root != null and index < root.get_child_count() else _problems.get_selected()
	if it == null or not it.get_metadata(0) is Array:
		return
	var m: Array = it.get_metadata(0)
	if m[0] == "":
		return
	if str(m[0]).get_extension() in [CBProject.SCENE_EXT, "cnworld"]:
		open_scene(m[0])  # a scene's problem: the scene, its object picked
		var wid := int(m[2]) if m.size() > 2 else 0
		if wid != 0:
			for o in context.world.get("objects", []):
				if int(o.id) == wid:
					context.show_world_object(o)
		return
	if not has_graph() or _tab().path != m[0]:
		open_script(m[0])
	if int(m[1]) > 0:
		_flush_redraw()
		_canvas.show_node.call_deferred(int(m[1]))


func _fill_code_pick() -> void:
	var keep := _code_pick.get_item_text(_code_pick.selected) if _code_pick.item_count > 0 and _code_pick.selected >= 0 else ""
	if has_graph() and _build.scripts.has(_tab().path) and not _code_pick.has_meta(&"user_pick"):
		keep = _build.scripts[_tab().path].c
	_code_pick.clear()
	var names: Array = _build.get("files", {}).keys()
	names.sort()
	for n in names:
		_code_pick.add_item(n)
	var at := names.find(keep)
	if names.size() > 0:
		_code_pick.select(at if at >= 0 else 0)
	_show_code()


func _show_code() -> void:
	if _code_pick.item_count == 0:
		_code_view.text = ""
		return
	var text: String = _build.files.get(_code_pick.get_item_text(_code_pick.selected), "")
	if _code_view.text != text:
		var scroll := _code_view.scroll_vertical
		_code_view.text = text
		_code_view.scroll_vertical = scroll


# ======================================================================= build / run

func _program_name() -> String:
	return CBProject.program_name(project_dir)


func _current_target() -> String:
	return Toolchains.TARGETS[_target.selected].id


func _busy() -> bool:
	return (_thread != null and _thread.is_alive()) or not _proc.is_empty()


func _ready_to_build() -> bool:
	if not Toolchains.can_execute() or _busy() or not has_project():
		return false
	save_all()
	_recompile()
	if not _build.errors.is_empty():
		_bottom.current_tab = 0
		_set_status("status_error", "Fix the problems first: the C can't be generated yet.")
		return false
	return true


func _target_ok() -> bool:
	if _target_problems.is_empty():
		return true
	_bottom.current_tab = 0
	_set_status("status_error", "%s can't build this project: see Problems" % Toolchains.target(_current_target()).name)
	return false


func _gen_dir() -> String:
	return project_dir.path_join(CBProject.BUILD_DIR).path_join("src")


## The first build in an exported editor unpacks the compilers from inside it (user, 2026-11-09: one
## single file), with a progress window; then `then` goes on. Without a pack it goes straight on.
func _with_toolchains(then: Callable) -> void:
	if not Toolchains.pack_pending():
		then.call()
		return
	if _busy():
		return
	_progress_label.text = "Unpacking the compilers (first time only) ..."
	_progress_bar.value = 0
	_progress_dialog.title = "Getting ready to build"
	_progress_dialog.popup_centered(Vector2i(520, 0))
	_set_busy(true)
	_join_thread()
	_thread = Thread.new()
	_thread.start(func() -> void:
		var err := Toolchains.unpack(func(done: int, total: int, what: String) -> void:
			_export_progress.call_deferred(done, total, what))
		_unpacked.call_deferred(err, then))


func _unpacked(err: String, then: Callable) -> void:
	_join_thread()
	_set_busy(false)
	_progress_dialog.hide()
	if err != "":
		_set_status("status_error", "Unpacking the compilers failed: " + err)
		return
	then.call()


func build(run: bool) -> void:
	if Toolchains.pack_pending() and _ready_to_build() and _target_ok():
		_with_toolchains(func() -> void: build(run))
		return
	if not _ready_to_build() or not _target_ok():
		return
	var id := _current_target()
	var srcs := ProjectBuild.write(_build, _gen_dir())
	var dir := project_dir.path_join(CBProject.BUILD_DIR).path_join(id)
	_bottom.current_tab = 1
	_log_info("Building %s for %s..." % [CBProject.project_name(project_dir), Toolchains.target(id).name])
	_set_busy(true)
	_join_thread()
	_thread = Thread.new()
	var base := _program_name()
	var pdir := project_dir
	var graphics: bool = _build.get("graphics", false)
	_thread.start(func() -> void:
		# (an unchanged program is reused: Toolchains.cached_build; raylib is only built when
		# something must be compiled for real)
		var r := Toolchains.cached_build(id, srcs, dir, base, "", graphics)
		if id == "dos" and r.ok:  # MS-DOS plays 8-bit 22 kHz WAVs: this project's audio, converted beside the program
			var a := Toolchains.dos_audio(pdir, dir)
			if a.converted > 0:
				r["output"] = str(r.output) + "Converted %d audio file(s) for MS-DOS (8-bit, mono, 22 kHz).\n" % a.converted
			if not a.ok:
				r["output"] = str(r.output) + "MS-DOS audio: " + str(a.output)
		_on_built.call_deferred(id, r, run))


func _on_built(id: String, r: Dictionary, run: bool) -> void:
	_join_thread()
	_set_busy(false)
	if r.command != "":
		_console.push_color(Color(0.6, 0.6, 0.7)); _console.add_text("$ " + r.command + "\n"); _console.pop()
	if r.output.strip_edges() != "":
		_console.push_color(Color(1, 0.75, 0.5) if r.ok else Color(1, 0.5, 0.5)); _console.add_text(r.output.strip_edges() + "\n"); _console.pop()
	_map_compiler_output(r.output)
	if not r.ok:
		_log_error("Build failed (exit %d)." % r.exit)
		_set_status("status_error", "Build failed: see Problems")
		if not _compile_problems.is_empty():
			_bottom.current_tab = 0
		return
	var how: String = {"project": " (unchanged since its last build: reused)", "cache": " (built before: reused from the build cache)", "prebuilt": " (compiled with C-Bricks: reused)"}.get(str(r.get("cached", "")), "")
	_console.append_text("[color=#80e080]Built[/color] [url=file:%s]%s[/url]%s\n" % [r.out.get_base_dir(), r.out, how])
	_set_status("status_success", "Built %s" % r.out.get_file())
	if run:
		_run(id, r.out)


## A C compiler's "scripts__util.c:12:5: error: ..." lines, put on their bricks.
func _map_compiler_output(output: String) -> void:
	_compile_problems.clear()
	var by_c := {}
	for p in _build.scripts:
		by_c[_build.scripts[p].c] = p
	for t in _tabs:
		t.errors.clear()
	var re := RegEx.create_from_string(ERROR_LINE)
	for m in re.search_all(output):
		var cfile := m.get_string(1)
		var line := m.get_string(2).to_int()
		var kind := m.get_string(4)
		var msg := m.get_string(5).strip_edges()
		var script: String = by_c.get(cfile, "")
		var id := CodeGen.brick_of_line(_build.files.get(cfile, ""), line)
		var where := "%s line %d" % [cfile, line]
		if script != "":
			var g: Dictionary = {}
			for t in _tabs:
				if t.path == script:
					g = t.graph
					if kind == "error" and id > 0 and not t.errors.has(id):
						t.errors[id] = msg
			if g.is_empty():
				g = CBProject.read_script(script)
			var n := Ops.node_by_id(g, id) if id > 0 else {}
			if not n.is_empty():
				where = "%s, %s (node %d)" % [CBProject.rel_path(project_dir, script), T.title_of(n.type, n.fields), id]
		_compile_problems.append({"script": script, "node": id, "msg": "C compiler %s in %s: %s" % [kind, where, msg], "kind": kind})
	_recompile()
	_queue_redraw(Context.Redraw.CANVAS)


## The project's C for a target (its graphics backend differs: raylib, or MS-DOS's own), as
## files on disk: the sources to compile. Generated here, on the main thread (it uses the
## classes' shared tables).
func _sources_for(id: String, dir: String) -> Array:
	var open := {}
	for t in _tabs:
		open[t.path] = t.graph
	var r := ProjectBuild.generate(project_dir, open, id)
	return Array(ProjectBuild.write(r, dir))


func build_all() -> void:
	if Toolchains.pack_pending() and _ready_to_build():
		_with_toolchains(build_all)
		return
	if not _ready_to_build():
		return
	# Each target gets its own generated C (MS-DOS draws with its own backend, the rest with raylib's).
	var srcs_by := {}
	for t in Toolchains.TARGETS:
		if t.id == "native" or Toolchains.resolve_command(t.id) == "" or not ProjectBuild.target_problems(_build, t.id).is_empty():
			continue
		var kind := "dos" if t.id == "dos" else "native"
		if not srcs_by.has(kind):
			srcs_by[kind] = _sources_for(kind, _gen_dir() if kind == "native" else _gen_dir() + "_dos")
	var dir := project_dir.path_join(CBProject.BUILD_DIR).path_join("all")
	var base := _program_name()
	_bottom.current_tab = 1
	_log_info("Building every target that has a toolchain into %s ..." % dir)
	_set_busy(true)
	_join_thread()
	_thread = Thread.new()
	var graphics: bool = _build.get("graphics", false)
	_thread.start(func() -> void:
		var results := []
		for t in Toolchains.TARGETS:
			if t.id == "native":
				continue
			var cmd := Toolchains.resolve_command(t.id)
			if cmd == "":
				results.append([t.name, null])
				continue
			if not ProjectBuild.target_problems(_build, t.id).is_empty():
				results.append([t.name + " (it can't do everything this project uses)", null])
				continue
			_log_info.call_deferred("  building %s..." % t.name)
			results.append([t.name, Toolchains.cached_build(t.id, srcs_by["dos" if t.id == "dos" else "native"], dir, base, cmd, graphics)])
		_on_built_all.call_deferred(results, dir))


func _on_built_all(results: Array, dir: String) -> void:
	_join_thread()
	_set_busy(false)
	var ok := 0
	for r in results:
		if r[1] == null:
			_console.append_text("[color=#777788]  –  %s: no toolchain installed[/color]\n" % r[0])
		elif r[1].ok:
			ok += 1
			_console.append_text("[color=#80e080]  ✓  %s[/color] → %s\n" % [r[0], r[1].out.get_file()])
		else:
			_console.append_text("[color=#ff7070]  ✗  %s[/color]\n" % r[0])
			_console.push_color(Color(1, 0.6, 0.6)); _console.add_text(r[1].output.strip_edges().indent("       ") + "\n"); _console.pop()
	_set_status("status_success" if ok > 0 else "status_warning", "Built for %d target(s)" % ok)
	_console.append_text("[url=file:%s]Open the build folder[/url]\n" % dir)


## The program's arguments: --cd to the project (so it finds its assets),
## --trace when Trace is on, then the project's run arguments.
func _run_args() -> PackedStringArray:
	var args := PackedStringArray(["--cd", project_dir])
	if _trace_btn.button_pressed:
		args.append("--trace")
	# The debugger: always on from the editor (Pause works any time); breakpoints of every script.
	_debug_cmd = project_dir.path_join(CBProject.BUILD_DIR).path_join("debug.cmd")
	var fa := FileAccess.open(_debug_cmd, FileAccess.WRITE)
	if fa != null:
		fa.close()
	args.append_array(["--debug", _debug_cmd])
	var bps := _all_breakpoints()
	if not bps.is_empty():
		args.append_array(["--break", ",".join(bps)])
	var extra := str(CBProject.load_config(project_dir).get_value("run", "args", "")).strip_edges()
	if extra != "":
		args.append_array(Toolchains.split_command(extra))
	return args


func _run(id: String, out: String) -> void:
	var runner := Toolchains.resolve_runner(id)
	if runner == "":
		_log_info("Built for another platform: copy %s (and the project's assets) to a %s machine to run it." % [out.get_file(), Toolchains.target(id).name])
		return
	if runner.begins_with("@open"):
		OS.shell_open(out)
		_log_info("Opened in your browser.")
		return
	if runner == "@dosbox":
		# (in DOSBox-X's window: the program's text is there; no trace or debugger in DOS)
		var extra := str(CBProject.load_config(project_dir).get_value("run", "args", "")).strip_edges()
		var dr := Toolchains.dos_run(out, Toolchains.split_command(extra) if extra != "" else PackedStringArray(), project_dir)
		var pid := OS.create_process(dr.prog, dr.argv)
		if pid <= 0:
			_log_error("Couldn't start %s" % dr.prog)
			return
		_console.append_text("[color=#80b0ff]── running %s in DOSBox-X (its window; a key closes it at the end) ──[/color]\n" % out.get_file())
		return
	var argv := Toolchains.expand(runner, {"out": out})
	var prog := argv[0] if argv[0].is_absolute_path() else Toolchains.find_program(argv[0])
	argv.remove_at(0)
	var run_args := _run_args()
	argv.append_array(run_args)
	var p := OS.execute_with_pipe(prog, argv, false)
	if p.is_empty():
		_log_error("Couldn't start %s" % prog)
		return
	_proc = p
	_stderr_tail = ""
	_stop_btn.disabled = false
	_set_busy(true)
	var shown := Array(run_args.slice(2)).filter(func(a): return a != "--debug" and a != _debug_cmd)
	var bi := shown.find("--break")
	if bi >= 0:
		shown.remove_at(bi + 1)
		shown.remove_at(bi)
	_console.append_text("[color=#80b0ff]── running %s %s ──[/color]\n" % [out.get_file(), " ".join(shown)])
	_set_debug_state("Running. Pause (F8) stops it at the next brick; breakpoints (F9) stop it there.")
	_stdin.grab_focus()


func _process(_delta: float) -> void:
	if not _flash_pending.is_empty():
		_canvas.flash(_flash_pending)
		_flash_pending.clear()
	if _proc.is_empty():
		return
	var io: FileAccess = _proc.stdio
	var er: FileAccess = _proc.stderr
	var got := false
	var b := io.get_buffer(8192)
	if b.size() > 0:
		_console.add_text(b.get_string_from_utf8())
		got = true
	var e := er.get_buffer(65536)
	if e.size() > 0:
		_take_stderr(e.get_string_from_utf8())
		got = true
	if not got and not OS.is_process_running(_proc.pid):
		if _stderr_tail != "":
			_take_stderr("\n")
		var code := OS.get_process_exit_code(_proc.pid)
		_console.append_text("\n[color=#80b0ff]── exited with code %d ──[/color]\n" % code)
		_debug_resumed()
		_set_debug_state("Not running. Run (F5) starts it; it pauses on breakpoints (F9 on a brick).")
		io.close()
		er.close()
		_proc = {}
		_stop_btn.disabled = true
		_set_busy(false)


## stderr: trace lines light up their bricks (not printed); the rest shows in red.
func _take_stderr(text: String) -> void:
	text = _stderr_tail + text
	var lines := text.split("\n")
	_stderr_tail = lines[lines.size() - 1]
	lines.remove_at(lines.size() - 1)
	var cur_rel := CBProject.rel_path(project_dir, _tab().path) if has_graph() else ""
	var shown := PackedStringArray()
	for line in lines:
		if _dbg_reading:
			if line == "[end]":
				_dbg_reading = false
				_debug_paused()
			else:
				_dbg_lines.append(line)
			continue
		if line.begins_with("[pause] "):
			var at := line.trim_prefix("[pause] ")
			var colon := at.rfind(":")
			_paused_script = project_dir.path_join(at.left(colon))
			_paused_brick = at.substr(colon + 1).to_int()
			_dbg_lines.clear()
			_dbg_reading = true
			continue
		if line == "[resume]":
			_debug_resumed()
			continue
		if line == "[stopped]":
			continue
		var m := _trace_re.search(line)
		if m != null:
			if m.get_string(1) == cur_rel:
				var id := m.get_string(2).to_int()
				if id not in _flash_pending:
					_flash_pending.append(id)
			continue
		shown.append(line)
	if not shown.is_empty():
		_console.push_color(Color(1, 0.55, 0.55)); _console.add_text("\n".join(shown) + "\n"); _console.pop()


# ======================================================================= debugger

## "main.cbricks:4" for every breakpoint of every script.
func _all_breakpoints() -> PackedStringArray:
	var out := PackedStringArray()
	var open := {}
	for t in _tabs:
		open[t.path] = t.graph
	for p in CBProject.list_scripts(project_dir):
		var g: Dictionary = open.get(p, {})
		if g.is_empty():
			g = CBProject.read_script(p)
		for id in g.get("breakpoints", []):
			out.append("%s:%d" % [CBProject.rel_path(project_dir, p), int(id)])
	return out


func toggle_breakpoint(id: int) -> void:
	if not has_graph() or Ops.node_by_id(context.graph, id).is_empty():
		return
	var bps: Array = context.graph.get("breakpoints", [])
	var on := id not in bps.map(func(x): return int(x))
	if on:
		bps.append(id)
	else:
		bps = bps.filter(func(x): return int(x) != id)
	context.graph["breakpoints"] = bps
	_tab().dirty = true
	_update_title()
	_queue_redraw(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES)
	_debug_send("%s %s:%d" % ["break" if on else "clear", CBProject.rel_path(project_dir, _tab().path), id])
	_set_status("status_info", "Breakpoint %s on %s (node %d)." % ["set" if on else "removed", T.title_of(Ops.node_by_id(context.graph, id).type, Ops.node_by_id(context.graph, id).fields), id])


## Opens the script that defines `name` and shows its Define Function.
func goto_function(name: String) -> void:
	var open := {}
	for t in _tabs:
		open[t.path] = t.graph
	for p in CBProject.list_scripts(project_dir):
		var g: Dictionary = open.get(p, {})
		if g.is_empty():
			g = CBProject.read_script(p)
		for n in g.get("nodes", []):
			if n.type == "function" and str(n.fields.get("name", "")) == name:
				open_script(p)
				_flush_redraw()
				_canvas.show_node.call_deferred(int(n.id))
				return
	_set_status("status_warning", "No script defines a function named '%s'." % name)


## A function's new name: Call Function bricks in the other scripts follow.
func _on_function_renamed(old_name: String, new_name: String) -> void:
	var changed := 0
	for p in CBProject.list_scripts(project_dir):
		if has_graph() and p == _tab().path:
			continue
		var tab: Dictionary = {}
		for t in _tabs:
			if t.path == p:
				tab = t
		var g: Dictionary = tab.graph if not tab.is_empty() else CBProject.read_script(p)
		var hit := false
		for n in g.get("nodes", []):
			if n.type == "call" and str(n.fields.get("function", "")) == old_name:
				n.fields.function = new_name
				hit = true
				changed += 1
		if hit:
			if tab.is_empty():
				CBProject.write_script(p, g)
			else:
				tab.dirty = true
	if changed > 0:
		_set_status("status_info", "Renamed the function's %d call(s) in other scripts too." % changed)
		_update_title()


# ----------------------------------------------------------------------- find

var _find_popup: PopupPanel = null
var _find_edit: LineEdit = null
var _find_list: ItemList = null


## Ctrl+F: every brick of every script, by its title, settings and note.
func open_find() -> void:
	if not has_project():
		return
	if _find_popup == null:
		_find_popup = PopupPanel.new()
		var box := VBoxContainer.new()
		_find_popup.add_child(box)
		_find_edit = LineEdit.new()
		_find_edit.placeholder_text = "Find a brick: its title, a variable, a value, a note..."
		_find_edit.clear_button_enabled = true
		_find_edit.text_changed.connect(func(_t: String) -> void: _fill_find())
		_find_edit.text_submitted.connect(func(_t: String) -> void:
			if _find_list.item_count > 0:
				_pick_find(0))
		box.add_child(_find_edit)
		_find_list = ItemList.new()
		_find_list.custom_minimum_size = Vector2(560, 320)
		_find_list.item_activated.connect(_pick_find)
		_find_list.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void: _pick_find(i))
		box.add_child(_find_list)
		add_child(_find_popup)
	_find_edit.text = ""
	_fill_find()
	_find_popup.popup_centered()
	_find_edit.grab_focus()


func _fill_find() -> void:
	_find_list.clear()
	var q := _find_edit.text.strip_edges().to_lower()
	var open := {}
	for t in _tabs:
		open[t.path] = t.graph
	var paths := Array(CBProject.list_scripts(project_dir))
	if has_graph():
		paths.erase(_tab().path)
		paths.insert(0, _tab().path)
	for p in paths:
		var g: Dictionary = open.get(p, {})
		if g.is_empty():
			g = CBProject.read_script(p)
		var rel := CBProject.rel_path(project_dir, p)
		for n in g.get("nodes", []):
			var title := T.title_of(n.type, n.fields)
			var text := " ".join(Array(BrickView.summary(n, g)))
			var hay := ("%s %s %s %s" % [title, text, n.get("note", ""), rel]).to_lower()
			if q != "" and not hay.contains(q):
				continue
			var i := _find_list.add_item("%s  ·  %s   (%s, node %d)" % [title, text.left(60), rel, int(n.id)])
			_find_list.set_item_metadata(i, [p, int(n.id)])
			_find_list.set_item_custom_fg_color(i, context.brick_theme.category_color(T.DEFS[n.type].cat).lerp(Color.WHITE, 0.35))
			if _find_list.item_count >= 300:
				return


func _pick_find(i: int) -> void:
	var m: Array = _find_list.get_item_metadata(i)
	_find_popup.hide()
	if not has_graph() or _tab().path != m[0]:
		open_script(m[0])
	_flush_redraw()
	_canvas.show_node.call_deferred(int(m[1]))


func _debug_send(command: String) -> void:
	if _proc.is_empty() or _debug_cmd == "":
		return
	var fa := FileAccess.open(_debug_cmd, FileAccess.READ_WRITE)
	if fa == null:
		return
	fa.seek_end()
	fa.store_string(command + "\n")
	fa.close()


func debug_continue() -> void:
	if _paused_script != "":
		_debug_send("continue")
	elif not _proc.is_empty():
		_debug_send("pause")
		_set_debug_state("Pausing at the next brick...")


## Step Into (F11): the very next brick, inside a function it calls too.
func debug_step() -> void:
	if _paused_script != "":
		_debug_send("step")


## Step Over (F10): the next brick of this call (calls made meanwhile run through).
func debug_step_over() -> void:
	if _paused_script != "":
		_debug_send("next")


## Step Out (Shift+F11): runs until this function returns, pauses in its caller.
func debug_step_out() -> void:
	if _paused_script != "":
		_debug_send("out")


## The program stopped at a brick: show it and its variables.
func _debug_paused() -> void:
	var values := {}
	_debug_tree.clear()
	var root := _debug_tree.create_item()
	var locals := _debug_tree.create_item(root)
	locals.set_text(0, "Variables")
	locals.set_selectable(0, false)
	var globals: TreeItem = null
	var pending_globals := []
	var pending_locals := []
	for line in _dbg_lines:
		if line.begins_with("[depth] "):
			_paused_depth = line.trim_prefix("[depth] ").to_int()
			continue
		var is_global: bool = line.begins_with("[global] ")
		var parts: PackedStringArray = line.trim_prefix("[global] " if is_global else "[var] ").split("\t", true, 2)
		if parts.size() < 3:
			continue
		values[parts[0]] = parts[2]
		if is_global:
			pending_globals.append([parts[0], parts[1], parts[2]])
		else:
			pending_locals.append([parts[0], parts[1], parts[2]])
		var parent := locals
		if is_global:
			if globals == null:
				globals = _debug_tree.create_item(root)
				globals.set_text(0, "Globals")
				globals.set_selectable(0, false)
			parent = globals
		var it := _debug_tree.create_item(parent)
		it.set_text(0, parts[0])
		it.set_text(1, parts[1])
		it.set_text(2, parts[2])
		it.set_tooltip_text(2, parts[2])
		it.set_autowrap_mode(2, TextServer.AUTOWRAP_WORD_SMART)
		it.set_custom_color(1, Color(context.brick_theme.text_color(), 0.6))
	if locals.get_child_count() == 0:
		var none := _debug_tree.create_item(locals)
		none.set_text(0, "(none yet)")
	_dbg_vars = pending_globals + pending_locals  # a local hides a global of its name
	_fill_watches()
	context.debug_values = values
	var rel := CBProject.rel_path(project_dir, _paused_script)
	if not has_graph() or _tab().path != _paused_script:
		open_script(_paused_script)
	context.paused_brick = _paused_brick
	var n := Ops.node_by_id(context.graph, _paused_brick)
	var what := "%s (node %d)" % [T.title_of(n.type, n.fields), _paused_brick] if not n.is_empty() else "brick %d" % _paused_brick
	var depth := "" if _paused_depth == 0 else ", %d call%s deep" % [_paused_depth, "" if _paused_depth == 1 else "s"]
	_set_debug_state("Paused at %s, %s%s. Continue (F8), Step over (F10), Step into (F11), Step out (Shift+F11), Stop." % [rel, what, depth])
	_set_status("status_warning", "Paused at %s: %s" % [rel, what])
	_bottom.current_tab = _debug_tab.get_index()
	_dbg_continue.text = "Continue"
	_dbg_step.disabled = false
	_dbg_over.disabled = false
	_dbg_out.disabled = _paused_depth == 0
	_dbg_out.tooltip_text = "Run until this function returns, then pause in its caller (Shift+F11)" if _paused_depth > 0 else "Paused outside any function: nothing to step out of"
	_queue_redraw(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES)
	_canvas.show_node.call_deferred(_paused_brick)
	get_window().grab_focus()


func _debug_resumed() -> void:
	var was := _paused_script != ""
	_paused_script = ""
	_paused_brick = 0
	_dbg_reading = false
	context.paused_brick = 0
	context.debug_values = {}
	if _dbg_continue != null:
		_dbg_continue.text = "Pause"
		_dbg_step.disabled = true
		_dbg_over.disabled = true
		_dbg_out.disabled = true
	if was:
		_set_debug_state("Running.")
		_queue_redraw(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES)


func _set_debug_state(text: String) -> void:
	if _debug_state != null:
		_debug_state.text = text


func _build_debug_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "Debug"
	var bar := HBoxContainer.new()
	box.add_child(bar)
	_dbg_continue = _tool_button(bar, "Pause", "play", debug_continue, "Continue (F8) when paused; Pause (F8) while it runs")
	_dbg_over = _tool_button(bar, "Step over", "step_over", debug_step_over, "Run to the next brick of this function: the functions it calls run through (F10)")
	_dbg_over.disabled = true
	_dbg_step = _tool_button(bar, "Step into", "step_into", debug_step, "Run the next brick, inside a called function too (F11)")
	_dbg_step.disabled = true
	_dbg_out = _tool_button(bar, "Step out", "step_out", debug_step_out, "Run until this function returns, then pause in its caller (Shift+F11)")
	_dbg_out.disabled = true
	_dbg_stop = _tool_button(bar, "Stop", "stop", stop_program, "Stop the program")
	# The state on its own line under the buttons, wrapping (it named the paused brick and got cut off).
	_debug_state = Label.new()
	_debug_state.size_flags_horizontal = SIZE_EXPAND_FILL
	_debug_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_state.custom_minimum_size.x = 120
	_debug_state.modulate.a = 0.8
	_debug_state.text = "Not running. Run (F5) starts it; it pauses on breakpoints (F9 on a brick)."
	box.add_child(_debug_state)
	_debug_tree = Tree.new()
	_debug_tree.size_flags_vertical = SIZE_EXPAND_FILL
	_debug_tree.hide_root = true
	_debug_tree.columns = 3
	_debug_tree.column_titles_visible = true
	_debug_tree.set_column_title(0, "Variable")
	_debug_tree.set_column_title(1, "Type")
	_debug_tree.set_column_title(2, "Value")
	_debug_tree.set_column_expand(0, false)
	_debug_tree.set_column_custom_minimum_width(0, 140)
	_debug_tree.set_column_expand(1, false)
	_debug_tree.set_column_custom_minimum_width(1, 110)
	_debug_tree.add_theme_font_override(&"font", Inspector._mono())
	_debug_tree.button_clicked.connect(func(item: TreeItem, _col: int, _id: int, _mb: int) -> void:
		_remove_watch.call_deferred(int(item.get_metadata(0))))
	# Double-click a variable: watch it.
	_debug_tree.item_activated.connect(func() -> void:
		var it := _debug_tree.get_selected()
		if it != null and it.get_parent() != null and it.get_parent().get_text(0) in ["Variables", "Globals"] and it.get_text(1) != "":
			_add_watch.call_deferred(it.get_text(0)))
	box.add_child(_debug_tree)
	_watch_edit = LineEdit.new()
	_watch_edit.placeholder_text = "Add a watch: an expression, e.g. score * 2, pos.x, gems[0], who == \"Ada\" (Enter)"
	_watch_edit.clear_button_enabled = true
	_watch_edit.tooltip_text = "Worked out at every pause from the variables there: + - * / %, == != < > && || !, fields (p.x), items (list[0], map[\"key\"]), .size(), len(), sqrt(), min() / max()..."
	_watch_edit.text_submitted.connect(func(t: String) -> void:
		_watch_edit.clear()
		_add_watch(t))
	box.add_child(_watch_edit)
	_fill_watches()
	return box


# ----------------------------------------------------------------------- watches

## Puts the Watches section at the top of the Debug tab's tree, worked out from
## the last pause's variables (CBWatches), or waiting for one.
func _fill_watches() -> void:
	if _debug_tree == null:
		return
	var root := _debug_tree.get_root()
	if root == null:
		root = _debug_tree.create_item()
	var section: TreeItem = null
	for c in root.get_children():
		if c.get_text(0) == "Watches":
			section = c
	if _watches.is_empty():
		if section != null:
			section.free()
		return
	if section == null:
		section = _debug_tree.create_item(root, 0)
		section.set_text(0, "Watches")
		section.set_selectable(0, false)
	for c in section.get_children():
		c.free()
	var paused := _paused_script != ""
	for i in _watches.size():
		var it := _debug_tree.create_item(section)
		it.set_text(0, _watches[i])
		it.set_tooltip_text(0, _watches[i])
		it.set_metadata(0, i)
		it.add_button(2, context.brick_theme.icon("remove"), 0, false, "Remove this watch")
		if not paused:
			it.set_text(2, "(worked out when the program pauses)")
			it.set_custom_color(2, Color(context.brick_theme.text_color(), 0.5))
			continue
		var r := CBWatches.evaluate(_watches[i], _dbg_vars, context.records)
		it.set_text(1, str(r.type))
		it.set_custom_color(1, Color(context.brick_theme.text_color(), 0.6))
		it.set_text(2, str(r.text))
		it.set_tooltip_text(2, str(r.text))
		if not r.ok:
			it.set_custom_color(2, Color(1, 0.55, 0.5))


func _add_watch(expression: String) -> void:
	var e := expression.strip_edges()
	if e == "" or not has_project():
		return
	if e not in _watches:
		_watches.append(e)
		_save_watches()
	_fill_watches()
	_bottom.current_tab = _debug_tab.get_index()


func _remove_watch(index: int) -> void:
	if index < 0 or index >= _watches.size():
		return
	_watches.remove_at(index)
	_save_watches()
	_fill_watches()


func _save_watches() -> void:
	var cf := CBProject.load_config(project_dir)
	cf.set_value("debug", "watches", _watches)
	CBProject.save_config(project_dir, cf)


func _send_stdin(t: String) -> void:
	_stdin.clear()
	if _proc.is_empty():
		_set_status("status_info", "No program is running.")
		return
	_console.push_color(Color(0.6, 0.9, 1.0)); _console.add_text(t + "\n"); _console.pop()
	_proc.stdio.store_string(t + "\n")
	_proc.stdio.flush()


func stop_program() -> void:
	if _proc.is_empty():
		return
	_debug_resumed()
	if OS.is_process_running(_proc.pid):
		OS.kill(_proc.pid)
	_proc.stdio.close()
	_proc.stderr.close()
	_proc = {}
	_stop_btn.disabled = true
	_set_busy(false)
	_console.append_text("\n[color=#80b0ff]── stopped ──[/color]\n")


func _join_thread() -> void:
	if _thread != null and not _thread.is_alive():
		_thread.wait_to_finish()
		_thread = null


func _set_busy(b: bool) -> void:
	for btn in [_build_btn, _run_btn, _all_btn]:
		btn.disabled = b or not Toolchains.can_execute()


func _update_target_state() -> void:
	if not Toolchains.can_execute() or _target == null:
		return
	for i in Toolchains.TARGETS.size():
		var ok := Toolchains.resolve_command(Toolchains.TARGETS[i].id) != ""
		_target.set_item_text(i, Toolchains.TARGETS[i].name + ("" if ok else "  (not installed)"))
	var id := _current_target()
	_run_btn.visible = Toolchains.resolve_runner(id) != ""
	_target.tooltip_text = "Compiles with: %s" % (Toolchains.resolve_command(id) if Toolchains.resolve_command(id) != "" else "nothing found (see Toolchains)")


func export_project() -> void:
	if not has_project():
		return
	save_all()
	_recompile()
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(Toolchains.project_zip(_program_name(), ProjectBuild.generate(project_dir, {}, "native"), project_dir), _program_name() + ".zip", "application/zip")
		return
	_ask_file("export")


# ======================================================================= files / dialogs

func _ask_file(mode: String) -> void:
	_file_mode = mode
	var d := _file_dialog
	d.filters = PackedStringArray()
	d.current_file = ""
	match mode:
		"open_project":
			d.file_mode = FileDialog.FILE_MODE_OPEN_ANY
			d.title = "Open a project: its folder or its project.cbproj"
			d.add_filter("project.cbproj", "C-Bricks project")
		"export":
			d.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			d.title = "Choose where to put the C project"
		"new_parent":
			d.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			d.title = "Choose the folder new projects go in"
		"save_c":
			d.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			d.title = "Choose a folder for the generated C files"
	d.popup_centered_ratio(0.6)


func _on_file_chosen(path: String) -> void:
	match _file_mode:
		"open_project":
			open_project(path)
		"new_parent":
			(_new_dialog.find_child("Parent", true, false) as LineEdit).text = path
			_new_dialog.popup_centered()
		"save_c":
			ProjectBuild.write(_build, path)
			_set_status("status_success", "Wrote %d file(s) to %s" % [_build.files.size(), path])
		"export":
			_export_to(path.path_join(_program_name()))


## Exports the C project into `dir` in the background, a progress bar showing how far it got
## (user, 2026-11-08); the window stays usable meanwhile.
func _export_to(dir: String) -> void:
	if _busy():
		_set_status("status_info", "Wait for the build to finish first.")
		return
	_progress_label.text = "Exporting to %s ..." % dir
	_progress_bar.value = 0
	_progress_dialog.title = "Exporting the C project"
	_progress_dialog.popup_centered(Vector2i(520, 0))
	_set_busy(true)
	_join_thread()
	_thread = Thread.new()
	var base := _program_name()
	var open := {}
	for t in _tabs:
		open[t.path] = t.graph
	var result := ProjectBuild.generate(project_dir, open, "native")  # (an exported project builds with raylib's backend, whatever the Target is)
	var pdir := project_dir
	_thread.start(func() -> void:
		var err := Toolchains.export_project(dir, base, result, pdir, func(done: int, total: int, what: String) -> void:
			_export_progress.call_deferred(done, total, what))
		_export_done.call_deferred(dir, err))


func _export_progress(done: int, total: int, what: String) -> void:
	_progress_bar.max_value = maxi(total, 1)
	_progress_bar.value = done
	_progress_label.text = "%d of %d: %s" % [done, total, what]


func _export_done(dir: String, err: String) -> void:
	_join_thread()
	_set_busy(false)
	_progress_dialog.hide()
	if err != "":
		_set_status("status_error", err)
		return
	_bottom.current_tab = 1
	_console.append_text("[color=#80e080]Exported the C project[/color] → [url=file:%s]%s[/url]  (src/, assets, Makefile, CMakeLists.txt, build.sh, build.bat, README.md)\n" % [dir, dir])
	_set_status("status_success", "Exported to %s" % dir)


func _open_new_project() -> void:
	_saving_example = false
	_new_dialog.title = "New Project"
	_new_dialog.ok_button_text = "Create & Open"
	(_new_dialog.find_child("NewHint", true, false) as Label).text = NEW_HINT
	(_new_dialog.find_child("Name", true, false) as LineEdit).text = "My Program"
	(_new_dialog.find_child("Parent", true, false) as LineEdit).text = CBProject.default_parent()
	_new_dialog.popup_centered(Vector2i(560, 0))


## Save on an example: the New Project dialog asks a name and a folder for your copy.
func _ask_save_example() -> void:
	_saving_example = true
	_new_dialog.title = "Save Example as a Project"
	_new_dialog.ok_button_text = "Save & Open"
	(_new_dialog.find_child("NewHint", true, false) as Label).text = "Copies this example, with your changes, into a project folder of your own and goes on there. The example stays as it is."
	(_new_dialog.find_child("Name", true, false) as LineEdit).text = CBProject.project_name(project_dir)
	(_new_dialog.find_child("Parent", true, false) as LineEdit).text = CBProject.default_parent()
	_new_dialog.popup_centered(Vector2i(560, 0))


## The example's scratch copy, as it is now, into parent/name: opened there.
func save_example_as(parent: String, name: String) -> String:
	name = name.strip_edges()
	if name == "" or name.contains("/") or name.contains("\\"):
		_set_status("status_error", "Give the project a name (no slashes).")
		return ""
	var to := parent.strip_edges().path_join(name)
	if DirAccess.dir_exists_absolute(to) and not (DirAccess.get_files_at(to).is_empty() and DirAccess.get_directories_at(to).is_empty()):
		_set_status("status_error", "%s already exists and isn't empty: pick another name or folder." % to)
		return ""
	save_all()
	DirAccess.make_dir_recursive_absolute(to)
	if CBProject.copy_dir(project_dir, to) != OK:
		_set_status("status_error", "Couldn't save to %s" % to)
		return ""
	var cf := CBProject.load_config(to)
	cf.set_value("project", "name", name)
	CBProject.save_config(to, cf)
	var copy := project_dir
	open_project(to)
	_recent.erase(copy)  # (your project takes the copy's place in Recent Projects)
	_drop_copy(copy)
	_save_settings()
	_set_status("status_success", "Saved as your project %s" % to)
	return to


func _create_project() -> void:
	var name := (_new_dialog.find_child("Name", true, false) as LineEdit).text
	var parent := (_new_dialog.find_child("Parent", true, false) as LineEdit).text.strip_edges()
	if _saving_example:
		_saving_example = false
		save_example_as(parent, name)
		return
	var dir := CBProject.create(parent, name)
	if dir == "":
		_set_status("status_error", CBProject.last_error)
		return
	open_project(dir)


func _open_project_settings() -> void:
	if not has_project():
		return
	var cf := CBProject.load_config(project_dir)
	(_project_dialog.find_child("PName", true, false) as LineEdit).text = str(cf.get_value("project", "name", ""))
	(_project_dialog.find_child("PVersion", true, false) as LineEdit).text = str(cf.get_value("project", "version", "1.0"))
	(_project_dialog.find_child("PArgs", true, false) as LineEdit).text = str(cf.get_value("run", "args", ""))
	(_project_dialog.find_child("PDosScreen", true, false) as OptionButton).select(maxi(0, DOS_SCREENS.find(int(cf.get_value("dos", "screen", 0)))))
	(_project_dialog.find_child("PBackend", true, false) as OptionButton).select(maxi(0, BACKEND_IDS.find(str(cf.get_value("graphics", "backend", "auto")))))
	_refresh_backend_rows()
	_project_dialog.popup_centered(Vector2i(760, 0))


func _save_project_settings() -> void:
	var cf := CBProject.load_config(project_dir)
	cf.set_value("project", "name", (_project_dialog.find_child("PName", true, false) as LineEdit).text.strip_edges())
	cf.set_value("project", "version", (_project_dialog.find_child("PVersion", true, false) as LineEdit).text.strip_edges())
	cf.set_value("run", "args", (_project_dialog.find_child("PArgs", true, false) as LineEdit).text.strip_edges())
	cf.set_value("graphics", "backend", BACKEND_IDS[(_project_dialog.find_child("PBackend", true, false) as OptionButton).selected])
	cf.set_value("dos", "screen", DOS_SCREENS[(_project_dialog.find_child("PDosScreen", true, false) as OptionButton).selected])
	CBProject.save_config(project_dir, cf)
	_dock.refresh()
	_recompile()
	_update_title()
	_set_status("status_success", "Project settings saved.")


func _set_project_value(section: String, key: String, value) -> void:
	if not has_project():
		return
	var cf := CBProject.load_config(project_dir)
	cf.set_value(section, key, value)
	CBProject.save_config(project_dir, cf)


func _add_recent(dir: String) -> void:
	_recent.erase(dir)
	_recent.insert(0, dir)
	while _recent.size() > MAX_RECENT:
		_drop_copy(_recent[_recent.size() - 1])
		_recent.remove_at(_recent.size() - 1)
	_save_settings()


func _forget_recent(dir: String) -> void:
	_recent.erase(dir)
	_drop_copy(dir)
	_save_settings()
	refresh_start()


## An example copy no longer in Recent Projects goes (only those: never a project of yours).
func _drop_copy(dir: String) -> void:
	if dir.begins_with(ProjectSettings.globalize_path(EXAMPLE_SCRATCH)) and dir != project_dir and DirAccess.dir_exists_absolute(dir):
		_remove_tree(dir)


func _is_example_copy(dir: String) -> bool:
	return dir.begins_with(ProjectSettings.globalize_path(EXAMPLE_SCRATCH))


func _update_title() -> void:
	if _tab_bar != null:
		for i in _tabs.size():
			_tab_bar.set_tab_title(i, _tabs[i].path.get_file() + (" *" if _tabs[i].dirty else ""))
	if _dock != null and has_project():
		var dirty := {}
		for t in _tabs:
			if t.dirty:
				dirty[t.path] = true
		if dirty != _dock.dirty_scripts:
			_dock.dirty_scripts = dirty
			_dock.refresh()
	var nm := CBProject.project_name(project_dir) if has_project() else ""
	if _title != null:
		_title.text = nm
	var script := ("  ·  " + CBProject.rel_path(project_dir, _tab().path) + (" *" if _tab().dirty else "")) if has_graph() else ""
	if _is_example():
		nm += "  (an example copy: Save asks where to keep it)"
		if _title != null:
			_title.text = nm
	get_window().title = ("%s%s - C-Bricks" % [nm, script]) if has_project() else "C-Bricks - Project Manager"


func _apply_view(view: Dictionary) -> void:
	_canvas.zoom = float(view.zoom)
	_canvas.scroll_offset = view.scroll
	_bricks_into_view()


func _bricks_into_view() -> void:
	for _f in 2:
		await get_tree().process_frame
	if has_graph():
		_canvas.bring_bricks_into_view()


func _quit() -> void:
	stop_program()
	save_all()
	_save_settings()
	if _thread != null:
		_thread.wait_to_finish()
	for t in _tabs:
		t.undo.free()
	_tabs.clear()
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_quit()
	elif what == NOTIFICATION_PREDELETE:
		for t in _tabs:
			if is_instance_valid(t.undo):
				t.undo.free()


# ======================================================================= app settings

func _load_settings() -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	_recent = PackedStringArray(cf.get_value("projects", "recent", []))
	_screen = str(cf.get_value("ui", "main_screen", "Script"))
	for k in _panel_sizes:
		_panel_sizes[k] = int(cf.get_value("ui", k + "_size", _panel_sizes[k]))
	for t in Toolchains.TARGETS:
		var v := str(cf.get_value("overrides", t.id, ""))
		if v != "":
			Toolchains.overrides[t.id] = v


func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	cf.set_value("projects", "recent", Array(_recent))
	cf.set_value("ui", "main_screen", _screen)
	if cf.has_section_key("ui", "preview_sky"):
		cf.erase_section_key("ui", "preview_sky")  # (the Sky toggle is gone: the Environment decides)
	for k in _panel_sizes:
		cf.set_value("ui", k + "_size", _panel_sizes[k])
	if cf.has_section("overrides"):
		cf.erase_section("overrides")
	for id in Toolchains.overrides:
		cf.set_value("overrides", id, Toolchains.overrides[id])
	cf.save(SETTINGS)


func _open_settings() -> void:
	Toolchains.clear_cache()
	for c in _settings_dialog.get_children():
		if c is TabContainer:
			_settings_dialog.remove_child(c)
			c.queue_free()
	var tabs := TabContainer.new()
	tabs.name = "Tabs"
	tabs.custom_minimum_size = Vector2(940, 520)
	_settings_dialog.add_child(tabs)
	tabs.add_child(_toolchains_tab())
	tabs.add_child(_commands_tab())
	tabs.set_tab_title(0, "Toolchains")
	tabs.set_tab_title(1, "Commands")
	_settings_dialog.popup_centered(Vector2i(980, 620))


## The first tab: every toolchain that can be installed from here, with its state and a progress bar.
func _toolchains_tab() -> Control:
	var sc := ScrollContainer.new()
	sc.name = "Toolchains"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 8)
	sc.add_child(vb)
	var help := Label.new()
	help.text = "The programs C-Bricks calls to turn your C into programs. Install one here (it is downloaded, checked against its published sha256 and unpacked into the editor's own folder) or let the editor find one already on this computer. Installing and removing take effect at once; the Commands tab holds each target's compile command."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate.a = 0.7
	vb.add_child(help)
	_tc_rows.clear()
	for t in ToolchainManager.TOOLS:
		var pc := PanelContainer.new()
		var box := VBoxContainer.new()
		pc.add_child(box)
		var top := HBoxContainer.new()
		box.add_child(top)
		var icon := TextureRect.new()
		icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		top.add_child(icon)
		var name_l := Label.new()
		name_l.text = str(t.name)
		name_l.add_theme_font_size_override("font_size", 16)
		top.add_child(name_l)
		var state := Label.new()
		state.size_flags_horizontal = SIZE_EXPAND_FILL
		state.clip_text = true
		state.modulate.a = 0.75
		top.add_child(state)
		var install := Button.new()
		install.text = "Install"
		install.pressed.connect(func() -> void: _tc_install(str(t.id)))
		top.add_child(install)
		var remove := Button.new()
		remove.text = "Remove"
		remove.pressed.connect(func() -> void: _tc_manager.remove(str(t.id)))
		top.add_child(remove)
		var cancel := Button.new()
		cancel.text = "Cancel"
		cancel.pressed.connect(func() -> void: _tc_manager.cancel())
		top.add_child(cancel)
		var what := Label.new()
		what.text = str(t.enables)
		what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(what)
		var meta := HBoxContainer.new()
		box.add_child(meta)
		var info := Label.new()
		info.name = "Info"
		info.modulate.a = 0.6
		meta.add_child(info)
		var link := LinkButton.new()
		link.text = "Website"
		link.uri = str(t.source)
		meta.add_child(link)
		var bar_row := HBoxContainer.new()
		box.add_child(bar_row)
		var bar := ProgressBar.new()
		bar.size_flags_horizontal = SIZE_EXPAND_FILL
		bar.custom_minimum_size.y = 18
		bar.show_percentage = false
		bar_row.add_child(bar)
		var bar_l := Label.new()
		bar_l.custom_minimum_size.x = 330
		bar_l.clip_text = true
		bar_row.add_child(bar_l)
		vb.add_child(pc)
		_tc_rows[str(t.id)] = {"icon": icon, "state": state, "install": install, "remove": remove, "cancel": cancel, "info": info, "bar_row": bar_row, "bar": bar, "bar_l": bar_l}
		_tc_refresh(str(t.id))
	return sc


## One row's state: what's installed / found / missing, which buttons, whether a bar shows.
func _tc_refresh(id: String) -> void:
	if not _tc_rows.has(id) or not is_instance_valid(_tc_rows[id].state):
		return
	var r: Dictionary = _tc_rows[id]
	var st := ToolchainManager.status(id)
	var e := ToolchainManager.entry(id)
	var working: bool = _tc_manager.busy()
	var mine: bool = working and _tc_manager.current() == id
	var good: bool = st.state != "missing"
	(r.icon as TextureRect).texture = context.brick_theme.icon("status_success" if good else "status_error")
	match st.state:
		"installed":
			(r.state as Label).text = "Installed" + ((" " + str(st.version)) if str(st.version) != "" else "") + "  ·  " + str(st.path)
		"found":
			(r.state as Label).text = "Found on this computer  ·  " + str(st.path)
		_:
			(r.state as Label).text = "Not installed" + ("" if not e.is_empty() else "  ·  no download for " + ToolchainManager.platform())
	(r.state as Label).tooltip_text = (r.state as Label).text
	(r.info as Label).text = (("Download " + ("about 1 GB (emsdk fetches the compiler)" if e.has("emsdk") else String.humanize_size(int(e.get("size", 0)))) + "  ·  ") if not e.is_empty() else "") + "Licence: " + str(ToolchainManager.tool_info(id).licence) + "  ·  "
	(r.install as Button).visible = st.state != "installed" and not mine
	(r.install as Button).text = "Install" if st.state == "missing" else "Install here"
	(r.install as Button).disabled = working or e.is_empty()
	(r.remove as Button).visible = st.state == "installed" and not mine
	(r.remove as Button).disabled = working
	(r.cancel as Button).visible = mine
	(r.bar_row as Control).visible = mine
	if not mine:
		(r.bar as ProgressBar).value = 0


func _tc_install(id: String) -> void:
	_tc_manager.install(id)
	for k in _tc_rows:
		_tc_refresh(k)


func _tc_progress(id: String, done: int, total: int, what: String) -> void:
	if not _tc_rows.has(id) or not is_instance_valid(_tc_rows[id].bar):
		return
	var r: Dictionary = _tc_rows[id]
	var bar := r.bar as ProgressBar
	bar.indeterminate = total <= 0
	bar.max_value = maxf(total, 1)
	bar.value = done
	(r.bar_l as Label).text = what if total <= 0 else "%s  %s of %s" % [what, String.humanize_size(done), String.humanize_size(total)]
	(r.cancel as Button).disabled = what != "Downloading"
	(r.bar_row as Control).visible = true


func _tc_finished(id: String, err: String) -> void:
	for k in _tc_rows:
		_tc_refresh(k)
	_update_target_state()
	if err != "":
		_set_status("status_error", "%s: %s" % [id, err])
		_log_info("Toolchain %s: %s" % [id, err])
		if _tc_rows.has(id) and is_instance_valid(_tc_rows[id].state):
			(_tc_rows[id].state as Label).text = err
			(_tc_rows[id].state as Label).tooltip_text = err
	else:
		_set_status("status_success", "%s: done." % id)


## The second tab: each target's compile command (the old window).
func _commands_tab() -> Control:
	var sc := ScrollContainer.new()
	sc.name = "Commands"
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = SIZE_EXPAND_FILL
	sc.add_child(vb)
	var help := Label.new()
	help.text = "Each target's compile command. Leave a box empty to use the toolchain found (shown greyed). Placeholders: {src} (every .c file) {out} {dir}. zig (ziglang.org) covers almost every target. Save keeps these."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate.a = 0.7
	vb.add_child(help)
	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = 3
	vb.add_child(grid)
	for t in Toolchains.TARGETS:
		var saved = Toolchains.overrides.get(t.id, "")
		Toolchains.overrides.erase(t.id)
		var detected := Toolchains.resolve_command(t.id)
		if saved != "":
			Toolchains.overrides[t.id] = saved
		var st := TextureRect.new()
		st.texture = context.brick_theme.icon("status_success" if detected != "" else "status_error")
		st.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		st.tooltip_text = detected if detected != "" else "Not found. Tried:\n" + "\n".join(t.candidates)
		grid.add_child(st)
		var l := Label.new()
		l.text = t.name
		grid.add_child(l)
		var le := LineEdit.new()
		le.name = t.id
		le.text = saved
		le.placeholder_text = detected if detected != "" else t.candidates[0]
		le.custom_minimum_size.x = 520
		le.size_flags_horizontal = SIZE_EXPAND_FILL
		grid.add_child(le)
	return sc


func _save_settings_from_dialog() -> void:
	var grid := _settings_dialog.find_child("Grid", true, false)
	if grid == null:
		return
	Toolchains.overrides.clear()
	for t in Toolchains.TARGETS:
		var v := (grid.get_node(t.id) as LineEdit).text.strip_edges()
		if v != "":
			Toolchains.overrides[t.id] = v
	_save_settings()
	Toolchains.clear_cache()
	_update_target_state()
	_set_status("status_success", "Toolchain settings saved.")


# ======================================================================= layout

func _build_toolbar(parent: Control) -> void:
	var bar := HFlowContainer.new()
	parent.add_child(bar)
	var files := _toolbar_group(bar)
	var settings := _toolbar_group(bar)
	var status := _toolbar_group(bar)
	status.size_flags_horizontal = SIZE_EXPAND_FILL
	status.custom_minimum_size.x = 240  # too little room left on a row: it wraps to the next row instead of shrinking to a few letters
	var tools := _toolbar_group(bar)
	var project_menu := MenuButton.new()
	project_menu.text = "Project"
	project_menu.flat = true
	project_menu.icon = context.brick_theme.icon("project")
	var pp := project_menu.get_popup()
	pp.add_item("New Project...", 0)
	pp.add_item("Open Project...", 1)
	pp.add_separator()
	pp.add_item("New Script...", 2)
	pp.add_item("Project Settings...", 3)
	pp.add_item("Show Project Folder", 4)
	pp.add_separator()
	pp.add_item("Close Project (Project Manager)", 5)
	pp.about_to_popup.connect(func() -> void:
		for id in [2, 3, 4, 5]:
			pp.set_item_disabled(pp.get_item_index(id), not has_project()))
	pp.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_open_new_project()
		elif id == 1:
			_ask_file("open_project")
		elif id == 2:
			_dock._ask_new_script(_dock._selected_folder())
		elif id == 3:
			_open_project_settings()
		elif id == 4:
			OS.shell_open(project_dir)
		elif id == 5:
			close_project())
	files.add_child(project_menu)
	for spec in [["Save", "save", save, "Save this script (Ctrl+S; Ctrl+Shift+S: all)"],
			["", "undo", undo, "Undo (Ctrl+Z): the scene's last change on the 2D / 3D screens, the script's on Node"], ["", "redo", redo, "Redo (Ctrl+Shift+Z)"]]:
		var button := Button.new()
		button.text = spec[0]
		button.flat = true
		button.icon = context.brick_theme.icon(spec[1])
		button.tooltip_text = spec[3]
		button.pressed.connect(func() -> void: spec[2].call())
		files.add_child(button)
		_graph_tools.append(button)
	_title = Label.new()
	_title.add_theme_color_override(&"font_color", BrickTheme.LOCAL_COLOR)
	settings.add_child(_title)
	var sep := VSeparator.new()
	settings.add_child(sep)
	var tl := Label.new()
	tl.text = "Target"
	settings.add_child(tl)
	_target = OptionButton.new()
	_target.custom_minimum_size.x = 130
	_target.fit_to_longest_item = false
	_target.clip_text = true
	for i in Toolchains.TARGETS.size():
		_target.add_item(Toolchains.TARGETS[i].name, i)
	_target.item_selected.connect(func(_i: int) -> void:
		_set_project_value("build", "target", _current_target())
		_recompile()  # (what the target can't do: Problems naming those bricks)
		if has_graph():
			_palette.rebuild()
		_update_target_state())
	settings.add_child(_target)
	_graph_tools.append_array([_title, sep, tl, _target])
	_status_icon = TextureRect.new()
	_status_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	status.add_child(_status_icon)
	_status = Label.new()
	_status.size_flags_horizontal = SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.mouse_filter = MOUSE_FILTER_PASS
	status.add_child(_status)
	tools.add_child(VSeparator.new())
	_build_btn = _tool_button(tools, "Build", "build", func() -> void: build(false), "Compile the project for the target (F6)")
	_run_btn = _tool_button(tools, "Run", "play", func() -> void: build(true), "Build and run it here, from the project folder, with the project's run arguments; type its input under Console (F5)")
	_trace_btn = _tool_button(tools, "Trace", "trace", func() -> void: _set_project_value("run", "trace", _trace_btn.button_pressed), "Light up bricks as they run (runs the program with --trace)")
	_trace_btn.toggle_mode = true
	_all_btn = _tool_button(tools, "Build All", "build_all", build_all, "Compile for every target that has a toolchain")
	_stop_btn = _tool_button(tools, "Stop", "stop", stop_program, "Stop the running program")
	_stop_btn.disabled = true
	tools.add_child(VSeparator.new())
	var export_menu := MenuButton.new()
	export_menu.text = "Export"
	export_menu.flat = true
	export_menu.icon = context.brick_theme.icon("export")
	export_menu.get_popup().add_item("C project (src/, assets, Makefile, CMake, scripts)...", 0)
	export_menu.get_popup().add_item("Only the generated C files...", 1)
	export_menu.get_popup().id_pressed.connect(func(id: int) -> void:
		if id == 0:
			export_project()
		else:
			save_all()
			_recompile()
			_ask_file("save_c"))
	tools.add_child(export_menu)
	_graph_tools.append_array([_build_btn, _run_btn, _trace_btn, _all_btn, _stop_btn, export_menu])
	_tool_button(tools, "", "settings", _open_settings, "Toolchains: install compilers, each target's compile command")
	if not Toolchains.can_execute():
		for b in [_build_btn, _run_btn, _all_btn, _stop_btn, _trace_btn]:
			b.disabled = true
			b.tooltip_text = "Not available in the browser: Export the C project instead."


func _tool_button(parent: Control, text: String, icon_name: String, action: Callable, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.icon = context.brick_theme.icon(icon_name)
	b.tooltip_text = tip
	b.pressed.connect(func() -> void: action.call())
	parent.add_child(b)
	return b


func _toolbar_group(bar: HFlowContainer) -> HBoxContainer:
	var group := HBoxContainer.new()
	bar.add_child(group)
	return group


func _build_bottom(parent: Control) -> void:
	_bottom = TabContainer.new()
	_bottom.custom_minimum_size.y = 60
	_bottom.clip_tabs = true
	_problems = Tree.new()
	_problems.name = "Problems"
	_problems.hide_root = true
	_problems.tooltip_text = "Click a problem to jump to its brick."
	_problems.item_selected.connect(func() -> void: _on_problem_selected.call_deferred())
	_problems.create_item()
	_bottom.add_child(_problems)
	var con := VBoxContainer.new()
	con.name = "Console"
	_console = RichTextLabel.new()
	_console.size_flags_vertical = SIZE_EXPAND_FILL
	_console.scroll_following = true
	_console.selection_enabled = true
	_console.context_menu_enabled = true
	_console.bbcode_enabled = true
	_console.add_theme_font_override(&"normal_font", Inspector._mono())
	_console.add_theme_font_size_override(&"normal_font_size", 13)
	_console.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_console.meta_clicked.connect(func(meta) -> void:
		if str(meta).begins_with("file:"):
			OS.shell_open(str(meta).trim_prefix("file:")))
	_console.add_theme_stylebox_override(&"normal", BrickTheme.flat_box(BrickTheme.DARK, 3, 6.0))
	con.add_child(_console)
	var in_row := HBoxContainer.new()
	_stdin = LineEdit.new()
	_stdin.size_flags_horizontal = SIZE_EXPAND_FILL
	_stdin.placeholder_text = "Input for the running program (stdin): type and press Enter"
	_stdin.add_theme_font_override(&"font", Inspector._mono())
	_stdin.text_submitted.connect(_send_stdin)
	in_row.add_child(_stdin)
	var clear := Button.new()
	clear.text = "Clear"
	clear.flat = true
	clear.pressed.connect(func() -> void: _console.clear())
	in_row.add_child(clear)
	con.add_child(in_row)
	_bottom.add_child(con)
	var code_box := VBoxContainer.new()
	code_box.name = "Generated C"
	_code_pick = OptionButton.new()
	_code_pick.fit_to_longest_item = false
	_code_pick.clip_text = true
	_code_pick.tooltip_text = "One .c file per script, cbricks.h (shared by them) and cbricks_runtime.c (the command-line flags)."
	_code_pick.item_selected.connect(func(_i: int) -> void:
		_code_pick.set_meta(&"user_pick", true)
		_show_code())
	code_box.add_child(_code_pick)
	_code_view = CodeEdit.new()
	_code_view.size_flags_vertical = SIZE_EXPAND_FILL
	_code_view.editable = false
	_code_view.gutters_draw_line_numbers = true
	_code_view.highlight_current_line = true
	_code_view.syntax_highlighter = _c_highlighter()
	_code_view.add_theme_font_override(&"font", Inspector._mono())
	_code_view.add_theme_font_size_override(&"font_size", 13)
	_code_view.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_code_view.tooltip_text = "The C made from the project (read-only: rewritten from the graphs). Each line names its brick."
	code_box.add_child(_code_view)
	_bottom.add_child(code_box)
	_debug_tab = _build_debug_tab()
	_bottom.add_child(_debug_tab)
	parent.add_child(_framed(_bottom, 4))


func _c_highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.number_color = Color("b5cea8")
	h.symbol_color = Color("c8c8d0")
	h.function_color = Color("dcdcaa")
	h.member_variable_color = Color("9cdcfe")
	for k in ["if", "else", "while", "for", "do", "return", "break", "continue", "switch", "case", "default", "goto", "sizeof", "static", "const", "extern", "struct", "union", "enum", "typedef"]:
		h.add_keyword_color(k, Color("c586c0"))
	for k in ["int", "double", "float", "char", "bool", "void", "long", "short", "unsigned", "signed", "size_t", "FILE", "true", "false", "NULL", "clock_t", "time_t"]:
		h.add_keyword_color(k, Color("4ec9b0"))
	h.add_color_region("\"", "\"", Color("ce9178"))
	h.add_color_region("'", "'", Color("ce9178"))
	h.add_color_region("//", "", Color(0.45, 0.55, 0.45), true)
	h.add_color_region("/*", "*/", Color("6a9955"))
	h.add_color_region("#", "", Color("9b9bff"), true)
	return h


## A settings dialog's heading: a name over a rule.
func _section(parent: Control, title: String) -> void:
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override(&"font_size", 15)
	l.add_theme_color_override(&"font_color", BrickTheme.ACCENT)
	if parent.get_child_count() > 0:
		var gap := Control.new()
		gap.custom_minimum_size.y = 6
		parent.add_child(gap)
	parent.add_child(l)
	parent.add_child(HSeparator.new())


## A row with its label in the shared column.
func _row(parent: Control, label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 130
	row.add_child(l)
	parent.add_child(row)
	return row


## Shows the MS-DOS screen only when the project builds with the MS-DOS backend, and says which backend a build will use.
func _refresh_backend_rows() -> void:
	var pick: String = BACKEND_IDS[(_project_dialog.find_child("PBackend", true, false) as OptionButton).selected]
	var target := _current_target() if _target != null else "native"
	var used := ProjectBuild.resolve_backend(pick, target)
	(_project_dialog.find_child("PDosRow", true, false) as Control).visible = used == "dos"
	var why := ProjectBuild.backend_problem(used, target) if pick != "auto" else ""
	var info := "Builds for %s with %s." % [Toolchains.target(target).name, ProjectBuild.BACKEND_NAMES[used]]
	if why != "":
		info += "\nProblem: " + why
	(_project_dialog.find_child("PBackendInfo", true, false) as Label).text = info
	_project_dialog.reset_size()


func _labeled(parent: Control, label: String, node_name: String, hint: String = "") -> LineEdit:
	var row := _row(parent, label)
	var le := LineEdit.new()
	le.name = node_name
	le.size_flags_horizontal = SIZE_EXPAND_FILL
	le.placeholder_text = hint
	row.add_child(le)
	return le


func _build_dialogs() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_USERDATA if OS.has_feature("web") else FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = not OS.has_feature("web")
	_file_dialog.file_selected.connect(_on_file_chosen)
	_file_dialog.dir_selected.connect(_on_file_chosen)
	add_child(_file_dialog)
	_settings_dialog = AcceptDialog.new()
	_settings_dialog.title = "Toolchains"
	_settings_dialog.ok_button_text = "Save"
	_settings_dialog.add_cancel_button("Cancel")
	_settings_dialog.confirmed.connect(_save_settings_from_dialog)
	add_child(_settings_dialog)
	_tc_manager = ToolchainManager.new()
	_tc_manager.progress.connect(_tc_progress)
	_tc_manager.finished.connect(_tc_finished)
	add_child(_tc_manager)
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "New Project"
	_new_dialog.ok_button_text = "Create & Open"
	var nv := VBoxContainer.new()
	_labeled(nv, "Project name", "Name")
	var prow := HBoxContainer.new()
	var parent_edit := _labeled(prow, "In folder", "Parent")
	parent_edit.custom_minimum_size.x = 320
	var browse := Button.new()
	browse.text = "Browse..."
	browse.pressed.connect(func() -> void:
		_new_dialog.hide()
		_ask_file("new_parent"))
	prow.add_child(browse)
	nv.add_child(prow)
	var nhint := Label.new()
	nhint.name = "NewHint"
	nhint.text = NEW_HINT
	nhint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nhint.custom_minimum_size.x = 500
	nhint.modulate.a = 0.7
	nv.add_child(nhint)
	_new_dialog.add_child(nv)
	_new_dialog.confirmed.connect(_create_project)
	add_child(_new_dialog)
	# the export's progress (a popup with a bar and the file it's on)
	_progress_dialog = AcceptDialog.new()
	_progress_dialog.get_ok_button().visible = false
	_progress_dialog.exclusive = false
	var pvb := VBoxContainer.new()
	pvb.custom_minimum_size.x = 480
	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size.y = 22
	pvb.add_child(_progress_bar)
	_progress_label = Label.new()
	_progress_label.clip_text = true
	_progress_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pvb.add_child(_progress_label)
	_progress_dialog.add_child(pvb)
	add_child(_progress_dialog)
	_project_dialog = AcceptDialog.new()
	_project_dialog.title = "Project Settings"
	_project_dialog.ok_button_text = "Save"
	_project_dialog.add_cancel_button("Cancel")
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override(&"separation", 6)
	_section(pv, "Project")
	_labeled(pv, "Name", "PName")
	_labeled(pv, "Version", "PVersion", "1.0")
	_section(pv, "Run")
	_labeled(pv, "Arguments", "PArgs", "e.g. --name=Ada --seed 1 -v")
	var flags := Label.new()
	var lines := PackedStringArray(["Run passes these to the program (after --cd <project folder>). Every C-Bricks program also takes:"])
	for f in ProjectBuild.FLAGS:
		lines.append("    %-15s %s" % [f[0], f[1]])
	lines.append("Anything else reaches the Program Arguments brick.")
	flags.text = "\n".join(lines)
	flags.add_theme_font_override(&"font", Inspector._mono())
	flags.add_theme_font_size_override(&"font_size", 12)
	flags.modulate.a = 0.75
	flags.visible = false  # (folded: the list is long, and most people never need it)
	var flags_btn := Button.new()
	flags_btn.text = "Program flags ▸"
	flags_btn.flat = true
	flags_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	flags_btn.toggle_mode = true
	flags_btn.toggled.connect(func(on: bool) -> void:
		flags.visible = on
		flags_btn.text = "Program flags ▾" if on else "Program flags ▸"
		_project_dialog.reset_size())
	pv.add_child(flags_btn)
	pv.add_child(flags)
	# Graphics (2026-11-09, user: "a graphics backend dropdown"): the backend that draws a graphics project; the
	# MS-DOS screen only shows when that backend is the MS-DOS one
	_section(pv, "Graphics")
	var brow := _row(pv, "Backend")
	var backend_pick := OptionButton.new()
	backend_pick.name = "PBackend"
	for id in BACKEND_IDS:
		backend_pick.add_item(ProjectBuild.BACKEND_NAMES[id])
	backend_pick.tooltip_text = "What draws and plays a graphics project. Automatic follows the Target (MS-DOS: its own software renderer; everything else: raylib). A backend the Target can't use is a problem."
	backend_pick.item_selected.connect(func(_i: int) -> void: _refresh_backend_rows())
	brow.add_child(backend_pick)
	var binfo := Label.new()
	binfo.name = "PBackendInfo"
	binfo.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	binfo.custom_minimum_size.x = 400
	binfo.add_theme_font_size_override(&"font_size", 12)
	binfo.modulate.a = 0.75
	pv.add_child(binfo)
	var drow := _row(pv, "MS-DOS screen")
	drow.name = "PDosRow"
	var dos_pick := OptionButton.new()
	dos_pick.name = "PDosScreen"
	for i in DOS_SCREENS.size():
		dos_pick.add_item(DOS_SCREEN_NAMES[i], i)
	dos_pick.tooltip_text = "The screen an MS-DOS build opens: VGA 320 x 200 runs on every PC and emulator; the VESA modes need a card with VESA 2.0 (and say so if it hasn't). Auto: the smallest that fits the Open window's size."
	drow.add_child(dos_pick)
	_project_dialog.add_child(pv)
	_project_dialog.confirmed.connect(_save_project_settings)
	add_child(_project_dialog)


## Puts the dividers where the panels get their saved sizes (a split's offset
## isn't in pixels of either panel, so it's corrected from what was measured).
func _apply_panel_sizes() -> void:
	for _f in 2:
		await get_tree().process_frame
	for _pass in 3:
		var left: float = _left_area.size.x
		var insp: float = _inspector.get_parent().size.x
		var bottom: float = _bottom.get_parent().size.y
		_hsplit.split_offset += int(_panel_sizes.left - left)
		_rsplit.split_offset -= int(_panel_sizes.inspector - insp)
		_vsplit.split_offset -= int(_panel_sizes.bottom - bottom)
		await get_tree().process_frame


func _remember_panel_sizes() -> void:
	_panel_sizes = {"left": int(_left_area.size.x), "inspector": int(_inspector.get_parent().size.x), "bottom": int(_bottom.get_parent().size.y)}
	_save_settings()


func _show_body(open: bool) -> void:
	for area in _body + _graph_tools:
		area.visible = open
	if open:
		_apply_panel_sizes()
	if _start != null:
		_start.visible = not open
	if not open:
		_set_status("status_info", "Make or open a project to start.")


## The project manager (like Godot's): recent projects, examples, new / open.
func _build_start(parent: Control) -> void:
	var center := CenterContainer.new()
	center.size_flags_vertical = SIZE_EXPAND_FILL
	parent.add_child(center)
	_start = center
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(900, 0)
	column.add_theme_constant_override(&"separation", 10)
	center.add_child(column)
	var heading := Label.new()
	heading.text = "C-Bricks Projects"
	heading.add_theme_font_size_override(&"font_size", 22)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(heading)
	var hint := Label.new()
	hint.text = "A project is a folder: its scripts (.cbricks) become C files, everything else in it (models, images, text) is the program's assets. It builds for this computer, Windows, macOS, Linux, the BSDs, the web and more."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate.a = 0.8
	column.add_child(hint)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)
	for spec in [["New Project...", _open_new_project, BrickTheme.LOCAL_COLOR], ["Open Project...", func() -> void: _ask_file("open_project"), Color()]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		if spec[2] != Color():
			b.add_theme_color_override(&"font_color", spec[2])
		buttons.add_child(b)
	var filter_row := HBoxContainer.new()
	column.add_child(filter_row)
	_start_filter = LineEdit.new()
	_start_filter.placeholder_text = "Filter both lists: part of a name or folder"
	_start_filter.clear_button_enabled = true
	_start_filter.right_icon = context.brick_theme.icon("search")
	_start_filter.size_flags_horizontal = SIZE_EXPAND_FILL
	_start_filter.text_changed.connect(func(_t: String) -> void: refresh_start())
	_start_filter.text_submitted.connect(func(_t: String) -> void: _open_start_pick())
	filter_row.add_child(_start_filter)
	var refresh := Button.new()
	refresh.flat = true
	refresh.icon = context.brick_theme.icon("reload")
	refresh.tooltip_text = "Look again"
	refresh.pressed.connect(refresh_start)
	filter_row.add_child(refresh)
	# (user, 2026-11-08) two lists: your projects (carry on where you left them) and the
	# examples (each click a new copy, which then shows in Recent Projects)
	var lists := HBoxContainer.new()
	lists.add_theme_constant_override(&"separation", 12)
	column.add_child(lists)
	for spec in [["Recent Projects", "Double-click (or Enter) to open: it carries on where you left it. Example copies are marked."], ["Example Projects", "Click to open a new copy of the example (it shows in Recent Projects): the example itself never changes."]]:
		var side := VBoxContainer.new()
		side.size_flags_horizontal = SIZE_EXPAND_FILL
		side.size_flags_stretch_ratio = 1.6 if spec[0] == "Recent Projects" else 1.0
		lists.add_child(side)
		var head := Label.new()
		head.text = spec[0]
		head.add_theme_font_size_override(&"font_size", 16)
		side.add_child(head)
		var il := ItemList.new()
		il.custom_minimum_size.y = 340
		il.tooltip_text = spec[1]
		il.name = spec[0].replace(" ", "")
		side.add_child(_framed(il))
		if spec[0] == "Recent Projects":
			_start_list = il
			il.item_activated.connect(func(i: int) -> void: _open_start_item(il, i))
		else:
			_example_list = il
			il.item_clicked.connect(func(i: int, _at: Vector2, button: int) -> void:
				if button == MOUSE_BUTTON_LEFT:
					_open_start_item.call_deferred(il, i))
			il.item_activated.connect(func(i: int) -> void: _open_start_item(il, i))


func refresh_start() -> void:
	if _start_list == null:
		return
	_start_list.clear()
	_example_list.clear()
	var words := _start_filter.text.to_lower().split(" ", false) if _start_filter != null else PackedStringArray()
	var fits := func(text: String) -> bool:
		var lower := text.to_lower()
		for w in words:
			if not lower.contains(w):
				return false
		return true
	for dir in _recent:
		if CBProject.is_project(dir) and fits.call(dir + " " + CBProject.project_name(dir)):
			var copy := _is_example_copy(dir)
			var label := "%s     %s" % [CBProject.project_name(dir), "(example copy %s)" % dir.get_file() if copy else dir]
			var i := _start_list.add_item(label, context.brick_theme.icon("script" if copy else "project"))
			_start_list.set_item_metadata(i, ["project", dir])
			_start_list.set_item_tooltip(i, dir + ("\nAn example's copy, kept in the app's data: Save asks where to keep it as your project." if copy else ""))
			_start_list.set_item_custom_fg_color(i, Color(BrickTheme.LOCAL_COLOR, 0.75) if copy else BrickTheme.LOCAL_COLOR)
	if _start_list.item_count == 0:
		_start_list.add_item("(no projects yet: New Project, or an example)" if words.is_empty() else "(none match the filter)", null, false)
	var names := Array(DirAccess.get_directories_at("res://examples"))
	names.sort_custom(func(a, b): return CBProject.project_name("res://examples/" + a) < CBProject.project_name("res://examples/" + b))
	for d in names:
		var res := "res://examples/" + str(d)
		if CBProject.is_project(res) and fits.call(str(d) + " " + CBProject.project_name(res)):
			var i := _example_list.add_item(CBProject.project_name(res), context.brick_theme.icon("script"))
			_example_list.set_item_metadata(i, ["example", res])
			_example_list.set_item_tooltip(i, "Opens a new copy of %s (then in Recent Projects)." % CBProject.project_name(res))
	if _example_list.item_count == 0:
		_example_list.add_item("(none match the filter)", null, false)


func _open_start_item(list: ItemList, i: int) -> void:
	if i < 0 or i >= list.item_count:
		return
	var m = list.get_item_metadata(i)
	if not m is Array:
		return
	if m[0] == "project":
		open_project(m[1])
	else:
		open_example(m[1])


## Enter in the filter: the selected (or first) recent project, else the first example.
func _open_start_pick() -> void:
	for list: ItemList in [_start_list, _example_list]:
		var picked := list.get_selected_items()
		var i: int = picked[0] if not picked.is_empty() else 0
		if i < list.item_count and list.is_item_selectable(i):
			_open_start_item(list, i)
			return


func _framed(area: Control, padding: int = -1) -> PanelContainer:
	var frame := PanelContainer.new()
	var style := context.brick_theme.frame_style()
	if padding >= 0:
		style.set_content_margin_all(padding)
	frame.add_theme_stylebox_override(&"panel", style)
	frame.size_flags_horizontal = area.size_flags_horizontal
	frame.size_flags_vertical = area.size_flags_vertical
	frame.add_child(area)
	return frame


func _set_status(icon_name: String, text: String) -> void:
	if _status == null:
		return
	_status_icon.texture = context.brick_theme.icon(icon_name)
	_status.text = text
	_status.tooltip_text = text


func _log_info(t: String) -> void:
	_console.push_color(Color(0.7, 0.75, 0.85)); _console.add_text(t + "\n"); _console.pop()


func _log_error(t: String) -> void:
	_console.push_color(Color(1, 0.45, 0.45)); _console.add_text(t + "\n"); _console.pop()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var ctrl := k.ctrl_pressed or k.meta_pressed
	var shift := k.shift_pressed
	var key := k.keycode
	if key == KEY_F5:
		if _paused_script != "":
			debug_continue()
		else:
			build(true)
	elif key == KEY_F6:
		build(false)
	elif key == KEY_F8:
		debug_continue()
	elif key == KEY_F10:
		debug_step_over()
	elif key == KEY_F11 and shift:
		debug_step_out()
	elif key == KEY_F11:
		debug_step()
	elif key == KEY_F9 and has_graph() and context.selected > 0:
		toggle_breakpoint(context.selected)
	elif ctrl and key == KEY_S:
		if shift and not _is_example():
			save_all()
		else:
			save()
	elif ctrl and key == KEY_W:
		close_tab(_cur)
	elif ctrl and key == KEY_O:
		_ask_file("open_project")
	elif ctrl and key == KEY_N and has_project():
		_dock._ask_new_script(_dock._selected_folder())
	elif ctrl and key == KEY_Z:
		if shift:
			redo()
		else:
			undo()
	elif ctrl and key == KEY_Y:
		redo()
	elif ctrl and key == KEY_E:
		export_project()
	elif ctrl and key == KEY_F:
		open_find()
	else:
		return
	accept_event()


# ----------------------------------------------------------------------- the world file

## The World tab or Properties changed world.cnworld: save it, rebuild, refresh.
## A script's graph: its open tab's, else the file's.
func _script_graph(path: String) -> Dictionary:
	for t in _tabs:
		if t.path == path:
			return t.graph
	return CBProject.read_script(path)


## A Script object's type picked in Properties: the file's Side (its open tab's
## too), and every Script object of that file shows the new type.
func _set_script_side(rel: String, side: String) -> void:
	var path := project_dir.path_join(rel)
	var open := false
	for t in _tabs:
		if t.path == path:
			t.graph["side"] = side
			_save_tab(t)
			open = true
	if not open:
		var g := CBProject.read_script(path)
		if g.is_empty():
			return
		g["side"] = side
		CBProject.write_script(path, g)
	_sync_script_objects()
	_on_world_changed("%s runs on: %s" % [rel.get_file(), side])


## Script objects' types follow their files' Sides (also after a script's Side changes).
func _sync_script_objects() -> bool:
	var changed := false
	for o in context.world.get("objects", []):
		if CBTypes.is_script_object(o) and str(o.get("script", "")) != "":
			var t := CBTypes.script_type_of(str(_script_graph(project_dir.path_join(str(o.get("script", "")))).get("side", "Shared")))
			if str(o["class"]) != t:
				o["class"] = t
				changed = true
	return changed


func _on_world_changed(action: String) -> void:
	if not has_project():
		return
	_sync_script_objects()
	if context.scene_path == "":
		context.scene_path = CBProject.world_path(project_dir)
	_scene_record(action)
	_save_world(action)


## The scene's change into its undo history (before: the scene as last saved).
func _scene_record(action: String) -> void:
	var h: Dictionary = _scene_hist.get(context.scene_path, {})
	if h.is_empty():
		return
	var now: Dictionary = context.world.duplicate(true)
	if now == h.last:
		return
	h.undo.append([action, h.last])
	if h.undo.size() > 200:
		h.undo.pop_front()
	h.redo.clear()
	h.last = now


## Undo (back) / redo the edited scene's last change.
func _scene_step(back: bool) -> void:
	var h: Dictionary = _scene_hist.get(context.scene_path, {})
	if h.is_empty():
		return
	var from: Array = h.undo if back else h.redo
	if from.is_empty():
		_set_status("status_info", "Nothing to %s in %s" % ["undo" if back else "redo", context.scene_path.get_file()])
		return
	var step: Array = from.pop_back()
	(h.redo if back else h.undo).append([step[0], h.last])
	h.last = (step[1] as Dictionary).duplicate(true)
	var picked := int(context.world_object.get("id", 0))
	context.world.clear()
	context.world.merge((step[1] as Dictionary).duplicate(true))
	context.world_object = {}
	for o in context.world.get("objects", []):
		if int(o.id) == picked:
			context.world_object = o
	_save_world("%s: %s" % ["Undo" if back else "Redo", step[0]])


func _save_world(action: String) -> void:
	CBProject.write_scene(context.scene_path, context.world)
	_dock.refresh()
	context.refresh_flat()
	_set_status("status_info", "%s (saved %s)" % [action, context.scene_path.get_file()])
	_world_dock.rebuild()
	_view_3d.rebuild()
	_view_2d.queue_redraw()
	_recompile()
	_queue_redraw(Context.Redraw.PROPERTIES)


## A problem in a scene, or a scene opened from FileSystem: the 3D screen
## (the Scene tree is always on the left).
func show_world_tab() -> void:
	switch_screen("3D")


## Edits a scene (a .cbscene; an old project's world.cnworld): the Scene tree, 2D and
## 3D show it; it gets a tab over the Scene tree (show: also the 3D screen).
func open_scene(path: String, show := true) -> void:
	if path not in _scene_paths:
		_scene_paths.append(path)
	context.scene_path = path
	context.world = CBProject.read_scene(path)
	if not _scene_hist.has(path):
		_scene_hist[path] = {"undo": [], "redo": [], "last": context.world.duplicate(true)}
	else:
		_scene_hist[path].last = context.world.duplicate(true)
	context.world_object = {}
	context.refresh_flat()
	_world_dock.show_scenes(_scene_paths, path, CBProject.world_path(project_dir))
	_world_dock.rebuild()
	_view_3d.rebuild()
	_view_2d.queue_redraw()
	_queue_redraw(Context.Redraw.PROPERTIES)
	if show:
		show_world_tab()


## Closes a scene's tab (the Main scene's stays).
func close_scene(path: String) -> void:
	if path == CBProject.world_path(project_dir) or path not in _scene_paths:
		return
	var i := _scene_paths.find(path)
	_scene_paths.erase(path)
	if context.scene_path == path:
		open_scene(_scene_paths[clampi(i - 1, 0, _scene_paths.size() - 1)], false)
	else:
		_world_dock.show_scenes(_scene_paths, context.scene_path, CBProject.world_path(project_dir))


## Shows one of the main screens: "2D", "3D" or "Script" (Godot's).
func switch_screen(which: String) -> void:
	if not _screens.has(which):
		which = "Script"
	_screen = which
	for k in _screens:
		_screens[k].visible = k == which
	for k in _screen_buttons:
		_screen_buttons[k].set_pressed_no_signal(k == which)
	if _node_bar != null:
		_node_bar.visible = which == "Script"  # the script tabs and brick tools only under Node
	if _palette_frame != null:
		_palette_frame.visible = which == "Script"  # Node: the palette replaces Scene / FileSystem
		_left_split.visible = which != "Script"
	if which == "3D" and _view_3d != null:
		_view_3d.rebuild()
	elif which == "2D" and _view_2d != null:
		_view_2d.rebuild(project_dir)
	_save_settings()


## A dock's title over it (Godot's dock tabs): "Scene", "FileSystem".
func _dock_box(title: String, icon_name: String, dock: Control, tip: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_theme_constant_override(&"separation", 4)
	var head := HBoxContainer.new()
	var icon := TextureRect.new()
	icon.texture = context.brick_theme.icon(icon_name)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	head.add_child(icon)
	var label := Label.new()
	label.text = title
	label.tooltip_text = tip
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.add_theme_color_override(&"font_color", BrickTheme.LOCAL_COLOR)
	head.add_child(label)
	box.add_child(head)
	box.add_child(dock)
	return box
