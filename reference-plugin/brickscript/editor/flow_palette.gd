@tool
extends VBoxContainer

## Left sidebar of the wire editor: a search box over every node, category
## buttons that jump to their section, and one entry per node type the open
## graph can use (its context's bricks; network ones with the Network Context
## Engine). Click an
## entry to see what it does in Properties; drag it onto the canvas, or
## double-click it, to add it.

const Context = preload("flow_context.gd")
const Library = preload("../core/flow_library.gd")
const BrickTheme = preload("brick_theme.gd")
const Canvas = preload("flow_canvas.gd")
const Ops = preload("../core/flow_ops.gd")
const FlowGraphNode = preload("flow_graph_node.gd")
## How see-through a dragged brick's ghost is.
const GHOST_ALPHA: float = 0.6
const SERVER_COLOR: Color = Color(1.0, 0.62, 0.3)
const LOCAL_COLOR: Color = Color(0.55, 0.82, 1.0)

## A node type was double-clicked (add it in view).
signal add_requested(type: StringName)

var context: Context = null
## The canvas bricks are dropped on (its zoom sizes the drag ghost).
var canvas: GraphEdit = null

## What the bricks are for: local or server (tinted), at the top.
var _context_label: Label = null
var _search: LineEdit = null
var _categories: VBoxContainer = null
var _scroll: ScrollContainer = null
var _list: VBoxContainer = null
var _headers: Dictionary[String, Control] = {}


func _init() -> void:
	custom_minimum_size.x = 230
	_context_label = Label.new()
	_context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_context_label)
	_search = LineEdit.new()
	_search.placeholder_text = "Search all nodes"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_typed: String) -> void: _refill())
	add_child(_search)
	var columns: HBoxContainer = HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(columns)
	_categories = VBoxContainer.new()
	_categories.custom_minimum_size.x = 76
	columns.add_child(_categories)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	columns.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override(&"separation", 4)
	_scroll.add_child(_list)


func rebuild() -> void:
	_search.right_icon = context.brick_theme.icon(&"Search")
	var server: bool = context.graph != null and context.graph.context == &"server"
	_context_label.text = "Server bricks: this brickscript runs only on the server." if server else "Local bricks: this brickscript runs on every machine."
	if context.graph != null and context.graph.shared:
		_context_label.text = "Shared, Server only: functions server brickscripts call (server bricks allowed)." if server \
			else "Shared, Used by Both: functions any brickscript calls (only bricks that work on either side)."
	if not context.network_available:
		_context_label.text += " (Network bricks need the Network Context Engine.)"
	_context_label.add_theme_color_override(&"font_color", SERVER_COLOR if server else LOCAL_COLOR)
	for child: Node in _categories.get_children():
		_categories.remove_child(child)
		child.queue_free()
	for category: String in BrickTheme.CATEGORY_ORDER:
		if not _category_used(category):
			continue
		var button: Button = Button.new()
		button.text = BrickTheme.CATEGORY_TITLES[category]
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_color_override(&"font_color", context.brick_theme.category_color(category))
		button.pressed.connect(_show_category.bind(category))
		_categories.add_child(button)
	_refill()


## The entries shown, in order (for tests).
func entries() -> Array[Button]:
	var result: Array[Button] = []
	for child: Node in _list.get_children():
		if child is Button and not child.is_queued_for_deletion():
			result.append(child)
	return result


func _refill() -> void:
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_headers.clear()
	var query: String = _search.text.strip_edges().to_lower()
	var shown: int = 0
	for category: String in BrickTheme.CATEGORY_ORDER:
		var types: Array[StringName] = []
		for type: StringName in Library.NODES:
			var definition: Dictionary = Library.NODES[type]
			# A brick family is one entry (its first usable member), found by
			# its members' names too.
			var haystack: String = "%s %s" % [Library.search_text(type), BrickTheme.CATEGORY_TITLES[category]]
			if definition["category"] == category and Library.listed(type, context.can_use) and (query.is_empty() or haystack.to_lower().contains(query)):
				types.append(type)
		if types.is_empty():
			continue
		var header: Label = Label.new()
		header.text = BrickTheme.CATEGORY_TITLES[category]
		header.add_theme_color_override(&"font_color", context.brick_theme.category_color(category))
		_list.add_child(header)
		_headers[category] = header
		for type: StringName in types:
			_list.add_child(_entry(type, context.brick_theme.category_color(category)))
			shown += 1
	if shown == 0:
		var none: Label = Label.new()
		none.text = "No nodes match \"%s\"." % _search.text
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(none)


func _category_used(category: String) -> bool:
	for type: StringName in Library.NODES:
		if Library.NODES[type]["category"] == category and context.can_use(type):
			return true
	return false


func _entry(type: StringName, color: Color) -> Button:
	var button: Button = Button.new()
	button.text = Library.listed_title(type)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var family: StringName = Library.family_of(type)
	var description: String = Library.FAMILIES[family]["description"] if family != &"" else Library.NODES[type].get("description", "")
	button.tooltip_text = "%s\n\nClick for details. Drag onto the canvas, or double-click, to add it." % description
	button.pressed.connect(context.show_info.bind(type))
	button.mouse_default_cursor_shape = Control.CURSOR_DRAG
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus"]:
		var style: StyleBoxFlat = StyleBoxFlat.new()
		style.bg_color = context.brick_theme.background().lerp(color, 0.32 if state == &"hover" else 0.2)
		style.border_color = color
		style.border_width_left = 4
		style.set_corner_radius_all(4)
		style.content_margin_left = 10
		style.content_margin_right = 8
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		button.add_theme_stylebox_override(state, style)
	button.set_drag_forwarding(func(_at: Vector2) -> Variant:
		button.set_drag_preview(_ghost(type))
		return {Canvas.DRAG_KEY: type}, Callable(), Callable())
	button.gui_input.connect(func(event: InputEvent) -> void:
		var click: InputEventMouseButton = event as InputEventMouseButton
		if click != null and click.double_click and click.button_index == MOUSE_BUTTON_LEFT:
			add_requested.emit(type))
	return button


func _show_category(category: String) -> void:
	if not _search.text.is_empty():
		_search.text = ""
		_refill()
	_scroll_to.call_deferred(category)


func _scroll_to(category: String) -> void:
	var header: Control = _headers.get(category, null)
	if header != null:
		_scroll.scroll_vertical = int(header.position.y)


## What a drag from the palette shows: the brick it adds, as it will look
## (its defaults, for the open graph), see-through and at the canvas's zoom.
## Its top-left corner is at the mouse: where the brick lands.
func _ghost(type: StringName) -> Control:
	var scratch: BrickscriptFlowGraph = BrickscriptFlowGraph.new()
	if context.graph != null:
		scratch.context = context.graph.context
		scratch.script_node = context.graph.script_node
		scratch.shared = context.graph.shared
	var brick: FlowGraphNode = FlowGraphNode.new()
	brick.setup(Ops.add_node(scratch, type, Vector2.ZERO), context)
	brick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ghost: Control = Control.new()
	ghost.modulate.a = GHOST_ALPHA
	ghost.scale = Vector2.ONE * (canvas.zoom if canvas != null else 1.0)
	ghost.add_child(brick)
	return ghost
