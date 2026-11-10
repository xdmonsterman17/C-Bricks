@tool
class_name BrickscriptFileLoader
extends ResourceFormatLoader

## Loads .bricklocal / .brickserver files as GDScripts compiled from their
## graphs (nodes and scenes use them as their script), and older .brick files
## as BrickscriptFlowGraph (see brick_file.gd). Godot
## registers it itself because it has a class_name: loaders added by hand are
## dropped whenever the editor refreshes its script classes (after a scan).

const BrickFile = preload("brick_file.gd")


func _get_recognized_extensions() -> PackedStringArray:
	return BrickFile.EXTENSIONS


func _handles_type(type: StringName) -> bool:
	return type == &"Script" or type == &"GDScript" or type == &"Resource"


## .bricklocal / .brickserver are scripts; older .brick files are graphs.
## Reported as "Script", not "GDScript": the editor re-reads a "GDScript"
## file's text as GDScript source (to update its docs), which a graph isn't.
func _get_resource_type(path: String) -> String:
	if BrickFile.is_script_path(path):
		return "Script"
	return "Resource" if BrickFile.is_brick_path(path) else ""


func _get_resource_script_class(path: String) -> String:
	if not BrickFile.is_brick_path(path) or BrickFile.is_script_path(path):
		return ""
	return "BrickscriptServerGraph" if BrickFile.is_server_path(path) else "BrickscriptFlowGraph"


func _load(path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	if BrickFile.is_script_path(path):
		return BrickFile.load_script(path)
	var graph: BrickscriptFlowGraph = BrickFile.load_graph(path)
	return graph if graph != null else ERR_FILE_CORRUPT


## Registers the brickscript loader and saver now if Godot hasn't yet. Godot
## adds them only after a `-s` SceneTree script's `_init()` has run, so there
## `load()` of a brickscript fails ("No loader found") and a scene packed and
## saved there loses its brickscripts. Better: do the work in `_initialize()`,
## which runs after; call this only when it has to happen in `_init()`.
## Returns true if it had to register them.
static func ensure_registered() -> bool:
	if ResourceLoader.get_recognized_extensions_for_type("Script").has(BrickFile.EXTENSIONS[0]):
		return false
	ResourceLoader.add_resource_format_loader(BrickscriptFileLoader.new())
	ResourceSaver.add_resource_format_saver(BrickscriptFileSaver.new())
	return true
