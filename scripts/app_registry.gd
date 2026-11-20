class_name AppRegistry
extends RefCounted
## The app registry (2026-11-19): programs of the C-Bricks family (C-Vert, the editor) leave where they live in
## <config>/apps/<name>, one line: the program's absolute path. The runtime's cb_register_app writes the same files, so a
## program built with C-Bricks registers itself; the editor reads them here. <config> is $CBRICKS_CONFIG, else the
## per-user config folder + "c-bricks" (Linux ~/.config, macOS ~/Library/Application Support, Windows %APPDATA%).


static func config_dir() -> String:
	var o := OS.get_environment("CBRICKS_CONFIG")
	if o != "":
		return o
	match OS.get_name():
		"Windows":
			return OS.get_environment("APPDATA").path_join("c-bricks") if OS.get_environment("APPDATA") != "" else ""
		"macOS":
			return OS.get_environment("HOME").path_join("Library/Application Support/c-bricks") if OS.get_environment("HOME") != "" else ""
	var x := OS.get_environment("XDG_CONFIG_HOME")
	if x != "":
		return x.path_join("c-bricks")
	var h := OS.get_environment("HOME")
	return h.path_join(".config/c-bricks") if h != "" else ""


## The registered program's path, or "" when there is no entry or the file is gone.
static func find(app: String) -> String:
	var dir := config_dir()
	if dir == "" or app == "":
		return ""
	var f := FileAccess.open(dir.path_join("apps").path_join(app), FileAccess.READ)
	if f == null:
		return ""
	var line := f.get_as_text().split("\n")[0].strip_edges()
	return line if line != "" and FileAccess.file_exists(line) else ""


## Remembers where a program lives (the user picked it in a dialog). False when the config folder can't be written.
static func remember(app: String, path: String) -> bool:
	var dir := config_dir()
	if dir == "" or app == "" or path == "":
		return false
	var apps := dir.path_join("apps")
	if DirAccess.make_dir_recursive_absolute(apps) != OK:
		return false
	var f := FileAccess.open(apps.path_join(app), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(path)
	return true
