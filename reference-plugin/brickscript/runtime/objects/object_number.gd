@icon("res://addons/brickscript/icons/nodes/object_number.svg")
class_name ObjectNumber
extends BrickscriptObjectValue

## A Number: health, a speed, a time. The server changes it; every machine sees it (see BrickscriptObjectValue).

@export var value: float = 0.0:
	set(new_value):
		if value == new_value:
			return
		value = new_value
		_value_changed()
