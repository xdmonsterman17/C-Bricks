@tool
class_name BrickscriptFlowNode
extends Resource

## One node of a Brickscript wire graph. What it does is defined by its `type`
## in flow_library.gd; this resource only holds the user's choices for it.
## Nodes are joined by execution wires only: values travel through named
## variables, never through wires.

const Types = preload("flow_types.gd")

## Unique within its graph; exec wires point at it.
@export var id: int = 0
## Node id, a key of flow_library.gd NODES (e.g. &"print").
@export var type: StringName = &""
## Input values by input name. Each is either {"var": "name"} (read the
## variable with that name) or {"type": ValueType, "value": typed-in value}.
## A missing input uses the definition's default.
@export var inputs: Dictionary[StringName, Dictionary] = {}
## Typed-in settings that are not values: action names, the formula text,
## Set Var's name and var_kind, loop names, row count.
@export var settings: Dictionary[StringName, Variant] = {}
## Where the node's result goes. Blank: the result is not kept.
@export var output_name: String = ""
## false: `output_name` makes a new chain variable. true: it names an
## existing variable (chain or script) to write into.
@export var use_var: bool = false
## Exec wires out, by exit name (&"next", &"true" / &"false", events &"1",
## &"2", ...) -> id of the node they lead to.
@export var exits: Dictionary[StringName, int] = {}
## Where the node sits on the editor canvas. Editor-only.
@export var position: Vector2 = Vector2.ZERO
## Size the user dragged it to on the canvas (whole grid squares). ZERO: fit
## its content. Editor-only.
@export var size: Vector2 = Vector2.ZERO


func input_variable(input: StringName, var_name: String) -> BrickscriptFlowNode:
	inputs[input] = {"var": var_name}
	return self


func input_value(input: StringName, value_type: int, value: Variant) -> BrickscriptFlowNode:
	inputs[input] = {"type": value_type, "value": value}
	return self


## A Node input typed in as a path, with the node's type (what the editor's
## path picker stores from the scenes): `node_class` a Godot class
## (&"Label"), `script` the node's script if it has one. With the type,
## bricks know the node (Property lists its members, a local brickscript may
## change a Label).
func input_node(input: StringName, path: String, node_class: StringName = &"", script: String = "") -> BrickscriptFlowNode:
	var data: Dictionary = {"type": Types.ValueType.NODE, "value": path}
	if node_class != &"" or not script.is_empty():
		data["node"] = {"class": node_class if node_class != &"" else &"Node"}
		if not script.is_empty():
			data["node"]["script"] = script
	inputs[input] = data
	return self


func output(name: String, into_existing: bool = false) -> BrickscriptFlowNode:
	output_name = name
	use_var = into_existing
	return self


func setting(setting_name: StringName, value: Variant) -> BrickscriptFlowNode:
	settings[setting_name] = value
	return self
