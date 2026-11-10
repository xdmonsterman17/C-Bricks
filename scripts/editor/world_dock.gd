class_name WorldDock
extends VBoxContainer
## The Scene dock (Godot's Scene dock, Roblox's Explorer): the open scenes as tabs
## (the Main scene first), the edited scene's objects as a tree; copies of other
## scenes show their objects greyed under them (edited in their own scene).
## Add puts an object of a class, a Script object or a copy of another scene under
## the selected one (or the top); right-click: Save branch as scene. Selecting
## one shows its name, parent and fields in Properties (inspector.gd
## _show_world_object). Every change is written to the file at once
## (context.on_world_changed).

const Context = preload("res://scripts/editor/context.gd")
const BrickTheme = preload("res://scripts/editor/brick_theme.gd")

signal scene_picked(path: String)
signal scene_closed(path: String)

var context: Context = null
var _scene_tabs: TabBar = null
var _scene_list: Array = []
var _menu: PopupMenu = null
var _tree: Tree = null
var _add: Button = null
var _add_dialog: AddDialog = null
var _delete: Button = null
var _new_scene: Button = null
var _syncing := false  # selecting the tree's item for another view's pick


func _init() -> void:
	add_theme_constant_override(&"separation", 4)
	_scene_tabs = TabBar.new()
	_scene_tabs.clip_tabs = true
	_scene_tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ACTIVE_ONLY
	_scene_tabs.tab_changed.connect(func(i: int) -> void:
		if i >= 0 and i < _scene_list.size() and _scene_list[i] != context.scene_path:
			scene_picked.emit(_scene_list[i]))
	_scene_tabs.tab_close_pressed.connect(func(i: int) -> void:
		if i >= 0 and i < _scene_list.size():
			scene_closed.emit(_scene_list[i]))
	add_child(_scene_tabs)
	var bar := HBoxContainer.new()
	add_child(bar)
	_add = Button.new()
	_add.text = "Add"
	_add.tooltip_text = "Add an object under the selected object (or the world): opens Godot's Create New Node window"
	_add.pressed.connect(open_add)
	bar.add_child(_add)
	_delete = Button.new()
	_delete.text = "Delete"
	_delete.tooltip_text = "Delete the selected object and the objects under it"
	_delete.pressed.connect(_delete_selected)
	bar.add_child(_delete)
	_new_scene = Button.new()
	_new_scene.text = "New scene"
	_new_scene.tooltip_text = "Make a new scene (.cbscene) and open it in a tab here"
	_new_scene.pressed.connect(func() -> void:
		if context.on_new_scene.is_valid():
			context.on_new_scene.call())
	bar.add_child(_new_scene)
	_tree = Tree.new()
	_tree.size_flags_vertical = SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_selected)
	_tree.item_activated.connect(func() -> void:  # double-click: a Script object's graph, a copy's scene
		var o := find(int(_tree.get_selected().get_metadata(0))) if _tree.get_selected() != null else {}
		if CBTypes.is_script_object(o) and context.on_open_script.is_valid():
			context.on_open_script.call(str(o.get("script", "")))
		elif o.has("scene") and context.on_open_scene.is_valid():
			context.on_open_scene.call(str(o.scene)))
	_tree.allow_rmb_select = true
	_tree.item_mouse_selected.connect(func(at: Vector2, button: int) -> void:
		if button == MOUSE_BUTTON_RIGHT:
			_open_menu(at))
	# Drag a row onto another to put it under that one (user, 2026-11-07: no Parent dropdown).
	_tree.set_drag_forwarding(_drag_row, _can_drop_row, _drop_row)
	add_child(_tree)
	_tree.tooltip_text = "The scene's objects (the Main scene: what the world starts with). Bricks find them by name: Object (Find)."
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)


func _ready() -> void:
	_add.icon = context.brick_theme.icon("add")
	_delete.icon = context.brick_theme.icon("remove")
	_new_scene.icon = context.brick_theme.icon("scene")
	# A pick in the 2D / 3D screen (or here) selects the object's row: deferred, and
	# without rebuilding, since this can run inside the Tree's own item_selected
	# (clearing a Tree there fails: it crashed the exported app).
	context.selection_changed.connect(func(_id: int) -> void: _sync_selection.call_deferred())
	rebuild()


## Opens the Create New Node window (Add).
func open_add() -> void:
	_dialog().open("add", "", func(key: String) -> void: _add_object(key))


func _dialog() -> AddDialog:
	if _add_dialog == null:
		_add_dialog = AddDialog.new()
		_add_dialog.context = context
		_add_dialog.dock = self
		add_child(_add_dialog)
	return _add_dialog


## Why a scene can't be placed in the edited one ("" it can).
func scene_block(rel: String) -> String:
	var here := CBProject.rel_path(context.project_dir, context.scene_path)
	var roots := _roots_of(rel)
	if contains_scene(rel, here):
		return "%s holds this scene: a copy of it here would hold itself." % rel
	if roots != 1:
		return "%s has %d objects at the top: a scene placed in another needs one (put them under one node)." % [rel, roots]
	return ""


## The tree from context.world (keeps the selected object selected).
func rebuild() -> void:
	if _tree == null or context == null:
		return
	_tree.clear()
	var root := _tree.create_item()
	var is_main := context.scene_path == CBProject.world_path(context.project_dir) if context.project_dir != "" else true
	var objects: Array = context.world.get("objects", [])
	var left := objects.duplicate()
	var items := {0: root}
	var tops := objects.filter(func(x): return int(x.parent) == 0)
	if tops.is_empty():
		root.set_text(0, "(empty: Add a node, it's the root)")
		root.set_custom_color(0, Color(1, 1, 1, 0.45))
		root.set_icon(0, context.brick_theme.icon("scene"))
		root.set_tooltip_text(0, "The first node added is this scene's root" + (" (the Main scene's root is the world while the program runs)" if is_main else "") + ".")
		root.set_metadata(0, 0)
	elif tops.size() == 1 and not CBTypes.is_script_object(tops[0]):
		# The scene's root (Godot's): in the Main scene, the world while the program runs.
		var r: Dictionary = tops[0]
		root.set_text(0, "%s  (%s)" % [str(r.name), str(r.get("class", str(r.get("scene", "")).get_file()))])
		root.set_icon(0, context.brick_theme.icon("scene" if r.has("scene") else node_icon(str(r.get("class", "")))))
		root.set_tooltip_text(0, ("The Main scene's root: the world while the program runs (New object puts objects under it)." if is_main else "This scene's root (%s): a copy of the scene in another one is this node." % context.scene_path.get_file()) + " Click it to rename it; right-click: Change type.")
		root.set_metadata(0, int(r.id))
		root.set_icon_max_width(0, 20)
		items[int(r.id)] = root
		left.erase(r)
		if r.has("scene"):
			_inner_rows(root, int(r.id))
		if int(r.id) == int(context.world_object.get("id", -1)):
			root.select(0)
	else:
		root.set_text(0, context.scene_path.get_file())
		root.set_icon(0, context.brick_theme.icon("scene"))
		root.set_tooltip_text(0, "This scene: it needs one object at the top (its root) to be placed in another scene")
		root.set_metadata(0, 0)
	var progress := true
	while progress and not left.is_empty():
		progress = false
		for o in left.duplicate():
			var pid := int(o.parent)
			if items.has(pid) or not objects.any(func(x): return int(x.id) == pid):
				var it := _tree.create_item(items.get(pid, root))
				if o.has("scene"):
					# A copy of another scene: its objects greyed under it (edited in that scene).
					it.set_text(0, "%s  (%s)" % [str(o.name), str(o.scene).get_file()])
					it.set_icon(0, context.brick_theme.icon("scene"))
					it.set_tooltip_text(0, "A copy of %s: its root's fields, groups and metadata can change here; double-click to edit the scene." % str(o.scene))
					_inner_rows(it, int(o.id))
				else:
					it.set_text(0, "%s  (%s)" % [str(o.name), str(o["class"])])
					it.set_icon(0, context.brick_theme.icon(node_icon(str(o["class"]))))
				if CBTypes.is_script_object(o):
					it.set_custom_color(0, script_color(str(o["class"])))
					it.set_tooltip_text(0, "%s: runs %s for the object it's under (double-click: open it)" % [str(o.get("script", "")), str(o["class"])])
				it.set_icon_max_width(0, 20)
				it.set_metadata(0, int(o.id))
				items[int(o.id)] = it
				if int(o.id) == int(context.world_object.get("id", -1)):
					it.select(0)
				left.erase(o)
				progress = true
	_delete.disabled = context.world_object.is_empty()


## A copy's own objects (from context.world_flat), greyed and not selectable.
func _inner_rows(under: TreeItem, copy_id: int) -> void:
	var items := {copy_id: under}
	var inner: Array = context.world_flat.get("objects", []).filter(func(x): return int(x.get("owner", 0)) == copy_id)
	var progress := true
	while progress and not inner.is_empty():
		progress = false
		for x in inner.duplicate():
			if items.has(int(x.parent)):
				var it := _tree.create_item(items[int(x.parent)])
				it.set_text(0, "%s  (%s)" % [str(x.name), str(x.get("class", ""))])
				it.set_icon(0, context.brick_theme.icon("scene" if x.has("scene") else node_icon(str(x.get("class", "")))))
				it.set_icon_max_width(0, 20)
				it.set_custom_color(0, Color(context.brick_theme.text_color(), 0.45))
				it.set_selectable(0, false)
				it.set_metadata(0, -1)
				items[int(x.id)] = it
				inner.erase(x)
				progress = true
	under.collapsed = true


func _on_selected() -> void:
	if _syncing:
		return
	var it := _tree.get_selected()
	var id: int = it.get_metadata(0) if it != null else 0
	var o := find(id)
	context.show_world_object(o)
	_delete.disabled = o.is_empty()


func find(id: int) -> Dictionary:
	for o in context.world.get("objects", []):
		if int(o.id) == id:
			return o
	return {}


## A node's icon by its class (user, 2026-11-07: fixed icons, not renders; Godot's colours,
## 3D red, 2D blue): its nearest built-in class's (a Gem extending Shape3D: the cube).
static func node_icon(cls: String) -> String:
	if CBTypes.SCRIPT_TYPES.has(cls):
		return "script"
	for c in CBTypes.lineage(cls):
		var k: String = {"Shape3D": "shape3d", "Mesh3D": "mesh3d", "Camera3D": "camera3d", "Light3D": "light3d", "Spatial3D": "spatial3d",
				"Shape2D": "shape2d", "Sprite2D": "sprite2d", "Text2D": "text2d", "Camera2D": "camera2d", "Spatial2D": "spatial2d",
				"Environment": "environment", "Label": "label", "Panel": "panel", "Bar": "bar", "Image": "image", "Button": "button", "VBox": "vbox", "HBox": "hbox", "Control": "control"}.get(str(c), "")
		if k != "":
			return k
	return "node"


## A Script object's name colour by where it runs (user, 2026-11-07): LocalScript (Client)
## blue, Script (Server) orange, ModuleScript (Shared) purple.
static func script_color(cls: String) -> Color:
	return BrickTheme.side_color(str(CBTypes.SCRIPT_TYPES[cls])) if CBTypes.SCRIPT_TYPES.has(cls) else Color.WHITE


## The edited scene's root: its one node at the top ({} while the scene is empty).
func scene_root() -> Dictionary:
	for o in context.world.get("objects", []):
		if int(o.get("parent", 0)) == 0 and not CBTypes.is_script_object(o):
			return o
	return {}


func _add_object(cls: String) -> void:
	var w: Dictionary = context.world
	if w.is_empty():
		return
	# One root per scene (Godot's): the first node added is the root; the next go under
	# the selected node, or under the root.
	var root := scene_root()
	if root.is_empty() and CBTypes.SCRIPT_TYPES.has(cls):
		if context.on_status.is_valid():
			context.on_status.call("A scene's root is a node: add one first (Node, Spatial3D...), then the script under it.")
		return
	var parent := 0 if root.is_empty() else int(context.world_object.get("id", root.id))
	if not root.is_empty() and (parent == 0 or find(parent).is_empty()):
		parent = int(root.id)
	var name := cls
	var n := 2
	while w.objects.any(func(x): return str(x.name) == name):
		name = "%s%d" % [cls, n]
		n += 1
	var o := {"id": int(w.next_id), "class": cls, "name": name, "parent": parent, "fields": {}}
	if cls.begins_with("scene:"):
		var rel := cls.trim_prefix("scene:")
		o = {"id": int(w.next_id), "scene": rel, "name": _free_name(rel.get_file().get_basename().capitalize().replace(" ", "")), "parent": parent, "fields": {}}
	if CBTypes.SCRIPT_TYPES.has(cls):
		# A new script file for it, in scripts/, named after it: When program starts ready.
		var rel := _new_script_file(name, CBTypes.SCRIPT_TYPES[cls])
		if rel == "":
			return
		o["script"] = rel
	w.next_id = int(w.next_id) + 1
	w.objects.append(o)
	context.world_object = o
	context.on_world_changed.call("Add %s" % cls)
	context.show_world_object(o)


## Makes scripts/<name>.cbricks (a free name) with a When program starts brick and
## the Side; returns its path from the project folder ("" if it can't).
func _new_script_file(obj_name: String, side: String) -> String:
	if context.project_dir == "":
		return ""
	var base := CBProject.safe_name(obj_name)  # "Script Test" -> scripts/script-test.cbricks
	var rel := "scripts/%s.cbricks" % base
	var n := 2
	while FileAccess.file_exists(context.project_dir.path_join(rel)):
		rel = "scripts/%s-%d.cbricks" % [base, n]
		n += 1
	DirAccess.make_dir_recursive_absolute(context.project_dir.path_join("scripts"))
	var g := Ops.new_graph()
	g["side"] = side
	if CBProject.write_script(context.project_dir.path_join(rel), g) != OK:
		return ""
	return rel


func _delete_selected() -> void:
	var o: Dictionary = context.world_object
	if o.is_empty():
		return
	var doomed := [int(o.id)]
	var grew := true
	while grew:
		grew = false
		for x in context.world.objects:
			if int(x.parent) in doomed and int(x.id) not in doomed:
				doomed.append(int(x.id))
				grew = true
	context.world.objects = context.world.objects.filter(func(x): return int(x.id) not in doomed)
	context.on_world_changed.call("Delete %s" % str(o.name))
	context.show_world_object({})


## Selects the row of context.world_object (none: no row), without rebuilding.
func _sync_selection() -> void:
	if _tree == null or _tree.get_root() == null:
		return
	var id := int(context.world_object.get("id", 0)) if not context.world_object.is_empty() else 0
	_delete.disabled = id == 0
	var found := _item_of(_tree.get_root(), id) if id != 0 else null
	if id != 0 and found == null:
		rebuild()  # an object the tree doesn't show yet (outside any Tree signal here)
		return
	_syncing = true
	if found == null:
		_tree.deselect_all()
	elif _tree.get_selected() != found:
		found.select(0)
		_tree.scroll_to_item(found)
	_syncing = false


func _item_of(item: TreeItem, id: int) -> TreeItem:
	var meta = item.get_metadata(0)
	if meta != null and int(meta) == id:
		return item
	for c in item.get_children():
		var f := _item_of(c, id)
		if f != null:
			return f
	return null


func _free_name(base: String) -> String:
	var name := base
	var n := 2
	while context.world.objects.any(func(x): return str(x.name) == name):
		name = "%s%d" % [base, n]
		n += 1
	return name


## A scene's objects at the top (its roots; Script objects don't count).
func _roots_of(rel: String) -> int:
	return CBProject.read_scene(context.project_dir.path_join(rel)).objects.filter(func(o): return int(o.parent) == 0 and not CBTypes.is_script_object(o)).size()


## Whether scene `outer` is `inner` or holds a copy of it (through other scenes too).
func contains_scene(outer: String, inner: String, seen: Array = []) -> bool:
	if outer == inner:
		return true
	if outer in seen:
		return false
	for o in CBProject.read_scene(context.project_dir.path_join(outer)).objects:
		if o.has("scene") and contains_scene(str(o.scene), inner, seen + [outer]):
			return true
	return false


## The open scenes' tabs (the Main scene's with a star, no close button).
func show_scenes(paths: Array, current: String, main: String) -> void:
	_scene_list = paths.duplicate()
	_scene_tabs.set_block_signals(true)  # (filling it changes its tab: not a pick)
	_scene_tabs.clear_tabs()
	for p in _scene_list:
		_scene_tabs.add_tab(str(p).get_file().get_basename(), context.brick_theme.icon("star" if p == main else "scene"))
		_scene_tabs.set_tab_tooltip(_scene_tabs.tab_count - 1, CBProject.rel_path(context.project_dir, p) + ("  (the Main scene: the world starts with it)" if p == main else ""))
	_scene_tabs.current_tab = maxi(0, _scene_list.find(current))
	_scene_tabs.set_block_signals(false)


const M_SAVE_BRANCH := 1
const M_OPEN_SCENE := 2
const M_DELETE := 3
const M_CHANGE := 4


func _open_menu(at: Vector2) -> void:
	var o: Dictionary = context.world_object
	if o.is_empty():
		return
	_menu.clear()
	var is_root := int(o.get("parent", 0)) == 0
	if o.has("scene"):
		_menu.add_icon_item(context.brick_theme.icon("scene"), "Open %s" % str(o.scene).get_file(), M_OPEN_SCENE)
	elif not CBTypes.is_script_object(o) and not is_root:  # (the root is the scene already)
		_menu.add_icon_item(context.brick_theme.icon("scene"), "Save branch as scene", M_SAVE_BRANCH)
		_menu.set_item_tooltip(0, "Moves this object and the objects under it into a new scene (scenes/%s.cbscene) and puts a copy of it here." % str(o.name).to_snake_case())
	if not o.has("scene"):  # (a copy's type is its scene's root's)
		_menu.add_icon_item(context.brick_theme.icon("reload"), "Change type...", M_CHANGE)
		_menu.set_item_tooltip(_menu.item_count - 1, "Pick another class for it (Godot's Change Type): fields the new class hasn't got are dropped." if not CBTypes.is_script_object(o) else "Script, LocalScript or ModuleScript: where it runs (its file's Side).")
	_menu.add_icon_item(context.brick_theme.icon("remove"), "Delete", M_DELETE)
	_menu_at = Vector2i(_tree.get_screen_position() + at)
	_menu.position = Vector2i(_tree.get_screen_position() + at)
	_menu.reset_size()
	_menu.popup()


var _menu_at := Vector2i.ZERO


## The Create New Node window, picking a new type for the selected object.
func _open_change() -> void:
	var o := context.world_object
	_dialog().open("change", str(o.get("class", "")), func(key: String) -> void: change_type(context.world_object, key))


## Godot's Change Type: a node's class (fields the new class hasn't got are dropped), or
## a Script object's type (its file's Side).
func change_type(o: Dictionary, cls: String) -> void:
	if o.is_empty() or o.has("scene") or str(o.get("class", "")) == cls:
		return
	if CBTypes.is_script_object(o):
		if CBTypes.SCRIPT_TYPES.has(cls) and context.on_script_side.is_valid():
			o["class"] = cls
			context.on_script_side.call(str(o.get("script", "")), str(CBTypes.SCRIPT_TYPES[cls]))
		return
	o["class"] = cls
	var keep := CBTypes.all_fields(cls).map(func(x): return x[0])
	for fname in (o.fields as Dictionary).keys():
		if fname not in keep:
			o.fields.erase(fname)
	context.on_world_changed.call("Change %s to %s" % [str(o.name), cls])
	context.show_world_object(o)


func _on_menu(id: int) -> void:
	match id:
		M_SAVE_BRANCH: save_branch_as_scene.call_deferred(context.world_object)
		M_OPEN_SCENE:
			if context.on_open_scene.is_valid():
				context.on_open_scene.call(str(context.world_object.get("scene", "")))
		M_DELETE: _delete_selected.call_deferred()
		M_CHANGE: _open_change.call_deferred()


## Godot's Save Branch as Scene: the object and what's under it go into a new scene
## file (scenes/<name>.cbscene, it the root); a copy of that scene takes its place.
## Returns the new scene's path from the project folder ("" if it can't).
func save_branch_as_scene(o: Dictionary) -> String:
	if o.is_empty() or o.has("scene") or CBTypes.is_script_object(o) or context.project_dir == "":
		return ""
	var ids := [int(o.id)]
	var grew := true
	while grew:
		grew = false
		for x in context.world.objects:
			if int(x.parent) in ids and int(x.id) not in ids:
				ids.append(int(x.id))
				grew = true
	var base := str(o.name).to_snake_case()
	var rel := "scenes/%s.cbscene" % base
	var n := 2
	while FileAccess.file_exists(context.project_dir.path_join(rel)):
		rel = "scenes/%s_%d.cbscene" % [base, n]
		n += 1
	var objs := []
	var top := 0
	for x in context.world.objects:
		if int(x.id) in ids:
			var c: Dictionary = x.duplicate(true)
			if int(c.id) == int(o.id):
				c.parent = 0
			objs.append(c)
			top = maxi(top, int(c.id))
	if CBProject.write_scene(context.project_dir.path_join(rel), {"format": "c-bricks-scene", "version": CBProject.SCENE_VERSION, "next_id": top + 1, "objects": objs}) != OK:
		return ""
	var copy := {"id": int(o.id), "scene": rel, "name": str(o.name), "parent": int(o.parent), "fields": {}}
	var kept := []
	for x in context.world.objects:
		if int(x.id) == int(o.id):
			kept.append(copy)
		elif int(x.id) not in ids:
			kept.append(x)
	context.world.objects = kept
	context.world_object = copy
	context.on_world_changed.call("Save branch as %s" % rel)
	context.show_world_object(copy)
	return rel


# ------------------------------------------------------------------ drag to reparent
func _drag_row(_at: Vector2) -> Variant:
	var it := _tree.get_selected()
	var id := int(it.get_metadata(0)) if it != null else 0
	var o := find(id)
	if o.is_empty() or int(o.parent) == 0:
		return null  # (nothing, a copy's inner row, or the root: it stays the root)
	var l := Label.new()
	l.text = str(o.name)
	set_drag_preview(l)
	_tree.drop_mode_flags = Tree.DROP_MODE_ON_ITEM | Tree.DROP_MODE_INBETWEEN
	return {"world_object": id}


## The node a drop would put it under ({} if not there: itself, under itself, a Script
## object, a copy's inner row). Dropped between rows (above / below one): beside that row,
## under its parent ({"beside": the row's node, "after": below it}).
func _drop_target(at: Vector2, data: Variant) -> Dictionary:
	if not (data is Dictionary and (data as Dictionary).has("world_object")):
		return {}
	var it := _tree.get_item_at_position(at)
	if it == null:
		return {}
	var target := find(int(it.get_metadata(0)))
	var moving := int(data.world_object)
	var section := _tree.get_drop_section_at_position(at)
	if section in [-1, 1] and not target.is_empty() and int(target.parent) != 0 and int(target.id) != moving:
		var under := find(int(target.parent))
		var q := int(under.get("id", 0))
		while q != 0:  # (not beside something under itself)
			if q == moving:
				return {}
			q = int(find(q).get("parent", 0))
		return {"under": under, "beside": target, "after": section > 0}
	if target.is_empty() or CBTypes.is_script_object(target) or int(target.id) == moving:
		return {}
	var p := int(target.parent)
	while p != 0:  # not under itself
		if p == moving:
			return {}
		p = int(find(p).get("parent", 0))
	return target


## Puts `o` just before (or after) `beside`, under the same parent: the scene file's order
## is the order siblings are made in (a VBox / HBox stacks them in it).
func move_beside(o: Dictionary, beside: Dictionary, after: bool) -> void:
	var objs: Array = context.world.objects
	if o == beside or int(beside.get("parent", 0)) == 0:
		return
	objs.erase(o)
	o.parent = int(beside.parent)
	objs.insert(objs.find(beside) + (1 if after else 0), o)
	context.world_object = o
	context.on_world_changed.call("Move %s %s %s" % [str(o.name), "below" if after else "above", str(beside.name)])


func _can_drop_row(at: Vector2, data: Variant) -> bool:
	return not _drop_target(at, data).is_empty()


func _drop_row(at: Vector2, data: Variant) -> void:
	var target := _drop_target(at, data)
	_tree.drop_mode_flags = Tree.DROP_MODE_DISABLED  # (after: the drop's section needs it on)
	var o := find(int(data.world_object))
	if target.is_empty() or o.is_empty():
		return
	if target.has("beside"):  # between rows: next to that node, in the scene's order
		move_beside(o, target.beside, bool(target.after))
		return
	if int(o.parent) == int(target.id):
		return
	o.parent = int(target.id)
	context.world_object = o
	context.on_world_changed.call("Move %s under %s" % [str(o.name), str(target.name)])
