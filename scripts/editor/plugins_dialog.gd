class_name PluginsDialog
extends AcceptDialog
## Manage plugins (start page, beside Recent Projects): the global library of target device plugins
## (user://plugins), which projects use each, and adding / removing / updating one per project.

const PluginSettingsUI = preload("res://scripts/editor/plugin_settings_ui.gd")

signal changed   ## a project's plugins changed (the editor refreshes its Target list)

var _recent: Callable            ## -> Array of project dirs (Recent Projects)
var _lib: ItemList
var _detail: Label
var _projects: OptionButton
var _proj_list: ItemList
var _msg: Label
var _install_dialog: FileDialog
var _ids: Array = []             ## the library list's plugin ids
var _proj_ids: Array = []        ## the project list's plugin ids
var _confirm: ConfirmationDialog
var _settings_dlg: ConfirmationDialog = null


func setup(recent: Callable) -> void:
	_recent = recent
	title = "Manage plugins"
	ok_button_text = "Close"
	min_size = Vector2(880, 520)
	var root := VBoxContainer.new()
	root.add_theme_constant_override(&"separation", 8)
	add_child(root)
	var intro := Label.new()
	intro.text = "Target device plugins: a C backend (the platform's window, input, drawing...) and a target.cfg. They live in this library; each project keeps its own copy (plugins/ in the project folder), so it still builds without the library."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.modulate.a = 0.85
	intro.custom_minimum_size.x = 820
	root.add_child(intro)
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override(&"separation", 12)
	root.add_child(cols)
	# left: the library
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	left.add_child(_head("Library"))
	_lib = ItemList.new()
	_lib.name = "PluginLibrary"
	_lib.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lib.custom_minimum_size.y = 220
	_lib.item_selected.connect(func(_i: int) -> void: _show_detail())
	left.add_child(_lib)
	_detail = Label.new()
	_detail.name = "PluginDetail"
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size = Vector2(380, 90)
	left.add_child(_detail)
	var lb := HBoxContainer.new()
	left.add_child(lb)
	lb.add_child(_button("Install from folder...", _ask_install, "InstallPlugin"))
	lb.add_child(_button("Install the null-terminal kit", _install_kit, "InstallKit", "The bring-up kit: the smallest working plugin, to copy and change for a new device."))
	lb.add_child(_button("Remove from library", _remove_library, "RemovePlugin"))
	lb.add_child(_button("Settings...", _open_settings, "PluginSettings", "The plugin's global settings, for every project that doesn't set its own (Project Settings > Plugins)."))
	# right: a project
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	right.add_child(_head("A project"))
	_projects = OptionButton.new()
	_projects.name = "PluginProject"
	_projects.item_selected.connect(func(_i: int) -> void: _fill_project())
	right.add_child(_projects)
	_proj_list = ItemList.new()
	_proj_list.name = "ProjectPlugins"
	_proj_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_proj_list.custom_minimum_size.y = 220
	right.add_child(_proj_list)
	var pb := HBoxContainer.new()
	right.add_child(pb)
	pb.add_child(_button("Add the library's selected plugin", _add_to_project, "AddToProject"))
	pb.add_child(_button("Update", _update_in_project, "UpdateInProject", "Copies the library's version into the project."))
	pb.add_child(_button("Remove from project", _remove_from_project, "RemoveFromProject"))
	_msg = Label.new()
	_msg.name = "PluginMessage"
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(820, 24)
	root.add_child(_msg)
	_install_dialog = FileDialog.new()
	_install_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_install_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_install_dialog.title = "Choose a plugin folder (it has a target.cfg)"
	_install_dialog.dir_selected.connect(_install)
	add_child(_install_dialog)
	_confirm = ConfirmationDialog.new()
	add_child(_confirm)


## The selected library plugin's global settings, in a dialog of its own.
func _open_settings() -> void:
	var id := _selected_id()
	var p := {}
	for q in TargetPlugins.library():
		if q.id == id:
			p = q
	if p.is_empty():
		_msg.text = "Select a plugin first."
		return
	if Array(p.settings).is_empty():
		_msg.text = "%s has no settings." % p.title
		return
	if _settings_dlg != null:
		_settings_dlg.queue_free()
	_settings_dlg = ConfirmationDialog.new()
	_settings_dlg.theme = theme
	_settings_dlg.title = "%s: global settings" % p.title
	_settings_dlg.ok_button_text = "Save"
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 8)
	var hint := Label.new()
	hint.text = "Used by every project that doesn't set its own value (Project Settings > Plugins)."
	hint.modulate.a = 0.7
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 480
	box.add_child(hint)
	var state := PluginSettingsUI.build(box, p, "global")
	_settings_dlg.add_child(box)
	_settings_dlg.confirmed.connect(func() -> void:
		PluginSettingsUI.apply(state)
		_msg.text = "Saved %s's global settings." % p.title)
	add_child(_settings_dlg)
	_settings_dlg.popup_centered(Vector2i(560, 0))


func _head(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", 16)
	return l


func _button(text: String, fn: Callable, node_name: String, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.name = node_name
	b.tooltip_text = tip
	b.pressed.connect(fn)
	return b


func open() -> void:
	_msg.text = ""
	refresh()
	popup_centered(Vector2i(900, 560))


func refresh() -> void:
	_lib.clear()
	_ids.clear()
	var dirs: Array = _recent.call()
	var use := TargetPlugins.usage(dirs)
	for p in TargetPlugins.library():
		var n := Array(use.get(p.id, [])).size()
		_lib.add_item("%s   v%s   (%s)   used by %d project%s" % [p.title, p.version, p.id, n, "" if n == 1 else "s"])
		_ids.append(p.id)
	if _ids.is_empty():
		_lib.add_item("(empty: install a plugin folder, or the null-terminal kit)")
		_lib.set_item_disabled(0, true)
	var keep := _projects.selected
	_projects.clear()
	for d in dirs:
		if CBProject.is_project(str(d)):
			_projects.add_item(CBProject.project_name(str(d)) + "   " + str(d).get_base_dir().get_file() + "/" + str(d).get_file())
			_projects.set_item_metadata(_projects.item_count - 1, d)
	if _projects.item_count > 0:
		_projects.select(clampi(keep, 0, _projects.item_count - 1))
	_fill_project()
	_show_detail()


func _selected_id() -> String:
	var s := _lib.get_selected_items()
	return str(_ids[s[0]]) if not s.is_empty() and s[0] < _ids.size() else ""


func _show_detail() -> void:
	var id := _selected_id()
	if id == "":
		_detail.text = "Select a plugin to see what it is."
		return
	var p := {}
	for q in TargetPlugins.library():
		if q.id == id:
			p = q
	var bits := [str(p.description)]
	if not Array(p.settings).is_empty():
		bits.append("%d setting(s): Settings... (global) or Project Settings > Plugins." % Array(p.settings).size())
	bits.append("Adds the target \"%s\"." % p.target.name if not p.target.is_empty() else "Adds a backend only (for targets that already exist).")
	if not p.hooks.is_empty():
		bits.append("Runs its own scripts (%s): trusted code, asked about when you add it to a project and again before a script first runs." % ", ".join(PackedStringArray(p.hooks.keys())))
	var users := Array(TargetPlugins.usage(_recent.call()).get(id, []))
	if not users.is_empty():
		bits.append("Used by: " + ", ".join(PackedStringArray(users.map(func(d): return CBProject.project_name(str(d))))))
	_detail.text = "\n".join(PackedStringArray(bits))


func _project_dir() -> String:
	return str(_projects.get_item_metadata(_projects.selected)) if _projects.item_count > 0 else ""


func _fill_project() -> void:
	_proj_list.clear()
	_proj_ids.clear()
	var dir := _project_dir()
	if dir == "":
		_proj_list.add_item("(no projects yet)")
		_proj_list.set_item_disabled(0, true)
		return
	var mine := TargetPlugins.project_plugins(dir)
	for id in mine:
		var up := TargetPlugins.update_available(dir, id)
		_proj_list.add_item("%s   v%s%s" % [id, mine[id], "   - update available: v" + up if up != "" else ""])
		_proj_ids.append(id)
	if _proj_ids.is_empty():
		_proj_list.add_item("(this project uses no plugins)")
		_proj_list.set_item_disabled(0, true)


func _say(text: String, good := true) -> void:
	_msg.text = text
	_msg.modulate = Color(0.6, 0.9, 0.6) if good else Color(1.0, 0.6, 0.5)


func _ask_install() -> void:
	_install_dialog.popup_centered_ratio(0.6)


func _install(dir: String) -> void:
	var why := TargetPlugins.install(dir)
	_say("Installed." if why == "" else "Not installed: " + why, why == "")
	refresh()


func _install_kit() -> void:
	var done := []
	for p in TargetPlugins.examples():
		var why := TargetPlugins.install(str(p.dir))
		if why != "":
			_say("Not installed: " + why, false)
			return
		done.append(str(p.title))
	_say("Installed: " + ", ".join(PackedStringArray(done)) if not done.is_empty() else "No example plugins found.", not done.is_empty())
	refresh()


func _remove_library() -> void:
	var id := _selected_id()
	if id == "":
		return
	TargetPlugins.uninstall(id)
	var users := Array(TargetPlugins.usage(_recent.call()).get(id, []))
	_say("Removed from the library." + (" %d project%s keep their own copy." % [users.size(), "" if users.size() == 1 else "s"] if not users.is_empty() else ""))
	refresh()


func _library_plugin(id: String) -> Dictionary:
	for p in TargetPlugins.library():
		if p.id == id:
			return p
	return {}


func _add_to_project() -> void:
	var id := _selected_id()
	var dir := _project_dir()
	if id == "" or dir == "":
		_say("Select a plugin in the library and a project first.", false)
		return
	var p := _library_plugin(id)
	if not p.hooks.is_empty():
		_confirm.dialog_text = "%s runs its own scripts (%s) when you build or run. Only add plugins you trust: they can do anything you can. Add it to %s?" % [p.title, ", ".join(PackedStringArray(p.hooks.keys())), CBProject.project_name(dir)]
		for c in _confirm.confirmed.get_connections():
			_confirm.confirmed.disconnect(c.callable)
		_confirm.confirmed.connect(func() -> void: _do_add(dir, str(p.dir)))
		_confirm.popup_centered()
		return
	_do_add(dir, str(p.dir))


func _do_add(dir: String, plugin_dir: String) -> void:
	var why := TargetPlugins.add_to_project(dir, plugin_dir)
	_say("Added to %s." % CBProject.project_name(dir) if why == "" else "Not added: " + why, why == "")
	_after_change(dir)


func _update_in_project() -> void:
	var dir := _project_dir()
	var s := _proj_list.get_selected_items()
	if dir == "" or s.is_empty() or s[0] >= _proj_ids.size():
		return
	var id := str(_proj_ids[s[0]])
	var p := _library_plugin(id)
	if p.is_empty():
		_say("The library has no '%s' to update from." % id, false)
		return
	_do_add(dir, str(p.dir))


func _remove_from_project() -> void:
	var dir := _project_dir()
	var s := _proj_list.get_selected_items()
	if dir == "" or s.is_empty() or s[0] >= _proj_ids.size():
		return
	TargetPlugins.remove_from_project(dir, str(_proj_ids[s[0]]))
	_say("Removed from %s." % CBProject.project_name(dir))
	_after_change(dir)


func _after_change(_dir: String) -> void:
	changed.emit()
	refresh()
