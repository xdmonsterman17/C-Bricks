@icon("res://addons/brickscript/icons/nodes/object_color.svg")
class_name ObjectColor
extends BrickscriptObjectValue

## A Color: a team color. The server changes it; every machine sees it (see BrickscriptObjectValue).

@export var value: Color = Color.WHITE:
	set(new_value):
		if value == new_value:
			return
		value = new_value
		_value_changed()
