@tool
extends GraphNode

## One node of a wire graph on the canvas. The top rows carry the exec ports:
## the input on the left of the first row (not on events), one exit per row on
## the right (events: their numbered outputs plus a spare; If: True / False).
## Below them, a read-only summary of its settings, inputs and output; editing
## happens in the Properties panel.
##
## Its position and size are whole grid squares, so edges line up with the
## grid. It fits its content unless the user dragged its corner to make it
## bigger (saved in BrickscriptFlowNode.size).

const Context = preload("flow_context.gd")
const Library = preload("../core/flow_library.gd")
const Ops = preload("../core/flow_ops.gd")
const Types = preload("../core/flow_types.gd")
const NodeTypes = preload("../core/node_types.gd")
const ValueEditor = preload("flow_value_editor.gd")
const FlowCompiler = preload("../core/flow_compiler.gd")

const EXEC_PORT: int = 0
const EXEC_COLOR: Color = Color(0.92, 0.92, 0.92)
const MIN_WIDTH: float = 176.0
## Brick text: a bit bigger than the editor's, with a thin dark outline so it
## reads on any fill and when zoomed out.
const TEXT_SIZE: int = 15
const TITLE_SIZE: int = 15
const OUTLINE_COLOR: Color = Color(0, 0, 0, 0.55)
const OUTLINE_SIZE: int = 3
const RUNTIME_ERROR_COLOR: Color = Color(1.0, 0.3, 0.3)
## Trace: how a brick that just ran lights up, and how long it fades.
const FLASH_COLOR: Color = Color(1.6, 1.6, 1.1)
const FLASH_TIME: float = 0.5

var node: BrickscriptFlowNode = null
var _text_color: Color = Color.WHITE
var _flash: Tween = null
## Its corner is being dragged.
var _resizing: bool = false
## Right-side port index -> exit name.
var exit_names: Array[StringName] = []


func setup(flow_node: BrickscriptFlowNode, context: Context) -> void:
	node = flow_node
	name = str(node.id)
	position_offset = Ops.snap(node.position)
	custom_minimum_size.x = MIN_WIDTH
	resizable = true
	# Deferred: GraphEdit's own handler runs after ours and rounds to the grid
	# before clamping to the content, which can leave it between grid lines.
	resize_request.connect(func(new_size: Vector2) -> void:
		_resizing = true
		size = Ops.snap_up(new_size.max(get_combined_minimum_size())), CONNECT_DEFERRED)
	resize_end.connect(func(_new_size: Vector2) -> void: _resizing = false)
	var definition: Dictionary = Library.get_definition(node.type)
	title = definition.get("title", String(node.type))
	tooltip_text = "Click to edit in Properties. Drag from a ▶ port to wire what runs next."
	_style(context.brick_theme.category_color(definition.get("category", "")), context)
	if context.runtime_bricks.has(node.id):
		_mark_runtime_error(context.runtime_bricks[node.id])
	var event: bool = Ops.is_event(node)
	# Constant / Export declare a variable before the game starts: no ports.
	var has_input: bool = not event and not Ops.is_declaration(node)
	exit_names = Ops.exits_for(node)
	if node.type == &"reroute":
		_setup_reroute(context)
		return
	var rows: int = maxi(1, exit_names.size()) if has_input or not exit_names.is_empty() else 0
	for row: int in rows:
		var exit: StringName = exit_names[row] if row < exit_names.size() else &""
		add_child(_port_row("▶" if row == 0 and has_input else "", _exit_label(exit, event)))
		set_slot(row, row == 0 and has_input, EXEC_PORT, EXEC_COLOR, row < exit_names.size(), EXEC_PORT, EXEC_COLOR)
	_text_color = context.brick_theme.brick_text_color()
	for row: Node in get_children():
		for label: Node in row.get_children():
			_readable(label as Label)
	for line: String in summary(node):
		var label: Label = Label.new()
		label.text = line
		_readable(label)
		add_child(label)
	var title_label: Label = get_titlebar_hbox().get_child(0) as Label if get_titlebar_hbox().get_child_count() > 0 else null
	if title_label != null:
		_readable(title_label, TITLE_SIZE)
	# The content's size is only known once the theme applies, and text can
	# grow it later; whenever it ends up between grid lines, snap it again.
	ready.connect(fit)
	minimum_size_changed.connect(_snap_size)
	resized.connect(func() -> void:
		if size != Ops.snap_up(size):
			_snap_size.call_deferred())


## A reroute point: a small dot with a way in and a way out, nothing else.
func _setup_reroute(context: Context) -> void:
	title = ""
	resizable = false
	custom_minimum_size = Vector2.ZERO
	tooltip_text = "A reroute point: it only bends the wire. Drag it; delete it to straighten the wire."
	var dot: Label = Label.new()
	dot.text = "●"
	dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text_color = context.brick_theme.brick_text_color()
	_readable(dot)
	add_child(dot)
	set_slot(0, true, EXEC_PORT, EXEC_COLOR, true, EXEC_PORT, EXEC_COLOR)
	ready.connect(func() -> void: size = Ops.snap_up(get_combined_minimum_size()))


## Sizes the node to its saved size, or its content, in whole grid squares.
func fit() -> void:
	size = Ops.snap_up(node.size.max(get_combined_minimum_size()))


## Snaps to whole grid squares. A brick never resized by hand follows its
## content (also shrinking: its text may be shorter now, or the theme was
## still settling when it was made); one being dragged or resized by hand
## keeps its size.
func _snap_size() -> void:
	var kept: Vector2 = size if _resizing or node.size != Vector2.ZERO else Vector2.ZERO
	size = Ops.snap_up(kept.max(get_combined_minimum_size()))

## Read-only lines describing the node: settings, inputs, output.
static func summary(flow_node: BrickscriptFlowNode) -> PackedStringArray:
	var lines: PackedStringArray = []
	var definition: Dictionary = Library.get_definition(flow_node.type)
	# Inputs the first line already shows (not listed again below it).
	var shown: Array[StringName] = []
	match flow_node.type:
		&"constant", &"export":
			lines.append("%s = %s" % [flow_node.settings.get(&"name", "?"), describe_input(flow_node, &"value")])
			return lines
		&"for_each", &"for_each_pair", &"repeat":
			var made: PackedStringArray = []
			for setting: Dictionary in definition.get("settings", []):
				var made_name: String = str(flow_node.settings.get(setting["name"], ""))
				if not made_name.is_empty():
					made.append(made_name)
			var source: Dictionary = definition["inputs"][0]
			var head: String = "repeat %s times" % describe_input(flow_node, source["name"]) if flow_node.type == &"repeat" \
				else "for each in %s" % describe_input(flow_node, source["name"])
			lines.append(head + ("" if made.is_empty() else " → " + ", ".join(made)))
			return lines
		&"if", &"while":
			var operator: String = str(flow_node.settings.get(&"operator", "is true"))
			var a: String = describe_input(flow_node, &"a")
			var word: String = String(flow_node.type)
			lines.append("%s %s %s %s" % [word, a, operator, describe_input(flow_node, &"b")] if Ops.input_shown(flow_node, &"b") else "%s %s %s" % [word, a, operator])
			return lines
		&"wait":
			lines.append("wait %s s" % describe_input(flow_node, &"seconds"))
			return lines
		&"wait_for_signal":
			lines.append("wait for %s.%s" % [describe_input(flow_node, &"of"), _or_blank(flow_node.settings.get(&"signal", ""))])
			return lines
		&"event_signal":
			var source: String = str(flow_node.settings.get(&"path", ""))
			lines.append("%s.%s" % [Types.path_shown(source) if not source.strip_edges().is_empty() else "Self", _or_blank(flow_node.settings.get(&"signal", ""))])
			return lines
		&"emit_signal":
			var values: PackedStringArray = []
			for spec: Dictionary in Ops.input_specs(flow_node):
				values.append(describe_input(flow_node, spec["name"]))
			lines.append("emit %s(%s)" % [_or_blank(flow_node.settings.get(&"signal", "")), ", ".join(values)])
			return lines
		&"get_node":
			var path: String = str(flow_node.settings.get(&"path", ""))
			var type_text: String = str(flow_node.settings.get(&"node_class", ""))
			lines.append("get %s%s" % [Types.path_shown(path) if not path.strip_edges().is_empty() else "Self", " (%s)" % type_text if not type_text.is_empty() else ""])
		&"set_property" when Library.mode_of(flow_node) == "Get":
			lines.append("%s.%s" % [describe_input(flow_node, &"of"), _or_blank(flow_node.settings.get(&"property", ""))])
			shown = [&"of"]
		&"set_property":
			var operator: String = "+=" if Library.mode_of(flow_node) == "Add" else "="
			lines.append("%s.%s %s %s" % [describe_input(flow_node, &"of"), _or_blank(flow_node.settings.get(&"property", "")), operator, describe_input(flow_node, &"value")])
			return lines
		&"tween_property":
			lines.append("%s.%s → %s" % [describe_input(flow_node, &"of"), _or_blank(flow_node.settings.get(&"property", "")), describe_input(flow_node, &"to")])
			var repeat: String = describe_input(flow_node, &"repeat")
			var rounds: String = " forever" if repeat == "-1" else " x%d" % (int(repeat) + 1) if repeat.is_valid_int() and int(repeat) > 0 else ""
			var reverses: String = describe_input(flow_node, &"reverses")
			lines.append("in %s s, %s %s%s%s" % [describe_input(flow_node, &"seconds"), flow_node.settings.get(&"easing", "Quad"), flow_node.settings.get(&"direction", "Out"),
				", back again" if reverses == "true" else "" if reverses == "false" else ", reverses: " + reverses, rounds])
			return lines
		&"stop_tweens":
			lines.append("stop %s's tweens" % describe_input(flow_node, &"of"))
			return lines
		&"mesh_vertices":
			var what: String = "colors" if str(flow_node.settings.get(&"of", "")) == "Colors" else "points"
			if str(flow_node.settings.get(&"mode", "Get")) == "Get":
				lines.append("%s's %s" % [describe_input(flow_node, &"mesh"), what])
				shown = [&"mesh"]
			else:
				lines.append("%s's %s = %s" % [describe_input(flow_node, &"mesh"), what, describe_input(flow_node, &"value")])
				return lines
		&"call_method":
			var args: PackedStringArray = []
			for spec: Dictionary in Ops.input_specs(flow_node).slice(1):
				args.append(describe_input(flow_node, spec["name"]))
			lines.append("%s.%s(%s)" % [describe_input(flow_node, &"of"), _or_blank(flow_node.settings.get(&"method", "")), ", ".join(args)])
			if not flow_node.output_name.is_empty():
				lines.append("→ %s%s" % ["into " if flow_node.use_var else "", flow_node.output_name])
			return lines
		&"find_node":
			var type_text: String = str(flow_node.settings.get(&"node_class", ""))
			lines.append("find %s in %s%s" % [describe_input(flow_node, &"name"), describe_input(flow_node, &"under"), " (%s)" % type_text if not type_text.is_empty() else ""])
			shown = [&"name", &"under"]
		&"get_root":
			var type_text: String = str(flow_node.settings.get(&"node_class", ""))
			var game: bool = str(flow_node.settings.get(&"root", "")) == Library.ROOT_OF[1]
			lines.append("%s%s" % ["root of the game" if game else "root of %s's scene" % describe_input(flow_node, &"of"), " (%s)" % type_text if not type_text.is_empty() else ""])
			shown = [&"of"]
		&"find_ancestor":
			var type_text: String = str(flow_node.settings.get(&"node_class", ""))
			var name_data: Dictionary = Ops.input_of(flow_node, &"name")
			var named: String = "" if not name_data.has("var") and str(name_data.get("value", "")).is_empty() else " named %s" % describe_input(flow_node, &"name")
			lines.append("first ancestor of %s%s%s" % [describe_input(flow_node, &"of"), named, " (%s)" % type_text if not type_text.is_empty() else ""])
			shown = [&"name", &"of"]
		&"get_children":
			var type_text: String = str(flow_node.settings.get(&"node_class", ""))
			var all: bool = str(flow_node.settings.get(&"search", "")) == "All descendants"
			lines.append("%s of %s%s" % ["all descendants" if all else "children", describe_input(flow_node, &"of"), " (%s)" % type_text if not type_text.is_empty() else ""])
			shown = [&"of"]
		&"as_script":
			var script: String = str(flow_node.settings.get(&"node_script", ""))
			lines.append("%s as %s" % [describe_input(flow_node, &"node"), script.get_file() if not script.is_empty() else "(script?)"])
			shown = [&"node"]
		&"nodes_in_group":
			var type_text: String = str(flow_node.settings.get(&"node_class", ""))
			lines.append("group \"%s\"%s" % [flow_node.settings.get(&"group", ""), " (%s)" % type_text if not type_text.is_empty() else ""])
		&"add_to_group", &"remove_from_group":
			lines.append("%s %s %s \"%s\"" % ["add" if flow_node.type == &"add_to_group" else "remove", describe_input(flow_node, &"node"), "to" if flow_node.type == &"add_to_group" else "from", flow_node.settings.get(&"group", "")])
			return lines
		&"is_in_group":
			lines.append("%s in \"%s\"?" % [describe_input(flow_node, &"node"), flow_node.settings.get(&"group", "")])
			shown = [&"node"]
		&"spawn_scene":
			var scene: String = str(flow_node.settings.get(&"scene", ""))
			lines.append("spawn %s in %s" % [scene.get_file() if not scene.is_empty() else "(scene?)", describe_input(flow_node, &"parent")])
			shown = [&"parent"]
		&"define_function":
			var inputs: PackedStringArray = []
			for param: Array in Ops.function_params(flow_node):
				inputs.append("%s: %s" % [param[0], Types.type_name(param[1])])
			lines.append("function %s(%s)" % [_or_blank(flow_node.settings.get(&"name", "")), ", ".join(inputs)])
			return lines
		&"return_value":
			lines.append("return" if str(flow_node.settings.get(&"gives", "A value")) == "Nothing" else "return %s" % describe_input(flow_node, &"value"))
			return lines
		&"call_function":
			var args: PackedStringArray = []
			for spec: Dictionary in Ops.input_specs(flow_node):
				if spec["name"] != &"node":
					args.append(describe_input(flow_node, spec["name"]))
			var from: String = str(flow_node.settings.get(&"from", ""))
			var file: String = str(flow_node.settings.get(&"file", "")) if from == "A file" else ""
			var prefix: String = file.get_file().get_basename() + ": " if not file.is_empty() else ""
			if from == "A node":
				prefix = describe_input(flow_node, &"node") + "."
			lines.append("%s%s(%s)" % [prefix, _or_blank(flow_node.settings.get(&"function", "")), ", ".join(args)])
			if not flow_node.output_name.is_empty():
				lines.append("→ %s%s" % ["into " if flow_node.use_var else "", flow_node.output_name])
			return lines
		&"formula":
			var expression: String = str(flow_node.settings.get(&"expression", ""))
			lines.append("= " + (expression if not expression.is_empty() else "(type a formula)"))
		&"set_var":
			var target: String = str(flow_node.settings.get(&"name", ""))
			var kind: String = FlowCompiler.set_var_kind(flow_node)
			if Library.mode_of(flow_node) == "Add":
				lines.append("%s += %s" % [target if not target.is_empty() else "(name)", describe_input(flow_node, &"value")])
				return lines
			if Library.mode_of(flow_node) == "Get":
				lines.append("→ %s%s = %s" % ["into " if flow_node.use_var else "", flow_node.output_name if not flow_node.output_name.is_empty() else "(not kept)", target if not target.is_empty() else "(name)"])
				return lines
			var note: String = {"Constant": " (Constant)", "Export": " (Export)", "Chain": " (this run)"}.get(kind, "")
			lines.append("%s ← %s%s" % [target if not target.is_empty() else "(name)", describe_input(flow_node, &"value"), note])
			return lines
	if flow_node.settings.has(&"action"):
		lines.append("action: %s" % flow_node.settings[&"action"])
	if flow_node.settings.has(&"message"):
		lines.append("message: \"%s\"" % flow_node.settings[&"message"])
	if flow_node.settings.has(&"to"):
		lines.append("to: %s" % flow_node.settings[&"to"])
	for spec: Dictionary in Ops.input_specs(flow_node):
		if Ops.input_shown(flow_node, spec["name"]) and not shown.has(spec["name"]):
			lines.append("%s: %s" % [spec["name"], describe_input(flow_node, spec["name"])])
	if Library.node_has_output(flow_node):
		var output: String = flow_node.output_name
		if output.is_empty():
			lines.append("→ (not kept)")
		else:
			lines.append("→ %s%s" % ["into " if flow_node.use_var else "", output])
	return lines


static func _or_blank(text: Variant) -> String:
	return str(text) if not str(text).is_empty() else "(?)"


static func describe_input(flow_node: BrickscriptFlowNode, input: StringName) -> String:
	var data: Dictionary = Ops.input_of(flow_node, input)
	if data.has("var"):
		var var_name: String = str(data["var"])
		return var_name if not var_name.is_empty() else "(variable?)"
	var type: int = int(data.get("type", 0))
	var value: Variant = data.get("value")
	if type == Types.ValueType.NODE and value != null and not str(value).strip_edges().is_empty():
		return Types.path_shown(str(value))
	if type == Types.ValueType.NODE and input == &"terrain":
		# (A Terrain input left blank: the scene's Terrain.)
		return "the scene's Terrain"
	if type == Types.ValueType.RESOURCE:
		return str(value).get_file() if value != null and not str(value).is_empty() else "(file?)"
	match type:
		Types.ValueType.TEXT:
			return "\"%s\"" % str(value)
		Types.ValueType.NUMBER, Types.ValueType.WHOLE:
			return ValueEditor.number_text(value, type)
		Types.ValueType.LIST:
			# An empty List, maybe of a type: "[] of Number".
			var list: Dictionary = NodeTypes.list_info_of_value(value)
			return "[]" if list.is_empty() else "[] of " + NodeTypes.describe_list(list).trim_prefix("List of ")
		Types.ValueType.TABLE:
			# An empty Table, maybe typed: "{} of Text -> Number".
			var table: Dictionary = NodeTypes.table_info_of_value(value)
			return "{}" if table.is_empty() else "{} of " + NodeTypes.describe_table(table).trim_prefix("Table of ")
	return str(value)


func _exit_label(exit: StringName, event: bool) -> String:
	if exit == &"":
		return ""
	if event:
		var number: int = int(String(exit))
		return "Output %d" % number if node.exits.get(exit, 0) > 0 else "+ output"
	return Ops.exit_title(node, exit)


func _port_row(left: String, right: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	var left_label: Label = Label.new()
	left_label.text = left
	left_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left_label)
	var right_label: Label = Label.new()
	right_label.text = right
	right_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if right.begins_with("+ "):
		right_label.modulate.a = 0.55
	row.add_child(right_label)
	return row


func _readable(label: Label, font_size: int = TEXT_SIZE) -> void:
	if label == null:
		return
	label.add_theme_color_override(&"font_color", _text_color)
	label.add_theme_color_override(&"font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override(&"outline_size", OUTLINE_SIZE)
	label.add_theme_font_size_override(&"font_size", font_size)


## The brick just ran (Trace): it brightens and fades back.
func flash() -> void:
	if _flash != null and _flash.is_valid():
		_flash.kill()
	self_modulate = FLASH_COLOR
	_flash = create_tween()
	_flash.tween_property(self, ^"self_modulate", Color.WHITE, FLASH_TIME)


## The running game hit an error here: a red outline, the error as the tip.
func _mark_runtime_error(text: String) -> void:
	for style_name: StringName in [&"titlebar", &"titlebar_selected", &"panel", &"panel_selected"]:
		var style: StyleBoxFlat = (get_theme_stylebox(style_name) as StyleBoxFlat).duplicate()
		style.border_color = RUNTIME_ERROR_COLOR
		style.set_border_width_all(3)
		if style_name.begins_with("titlebar"):
			style.border_width_bottom = 0
		else:
			style.border_width_top = 0
		add_theme_stylebox_override(style_name, style)
	tooltip_text = "The game hit an error here: %s" % text


## Title bar in the category color (like the snap blocks were).
func _style(color: Color, context: Context) -> void:
	for selected: bool in [false, true]:
		var bar: StyleBoxFlat = StyleBoxFlat.new()
		# Dark enough for light text on every category color.
		bar.bg_color = context.brick_theme.background().lerp(color, 0.45 if selected else 0.32)
		bar.border_color = context.brick_theme.accent_color() if selected else color
		bar.set_border_width_all(2)
		bar.border_width_bottom = 0
		bar.corner_radius_top_left = 6
		bar.corner_radius_top_right = 6
		bar.set_content_margin_all(6)
		add_theme_stylebox_override(&"titlebar_selected" if selected else &"titlebar", bar)
		var body: StyleBoxFlat = StyleBoxFlat.new()
		body.bg_color = context.brick_theme.background().lerp(color, 0.1)
		body.border_color = context.brick_theme.accent_color() if selected else color.darkened(0.2)
		body.set_border_width_all(2)
		body.border_width_top = 0
		body.corner_radius_bottom_left = 6
		body.corner_radius_bottom_right = 6
		body.content_margin_left = 10
		body.content_margin_right = 10
		body.content_margin_top = 4
		body.content_margin_bottom = 6
		add_theme_stylebox_override(&"panel_selected" if selected else &"panel", body)
