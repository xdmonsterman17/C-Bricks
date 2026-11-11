extends SceneTree
## C-Bricks test runner: godot --headless --path . -s res://tests/run_tests.gd [-- <case names>]
##
## Every folder in tests/cases/ with a case.cfg is a case (folders starting with
## "_" are skipped). A case names a project (its own folder when it has a
## project.cbproj, or `project = "res://examples/..."`), how to run it and what
## should come out. Each case: generate the project's C (no problems allowed
## unless expected), compile it with the native compiler and -Wall -Wextra
## -pedantic (warnings are reported), run it, compare. The report goes to
## tests/reports/latest.md; the exit code is the number of failed cases.
##
## Graphics cases run headless too (user, 2026-11-07): the runner starts its own virtual X
## display (Xvfb, Mesa's software OpenGL) and their windows open there, not on the screen.
## `-- --on-screen` opens them on the real display instead (to watch them).
##
## Kind to the machine (user, 2026-11-07: a video stuttered while tests ran): the runner
## lowers its own priority (nice 19, ionice idle; every compile and program inherits it)
## and gives Mesa's software OpenGL 2 threads. Faster (2026-11-07): a case's program is
## kept (user://test_cache) and reused while its C and compile command are the same; on a
## change its .c files compile in parallel, then link; a program runs once (stdout and
## stderr apart only when a case checks stdout alone).

const CASES := "res://tests/cases"
## One test project per palette group: every brick and every mode (tests/make_suites.py).
const SUITES := "res://tests/suites"
const REPORT := "res://tests/reports/latest.md"

var _failed := 0
var _lines := PackedStringArray()
var _xvfb_pid := -1
var _case_start := 0       # (msec) when the case under way started
var _compile_ms := 0       # (msec) its C compile
var _times := []           # [name, total msec, compile msec], for the report's slowest list
var _cached := 0           # cases whose program was reused
## Network cases (`peers`) wait in real time: queued while the others run, then run
## PEER_POOL at once (each has its own port and files). Not more: they're timing-sensitive.
const PEER_POOL := 3
var _peer_queue := []      # {name, cf, exe, args, work, notes, start}
const CACHE := "user://test_cache"
const STRICT_FLAGS := ["-std=c99", "-O0", "-Wall", "-Wextra", "-pedantic"]


func _init() -> void:
	# A core script that doesn't compile makes every case's calls fail silently: stop here.
	for core in ["res://scripts/project_build.gd", "res://scripts/codegen.gd", "res://scripts/node_defs.gd", "res://scripts/types.gd", "res://scripts/toolchains.gd", "res://scripts/project.gd", "res://scripts/ops.gd"]:
		var sc := load(core) as GDScript
		if sc == null or not sc.can_instantiate():
			printerr("%s doesn't compile: no case can run (see the errors above)." % core)
			quit(1)
			return
	var only := PackedStringArray()
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a != "--on-screen":
			only.append(a)
	_be_kind()
	var display := "the screen (--on-screen)" if "--on-screen" in args else _start_virtual_display()
	var names := Array(DirAccess.get_directories_at(CASES))
	names.sort()
	var cc := Toolchains.resolve_command("native")
	_lines.append("# C-Bricks test report")
	_lines.append("")
	_lines.append("%s · compiler: `%s` · graphics cases' windows: %s" % [Time.get_datetime_string_from_system(false, true), cc if cc != "" else "none found", display])
	_lines.append("")
	var count := 0
	# The suites (one per palette group), then the scenario cases.
	var groups := Array(DirAccess.get_directories_at(SUITES)) if DirAccess.dir_exists_absolute(SUITES) else []
	groups.sort()
	for g in groups:
		var label := "suite_" + str(g)
		if not only.is_empty() and label not in only and "suites" not in only:
			continue
		if not FileAccess.file_exists("%s/%s/case.cfg" % [SUITES, g]):
			continue
		count += 1
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		_run_case(label, "%s/%s" % [SUITES, g])
	for name in names:
		if name.begins_with("_") or (not only.is_empty() and name not in only):
			continue
		if not FileAccess.file_exists("%s/%s/case.cfg" % [CASES, name]):
			continue
		count += 1
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		_run_case(name, "%s/%s" % [CASES, name])
	_run_peer_queue()
	if only.is_empty() or "coverage" in only:
		count += 1
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		_check_coverage()
	if only.is_empty() or "watches" in only:
		count += 1
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		_check_watches()
	if only.is_empty() or "examples" in only:
		count += 1
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		_check_examples()
	if only.is_empty() or "scopes" in only:
		count += 1
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		_check_scopes()
	if only.is_empty() or "old_names" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_old_names()
	if only.is_empty() or "new_project" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_new_project()
	if only.is_empty() or "ui_layout" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_ui_layout()
	if only.is_empty() or "build_cache" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_build_cache()
	if only.is_empty() or "unpack" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_unpack()
	if only.is_empty() or "toolchain_install" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		await _check_toolchain_install()
	if only.is_empty() or "bundle" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_bundle()
	if only.is_empty() or "dos" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_dos()
	if only.is_empty() or "dos_input" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_dos_input()
	if only.is_empty() or "dos_net" in only:
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		count += 1
		_check_dos_net()
	if only.is_empty() or "api_md" in only:
		count += 1
		_case_start = Time.get_ticks_msec()
		_compile_ms = 0
		_check_api_md()
	_lines.insert(4, "**%d of %d case(s) passed.** %d program(s) reused from the cache (their C unchanged).\n" % [count - _failed, count, _cached])
	_times.sort_custom(func(a, b): return a[1] > b[1])
	_lines.append("")
	_lines.append("## Slowest")
	for t in _times.slice(0, 10):
		_lines.append("- %s: %.1f s%s" % [t[0], t[1] / 1000.0, (" (compile %.1f s)" % (t[2] / 1000.0)) if t[2] > 0 else ""])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/reports"))
	var fa := FileAccess.open(REPORT, FileAccess.WRITE)
	if fa != null:
		fa.store_string("\n".join(_lines) + "\n")
		fa.close()
	print("%d of %d case(s) passed (%d reused from the cache). Report: tests/reports/latest.md" % [count - _failed, count, _cached])
	_stop_virtual_display()
	quit(_failed)


## Starts Xvfb on a free display number and points this process's children (the graphics
## cases) at it; gives where their windows go. No Xvfb: the real display, as before.
func _start_virtual_display() -> String:
	if not Toolchains.has_program("Xvfb"):
		return "the screen (Xvfb isn't installed)"
	for n in range(90, 120):
		var sock := "/tmp/.X11-unix/X%d" % n
		if _is_socket(sock) or FileAccess.file_exists("/tmp/.X%d-lock" % n):
			continue
		_xvfb_pid = OS.create_process("Xvfb", [":%d" % n, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"])
		if _xvfb_pid <= 0:
			break
		for i in 50:  # (up to 5 s for it to listen)
			if _is_socket(sock):
				OS.set_environment("DISPLAY", ":%d" % n)
				OS.unset_environment("WAYLAND_DISPLAY")
				return "a virtual display (Xvfb :%d, software OpenGL)" % n
			OS.delay_msec(100)
		OS.kill(_xvfb_pid)
		_xvfb_pid = -1
		break
	return "the screen (Xvfb didn't start)"


func _run_case(name: String, res_dir: String) -> void:
	var case_dir := ProjectSettings.globalize_path(res_dir)
	var cf := ConfigFile.new()
	cf.load(case_dir.path_join("case.cfg"))
	var project := str(cf.get_value("case", "project", ""))
	var dir := case_dir if project == "" else ProjectSettings.globalize_path(project)
	var problems := []
	var notes := []
	if not CBProject.is_project(dir):
		_fail(name, ["no project at %s" % dir], [])
		return
	var r := ProjectBuild.generate(dir)
	var want_errors: Array = cf.get_value("case", "expect_problems", [])
	if not want_errors.is_empty():
		var got: Array = r.errors.map(func(e): return e.msg)
		for w in want_errors:
			if not got.any(func(m): return m.contains(w)):
				problems.append("expected a problem containing '%s', got %s" % [w, got])
		_finish(name, problems, notes)
		return
	if not r.errors.is_empty():
		_fail(name, ["the C couldn't be generated:"] + r.errors.map(func(e): return "  " + e.msg), [])
		return
	var work := OS.get_user_data_dir().path_join("test_build").path_join(name)
	var srcs := ProjectBuild.write(r, work.path_join("src"))
	var strict := "cc -std=c99 -O0 -Wall -Wextra -pedantic {src} -o {out} -lm"
	# Graphics projects link raylib (compiled once per target, cached) and need a display to run.
	var rl: Dictionary = {}
	if r.graphics:
		if OS.get_environment("DISPLAY") == "" and OS.get_environment("WAYLAND_DISPLAY") == "":
			_skip(name, "a graphics program: no display to open its window on")
			return
		rl = Toolchains.build_raylib("native")
		if not rl.ok:
			_fail(name, ["raylib didn't build:", str(rl.output).strip_edges().indent("    ")], [])
			return
	var t0 := Time.get_ticks_msec()
	var built := _compile_cached(name, srcs, work, rl) if Toolchains.has_program("cc") else Toolchains.compile("native", srcs, work, "prog", "", rl)
	_compile_ms = Time.get_ticks_msec() - t0
	if not built.ok:
		_fail(name, ["didn't compile:", built.output.strip_edges().indent("    ")], [])
		return
	if built.output.contains("warning:"):
		notes.append("compiler warnings:\n" + built.output.strip_edges().indent("    "))
	# Run in a copy of the project (so files a case writes never land in the source tree):
	# --cd there, a fixed seed, stdin from the case.
	var run_dir := work.path_join("project")
	_remove_tree(run_dir)
	CBProject.copy_dir(dir, run_dir)
	var run_args := PackedStringArray(["--cd", run_dir, "--seed", str(cf.get_value("case", "seed", 1)), "--max-steps", str(cf.get_value("case", "max_steps", 1000000))])
	var stdin := str(cf.get_value("case", "input", ""))
	var input_file := work.path_join("stdin.txt")
	var fi := FileAccess.open(input_file, FileAccess.WRITE)
	fi.store_string(stdin)
	fi.close()
	run_args.append_array(["--input", input_file])
	if cf.has_section_key("case", "peers"):
		_peer_queue.append({"name": name, "cf": cf, "exe": built.out, "args": run_args, "work": work, "notes": notes, "compile": _compile_ms, "ready": Time.get_ticks_msec() - _case_start})
		return
	run_args.append_array(Toolchains.split_command(str(cf.get_value("case", "args", ""))))
	# One run. A case that checks stdout alone gets stderr in a file (then stdout + stderr is
	# the two one after the other: such cases don't check the order across them, except the
	# few with expect_order too, which run twice as before).
	var stdout := ""
	var combined := ""
	var code := 0
	var split := cf.has_section_key("case", "expect_output")
	if split and not cf.has_section_key("case", "expect_order"):
		var err_file := work.path_join("stderr.txt")
		# (OS.execute with output runs through popen's own shell, which would expand a "$1":
		# one command line of single-quoted words instead)
		var words := PackedStringArray([_sq(built.out)])
		for a in run_args:
			words.append(_sq(a))
		var out := []
		code = OS.execute("/bin/sh", ["-c", " ".join(words) + " 2> " + _sq(err_file)], out, false)
		stdout = "".join(out)
		combined = stdout + FileAccess.get_file_as_string(err_file)
	else:
		var both := []
		code = OS.execute(built.out, run_args, both, true)
		combined = "".join(both)
		if split:
			var out := []
			OS.execute(built.out, run_args, out, false)
			stdout = "".join(out)
	var want_exit := int(cf.get_value("case", "expect_exit", 0))
	if code != want_exit:
		problems.append("exit code %d, expected %d" % [code, want_exit])
	if cf.has_section_key("case", "expect_output"):
		var want := str(cf.get_value("case", "expect_output"))
		if stdout.strip_edges() != want.strip_edges():
			problems.append("stdout differs:\n" + _diff(want.strip_edges(), stdout.strip_edges()))
	for piece in cf.get_value("case", "expect_contains", []):
		if not combined.contains(str(piece)):
			problems.append("output (stdout + stderr) has no '%s'" % piece)
	# Pieces that must appear in this order (stdout + stderr).
	var from := 0
	for piece in cf.get_value("case", "expect_order", []):
		var at := combined.find(str(piece), from)
		if at < 0:
			problems.append("output (stdout + stderr) has no '%s' after the pieces before it" % piece)
			break
		from = at + str(piece).length()
	for piece in cf.get_value("case", "expect_missing", []):
		if combined.contains(str(piece)):
			problems.append("output (stdout + stderr) has '%s', it shouldn't" % piece)
	if not problems.is_empty():
		notes.append("output:\n" + combined.strip_edges().indent("    "))
	_finish(name, problems, notes)


## A network case: the same program run several times at once (`peers`: each one's
## flags, e.g. "--server 47311", "--join 127.0.0.1:47311 --name ada"), started
## `peer_delay` seconds apart, each one's stdout + stderr checked on its own
## (expect_peerN_order / _contains / _missing / _exit; N from 0).
func _run_peer_queue() -> void:
	var running := []
	while not _peer_queue.is_empty() or not running.is_empty():
		while running.size() < PEER_POOL and not _peer_queue.is_empty():
			var c: Dictionary = _peer_queue.pop_front()
			c["pids"] = []
			c["outs"] = []
			c["peers"] = c.cf.get_value("case", "peers", [])
			c["next"] = 0                           # the next peer to start
			c["next_at"] = Time.get_ticks_msec()    # and when (peer_delay apart)
			c["began"] = Time.get_ticks_msec()
			running.append(c)
		for c in running.duplicate():
			if _peer_step(c):
				running.erase(c)
				_case_start = Time.get_ticks_msec() - (int(c.ready) + Time.get_ticks_msec() - int(c.began))
				_compile_ms = int(c.compile)
				_check_peers(c)
		OS.delay_msec(30)


## Starts a case's peers as their time comes; true when they've all ended (or timed out).
func _peer_step(c: Dictionary) -> bool:
	var peers: Array = c.peers
	var now := Time.get_ticks_msec()
	if int(c.next) < peers.size():
		if now >= int(c.next_at):
			var i := int(c.next)
			var out_file: String = str(c.work).path_join("peer%d.txt" % i)
			DirAccess.remove_absolute(out_file)
			c.outs.append(out_file)
			var sh_args := PackedStringArray(["-c", "out=\"$1\"; shift; \"$@\" > \"$out\" 2>&1; echo \"[peer exit $?]\" >> \"$out\"", "sh", out_file, c.exe])
			sh_args.append_array(c.args)
			sh_args.append_array(Toolchains.split_command(str(peers[i])))
			c.pids.append(OS.create_process("/bin/sh", sh_args))
			c.next = i + 1
			c.next_at = now + int(float(c.cf.get_value("case", "peer_delay", 0.3)) * 1000)
		return false
	if c.pids.any(func(pid): return OS.is_process_running(pid)):
		if now - int(c.began) > float(c.cf.get_value("case", "peer_timeout", 30.0)) * 1000:
			for pid in c.pids:
				OS.kill(pid)
			return true
		return false
	return true


## A network case's peers, each one's stdout + stderr checked on its own
## (expect_peerN_order / _contains / _missing / _exit; N from 0).
func _check_peers(c: Dictionary) -> void:
	var cf: ConfigFile = c.cf
	var peers: Array = c.peers
	var timeout := float(cf.get_value("case", "peer_timeout", 30.0))
	var notes: Array = c.notes
	var problems := []
	var outputs := []
	for i in peers.size():
		var text := FileAccess.get_file_as_string(c.outs[i])
		var label := "peer %d (%s)" % [i, peers[i]]
		var m := RegEx.create_from_string("\\[peer exit (\\d+)\\]").search(text)
		var want_exit := int(cf.get_value("case", "expect_peer%d_exit" % i, 0))
		if m == null:
			problems.append("%s: still running after %d s (stopped)" % [label, int(timeout)])
		elif int(m.get_string(1)) != want_exit:
			problems.append("%s: exit code %s, expected %d" % [label, m.get_string(1), want_exit])
		for piece in cf.get_value("case", "expect_peer%d_contains" % i, []):
			if not text.contains(str(piece)):
				problems.append("%s: output has no '%s'" % [label, piece])
		var from := 0
		for piece in cf.get_value("case", "expect_peer%d_order" % i, []):
			var at := text.find(str(piece), from)
			if at < 0:
				problems.append("%s: output has no '%s' after the pieces before it" % [label, piece])
				break
			from = at + str(piece).length()
		for piece in cf.get_value("case", "expect_peer%d_missing" % i, []):
			if text.contains(str(piece)):
				problems.append("%s: output has '%s', it shouldn't" % [label, piece])
		outputs.append("%s output:\n%s" % [label, text.strip_edges().indent("    ")])
	if not problems.is_empty():
		notes.append_array(outputs)  # (every peer's: one's problem is often another's doing)
	_finish(str(c.name), problems, notes)


## How long the case under way took ("4.2 s, compile 1.1 s"); kept for the report.
func _took(name: String) -> String:
	var ms := Time.get_ticks_msec() - _case_start
	_times.append([name, ms, _compile_ms])
	return "%.1f s%s" % [ms / 1000.0, (", compile %.1f s" % (_compile_ms / 1000.0)) if _compile_ms > 0 else ""]


func _finish(name: String, problems: Array, notes: Array) -> void:
	if problems.is_empty():
		print("  ok    ", name, "  (", _took(name), ")")
		_lines.append("- ✅ **%s**" % name)
		for n in notes:
			_lines.append("  - " + n.replace("\n", "\n    "))
	else:
		_fail(name, problems, notes)


func _skip(name: String, why: String) -> void:
	print("  skip  ", name, " (", why, ")")
	_lines.append("- ⏭️ **%s**: skipped, %s" % [name, why])


func _fail(name: String, problems: Array, notes: Array) -> void:
	_failed += 1
	print("  FAIL  ", name, "  (", _took(name), ")")
	for p in problems:
		print("        ", p)
	_lines.append("- ❌ **%s**" % name)
	for p in problems + notes:
		_lines.append("  - " + str(p).replace("\n", "\n    "))


static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path) or not path.contains("test_build"):
		return
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


static func _diff(want: String, got: String) -> String:
	var a := want.split("\n")
	var b := got.split("\n")
	var out := PackedStringArray()
	for i in maxi(a.size(), b.size()):
		var x: String = a[i] if i < a.size() else "(nothing)"
		var y: String = b[i] if i < b.size() else "(nothing)"
		if x != y:
			out.append("    line %d: expected %s, got %s" % [i + 1, x.c_escape(), y.c_escape()])
		if out.size() >= 8:
			out.append("    ...")
			break
	return "\n".join(out)


## API.md has an entry ("#### `type`: Title") for every brick in NodeDefs.DEFS.
func _check_api_md() -> void:
	var api := FileAccess.get_file_as_string("res://API.md")
	var missing := []
	for t in NodeDefs.DEFS:
		if not api.contains("#### `%s`:" % t):
			missing.append(t)
	if missing.is_empty():
		_finish("api_md", [], [])
	else:
		_fail("api_md", ["API.md has no entry for: %s (add \"#### `type`: Title\")" % ", ".join(missing)], [])


## The debugger's watches (CBWatches): values read back by type, expressions over them.
func _check_watches() -> void:
	var records := {"Pet": [["name", "string"], ["age", "int"], ["toys", "string list"]]}
	var vars := [
		["score", "int", "41"], ["speed", "float", "2.5"], ["over", "bool", "false"], ["who", "string", "Ada"],
		["pos", "vector3", "(1.5, 0.25, -3)"], ["nums", "int list", "[3, 1, 2]"], ["names", "string list", "[bob, cy]"],
		["ages", "int map", "{\"ada\": 36, \"bob\": 42}"], ["rex", "Pet", "Pet(name: \"Rex\", age: 3, toys: [ball, bone])"],
		["path", "vector3 list", "[(0, 0, 0), (1, 2, 3)]"], ["empty", "float list", "[]"], ["cut", "int list", "[1, 2, 3, 4..."],
	]
	var want := {
		"score + 1": "42", "score / 2": "20", "score % 5": "1", "speed * 2": "5", "!over && score > 40": "true",
		"who + \"!\"": "Ada!", "who == \"Ada\"": "true", "pos.x + pos.z": "-1.5", "pos": "(1.5, 0.25, -3)",
		"nums[2] * 10": "20", "nums.size()": "3", "len(names)": "2", "names[1]": "cy", "ages[\"bob\"]": "42",
		"ages.has(\"cy\")": "false", "rex.name": "Rex", "rex.toys[1]": "bone", "rex": "{\"name\": \"Rex\", \"age\": 3, \"toys\": [\"ball\", \"bone\"]}",
		"path[1].y": "2", "empty.size()": "0", "fmax(speed, 3)": "3", "sqrt(16.0)": "4", "max(score, 50)": "50",
		"cut": "[1, 2, 3, 4...",
	}
	var problems := []
	for src in want:
		var r := CBWatches.evaluate(src, vars, records)
		if not r.ok or r.text != want[src]:
			problems.append("%s -> %s (wanted %s)" % [src, r.text, want[src]])
	var bad := {"scroe + 1": "did you mean 'score'?", "nums[9]": "no item, key or field there", "ages[\"zed\"]": "no item, key or field there", "score +": "can't read it", "zzz": "no variable named 'zzz' here"}
	for src in bad:
		var r := CBWatches.evaluate(src, vars, records)
		if r.ok or not str(r.text).contains(bad[src]):
			problems.append("%s should fail with '%s', got ok=%s: %s" % [src, bad[src], r.ok, r.text])
	_finish("watches", problems, [])


## Every example generates its C without problems (they're what users open first).
func _check_examples() -> void:
	var problems := []
	for e in DirAccess.get_directories_at("res://examples"):
		var r := ProjectBuild.generate(ProjectSettings.globalize_path("res://examples/" + e))
		for err in r.errors:
			problems.append("%s: %s" % [e, err.msg])
	_finish("examples", problems, [])


## Variable dropdowns offer what's made before a brick in its chain (Brickscript's
## way), plus Globals, Constants and the function's inputs.
func _check_scopes() -> void:
	var N := func(i: int, t: String, fields: Dictionary, args: Dictionary, outs: Dictionary, links: Dictionary) -> Dictionary:
		var o := {}
		for k in outs:
			o[k] = {"var": outs[k], "use": false}
		return {"id": i, "type": t, "pos": [0, 0], "size": [0, 0], "fields": fields, "args": args, "outs": o, "links": links}
	var I := func(x: int) -> Dictionary: return {"type": "int", "value": str(x)}
	var g := {"format": "c-bricks", "version": 3, "next_id": 100, "nodes": [
		N.call(1, "start", {}, {}, {}, {"out": [2, 20]}),
		N.call(2, "print", {}, {"value": {"type": "string", "value": "first"}}, {}, {"next": [3]}),
		N.call(3, "var", {"mode": "Set", "name": "early", "scope": "Local"}, {"value": I.call(1)}, {}, {"next": [4]}),
		N.call(4, "for", {}, {"from": I.call(0), "to": I.call(3), "step": I.call(1)}, {"index": "i"}, {"loop": [5], "done": [6]}),
		N.call(5, "var", {"mode": "Set", "name": "in_loop", "scope": "Local"}, {"value": {"var": "i"}}, {}, {}),
		N.call(6, "if", {"operator": "is true"}, {"a": {"type": "bool", "value": "true"}}, {}, {"true": [7], "next": [8]}),
		N.call(7, "var", {"mode": "Set", "name": "branch", "scope": "Local"}, {"value": I.call(2)}, {}, {}),
		N.call(8, "print", {}, {"value": {"var": "branch"}}, {}, {}),
		N.call(20, "var", {"mode": "Set", "name": "later", "scope": "Local"}, {"value": I.call(5)}, {}, {}),
		N.call(30, "var", {"mode": "Set", "name": "shared", "scope": "Global"}, {"value": I.call(0)}, {}, {}),
		N.call(40, "function", {"name": "f", "returns": "void", "params": [["n", "int"]]}, {}, {}, {"out": [41]}),
		N.call(41, "print", {}, {"value": {"var": "n"}}, {}, {}),
		N.call(50, "constant", {"name": "LIMIT", "type": "int"}, {"value": I.call(9)}, {}, {}),
	]}
	var res := CodeGen.new().generate(g, {})
	var at := func(id: int) -> Array:
		var names: Array = res.scopes.get(id, {}).keys()
		names.sort()
		return names
	var want := {
		2: ["LIMIT", "shared"],                                  # first brick: nothing made yet
		3: ["LIMIT", "shared"],                                  # 'early' is made here, not before
		5: ["LIMIT", "early", "i", "shared"],                    # the loop body sees its index
		6: ["LIMIT", "early", "i", "in_loop", "shared"],         # after the loop (Done)
		8: ["LIMIT", "branch", "early", "i", "in_loop", "shared"],  # Next sees what True made
		20: ["LIMIT", "branch", "early", "i", "in_loop", "shared"],  # Output 2 sees Output 1's chain
		41: ["LIMIT", "n", "shared"],                            # a function: its input, no main locals
	}
	var problems := []
	for id in want:
		var got: Array = at.call(id)
		if got != want[id]:
			problems.append("brick %d offers %s, wanted %s" % [id, got, want[id]])
	# Reading a variable before its chain makes it: a warning naming the brick.
	var early := {"format": "c-bricks", "version": 3, "next_id": 10, "nodes": [
		N.call(1, "start", {}, {}, {}, {"out": [2]}),
		N.call(2, "print", {}, {"value": {"var": "x"}}, {}, {"next": [3]}),
		N.call(3, "var", {"mode": "Set", "name": "x"}, {"value": I.call(5)}, {}, {}),
	]}
	var r2 := CodeGen.new().generate(early, {})
	if not r2.warnings.any(func(w): return int(w.node) == 2 and str(w.msg).contains("'x' isn't made before this brick")):
		problems.append("reading 'x' before it's made gives no warning: %s" % [r2.warnings])
	# Chain variables stay in their event / function unless made Shared.
	for kind in ["Chain", "Shared", "output Shared"]:
		var set_brick: Dictionary = N.call(3, "var", {"mode": "Set", "name": "hp", "scope": kind if kind != "output Shared" else "Chain"}, {"value": I.call(5)}, {}, {})
		if kind == "output Shared":
			set_brick = N.call(3, "random", {}, {"min": I.call(1), "max": I.call(9)}, {}, {})
			set_brick.outs = {"result": {"var": "hp", "use": false, "kind": "Shared"}}
		var two := {"format": "c-bricks", "version": 3, "next_id": 20, "nodes": [
			N.call(1, "start", {}, {}, {}, {"out": [3, 4]}),
			set_brick,
			N.call(4, "call", {"function": "show"}, {}, {}, {}),
			N.call(10, "function", {"name": "show", "returns": "void", "params": []}, {}, {}, {"out": [11]}),
			N.call(11, "print", {}, {"value": {"var": "hp"}}, {}, {}),
		]}
		var r3 := CodeGen.new().generate(two, {})
		var refused: bool = r3.errors.any(func(e): return int(e.node) == 11 and str(e.msg).contains("chain variable of another event or function"))
		if (kind == "Chain") != refused:
			problems.append("a function reading main's %s variable: %s" % [kind, "refused" if refused else "allowed"] + " %s" % [r3.errors])
	_finish("scopes", problems, [])


## Every brick is used in its palette group's suite, and every mode of a family brick
## (its Mode / Do / Operation setting) too: a new brick or mode needs a test.
func _check_coverage() -> void:
	var used := {}   # group -> {type: {mode values}}
	var problems := []
	for g in NodeDefs.DEFS.values().map(func(d): return str(d.get("cat", ""))):
		if used.has(g):
			continue
		used[g] = {}
		var dir := ProjectSettings.globalize_path("%s/%s" % [SUITES, g])
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for p in CBProject.list_scripts(dir):
			for n in CBProject.read_script(p).get("nodes", []):
				var t := str(n.get("type", ""))
				if not used[g].has(t):
					used[g][t] = {}
				var def: Dictionary = NodeDefs.DEFS.get(t, {})
				if def.has("mode"):
					used[g][t][str(n.get("fields", {}).get(def.mode, ""))] = true
	for t in NodeDefs.DEFS:
		var def: Dictionary = NodeDefs.DEFS[t]
		var g := str(def.get("cat", ""))
		if not used[g].has(t):
			problems.append("%s (%s): not in tests/suites/%s" % [def.title, t, g])
			continue
		if def.has("mode"):
			for f in def.get("fields", []):
				if f[0] == def.mode:
					for option in f[3]:
						if not used[g][t].has(str(option)):
							problems.append("%s: its %s '%s' isn't used in tests/suites/%s" % [def.title, f[4], option, g])
	_finish("coverage", problems, [])


## (FileAccess.file_exists is false for a socket: X's display sockets are sockets.)
static func _is_socket(path: String) -> bool:
	return OS.execute("test", ["-S", path]) == 0


## Stops our Xvfb with SIGTERM (OS.kill's SIGKILL would leave its socket and lock behind).
func _stop_virtual_display() -> void:
	if _xvfb_pid <= 0:
		return
	OS.execute("kill", [str(_xvfb_pid)])
	for i in 30:
		if not OS.is_process_running(_xvfb_pid):
			break
		OS.delay_msec(100)
	_xvfb_pid = -1


## Lower priority for this process and everything it starts (nice 19, I/O idle), and a
## small software renderer: the tests yield to whatever else the machine is doing.
func _be_kind() -> void:
	var pid := str(OS.get_process_id())
	OS.execute("renice", ["-n", "19", "-p", pid])
	OS.execute("ionice", ["-c", "3", "-p", pid])
	OS.set_environment("LP_NUM_THREADS", "2")


## The case's program: reused from the cache when its C (every source and header), the
## compile flags and raylib's parts are the same as last time; else compiled (each .c in
## parallel, then linked) and kept. Gives Toolchains.compile's shape.
func _compile_cached(name: String, srcs: Array, work: String, rl: Dictionary) -> Dictionary:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update((" ".join(STRICT_FLAGS) + "|" + JSON.stringify(rl.get("objs", [])) + "|" + JSON.stringify(rl.get("flags", []))).to_utf8_buffer())
	var src_dir := work.path_join("src")
	for f in DirAccess.get_files_at(src_dir):  # (sources and cbricks.h: everything they include)
		ctx.update(f.to_utf8_buffer())
		ctx.update(FileAccess.get_file_as_bytes(src_dir.path_join(f)))
	var key := ctx.finish().hex_encode().substr(0, 16)
	var cdir := ProjectSettings.globalize_path(CACHE).path_join(name)
	var kept := cdir.path_join(key)
	var out := work.path_join("prog")
	if FileAccess.file_exists(kept.path_join("prog")):
		DirAccess.copy_absolute(kept.path_join("prog"), out)
		OS.execute("chmod", ["+x", out])
		_cached += 1
		return {"ok": true, "exit": 0, "output": FileAccess.get_file_as_string(kept.path_join("output.txt")), "command": "(cached)", "out": out}
	var built := _compile_parallel(srcs, work, rl)
	if built.ok:
		_remove_tree(cdir)  # (one program kept per case)
		DirAccess.make_dir_recursive_absolute(kept)
		DirAccess.copy_absolute(out, kept.path_join("prog"))
		var fo := FileAccess.open(kept.path_join("output.txt"), FileAccess.WRITE)
		fo.store_string(str(built.output))
		fo.close()
	return built


## cc -c on every source at once (4 cores: they finish together), then one link.
func _compile_parallel(srcs: Array, work: String, rl: Dictionary) -> Dictionary:
	var obj_dir := work.path_join("obj")
	_remove_tree(obj_dir)
	DirAccess.make_dir_recursive_absolute(obj_dir)
	var cflags := PackedStringArray(STRICT_FLAGS)
	var lflags := PackedStringArray()
	for f in rl.get("flags", []):  # raylib's: -I / -D compile, the rest (libraries) link
		var fs := str(f)
		if fs.begins_with("-I") or fs.begins_with("-D") or (cflags.size() > 0 and cflags[-1] == "-I"):
			cflags.append(fs)
		else:
			lflags.append(fs)
	var pids := []
	var objs := PackedStringArray()
	for src in srcs:
		var obj := obj_dir.path_join(str(src).get_file().get_basename() + ".o")
		objs.append(obj)
		var sh := PackedStringArray(["-c", "log=\"$1\"; shift; \"$@\" > \"$log\" 2>&1; echo $? >> \"$log.code\"", "sh", obj + ".log", "cc"])
		sh.append_array(cflags)
		sh.append_array(["-c", str(src), "-o", obj])
		pids.append(OS.create_process("/bin/sh", sh))
	var waited := 0
	while pids.any(func(pid): return OS.is_process_running(pid)) and waited < 300000:
		OS.delay_msec(20)
		waited += 20
	var text := ""
	var ok := true
	for obj in objs:
		text += FileAccess.get_file_as_string(obj + ".log")
		if FileAccess.get_file_as_string(obj + ".log.code").strip_edges() != "0":
			ok = false
	var out := work.path_join("prog")
	if not ok:
		return {"ok": false, "exit": 1, "output": text, "command": "cc (parallel)", "out": out}
	var argv := PackedStringArray(objs)
	argv.append_array(PackedStringArray(rl.get("objs", [])))
	argv.append_array(["-o", out])
	argv.append_array(lflags)
	argv.append("-lm")
	var lo := []
	var code := OS.execute("cc", argv, lo, true)
	text += "".join(lo)
	return {"ok": code == 0, "exit": code, "output": text, "command": "cc " + " ".join(argv), "out": out}


## A word for sh, single-quoted ('it'"'"'s' for a quote inside).
static func _sq(word: String) -> String:
	return "'" + word.replace("'", "'\"'\"'") + "'"


## A project from before the rename (2026-11-07: C-Nodes -> C-Bricks): Net Gems turned back
## into the old names (project.cnproj, .cnodes, .cnscene, "c-nodes" formats) in a copy,
## upgraded by CBProject.upgrade_names, then built with no problems.
func _check_old_names() -> void:
	var dir := OS.get_user_data_dir().path_join("test_build/old_names")
	_remove_tree(dir)
	CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/net_gems"), dir)
	var made := []
	_old_files_of(dir, made)
	var problems := []
	if not FileAccess.file_exists(dir.path_join("project.cnproj")):
		problems.append("couldn't make the old-style copy")
	if not CBProject.is_project(dir):
		problems.append("an old project (project.cnproj) isn't seen as a project")
	if not CBProject.upgrade_names(dir):
		problems.append("upgrade_names did nothing")
	var left := []
	_old_files_of(dir, left, true)
	if not left.is_empty():
		problems.append("old-named files left: %s" % [left])
	var hero := FileAccess.get_file_as_string(dir.path_join("scenes/hero.cbscene"))
	if not hero.contains("scripts/welcome.cbricks") or hero.contains(".cnodes"):
		problems.append("the Hero scene's Script object still names the old file")
	var r := ProjectBuild.generate(dir)
	if not r.errors.is_empty():
		problems.append("the upgraded project has problems: %s" % [r.errors.map(func(e): return e.msg)])
	_finish("old_names", problems, [])


## Renames a project's files to the old names (or, `only_list`, lists the old-named ones).
func _old_files_of(path: String, out: Array, only_list := false) -> void:
	for f in DirAccess.get_files_at(path):
		var full := path.path_join(f)
		if only_list:
			if f.get_extension() in ["cnodes", "cnscene"] or f == "project.cnproj":
				out.append(f)
			continue
		var to := ""
		match f.get_extension():
			"cbricks": to = f.get_basename() + ".cnodes"
			"cbscene": to = f.get_basename() + ".cnscene"
			"cbproj": to = "project.cnproj"
		if to == "":
			continue
		var text := FileAccess.get_file_as_string(full).replace(".cbricks", ".cnodes").replace(".cbscene", ".cnscene").replace("\"c-bricks", "\"c-nodes")
		var fa := FileAccess.open(path.path_join(to), FileAccess.WRITE)
		fa.store_string(text)
		fa.close()
		DirAccess.remove_absolute(full)
		out.append(to)
	for d in DirAccess.get_directories_at(path):
		if not d.begins_with("."):
			_old_files_of(path.path_join(d), out, only_list)


## A new project (user, 2026-11-07: no main script made for it): settings and assets/ only,
## and it builds without problems (the build's own main(): cbricks_main.c).
## The editor's bundled toolchains (<editor folder>/toolchains, or CBRICKS_TOOLCHAINS): searched before PATH and
## the usual folders, so a copy of zig / DJGPP / DOSBox-X beside the editor wins; a program there is found.
func _check_bundle() -> void:
	var problems := []
	var dir := OS.get_user_data_dir().path_join("test_build/bundle")
	_remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir.path_join("zig"))
	var fa := FileAccess.open(dir.path_join("zig/zig"), FileAccess.WRITE)
	fa.store_string("#!/bin/sh\n")
	fa.close()
	OS.set_environment("CBRICKS_TOOLCHAINS", dir)
	Toolchains.clear_cache()
	var found := Toolchains.find_program("zig")
	var dirs := Toolchains.search_dirs()
	if Toolchains.bundle_dir() != dir:
		problems.append("bundle_dir should be CBRICKS_TOOLCHAINS (%s), got %s" % [dir, Toolchains.bundle_dir()])
	if dirs.size() < 4 or dirs[0] != dir.path_join("zig") or dirs[1] != dir.path_join("djgpp/bin") or dirs[2] != dir.path_join("dosbox-x"):
		problems.append("the bundle's folders should come first in search_dirs, got %s" % str(dirs.slice(0, 4)))
	if found != dir.path_join("zig/zig"):
		problems.append("a zig in the bundle should be found before any other, got '%s'" % found)
	OS.set_environment("CBRICKS_TOOLCHAINS", "")
	Toolchains.clear_cache()
	if Toolchains.search_dirs()[0] == dir.path_join("zig"):
		problems.append("without the bundle the folders are PATH's")
	_remove_tree(dir)
	_finish("bundle", problems, [])


## Unpacking the toolchains from inside the editor (a small zip stands in for the real pack): files written,
## the listed ones executable, the folder marked, an interrupted .part replaced.
func _check_unpack() -> void:
	var problems := []
	var base := OS.get_user_data_dir().path_join("toolchains/test_build_unpack")
	Toolchains._rm_tree(base)
	DirAccess.make_dir_recursive_absolute(base)
	var stage := base.path_join("stage")
	for e in [["zig/zig", "#!/bin/sh\necho zig\n"], ["djgpp/bin/gcc", "x"], ["README.md", "hi"]]:
		DirAccess.make_dir_recursive_absolute(stage.path_join(str(e[0])).get_base_dir())
		var w := FileAccess.open(stage.path_join(str(e[0])), FileAccess.WRITE)
		w.store_string(e[1])
		w.close()
	FileAccess.set_unix_permissions(stage.path_join("zig/zig"), 493)
	FileAccess.set_unix_permissions(stage.path_join("djgpp/bin/gcc"), 493)
	var made := []
	if OS.execute("python3", ["-I", ProjectSettings.globalize_path("res://tools/make_toolchain_pack.py"), stage, base.path_join("pack")], made) != 0:
		problems.append("the packer failed: " + str(made))
	var dest := base.path_join("out")
	DirAccess.make_dir_recursive_absolute(dest + ".part")  # (a leftover of an interrupted unpack)
	var f := FileAccess.open(dest + ".part/stale", FileAccess.WRITE)
	f.close()
	var steps := [0]
	var err := Toolchains.unpack(func(_d: int, _t: int, _w: String) -> void: steps[0] += 1, base.path_join("pack/toolchains.pak"), dest)
	if err != "":
		problems.append("unpack failed: " + err)
	if not FileAccess.file_exists(dest.path_join(".unpacked")) or FileAccess.get_file_as_string(dest.path_join("zig/zig")) != "#!/bin/sh\necho zig\n":
		problems.append("the files and the .unpacked mark should be there")
	if FileAccess.file_exists(dest.path_join("stale")) or DirAccess.dir_exists_absolute(dest + ".part"):
		problems.append("an interrupted unpack's leftovers should be gone")
	if FileAccess.get_unix_permissions(dest.path_join("zig/zig")) & 64 == 0 or FileAccess.get_unix_permissions(dest.path_join("djgpp/bin/gcc")) & 64 == 0:
		problems.append("the listed files should be executable")
	if FileAccess.get_unix_permissions(dest.path_join("README.md")) & 64 != 0:
		problems.append("an unlisted file shouldn't be")
	if steps[0] < 1:
		problems.append("progress should be reported")
	err = Toolchains.unpack(Callable(), base.path_join("pack/toolchains.pak"), dest)  # (again, over a marked folder)
	if err != "":
		problems.append("unpacking over an earlier unpack failed: " + err)
	Toolchains._rm_tree(base)
	if DirAccess.dir_exists_absolute(base):
		problems.append("the removal should take hidden files (.unpacked) too")
	_finish("unpack", problems, [])


## The Toolchains window's engine (ToolchainManager) against a local web server: a small .tar.xz is downloaded
## with progress, checked, unpacked into the installed folder (search_dirs sees it), removed; a wrong sha256, a
## missing file (404) and a tool with no download for this computer each fail with a message and install nothing.
func _check_toolchain_install() -> void:
	var problems := []
	var base := OS.get_user_data_dir().path_join("toolchains/test_installed_src")
	Toolchains._rm_tree(base)
	var served := base.path_join("served")
	DirAccess.make_dir_recursive_absolute(served)
	DirAccess.make_dir_recursive_absolute(base.path_join("stage/fake-1/bin"))
	var w := FileAccess.open(base.path_join("stage/fake-1/bin/fakeprog"), FileAccess.WRITE)
	w.store_string("#!/bin/sh\necho fake\n")
	w.close()
	var out := []
	if OS.execute("tar", ["-C", base.path_join("stage"), "-cJf", served.path_join("fake.tar.xz"), "fake-1"], out, true) != 0:
		_finish("toolchain_install", ["tar couldn't make the test archive: " + str(out)], [])
		return
	var port := 18765
	var server := OS.create_process("python3", ["-I", "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", served])
	await create_timer(1.0).timeout
	var plat := ToolchainManager.platform()
	var good := {"url": "http://127.0.0.1:%d/fake.tar.xz" % port, "sha256": FileAccess.get_sha256(served.path_join("fake.tar.xz")), "size": FileAccess.get_file_as_bytes(served.path_join("fake.tar.xz")).size(), "strip": 1}
	var bad_sha: Dictionary = good.duplicate()
	bad_sha.sha256 = "0".repeat(64)
	var missing: Dictionary = good.duplicate()
	missing.url = "http://127.0.0.1:%d/nothing.tar.xz" % port
	var manifest := {"format": 1, "tools": {
		"zig": {"version": "9.9", "platforms": {plat: good}},
		"djgpp": {"version": "1", "platforms": {plat: bad_sha}},
		"dosbox-x": {"version": "1", "platforms": {plat: missing}},
		"cmake": {"version": "1", "platforms": {}}}}
	var mf := FileAccess.open(base.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_string(JSON.stringify(manifest))
	mf.close()
	OS.set_environment("CBRICKS_TOOLCHAIN_MANIFEST", base.path_join("manifest.json"))
	ToolchainManager.root_override = OS.get_user_data_dir().path_join("toolchains/test_installed")
	Toolchains._rm_tree(ToolchainManager.root_override)
	var mgr := ToolchainManager.new()
	root.add_child(mgr)
	var seen := [0, ""]
	mgr.progress.connect(func(_id: String, _d: int, _t: int, what: String) -> void:
		seen[0] += 1
		seen[1] = what)
	# 1. a good install
	mgr.install("zig")
	var r: Array = await mgr.finished
	if r[1] != "":
		problems.append("the good install failed: " + str(r[1]))
	var st := ToolchainManager.status("zig")
	if st.state != "installed" or st.version != "9.9":
		problems.append("after installing, zig should be 'installed' 9.9, got " + str(st))
	if not FileAccess.file_exists(ToolchainManager.root_override.path_join("zig/bin/fakeprog")):
		problems.append("the archive's files (top folder stripped) should be in installed/zig")
	if ToolchainManager.root_override.path_join("zig") not in Array(Toolchains.search_dirs()):
		problems.append("search_dirs should list the installed zig")
	if seen[0] < 1:
		problems.append("progress should be reported")
	if FileAccess.file_exists(ToolchainManager.downloads_dir().path_join("fake.tar.xz")):
		problems.append("the downloaded archive should be deleted afterwards")
	# 2. removal
	mgr.remove("zig")
	await mgr.finished
	if DirAccess.dir_exists_absolute(ToolchainManager.root_override.path_join("zig")) or ToolchainManager.status("zig").state == "installed":
		problems.append("Remove should delete the installed folder")
	# 3. failures
	for c in [["djgpp", "sha256"], ["dosbox-x", "404"], ["cmake", "no download"]]:
		mgr.install(c[0])
		var f: Array = await mgr.finished
		if f[1] == "" or not (str(f[1]).to_lower().contains(c[1]) or (c[1] == "no download" and str(f[1]).contains("no download"))):
			problems.append("%s should fail mentioning '%s', got '%s'" % [c[0], c[1], f[1]])
		if ToolchainManager.status(c[0]).state == "installed" or DirAccess.dir_exists_absolute(ToolchainManager.root_override.path_join(c[0])):
			problems.append("%s must not be installed after failing" % c[0])
	mgr.queue_free()
	OS.kill(server)
	OS.set_environment("CBRICKS_TOOLCHAIN_MANIFEST", "")
	Toolchains._rm_tree(ToolchainManager.root_override)
	ToolchainManager.root_override = ""
	Toolchains._rm_tree(base)
	# the real manifest: every download has an https URL, a sha256 and a size (2026-11-10: other computers' entries are pinned by hand)
	var sha_re := RegEx.create_from_string("^[0-9a-f]{64}$")
	var manifest_tools := ToolchainManager.manifest().get("tools", {}) as Dictionary
	for mid in ["zig", "djgpp", "dosbox-x", "emscripten", "cmake"]:
		if not manifest_tools.has(mid):
			problems.append("manifest has no %s" % mid)
			continue
		for mplat in ((manifest_tools[mid] as Dictionary).get("platforms", {}) as Dictionary):
			var ment: Dictionary = manifest_tools[mid].platforms[mplat]
			if not str(ment.get("url", "")).begins_with("https://") or sha_re.search(str(ment.get("sha256", ""))) == null or int(ment.get("size", 0)) <= 0:
				problems.append("manifest %s / %s: needs an https url, a 64-digit sha256 and a size" % [mid, mplat])
	for mplat in ["x86_64-linux", "x86_64-windows", "aarch64-windows", "x86_64-macos", "aarch64-macos"]:
		if not (manifest_tools.get("djgpp", {}).get("platforms", {}) as Dictionary).has(mplat):
			problems.append("manifest: DJGPP has no download for %s" % mplat)
	_finish("toolchain_install", problems, [])


func _check_new_project() -> void:
	var parent := OS.get_user_data_dir().path_join("test_build/new_project")
	_remove_tree(parent)
	DirAccess.make_dir_recursive_absolute(parent)
	var dir := CBProject.create(parent, "Fresh")
	var problems := []
	if dir == "":
		problems.append("CBProject.create failed: " + CBProject.last_error)
	elif not CBProject.list_scripts(dir).is_empty():
		problems.append("a new project has scripts: %s" % [CBProject.list_scripts(dir)])
	else:
		var r := ProjectBuild.generate(dir)
		if not r.errors.is_empty():
			problems.append("it has problems: %s" % [r.errors.map(func(e): return e.msg)])
		elif not r.files.has("cbricks_main.c"):
			problems.append("no main() of the build's own (cbricks_main.c)")
	_finish("new_project", problems, [])


## The editor's UI boxes (WorldValues.ui_box: the 2D screen, picking) are the runtime's
## (cb_ui_box): ui_containers' scene, the numbers its --click relies on.
func _check_ui_layout() -> void:
	var dir := ProjectSettings.globalize_path("res://tests/cases/ui_containers")
	ProjectBuild.generate(dir)  # (the project's classes: Menu extends VBox)
	var ids := WorldValues.by_id(CBProject.read_scene(dir.path_join("main.cbscene")))
	var want := {"MenuBack": Rect2(10, 35, 152, 130), "Play": Rect2(16, 41, 140, 30), "Quit": Rect2(16, 77, 140, 30), "Footer": Rect2(16, 113, 140, 14),
		"Red": Rect2(192, 8, 24, 24), "Green": Rect2(220, 8, 24, 30), "Blue": Rect2(248, 8, 40, 24)}
	var problems := []
	for o in ids.values():
		var box := WorldValues.ui_box(o, ids, Vector2(320, 200)) if WorldValues.is_ui(o) else {}
		if want.has(str(o.name)) and (box.get("rect") as Rect2) != want[str(o.name)]:
			problems.append("%s: %s, the runtime's is %s" % [o.name, box.get("rect"), want[str(o.name)]])
		if str(o.name) == "Options" and bool(box.get("shown", true)):
			problems.append("Options is hidden: it shouldn't be shown")
	_finish("ui_layout", problems, [])


## The app's build cache (Toolchains.cached_build; user, 2026-11-08): a project compiles once,
## then (unchanged) is reused, also after it's generated again as a reload does; a change
## compiles again; a copy elsewhere reuses the shared cache; an example's fresh copy has the
## fingerprint wherever it's copied (what res://prebuilt, made on export, relies on).
## MS-DOS (2026-11-08): what it can't do is a problem naming each brick / object; text programs
## build with DJGPP and run in DOSBox-X (no window), their output as on this computer.
## xdotool -> the DOSBox-X window: one command; returns its output.
func _xdo(args: Array) -> String:
	var out := []
	OS.execute("xdotool", PackedStringArray(args), out, true)
	return "".join(out).strip_edges()


## The keyboard and mouse on MS-DOS, for real: DOSBox-X runs on the runner's Xvfb with SDL's X11 driver, xdotool
## sends X events (XTEST: they reach the emulated keyboard controller and the INT 33h mouse), and tests/dos/input
## prints what the program saw each frame.
func _check_dos_input() -> void:
	var problems := []
	var notes := []
	if Toolchains.resolve_command("dos") == "" or Toolchains.find_program("dosbox-x") == "" or not Toolchains.has_program("xdotool") or not Toolchains.has_program("Xvfb"):
		_skip("dos_input", "DJGPP, DOSBox-X, xdotool or Xvfb isn't installed")
		return
	var dir := OS.get_user_data_dir().path_join("test_build/dos_input")
	_remove_tree(dir)
	CBProject.copy_dir(ProjectSettings.globalize_path("res://tests/dos/input"), dir)
	var r := ProjectBuild.generate(dir, {}, "dos")
	if not r.errors.is_empty():
		_fail("dos_input", ["generate: " + str(r.errors.map(func(e): return e.msg))], notes)
		return
	var srcs := ProjectBuild.write(r, dir.path_join(".build/src"))
	var b := Toolchains.cached_build("dos", srcs, dir.path_join(".build/dos"), CBProject.program_name(dir), "", true)
	if not b.ok:
		_fail("dos_input", ["build: " + str(b.output).left(2000)], notes)
		return
	var run := Toolchains.dos_run(b.out, PackedStringArray(), dir, true)
	var argv := PackedStringArray(["-u", "WAYLAND_DISPLAY", "SDL_VIDEODRIVER=x11", "SDL_AUDIODRIVER=dummy", "nice", "-n", "19", run.prog]) + PackedStringArray(run.argv) + PackedStringArray(["-set", "sdl autolock=false"])
	var pid := OS.create_process("env", argv)
	var win := ""
	for i in 150:  # (up to 15 s for DOSBox-X's window)
		win = _xdo(["search", "--onlyvisible", "--name", "DOSBox"]).get_slice("\n", 0)
		if win != "":
			break
		OS.delay_msec(100)
	if win == "":
		OS.kill(pid)
		_fail("dos_input", ["DOSBox-X's window never appeared"], notes)
		return
	_xdo(["windowfocus", win])
	OS.delay_msec(5000)   # (the DOS prompt, the program, its window)
	var geo := _xdo(["getwindowgeometry", "--shell", win])
	_xdo(["mousemove", "--window", win, "160", "100"])
	OS.delay_msec(500)
	for k in ["a", "space", "Up", "Return", "Shift_L", "F5", "Control_L"]:  # (a key down for 0.3 s each, a gap between)
		_xdo(["keydown", k])
		OS.delay_msec(300)
		_xdo(["keyup", k])
		OS.delay_msec(300)
	for k in ["a", "Up"]:  # (two held together)
		_xdo(["keydown", k])
	OS.delay_msec(300)
	for k in ["a", "Up"]:
		_xdo(["keyup", k])
	OS.delay_msec(300)
	_xdo(["mousemove_relative", "--", "40", "20"])
	OS.delay_msec(300)
	_xdo(["mousemove_relative", "--", "-80", "-50"])
	OS.delay_msec(300)
	for btn in ["1", "3"]:
		_xdo(["mousedown", btn])
		OS.delay_msec(300)
		_xdo(["mouseup", btn])
		OS.delay_msec(300)
	_xdo(["click", "4"])
	OS.delay_msec(300)
	_xdo(["click", "5"])
	OS.delay_msec(300)
	_xdo(["key", "q"])
	for i in 100:
		if not OS.is_process_running(pid):
			break
		OS.delay_msec(100)
	if OS.is_process_running(pid):
		OS.kill(pid)
		problems.append("MS-DOS input: the program didn't close on Q (keys didn't reach it?)")
	var rows := []
	for ln in Toolchains.dos_output(run).split("\n"):
		if ln.begins_with("[in] "):
			rows.append(ln.substr(5).split(" "))
	notes.append("window %s; %d frames printed" % [geo.replace("\n", " "), rows.size()])
	# columns: 0 A, 1 SPACE pressed, 2 SPACE released, 3 UP, 4 ENTER, 5 SHIFT, 6 F5, 7 CTRL, 8 mouse left, 9 mouse clicked, 10 mouse right, 11 x, 12 y, 13 wheel
	var names := ["A down", "SPACE pressed", "SPACE released", "UP down", "ENTER down", "LEFT SHIFT down", "F5 down", "LEFT CONTROL down", "mouse left down", "mouse left clicked", "mouse right down"]
	for c in names.size():
		var seen := rows.filter(func(row): return row.size() > 13 and row[c] == "true").size()
		notes.append("%s: true in %d frame(s)" % [names[c], seen])
		if seen == 0:
			problems.append("MS-DOS input: %s was never seen" % names[c])
	var both := rows.filter(func(row): return row.size() > 13 and row[0] == "true" and row[3] == "true").size()
	if both == 0:
		problems.append("MS-DOS input: A and UP held together were never both down")
	var xs := rows.filter(func(row): return row.size() > 13).map(func(row): return int(row[11]))
	var ys := rows.filter(func(row): return row.size() > 13).map(func(row): return int(row[12]))
	if xs.is_empty() or xs.max() - xs.min() < 10 or ys.max() - ys.min() < 5:
		problems.append("MS-DOS input: the pointer's position didn't move (x %s, y %s)" % [str([xs.min(), xs.max()]) if not xs.is_empty() else "-", str([ys.min(), ys.max()]) if not ys.is_empty() else "-"])
	else:
		notes.append("pointer x %d..%d, y %d..%d" % [xs.min(), xs.max(), ys.min(), ys.max()])
	# The wheel isn't driven: SDL on Xvfb drops XTEST's wheel clicks (checked: not even DOSBox-X's own wheel-to-arrow
	# option saw them). DOSBox-X does offer the wheel API the backend asks for (AX=11h answers "WM", CX bit 0).
	_finish("dos_input", problems, notes)


## Networking on MS-DOS: a native server (a normal process) and net_join's client built for MS-DOS (Watt-32 over the
## packet driver NE2000.COM, DOSBox-X's NE2000 on its built-in NAT: the host is 10.0.2.2) join each other, both ways:
## the DOS client joins the native server, and a native client joins the DOS server through a forwarded UDP port.
func _check_dos_net() -> void:
	var problems := []
	var notes := []
	if Toolchains.resolve_command("dos") == "" or Toolchains.find_program("dosbox-x") == "" or not FileAccess.file_exists(Toolchains.WATT_LIB):
		_skip("dos_net", "DJGPP or DOSBox-X isn't installed")
		return
	var dir := OS.get_user_data_dir().path_join("test_build/dos_net")
	_remove_tree(dir)
	CBProject.copy_dir(ProjectSettings.globalize_path("res://tests/cases/net_join"), dir)
	var r := ProjectBuild.generate(dir, {}, "dos")
	if not r.errors.is_empty() or not ProjectBuild.target_problems(r, "dos").is_empty():
		_fail("dos_net", ["MS-DOS target problems: %s" % str(r.errors.map(func(e): return e.msg) + ProjectBuild.target_problems(r, "dos").map(func(e): return e.msg))], notes)
		return
	var srcs := ProjectBuild.write(r, dir.path_join(".build/src"))
	var b := Toolchains.cached_build("dos", srcs, dir.path_join(".build/dos"), CBProject.program_name(dir), "", false)
	if not b.ok:
		_fail("dos_net", ["didn't build for MS-DOS:\n" + str(b.output).left(3000)], notes)
		return
	var nr := ProjectBuild.generate(dir, {}, "native")
	var nsrcs := ProjectBuild.write(nr, dir.path_join(".build/nsrc"))
	var nb := Toolchains.cached_build("native", nsrcs, dir.path_join(".build/native"), CBProject.program_name(dir), "", false)
	if not nb.ok:
		_fail("dos_net", ["native build failed:\n" + str(nb.output).left(2000)], notes)
		return
	# 1) the DOS client joins a native server (the server's port is on the host: 10.0.2.2 from DOSBox-X)
	var sout := dir.path_join("server.txt")
	var spid := OS.create_process("sh", PackedStringArray(["-c", "exec \"%s\" --server 47341 --stay 60 > \"%s\" 2>&1" % [nb.out, sout]]))
	OS.delay_msec(400)
	var run := Toolchains.dos_run(b.out, PackedStringArray(["--join", "10.0.2.2:47341", "--name", "dosa", "--stay", "4"]), dir, true)
	OS.execute("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "timeout", "90", "nice", "-n", "19", run.prog]) + PackedStringArray(run.argv), [], true)
	var got := Toolchains.dos_output(run)
	for want in ["[role] client", "[joined] dosa #2", "[done] client"]:
		if not got.contains(want):
			problems.append("the DOS client's output has no '%s':\n%s" % [want, got.left(1500)])
	OS.kill(spid)  # (its stay is long: DOSBox-X takes a while to start)
	var sgot := FileAccess.get_file_as_string(sout)
	if not sgot.contains("[joined] dosa #2"):
		problems.append("the native server never saw the DOS client join:\n%s" % sgot.left(1500))
	else:
		notes.append("a DOS client (Watt-32, NE2000 packet driver, DOSBox-X's NAT) joined a native server: it was player #2 on both")
	# 2) a native client joins the DOS server: DOSBox-X forwards the host's UDP port 47342 into the guest
	var run2 := Toolchains.dos_run(b.out, PackedStringArray(["--server", "47342", "--stay", "24"]), dir, true, "", "47342:47342")
	var dpid := OS.create_process("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "nice", "-n", "19", run2.prog]) + PackedStringArray(run2.argv))
	var cout := dir.path_join("client.txt")
	var joined := false
	for attempt in 6:  # (DOSBox-X boots, loads the driver, asks DHCP: the first tries can find nobody)
		OS.delay_msec(5000 if attempt == 0 else 3000)
		OS.execute("sh", PackedStringArray(["-c", "\"%s\" --join 127.0.0.1:47342 --name nat --stay 1.5 > \"%s\" 2>&1" % [nb.out, cout]]))
		if FileAccess.get_file_as_string(cout).contains("[role] client"):
			joined = true
			break
	for i in 150:
		if not OS.is_process_running(dpid):
			break
		OS.delay_msec(500)
	OS.kill(dpid)
	var cgot := FileAccess.get_file_as_string(cout)
	var dgot := Toolchains.dos_output(run2)
	if not joined or not dgot.contains("[joined] nat #2"):
		problems.append("a native client couldn't join the DOS server (forwarded UDP port). Client:\n%s\nDOS server:\n%s" % [cgot.left(800), dgot.left(800)])
	else:
		notes.append("a native client joined a DOS server through DOSBox-X's UDP port forward: player #2 on both")
	_finish("dos_net", problems, notes)


func _check_dos() -> void:
	var problems := []
	var notes := []
	var gfx := ProjectBuild.generate(ProjectSettings.globalize_path("res://examples/bouncing_ball"), {}, "dos")
	if not ProjectBuild.target_problems(gfx, "dos").is_empty():
		problems.append("a 2D project for MS-DOS: no target problems expected, got %s" % str(ProjectBuild.target_problems(gfx, "dos").map(func(e): return e.msg)))
	var g3 := ProjectBuild.generate(ProjectSettings.globalize_path("res://examples/bouncing_ball"), {}, "dos")
	if not g3.files.has("stb_image.h") or not str(g3.files.get("cbricks_backend.c", "")).contains("MS-DOS"):
		problems.append("a graphics project for MS-DOS carries the DOS backend and stb's headers")
	var w3 := ProjectBuild.generate(ProjectSettings.globalize_path("res://tests/cases/no_main_3d"), {}, "dos")
	var tp3 := ProjectBuild.target_problems(w3, "dos")
	if not tp3.is_empty():
		problems.append("a project with a 3D scene for MS-DOS: no target problems expected (it has a software 3D renderer), got %s" % str(tp3.map(func(e): return e.msg)))
	# the Graphics backend setting: Automatic follows the target; a backend the target can't use is a problem
	if ProjectBuild.resolve_backend("auto", "dos") != "dos" or ProjectBuild.resolve_backend("auto", "native") != "raylib" or ProjectBuild.resolve_backend("raylib", "dos") != "raylib":
		problems.append("resolve_backend: Automatic = dos for MS-DOS, else raylib; a named backend wins")
	if ProjectBuild.backend_problem("dos", "native") == "" or ProjectBuild.backend_problem("raylib", "dos") == "" or ProjectBuild.backend_problem("dos", "dos") != "" or ProjectBuild.backend_problem("raylib", "native") != "":
		problems.append("backend_problem: dos only on the MS-DOS target, raylib anywhere but there")
	var bgd := ProjectBuild.generate_graphs("t", "1", "", PackedStringArray(), {}, "native", 0, "dos")
	if bgd.backend != "dos":
		problems.append("generate_graphs reports the backend it used")
	var an := ProjectBuild.generate(ProjectSettings.globalize_path("res://examples/net_gems"), {}, "dos")
	if not ProjectBuild.target_problems(an, "dos").is_empty():
		problems.append("a network project for MS-DOS (Watt-32): no problems expected, got %s" % str(ProjectBuild.target_problems(an, "dos").map(func(e): return e.msg)))
	if not ProjectBuild.target_problems(an, "linux-riscv64").any(func(e): return str(e.msg).contains("graphics")):
		problems.append("a graphics project for a target without raylib: problems naming graphics expected")
	if not ProjectBuild.target_problems(ProjectBuild.generate(ProjectSettings.globalize_path("res://examples/fizzbuzz")), "dos").is_empty():
		problems.append("a text project for MS-DOS: no target problems expected")
	if Toolchains.resolve_command("dos") == "" or Toolchains.find_program("dosbox-x") == "":
		if problems.is_empty():
			_skip("dos", "the problems are right; DJGPP (i586-pc-msdosdjgpp-gcc) or DOSBox-X isn't installed, so nothing was built for DOS")
		else:
			_fail("dos", problems, notes)
		return
	var root := OS.get_user_data_dir().path_join("test_build/dos")
	for c in [["hello_world", [], "Hello from C-Bricks!\n1\n2\n3\n4\n5\nDone!"], ["fizzbuzz", [], "13\n14\nFizzBuzz\n"], ["arguments_and_files", ["--name=Ada"], "Welcome! This line comes from assets/greeting.txt.\ncube.obj has this many lines: 16"], ["read_your_name", [], "What's your name? Hello, Ada Lovelace!", "Ada Lovelace\n"]]:
		var dir: String = root.path_join(c[0])
		_remove_tree(dir)
		CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/" + c[0]), dir)
		var r := ProjectBuild.generate(dir, {}, "dos")
		var srcs := ProjectBuild.write(r, dir.path_join(".build/src"))
		var t0 := Time.get_ticks_msec()
		var b := Toolchains.cached_build("dos", srcs, dir.path_join(".build/dos"), CBProject.program_name(dir), "", false)
		_compile_ms += Time.get_ticks_msec() - t0
		if not b.ok:
			problems.append("%s didn't build for MS-DOS:\n%s" % [c[0], str(b.output).strip_edges().left(3000)])
			continue
		var run := Toolchains.dos_run(b.out, PackedStringArray(c[1]), dir, true, str(c[3]) if c.size() > 3 else "")
		var out := []
		OS.execute("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "timeout", "120", "nice", "-n", "19", run.prog]) + PackedStringArray(run.argv), out, true)
		var got := Toolchains.dos_output(run)
		if not got.contains(str(c[2])):
			problems.append("%s in DOSBox-X: expected its output to contain %s, got:\n%s" % [c[0], JSON.stringify(c[2]), got.left(2000)])
		else:
			notes.append("%s: built (%s, %d bytes), ran in DOSBox-X" % [c[0], b.out.get_file(), FileAccess.get_file_as_bytes(b.out).size()])
	# the MS-DOS examples (tests/make_dos_examples.py): each has Target MS-DOS, no target problems, and builds
	for e in DirAccess.get_directories_at("res://examples"):
		if not str(e).begins_with("dos_"):
			continue
		var edir: String = root.path_join(str(e))
		_remove_tree(edir)
		CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/" + str(e)), edir)
		var er := ProjectBuild.generate(edir, {}, "dos")
		if not ProjectBuild.target_problems(er, "dos").is_empty() or not er.errors.is_empty():
			problems.append("example %s: no problems expected for MS-DOS" % e)
			continue
		var esrcs := ProjectBuild.write(er, edir.path_join(".build/src"))
		var eb := Toolchains.cached_build("dos", esrcs, edir.path_join(".build/dos"), CBProject.program_name(edir), "", bool(er.get("graphics", false)))
		if not eb.ok:
			problems.append("example %s didn't build for MS-DOS:\n%s" % [e, str(eb.output).strip_edges().left(2000)])
		else:
			notes.append("example %s: built for MS-DOS (%d bytes)" % [e, FileAccess.get_file_as_bytes(eb.out).size()])
	# the frame loop, the clock, Pause, time scale and Wait on MS-DOS: the same cases as here, the same lines
	for c in ["pause", "time_effects"]:
		var dir: String = root.path_join(c)
		_remove_tree(dir)
		CBProject.copy_dir(ProjectSettings.globalize_path("res://tests/cases/" + c), dir)
		var r := ProjectBuild.generate(dir, {}, "dos")
		var srcs := ProjectBuild.write(r, dir.path_join(".build/src"))
		var t0 := Time.get_ticks_msec()
		var b := Toolchains.cached_build("dos", srcs, dir.path_join(".build/dos"), CBProject.program_name(dir), "", true)
		_compile_ms += Time.get_ticks_msec() - t0
		if not b.ok:
			problems.append("%s didn't build for MS-DOS:\n%s" % [c, str(b.output).strip_edges().left(3000)])
			continue
		var run := Toolchains.dos_run(b.out, PackedStringArray(), dir, true)
		OS.execute("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "timeout", "180", "nice", "-n", "19", run.prog]) + PackedStringArray(run.argv), [], true)
		var got := Toolchains.dos_output(run)
		var cfg := ConfigFile.new()
		cfg.load(dir.path_join("case.cfg"))
		var at := 0
		for want in cfg.get_value("case", "expect_order", []):
			var i := got.find(str(want), at)
			if i < 0:
				problems.append("%s on MS-DOS: expected the line %s next, got:\n%s" % [c, JSON.stringify(want), got.left(1500)])
				break
			at = i + str(want).length()
		if problems.is_empty():
			notes.append("%s: its lines in order, on MS-DOS" % c)
	# sound on MS-DOS (a Sound Blaster, mixed by software): tests/dos/sound loads a WAV as music and one as a
	# sound, plays, pauses, resumes, and lets the music run out; -v makes the backend report what the card played
	var sdir: String = root.path_join("sound")
	_remove_tree(sdir)
	CBProject.copy_dir(ProjectSettings.globalize_path("res://tests/dos/sound"), sdir)
	var sr := ProjectBuild.generate(sdir, {}, "dos")
	var ssrcs := ProjectBuild.write(sr, sdir.path_join(".build/src"))
	var conv := Toolchains.dos_audio(sdir, sdir.path_join(".build/dos"))  # (the editor's build does this: WAV / OGG / MP3 -> 8-bit mono 22 kHz)
	if not conv.ok or int(conv.converted) != 4:
		problems.append("MS-DOS audio conversion: 4 files (2 WAV, an OGG, an MP3) expected converted, got %s (%s)" % [conv.converted, conv.output])
	for want_file in ["a0000001.wav", "a0000004.wav"]:
		if FileAccess.get_file_as_bytes(sdir.path_join(".build/dos/audio").path_join(want_file)).size() < 1000:
			problems.append("MS-DOS audio conversion: audio/%s should be written" % want_file)
	var st0 := Time.get_ticks_msec()
	var sb := Toolchains.cached_build("dos", ssrcs, sdir.path_join(".build/dos"), CBProject.program_name(sdir), "", true)
	_compile_ms += Time.get_ticks_msec() - st0
	if not sb.ok:
		problems.append("the sound project didn't build for MS-DOS:\n%s" % str(sb.output).strip_edges().left(3000))
	else:
		var srun := Toolchains.dos_run(sb.out, PackedStringArray(["-v"]), sdir, true)
		OS.execute("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "timeout", "180", "nice", "-n", "19", srun.prog]) + PackedStringArray(srun.argv), [], true)
		var sgot := Toolchains.dos_output(srun)
		var sat := 0
		for want in ["[load] music (0.5 s), sound (", ", missing: music (not loaded)", "[convert] sound (11183 frames), music (8.4 s)", "[music] playing 0.15 s in: true", "[music] paused: playing? false", "[music] resumed: playing? true", "[music] after its 0.5 s ran out: playing? false", "[audio] Sound Blaster at "]:
			var i := sgot.find(want, sat)
			if i < 0:
				problems.append("sound on MS-DOS: expected %s next, got:\n%s" % [JSON.stringify(want), sgot.left(1500)])
				break
			sat = i + want.length()
		var m := RegEx.create_from_string("(\\d+) samples played").search(sgot)
		if m == null or m.get_string(1).to_int() < 10000:
			problems.append("sound on MS-DOS: the Sound Blaster should have played at least a second's worth of samples (22222 a second), report: %s" % (m.get_string() if m != null else "none"))
		else:
			var pk := RegEx.create_from_string("loudest mixed sample (\\d+)").search(sgot)
			if pk == null or pk.get_string(1).to_int() < 30:
				problems.append("sound on MS-DOS: the mix was silent or nearly (the tones peak near 76 of 127): %s" % (pk.get_string() if pk != null else "no peak reported"))
			else:
				notes.append("sound: WAVs (8-bit mono 11 kHz, 16-bit stereo 44 kHz) mixed and played through DMA: %s samples, loudest %s of 127" % [m.get_string(1), pk.get_string(1)])
	# FM music on MS-DOS (the OPL chip, DOSBox-X's Sound Blaster 16 has one): tests/dos/fm loads an IMF, a VGM, a DRO and a
	# theme.wav that has a theme.imf beside it (the FM one must win: 1.2 s, not the WAV's 0.1 s), plays, pauses, resumes
	var fdir: String = root.path_join("fm")
	_remove_tree(fdir)
	CBProject.copy_dir(ProjectSettings.globalize_path("res://tests/dos/fm"), fdir)
	var fr_ := ProjectBuild.generate(fdir, {}, "dos")
	var fsrcs := ProjectBuild.write(fr_, fdir.path_join(".build/src"))
	var fconv := Toolchains.dos_audio(fdir, fdir.path_join(".build/dos"))
	if not fconv.ok or int(fconv.copied) != 4 or int(fconv.converted) != 1:
		problems.append("MS-DOS FM audio: 4 FM files copied and 1 WAV converted expected, got %s / %s (%s)" % [fconv.copied, fconv.converted, fconv.output])
	var fb := Toolchains.cached_build("dos", fsrcs, fdir.path_join(".build/dos"), CBProject.program_name(fdir), "", true)
	if not fb.ok:
		problems.append("the FM project didn't build for MS-DOS:\n%s" % str(fb.output).strip_edges().left(3000))
	else:
		var frun := Toolchains.dos_run(fb.out, PackedStringArray(["-v"]), fdir, true)
		OS.execute("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "timeout", "180", "nice", "-n", "19", frun.prog]) + PackedStringArray(frun.argv), [], true)
		var fgot := Toolchains.dos_output(frun)
		var fat := 0
		for want in ["[fm] theme.wav (its FM version): music (1.2 s)", "[fm] song.imf: music (1.2 s)", "[fm] tune.vgm: music (1.0 s)", "[fm] box.dro: music (0.8 s)", "[fm] playing: true", "[fm] paused: playing? false", "[fm] resumed, volume 0.5: playing? true", "[fm] later: theme (stopped by the next song) playing? false, vgm playing? false", "[audio] FM chip: OPL"]:
			var i := fgot.find(want, fat)
			if i < 0:
				problems.append("FM music on MS-DOS: expected %s next, got:\n%s" % [JSON.stringify(want), fgot.left(1500)])
				break
			fat = i + want.length()
		var fm_m := RegEx.create_from_string("(\\d+) register writes").search(fgot)
		if fm_m == null or fm_m.get_string(1).to_int() < 40:
			problems.append("FM music on MS-DOS: the OPL chip should have been written (a few dozen registers at least), report: %s" % (fm_m.get_string() if fm_m != null else "none"))
		else:
			notes.append("FM music: IMF, VGM and DRO files read and played on the OPL chip (%s register writes); theme.wav's FM version won" % fm_m.get_string(1))
	# MIDI on MS-DOS: compiled at load into OPL register writes with DMXOPL's bank (copied beside the program)
	var mdir: String = root.path_join("midi")
	_remove_tree(mdir)
	CBProject.copy_dir(ProjectSettings.globalize_path("res://tests/dos/midi"), mdir)
	var mr := ProjectBuild.generate(mdir, {}, "dos")
	var msrcs := ProjectBuild.write(mr, mdir.path_join(".build/src"))
	var mconv := Toolchains.dos_audio(mdir, mdir.path_join(".build/dos"))
	if not mconv.ok or int(mconv.copied) != 1 or not FileAccess.file_exists(mdir.path_join(".build/dos/audio/genmidi.op2")):
		problems.append("MS-DOS MIDI: the MIDI file and the instrument bank should be copied beside the program, got %s (%s)" % [mconv.copied, mconv.output])
	var mb := Toolchains.cached_build("dos", msrcs, mdir.path_join(".build/dos"), CBProject.program_name(mdir), "", true)
	if not mb.ok:
		problems.append("the MIDI project didn't build for MS-DOS:\n%s" % str(mb.output).strip_edges().left(3000))
	else:
		var mrun := Toolchains.dos_run(mb.out, PackedStringArray(["-v"]), mdir, true)
		OS.execute("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "timeout", "180", "nice", "-n", "19", mrun.prog]) + PackedStringArray(mrun.argv), [], true)
		var mgot := Toolchains.dos_output(mrun)
		var mat := 0
		for want in ["[midi] march.mid: music (2.0 s)", "[midi] playing: true", "[midi] after its 2 s: playing? false", "[audio] FM chip: OPL"]:
			var i := mgot.find(want, mat)
			if i < 0:
				problems.append("MIDI on MS-DOS: expected %s next, got:\n%s" % [JSON.stringify(want), mgot.left(1500)])
				break
			mat = i + want.length()
		var mm := RegEx.create_from_string("(\\d+) register writes").search(mgot)
		if mm == null or mm.get_string(1).to_int() < 80:
			problems.append("MIDI on MS-DOS: the notes should have become many register writes (3 chord notes, a bass note, 4 drum hits), report: %s" % (mm.get_string() if mm != null else "none"))
		else:
			notes.append("MIDI: march.mid (chord, bass, drums, a bend) compiled with DMXOPL's bank and played on the OPL chip: %s register writes" % mm.get_string(1))
	# 2D and the UI on MS-DOS (a VGA screen in DOSBox-X): the draw_2d and ui_basic cases take their screenshots
	for c in [["draw_2d", "draw_2d.png", 320, 200, 0], ["ui_containers", "ui_containers.png", 320, 200, 0], ["draw_2d", "draw_2d.png", 640, 480, 640], ["draw_2d", "draw_2d.png", 800, 600, 800], ["world_light_fog", "world_light_fog.png", 320, 200, 0], ["world_classes", "world_classes.png", 320, 200, 0], ["graphics_3d", "shot3d.png", 800, 600, 0], ["gem_hunt_shot", "gems.png", 800, 600, 0]]:
		var dir: String = root.path_join("%s_%d" % [c[0], c[2]])
		_remove_tree(dir)
		CBProject.copy_dir(ProjectSettings.globalize_path("res://tests/cases/" + c[0]), dir)
		if int(c[4]) > 0:  # Project settings: the DOS screen
			var pcf := CBProject.load_config(dir)
			pcf.set_value("dos", "screen", int(c[4]))
			CBProject.save_config(dir, pcf)
		var r := ProjectBuild.generate(dir, {}, "dos")
		if not r.errors.is_empty() or not ProjectBuild.target_problems(r, "dos").is_empty():
			problems.append("%s for MS-DOS: problems %s" % [c[0], str(r.errors.map(func(e): return e.msg) + ProjectBuild.target_problems(r, "dos").map(func(e): return e.msg))])
			continue
		var srcs := ProjectBuild.write(r, dir.path_join(".build/src"))
		var t0 := Time.get_ticks_msec()
		var b := Toolchains.cached_build("dos", srcs, dir.path_join(".build/dos"), CBProject.program_name(dir), "", true)
		_compile_ms += Time.get_ticks_msec() - t0
		if not b.ok:
			problems.append("%s didn't build for MS-DOS:\n%s" % [c[0], str(b.output).strip_edges().left(3000)])
			continue
		var run := Toolchains.dos_run(b.out, PackedStringArray(), dir, true)
		OS.execute("env", PackedStringArray(["SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy", "timeout", "300", "nice", "-n", "19", run.prog]) + PackedStringArray(run.argv), [], true)
		var png: String = dir.path_join(str(c[1]))
		if not FileAccess.file_exists(png):  # (DOS names files in capitals, 8.3: ui_containers.png is UI_CONTA.PNG)
			for f in DirAccess.get_files_at(dir):
				if f.get_extension().to_lower() == "png" and f == f.to_upper() and str(c[1]).to_upper().begins_with(f.get_basename()):
					png = dir.path_join(f)
		var img := Image.load_from_file(png) if FileAccess.file_exists(png) else null
		if img == null:
			problems.append("%s in DOSBox-X: no %s was taken. Its output:\n%s" % [c[0], c[1], Toolchains.dos_output(run).left(1500)])
			continue
		var colors := {}
		for y in range(0, img.get_height(), 3):
			for x in range(0, img.get_width(), 3):
				colors[img.get_pixel(x, y).to_html(false)] = true
		if img.get_width() != int(c[2]) or img.get_height() != int(c[3]) or colors.size() < 5:
			problems.append("%s in DOSBox-X: the screenshot is %d x %d with %d colours (expected %d x %d, drawn on)" % [c[0], img.get_width(), img.get_height(), colors.size(), c[2], c[3]])
		else:
			notes.append("%s: drawn in a %d x %d %s screen (%d colours); screenshot %s" % [c[0], img.get_width(), img.get_height(), "VGA" if img.get_width() == 320 else "VESA", colors.size(), png])
	_finish("dos", problems, notes)


func _check_build_cache() -> void:
	var problems := []
	var root := OS.get_user_data_dir().path_join("test_build/build_cache")
	_remove_tree(root)
	var a := root.path_join("a")
	CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/hello_world"), a)
	# a change no cache has seen: the time in a C comment, via the project's name
	var cf := CBProject.load_config(a)
	cf.set_value("project", "name", "Cache test %d" % Time.get_ticks_usec())
	CBProject.save_config(a, cf)
	var build := func(dir: String) -> Dictionary:
		var r := ProjectBuild.generate(dir)
		var srcs := ProjectBuild.write(r, dir.path_join(".build/src"))
		return Toolchains.cached_build("native", srcs, dir.path_join(".build/native"), CBProject.program_name(dir), "", bool(r.get("graphics", false)))
	var b1: Dictionary = build.call(a)
	if not b1.ok or str(b1.cached) != "":
		problems.append("a new project should compile (got cached '%s', ok %s)" % [b1.get("cached"), b1.ok])
	var b2: Dictionary = build.call(a)
	if str(b2.get("cached", "")) != "project":
		problems.append("built again unchanged (generated again, as after a reload): reused from the project expected, got '%s'" % b2.get("cached"))
	var b := root.path_join("b")
	CBProject.copy_dir(a, b)
	_remove_tree(b.path_join(".build"))
	var b3: Dictionary = build.call(b)
	if str(b3.get("cached", "")) != "cache":
		problems.append("a copy elsewhere: reused from the shared cache expected, got '%s'" % b3.get("cached"))
	cf.set_value("project", "version", "2.0")
	CBProject.save_config(a, cf)
	var b4: Dictionary = build.call(a)
	if str(b4.get("cached", "")) != "":
		problems.append("a changed project should compile again, got '%s'" % b4.get("cached"))
	# what the prebuilt programs rely on: an example copied anywhere has the same fingerprint
	# (no paths in it). (Whether res://prebuilt is current is the export's job: export.sh.)
	var keys := []
	for where in ["fizz_one", "somewhere/else/fizz_two"]:
		var c := root.path_join(where)
		CBProject.copy_dir(ProjectSettings.globalize_path("res://examples/fizzbuzz"), c)
		var r := ProjectBuild.generate(c)
		keys.append(Toolchains.build_key("native", Array(ProjectBuild.write(r, c.path_join(".build/src"))), Toolchains.resolve_command("native"), false))
	if keys[0] != keys[1]:
		problems.append("two copies of fizzbuzz in different folders have different fingerprints (%s, %s): the prebuilt programs would never match" % [str(keys[0]).substr(0, 12), str(keys[1]).substr(0, 12)])
	_finish("build_cache", problems, [])
