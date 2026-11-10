@icon("res://addons/brickscript/icons/nodes/starter.svg")
class_name BrickscriptStarter
extends Node

## What every new player or character starts with (like Roblox's
## StarterPlayer / StarterCharacterScripts): its children are copied into
## each one. A PlayerService has two: StarterPlayer (the Players node copies
## it into every player node) and StarterCharacter (the Character Spawner
## copies it into every character).
## - Object values (Object Number, Object Text...) and other nodes: on every
##   machine.
## - LocalScript nodes: only on that player's own machine (their Fire Server
##   reaches the ServerScripts beside them, and those ServerScripts' Fire
##   Clients reaches them, through the BrickscriptDebug autoload: see its
##   relay_told() / relay_server_told()).
## - ServerScript nodes: only where the game runs (the server; offline this
##   machine).
## While the game runs its children aren't in the scene (taken out before
## they're ready), so nothing in it runs by itself.

## Script node metadata (shared with plugin_main.gd and the engine).
const SCRIPT_NODE_META: StringName = &"script_node"
## On a LocalScript copy (shared with flow_library.gd TELL_SERVER_HELPER).
const STARTER_COPY_META: StringName = &"_brickscript_starter_copy"
## On a node the starter copied into (shared with TELL_CLIENTS_HELPER): its
## ServerScripts' Fire Clients goes through the BrickscriptDebug autoload,
## since the LocalScript copies beside them are on one machine only.
const HAS_COPIES_META: StringName = &"_brickscript_has_starter_copies"

## The children, taken out of the scene.
var _template: Array[Node] = []
var _taken: bool = false


func _enter_tree() -> void:
	# (Before the children enter the tree: they never run here.)
	_take()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in _template:
			if is_instance_valid(node):
				node.free()


## Copies the template into `target` (a player node or a character) for
## `player` (its peer): what this machine should have, and only what
## `target` hasn't got (by name). `is_server`: the game runs here. Copies
## outside a player node are in the local_only group (every machine makes
## its own; synced values still come from the server by path).
func copy_into(target: Node, player: int, local_peer: int, is_server: bool) -> Array[Node]:
	_take()
	var made: Array[Node] = []
	if _template.any(func(node: Node) -> bool: return str(node.get_meta(SCRIPT_NODE_META, "")) == "local"):
		target.set_meta(HAS_COPIES_META, true)
	for node: Node in _template:
		var kind: String = str(node.get_meta(SCRIPT_NODE_META, ""))
		if kind == "server" and not is_server or kind == "local" and player != local_peer:
			continue
		if target.has_node(NodePath(String(node.name))):
			continue
		var copy: Node = node.duplicate()
		if kind == "local":
			# Only on its player's machine: its Fire Server goes through the
			# BrickscriptDebug autoload (the server has no copy to call).
			copy.set_meta(STARTER_COPY_META, true)
		if not target is BrickscriptPlayer:
			copy.add_to_group(&"local_only", true)
		target.add_child(copy)
		made.append(copy)
	return made


## The template's children (taken out of the scene).
func template() -> Array[Node]:
	_take()
	return _template


func _take() -> void:
	if _taken or Engine.is_editor_hint():
		return
	_taken = true
	for child: Node in get_children():
		remove_child(child)
		child.owner = null
		_template.append(child)
