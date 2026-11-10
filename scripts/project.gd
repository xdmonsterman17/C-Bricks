class_name CBProject
extends RefCounted
## A C-Bricks project is a folder, like a Godot project:
##
##   MyGame/
##     project.cbproj        settings (name, version, run arguments, target)
##     main.cbscene          the Main scene: the objects the world starts with
##     scenes/enemy.cbscene  other scenes (placed in scenes, or Instance scene)
##     main.cbricks           a script (graph). Every .cbricks anywhere in the folder is
##     scripts/util.cbricks   one: each becomes its own .c file, and they can call
##     assets/model.obj      each other's functions. Everything else is an asset:
##     .build/               the program finds it by its path from the project folder.
##                           (build output, made by C-Bricks; like Godot's .godot/)

const FILE := "project.cbproj"
const SCRIPT_EXT := "cbricks"
const BUILD_DIR := ".build"
## Scenes: objects (and copies of other scenes); the Main scene is the world's start.
const SCENE_EXT := "cbscene"
const MAIN_SCENE := "main.cbscene"
## The old world file (before scenes): read as the Main scene, renamed by upgrade_world.
const WORLD_FILE := "world.cnworld"


## Before the rename (2026-11-07, C-Nodes -> C-Bricks): a project's settings file and its
## scripts' / scenes' extensions. upgrade_names renames them when the project opens.
const OLD_FILE := "project.cnproj"
const OLD_EXTS := {"cnodes": "cbricks", "cnscene": "cbscene"}


## The built program's file name: the project's name in snake_case, safe for a file.
static func program_name(dir: String) -> String:
	var base := project_name(dir).to_snake_case()
	var s := ""
	for ch in base:
		s += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch == "-") else "_"
	return s if s != "" else "program"


static func is_project(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join(FILE)) or FileAccess.file_exists(dir.path_join(OLD_FILE))


## A C-Nodes project (project.cnproj, .cnodes scripts, .cnscene scenes) becomes a C-Bricks
## one: the files renamed, and every reference to them inside scripts, scenes and the
## settings (Script objects, Instance / Change scene, main_scene, watches...) with them;
## the format names too. True if it did.
static func upgrade_names(dir: String) -> bool:
	if not FileAccess.file_exists(dir.path_join(OLD_FILE)) or FileAccess.file_exists(dir.path_join(FILE)):
		return false
	var files := []
	_old_files(dir, files)
	for f in files:
		var text := FileAccess.get_file_as_string(f)
		for old_ext in OLD_EXTS:
			text = text.replace("." + old_ext, "." + OLD_EXTS[old_ext])
		text = text.replace("\"c-nodes", "\"c-bricks")
		var to: String = f
		if f.get_extension() in OLD_EXTS:
			to = f.get_basename() + "." + OLD_EXTS[f.get_extension()]
		elif f.get_file() == OLD_FILE:
			to = dir.path_join(FILE)
		var fa := FileAccess.open(to, FileAccess.WRITE)
		if fa == null:
			continue
		fa.store_string(text)
		fa.close()
		if to != f:
			DirAccess.remove_absolute(f)
	return true


## The project's old-named files (scripts, scenes, the settings), not in .build/.
static func _old_files(path: String, out: Array) -> void:
	for f in DirAccess.get_files_at(path):
		if f.get_extension() in OLD_EXTS or f == OLD_FILE:
			out.append(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		if not d.begins_with("."):
			_old_files(path.path_join(d), out)


## Where new projects (and opened examples' copies) go by default: Documents/Projects/C-Bricks
## (user, 2026-11-07; /home/xdmonster/Documents/Projects/C-Bricks on the user's Pi).
static func default_parent() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs == "":
		docs = OS.get_user_data_dir()
	return docs.path_join("Projects").path_join("C-Bricks")


## A name as a safe file name (user, 2026-11-07): "Script Test" -> "script-test": lower
## case, spaces (and runs of them) to "-", only letters, digits, "-", "_" and "." kept.
static func safe_name(name: String, fallback := "script") -> String:
	var out := ""
	for ch in name.strip_edges().to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch in ["_", "."]:
			out += ch
		elif ch in [" ", "-", "\t"]:
			out += "-"
	while out.contains("--"):
		out = out.replace("--", "-")
	out = out.strip_edges().trim_prefix("-").trim_suffix("-").trim_prefix(".")
	return out if out != "" else fallback


## A script or scene file moved (from / to: paths from the project folder; "" to:
## deleted): every scene's Script objects and copies follow, and the Main scene.
static func repoint(dir: String, from_rel: String, to_rel: String) -> void:
	if from_rel == "" or to_rel == "":
		return
	for p in list_scenes(dir):
		var data := read_scene(p)
		var moved := false
		for o in data.objects:
			for key in ["script", "scene"]:
				var v := str(o.get(key, ""))
				if v == from_rel or v.begins_with(from_rel + "/"):
					o[key] = to_rel + v.substr(from_rel.length())
					moved = true
		if moved:
			write_scene(p, data)
	var cf := load_config(dir)
	var main := str(cf.get_value("project", "main_scene", ""))
	if main != "" and (main == from_rel or main.begins_with(from_rel + "/")):
		cf.set_value("project", "main_scene", to_rel + main.substr(from_rel.length()))
		save_config(dir, cf)


static func load_config(dir: String) -> ConfigFile:
	var cf := ConfigFile.new()
	cf.load(dir.path_join(FILE))
	return cf


static func save_config(dir: String, cf: ConfigFile) -> Error:
	return cf.save(dir.path_join(FILE))


static func project_name(dir: String) -> String:
	return str(load_config(dir).get_value("project", "name", dir.get_file()))


## A new project folder `parent/name`: settings and assets/, no script (user, 2026-11-07: the
## main script isn't made for you; without a When program starts the build's own main()
## runs the Main scene). Returns its path, or "" (see last_error).
static var last_error := ""


static func create(parent: String, name: String) -> String:
	last_error = ""
	name = name.strip_edges()
	if name == "" or name.contains("/") or name.contains("\\"):
		last_error = "Give the project a name (no slashes)."
		return ""
	var dir := parent.path_join(name)
	if DirAccess.dir_exists_absolute(dir) and not DirAccess.get_files_at(dir).is_empty():
		last_error = "%s already exists and isn't empty." % dir
		return ""
	if DirAccess.make_dir_recursive_absolute(dir.path_join("assets")) != OK:
		last_error = "Can't make %s." % dir
		return ""
	var cf := ConfigFile.new()
	cf.set_value("project", "name", name)
	cf.set_value("project", "version", "1.0")
	cf.set_value("run", "args", "")
	cf.set_value("build", "target", "native")
	save_config(dir, cf)
	return dir


static func write_script(path: String, graph: Dictionary) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return FileAccess.get_open_error()
	var data: Dictionary = graph.duplicate(true)
	fa.store_string(JSON.stringify(data, "\t"))
	fa.close()
	return OK


static func read_script(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary and data.has("nodes")):
		return {}
	return Ops.normalize(data)


## Every file and folder of the project, relative paths, folders ending in "/"
## (hidden ones and the build folder left out), sorted folders first.
static func list_entries(dir: String, sub: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	var here := dir.path_join(sub) if sub != "" else dir
	var folders := Array(DirAccess.get_directories_at(here))
	folders.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	for d in folders:
		if d.begins_with("."):
			continue
		var rel: String = sub.path_join(d) if sub != "" else d
		out.append(rel + "/")
		out.append_array(list_entries(dir, rel))
	var files := Array(DirAccess.get_files_at(here))
	files.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	for f in files:
		if f.begins_with(".") or f.ends_with(".import") or f.ends_with(".uid"):
			continue
		out.append(sub.path_join(f) if sub != "" else f)
	return out


## Absolute paths of the project's scripts: main.cbricks first, then by path.
static func list_scripts(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for rel in list_entries(dir):
		if rel.get_extension() == SCRIPT_EXT:
			out.append(dir.path_join(rel))
	var main := dir.path_join("main.cbricks")
	if main in out:
		out.erase(main)
		out.insert(0, main)
	return out


## Assets: files that aren't scripts or the project file (relative paths).
static func list_assets(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for rel in list_entries(dir):
		if rel.ends_with("/") or rel.get_extension() == SCRIPT_EXT or rel == FILE or rel == WORLD_FILE or rel.get_extension() == SCENE_EXT:
			continue
		out.append(rel)
	return out


static func rel_path(dir: String, path: String) -> String:
	return path.trim_prefix(dir).trim_prefix("/")


## Copies a folder (also out of res://, for the examples).
static func copy_dir(from: String, to: String) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(to)
	if err != OK:
		return err
	for f in DirAccess.get_files_at(from):
		if f.ends_with(".import") or f.ends_with(".uid"):
			continue
		var name := f.trim_suffix(".remap")
		var bytes := FileAccess.get_file_as_bytes(from.path_join(name))
		var fa := FileAccess.open(to.path_join(name), FileAccess.WRITE)
		if fa == null:
			return FileAccess.get_open_error()
		fa.store_buffer(bytes)
		fa.close()
	for d in DirAccess.get_directories_at(from):
		err = copy_dir(from.path_join(d), to.path_join(d))
		if err != OK:
			return err
	return OK


# ------------------------------------------------------------------ scenes
#
# {"format": "c-bricks-scene", "version": 1, "next_id": N,
#  "objects": [{"id", "class", "name", "parent": an object's id or 0 (the top),
#               "fields": {field: value as typed in}, "groups": [..], "meta": {k: text}},
#              {"id", "scene": "scenes/enemy.cbscene", "name", "parent", "fields" (the copy's
#               root: overrides), "groups", "meta"},          (a copy of another scene)
#              {"id", "class": "Script" | "LocalScript" | "ModuleScript", "script": rel, ...}]}

## The Main scene's path (project.cbproj [project] main_scene; main.cbscene by default; an
## old project's world.cnworld until it's upgraded).
static func world_path(dir: String) -> String:
	var rel := str(load_config(dir).get_value("project", "main_scene", MAIN_SCENE)) if FileAccess.file_exists(dir.path_join(FILE)) else MAIN_SCENE
	if not FileAccess.file_exists(dir.path_join(rel)) and FileAccess.file_exists(dir.path_join(WORLD_FILE)):
		return dir.path_join(WORLD_FILE)
	return dir.path_join(rel)


static func new_world() -> Dictionary:
	return {"format": "c-bricks-scene", "version": SCENE_VERSION, "next_id": 1, "objects": []}


## Absolute paths of the project's scenes (the Main scene first).
static func list_scenes(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for rel in list_entries(dir):
		if rel.get_extension() == SCENE_EXT:
			out.append(dir.path_join(rel))
	var main := world_path(dir)
	if main in out:
		out.erase(main)
	if FileAccess.file_exists(main):
		out.insert(0, main)
	return out


## An old project: world.cnworld -> main.cbscene, the Main scene (true if it did).
static func upgrade_world(dir: String) -> bool:
	var old := dir.path_join(WORLD_FILE)
	if not FileAccess.file_exists(old) or FileAccess.file_exists(dir.path_join(MAIN_SCENE)):
		return false
	var data := read_scene(old)
	if write_scene(dir.path_join(MAIN_SCENE), data) != OK:
		return false
	DirAccess.remove_absolute(old)
	var cf := load_config(dir)
	cf.set_value("project", "main_scene", MAIN_SCENE)
	save_config(dir, cf)
	return true


static func read_world(dir: String) -> Dictionary:
	return read_scene(world_path(dir))


static func read_scene(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return new_world()
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary or not data.get("objects") is Array:
		return new_world()
	for o in data.objects:
		o.id = int(o.get("id", 0))
		o.parent = int(o.get("parent", 0))
		if not o.get("fields") is Dictionary:
			o.fields = {}
	data.next_id = int(data.get("next_id", 1))
	data.format = "c-bricks-scene"
	if int(data.get("version", 1)) < 2:
		upgrade_scene_classes(data)
	if int(data.get("version", 1)) < 3:
		upgrade_scene_root(data, path)
	if int(data.get("version", 1)) < 4:
		upgrade_scene_spatial_root(data)
	data.version = SCENE_VERSION
	return data


## The scene format: 2 = the small built-in classes (2026-11-07: Node, Spatial3D, Shape3D...);
## 3 = one root per scene (the first node added; the Main scene's is the world);
## 4 = a 3D scene's plain Node root is a Spatial3D (user, 2026-11-07: "make every Main
## object a spatial object").
const SCENE_VERSION := 4


## A scene's root that's a plain Node (as upgrades and the example generators made them,
## e.g. Main) becomes a Spatial3D when the scene holds 3D things; a scene without any
## keeps its Node (a Spatial3D would make a text program a graphics one).
static func upgrade_scene_spatial_root(data: Dictionary) -> void:
	var tops: Array = data.objects.filter(func(o): return int(o.get("parent", 0)) == 0 and not CBTypes.is_script_object(o))
	if tops.size() != 1 or str(tops[0].get("class", "")) != "Node" or tops[0].has("scene"):
		return
	if data.objects.any(func(o): return CBTypes.is_subclass(str(o.get("class", "")), "Spatial3D") or _known_3d(str(o.get("class", "")))):
		tops[0]["class"] = "Spatial3D"


## (a class of the project's own, when its lineage isn't known yet: by its built-in name only)
static func _known_3d(cls: String) -> bool:
	return cls in ["Spatial3D", "Shape3D", "Mesh3D", "Camera3D", "Light3D"]


## A scene from before one root per scene: its objects at the top (if not just one node)
## go under a new root: the Main scene's old "World" settings ("root": its class and
## name), else a Node named after the file (main.cbscene -> Main).
static func upgrade_scene_root(data: Dictionary, path: String) -> void:
	var old_root = data.get("root")
	data.erase("root")
	var tops: Array = data.objects.filter(func(o): return int(o.get("parent", 0)) == 0)
	var custom: bool = old_root is Dictionary and (str(old_root.get("class", "Node")) not in ["Node", "Object"] or str(old_root.get("name", "World")) != "World")
	if tops.is_empty() or (tops.size() == 1 and not CBTypes.is_script_object(tops[0]) and not custom):
		return
	var root := {"id": int(data.next_id), "class": "Node", "name": path.get_file().get_basename().replace("-", " ").replace("_", " ").capitalize().replace(" ", ""), "parent": 0, "fields": {}}
	if old_root is Dictionary:
		root["class"] = CBTypes.renamed_type(str(old_root.get("class", "Node")))
		root["name"] = str(old_root.get("name", "World"))
	data.next_id = int(data.next_id) + 1
	for o in tops:
		o.parent = int(root.id)
	data.objects.push_front(root)


## A scene from before 2026-11-07, in the new classes: Part -> Shape3D (no velocity),
## MeshPart -> Mesh3D (size -> scale), Model -> Spatial3D, Label -> Text2D (x, y ->
## position), Light -> Light3D (direction -> rotation), the Camera's sky and the Light's
## ambient -> a new Environment (so the game looks the same), Object -> Node.
static func upgrade_scene_classes(data: Dictionary) -> void:
	var env := {}
	var sky := ""
	var ambient := ""
	for o in data.objects:
		var cls := str(o.get("class", ""))
		var f: Dictionary = o.fields
		match cls:
			"Part":
				f.erase("velocity")
			"MeshPart":
				if f.has("size"):
					f["scale"] = f.size
				for k in ["size", "velocity", "shape", "solid"]:
					f.erase(k)
			"Label":
				f["position"] = "%s, %s" % [str(f.get("x", "10")), str(f.get("y", "10"))]
				f.erase("x")
				f.erase("y")
			"Camera":
				if sky == "":
					sky = str(f.get("sky", "SKYBLUE"))
				f.erase("sky")
			"Light":
				var d := str(f.get("direction", "-0.4, -1, -0.6")).split(",")
				var v := Vector3(float(d[0]) if d.size() > 0 else -0.4, float(d[1]) if d.size() > 1 else -1.0, float(d[2]) if d.size() > 2 else -0.6)
				if v.length() > 0.0001:
					v = v.normalized()
					# it shines along its -Z: (-sin y cos x, sin x, -cos y cos x)
					f["rotation"] = "%s, %s, 0" % [snappedf(rad_to_deg(asin(clampf(v.y, -1, 1))), 0.01), snappedf(rad_to_deg(atan2(-v.x, -v.z)), 0.01)]
				if ambient == "" and f.has("ambient"):
					ambient = str(f.ambient)
				f.erase("direction")
				f.erase("ambient")
		if CBTypes.RENAMED.has(cls):
			o["class"] = CBTypes.RENAMED[cls]
	if sky != "" or ambient != "":
		env = {"id": int(data.next_id), "class": "Environment", "name": "Environment", "parent": 0, "fields": {"sky": sky if sky != "" else "SKYBLUE"}}
		if ambient != "":
			env.fields["ambient"] = ambient
		data.next_id = int(data.next_id) + 1
		data.objects.append(env)
	if data.get("root") is Dictionary and str(data.root.get("class", "")) == "Object":
		data.root["class"] = "Node"


static func write_world(dir: String, world: Dictionary) -> Error:
	return write_scene(world_path(dir), world)


static func write_scene(path: String, world: Dictionary) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return FileAccess.get_open_error()
	var out: Dictionary = world.duplicate(true)
	for o in out.get("objects", []):  # empty groups / metadata / snapshot settings aren't written
		for k in ["groups", "meta"]:
			if o.has(k) and o[k].is_empty():
				o.erase(k)
	fa.store_string(JSON.stringify(out, "\t"))
	fa.close()
	return OK
