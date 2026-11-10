@icon("res://addons/brickscript/icons/nodes/object_whole.svg")
class_name ObjectWhole
extends BrickscriptObjectValue

## A Whole number: gems, kills, a level. The server changes it; every machine sees it (see BrickscriptObjectValue).

@export var value: int = 0:
	set(new_value):
		if value == new_value:
			return
		value = new_value
		_value_changed()
