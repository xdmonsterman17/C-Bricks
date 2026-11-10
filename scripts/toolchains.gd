class_name Toolchains
extends RefCounted
## Build targets for generated C code. Each target lists candidate command templates;
## the first one whose program is installed is used (or the user's override).
##
## Template placeholders: {src} source file, {out} output file, {dir} output directory.

const TARGETS := [
	{
		"id": "native", "name": "This computer (native)", "ext": "", "ext_windows": ".exe",
		"candidates": [
			"cc -std=c99 -O2 -Wall {src} -o {out} -lm",
			"gcc -std=c99 -O2 -Wall {src} -o {out} -lm",
			"clang -std=c99 -O2 -Wall {src} -o {out} -lm",
			"zig cc -std=c99 -O2 {src} -o {out} -lm",
			"tcc {src} -o {out} -lm",
		],
		"run": ["{out}"],
	},
	{
		"id": "linux-x86_64", "name": "Linux x86_64", "ext": "-linux-x86_64",
		"candidates": [
			"x86_64-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
			"zig cc -target x86_64-linux-musl -std=c99 -O2 {src} -o {out} -lm",
		],
		"run": ["qemu-x86_64 {out}"],
	},
	{
		"id": "linux-arm64", "name": "Linux ARM64 / Raspberry Pi 64-bit", "ext": "-linux-arm64",
		"candidates": [
			"aarch64-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
			"zig cc -target aarch64-linux-musl -std=c99 -O2 {src} -o {out} -lm",
		],
		"run": ["qemu-aarch64 {out}"],
	},
	{
		"id": "linux-armhf", "name": "Linux ARMv7 / Raspberry Pi 32-bit", "ext": "-linux-armhf",
		"candidates": [
			"arm-linux-gnueabihf-gcc -std=c99 -O2 -static {src} -o {out} -lm",
			"zig cc -target arm-linux-musleabihf -std=c99 -O2 {src} -o {out} -lm",
		],
		"run": ["qemu-arm {out}"],
	},
	{
		"id": "windows-x86_64", "name": "Windows x86_64", "ext": "-windows-x86_64.exe",
		"candidates": [
			"x86_64-w64-mingw32-gcc -std=c99 -O2 -static {src} -o {out} -lm",
			"zig cc -target x86_64-windows-gnu -std=c99 -O2 {src} -o {out}",
			"gcc -std=c99 -O2 -static {src} -o {out} -lm",  # on a Windows host (MSYS2/MinGW)
		],
		"run": ["wine {out}"],
	},
	{
		"id": "windows-arm64", "name": "Windows ARM64", "ext": "-windows-arm64.exe",
		"candidates": [
			"zig cc -target aarch64-windows-gnu -std=c99 -O2 {src} -o {out}",
			"aarch64-w64-mingw32-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "macos-arm64", "name": "macOS Apple Silicon", "ext": "-macos-arm64",
		"candidates": [
			"zig cc -target aarch64-macos -std=c99 -O2 {src} -o {out}",
			"oa64-clang -std=c99 -O2 {src} -o {out}",
			"clang -arch arm64 -std=c99 -O2 {src} -o {out}",
		],
		"run": [],
	},
	{
		"id": "macos-x86_64", "name": "macOS Intel", "ext": "-macos-x86_64",
		"candidates": [
			"zig cc -target x86_64-macos -std=c99 -O2 {src} -o {out}",
			"o64-clang -std=c99 -O2 {src} -o {out}",
			"clang -arch x86_64 -std=c99 -O2 {src} -o {out}",
		],
		"run": [],
	},
	{
		"id": "windows-x86", "name": "Windows x86 32-bit", "ext": "-windows-x86.exe",
		"candidates": [
			"zig cc -target x86-windows-gnu -std=c99 -O2 {src} -o {out}",
			"i686-w64-mingw32-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": ["wine {out}"],
	},
	{
		"id": "linux-x86", "name": "Linux x86 32-bit", "ext": "-linux-x86",
		"candidates": [
			"zig cc -target x86-linux-musl -std=c99 -O2 {src} -o {out} -lm",
			"i686-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": ["qemu-i386 {out}"],
	},
	{
		"id": "linux-riscv64", "name": "Linux RISC-V 64", "ext": "-linux-riscv64",
		"candidates": [
			"zig cc -target riscv64-linux-musl -std=c99 -O2 {src} -o {out} -lm",
			"riscv64-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": ["qemu-riscv64 {out}"],
	},
	{
		"id": "linux-ppc64le", "name": "Linux POWER (ppc64le)", "ext": "-linux-ppc64le",
		"candidates": [
			"zig cc -target powerpc64le-linux-musl -std=c99 -O2 {src} -o {out} -lm",
			"powerpc64le-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "linux-s390x", "name": "Linux IBM Z (s390x)", "ext": "-linux-s390x",
		"candidates": [
			"zig cc -target s390x-linux-musl -std=c99 -O2 {src} -o {out} -lm",
			"s390x-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "linux-loongarch64", "name": "Linux LoongArch 64", "ext": "-linux-loongarch64",
		"candidates": [
			"zig cc -target loongarch64-linux-musl -std=c99 -O2 {src} -o {out} -lm",
			"loongarch64-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "linux-mipsel", "name": "Linux MIPS (little-endian)", "ext": "-linux-mipsel",
		"candidates": [
			"zig cc -target mipsel-linux-musleabi -std=c99 -O2 {src} -o {out} -lm",
			"mipsel-linux-gnu-gcc -std=c99 -O2 -static {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "freebsd-x86_64", "name": "FreeBSD x86_64", "ext": "-freebsd-x86_64",
		"candidates": [
			"zig cc -target x86_64-freebsd -std=c99 -O2 {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "freebsd-arm64", "name": "FreeBSD ARM64", "ext": "-freebsd-arm64",
		"candidates": [
			"zig cc -target aarch64-freebsd -std=c99 -O2 {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "netbsd-x86_64", "name": "NetBSD x86_64", "ext": "-netbsd-x86_64",
		"candidates": [
			"zig cc -target x86_64-netbsd -std=c99 -O2 {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		"id": "android-arm64", "name": "Android ARM64 (NDK, CLI binary)", "ext": "-android-arm64",
		"candidates": [
			"aarch64-linux-android24-clang -std=c99 -O2 {src} -o {out} -lm",
			"zig cc -target aarch64-linux-musl -static -std=c99 -O2 {src} -o {out} -lm",
		],
		"run": [],
	},
	{
		# MS-DOS (2026-11-08): DJGPP (32-bit protected mode, 386+); text programs for now. The
		# .exe needs a DPMI host: DOSBox has one, real DOS gets CWSDPMI.EXE beside it.
		"id": "dos", "name": "MS-DOS (DJGPP, 386+)", "ext": "-dos.exe",
		"candidates": [
			"i586-pc-msdosdjgpp-gcc -std=c99 -O2 -s {src} -o {out} -lm",
			"i386-pc-msdosdjgpp-gcc -std=c99 -O2 -s {src} -o {out} -lm",
		],
		"run": ["@dosbox {out}"],
	},
	{
		"id": "web", "name": "Web (Emscripten HTML + WASM)", "ext": ".html",
		"candidates": [
			"emcc -std=c99 -O2 {src} -o {out} -sEXIT_RUNTIME=1",
		],
		"run": ["emrun --no_emrun_detect {out}", "@open {out}"],
	},
	{
		"id": "wasi", "name": "WebAssembly WASI", "ext": ".wasm",
		"candidates": [
			"zig cc -target wasm32-wasi -std=c99 -O2 {src} -o {out} -lm",
			"clang --target=wasm32-wasi -std=c99 -O2 {src} -o {out}",
		],
		"run": ["wasmtime {out}", "wasmer run {out}"],
	},
]

static var _which_cache := {}
static var overrides := {}   # target id -> command template


static func target(id: String) -> Dictionary:
	for t in TARGETS:
		if t.id == id:
			return t
	return TARGETS[0]


static func can_execute() -> bool:
	return not OS.has_feature("web")


## The toolchains shipped with the exported editor (2026-11-09): zig/ (zig, Windows / Linux / macOS / BSD cross
## builds), djgpp/ (MS-DOS) and dosbox-x/. In order: the folder CBRICKS_TOOLCHAINS names (tests, a shared install),
## a `toolchains/` folder beside the executable, then the copy unpacked from inside the executable into the user
## folder (`unpack`, the first time something is built: user, 2026-11-09, one single file). "" when there is none.
static func bundle_dir() -> String:
	var env := OS.get_environment("CBRICKS_TOOLCHAINS")
	if env != "":
		return env if DirAccess.dir_exists_absolute(env) else ""
	var beside := OS.get_executable_path().get_base_dir().path_join("toolchains")
	if DirAccess.dir_exists_absolute(beside):
		return beside
	var un := unpacked_dir()
	return un if un != "" and FileAccess.file_exists(un.path_join(".unpacked")) else ""


## Removes a folder inside the unpacked-toolchains area (and nothing else).
static func _rm_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path) or not path.begins_with(OS.get_user_data_dir().path_join("toolchains")):
		return
	for d in DirAccess.get_directories_at(path):
		_rm_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


const TOOLCHAIN_PACK := "res://toolchains_pack/toolchains.pak"


## Where the pack unpacks to: <user data>/toolchains/<the pack's id> ("" when the editor has no pack).
static func unpacked_dir() -> String:
	if not FileAccess.file_exists(TOOLCHAIN_PACK):
		return ""
	var id := FileAccess.get_file_as_string("res://toolchains_pack/toolchains.id").strip_edges()
	return OS.get_user_data_dir().path_join("toolchains").path_join(id if id != "" else "pack")


## Whether the editor carries a pack that isn't unpacked yet (an exported editor only: a Godot-run project uses
## the machine's tools).
static func pack_pending() -> bool:
	return OS.has_feature("template") and OS.get_environment("CBRICKS_TOOLCHAINS") == "" and bundle_dir() == "" and unpacked_dir() != ""


## Unpacks the pack into `unpacked_dir()` (into a .part folder first: an interrupted unpack starts over, and old
## packs' folders are removed). progress(done, total, what) may be called from this (a worker) thread. Returns
## "" or what went wrong. `pack` is the .pak (tools/make_toolchain_pack.py: its .idx lists the files).
static func unpack(progress: Callable = Callable(), pack := TOOLCHAIN_PACK, dest_to := "") -> String:
	var dest := dest_to if dest_to != "" else unpacked_dir()
	if dest == "":
		return "this editor has no toolchains inside it"
	var pk := FileAccess.open(pack, FileAccess.READ)
	var lines := FileAccess.get_file_as_string(pack.get_basename() + ".idx").split("\n", false)
	if pk == null or lines.is_empty():
		return "can't open the toolchains inside the editor"
	var part := dest + ".part"
	_rm_tree(part)
	DirAccess.make_dir_recursive_absolute(part)
	var made := {}
	var n := 0
	for line in lines:
		var p := line.split(" ", false, 4)  # offset, compressed size, size, executable, path
		n += 1
		if progress.is_valid() and n % 100 == 1:
			progress.call(n, lines.size(), p[4])
		var target := part.path_join(p[4])
		if not made.has(target.get_base_dir()):
			DirAccess.make_dir_recursive_absolute(target.get_base_dir())
			made[target.get_base_dir()] = true
		pk.seek(int(p[0]))
		var data := PackedByteArray() if int(p[2]) == 0 else pk.get_buffer(int(p[1])).decompress(int(p[2]), FileAccess.COMPRESSION_DEFLATE)  # (an empty file)
		if data.size() != int(p[2]):
			return "the toolchains inside the editor are damaged (%s)" % p[4]
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			return "can't write %s (is the disk full?)" % target
		out.store_buffer(data)
		out.close()
		if p[3] == "1":
			FileAccess.set_unix_permissions(target, 493)  # (rwxr-xr-x)
	pk.close()
	var mark := FileAccess.open(part.path_join(".unpacked"), FileAccess.WRITE)
	mark.store_string("ok")
	mark.close()
	_rm_tree(dest)
	if DirAccess.rename_absolute(part, dest) != OK:
		return "can't move the unpacked toolchains into place"
	if dest_to == "":
		for old in DirAccess.get_directories_at(dest.get_base_dir()):  # (an older editor's copy)
			if dest.get_base_dir().path_join(old) != dest:
				_rm_tree(dest.get_base_dir().path_join(old))
	clear_cache()
	return ""


## Folders searched besides PATH: an app started from a desktop menu often
## doesn't get the shell's PATH (zig in ~/.local/bin, Homebrew, MSYS2...).
static func search_dirs() -> PackedStringArray:
	var dirs := PackedStringArray()
	var sep := ";" if OS.get_name() == "Windows" else ":"
	var bundle := bundle_dir()
	if bundle != "":  # the editor's own toolchains first: they're the ones it was tested with
		for sub in ["zig", "djgpp/bin", "dosbox-x", "emscripten"]:
			dirs.append(bundle.path_join(sub))
	for d in OS.get_environment("PATH").split(sep, false):
		if d not in dirs:
			dirs.append(d)
	var home := OS.get_environment("USERPROFILE" if OS.get_name() == "Windows" else "HOME")
	var extra: Array = []
	if OS.get_name() == "Windows":
		extra = [home.path_join("zig"), "C:/zig", "C:/msys64/mingw64/bin", "C:/msys64/ucrt64/bin", "C:/msys64/clang64/bin", "C:/Program Files/LLVM/bin", home.path_join("scoop/shims")]
	else:
		extra = [home.path_join(".local/bin"), home.path_join(".local/opt/djgpp/bin"), home.path_join(".local/opt/zig"), home.path_join("zig"), home.path_join("emsdk/upstream/emscripten"), home.path_join(".local/opt/emsdk/upstream/emscripten"), home.path_join(".wasmtime/bin"),
			"/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin", "/opt/local/bin", "/snap/bin"]
	for d in extra:
		if d not in dirs:
			dirs.append(d)
	return dirs


## The program's full path ("" when it isn't installed).
static func find_program(prog: String) -> String:
	if not can_execute():
		return ""
	if _which_cache.has(prog):
		return _which_cache[prog]
	var found := ""
	if prog.is_absolute_path():
		found = prog if FileAccess.file_exists(prog) else ""
	else:
		var names := [prog]
		if OS.get_name() == "Windows":
			names = [prog + ".exe", prog + ".cmd", prog + ".bat", prog]
		for d in search_dirs():
			for nm in names:
				if FileAccess.file_exists(d.path_join(nm)):
					found = d.path_join(nm)
					break
			if found != "":
				break
	_which_cache[prog] = found
	return found


static func has_program(prog: String) -> bool:
	return find_program(prog) != ""


static func clear_cache() -> void:
	_which_cache.clear()


## Split a command template into argv, honouring "double quotes".
static func split_command(cmd: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	var quoted := false
	var has := false
	for ch in cmd:
		if ch == "\"":
			quoted = not quoted
			has = true
		elif ch == " " and not quoted:
			if has:
				out.append(cur)
			cur = ""
			has = false
		else:
			cur += ch
			has = true
	if has:
		out.append(cur)
	return out


## Command template that will be used for a target, or "" if no compiler was found.
static func resolve_command(id: String) -> String:
	var ov := str(overrides.get(id, "")).strip_edges()
	if ov != "":
		return ov
	var t := target(id)
	# Skip the host-only fallbacks that would produce the wrong platform.
	for c in t.candidates:
		var prog: String = split_command(c)[0]
		if id == "windows-x86_64" and prog == "gcc" and OS.get_name() != "Windows":
			continue
		if id.begins_with("macos") and prog == "clang" and OS.get_name() != "macOS":
			continue
		if has_program(prog):
			return c
	return ""


static func resolve_runner(id: String) -> String:
	var t := target(id)
	if id == "dos":
		return "@dosbox" if find_program("dosbox-x") != "" or find_program("dosbox") != "" else ""
	for r in t.run:
		if r.begins_with("@") or r.begins_with("{out}"):
			return r
		if has_program(split_command(r)[0]):
			return r
	return ""


static func output_path(id: String, dir: String, base: String) -> String:
	var t := target(id)
	var ext: String = t.ext
	if id == "native" and OS.get_name() == "Windows":
		ext = t.ext_windows
	return dir.path_join(base + ext)


## Template -> argv. A value that is a list (the sources) fills its placeholder's
## place with one argument per item.
static func expand(template: String, vars: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for arg in split_command(template):
		var spliced := false
		for k in vars:
			if arg == "{%s}" % k and (vars[k] is Array or vars[k] is PackedStringArray):
				out.append_array(PackedStringArray(vars[k]))
				spliced = true
		if spliced:
			continue
		for k in vars:
			var v = vars[k]
			arg = arg.replace("{%s}" % k, " ".join(PackedStringArray(v)) if (v is Array or v is PackedStringArray) else str(v))
		out.append(arg)
	return out


## Blocking compile. Safe to call from a worker thread.
## Returns {"ok": bool, "exit": int, "output": String, "command": String, "out": String}
# ------------------------------------------------------------------ raylib (graphics bricks)

const RAYLIB_VERSION := "5.5"
const RAYLIB_RES := "res://thirdparty/raylib/src"
const RAYLIB_SOURCES := ["rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "rmodels.c", "raudio.c", "utils.c", "rglfw.c"]


## How raylib builds for a target: {"defines", "libs", "skip"} ({} = it can't).
## Cross targets need the platform's GL / windowing SDK: zig ships Windows'
## (opengl32, gdi32), not X11's or macOS' frameworks, so those build natively only.
static func raylib_flags(id: String) -> Dictionary:
	var host := OS.get_name()
	var desktop := ["-DPLATFORM_DESKTOP", "-DGRAPHICS_API_OPENGL_33"]
	# Linux / BSD: X11 (raylib 5.5's rglfw.c needs a backend named) and OpenGL 2.1,
	# which every Linux GPU has (a Raspberry Pi's V3D tops out at 3.1: no 3.3 core).
	var linux := ["-DPLATFORM_DESKTOP", "-DGRAPHICS_API_OPENGL_21", "-D_GNU_SOURCE", "-D_GLFW_X11"]
	var windows := {"defines": desktop, "libs": ["-lopengl32", "-lgdi32", "-lwinmm", "-lws2_32"], "skip": []}
	match id:
		"native":
			if host == "Windows":
				return windows
			if host == "macOS":
				return {"defines": desktop, "libs": ["-framework", "Cocoa", "-framework", "IOKit", "-framework", "CoreVideo", "-framework", "OpenGL"], "skip": []}
			return {"defines": linux, "libs": ["-lGL", "-lm", "-lpthread", "-ldl", "-lrt", "-lX11"], "skip": []}
		"windows-x86_64", "windows-x86", "windows-arm64":
			return windows
		"web":
			return {"defines": ["-DPLATFORM_WEB", "-DGRAPHICS_API_OPENGL_ES2"], "libs": ["-sUSE_GLFW=3", "-sASYNCIFY"], "skip": ["rglfw.c"]}
		"macos-arm64", "macos-x86_64":
			if host == "macOS":
				return {"defines": desktop, "libs": ["-framework", "Cocoa", "-framework", "IOKit", "-framework", "CoreVideo", "-framework", "OpenGL"], "skip": []}
	return {}


## MS-DOS programs run in DOSBox-X (2026-11-08): the folder the program runs in (the project's,
## its files where it looks for them) as C:, the program as D:\<8.3 name>.EXE beside its output.
## capture: run to the end and exit (a dummy video driver: nothing shows), stdout into D:\OUT.TXT (dos_output reads it), stdin_text
## from D:\IN.TXT;
## otherwise a window that waits for a key at the end. -> {"prog", "argv", "out_txt"} ({} without DOSBox-X).
static func dos_run(exe: String, args: PackedStringArray, cwd: String, capture := false, stdin_text := "", udp_forwards := "") -> Dictionary:
	var prog := find_program("dosbox-x")
	if prog == "":
		prog = find_program("dosbox")
	if prog == "":
		return {}
	var run := exe.get_base_dir()   # (D: is the folder of the program: its converted audio/ is there too)
	var short := dos_name(exe.get_file().get_basename().trim_suffix("-dos"))
	DirAccess.copy_absolute(exe, run.path_join(short + ".EXE"))
	var out_txt := run.path_join("OUT.TXT")
	if FileAccess.file_exists(out_txt):
		DirAccess.remove_absolute(out_txt)
	var quoted := PackedStringArray()
	for a in args:
		quoted.append("\"%s\"" % a if a.contains(" ") else a)
	var cmd := "D:\\%s.EXE%s" % [short, "" if quoted.is_empty() else " " + " ".join(quoted)]
	var argv := PackedStringArray(["-fastlaunch", "-nopromptfolder", "-set", "dosbox quit warning=false", "-set", "cpu cycles=max",
		"-c", "mount c \"%s\"" % cwd, "-c", "mount d \"%s\"" % run, "-c", "C:"])
	if FileAccess.get_file_as_bytes(exe).hex_encode().contains("WATTCP.CFG".to_ascii_buffer().hex_encode()):  # (linked with Watt-32: a network program)
		# DOSBox-X's NE2000 on its built-in NAT (slirp), the packet driver loaded, Watt-32 told to ask DHCP: the program
		# reaches the host at 10.0.2.2; `udp_forwards` ("host:guest" ports) lets the host reach it.
		_copy_file(PACKET_DRIVER, run.path_join("NE2000.COM"))
		if not FileAccess.file_exists(run.path_join("WATTCP.CFG")):
			var cf := FileAccess.open(run.path_join("WATTCP.CFG"), FileAccess.WRITE)
			cf.store_string("my_ip = dhcp\r\n")
			cf.close()
		argv.append_array(["-set", "ne2000 ne2000=true", "-set", "ne2000 nicbase=300", "-set", "ne2000 nicirq=3", "-set", "ne2000 backend=slirp"])
		if udp_forwards != "":
			argv.append_array(["-set", "ethernet, slirp udp_port_forwards=" + udp_forwards])
		argv.append_array(["-c", "D:\\NE2000.COM 0x60 3 0x300", "-c", "set WATTCP.CFG=D:\\WATTCP.CFG"])
	if capture:
		argv.insert(0, "-exit")  # (not -silent: that turns DOSBox-X's Sound Blaster off)
		if stdin_text != "":
			var f := FileAccess.open(run.path_join("IN.TXT"), FileAccess.WRITE)
			f.store_string(stdin_text.replace("\n", "\r\n"))
			f.close()
			cmd += " < D:\\IN.TXT"
		argv.append_array(["-c", cmd + " > D:\\OUT.TXT"])
	else:
		argv.append_array(["-c", "cls", "-c", cmd, "-c", "echo.", "-c", "pause", "-c", "exit"])
	return {"prog": prog, "argv": argv, "out_txt": out_txt}


const AUDIO_TOOL_FILES := [["res://scripts/tools/audioconv.c", "audioconv.c"], ["res://thirdparty/raylib/src/external/dr_wav.h", "dr_wav.h"],
	["res://thirdparty/raylib/src/external/dr_mp3.h", "dr_mp3.h"], ["res://thirdparty/raylib/src/external/stb_vorbis.c", "stb_vorbis.c"]]

## The audio converter (scripts/tools/audioconv.c): built once with this computer's C compiler,
## kept in user://audioconv/<hash>/. -> {"ok", "path", "key", "output"}.
static func dos_converter() -> Dictionary:
	var base := OS.get_user_data_dir().path_join("audioconv")
	var src := base.path_join("src")
	DirAccess.make_dir_recursive_absolute(src)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for f in AUDIO_TOOL_FILES:
		var text := FileAccess.get_file_as_bytes(f[0])
		ctx.update(text)
		var dst := src.path_join(f[1])
		if not FileAccess.file_exists(dst) or FileAccess.get_file_as_bytes(dst) != text:
			var w := FileAccess.open(dst, FileAccess.WRITE)
			if w == null:
				return {"ok": false, "path": "", "key": "", "output": "Couldn't write the audio converter's source to %s." % dst}
			w.store_buffer(text)
			w.close()
	ctx.update(resolve_command("native").to_utf8_buffer())
	var key := ctx.finish().hex_encode().substr(0, 12)
	var dir := base.path_join(key)
	var out := output_path("native", dir, "audioconv")
	if FileAccess.file_exists(out):
		return {"ok": true, "path": out, "key": key, "output": ""}
	var r := compile("native", [src.path_join("audioconv.c")], dir, "audioconv")
	if not r.ok:
		return {"ok": false, "path": "", "key": key, "output": "Couldn't build the audio converter (it needs a C compiler on this computer):\n" + str(r.output)}
	return {"ok": true, "path": out, "key": key, "output": ""}


## Prepares a project's audio for MS-DOS (ProjectBuild.dos_audio_list) in out_dir/audio/: each WAV /
## OGG / MP3 converted, each FM music file copied; only what changed (or all, when the converter
## did). -> {"ok", "converted": n (PCM), "copied": n (FM), "output"}.
static func dos_audio(project_dir: String, out_dir: String) -> Dictionary:
	var list: Array = ProjectBuild.dos_audio_list(project_dir)
	var audio := out_dir.path_join("audio")
	DirAccess.make_dir_recursive_absolute(audio)
	var done := 0
	var copied := 0
	var msgs := ""
	var ok := true
	var tool: Dictionary = {}
	var fresh := false
	var stamp := audio.path_join("converter.txt")
	var seen_fm := {}
	for e in list:
		var src := project_dir.path_join(str(e.from))
		if str(e.fm) != "" and not seen_fm.has(e.fm):  # FM music: copied as it is
			seen_fm[e.fm] = true
			var fdst := audio.path_join(str(e.fm))
			var fsrc := project_dir.path_join(str(e.fm_src))
			if not FileAccess.file_exists(fdst) or FileAccess.get_modified_time(fdst) < FileAccess.get_modified_time(fsrc):
				DirAccess.copy_absolute(fsrc, fdst)
				copied += 1
		if str(e.pcm) == "":
			continue
		if tool.is_empty():
			tool = dos_converter()
			if not tool.ok:
				return {"ok": false, "converted": done, "copied": copied, "output": tool.output}
			fresh = not FileAccess.file_exists(stamp) or FileAccess.get_file_as_string(stamp).strip_edges() != str(tool.key)
		var dst := audio.path_join(str(e.pcm))
		if not fresh and FileAccess.file_exists(dst) and FileAccess.get_modified_time(dst) >= FileAccess.get_modified_time(src):
			continue
		var output := []
		var code := OS.execute(tool.path, [src, dst], output, true, false)
		if code != 0:
			ok = false
			msgs += "%s: %s" % [e.from, "".join(output).strip_edges() + "\n"]
		else:
			done += 1
	var wants_bank := false  # MIDI music: the instrument bank goes beside it (the project's own genmidi.op2, else the bundled DMXOPL)
	for e in list:
		if str(e.fm).get_extension() == "mid":
			wants_bank = true
	if wants_bank:
		var bank_src := "res://thirdparty/dmxopl/GENMIDI.op2"
		for rel in CBProject.list_assets(project_dir):
			if rel.get_file().to_lower() == "genmidi.op2":
				bank_src = project_dir.path_join(rel)
		var bytes := FileAccess.get_file_as_bytes(bank_src)
		var bdst := audio.path_join("genmidi.op2")
		if not bytes.is_empty() and (not FileAccess.file_exists(bdst) or FileAccess.get_file_as_bytes(bdst) != bytes):
			var bw := FileAccess.open(bdst, FileAccess.WRITE)
			if bw != null:
				bw.store_buffer(bytes)
				bw.close()
	if not tool.is_empty():
		var w := FileAccess.open(stamp, FileAccess.WRITE)
		if w != null:
			w.store_string(str(tool.key))
			w.close()
	return {"ok": ok, "converted": done, "copied": copied, "output": msgs}


## A file name DOS can use: 8 letters / digits / _, upper case ("bouncing_ball" -> "BOUNCING").
static func dos_name(base: String) -> String:
	var out := ""
	for ch in base.to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_":
			out += ch
		if out.length() == 8:
			break
	return out if out != "" else "PROGRAM"


## A captured DOS run's output (dos_run with capture), with DOS's CR LF line ends made LF.
static func dos_output(run: Dictionary) -> String:
	if not FileAccess.file_exists(str(run.get("out_txt", ""))):
		return ""
	return FileAccess.get_file_as_string(run.out_txt).replace("\r\n", "\n")


## What a target's programs can do (2026-11-08, the MS-DOS plan's step 3): "graphics" (a window,
## drawing, input, sound, the UI, the scene), "3d", "network". A brick needing more is a problem
## naming it (ProjectBuild.target_problems).
static func caps(id: String) -> Array:
	if id == "dos":
		return ["graphics", "3d", "network"]  # (text, 2D, the UI, sound, 3D and UDP networking through Watt-32)
	var c := ["network"]
	if not raylib_flags(id).is_empty():
		c.append_array(["graphics", "3d"])
	return c


## raylib's source on disk (copied out of the app once: a compiler can't read res://).
static func raylib_dir() -> String:
	var dir := OS.get_user_data_dir().path_join("raylib").path_join(RAYLIB_VERSION).path_join("src")
	if FileAccess.file_exists(dir.path_join("raylib.h")):
		return dir
	_copy_res(RAYLIB_RES, dir)
	return dir


static func _copy_res(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for f in DirAccess.get_files_at(from):
		var name := f.trim_suffix(".remap")
		var fa := FileAccess.open(to.path_join(name), FileAccess.WRITE)
		if fa != null:
			fa.store_buffer(FileAccess.get_file_as_bytes(from.path_join(name)))
			fa.close()
	for d in DirAccess.get_directories_at(from):
		_copy_res(from.path_join(d), to.path_join(d))


## The compiler part of a command template: "zig cc -target x86_64-windows-gnu".
static func compiler_prefix(template: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in split_command(template):
		if a.begins_with("-std") or a.begins_with("-O") or a.begins_with("{") or a == "-static" or a == "-Wall":
			break
		out.append(a)
	return out


## Compiles raylib for a target once (cached per target). Safe from a worker thread.
## {"ok", "objs": [.o paths], "flags": [extra flags for the program], "output"}
static func build_raylib(id: String, template := "") -> Dictionary:
	var rf := raylib_flags(id)
	if rf.is_empty():
		return {"ok": false, "objs": [], "flags": [], "output": "Graphics bricks (raylib) can't be built for %s from here: it needs that platform's OpenGL / windowing SDK. They build for this computer, Windows (zig), macOS on a Mac, and the Web (emcc)." % target(id).name}
	if template == "":
		template = resolve_command(id)
	if template == "":
		return {"ok": false, "objs": [], "flags": [], "output": "No compiler for %s." % target(id).name}
	var src := raylib_dir()
	var prefix := compiler_prefix(template)
	# Cached per target, compiler and defines: changing either builds a fresh set.
	var key := (" ".join(prefix) + "|" + " ".join(PackedStringArray(rf.defines))).md5_text().substr(0, 8)
	var cache := OS.get_user_data_dir().path_join("raylib").path_join(RAYLIB_VERSION).path_join("%s-%s" % [id, key])
	DirAccess.make_dir_recursive_absolute(cache)
	var prog := find_program(prefix[0])
	if prog == "":
		prog = prefix[0]
	var objs := PackedStringArray()
	var log := ""
	for f in RAYLIB_SOURCES:
		if f in rf.skip:
			continue
		var obj := cache.path_join(f.get_basename() + ".o")
		objs.append(obj)
		if FileAccess.file_exists(obj):
			continue
		var argv := PackedStringArray(prefix.slice(1))
		argv.append_array(["-c", src.path_join(f), "-o", obj, "-O2", "-std=gnu99", "-w", "-I", src, "-I", src.path_join("external/glfw/include")])
		argv.append_array(PackedStringArray(rf.defines))
		var output := []
		var code := OS.execute(prog, argv, output, true, false)
		log += "".join(output)
		if code != 0:
			DirAccess.remove_absolute(obj)
			return {"ok": false, "objs": [], "flags": [], "output": "raylib's %s didn't compile for %s:\n%s" % [f, target(id).name, "".join(output).strip_edges()]}
	var flags := PackedStringArray(["-I", src])
	flags.append_array(PackedStringArray(rf.defines))
	flags.append_array(PackedStringArray(rf.libs))
	return {"ok": true, "objs": objs, "flags": flags, "output": log}


# ------------------------------------------------------------------ the build cache
# (user, 2026-11-08: "when i save and reload a project it should be cached rather than
# have to re-compile unless a change is made"; "every example is pre compiled")
# A program is kept with a fingerprint of everything that made it: the target, the compile
# command, every generated .c / .h (contents, not paths) and, for graphics, which raylib build
# it links. Looked for, in order: beside the program in the project's .build/<target>/
# (`<program>.key`), the shared user://build_cache/<key>/, and res://prebuilt/<key>/ (the
# examples, compiled when the editor is exported: tools/prebuild.gd). Only on a miss is raylib
# built and the program compiled. The Web's several files aren't cached.
const BUILD_CACHE := "user://build_cache"
const PREBUILT := "res://prebuilt"
const BUILD_CACHE_KEEP := 60


## raylib's build key for a target (its cache folder's name, as build_raylib makes it).
static func raylib_key(id: String, template := "") -> String:
	var rf := raylib_flags(id)
	if template == "":
		template = resolve_command(id)
	if rf.is_empty() or template == "":
		return ""
	return "%s-%s" % [id, (" ".join(compiler_prefix(template)) + "|" + " ".join(PackedStringArray(rf.defines))).md5_text().substr(0, 8)]


static func build_key(id: String, srcs: Array, template: String, graphics: bool) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(("%s|%s|%s|%s" % [id, template, RAYLIB_VERSION, raylib_key(id, template) if graphics and id != "dos" else ""]).to_utf8_buffer())
	if id == "dos":
		ctx.update(FileAccess.get_file_as_bytes(CWSDSTUB))  # (DOS programs carry CWSDPMI)
		if _dos_net(srcs):
			ctx.update(FileAccess.get_md5(WATT_LIB).to_utf8_buffer())
	var files := {}
	for src in srcs:
		files[str(src)] = true
		var d := str(src).get_base_dir()
		for f in DirAccess.get_files_at(d):
			if f.get_extension() == "h":
				files[d.path_join(f)] = true
	var names := files.keys()
	names.sort_custom(func(a, b): return str(a).get_file() < str(b).get_file())
	for f in names:
		ctx.update(str(f).get_file().to_utf8_buffer())
		ctx.update(FileAccess.get_file_as_bytes(str(f)))
	return ctx.finish().hex_encode()


## Build (or reuse) a project's program: compile()'s result, plus "cached" (where it came
## from: "" compiled now, "project", "cache", "prebuilt").
static func cached_build(id: String, srcs: Array, out_dir: String, base: String, template := "", graphics := false) -> Dictionary:
	if template == "":
		template = resolve_command(id)
	var out := output_path(id, out_dir, base)
	var cacheable := template != "" and id != "web" and not out.get_extension() in ["html", "js", "wasm"]
	var key := build_key(id, srcs, template, graphics) if cacheable else ""
	if key != "":
		var stamp := out + ".key"
		if FileAccess.file_exists(out) and FileAccess.file_exists(stamp) and FileAccess.get_file_as_string(stamp).strip_edges() == key:
			return {"ok": true, "exit": 0, "output": "", "command": "", "out": out, "cached": "project"}
		for place in [[ProjectSettings.globalize_path(BUILD_CACHE).path_join(key), "cache"], [PREBUILT.path_join(key), "prebuilt"]]:
			var kept: String = str(place[0]).path_join(out.get_file())
			if FileAccess.file_exists(kept):
				DirAccess.make_dir_recursive_absolute(out_dir)
				if _copy_file(kept, out):
					_stamp(out, key)
					return {"ok": true, "exit": 0, "output": "", "command": "", "out": out, "cached": place[1]}
	var extra := {}
	if graphics and id != "dos":  # (MS-DOS draws with its own backend: no raylib)
		var rl := build_raylib(id, template)
		if not rl.ok:
			return {"ok": false, "exit": -1, "output": rl.output, "command": "", "out": out, "cached": ""}
		extra = rl
	var r := compile(id, srcs, out_dir, base, template, extra)
	r["cached"] = ""
	if r.ok and key != "" and FileAccess.file_exists(out):
		_stamp(out, key)
		var keep_dir := ProjectSettings.globalize_path(BUILD_CACHE).path_join(key)
		DirAccess.make_dir_recursive_absolute(keep_dir)
		_copy_file(out, keep_dir.path_join(out.get_file()))
		_trim_cache()
	return r


static func _stamp(out: String, key: String) -> void:
	var f := FileAccess.open(out + ".key", FileAccess.WRITE)
	if f != null:
		f.store_string(key)
		f.close()


## Copies a file (res:// too: the pack) and keeps it runnable.
static func _copy_file(from: String, to: String) -> bool:
	var data := FileAccess.get_file_as_bytes(from)
	if data.is_empty():
		return false
	var f := FileAccess.open(to, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", to])
	return true


## The shared cache keeps its newest BUILD_CACHE_KEEP programs.
static func _trim_cache() -> void:
	var root := ProjectSettings.globalize_path(BUILD_CACHE)
	var dirs := []
	for d in DirAccess.get_directories_at(root):
		dirs.append([FileAccess.get_modified_time(root.path_join(d)), d])
	if dirs.size() <= BUILD_CACHE_KEEP:
		return
	dirs.sort()
	for i in dirs.size() - BUILD_CACHE_KEEP:
		var d: String = root.path_join(str(dirs[i][1]))
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		DirAccess.remove_absolute(d)


## `src`: one .c path or a list of them (a project's files). `extra`: more
## objects and flags for the link (raylib's).
static func compile(id: String, src, out_dir: String, base: String, template := "", extra: Dictionary = {}) -> Dictionary:
	if template == "":
		template = resolve_command(id)
	if template == "":
		return {"ok": false, "exit": -1, "output": "No compiler found for '%s'. Install one of:\n  %s\nor set a custom command in Settings." % [target(id).name, "\n  ".join(target(id).candidates)], "command": "", "out": ""}
	DirAccess.make_dir_recursive_absolute(out_dir)
	var out := output_path(id, out_dir, base)
	var argv := expand(template, {"src": src, "out": out, "dir": out_dir})
	var prog := find_program(argv[0])
	if prog == "":
		prog = argv[0]
	argv.remove_at(0)
	argv.append_array(PackedStringArray(extra.get("objs", [])))
	argv.append_array(PackedStringArray(extra.get("flags", [])))
	if id == "dos" and _dos_net(src):  # networking: Watt-32's BSD sockets (thirdparty/watt32)
		var watt := watt_dir()
		argv.append_array(PackedStringArray(["-I" + watt.path_join("inc"), "-L" + watt.path_join("lib"), "-lwatt", "-lm"]))
	# Windows: Winsock for networking (cbricks_socket.c; unused, it costs nothing). MSVC's cl
	# gets it from the #pragma in the file.
	if (id.begins_with("windows") or (id == "native" and OS.get_name() == "Windows")) and prog.get_file().get_basename() != "cl" and not argv.has("-lws2_32"):
		argv.append("-lws2_32")
	var output := []
	var code := OS.execute(prog, argv, output, true, false)
	var text := "".join(output)
	if code == 0 and id == "dos":
		var why := dos_standalone(out)
		if why != "":
			return {"ok": false, "exit": 1, "output": text + why, "command": prog + " " + " ".join(argv), "out": out}
	return {"ok": code == 0, "exit": code, "output": text, "command": prog + " " + " ".join(argv), "out": out}


const CWSDSTUB := "res://thirdparty/cwsdpmi/CWSDSTUB.EXE"
const WATT_LIB := "res://thirdparty/watt32/lib/libwatt.a"
const PACKET_DRIVER := "res://thirdparty/pktdrvr/NE2000.COM"


## Does this source (a path or a list) include the network project's socket file?
static func _dos_net(src) -> bool:
	var list: Array = src if src is Array or src is PackedStringArray else [src]
	for f in list:
		if str(f).get_file() == "cbricks_socket.c":
			return true
	return false


## Watt-32 (BSD sockets for DJGPP) out of the pack into user://watt32 (compilers can't read it): its folder.
static func watt_dir() -> String:
	var dir := OS.get_user_data_dir().path_join("watt32")
	if not FileAccess.file_exists(dir.path_join("lib/libwatt.a")) or FileAccess.get_md5(dir.path_join("lib/libwatt.a")) != FileAccess.get_md5(WATT_LIB):
		CBProject.copy_dir("res://thirdparty/watt32", dir)
	return dir

## An MS-DOS program that runs on plain DOS (2026-11-08): DJGPP's .exe is a small stub that
## needs a DPMI host (CWSDPMI.EXE) beside it; its COFF image goes behind CWSDSTUB.EXE instead,
## which carries CWSDPMI (thirdparty/cwsdpmi: what exe2coff + "copy /b" do). "" or why not.
static func dos_standalone(exe: String) -> String:
	var b := FileAccess.get_file_as_bytes(exe)
	var stub := FileAccess.get_file_as_bytes(CWSDSTUB)
	if b.size() < 64 or stub.is_empty():
		return "MS-DOS: couldn't read %s or CWSDPMI's stub." % exe.get_file()
	var at := 0
	if b[0] == 0x4D and b[1] == 0x5A:  # "MZ": the go32 stub, its size from the header
		var last := b[2] | (b[3] << 8)
		var pages := b[4] | (b[5] << 8)
		at = pages * 512 - ((512 - last) if last != 0 else 0)
	if at + 2 > b.size() or not (b[at] == 0x4C and b[at + 1] == 0x01):  # COFF i386 magic 0x014c
		return "MS-DOS: %s isn't a DJGPP program (no COFF image after its stub)." % exe.get_file()
	var f := FileAccess.open(exe, FileAccess.WRITE)
	if f == null:
		return "MS-DOS: couldn't write %s." % exe.get_file()
	f.store_buffer(stub)
	f.store_buffer(b.slice(at))
	f.close()
	return ""


# ------------------------------------------------------------------ project export
#
# The exported project is plain C99 plus build files for every way of building
# it: any C compiler on the machine itself, zig for cross-compiling to the
# platforms below from anywhere, CMake for IDEs and SDK toolchains (Visual
# Studio, Xcode, Android NDK, Emscripten...), and Emscripten for the web.

## Platforms zig reaches from any machine: [zig target, file suffix, what it is].
const ZIG_PLATFORMS := [
	["x86_64-linux-musl", "", "Linux x86_64 (static)"],
	["x86-linux-musl", "", "Linux x86 32-bit (static)"],
	["aarch64-linux-musl", "", "Linux ARM64 / Raspberry Pi 64-bit (static)"],
	["arm-linux-musleabihf", "", "Linux ARMv7 / Raspberry Pi 32-bit (static)"],
	["riscv64-linux-musl", "", "Linux RISC-V 64 (static)"],
	["powerpc64le-linux-musl", "", "Linux POWER little-endian (static)"],
	["s390x-linux-musl", "", "Linux IBM Z (static)"],
	["loongarch64-linux-musl", "", "Linux LoongArch 64 (static)"],
	["mipsel-linux-musleabi", "", "Linux MIPS little-endian (static)"],
	["x86_64-windows-gnu", ".exe", "Windows x86_64"],
	["x86-windows-gnu", ".exe", "Windows x86 32-bit"],
	["aarch64-windows-gnu", ".exe", "Windows ARM64"],
	["aarch64-macos", "", "macOS Apple Silicon"],
	["x86_64-macos", "", "macOS Intel"],
	["x86_64-freebsd", "", "FreeBSD x86_64"],
	["aarch64-freebsd", "", "FreeBSD ARM64"],
	["x86_64-netbsd", "", "NetBSD x86_64"],
	["wasm32-wasi", ".wasm", "WebAssembly WASI (wasmtime, wasmer, browsers with a WASI shim)"],
]


static func _zig_needs_lm(triple: String) -> bool:
	return not (triple.contains("windows") or triple.contains("macos"))


static func makefile(base: String, srcs: PackedStringArray) -> String:
	var triples := PackedStringArray()
	for p in ZIG_PLATFORMS:
		triples.append(p[0])
	return """# Generated by C-Bricks. The program is plain C99: any C compiler builds it.
#
#   make                      this computer, with $(CC)
#   make TARGET=<zig target>  another platform, cross-compiled with zig
#   make all-targets          every platform zig reaches (see ZIG_TARGETS)
#   make web                  HTML + WebAssembly with Emscripten (emcc)
#   make clean

NAME    ?= {base}
SRC      = {srcs}
OUT      = build
CC      ?= cc
CFLAGS  ?= -std=c99 -O2 -Wall
LDLIBS  ?= -lm
ZIG     ?= zig
EMCC    ?= emcc

ifeq ($(OS),Windows_NT)
  EXE = .exe
  LDLIBS += -lws2_32
endif

ZIG_TARGETS = {triples}

# File suffix and libraries for a zig target.
suffix_of = $(if $(findstring windows,$(1)),.exe,$(if $(findstring wasm,$(1)),.wasm,))
libs_of   = $(if $(findstring windows,$(1)),-lws2_32,$(if $(findstring macos,$(1)),,-lm))

.PHONY: native all-targets web clean $(ZIG_TARGETS)

ifdef TARGET
native: $(TARGET)
else
native:
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(SRC) -o $(OUT)/$(NAME)$(EXE) $(LDLIBS)
endif

$(ZIG_TARGETS):
	@mkdir -p $(OUT)
	$(ZIG) cc -target $@ $(CFLAGS) $(SRC) -o $(OUT)/$(NAME)-$@$(call suffix_of,$@) $(call libs_of,$@)

all-targets: $(ZIG_TARGETS)

web:
	@mkdir -p $(OUT)
	$(EMCC) $(CFLAGS) $(SRC) -o $(OUT)/$(NAME).html -sEXIT_RUNTIME=1

clean:
	rm -rf $(OUT)
""".replace("{base}", base).replace("{triples}", " \\\n              ".join(triples)).replace("{srcs}", " ".join(srcs))


static func cmakelists(base: String, srcs: PackedStringArray) -> String:
	return """# Generated by C-Bricks. Plain C99: works with every CMake generator and toolchain.
#   cmake -B build && cmake --build build                      (this computer)
#   cmake -B build -G "Visual Studio 17 2022"                  (Windows, MSVC)
#   cmake -B build -G Xcode                                    (macOS)
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=<ndk>/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a
#   emcmake cmake -B build && cmake --build build              (web)
cmake_minimum_required(VERSION 3.13)
project({base} C)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
add_executable({base} {srcs})

# The maths library is separate on Unix-likes, built in elsewhere.
include(CheckLibraryExists)
check_library_exists(m floor "" HAVE_LIBM)
if(HAVE_LIBM)
  target_link_libraries({base} PRIVATE m)
endif()

if(WIN32)
  target_link_libraries({base} PRIVATE ws2_32)  # Winsock (networking)
endif()

if(MSVC)
  target_compile_definitions({base} PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options({base} PRIVATE /W3)
else()
  target_compile_options({base} PRIVATE -Wall)
endif()

if(EMSCRIPTEN)
  set_target_properties({base} PROPERTIES SUFFIX ".html")
  target_link_options({base} PRIVATE -sEXIT_RUNTIME=1)
endif()
""".replace("{base}", base).replace("{srcs}", " ".join(srcs))


static func build_sh(base: String, srcs: PackedStringArray) -> String:
	var lines := PackedStringArray()
	for p in ZIG_PLATFORMS:
		lines.append(p[0])
	return """#!/bin/sh
# Generated by C-Bricks.
#   ./build.sh                 build for this computer (cc, gcc, clang, tcc or zig)
#   ./build.sh all             every platform zig reaches
#   ./build.sh <zig target>... e.g. ./build.sh x86_64-windows-gnu aarch64-macos
set -e
cd "$(dirname "$0")"
mkdir -p build
NAME="{base}"
SRC="{srcs}"
TARGETS="{targets}"

native() {
	for c in "${CC:-}" cc gcc clang tcc; do
		if [ -n "$c" ] && command -v "$c" >/dev/null 2>&1; then
			echo "$c -std=c99 -O2 $SRC -o build/$NAME -lm"
			"$c" -std=c99 -O2 $SRC -o "build/$NAME" -lm
			return
		fi
	done
	if command -v zig >/dev/null 2>&1; then
		zig cc -std=c99 -O2 $SRC -o "build/$NAME" -lm
		return
	fi
	echo "No C compiler found: install gcc, clang or zig." >&2
	exit 1
}

cross() {
	t="$1"; ext=""; libs="-lm"
	case "$t" in
		*windows*) ext=".exe"; libs="-lws2_32" ;;
		*macos*) libs="" ;;
		wasm*) ext=".wasm" ;;
	esac
	command -v zig >/dev/null 2>&1 || { echo "Cross-compiling needs zig (ziglang.org)." >&2; exit 1; }
	echo "zig cc -target $t -> build/$NAME-$t$ext"
	zig cc -target "$t" -std=c99 -O2 $SRC -o "build/$NAME-$t$ext" $libs
}

if [ $# -eq 0 ]; then
	native
elif [ "$1" = "all" ]; then
	for t in $TARGETS; do cross "$t"; done
else
	for t in "$@"; do cross "$t"; done
fi
""".replace("{base}", base).replace("{targets}", " ".join(lines)).replace("{srcs}", " ".join(srcs))


static func build_bat(base: String, srcs: PackedStringArray) -> String:
	var lines := PackedStringArray()
	for p in ZIG_PLATFORMS:
		lines.append(p[0])
	return """@echo off
rem Generated by C-Bricks.
rem   build.bat              this computer: MSVC (Developer Command Prompt), clang, gcc or zig
rem   build.bat all          every platform zig reaches
rem   build.bat <zig target> e.g. build.bat aarch64-windows-gnu
setlocal
cd /d "%~dp0"
if not exist build mkdir build
set NAME={base}
set SRC={srcs_win}
if "%~1"=="" goto native
if /i "%~1"=="all" (
  for %%t in ({targets}) do call :cross %%t
  goto :eof
)
:args
if "%~1"=="" goto :eof
call :cross %~1
shift
goto args

:native
where cl >nul 2>nul && (cl /nologo /O2 /D_CRT_SECURE_NO_WARNINGS %SRC% /Fe:build\\%NAME%.exe & goto :eof)
where clang >nul 2>nul && (clang -std=c99 -O2 %SRC% -o build\\%NAME%.exe -lws2_32 & goto :eof)
where gcc >nul 2>nul && (gcc -std=c99 -O2 %SRC% -o build\\%NAME%.exe -lm -lws2_32 & goto :eof)
where zig >nul 2>nul && (zig cc -std=c99 -O2 %SRC% -o build\\%NAME%.exe -lws2_32 & goto :eof)
echo No C compiler found. Install Visual Studio Build Tools, LLVM, MSYS2 or zig.
exit /b 1

:cross
set T=%~1
set EXT=
set LIBS=-lm
echo %T% | findstr /i "windows" >nul && (set EXT=.exe& set LIBS=-lws2_32)
echo %T% | findstr /i "macos" >nul && set LIBS=
echo %T% | findstr /i "wasm" >nul && set EXT=.wasm
where zig >nul 2>nul || (echo Cross-compiling needs zig ^(ziglang.org^). & exit /b 1)
echo zig cc -target %T%
zig cc -target %T% -std=c99 -O2 %SRC% -o build\\%NAME%-%T%%EXT% %LIBS%
goto :eof
""".replace("{base}", base).replace("{targets}", " ".join(lines)).replace("{srcs_win}", " ".join(Array(srcs).map(func(x): return x.replace("/", "\\"))))


static func project_readme(base: String) -> String:
	var rows := PackedStringArray()
	for p in ZIG_PLATFORMS:
		rows.append("| %s | `make %s` or `./build.sh %s` |" % [p[2], p[0], p[0]])
	return """# {base}

Made with C-Bricks. `src/` is plain, portable C99 (it only uses the C standard
library: stdio, stdlib, stdbool, string, math, time), so any hosted C99 compiler
builds it for its platform:

    cc -std=c99 src/*.c -o {base} -lm

Run it from this folder, so it finds its files (`assets/`...), or pass `--cd <this folder>`.
`./build/{base} --help` lists the flags every C-Bricks program takes (--trace, --seed,
--input, --max-steps, --verbose...): handy for debugging and tests.

## This computer

| How | Command |
| --- | --- |
| Make | `make` |
| Shell script | `./build.sh` |
| Windows | `build.bat` (MSVC Developer Prompt, clang, gcc or zig) |
| CMake (any IDE) | `cmake -B build && cmake --build build` |
| Visual Studio | `cmake -B build -G "Visual Studio 17 2022"`, open the .sln |
| Xcode | `cmake -B build -G Xcode`, open the .xcodeproj |

## Other platforms, from any machine (zig)

Install zig (https://ziglang.org: one download, no setup) and pick a target:

| Platform | Command |
| --- | --- |
{rows}
| Every one above | `make all-targets` or `./build.sh all` |

Any other zig target works the same way: `make TARGET=<target>` (see `zig targets`).

## Platform SDKs

| Platform | Command |
| --- | --- |
| Web (HTML + WASM) | `make web`, or `emcmake cmake -B build && cmake --build build` (Emscripten) |
| Android | `cmake -B build -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a` (a command-line program: run it with `adb shell`) |
| iOS / tvOS | `cmake -B build -G Xcode -DCMAKE_SYSTEM_NAME=iOS` (needs an app wrapper to show its output) |
| Any cross compiler | `make CC=<compiler>`, e.g. `make CC=arm-none-linux-gnueabihf-gcc` |
| Embedded boards | any toolchain with a C library that has stdio (newlib, picolibc): `<toolchain>-gcc -std=c99 src/*.c -lm` |

Output goes to `build/`.
""".replace("{base}", base).replace("{rows}", "\n".join(rows))


static func project_files(base: String, result: Dictionary) -> Dictionary:
	var srcs := PackedStringArray()
	for name in result.sources:
		srcs.append("src/" + name)
	var files := {
		"Makefile": makefile(base, srcs),
		"CMakeLists.txt": cmakelists(base, srcs),
		"build.sh": build_sh(base, srcs),
		"build.bat": build_bat(base, srcs).replace("\n", "\r\n"),
		"README.md": project_readme(base),
		".gitignore": "build/\n",
	}
	if result.get("graphics", false):
		files["Makefile"] = gfx_makefile(base, srcs)
		files["CMakeLists.txt"] = gfx_cmakelists(base, srcs)
		files["build.sh"] = gfx_build_sh(base, srcs)
		files["build.bat"] = gfx_build_bat(base, srcs).replace("\n", "\r\n")
		files["README.md"] = project_readme(base) + GFX_README
	for name in result.files:
		files["src/" + name] = result.files[name]
	return files


# ---- graphics projects: raylib's source goes along (thirdparty/raylib, zlib license)

const RL := "thirdparty/raylib/src"
const RL_FILES := "$(RL)/rcore.c $(RL)/rshapes.c $(RL)/rtextures.c $(RL)/rtext.c $(RL)/rmodels.c $(RL)/raudio.c $(RL)/utils.c"
const GFX_README := """
## Graphics (raylib)

This program draws with [raylib](https://www.raylib.com) (zlib license), whose
source is in `thirdparty/raylib/` and is compiled with it. Windowed builds need the
platform's OpenGL / windowing libraries:

| Platform | What it needs | Build |
| --- | --- | --- |
| Linux | X11 and OpenGL dev packages (Debian / Ubuntu / Raspberry Pi OS: `sudo apt install libx11-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev libgl-dev`) | `make` |
| Windows | nothing extra (MSVC, MinGW or zig) | `build.bat`, or `make x86_64-windows-gnu` from anywhere with zig |
| macOS | Xcode's command-line tools | `make` |
| Web | Emscripten | `make web` |
"""


static func gfx_makefile(base: String, srcs: PackedStringArray) -> String:
	return """# Generated by C-Bricks (a graphics program: raylib is compiled in, see README.md).
#   make                      this computer
#   make x86_64-windows-gnu   Windows (also x86-windows-gnu, aarch64-windows-gnu), with zig
#   make web                  HTML + WebAssembly with Emscripten
NAME    ?= {base}
SRC      = {srcs}
OUT      = build
RL       = thirdparty/raylib/src
RL_SRC   = {rl} $(RL)/rglfw.c
CC      ?= cc
ZIG     ?= zig
EMCC    ?= emcc
FLAGS    = -std=gnu99 -O2 -I$(RL) -I$(RL)/external/glfw/include -DPLATFORM_DESKTOP -DGRAPHICS_API_OPENGL_33

ifeq ($(OS),Windows_NT)
  EXE  = .exe
  LIBS = -lopengl32 -lgdi32 -lwinmm -lws2_32
else ifeq ($(shell uname),Darwin)
  LIBS = -framework Cocoa -framework IOKit -framework CoreVideo -framework OpenGL
else
  FLAGS := $(subst OPENGL_33,OPENGL_21,$(FLAGS)) -D_GNU_SOURCE -D_GLFW_X11
  LIBS = -lGL -lm -lpthread -ldl -lrt -lX11
endif

WINDOWS = x86_64-windows-gnu x86-windows-gnu aarch64-windows-gnu
.PHONY: native web clean $(WINDOWS)

native:
	@mkdir -p $(OUT)
	$(CC) $(FLAGS) $(SRC) $(RL_SRC) -o $(OUT)/$(NAME)$(EXE) $(LIBS)

$(WINDOWS):
	@mkdir -p $(OUT)
	$(ZIG) cc -target $@ -std=gnu99 -O2 -I$(RL) -I$(RL)/external/glfw/include -DPLATFORM_DESKTOP -DGRAPHICS_API_OPENGL_33 $(SRC) $(RL_SRC) -o $(OUT)/$(NAME)-$@.exe -lopengl32 -lgdi32 -lwinmm -lws2_32

web:
	@mkdir -p $(OUT)
	$(EMCC) -std=gnu99 -O2 -I$(RL) -DPLATFORM_WEB -DGRAPHICS_API_OPENGL_ES2 $(SRC) {rl} -o $(OUT)/$(NAME).html -sUSE_GLFW=3 -sASYNCIFY

clean:
	rm -rf $(OUT)
""".replace("{base}", base).replace("{srcs}", " ".join(srcs)).replace("{rl}", RL_FILES)


static func gfx_cmakelists(base: String, srcs: PackedStringArray) -> String:
	return """# Generated by C-Bricks (a graphics program: raylib is compiled in, see README.md).
cmake_minimum_required(VERSION 3.13)
project({base} C)
set(CMAKE_C_STANDARD 99)
set(RL ${CMAKE_SOURCE_DIR}/thirdparty/raylib/src)
set(RL_SRC ${RL}/rcore.c ${RL}/rshapes.c ${RL}/rtextures.c ${RL}/rtext.c ${RL}/rmodels.c ${RL}/raudio.c ${RL}/utils.c)
if(NOT EMSCRIPTEN)
  list(APPEND RL_SRC ${RL}/rglfw.c)
endif()
add_executable({base} {srcs} ${RL_SRC})
target_include_directories({base} PRIVATE ${RL} ${RL}/external/glfw/include)
if(EMSCRIPTEN)
  target_compile_definitions({base} PRIVATE PLATFORM_WEB GRAPHICS_API_OPENGL_ES2)
  set_target_properties({base} PROPERTIES SUFFIX ".html")
  target_link_options({base} PRIVATE -sUSE_GLFW=3 -sASYNCIFY)
else()
  target_compile_definitions({base} PRIVATE PLATFORM_DESKTOP)
endif()
if(WIN32 OR APPLE)
  target_compile_definitions({base} PRIVATE GRAPHICS_API_OPENGL_33)
elseif(NOT EMSCRIPTEN)
  target_compile_definitions({base} PRIVATE GRAPHICS_API_OPENGL_21)
endif()
if(WIN32)
  target_link_libraries({base} PRIVATE opengl32 gdi32 winmm ws2_32)
elseif(APPLE)
  target_link_libraries({base} PRIVATE "-framework Cocoa" "-framework IOKit" "-framework CoreVideo" "-framework OpenGL")
elseif(NOT EMSCRIPTEN)
  find_package(OpenGL REQUIRED)
  find_package(X11 REQUIRED)
  target_compile_definitions({base} PRIVATE _GNU_SOURCE _GLFW_X11)
  target_link_libraries({base} PRIVATE OpenGL::GL ${X11_LIBRARIES} m pthread dl rt)
endif()
if(MSVC)
  target_compile_definitions({base} PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()
""".replace("{base}", base).replace("{srcs}", " ".join(srcs))


static func gfx_build_sh(base: String, srcs: PackedStringArray) -> String:
	return """#!/bin/sh
# Generated by C-Bricks (a graphics program: raylib is compiled in, see README.md).
#   ./build.sh                  this computer
#   ./build.sh x86_64-windows-gnu  Windows with zig (also x86-windows-gnu, aarch64-windows-gnu)
set -e
cd "$(dirname "$0")"
mkdir -p build
NAME="{base}"
RL=thirdparty/raylib/src
SRC="{srcs} $RL/rcore.c $RL/rshapes.c $RL/rtextures.c $RL/rtext.c $RL/rmodels.c $RL/raudio.c $RL/utils.c $RL/rglfw.c"
FLAGS="-std=gnu99 -O2 -I$RL -I$RL/external/glfw/include -DPLATFORM_DESKTOP -DGRAPHICS_API_OPENGL_33"
if [ $# -gt 0 ]; then
	for t in "$@"; do
		echo "zig cc -target $t -> build/$NAME-$t.exe"
		zig cc -target "$t" $FLAGS $SRC -o "build/$NAME-$t.exe" -lopengl32 -lgdi32 -lwinmm -lws2_32
	done
	exit 0
fi
case "$(uname)" in
	Darwin) LIBS="-framework Cocoa -framework IOKit -framework CoreVideo -framework OpenGL" ;;
	*) FLAGS="$(echo "$FLAGS" | sed s/OPENGL_33/OPENGL_21/) -D_GNU_SOURCE -D_GLFW_X11"; LIBS="-lGL -lm -lpthread -ldl -lrt -lX11" ;;
esac
CC="${CC:-cc}"
echo "$CC ... -> build/$NAME"
$CC $FLAGS $SRC -o "build/$NAME" $LIBS
""".replace("{base}", base).replace("{srcs}", " ".join(srcs))


static func gfx_build_bat(base: String, srcs: PackedStringArray) -> String:
	var win := " ".join(Array(srcs).map(func(x): return x.replace("/", "\\")))
	return """@echo off
rem Generated by C-Bricks (a graphics program: raylib is compiled in, see README.md).
setlocal
cd /d "%~dp0"
if not exist build mkdir build
set NAME={base}
set RL=thirdparty\\raylib\\src
set SRC={win} %RL%\\rcore.c %RL%\\rshapes.c %RL%\\rtextures.c %RL%\\rtext.c %RL%\\rmodels.c %RL%\\raudio.c %RL%\\utils.c %RL%\\rglfw.c
where cl >nul 2>nul && (cl /nologo /O2 /D_CRT_SECURE_NO_WARNINGS /DPLATFORM_DESKTOP /DGRAPHICS_API_OPENGL_33 /I%RL% /I%RL%\\external\\glfw\\include %SRC% /Fe:build\\%NAME%.exe opengl32.lib gdi32.lib winmm.lib user32.lib shell32.lib ws2_32.lib & goto :eof)
set FLAGS=-std=gnu99 -O2 -DPLATFORM_DESKTOP -DGRAPHICS_API_OPENGL_33 -I%RL% -I%RL%\\external\\glfw\\include
set LIBS=-lopengl32 -lgdi32 -lwinmm -lws2_32
where gcc >nul 2>nul && (gcc %FLAGS% %SRC% -o build\\%NAME%.exe %LIBS% & goto :eof)
where clang >nul 2>nul && (clang %FLAGS% %SRC% -o build\\%NAME%.exe %LIBS% & goto :eof)
where zig >nul 2>nul && (zig cc %FLAGS% %SRC% -o build\\%NAME%.exe %LIBS% & goto :eof)
echo No C compiler found. Install Visual Studio Build Tools, LLVM, MSYS2 or zig.
exit /b 1
""".replace("{base}", base).replace("{win}", win)


## Write a standalone, portable C project: its sources in src/, the project's
## assets copied as they are, and the build files. Returns an error message or "".
## The exported C project in `dir`. `progress` (optional; called from the exporting thread):
## progress.call(done, total, what) after each file (user, 2026-11-08: a progress bar).
static func export_project(dir: String, base: String, result: Dictionary, project_dir: String = "", progress := Callable()) -> String:
	var files := project_files(base, result)
	var assets: Array = Array(CBProject.list_assets(project_dir)) if project_dir != "" else []
	var raylib: Array = []
	if result.get("graphics", false):
		_res_files(RAYLIB_RES, "", raylib)
	var total: int = files.size() + assets.size() + raylib.size()
	var done := [0]  # (a lambda captures a local by value: an Array is shared)
	var step := func(what: String) -> void:
		done[0] += 1
		if progress.is_valid():
			progress.call(done[0], total, what)
	DirAccess.make_dir_recursive_absolute(dir.path_join("src"))
	for name in files:
		var path := dir.path_join(name)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var fa := FileAccess.open(path, FileAccess.WRITE)
		if fa == null:
			return "Could not write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
		fa.store_string(files[name])
		fa.close()
		step.call(name)
	for rel in assets:
		DirAccess.make_dir_recursive_absolute(dir.path_join(rel).get_base_dir())
		DirAccess.copy_absolute(project_dir.path_join(rel), dir.path_join(rel))
		step.call(rel)
	if result.get("graphics", false):
		var to := dir.path_join("thirdparty/raylib/src")
		for rel in raylib:
			DirAccess.make_dir_recursive_absolute(to.path_join(rel).get_base_dir())
			var fa := FileAccess.open(to.path_join(rel), FileAccess.WRITE)
			if fa != null:
				fa.store_buffer(FileAccess.get_file_as_bytes(RAYLIB_RES.path_join(rel)))
				fa.close()
			step.call("thirdparty/raylib/src/" + rel)
		var lic := FileAccess.open(dir.path_join("thirdparty/raylib/LICENSE"), FileAccess.WRITE)
		if lic != null:
			lic.store_string(FileAccess.get_file_as_string("res://thirdparty/raylib/LICENSE"))
			lic.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(dir.path_join("build.sh"), 493)  # rwxr-xr-x
	return ""


## Every file under a res:// folder, as paths from it (a .remap's name without .remap).
static func _res_files(root: String, rel: String, out: Array) -> void:
	var here := root.path_join(rel) if rel != "" else root
	for f in DirAccess.get_files_at(here):
		out.append(rel.path_join(f.trim_suffix(".remap")) if rel != "" else f.trim_suffix(".remap"))
	for d in DirAccess.get_directories_at(here):
		_res_files(root, rel.path_join(d) if rel != "" else d, out)


## Zip the project into memory (the browser build of the editor downloads it).
static func project_zip(base: String, result: Dictionary, project_dir: String = "") -> PackedByteArray:
	var path := "user://_export.zip"
	var zp := ZIPPacker.new()
	if zp.open(path) != OK:
		return PackedByteArray()
	var files := project_files(base, result)
	for name in files:
		zp.start_file(base + "/" + name)
		zp.write_file(files[name].to_utf8_buffer())
		zp.close_file()
	if project_dir != "":
		for rel in CBProject.list_assets(project_dir):
			zp.start_file(base + "/" + rel)
			zp.write_file(FileAccess.get_file_as_bytes(project_dir.path_join(rel)))
			zp.close_file()
	zp.close()
	return FileAccess.get_file_as_bytes(path)
