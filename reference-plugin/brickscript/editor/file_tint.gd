@tool
extends Node

## Tints some files in the editor: their names in the FileSystem dock (tree
## and file list) and, with `tint_scripts`, their entries in the script
## editor's list and the background of their code. Godot has no API for
## this, so it finds the dock's Tree / ItemList and recolors matching items
## whenever they redraw (they are rebuilt often). If a Godot version lays the
## editor out differently, nothing gets tinted and nothing breaks.
##
## The Brickscript and Network Context Engine plugins each carry their own
## copy of this file, so neither needs the other.

## How far a tinted script's code background moves toward `color`.
const CODE_TINT: float = 0.08
const BACKGROUND_META: StringName = &"_file_tint_background"

var color: Color = Color(1.0, 0.62, 0.3)
## func(path: String) -> bool: whether a file is tinted `color` (with
## `tint_scripts`, its code background too).
var matches: Callable = Callable()
## Optional second kind (names only): func(path) -> bool, tinted `other_color`.
var other_matches: Callable = Callable()
var other_color: Color = Color(0.55, 0.82, 1.0)
var tint_scripts: bool = false
## Optional: func(path: String) -> Texture2D, an icon to show instead of
## Godot's (null: keep it). Set in the FileSystem tree and list view.
var icon_of: Callable = Callable()

var _watched: Array[Control] = []
var _tinted_code: Array[CodeEdit] = []
var _pending: bool = false


func _ready() -> void:
	var dock: Control = EditorInterface.get_file_system_dock()
	for found: Node in dock.find_children("*", "Tree", true, false) + dock.find_children("*", "ItemList", true, false):
		_watch(found as Control)
	if tint_scripts:
		var script_editor: ScriptEditor = EditorInterface.get_script_editor()
		for found: Node in script_editor.find_children("*", "ItemList", true, false):
			_watch(found as Control)
		# Deferred: the new script's editor is current only afterwards.
		script_editor.editor_script_changed.connect(_on_script_changed, CONNECT_DEFERRED)
		_on_script_changed(script_editor.get_current_script())
	_queue()


func _exit_tree() -> void:
	for control: Control in _watched:
		if is_instance_valid(control) and control.draw.is_connected(_queue):
			control.draw.disconnect(_queue)
	_tint_all(false)
	_watched.clear()
	for code: CodeEdit in _tinted_code:
		if is_instance_valid(code) and code.has_meta(BACKGROUND_META):
			code.add_theme_color_override(&"background_color", code.get_meta(BACKGROUND_META))
			code.remove_meta(BACKGROUND_META)
	_tinted_code.clear()
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if script_editor != null and script_editor.editor_script_changed.is_connected(_on_script_changed):
		script_editor.editor_script_changed.disconnect(_on_script_changed)


func _watch(control: Control) -> void:
	if control != null and not _watched.has(control):
		control.draw.connect(_queue)
		_watched.append(control)


## Recolors once after the redraws of this frame. Colors are only set when
## they differ, so recoloring doesn't keep causing redraws.
func _queue() -> void:
	if not _pending:
		_pending = true
		_tint_all.call_deferred(true)


func _tint_all(on: bool) -> void:
	_pending = false
	for control: Control in _watched:
		if not is_instance_valid(control):
			continue
		if control is Tree:
			var item: TreeItem = (control as Tree).get_root()
			while item != null:
				_tint_tree_item(item, on)
				item = item.get_next_in_tree()
		elif control is ItemList:
			var list: ItemList = control
			for index: int in list.item_count:
				var metadata: Variant = list.get_item_metadata(index)
				var path: String = metadata if metadata is String else list.get_item_tooltip(index)
				var tint: Color = _color_for(path)
				var wanted: Color = tint if on else Color()
				if list.get_item_custom_fg_color(index) != wanted and tint != Color():
					list.set_item_custom_fg_color(index, wanted)
				# Small icons only (not thumbnails).
				var list_icon: Texture2D = _icon_for(path) if on and list.icon_mode == ItemList.ICON_MODE_LEFT else null
				if list_icon != null and list.get_item_icon(index) != list_icon:
					list.set_item_icon(index, list_icon)


func _tint_tree_item(item: TreeItem, on: bool) -> void:
	var metadata: Variant = item.get_metadata(0)
	var icon: Texture2D = _icon_for(metadata) if metadata is String and on else null
	if icon != null and item.get_icon(0) != icon:
		item.set_icon(0, icon)
	var tint: Color = _color_for(metadata) if metadata is String else Color()
	if tint == Color():
		return
	if on and item.get_custom_color(0) != tint:
		item.set_custom_color(0, tint)
	elif not on:
		item.clear_custom_color(0)


func _matches(path: String) -> bool:
	return not path.is_empty() and matches.is_valid() and bool(matches.call(path))


func _icon_for(path: String) -> Texture2D:
	return icon_of.call(path) if not path.is_empty() and icon_of.is_valid() else null


## The tint of a file's name, or Color() for none.
func _color_for(path: String) -> Color:
	if _matches(path):
		return color
	if not path.is_empty() and other_matches.is_valid() and bool(other_matches.call(path)):
		return other_color
	return Color()


## Tints the code background of the shown script if it matches, and takes
## the tint off one that doesn't (the signal's script can be stale, so the
## current script is asked again).
func _on_script_changed(_script: Script) -> void:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var current: ScriptEditorBase = script_editor.get_current_editor()
	var code: CodeEdit = current.get_base_editor() as CodeEdit if current != null else null
	if code == null:
		return
	var script: Script = script_editor.get_current_script()
	var wanted: bool = script != null and _matches(script.resource_path)
	if wanted and not code.has_meta(BACKGROUND_META):
		var background: Color = code.get_theme_color(&"background_color")
		code.set_meta(BACKGROUND_META, background)
		# The editor's code background is usually drawn by a style box, with a
		# transparent background_color on top: then tint with a see-through color.
		var tint: Color = Color(color, CODE_TINT) if background.a < 0.01 else background.lerp(color, CODE_TINT)
		code.add_theme_color_override(&"background_color", tint)
		_tinted_code.append(code)
	elif not wanted and code.has_meta(BACKGROUND_META):
		code.add_theme_color_override(&"background_color", code.get_meta(BACKGROUND_META))
		code.remove_meta(BACKGROUND_META)
		_tinted_code.erase(code)
