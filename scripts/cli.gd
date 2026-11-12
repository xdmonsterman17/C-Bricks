extends SceneTree
## Headless commands for `cbricks` (no window): build a project, list its problems.
##   godot --headless --path <C-Bricks> -s res://scripts/cli.gd -- build DIR [strict]
##   godot --headless --path <C-Bricks> -s res://scripts/cli.gd -- check DIR
## `build`: graph -> C (ProjectBuild) -> native program in DIR/.build/native/<program name>.
## `check`: only the graph -> C step: prints warnings and problems.
## Exit code: 0 ok, 1 problems / didn't compile, 2 bad arguments. Writes only inside DIR/.build/.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or not args[0] in ["build", "check"]:
		printerr("usage: -- build|check <project dir> [strict]")
		quit(2)
		return
	var dir := args[1].simplify_path()
	if dir.get_file() == "project.cbproj":
		dir = dir.get_base_dir()
	if not CBProject.is_project(dir):
		printerr("not a C-Bricks project (no project.cbproj): %s" % dir)
		quit(2)
		return
	var r: Dictionary = ProjectBuild.generate(dir)
	for w in r.warnings:
		print("warning: ", w.msg if w is Dictionary else str(w))
	if not r.errors.is_empty():
		for e in r.errors:
			printerr("problem: ", e.msg if e is Dictionary else str(e))
		quit(1)
		return
	if args[0] == "check":
		print("no problems")
		quit(0)
		return
	var build := dir.path_join(".build")
	var srcs := ProjectBuild.write(r, build.path_join("src"))
	var rl: Dictionary = {}
	if r.graphics:
		print("building raylib for this computer (cached after the first time)...")
		rl = Toolchains.build_raylib("native")
		if not rl.ok:
			printerr("raylib didn't build:\n", str(rl.output))
			quit(1)
			return
	var template := ""
	if args.size() > 2 and args[2] == "strict":
		template = "cc -std=c99 -O1 -Wall -Wextra -pedantic {src} -o {out} -lm"
	var built: Dictionary = Toolchains.compile("native", srcs, build.path_join("native"), CBProject.program_name(dir), template, rl)
	if not built.ok:
		printerr("didn't compile:\n", str(built.output))
		quit(1)
		return
	var out := str(built.output).strip_edges()
	if out != "":
		print("compiler output:\n", out)
	print("built: ", built.out)
	quit(0)
