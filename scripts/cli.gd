extends SceneTree
## Headless commands for `cbricks` (no window): build a project, list its problems.
##   godot --headless --path <C-Bricks> -s res://scripts/cli.gd -- build DIR [strict] [--json]
##   godot --headless --path <C-Bricks> -s res://scripts/cli.gd -- check DIR [--json]
##   godot --headless --path <C-Bricks> -s res://scripts/cli.gd -- export DIR OUT [--json]
##   godot --headless --path <C-Bricks> -s res://scripts/cli.gd -- arrange DIR [script.cbricks ...]
## `build`: graph -> C (ProjectBuild) -> native program in DIR/.build/native/<program name>.
## `check`: only the graph -> C step: prints warnings and problems.
## `export`: the standalone C project (src/, assets, Makefile, CMake, build scripts) into OUT.
## `--json` (build / check / export): the last stdout line is {"ok", "problems": [{"script", "node", "msg"}], "warnings": [...]}
## (script = path relative to DIR, node = brick id or 0); the human text goes to stderr / is left out.
## Exit code: 0 ok, 1 problems / didn't compile, 2 bad arguments. Writes only inside DIR/.build/.

var _json := false


## Prints the problems as JSON (when --json) and quits with `code`.
func _report(dir: String, r: Dictionary, code: int) -> void:
	if _json:
		var probs: Array = []
		for e in r.get("errors", []):
			var d: Dictionary = e if e is Dictionary else {"msg": str(e)}
			var sp := str(d.get("script", ""))
			probs.append({"script": CBProject.rel_path(dir, sp) if sp.begins_with(dir) else sp, "node": int(d.get("node", 0)), "msg": str(d.get("msg", ""))})
		var warns: Array = []
		for w in r.get("warnings", []):
			warns.append(str(w.msg if w is Dictionary else w))
		print(JSON.stringify({"ok": code == 0, "problems": probs, "warnings": warns}))
	quit(code)


func _init() -> void:
	var args := Array(OS.get_cmdline_user_args())
	_json = "--json" in args
	args = args.filter(func(a: String) -> bool: return a != "--json")
	if args.size() < 2 or not args[0] in ["build", "check", "arrange", "export"]:
		printerr("usage: -- build|check|arrange|export <project dir> [strict | script paths | out dir] [--json]")
		quit(2)
		return
	var dir: String = String(args[1]).simplify_path()
	if dir.get_file() == "project.cbproj":
		dir = dir.get_base_dir()
	if not CBProject.is_project(dir):
		printerr("not a C-Bricks project (no project.cbproj): %s" % dir)
		quit(2)
		return
	if args[0] == "arrange":  # lay the scripts out (all, or the ones named: paths relative to DIR) with estimated sizes
		var names := PackedStringArray(args.slice(2))
		var done := 0
		for path in CBProject.list_scripts(dir):
			if not names.is_empty() and not CBProject.rel_path(dir, path) in names:
				continue
			var g := CBProject.read_script(path)
			if g.is_empty():
				printerr("not a script: ", path)
				continue
			Ops.tidy_estimated(g)
			if CBProject.write_script(path, g) != OK:
				printerr("couldn't write ", path)
				quit(1)
				return
			print("arranged ", CBProject.rel_path(dir, path))
			done += 1
		quit(0 if done > 0 else 1)
		return
	var r: Dictionary = ProjectBuild.generate(dir)
	if not _json:
		for w in r.warnings:
			print("warning: ", w.msg if w is Dictionary else str(w))
	if not r.errors.is_empty():
		if not _json:
			for e in r.errors:
				printerr("problem: ", e.msg if e is Dictionary else str(e))
		_report(dir, r, 1)
		return
	if args[0] == "check":
		if not _json:
			print("no problems")
		_report(dir, r, 0)
		return
	if args[0] == "export":
		if args.size() < 3:
			printerr("usage: -- export <project dir> <out dir>")
			quit(2)
			return
		var out_dir := String(args[2]).simplify_path()
		var res: Dictionary = ProjectBuild.generate(dir, {}, "native")  # (an exported project builds with raylib's backend)
		var err := Toolchains.export_project(out_dir, CBProject.program_name(dir), res, dir)
		if err != "":
			printerr("export failed: ", err)
			res = {"errors": [{"script": "", "node": 0, "msg": err}], "warnings": []}
			_report(dir, res, 1)
			return
		if not _json:
			print("exported to: ", out_dir)
		_report(dir, r, 0)
		return
	var build: String = dir.path_join(".build")
	var srcs := ProjectBuild.write(r, build.path_join("src"))
	var rl: Dictionary = {}
	if r.graphics:
		print("building raylib for this computer (cached after the first time)...")
		rl = Toolchains.build_raylib("native")
		if not rl.ok:
			printerr("raylib didn't build:\n", str(rl.output))
			_report(dir, {"errors": [{"script": "", "node": 0, "msg": "raylib didn't build: " + str(rl.output).left(500)}]}, 1)
			return
	var template := ""
	if args.size() > 2 and args[2] == "strict":
		template = "cc -std=c99 -O1 -Wall -Wextra -pedantic {src} -o {out} -lm"
	var built: Dictionary = Toolchains.compile("native", srcs, build.path_join("native"), CBProject.program_name(dir), template, rl)
	if not built.ok:
		printerr("didn't compile:\n", str(built.output))
		_report(dir, {"errors": [{"script": "", "node": 0, "msg": "didn't compile: " + str(built.output).left(2000)}]}, 1)
		return
	var out := str(built.output).strip_edges()
	if out != "":
		print("compiler output:\n", out)
	print("built: ", built.out)
	_report(dir, r, 0)
