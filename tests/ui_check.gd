extends SceneTree
## Drives the real editor window (needs a display):
##   godot --path . --resolution 1600x900 -s res://tests/ui_check.gd
## On a copy of the arguments_and_files example (in user://ui_check, never your
## projects): opens it, builds and runs it with Trace, opens the second script,
## breaks its C on purpose and checks the compiler error lands on its brick.
## Screenshots go to tests/reports/ui_*.png. Your recent-projects list is put back.
## Exit code: the number of failed checks.

const SETTINGS := "user://settings.cfg"
const BrickTheme = preload("res://scripts/editor/brick_theme.gd")

var _panel: Control = null
var _frame := 0
var _failed := 0
var _dir := ""
var _settings_backup := ""


func _init() -> void:
	if FileAccess.file_exists(SETTINGS):
		_settings_backup = FileAccess.get_file_as_string(SETTINGS)
		# Start from the app's defaults (panel sizes, screen): the user's own settings
		# made checks depend on how they last left the window. Restored in _finish().
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	# The user's example copies (user://example) are set aside and put back in _finish(): the
	# app deletes copies that aren't in Recent Projects at startup, and this run's list is empty.
	var ex := OS.get_user_data_dir().path_join("example")
	var aside := OS.get_user_data_dir().path_join("example_set_aside_by_ui_check")
	if DirAccess.dir_exists_absolute(ex) and not DirAccess.dir_exists_absolute(aside):
		DirAccess.rename_absolute(ex, aside)
	_dir = OS.get_user_data_dir().path_join("ui_check")
	_remove_tree(_dir)  # the last run's copy (deleted, not trashed: it's ours)
	CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/arguments_and_files"), _dir)
	_panel = load("res://main.tscn").instantiate()
	root.add_child(_panel)


static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path) or not path.contains("app_userdata"):
		return
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/reports"))
	root.get_texture().get_image().save_png("res://tests/reports/ui_%s.png" % name)


func _process(_delta: float) -> bool:
	# A build / run in flight holds the frame-numbered steps until it ends
	# (compile time varies: fixed frame counts raced it, BUGS.md).
	if _hold.is_valid():
		if not _hold.call():
			_held += 1
			if _held > 3600:
				_hold = Callable()
				_check(false, "waited too long for a build / run to end")
				_finish()
			return false
		_hold = Callable()
	_frame += 1
	if _frame > 20000:  # (a step that died of a script error never hands on: don't wait forever)
		_check(false, "the check stalled at frame %d (a script error in a step?)" % _frame)
		_finish()
		return true
	match _frame:
		8:
			_shot("project_manager")
			_panel.open_project(_dir)
		20:
			_check(_panel._tabs.size() == 1, "the project opens its main script")
			_check(_panel._palette.is_visible_in_tree() and not _panel._world_dock.is_visible_in_tree() and not _panel._dock.is_visible_in_tree(), "on the Node screen the palette takes the left column")
			_panel.switch_screen("3D")
			_check(_panel._world_dock.is_visible_in_tree() and _panel._dock.is_visible_in_tree() and not _panel._palette.is_visible_in_tree(), "on 2D / 3D the left column has the Scene tree above FileSystem")
			var con: Rect2 = _panel._bottom.get_global_rect()
			_check(con.position.x >= _panel._left_area.get_global_rect().end.x - 1 and con.end.x <= _panel._inspector.get_global_rect().position.x + 1, "the bottom panel sits between the left column and Properties")
			_panel.switch_screen("Script")
			_check(_panel._screen_buttons.size() == 3 and _panel._screen == "Script" and _panel._palette.is_visible_in_tree(), "2D / 3D / Script screens; the Script screen shows the palette beside the canvas")
			_check(_panel._build.errors.is_empty(), "the project generates without problems")
			_check(_panel._build.files.has("scripts__util.c") and _panel._build.files.has("cbricks.h"), "one .c per script, plus cbricks.h")
			_panel._trace_btn.button_pressed = true
			_panel.build(true)
			_hold = _build_done
		200:
			var text: String = _panel._console.get_parsed_text()
			_check(text.contains("Hello, Ada"), "Run passes the project's run arguments (--name=Ada)")
			_check(text.contains("cube.obj has this many lines: 16"), "the program finds its assets (run from the project folder)")
			_check(not text.contains("[trace]"), "trace lines light bricks up instead of filling the console")
			var win := Rect2(Vector2.ZERO, Vector2(root.size))
			var con: Rect2 = _panel._console.get_global_rect()
			_check(_panel._console.is_visible_in_tree() and win.encloses(con) and con.size.y >= 60, "the Console is on screen (%s in a %s window)" % [con, root.size])
			_shot("run")
			_panel.open_script(_dir.path_join("scripts/util.cbricks"))
		215:
			_check(_panel._tabs.size() == 2, "a second script opens in its own tab")
			_shot("project_tab")
			_panel.switch_screen("3D")
			_check(_panel._view_3d.is_visible_in_tree() and not _panel._canvas.is_visible_in_tree() and not _panel._palette.is_visible_in_tree(), "the 3D screen replaces the Script screen (palette and canvas)")
			_panel.switch_screen("Script")
			var util: Dictionary = _panel._tabs[1]
			for n in util.graph.nodes:
				if n.type == "raw_c":
					n.fields.code = "count = undefined_name;"
			util.dirty = true
			_panel.build(false)
			_hold = _build_done
		400:
			var util: Dictionary = _panel._tabs[1]
			_check(util.errors.size() == 1, "the C compiler's error lands on its brick")
			var first: String = _panel.problem_text(0)
			_check(first.contains("scripts/util.cbricks, C Code (node"), "Problems names the script and the brick")
			_panel._on_problem_selected(0)
		420:
			_shot("compiler_error")
			# The debugger: fix the C again, a breakpoint on main's "if lines > 0", run.
			var util: Dictionary = _panel._tabs[1]
			for n in util.graph.nodes:
				if n.type == "raw_c":
					n.fields.code = "for (const char *p = text; *p; p++) {\n    if (*p == '\\n') count++;\n}"
			util.dirty = true
			_panel._switch_tab(0)
			_panel.toggle_breakpoint(9)
			_check(9 in _panel.context.graph.get("breakpoints", []), "F9 / right-click sets a breakpoint")
			_panel.build(true)
			_wait_for = func() -> bool: return _panel._paused_script != ""
			_then = _at_breakpoint
	if _wait_for.is_valid():
		if _wait_for.call():
			_wait_for = Callable()
			var next := _then
			_then = Callable()
			next.call()
		elif _frame > 2400:
			_check(false, "waited too long (%s)" % _then)
			_finish()
	return false


var _wait_for: Callable = Callable()
## Holds the frame-numbered steps while it returns false (see _process).
var _hold: Callable = Callable()
var _held := 0


func _build_done() -> bool:
	return _panel._thread == null and _panel._proc.is_empty()
var _then: Callable = Callable()


func _at_breakpoint() -> void:
	_check(_panel._paused_brick == 9 and _panel._paused_script.ends_with("main.cbricks"), "the program pauses at the breakpoint")
	_check(_panel.context.debug_values.get("lines", "") == "16", "the Debug tab has the variables' values (lines = 16)")
	_check(_panel.context.paused_brick == 9, "the paused brick is outlined")
	# Watches: worked out from the paused variables; a typo gets a guess.
	_panel._add_watch("lines * 2")
	_panel._add_watch("lnes + 1")
	_panel._add_watch("who + \"!\"")
	var shown := {}
	for c in _panel._debug_tree.get_root().get_children():
		if c.get_text(0) == "Watches":
			for w in c.get_children():
				shown[w.get_text(0)] = w.get_text(2)
	_check(shown.get("lines * 2", "") == "32" and shown.get("who + \"!\"", "") == "Ada!" and str(shown.get("lnes + 1", "")).contains("did you mean 'lines'"), "watches are worked out at the pause (%s)" % [shown])
	_check(Array(CBProject.load_config(_dir).get_value("debug", "watches", [])).size() == 3, "watches are saved in project.cbproj")
	_shot("debug_paused")
	_panel.debug_step()
	_wait_for = func() -> bool: return _panel._paused_script != "" and _panel._paused_brick != 9
	_then = _after_step


func _after_step() -> void:
	_check(_panel._paused_brick == 11, "Step pauses at the next brick (the True chain's first)")
	_panel._vsplit.split_offset -= 220  # a taller bottom panel for the Watches screenshot
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 10
	_then = _after_watch_shot


func _after_watch_shot() -> void:
	_shot("watches")
	_panel._vsplit.split_offset += 220
	_panel.debug_continue()
	_wait_for = func() -> bool: return _panel._proc.is_empty()
	_then = _after_continue


func _after_continue() -> void:
	_check(_panel._console.get_parsed_text().contains("cube.obj has this many lines: 16"), "Continue runs the program to its end")
	# Find (Ctrl+F) lists bricks of every script.
	_panel.open_find()
	_panel._find_edit.text = "count"
	_panel._fill_find()
	var hits := []
	for i in _panel._find_list.item_count:
		hits.append(_panel._find_list.get_item_text(i))
	_check(hits.any(func(h): return h.contains("util.cbricks")) and hits.any(func(h): return h.contains("main.cbricks")), "Find lists matching bricks in every script")
	_panel._find_popup.hide()
	# Renaming a function: the other script's Call Function follows.
	_panel._switch_tab(1)
	var fn: Dictionary = {}
	for n in _panel.context.graph.nodes:
		if n.type == "function":
			fn = n
	Ops.rename_function(_panel.context.graph, fn, "count_rows")
	_panel._on_function_renamed("count_lines", "count_rows")
	var calls: Array = _panel._tabs[0].graph.nodes.filter(func(n): return n.type == "call")
	_check(not calls.is_empty() and calls.all(func(n): return n.fields.function == "count_rows"), "renaming a function renames its calls in other scripts")
	# A Map brick: in the palette (search), on the canvas, in Properties.
	_panel._switch_tab(0)
	_panel.switch_screen("Script")
	_panel._palette._search.text = "map"
	_panel._palette._refill()
	var entries := []
	for c in _panel._palette._list.get_children():
		if c is Button:
			entries.append(c.text)
	_check(entries.any(func(t): return str(t).contains("Map")), "the palette finds the Map brick (%s)" % [entries])
	var node: Dictionary = _panel._canvas.add_node_in_view("map")
	_check(not node.is_empty(), "a Map brick goes on the canvas")
	if not node.is_empty():
		node.fields.op = "Get or"
		_panel.context.notify_changed(11, "Map settings")
		_panel.context.select(int(node.id))
	var shown_at := _frame
	_wait_for = func() -> bool: return _frame > shown_at + 30
	_then = _after_map_brick


func _after_map_brick() -> void:
	_shot("map_brick")
	# Remotes: a Define Remote, then a Fire Server picking it in Properties' dropdown.
	var decl: Dictionary = _panel._canvas.add_node_in_view("remote")
	if not decl.is_empty():
		decl.fields.name = "buy"
		decl.fields.values = [["item", "string"], ["amount", "int"]]
		_panel.context.notify_changed(11, "Remote settings")
	var fire: Dictionary = _panel._canvas.add_node_in_view("fire_server")
	_check(not decl.is_empty() and not fire.is_empty(), "Define Remote and Fire Server go on the canvas")
	if not fire.is_empty():
		_panel._recompile()
		_check(CBTypes.remotes.has("buy"), "the build knows the remote 'buy' (%s)" % [CBTypes.remotes.keys()])
		fire.fields.remote = "buy"
		Ops.refit_calls(_panel.context.graph)
		_panel.context.notify_changed(11, "Pick remote")
		_check(fire.args.has("item") and fire.args.has("amount"), "Fire Server gets a row per value of the remote (%s)" % [fire.args.keys()])
		# Invoke (2026-11-07): an Ask server remote; Invoke Server's dropdown offers only questions.
		var ask: Dictionary = _panel._canvas.add_node_in_view("remote")
		ask.fields.name = "price"
		ask.fields.direction = "Ask server"
		ask.fields.values = [["item", "string"]]
		ask.fields.answer = "int"
		var inv: Dictionary = _panel._canvas.add_node_in_view("invoke_server")
		_panel._recompile()
		_panel.context.select(int(inv.id))
		_panel._inspector.rebuild()
		var offered := []
		for ob in _panel._inspector.find_children("*", "OptionButton", true, false):
			for k in (ob as OptionButton).item_count:
				offered.append((ob as OptionButton).get_item_text(k))
		_check("price" in offered and "buy" not in offered, "Invoke Server's Remote offers the Ask server remotes only (%s)" % [offered])
		inv.fields.remote = "price"
		Ops.refit_calls(_panel.context.graph)
		_panel.context.notify_changed(11, "Pick question")
		_check(inv.args.has("item") and inv.args.has("timeout") and inv.outs.has("answer") and inv.outs.has("answered"), "Invoke Server gets the question's rows, a Timeout, Answer and Answered (%s / %s)" % [inv.args.keys(), inv.outs.keys()])
		_panel.context.select(int(fire.id))
	var shown_at := _frame
	_wait_for = func() -> bool: return _frame > shown_at + 30
	_then = _after_remote_brick


func _after_remote_brick() -> void:
	_shot("remote_brick")
	# The World tab: add a Part, give it a field value, check world.cnworld and the C.
	_panel.show_world_tab()
	_panel._world_dock._add_object("Shape3D")
	var o: Dictionary = _panel.context.world_object
	_check(str(o.get("class", "")) == "Shape3D" and str(o.get("name", "")) == "Shape3D", "the Scene tab adds a Shape3D (%s)" % [o])
	o.name = "Part"  # (the steps below follow it by this name)
	o.fields["position"] = "1, 2, 3"
	_panel._on_world_changed("Set position")
	var saved := CBProject.read_world(_dir)
	_check(saved.objects.size() == 1 and str(saved.objects[0].fields.get("position", "")) == "1, 2, 3", "world.cnworld is saved with the object's fields")
	var scene: String = _panel._build.get("files", {}).get("cbricks_scene.c", "")
	_check(scene.contains("cb_scene_new(&cls_Shape3D_class, ") and scene.contains("cb_v3(1, 2, 3)"), "the world file becomes C (cbricks_scene.c)")
	# Target capabilities (2026-11-08): MS-DOS can't do the scene (graphics, 3D) yet: Problems
	# name the object; Build stops; back to this computer, they're gone.
	var dos_i := Toolchains.TARGETS.map(func(t): return t.id).find("linux-riscv64")  # (no raylib there: no graphics, no 3D; MS-DOS can do them all now)
	_panel._target.select(dos_i)
	_panel._target.item_selected.emit(dos_i)
	var texts := []
	for i in _panel._problems.get_root().get_child_count():
		texts.append(_panel.problem_text(i))
	_check(texts.any(func(t): return str(t).contains("can't do 3D") or str(t).contains("can't do graphics")) and not texts.any(func(t): return str(t).contains("can't do networking")), "a target without graphics (Linux RISC-V 64): Problems name the scene's graphics / 3D, not networking (%s)" % [texts])
	_panel.build(false)
	_check(not _panel._busy() and _panel._status.text.contains("can't build"), "Build stops: MS-DOS can't build this project (%s)" % _panel._status.text)
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 6
	_then = _target_back


func _target_back() -> void:
	_shot("target_problems")
	# Wrong-place bricks (2026-11-08, user): greyed in the palette, greyed + outlined on the canvas.
	_check(not _panel.context.misplaced_bricks.has(102), "main's Fire Server is fine on every target (networking works everywhere) (%s)" % [_panel.context.misplaced_bricks.keys()])
	_panel.switch_screen("Script")
	_panel._palette._show_category("graphics")
	var open_window: Button = null
	var draw_3d: Button = null
	var fire: Button = null
	for b in _panel._palette._list.get_children():
		if b is Button and (b as Button).text == "Open window":
			open_window = b
		if b is Button and (b as Button).text == "Draw 3D":
			draw_3d = b
		if b is Button and (b as Button).text == "Fire Server":
			fire = b
	_check(open_window != null and open_window.disabled and draw_3d != null and draw_3d.disabled and open_window.tooltip_text.contains("RISC-V"), "the palette greys Open window and Draw 3D for a target without graphics, saying why")
	_check(fire != null and not fire.disabled, "the palette keeps Fire Server (networking works on every target, MS-DOS too)")
	_check(_panel.context.blocked("draw3d") != "" and _panel.context.blocked("print") == "", "Draw 3D is blocked for a target without graphics, Print isn't")
	var side_before := str(_panel.context.graph.get("side", "Shared"))
	_panel.context.graph["side"] = "Client"
	_check(_panel.context.blocked("player_key") != "" and _panel.context.blocked("print") == "", "in a Client script the palette greys Player Key (the server's), not Print")
	_panel.context.graph["side"] = side_before
	_part = _panel.context.world_object
	_panel._on_problem_selected(0)  # the canvas goes to the first problem
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 6
	_then = _target_back_2


var _part: Dictionary = {}


func _target_back_2() -> void:
	_shot("misplaced")
	_panel.context.world_object = _part  # (the problem's click picked the brick instead)
	_panel.switch_screen("3D")
	_panel._target.select(0)
	_panel._target.item_selected.emit(0)
	_check(_panel._target_problems.is_empty(), "back on this computer: no target problems")
	# Project Settings' MS-DOS screen (user: "maybe 2 is a project setting?"): saved in the project, kept on reopening
	_panel._open_project_settings()
	var dos_pick := _panel._project_dialog.find_child("PDosScreen", true, false) as OptionButton
	_check(dos_pick != null and dos_pick.selected == 0 and dos_pick.item_count == 4, "Project Settings has an MS-DOS screen (Auto, VGA 320 x 200, VESA 640 x 480 / 800 x 600), Auto at first")
	var bk_pick := _panel._project_dialog.find_child("PBackend", true, false) as OptionButton
	_check(bk_pick != null and bk_pick.selected == 0 and bk_pick.item_count == 3, "Project Settings has a Graphics backend dropdown (Automatic, raylib, MS-DOS), Automatic at first")
	_check(not (_panel._project_dialog.find_child("PDosRow", true, false) as Control).visible, "the MS-DOS screen row is hidden while the backend is raylib's (native target)")
	bk_pick.select(2)
	bk_pick.item_selected.emit(2)
	_check((_panel._project_dialog.find_child("PDosRow", true, false) as Control).visible, "picking the MS-DOS backend shows the MS-DOS screen row")
	_check((_panel._project_dialog.find_child("PBackendInfo", true, false) as Label).text.contains("Problem"), "and says an MS-DOS renderer can't build for this computer")
	dos_pick.select(2)
	_panel._save_project_settings()
	_check(str(CBProject.load_config(_dir).get_value("graphics", "backend", "")) == "dos", "the backend is saved in the project")
	_panel._open_project_settings()
	bk_pick = _panel._project_dialog.find_child("PBackend", true, false) as OptionButton
	bk_pick.select(0)
	bk_pick.item_selected.emit(0)
	dos_pick = _panel._project_dialog.find_child("PDosScreen", true, false) as OptionButton
	dos_pick.select(2)
	_panel._save_project_settings()
	_check(int(CBProject.load_config(_dir).get_value("dos", "screen", 0)) == 640, "the MS-DOS screen is saved in the project (640)")
	_panel._open_project_settings()
	_check((_panel._project_dialog.find_child("PDosScreen", true, false) as OptionButton).selected == 2, "and shows again when the settings reopen")
	_panel._open_project_settings()
	var pick2 := _panel._project_dialog.find_child("PBackend", true, false) as OptionButton
	pick2.select(2)
	pick2.item_selected.emit(2)
	var dlg: Window = _panel._project_dialog  # (its own window: its content is shown in the main one for a frame to be shot)
	var content: Control = dlg.find_child("PName", true, false).get_parent().get_parent()
	var holder := PanelContainer.new()
	root.add_child(holder)
	holder.position = Vector2(300, 80)
	content.reparent(holder)
	var ticks := [0]
	_hold = func() -> bool:
		ticks[0] += 1
		if ticks[0] == 8:
			_shot("project_settings")
			content.reparent(dlg)
			holder.queue_free()
		return ticks[0] >= 9
	_panel._project_dialog.hide()
	# Script type (user, 2026-11-08): the canvas is tinted by where the script runs, labelled top right.
	var canvas = _panel._canvas
	var kept_side := str(_panel.context.graph.get("side", "Shared"))
	var bgs: Array = []
	for side in ["Shared", "Server", "Client"]:
		_panel.context.graph["side"] = side
		canvas.rebuild()
		var bg: Color = (canvas.theme.get_stylebox(&"panel", &"GraphEdit") as StyleBoxFlat).bg_color
		bgs.append(bg)
		_check(canvas._side_label.text.contains(BrickTheme.SIDE_TYPES[side]) and canvas._side_label.text.contains(side), "the canvas says what kind of script this is (%s)" % canvas._side_label.text)
	_check(bgs[1].r > bgs[1].b and bgs[2].b > bgs[2].r and bgs[0].b > bgs[0].g, "dark tints: Server orange-ish (r > b), Client blue-ish (b > r), Shared purple-ish (%s)" % [bgs])
	_check(bgs[0].v < 0.25 and bgs[1].v < 0.25 and bgs[2].v < 0.25, "the tints stay dark")
	_panel.context.graph["side"] = "Server"
	canvas.rebuild()
	_kept_side = kept_side
	_panel.switch_screen("Script")
	var at0 := _frame
	_wait_for = func() -> bool: return _frame > at0 + 6
	_then = _script_shot


var _kept_side := "Shared"


func _script_shot() -> void:
	_shot("script_server")
	_panel.context.graph["side"] = _kept_side
	_panel._canvas.rebuild()
	_panel.switch_screen("3D")
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 20
	_then = _in_3d


## The 3D screen: the Part is drawn, a click selects it, its X arrow drags it.
func _in_3d() -> void:
	var view: WorldView3D = _panel._view_3d
	var o: Dictionary = _panel.context.world_object
	_check(_panel._screen == "3D" and view.is_visible_in_tree(), "a world object shows the 3D screen")
	_panel.context.show_world_object({})
	var on_screen := view._cam.unproject_position(Vector3(1, 2, 3))
	_check(view.pick_at(on_screen) == int(o.id), "clicking the Part in the 3D view picks it")
	_panel.context.show_world_object(o)
	_check(view.axis_at(view._cam.unproject_position(Vector3(1, 2, 3) + Vector3.RIGHT * 1.2)) == 0, "its X arrow is under the pointer")
	view.begin_drag(0, view._cam.unproject_position(Vector3(1, 2, 3) + Vector3.RIGHT * 1.2))
	view.drag_to(view._cam.unproject_position(Vector3(3, 2, 3) + Vector3.RIGHT * 1.2))
	view.end_drag()
	var moved := WorldValues.vec(str(CBProject.read_world(_dir).objects[0].fields.get("position", "")))
	_check(moved.distance_to(Vector3(3, 2, 3)) < 0.05, "dragging the X arrow moves it 2 along x and saves it (%s)" % moved)
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 20
	_then = _in_2d


## The 2D screen: a Label on the game window's frame, picked and dragged.
func _in_2d() -> void:
	_shot("view_3d")
	_panel._world_dock._add_object("Text2D")
	var label: Dictionary = _panel.context.world_object
	label.fields["position"] = "10, 10"
	_panel._on_world_changed("Move text")
	_panel.switch_screen("2D")
	var v2: WorldView2D = _panel._view_2d
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 20
	_then = func() -> void:
		# (checked once the 2D screen has its size: it was only just shown)
		var f: Array = v2._frame()
		var spot: Vector2 = (f[0] as Rect2).position + Vector2(12, 12) * float(f[1]) + Vector2(4, 4)
		_check(int(v2.label_at(spot).get("id", 0)) == int(label.id), "the 2D screen shows the Text2D where its position is")
		_click_tree(label)


## A real mouse click on the Scene tree's Part row (it crashed the exported app:
## the tree rebuilt itself inside its own item_selected).
func _click_tree(label: Dictionary) -> void:
	_panel.switch_screen("3D")
	var tree: Tree = _panel._world_dock._tree
	var row := tree.get_root()  # (the Part: the scene's root, its top row)
	var at := tree.get_global_rect().position + tree.get_item_area_rect(row).get_center()
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = at
		e.global_position = at
		root.push_input(e)
	var at_frame := _frame
	_wait_for = func() -> bool: return _frame > at_frame + 10
	_then = func() -> void:
		var items := 0
		var it := tree.get_root()
		while it != null:
			items += 1
			it = it.get_next_in_tree()
		_check(str(_panel.context.world_object.get("name", "")) == "Part" and items == 2 and tree.get_selected() != null and tree.get_selected().get_text(0).begins_with("Part"), "clicking a Scene tree row selects it, the tree stays whole (%d rows)" % items)
		_check(row.get_icon(0) != null and row.get_icon(0) == _panel.context.brick_theme.icon("shape3d"), "the Part's Scene tree row has the Shape3D icon (a red cube, not a render)")
		_shot("scene_click")
		_properties_tabs(label)


## The Part's Properties: one fold per class (its own open), Metadata, the Groups tab.
func _properties_tabs(label: Dictionary) -> void:
	var insp = _panel._inspector
	insp.rebuild()
	var heads := _buttons(insp).map(func(b: Button) -> String: return b.text)
	_check("▾ Shape3D" in heads and "▸ Metadata" in heads, "Properties: a fold per class, the object's own open, Metadata closed (%s)" % [heads])
	insp._world_tab = 1
	insp.rebuild()
	var edits := _find_all(insp, "LineEdit").filter(func(e): return (e as LineEdit).placeholder_text == "group name")
	_check(not edits.is_empty(), "the Groups tab has a box for a group's name")
	if not edits.is_empty():
		var le: LineEdit = edits[0]
		le.text = "enemies"
		le.text_submitted.emit("enemies")
	var saved: Array = CBProject.read_world(_dir).objects.filter(func(x): return str(x.name) == "Part")
	_check(not saved.is_empty() and "enemies" in saved[0].get("groups", []), "adding a group saves it in world.cnworld")
	_check(str(_panel._build.get("files", {}).get("cbricks_scene.c", "")).contains("cb_group_add(w1, \"enemies\""), "the world's groups become C")
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 10
	_then = func() -> void:
		_shot("properties_groups")
		insp._world_tab = 0
		_script_object(label)


## A Script object: Add > Script under the Part makes its file; Type switches its Side.
func _script_object(label: Dictionary) -> void:
	_panel._world_dock._add_object("Script")
	var so: Dictionary = _panel.context.world_object
	var rel := str(so.get("script", ""))
	var g := CBProject.read_script(_dir.path_join(rel))
	_check(CBTypes.is_script_object(so) and int(so.parent) == 1 and str(g.get("side", "")) == "Server", "Add > Script puts a Script object under the Part and makes its file (%s)" % rel)
	_check(str(_panel._build.get("files", {}).get("cbricks_scene.c", "")).contains("cb_script_start_"), "its When program starts runs from the world file (cbricks_scene.c)")
	_panel._set_script_side(rel, "Client")
	_check(str(so["class"]) == "LocalScript" and str(CBProject.read_script(_dir.path_join(rel)).get("side", "")) == "Client", "Type LocalScript sets the file's Side to Client")
	# Renaming it renames its file to a safe name (user: "Script Test" -> script-test.cbricks).
	so.name = "Script Test"
	_panel._on_script_object_renamed(so)
	_panel._on_world_changed("Rename object")
	var renamed := str(so.get("script", ""))
	_check(renamed == "scripts/script-test.cbricks" and FileAccess.file_exists(_dir.path_join(renamed)) and not FileAccess.file_exists(_dir.path_join(rel)) and str(CBProject.read_world(_dir).objects.filter(func(x): return CBTypes.is_script_object(x))[0].get("script", "")) == renamed, "renaming the Script object 'Script Test' renames its file to scripts/script-test.cbricks (and the scene follows): %s" % renamed)
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 10
	_then = func() -> void:
		_shot("script_object")
		_scene_branch(label)


## Save branch as scene: the Part (and its Script object) become scenes/part.cbscene,
## a copy of it takes its place, drawn and picked in 3D; the scene opens in a tab.
func _scene_branch(label: Dictionary) -> void:
	_panel.switch_screen("3D")
	var part: Dictionary = _panel._world_dock.find(1)
	var rel: String = _panel._world_dock.save_branch_as_scene(part)
	var saved := CBProject.read_scene(_dir.path_join(rel))
	_check(rel == "scenes/part.cbscene" and saved.objects.size() == 3, "Save branch as scene writes the Part and what was under it (its Label, its Script object) to %s" % rel)
	var copy: Dictionary = _panel._world_dock.find(1)
	_check(str(copy.get("scene", "")) == rel and not copy.has("class"), "a copy of the scene takes the Part's place")
	_check(str(_panel._build.get("files", {}).get("cbricks_scene.c", "")).contains("a copy of scenes/part.cbscene"), "the copy becomes C (cbricks_scene.c)")
	var view: WorldView3D = _panel._view_3d
	view.rebuild()
	_panel.context.show_world_object({})
	_check(view.pick_at(view._cam.unproject_position(Vector3(3, 2, 3))) == 1, "the copy is drawn and picked in the 3D view")
	_panel.open_scene(_dir.path_join(rel), false)
	_check(_panel._world_dock._scene_tabs.tab_count == 2 and _panel.context.scene_path.ends_with(rel), "the scene opens in a second tab over the Scene tree")
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 10
	_then = func() -> void:
		_shot("scene_tabs")
		_panel.open_scene(CBProject.world_path(_dir), false)
		_after_tree_click(label)


func _find_all(n: Node, cls: String) -> Array:
	var out := []
	for c in n.get_children():
		if c.is_class(cls) and (c as Control).is_visible_in_tree():
			out.append(c)
		out.append_array(_find_all(c, cls))
	return out


func _buttons(n: Node) -> Array:
	return _find_all(n, "Button").filter(func(b): return b is Button and not b is OptionButton and not b is CheckBox)


var _dialog_seen := false


func _after_tree_click(label: Dictionary) -> void:
	if not _dialog_seen:
		# The Create New Node window (user, 2026-11-09): a tree by what extends what, with icons.
		_panel._world_dock.open_add()
		var dlg: AddDialog = _panel._world_dock._add_dialog
		var find_item := func(t: Tree, key: String) -> TreeItem:
			var stack: Array = [t.get_root()]
			while not stack.is_empty():
				var it: TreeItem = stack.pop_back()
				if str(it.get_metadata(0)) == key:
					return it
				stack.append_array(it.get_children())
			return null
		var shape: TreeItem = find_item.call(dlg._tree, "Shape3D")
		_check(dlg.visible and shape != null and shape.get_parent().get_text(0) == "Spatial3D" and shape.get_icon(0) != null, "Add opens a window with a tree: Shape3D under Spatial3D, with its icon")
		_check(find_item.call(dlg._tree, "Button") != null and (find_item.call(dlg._tree, "Button") as TreeItem).get_parent().get_text(0) == "Control" and find_item.call(dlg._tree, "LocalScript") != null, "Button is under Control; the Scripts are listed too")
		var win_center: Vector2 = Vector2(dlg.position) + Vector2(dlg.size) / 2.0
		var view_center: Vector2 = Vector2(_panel.get_viewport().get_visible_rect().size) / 2.0
		_check(win_center.distance_to(view_center) < 60.0, "the window opens in the middle of the screen (%s vs %s)" % [win_center, view_center])
		dlg._search.text = "cam"
		dlg._fill()
		_check(find_item.call(dlg._tree, "Camera3D") != null and find_item.call(dlg._tree, "Camera2D") != null and find_item.call(dlg._tree, "Shape3D") == null and dlg._tree.get_selected() != null, "searching 'cam' leaves the cameras (and their parents) and picks the first")
		_check(dlg._desc.get_parsed_text().contains("Camera3D") and dlg.describe("Camera3D").contains("field of view"), "the description of the picked one shows (%s)" % dlg._desc.get_parsed_text().left(40))
		dlg._search.text = ""
		dlg._fill()
		var at := _frame
		_wait_for = func() -> bool: return _frame > at + 10
		_then = func() -> void:
			dlg.get_texture().get_image().save_png("res://tests/reports/ui_add_dialog.png")  # (its own window: not in the main one's picture)
			dlg.hide()
			_dialog_seen = true
			_after_tree_click(label)
		return
	if true:
		_panel.switch_screen("2D")
		_shot("view_2d")
		_panel.context.show_world_object(label)
		_panel._world_dock._delete_selected()
		_panel.context.show_world_object(_panel._world_dock.find(1))
		_panel._world_dock._delete_selected()
		_check(CBProject.read_world(_dir).objects.is_empty(), "Delete removes them from world.cnworld")
		# An empty Main scene: the first node added is its root (the world while it runs).
		_check(_panel._world_dock.scene_root().is_empty() and _panel._world_dock._tree.get_root().get_text(0).begins_with("(empty"), "an empty scene shows that its first node will be its root")
		_panel.context.show_world_object({})
		_panel._world_dock._add_object("Spatial3D")
		var wr: Dictionary = _panel.context.world_object
		_check(int(wr.get("parent", -1)) == 0 and _panel._world_dock.scene_root() == wr, "the first node added is the scene's root")
		wr.name = "Arena"
		_panel._on_world_changed("Rename the root")
		_panel._world_dock._add_object("Shape3D")
		_check(int(_panel.context.world_object.get("parent", 0)) == int(wr.id), "the next node goes under the root (one root per scene)")
		_check(str(CBProject.read_world(_dir).objects[0].get("name", "")) == "Arena" and _panel._world_dock._tree.get_root().get_text(0).begins_with("Arena  (Spatial3D)"), "the root is the scene tree's top row, renamed")
		_check(str(_panel._build.get("files", {}).get("cbricks_scene.c", "")).contains("if (!parent_) cb_world_adopt(root);"), "the Main scene's root becomes the world (cb_world_adopt)")
		# New scene (the Scene dock's button): a safe file name, opened, its root as the top row.
		_panel.context.on_new_scene.call()
		_panel._dock._name_action.call("My Level")
		_panel._dock._name_dialog.hide()
		_check(FileAccess.file_exists(_dir.path_join("my-level.cbscene")) and _panel.context.scene_path.ends_with("my-level.cbscene"), "New scene makes my-level.cbscene and opens it")
		_check(_panel._world_dock._tree.get_root().get_text(0).begins_with("(empty"), "a new scene starts with no root (%s)" % _panel._world_dock._tree.get_root().get_text(0))
		_panel.context.show_world_object({})
		_panel._world_dock._add_object("Spatial3D")
		_panel.switch_screen("3D")
		_check(_panel._view_3d._env.background_color == WorldValues.color(WorldView3D.NO_ENVIRONMENT), "without an Environment the 3D screen is the game's neutral grey")
		_panel._world_dock._add_object("Environment")
		_panel.context.world_object.fields["sky"] = "#203040"
		_panel._on_world_changed("Sky")
		_panel._view_3d.rebuild()
		_check(_panel._view_3d._env.background_color == WorldValues.color("#203040"), "an Environment's sky is the 3D screen's background (as in the game)")
		# (2026-11-07) fog and the Light3D's color / energy, previewed as the game draws them
		_panel.context.world_object.fields["fog"] = "0.08"
		_panel._on_world_changed("Fog")
		_panel._world_dock._add_object("Light3D")
		_panel.context.world_object.fields["color"] = "#ff8040"
		_panel.context.world_object.fields["energy"] = "1.5"
		_panel._on_world_changed("Light")
		_panel._view_3d.rebuild()
		_check(_panel._view_3d._env.fog_enabled and is_equal_approx(_panel._view_3d._env.fog_density, 0.08) and _panel._view_3d._env.fog_light_color == WorldValues.color("#203040"), "the Environment's fog shows on the 3D screen, in the sky's color")
		_check(_panel._view_3d._sun.light_color == WorldValues.color("#ff8040") and is_equal_approx(_panel._view_3d._sun.light_energy, 1.5), "the Light3D's color and energy light the 3D screen")
		_panel._world_dock._add_object("Shape3D")
		_panel.context.world_object.fields["position"] = "0, 0.5, -6"
		_panel._on_world_changed("Box")
		_panel._view_3d.rebuild()
		# (user: Properties for the root couldn't be made narrow) a root's Properties fit a narrow panel
		_panel.context.show_world_object(_panel._world_dock.scene_root())
		_panel._inspector.rebuild()
		var min_w: float = _panel._inspector.get_combined_minimum_size().x
		_check(min_w < 260.0, "the root's Properties can be made narrow (minimum width %d px)" % int(min_w))
		var at := _frame
		_wait_for = func() -> bool: return _frame > at + 10
		_then = func() -> void:
			_shot("scene_root")
			_panel.open_scene(CBProject.world_path(_dir), false)
			_scene_editing()


## (user, 2026-11-07) no Class / Parent dropdowns, Change type..., drag to reparent, undo of
## the 3D screen's moves, live values while dragging, the Node tools only on Node.
func _scene_editing() -> void:
	_panel.switch_screen("3D")
	var dock = _panel._world_dock
	_panel.context.show_world_object(dock.scene_root())
	dock._add_object("Shape3D")
	var part: Dictionary = _panel.context.world_object
	part.name = "Mover"
	part.fields["position"] = "1, 0.5, 0"
	_panel._on_world_changed("Name")
	_panel.context.show_world_object(part)
	_panel._inspector.rebuild()
	var names: Array = _panel._inspector.find_children("*", "Label", true, false).map(func(l): return (l as Label).text)
	_check("Class" not in names and "Parent" not in names, "Properties has no Class or Parent row (%s)" % [names.slice(0, 8)])
	# Change type... (the Add panel): Shape3D -> Spatial3D drops the fields Spatial3D hasn't got
	part.fields["color"] = "RED"
	dock.change_type(part, "Spatial3D")
	_check(str(part["class"]) == "Spatial3D" and not part.fields.has("color") and part.fields.has("position"), "Change type makes it a Spatial3D, dropping color, keeping position")
	dock.change_type(part, "Shape3D")
	# drag a row onto another: reparent
	_panel.context.show_world_object(dock.scene_root())  # (Add goes under the selection: next to Mover, not in it)
	dock._add_object("Spatial3D")
	var holder: Dictionary = _panel.context.world_object
	holder.name = "Holder"
	_panel._on_world_changed("Name")
	dock.rebuild()
	var tree: Tree = dock._tree
	var target_row: TreeItem = dock._item_of(tree.get_root(), int(holder.id))
	var at: Vector2 = tree.get_item_area_rect(target_row).get_center()
	_check(dock._can_drop_row(at, {"world_object": int(part.id)}) and not dock._can_drop_row(at, {"world_object": int(holder.id)}), "a row can be dropped on another, not on itself")
	dock._drop_row(at, {"world_object": int(part.id)})
	_check(int(part.parent) == int(holder.id), "dropping Mover on Holder puts it under Holder")
	_panel.undo()  # (the 3D screen: the scene's undo)
	part = _find_object("Mover")
	_check(int(part.get("parent", 0)) != int(holder.id), "Undo on the 3D screen takes the move back")
	_panel.redo()
	part = _find_object("Mover")
	_check(int(part.get("parent", 0)) == int(holder.id), "Redo puts it back under Holder")
	# (UI step 4) dropping between rows reorders: a new node under Holder, dropped above Mover
	_panel.context.show_world_object(holder)
	dock._add_object("Spatial3D")
	var second: Dictionary = _panel.context.world_object
	dock.rebuild()
	dock.move_beside(second, part, false)  # (what a drop just above Mover's row does)
	var objs: Array = _panel.context.world.objects
	var si := objs.map(func(x): return int(x.id)).find(int(second.id))
	var mi := objs.map(func(x): return int(x.id)).find(int(part.id))
	_check(si >= 0 and si < mi and int(_find_object(str(second.name)).get("parent", 0)) == int(holder.id), "dropping a row just above another puts it before that one, under the same parent (order %d < %d)" % [si, mi])
	# a 3D drag: Properties follows it live; Undo takes it back
	_panel.context.show_world_object(part)
	_panel._inspector.rebuild()
	var before: String = str(part.fields.get("position", ""))
	var v = _panel._view_3d
	var mid: Vector2 = (v.size as Vector2) / 2.0
	v.begin_drag(0, mid)
	v.drag_to(mid + Vector2(60, 0))
	var pos_edit = _panel._inspector._world_edits.get("position")
	var live: String = str(part.fields.get("position", ""))
	_check(live != before and pos_edit != null and (pos_edit as LineEdit).text == live, "Properties shows the position while the arrow is dragged (%s -> %s)" % [before, live])
	v.end_drag()
	_panel.undo()
	_check(str(_find_object("Mover").fields.get("position", "")) == before, "Undo takes the 3D screen's move back")
	# (2026-11-07, UI step 1) a Label: its anchor picked in Properties' grid, drawn and picked in
	# the 2D screen where the game puts it, dragged by its offset
	_panel.switch_screen("2D")
	_panel.context.show_world_object(dock.scene_root())
	dock._add_object("Panel")
	var pnl: Dictionary = _panel.context.world_object
	pnl.fields["anchor"] = "bottom_right"
	pnl.fields["offset"] = "-20, -20"
	pnl.fields["size"] = "200, 60"
	pnl.fields["border"] = "2"
	pnl.fields["border_color"] = "WHITE"
	pnl.fields["radius"] = "8"
	_panel._on_world_changed("Panel")
	dock._add_object("Label")
	var lbl: Dictionary = _panel.context.world_object
	lbl.fields["text"] = "Score: 3"
	_panel._on_world_changed("Label")
	_check(int(lbl.parent) == int(pnl.id), "a Label added with the Panel selected goes in it")
	_panel.context.show_world_object(lbl)
	_panel._inspector.rebuild()
	var center_b: Array = _panel._inspector.find_children("*", "Button", true, false).filter(func(b): return (b as Button).text == "●")
	_check(center_b.size() == 1, "Properties has the anchor grid")
	if center_b.size() == 1:
		(center_b[0] as Button).pressed.emit()
	lbl = _find_object(str(lbl.name))
	_check(str(lbl.fields.get("anchor", "")) == "center", "pressing the grid's middle anchors it center")
	var v2 = _panel._view_2d
	var f: Array = v2._frame()
	var box: Dictionary = WorldValues.ui_box(_panel.context.flat_of(lbl), WorldValues.by_id(_panel.context.world_flat), v2.window_size)
	var want := Rect2((f[0] as Rect2).position + (box.rect as Rect2).position * float(f[1]), (box.rect as Rect2).size * float(f[1]))
	var picked: Dictionary = v2.label_at(want.get_center())
	_check(int(picked.get("id", -1)) == int(lbl.id), "the 2D screen picks the Label where it's drawn (inside the Panel at the bottom right)")
	
	_check(str(_panel._screen_buttons["Script"].text) == "Bricks", "the scripting screen's button says Bricks")
	_panel.context.show_world_object(dock.scene_root())
	dock._add_object("LocalScript")
	var ls: Dictionary = _panel.context.world_object
	dock.rebuild()
	var ls_row: TreeItem = dock._item_of(dock._tree.get_root(), int(ls.get("id", -1)))
	var colored: bool = ls_row != null and str(ls.get("class", "")) == "LocalScript" and ls_row.get_custom_color(0) == WorldDock.script_color("LocalScript") and WorldDock.script_color("Script") != WorldDock.script_color("ModuleScript")
	_check(colored, "a Script object's row is coloured by its type (LocalScript blue, Script orange, ModuleScript purple)")
	# the brick tools: only on the Node screen, beside the script tabs
	var frame_b: Array = _panel.find_children("*", "Button", true, false).filter(func(b): return (b as Button).text == "Arrange")
	_check(frame_b.size() == 1 and not frame_b[0].is_visible_in_tree(), "Arrange (a Node tool) isn't shown on the 3D screen (%d found)" % frame_b.size())
	_panel.switch_screen("Script")
	_check(frame_b.size() == 1 and frame_b[0].is_visible_in_tree() and frame_b[0].get_parent() == _panel._node_bar, "on Node, Arrange is in the Node bar beside the script tabs")
	var at_f := _frame
	_wait_for = func() -> bool: return _frame > at_f + 10
	_then = func() -> void:
		_shot("node_bar")
		_panel.switch_screen("2D")
		var at_u := _frame
		_wait_for = func() -> bool: return _frame > at_u + 10
		_then = func() -> void:
			_shot("ui_layer")
			_after_ui_shot()


func _after_ui_shot() -> void:
	_panel.switch_screen("3D")
	var at_g := _frame
	_wait_for = func() -> bool: return _frame > at_g + 10
	_then = func() -> void:
		_shot("scene_icons")
		# (2026-11-08) WASD flies the 3D view's camera: hold W with the view focused
		var v = _panel._view_3d
		v.grab_focus()
		var cam: Camera3D = v._cam
		var from: Vector3 = cam.global_transform.origin
		var ahead: Vector3 = -cam.global_transform.basis.z
		var w := InputEventKey.new()
		w.keycode = KEY_W
		w.physical_keycode = KEY_W
		w.pressed = true
		Input.parse_input_event(w)
		var at_w := _frame
		_wait_for = func() -> bool: return _frame > at_w + 20
		_then = func() -> void:
			var up := InputEventKey.new()
			up.keycode = KEY_W
			up.physical_keycode = KEY_W
			up.pressed = false
			Input.parse_input_event(up)
			var moved: Vector3 = cam.global_transform.origin - from
			_check(moved.length() > 0.5 and moved.normalized().dot(ahead) > 0.9, "holding W flies the 3D view's camera forward (%s)" % moved)
			_look_and_export()


## (2026-11-08) the right mouse button holds the pointer while it turns the 3D view; Export
## runs in the background with a progress bar.
func _look_and_export() -> void:
	var v = _panel._view_3d
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = (v.size as Vector2) / 2.0
	v._gui_input(press)
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "right mouse down in the 3D view holds the pointer (captured)")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_RIGHT
	release.pressed = false
	v._gui_input(release)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "letting go gives it back")
	var out := OS.get_user_data_dir().path_join("ui_check_export")
	_remove_dir(out)
	_panel._recompile()
	_panel._export_to(out)
	_check(_panel._progress_dialog.visible, "Export shows its progress window")
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 4 or not _panel._busy()
	_then = func() -> void:
		_shot("export_progress")
		_wait_for = func() -> bool: return not _panel._busy() or _frame > at + 3000
		_then = _after_export.bind(out)


func _after_export(out: String) -> void:
	if true:
		var bar: ProgressBar = _panel._progress_bar
		_check(not _panel._progress_dialog.visible and bar.value == bar.max_value and bar.max_value > 100 and FileAccess.file_exists(out.path_join("Makefile")) and FileAccess.file_exists(out.path_join("thirdparty/raylib/src/rcore.c")), "the export finished: the bar went to the end (%d files), the project's there" % int(bar.max_value))
		_remove_dir(out)
		_examples_are_scratch()


## (2026-11-08) Example Projects: each click a new copy, shown in Recent Projects; a copy
## reopened from Recent carries on where it was left; Save asks where to keep it as a project,
## which then takes the copy's place in Recent; the example never changes. The start page's
## two lists (screenshot).
func _examples_are_scratch() -> void:
	var back_to: String = _panel.project_dir
	var res_files := DirAccess.get_files_at("res://examples/hello_world").size()
	_panel.open_example("res://examples/hello_world")
	var first: String = _panel.project_dir
	_check(_panel._is_example() and first.begins_with(OS.get_user_data_dir()) and first in _panel._recent, "an example opens as a new copy, listed in Recent Projects (%s)" % first)
	_panel.switch_screen("3D")
	_panel._world_dock._add_object("Spatial3D")  # a change, kept in the copy
	_panel.open_example("res://examples/hello_world")
	var second: String = _panel.project_dir
	_check(second != first and CBProject.read_scene(CBProject.world_path(second)).objects.is_empty(), "the example again: another new copy, as the example is (%s)" % second.get_file())
	_panel.open_project(first)
	_check(_panel.project_dir == first and CBProject.read_scene(CBProject.world_path(first)).objects.size() > 0, "the first copy, opened from Recent Projects, carries on where it was left")
	_panel.save()
	_check(_panel._new_dialog.visible and _panel._new_dialog.title == "Save Example as a Project", "Save on an example copy asks where to keep it as a project")
	_panel._new_dialog.hide()
	var parent := OS.get_user_data_dir().path_join("ui_check_saved")
	_remove_dir(parent)
	var saved: String = _panel.save_example_as(parent, "My Hello")
	_check(saved != "" and _panel.project_dir == saved and not _panel._is_example() and CBProject.read_scene(CBProject.world_path(saved)).objects.size() > 0, "Save as project copies it with the change and goes on there")
	_check(saved in _panel._recent and not first in _panel._recent and not DirAccess.dir_exists_absolute(first), "your project takes the copy's place in Recent Projects (the copy is gone)")
	_check(DirAccess.get_files_at("res://examples/hello_world").size() == res_files and not FileAccess.file_exists("res://examples/hello_world/main.cbscene"), "the example itself is unchanged")
	_panel.close_project()
	_panel.refresh_start()
	var titles: Array = _panel.find_children("*", "Label", true, false).filter(func(l): return (l as Label).is_visible_in_tree()).map(func(l): return (l as Label).text)
	var recent_has_copy := false
	for k in _panel._start_list.item_count:
		if str(_panel._start_list.get_item_text(k)).contains("example copy"):
			recent_has_copy = true
	_check("Recent Projects" in titles and "Example Projects" in titles and recent_has_copy and _panel._example_list.item_count >= 8, "the start page: Recent Projects (an example copy marked) and Example Projects")
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 10
	_then = func() -> void:
		_shot("start_page")
		for d in [second, saved]:
			_panel._recent.erase(d)
			_panel._drop_copy(d)
		_remove_dir(parent)
		_panel.open_project(back_to)
		_panel.switch_screen("Script")
		_toolchains_window()


## The Toolchains window (user, 2026-11-10): two tabs, the first one the installable tools with state and buttons.
func _toolchains_window() -> void:
	_panel._open_settings()
	var dlg: AcceptDialog = _panel._settings_dialog
	var tabs: TabContainer = dlg.get_node("Tabs")
	_check(dlg.visible and tabs.get_tab_count() == 2 and tabs.get_tab_title(0) == "Toolchains" and tabs.get_tab_title(1) == "Commands" and tabs.current_tab == 0, "the Toolchains window opens on its Toolchains tab; Commands is the second")
	var ids: Array = ToolchainManager.TOOLS.map(func(t): return t.id)
	_check(_panel._tc_rows.keys() == ids, "a row per tool: %s" % str(_panel._tc_rows.keys()))
	var zig_row: Dictionary = _panel._tc_rows.zig
	var st: String = ToolchainManager.status("zig").state
	_check((zig_row.install as Button).visible == (st != "installed") and (zig_row.remove as Button).visible == (st == "installed") and not (zig_row.bar_row as Control).visible, "zig's row shows %s with the right buttons and no progress bar" % st)
	_check(tabs.get_child(1).find_child("Grid", true, false) != null, "the Commands tab holds each target's compile command")
	_panel._tc_progress("zig", 5 * 1048576, 20 * 1048576, "Downloading")
	_check((zig_row.bar_row as Control).visible and (zig_row.bar as ProgressBar).value == 5 * 1048576 and (zig_row.bar_l as Label).text.contains("5.00 MiB of 20.00 MiB"), "a download shows its bar and 'N of M' (%s)" % (zig_row.bar_l as Label).text)
	var at := _frame
	_wait_for = func() -> bool: return _frame > at + 10
	_then = func() -> void:
		dlg.get_texture().get_image().save_png("res://tests/reports/ui_toolchains.png")
		_panel._tc_progress("zig", 0, 0, "Unpacking")
		_check((zig_row.bar as ProgressBar).indeterminate, "unpacking shows a bar without an end")
		_panel._tc_finished("zig", "")
		_check(not (zig_row.bar_row as Control).visible, "when it finishes the bar goes")
		tabs.current_tab = 1
		var at2 := _frame
		_wait_for = func() -> bool: return _frame > at2 + 6
		_then = func() -> void:
			dlg.get_texture().get_image().save_png("res://tests/reports/ui_toolchain_commands.png")
			dlg.hide()
			_finish()


static func _remove_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)


func _find_object(n: String) -> Dictionary:
	for o in _panel.context.world.objects:
		if str(o.name) == n:
			return o
	return {}


func _finish() -> void:
	if true:
			# With no script open, a pick of a plain object still shows in Properties (it was skipped
			# because redraws only ran with a graph open: user, 2026-11-09).
			while not _panel._tabs.is_empty():
				_panel.close_tab(0)
			var root: Dictionary = _panel._world_dock.scene_root()
			if not root.is_empty():
				_panel.context.show_world_object(root)
				_panel._flush_redraw()
				_check(_panel._inspector._title.text.begins_with(str(root.name)), "with no script open, picking an object still fills Properties (%s)" % _panel._inspector._title.text)
			var ex := OS.get_user_data_dir().path_join("example")
			var aside := OS.get_user_data_dir().path_join("example_set_aside_by_ui_check")
			if DirAccess.dir_exists_absolute(aside):
				_remove_tree(ex)  # (this run's copies)
				DirAccess.rename_absolute(aside, ex)
			if _settings_backup != "":
				var fa := FileAccess.open(SETTINGS, FileAccess.WRITE)
				fa.store_string(_settings_backup)
				fa.close()
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
			print("%d check(s) failed. Screenshots: tests/reports/ui_*.png" % _failed)
			quit(_failed)
