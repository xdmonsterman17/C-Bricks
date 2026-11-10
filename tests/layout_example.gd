extends SceneTree
## Lays out a generated example in the real editor (bricks placed by their real
## sizes with Ops.tidy) and saves it back: godot --path . -s res://tests/layout_example.gd -- gem_collector
## Works on a copy in user://, writes only the example's main.cbricks; restores user://settings.cfg.

const SETTINGS := "user://settings.cfg"
var _panel: Control = null
var _frame := 0
var _name := ""
var _dir := ""
var _backup := ""
var _scripts := PackedStringArray()
var _at := 0
var _shot_at := -1


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	_name = args[0] if not args.is_empty() else "gem_collector"
	if FileAccess.file_exists(SETTINGS):
		_backup = FileAccess.get_file_as_string(SETTINGS)
	_dir = OS.get_user_data_dir().path_join("layout_example")
	_clear(_dir)  # an empty copy: files of the last example laid out mustn't be saved into this one
	CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/" + _name), _dir)
	_panel = load("res://main.tscn").instantiate()
	root.add_child(_panel)


func _process(_delta: float) -> bool:
	_frame += 1
	match _frame:
		5:
			_panel.open_project(_dir)
		30:
			_scripts = CBProject.list_scripts(_dir)
	# Every script in turn: open it, wait for its bricks to have sizes, lay it out, save it.
	if _frame >= 31 and _at < _scripts.size():
		var step := _frame - 31 - _at * 20
		if step == 0:
			_panel.open_script(_scripts[_at])
		elif step == 15:
			var graph: Dictionary = _panel.context.graph
			Ops.tidy(graph, _panel._canvas.brick_sizes())
			var rel := CBProject.rel_path(_dir, _scripts[_at])
			var err := CBProject.write_script(ProjectSettings.globalize_path("res://examples/%s/%s" % [_name, rel]), graph)
			print("saved %s: %s" % [rel, error_string(err)])
			_panel.context.notify_changed(11, "Layout")
			_at += 1
			if _at == _scripts.size():
				_shot_at = _frame + 20
	match _frame:
		_ when _frame == _shot_at:
			root.get_texture().get_image().save_png("res://tests/reports/layout_%s.png" % _name)
			if _backup != "":
				var fa := FileAccess.open(SETTINGS, FileAccess.WRITE)
				fa.store_string(_backup)
				fa.close()
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
			quit(0)
	return false


## Deletes the scratch copy (only under app_userdata: it's ours).
static func _clear(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path) or not path.contains("app_userdata"):
		return
	for d in DirAccess.get_directories_at(path):
		_clear(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
