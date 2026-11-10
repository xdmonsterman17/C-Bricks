@tool
extends GraphEdit

## The wire canvas: one GraphNode per node of the graph, exec wires between
## them. Built on Godot's GraphEdit (pan, zoom, grid, minimap, box select).
## Wire by dragging from a ▶ port; drop palette entries here, or right-click
## (or release a wire on empty space) for a menu of nodes to add. Right-drag
## (or middle-drag) pans. Ctrl+C / X /
## V / D copy, cut, paste and duplicate the selected nodes (with the wires
## between them) through the system clipboard, so they paste into other
## graphs too. Comment frames (right-click > Comment frame) hold the nodes
## attached to them: they move with it; drop nodes on a frame to add them.

const Context = preload("flow_context.gd")
const Library = preload("../core/flow_library.gd")
const Ops = preload("../core/flow_ops.gd")
const FlowGraphNode = preload("flow_graph_node.gd")
const BrickTheme = preload("brick_theme.gd")

const GRID_STEP: int = Ops.GRID
## Add menu id of "Comment frame" (other ids index _add_menu_types).
const FRAME_ITEM: int = 10000
## Space a frame leaves around the nodes it holds: sides and bottom, and top
## (room for its title). Whole grid squares, so its edges stay on the grid.
const FRAME_PADDING: Vector2 = Vector2(32, 32)
## A frame's title sits in a band across its top, a line under it: whole
## grid squares tall (one more each time the title wraps), the bricks
## FRAME_PADDING below it. The band's text margins:
const FRAME_BAND_MARGINS: Vector2 = Vector2(12, 4)
## A brick dropped this close outside a frame's edge (its middle) stays in
## the frame, or joins it from the palette; the frame grows to fit it (the
## user's 3 grid squares, 2026-10-28).
const FRAME_DROP_ROOM: float = 48.0
## How far the mouse may move with the right button down and still count as
## a click (opens the add menu) rather than a pan.
const PAN_THRESHOLD: float = 4.0
## Drag data from the palette: {DRAG_KEY: node type}.
const DRAG_KEY: String = "brickscript_flow_node"

var context: Context = null

var _add_menu: PopupMenu = null
## A frame fit is waiting for the end of the frame (_queue_fit).
var _fit_queued: bool = false
var _add_menu_types: Array[StringName] = []
## Where the add menu puts its node, and the wire to attach it to (from a
## wire released on empty space): [node id, exit] or [].
var _add_at: Vector2 = Vector2.ZERO
var _add_wire: Array = []
## Last copy, for when the system clipboard isn't available (headless).
var _clipboard: String = ""
## Node ids to show selected after the next rebuild (e.g. what was pasted).
var _select_after_rebuild: Array[int] = []
## Where the right button went down (canvas coordinates), and whether it has
## been dragged since: a right-drag pans, a right-click opens the add menu.
var _right_down_at: Vector2 = Vector2.INF
var _right_dragged: bool = false
## How far the mouse has moved since the right button went down.
var _right_travel: float = 0.0


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	snapping_enabled = true
	snapping_distance = GRID_STEP
	show_grid = true
	minimap_enabled = true
	right_disconnects = true
	show_arrange_button = false
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	delete_nodes_request.connect(_on_delete_nodes_request)
	node_selected.connect(func(view: Node) -> void: context.select(int(String(view.name))))
	node_deselected.connect(func(_view: Node) -> void:
		if _selected_views().is_empty():
			context.select(0))
	begin_node_move.connect(_on_begin_node_move)
	end_node_move.connect(_on_end_node_move)
	copy_nodes_request.connect(copy_selected)
	cut_nodes_request.connect(func() -> void:
		if copy_selected():
			_delete_views(_selected_views(), "Cut nodes"))
	paste_nodes_request.connect(paste)
	duplicate_nodes_request.connect(duplicate_selected)
	graph_elements_linked_to_frame_request.connect(_on_linked_to_frame)
	connection_to_empty.connect(func(from_node: StringName, from_port: int, release: Vector2) -> void:
		var view: FlowGraphNode = get_node_or_null(NodePath(String(from_node))) as FlowGraphNode
		if view != null and from_port < view.exit_names.size():
			_open_add_menu(release, [view.node.id, view.exit_names[from_port]]))
	_add_menu = PopupMenu.new()
	_add_menu.id_pressed.connect(_on_add_menu)
	add_child(_add_menu)


func _ready() -> void:
	_style_minimap()


## The minimap as an opaque panel with a border: Godot's own is see-through
## (65 % and a faint background), so its tiny bricks looked like marks drawn
## on whatever brick sat in that corner.
func _style_minimap() -> void:
	minimap_opacity = 1.0
	# (Godot's 240 x 160 hides a whole brick or more; it can be dragged bigger.)
	minimap_size = Vector2(192, 128)
	var colors: BrickTheme = context.brick_theme if context != null else BrickTheme.new()
	var panel: StyleBoxFlat = StyleBoxFlat.new()
	panel.bg_color = colors.background().lerp(Color.BLACK, 0.3)
	panel.border_color = Color(colors.text_color(), 0.35)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(4)
	# (Only the minimap's panel: everything else comes from the editor's theme.)
	var look: Theme = Theme.new()
	look.set_stylebox(&"panel", &"GraphEditMinimap", panel)
	theme = look


func rebuild() -> void:
	for view: FlowGraphNode in views():
		remove_child(view)
		view.queue_free()
	for view: GraphFrame in frame_views():
		remove_child(view)
		view.queue_free()
	clear_connections()
	for frame: Dictionary in context.graph.frames:
		add_child(_frame_view(frame))
	for node: BrickscriptFlowNode in context.graph.nodes:
		if node == null:
			continue
		var view: FlowGraphNode = FlowGraphNode.new()
		view.setup(node, context)
		view.resize_end.connect(_on_resize_end.bind(view))
		# (Its size settles over a few frames: the frames around it follow,
		# and a wrapped frame title rewraps to the final width.)
		view.resized.connect(_queue_fit)
		# Nodes stop mouse events from reaching the canvas: let right-drags
		# on them pan too.
		view.gui_input.connect(func(event: InputEvent) -> void:
			if _pan_input(event, false):
				view.accept_event())
		add_child(view)
		view.selected = node.id == context.selected or _select_after_rebuild.has(node.id)
	_select_after_rebuild.clear()
	for frame: Dictionary in context.graph.frames:
		for id: int in frame["nodes"]:
			if view_of(id) != null:
				attach_graph_element_to_frame(StringName(str(id)), StringName(str(frame["id"])))
	# Node sizes are only final once they are in the tree.
	_fit_frames.call_deferred()
	for view: FlowGraphNode in views():
		for port: int in view.exit_names.size():
			var target: int = view.node.exits.get(view.exit_names[port], 0)
			if target > 0 and has_node(NodePath(str(target))):
				connect_node(view.name, port, StringName(str(target)), 0)


func views() -> Array[FlowGraphNode]:
	var result: Array[FlowGraphNode] = []
	for child: Node in get_children():
		if child is FlowGraphNode and not child.is_queued_for_deletion():
			result.append(child)
	return result


func frame_views() -> Array[GraphFrame]:
	var result: Array[GraphFrame] = []
	for child: Node in get_children():
		if child is GraphFrame and not child.is_queued_for_deletion():
			result.append(child)
	return result


func view_of(node_id: int) -> FlowGraphNode:
	return get_node_or_null(NodePath(str(node_id))) as FlowGraphNode


## Canvas (graph) coordinates of a point given in this control's coordinates.
func to_graph(local_point: Vector2) -> Vector2:
	return ((local_point + scroll_offset) / zoom).snapped(Vector2(GRID_STEP, GRID_STEP))


## Adds a node of `type` at canvas position `at`, selects it, and returns it.
func add_node_at(type: StringName, at: Vector2) -> BrickscriptFlowNode:
	var node: BrickscriptFlowNode = Ops.add_node(context.graph, type, at)
	if node == null:
		return null
	context.select(node.id)
	context.notify_changed(Context.Redraw.ALL, "Add node")
	return node


## Adds a node where the middle of the visible canvas is.
func add_node_in_view(type: StringName) -> BrickscriptFlowNode:
	return add_node_at(type, to_graph(size / 2.0))


## Scrolls so the node is in the middle, and selects it.
## Lights up the bricks that just ran (Trace).
func flash(node_ids: Array) -> void:
	for node_id: Variant in node_ids:
		var view: FlowGraphNode = view_of(int(node_id))
		if view != null:
			view.flash()


## When none of the bricks is in view (a remembered view from elsewhere, or
## bricks far from the start): scrolls to the top-left one, just below the
## zoom bar. False when it didn't need to.
func bring_bricks_into_view() -> bool:
	var shown: Array[FlowGraphNode] = views()
	if shown.is_empty() or size.x <= 0.0:
		return false
	var seen: Rect2 = Rect2(scroll_offset / zoom, size / zoom)
	var first: FlowGraphNode = shown[0]
	for view: FlowGraphNode in shown:
		if seen.intersects(Rect2(view.position_offset, view.size.max(Vector2.ONE))):
			return false
		if view.position_offset.y < first.position_offset.y or view.position_offset.y == first.position_offset.y and view.position_offset.x < first.position_offset.x:
			first = view
	# (Below the zoom bar, whatever the zoom.)
	scroll_offset = first.position_offset * zoom - Vector2(32.0, 64.0)
	return true


func show_node(node_id: int) -> void:
	var view: FlowGraphNode = view_of(node_id)
	if view == null:
		return
	scroll_offset = view.position_offset * zoom - size / 2.0 + view.size * zoom / 2.0
	for other: FlowGraphNode in views():
		other.selected = other == view
	context.select(node_id)


#region Panning

func _gui_input(event: InputEvent) -> void:
	# Handled here (and accepted) so GraphEdit's own right-press menu doesn't
	# open: the menu opens on a right-click without a drag instead.
	if _pan_input(event, true):
		accept_event()
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT and button.pressed and button.double_click and add_reroute_at(get_local_mouse_position()) != null:
		accept_event()


## Double-click on a wire: a reroute point there, wired in between (it bends
## the wire). null if no wire is near.
func add_reroute_at(local_point: Vector2) -> BrickscriptFlowNode:
	var wire: Dictionary = get_closest_connection_at_point(local_point, 8.0)
	if wire.is_empty():
		return null
	var from_view: FlowGraphNode = get_node_or_null(NodePath(String(wire["from_node"]))) as FlowGraphNode
	if from_view == null or int(wire["from_port"]) >= from_view.exit_names.size():
		return null
	var point: BrickscriptFlowNode = Ops.insert_reroute(context.graph, from_view.node, from_view.exit_names[int(wire["from_port"])], to_graph(local_point) - Vector2(GRID_STEP, GRID_STEP))
	if point == null:
		return null
	context.select(point.id)
	context.notify_changed(Context.Redraw.ALL, "Add reroute point")
	return point


## Right button: a drag pans, a click (on empty canvas) opens the add menu.
## Returns whether the event was used.
func _pan_input(event: InputEvent, on_canvas: bool) -> bool:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_RIGHT:
		var at: Vector2 = get_local_mouse_position()
		if button.pressed:
			_right_down_at = at
			_right_dragged = false
			_right_travel = 0.0
		else:
			if on_canvas and not _right_dragged and _right_down_at != Vector2.INF:
				_open_add_menu(at, [])
			_right_down_at = Vector2.INF
		return true
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and motion.button_mask & MOUSE_BUTTON_MASK_RIGHT and _right_down_at != Vector2.INF:
		_right_travel += motion.screen_relative.length()
		if not _right_dragged and _right_travel > PAN_THRESHOLD:
			_right_dragged = true
		if _right_dragged:
			scroll_offset -= motion.screen_relative
		return true
	return false

#endregion


#region Clipboard

## Copies the selected nodes; returns whether there were any.
func copy_selected() -> bool:
	var nodes: Array = _selected_views().map(func(view: FlowGraphNode) -> BrickscriptFlowNode: return view.node)
	if nodes.is_empty():
		return false
	_clipboard = Ops.clipboard_text(Ops.copy_nodes(nodes))
	DisplayServer.clipboard_set(_clipboard)
	return true


## Pastes copied nodes: at the mouse when it's over the canvas, otherwise
## next to where they were copied from.
func paste() -> void:
	var copied: Array = Ops.clipboard_data(DisplayServer.clipboard_get())
	if copied.is_empty():
		copied = Ops.clipboard_data(_clipboard)
	var mouse: Vector2 = get_local_mouse_position()
	var at: Variant = to_graph(mouse) if Rect2(Vector2.ZERO, size).has_point(mouse) else null
	_add_copies(copied, at, "Paste nodes")


func duplicate_selected() -> void:
	var nodes: Array = _selected_views().map(func(view: FlowGraphNode) -> BrickscriptFlowNode: return view.node)
	_add_copies(Ops.copy_nodes(nodes), null, "Duplicate nodes")


func _add_copies(copied: Array, at: Variant, action: String) -> void:
	var pasted: Array[BrickscriptFlowNode] = Ops.paste_nodes(context.graph, copied, at)
	if pasted.is_empty():
		return
	for node: BrickscriptFlowNode in pasted:
		_select_after_rebuild.append(node.id)
	context.select(pasted.back().id)
	context.notify_changed(Context.Redraw.ALL, action)

#endregion


#region Drops from the palette

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and Library.get_definition(data.get(DRAG_KEY, &"")) != {}


func _drop_data(at_position: Vector2, data: Variant) -> void:
	var at: Vector2 = to_graph(at_position)
	var node: BrickscriptFlowNode = Ops.add_node(context.graph, data[DRAG_KEY], at)
	if node == null:
		return
	# Dropped on a frame (or just outside its edge, FRAME_DROP_ROOM): it joins
	# the smallest one there, which grows to fit it.
	var into: Dictionary = {}
	var smallest: float = INF
	for frame_view: GraphFrame in frame_views():
		var area: Rect2 = Rect2(frame_view.position_offset, frame_view.size)
		if area.grow(FRAME_DROP_ROOM).has_point(at) and area.get_area() < smallest:
			smallest = area.get_area()
			into = Ops.frame_by_id(context.graph, int(String(frame_view.name)))
	if not into.is_empty():
		Ops.attach_to_frame(context.graph, into, node.id)
	context.select(node.id)
	context.notify_changed(Context.Redraw.ALL, "Add node")

#endregion


#region Wires and edits

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	var from_view: FlowGraphNode = get_node_or_null(NodePath(String(from_node))) as FlowGraphNode
	var to_view: FlowGraphNode = get_node_or_null(NodePath(String(to_node))) as FlowGraphNode
	if from_view == null or to_view == null or from_port >= from_view.exit_names.size():
		return
	if Ops.connect_exit(context.graph, from_view.node, from_view.exit_names[from_port], to_view.node):
		context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Connect")


func _on_disconnection_request(from_node: StringName, from_port: int, _to_node: StringName, _to_port: int) -> void:
	var from_view: FlowGraphNode = get_node_or_null(NodePath(String(from_node))) as FlowGraphNode
	if from_view != null and from_port < from_view.exit_names.size() and Ops.disconnect_exit(from_view.node, from_view.exit_names[from_port]):
		context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Disconnect")


func _on_delete_nodes_request(names: Array[StringName]) -> void:
	var doomed: Array[FlowGraphNode] = []
	for view_name: StringName in names:
		var view: FlowGraphNode = get_node_or_null(NodePath(String(view_name))) as FlowGraphNode
		if view != null:
			doomed.append(view)
	if _on_delete_nodes_request_frames(names) and doomed.is_empty():
		context.notify_changed(Context.Redraw.ALL, "Delete frame")
		return
	_delete_views(doomed, "Delete nodes")


func _on_delete_nodes_request_frames(names: Array[StringName]) -> bool:
	var deleted: bool = false
	for view_name: StringName in names:
		var frame: Dictionary = Ops.frame_by_id(context.graph, int(String(view_name)))
		if not frame.is_empty() and Ops.delete_frame(context.graph, frame):
			deleted = true
			if frame["id"] == context.selected:
				context.select(0)
	return deleted


func _delete_views(doomed: Array[FlowGraphNode], action: String) -> void:
	var deleted: bool = false
	for view: FlowGraphNode in doomed:
		if Ops.delete_node(context.graph, view.node):
			deleted = true
			if view.node.id == context.selected:
				context.select(0)
	if deleted:
		context.notify_changed(Context.Redraw.ALL, action)


## Bricks dragged without their frame are let go of for the drag, so the
## frame doesn't grow after them (Godot grows a frame around its attached
## bricks as they move). Node id -> the frame's id.
var _dragged_out: Dictionary[int, int] = {}


func _on_begin_node_move() -> void:
	_dragged_out.clear()
	for view: FlowGraphNode in _selected_views():
		for frame: Dictionary in context.graph.frames:
			if not frame["nodes"].has(view.node.id):
				continue
			var frame_view: GraphFrame = get_node_or_null(NodePath(str(frame["id"]))) as GraphFrame
			if frame_view != null and not frame_view.selected:
				_dragged_out[view.node.id] = frame["id"]
				detach_graph_element_from_frame(view.name)


func _on_end_node_move() -> void:
	for view: FlowGraphNode in views():
		Ops.set_position(view.node, view.position_offset)
		view.position_offset = view.node.position
	# A frame that was moved is where it was dropped (before it's fitted, so
	# a resized one doesn't stretch from where it was to where it is).
	for frame_view: GraphFrame in frame_views():
		var frame: Dictionary = Ops.frame_by_id(context.graph, int(String(frame_view.name)))
		if not frame.is_empty() and Ops.snap(frame_view.position_offset) != frame["position"]:
			Ops.set_frame(frame, "position", frame_view.position_offset)
	# Bricks dragged out of their frame: back in if dropped inside it, else
	# they leave it.
	var left: bool = false
	for id: int in _dragged_out:
		var frame: Dictionary = Ops.frame_by_id(context.graph, _dragged_out[id])
		var node_view: FlowGraphNode = view_of(id)
		if frame.is_empty() or node_view == null:
			continue
		var middle: Vector2 = node_view.position_offset + node_view.size / 2.0
		# The frame as drawn (its stored rect is only kept once it's been
		# moved, resized or fitted after a change).
		var frame_view: GraphFrame = get_node_or_null(NodePath(str(frame["id"]))) as GraphFrame
		var area: Rect2 = Rect2(frame_view.position_offset, frame_view.size) if frame_view != null else Rect2(frame["position"], frame["size"])
		if area.grow(FRAME_DROP_ROOM).has_point(middle):
			attach_graph_element_to_frame(node_view.name, StringName(str(frame["id"])))
		elif Ops.detach_from_frame(frame, id):
			left = true
	_dragged_out.clear()
	_fit_frames()
	_store_frames()
	context.notify_changed(Context.Redraw.NONE, "Move nodes" if not left else "Move nodes out of a frame")


## Fits the frames once at the end of this frame (many bricks may resize).
func _queue_fit() -> void:
	if _fit_queued:
		return
	_fit_queued = true
	(func() -> void:
		_fit_queued = false
		if is_inside_tree():
			_fit_frames()).call_deferred()


## Frames holding nodes wrap them: their bounding box plus FRAME_PADDING
## (the title band and FRAME_PADDING on top), on the grid. A frame the user resized ("fit"
## off) keeps its size, only growing so its nodes stay inside.
func _fit_frames() -> void:
	for view: GraphFrame in frame_views():
		var frame: Dictionary = Ops.frame_by_id(context.graph, int(String(view.name)))
		var bounds: Rect2 = Rect2()
		for id: int in frame.get("nodes", []):
			var node_view: FlowGraphNode = view_of(id)
			if node_view != null:
				var rect: Rect2 = Rect2(node_view.position_offset, node_view.size)
				bounds = rect if bounds.size == Vector2.ZERO else bounds.merge(rect)
		if bounds.size == Vector2.ZERO:
			continue
		# The width first (the bricks', or the size the user gave it): a long
		# title wraps to it, and the frame grows upward to fit its lines.
		var width: float = Ops.snap_up(bounds.size + FRAME_PADDING * 2.0).x
		if not frame.get("fit", true):
			width = maxf(width, (frame["size"] as Vector2).x)
		var room: float = _title_room(view, width)
		var top_left: Vector2 = Ops.snap(bounds.position - Vector2(FRAME_PADDING.x, room))
		var needed: Rect2 = Rect2(top_left, Ops.snap_up(bounds.end + FRAME_PADDING - top_left))
		if not frame.get("fit", true):
			# From its stored size (not the view's: right after a redraw the
			# nodes' sizes aren't settled yet, and it mustn't keep that growth).
			needed = needed.merge(Rect2(frame["position"], frame["size"]))
		needed.size = Ops.snap_up(needed.size.max(Vector2(0.0, room + FRAME_PADDING.y)))
		view.position_offset = needed.position
		view.size = needed.size
		_shrink_title_bar(view)


## The room above a frame's bricks at `width`: its title band and
## FRAME_PADDING under it.
func _title_room(view: GraphFrame, width: float) -> float:
	return _band_height(view, width) + FRAME_PADDING.y


## The title band's height at `width`: the wrapped title and its margins,
## rounded up to whole grid squares (one more for each line it wraps to).
func _band_height(view: GraphFrame, width: float) -> float:
	var label: Label = _title_label(view)
	var text_height: float = 0.0
	if label != null:
		var font: Font = label.get_theme_font(&"font")
		var font_size: int = label.get_theme_font_size(&"font_size")
		text_height = font.get_height(font_size)
		if not view.title.is_empty():
			text_height = maxf(text_height, font.get_multiline_string_size(view.title, HORIZONTAL_ALIGNMENT_LEFT, maxf(width - FRAME_BAND_MARGINS.x * 2.0, 32.0), font_size).y)
	return Ops.snap_up(Vector2(0.0, text_height + FRAME_BAND_MARGINS.y * 2.0)).y


## The title bar at its band's height (a container doesn't shrink by itself:
## laid out narrower once, it would stay that tall).
func _shrink_title_bar(view: GraphFrame) -> void:
	var bar: HBoxContainer = view.get_titlebar_hbox()
	bar.custom_minimum_size.y = _band_height(view, view.size.x) - FRAME_BAND_MARGINS.y * 2.0
	bar.size = Vector2(bar.size.x, 0.0)
	# (The frame draws its title bar from the bar's size: again, at the new one.)
	view.queue_redraw()


## The title band: the frame's color, darker, with a line under it (lighter
## when the frame is selected).
static func _band_style(color: Color, selected: bool) -> StyleBoxFlat:
	var band: StyleBoxFlat = StyleBoxFlat.new()
	band.bg_color = Color(color.darkened(0.55), 1.0)
	band.border_color = Color(color.lightened(0.55 if selected else 0.25), 1.0)
	band.border_width_bottom = 2
	band.corner_radius_top_left = 4
	band.corner_radius_top_right = 4
	band.content_margin_left = FRAME_BAND_MARGINS.x
	band.content_margin_right = FRAME_BAND_MARGINS.x
	band.content_margin_top = FRAME_BAND_MARGINS.y
	band.content_margin_bottom = FRAME_BAND_MARGINS.y
	return band


## A frame's title text (the Label in its title bar).
func _title_label(view: GraphFrame) -> Label:
	for child: Node in view.get_titlebar_hbox().get_children():
		if child is Label:
			return child as Label
	return null


## Keeps what the frames show (moved by the user, or fitted to their nodes).
func _store_frames() -> void:
	for view: GraphFrame in frame_views():
		var frame: Dictionary = Ops.frame_by_id(context.graph, int(String(view.name)))
		if not frame.is_empty():
			Ops.set_frame(frame, "position", view.position_offset)
			Ops.set_frame(frame, "size", view.size)


func _on_linked_to_frame(elements: Array, frame_name: StringName) -> void:
	var frame: Dictionary = Ops.frame_by_id(context.graph, int(String(frame_name)))
	var attached: bool = false
	for element: Variant in elements:
		if not frame.is_empty() and Ops.attach_to_frame(context.graph, frame, int(String(element))):
			# Hooked up here, not by redrawing the canvas: a redraw makes every
			# brick again, and a frame mustn't change any brick.
			if get_element_frame(StringName(element)) != null:
				detach_graph_element_from_frame(StringName(element))
			attach_graph_element_to_frame(StringName(element), frame_name)
			attached = true
	if attached:
		_fit_frames()
		_store_frames()
		context.notify_changed(Context.Redraw.PROPERTIES, "Add to frame")


func _frame_view(frame: Dictionary) -> GraphFrame:
	var view: GraphFrame = GraphFrame.new()
	view.name = str(frame["id"])
	view.title = frame["title"]
	view.position_offset = frame["position"]
	view.size = frame["size"]
	view.tint_color_enabled = true
	view.tint_color = Color(frame["color"], 0.45)
	view.add_theme_stylebox_override(&"titlebar", _band_style(frame["color"], false))
	view.add_theme_stylebox_override(&"titlebar_selected", _band_style(frame["color"], true))
	# Sized here (_fit_frames) instead of Godot's autoshrink, which counts the
	# title bar's theme-dependent height and leaves edges between grid lines.
	view.autoshrink_enabled = false
	# GraphEdit still keeps this much room around attached nodes; match ours.
	view.autoshrink_margin = int(FRAME_PADDING.x)
	view.resizable = true
	view.selected = frame["id"] == context.selected
	view.tooltip_text = "Comment frame: drop nodes on it to group them; they move with it."
	# A long title wraps (the frame grows a line taller each time, see
	# _title_room) instead of making the frame wider than its bricks.
	var title_label: Label = _title_label(view)
	if title_label != null:
		title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title_label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	# GraphEdit won't let a frame's corner go inside its bricks, which locked
	# shrinking it. Deferred, so it runs after GraphEdit's clamp and wins:
	# bricks left (mostly) outside leave it on resize_end.
	view.resize_request.connect(func(new_size: Vector2) -> void:
		view.size = Ops.snap_up(new_size.max(Vector2(64.0, _title_room(view, new_size.x) + FRAME_PADDING.y)))
		_shrink_title_bar(view), CONNECT_DEFERRED)
	view.resize_end.connect(func(_new_size: Vector2) -> void:
		# Resized by hand: it keeps this size from now on (Fit to its bricks
		# in Properties fits it again). Bricks it no longer covers (their
		# middle outside) leave it, so it doesn't grow back around them.
		view.size = Ops.snap_up(view.size)
		var changed: bool = Ops.set_frame(frame, "fit", false)
		changed = Ops.set_frame(frame, "position", view.position_offset) or changed
		changed = Ops.set_frame(frame, "size", view.size) or changed
		var area: Rect2 = Rect2(view.position_offset, view.size)
		for id: int in frame["nodes"].duplicate():
			var node_view: FlowGraphNode = view_of(id)
			if node_view != null and not area.has_point(node_view.position_offset + node_view.size / 2.0):
				Ops.detach_from_frame(frame, id)
				detach_graph_element_from_frame(node_view.name)
				changed = true
		# Bricks in no frame that it now covers (their middle inside) join it.
		# Another frame's bricks stay with that frame.
		var framed: Dictionary[int, bool] = {}
		for other: Dictionary in context.graph.frames:
			for id: Variant in other["nodes"]:
				framed[int(id)] = true
		for node_view: FlowGraphNode in views():
			if not framed.has(node_view.node.id) and area.has_point(node_view.position_offset + node_view.size / 2.0):
				Ops.attach_to_frame(context.graph, frame, node_view.node.id)
				attach_graph_element_to_frame(node_view.name, view.name)
				changed = true
		# It still grows to keep the bricks it holds in (with padding); saved
		# as shown.
		_fit_frames()
		_store_frames()
		if changed:
			# Not a canvas redraw: resizing a frame never touches its bricks.
			context.notify_changed(Context.Redraw.PROPERTIES, "Resize frame"))
	return view


## A node dragged by its corner keeps that size (whole grid squares).
func _on_resize_end(_new_size: Vector2, view: FlowGraphNode) -> void:
	if Ops.set_size(view.node, view.size):
		view.fit()
		# GraphEdit only grows the brick's frame; a fitted one shrinks too.
		_fit_frames()
		_store_frames()
		context.notify_changed(Context.Redraw.PROPERTIES, "Resize node")


## Each brick's drawn size, by id (for Ops.arranged_x()).
func brick_sizes() -> Dictionary:
	var sizes: Dictionary = {}
	for view: FlowGraphNode in views():
		sizes[view.node.id] = view.size
	return sizes


## Toolbar Arrange: the selected bricks' chains (all when none is selected)
## spaced two grid squares apart (Ops.arrange()); one undo step.
func arrange_chains() -> void:
	var only: Array = _selected_views().map(func(view: FlowGraphNode) -> int: return view.node.id)
	if Ops.arrange(context.graph, brick_sizes(), only):
		context.notify_changed(Context.Redraw.ALL, "Arrange")


func _selected_views() -> Array[FlowGraphNode]:
	var result: Array[FlowGraphNode] = []
	for view: FlowGraphNode in views():
		if view.selected:
			result.append(view)
	return result

#endregion


#region Add menu

## Toolbar: a comment frame around the selected nodes, or in the middle of
## the view.
func add_frame_here() -> void:
	_add_at = to_graph(size / 2.0) - Ops.FRAME_SIZE / 2.0
	_add_frame()


## A comment frame where the menu was opened, or around the selected nodes.
func _add_frame() -> void:
	var selected: Array[FlowGraphNode] = _selected_views()
	var at: Vector2 = _add_at
	var ids: Array = []
	if not selected.is_empty():
		for view: FlowGraphNode in selected:
			ids.append(view.node.id)
	var frame: Dictionary = Ops.add_frame(context.graph, at, ids)
	context.select(frame["id"])
	context.notify_changed(Context.Redraw.ALL, "Add frame")

func _open_add_menu(at: Vector2, wire: Array) -> void:
	_add_at = to_graph(at)
	_add_wire = wire
	_add_menu.clear()
	_add_menu_types.clear()
	if wire.is_empty():
		var wrapping: int = _selected_views().size()
		_add_menu.add_item("Comment frame" if wrapping == 0 else "Comment frame around %d selected node(s)" % wrapping, FRAME_ITEM)
	for category: String in BrickTheme.CATEGORY_ORDER:
		var first: bool = true
		for type: StringName in Library.NODES:
			var definition: Dictionary = Library.NODES[type]
			if definition["category"] != category or not Library.listed(type, context.can_use) or (not wire.is_empty() and definition["kind"] != Library.Kind.ACTION):
				continue
			if first:
				_add_menu.add_separator(BrickTheme.CATEGORY_TITLES[category])
				first = false
			# A brick family: one item (its first usable member).
			_add_menu.add_item(Library.listed_title(type), _add_menu_types.size())
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
	var node: BrickscriptFlowNode = Ops.add_node(context.graph, _add_menu_types[id], _add_at)
	if node == null:
		return
	if not _add_wire.is_empty():
		var from: BrickscriptFlowNode = context.graph.node_by_id(_add_wire[0])
		Ops.connect_exit(context.graph, from, _add_wire[1], node)
		# Two grid squares after the brick it follows; on its row when dropped
		# beside it, else on the row it was dropped on (a branch).
		var from_view: FlowGraphNode = view_of(from.id)
		if from_view != null:
			node.position.x = Ops.snap_up(Vector2(from.position.x + from_view.size.x, 0)).x + Ops.CHAIN_GAP
			if absf(node.position.y - from.position.y) < from_view.size.y / 2.0:
				node.position.y = from.position.y
	context.select(node.id)
	context.notify_changed(Context.Redraw.ALL, "Add node")

#endregion
