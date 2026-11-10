class_name AddDialog
extends ConfirmationDialog
## Godot's "Create New Node" window (user, 2026-11-09): opens in the middle of the screen with
## a search box, a tree of everything that can be added (the classes by what they extend, your
## own classes under their parents, Scripts, copies of other Scenes) with their icons, and a
## description of the picked one. Double-click, Enter in the search box, or Create picks it.
## The same window does Change type... (the Scene tree's right-click: `current` is greyed).

const Context = preload("res://scripts/editor/context.gd")

## What a built-in class is for (the description under the tree).
const DESCRIPTIONS := {
	"Node": "The base of every object: a name, a place in the tree, groups, metadata and scripts. It has no position and draws nothing.",
	"Spatial3D": "An object in the 3D world: position, rotation and scale (relative to its parent Spatial3D). Group other 3D objects under it to move them together.",
	"Shape3D": "A box, sphere, cylinder... drawn in 3D with a size and a colour. Solid ones stop Move and collide; Every frame and touch events work on it.",
	"Mesh3D": "A 3D model loaded from a mesh file (OBJ...), with a colour.",
	"Camera3D": "The view into the 3D world: where it stands (position), what it looks at (target) and its field of view.",
	"Light3D": "A light in the 3D world (a sun): colour and energy.",
	"Spatial2D": "An object in the 2D world: position, rotation and scale (relative to its parent Spatial2D).",
	"Shape2D": "A rectangle, circle... drawn in 2D with a size and a colour.",
	"Sprite2D": "A picture (a texture, or one frame of a sprite sheet) drawn in 2D.",
	"Text2D": "Text drawn in the 2D world, where its position is. (For a HUD use a Label.)",
	"Camera2D": "The view into the 2D world: zoom, centred on its position.",
	"Control": "The base of the UI: placed in the window (or its Control parent) by an anchor and an offset, in pixels. Drawn on top of the 3D and 2D, never sent over the network.",
	"Label": "Text in the UI: size, colour and alignment.",
	"Panel": "A filled box in the UI (a background): colour, border and rounded corners.",
	"Bar": "A progress / health bar in the UI: a value out of a maximum.",
	"Button": "A clickable UI button. When clicked runs for it; a plain script can use When button clicked.",
	"VBox": "Lays its Control children out in a column (separation, padding, fill). A good one to extend.",
	"HBox": "Lays its Control children out in a row (separation, padding, fill). A good one to extend.",
	"Image": "A picture in the UI: a texture and a tint.",
	"Environment": "The world's sky, ambient light and fog. One per world.",
	"Script": "A script file run for the object it's under, on the Server (it's the rules in a network game).",
	"LocalScript": "A script file run for the object it's under, on each player's Client (input, UI, camera).",
	"ModuleScript": "A script file of functions shared by Server and Client: other scripts call it.",
}

var context: Context = null
var dock: Node = null  # the Scene dock: scene_block(rel) says why a scene can't be placed

var _search: LineEdit = null
var _tree: Tree = null
var _desc: RichTextLabel = null
var _on_pick := Callable()
var _mode := "add"
var _current := ""  # Change type: the object's present class (greyed)


func _init() -> void:
	min_size = Vector2i(560, 520)
	exclusive = true
	ok_button_text = "Create"
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	add_child(box)
	_search = LineEdit.new()
	_search.placeholder_text = "Search"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _fill())
	_search.text_submitted.connect(func(_t: String) -> void: _create())
	box.add_child(_search)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_SINGLE
	_tree.item_selected.connect(_on_selected)
	_tree.item_activated.connect(_create)
	box.add_child(_tree)
	var dl := Label.new()
	dl.text = "Description:"
	box.add_child(dl)
	_desc = RichTextLabel.new()
	_desc.custom_minimum_size = Vector2(0, 96)
	_desc.bbcode_enabled = true
	_desc.fit_content = false
	box.add_child(_desc)
	confirmed.connect(_create)
	# Typing anywhere goes to the search box (Godot's): arrows still move in the tree.
	_search.gui_input.connect(func(e: InputEvent) -> void:
		var k := e as InputEventKey
		if k != null and k.pressed and (k.keycode == KEY_DOWN or k.keycode == KEY_UP):
			_tree.grab_focus()
			_tree.gui_input.emit(e))


## Opens the window in the middle of the screen. mode "add": the objects to add; "change":
## a new type for `current`'s object. on_pick gets the key: a class name, a Script type or
## "scene:<rel>".
func open(mode: String, current: String, on_pick: Callable) -> void:
	_mode = mode
	_current = current
	_on_pick = on_pick
	title = "Change Type of Node" if mode == "change" else "Create New Node"
	ok_button_text = "Change" if mode == "change" else "Create"
	_search.text = ""
	_fill()
	popup_centered(Vector2i(640, 620))
	_search.call_deferred("grab_focus")


func _fill() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var q := _search.text.strip_edges().to_lower()
	var script_change := _mode == "change" and CBTypes.SCRIPT_TYPES.has(_current)
	if script_change:
		for s: String in CBTypes.SCRIPT_TYPES:
			_leaf(root, s, s, q, "%s  (%s)" % [s, CBTypes.SCRIPT_TYPES[s]])
	else:
		_class_branch(root, CBTypes.OBJECT, q)
		if _mode == "add":
			var scripts := _section(root, "Scripts", "script")
			for s: String in CBTypes.SCRIPT_TYPES:
				_leaf(scripts, s, s, q, "%s  (%s)" % [s, CBTypes.SCRIPT_TYPES[s]])
			if context != null and context.project_dir != "":
				var scenes := _section(root, "Scenes (a copy)", "scene")
				for p in CBProject.list_scenes(context.project_dir):
					if p != context.scene_path:
						var rel := CBProject.rel_path(context.project_dir, p)
						_leaf(scenes, "scene:" + rel, rel, q, rel)
				_drop_if_empty(scenes)
			_drop_if_empty(scripts)
	# Pick: the first thing that can be created.
	var first := _first_pickable(root, q)
	if first != null:
		first.select(0)
		_on_selected()  # (select() doesn't always emit)
		if q == "":
			_tree.scroll_to_item(first)
	else:
		_on_selected()


func _drop_if_empty(it: TreeItem) -> void:
	if it.get_child_count() == 0:
		it.get_parent().remove_child(it)
		it.free()


func _section(parent: TreeItem, text: String, icon: String) -> TreeItem:
	var it := _tree.create_item(parent)
	it.set_text(0, text)
	it.set_icon(0, context.brick_theme.icon(icon))
	it.set_selectable(0, false)
	it.set_custom_color(0, Color(context.brick_theme.text_color(), 0.7))
	it.set_metadata(0, "")
	it.set_icon_max_width(0, 20)
	return it


func _first_pickable(it: TreeItem, q: String) -> TreeItem:
	var c := it.get_first_child()
	while c != null:
		if c.get_metadata(0) is String and str(c.get_metadata(0)) != "" and c.is_selectable(0) and (q == "" or c.get_text(0).to_lower().contains(q)):
			return c
		var d := _first_pickable(c, q)
		if d != null:
			return d
		c = c.get_next()
	return null


## One class and everything extending it, as a branch; with a search, only the matches and
## the branches that lead to them (opened).
func _class_branch(parent: TreeItem, cls: String, q: String) -> void:
	var it := _tree.create_item(parent)
	_style_class(it, cls)
	for k in _children_of(cls):
		_class_branch(it, k, q)
	var matches := q == "" or cls.to_lower().contains(q)
	if not matches and it.get_child_count() == 0:
		parent.remove_child(it)
		it.free()
	elif not matches:  # only a way to a match: its own name isn't one
		it.set_custom_color(0, Color(context.brick_theme.text_color(), 0.55))


func _children_of(cls: String) -> Array:
	var out := []
	var mine := []
	for c: String in CBTypes.BUILTIN:
		if str(CBTypes.BUILTIN[c].get("extends", CBTypes.OBJECT)) == cls:
			out.append(c)
	for c: String in CBTypes.classes:
		if not CBTypes.is_builtin(c) and c != CBTypes.OBJECT and str(CBTypes.classes[c].get("extends", CBTypes.OBJECT)) == cls:
			mine.append(c)
	mine.sort()
	return out + mine


func _style_class(it: TreeItem, cls: String) -> void:
	it.set_text(0, cls)
	it.set_icon(0, context.brick_theme.icon(WorldDock.node_icon(cls)))
	it.set_metadata(0, cls)
	it.set_icon_max_width(0, 20)
	var yours := not CBTypes.is_builtin(cls) and cls != CBTypes.OBJECT
	if yours:
		it.set_custom_color(0, Color(0.55, 0.85, 0.6))
		it.set_tooltip_text(0, "Your class (extends %s)" % str(CBTypes.classes.get(cls, {}).get("extends", CBTypes.OBJECT)))
	if _mode == "change" and cls == _current:
		it.set_selectable(0, false)
		it.set_custom_color(0, Color(context.brick_theme.text_color(), 0.4))
		it.set_tooltip_text(0, "It is this already.")


func _leaf(parent: TreeItem, key: String, name: String, q: String, text: String) -> void:
	if q != "" and not text.to_lower().contains(q):
		return
	var it := _tree.create_item(parent)
	it.set_text(0, text)
	it.set_metadata(0, key)
	if key.begins_with("scene:"):
		it.set_icon(0, context.brick_theme.icon("scene"))
		var why: String = dock.call("scene_block", key.trim_prefix("scene:")) if dock != null else ""
		if why != "":
			it.set_selectable(0, false)
			it.set_custom_color(0, Color(context.brick_theme.text_color(), 0.4))
			it.set_tooltip_text(0, why)
	else:
		it.set_icon(0, context.brick_theme.icon("script"))
		it.set_custom_color(0, WorldDock.script_color(key))
		if _mode == "change" and key == _current:
			it.set_selectable(0, false)
			it.set_custom_color(0, Color(context.brick_theme.text_color(), 0.4))
	it.set_icon_max_width(0, 20)


func _on_selected() -> void:
	var it := _tree.get_selected()
	var key := str(it.get_metadata(0)) if it != null else ""
	get_ok_button().disabled = key == ""
	_desc.clear()
	if key == "":
		return
	_desc.append_text(describe(key))


## The description of a class / script type / scene (BBCode).
func describe(key: String) -> String:
	if key.begins_with("scene:"):
		return "A copy of [b]%s[/b] placed here: its root's fields, groups and metadata can be changed on the copy; edit the scene itself to change what's inside." % key.trim_prefix("scene:")
	var text: String = DESCRIPTIONS.get(key, "")
	if CBTypes.SCRIPT_TYPES.has(key):
		return "[b]%s[/b] (runs on the %s)\n%s" % [key, CBTypes.SCRIPT_TYPES[key], text]
	var ext := str(CBTypes.classes.get(key, CBTypes.BUILTIN.get(key, {})).get("extends", ""))
	var head := "[b]%s[/b]" % key + (" extends %s" % ext if ext != "" else "")
	if text == "" and not CBTypes.is_builtin(key) and key != CBTypes.OBJECT:
		text = "One of your classes."
	var fields := CBTypes.all_fields(key).map(func(f): return str(f[0]))
	return "%s\n%s%s" % [head, text, ("\n[color=gray]Fields: %s[/color]" % ", ".join(fields)) if not fields.is_empty() else ""]


func _create() -> void:
	var it := _tree.get_selected()
	if it == null or str(it.get_metadata(0)) == "" or not it.is_selectable(0):
		return
	var key := str(it.get_metadata(0))
	hide()
	if _on_pick.is_valid():
		_on_pick.call(key)
