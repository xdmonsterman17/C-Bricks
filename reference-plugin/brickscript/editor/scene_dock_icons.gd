@tool
extends Node

## Takes the script button off some nodes' rows in the Scene dock (and the
## other scene trees the editor shows: Select Node, Reparent...): nodes whose
## script is one of a plugin's own engine-like node scripts (a Character3D,
## the PlayerService, a Terrain), so they look like Godot's own nodes. User,
## 2026-11-03 (DECISIONS.md). Godot has no API for it, so, like the
## FileSystem tint (file_tint.gd), it finds the dock's Tree and removes the
## button whenever the tree redraws (it is rebuilt often). If a Godot version
## lays the dock out differently, the icon simply stays.
##
## The Brickscript, Terrain Engine and Cull Throttle Engine plugins each
## carry their own copy of this file, so none needs another.

## SceneTreeEditor's id for a row's script button (scene_tree_editor.h
## BUTTON_SCRIPT); its tooltip names the script's path (a @tool script's adds
## a line after it), which is checked too, so another button with this id is
## never taken.
const SCRIPT_BUTTON: int = 2

## func(script_path: String) -> bool: whether a node running that script
## loses its script button.
var matches: Callable = Callable()

var _watched: Array[Tree] = []
var _pending: bool = false


func _ready() -> void:
	_find_trees()
	# Dialogs with a scene tree (Select Node, Reparent) are made when first
	# opened: look again when a window shows up.
	get_tree().node_added.connect(_on_node_added)
	_queue()


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	for tree: Tree in _watched:
		if is_instance_valid(tree) and tree.draw.is_connected(_queue):
			tree.draw.disconnect(_queue)
	_watched.clear()
	# The editor puts the buttons back itself on its next rebuild.
	var dock: Node = EditorInterface.get_base_control()
	for tree: Node in dock.find_children("*", "Tree", true, false):
		(tree as Tree).queue_redraw()


## The scene trees: Trees whose rows name nodes (a NodePath as metadata).
func _find_trees() -> void:
	for found: Node in EditorInterface.get_base_control().find_children("*", "Tree", true, false):
		_watch(found as Tree)


func _watch(tree: Tree) -> void:
	if tree == null or _watched.has(tree):
		return
	_watched.append(tree)
	tree.draw.connect(_queue)


func _on_node_added(node: Node) -> void:
	if node is Tree and EditorInterface.get_base_control().is_ancestor_of(node):
		_watch.call_deferred(node)


## After the redraw (removing a button redraws once more, which then finds
## nothing left to remove).
func _queue() -> void:
	if not _pending:
		_pending = true
		_strip.call_deferred()


func _strip() -> void:
	_pending = false
	if not matches.is_valid():
		return
	for tree: Tree in _watched:
		if is_instance_valid(tree) and tree.is_visible_in_tree() and tree.get_root() != null:
			_strip_item(tree.get_root())


func _strip_item(item: TreeItem) -> void:
	while item != null:
		var path: Variant = item.get_metadata(0)
		var index: int = item.get_button_by_id(0, SCRIPT_BUTTON)
		if path is NodePath and index >= 0:
			var node: Node = get_tree().root.get_node_or_null(path)
			var script: Script = node.get_script() as Script if node != null else null
			if script != null and item.get_button_tooltip_text(0, index).contains(script.resource_path) and matches.call(script.resource_path):
				item.erase_button(0, index)
		if item.get_first_child() != null:
			_strip_item(item.get_first_child())
		item = item.get_next()
