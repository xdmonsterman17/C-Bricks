extends SceneTree
## Compiles every example for this computer before the editor is exported (export-editor.sh runs
## it), into res://prebuilt/<fingerprint>/<program>: the export ships them, so an example's
## first Run (from its copy in Documents) reuses its program instead of compiling it
## (Toolchains.cached_build). Each is built in a copy, exactly as the app builds a project.
##   godot --headless --path . -s res://tools/prebuild.gd

func _init() -> void:
	var out_root := ProjectSettings.globalize_path("res://prebuilt")
	_remove_tree(out_root)  # (only this export's programs)
	DirAccess.make_dir_recursive_absolute(out_root)
	var built := 0
	var failed := 0
	var names := Array(DirAccess.get_directories_at("res://examples"))
	names.sort()
	for name in names:
		var copy := OS.get_user_data_dir().path_join("prebuild").path_join(name)
		_remove_tree(copy)
		CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/" + name), copy)
		if _target_of(copy) != "native":
			continue  # (an MS-DOS example: built for its Target when run)
		var r := ProjectBuild.generate(copy)
		if not r.errors.is_empty():
			printerr("%s: problems, not prebuilt: %s" % [name, r.errors.map(func(e): return e.msg)])
			failed += 1
			continue
		var srcs := ProjectBuild.write(r, copy.path_join(CBProject.BUILD_DIR).path_join("src"))
		var base := CBProject.program_name(copy)
		var out_dir := copy.path_join(CBProject.BUILD_DIR).path_join("native")
		var b := Toolchains.cached_build("native", srcs, out_dir, base, "", bool(r.get("graphics", false)))
		if not b.ok:
			printerr("%s: didn't compile:\n%s" % [name, str(b.output).strip_edges()])
			failed += 1
			continue
		var key := FileAccess.get_file_as_string(str(b.out) + ".key").strip_edges()
		var dest := out_root.path_join(key)
		DirAccess.make_dir_recursive_absolute(dest)
		DirAccess.copy_absolute(str(b.out), dest.path_join(str(b.out).get_file()))
		print("prebuilt %-22s %s%s" % [name, key.substr(0, 12), "  (reused)" if str(b.get("cached", "")) != "" else ""])
		built += 1
	print("%d example(s) prebuilt, %d failed" % [built, failed])
	quit(failed)


static func _target_of(dir: String) -> String:
	var cf := ConfigFile.new()
	cf.load(dir.path_join("project.cbproj"))
	return str(cf.get_value("build", "target", "native"))


static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
