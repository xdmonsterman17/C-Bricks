extends VBoxContainer
## The project's files as a tree (like Godot's FileSystem dock): the folder as
## it is on disk, nothing packed. Scripts (.cbricks) open in the editor; any
## other file (models, images, text...) is an asset the program reads by its
## path, and opens in its own app on a double-click. Right-click for New
## Script / New Folder / Rename / Duplicate / Delete / Show in File Manager.
## Files dropped on the window from the file manager are copied in.

const Context = preload("res://scripts/editor/context.gd")

signal script_activated(path: String)
## A file or folder moved (rename) or went away (to = ""): open tabs follow.
signal path_changed(from: String, to: String)
signal changed

const ICONS := {
	"cbricks": "script", "cbscene": "scene", "cnworld": "scene", "c": "file_code", "h": "file_code", "cpp": "file_code", "hpp": "file_code",
	"obj": "file_mesh", "gltf": "file_mesh", "glb": "file_mesh", "fbx": "file_mesh", "stl": "file_mesh", "ply": "file_mesh", "mtl": "file_mesh",
	"png": "file_image", "jpg": "file_image", "jpeg": "file_image", "bmp": "file_image", "svg": "file_image", "tga": "file_image", "webp": "file_image",
	"wav": "file_sound", "ogg": "file_sound", "mp3": "file_sound", "flac": "file_sound",
	"txt": "file_text", "md": "file_text", "json": "file_text", "csv": "file_text", "cfg": "file_text", "ini": "file_text", "xml": "file_text", "cbproj": "project",
}

var context: Context = null
var project_dir: String = ""
## The script with When program starts (marked with a star).
var main_script: String = ""
## Open scripts with unsaved changes (marked with *).
var dirty_scripts: Dictionary = {}

var _tree: Tree = null
var _filter: LineEdit = null
var _menu: PopupMenu = null
var _name_dialog: ConfirmationDialog = null
var _name_edit: LineEdit = null
var _name_action: Callable = Callable()
var _collapsed: Dictionary = {}
var _menu_path: String = ""


func _init() -> void:
	custom_minimum_size = Vector2(0, 60)
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = ""  # the tab says "Project"
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(title)
	add_child(head)
	for spec in [["new_script", "New script in the selected folder", func() -> void: _ask_new_script(_selected_folder())],
			["new_folder", "New folder in the selected folder", func() -> void: _ask_new_folder(_selected_folder())],
			["reload", "Look at the folder again", refresh]]:
		var b := Button.new()
		b.flat = true
		b.tooltip_text = spec[1]
		b.pressed.connect(spec[2])
		b.set_meta(&"icon", spec[0])
		head.add_child(b)
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter files"
	_filter.clear_button_enabled = true
	_filter.text_changed.connect(func(_t: String) -> void: refresh())
	add_child(_filter)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = SIZE_EXPAND_FILL
	_tree.allow_rmb_select = true
	_tree.item_activated.connect(_on_activated)
	_tree.item_mouse_selected.connect(func(_at: Vector2, button: int) -> void:
		if button == MOUSE_BUTTON_RIGHT:
			_open_menu(_tree.get_selected()))
	_tree.empty_clicked.connect(func(_at: Vector2, button: int) -> void:
		if button == MOUSE_BUTTON_RIGHT:
			_tree.deselect_all()
			_open_menu(null))
	_tree.item_collapsed.connect(func(item: TreeItem) -> void:
		var rel: String = item.get_metadata(0)
		if item.collapsed:
			_collapsed[rel] = true
		else:
			_collapsed.erase(rel))
	add_child(_tree)
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	_name_dialog = ConfirmationDialog.new()
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size.x = 320
	_name_edit.text_submitted.connect(func(_t: String) -> void:
		_name_dialog.hide()
		_on_name_confirmed())
	_name_dialog.add_child(_name_edit)
	_name_dialog.register_text_enter(_name_edit)
	_name_dialog.confirmed.connect(_on_name_confirmed)
	add_child(_name_dialog)


func _ready() -> void:
	for b in get_child(0).get_children():
		if b is Button and b.has_meta(&"icon"):
			b.icon = context.brick_theme.icon(b.get_meta(&"icon"))
	_filter.right_icon = context.brick_theme.icon("search")


func set_project(dir: String) -> void:
	project_dir = dir
	_collapsed.clear()
	refresh()


func refresh() -> void:
	_tree.clear()
	if project_dir == "":
		return
	var root := _tree.create_item()
	root.set_metadata(0, "")
	var top := _tree.create_item(root)
	top.set_text(0, "%s (%s)" % [CBProject.project_name(project_dir), project_dir.get_file()])
	top.set_icon(0, context.brick_theme.icon("project"))
	top.set_metadata(0, "")
	top.set_tooltip_text(0, project_dir)
	var folders := {"": top}
	var q := _filter.text.strip_edges().to_lower()
	for rel in CBProject.list_entries(project_dir):
		var is_dir := rel.ends_with("/")
		var clean := rel.trim_suffix("/")
		if q != "" and not is_dir and not clean.to_lower().contains(q):
			continue
		var parent: TreeItem = folders.get(clean.get_base_dir(), top)
		var it := _tree.create_item(parent)
		it.set_metadata(0, clean)
		var label := clean.get_file()
		if is_dir:
			it.set_icon(0, context.brick_theme.icon("folder"))
			it.collapsed = _collapsed.has(clean)
			folders[clean] = it
		else:
			var ext := clean.get_extension().to_lower()
			it.set_icon(0, context.brick_theme.icon(ICONS.get(ext, "file")))
			var abs := project_dir.path_join(clean)
			if abs == main_script:
				label += "  ★"
				it.set_tooltip_text(0, "%s\nThe program starts here (When program starts)." % clean)
			elif ext in [CBProject.SCENE_EXT, "cnworld"]:
				var is_main := abs == CBProject.world_path(project_dir)
				if is_main:
					label += "  ★"
				it.set_tooltip_text(0, "%s\nA scene%s. Double-click: edit it in the Scene tree." % [clean, " (the Main scene: the world starts with it)" if is_main else ""])
				it.set_custom_color(0, context.brick_theme.category_color("objects").lerp(Color.WHITE, 0.4))
			else:
				it.set_tooltip_text(0, clean + ("\nAn asset: the program reads it by this path." if ext != CBProject.SCRIPT_EXT and clean != CBProject.FILE else ""))
			if dirty_scripts.has(abs):
				label += " *"
			if ext == CBProject.SCRIPT_EXT:
				it.set_custom_color(0, context.brick_theme.category_color("events").lerp(Color.WHITE, 0.4))
			elif clean == CBProject.FILE:
				it.set_custom_color(0, Color(context.brick_theme.text_color(), 0.6))
		it.set_text(0, label)
	if q != "":
		# Hide folders the filter left empty.
		for rel in folders:
			var f: TreeItem = folders[rel]
			if rel != "" and f.get_child_count() == 0:
				f.free()


func _abs(rel: String) -> String:
	return project_dir.path_join(rel) if rel != "" else project_dir


func _selected_rel() -> String:
	var it := _tree.get_selected()
	return it.get_metadata(0) if it != null else ""


## The selected folder (a file's folder; nothing selected: the project folder).
func _selected_folder() -> String:
	var rel := _selected_rel()
	if rel == "" or DirAccess.dir_exists_absolute(_abs(rel)):
		return rel
	return rel.get_base_dir()


func _on_activated() -> void:
	var rel := _selected_rel()
	var path := _abs(rel)
	if rel == "" or DirAccess.dir_exists_absolute(path):
		var it := _tree.get_selected()
		if it != null:
			it.collapsed = not it.collapsed
		return
	if path.get_extension() in [CBProject.SCRIPT_EXT, CBProject.SCENE_EXT] or path.get_file() == CBProject.WORLD_FILE:
		script_activated.emit(path)
	else:
		OS.shell_open(path)


# ------------------------------------------------------------------ menu

enum { M_OPEN, M_NEW_SCRIPT, M_NEW_FOLDER, M_RENAME, M_DUPLICATE, M_DELETE, M_SHOW, M_COPY_PATH, M_IMPORT, M_NEW_SCENE, M_MAIN_SCENE }


func _open_menu(item: TreeItem) -> void:
	_menu_path = item.get_metadata(0) if item != null else ""
	_menu.clear()
	var is_file := _menu_path != "" and not DirAccess.dir_exists_absolute(_abs(_menu_path))
	if is_file:
		_menu.add_item("Open", M_OPEN)
		_menu.add_separator()
	_menu.add_icon_item(context.brick_theme.icon("new_script"), "New Script...", M_NEW_SCRIPT)
	_menu.add_icon_item(context.brick_theme.icon("scene"), "New Scene...", M_NEW_SCENE)
	_menu.add_icon_item(context.brick_theme.icon("new_folder"), "New Folder...", M_NEW_FOLDER)
	if is_file and _menu_path.get_extension() == CBProject.SCENE_EXT and _abs(_menu_path) != CBProject.world_path(project_dir):
		_menu.add_icon_item(context.brick_theme.icon("star"), "Set as Main Scene", M_MAIN_SCENE)
	_menu.add_item("Add files: drop them on the window", M_IMPORT)
	_menu.set_item_disabled(_menu.item_count - 1, true)
	if _menu_path != "":
		_menu.add_separator()
		_menu.add_item("Rename...", M_RENAME)
		if is_file:
			_menu.add_item("Duplicate...", M_DUPLICATE)
		_menu.add_icon_item(context.brick_theme.icon("remove"), "Delete (to the trash)", M_DELETE)
	_menu.add_separator()
	_menu.add_item("Show in File Manager", M_SHOW)
	_menu.add_item("Copy Path", M_COPY_PATH)
	_menu.position = Vector2i(get_screen_position() + get_local_mouse_position())
	_menu.reset_size()
	_menu.popup()


func _on_menu(id: int) -> void:
	var rel := _menu_path
	var path := _abs(rel)
	var folder := rel if rel == "" or DirAccess.dir_exists_absolute(path) else rel.get_base_dir()
	match id:
		M_NEW_SCENE:
			_ask_new_scene(folder)
		M_MAIN_SCENE:
			var cf := CBProject.load_config(project_dir)
			cf.set_value("project", "main_scene", rel)
			CBProject.save_config(project_dir, cf)
			_status("%s is the Main scene: the world starts with it." % rel)
			_changed()
		M_OPEN:
			if path.get_extension() in [CBProject.SCRIPT_EXT, CBProject.SCENE_EXT]:
				script_activated.emit(path)
			else:
				OS.shell_open(path)
		M_NEW_SCRIPT:
			_ask_new_script(folder)
		M_NEW_FOLDER:
			_ask_new_folder(folder)
		M_RENAME:
			_ask_name("Rename", rel.get_file(), func(name: String) -> void:
				var ext := path.get_extension()
				if ext in [CBProject.SCRIPT_EXT, CBProject.SCENE_EXT]:
					# Scripts and scenes get safe file names ("Script Test" -> script-test.cbricks).
					name = CBProject.safe_name(name.trim_suffix("." + ext), "script" if ext == CBProject.SCRIPT_EXT else "scene") + "." + ext
				var to := path.get_base_dir().path_join(name)
				if to == path:
					return
				if FileAccess.file_exists(to) or DirAccess.dir_exists_absolute(to):
					_status("%s already exists." % name)
					return
				if DirAccess.rename_absolute(path, to) == OK:
					CBProject.repoint(project_dir, rel, CBProject.rel_path(project_dir, to))  # Script objects, copies, the Main scene
					path_changed.emit(path, to)
					_changed())
		M_DUPLICATE:
			var base := rel.get_file().get_basename()
			var ext := rel.get_extension()
			_ask_name("Duplicate as", "%s_copy.%s" % [base, ext], func(name: String) -> void:
				var to := path.get_base_dir().path_join(name)
				if FileAccess.file_exists(to):
					_status("%s already exists." % name)
					return
				if to.get_extension() == CBProject.SCRIPT_EXT and path.get_extension() == CBProject.SCRIPT_EXT:
					# A copy's functions would clash with the original's: renamed.
					var g := CBProject.read_script(path)
					for n in g.get("nodes", []):
						if n.type == "function":
							n.fields.name = str(n.fields.name) + "_copy"
					CBProject.write_script(to, g)
				else:
					DirAccess.copy_absolute(path, to)
				_changed())
		M_DELETE:
			if OS.move_to_trash(path) == OK:
				path_changed.emit(path, "")
				_changed()
			else:
				_status("Couldn't move %s to the trash." % rel)
		M_SHOW:
			OS.shell_show_in_file_manager(path)
		M_COPY_PATH:
			DisplayServer.clipboard_set(path)


func _ask_new_script(folder: String) -> void:
	_ask_name("New script", "new-script.cbricks", func(name: String) -> void:
		name = CBProject.safe_name(name.trim_suffix("." + CBProject.SCRIPT_EXT)) + "." + CBProject.SCRIPT_EXT
		var to := _abs(folder).path_join(name)
		if FileAccess.file_exists(to):
			_status("%s already exists." % name)
			return
		var g := {"format": "c-bricks", "version": 4, "next_id": 1, "nodes": [], "frames": []}
		Ops.add_node(g, "function", Vector2(32, 64))
		g.nodes[0].fields.name = Ops.unique_function_name(g, name.get_basename().to_snake_case().validate_filename().replace("-", "_"))
		CBProject.write_script(to, g)
		_changed()
		script_activated.emit(to))


## A new scene: empty (the first node added in the Scene dock is its root); opened.
func _ask_new_scene(folder: String) -> void:
	_ask_name("New scene", "new-scene.cbscene", func(name: String) -> void:
		name = CBProject.safe_name(name.trim_suffix("." + CBProject.SCENE_EXT), "scene") + "." + CBProject.SCENE_EXT
		var to := _abs(folder).path_join(name)
		if FileAccess.file_exists(to):
			_status("%s already exists." % name)
			return
		CBProject.write_scene(to, CBProject.new_world())  # empty: its first node added is its root
		_changed()
		script_activated.emit(to))


func _ask_new_folder(folder: String) -> void:
	_ask_name("New folder", "assets", func(name: String) -> void:
		DirAccess.make_dir_recursive_absolute(_abs(folder).path_join(name))
		_changed())


func _ask_name(title: String, initial: String, action: Callable) -> void:
	_name_dialog.title = title
	_name_edit.text = initial
	_name_action = action
	_name_dialog.popup_centered()
	_name_edit.grab_focus()
	var dot := initial.rfind(".")
	_name_edit.select(0, dot if dot > 0 else initial.length())


func _on_name_confirmed() -> void:
	var name := _name_edit.text.strip_edges()
	if name == "" or name.contains("/") or name.contains("\\") or name.begins_with("."):
		_status("'%s' isn't a usable name." % name)
		return
	if _name_action.is_valid():
		_name_action.call(name)


## Files dropped on the window: copied into the selected folder.
func import_files(paths: PackedStringArray) -> void:
	if project_dir == "":
		return
	var into := _abs(_selected_folder())
	var count := 0
	for p in paths:
		if p.begins_with(project_dir):
			continue
		var to := into.path_join(p.get_file())
		if DirAccess.dir_exists_absolute(p):
			if CBProject.copy_dir(p, to) == OK:
				count += 1
		elif DirAccess.copy_absolute(p, to) == OK:
			count += 1
	if count > 0:
		_status("Copied %d item(s) into %s." % [count, CBProject.rel_path(project_dir, into) if into != project_dir else "the project"])
		_changed()


func _changed() -> void:
	refresh()
	changed.emit()


func _status(text: String) -> void:
	if context.on_status.is_valid():
		context.on_status.call(text)
