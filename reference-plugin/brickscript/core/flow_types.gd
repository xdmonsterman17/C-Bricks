@tool
extends RefCounted

## The value types of Brickscript's wire graphs: what each is called, its
## GDScript type, default and sample value, and how a typed-in value of it is
## written as code. Pure data, no editor dependencies.
##
## The numbers match BrickscriptVariable.type (1 / 2 / 4 were the first three),
## so variables keep their type across the redesign.

## PLAYER: a player (Owner, Me, Player Joined...). The code holds the
## player's node (a BrickscriptPlayer under the Players node); null is "no
## player". It can't be typed in; Node inputs take it too (its values are its
## children), and str(player) is its name. Graph files store "no player" as 0.
enum ValueType { ANY = 0, NUMBER = 1, TEXT = 2, WHOLE = 4, BOOL = 5, VECTOR2 = 6, VECTOR3 = 7, COLOR = 8, NODE = 9, LIST = 10, TABLE = 11, RESOURCE = 12, PLAYER = 13 }

## Order of the type dropdown.
const ORDER: Array[int] = [
	ValueType.NUMBER, ValueType.WHOLE, ValueType.TEXT, ValueType.BOOL, ValueType.VECTOR2,
	ValueType.VECTOR3, ValueType.COLOR, ValueType.NODE, ValueType.RESOURCE, ValueType.LIST, ValueType.TABLE,
]
const NAMES: Dictionary[int, String] = {
	ValueType.ANY: "Anything", ValueType.NUMBER: "Number", ValueType.TEXT: "Text",
	ValueType.WHOLE: "Whole", ValueType.BOOL: "Bool", ValueType.VECTOR2: "Vector2",
	ValueType.VECTOR3: "Vector3", ValueType.COLOR: "Color", ValueType.NODE: "Node",
	ValueType.LIST: "List", ValueType.TABLE: "Table", ValueType.RESOURCE: "Resource",
	ValueType.PLAYER: "Player",
}
const GDSCRIPT_TYPES: Dictionary[int, String] = {
	ValueType.NUMBER: "float", ValueType.TEXT: "String", ValueType.WHOLE: "int",
	ValueType.BOOL: "bool", ValueType.VECTOR2: "Vector2", ValueType.VECTOR3: "Vector3",
	ValueType.COLOR: "Color", ValueType.NODE: "Node", ValueType.LIST: "Array",
	ValueType.TABLE: "Dictionary", ValueType.RESOURCE: "Resource", ValueType.PLAYER: "BrickscriptPlayer",
}
## The Variant type a value of each type is (a List's typed Array items).
const VARIANT_TYPES: Dictionary[int, int] = {
	ValueType.NUMBER: TYPE_FLOAT, ValueType.WHOLE: TYPE_INT, ValueType.TEXT: TYPE_STRING,
	ValueType.BOOL: TYPE_BOOL, ValueType.VECTOR2: TYPE_VECTOR2, ValueType.VECTOR3: TYPE_VECTOR3,
	ValueType.COLOR: TYPE_COLOR, ValueType.LIST: TYPE_ARRAY, ValueType.TABLE: TYPE_DICTIONARY,
	ValueType.PLAYER: TYPE_OBJECT,
}
## Types that can only be typed in empty (to start a List / Table, e.g. in
## Set Var); their items come from Make list / Make table or edits.
const EMPTY_ONLY: Array[int] = [ValueType.LIST, ValueType.TABLE]
const NUMERIC: Array[int] = [ValueType.NUMBER, ValueType.WHOLE]
const VECTORS: Array[int] = [ValueType.VECTOR2, ValueType.VECTOR3]


static func type_name(type: int) -> String:
	return NAMES.get(type, "?")


static func is_known(type: int) -> bool:
	return GDSCRIPT_TYPES.has(type)


## A fresh default value: 0, "", false, zero vector, black, null, [] or {}
## (a Resource has none: a file must be picked).
static func default_value(type: int) -> Variant:
	match type:
		ValueType.NUMBER: return 0.0
		ValueType.WHOLE, ValueType.PLAYER: return 0
		ValueType.TEXT: return ""
		ValueType.BOOL: return false
		ValueType.VECTOR2: return Vector2.ZERO
		ValueType.VECTOR3: return Vector3.ZERO
		ValueType.COLOR: return Color(0, 0, 0)
		ValueType.LIST: return []
		ValueType.TABLE: return {}
	return null


## What a Formula can read of a Player (a BrickscriptPlayer node), to try one
## out: `player.peer_id`, `player.username`, `str(player)`...
class PlayerSample extends RefCounted:
	var peer_id: int = 2
	var username: String = "Player2"
	var user_id: String = "0123456789abcdef"
	var name: StringName = &"Player2"

	func is_me() -> bool:
		return false

	func _to_string() -> String:
		return String(name)


## A non-zero stand-in, used to try a formula out and learn its result type.
## null for types a formula can't be tried with (Node, List, Table).
static func sample_value(type: int) -> Variant:
	match type:
		ValueType.NUMBER: return 1.5
		ValueType.WHOLE: return 3
		ValueType.PLAYER: return PlayerSample.new()
		ValueType.TEXT: return "a"
		ValueType.BOOL: return true
		ValueType.VECTOR2: return Vector2(1.5, 2.5)
		ValueType.VECTOR3: return Vector3(1.5, 2.5, 3.5)
		ValueType.COLOR: return Color(0.5, 0.5, 0.5)
	return null


## The type of a runtime value, or ANY if Brickscript has no type for it.
static func of_value(value: Variant) -> int:
	match typeof(value):
		TYPE_FLOAT: return ValueType.NUMBER
		TYPE_INT: return ValueType.WHOLE
		TYPE_STRING, TYPE_STRING_NAME: return ValueType.TEXT
		TYPE_BOOL: return ValueType.BOOL
		TYPE_VECTOR2: return ValueType.VECTOR2
		TYPE_VECTOR3: return ValueType.VECTOR3
		TYPE_COLOR: return ValueType.COLOR
		TYPE_OBJECT: return ValueType.RESOURCE if value is Resource else ValueType.NODE
		TYPE_ARRAY: return ValueType.LIST
		TYPE_DICTIONARY: return ValueType.TABLE
	return ValueType.ANY


## Whether a value of type `given` may go where `wanted` is expected. Number
## and Whole fit each other (a decimal into a whole is rounded). Anything (an
## item from a List or Table) fits everywhere; GDScript checks it at runtime.
static func fits(given: int, wanted: int) -> bool:
	return wanted == ValueType.ANY or given == ValueType.ANY or given == wanted or (NUMERIC.has(given) and NUMERIC.has(wanted))


## The GDScript type of a variable of `type` (Anything is `Variant`).
static func gd_type(type: int) -> String:
	return "Variant" if type == ValueType.ANY else GDSCRIPT_TYPES.get(type, "Variant")


## Code for a value of `type`, or "" if `value` can't be one (see
## literal_problem()). Text goes through var_to_str(), so typed text can never
## become code.
static func literal(type: int, value: Variant) -> String:
	if not literal_problem(type, value).is_empty():
		return ""
	match type:
		ValueType.NUMBER: return var_to_str(float(value))
		ValueType.WHOLE: return str(roundi(value))
		ValueType.PLAYER: return "null"
		ValueType.TEXT: return var_to_str(str(value))
		ValueType.BOOL: return "true" if value else "false"
		ValueType.NODE:
			match str(value).strip_edges():
				".": return "self"
				"..": return "get_parent()"
			return "get_node(%s)" % var_to_str(NodePath(str(value)))
		# A project file (texture, sound, scene...), loaded when it's used.
		ValueType.RESOURCE: return "load(%s)" % var_to_str(str(value).strip_edges())
		# An empty List may carry its item type (`Array[float]([])`); the
		# variable it goes into is declared with it.
		ValueType.LIST: return "[]"
		# An empty Table likewise (`Dictionary[String, float]({})`).
		ValueType.TABLE: return "{}"
	return var_to_str(value)


## A node path as bricks show it, Roblox style: "." is Self (the node the
## brickscript is: a script node itself), ".." Self.Parent, "../UI/Score"
## Self.Parent.UI.Score. Godot node names can't hold ".", so it reads back
## exactly (path_typed). Blank stays blank; an absolute path, a %Unique name
## or one with a :property stays as Godot writes it.
static func path_shown(path: String) -> String:
	var text: String = path.strip_edges()
	if text.is_empty() or text.begins_with("/") or text.contains(":") or text.contains("%"):
		return text
	var parts: PackedStringArray = ["Self"]
	for step: String in text.split("/", false):
		if step == "..":
			parts.append("Parent")
		elif step.to_lower() == "parent":
			# A node really named Parent: only the Godot way says it.
			return text
		elif step != ".":
			parts.append(step)
	return ".".join(parts)


## A path typed in either way (Self.Parent.UI or ../UI) as a Godot path
## ("self" / "parent" in any case; a child really named Parent is typed
## the Godot way: Parent).
static func path_typed(text: String) -> String:
	var typed: String = text.strip_edges()
	var head: String = typed.get_slice(".", 0)
	if head.to_lower() != "self" or typed.contains("/"):
		return typed
	var steps: PackedStringArray = []
	for part: String in typed.split(".", false).slice(1):
		steps.append(".." if part.to_lower() == "parent" else part)
	return "." if steps.is_empty() else "/".join(steps)


## Why `value` can't be typed in as `type`, or "" if it can.
static func literal_problem(type: int, value: Variant) -> String:
	if not is_known(type):
		return "unknown type"
	match type:
		ValueType.LIST:
			if not value is Array or not (value as Array).is_empty():
				return "a List can only be typed in empty; build one with Make list"
		ValueType.TABLE:
			if not value is Dictionary or not (value as Dictionary).is_empty():
				return "a Table can only be typed in empty; build one with Make table"
		ValueType.NUMBER, ValueType.WHOLE:
			if not (value is float or value is int) or not is_finite(float(value)):
				return "expected a number"
		ValueType.TEXT:
			if not (value is String or value is StringName):
				return "expected text"
		ValueType.BOOL:
			if not value is bool:
				return "expected true or false"
		ValueType.VECTOR2:
			if not value is Vector2 or not (value as Vector2).is_finite():
				return "expected a Vector2"
		ValueType.VECTOR3:
			if not value is Vector3 or not (value as Vector3).is_finite():
				return "expected a Vector3"
		ValueType.COLOR:
			if not value is Color:
				return "expected a Color"
		ValueType.NODE:
			if not (value is String or value is NodePath) or str(value).is_empty():
				return "expected a node path (Self, Self.Parent, Self.Parent.UI...)"
		ValueType.RESOURCE:
			if not value is String or not (value as String).strip_edges().begins_with("res://") or (value as String).strip_edges() == "res://":
				return "pick a file (res://...)"
		ValueType.PLAYER:
			# Only "no player" (a variable's starting value).
			if not (value is int and value == 0):
				return "a Player can't be typed in: get one with Owner or Me"
	return ""
