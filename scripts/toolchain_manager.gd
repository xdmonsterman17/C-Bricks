class_name ToolchainManager
extends Node
## The Toolchains window's engine (user, 2026-11-10: "all the thirdparty toolchains should be downloaded"): what can
## be installed (zig, DJGPP, DOSBox-X, Emscripten, CMake), where it came from, and the download -> check -> unpack
## steps. The list of downloads is `toolchains_manifest.json` (tools/make_toolchain_release.py writes it: URL, sha256,
## size per kind of computer); installed tools live in `user://toolchains/installed/<id>/`, where
## `Toolchains.search_dirs` looks first (after a bundle). Add the node to the tree, connect `progress` / `finished`,
## call `install(id)`; one install at a time.

signal progress(id: String, done: int, total: int, what: String)  ## total 0 = no known end (unpacking)
signal finished(id: String, err: String)  ## err "" = installed / removed

const MANIFEST := "res://toolchains_manifest.json"

## What each tool is for; `probe` = the program that tells it's there (anywhere on this computer).
const TOOLS := [
	{"id": "zig", "name": "zig", "probe": "zig", "licence": "MIT", "source": "https://ziglang.org/download/",
		"enables": "Native builds, and cross builds for Windows, macOS, Linux, the BSDs and WASI (zig cc). Also builds raylib."},
	{"id": "djgpp", "name": "DJGPP", "probe": "i586-pc-msdosdjgpp-gcc", "licence": "GPL / LGPL (GCC, binutils), DJGPP's own (libc)", "source": "https://www.delorie.com/djgpp/",
		"enables": "Builds for MS-DOS (GCC 12.2, protected mode)."},
	{"id": "dosbox-x", "name": "DOSBox-X", "probe": "dosbox-x", "licence": "GPL-2.0", "source": "https://github.com/joncampbell123/dosbox-x",
		"enables": "Runs MS-DOS builds from the editor (Run), with sound, mouse and networking."},
	{"id": "emscripten", "name": "Emscripten", "probe": "emcc", "licence": "MIT / NCSA", "source": "https://emscripten.org/",
		"enables": "The Web target (HTML + WebAssembly). Large: about 1 GB, fetched by emsdk (needs Python)."},
	{"id": "cmake", "name": "CMake", "probe": "cmake", "licence": "BSD-3-Clause", "source": "https://cmake.org/download/",
		"enables": "Building an exported project's CMakeLists.txt from the editor's tests and by hand. Optional."},
]

## Where installs go (tests change it; must stay under user://toolchains: removal only works there).
static var root_override := ""

var _id := ""
var _entry := {}
var _file := ""
var _http: HTTPRequest = null
var _thread: Thread = null


## <user data>/toolchains/installed
static func installed_root() -> String:
	return root_override if root_override != "" else OS.get_user_data_dir().path_join("toolchains/installed")


static func downloads_dir() -> String:
	return OS.get_user_data_dir().path_join("toolchains/downloads")


## "aarch64-linux", "x86_64-windows"...: the kind of computer (the manifest's platform keys, zig's names).
static func platform() -> String:
	var arch := Engine.get_architecture_name()
	var cpu := {"x86_64": "x86_64", "arm64": "aarch64", "x86_32": "x86", "arm32": "arm", "rv64": "riscv64"}.get(arch, arch) as String
	var os_name := {"Linux": "linux", "Windows": "windows", "macOS": "macos", "FreeBSD": "freebsd"}.get(OS.get_name(), OS.get_name().to_lower()) as String
	return cpu + "-" + os_name


static func manifest() -> Dictionary:
	var path := OS.get_environment("CBRICKS_TOOLCHAIN_MANIFEST")  # (tests: a local server's)
	if path == "":
		path = MANIFEST
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


## This tool's download for this computer: {url, sha256, size, strip, version, ...} or {} (none).
static func entry(id: String) -> Dictionary:
	var t: Dictionary = (manifest().get("tools", {}) as Dictionary).get(id, {})
	var e: Dictionary = (t.get("platforms", {}) as Dictionary).get(platform(), {})
	if e.is_empty():
		return {}
	e = e.duplicate()
	e["version"] = t.get("version", "")
	return e


static func tool_info(id: String) -> Dictionary:
	for t in TOOLS:
		if t.id == id:
			return t
	return {}


## {state: "installed" | "found" | "missing", version, path, size}. installed = by this window (removable);
## found = something else on this computer (PATH, usual folders, a bundle), not touched.
static func status(id: String) -> Dictionary:
	var dir := installed_root().path_join(id)
	var mark := dir.path_join(".installed")
	if FileAccess.file_exists(mark):
		return {"state": "installed", "version": FileAccess.get_file_as_string(mark).strip_edges(), "path": dir}
	var found := Toolchains.find_program(str(tool_info(id).get("probe", id)))
	if found != "":
		return {"state": "found", "version": "", "path": found}
	return {"state": "missing", "version": "", "path": ""}


func busy() -> bool:
	return _id != ""


func current() -> String:
	return _id


## Downloads, checks and unpacks a tool; `finished` says how it went.
func install(id: String) -> void:
	if busy():
		return
	var e := entry(id)
	if e.is_empty():
		finished.emit.call_deferred(id, "There is no download of %s for this computer (%s): install it yourself (%s)." % [tool_info(id).get("name", id), platform(), tool_info(id).get("source", "")])
		return
	_id = id
	_entry = e
	DirAccess.make_dir_recursive_absolute(downloads_dir())
	_file = downloads_dir().path_join(str(e.url).get_file())
	_http = HTTPRequest.new()
	_http.download_file = _file
	_http.use_threads = true
	_http.download_chunk_size = 262144
	_http.max_redirects = 10
	add_child(_http)
	_http.request_completed.connect(_downloaded)
	var err := _http.request(str(e.url))
	if err != OK:
		_end("Can't start the download (%s)." % error_string(err))
		return
	set_process(true)
	progress.emit(id, 0, int(e.get("size", 0)), "Downloading")


func _process(_dt: float) -> void:
	if _http != null and _thread == null:
		var total := _http.get_body_size()
		progress.emit(_id, _http.get_downloaded_bytes(), total if total > 0 else int(_entry.get("size", 0)), "Downloading")


## Stops a download (not an unpacking: that finishes in a moment).
func cancel() -> void:
	if _http != null and _thread == null:
		_http.cancel_request()
		_end("Cancelled.")


func _downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _http == null:
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_end("The download failed (%s)." % (("HTTP %d" % code) if result == HTTPRequest.RESULT_SUCCESS else "network error %d" % result) + (" Is the release published?" if code == 404 else ""))
		return
	progress.emit(_id, 0, 0, "Checking")
	_thread = Thread.new()
	_thread.start(_unpack_worker)


func _unpack_worker() -> void:
	var err := _unpack_file()
	call_deferred("_unpacked", err)


func _unpack_file() -> String:
	var want := str(_entry.get("sha256", ""))
	if want != "" and FileAccess.get_sha256(_file) != want:
		return "The download is damaged or changed (its sha256 doesn't match the manifest's): not installed."
	call_deferred("_say", "Unpacking")
	var root := installed_root()
	var dest := root.path_join(_id)
	var in_place := _entry.has("emsdk")  # (emsdk writes absolute paths into its config: it unpacks where it stays)
	var part := dest if in_place else dest + ".part"
	Toolchains._rm_tree(part)
	DirAccess.make_dir_recursive_absolute(part)
	var out := []
	var code := OS.execute("tar", ["-xf", ProjectSettings.globalize_path(_file), "-C", ProjectSettings.globalize_path(part), "--strip-components=" + str(int(_entry.get("strip", 0)))], out, true)
	if code != 0:
		Toolchains._rm_tree(part)
		return "Unpacking failed (tar exit %d: %s). Needs `tar` (with xz for .tar.xz)." % [code, " ".join(out).strip_edges().left(300)]
	if _entry.has("emsdk"):  # emsdk's own downloads: the compiler itself
		var e := _run_emsdk(part, str(_entry.emsdk))
		if e != "":
			Toolchains._rm_tree(part)
			return e
	var mark := FileAccess.open(part.path_join(".installed"), FileAccess.WRITE)
	mark.store_string(str(_entry.get("version", "")))
	mark.close()
	if not in_place:
		Toolchains._rm_tree(dest)
		if DirAccess.rename_absolute(part, dest) != OK:
			return "Can't move the unpacked files into place."
	return ""


func _run_emsdk(dir: String, version: String) -> String:
	var py := "python" if OS.get_name() == "Windows" else "python3"
	var script := ProjectSettings.globalize_path(dir.path_join("emsdk.py"))
	for step in ["install", "activate"]:
		var p := OS.execute_with_pipe(py, ["-u", script, step, version])
		if p.is_empty():
			return "Can't run Python (%s) to run emsdk: install Python 3 first." % py
		var io: FileAccess = p.stdio
		var tail := ""
		while io.get_error() == OK:
			var line := io.get_line().strip_edges()
			if line != "":
				tail = line
				call_deferred("_say", "emsdk %s: %s" % [step, line.left(90)])
		var code := OS.get_process_exit_code(p.pid)
		if code != 0:
			return "emsdk %s failed (exit %d): %s" % [step, code, tail]
	return ""


func _say(what: String) -> void:
	if _id != "":
		progress.emit(_id, 0, 0, what)


func _unpacked(err: String) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_end(err)


func _end(err: String) -> void:
	var id := _id
	if _http != null:
		_http.queue_free()
		_http = null
	if _file != "":
		DirAccess.remove_absolute(_file)
		_file = ""
	_id = ""
	set_process(false)
	Toolchains.clear_cache()
	finished.emit(id, err)


## Removes an installed tool (what this window installed; nothing else).
func remove(id: String) -> void:
	if busy():
		return
	Toolchains._rm_tree(installed_root().path_join(id))
	Toolchains.clear_cache()
	finished.emit.call_deferred(id, "")


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
