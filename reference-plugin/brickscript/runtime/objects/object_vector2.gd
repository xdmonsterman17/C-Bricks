@icon("res://addons/brickscript/icons/nodes/object_vector2.svg")
class_name ObjectVector2
extends BrickscriptObjectValue

## A Vector2: a 2D position or direction. The server changes it; every machine sees it (see BrickscriptObjectValue).

@export var value: Vector2 = Vector2.ZERO:
	set(new_value):
		if value == new_value:
			return
		value = new_value
		_value_changed()
