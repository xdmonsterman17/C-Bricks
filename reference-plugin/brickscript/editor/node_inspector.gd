@tool
extends EditorInspectorPlugin

## Brickscript's additions to the Inspector of game nodes:
## - a character node (BrickscriptCharacter3D / 2D) doesn't show its Script
##   row (the node is its script, like a built-in node type);
## - a node an Export brick is shown on (Shown on: the node it acts for / a
##   node) shows that export at the top, with Godot's own editor for its
##   type, and the script node doesn't. The value stays on the script node (a
##   plain @export, saved like any other): edits go to it, undoable.

const ShownExports = preload("../core/shown_exports.gd")

## The editor's undo history (set by the plugin).
var undo_redo: EditorUndoRedoManager = null


func _can_handle(object: Object) -> bool:
	return object is Node


func _parse_property(object: Object, _type: Variant.Type, name: String, _hint_type: PropertyHint, _hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	if name == "script":
		return ShownExports.is_character(object)
	# An export shown on another node: there, not here.
	return ShownExports.shown_elsewhere(object).has(name)


func _parse_begin(object: Object) -> void:
	var node: Node = object as Node
	var scene: Node = EditorInterface.get_edited_scene_root() if node != null else null
	if scene == null:
		return
	var shown: Array[Array] = ShownExports.shown_on(node, scene)
	if shown.is_empty():
		return
	for pair: Array in shown:
		var editor: Control = _editor_for(pair[0], pair[1])
		if editor != null:
			add_custom_control(editor)


## Godot's own editor for the export's type, labelled "Speed (LocalScript)".
func _editor_for(holder: Node, name: String) -> Control:
	var info: Dictionary = {}
	for property: Dictionary in holder.get_property_list():
		if property["name"] == name:
			info = property
			break
	if info.is_empty():
		return null
	var editor: EditorProperty = EditorInspector.instantiate_property_editor(holder, info["type"], name, info["hint"], info["hint_string"], info["usage"] | PROPERTY_USAGE_EDITOR)
	if editor == null:
		return null
	editor.label = "%s (%s)" % [name.capitalize(), holder.name]
	editor.tooltip_text = "An Export of %s's brickscript, shown here (Shown on). Its value is kept on %s." % [holder.name, holder.name]
	editor.set_object_and_property(holder, name)
	editor.property_changed.connect(func(property: StringName, value: Variant, _field: StringName, _changing: bool) -> void:
		_set_export(holder, String(property), value)
		editor.update_property())
	editor.update_property()
	# In a box: the Inspector would also apply a custom EditorProperty's
	# changes itself, to the node it shows (which hasn't got this property).
	var box: VBoxContainer = VBoxContainer.new()
	box.add_child(editor)
	return box


func _set_export(holder: Node, name: String, value: Variant) -> void:
	if undo_redo == null:
		holder.set(name, value)
		return
	undo_redo.create_action("Brickscript: set %s" % name, UndoRedo.MERGE_ENDS, holder)
	undo_redo.add_do_property(holder, name, value)
	undo_redo.add_undo_property(holder, name, holder.get(name))
	undo_redo.commit_action()
