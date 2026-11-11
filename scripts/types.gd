class_name CBTypes
extends RefCounted
## Type names of C-Bricks values, and what they are in C.
##   "int", "float", "bool", "string"     the basic types
##   "int list", "Point list", ...         a list of one type (a cb_list * in C)
##   "int map", "Point map", ...           text keys -> values of one type (a cb_map * in C)
##   "Point"                               a record (a struct) the project defines
##   "vector3"                             a 3D point / direction (raylib's Vector3: three floats)
## Records are registered per generation (`records`: name -> [[field, type], ...]).

const BASIC := ["int", "float", "bool", "string"]
## Value types beyond the basic ones: copied like numbers, typed in as "x, y, z".
const VECTOR := "vector3"
const VECTOR2 := "vector2"  # a 2D point or direction (raylib's Vector2), typed in as "x, y"
## raylib handles (graphics projects): kept in variables, made by Load bricks.
const HANDLES := {"texture": "cb_texture", "sound": "cb_sound", "music": "cb_music"}
## The project's classes (scripts with a Class brick), set by ProjectBuild / the editor:
## name -> {"extends", "fields": [[name, type]], "synced": [names], "script", "node",
##          "methods": {name: {"params": [[type, name]], "returns"}}, "created": bool}.
## "Node" is the built-in root class (cb_object in C; "Object" before 2026-11-07).
static var classes: Dictionary = {}
## The project's remotes (Define Remote), for the Fire / On Fired bricks:
## name -> {"direction": "To server" / "To clients" / "Both", "params": [[type, name]],
## "index": its number in the build, "script", "node"}. Filled by ProjectBuild.
static var remotes: Dictionary = {}
## The keys the project's Player Key / Player Input bricks name (raylib names, sorted):
## every player's machine sends their state; a brick names one by its place here.
static var net_keys: Array = []
const OBJECT := "Node"

## The world's built-in classes (user, 2026-11-07: small, Godot's way; the project's own
## classes extend them). Drawn and run by the Game loop (cb_gfx.c). Fields: [name, type,
## default as typed in]. A Spatial3D's position / rotation / scale are relative to its
## parent Spatial3D (Spatial2D: to its Spatial2D parent).
const BUILTIN := {
	"Spatial3D": {"extends": "Node", "fields": [["position", "vector3", "0, 0, 0"], ["rotation", "vector3", "0, 0, 0"], ["scale", "vector3", "1, 1, 1"]], "synced": ["position", "rotation", "scale"]},
	"Shape3D": {"extends": "Spatial3D", "fields": [["shape", "string", "Box"], ["size", "vector3", "1, 1, 1"], ["color", "string", "WHITE"], ["visible", "bool", "true"], ["solid", "bool", "false"], ["splat", "bool", "false"]], "synced": ["shape", "size", "color", "visible", "solid"]},
	"Mesh3D": {"extends": "Spatial3D", "fields": [["mesh", "mesh", ""], ["color", "string", "WHITE"], ["visible", "bool", "true"], ["splat", "bool", "false"]], "synced": ["color", "visible"]},
	"Camera3D": {"extends": "Spatial3D", "fields": [["target", "vector3", "0, 0, 0"], ["fov", "float", "60"]], "synced": []},
	"Light3D": {"extends": "Spatial3D", "fields": [["color", "string", "WHITE"], ["energy", "float", "1"]], "synced": ["color", "energy"]},
	"Spatial2D": {"extends": "Node", "fields": [["position", "vector2", "0, 0"], ["rotation", "float", "0"], ["scale", "vector2", "1, 1"]], "synced": ["position", "rotation", "scale"]},
	"Shape2D": {"extends": "Spatial2D", "fields": [["shape", "string", "Rectangle"], ["size", "vector2", "32, 32"], ["color", "string", "WHITE"], ["visible", "bool", "true"]], "synced": ["shape", "size", "color", "visible"]},
	"Sprite2D": {"extends": "Spatial2D", "fields": [["texture", "string", ""], ["color", "string", "WHITE"], ["visible", "bool", "true"], ["columns", "int", "1"], ["rows", "int", "1"], ["frame", "int", "0"]], "synced": ["texture", "color", "visible", "columns", "rows", "frame"]},
	"Text2D": {"extends": "Spatial2D", "fields": [["text", "string", "Text"], ["size", "int", "20"], ["color", "string", "BLACK"], ["visible", "bool", "true"]], "synced": []},
	"Camera2D": {"extends": "Spatial2D", "fields": [["zoom", "float", "1"]], "synced": []},
	# UI (2026-11-07, agreed): placed in the window, in pixels, never moved by a camera, drawn
	# on top of the 3D and 2D; never sent over the network (each machine builds its own).
	"Control": {"extends": "Node", "fields": [["anchor", "string", "top_left"], ["offset", "vector2", "0, 0"], ["size", "vector2", "120, 32"], ["visible", "bool", "true"]], "synced": []},
	"Label": {"extends": "Control", "fields": [["text", "string", "Label"], ["font_size", "int", "20"], ["color", "string", "WHITE"], ["align", "string", "left"]], "synced": []},
	"Panel": {"extends": "Control", "fields": [["color", "string", "#000000a0"], ["border_color", "string", ""], ["border", "int", "0"], ["radius", "float", "0"]], "synced": []},
	"Bar": {"extends": "Control", "fields": [["value", "float", "50"], ["max", "float", "100"], ["color", "string", "#4caf50"], ["back", "string", "#00000080"]], "synced": []},
	"Button": {"extends": "Control", "fields": [["text", "string", "Button"], ["font_size", "int", "18"], ["text_color", "string", "WHITE"], ["color", "string", "#3a4150"], ["hover_color", "string", "#4c5568"], ["press_color", "string", "#2a2f3a"], ["border_color", "string", "#ffffff40"], ["border", "int", "1"], ["radius", "float", "4"], ["disabled", "bool", "false"]], "synced": []},
	"VBox": {"extends": "Control", "fields": [["separation", "float", "4"], ["padding", "float", "0"], ["fill", "bool", "false"]], "synced": []},
	"HBox": {"extends": "Control", "fields": [["separation", "float", "4"], ["padding", "float", "0"], ["fill", "bool", "false"]], "synced": []},
	"Image": {"extends": "Control", "fields": [["texture", "string", ""], ["color", "string", "WHITE"]], "synced": []},
	"Environment": {"extends": "Node", "fields": [["sky", "string", "#87ceeb"], ["ambient", "float", "0.38"], ["fog", "float", "0"], ["fog_color", "string", ""], ["horizon", "string", ""], ["ambient_color", "string", "WHITE"], ["fog_start", "float", "0"], ["vignette", "float", "0"], ["scanlines", "float", "0"], ["grain", "float", "0"], ["posterize", "float", "0"], ["bloom", "float", "0"], ["curve", "float", "0"], ["outline", "float", "0"], ["dither", "float", "0"], ["snap", "float", "0"]], "synced": ["sky", "ambient", "fog", "fog_color", "horizon", "ambient_color", "fog_start", "vignette", "scanlines", "grain", "posterize", "bloom", "curve", "outline", "dither", "snap"]},
}
## A UI field's choices (Properties shows a picker; the runtime reads the name).
const UI_ANCHORS := ["top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom", "bottom_right", "full"]
const UI_ALIGNS := ["left", "center", "right"]


## Old class names (files before 2026-11-07, version-gated): read as the new ones.
const RENAMED := {"Object": "Node", "Part": "Shape3D", "Model": "Spatial3D", "MeshPart": "Mesh3D", "Camera": "Camera3D", "Light": "Light3D", "Label": "Text2D"}


## A type name with old class names renamed ("Part" -> "Shape3D", "Object list" -> "Node list").
static func renamed_type(t: String) -> String:
	for suffix in ["", " list", " map"]:
		if suffix == "" or t.ends_with(suffix):
			var base := t.trim_suffix(suffix) if suffix != "" else t
			if RENAMED.has(base):
				return RENAMED[base] + suffix
	return t

## Object events: brick type -> [method name, its inputs].
const EVENTS := {"every_frame": ["on_frame", [["float", "dt"]]], "touched": ["on_touched", [["Shape3D", "other"]]], "drawn": ["on_drawn", []], "clicked": ["on_clicked", []]}


## A class's name in C: "cls_Camera3D" (raylib has Camera3D, Model, Color...); Node is cb_object's.
static func cname(c: String) -> String:
	return "Node" if c == OBJECT else "cls_" + c


static func is_builtin(c: String) -> bool:
	return BUILTIN.has(c)


## The world's built-in classes (Part, Camera...): they make a project a graphics one.
static func is_world_builtin(c: String) -> bool:
	return BUILTIN.has(c)



## The built-in classes as entries of `classes` (no script, no methods).
static func builtin_entries() -> Dictionary:
	var out := {}
	for table: Dictionary in [BUILTIN]:
		for c in table:
			out[c] = {"extends": table[c].extends, "fields": table[c].fields.duplicate(true), "synced": table[c].synced.duplicate(), "script": "", "node": 0, "methods": {}, "created": false, "side": "Shared", "builtin": true}
	return out

## A mesh built with the mesh bricks (a cb_mesh * in cbricks_gfx.c: its triangles and its model).
const MESH := "mesh"
const C_BASIC := {"void": "void", "int": "int", "float": "double", "bool": "bool", "string": "const char *"}


static func is_list(t: String) -> bool:
	return t.ends_with(" list")


static func elem(t: String) -> String:
	return t.trim_suffix(" list") if is_list(t) else ""


static func list_of(t: String) -> String:
	return t + " list"


static func is_map(t: String) -> bool:
	return t.ends_with(" map")


## A map's value type ("int map" -> "int").
static func map_value(t: String) -> String:
	return t.trim_suffix(" map") if is_map(t) else ""


static func map_of(t: String) -> String:
	return t + " map"


## Lists and maps: shared when copied (a pointer in C), made fresh.
static func is_container(t: String) -> bool:
	return is_list(t) or is_map(t)


static func is_basic(t: String) -> bool:
	return t in BASIC


static func is_vector2(t: String) -> bool:
	return t == VECTOR2


static func is_vector(t: String) -> bool:
	return t == VECTOR


static func is_class_type(t: String) -> bool:
	return t == OBJECT or classes.has(t)


## The class and its parents, the class itself first ("Gem" -> ["Gem", "Shape3D", "Spatial3D", "Node"]).
## The Scene tree's Script objects (Roblox's): a script file placed in the world,
## its type = the file's Side. Not runtime classes: their When program starts runs
## once for the object they're under (`parent`).
const SCRIPT_TYPES := {"Script": "Server", "LocalScript": "Client", "ModuleScript": "Shared"}

## A script's Side as the runtime's bits (cb_side_runs): 1 Server, 2 Client, 3 Shared.
static func side_bits(side: String) -> int:
	return {"Server": 1, "Client": 2}.get(side, 3)



static func script_type_of(side: String) -> String:
	for k in SCRIPT_TYPES:
		if SCRIPT_TYPES[k] == side:
			return k
	return "ModuleScript"


static func is_script_object(o: Dictionary) -> bool:
	return SCRIPT_TYPES.has(str(o.get("class", "")))


static func lineage(cls: String) -> Array:
	var out := []
	var c := cls
	while c != "" and c not in out:
		out.append(c)
		if c == OBJECT:
			break
		c = str(classes.get(c, {}).get("extends", OBJECT))
	return out


## Whether a value of class `sub` fits where `base` is wanted (a Gem is a Part).
static func is_subclass(sub: String, base: String) -> bool:
	return base in lineage(sub)


## Every field of a class, its root class's first: [[name, type, class it's declared in]].
static func all_fields(cls: String) -> Array:
	var out := []
	var line := lineage(cls)
	line.reverse()
	for c in line:
		for f in classes.get(c, {}).get("fields", []):
			out.append([str(f[0]), str(f[1]), c])
	return out


## Every method a class has (its own and inherited): name -> {"params", "returns", "declared": the
## root-most class with it (its function table), "impl": the class whose function runs}.
static func all_methods(cls: String) -> Dictionary:
	var out := {}
	var line := lineage(cls)
	line.reverse()
	for c in line:
		var ms: Dictionary = classes.get(c, {}).get("methods", {})
		for m in ms:
			if out.has(m):
				out[m].impl = c
			else:
				out[m] = {"params": ms[m].params, "returns": ms[m].returns, "declared": c, "impl": c, "event": ms[m].get("event", false)}
	return out


static func is_record(t: String, records: Dictionary) -> bool:
	return records.has(t)


## A usable type name: basic, a known record, or a list / map of one of those.
static func valid(t: String, records: Dictionary) -> bool:
	if is_list(t):
		return valid(elem(t), records) and not is_container(elem(t))
	if is_map(t):
		return valid(map_value(t), records) and not is_container(map_value(t))
	return is_basic(t) or is_vector(t) or is_vector2(t) or records.has(t) or HANDLES.has(t) or t == MESH or is_class_type(t)


## NodeDefs port category of a type name (for the editor's dropdown filters).
static func port(t: String) -> int:
	match t:
		"int": return NodeDefs.INT
		"float": return NodeDefs.FLOAT
		"bool": return NodeDefs.BOOL
		"string": return NodeDefs.STRING
		"vector3": return NodeDefs.VEC3
		"vector2": return NodeDefs.VEC2
		"", "any": return NodeDefs.ANY
	if is_list(t):
		return NodeDefs.LIST
	if is_map(t):
		return NodeDefs.MAP
	if is_class_type(t):
		return NodeDefs.OBJECT
	return NodeDefs.RECORD


static func c_type(t: String) -> String:
	if C_BASIC.has(t):
		return C_BASIC[t]
	if HANDLES.has(t):
		return HANDLES[t]
	if is_vector(t):
		return "Vector3"
	if is_vector2(t):
		return "Vector2"
	if t == MESH:
		return "cb_mesh *"
	if is_class_type(t):
		return "%s *" % cname(t)
	if is_list(t):
		return "cb_list *"
	if is_map(t):
		return "cb_map *"
	return t if t.is_valid_identifier() else "int"


## An element's C type inside a list ("Point list" -> "Point").
static func c_elem(t: String) -> String:
	return c_type(elem(t))


## A fresh value: for locals (any expression allowed).
static func zero(t: String) -> String:
	match t:
		"float": return "0.0"
		"bool": return "false"
		"string": return "\"\""
		"int", "", "any": return "0"
	if is_list(t):
		return "cb_list_new(sizeof(%s))" % c_elem(t)
	if is_map(t):
		return "cb_map_new(sizeof(%s))" % c_type(map_value(t))
	if HANDLES.has(t):
		return "(%s){0}" % HANDLES[t]
	if is_vector(t):
		return "cb_v3(0, 0, 0)"
	if is_vector2(t):
		return "cb_v2(0, 0)"
	if t == MESH:
		return "cb_mesh_new()"
	if is_class_type(t):
		return "NULL"
	return "cb_make_%s()" % t


## A value allowed at file scope (constant). Lists / records start empty there
## and get their fresh value in the file's init function.
static func static_zero(t: String) -> String:
	if is_container(t) or t == MESH or is_class_type(t):
		return "NULL"
	if not is_basic(t) and t not in ["", "any", "void"]:
		return "{0}"  # records, raylib handles
	return zero(t)


static func needs_init(t: String) -> bool:
	return is_container(t) or not (is_basic(t) or is_vector(t) or is_vector2(t) or HANDLES.has(t) or is_class_type(t) or t in ["", "any", "void"])


## The runtime / generated function that prints one value of type t (FILE *, const void *).
static func show_fn(t: String) -> String:
	if is_list(t):
		return "cb_show_%s_list" % elem(t)
	if is_map(t):
		return "cb_show_%s_map" % map_value(t)
	match t:
		"int": return "cb_show_int"
		"float": return "cb_show_float"
		"bool": return "cb_show_bool"
		"string": return "cb_show_string"
		"vector3": return "cb_show_vector3"
		"vector2": return "cb_show_vector2"
		"mesh": return "cb_show_mesh"
	if is_class_type(t):
		return "cb_show_object"
	return "cb_show_%s" % t


## Every type a picker offers: basics, records, then lists of each, then maps of each.
static func all(records: Dictionary) -> PackedStringArray:
	var out := PackedStringArray(BASIC)
	out.append(VECTOR2)
	out.append(VECTOR)
	var names := records.keys()
	names.sort()
	var cls := classes.keys()
	cls.sort()
	names = names + [OBJECT] + cls
	for r in names:
		out.append(r)
	for t in BASIC + [VECTOR2, VECTOR] + names:
		out.append(list_of(t))
	for t in BASIC + [VECTOR2, VECTOR] + names:
		out.append(map_of(t))
	return out
