extends VBoxContainer
## Left sidebar (after Brickscript's flow_palette.gd): a search box over every
## brick, category buttons that jump to their section, and one entry per brick.
## Click an entry to see what it does in Properties; drag it onto the canvas,
## or double-click it, to add it.

const Context = preload("res://scripts/editor/context.gd")
const BrickTheme = preload("res://scripts/editor/brick_theme.gd")
const BrickView = preload("res://scripts/editor/brick_view.gd")
const T = preload("res://scripts/node_defs.gd")

const GHOST_ALPHA: float = 0.6
const DRAG_KEY: String = "cbricks_brick"

signal add_requested(type: String)

var context: Context = null
var canvas: GraphEdit = null

var _context_label: Label = null
var _search: LineEdit = null
var _categories: VBoxContainer = null
var _cat_scroll: ScrollContainer = null
var _scroll: ScrollContainer = null
var _list: VBoxContainer = null
var _headers: Dictionary = {}


func _init() -> void:
	custom_minimum_size.x = 0
	_context_label = Label.new()
	_context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_context_label)
	_search = LineEdit.new()
	_search.placeholder_text = "Search all bricks"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _refill())
	add_child(_search)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(columns)
	# The category buttons scroll too: unscrolled, their height was the
	# palette's minimum and pushed the bottom panel (Console) off the window.
	var cat_scroll := ScrollContainer.new()
	cat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cat_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	cat_scroll.custom_minimum_size.x = 62
	columns.add_child(cat_scroll)
	_cat_scroll = cat_scroll
	resized.connect(_fit_categories)
	_categories = VBoxContainer.new()
	_categories.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat_scroll.add_child(_categories)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	columns.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override(&"separation", 4)
	_scroll.add_child(_list)


func rebuild() -> void:
	_search.right_icon = context.brick_theme.icon("search")
	_context_label.text = "C bricks: they become one C99 file, built for %s." % Toolchains.target(context.target_id).name
	_context_label.add_theme_color_override(&"font_color", BrickTheme.LOCAL_COLOR)
	for child in _categories.get_children():
		_categories.remove_child(child)
		child.queue_free()
	for category in BrickTheme.CATEGORY_ORDER:
		var button := Button.new()
		button.text = BrickTheme.CATEGORY_SHORT.get(category, BrickTheme.CATEGORY_TITLES[category])
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.tooltip_text = BrickTheme.CATEGORY_TITLES[category]
		button.add_theme_color_override(&"font_color", context.brick_theme.category_color(category))
		button.add_theme_color_override(&"font_hover_color", context.brick_theme.category_color(category).lightened(0.3))
		button.pressed.connect(_show_category.bind(category))
		_categories.add_child(button)
	_fit_categories.call_deferred()
	_refill()


## The category column as wide as its longest name; in a narrow palette it gives
## way (the brick list keeps 110 px, the column at least 62) and the names clip with "…".
func _fit_categories() -> void:
	if _cat_scroll == null or _categories.get_child_count() == 0:
		return
	var widest := 0.0
	for b in _categories.get_children():
		var btn := b as Button
		var font := btn.get_theme_font(&"font")
		var size := btn.get_theme_font_size(&"font_size")
		widest = maxf(widest, font.get_string_size(btn.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	var want := widest + 18.0  # the button's padding
	# Leave the brick list at least 110 px: the column never holds the panel open.
	_cat_scroll.custom_minimum_size.x = clampf(size.x - 110.0, 62.0, maxf(62.0, want))


func _refill() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_headers.clear()
	var query := _search.text.strip_edges().to_lower()
	var shown := 0
	for category in BrickTheme.CATEGORY_ORDER:
		var types := []
		for type in T.DEFS:
			var def: Dictionary = T.DEFS[type]
			var hay := "%s %s %s %s" % [def.title, type, BrickTheme.CATEGORY_TITLES[category], " ".join(def.get("mode_titles", {}).values())]
			if def.cat == category and (query.is_empty() or hay.to_lower().contains(query)):
				types.append(type)
		if types.is_empty():
			continue
		var header := Label.new()
		header.text = BrickTheme.CATEGORY_TITLES[category]
		header.clip_text = true
		header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		header.add_theme_color_override(&"font_color", context.brick_theme.category_color(category))
		_list.add_child(header)
		_headers[category] = header
		for type in types:
			_list.add_child(_entry(type, context.brick_theme.category_color(category)))
			shown += 1
	if shown == 0:
		var none := Label.new()
		none.text = "No bricks match \"%s\"." % _search.text
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(none)


func _entry(type: String, color: Color) -> Button:
	var def: Dictionary = T.DEFS[type]
	var button := Button.new()
	button.text = def.title
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.disabled = not context.can_use(type)
	button.tooltip_text = "%s\n\nClick for details. Drag onto the canvas, or double-click, to add it." % def.get("desc", "")
	var blocked := context.blocked(type)
	if blocked != "":
		button.tooltip_text = "%s\n\nNot here: %s" % [def.get("desc", ""), blocked]
		button.add_theme_color_override(&"font_disabled_color", Color(context.brick_theme.brick_text_color(), 0.35))
	elif button.disabled:
		button.tooltip_text = "There is one already: a program has only one %s." % def.title
	button.pressed.connect(context.show_info.bind(type))
	button.mouse_default_cursor_shape = Control.CURSOR_DRAG
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus", &"disabled"]:
		var style := StyleBoxFlat.new()
		var c := color if blocked == "" else BrickView.MISPLACED_GREY
		style.bg_color = context.brick_theme.background().lerp(c, 0.32 if state == &"hover" else 0.12 if state == &"disabled" else 0.2)
		style.border_color = c if state != &"disabled" else Color(c, 0.4)
		style.border_width_left = 4
		style.set_corner_radius_all(4)
		style.content_margin_left = 10
		style.content_margin_right = 8
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		button.add_theme_stylebox_override(state, style)
	button.add_theme_color_override(&"font_color", context.brick_theme.brick_text_color())
	button.set_drag_forwarding(func(_at: Vector2) -> Variant:
		if not context.can_use(type):
			return null
		button.set_drag_preview(_ghost(type))
		return {DRAG_KEY: type}, Callable(), Callable())
	button.gui_input.connect(func(event: InputEvent) -> void:
		var click := event as InputEventMouseButton
		if click != null and click.double_click and click.button_index == MOUSE_BUTTON_LEFT and context.can_use(type):
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


## The brick a drag adds, as it will look, see-through, at the canvas's zoom.
func _ghost(type: String) -> Control:
	var scratch := {"nodes": [], "frames": [], "next_id": 1}
	for n in context.graph.nodes:
		if n.type == "function":
			scratch.nodes.append(n)
	var node := Ops.add_node(scratch, type, Vector2.ZERO)
	var brick := BrickView.new()
	var ctx := Context.new()
	ctx.graph = scratch
	brick.setup(node, ctx)
	brick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ghost := Control.new()
	ghost.modulate.a = GHOST_ALPHA
	ghost.scale = Vector2.ONE * (canvas.zoom if canvas != null else 1.0)
	ghost.add_child(brick)
	return ghost
