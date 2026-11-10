@tool
extends RefCounted

## What kind of node a Node value holds, and what can be done with one.
##
## A node type is a Dictionary: {"class": StringName (a Godot Node class),
## "script": String (the script it runs: a .gd or a brickscript; "" for
## none)}. It travels with Node variables through the compiler, so the
## property and method dropdowns of the node bricks know what to offer, and
## generated code is typed. {} means "some Node".
##
## Members (properties and methods) come from Godot's class data (ClassDB)
## and, for a .gd script, from the script itself. A brickscript's own
## variables are worked out by the compiler (flow_compiler.gd members_of()),
## which uses this file for everything else.
##
## Also: the scene lookups behind the guesses (what type the node at a path
## is, in the scenes that use a brickscript; what a scene's root is).

const Types = preload("flow_types.gd")
## Loaded when needed (it uses this file: no preload cycle).
const BRICK_FILE_PATH: String = "res://addons/brickscript/core/brick_file.gd"
## The runtime scripts _starter_layout() reads (by path: the core never loads
## the runtime).
const STARTER_SCRIPT: String = "res://addons/brickscript/runtime/starter.gd"
const PLAYERS_SCRIPT: String = "res://addons/brickscript/runtime/players.gd"
const PLAYER_SCRIPT: String = "res://addons/brickscript/runtime/player.gd"
const SPAWNER_SCRIPT: String = "res://addons/brickscript/runtime/character_spawner.gd"
## Properties of those that name a starter (Players.starter,
## Spawner.starter_character) or where characters go (Spawner.container).
const STARTER_LINKS: PackedStringArray = ["starter", "starter_character", "container"]
const BRICK_EXTENSIONS: PackedStringArray = ["bricklocal", "brickserver"]
## spawn_placements() cache: its files and their times, and what it found.
static var _placements_key: String = ""
static var _placements: Array[Dictionary] = []
const T = Types.ValueType
## Source files the editor imports, by the class they become.
const IMPORTED: Dictionary = {
	"png,jpg,jpeg,svg,webp,bmp,tga,exr,hdr,dds,ktx": &"Texture2D",
	"wav,ogg,mp3": &"AudioStream",
	"ttf,otf,woff,woff2,fnt": &"Font",
	"obj,glb,gltf,fbx,blend": &"PackedScene",
}
## Every file a Resource input offers when nothing narrows it down.
const ALL_RESOURCE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "svg", "webp", "wav", "ogg", "mp3", "tscn", "scn", "tres", "res", "ttf", "otf"]

## What a local brickscript may change (only this machine sees it, so it
## never touches the game itself): UI, cameras, sounds and particles, and
## anything inside UI (a CanvasLayer or Control) or a local-only node.
const LOCAL_ONLY_CLASSES: Array[StringName] = [&"Control", &"CanvasLayer", &"Camera2D", &"Camera3D",
	&"AudioStreamPlayer", &"AudioStreamPlayer2D", &"AudioStreamPlayer3D",
	&"GPUParticles2D", &"GPUParticles3D", &"CPUParticles2D", &"CPUParticles3D"]
## Nodes a local brickscript spawned (effects) are put in this group: they
## stay on that machine, never synced, and the local script may change them.
## Shared by name with the Network Context Engine (like server_script).
const LOCAL_ONLY_GROUP: StringName = &"local_only"

## Members of Godot classes by class name (they never change while running).
static var _class_cache: Dictionary = {}
## animation_names(): key -> [scene modified time, names].
static var _animation_cache: Dictionary = {}
## Members of .gd scripts by path: {"time": modified time, "members": [...]}.
static var _script_cache: Dictionary = {}


## "Sprite2D", "CharacterBody2D (enemy.bricklocal)", "Texture2D" or "Node".
static func describe(node_type: Dictionary) -> String:
	var class_text: String = String(node_type.get("class", &"Node"))
	if class_text.is_empty():
		class_text = "Node"
	var script: String = str(node_type.get("script", ""))
	return class_text if script.is_empty() else "%s (%s)" % [class_text, script.get_file()]


## A Node script class by its name (`class_name ObjectWhole`): {"class": the
## built-in class it extends, "script": its file}, or {} if there's none.
static func script_class(name: StringName) -> Dictionary:
	var by_name: Dictionary = {}
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		by_name[entry["class"]] = entry
	if not by_name.has(name):
		return {}
	var base: StringName = name
	while by_name.has(base):
		base = by_name[base]["base"]
	if not is_node_class(base):
		return {}
	return {"class": base, "script": str(by_name[name]["path"])}


## The GDScript type a variable holding this node is declared with.
static func gd_class(node_type: Dictionary) -> String:
	var class_name_: StringName = node_type.get("class", &"Node")
	return String(class_name_) if is_node_class(class_name_) else "Node"


## Node classes a game can use (no editor-only or abstract ones), sorted.
static func game_node_classes() -> PackedStringArray:
	if _class_cache.has(&"__game_classes"):
		return _class_cache[&"__game_classes"]
	var result: PackedStringArray = ["Node"]
	for class_text: String in ClassDB.get_inheriters_from_class(&"Node"):
		if ClassDB.can_instantiate(class_text) and ClassDB.class_get_api_type(class_text) == ClassDB.API_CORE and class_text != "MissingNode":
			result.append(class_text)
	result.sort()
	_class_cache[&"__game_classes"] = result
	return result


## A property may name several classes ("CanvasItemMaterial,ShaderMaterial"):
## the nearest class they all are (Material).
static func _shared_class(names: String) -> StringName:
	var classes: PackedStringArray = names.split(",", false)
	if classes.size() <= 1:
		return StringName(names.strip_edges())
	var shared: StringName = StringName(classes[0].strip_edges())
	for other: String in classes:
		var other_class: StringName = StringName(other.strip_edges())
		while ClassDB.class_exists(shared) and not (other_class == shared or ClassDB.is_parent_class(other_class, shared)):
			shared = ClassDB.get_parent_class(shared)
	return shared


static func is_resource_class(class_name_: StringName) -> bool:
	return not String(class_name_).is_empty() and ClassDB.class_exists(class_name_) and (class_name_ == &"Resource" or ClassDB.is_parent_class(class_name_, &"Resource"))


## File extensions that load as `class_name_` (or a subclass): what Godot's
## loaders say, plus the source formats the editor imports (a .png is a
## Texture2D, a .wav an AudioStream).
static func resource_extensions(class_name_: StringName) -> PackedStringArray:
	var found: PackedStringArray = ResourceLoader.get_recognized_extensions_for_type(String(class_name_))
	for imported: String in IMPORTED:
		if ClassDB.is_parent_class(IMPORTED[imported], class_name_) or IMPORTED[imported] == class_name_:
			for extension: String in imported.split(","):
				if not found.has(extension):
					found.append(extension)
	return found


## Whether the file at `path` can be used where a `class_name_` is wanted
## (.tres / .res files can hold any resource: let them through).
static func resource_fits(path: String, class_name_: StringName) -> bool:
	if String(class_name_).is_empty() or class_name_ == &"Resource" or not is_resource_class(class_name_):
		return true
	var extension: String = path.get_extension().to_lower()
	return extension in ["tres", "res"] or resource_extensions(class_name_).has(extension)


## The class a file loads as, as far as its extension tells (Resource for
## .tres / .res and the unknown).
static func resource_class_of(path: String) -> StringName:
	var extension: String = path.get_extension().to_lower()
	for imported: String in IMPORTED:
		if imported.split(",").has(extension):
			return IMPORTED[imported]
	if extension in ["tscn", "scn"]:
		return &"PackedScene"
	return &"Resource"


## Files in the project (not addons/) that fit `class_name_`, sorted.
static func resource_files(class_name_: StringName, folder: String = "res://") -> PackedStringArray:
	var extensions: PackedStringArray = resource_extensions(class_name_) if is_resource_class(class_name_) and class_name_ != &"Resource" else ALL_RESOURCE_EXTENSIONS
	var found: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return found
	for file: String in dir.get_files():
		if extensions.has(file.get_extension().to_lower()):
			found.append(folder.path_join(file))
	for sub: String in dir.get_directories():
		if not sub.begins_with(".") and sub != "addons" and sub != "build" and not FileAccess.file_exists(folder.path_join(sub).path_join(".gdignore")):
			found.append_array(resource_files(class_name_, folder.path_join(sub)))
	found.sort()
	return found


static func is_node_class(class_name_: StringName) -> bool:
	return not String(class_name_).is_empty() and ClassDB.class_exists(class_name_) and (class_name_ == &"Node" or ClassDB.is_parent_class(class_name_, &"Node"))


## Whether a node of type `given` can be stored where `wanted` is expected:
## the same class or a subclass. Unknown classes (plain Node) are let
## through; GDScript checks them when the game runs.
static func fits(given: Dictionary, wanted: Dictionary) -> bool:
	var given_class: StringName = given.get("class", &"Node")
	var wanted_class: StringName = wanted.get("class", &"Node")
	if not is_node_class(given_class) or not is_node_class(wanted_class) or given_class == &"Node" or wanted_class == &"Node":
		return true
	return given_class == wanted_class or ClassDB.is_parent_class(given_class, wanted_class) or ClassDB.is_parent_class(wanted_class, given_class)


## Whether a Resource of class `given` can go where a `wanted` is expected
## (either may be the other's subclass). Unknown classes are let through.
static func resource_class_fits(given: StringName, wanted: StringName) -> bool:
	if not is_resource_class(wanted) or not is_resource_class(given) or wanted == &"Resource" or given == &"Resource":
		return true
	return given == wanted or ClassDB.is_parent_class(given, wanted) or ClassDB.is_parent_class(wanted, given)


#region Typed lists

## A List's type travels where a Node's node type does: {"item": ValueType,
## "items": the node type (Node items) or {"class"} (Resource items)}. {} is
## a List of Anything (an untyped Array).

## The Godot Variant type each item type is stored as in a typed Array.
const LIST_VARIANT_TYPES: Dictionary[int, String] = {
	T.NUMBER: "TYPE_FLOAT", T.WHOLE: "TYPE_INT", T.TEXT: "TYPE_STRING", T.BOOL: "TYPE_BOOL",
	T.VECTOR2: "TYPE_VECTOR2", T.VECTOR3: "TYPE_VECTOR3", T.COLOR: "TYPE_COLOR",
	T.NODE: "TYPE_OBJECT", T.RESOURCE: "TYPE_OBJECT", T.LIST: "TYPE_ARRAY", T.TABLE: "TYPE_DICTIONARY",
	T.PLAYER: "TYPE_OBJECT",
}


static func list_info(item: int, items: Dictionary = {}) -> Dictionary:
	if item == T.ANY or not LIST_VARIANT_TYPES.has(item):
		return {}
	return {"item": item, "items": items if item in [T.NODE, T.RESOURCE] else {}}


static func list_item(info: Dictionary) -> int:
	return int(info.get("item", T.ANY))


## The class a typed Array of these items names ("" for builtin items).
static func _list_class(info: Dictionary) -> String:
	match list_item(info):
		T.NODE:
			return gd_class(info.get("items", {}))
		T.RESOURCE:
			var class_name_: StringName = info.get("items", {}).get("class", &"Resource")
			return String(class_name_) if is_resource_class(class_name_) else "Resource"
		T.PLAYER:
			# (A typed Array's class must be a built-in one: players are Nodes.)
			return "Node"
	return ""


## `Array[float]`, `Array[Label]`, or `Array` for a List of Anything.
static func list_gd_type(info: Dictionary) -> String:
	var item: int = list_item(info)
	if item == T.ANY:
		return "Array"
	var class_text: String = _list_class(info)
	return "Array[%s]" % (class_text if not class_text.is_empty() else Types.gd_type(item))


## "List of Number", "List of Label", or "List".
static func describe_list(info: Dictionary) -> String:
	var item: int = list_item(info)
	if item == T.ANY:
		return "List"
	return "List of " + (describe(info.get("items", {})) if item == T.NODE else _list_class(info) if item == T.RESOURCE else Types.type_name(item))


## How a List of `given` items goes where a List of `wanted` items is
## expected: "" (as it is), "convert" (into a new typed Array, checked when the
## game runs), "round" (decimals into whole numbers) or "no".
static func list_fit(given: Dictionary, wanted: Dictionary) -> String:
	var wanted_item: int = list_item(wanted)
	var given_item: int = list_item(given)
	if wanted_item == T.ANY:
		return ""
	if given_item == T.ANY:
		return "convert"
	if given_item == T.NUMBER and wanted_item == T.WHOLE:
		return "round"
	if given_item == T.WHOLE and wanted_item == T.NUMBER:
		return "convert"
	if given_item != wanted_item:
		return "no"
	match given_item:
		T.NODE:
			if not fits(given.get("items", {}), wanted.get("items", {})):
				return "no"
		T.RESOURCE:
			if not resource_class_fits(given.get("items", {}).get("class", &"Resource"), wanted.get("items", {}).get("class", &"Resource")):
				return "no"
	return "" if _list_class(given) == _list_class(wanted) else "convert"


## Code that turns the List `code` into one of `wanted`'s items, as
## list_fit() said (`how`).
static func list_converted(code: String, wanted: Dictionary, how: String) -> String:
	if how == "round":
		code = "%s.map(func(value: Variant) -> int: return roundi(value))" % code
	elif how != "convert":
		return code
	return "Array(%s, %s, &%s, null)" % [code, LIST_VARIANT_TYPES[list_item(wanted)], var_to_str(_list_class(wanted))]


## The type of a typed-in empty List: its Array's item type (`Array[float]([])`
## in the graph's text).
static func list_info_of_value(value: Variant) -> Dictionary:
	if not value is Array or not (value as Array).is_typed():
		return {}
	var array: Array = value
	var class_name_: StringName = array.get_typed_class_name()
	if array.get_typed_builtin() == TYPE_OBJECT:
		if is_node_class(class_name_):
			return list_info(T.NODE, {} if class_name_ == &"Node" else {"class": class_name_})
		if is_resource_class(class_name_):
			return list_info(T.RESOURCE, {"class": class_name_})
		return {}
	for item: int in Types.VARIANT_TYPES:
		if Types.VARIANT_TYPES[item] == array.get_typed_builtin():
			return list_info(item)
	return {}


## An empty Array of `item`s (what an "of" dropdown stores).
static func empty_list(item: int) -> Array:
	match item:
		T.NODE:
			return Array([], TYPE_OBJECT, &"Node", null)
		T.RESOURCE:
			return Array([], TYPE_OBJECT, &"Resource", null)
	if not Types.VARIANT_TYPES.has(item):
		return []
	return Array([], Types.VARIANT_TYPES[item], &"", null)


#region Typed tables
# A Table knows its keys' and its values' types, each described like a List's
# items (list_info: {"item": type, "items": node type}): {"keys": ..., "values":
# ...}. {} is a Table of Anything -> Anything (a plain Dictionary).

static func table_info(keys: Dictionary, values: Dictionary) -> Dictionary:
	if keys.is_empty() and values.is_empty():
		return {}
	return {"keys": keys, "values": values}


static func table_keys(info: Dictionary) -> Dictionary:
	return info.get("keys", {})


static func table_values(info: Dictionary) -> Dictionary:
	return info.get("values", {})


## One side's GDScript type: `float`, `Label`, or `Variant` for Anything.
static func _side_gd_type(side: Dictionary) -> String:
	var item: int = list_item(side)
	if item == T.ANY:
		return "Variant"
	var class_text: String = _list_class(side)
	return class_text if not class_text.is_empty() else Types.gd_type(item)


## `Dictionary[String, float]`, or `Dictionary` for Anything -> Anything.
static func table_gd_type(info: Dictionary) -> String:
	if info.is_empty():
		return "Dictionary"
	return "Dictionary[%s, %s]" % [_side_gd_type(table_keys(info)), _side_gd_type(table_values(info))]


static func _describe_side(side: Dictionary) -> String:
	var item: int = list_item(side)
	if item == T.ANY:
		return "Anything"
	return describe_list(side).trim_prefix("List of ")


## "Table of Text -> Number", or "Table".
static func describe_table(info: Dictionary) -> String:
	if info.is_empty():
		return "Table"
	return "Table of %s -> %s" % [_describe_side(table_keys(info)), _describe_side(table_values(info))]


## How a Table of `given` goes where a Table of `wanted` is expected: ""
## (as it is), "convert" (into a new typed Dictionary, checked when the game
## runs) or "no". Unlike a List, decimals aren't rounded into Whole keys or
## values: that's "no".
static func table_fit(given: Dictionary, wanted: Dictionary) -> String:
	if wanted.is_empty():
		return ""
	var how: String = ""
	for side: String in ["keys", "values"]:
		var wanted_side: Dictionary = wanted.get(side, {})
		var given_side: Dictionary = given.get(side, {})
		var fit: String = list_fit(given_side, wanted_side)
		if fit == "no" or fit == "round":
			return "no"
		if fit == "convert" or (list_item(wanted_side) != T.ANY and list_item(given_side) == T.ANY):
			how = "convert"
	if how.is_empty() and table_gd_type(given) != table_gd_type(wanted):
		how = "convert"
	return how


static func _side_args(side: Dictionary) -> String:
	if list_item(side) == T.ANY:
		return "TYPE_NIL, &\"\", null"
	return "%s, &%s, null" % [LIST_VARIANT_TYPES[list_item(side)], var_to_str(_list_class(side))]


## Code that turns the Table `code` into one of `wanted`'s types.
static func table_converted(code: String, wanted: Dictionary, how: String) -> String:
	if how != "convert":
		return code
	return "Dictionary(%s, %s, %s)" % [code, _side_args(table_keys(wanted)), _side_args(table_values(wanted))]


## A typed-in empty Table's types (`Dictionary[String, float]({})` in the
## graph's text).
static func table_info_of_value(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var table: Dictionary = value
	var keys: Dictionary = _side_of(table.get_typed_key_builtin(), table.get_typed_key_class_name()) if table.is_typed_key() else {}
	var values: Dictionary = _side_of(table.get_typed_value_builtin(), table.get_typed_value_class_name()) if table.is_typed_value() else {}
	return table_info(keys, values)


static func _side_of(builtin: int, class_name_: StringName) -> Dictionary:
	if builtin == TYPE_OBJECT:
		if is_node_class(class_name_):
			return list_info(T.NODE, {} if class_name_ == &"Node" else {"class": class_name_})
		if is_resource_class(class_name_):
			return list_info(T.RESOURCE, {"class": class_name_})
		return {}
	for item: int in Types.VARIANT_TYPES:
		if Types.VARIANT_TYPES[item] == builtin:
			return list_info(item)
	return {}


## An empty Dictionary of `keys` -> `values` (ValueTypes; what the "of"
## dropdowns store).
static func empty_table(keys: int, values: int) -> Dictionary:
	if keys == T.ANY and values == T.ANY:
		return {}
	var key_args: Array = _empty_side(keys)
	var value_args: Array = _empty_side(values)
	return Dictionary({}, key_args[0], key_args[1], null, value_args[0], value_args[1], null)


static func _empty_side(item: int) -> Array:
	match item:
		T.NODE:
			return [TYPE_OBJECT, &"Node"]
		T.RESOURCE:
			return [TYPE_OBJECT, &"Resource"]
	return [Types.VARIANT_TYPES.get(item, TYPE_NIL), &""]

#endregion


## The List of the items a Make list puts in ([type, node type] each): all
## one type, numbers (Whole and Number) -> Number, nodes -> their nearest
## shared class, anything else mixed -> Anything.
static func list_info_of_items(items: Array) -> Dictionary:
	if items.is_empty():
		return {}
	var item: int = items[0][0]
	for entry: Array in items:
		if entry[0] == item:
			continue
		if Types.NUMERIC.has(entry[0]) and Types.NUMERIC.has(item):
			item = T.NUMBER
			continue
		return {}
	if item == T.NODE:
		var shared: StringName = &""
		var script: String = str(items[0][1].get("script", ""))
		for entry: Array in items:
			var class_name_: StringName = entry[1].get("class", &"Node")
			shared = class_name_ if shared.is_empty() else _common_class(shared, class_name_)
			if str(entry[1].get("script", "")) != script:
				script = ""
		var node_type: Dictionary = {}
		if is_node_class(shared) and shared != &"Node":
			node_type["class"] = shared
		if not script.is_empty():
			node_type["script"] = script
		return list_info(T.NODE, node_type)
	if item == T.RESOURCE:
		var shared: StringName = &""
		for entry: Array in items:
			var class_name_: StringName = entry[1].get("class", &"Resource")
			shared = class_name_ if shared.is_empty() else _common_class(shared, class_name_)
		return list_info(T.RESOURCE, {"class": shared if is_resource_class(shared) else &"Resource"})
	return list_info(item)


## The nearest class both are (or inherit from).
static func _common_class(a: StringName, b: StringName) -> StringName:
	if not ClassDB.class_exists(a) or not ClassDB.class_exists(b):
		return &"Object"
	var shared: StringName = a
	while not shared.is_empty() and shared != b and not ClassDB.is_parent_class(b, shared):
		shared = ClassDB.get_parent_class(shared)
	return shared

#endregion


## The Brickscript type of a Godot property / argument / return value
## (from a property-info Dictionary), and its node type for objects; or
## [-1] if Brickscript has no type for it (e.g. Transform2D). A NodePath is
## Text marked {"path": true}: the compiler converts it going in and out.
static func value_type_of(info: Dictionary) -> Array:
	match int(info.get("type", TYPE_NIL)):
		TYPE_NIL:
			return [T.ANY, {}] if int(info.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT else [-1, {}]
		TYPE_FLOAT: return [T.NUMBER, {}]
		TYPE_INT: return [T.WHOLE, {}]
		TYPE_STRING, TYPE_STRING_NAME: return [T.TEXT, {}]
		TYPE_NODE_PATH: return [T.TEXT, {"path": true}]
		TYPE_BOOL: return [T.BOOL, {}]
		TYPE_VECTOR2: return [T.VECTOR2, {}]
		TYPE_VECTOR3: return [T.VECTOR3, {}]
		TYPE_COLOR: return [T.COLOR, {}]
		TYPE_ARRAY: return [T.LIST, {}]
		TYPE_DICTIONARY: return [T.TABLE, {}]
		TYPE_OBJECT:
			var class_name_: StringName = _shared_class(str(info.get("class_name", "")))
			if is_node_class(class_name_):
				return [T.NODE, {"class": class_name_}]
			if is_resource_class(class_name_):
				return [T.RESOURCE, {"class": class_name_}]
	return [-1, {}]


## A member: {"name", "kind" ("property" / "method"), "type" (ValueType;
## a method's return type, -1 for none), "node" (node type of a Node value),
## "writable", "origin" (where it comes from: a class name, "Export",
## "Shared", "Constant", "script"), "native" (true: a Godot class member,
## written as `node.name`; false: a script member, reached by name with
## get / set / call), and for methods "args" ([ValueType, ...]) and
## "required" (how many must be given)}.
static func class_members(class_name_: StringName) -> Array[Dictionary]:
	if not is_node_class(class_name_):
		class_name_ = &"Node"
	if _class_cache.has(class_name_):
		return _class_cache[class_name_]
	var members: Array[Dictionary] = []
	var seen: Dictionary = {}
	for property: Dictionary in ClassDB.class_get_property_list(class_name_, false):
		var usage: int = int(property["usage"])
		var name: String = property["name"]
		# Not only what the Inspector shows: name, owner, ... too.
		if usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP) or name.contains("/") or seen.has(name):
			continue
		var typed: Array = value_type_of(property)
		if typed[0] < 0:
			continue
		seen[name] = true
		members.append({"name": name, "kind": "property", "type": typed[0], "node": typed[1], "native": true,
			"writable": not ClassDB.class_get_property_setter(class_name_, name).is_empty(), "origin": _declaring_class(class_name_, name)})
	for method: Dictionary in ClassDB.class_get_method_list(class_name_, false):
		var entry: Dictionary = _method_entry(method, true)
		if not entry.is_empty() and not seen.has(entry["name"]):
			seen[entry["name"]] = true
			entry["origin"] = _declaring_class(class_name_, entry["name"])
			members.append(entry)
	for signal_info: Dictionary in ClassDB.class_get_signal_list(class_name_, false):
		var entry: Dictionary = signal_entry(signal_info, true)
		entry["origin"] = _declaring_class(class_name_, entry["name"])
		members.append(entry)
	# The class's own members first (a ColorRect's color), then its parents'.
	var depth: Dictionary = {}
	var current: StringName = class_name_
	while ClassDB.class_exists(current):
		depth[String(current)] = depth.size()
		current = ClassDB.get_parent_class(current)
	members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_depth: int = depth.get(a["origin"], 99)
		var b_depth: int = depth.get(b["origin"], 99)
		return a_depth < b_depth or a_depth == b_depth and a["name"] < b["name"])
	_class_cache[class_name_] = members
	return members


## A script constant listing its properties that are read only.
const READ_ONLY_CONST: String = "_BRICKSCRIPT_READ_ONLY"


## Members a .gd script adds (its variables, constants and methods; not the
## ones of its base class).
static func gd_script_members(path: String) -> Array[Dictionary]:
	var time: int = FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0
	if _script_cache.has(path) and _script_cache[path]["time"] == time:
		return _script_cache[path]["members"]
	var members: Array[Dictionary] = []
	var script: Script = load(path) as Script if ResourceLoader.exists(path) else null
	if script != null:
		for property: Dictionary in script.get_script_property_list():
			var usage: int = int(property["usage"])
			if usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP) or not usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				continue
			var typed: Array = value_type_of(property)
			members.append({"name": property["name"], "kind": "property", "type": maxi(typed[0], T.ANY), "node": typed[1], "native": false,
				"writable": true, "origin": "Export" if usage & PROPERTY_USAGE_EDITOR else "script"})
		var constants: Dictionary = script.get_script_constant_map()
		# A script may list properties that are only for reading (a
		# character's on_the_floor, moving...): Set property refuses them.
		var read_only: PackedStringArray = PackedStringArray(constants.get(READ_ONLY_CONST, PackedStringArray()))
		for member: Dictionary in members:
			if read_only.has(member["name"]):
				member["writable"] = false
		for name: String in constants:
			if name == READ_ONLY_CONST:
				continue
			if not constants[name] is Object:
				members.append({"name": name, "kind": "property", "type": Types.of_value(constants[name]), "node": {}, "native": false, "writable": false, "origin": "Constant"})
		for method: Dictionary in script.get_script_method_list():
			var entry: Dictionary = _method_entry(method, false)
			if not entry.is_empty():
				entry["origin"] = "script"
				members.append(entry)
		for signal_info: Dictionary in script.get_script_signal_list():
			var entry: Dictionary = signal_entry(signal_info, false)
			entry["origin"] = "script"
			members.append(entry)
	_script_cache[path] = {"time": time, "members": members}
	return members


## The node type a script's nodes have: its base class, and the script.
static func of_script(path: String) -> Dictionary:
	var script: Script = load(path) as Script if not path.is_empty() and ResourceLoader.exists(path) else null
	if script == null:
		return {}
	return {"class": script.get_instance_base_type(), "script": path}


## A signal as a member: kind "signal", "args" (ValueTypes; Anything for a
## type Brickscript doesn't have), "arg_names", "arg_nodes" (node types).
static func signal_entry(signal_info: Dictionary, native: bool) -> Dictionary:
	var args: Array[int] = []
	var names: PackedStringArray = []
	var nodes: Array[Dictionary] = []
	for arg: Dictionary in signal_info.get("args", []):
		var typed: Array = value_type_of(arg)
		args.append(maxi(typed[0], T.ANY))
		names.append(str(arg.get("name", "value_%d" % (names.size() + 1))))
		nodes.append(typed[1])
	return {"name": signal_info["name"], "kind": "signal", "type": -1, "node": {}, "native": native, "writable": false,
		"args": args, "arg_names": names, "arg_nodes": nodes, "required": args.size()}


static func _method_entry(method: Dictionary, native: bool) -> Dictionary:
	var name: String = method["name"]
	if name.begins_with("_") or int(method.get("flags", 0)) & METHOD_FLAG_VIRTUAL:
		return {}
	var args: Array[int] = []
	var arg_nodes: Array[Dictionary] = []
	for arg: Dictionary in method["args"]:
		var typed: Array = value_type_of(arg)
		if typed[0] < 0:
			return {}
		args.append(typed[0])
		arg_nodes.append(typed[1])
	var returned: Dictionary = method.get("return", {})
	var returns: Array = value_type_of(returned) if int(returned.get("type", TYPE_NIL)) != TYPE_NIL or int(returned.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT else [-1, {}]
	# "const": a Godot method that only reads (get_child_count, is_on_floor...).
	return {"name": name, "kind": "method", "type": returns[0], "node": returns[1], "native": native, "writable": false,
		"args": args, "arg_nodes": arg_nodes, "required": args.size() - (method.get("default_args", []) as Array).size(),
		"const": native and int(method.get("flags", 0)) & METHOD_FLAG_CONST != 0}


static func _declaring_class(class_name_: StringName, member: String) -> String:
	var current: StringName = class_name_
	while ClassDB.class_exists(ClassDB.get_parent_class(current)):
		var parent: StringName = ClassDB.get_parent_class(current)
		if not ClassDB.class_has_method(parent, member) and not ClassDB.class_has_signal(parent, member) and not _class_has_property(parent, member):
			break
		current = parent
	return String(current)


static func _class_has_property(class_name_: StringName, member: String) -> bool:
	for property: Dictionary in ClassDB.class_get_property_list(class_name_, false):
		if property["name"] == member:
			return true
	return false


#region Scenes
## Whether a local brickscript may change a node of this type: a
## LOCAL_ONLY_CLASSES class (or subclass), or one it spawned itself
## ("local": true).
## Bodies a player's machine may move (their character): a local brickscript
## changing one is checked when the game runs (does this machine's player
## own it?), not refused when compiling.
const MOVABLE_CLASSES: Array[StringName] = [&"CharacterBody2D", &"CharacterBody3D", &"RigidBody2D", &"RigidBody3D", &"AnimatableBody2D", &"AnimatableBody3D"]


static func is_movable(node_type: Dictionary) -> bool:
	var class_name_: StringName = node_type.get("class", &"")
	return is_node_class(class_name_) and MOVABLE_CLASSES.any(func(movable: StringName) -> bool: return ClassDB.is_parent_class(class_name_, movable))


static func is_local_only(node_type: Dictionary) -> bool:
	if node_type.get("local", false):
		return true
	var class_name_: StringName = node_type.get("class", &"Node")
	if not is_node_class(class_name_):
		return false
	for local: StringName in LOCAL_ONLY_CLASSES:
		if class_name_ == local or ClassDB.is_parent_class(class_name_, local):
			return true
	return false


## The physics bodies and areas in a scene (and the scenes it instances), as
## "path (Class)": a local brickscript may only spawn scenes without any.
static func scene_bodies(scene_path: String, depth: int = 0) -> PackedStringArray:
	var found: PackedStringArray = []
	if depth > 8 or not scene_path.ends_with(".tscn") or not FileAccess.file_exists(scene_path):
		return found
	var resources: Dictionary = {}
	for line: String in _scene_text(scene_path).split("\n"):
		line = line.strip_edges()
		if line.begins_with("[ext_resource"):
			resources[_attribute(line, "id")] = _attribute(line, "path")
		elif line.begins_with("[node "):
			var name: String = _attribute(line, "name")
			var type: StringName = StringName(_attribute(line, "type"))
			if is_node_class(type) and (ClassDB.is_parent_class(type, &"CollisionObject2D") or ClassDB.is_parent_class(type, &"CollisionObject3D")):
				found.append("%s (%s)" % [name, type])
			var instance: String = _resource_id(line, "instance=ExtResource(")
			if not instance.is_empty():
				for inner: String in scene_bodies(resources.get(instance, ""), depth + 1):
					found.append("%s/%s" % [name, inner])
	return found


# Scenes are read as text (.tscn), never loaded: loading would load (and for
# brickscripts compile) every script they use, and fails on missing ones.

## The type of a scene's root node (its class, and its script if any), or {}.
static func scene_root_type(scene_path: String, depth: int = 0) -> Dictionary:
	var nodes: Array[Dictionary] = _scene_nodes(scene_path, depth)
	return nodes[0]["type"] if not nodes.is_empty() else {}


## Guesses the type of the node at `node_path` (relative to the node running
## `script_path`) from the project's scenes that use that script, or that
## instance one using it, or where a brickscript spawns one using it (Spawn
## scene: its root is placed under the spawn's parent, see
## spawn_placements()). Returns {"type": node type or {}, "scene": where it
## was found, "paths": every node path found relative to the script's node,
## for the path dropdowns, "types": path -> its node type, "names": path ->
## the node's name}. With `from_parent`, paths are from the parent of the
## node running the script (a script node acts for its parent).
static func guess_from_scenes(script_path: String, node_path: String, folder: String = "res://", from_parent: bool = false) -> Dictionary:
	# "seen": [[scene path, node type], ...] for `node_path` in every scene
	# (a brickscript can run under different parents); "type" is the type
	# they all share (shared_type()), "scene" the first.
	var result: Dictionary = {"type": {}, "scene": "", "paths": PackedStringArray(), "types": {}, "names": {}, "seen": []}
	if script_path.is_empty():
		return result
	var wanted: String = node_path.strip_edges()
	if wanted.is_empty():
		wanted = "."
	# Scenes that use the script, then scenes that instance one of those (a
	# script on a scene's root has its parent there).
	var using: PackedStringArray = []
	var instancing: PackedStringArray = []
	var texts: Dictionary = {}
	for scene_path: String in _scene_files(folder):
		texts[scene_path] = _scene_text(scene_path)
		if (texts[scene_path] as String).contains("\"%s\"" % script_path):
			using.append(scene_path)
	for scene_path: String in texts:
		if not using.has(scene_path) and Array(using).any(func(used: String) -> bool: return (texts[scene_path] as String).contains("\"%s\"" % used)):
			instancing.append(scene_path)
	var layouts: Array[Array] = []
	for scene_path: String in using + instancing:
		layouts.append([scene_path, _scene_nodes(scene_path, 0)])
	for placement: Dictionary in spawn_placements(folder):
		if placement["type"].get("script", "") == script_path:
			layouts.append([placement["scene"], placement["nodes"]])
	for layout: Array in layouts:
		var scene_path: String = layout[0]
		var nodes: Array[Dictionary] = []
		nodes.assign(layout[1])
		# (A brickscript inside a StarterPlayer / StarterCharacter: where its
		# copies run.)
		nodes = _starter_layout(nodes)
		for owner: Dictionary in nodes:
			if owner["type"].get("script", "") != script_path:
				continue
			# A script node's paths start at its parent (the node it acts for).
			var base: String = owner["path"]
			if from_parent:
				if base == ".":
					continue
				base = "." if not base.contains("/") else base.get_base_dir()
			for other: Dictionary in nodes:
				var relative: String = _relative_path(base, other["path"])
				if not result["paths"].has(relative):
					result["paths"].append(relative)
					result["types"][relative] = other["type"]
					result["names"][relative] = other.get("name", "")
				if relative == wanted:
					if (result["type"] as Dictionary).is_empty():
						result["type"] = other["type"]
						result["scene"] = scene_path
					if not (result["seen"] as Array).any(func(entry: Array) -> bool: return entry[0] == scene_path and entry[1] == other["type"]):
						(result["seen"] as Array).append([scene_path, other["type"]])
	var kinds: Array[Dictionary] = []
	for entry: Array in result["seen"]:
		if not kinds.has(entry[1]):
			kinds.append(entry[1])
	if kinds.size() > 1:
		result["type"] = shared_type(kinds)
	return result


## Where `guess` (guess_from_scenes) found its node as different types:
## "Node3D in a.tscn, CharacterBody3D in b.tscn" ("" when they agree).
static func mixed_note(guess: Dictionary) -> String:
	var kinds: Array = []
	var parts: PackedStringArray = []
	for entry: Array in guess.get("seen", []):
		if not kinds.has(entry[1]):
			kinds.append(entry[1])
		parts.append("%s in %s" % [describe(entry[1]), String(entry[0]).get_file()])
	return ", ".join(parts) if kinds.size() > 1 else ""


## The type every one of `types` is: the nearest class they all share, and
## their script if they all have the same one.
static func shared_type(types: Array[Dictionary]) -> Dictionary:
	if types.is_empty():
		return {}
	var shared: Dictionary = types[0].duplicate()
	for other: Dictionary in types:
		if other.get("script", "") != shared.get("script", ""):
			shared.erase("script")
		var shared_class: StringName = shared.get("class", &"Node")
		var other_class: StringName = other.get("class", &"Node")
		while not (other_class == shared_class or ClassDB.is_parent_class(other_class, shared_class)) and ClassDB.class_exists(ClassDB.get_parent_class(shared_class)):
			shared_class = ClassDB.get_parent_class(shared_class)
		shared["class"] = shared_class
	return shared


## The animations of the node at `node_path` from the node running
## `script_path` (see guess_from_scenes), read from the first scene that has
## it: an AnimationPlayer's or an animated sprite's. [] if not found.
static func animation_names(script_path: String, node_path: String, from_parent: bool = false) -> PackedStringArray:
	var guess: Dictionary = guess_from_scenes(script_path, node_path, "res://", from_parent)
	var scene_path: String = guess.get("scene", "")
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return PackedStringArray()
	var key: String = "%s|%s|%s|%s" % [script_path, node_path, from_parent, scene_path]
	var time: int = FileAccess.get_modified_time(scene_path)
	if _animation_cache.has(key) and _animation_cache[key][0] == time:
		return _animation_cache[key][1]
	var names: PackedStringArray = []
	var packed: PackedScene = load(scene_path) as PackedScene
	var instance: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED) if packed != null else null
	if instance != null:
		var owner: Node = _node_running(instance, script_path)
		var base: Node = owner.get_parent() if owner != null and from_parent else owner
		var target: Node = base.get_node_or_null(NodePath(node_path)) if base != null else null
		if target is AnimationPlayer:
			for animation: StringName in (target as AnimationPlayer).get_animation_list():
				names.append(String(animation))
		elif target != null and target.get(&"sprite_frames") is SpriteFrames:
			for animation: StringName in (target.get(&"sprite_frames") as SpriteFrames).get_animation_names():
				names.append(String(animation))
		instance.free()
	_animation_cache[key] = [time, names]
	return names


static func _node_running(under: Node, script_path: String) -> Node:
	var script: Script = under.get_script() as Script
	if script != null and script.resource_path == script_path:
		return under
	for child: Node in under.get_children():
		var found: Node = _node_running(child, script_path)
		if found != null:
			return found
	return null


## The node type of a node that carries `server_path` as its own server
## script (`server_script` metadata) in one of the project's scenes; {} if
## none does.
static func carrier_of_server_script(server_path: String, folder: String = "res://") -> Dictionary:
	for scene_path: String in _scene_files(folder):
		if not _scene_text(scene_path).contains("\"%s\"" % server_path):
			continue
		for node: Dictionary in _scene_nodes(scene_path, 0):
			if node.get("server_script", "") == server_path:
				return node["type"]
	return {}


## Groups the project uses: its global groups (Project Settings > Groups)
## and every group a scene puts a node in, sorted.
static func project_groups(folder: String = "res://") -> PackedStringArray:
	var found: Dictionary = {}
	for property: Dictionary in ProjectSettings.get_property_list():
		var name: String = property["name"]
		if name.begins_with("global_group/"):
			found[name.trim_prefix("global_group/")] = true
	for scene_path: String in _scene_files(folder):
		for node: Dictionary in _scene_nodes(scene_path, 0):
			for group: String in node["groups"]:
				found[group] = true
	var result: PackedStringArray = PackedStringArray(found.keys())
	result.sort()
	return result


## The node type of a group's nodes in the project's scenes: their class
## and script if they all share them (else the nearest shared class), or {}.
static func group_type(group: String, folder: String = "res://") -> Dictionary:
	var types: Array[Dictionary] = []
	for scene_path: String in _scene_files(folder):
		for node: Dictionary in _scene_nodes(scene_path, 0):
			if (node["groups"] as PackedStringArray).has(group):
				types.append(node["type"])
	return shared_type(types)


## Parsed scenes (Round A, 2026-11-03: path and group guesses re-parsed
## every scene on each pick): "path|depth" -> {"deps": {scene path: modified
## time} (itself and the scenes it instances), "nodes"}. Used while every
## dep's time is the same.
static var _nodes_cache: Dictionary = {}
## The deps of the scenes being parsed (innermost last).
static var _deps_stack: Array[Dictionary] = []
## Scene texts: path -> [modified time, text].
static var _text_cache: Dictionary = {}


## Whether a file's modified time (whole seconds) can be trusted for a
## cache: not changed in the last 2 seconds (saved twice in one second, the
## time wouldn't change).
static func _settled(time: int) -> bool:
	return int(Time.get_unix_time_from_system()) - time > 2


## A scene file's text, read again only when the file changed.
static func _scene_text(scene_path: String) -> String:
	var time: int = FileAccess.get_modified_time(scene_path)
	var cached: Array = _text_cache.get(scene_path, [])
	if not cached.is_empty() and cached[0] == time and _settled(time):
		return cached[1]
	var text: String = FileAccess.get_file_as_string(scene_path)
	_text_cache[scene_path] = [time, text]
	return text


## A .tscn's nodes, root first: [{"path" ("." for the root, "A/B"), "type",
## "groups"}]. Cached (see _nodes_cache); a copy, so callers may change it.
static func _scene_nodes(scene_path: String, depth: int) -> Array[Dictionary]:
	var key: String = "%s|%d" % [scene_path, depth]
	var cached: Dictionary = _nodes_cache.get(key, {})
	if not cached.is_empty() and (cached["deps"] as Dictionary).keys().all(func(dep: String) -> bool: return FileAccess.get_modified_time(dep) == cached["deps"][dep] and _settled(cached["deps"][dep])):
		if not _deps_stack.is_empty():
			_deps_stack[-1].merge(cached["deps"])
		return (cached["nodes"] as Array[Dictionary]).duplicate(true)
	_deps_stack.append({scene_path: FileAccess.get_modified_time(scene_path)})
	var nodes: Array[Dictionary] = _parse_scene_nodes(scene_path, depth)
	var deps: Dictionary = _deps_stack.pop_back()
	if not _deps_stack.is_empty():
		_deps_stack[-1].merge(deps)
	_nodes_cache[key] = {"deps": deps, "nodes": nodes.duplicate(true)}
	return nodes


static func _parse_scene_nodes(scene_path: String, depth: int) -> Array[Dictionary]:
	var nodes: Array[Dictionary] = []
	if depth > 8 or not scene_path.ends_with(".tscn") or not FileAccess.file_exists(scene_path):
		return nodes
	var resources: Dictionary = {}
	var current: Dictionary = {}
	for line: String in _scene_text(scene_path).split("\n"):
		line = line.strip_edges()
		if line.begins_with("[ext_resource"):
			resources[_attribute(line, "id")] = _attribute(line, "path")
		elif line.begins_with("[node "):
			var name: String = _attribute(line, "name")
			var parent: String = _attribute(line, "parent")
			var path: String = "." if not line.contains("parent=") else name if parent == "." else parent + "/" + name
			var type: Dictionary = {"class": StringName(_attribute(line, "type"))}
			var instance: String = _resource_id(line, "instance=ExtResource(")
			if not instance.is_empty():
				type = scene_root_type(resources.get(instance, ""), depth + 1).duplicate()
			if String(type.get("class", &"")).is_empty():
				type["class"] = &"Node"
			var groups: PackedStringArray = []
			var start: int = line.find("groups=[")
			if start >= 0:
				for group: String in line.substr(start + 8, line.find("]", start) - start - 8).split(",", false):
					groups.append(group.strip_edges().trim_prefix("\"").trim_suffix("\""))
			current = {"path": path, "type": type, "groups": groups, "name": name, "instance": not instance.is_empty()}
			nodes.append(current)
		elif line.begins_with("["):
			current = {}
		elif not current.is_empty() and line.begins_with("script = ExtResource("):
			var script: String = resources.get(_resource_id(line, "script = ExtResource("), "")
			if not script.is_empty():
				current["type"]["script"] = script
		elif not current.is_empty() and line.begins_with("metadata/server_script = ExtResource("):
			# The node's own server script (Network Context Engine).
			current["server_script"] = resources.get(_resource_id(line, "metadata/server_script = ExtResource("), "")
		elif not current.is_empty() and line.begins_with("character_scene = ExtResource("):
			# A Character Spawner's (for StarterCharacter, see _starter_layout).
			current["character_scene"] = resources.get(_resource_id(line, "character_scene = ExtResource("), "")
		elif not current.is_empty():
			for key: String in STARTER_LINKS:
				if line.begins_with(key + " = NodePath(\""):
					current[key] = line.trim_prefix(key + " = NodePath(\"").trim_suffix("\")")
	return nodes


## Get root's Type, from the scenes: for Its scene, the root of the scene
## file the node at `node_path` (from the node running `script_path`) is
## saved in, in the first scene that has the script (a placed scene's root is
## its own). {} when the scenes don't say: a path above that scene's root, a
## script in a StarterPlayer / StarterCharacter (its copies run in other
## scenes), and the game's scene (`game`): a brickscript may run in any level,
## not only the main scene.
static func root_type_guess(script_path: String, node_path: String, game: bool, folder: String = "res://") -> Dictionary:
	if game:
		return {}
	for scene_path: String in _scene_files(folder):
		if not _scene_text(scene_path).contains("\"%s\"" % script_path):
			continue
		var nodes: Array[Dictionary] = _scene_nodes(scene_path, 0)
		var types: Dictionary = {}
		for node: Dictionary in nodes:
			types[node["path"]] = node
		for owner: Dictionary in nodes:
			if owner["type"].get("script", "") != script_path:
				continue
			var steps: PackedStringArray = [] if owner["path"] == "." else owner["path"].split("/")
			for i: int in steps.size():
				if types.get("/".join(steps.slice(0, i + 1)), {}).get("type", {}).get("script", "") == STARTER_SCRIPT:
					return {}
			for step: String in node_path.strip_edges().split("/", false):
				if step == "..":
					if steps.is_empty():
						return {}
					steps.remove_at(steps.size() - 1)
				elif step != ".":
					steps.append(step)
			var target: Dictionary = types.get("." if steps.is_empty() else "/".join(steps), {})
			if target.is_empty():
				return {}
			return target["type"] if target.get("instance", false) else nodes[0]["type"]
	return {}


## A scene's nodes as the game has them where a brickscript inside a
## StarterPlayer / StarterCharacter (BrickscriptStarter) runs: the starter's
## children are copied into every player node (under the Players node whose
## `starter` it is: the starter stands in for a BrickscriptPlayer there) or
## into every character (under the Character Spawner whose
## `starter_character` it is, in its container: the starter stands in for
## the character scene's root, with that scene's nodes). Other starters, and
## scenes without one, stay as they are.
static func _starter_layout(nodes: Array[Dictionary]) -> Array[Dictionary]:
	var moved: Dictionary = {}
	var extra: Array[Dictionary] = []
	for starter: Dictionary in nodes:
		if starter["type"].get("script", "") != STARTER_SCRIPT:
			continue
		for user: Dictionary in nodes:
			var script: String = user["type"].get("script", "")
			if script == PLAYERS_SCRIPT and _resolve_path(user["path"], str(user.get("starter", "../StarterPlayer"))) == starter["path"]:
				var at: String = _join(user["path"], starter["name"])
				moved[starter["path"]] = [at, {"class": &"Node", "script": PLAYER_SCRIPT}]
			elif script == SPAWNER_SCRIPT and not str(user.get("starter_character", "")).is_empty() and _resolve_path(user["path"], str(user["starter_character"])) == starter["path"]:
				var holder: String = _resolve_path(user["path"], str(user.get("container", ".")))
				var at: String = _join(holder if not holder.is_empty() else user["path"], starter["name"])
				var inner: Array[Dictionary] = _scene_nodes(str(user.get("character_scene", "")), 1)
				moved[starter["path"]] = [at, inner[0]["type"] if not inner.is_empty() else {"class": &"Node"}]
				for node: Dictionary in inner.slice(1):
					extra.append({"path": at + "/" + String(node["path"]), "type": node["type"], "groups": node.get("groups", PackedStringArray()), "name": node.get("name", "")})
	if moved.is_empty():
		return nodes
	var result: Array[Dictionary] = []
	for node: Dictionary in nodes:
		var copy: Dictionary = node
		for from: String in moved:
			var path: String = node["path"]
			if path == from or path.begins_with(from + "/"):
				copy = node.duplicate()
				copy["path"] = String(moved[from][0]) + path.substr(from.length())
				if path == from:
					copy["type"] = moved[from][1]
		result.append(copy)
	var taken: Dictionary = {}
	for node: Dictionary in result:
		taken[node["path"]] = true
	for node: Dictionary in extra:
		if not taken.has(node["path"]):
			result.append(node)
	return result


static func _join(base: String, name: String) -> String:
	return name if base == "." else base + "/" + name


## The value of `key="..."` in a .tscn header line.
static func _attribute(line: String, key: String) -> String:
	var start: int = line.find(" %s=\"" % key)
	if start < 0:
		return ""
	start += key.length() + 3
	return line.substr(start, line.find("\"", start) - start)


## The id in `prefix"id")` within a line.
static func _resource_id(line: String, prefix: String) -> String:
	var start: int = line.find(prefix)
	if start < 0:
		return ""
	start += prefix.length() + 1
	return line.substr(start, line.find("\"", start) - start)


static func _relative_path(base: String, target: String) -> String:
	var base_parts: PackedStringArray = [] if base == "." else base.split("/")
	var target_parts: PackedStringArray = [] if target == "." else target.split("/")
	var common: int = 0
	while common < base_parts.size() and common < target_parts.size() and base_parts[common] == target_parts[common]:
		common += 1
	var parts: PackedStringArray = []
	for i: int in base_parts.size() - common:
		parts.append("..")
	parts.append_array(target_parts.slice(common))
	return "." if parts.is_empty() else "/".join(parts)


## Where brickscripts spawn scenes (Spawn scene with a typed-in parent): for
## each, a scene that has the spawning node, with the spawned scene's root
## added under the parent. {"scene": that scene, "type": the spawned root's
## node type, "nodes": its nodes plus the placed root}. Cached until a
## brickscript or scene file changes.
static func spawn_placements(folder: String = "res://") -> Array[Dictionary]:
	var bricks: PackedStringArray = _files_with(folder, BRICK_EXTENSIONS)
	var scenes: PackedStringArray = _scene_files(folder)
	var key: String = folder
	for file: String in bricks + scenes:
		key += "|%s:%d" % [file, FileAccess.get_modified_time(file)]
	if _placements_key == key:
		return _placements
	var placements: Array[Dictionary] = []
	var brick_file: GDScript = load(BRICK_FILE_PATH)
	for file: String in bricks:
		var graph: BrickscriptFlowGraph = brick_file.call(&"load_graph", file)
		if graph == null:
			continue
		# A server brickscript's paths start from its body: the node running
		# its paired local script.
		var spawner: String = brick_file.call(&"body_script_for", file) if graph.context == &"server" else file
		if spawner.is_empty():
			continue
		for brick: BrickscriptFlowNode in graph.nodes:
			if brick == null or brick.type != &"spawn_scene":
				continue
			var spawned: String = str(brick.settings.get(&"scene", "")).strip_edges()
			var parent: Dictionary = brick.inputs.get(&"parent", {"type": T.NODE, "value": ".."})
			if spawned.is_empty() or parent.has("var") or not ResourceLoader.exists(spawned):
				continue
			var root: Array[Dictionary] = _scene_nodes(spawned, 0)
			if root.is_empty():
				continue
			for scene_path: String in scenes:
				if not _scene_text(scene_path).contains("\"%s\"" % spawner):
					continue
				var nodes: Array[Dictionary] = _scene_nodes(scene_path, 0)
				for owner: Dictionary in nodes:
					if owner["type"].get("script", "") != spawner:
						continue
					var at: String = _resolve_path(owner["path"], str(parent.get("value", "..")))
					if at.is_empty():
						continue
					var placed: Dictionary = root[0].duplicate()
					placed["path"] = String(root[0]["name"]) if at == "." else at + "/" + String(root[0]["name"])
					placements.append({"scene": scene_path, "type": root[0]["type"], "nodes": nodes + [placed]})
	_placements_key = key
	_placements = placements
	return placements


## A node path inside a scene ("." is the root) followed by a relative path;
## "" if it leaves the scene.
static func _resolve_path(from: String, relative: String) -> String:
	var parts: PackedStringArray = [] if from == "." else from.split("/")
	for part: String in relative.strip_edges().split("/", false):
		if part == "..":
			if parts.is_empty():
				return ""
			parts.remove_at(parts.size() - 1)
		elif part != ".":
			parts.append(part)
	return "." if parts.is_empty() else "/".join(parts)


static func _files_with(folder: String, extensions: PackedStringArray) -> PackedStringArray:
	if cache_walks:
		var key: String = "files|%s|%s" % [folder, ",".join(extensions)]
		if not _walks.has(key):
			_walks[key] = _walk_files_with(folder, extensions)
		return (_walks[key] as PackedStringArray).duplicate()
	return _walk_files_with(folder, extensions)


static func _walk_files_with(folder: String, extensions: PackedStringArray) -> PackedStringArray:
	var found: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return found
	for file: String in dir.get_files():
		if extensions.has(file.get_extension()):
			found.append(folder.path_join(file))
	for sub: String in dir.get_directories():
		if not sub.begins_with(".") and sub != "addons" and not FileAccess.file_exists(folder.path_join(sub).path_join(".gdignore")):
			found.append_array(_walk_files_with(folder.path_join(sub), extensions))
	return found


## Folder walks remembered while `cache_walks` is on: the editor plugin turns
## it on and calls forget_files() whenever the editor's file system changes
## (a file added, removed, moved). Off (tests, the game): every call walks.
static var cache_walks: bool = false
static var _walks: Dictionary = {}


static func forget_files() -> void:
	_walks.clear()


static func _scene_files(folder: String) -> PackedStringArray:
	if cache_walks:
		var key: String = "scenes|" + folder
		if not _walks.has(key):
			_walks[key] = _walk_scene_files(folder)
		return (_walks[key] as PackedStringArray).duplicate()
	return _walk_scene_files(folder)


static func _walk_scene_files(folder: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return found
	for file: String in dir.get_files():
		if file.ends_with(".tscn"):
			found.append(folder.path_join(file))
	for sub: String in dir.get_directories():
		if not sub.begins_with(".") and sub != "addons" and not FileAccess.file_exists(folder.path_join(sub).path_join(".gdignore")):
			found.append_array(_walk_scene_files(folder.path_join(sub)))
	return found

#endregion
