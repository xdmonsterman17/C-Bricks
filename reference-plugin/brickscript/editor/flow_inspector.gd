@tool
extends VBoxContainer

## Right sidebar: the properties of the node selected on the canvas, in two
## sections, Inputs then Outputs below it:
## - Inputs: settings (action, formula, If's comparison), then each input:
##   one dropdown, "Variable" (then a dropdown of the variables usable at this
##   node that fit the input) or a value type (then that type's editor);
##   + / - rows for Make list / Make table.
## - Outputs: where the result goes ("Output Var": blank = not kept, a name
##   makes a chain variable; or "Use Var" and a dropdown of existing
##   variables), Set Var's target (or a new variable's name and kind), a
##   loop's names, an event's values and its outputs in run order (up / down
##   to reorder), and what runs next.
## Clicking a palette entry shows what that node does instead; a selected
## comment frame shows its title and color. Variables are made by bricks
## (Set Var for Constants, Exports and Shared ones), so there is no list.

const Context = preload("flow_context.gd")
const Library = preload("../core/flow_library.gd")
const Ops = preload("../core/flow_ops.gd")
const Types = preload("../core/flow_types.gd")
const ValueEditor = preload("flow_value_editor.gd")
const BrickTheme = preload("brick_theme.gd")
const FlowCompiler = preload("../core/flow_compiler.gd")
const NodeTypes = preload("../core/node_types.gd")
const PathPicker = preload("flow_path_picker.gd")
## Comment frame colors one click away (Properties of a frame).
const FRAME_SWATCHES: Array[Color] = [Color(0.25, 0.3, 0.4), Color(0.2, 0.45, 0.6), Color(0.2, 0.5, 0.3), Color(0.55, 0.5, 0.2),
	Color(0.6, 0.35, 0.15), Color(0.6, 0.2, 0.25), Color(0.45, 0.25, 0.55), Color(0.35, 0.35, 0.35)]
const BrickFile = preload("../core/brick_file.gd")
## Setting kinds that say what a Node is (shown together, before inputs).
const NODE_TYPE_KINDS: PackedStringArray = ["node_path", "scene", "node_class", "node_script"]

## Input mode dropdown id for "Variable" (other ids are ValueTypes).
const VARIABLE_MODE: int = 1000
## Variable dropdown ids: "(choose)", a name not usable here, "New variable…"
## (variables use their index; -1 would mean "auto" to OptionButton).
const PICK_NONE: int = 100000
const PICK_MISSING: int = 100001
const PICK_NEW: int = 100002
const WARNING_COLOR: Color = Color(1.0, 0.8, 0.4)
const LABEL_WIDTH: float = 72.0
## What each kind of new Set Var variable is.
const KIND_HINTS: Dictionary = {
	"Shared": "Shared: every event can use it, and it keeps its value between runs.",
	"Chain": "Chain: only bricks after this one in this event can use it; it resets every run.",
	"Constant": "Constant: one fixed value for the whole script; nothing can change it. Every brick can read it.",
	"Export": "Export: set per node in the Inspector, starting at this value. Every brick can read it.",
	"Synced": "Synced: Shared, and the same on every machine. The node's owner (the server, unless you Give To) changes it; everyone else gets the new value.",
}

var context: Context = null
## Room between the rows and the panel's right edge, in pixels at scale 1.
const RIGHT_PADDING: int = 12

var _title: Label = null
var _scroll: ScrollContainer = null
var _body: VBoxContainer = null
## Where sections add their rows: _body, or the Inputs / Outputs section.
var _target: VBoxContainer = null


func _init() -> void:
	var header: Label = Label.new()
	header.text = "Properties"
	add_child(header)
	_title = Label.new()
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_title)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	# Rows stop short of the panel's right edge (and its scroll bar).
	var margin: MarginContainer = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override(&"margin_right", RIGHT_PADDING * _editor_scale())
	_scroll.add_child(margin)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_body)
	_target = _body


## The editor's display scale (1 outside the editor).
static func _editor_scale() -> float:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		return float(Engine.get_singleton(&"EditorInterface").call(&"get_editor_scale"))
	return 1.0


## The editors shown (for tests).
func body() -> VBoxContainer:
	return _body


func rebuild() -> void:
	Context.commit_focused(self)
	for child: Node in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_target = _body
	var frame: Dictionary = Ops.frame_by_id(context.graph, context.selected) if context.selected > 0 else {}
	if not frame.is_empty():
		_show_frame(frame)
		return
	var node: BrickscriptFlowNode = context.selected_node()
	if node == null and context.info_type != &"":
		_show_info(context.info_type)
		return
	if node == null:
		_title.text = ""
		_title.remove_theme_color_override(&"font_color")
		_target.add_child(_hint("Click a brick on the canvas to see and edit its properties, or a palette entry to see what it does.\nRight-click the canvas (or drag from the palette) to add bricks; drag from a ▶ port to wire what runs next.\nVariables come from bricks: Variable (Set) makes Shared, Chain, Constant and Export ones."))
		if not context.parent_note.is_empty():
			var note: Label = _hint(context.parent_note)
			note.name = "ParentNote"
			_target.add_child(note)
		return
	var definition: Dictionary = Library.get_definition(node.type)
	_title.text = definition.get("title", String(node.type))
	_title.add_theme_color_override(&"font_color", context.brick_theme.category_color(definition.get("category", "")))
	if Ops.is_event(node):
		_target.add_child(_hint("Event: starts chains. Its outputs run in order, each to the end, before the next."))
	elif Ops.is_declaration(node):
		_target.add_child(_hint("A declaration: no wires; it is set before the game starts and every brick can read it."))
	elif not _reached(node):
		var kind: String = FlowCompiler.set_var_kind(node) if node.type == &"set_var" else ""
		if kind == "Constant" or kind == "Export":
			_target.add_child(_hint("A declaration: set before the game starts, no wiring needed."))
		elif kind == "Shared":
			_target.add_child(_hint("Not wired to an event: it gives its variable's starting value."))
		else:
			_target.add_child(_hint("Not wired to an event yet: it won't run."))
	var inputs_tab: VBoxContainer = _section("Inputs")
	var outputs_tab: VBoxContainer = _section("Outputs")

	_target = inputs_tab
	if Library.family_of(node.type) != &"":
		_add_family_choice(node)
	if node.type == &"formula":
		_add_formula(node)
	for setting: Dictionary in definition.get("settings", []):
		if setting["kind"] == "action":
			_add_row(str(setting.get("title", "Action")), _action_field(node, setting["name"]))
	for setting: Dictionary in definition.get("settings", []):
		if setting.has("context") and setting["context"] != context.graph.context:
			# Only for one kind of brickscript (Runs on: server brickscripts).
			continue
		if setting["kind"] == "choice" and setting.get("place", "") != "outputs":
			_add_choice(node, setting)
		elif setting["kind"] == "text" and node.type != &"set_var" and node.type != &"formula":
			_add_text_setting(node, setting)
		elif NODE_TYPE_KINDS.has(setting["kind"]) and _node_type_shown(node):
			_add_node_type_setting(node, setting)
		elif setting["kind"] in ["signal", "property"] and not setting.has("target"):
			_add_member_setting(node, setting)
		elif setting["kind"] == "group":
			_add_group_setting(node, setting)
		elif setting["kind"] == "layers":
			_add_layers_setting(node, setting)
		elif setting["kind"] == "animation":
			_add_animation_setting(node, setting)
		elif setting["kind"] == "shared_file" and _calls_a_file(node):
			_add_shared_file_setting(node, setting)
		elif setting["kind"] == "function_script" and _calls_a_node(node):
			_add_function_script_setting(node, setting)
		elif setting["kind"] == "function":
			_add_function_setting(node, setting)
	if node.type == &"define_function":
		_add_function_params(node)
	for spec: Dictionary in Ops.input_specs(node):
		if Ops.input_shown(node, spec["name"]):
			_add_input(node, spec)
		# A property / method setting goes right after the node it belongs to.
		for setting: Dictionary in definition.get("settings", []):
			if setting.get("target", &"") == spec["name"]:
				_add_member_setting(node, setting)
	if definition.has("variadic"):
		_add_row_buttons(node)
	if inputs_tab.get_child_count() == 0:
		_target.add_child(_hint("No inputs."))

	_target = outputs_tab
	if node.type == &"set_var":
		_add_set_var(node)
	if Library.DECLARATIONS.has(node.type):
		_add_declared_name(node)
	var made_names: Array = definition.get("settings", []).filter(func(setting: Dictionary) -> bool: return setting["kind"] == "name")
	if not made_names.is_empty():
		_add_loop_names(node, made_names, definition)
	if Library.node_has_output(node):
		_add_output(node)
	var provides: Dictionary = Ops.provides_of(node)
	if node.type == &"event_signal":
		provides = _signal_values(node)
	for value_name: Variant in provides:
		_target.add_child(_hint("Provides %s (%s, read-only) to the bricks it runs." % [value_name, Types.type_name(provides[value_name])]))
	if Ops.is_event(node):
		_add_event_outputs(node)
	elif not Ops.is_declaration(node):
		_add_runs_next(node, definition)

	_target = _body
	_target.add_child(HSeparator.new())
	if node.size != Vector2.ZERO:
		var fit: Button = Button.new()
		fit.text = "Fit to content"
		fit.tooltip_text = "Undo resizing: size the node to what it shows again."
		fit.pressed.connect(func() -> void:
			if Ops.set_size(node, Vector2.ZERO):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Fit node to content"))
		_target.add_child(fit)
	var remove: Button = Button.new()
	remove.text = "Delete node"
	remove.icon = context.brick_theme.icon(&"Remove")
	remove.pressed.connect(func() -> void:
		if Ops.delete_node(context.graph, node):
			context.select(0)
			context.notify_changed(Context.Redraw.ALL, "Delete node"))
	_target.add_child(remove)


#region Sections

## A titled section of the node's properties (Inputs, Outputs), stacked.
func _section(title: String) -> VBoxContainer:
	var header: Label = Label.new()
	header.text = title
	header.add_theme_color_override(&"font_color", context.brick_theme.accent_color())
	var line: HSeparator = HSeparator.new()
	_body.add_child(line)
	_body.add_child(header)
	var page: VBoxContainer = VBoxContainer.new()
	page.name = title
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(page)
	return page


## Where an action brick goes next, named like its exits.
func _add_runs_next(node: BrickscriptFlowNode, definition: Dictionary) -> void:
	if not Library.node_has_output(node) and node.type != &"set_var" and not definition.get("settings", []).any(func(setting: Dictionary) -> bool: return setting["kind"] == "name"):
		_target.add_child(_hint("Doesn't make a value."))
	_target.add_child(HSeparator.new())
	var header: Label = Label.new()
	header.text = "Runs next"
	_target.add_child(header)
	for exit: StringName in Ops.exits_for(node):
		var target: BrickscriptFlowNode = context.graph.node_by_id(node.exits.get(exit, 0))
		var exit_title: String = Ops.exit_title(node, exit)
		if exit_title.begins_with("+ "):
			# The spare one: wiring it adds another (shown on the brick).
			continue
		if exit_title.is_empty():
			exit_title = "Next"
		_target.add_child(_hint("%s → %s" % [exit_title, Library.get_definition(target.type).get("title", "?") if target != null else "(not wired)"]))
	if Ops.exits_for(node).any(func(exit: StringName) -> bool: return Ops.grows(node, Ops.exit_base(exit))):
		_target.add_child(_hint("Wire the spare ▶ (+ next, + loop body, + done) for another chain: they run in order, each to its end."))

## What a palette entry's node does: its description, inputs, settings,
## output and exits, and a button to add it.
func _show_info(type: StringName) -> void:
	var definition: Dictionary = Library.get_definition(type)
	var family: StringName = Library.family_of(type)
	_title.text = Library.listed_title(type)
	_title.add_theme_color_override(&"font_color", context.brick_theme.category_color(definition.get("category", "")))
	var kind: String = ["Event (starts chains)", "Action", "Declaration (no wires)"][definition["kind"]]
	_target.add_child(_hint("%s · %s" % [BrickTheme.CATEGORY_TITLES.get(definition["category"], definition["category"]), kind]))
	var description: Label = Label.new()
	description.text = Library.FAMILIES[family]["description"] if family != &"" else definition.get("description", "")
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_target.add_child(description)
	var lines: PackedStringArray = []
	if family != &"":
		# Each way it works (its dropdown in Properties), then the first's
		# details: the one Add to canvas adds.
		for member: Array in Library.FAMILIES[family]["members"]:
			if context.can_use(member[1]):
				lines.append("• %s (%s): %s" % [member[0], Library.get_definition(member[1])["title"], Library.get_definition(member[1]).get("description", "")])
		_info_section("%s (picked in Properties)" % Library.FAMILIES[family]["setting"], lines)
		lines = []
		_target.add_child(_hint("Below: %s (%s), which Add to canvas adds." % [Library.family_option(type), definition["title"]]))
	for setting: Dictionary in definition.get("settings", []):
		var how: String = setting.get("info", "")
		if how.is_empty():
			how = {"choice": "pick one: " + ", ".join(setting.get("options", [])), "name": "a name it makes (blank: not kept)"}.get(setting["kind"], "typed in")
		lines.append("• %s: %s" % [setting.get("title", String(setting["name"]).capitalize()), how])
	if not lines.is_empty():
		_info_section("Settings", lines)
	lines = []
	var inputs: Array = definition.get("inputs", []) + definition.get("variadic", {}).get("inputs", []).map(func(spec: Dictionary) -> Dictionary:
		var row: Dictionary = spec.duplicate()
		row["name"] = String(spec["name"]) + " (one per row, + / -)"
		return row)
	for spec: Dictionary in inputs:
		var allowed: PackedStringArray = []
		for wanted: int in spec["types"]:
			allowed.append(Types.type_name(wanted))
		lines.append("• %s: %s%s" % [String(spec["name"]).capitalize() if not String(spec["name"]).contains("(") else spec["name"], " or ".join(allowed) if not allowed.is_empty() else "anything", " (changed in place)" if spec.get("writes", false) else ""])
	if not lines.is_empty():
		_info_section("Inputs (a variable, or a typed-in value)", lines)
	if Library.has_output(type):
		_info_section("Output", ["• " + _returns_text(type, definition) + ", into its Output Var (or an existing variable with Use Var)"])
	var provides: Dictionary = definition.get("provides", {})
	if not provides.is_empty():
		_info_section("Provides", provides.keys().map(func(value_name: String) -> String: return "• %s (%s), read-only" % [value_name, Types.type_name(provides[value_name])]))
	var exits: PackedStringArray = []
	if definition["kind"] == Library.Kind.EVENT:
		exits.append("• Output 1, 2, …: run in order, each to the end")
	elif definition["kind"] == Library.Kind.DECLARE:
		exits.append("• Nothing: it has no wires; it is set before the game starts")
	else:
		for exit: StringName in Library.exits_of(type):
			exits.append("• " + definition.get("exit_titles", {}).get(exit, "Next" if exit == &"next" else String(exit).capitalize()))
	_info_section("Runs next", exits)
	_target.add_child(HSeparator.new())
	var add: Button = Button.new()
	add.text = "Add to canvas"
	add.icon = context.brick_theme.icon(&"Add")
	add.tooltip_text = "Or drag it from the palette, or double-click it there."
	add.pressed.connect(func() -> void:
		if context.on_add_type.is_valid():
			context.on_add_type.call(type))
	_target.add_child(add)


func _info_section(heading: String, lines: Array) -> void:
	var header: Label = Label.new()
	header.text = heading
	_target.add_child(header)
	for line: String in lines:
		_target.add_child(_hint(line))


static func _returns_text(type: StringName, definition: Dictionary) -> String:
	if type == &"formula":
		return "worked out from the formula"
	var returns: Variant = definition.get("returns", null)
	match returns:
		&"arith":
			return "a Number, Whole or vector (from A and B)"
		&"divide":
			return "a Number (or a vector)"
	return "a " + Types.type_name(returns) if returns is int else "a value"

func _show_frame(frame: Dictionary) -> void:
	_title.text = "Comment frame"
	_title.remove_theme_color_override(&"font_color")
	var title: LineEdit = LineEdit.new()
	title.text = frame["title"]
	_on_commit(title, func() -> void:
		if Ops.set_frame(frame, "title", title.text):
			context.notify_changed(Context.Redraw.CANVAS, "Rename frame"))
	_add_row("Title", title)
	var color: ColorPickerButton = ColorPickerButton.new()
	color.color = frame["color"]
	color.edit_alpha = false
	color.custom_minimum_size.y = 24
	color.popup_closed.connect(func() -> void:
		if Ops.set_frame(frame, "color", color.color):
			context.notify_changed(Context.Redraw.CANVAS, "Recolor frame"))
	_add_row("Color", color)
	# Quick colors.
	var swatches: HBoxContainer = HBoxContainer.new()
	swatches.name = "Swatches"
	for swatch_color: Color in FRAME_SWATCHES:
		var swatch: Button = Button.new()
		swatch.custom_minimum_size = Vector2(22, 22)
		swatch.tooltip_text = "#" + swatch_color.to_html(false)
		var style: StyleBoxFlat = StyleBoxFlat.new()
		style.bg_color = swatch_color
		style.set_corner_radius_all(3)
		for state: StringName in [&"normal", &"hover", &"pressed"]:
			swatch.add_theme_stylebox_override(state, style)
		swatch.pressed.connect(func() -> void:
			if Ops.set_frame(frame, "color", swatch_color):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Recolor frame"))
		swatches.add_child(swatch)
	_add_row("", swatches)
	var count: int = frame["nodes"].size()
	if count > 0 and not frame.get("fit", true):
		var fit: Button = Button.new()
		fit.text = "Fit to its bricks"
		fit.tooltip_text = "Size it around its bricks again (it was resized by hand)."
		fit.pressed.connect(func() -> void:
			if Ops.set_frame(frame, "fit", true):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Fit frame"))
		_target.add_child(fit)
	_target.add_child(_hint("Holds %d node(s); they move with it. Drop nodes on the frame to add them." % count if count > 0 else "Empty. Drop nodes on it to group them."))
	if count > 0:
		var release: Button = Button.new()
		release.text = "Release nodes"
		release.tooltip_text = "Let go of the nodes (they stay where they are)."
		release.pressed.connect(func() -> void:
			if Ops.release_frame(frame):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Release nodes"))
		_target.add_child(release)
	_target.add_child(HSeparator.new())
	var remove: Button = Button.new()
	remove.text = "Delete frame"
	remove.tooltip_text = "Deletes the frame only; its nodes stay."
	remove.icon = context.brick_theme.icon(&"Remove")
	remove.pressed.connect(func() -> void:
		if Ops.delete_frame(context.graph, frame):
			context.select(0)
			context.notify_changed(Context.Redraw.ALL, "Delete frame"))
	_target.add_child(remove)

func _add_formula(node: BrickscriptFlowNode) -> void:
	var edit: LineEdit = LineEdit.new()
	edit.text = str(node.settings.get(&"expression", ""))
	edit.placeholder_text = "e.g. (speed * delta + 1) * 2"
	_on_commit(edit, func() -> void:
		if Ops.set_setting(node, &"expression", edit.text.strip_edges()):
			context.notify_changed(Context.Redraw.CANVAS, "Change property"))
	_add_row("Formula", edit)
	_target.add_child(_hint("Variable names, numbers, + - * / ( ), comparisons (> == and or), and functions like min, max, abs, sqrt, round, lerp, clamp, Vector3(x, y, z)."))


## A dropdown of writable variables, plus "New variable…" (which shows a
## name box): a name that isn't one of them is a new variable.
func _add_set_var(node: BrickscriptFlowNode) -> void:
	var current: String = str(node.settings.get(&"name", ""))
	if Library.mode_of(node) == "Get":
		# Get: any variable it can read, into its Output (no new name, no Kind).
		_add_row("Variable", _var_dropdown(current, context.variables_at(node.id), false, false, func(picked: String) -> void:
			if Ops.set_setting(node, &"name", picked):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property")))
		_target.add_child(_hint("Reads it into its Output."))
		return
	if Library.mode_of(node) == "Add":
		# Add: an existing number or vector variable (no new name, no Kind).
		var addable: Array[Dictionary] = context.variables_at(node.id, [Types.ValueType.NUMBER, Types.ValueType.WHOLE, Types.ValueType.VECTOR2, Types.ValueType.VECTOR3], true)
		_add_row("Variable", _var_dropdown(current, addable, false, false, func(picked: String) -> void:
			if Ops.set_setting(node, &"name", picked):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property")))
		_target.add_child(_hint("Adds the value to it (a negative value takes away)."))
		return
	# A variable only this Set Var makes is its own new name, not an existing
	# variable to pick.
	var made_elsewhere: bool = context.graph.variables.any(func(variable: BrickscriptVariable) -> bool: return variable != null and variable.name == current) \
		or context.graph.nodes.any(func(other: BrickscriptFlowNode) -> bool: return other != node and other.type == &"set_var" and str(other.settings.get(&"name", "")) == current)
	var choices: Array[Dictionary] = context.variables_at(node.id, [], true)
	if not made_elsewhere:
		choices = choices.filter(func(choice: Dictionary) -> bool: return choice["name"] != current)
	var is_new: bool = not current.is_empty() and not choices.any(func(choice: Dictionary) -> bool: return choice["name"] == current)
	_add_row("Variable", _var_dropdown("" if is_new else current, choices, true, is_new, func(picked: String) -> void:
		if Ops.set_setting(node, &"name", picked):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property")))
	if not is_new:
		if not current.is_empty():
			_target.add_child(_hint("Writes the existing variable '%s'." % current))
		return
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = current
	name_edit.placeholder_text = "new variable name"
	name_edit.tooltip_text = "Renaming it also renames it in every brick that uses it."
	_on_commit(name_edit, func() -> void:
		var typed: String = name_edit.text.strip_edges()
		if typed == current or typed.is_empty():
			name_edit.text = current
		elif Ops.rename_made_variable(context.graph, node, typed):
			context.notify_changed(Context.Redraw.CANVAS, "Rename variable")
		else:
			name_edit.text = current
			name_edit.tooltip_text = "'%s' is not a valid name, or is already used." % typed)
	_add_row("Name", name_edit)
	var kind: String = FlowCompiler.set_var_kind(node)
	var kinds: PackedStringArray = Library.SET_VAR_KINDS
	var kind_picker: OptionButton = OptionButton.new()
	for kind_name: String in kinds:
		var kind_icon: Texture2D = context.brick_theme.kind_icon(["Constant", "Export", "Shared", "Chain"].find(kind_name))
		kind_picker.add_icon_item(kind_icon, kind_name)
		kind_picker.set_item_tooltip(kind_picker.item_count - 1, KIND_HINTS[kind_name])
	kind_picker.select(maxi(0, kinds.find(kind)))
	kind_picker.item_selected.connect(func(index: int) -> void:
		if Ops.set_setting(node, &"var_kind", kinds[index]):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change variable kind"))
	_add_row("Kind", kind_picker)
	_target.add_child(_hint(KIND_HINTS[kind]))


## A Constant / Export's name: renaming it renames every brick that uses it.
func _add_declared_name(node: BrickscriptFlowNode) -> void:
	var current: String = str(node.settings.get(&"name", ""))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = current
	name_edit.placeholder_text = "name"
	name_edit.tooltip_text = "Renaming it also renames it in every brick that uses it."
	_on_commit(name_edit, func() -> void:
		var typed: String = name_edit.text.strip_edges()
		if typed == current or typed.is_empty():
			name_edit.text = current
		elif Ops.rename_made_variable(context.graph, node, typed):
			context.notify_changed(Context.Redraw.CANVAS, "Rename variable")
		else:
			name_edit.text = current
			name_edit.tooltip_text = "'%s' is not a valid name, or is already used." % typed)
	_add_row("Name", name_edit)
	_target.add_child(_hint(KIND_HINTS[Library.DECLARATIONS[node.type]]))


## + / - for Make list / Make table rows.
func _add_row_buttons(node: BrickscriptFlowNode) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	var unit: String = {&"make_list": "value", &"unpack_table": "key"}.get(node.type, "key/value row")
	for step: Array in [[1, &"Add", "+", "Add a %s" % unit], [-1, &"Remove", "-", "Remove the last %s" % unit]]:
		var button: Button = Button.new()
		button.icon = context.brick_theme.icon(step[1])
		if button.icon == null:
			button.text = step[2]
		button.tooltip_text = step[3]
		button.disabled = step[0] < 0 and Ops.row_count(node) <= Library.get_definition(node.type)["variadic"]["min"]
		button.pressed.connect(func() -> void:
			if Ops.set_row_count(node, Ops.row_count(node) + step[0]):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change rows"))
		row.add_child(button)
	var count: Label = Label.new()
	count.text = "%d %s(s)" % [Ops.row_count(node), unit]
	count.modulate.a = 0.7
	row.add_child(count)
	_target.add_child(row)


## The chain variables a loop fills each time round (blank: not kept).
func _add_loop_names(node: BrickscriptFlowNode, settings: Array, definition: Dictionary = {}) -> void:
	var header: Label = Label.new()
	header.text = definition.get("names_header", "Each time round, fills")
	_target.add_child(header)
	# Taken by a variable before this loop (or a script variable): the loop
	# writes into it; else the name is a new chain variable.
	var writable: Array[Dictionary] = context.variables_at(node.id, [], true)
	for setting: Dictionary in settings:
		var name: StringName = setting["name"]
		var current: String = str(node.settings.get(name, ""))
		# Index / Counter are Whole; a setting may say what it makes.
		var made_type: int = Types.ValueType.WHOLE if name == &"index_name" else int(setting.get("made_type", Types.ValueType.ANY))
		var choices: Array[Dictionary] = writable.filter(func(choice: Dictionary) -> bool: return made_type == Types.ValueType.ANY or Types.fits(made_type, choice["type"]))
		var existing: bool = choices.any(func(choice: Dictionary) -> bool: return choice["name"] == current)
		var base: String = String(setting.get("suggest", setting["default"]))
		_add_made_variable(node, setting["title"], current, existing, choices, base if not base.is_empty() else "i", name,
			func(picked: String) -> bool: return Ops.set_setting(node, name, picked))
	_target.add_child(_hint(definition.get("names_hint", "Chain variables the Loop body can read (they keep their last value after the loop), or existing ones it writes into. Done runs once the loop has finished.")))


## A brick family's dropdown (Mode, When, Operation...): the ways of this
## brick usable here; picking one makes it that brick (Ops.change_type()).
func _add_family_choice(node: BrickscriptFlowNode) -> void:
	var family: Dictionary = Library.FAMILIES[Library.family_of(node.type)]
	var picker: OptionButton = OptionButton.new()
	picker.name = "Family"
	var types: Array[StringName] = []
	for member: Array in family["members"]:
		if member[1] == node.type or context.can_use(member[1]):
			picker.add_item(member[0])
			types.append(member[1])
	picker.select(types.find(node.type))
	picker.tooltip_text = family["description"]
	picker.item_selected.connect(func(index: int) -> void:
		if Ops.change_type(context.graph, node, types[index]):
			context.notify_changed(Context.Redraw.ALL, "Change %s" % String(family["setting"]).to_lower()))
	_add_row(family["setting"], picker)


func _add_choice(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var picker: OptionButton = OptionButton.new()
	var options: PackedStringArray = setting["options"]
	for option: String in options:
		picker.add_item(option)
	picker.select(maxi(0, options.find(str(node.settings.get(setting["name"], setting["default"])))))
	picker.item_selected.connect(func(index: int) -> void:
		if Ops.set_setting(node, setting["name"], options[index]):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	_add_row(setting.get("title", String(setting["name"]).capitalize()), picker)


## A typed-in text setting (e.g. a network message's name).
func _add_text_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var edit: LineEdit = LineEdit.new()
	edit.text = str(node.settings.get(setting["name"], setting["default"]))
	edit.tooltip_text = setting.get("info", "")
	_on_commit(edit, func() -> void:
		if Ops.set_setting(node, setting["name"], edit.text.strip_edges()):
			context.notify_changed(Context.Redraw.CANVAS, "Change property"))
	_add_row(setting.get("title", String(setting["name"]).capitalize()), edit)


#region Functions

## Define Function's inputs: a name and a type each, + / - to add or remove.
func _add_function_params(node: BrickscriptFlowNode) -> void:
	var params: Array = (node.settings.get(&"params", []) as Array).duplicate(true)
	var store: Callable = func(changed: Array, action: String) -> void:
		if Ops.set_function_params(node, changed):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, action)
	for i: int in params.size():
		var row: HBoxContainer = HBoxContainer.new()
		var edit: LineEdit = LineEdit.new()
		edit.text = str(params[i][0])
		edit.placeholder_text = "input name"
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_on_commit(edit, func() -> void:
			var changed: Array = params.duplicate(true)
			changed[i][0] = edit.text.strip_edges()
			store.call(changed, "Rename function input"))
		row.add_child(edit)
		var type_picker: OptionButton = OptionButton.new()
		for type_name: String in Library.FUNCTION_INPUT_TYPES:
			type_picker.add_item(type_name)
		type_picker.select(maxi(0, Library.FUNCTION_INPUT_TYPES.find(str(params[i][1]))))
		type_picker.item_selected.connect(func(index: int) -> void:
			var changed: Array = params.duplicate(true)
			changed[i][1] = Library.FUNCTION_INPUT_TYPES[index]
			store.call(changed, "Change function input type"))
		row.add_child(type_picker)
		var remove: Button = Button.new()
		remove.icon = context.brick_theme.icon(&"Remove")
		remove.tooltip_text = "Remove this input"
		remove.pressed.connect(func() -> void:
			var changed: Array = params.duplicate(true)
			changed.remove_at(i)
			store.call(changed, "Remove function input"))
		row.add_child(remove)
		_add_row("Input %d" % (i + 1), row)
	var add: Button = Button.new()
	add.text = "Add input"
	add.icon = context.brick_theme.icon(&"Add")
	add.pressed.connect(func() -> void:
		var changed: Array = params.duplicate(true)
		changed.append(["input_%d" % (params.size() + 1), "Number"])
		store.call(changed, "Add function input"))
	_target.add_child(add)
	_target.add_child(_hint("Each input is a value its chain reads (read-only), given by the Call Function that calls it."))


## Call Function's function: picked from the Define Functions here; picking
## one gives the brick one value row per input, typed like it.
func _add_function_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var functions: Dictionary = _target_functions(node)
	var labels: PackedStringArray = []
	var values: PackedStringArray = []
	for name: String in functions:
		values.append(name)
		var inputs: PackedStringArray = []
		for param: Array in Ops.function_params(functions[name]):
			inputs.append("%s: %s" % [param[0], Types.type_name(param[1])])
		labels.append("%s(%s)" % [name, ", ".join(inputs)])
	var current: String = str(node.settings.get(setting["name"], ""))
	var field: HBoxContainer = _pick_field(current, "pick a function", labels, values, func(typed: String) -> void:
		var changed: bool = Ops.set_setting(node, setting["name"], typed)
		if functions.has(typed):
			changed = _fit_to_function(node, functions[typed]) or changed
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	var edit: LineEdit = field.get_child(0)
	if not current.is_empty() and not functions.has(current):
		edit.add_theme_color_override(&"font_color", WARNING_COLOR)
		edit.tooltip_text = "No Define Function named '%s' in %s." % [current, "that file" if _calls_a_file(node) else "this brickscript"]
	_add_row(setting.get("title", "Function"), field)
	if functions.is_empty():
		if _calls_a_node(node) and str(node.settings.get(&"function_script", "")).is_empty():
			_target.add_child(_hint("Type the function's name (its brickscript isn't picked), and add a value row (+) per input."))
		else:
			_target.add_child(_hint("Pick a shared brickscript first." if _calls_a_file(node) and str(node.settings.get(&"file", "")).is_empty()
				else "No functions there yet: add a Define Function brick."))


## Call Function From: A file: the shared brickscript, picked from the
## project's .brickshared files.
func _add_shared_file_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var files: PackedStringArray = Array(_project_scripts("res://")).filter(func(path: String) -> bool: return BrickFile.is_shared_path(path))
	var labels: PackedStringArray = []
	for path: String in files:
		var graph: BrickscriptFlowGraph = BrickFile.load_graph(path)
		labels.append("%s  (%s)" % [path.trim_prefix("res://"), "Server only" if graph != null and graph.context == &"server" else "Both"])
	var current: String = str(node.settings.get(setting["name"], ""))
	_add_row(setting.get("title", "File"), _pick_field(current, "res://....brickshared", labels, files, func(typed: String) -> void:
		if Ops.set_setting(node, setting["name"], typed):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property")))
	if files.is_empty():
		_target.add_child(_hint("No shared brickscripts yet: FileSystem > right-click > Create New > Brickscript (shared functions)."))


## Call Function From: A node: the node's brickscript (optional), picked
## from the project's brickscripts of this one's side.
func _add_function_script_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var extension: String = BrickFile.SERVER_EXTENSION if context.graph.context == &"server" else BrickFile.LOCAL_EXTENSION
	var files: PackedStringArray = Array(_project_scripts("res://")).filter(func(path: String) -> bool: return path.get_extension() == extension)
	var labels: PackedStringArray = []
	for path: String in files:
		labels.append(path.trim_prefix("res://"))
	var current: String = str(node.settings.get(setting["name"], ""))
	_add_row(setting.get("title", "Its brickscript"), _pick_field(current, "optional: res://....%s" % extension, labels, files, func(typed: String) -> void:
		if Ops.set_setting(node, setting["name"], typed):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property")))
	_target.add_child(_hint("The node's %s brickscript: pick it to choose from its functions (typed, checked now). Blank: type the function's name and add its values (+); it's checked when the game runs."
		% ("server" if context.graph.context == &"server" else "local")))


func _calls_a_file(node: BrickscriptFlowNode) -> bool:
	return node.type == &"call_function" and str(node.settings.get(&"from", Library.FUNCTION_FROM[0])) == Library.FUNCTION_FROM[1]


func _calls_a_node(node: BrickscriptFlowNode) -> bool:
	return node.type == &"call_function" and str(node.settings.get(&"from", Library.FUNCTION_FROM[0])) == Library.FUNCTION_FROM[2]


## The functions a Call Function can pick: this brickscript's, its file's,
## or its node's brickscript's (name -> Define Function node).
func _target_functions(node: BrickscriptFlowNode) -> Dictionary:
	if not _calls_a_file(node) and not _calls_a_node(node):
		return Ops.functions_of(context.graph)
	var path: String = str(node.settings.get(&"file" if _calls_a_file(node) else &"function_script", ""))
	var graph: BrickscriptFlowGraph = BrickFile.load_graph(path) if BrickFile.is_script_path(path) else null
	return Ops.functions_of(graph) if graph != null else {}


## One value row per input of `define`, each typed like it (unless it reads a
## variable).
func _fit_to_function(node: BrickscriptFlowNode, define: BrickscriptFlowNode) -> bool:
	var params: Array = Ops.function_params(define)
	var changed: bool = Ops.set_row_count(node, params.size())
	for i: int in params.size():
		var input: StringName = StringName("arg_%d" % (i + 1))
		var data: Dictionary = Ops.input_of(node, input)
		var type: int = params[i][1]
		if not data.has("var") and Types.is_known(type) and int(data.get("type", -1)) != type:
			changed = Ops.set_input_type(node, input, type) or changed
	return changed


## An input row's label: Call Function's rows are named after the
## function's inputs.
func _input_title(node: BrickscriptFlowNode, spec: Dictionary) -> String:
	if node.type == &"call_function":
		var define: BrickscriptFlowNode = _target_functions(node).get(str(node.settings.get(&"function", "")))
		var row: int = int(String(spec["name"]).trim_prefix("arg_")) - 1
		if define != null and row >= 0 and row < Ops.function_params(define).size():
			return str(Ops.function_params(define)[row][0])
	return String(spec["name"]).capitalize()

#endregion


#region Node bricks

## Export's Type / Script only matter for a Node value.
func _node_type_shown(node: BrickscriptFlowNode) -> bool:
	return node.type != &"export" or int(Ops.input_of(node, &"value").get("type", -1)) == Types.ValueType.NODE


## Path (Get node), Scene (Spawn scene), Type, Script: each a text box with
## a dropdown of what the project has. Picking a path or scene fills in the
## Type and Script it finds.
func _add_node_type_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var name: StringName = setting["name"]
	var current: String = str(node.settings.get(name, setting["default"]))
	if setting["kind"] == "node_path":
		var picker: HBoxContainer = PathPicker.build(current, context.guess_path(current), "blank: Self",
			func(path: String, found: Dictionary) -> void:
				var changed: bool = Ops.set_setting(node, name, path)
				if not found.is_empty():
					changed = _set_node_type(node, found) or changed
				if changed:
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"), context.brick_theme)
		_add_row(setting.get("title", String(name).capitalize()), picker)
		return
	var labels: PackedStringArray = []
	var values: PackedStringArray = []
	var found_types: Dictionary = {}
	match setting["kind"]:
		"node_path":
			var guess: Dictionary = context.guess_path(current)
			found_types = guess["types"]
			for path: String in guess["paths"]:
				if path != ".":
					values.append(path)
					labels.append("%s · %s" % [Types.path_shown(path), NodeTypes.describe(found_types[path])])
		"scene":
			for path: String in NodeTypes._scene_files("res://"):
				values.append(path)
				labels.append(path.trim_prefix("res://"))
		"node_class":
			values = NodeTypes.game_node_classes()
			labels = values
		"node_script":
			for path: String in _project_scripts("res://"):
				values.append(path)
				labels.append(path.trim_prefix("res://"))
	var field: HBoxContainer = _pick_field(current, setting.get("info", ""), labels, values, func(typed: String) -> void:
		var changed: bool = Ops.set_setting(node, name, typed)
		match setting["kind"]:
			"node_path":
				var guess: Dictionary = context.guess_path(typed)
				if not (guess["type"] as Dictionary).is_empty():
					changed = _set_node_type(node, guess["type"]) or changed
			"scene":
				var root: Dictionary = NodeTypes.scene_root_type(typed)
				if not root.is_empty():
					changed = _set_node_type(node, root) or changed
			"node_script":
				if not typed.is_empty() and str(node.settings.get(&"node_class", "")).is_empty():
					var base: Dictionary = _script_type(typed)
					changed = Ops.set_setting(node, &"node_class", String(base.get("class", &"Node"))) or changed
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	if setting["kind"] == "node_path":
		var edit: LineEdit = field.get_child(0)
		edit.placeholder_text = "blank: Self"
	_add_row(setting.get("title", String(name).capitalize()), field)


## Group: a text box with a dropdown of the project's groups (and the ones
## this brickscript names). For Nodes in group, picking one fills in the
## Type its nodes share in your scenes.
func _add_group_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var found: Dictionary = {}
	for group: String in NodeTypes.project_groups():
		found[group] = true
	for other: BrickscriptFlowNode in context.graph.nodes:
		var named: String = str(other.settings.get(&"group", "")).strip_edges()
		if not named.is_empty():
			found[named] = true
	var groups: PackedStringArray = PackedStringArray(found.keys())
	groups.sort()
	var field: HBoxContainer = _pick_field(str(node.settings.get(&"group", "")), "e.g. enemies", groups, groups, func(typed: String) -> void:
		var changed: bool = Ops.set_setting(node, &"group", typed)
		if node.type == &"nodes_in_group":
			var shared: Dictionary = NodeTypes.group_type(typed)
			if not shared.is_empty():
				changed = _set_node_type(node, shared) or changed
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	_add_row("Group", field)


## An animation's name: typed in, or picked from the animations of the node
## in its input (a typed-in path, found in the scenes that use this
## brickscript).
func _add_animation_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var data: Dictionary = Ops.input_of(node, setting["target"])
	var names: PackedStringArray = []
	if not data.has("var") and not context.scene_script_path().is_empty():
		names = NodeTypes.animation_names(context.scene_script_path(), str(data.get("value", "")))
	var field: HBoxContainer = _pick_field(str(node.settings.get(setting["name"], "")), "e.g. walk" if names.is_empty() else "pick one", names, names, func(typed: String) -> void:
		if Ops.set_setting(node, setting["name"], typed):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	field.tooltip_text = setting.get("info", "")
	_add_row(setting.get("title", "Animation"), field)


## Layers: layer numbers typed in ("1, 3"; blank: all), and a dropdown of
## the project's layers (named ones by name) that switches one on or off.
func _add_layers_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var current: String = str(node.settings.get(setting["name"], ""))
	var on: Array[int] = []
	for part: String in current.replace(" ", ",").split(",", false):
		if part.is_valid_int():
			on.append(int(part))
	var vector: int = int(Ops.input_of(node, &"from" if node.type == &"raycast" else &"at").get("type", Types.ValueType.VECTOR3))
	var section: String = "layer_names/%s_physics/layer_%d" % ["2d" if vector == Types.ValueType.VECTOR2 else "3d", 0]
	var labels: PackedStringArray = []
	var values: PackedStringArray = []
	for layer: int in range(1, 33):
		var named: String = str(ProjectSettings.get_setting(section.trim_suffix("0") + str(layer), ""))
		if named.is_empty() and layer > 8 and not on.has(layer):
			continue
		var toggled: Array[int] = on.duplicate()
		if toggled.has(layer):
			toggled.erase(layer)
		else:
			toggled.append(layer)
		toggled.sort()
		labels.append("%s %d%s" % ["[x]" if on.has(layer) else "[ ]", layer, " · " + named if not named.is_empty() else ""])
		values.append(", ".join(toggled.map(func(number: int) -> String: return str(number))))
	var field: HBoxContainer = _pick_field(current, "blank: all layers", labels, values, func(typed: String) -> void:
		if Ops.set_setting(node, setting["name"], typed):
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	_add_row(setting.get("title", "Layers"), field)


## Sets a node brick's Type and Script to a found node type.
func _set_node_type(node: BrickscriptFlowNode, node_type: Dictionary) -> bool:
	var changed: bool = Ops.set_setting(node, &"node_class", String(node_type.get("class", &"")))
	return Ops.set_setting(node, &"node_script", str(node_type.get("script", ""))) or changed


static func _script_type(path: String) -> Dictionary:
	if BrickFile.is_script_path(path):
		var graph: BrickscriptFlowGraph = BrickFile.load_graph(path)
		return {"class": graph.base_type if graph != null else &"Node", "script": path}
	return NodeTypes.of_script(path)


## The project's scripts (.gd and brickscripts), outside addons/.
static func _project_scripts(folder: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return found
	for file: String in dir.get_files():
		if file.ends_with(".gd") or BrickFile.is_script_path(file):
			found.append(folder.path_join(file))
	for sub: String in dir.get_directories():
		if not sub.begins_with(".") and sub != "addons" and not FileAccess.file_exists(folder.path_join(sub).path_join(".gdignore")):
			found.append_array(_project_scripts(folder.path_join(sub)))
	return found


## Property / Method of the node in the setting's `target` input: a text box
## with a dropdown of what that node has (this brickscript's own variables
## or the other script's first, then the class's). Picking one sets up the
## value (Set property: its type; Call method: one row per value).
func _add_member_setting(node: BrickscriptFlowNode, setting: Dictionary) -> void:
	var name: StringName = setting["name"]
	var kind: String = setting["kind"] if setting["kind"] in ["method", "signal"] else "property"
	# A signal event names its node in its own settings; other bricks in an
	# input.
	var node_type: Dictionary = context.node_type_of(node, setting["target"]) if setting.has("target") else context.node_type_of_settings(node)
	var members: Array[Dictionary] = []
	for member: Dictionary in context.members_of(node, node_type):
		if member["kind"] != kind:
			continue
		if (node.type == &"set_property" and Library.mode_of(node) != "Get" or node.type == &"tween_property") and not member["writable"]:
			continue
		if node.type == &"tween_property" and not (member["type"] == Types.ValueType.ANY or Library.TWEEN_TYPES.has(member["type"])):
			continue
		if node.type == &"set_property" and Library.mode_of(node) == "Add" and not member["type"] in Library.ADDABLE_TYPES:
			continue
		members.append(member)
	var labels: PackedStringArray = []
	var values: PackedStringArray = []
	for member: Dictionary in members:
		values.append(member["name"])
		labels.append(member_label(member))
	var current: String = str(node.settings.get(name, ""))
	var field: HBoxContainer = _pick_field(current, "pick or type a name", labels, values, func(typed: String) -> void:
		var changed: bool = Ops.set_setting(node, name, typed)
		var picked: Array = members.filter(func(member: Dictionary) -> bool: return member["name"] == typed)
		if not picked.is_empty():
			changed = _fit_inputs_to(node, picked[0]) or changed
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	var edit: LineEdit = field.get_child(0)
	if not current.is_empty() and not values.has(current):
		edit.add_theme_color_override(&"font_color", WARNING_COLOR)
		edit.tooltip_text = "'%s' isn't known on %s: it's used by name when the game runs." % [current, context.describe_node_type(node_type)]
	_add_row(setting.get("title", String(name).capitalize()), field)
	_target.add_child(_hint("On %s: %d %s(s) to pick from." % [context.describe_node_type(node_type), members.size(), kind]))


## "position · Vector2 (Node2D)", "look_at(Vector2) (Node2D)", "health · Whole (Shared)".
static func member_label(member: Dictionary) -> String:
	var type_text: String = Types.type_name(member["type"]) if member["type"] >= 0 else ""
	if member.get("node", {}).size() > 0:
		type_text = NodeTypes.describe(member["node"])
	if member["kind"] == "signal":
		var values: PackedStringArray = []
		for i: int in member.get("args", []).size():
			var arg_node: Dictionary = member["arg_nodes"][i] if i < member.get("arg_nodes", []).size() else {}
			values.append("%s %s" % [NodeTypes.describe(arg_node) if not arg_node.is_empty() else Types.type_name(member["args"][i]), member["arg_names"][i]])
		return "%s(%s)  (%s)" % [member["name"], ", ".join(values), member["origin"]]
	if member["kind"] == "method":
		var args: PackedStringArray = []
		for arg: int in member.get("args", []):
			args.append(Types.type_name(arg))
		return "%s(%s)%s  (%s)" % [member["name"], ", ".join(args), " → " + type_text if not type_text.is_empty() else "", member["origin"]]
	return "%s · %s  (%s)" % [member["name"], type_text, member["origin"]]


## After picking a member: Set property's value becomes its type (if typed
## in; in Add mode too); Call method gets one value row per
## argument, each typed.
func _fit_inputs_to(node: BrickscriptFlowNode, member: Dictionary) -> bool:
	var changed: bool = false
	var type: int = member["type"]
	match node.type:
		&"set_property", &"tween_property":
			var input: StringName = &"to" if node.type == &"tween_property" else &"value"
			var data: Dictionary = Ops.input_of(node, input)
			if not data.has("var") and type > 0 and Types.is_known(type) and int(data.get("type", -1)) != type:
				changed = Ops.set_input_type(node, input, type)
		&"call_method":
			var args: Array = member.get("args", [])
			changed = Ops.set_row_count(node, args.size())
			for i: int in args.size():
				var input: StringName = StringName("arg_%d" % (i + 1))
				var data: Dictionary = Ops.input_of(node, input)
				if not data.has("var") and args[i] > 0 and Types.is_known(args[i]) and int(data.get("type", -1)) != args[i]:
					changed = Ops.set_input_type(node, input, args[i]) or changed
	return changed

## The values a When signal received provides: its signal's, by name.
func _signal_values(node: BrickscriptFlowNode) -> Dictionary:
	var signal_name: String = str(node.settings.get(&"signal", ""))
	for member: Dictionary in context.members_of(node, context.node_type_of_settings(node)):
		if member["kind"] == "signal" and member["name"] == signal_name:
			var values: Dictionary = {}
			for i: int in member["args"].size():
				values[member["arg_names"][i]] = member["args"][i]
			return values
	return {} if signal_name.is_empty() else {"values": Types.ValueType.LIST}

#endregion


## The class a Resource input wants: the brick's own (Play sound: an
## AudioStream), the property it sets, or the method value it fills; &"" for
## any.
func _resource_class_for(node: BrickscriptFlowNode, spec: Dictionary) -> StringName:
	if spec.has("resource_class"):
		return spec["resource_class"]
	var member_name: String = str(node.settings.get(&"method" if node.type == &"call_method" else &"property", ""))
	if member_name.is_empty() or not node.type in [&"set_property", &"call_method"]:
		return &""
	for member: Dictionary in context.members_for(node, &"of"):
		if member["name"] != member_name:
			continue
		if node.type == &"set_property":
			return member.get("node", {}).get("class", &"")
		var row: int = int(String(spec["name"]).get_slice("_", 1)) - 1
		var classes: Array = member.get("arg_nodes", [])
		return classes[row].get("class", &"") if row >= 0 and row < classes.size() else &""
	return &""


## One input: the mode dropdown, then its editor below.
func _add_input(node: BrickscriptFlowNode, spec: Dictionary) -> void:
	var data: Dictionary = Ops.input_of(node, spec["name"])
	var mode: OptionButton = OptionButton.new()
	if not spec.get("literal_only", false):
		mode.add_item("Variable", VARIABLE_MODE)
		mode.set_item_tooltip(0, "Read a variable: type its name, or pick one")
	for type: int in Ops.literal_types(spec):
		mode.add_item(Types.type_name(type), type)
	var selected_id: int = VARIABLE_MODE if data.has("var") else int(data.get("type", 0))
	mode.select(maxi(0, mode.get_item_index(selected_id)))
	mode.item_selected.connect(func(index: int) -> void:
		var id: int = mode.get_item_id(index)
		var changed: bool = Ops.set_input(node, spec["name"], {"var": ""}) if id == VARIABLE_MODE else Ops.set_input_type(node, spec["name"], id)
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	_add_row(_input_title(node, spec), mode)
	var editor: Control = null
	if data.has("var"):
		var types: Array = spec["types"]
		# A Text variable can hold a file path for a Resource input.
		if types.has(Types.ValueType.RESOURCE) and not types.has(Types.ValueType.TEXT):
			types = types + [Types.ValueType.TEXT]
		var fitting: Array[Dictionary] = context.variables_at(node.id, types, spec.get("writes", false))
		editor = _var_dropdown(str(data["var"]), fitting, false, false, func(picked: String) -> void:
			if Ops.set_input(node, spec["name"], {"var": picked}):
				context.notify_changed(Context.Redraw.CANVAS, "Change property"))
	elif int(data.get("type", 0)) == Types.ValueType.NODE:
		# A node path: picked from the scenes (dropdown or step by step); the
		# node type found is kept with it, so the next bricks know its members.
		var current: String = str(data.get("value", ""))
		editor = PathPicker.build(current, context.guess_path(current), str(spec.get("placeholder", "Self, Self.Parent, or e.g. Self.Parent.UI.Score")),
			func(path: String, found: Dictionary) -> void:
				var value: Dictionary = {"type": Types.ValueType.NODE, "value": path}
				if not found.is_empty() and path != "." and path != "..":
					value["node"] = found
				if Ops.set_input(node, spec["name"], value):
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"), context.brick_theme, str(spec.get("node_script", "")))
	else:
		var type: int = int(data.get("type", 0))
		editor = ValueEditor.build(type, data.get("value"), func(value: Variant) -> void:
			if Ops.set_input(node, spec["name"], {"type": type, "value": value}):
				context.notify_changed(Context.Redraw.CANVAS, "Change property"), _resource_class_for(node, spec) if type == Types.ValueType.RESOURCE else &"")
	_add_row("", editor)


func _add_output(node: BrickscriptFlowNode) -> void:
	var header: Label = Label.new()
	header.text = "Output"
	_target.add_child(header)
	var type: int = _output_type(node)
	var choices: Array[Dictionary] = context.variables_at(node.id, [] if type == Types.ValueType.ANY else [type], true)
	var existing: bool = node.use_var
	var explain: Label = _hint(_output_explanation(node))
	_add_made_variable(node, "Into", node.output_name, existing, choices, _new_name_base(node), &"",
		func(picked: String) -> bool: return Ops.set_output(node, picked, true),
		func() -> void: explain.text = _output_explanation(node))
	_target.add_child(explain)


## Where a brick's value (an Output) or a loop's name goes: one dropdown of
## "(don't keep it)", the existing variables that fit and may be written (as
## found here: script variables, this event's values, chain variables made
## earlier along the wires), and "New variable…", which shows a name box (a
## rename renames every use). `setting` is the name setting, or &"" for the
## Output Var.
func _add_made_variable(node: BrickscriptFlowNode, row_label: String, current: String, existing: bool, choices: Array[Dictionary], base: String, setting: StringName,
		on_existing: Callable, on_renamed: Callable = Callable()) -> void:
	var picker: OptionButton = OptionButton.new()
	picker.fit_to_longest_item = false
	picker.clip_text = true
	picker.add_item("(don't keep it)", PICK_NONE)
	var names: PackedStringArray = []
	for choice: Dictionary in choices:
		if choice["name"] == current and not existing:
			# Its own new variable isn't an existing one to pick.
			continue
		names.append(choice["name"])
		picker.add_item(_choice_label(choice), names.size() - 1)
	if existing and not current.is_empty() and not names.has(current):
		picker.add_item("%s (not usable here)" % current, PICK_MISSING)
		picker.set_item_tooltip(picker.item_count - 1, "No variable with this name exists here, or it doesn't fit: pick another.")
	picker.add_separator()
	picker.add_item("New variable…", PICK_NEW)
	var selected_id: int = PICK_NONE
	if not current.is_empty():
		selected_id = (names.find(current) if names.has(current) else PICK_MISSING) if existing else PICK_NEW
	picker.select(picker.get_item_index(selected_id))
	picker.item_selected.connect(func(index: int) -> void:
		var id: int = picker.get_item_id(index)
		var changed: bool = false
		if id == PICK_NONE:
			changed = Ops.set_output(node, "", false) if setting == &"" else Ops.set_setting(node, setting, "")
		elif id == PICK_NEW:
			var fresh: String = Ops.unique_name(context.graph, base)
			changed = Ops.set_output(node, fresh, false) if setting == &"" else Ops.set_setting(node, setting, fresh)
		elif id < names.size():
			changed = on_existing.call(names[id])
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change property"))
	_add_row(row_label, picker)
	if current.is_empty() or existing:
		return
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = current
	name_edit.placeholder_text = "new variable name"
	name_edit.tooltip_text = "Renaming it also renames it in every brick that uses it."
	_on_commit(name_edit, func() -> void:
		var typed: String = name_edit.text.strip_edges()
		if typed == current or typed.is_empty():
			name_edit.text = current
		elif Ops.rename_made_output(context.graph, node, setting, typed):
			# Not rebuilt: tabbing out of the name keeps your place.
			current = typed
			if on_renamed.is_valid():
				on_renamed.call()
			context.notify_changed(Context.Redraw.CANVAS, "Rename variable")
		else:
			name_edit.text = current
			name_edit.tooltip_text = "'%s' is not a valid name, or is already used." % typed)
	_add_row("Name", name_edit)


## "health · Whole (Shared)", "coins · List of Node2D (chain)", ...
func _choice_label(choice: Dictionary) -> String:
	var node_type: Dictionary = choice.get("node", {})
	var type_text: String = Types.type_name(choice["type"])
	if choice["type"] == Types.ValueType.LIST:
		type_text = NodeTypes.describe_list(node_type)
	elif choice["type"] == Types.ValueType.TABLE:
		type_text = NodeTypes.describe_table(node_type)
	elif not node_type.is_empty() and not node_type.get("self", false):
		type_text = NodeTypes.describe(node_type)
	return "%s · %s (%s)" % [choice["name"], type_text, choice["origin"]]


## What kind of value a brick makes, as far as Properties can tell (Anything
## when it depends on what the game does, e.g. a Formula).
func _output_type(node: BrickscriptFlowNode) -> int:
	var definition: Dictionary = Library.get_definition(node.type)
	var returns: Variant = definition.get("returns", null)
	if returns is int:
		return returns
	match node.type:
		&"get_node", &"find_node", &"get_root", &"find_ancestor", &"spawn_scene", &"as_script", &"raycast", &"get_character", &"nearest_character":
			return Types.ValueType.NODE
		&"get_player":
			return Types.ValueType.PLAYER
		&"get_children", &"nodes_in_group", &"bodies_near", &"find_path":
			return Types.ValueType.LIST
		&"host", &"join":
			return Types.ValueType.BOOL
		&"screen_to_world", &"player_aim":
			return Types.ValueType.VECTOR2 if str(node.settings.get(&"space", "3D")) == "2D" else Types.ValueType.VECTOR3
		&"world_to_screen":
			return Types.ValueType.VECTOR2
		&"set_property", &"call_method":
			var wanted: String = str(node.settings.get(&"property" if node.type == &"set_property" else &"method", ""))
			for member: Dictionary in context.members_for(node, &"of"):
				if member["name"] == wanted and member["type"] >= 0:
					return member["type"]
	return Types.ValueType.ANY


## A first name for a brick's new variable: the node it finds, the property,
## method or group it reads, else a word for what it makes.
static func _new_name_base(node: BrickscriptFlowNode) -> String:
	# Get node Player/Gun -> gun; Find node "Coin" -> coin; As script 07_coin -> coin.
	var found: String = str(node.settings.get(&"path", "")).get_file() if node.type == &"get_node" else \
		str(Ops.input_of(node, &"name").get("value", "")) if node.type in [&"find_node", &"find_ancestor"] else \
		str(node.settings.get(&"node_script", "")).get_file().get_basename().lstrip("0123456789_") if node.type == &"as_script" else ""
	found = found.to_snake_case()
	if found.is_valid_ascii_identifier():
		return found
	for setting: StringName in [&"property", &"method", &"group"]:
		var named: String = str(node.settings.get(setting, "")).strip_edges()
		if named.is_valid_ascii_identifier():
			return named
	var bases: Dictionary = {&"get_node": "node", &"find_node": "found", &"as_script": "node", &"spawn_scene": "spawned", &"get_children": "children", &"make_list": "list",
		&"make_table": "table", &"get_item": "item", &"get_value": "value", &"size": "count", &"has": "found", &"is_in_group": "in_group", &"is_mine": "mine", &"this_player": "player", &"my_player": "me", &"get_character": "character", &"get_player": "player", &"get_root": "root", &"find_ancestor": "ancestor",
		&"make_vector2": "vector", &"make_vector3": "vector", &"add": "sum", &"subtract": "difference", &"multiply": "product", &"divide": "quotient",
		&"formula": "result", &"host": "hosting", &"join": "joined", &"bodies_near": "nearby", &"raycast": "hit", &"find_path": "path", &"nearest_character": "nearest", &"random_spot": "spot", &"mesh_vertices": "points",
		&"screen_to_world": "ray_to", &"player_aim": "aim", &"world_to_screen": "screen_point"}
	return bases.get(node.type, "value")


static func _output_explanation(node: BrickscriptFlowNode) -> String:
	if node.output_name.is_empty():
		return "The result isn't kept. Name it to use it in later nodes."
	if node.use_var:
		return "Writes the result into the existing variable '%s'." % node.output_name
	return "Makes the chain variable '%s': later nodes of this event can read it; it resets every run." % node.output_name


## The event's outputs in run order, with up / down to swap neighbours.
func _add_event_outputs(event: BrickscriptFlowNode) -> void:
	var header: Label = Label.new()
	header.text = "Outputs (run in this order)"
	_target.add_child(header)
	var highest: int = Ops.highest_output(event)
	if highest == 0:
		_target.add_child(_hint("Drag from \"+ output\" to the node that should run first."))
		return
	for number: int in range(1, highest + 1):
		var target: BrickscriptFlowNode = context.graph.node_by_id(event.exits.get(StringName(str(number)), 0))
		var row: HBoxContainer = HBoxContainer.new()
		var label: Label = Label.new()
		label.text = "%d → %s" % [number, Library.get_definition(target.type).get("title", "?") if target != null else "(nothing)"]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		for step: Array in [[-1, &"MoveUp", "↑"], [1, &"MoveDown", "↓"]]:
			var button: Button = Button.new()
			button.flat = true
			button.icon = context.brick_theme.icon(step[1])
			if button.icon == null:
				button.text = step[2]
			button.tooltip_text = "Run earlier" if step[0] < 0 else "Run later"
			button.disabled = number + step[0] < 1 or number + step[0] > highest
			button.pressed.connect(func() -> void:
				if Ops.swap_outputs(event, number, number + step[0]):
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Reorder outputs"))
			row.add_child(button)
		_target.add_child(row)
	_target.add_child(_hint("Drag from \"+ output\" to add another."))

#endregion


#region Editors

## Action name: type it, or pick from the project's Input Map. `setting` is
## the setting it fills (Player Direction has four).
func _action_field(node: BrickscriptFlowNode, setting: StringName = &"action") -> HBoxContainer:
	var actions: PackedStringArray = context.action_names()
	var field: HBoxContainer = _pick_field(str(node.settings.get(setting, "")), "action", actions, actions, func(typed: String) -> void:
		if Ops.set_setting(node, setting, typed):
			context.notify_changed(Context.Redraw.CANVAS, "Change property"))
	var edit: LineEdit = field.get_child(0)
	var mark: Callable = func(_typed: String = "") -> void:
		var unknown: bool = not actions.has(edit.text.strip_edges())
		edit.tooltip_text = "'%s' is not in the project's Input Map (Project Settings > Input Map)" % edit.text if unknown else ""
		if unknown:
			edit.add_theme_color_override(&"font_color", WARNING_COLOR)
		else:
			edit.remove_theme_color_override(&"font_color")
	edit.text_changed.connect(mark)
	mark.call()
	return field


## A dropdown of variables (`choices` from context.variables_at()), shown as
## "name · Type (where it comes from)". A current name that isn't usable here
## stays listed, marked, so nothing changes silently. With `offer_new`, the
## last entry is "New variable…" (picked: a fresh unique name).
func _var_dropdown(current: String, choices: Array[Dictionary], offer_new: bool, new_selected: bool, on_pick: Callable) -> OptionButton:
	var picker: OptionButton = OptionButton.new()
	picker.fit_to_longest_item = false
	picker.clip_text = true
	var names: PackedStringArray = []
	if current.is_empty() and not new_selected:
		picker.add_item("(choose a variable)", PICK_NONE)
	for choice: Dictionary in choices:
		names.append(choice["name"])
		picker.add_item(_choice_label(choice), names.size() - 1)
	if not current.is_empty() and not names.has(current):
		picker.add_item("%s (not usable here)" % current, PICK_MISSING)
		picker.set_item_tooltip(picker.item_count - 1, "No variable with this name exists here, or it doesn't fit: pick another.")
	if offer_new:
		picker.add_separator()
		picker.add_item("New variable…", PICK_NEW)
	var selected_id: int = PICK_NEW if new_selected else (names.find(current) if names.has(current) else (PICK_NONE if current.is_empty() else PICK_MISSING))
	picker.select(picker.get_item_index(selected_id))
	if choices.is_empty() and not offer_new:
		picker.tooltip_text = "No fitting variables here: script variables, this event's values and chain variables made earlier in this event are listed."
	picker.item_selected.connect(func(index: int) -> void:
		var id: int = picker.get_item_id(index)
		if id < names.size():
			on_pick.call(names[id])
		elif id == PICK_NEW:
			on_pick.call(Ops.unique_name(context.graph, "value")))
	return picker


## A text box with a dropdown of suggestions next to it: `labels` are shown,
## picking one puts its `values` entry in the box.
func _pick_field(current: String, placeholder: String, labels: PackedStringArray, values: PackedStringArray, on_commit: Callable) -> HBoxContainer:
	var box: HBoxContainer = HBoxContainer.new()
	box.add_theme_constant_override(&"separation", 0)
	var edit: LineEdit = LineEdit.new()
	edit.text = current
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_on_commit(edit, func() -> void: on_commit.call(edit.text.strip_edges()))
	box.add_child(edit)
	var menu: MenuButton = MenuButton.new()
	menu.flat = true
	menu.tooltip_text = "Pick one"
	menu.icon = context.brick_theme.icon(&"GuiDropdown")
	if menu.icon == null:
		menu.text = "v"
	menu.disabled = labels.is_empty()
	var popup: PopupMenu = menu.get_popup()
	for label: String in labels:
		popup.add_item(label)
	popup.index_pressed.connect(func(index: int) -> void:
		edit.text = values[index]
		on_commit.call(edit.text))
	box.add_child(menu)
	return box


func _add_row(label_text: String, editor: Control) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	var label: Label = Label.new()
	label.text = label_text
	label.custom_minimum_size.x = LABEL_WIDTH
	row.add_child(label)
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(editor)
	_target.add_child(row)


func _hint(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate.a = 0.7
	return label


static func _on_commit(edit: LineEdit, commit: Callable) -> void:
	edit.text_submitted.connect(func(_typed: String) -> void: commit.call())
	edit.focus_exited.connect(commit)

#endregion


func _reached(node: BrickscriptFlowNode) -> bool:
	for other: BrickscriptFlowNode in context.graph.nodes:
		if Ops.is_event(other) and Ops.leads_to(context.graph, other, node):
			return true
	return false
