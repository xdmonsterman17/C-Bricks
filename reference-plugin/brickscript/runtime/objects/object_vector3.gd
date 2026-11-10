@icon("res://addons/brickscript/icons/nodes/object_vector3.svg")
class_name ObjectVector3
extends BrickscriptObjectValue

## A Vector3: a 3D position or direction. The server changes it; every machine sees it (see BrickscriptObjectValue).

@export var value: Vector3 = Vector3.ZERO:
	set(new_value):
		if value == new_value:
			return
		value = new_value
		_value_changed()
