extends VBoxContainer
## The Code screen (2026-11-16): the project's own text files (C and headers, notes, shaders) next to the Bricks
## editor, so a project whose program is mostly C needn't be written outside C-Bricks. Tabs of open files, a
## CodeEdit with line numbers and C highlighting, Ctrl+S, compiler errors marked on their lines. The generated C
## (read-only) stays in the bottom panel's "Generated C".

const BrickTheme = preload("res://scripts/editor/brick_theme.gd")

signal saved(path: String)
signal edited          ## a file's text changed (the panel recompiles lazily, as for bricks)

const TEXT_EXTS := ["c", "h", "txt", "md", "cfg", "json", "glsl", "vs", "fs", "sh", "py", "csv", "ini"]
const ERROR_BG := Color(0.55, 0.15, 0.15, 0.35)
const WARN_BG := Color(0.55, 0.45, 0.1, 0.25)

var make_highlighter: Callable = Callable()   ## -> a SyntaxHighlighter for C (the panel's)
var font: Font = null
var project_dir := ""

var _files: Array = []        # [{path, dirty, mtime, errors: {line: [kind, msg]}}]
var _cur := -1
var _tabs: TabBar
var _edit: CodeEdit
var _empty: Label
var _status: Label
var _loading := false


static func is_text_file(path: String) -> bool:
	return path.get_extension().to_lower() in TEXT_EXTS


func _init() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	_tabs = TabBar.new()
	_tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	_tabs.size_flags_horizontal = SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	_tabs.tab_close_pressed.connect(close_file)
	bar.add_child(_tabs)
	var save := Button.new()
	save.text = "Save"
	save.flat = true
	save.tooltip_text = "Save this file (Ctrl+S saves every open file)"
	save.pressed.connect(func() -> void: save_current())
	bar.add_child(save)
	add_child(bar)
	_edit = CodeEdit.new()
	_edit.size_flags_vertical = SIZE_EXPAND_FILL
	_edit.gutters_draw_line_numbers = true
	_edit.gutters_draw_fold_gutter = true
	_edit.highlight_current_line = true
	_edit.indent_automatic = true
	_edit.auto_brace_completion_enabled = true
	_edit.line_folding = true
	_edit.minimap_draw = false
	_edit.draw_tabs = true
	_edit.text_changed.connect(_on_text_changed)
	_edit.caret_changed.connect(_update_status)
	_edit.visible = false
	add_child(_edit)
	_empty = Label.new()
	_empty.text = "Double-click a .c or .h file in the FileSystem dock to edit it here."
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = SIZE_EXPAND_FILL
	_empty.add_theme_color_override(&"font_color", BrickTheme.LOCAL_COLOR)
	add_child(_empty)
	_status = Label.new()
	_status.add_theme_font_size_override(&"font_size", 12)
	_status.add_theme_color_override(&"font_color", Color(0.6, 0.62, 0.7))
	add_child(_status)


func _ready() -> void:
	if make_highlighter.is_valid():
		_edit.syntax_highlighter = make_highlighter.call()
	if font != null:
		_edit.add_theme_font_override(&"font", font)
	_edit.add_theme_font_size_override(&"font_size", 14)


# ------------------------------------------------------------------ files

func open_file(path: String, line := 0) -> void:
	var at := _index_of(path)
	if at < 0:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			_status.text = "Can't read %s" % path
			return
		_files.append({"path": path, "dirty": false, "mtime": FileAccess.get_modified_time(path), "errors": {}, "text": f.get_as_text(), "caret": [0, 0], "scroll": 0})
		_tabs.add_tab(path.get_file())
		at = _files.size() - 1
		_tabs.set_tab_tooltip(at, _rel(path))
	_tabs.current_tab = at
	_on_tab_changed(at)
	if line > 0:
		goto_line(line)


func goto_line(line: int) -> void:
	if _cur < 0:
		return
	var l := clampi(line - 1, 0, _edit.get_line_count() - 1)
	_edit.set_caret_line(l)
	_edit.set_caret_column(0)
	_edit.center_viewport_to_caret()
	_edit.grab_focus()


func close_file(i: int) -> void:
	if i < 0 or i >= _files.size():
		return
	if _files[i].dirty:
		_write(i)   # (saved first, as the Bricks tabs are)
	_stash()
	_files.remove_at(i)
	_tabs.remove_tab(i)
	_cur = -1
	if _files.is_empty():
		_show_current()
	else:
		var n := mini(i, _files.size() - 1)
		_tabs.current_tab = n
		_on_tab_changed(n)


func close_all() -> void:
	_files.clear()
	_tabs.clear_tabs()
	_cur = -1
	_show_current()


func has_dirty() -> bool:
	return _files.any(func(f: Dictionary) -> bool: return f.dirty)


func save_current() -> void:
	if _cur >= 0:
		_write(_cur)


func save_all() -> void:
	_stash()
	for i in _files.size():
		if _files[i].dirty:
			_write(i)


## A file moved or was deleted in the FileSystem dock: its tab follows (to == "": closed).
func path_changed(from: String, to: String) -> void:
	for i in range(_files.size() - 1, -1, -1):
		var p: String = _files[i].path
		if p != from and not p.begins_with(from + "/"):
			continue
		if to == "":
			_files[i].dirty = false
			close_file(i)
		else:
			_files[i].path = to + p.substr(from.length())
			_tabs.set_tab_title(i, str(_files[i].path).get_file())
			_tabs.set_tab_tooltip(i, _rel(_files[i].path))


## Files edited elsewhere (an outside editor, a git checkout): a clean tab reloads, a dirty one keeps the user's text.
func check_external() -> void:
	for i in _files.size():
		var f: Dictionary = _files[i]
		var m := FileAccess.get_modified_time(f.path)
		if m == f.mtime or f.dirty or not FileAccess.file_exists(f.path):
			continue
		f.mtime = m
		f.text = FileAccess.get_file_as_string(f.path)
		if i == _cur:
			_set_text(f.text)


## Compiler problems for the open files: {path: [{line, kind, msg}]}; marks the lines (red errors, amber warnings).
func set_problems(by_path: Dictionary) -> void:
	for f in _files:
		f.errors = {}
		for p in by_path.get(f.path, []):
			if not f.errors.has(int(p.line)) or p.kind == "error":
				f.errors[int(p.line)] = [p.kind, p.msg]
	_mark_lines()


func current_path() -> String:
	return _files[_cur].path if _cur >= 0 else ""


func current_text() -> String:
	return _edit.text if _cur >= 0 else ""


func paths() -> PackedStringArray:
	var out := PackedStringArray()
	for f in _files:
		out.append(f.path)
	return out


## Test hook: replaces the open file's text as typing would.
func type_text(text: String) -> void:
	if _cur >= 0:
		_edit.text = text
		_on_text_changed()


# ------------------------------------------------------------------ internals

func _index_of(path: String) -> int:
	for i in _files.size():
		if _files[i].path == path:
			return i
	return -1


func _rel(path: String) -> String:
	return path.trim_prefix(project_dir).trim_prefix("/") if project_dir != "" else path


func _stash() -> void:
	if _cur >= 0 and _cur < _files.size():
		var f: Dictionary = _files[_cur]
		f.text = _edit.text
		f.caret = [_edit.get_caret_line(), _edit.get_caret_column()]
		f.scroll = _edit.scroll_vertical


func _on_tab_changed(i: int) -> void:
	if i == _cur or i < 0 or i >= _files.size():
		return
	_stash()
	_cur = i
	_show_current()


func _show_current() -> void:
	_edit.visible = _cur >= 0
	_empty.visible = _cur < 0
	if _cur < 0:
		_status.text = ""
		return
	var f: Dictionary = _files[_cur]
	_set_text(f.text)
	_edit.set_caret_line(int(f.caret[0]))
	_edit.set_caret_column(int(f.caret[1]))
	_edit.scroll_vertical = int(f.scroll)
	_edit.syntax_highlighter = make_highlighter.call() if make_highlighter.is_valid() and str(f.path).get_extension().to_lower() in ["c", "h"] else null
	_mark_lines()
	_update_status()


func _set_text(text: String) -> void:
	_loading = true
	var scroll := _edit.scroll_vertical
	_edit.text = text
	_edit.scroll_vertical = scroll
	_edit.clear_undo_history()
	_loading = false
	_mark_lines()


func _on_text_changed() -> void:
	if _loading or _cur < 0:
		return
	var f: Dictionary = _files[_cur]
	f.text = _edit.text
	if not f.dirty:
		f.dirty = true
		_retitle(_cur)
	f.errors = {}   # (line numbers are stale once the text changes; the next build marks them again)
	_mark_lines()
	edited.emit()


func _retitle(i: int) -> void:
	_tabs.set_tab_title(i, _files[i].path.get_file() + (" *" if _files[i].dirty else ""))


func _write(i: int) -> void:
	var f: Dictionary = _files[i]
	var text: String = _edit.text if i == _cur else f.text
	var fa := FileAccess.open(f.path, FileAccess.WRITE)
	if fa == null:
		_status.text = "Could not save %s" % f.path
		return
	fa.store_string(text)
	fa.close()
	f.text = text
	f.dirty = false
	f.mtime = FileAccess.get_modified_time(f.path)
	_retitle(i)
	saved.emit(f.path)


func _mark_lines() -> void:
	for l in _edit.get_line_count():
		_edit.set_line_background_color(l, Color(0, 0, 0, 0))
	if _cur < 0:
		return
	var errors: Dictionary = _files[_cur].errors
	for line in errors:
		if int(line) >= 1 and int(line) <= _edit.get_line_count():
			_edit.set_line_background_color(int(line) - 1, ERROR_BG if errors[line][0] == "error" else WARN_BG)
	_update_status()


func _update_status() -> void:
	if _cur < 0:
		return
	var line := _edit.get_caret_line() + 1
	var errors: Dictionary = _files[_cur].errors
	var text := "%s   line %d, column %d" % [_rel(_files[_cur].path), line, _edit.get_caret_column() + 1]
	if errors.has(line):
		text += "   ·   %s: %s" % [errors[line][0], errors[line][1]]
	elif not errors.is_empty():
		text += "   ·   %d compiler message(s) in this file" % errors.size()
	_status.text = text
