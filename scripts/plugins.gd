class_name TargetPlugins
extends RefCounted
## Target device plugins (2026-11-14): a folder with a `target.cfg` manifest, a C backend
## (`cb_be_*`, scripts/runtime/cb_backend.h) and optionally a build target of its own. The built-in
## MS-DOS and raylib backends are described by the same format (res://plugins/*/target.cfg), so
## the format is proven by what ships.
##
## target.cfg:
##   [plugin]   id, title, version, api (= CB_BACKEND_API), description
##   [target]   (optional: adds a Target to the list) name, ext, candidates [compiler templates with
##              {src} and {out}], run [templates], caps ["graphics", "3d", "network"], defines [], libs []
##   [backend]  (optional) file (the C file), targets [the target ids that pick it with Automatic;
##              default: this plugin's target; "*" = any target), except [targets "*" does not cover],
##              caps [what the programs it builds can do], sources [more .c / .h files it needs]
##   [hooks]    (optional, trusted code: asked about before it runs) run, package: script paths
##
## A plugin dictionary: {"id", "title", "version", "api", "description", "dir", "builtin",
## "target": {} or the Toolchains target dictionary, "backend": {} or {"id", "file", "targets", "caps",
## "sources", "defines", "libs"}, "hooks": {"run", "package"}}.

const API := 1
const BUILTIN_DIRS := ["res://plugins/ms-dos", "res://plugins/raylib"]
const CAPS := ["graphics", "3d", "network"]

static var registry := {}   ## id -> plugin (built-ins first, then the loaded ones)
static var _loaded_builtin := false


static func _builtin() -> void:
	if _loaded_builtin:
		return
	_loaded_builtin = true
	for d in BUILTIN_DIRS:
		var r := load_dir(d, true)
		if r.ok:
			registry[r.plugin.id] = r.plugin
		else:
			push_error("built-in plugin %s: %s" % [d, r.error])


## Parses and checks one plugin folder. -> {"ok", "error", "plugin"} (nothing is registered).
static func load_dir(dir: String, builtin := false) -> Dictionary:
	var cfg_path := dir.path_join("target.cfg")
	if not FileAccess.file_exists(cfg_path):
		return {"ok": false, "error": "no target.cfg in %s" % dir}
	return parse(FileAccess.get_file_as_string(cfg_path), dir, builtin)


static func parse(text: String, dir: String, builtin := false) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return _bad("target.cfg is not a valid config file")
	var id := str(cfg.get_value("plugin", "id", ""))
	var re := RegEx.create_from_string("^[a-z0-9][a-z0-9_-]*$")
	if re.search(id) == null:
		return _bad("[plugin] id must be lowercase letters, digits, - or _ (got '%s')" % id)
	if int(cfg.get_value("plugin", "api", 0)) != API:
		return _bad("[plugin] api = %s, but this C-Bricks speaks backend API %d" % [str(cfg.get_value("plugin", "api", "missing")), API])
	var plugin := {
		"id": id, "title": str(cfg.get_value("plugin", "title", id)), "version": str(cfg.get_value("plugin", "version", "1")),
		"api": API, "description": str(cfg.get_value("plugin", "description", "")), "dir": dir, "builtin": builtin,
		"target": {}, "backend": {}, "hooks": {},
	}
	if cfg.has_section("target"):
		var t := _target(cfg, id, builtin)
		if t.has("error"):
			return _bad(str(t.error))
		plugin.target = t
	if cfg.has_section("backend"):
		var b := _backend(cfg, id, dir, plugin.target)
		if b.has("error"):
			return _bad(str(b.error))
		plugin.backend = b
	if plugin.target.is_empty() and plugin.backend.is_empty():
		return _bad("a plugin needs a [target] or a [backend]")
	for k in cfg.get_section_keys("hooks") if cfg.has_section("hooks") else PackedStringArray():
		if not k in ["run", "package"]:
			return _bad("[hooks] %s: unknown hook (run, package)" % k)
		var rel := str(cfg.get_value("hooks", k))
		if rel.is_absolute_path() or ".." in rel.split("/"):
			return _bad("[hooks] %s must be a file inside the plugin's folder" % k)
		plugin.hooks[k] = rel
	return {"ok": true, "error": "", "plugin": plugin}


static func _bad(why: String) -> Dictionary:
	return {"ok": false, "error": why}


static func _strings(cfg: ConfigFile, section: String, key: String) -> Array:
	var v = cfg.get_value(section, key, [])
	return Array(v) if v is Array or v is PackedStringArray else [str(v)]


static func _target(cfg: ConfigFile, id: String, builtin: bool) -> Dictionary:
	if not builtin and Toolchains.BUILTIN_TARGETS.any(func(t): return t.id == id):
		return {"error": "[plugin] id '%s' is a built-in target's name" % id}
	var cands := _strings(cfg, "target", "candidates")
	if cands.is_empty():
		return {"error": "[target] candidates: list at least one compiler command"}
	for c in cands:
		if not "{src}" in str(c) or not "{out}" in str(c):
			return {"error": "[target] candidates: '%s' needs {src} and {out}" % str(c)}
	var caps := _strings(cfg, "target", "caps")
	for c in caps:
		if not c in CAPS:
			return {"error": "[target] caps: '%s' is not one of %s" % [str(c), ", ".join(CAPS)]}
	return {
		"id": id, "name": str(cfg.get_value("target", "name", id)), "ext": str(cfg.get_value("target", "ext", "-" + id)),
		"candidates": cands, "run": _strings(cfg, "target", "run"), "caps": caps,
		"defines": _strings(cfg, "target", "defines"), "libs": _strings(cfg, "target", "libs"), "plugin": id,
	}


static func _backend(cfg: ConfigFile, id: String, dir: String, target: Dictionary) -> Dictionary:
	var rel := str(cfg.get_value("backend", "file", ""))
	if rel == "":
		return {"error": "[backend] file: name the backend's C file"}
	var file := dir.path_join(rel).simplify_path()
	if not FileAccess.file_exists(file):
		return {"error": "[backend] file: %s does not exist" % rel}
	var targets := _strings(cfg, "backend", "targets")
	if targets.is_empty() and not target.is_empty():
		targets = [id]
	if targets.is_empty():
		return {"error": "[backend] targets: which targets pick this backend?"}
	var caps := _strings(cfg, "backend", "caps")
	for c in caps:
		if not c in CAPS:
			return {"error": "[backend] caps: '%s' is not one of %s" % [str(c), ", ".join(CAPS)]}
	var sources := []
	for s in _strings(cfg, "backend", "sources"):
		var p := dir.path_join(str(s)).simplify_path()
		if not FileAccess.file_exists(p):
			return {"error": "[backend] sources: %s does not exist" % str(s)}
		sources.append(p)
	return {"id": id, "file": file, "targets": targets, "except": _strings(cfg, "backend", "except"), "caps": caps, "sources": sources}


## Adds a checked plugin (replacing one with the same id). A user plugin can't take a built-in's id.
static func register(plugin: Dictionary) -> String:
	_builtin()
	var id := str(plugin.id)
	if registry.has(id) and registry[id].builtin and not plugin.builtin:
		return "'%s' is a built-in plugin" % id
	registry[id] = plugin
	Toolchains.clear_cache()
	return ""


static func unregister(id: String) -> void:
	if registry.has(id) and not registry[id].builtin:
		registry.erase(id)


## Plugins that add targets, in the Toolchains target shape.
static func targets() -> Array:
	_builtin()
	var out := []
	for id in registry:
		if not registry[id].target.is_empty() and not registry[id].builtin:
			out.append(registry[id].target)
	return out


## The backend an Automatic pick gives a target: a backend naming the target beats one for "*"
## (a user plugin beats a built-in). "" when none.
static func backend_for(target_id: String) -> String:
	_builtin()
	var wild := ""
	for id in registry:
		var b: Dictionary = registry[id].backend
		if b.is_empty():
			continue
		if target_id in b.targets:
			return str(b.id)
		if "*" in b.targets and not target_id in b.except and wild == "":
			wild = str(b.id)
	return wild


static func backend(id: String) -> Dictionary:
	_builtin()
	return registry[id].backend if registry.has(id) else {}


static func backend_ids() -> PackedStringArray:
	_builtin()
	var out := PackedStringArray()
	for id in registry:
		if not registry[id].backend.is_empty():
			out.append(id)
	return out


## Why a backend can't build for a target ("" if it can).
static func backend_problem(backend_id: String, target_id: String) -> String:
	var b := backend(backend_id)
	if b.is_empty():
		return "no backend called '%s'" % backend_id
	if target_id in b.targets or ("*" in b.targets and not target_id in b.except):
		return ""
	var only := "the targets " + ", ".join(PackedStringArray(b.targets)) if not "*" in b.targets else "every target but " + ", ".join(PackedStringArray(b.except))
	return "the '%s' backend only builds for %s: pick Automatic or another backend in Project Settings ▸ Graphics backend, or change the Target." % [backend_id, only]


# ------------------------------------------------------------------ per project

## The plugin ids a project uses -> the version it was added at (project.cbproj [plugins]).
static func project_plugins(dir: String) -> Dictionary:
	var out := {}
	if dir == "":
		return out
	var cf := CBProject.load_config(dir)
	for id in cf.get_section_keys("plugins") if cf.has_section("plugins") else PackedStringArray():
		out[id] = str(cf.get_value("plugins", id))
	return out


static var _project_ids: Array = []   ## the ids the open project has registered
static var active_project := ""   ## the open project (use_project's last dir)
static var project_errors: Array = []   ## why a listed plugin didn't load: [{"id", "error"}]


## Makes `dir`'s plugins (plugins/<id>/ for each id in [plugins]) the project-scoped ones: the previous
## project's are dropped. "" = no project. Called by ProjectBuild.generate and the editor.
static func use_project(dir: String) -> void:
	_builtin()
	active_project = dir
	var changed := false
	for id in _project_ids:
		if registry.has(id) and not registry[id].builtin:
			registry.erase(id)
			changed = true
	_project_ids = []
	project_errors = []
	for id in project_plugins(dir):
		var r := load_dir(dir.path_join(CBProject.PLUGINS_DIR).path_join(id))
		if r.ok and r.plugin.id != id:
			r = _bad("the folder is called '%s' but its target.cfg says id '%s'" % [id, r.plugin.id])
		if not r.ok:
			project_errors.append({"id": id, "error": r.error})
			continue
		if registry.has(id):
			project_errors.append({"id": id, "error": "another plugin already has this id"})
			continue
		registry[id] = r.plugin
		_project_ids.append(id)
		changed = true
	if changed:
		Toolchains.clear_cache()


## Copies a plugin folder into the project (plugins/<id>/) and lists it in project.cbproj. "" or why not.
static func add_to_project(dir: String, plugin_dir: String) -> String:
	var r := load_dir(plugin_dir)
	if not r.ok:
		return str(r.error)
	var id: String = r.plugin.id
	if registry.has(id) and registry[id].builtin:
		return "'%s' is a built-in plugin" % id
	var dest := dir.path_join(CBProject.PLUGINS_DIR).path_join(id)
	if DirAccess.dir_exists_absolute(dest):
		remove_tree(dest)
	var err := CBProject.copy_dir(plugin_dir, dest)
	if err != OK:
		return "couldn't copy the plugin into %s (error %d)" % [dest, err]
	var cf := CBProject.load_config(dir)
	cf.set_value("plugins", id, r.plugin.version)
	CBProject.save_config(dir, cf)
	if dir == active_project:
		use_project(dir)
	return ""


static func remove_from_project(dir: String, id: String) -> void:
	var cf := CBProject.load_config(dir)
	if cf.has_section_key("plugins", id):
		cf.erase_section_key("plugins", id)
		CBProject.save_config(dir, cf)
	var dest := dir.path_join(CBProject.PLUGINS_DIR).path_join(id)
	if DirAccess.dir_exists_absolute(dest) and FileAccess.file_exists(dest.path_join("target.cfg")):
		remove_tree(dest)
	if dir == active_project:
		use_project(dir)


# ------------------------------------------------------------------ the library (Manage plugins)

static var library_path := "user://plugins"   ## (tests point it elsewhere)
const EXAMPLES := "res://plugin_examples"


static func library_dir() -> String:
	return ProjectSettings.globalize_path(library_path)


## The installed plugins, by title: [plugin].
static func library() -> Array:
	var out := []
	var root := library_dir()
	if not DirAccess.dir_exists_absolute(root):
		return out
	for d in DirAccess.get_directories_at(root):
		var r := load_dir(root.path_join(d))
		if r.ok:
			out.append(r.plugin)
	out.sort_custom(func(a, b): return str(a.title).naturalnocasecmp_to(str(b.title)) < 0)
	return out


## The plugins shipped as examples (plugin_examples/), installed or not: [plugin].
static func examples() -> Array:
	var out := []
	for d in DirAccess.get_directories_at(EXAMPLES):
		var r := load_dir(EXAMPLES.path_join(d))
		if r.ok:
			out.append(r.plugin)
	return out


## Copies a plugin folder into the library (replacing an older copy). "" or why not.
static func install(plugin_dir: String) -> String:
	var r := load_dir(plugin_dir)
	if not r.ok:
		return str(r.error)
	_builtin()
	if registry.has(r.plugin.id) and registry[r.plugin.id].builtin:
		return "'%s' is a built-in plugin" % r.plugin.id
	var dest := library_dir().path_join(str(r.plugin.id))
	if DirAccess.dir_exists_absolute(dest):
		remove_tree(dest)
	var err := CBProject.copy_dir(plugin_dir, dest)
	return "" if err == OK else "couldn't copy the plugin into the library (error %d)" % err


static func uninstall(id: String) -> void:
	var dest := library_dir().path_join(id)
	if DirAccess.dir_exists_absolute(dest) and FileAccess.file_exists(dest.path_join("target.cfg")):
		remove_tree(dest)


## Which of the given projects use each plugin: id -> [project dirs].
static func usage(project_dirs: Array) -> Dictionary:
	var out := {}
	for d in project_dirs:
		if not CBProject.is_project(str(d)):
			continue
		for id in project_plugins(str(d)):
			if not out.has(id):
				out[id] = []
			out[id].append(d)
	return out


## The library has a different version of a plugin than the project's copy: its version, else "".
static func update_available(project_dir: String, id: String) -> String:
	var mine := str(project_plugins(project_dir).get(id, ""))
	for p in library():
		if p.id == id and str(p.version) != mine:
			return str(p.version)
	return ""


## Deletes a folder, but only a plugin's (it has a target.cfg) or one under the app's user-data folder
## (tests' scratch copies): never anything else.
static func remove_tree(path: String) -> void:
	path = path.trim_suffix("/")
	var safe := FileAccess.file_exists(path.path_join("target.cfg")) or path.begins_with(OS.get_user_data_dir() + "/")
	if path.length() < 12 or not safe or not DirAccess.dir_exists_absolute(path):
		return
	var da := DirAccess.open(path)
	da.include_hidden = true
	for d in da.get_directories():
		_remove_inside(path.path_join(d))
	for f in da.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


static func _remove_inside(path: String) -> void:
	var da := DirAccess.open(path)
	if da == null:
		return
	da.include_hidden = true
	for d in da.get_directories():
		_remove_inside(path.path_join(d))
	for f in da.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
