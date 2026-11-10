extends GraphEdit
## The wire canvas (after Brickscript's flow_canvas.gd): one brick view per node
## of the graph, exec wires between them. Wire by dragging from a ▶ port; drop
## palette entries here, or right-click (or release a wire on empty space) for
## a menu of bricks to add. Right-drag (or middle-drag) pans. Ctrl+C / X / V / D
## copy, cut, paste and duplicate the selected bricks through the clipboard.
## Double-click a wire for a reroute point. Comment frames hold the bricks
## attached to them: they move with it; drop bricks on a frame to add them.

const Context = preload("res://scripts/editor/context.gd")
const BrickView = preload("res://scripts/editor/brick_view.gd")
const BrickTheme = preload("res://scripts/editor/brick_theme.gd")
const T = preload("res://scripts/node_defs.gd")

const FRAME_ITEM: int = 10000
const FRAME_PADDING: int = 32
const FRAME_DROP_ROOM: float = 48.0
const PAN_THRESHOLD: float = 4.0
## Drag data from the palette: {DRAG_KEY: brick type}.
const DRAG_KEY: String = "cbricks_brick"

var context: Context = null

var _add_menu: PopupMenu = null
var _add_menu_types: Array = []
var _add_at: Vector2 = Vector2.ZERO
var _add_wire: Array = []        # [node id, group, index] of a wire released on empty space
var _clipboard: String = ""
var _select_after_rebuild: Array = []
var _right_down_at: Vector2 = Vector2.INF
var _right_dragged: bool = false
var _right_travel: float = 0.0
var _dragged_out: Dictionary = {}


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	snapping_enabled = true
	snapping_distance = Ops.GRID
	show_grid = true
	minimap_enabled = true
	right_disconnects = true
	show_arrange_button = false
	connection_lines_thickness = 3.0
	add_valid_left_disconnect_type(BrickView.EXEC_PORT)
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	delete_nodes_request.connect(_on_delete_nodes_request)
	node_selected.connect(func(view: Node) -> void: context.select(int(String(view.name))))
	node_deselected.connect(func(_view: Node) -> void:
		if _selected_views().is_empty() and _selected_frames().is_empty():
			context.select(0))
	begin_node_move.connect(_on_begin_node_move)
	end_node_move.connect(_on_end_node_move)
	copy_nodes_request.connect(copy_selected)
	cut_nodes_request.connect(func() -> void:
		if copy_selected():
			_delete_views(_selected_views(), "Cut bricks"))
	paste_nodes_request.connect(paste)
	duplicate_nodes_request.connect(duplicate_selected)
	graph_elements_linked_to_frame_request.connect(_on_linked_to_frame)
	connection_to_empty.connect(func(from_node: StringName, from_port: int, release: Vector2) -> void:
		var view := get_node_or_null(NodePath(String(from_node))) as BrickView
		if view != null and from_port < view.exits.size():
			_open_add_menu(release, [int(view.node.id), view.exits[from_port][0], view.exits[from_port][1]]))
	_add_menu = PopupMenu.new()
	_add_menu.id_pressed.connect(_on_add_menu)
	add_child(_add_menu)


func _ready() -> void:
	_style()
	_side_label = Label.new()
	_side_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_side_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 10)
	_side_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_side_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_side_label.add_theme_font_size_override(&"font_size", 13)
	add_child(_side_label)


var _side_label: Label = null
var _styled_side := ""


## What kind of script this is (user, 2026-11-08): the background tinted by where it runs
## (Server orange, Client blue, Shared purple; dark), and a small label in the top right.
func _show_side() -> void:
	var side := str(context.graph.get("side", "Shared"))
	if side != _styled_side:
		_styled_side = side
		_style()
	if _side_label == null:
		return
	var cls := context.script_class
	_side_label.text = "%s (%s)%s · %s" % [BrickTheme.SIDE_TYPES.get(side, "ModuleScript"), side, " · class %s" % cls if cls != "" else "", BrickTheme.SIDE_WHERE.get(side, "")]
	_side_label.add_theme_color_override(&"font_color", Color(BrickTheme.side_color(side), 0.85))
	_side_label.tooltip_text = "Where this script runs: its Side (Properties, with no brick selected)."


## An opaque minimap with a border, grid colors from the theme.
func _style() -> void:
	minimap_opacity = 1.0
	minimap_size = Vector2(192, 128)
	var colors: BrickTheme = context.brick_theme
	var panel := StyleBoxFlat.new()
	panel.bg_color = colors.background().lerp(Color.BLACK, 0.3)
	panel.border_color = Color(colors.text_color(), 0.35)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(4)
	var look := Theme.new()
	look.set_stylebox(&"panel", &"GraphEditMinimap", panel)
	var bg := StyleBoxFlat.new()
	bg.bg_color = colors.script_tint(str(context.graph.get("side", "Shared"))) if context.has_graph() else colors.background()
	look.set_stylebox(&"panel", &"GraphEdit", bg)
	look.set_color(&"grid_minor", &"GraphEdit", colors.grid_colors()[0])
	look.set_color(&"grid_major", &"GraphEdit", colors.grid_colors()[1])
	look.set_color(&"activity", &"GraphEdit", colors.accent_color())
	theme = look


func rebuild() -> void:
	_show_side()
	for view in views():
		remove_child(view)
		view.queue_free()
	for view in frame_views():
		remove_child(view)
		view.queue_free()
	clear_connections()
	for frame in context.graph.get("frames", []):
		add_child(_frame_view(frame))
	for node in context.graph.nodes:
		var view := BrickView.new()
		view.setup(node, context)
		view.resize_end.connect(_on_resize_end.bind(view))
		view.gui_input.connect(func(event: InputEvent) -> void:
			if _pan_input(event, false, view):
				view.accept_event())
		add_child(view)
		view.selected = int(node.id) == context.selected or _select_after_rebuild.has(int(node.id))
	_select_after_rebuild.clear()
	for frame in context.graph.get("frames", []):
		for id in frame.nodes:
			if view_of(int(id)) != null:
				attach_graph_element_to_frame(StringName(str(int(id))), StringName(str(int(frame.id))))
	for view in views():
		for port in view.exits.size():
			var gi: Array = view.exits[port]
			var l: Array = Ops.group_links(view.node, gi[0])
			if gi[1] < l.size() and has_node(NodePath(str(int(l[gi[1]])))):
				connect_node(view.name, port, StringName(str(int(l[gi[1]]))), 0)


func views() -> Array:
	var out := []
	for c in get_children():
		if c is BrickView and not c.is_queued_for_deletion():
			out.append(c)
	return out


func frame_views() -> Array:
	var out := []
	for c in get_children():
		if c is GraphFrame and not c.is_queued_for_deletion():
			out.append(c)
	return out


func view_of(id: int) -> BrickView:
	return get_node_or_null(NodePath(str(id))) as BrickView


func to_graph(local_point: Vector2) -> Vector2:
	return Ops.snap((local_point + scroll_offset) / zoom)


func add_node_at(type: String, at: Vector2) -> Dictionary:
	var node := Ops.add_node(context.graph, type, at)
	if node.is_empty():
		return node
	context.select(int(node.id))
	context.notify_changed(Context.Redraw.ALL, "Add brick")
	return node


func add_node_in_view(type: String) -> Dictionary:
	return add_node_at(type, to_graph(size / 2.0))


func flash(ids: Array) -> void:
	for id in ids:
		var view := view_of(int(id))
		if view != null:
			view.flash()


## When none of the bricks is in view: scrolls to the top-left one.
func bring_bricks_into_view() -> bool:
	var shown := views()
	if shown.is_empty() or size.x <= 0.0:
		return false
	var seen := Rect2(scroll_offset / zoom, size / zoom)
	var first: BrickView = shown[0]
	for view in shown:
		if seen.intersects(Rect2(view.position_offset, view.size.max(Vector2.ONE))):
			return false
		if view.position_offset.y < first.position_offset.y or view.position_offset.y == first.position_offset.y and view.position_offset.x < first.position_offset.x:
			first = view
	scroll_offset = first.position_offset * zoom - Vector2(32.0, 64.0)
	return true


func show_node(id: int) -> void:
	var view := view_of(id)
	if view == null:
		return
	scroll_offset = view.position_offset * zoom - size / 2.0 + view.size * zoom / 2.0
	for other in views():
		other.selected = other == view
	context.select(id)


# ------------------------------------------------------------------ panning

func _gui_input(event: InputEvent) -> void:
	if _pan_input(event, true):
		accept_event()
		return
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT and button.pressed and button.double_click and not add_reroute_at(get_local_mouse_position()).is_empty():
		accept_event()


## Double-click on a wire: a reroute point there, wired in between.
func add_reroute_at(local_point: Vector2) -> Dictionary:
	var wire: Dictionary = get_closest_connection_at_point(local_point, 8.0)
	if wire.is_empty():
		return {}
	var from_view := get_node_or_null(NodePath(String(wire.from_node))) as BrickView
	if from_view == null or int(wire.from_port) >= from_view.exits.size():
		return {}
	var gi: Array = from_view.exits[int(wire.from_port)]
	var point := Ops.insert_reroute(context.graph, from_view.node, gi[0], gi[1], to_graph(local_point) - Vector2(Ops.GRID, Ops.GRID))
	if point.is_empty():
		return {}
	context.select(int(point.id))
	context.notify_changed(Context.Redraw.ALL, "Add reroute point")
	return point


## Right button: a drag pans, a click (on empty canvas) opens the add menu.
func _pan_input(event: InputEvent, on_canvas: bool, view: Control = null) -> bool:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_RIGHT:
		var at := get_local_mouse_position()
		if button.pressed:
			_right_down_at = at
			_right_dragged = false
			_right_travel = 0.0
		else:
			if on_canvas and not _right_dragged and _right_down_at != Vector2.INF:
				_open_add_menu(at, [])
			elif view is BrickView and not _right_dragged and _right_down_at != Vector2.INF:
				_open_brick_menu(view, at)
			_right_down_at = Vector2.INF
		return true
	var motion := event as InputEventMouseMotion
	if motion != null and motion.button_mask & MOUSE_BUTTON_MASK_RIGHT and _right_down_at != Vector2.INF:
		_right_travel += motion.screen_relative.length()
		if not _right_dragged and _right_travel > PAN_THRESHOLD:
			_right_dragged = true
		if _right_dragged:
			scroll_offset -= motion.screen_relative
		return true
	return false


# ------------------------------------------------------------------ clipboard

func copy_selected() -> bool:
	var nodes := _selected_views().map(func(v): return v.node)
	if nodes.is_empty():
		return false
	_clipboard = Ops.clipboard_text(Ops.copy_nodes(nodes))
	DisplayServer.clipboard_set(_clipboard)
	return true


func paste() -> void:
	var copied := Ops.clipboard_data(DisplayServer.clipboard_get())
	if copied.is_empty():
		copied = Ops.clipboard_data(_clipboard)
	var mouse := get_local_mouse_position()
	var at = to_graph(mouse) if Rect2(Vector2.ZERO, size).has_point(mouse) else null
	_add_copies(copied, at, "Paste bricks")


func duplicate_selected() -> void:
	_add_copies(Ops.copy_nodes(_selected_views().map(func(v): return v.node)), null, "Duplicate bricks")


func _add_copies(copied: Array, at, action: String) -> void:
	var pasted := Ops.paste_nodes(context.graph, copied, at)
	if pasted.is_empty():
		return
	for n in pasted:
		_select_after_rebuild.append(int(n.id))
	context.select(int(pasted.back().id))
	context.notify_changed(Context.Redraw.ALL, action)


# ------------------------------------------------------------------ palette drops

func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and T.DEFS.has(data.get(DRAG_KEY, ""))


func _drop_data(at_position: Vector2, data: Variant) -> void:
	var at := to_graph(at_position)
	var node := Ops.add_node(context.graph, data[DRAG_KEY], at)
	if node.is_empty():
		return
	var into: Dictionary = {}
	var smallest := INF
	for fv in frame_views():
		var area := Rect2(fv.position_offset, fv.size)
		if area.grow(FRAME_DROP_ROOM).has_point(at) and area.get_area() < smallest:
			smallest = area.get_area()
			into = Ops.frame_by_id(context.graph, int(String(fv.name)))
	if not into.is_empty():
		Ops.attach_to_frame(context.graph, into, int(node.id))
	context.select(int(node.id))
	context.notify_changed(Context.Redraw.ALL, "Add brick")


# ------------------------------------------------------------------ wires and edits

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	var from_view := get_node_or_null(NodePath(String(from_node))) as BrickView
	var to_view := get_node_or_null(NodePath(String(to_node))) as BrickView
	if from_view == null or to_view == null or from_port >= from_view.exits.size():
		return
	var gi: Array = from_view.exits[from_port]
	if Ops.connect_exit(context.graph, from_view.node, gi[0], gi[1], to_view.node):
		context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Connect")
	elif Ops.last_error != "" and context.on_status.is_valid():
		context.on_status.call(Ops.last_error)


func _on_disconnection_request(from_node: StringName, from_port: int, _to_node: StringName, _to_port: int) -> void:
	var from_view := get_node_or_null(NodePath(String(from_node))) as BrickView
	if from_view != null and from_port < from_view.exits.size():
		var gi: Array = from_view.exits[from_port]
		if Ops.disconnect_exit(from_view.node, gi[0], gi[1]):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Disconnect")


func _on_delete_nodes_request(names: Array[StringName]) -> void:
	var doomed := []
	var frames_gone := false
	for nm in names:
		var view := get_node_or_null(NodePath(String(nm)))
		if view is BrickView:
			doomed.append(view)
		elif view is GraphFrame and Ops.delete_frame(context.graph, Ops.frame_by_id(context.graph, int(String(nm)))):
			frames_gone = true
	if doomed.is_empty() and frames_gone:
		context.select(0)
		context.notify_changed(Context.Redraw.ALL, "Delete frame")
		return
	_delete_views(doomed, "Delete bricks")


func _delete_views(doomed: Array, action: String) -> void:
	var deleted := false
	for view in doomed:
		if Ops.delete_node(context.graph, view.node):
			deleted = true
			if int(view.node.id) == context.selected:
				context.select(0)
	if deleted:
		context.notify_changed(Context.Redraw.ALL, action)


func _on_begin_node_move() -> void:
	_dragged_out.clear()
	for view in _selected_views():
		for frame in context.graph.frames:
			if int(view.node.id) not in frame.nodes:
				continue
			var fv := get_node_or_null(NodePath(str(int(frame.id)))) as GraphFrame
			if fv != null and not fv.selected:
				_dragged_out[int(view.node.id)] = int(frame.id)
				detach_graph_element_from_frame(view.name)


func _on_end_node_move() -> void:
	for view in views():
		Ops.set_position(view.node, view.position_offset)
		view.position_offset = Ops.snap(view.position_offset)
	for id in _dragged_out:
		var frame := Ops.frame_by_id(context.graph, _dragged_out[id])
		var nv := view_of(id)
		var fv := get_node_or_null(NodePath(str(_dragged_out[id]))) as GraphFrame
		if frame.is_empty() or nv == null or fv == null:
			continue
		var middle := nv.position_offset + nv.size / 2.0
		if Rect2(fv.position_offset, fv.size).grow(FRAME_DROP_ROOM).has_point(middle):
			attach_graph_element_to_frame(nv.name, fv.name)
		else:
			Ops.detach_from_frame(frame, id)
	_dragged_out.clear()
	_store_frames.call_deferred()
	context.notify_changed(Context.Redraw.NONE, "Move bricks")


func _store_frames() -> void:
	for fv in frame_views():
		var frame := Ops.frame_by_id(context.graph, int(String(fv.name)))
		if not frame.is_empty():
			Ops.set_frame(frame, "pos", fv.position_offset)
			Ops.set_frame(frame, "size", fv.size)


func _on_linked_to_frame(elements: Array, frame_name: StringName) -> void:
	var frame := Ops.frame_by_id(context.graph, int(String(frame_name)))
	var attached := false
	for element in elements:
		if Ops.attach_to_frame(context.graph, frame, int(String(element))):
			if get_element_frame(StringName(element)) != null:
				detach_graph_element_from_frame(StringName(element))
			attach_graph_element_to_frame(StringName(element), frame_name)
			attached = true
	if attached:
		_store_frames.call_deferred()
		context.notify_changed(Context.Redraw.PROPERTIES, "Add to frame")


static func _band_style(color: Color, selected_state: bool) -> StyleBoxFlat:
	var band := StyleBoxFlat.new()
	band.bg_color = Color(color.darkened(0.55), 1.0)
	band.border_color = Color(color.lightened(0.55 if selected_state else 0.25), 1.0)
	band.border_width_bottom = 2
	band.corner_radius_top_left = 4
	band.corner_radius_top_right = 4
	band.content_margin_left = 12
	band.content_margin_right = 12
	band.content_margin_top = 4
	band.content_margin_bottom = 4
	return band


func _frame_view(frame: Dictionary) -> GraphFrame:
	var view := GraphFrame.new()
	var color := Color.html(frame.color)
	view.name = str(int(frame.id))
	view.title = frame.title
	view.position_offset = Vector2(frame.pos[0], frame.pos[1])
	view.size = Vector2(frame.size[0], frame.size[1])
	view.tint_color_enabled = true
	view.tint_color = Color(color, 0.45)
	view.add_theme_stylebox_override(&"titlebar", _band_style(color, false))
	view.add_theme_stylebox_override(&"titlebar_selected", _band_style(color, true))
	view.autoshrink_enabled = not frame.nodes.is_empty() and frame.get("fit", true)
	view.autoshrink_margin = FRAME_PADDING
	view.resizable = true
	view.selected = int(frame.id) == context.selected
	view.tooltip_text = "Comment frame: drop bricks on it to group them; they move with it."
	for child in view.get_titlebar_hbox().get_children():
		if child is Label:
			child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			child.clip_text = true
			child.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			child.custom_minimum_size.x = 64
			child.add_theme_font_size_override(&"font_size", 15)
			child.add_theme_color_override(&"font_color", Color(context.brick_theme.text_color(), 1.0))
	view.resize_end.connect(func(_s: Vector2) -> void:
		view.size = Ops.snap_up(view.size)
		var changed := Ops.set_frame(frame, "fit", false)
		changed = Ops.set_frame(frame, "pos", view.position_offset) or changed
		changed = Ops.set_frame(frame, "size", view.size) or changed
		if changed:
			context.notify_changed(Context.Redraw.PROPERTIES, "Resize frame"))
	return view


func _on_resize_end(_new_size: Vector2, view: BrickView) -> void:
	if Ops.set_size(view.node, view.size):
		view.fit()
		context.notify_changed(Context.Redraw.PROPERTIES, "Resize brick")


func brick_sizes() -> Dictionary:
	var sizes := {}
	for view in views():
		sizes[int(view.node.id)] = view.size
	return sizes


## Toolbar Arrange: the selected bricks' chains (all when none is selected).
func arrange_chains() -> void:
	var only := _selected_views().map(func(v): return int(v.node.id))
	if Ops.arrange(context.graph, brick_sizes(), only):
		context.notify_changed(Context.Redraw.ALL, "Arrange")


func _selected_views() -> Array:
	return views().filter(func(v): return v.selected)


func _selected_frames() -> Array:
	return frame_views().filter(func(v): return v.selected)


# ------------------------------------------------------------------ a brick's menu

var _brick_menu: PopupMenu = null
var _menu_brick: int = 0


## Right-click on a brick: breakpoint, go to its function, duplicate, delete.
func _open_brick_menu(view: BrickView, at: Vector2) -> void:
	_menu_brick = int(view.node.id)
	if _brick_menu == null:
		_brick_menu = PopupMenu.new()
		_brick_menu.id_pressed.connect(_on_brick_menu)
		add_child(_brick_menu)
	_brick_menu.clear()
	var on: bool = _menu_brick in context.breakpoints().map(func(x): return int(x))
	_brick_menu.add_item("Remove breakpoint (F9)" if on else "Add breakpoint (F9)", 0)
	if view.node.type == "call" and str(view.node.fields.get("function", "")) != "":
		_brick_menu.add_item("Go to function %s" % view.node.fields.function, 1)
	_brick_menu.add_separator()
	_brick_menu.add_item("Duplicate (Ctrl+D)", 2)
	_brick_menu.add_item("Delete", 3)
	_brick_menu.position = Vector2i(get_screen_position() + at)
	_brick_menu.reset_size()
	_brick_menu.popup()


func _on_brick_menu(id: int) -> void:
	var node := Ops.node_by_id(context.graph, _menu_brick)
	if node.is_empty():
		return
	match id:
		0:
			if context.on_toggle_breakpoint.is_valid():
				context.on_toggle_breakpoint.call(_menu_brick)
		1:
			if context.on_goto_function.is_valid():
				context.on_goto_function.call(str(node.fields.get("function", "")))
		2:
			for v in views():
				v.selected = int(v.node.id) == _menu_brick
			duplicate_selected()
		3:
			_delete_views(views().filter(func(v): return int(v.node.id) == _menu_brick), "Delete brick")


# ------------------------------------------------------------------ add menu

func add_frame_here() -> void:
	_add_at = to_graph(size / 2.0) - Ops.FRAME_SIZE / 2.0
	_add_frame()


func _add_frame() -> void:
	var ids := _selected_views().map(func(v): return int(v.node.id))
	var frame := Ops.add_frame(context.graph, _add_at, ids)
	context.select(int(frame.id))
	context.notify_changed(Context.Redraw.ALL, "Add frame")


func _open_add_menu(at: Vector2, wire: Array) -> void:
	_add_at = to_graph(at)
	_add_wire = wire
	_add_menu.clear()
	_add_menu_types.clear()
	if wire.is_empty():
		var wrapping := _selected_views().size()
		_add_menu.add_item("Comment frame" if wrapping == 0 else "Comment frame around %d selected brick(s)" % wrapping, FRAME_ITEM)
	for category in BrickTheme.CATEGORY_ORDER:
		var first := true
		for type in T.DEFS:
			var def: Dictionary = T.DEFS[type]
			if def.cat != category or not context.can_use(type) or (not wire.is_empty() and not T.has_input(type)):
				continue
			if first:
				_add_menu.add_separator(BrickTheme.CATEGORY_TITLES[category])
				first = false
			_add_menu.add_item(def.title, _add_menu_types.size())
			_add_menu_types.append(type)
	_add_menu.position = Vector2i(get_screen_position() + at)
	_add_menu.reset_size()
	_add_menu.popup()


func _on_add_menu(id: int) -> void:
	if id == FRAME_ITEM:
		_add_frame()
		return
	if id < 0 or id >= _add_menu_types.size():
		return
	var node := Ops.add_node(context.graph, _add_menu_types[id], _add_at)
	if node.is_empty():
		return
	if not _add_wire.is_empty():
		var from := Ops.node_by_id(context.graph, _add_wire[0])
		Ops.connect_exit(context.graph, from, _add_wire[1], _add_wire[2], node)
		# Two grid squares after the brick it follows; on its row when dropped
		# beside it, else on the row it was dropped on (a branch).
		var fv := view_of(int(from.id))
		if fv != null:
			node.pos[0] = Ops.snap_up(Vector2(from.pos[0] + fv.size.x, 0)).x + Ops.CHAIN_GAP
			if absf(node.pos[1] - from.pos[1]) < fv.size.y / 2.0:
				node.pos[1] = from.pos[1]
	context.select(int(node.id))
	context.notify_changed(Context.Redraw.ALL, "Add brick")
