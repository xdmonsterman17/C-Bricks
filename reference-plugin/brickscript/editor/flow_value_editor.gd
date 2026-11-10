@tool
extends RefCounted

## Editors for a typed-in value of each Brickscript type: a number box, text
## box, checkbox, x / y (/ z) boxes, color picker or node path. Shared by the
## Properties panel and the Variables list. Edits are committed (Enter, focus
## leaving, picker closed) through `on_commit(value)`.

const Types = preload("../core/flow_types.gd")
const NodeTypes = preload("../core/node_types.gd")
const T = Types.ValueType

const AXES: PackedStringArray = ["x", "y", "z"]


## `resource_class`: for a Resource, the class that fits (its file dropdown
## lists only those files; "" for any).
static func build(type: int, value: Variant, on_commit: Callable, resource_class: StringName = &"") -> Control:
	match type:
		T.RESOURCE:
			return _file_picker(str(value) if value != null else "", resource_class, on_commit)
		T.NUMBER, T.WHOLE:
			return _number_box(type, value, on_commit)
		T.BOOL:
			var check: CheckBox = CheckBox.new()
			check.text = "true" if value else "false"
			check.button_pressed = value == true
			check.toggled.connect(func(on: bool) -> void:
				check.text = "true" if on else "false"
				on_commit.call(on))
			return check
		T.VECTOR2, T.VECTOR3:
			return _vector_boxes(type, value, on_commit)
		T.COLOR:
			var picker: ColorPickerButton = ColorPickerButton.new()
			picker.color = value if value is Color else Color(0, 0, 0)
			picker.custom_minimum_size = Vector2(48, 24)
			picker.popup_closed.connect(func() -> void: on_commit.call(picker.color))
			return picker
		T.LIST:
			return _list_items_picker(value, on_commit)
		T.TABLE:
			return _table_types_picker(value, on_commit)
	var edit: LineEdit = LineEdit.new()
	edit.text = str(value) if value != null else ""
	edit.placeholder_text = "node path: .. parent, . this node, or e.g. Sprite2D" if type == T.NODE else "text"
	_on_commit(edit, func() -> void: on_commit.call(edit.text))
	return edit


## An empty List's "of" dropdown: what its items are (Anything, Number...),
## committed as an empty typed Array.
static func _list_items_picker(value: Variant, on_commit: Callable) -> HBoxContainer:
	var box: HBoxContainer = HBoxContainer.new()
	var note: Label = Label.new()
	note.text = "empty, of"
	note.modulate.a = 0.7
	box.add_child(note)
	var picker: OptionButton = OptionButton.new()
	picker.tooltip_text = "What the List holds. Bricks that add to it must give that type; items read from it have it."
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item: int in [T.ANY] + Types.ORDER:
		picker.add_item(Types.type_name(item), item)
	picker.select(maxi(0, picker.get_item_index(NodeTypes.list_item(NodeTypes.list_info_of_value(value)))))
	picker.item_selected.connect(func(index: int) -> void: on_commit.call(NodeTypes.empty_list(picker.get_item_id(index))))
	box.add_child(picker)
	return box


## An empty Table's "of ... -> ..." dropdowns: what its keys and values are,
## committed as an empty typed Dictionary.
static func _table_types_picker(value: Variant, on_commit: Callable) -> HBoxContainer:
	var box: HBoxContainer = HBoxContainer.new()
	var info: Dictionary = NodeTypes.table_info_of_value(value)
	var pickers: Array[OptionButton] = []
	for side: int in 2:
		var note: Label = Label.new()
		note.text = "empty, of" if side == 0 else "->"
		note.modulate.a = 0.7
		box.add_child(note)
		var picker: OptionButton = OptionButton.new()
		picker.name = "Keys" if side == 0 else "Values"
		picker.tooltip_text = "What the Table's %s are. Bricks that set them must give that type; %s read from it have it." % (["keys", "keys"] if side == 0 else ["values", "values"])
		picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for item: int in [T.ANY] + Types.ORDER:
			picker.add_item(Types.type_name(item), item)
		var current: Dictionary = NodeTypes.table_keys(info) if side == 0 else NodeTypes.table_values(info)
		picker.select(maxi(0, picker.get_item_index(NodeTypes.list_item(current))))
		pickers.append(picker)
		box.add_child(picker)
	for picker: OptionButton in pickers:
		picker.item_selected.connect(func(_index: int) -> void:
			on_commit.call(NodeTypes.empty_table(pickers[0].get_selected_id(), pickers[1].get_selected_id())))
	return box


## A res:// path box with a dropdown of the project's files that fit.
static func _file_picker(current: String, resource_class: StringName, on_commit: Callable) -> HBoxContainer:
	var box: HBoxContainer = HBoxContainer.new()
	box.add_theme_constant_override(&"separation", 0)
	var edit: LineEdit = LineEdit.new()
	edit.text = current
	edit.placeholder_text = "pick a %s file" % (String(resource_class) if not String(resource_class).is_empty() else "resource")
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_on_commit(edit, func() -> void: on_commit.call(edit.text.strip_edges()))
	box.add_child(edit)
	var menu: MenuButton = MenuButton.new()
	menu.flat = true
	menu.text = "..."
	var files: PackedStringArray = NodeTypes.resource_files(resource_class)
	menu.tooltip_text = "Pick one of the project's files" if not files.is_empty() else "No fitting files in the project yet"
	menu.disabled = files.is_empty()
	for file: String in files:
		menu.get_popup().add_item(file.trim_prefix("res://"))
	menu.get_popup().index_pressed.connect(func(index: int) -> void:
		edit.text = files[index]
		on_commit.call(files[index]))
	box.add_child(menu)
	return box


## Number box: keeps the old value if what was typed isn't a number; whole
## numbers are shown and kept without decimals.
static func _number_box(type: int, value: Variant, on_commit: Callable) -> LineEdit:
	var edit: LineEdit = LineEdit.new()
	edit.text = number_text(value, type)
	edit.placeholder_text = "0"
	# Lambdas capture locals by value: keep the last good value in an Array.
	var last: Array = [value]
	_on_commit(edit, func() -> void:
		var typed: String = edit.text.strip_edges()
		if not typed.is_valid_float():
			edit.text = number_text(last[0], type)
			return
		var number: float = typed.to_float()
		if type == T.WHOLE:
			number = roundf(number)
			edit.text = number_text(number, type)
		last[0] = number
		on_commit.call(int(number) if type == T.WHOLE else number))
	return edit


static func _vector_boxes(type: int, value: Variant, on_commit: Callable) -> HBoxContainer:
	var count: int = 2 if type == T.VECTOR2 else 3
	# Lambdas capture locals by value: keep the current vector in an Array.
	var current: Array = [value if Types.of_value(value) == type else Types.default_value(type)]
	var box: HBoxContainer = HBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	var edits: Array[LineEdit] = []
	for i: int in count:
		var edit: LineEdit = LineEdit.new()
		edit.text = number_text(current[0][i], T.NUMBER)
		edit.placeholder_text = AXES[i]
		edit.tooltip_text = AXES[i]
		edit.custom_minimum_size.x = 44
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edits.append(edit)
		box.add_child(edit)
	for edit: LineEdit in edits:
		_on_commit(edit, func() -> void:
			var result: Variant = Vector2.ZERO if count == 2 else Vector3.ZERO
			for i: int in count:
				var typed: String = edits[i].text.strip_edges()
				result[i] = typed.to_float() if typed.is_valid_float() else current[0][i]
				edits[i].text = number_text(result[i], T.NUMBER)
			current[0] = result
			on_commit.call(result))
	return box


static func number_text(value: Variant, type: int) -> String:
	if not (value is float or value is int):
		return "0"
	if type == T.WHOLE or (float(value) == floorf(float(value)) and absf(float(value)) < 1e15):
		return str(int(value))
	return str(value)


static func _on_commit(edit: LineEdit, commit: Callable) -> void:
	edit.text_submitted.connect(func(_typed: String) -> void: commit.call())
	edit.focus_exited.connect(commit)
