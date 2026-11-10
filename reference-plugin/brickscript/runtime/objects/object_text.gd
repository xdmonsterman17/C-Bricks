@icon("res://addons/brickscript/icons/nodes/object_text.svg")
class_name ObjectText
extends BrickscriptObjectValue

## A Text: a team name, a status. The server changes it; every machine sees it (see BrickscriptObjectValue).

@export var value: String = "":
	set(new_value):
		if value == new_value:
			return
		value = new_value
		_value_changed()
