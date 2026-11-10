@tool
class_name BrickscriptFileSaver
extends ResourceFormatSaver

## Saves BrickscriptFlowGraph as .bricklocal / .brickserver (or .brick) text.
## Godot registers it itself because it has a class_name (see brick_loader.gd).
## A brickscript loaded as a GDScript is never written back: its graph file is
## the source (the Brickscript tab saves it), so saving one is a no-op rather
## than an error.

const BrickFile = preload("brick_file.gd")


func _recognize(resource: Resource) -> bool:
	return resource is BrickscriptFlowGraph or resource is GDScript and BrickFile.is_script_path(resource.resource_path)


func _get_recognized_extensions(resource: Resource) -> PackedStringArray:
	if resource is BrickscriptFlowGraph:
		return BrickFile.EXTENSIONS
	if resource is GDScript and BrickFile.is_script_path(resource.resource_path):
		return PackedStringArray([resource.resource_path.get_extension()])
	return PackedStringArray()


func _save(resource: Resource, path: String, _flags: int) -> Error:
	if resource is GDScript:
		return OK
	return BrickFile.save_graph(resource as BrickscriptFlowGraph, path)
