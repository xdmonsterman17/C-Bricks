@icon("res://addons/brickscript/icons/nodes/object_bool.svg")
class_name ObjectBool
extends BrickscriptObjectValue

## A Bool (true / false): a door open, a player ready. The server changes it; every machine sees it (see BrickscriptObjectValue).

@export var value: bool = false:
	set(new_value):
		if value == new_value:
			return
		value = new_value
		_value_changed()
