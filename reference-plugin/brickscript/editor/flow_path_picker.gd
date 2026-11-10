@tool
extends RefCounted

## A node path field: a text box (paths shown Roblox style: Self is the
## node the brickscript is, Self.Parent its parent, Self.Parent.UI.Score;
## Godot's ../UI/Score can be typed too, and is what's stored: Types
## path_shown / path_typed), a dropdown of every path found in the scenes
## (with its type), and a step-by-step picker: a tree starting at Self and
## its parent, where each step lists the children there, so a path is built
## by walking to the node instead of counting Parents.
## `guess` is NodeTypes.guess_from_scenes() for the brickscript. Commits
## through on_commit(path: String, node_type: Dictionary) (node_type {} when
## the scenes don't say).

const NodeTypes = preload("../core/node_types.gd")
const Types = preload("../core/flow_types.gd")

const PICKER_SIZE: Vector2i = Vector2i(380, 360)


## `wanted_script`: only nodes running that script (or one extending it) in
## the dropdown (a Terrain input's: the scenes' Terrains, 2026-11-02).
static func build(current: String, guess: Dictionary, placeholder: String, on_commit: Callable, theme: Variant = null, wanted_script: String = "") -> HBoxContainer:
	var types: Dictionary = guess.get("types", {})
	var box: HBoxContainer = HBoxContainer.new()
	box.add_theme_constant_override(&"separation", 0)
	var edit: LineEdit = LineEdit.new()
	edit.name = "Path"
	edit.text = Types.path_shown(current)
	edit.placeholder_text = placeholder
	edit.tooltip_text = "Self: the node this brickscript is (a LocalScript / ServerScript node itself)\nSelf.Parent: its parent (the node a script node works for)\nSelf.Parent.UI.Score: a child of the parent, and so on\n(Godot paths like ../UI/Score work too)"
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var commit: Callable = func(path: String) -> void:
		edit.text = Types.path_shown(path)
		on_commit.call(path, types.get(path, {}))
	edit.text_submitted.connect(func(text: String) -> void: commit.call(Types.path_typed(text)))
	edit.focus_exited.connect(func() -> void:
		if Types.path_typed(edit.text) != current.strip_edges():
			commit.call(Types.path_typed(edit.text)))
	box.add_child(edit)

	var paths: PackedStringArray = PackedStringArray(Array(guess.get("paths", PackedStringArray())).filter(func(path: String) -> bool: return path != "."))
	if not wanted_script.is_empty():
		paths = PackedStringArray(Array(paths).filter(func(path: String) -> bool: return runs_script(types.get(path, {}), wanted_script)))
	var menu: MenuButton = MenuButton.new()
	menu.name = "Dropdown"
	menu.flat = true
	menu.tooltip_text = "Pick a node found in your scenes" if wanted_script.is_empty() else "Pick a %s found in your scenes" % wanted_script.get_file().get_basename().capitalize()
	menu.icon = _icon(theme, &"GuiDropdown")
	if menu.icon == null:
		menu.text = "v"
	menu.disabled = paths.is_empty()
	for path: String in paths:
		menu.get_popup().add_item("%s · %s" % [Types.path_shown(path), NodeTypes.describe(types[path])])
	menu.get_popup().index_pressed.connect(func(index: int) -> void: commit.call(paths[index]))
	box.add_child(menu)

	var step: Button = Button.new()
	step.name = "StepByStep"
	step.flat = true
	step.tooltip_text = "Walk to the node: from Self or its parent, step by step"
	step.icon = _icon(theme, &"Tree")
	if step.icon == null:
		step.text = "..."
	step.disabled = paths.is_empty()
	var popup: PopupPanel = make_tree_popup(guess, func(path: String) -> void: commit.call(path))
	popup.name = "StepPopup"
	box.add_child(popup)
	step.pressed.connect(func() -> void:
		popup.popup(Rect2i(Vector2i(step.get_screen_position()) + Vector2i(0, int(step.size.y)), PICKER_SIZE)))
	box.add_child(step)
	return box


## Whether a node of this type runs `script_path` (or a script extending it).
static func runs_script(node_type: Dictionary, script_path: String) -> bool:
	var found: String = str(node_type.get("script", ""))
	if found.is_empty() or not ResourceLoader.exists(found):
		return false
	var script: Script = load(found) as Script
	while script != null:
		if script.resource_path == script_path:
			return true
		script = script.get_base_script()
	return false


## The step-by-step tree in a popup: Self with its children, and
## Self.Parent with its children (siblings) and its own parent, and so on.
## Double-click a node (or select it and press Use this node) to pick it.
static func make_tree_popup(guess: Dictionary, on_pick: Callable) -> PopupPanel:
	var popup: PopupPanel = PopupPanel.new()
	var column: VBoxContainer = VBoxContainer.new()
	popup.add_child(column)
	var tree: Tree = Tree.new()
	tree.name = "Tree"
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.custom_minimum_size = Vector2(PICKER_SIZE) - Vector2(16, 48)
	column.add_child(tree)
	fill_tree(tree, guess)
	var use: Button = Button.new()
	use.name = "Use"
	use.text = "Use this node"
	use.disabled = true
	column.add_child(use)
	var pick: Callable = func() -> void:
		var item: TreeItem = tree.get_selected()
		if item != null:
			popup.hide()
			on_pick.call(str(item.get_metadata(0)))
	tree.item_selected.connect(func() -> void: use.disabled = tree.get_selected() == null)
	tree.item_activated.connect(pick)
	use.pressed.connect(pick)
	return popup


## Fills `tree` with the found paths, nested by steps. Each item's metadata
## is its path.
static func fill_tree(tree: Tree, guess: Dictionary) -> void:
	tree.clear()
	var root: TreeItem = tree.create_item()
	var types: Dictionary = guess.get("types", {})
	var names: Dictionary = guess.get("names", {})
	var items: Dictionary = {}
	var all: PackedStringArray = PackedStringArray(guess.get("paths", PackedStringArray()))
	if not all.has("."):
		all.insert(0, ".")
	# Shortest first, so each step's item exists before its children.
	var ordered: Array = Array(all)
	ordered.sort_custom(func(a: String, b: String) -> bool: return _steps(a) < _steps(b) or (_steps(a) == _steps(b) and a < b))
	for path: String in ordered:
		var parent_path: String = _step_up(path)
		var parent_item: TreeItem = root if parent_path.is_empty() else items.get(parent_path, null)
		if parent_item == null:
			continue
		var item: TreeItem = tree.create_item(parent_item)
		item.set_text(0, _label(path, names.get(path, ""), types.get(path, {})))
		item.set_tooltip_text(0, Types.path_shown(path))
		item.set_metadata(0, path)
		# Open the way up (Self, the parents); a node's own children
		# stay folded until stepped into.
		item.collapsed = not (path == "." or path.replace("..", "").replace("/", "").is_empty())
		items[path] = item


## Where a path's item goes: "." and ".." at the top; a child under its
## parent's path; ".." steps under the node one step down.
static func _step_up(path: String) -> String:
	if path == "." or path == "..":
		return ""
	var parts: PackedStringArray = path.split("/")
	if parts.size() == 1:
		return "."
	parts.remove_at(parts.size() - 1)
	return "/".join(parts)


static func _steps(path: String) -> int:
	return 0 if path == "." else path.split("/").size()


static func _label(path: String, name: String, node_type: Dictionary) -> String:
	var kind: String = NodeTypes.describe(node_type) if not node_type.is_empty() else "?"
	if path == ".":
		return "Self · %s" % kind
	if path.get_file() == "..":
		return "%s%s · %s" % [Types.path_shown(path), " (%s)" % name if not name.is_empty() else "", kind]
	return "%s · %s" % [path.get_file(), kind]


static func _icon(theme: Variant, icon_name: StringName) -> Texture2D:
	if theme != null and theme.has_method(&"icon"):
		return theme.call(&"icon", icon_name)
	return null
