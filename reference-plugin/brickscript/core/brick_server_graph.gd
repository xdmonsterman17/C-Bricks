@tool
@icon("res://addons/brickscript/icons/brickscript_server.svg")
class_name BrickscriptServerGraph
extends BrickscriptFlowGraph

## A server brickscript (.brickserver): a BrickscriptFlowGraph whose context
## is &"server". Its own class only so the FileSystem and Inspector show it
## with the server icon; it behaves exactly like any other graph.


func _init() -> void:
	context = &"server"
