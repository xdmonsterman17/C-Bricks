extends VBoxContainer

## What each kind of new variable is (Brickscript's words, flow_inspector.gd KIND_HINTS).
const KIND_HINTS: Dictionary = {
	"Chain": "Chain: only bricks after this one in this event or function can use it; it resets every run.",
	"Shared": "Shared: every event and function of this script can use it, and it keeps its value between runs.",
}
## Right sidebar (after Brickscript's flow_inspector.gd): the properties of the
## brick selected on the canvas, in two sections, Inputs then Outputs:
## - Inputs: its settings (Mode, Compare, Operation...), then each input: one
##   dropdown, "Variable" (then a dropdown of the variables usable at this brick
##   that fit) or a value type (then a box to type the value in).
## - Outputs: where the result goes ("Into": not kept, an existing variable, or
##   New variable… and its name), Variable (Set)'s target, an event's outputs in
##   run order (↑ / ↓ to reorder) and what runs next.
## Clicking a palette entry shows what that brick does instead; a selected
## comment frame shows its title and color.

const Context = preload("res://scripts/editor/context.gd")
const BrickTheme = preload("res://scripts/editor/brick_theme.gd")
const T = preload("res://scripts/node_defs.gd")

const FRAME_SWATCHES: Array[Color] = [Color(0.25, 0.3, 0.4), Color(0.2, 0.45, 0.6), Color(0.2, 0.5, 0.3), Color(0.55, 0.5, 0.2),
	Color(0.6, 0.3, 0.2), Color(0.55, 0.25, 0.45), Color(0.4, 0.3, 0.6), Color(0.35, 0.35, 0.35)]
const VARIABLE_MODE: int = 1000
const PICK_NONE: int = 100000
const PICK_MISSING: int = 100001
const PICK_NEW: int = 100002
const LABEL_WIDTH: float = 60.0
const RIGHT_PADDING: int = 12

var context: Context = null

var _title: Label = null
var _scroll: ScrollContainer = null
var _body: VBoxContainer = null
var _target: VBoxContainer = null
## The world object view: its tab (0 Properties, 1 Groups) and which folds are open (key -> bool).
var _world_tab := 0
## The shown world object's field editors (live updates while the 2D / 3D screens drag it).
var _world_edits := {}
var _world_edits_of := 0
var _folds := {}


func _init() -> void:
	var header := Label.new()
	header.text = "Properties"
	add_child(header)
	_title = Label.new()
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.add_theme_font_size_override(&"font_size", 16)
	add_child(_title)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override(&"margin_right", RIGHT_PADDING)
	_scroll.add_child(margin)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_body)
	_target = _body
	resized.connect(func() -> void: _align_labels())


func _ready() -> void:
	# (user, 2026-11-07) values follow a drag in the 2D / 3D screens as it happens: the
	# field's text only, no rebuild (rebuilding mid-drag would be slow and steal focus)
	context.world_live.connect(func(id: int, fname: String, text: String) -> void:
		if id == _world_edits_of and _world_edits.has(fname) and is_instance_valid(_world_edits[fname]):
			(_world_edits[fname] as LineEdit).text = text)


func rebuild() -> void:
	Context.commit_focused(self)
	_align_labels.call_deferred()
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_target = _body
	var frame := Ops.frame_by_id(context.graph, context.selected) if context.selected > 0 else {}
	if not frame.is_empty():
		_show_frame(frame)
		return
	var node := context.selected_node()
	if node.is_empty() and context.info_type != "":
		_show_info(context.info_type)
		return
	if node.is_empty() and not context.world_object.is_empty():
		_show_world_object(context.world_object)
		return
	if node.is_empty():
		_title.text = ""
		_title.remove_theme_color_override(&"font_color")
		if context.has_graph():
			_show_script_settings()
		_target.add_child(_hint("Click a brick on the canvas to see and edit its properties, or a palette entry to see what it does.\n\nRight-click the canvas (or drag from the palette) to add bricks; drag from a ▶ port to wire what runs next.\n\nVariables come from bricks: Variable (Set) and every brick's Output make them."))
		return
	var def: Dictionary = T.DEFS[node.type]
	_title.text = T.title_of(node.type, node.fields)
	_title.add_theme_color_override(&"font_color", context.brick_theme.category_color(def.cat))
	match T.kind_of(node.type):
		"event":
			_target.add_child(_hint("Event: starts chains. Its outputs run in order, each to the end, before the next."))
		"declare":
			_target.add_child(_hint("A declaration: no wires; it applies to the whole file."))
		"reroute":
			_target.add_child(_hint("A reroute point: it only bends the wire. Delete it to straighten the wire."))
		_:
			if not context.scopes.has(int(node.id)) or not _reached(node):
				_target.add_child(_hint("Not wired to an event yet: it won't run."))
	var inputs_tab := _section("Inputs")
	var outputs_tab := _section("Outputs")

	_target = inputs_tab
	for f in def.get("fields", []):
		if not T.shown(f, node.fields, 5):
			continue
		if f[1] == "var" and str(node.fields.get("mode", "Set")) == "Set":
			continue  # Variable (Set)'s target is in Outputs
		if f.size() > 6 and f[6] == "new":
			continue  # shown with the new variable's name
		_add_field(node, f)
	var lay := Ops.layout(context.graph, node)
	for a in lay.args:
		if T.shown(a, node.fields, 4):
			_add_input(node, a)
	if inputs_tab.get_child_count() == 0:
		_target.add_child(_hint("No inputs."))

	_target = outputs_tab
	for f in def.get("fields", []):
		if f[1] == "var" and str(node.fields.get("mode", "Set")) == "Set":
			_add_set_target(node, f)
	for o in lay.outs:
		if T.shown(o, node.fields, 4):
			_add_output(node, o)
	if T.kind_of(node.type) == "event":
		_add_event_outputs(node)
	elif T.kind_of(node.type) == "action":
		_add_runs_next(node, lay)
	if outputs_tab.get_child_count() == 0:
		_target.add_child(_hint("Nothing."))

	_target = _body
	_target.add_child(HSeparator.new())
	if Vector2(node.size[0], node.size[1]) != Vector2.ZERO:
		var fit := Button.new()
		fit.text = "Fit to content"
		fit.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		fit.tooltip_text = "Undo resizing: size the brick to what it shows again."
		fit.pressed.connect(func() -> void:
			if Ops.set_size(node, Vector2.ZERO):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Fit brick to content"))
		_target.add_child(fit)
	# A note on any brick: shown on it, and as a comment in the C.
	var note := LineEdit.new()
	note.text = str(node.get("note", ""))
	note.placeholder_text = "a note for this brick"
	_on_commit(note, func() -> void:
		if str(node.get("note", "")) != note.text.strip_edges():
			node["note"] = note.text.strip_edges()
			context.notify_changed(Context.Redraw.CANVAS, "Note"))
	_add_row("Note", note)
	if node.type == "call" and str(node.fields.get("function", "")) != "":
		var go := Button.new()
		go.text = "Go to function %s" % node.fields.function
		go.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		go.pressed.connect(func() -> void:
			if context.on_goto_function.is_valid():
				context.on_goto_function.call(str(node.fields.function)))
		_target.add_child(go)
	if T.kind_of(node.type) == "action":
		var on: bool = int(node.id) in context.breakpoints().map(func(x): return int(x))
		var bp := Button.new()
		bp.text = "Remove breakpoint" if on else "Add breakpoint"
		bp.tooltip_text = "Pause the program here when it's run from the editor (F9)."
		bp.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		bp.pressed.connect(func() -> void:
			if context.on_toggle_breakpoint.is_valid():
				context.on_toggle_breakpoint.call(int(node.id)))
		_target.add_child(bp)
	var remove := Button.new()
	remove.text = "Delete brick"
	remove.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	remove.icon = context.brick_theme.icon("remove")
	remove.pressed.connect(func() -> void:
		if Ops.delete_node(context.graph, node):
			context.select(0)
			context.notify_changed(Context.Redraw.ALL, "Delete brick"))
	_target.add_child(remove)


func _reached(node: Dictionary) -> bool:
	for other in context.graph.nodes:
		if T.kind_of(other.type) == "event" and Ops.leads_to(context.graph, other, node):
			return true
	return false


func _section(title: String) -> VBoxContainer:
	var header := Label.new()
	header.text = title
	header.add_theme_color_override(&"font_color", context.brick_theme.accent_color())
	_body.add_child(HSeparator.new())
	_body.add_child(header)
	var page := VBoxContainer.new()
	page.name = title
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(page)
	return page


# ------------------------------------------------------------------ settings

func _field_title(f: Array) -> String:
	return str(f[4]) if f.size() > 4 and f[4] != null else str(f[0]).capitalize()


func _add_field(node: Dictionary, f: Array) -> void:
	var fname: String = f[0]
	var title := _field_title(f)
	match f[1]:
		"option":
			var ob := OptionButton.new()
			ob.fit_to_longest_item = false
			ob.clip_text = true
			var opts: Array = f[3]
			for o in opts:
				ob.add_item(str(o))
			ob.select(maxi(0, opts.find(node.fields.get(fname, f[2]))))
			ob.item_selected.connect(func(i: int) -> void:
				if Ops.set_field(node, fname, opts[i]):
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change " + title.to_lower()))
			_add_row(title, ob)
		"check":
			var cb := CheckBox.new()
			cb.button_pressed = bool(node.fields.get(fname, f[2]))
			cb.text = "on" if cb.button_pressed else "off"
			cb.toggled.connect(func(on: bool) -> void:
				cb.text = "on" if on else "off"
				if Ops.set_field(node, fname, on):
					context.notify_changed(Context.Redraw.CANVAS, "Change " + title.to_lower()))
			_add_row(title, cb)
		"line":
			var le := LineEdit.new()
			le.text = str(node.fields.get(fname, f[2]))
			_on_commit(le, func() -> void:
				var typed := le.text.strip_edges()
				if node.type == "function" and fname == "name":
					var old_name := str(node.fields.name)
					if Ops.rename_function(context.graph, node, typed):
						if context.on_function_renamed.is_valid():
							context.on_function_renamed.call(old_name, typed)
						context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Rename function")
					else:
						le.text = str(node.fields.name)
						le.tooltip_text = "'%s' is not a valid function name, or another function has it." % typed
					return
				if Ops.set_field(node, fname, le.text):
					context.notify_changed(Context.Redraw.CANVAS, "Change " + title.to_lower()))
			_add_row(title, le)
			if node.type == "formula":
				_target.add_child(_hint("A C expression: variable names, numbers, + - * / % ( ), comparisons, && || and <math.h> functions like sqrt, pow, fabs."))
		"text":
			var header := Label.new()
			header.text = title
			_target.add_child(header)
			var te := TextEdit.new()
			te.text = str(node.fields.get(fname, f[2]))
			te.custom_minimum_size.y = 140
			te.scroll_fit_content_height = true
			te.add_theme_font_override(&"font", _mono())
			te.focus_exited.connect(func() -> void:
				if Ops.set_field(node, fname, te.text):
					context.notify_changed(Context.Redraw.CANVAS, "Change code"))
			_target.add_child(te)
			_target.add_child(_hint("Written into the program as it is (saved when you click away)."))
		"var":
			var want := T.ANY
			var writable := str(node.fields.get("mode", "")) == "Add"
			var choices := context.variables_at(int(node.id), want)
			if writable:
				choices = choices.filter(func(c): return c.type in ["int", "float"])
			_add_row(title, _var_dropdown(str(node.fields.get(fname, "")), choices, func(picked: String) -> void:
				if Ops.set_field(node, fname, picked):
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change variable")))
		"func":
			var ob := OptionButton.new()
			ob.fit_to_longest_item = false
			ob.clip_text = true
			var names: Array = Ops.functions(context.graph).keys()
			names.sort()
			var cur := str(node.fields.get(fname, ""))
			ob.add_item("(choose a function)", PICK_NONE)
			for i in names.size():
				ob.add_item(names[i], i)
			if cur != "" and cur not in names:
				ob.add_item("%s (missing)" % cur, PICK_MISSING)
			ob.select(ob.get_item_index(names.find(cur) if cur in names else (PICK_NONE if cur == "" else PICK_MISSING)))
			if names.is_empty():
				ob.tooltip_text = "No functions yet: add a Define Function brick."
			ob.item_selected.connect(func(i: int) -> void:
				var id := ob.get_item_id(i)
				if id < names.size() and Ops.set_field(node, fname, names[id]):
					Ops.refit_calls(context.graph)
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Pick function"))
			_add_row(title, ob)
		"params":
			_add_params(node, fname)
		"extends", "class", "method", "scene", "remote":
			# Extends: Object or another class; Class: a class (New object, Is a...);
			# Method: the methods of the brick's Class (its own and inherited).
			var opts := []
			var none_text := ""
			if f[1] == "scene":
				for p in CBProject.list_scenes(context.project_dir) if context.project_dir != "" else []:
					opts.append(CBProject.rel_path(context.project_dir, p))
				none_text = "(no scenes: make a .cbscene in FileSystem)"
			elif f[1] == "remote":
				# The project's remotes that go this brick's way (Define Remote's Direction).
				var ways: Array = ["Ask server"] if node.type in ["invoke_server", "on_client_invoked"] else (["To server", "Both"] if node.type in ["fire_server", "on_client_fired"] else ["To clients", "Both"])
				for rn in CBTypes.remotes:
					if str(CBTypes.remotes[rn].direction) in ways:
						opts.append(rn)
				opts.sort()
				none_text = "(no remotes this way: add a Define Remote brick)"
			elif f[1] == "method":
				var ms := CBTypes.all_methods(str(node.fields.get("class", "")))
				opts = ms.keys().filter(func(m): return not ms[m].get("event", false))
				none_text = "(pick the Class first)" if str(node.fields.get("class", "")) == "" else "(it has no methods)"
			else:
				opts = CBTypes.classes.keys()
				opts.sort()
				if f[1] == "extends":
					opts.erase(str(node.fields.get("name", "")))
				opts.push_front(CBTypes.OBJECT)
				none_text = "(no classes: give a script a Class brick)"
			var cur := str(node.fields.get(fname, f[2]))
			if cur != "" and cur not in opts:
				opts.append(cur)
			var ob := OptionButton.new()
			ob.fit_to_longest_item = false
			ob.clip_text = true
			if opts.is_empty():
				ob.add_item(none_text)
				ob.set_item_disabled(0, true)
			elif cur == "":
				ob.add_item("(choose)")
				ob.set_item_disabled(0, true)
			for o in opts:
				ob.add_item(str(o))
			var offset := 1 if (cur == "" or opts.is_empty()) else 0
			ob.select(maxi(0, opts.find(cur) + offset) if cur != "" else 0)
			ob.item_selected.connect(func(i: int) -> void:
				var k := i - offset
				if k >= 0 and k < opts.size() and Ops.set_field(node, fname, opts[k]):
					if node.type == "call_method":
						if f[1] == "class" and not CBTypes.all_methods(str(opts[k])).has(str(node.fields.get("method", ""))):
							node.fields.method = ""
						Ops.refit_calls(context.graph)
					if node.type in ["fire_server", "fire_clients", "invoke_server"]:
						Ops.refit_calls(context.graph)  # a row per value of the remote
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change " + title.to_lower()))
			_add_row(title, ob)
		"type", "type_void", "record":
			# A type picker: basics and records ("type": what a list holds),
			# plus lists ("type_void": what a function gives back, with void).
			var opts := []
			if f[1] == "type_void":
				opts = ["void"] + Array(CBTypes.all(context.records))
			elif f[1] == "record":
				opts = context.records.keys()
				opts.sort()
			else:
				opts = Array(CBTypes.BASIC) + context.records.keys()
			var cur := str(node.fields.get(fname, f[2]))
			if cur != "" and cur not in opts:
				opts.append(cur)
			var ob := OptionButton.new()
			ob.fit_to_longest_item = false
			ob.clip_text = true
			if opts.is_empty():
				ob.add_item("(no records: add a Define Record)")
				ob.set_item_disabled(0, true)
			for o in opts:
				ob.add_item(str(o))
			ob.select(maxi(0, opts.find(cur)))
			ob.item_selected.connect(func(i: int) -> void:
				if i < opts.size() and Ops.set_field(node, fname, opts[i]):
					if node.type == "function":
						Ops.refit_calls(context.graph)
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change " + title.to_lower()))
			_add_row(title, ob)
		"field":
			# The fields of the record the brick's Record input holds.
			var rvar := str(node.args.get("record", {}).get("var", ""))
			var rtype := str(context.types.get(rvar, ""))
			var names := []
			for fld in context.records.get(rtype, []):
				names.append(fld[0])
			if CBTypes.is_class_type(rtype):
				for fld in CBTypes.all_fields(rtype):
					names.append(fld[0])
			var cur := str(node.fields.get(fname, ""))
			var ob := OptionButton.new()
			ob.fit_to_longest_item = false
			ob.clip_text = true
			if names.is_empty():
				ob.add_item("(pick a record or object variable first)" if rtype == "" else "(%s has no fields)" % rtype)
				ob.set_item_disabled(0, true)
			for nm in names:
				ob.add_item(nm)
			if cur != "" and cur not in names:
				ob.add_item("%s (not in %s)" % [cur, rtype if rtype != "" else "?"])
				names.append(cur)
			ob.select(maxi(0, names.find(cur)))
			ob.item_selected.connect(func(i: int) -> void:
				if i < names.size() and Ops.set_field(node, fname, names[i]):
					context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Pick field"))
			_add_row(title, ob)
		"cases":
			_add_cases(node, fname)


## Define Function's inputs: a name and a type each, + / - to add or remove.
func _add_params(node: Dictionary, fname: String) -> void:
	var header := Label.new()
	header.text = "Fields" if node.type in ["record", "class"] else "Inputs"
	_target.add_child(header)
	var params: Array = node.fields.get(fname, [])
	var commit := func() -> void:
		Ops.refit_calls(context.graph)
		context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change function inputs")
	for i in params.size():
		var row := HBoxContainer.new()
		var le := LineEdit.new()
		le.text = str(params[i][0])
		le.placeholder_text = "name"
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_on_commit(le, func() -> void:
			var typed := le.text.strip_edges()
			if typed.is_valid_identifier() and typed != params[i][0]:
				params[i][0] = typed
				commit.call()
			else:
				le.text = str(params[i][0]))
		row.add_child(le)
		var ob := OptionButton.new()
		ob.fit_to_longest_item = false
		ob.clip_text = true
		var tnames := Array(CBTypes.all(context.records))
		if node.type == "record":
			# A record can hold a list or map of itself (not itself).
			tnames.erase(str(node.fields.get("name", "")))
			if CBTypes.list_of(str(node.fields.get("name", ""))) not in tnames:
				tnames.append(CBTypes.list_of(str(node.fields.get("name", ""))))
			if CBTypes.map_of(str(node.fields.get("name", ""))) not in tnames:
				tnames.append(CBTypes.map_of(str(node.fields.get("name", ""))))
		if params[i][1] not in tnames:
			tnames.append(params[i][1])
		for t in tnames:
			ob.add_item(t)
		ob.select(maxi(0, tnames.find(params[i][1])))
		ob.item_selected.connect(func(k: int) -> void:
			params[i][1] = tnames[k]
			commit.call())
		row.add_child(ob)
		var rm := Button.new()
		rm.flat = true
		rm.icon = context.brick_theme.icon("remove")
		rm.tooltip_text = "Remove this input"
		rm.pressed.connect(func() -> void:
			params.remove_at(i)
			commit.call())
		row.add_child(rm)
		_target.add_child(row)
	var add := Button.new()
	add.text = "Add field" if node.type in ["record", "class"] else "Add input"
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add.icon = context.brick_theme.icon("add")
	add.pressed.connect(func() -> void:
		var used := params.map(func(p): return p[0])
		var base := "abcdefghijklmnopqrstuvwxyz"
		var nm := "arg"
		for ch in base:
			if ch not in used:
				nm = ch
				break
		params.append([nm, "int"])
		node.fields[fname] = params
		commit.call())
	_target.add_child(add)
	if params.is_empty():
		_target.add_child(_hint("No inputs: Call Function calls it with ()."))


## Switch's cases: one value each (a number, or text when the value is text), + / -.
func _add_cases(node: Dictionary, fname: String) -> void:
	var header := Label.new()
	header.text = "Cases (each gets its own exit)"
	_target.add_child(header)
	var cases: Array = node.fields.get(fname, [])
	var commit := func() -> void:
		node.fields[fname] = cases
		context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change cases")
	for i in cases.size():
		var row := HBoxContainer.new()
		var le := LineEdit.new()
		le.text = str(cases[i])
		le.placeholder_text = "a value"
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_on_commit(le, func() -> void:
			if le.text != str(cases[i]):
				cases[i] = le.text
				commit.call())
		row.add_child(le)
		var rm := Button.new()
		rm.flat = true
		rm.icon = context.brick_theme.icon("remove")
		rm.tooltip_text = "Remove this case (its chains are dropped)"
		rm.pressed.connect(func() -> void:
			cases.remove_at(i)
			# Later cases move up a place: their wires follow.
			for k in range(i, cases.size()):
				node.links["case_%d" % k] = node.links.get("case_%d" % (k + 1), [])
			node.links.erase("case_%d" % cases.size())
			commit.call())
		row.add_child(rm)
		_target.add_child(row)
	var add := Button.new()
	add.text = "Add case"
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add.icon = context.brick_theme.icon("add")
	add.pressed.connect(func() -> void:
		cases.append(str(cases.size() + 1))
		commit.call())
	_target.add_child(add)


# ------------------------------------------------------------------ inputs

func _add_input(node: Dictionary, a: Array) -> void:
	var aname: String = a[0]
	var data: Dictionary = node.args.get(aname, Ops.default_arg(a))
	var mode := OptionButton.new()
	mode.fit_to_longest_item = false
	mode.clip_text = true
	mode.add_item("Variable", VARIABLE_MODE)
	mode.set_item_tooltip(0, "Read a variable: pick one")
	var lits := T.literal_types(a[1])
	for i in lits.size():
		mode.add_item(lits[i], i)
		mode.set_item_tooltip(mode.item_count - 1, T.TYPE_HINTS.get(lits[i], ""))
	var cur_id := VARIABLE_MODE if data.has("var") else maxi(0, lits.find(str(data.get("type", lits[0]))))
	mode.select(maxi(0, mode.get_item_index(cur_id)))
	mode.item_selected.connect(func(index: int) -> void:
		var id := mode.get_item_id(index)
		var changed: bool
		if id == VARIABLE_MODE:
			changed = Ops.set_arg(node, aname, {"var": ""})
		else:
			changed = Ops.set_arg(node, aname, {"type": lits[id], "value": str(data.get("value", a[2]))})
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change input"))
	var title := aname.capitalize() if node.type != "call" else aname
	_add_row(title, mode)
	var editor: Control
	if data.has("var"):
		editor = _var_dropdown(str(data.var), context.variables_at(int(node.id), a[1]), func(picked: String) -> void:
			if Ops.set_arg(node, aname, {"var": picked}):
				context.notify_changed(Context.Redraw.CANVAS, "Change input"))
		if context.debug_values.has(str(data.var)):
			_add_row("", editor)
			_target.add_child(_now(str(data.var)))
			return
	else:
		var t := str(data.get("type", lits[0]))
		var le := LineEdit.new()
		le.text = str(data.get("value", ""))
		le.placeholder_text = {"int": "0, or an expression", "float": "0.0, or an expression", "bool": "true / false, or a condition", "string": "text", "vector3": "x, y, z", "vector2": "x, y"}.get(t, "")
		le.tooltip_text = T.TYPE_HINTS.get(t, "")
		if t != "string":
			le.add_theme_font_override(&"font", _mono())
		_on_commit(le, func() -> void:
			if Ops.set_arg(node, aname, {"type": t, "value": le.text}):
				context.notify_changed(Context.Redraw.CANVAS, "Change input"))
		editor = le
	_add_row("", editor)


# ------------------------------------------------------------------ outputs

## Variable (Set)'s target: a variable that may be written, or New variable…
## with a name box (and its Kind) when no other brick makes it.
func _add_set_target(node: Dictionary, f: Array) -> void:
	var header := Label.new()
	header.text = "Variable"
	_target.add_child(header)
	var current := str(node.fields.get("name", ""))
	var is_new := _makers(current, node) == 0
	_add_made_variable(current, is_new, context.variables_at(int(node.id)), "x",
		func(picked: String) -> bool: return Ops.set_field(node, "name", picked),
		func(fresh: String) -> bool: return Ops.set_field(node, "name", fresh),
		func(typed: String) -> bool: return Ops.rename_variable(context.graph, current, typed),
		"", false)
	if is_new:
		for kf in T.DEFS[node.type].fields:
			if kf.size() > 6 and kf[6] == "new":
				_add_field(node, kf)
		var k := str(node.fields.get("scope", "Chain"))
		_target.add_child(_hint(("Makes the variable '%s', typed like its value. " % current + KIND_HINTS.get("Shared" if k in ["Shared", "Global"] else "Chain", "")) if current != "" else "Name the new variable."))
	else:
		_target.add_child(_hint("Writes into the variable '%s'." % current))


func _add_output(node: Dictionary, o: Array) -> void:
	var oname: String = o[0]
	var title := str(o[3]) if o.size() > 3 and o[3] != null else "Into"
	var header := Label.new()
	header.text = "Output" if title == "Into" else title
	_target.add_child(header)
	var data: Dictionary = node.outs.get(oname, {"var": "", "use": false})
	var current := str(data.get("var", ""))
	var use := bool(data.get("use", false))
	var out_type: int = o[1]
	if out_type == T.ANY:
		out_type = T.type_from_name(str(context.types.get(current, "any"))) if current != "" else T.ANY
	var choices := context.variables_at(int(node.id), out_type).filter(func(c): return c.origin != "Input")
	_add_made_variable(current, not use, choices, str(o[2]) if str(o[2]) != "" else "value",
		func(picked: String) -> bool: return Ops.set_out(node, oname, picked, true),
		func(fresh: String) -> bool: return Ops.set_out(node, oname, fresh, false),
		func(typed: String) -> bool: return Ops.rename_variable(context.graph, current, typed),
		title)
	if context.debug_values.has(current):
		_target.add_child(_now(current))
	if current != "" and not use:
		# Its Kind: this chain's (default) or Global (shared by every chain and function).
		var kind := OptionButton.new()
		kind.fit_to_longest_item = false
		kind.add_item("Chain")
		kind.add_item("Shared")
		kind.select(1 if str(data.get("kind", "")) in ["Shared", "Global"] else 0)
		kind.tooltip_text = KIND_HINTS.Chain + "\n" + KIND_HINTS.Shared
		kind.item_selected.connect(func(i: int) -> void:
			var d: Dictionary = node.outs.get(oname, {})
			if i == 1:
				d["kind"] = "Shared"
			else:
				d.erase("kind")
			node.outs[oname] = d
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Variable kind"))
		_add_row("Kind", kind)
	if current == "":
		_target.add_child(_hint("The result isn't kept. Name it to use it in later bricks."))
	elif use:
		_target.add_child(_hint("Writes the result into the existing variable '%s'." % current))
	else:
		_target.add_child(_hint("Makes the variable '%s': later bricks of this chain can read it%s." % [current, " (Shared: every event and function can)" if str(data.get("kind", "")) in ["Shared", "Global"] else ""]))


## How many other bricks make (set) `name`.
func _makers(name: String, except: Dictionary) -> int:
	var count := 0
	if name == "":
		return 0
	for n in context.graph.nodes:
		if int(n.id) == int(except.id):
			continue
		if n.type == "var" and str(n.fields.get("mode")) == "Set" and n.fields.get("name") == name:
			count += 1
		for o in n.outs.values():
			if o.get("var") == name and not o.get("use", false):
				count += 1
	for p in context.graph.nodes.filter(func(n): return n.type == "function"):
		for param in T.parse_params(p.fields.get("params", [])):
			if param[1] == name:
				count += 1
	return count


## One dropdown of "(don't keep it)", the existing variables that fit, and
## "New variable…", which shows a name box (a rename renames every use).
func _add_made_variable(current: String, is_new: bool, choices: Array, base: String, on_existing: Callable, on_fresh: Callable, on_renamed: Callable, row_label: String = "Into", allow_none: bool = true) -> void:
	var picker := OptionButton.new()
	picker.fit_to_longest_item = false
	picker.clip_text = true
	if allow_none:
		picker.add_item("(don't keep it)", PICK_NONE)
	var names := []
	for c in choices:
		if c.name == current and is_new:
			continue
		names.append(c.name)
		picker.add_item(_choice_label(c), names.size() - 1)
	if not is_new and current != "" and current not in names:
		picker.add_item("%s (not usable here)" % current, PICK_MISSING)
	picker.add_separator()
	picker.add_item("New variable…", PICK_NEW)
	var sel := PICK_NONE if allow_none else PICK_NEW
	if current != "":
		sel = PICK_NEW if is_new else (names.find(current) if current in names else PICK_MISSING)
	picker.select(maxi(0, picker.get_item_index(sel)))
	picker.item_selected.connect(func(index: int) -> void:
		var id := picker.get_item_id(index)
		var changed := false
		if id == PICK_NONE:
			changed = on_fresh.call("")
		elif id == PICK_NEW:
			changed = on_fresh.call(Ops.unique_name(context.graph, base))
		elif id < names.size():
			changed = on_existing.call(names[id])
		if changed:
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Change output"))
	_add_row(row_label, picker)
	if current == "" or not is_new:
		return
	var name_edit := LineEdit.new()
	name_edit.text = current
	name_edit.placeholder_text = "new variable name"
	name_edit.tooltip_text = "Renaming it also renames it in every brick that uses it."
	name_edit.add_theme_font_override(&"font", _mono())
	_on_commit(name_edit, func() -> void:
		var typed := name_edit.text.strip_edges()
		if typed == current or typed.is_empty():
			name_edit.text = current
		elif typed.is_valid_identifier() and on_renamed.call(typed):
			current = typed
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Rename variable")
		else:
			name_edit.text = current
			name_edit.tooltip_text = "'%s' is not a valid name, or is already used." % typed)
	_add_row("Name", name_edit)


## "score · int (Global)"
static func _choice_label(c: Dictionary) -> String:
	return "%s · %s (%s)" % [c.name, c.type, c.origin]


func _var_dropdown(current: String, choices: Array, on_pick: Callable) -> OptionButton:
	var picker := OptionButton.new()
	picker.fit_to_longest_item = false
	picker.clip_text = true
	var names := []
	if current.is_empty():
		picker.add_item("(choose a variable)", PICK_NONE)
	for c in choices:
		names.append(c.name)
		picker.add_item(_choice_label(c), names.size() - 1)
	if current != "" and current not in names:
		picker.add_item("%s (not usable here)" % current, PICK_MISSING)
		picker.set_item_tooltip(picker.item_count - 1, "No variable with this name is made here, or it doesn't fit: pick another.")
	var sel := names.find(current) if current in names else (PICK_NONE if current.is_empty() else PICK_MISSING)
	picker.select(maxi(0, picker.get_item_index(sel)))
	if choices.is_empty():
		picker.tooltip_text = "No fitting variables here yet: bricks make them with their Output or Variable (Set)."
	picker.item_selected.connect(func(index: int) -> void:
		var id := picker.get_item_id(index)
		if id < names.size():
			on_pick.call(names[id]))
	return picker


## An event's outputs in run order, ↑ / ↓ to swap neighbours.
func _add_event_outputs(node: Dictionary) -> void:
	var header := Label.new()
	header.text = "Outputs (run in this order)"
	_target.add_child(header)
	var l := Ops.group_links(node, "out")
	if l.is_empty():
		_target.add_child(_hint("Drag from \"+ output\" to the brick that should run first."))
		return
	_order_rows(node, "out", "")
	_target.add_child(_hint("Drag from \"+ output\" to add another."))


## Where an action goes next, named like its exits; ↑ / ↓ where one exit has several chains.
func _add_runs_next(node: Dictionary, lay: Dictionary) -> void:
	var header := Label.new()
	header.text = "Runs next"
	_target.add_child(header)
	if lay.groups.is_empty():
		_target.add_child(_hint("Nothing: what follows it doesn't run."))
		return
	for g in lay.groups:
		var l := Ops.group_links(node, g)
		var title: String = "Then" if g == "next" and lay.groups.size() > 1 else Ops.group_title(node, g)
		if l.is_empty():
			_target.add_child(_hint("%s → (not wired)" % title))
		else:
			_order_rows(node, g, title)
	if Ops.grows(node):
		_target.add_child(_hint("Wire a spare ▶ (+ next, + loop body, + done) for another chain: they run in order, each to its end."))


func _order_rows(node: Dictionary, g: String, title: String) -> void:
	var l := Ops.group_links(node, g)
	for i in l.size():
		var target := Ops.node_by_id(context.graph, int(l[i]))
		var row := HBoxContainer.new()
		var label := Label.new()
		var name := "%s %d" % [title, i + 1] if title != "" and l.size() > 1 else (title if title != "" else str(i + 1))
		label.text = "%s → %s" % [name, T.title_of(target.type, target.fields) if not target.is_empty() else "(nothing)"]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.modulate.a = 0.85
		row.add_child(label)
		if l.size() > 1:
			for step in [[-1, "move_up", "Run earlier"], [1, "move_down", "Run later"]]:
				var b := Button.new()
				b.flat = true
				b.icon = context.brick_theme.icon(step[1])
				b.tooltip_text = step[2]
				b.disabled = i + step[0] < 0 or i + step[0] >= l.size()
				b.pressed.connect(func() -> void:
					if Ops.swap_exits(node, g, i, i + step[0]):
						context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Reorder chains"))
				row.add_child(b)
		_target.add_child(row)


# ------------------------------------------------------------------ palette info

func _show_info(type: String) -> void:
	var def: Dictionary = T.DEFS[type]
	_title.text = def.title
	_title.add_theme_color_override(&"font_color", context.brick_theme.category_color(def.cat))
	var kind: String = {"event": "Event (starts chains)", "action": "Action", "declare": "Declaration (no wires)", "reroute": "Reroute point"}[T.kind_of(type)]
	_target.add_child(_hint("%s · %s" % [BrickTheme.CATEGORY_TITLES.get(def.cat, def.cat), kind]))
	var description := Label.new()
	description.text = def.get("desc", "")
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_target.add_child(description)
	var lines := []
	for f in def.get("fields", []):
		var how: String = "pick one: " + ", ".join(f[3]) if f[1] == "option" else {"check": "on or off", "var": "a variable", "func": "one of this program's functions", "params": "a name and a type each", "text": "C code"}.get(f[1], "typed in")
		lines.append("• %s: %s" % [_field_title(f), how])
	if not lines.is_empty():
		_info_section("Settings", lines)
	lines = []
	for a in def.get("args", []):
		lines.append("• %s: %s" % [str(a[0]).capitalize(), " or ".join(T.literal_types(a[1])) if a[1] != T.ANY else "anything"])
	if type == "call":
		lines.append("• one row per input of the function")
	if not lines.is_empty():
		_info_section("Inputs (a variable, or a typed-in value)", lines)
	lines = []
	for o in def.get("outs", []):
		lines.append("• %s: %s, into a variable" % [str(o[0]).capitalize(), T.TYPE_TITLES[o[1]] if o[1] != T.ANY else "worked out from its inputs"])
	if not lines.is_empty():
		_info_section("Output", lines)
	var exits := []
	match T.kind_of(type):
		"event": exits.append("• Output 1, 2, …: run in order, each to the end")
		"declare": exits.append("• Nothing: it has no wires")
		_:
			for g in def.get("groups", []):
				exits.append("• " + T.EXIT_TITLES.get(g, g))
			if exits.is_empty():
				exits.append("• Nothing: the chain stops here")
	_info_section("Runs next", exits)
	_target.add_child(HSeparator.new())
	var add := Button.new()
	add.text = "Add to canvas"
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add.icon = context.brick_theme.icon("add")
	add.disabled = not context.can_use(type)
	add.tooltip_text = "Or drag it from the palette, or double-click it there."
	add.pressed.connect(func() -> void:
		if context.on_add_type.is_valid():
			context.on_add_type.call(type))
	_target.add_child(add)


func _info_section(heading: String, lines: Array) -> void:
	var header := Label.new()
	header.text = heading
	_target.add_child(header)
	for line in lines:
		_target.add_child(_hint(line))


# ------------------------------------------------------------------ frames

func _show_frame(frame: Dictionary) -> void:
	_title.text = "Comment frame"
	_title.remove_theme_color_override(&"font_color")
	var title := LineEdit.new()
	title.text = frame.title
	_on_commit(title, func() -> void:
		if Ops.set_frame(frame, "title", title.text):
			context.notify_changed(Context.Redraw.CANVAS, "Rename frame"))
	_add_row("Title", title)
	var color := ColorPickerButton.new()
	color.color = Color.html(frame.color)
	color.edit_alpha = false
	color.custom_minimum_size.y = 24
	color.popup_closed.connect(func() -> void:
		if Ops.set_frame(frame, "color", color.color):
			context.notify_changed(Context.Redraw.CANVAS, "Recolor frame"))
	_add_row("Color", color)
	var swatches := HBoxContainer.new()
	for sc in FRAME_SWATCHES:
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(22, 22)
		swatch.tooltip_text = "#" + sc.to_html(false)
		var style := StyleBoxFlat.new()
		style.bg_color = sc
		style.set_corner_radius_all(3)
		for state: StringName in [&"normal", &"hover", &"pressed"]:
			swatch.add_theme_stylebox_override(state, style)
		swatch.pressed.connect(func() -> void:
			if Ops.set_frame(frame, "color", sc):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Recolor frame"))
		swatches.add_child(swatch)
	_add_row("", swatches)
	var count: int = frame.nodes.size()
	if count > 0 and not frame.get("fit", true):
		var fit := Button.new()
		fit.text = "Fit to its bricks"
		fit.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		fit.pressed.connect(func() -> void:
			if Ops.set_frame(frame, "fit", true):
				context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Fit frame"))
		_target.add_child(fit)
	_target.add_child(_hint("Holds %d brick(s); they move with it. Drop bricks on the frame to add them." % count if count > 0 else "Empty. Drop bricks on it to group them."))
	if count > 0:
		var release := Button.new()
		release.text = "Release bricks"
		release.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		release.tooltip_text = "Let go of the bricks (they stay where they are)."
		release.pressed.connect(func() -> void:
			frame.nodes.clear()
			context.notify_changed(Context.Redraw.CANVAS | Context.Redraw.PROPERTIES, "Release bricks"))
		_target.add_child(release)
	_target.add_child(HSeparator.new())
	var remove := Button.new()
	remove.text = "Delete frame"
	remove.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	remove.tooltip_text = "Deletes the frame only; its bricks stay."
	remove.icon = context.brick_theme.icon("remove")
	remove.pressed.connect(func() -> void:
		if Ops.delete_frame(context.graph, frame):
			context.select(0)
			context.notify_changed(Context.Redraw.ALL, "Delete frame"))
	_target.add_child(remove)


# ------------------------------------------------------------------ helpers

## A row: the property's name (in a column as wide as the longest name, see
## _align_labels) and its editor, which grows with the panel up to EDITOR_CAP.
## A row without a name lines up under the editors above it.
func _add_row(label_text: String, editor: Control) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = label_text
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.add_to_group(&"inspector_row_label")
	row.add_child(label)
	var box := Capped.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# (user, 2026-11-07: a long one-line label in a row made Properties too wide to scale
	# down: a plain label value clips instead, its whole text in its tooltip)
	if editor is Label and (editor as Label).autowrap_mode == TextServer.AUTOWRAP_OFF:
		var lv := editor as Label
		lv.clip_text = true
		lv.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if lv.tooltip_text == "":
			lv.tooltip_text = lv.text
		lv.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(editor)
	row.add_child(box)
	_target.add_child(row)


## The name column: as wide as the longest name shown, at most half the panel
## (names clip, with "…" and a tooltip, only when the panel is that narrow).
func _align_labels() -> void:
	var labels := get_tree().get_nodes_in_group(&"inspector_row_label").filter(func(l): return is_ancestor_of(l) and not l.is_queued_for_deletion())
	var widest := 0.0
	for l in labels:
		if l.text != "":
			var font: Font = l.get_theme_font(&"font")
			widest = maxf(widest, font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size(&"font_size")).x)
	var column := minf(ceilf(widest) + 6.0, maxf(LABEL_WIDTH, size.x * 0.5))
	for l in labels:
		l.custom_minimum_size.x = column


## Holds one editor: as wide as the space, but no wider than EDITOR_CAP (so
## dropdowns and boxes don't stretch to the screen's edge), and no narrower
## than the editor's own minimum (they clip their text, so that's small).
class Capped extends Container:
	const EDITOR_CAP := 260.0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_SORT_CHILDREN:
			for c in get_children():
				if c is Control:
					var w := minf(size.x, maxf(EDITOR_CAP, c.get_combined_minimum_size().x))
					fit_child_in_rect(c, Rect2(0, 0, w, size.y))

	func _get_minimum_size() -> Vector2:
		var m := Vector2.ZERO
		for c in get_children():
			if c is Control and c.visible:
				m = m.max(c.get_combined_minimum_size())
		return m


## While paused: a variable's value now (the debugger).
func _now(variable: String) -> Label:
	var l := _hint("now: %s = %s" % [variable, context.debug_values[variable]])
	l.modulate = Color(1.0, 0.85, 0.2, 0.95)
	l.tooltip_text = "Its value where the program is paused (Debug tab)."
	return l


func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate.a = 0.7
	return label


static var _mono_font: Font = null


static func _mono() -> Font:
	if _mono_font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["JetBrains Mono", "DejaVu Sans Mono", "Consolas", "Menlo", "monospace"])
		_mono_font = f
	return _mono_font


static func _on_commit(edit: LineEdit, commit: Callable) -> void:
	edit.text_submitted.connect(func(_t: String) -> void: commit.call())
	edit.focus_exited.connect(commit)


const SIDES := ["Shared", "Server", "Client"]
const SIDE_HINTS := {
	"Shared": "Runs wherever it's used: classes and functions both sides need.",
	"Server": "The game's rules (spawning, scores, damage): runs on the machine hosting the game.",
	"Client": "One player's side (input, camera, HUD, sounds): runs on each player's machine.",
}


## Nothing selected: the open script's own settings (its Side).
func _show_script_settings() -> void:
	_title.text = "This script"
	var side := str(context.graph.get("side", "Shared"))
	var ob := OptionButton.new()
	ob.fit_to_longest_item = false
	ob.clip_text = true
	for sd in SIDES:
		ob.add_item(sd)
	ob.select(maxi(0, SIDES.find(side)))
	ob.tooltip_text = "Where this script runs in a network game: Server, Client (each player), or Shared (both). Until networking comes, one program runs every side."
	ob.item_selected.connect(func(i: int) -> void:
		if str(context.graph.get("side", "Shared")) != SIDES[i]:
			context.graph["side"] = SIDES[i]
			context.notify_changed(Context.Redraw.PROPERTIES, "Change script side")
			if context.world.get("objects", []).any(func(x): return CBTypes.is_script_object(x) and context.project_dir.path_join(str(x.get("script", ""))) == context.graph_path) and context.on_world_changed.is_valid():
				context.on_world_changed.call("Script type follows its Side"))
	_add_row("Side", ob)
	_target.add_child(_hint(SIDE_HINTS.get(side, "")))
	var always := CheckBox.new()
	always.text = "on" if bool(context.graph.get("always", false)) else "off"
	always.button_pressed = bool(context.graph.get("always", false))
	always.tooltip_text = "Runs while paused (Godot's process mode Always): while the game is paused offline (Pause game), this script's When frame starts / ends and, for a class's script, its objects' Every frame go on (with the real frame time). Off: they stop with the world."
	always.toggled.connect(func(on: bool) -> void:
		always.text = "on" if on else "off"
		if on:
			context.graph["always"] = true
		else:
			context.graph.erase("always")
		context.notify_changed(Context.Redraw.NONE, "Runs while paused"))
	_add_row("Runs while paused", always)
	_target.add_child(HSeparator.new())


## The classes an object of a scene can be: the world's built-in ones,
## the project's; picking one calls on_pick(name).
func _class_picker(current: String, on_pick: Callable, with_object := false) -> OptionButton:
	var opts: Array = ([CBTypes.OBJECT] if with_object else []) + CBTypes.BUILTIN.keys()
	var mine := CBTypes.classes.keys().filter(func(c): return not CBTypes.is_builtin(c))
	mine.sort()
	opts += mine
	if current != "" and current not in opts:
		opts.append(current)
	var ob := OptionButton.new()
	ob.fit_to_longest_item = false
	ob.clip_text = true
	for c in opts:
		ob.add_item(str(c) + ("" if CBTypes.is_class_type(str(c)) else "  (no such class)"))
	ob.select(maxi(0, opts.find(current)))
	ob.tooltip_text = "Its class: picking another keeps the fields both have"
	ob.item_selected.connect(func(i: int) -> void:
		if str(opts[i]) != current:
			on_pick.call(str(opts[i])))
	return ob


## An object of the edited scene (the Scene tree): its name, parent and fields. A
## field left blank keeps its class's starting value. A copy of another scene: its
## root's class and fields (overrides; the scene's own values as hints).
func _show_world_object(o: Dictionary) -> void:
	_world_edits.clear()
	_world_edits_of = int(o.get("id", 0))
	var is_copy := o.has("scene")
	var cls := str(context.flat_of(o).get("class", "")) if is_copy else str(o.get("class", ""))
	_title.text = "%s  (%s)" % [str(o.name), str(o.scene).get_file() if is_copy else cls]
	_title.add_theme_color_override(&"font_color", context.brick_theme.category_color("objects"))
	var changed := func(action: String) -> void:
		if context.on_world_changed.is_valid():
			context.on_world_changed.call(action)
	var name_edit := LineEdit.new()
	name_edit.text = str(o.name)
	name_edit.tooltip_text = "Bricks find it by this name: Object (Find)."
	_on_commit(name_edit, func() -> void:
		var t := name_edit.text.strip_edges()
		if t != "" and t != str(o.name):
			o.name = t
			if CBTypes.is_script_object(o) and context.on_script_object_renamed.is_valid():
				context.on_script_object_renamed.call(o)  # its file: a safe version of the name
			changed.call("Rename object"))
	_add_row("Name", name_edit)
	if CBTypes.is_script_object(o):
		_show_script_object(o, changed)
	elif is_copy:
		var row := HBoxContainer.new()
		var sl := Label.new()
		sl.text = str(o.scene)
		sl.clip_text = true
		sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(sl)
		var ob := Button.new()
		ob.text = "Open"
		ob.icon = context.brick_theme.icon("scene")
		ob.tooltip_text = "Edit %s (its objects; a change shows in every copy)" % str(o.scene)
		ob.pressed.connect(func() -> void:
			if context.on_open_scene.is_valid():
				context.on_open_scene.call(str(o.scene)))
		row.add_child(ob)
		_add_row("Scene", row)
		var cl := Label.new()
		cl.text = cls if cls != "" else "(the scene needs one object at the top)"
		_add_row("Root class", cl)
	# (user, 2026-11-07: no Class or Parent dropdowns here: the Scene tree's right-click
	# Change type... and dragging a row onto another do those)
	if CBTypes.is_script_object(o):
		var open_b := Button.new()
		open_b.text = "Open script"
		open_b.icon = context.brick_theme.icon("script")
		open_b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		open_b.pressed.connect(func() -> void:
			if context.on_open_script.is_valid():
				context.on_open_script.call(str(o.get("script", ""))))
		_add_row("", open_b)
		_body.add_child(_hint("Its file's When program starts runs once for the object it's under, before main's, with `parent` = that object (the World at the top). Its type is the file's Side: Script = Server, LocalScript = Client (each player), ModuleScript = Shared (both)."))
		return
	# Properties | Groups (Godot's Inspector | Node > Groups), the picked one kept between objects.
	var tabs := TabBar.new()
	tabs.add_tab("Properties")
	tabs.add_tab("Groups")
	tabs.current_tab = _world_tab
	tabs.tab_changed.connect(func(t: int) -> void:
		_world_tab = t
		rebuild.call_deferred())
	_body.add_child(HSeparator.new())
	_body.add_child(tabs)
	if _world_tab == 1:
		_show_world_groups(o, changed)
		return
	var defaults := {}
	for c in CBTypes.lineage(cls):
		for fld in CBTypes.BUILTIN.get(c, {}).get("fields", []):
			defaults[fld[0]] = fld[2]
	if is_copy:  # the scene's own values (under the overrides) are the hints
		var inner: Dictionary = context.flat_of(o).get("fields", {}).duplicate()
		for k in o.get("fields", {}):
			inner.erase(k)
		var root_fields: Array = CBProject.read_scene(context.project_dir.path_join(str(o.scene))).objects.filter(func(x): return int(x.parent) == 0 and not CBTypes.is_script_object(x))
		if root_fields.size() == 1:
			inner.merge(root_fields[0].get("fields", {}), true)
		defaults.merge(inner, true)
	# One fold per class, its own fields (Godot's Inspector): the object's own class
	# open, the classes it extends closed (until opened: remembered per class).
	var by_class := {}
	for fld in CBTypes.all_fields(cls):
		if not by_class.has(fld[2]):
			by_class[fld[2]] = []
		by_class[fld[2]].append(fld)
	var first := true
	for c in CBTypes.lineage(cls):
		if not by_class.has(c):
			continue
		_target = _fold(c, "class:" + str(c), first)
		first = false
		for fld in by_class[c]:
			var fname: String = fld[0]
			var ty: String = fld[1]
			if ty == "bool":
				var cb := CheckBox.new()
				cb.button_pressed = str(o.fields.get(fname, defaults.get(fname, "false"))) == "true"
				cb.text = "on" if cb.button_pressed else "off"
				cb.toggled.connect(func(on: bool) -> void:
					o.fields[fname] = "true" if on else "false"
					changed.call("Set " + fname))
				_add_row(fname, cb)
			elif fname == "anchor" and CBTypes.is_subclass(cls, "Control"):
				_add_row(fname, _anchor_picker(str(o.fields.get(fname, defaults.get(fname, "top_left"))), func(picked: String) -> void:
					o.fields[fname] = picked
					changed.call("Anchor " + picked)))
			elif fname == "align" and CBTypes.is_subclass(cls, "Label"):
				var ab := OptionButton.new()
				var cur_a := str(o.fields.get(fname, defaults.get(fname, "left")))
				for i in CBTypes.UI_ALIGNS.size():
					ab.add_item(CBTypes.UI_ALIGNS[i], i)
				ab.select(maxi(0, CBTypes.UI_ALIGNS.find(cur_a)))
				ab.item_selected.connect(func(i: int) -> void:
					o.fields[fname] = CBTypes.UI_ALIGNS[i]
					changed.call("Align " + str(CBTypes.UI_ALIGNS[i])))
				_add_row(fname, ab)
			elif CBTypes.is_basic(ty) or CBTypes.is_vector(ty):
				var le := LineEdit.new()
				le.text = str(o.fields.get(fname, ""))
				le.placeholder_text = str(defaults.get(fname, {"vector3": "0, 0, 0", "string": "", "float": "0", "int": "0"}.get(ty, "")))
				le.tooltip_text = "%s (%s). Blank: the class's starting value%s." % [fname, ty, " (%s)" % defaults[fname] if defaults.has(fname) else ""]
				_world_edits[fname] = le
				_on_commit(le, func() -> void:
					var t := le.text.strip_edges()
					if t == "" and o.fields.has(fname):
						o.fields.erase(fname)
						changed.call("Clear " + fname)
					elif t != "" and str(o.fields.get(fname, "")) != t:
						o.fields[fname] = t
						changed.call("Set " + fname))
				_add_row(fname, le)
			else:
				var lab := Label.new()
				lab.text = "(%s: set it from a brick)" % ty
				lab.modulate = Color(1, 1, 1, 0.6)
				_add_row(fname, lab)

	_target = _body
	if CBTypes.is_subclass(cls, "Camera3D"):
		_show_snapshot(o, changed)
	_show_world_meta(o, changed)
	_body.add_child(_hint("A copy of another scene: blank fields keep the scene's own values (in grey); its objects are edited in that scene (Open)." if is_copy else "Made before When program starts runs (its When created first, then these values). Blank fields keep the class's starting value."))


## A UI node's anchor: a 3 x 3 grid (the corners, edges and middle of its parent's box, or
## the window's) and Full (fill it); the picked one pressed.
func _anchor_picker(current: String, on_pick: Callable) -> Control:
	var box := VBoxContainer.new()
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override(&"h_separation", 2)
	grid.add_theme_constant_override(&"v_separation", 2)
	var marks := ["↖", "↑", "↗", "←", "●", "→", "↙", "↓", "↘"]
	for i in 9:
		var b := Button.new()
		b.text = marks[i]
		b.toggle_mode = true
		b.button_pressed = CBTypes.UI_ANCHORS[i] == current
		b.custom_minimum_size = Vector2(24, 20)
		b.tooltip_text = str(CBTypes.UI_ANCHORS[i]).replace("_", " ")
		b.pressed.connect(func() -> void: on_pick.call(CBTypes.UI_ANCHORS[i]))
		grid.add_child(b)
	box.add_child(grid)
	var full := Button.new()
	full.text = "Full"
	full.toggle_mode = true
	full.button_pressed = current == "full"
	full.tooltip_text = "Fill the parent's box (or the window), offset in from each side"
	full.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	full.pressed.connect(func() -> void: on_pick.call("full"))
	box.add_child(full)
	return box


## A Script object's type (= its file's Side) and file.
func _show_script_object(o: Dictionary, changed: Callable) -> void:
	var tl := Label.new()
	tl.text = "%s  (%s)" % [str(o["class"]), CBTypes.SCRIPT_TYPES.get(str(o["class"]), "")]
	tl.clip_text = true
	tl.tooltip_text = "Where it runs in a network game (its file's Side): Script = the Server, LocalScript = each player's Client, ModuleScript = Shared (both). Change it: right-click it in the Scene tree, Change type."
	_add_row("Type", tl)
	var files := []
	for p in CBProject.list_scripts(context.project_dir):
		files.append(CBProject.rel_path(context.project_dir, p))
	var cur := str(o.get("script", ""))
	if cur not in files:
		files.append(cur)
	var fb := OptionButton.new()
	fb.fit_to_longest_item = false
	fb.clip_text = true
	for f in files:
		fb.add_item(f if f != "" else "(none)")
	fb.select(files.find(cur))
	fb.tooltip_text = "The script file it runs (a FileSystem .cbricks file)."
	fb.item_selected.connect(func(i: int) -> void:
		if str(files[i]) != cur:
			o["script"] = str(files[i])
			changed.call("Script file"))
	_add_row("File", fb)


## A fold: a header button (▾ open / ▸ closed) over a page; open or closed is
## remembered by `key` (default `open`) between objects and rebuilds.
func _fold(title: String, key: String, open: bool) -> VBoxContainer:
	var is_open := bool(_folds.get(key, open))
	var head := Button.new()
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.text = ("▾ " if is_open else "▸ ") + title
	head.add_theme_color_override(&"font_color", context.brick_theme.accent_color())
	head.focus_mode = Control.FOCUS_NONE
	var page := VBoxContainer.new()
	page.name = title
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.visible = is_open
	head.pressed.connect(func() -> void:
		page.visible = not page.visible
		_folds[key] = page.visible
		head.text = ("▾ " if page.visible else "▸ ") + title)
	_body.add_child(HSeparator.new())
	_body.add_child(head)
	_body.add_child(page)
	return page


## The object's metadata (Godot's): text values by key, read by the Metadata brick.
func _show_world_meta(o: Dictionary, changed: Callable) -> void:
	if not o.get("meta") is Dictionary:
		o["meta"] = {}
	var meta: Dictionary = o.meta
	_target = _fold("Metadata (%d)" % meta.size() if not meta.is_empty() else "Metadata", "meta", false)
	for k in meta.keys():
		var key: String = str(k)
		var row := HBoxContainer.new()
		var le := LineEdit.new()
		le.text = str(meta[k])
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.tooltip_text = "The text Metadata (Get) gives for '%s'." % key
		_on_commit(le, func() -> void:
			if meta.has(key) and str(meta[key]) != le.text:
				meta[key] = le.text
				changed.call("Set metadata " + key))
		row.add_child(le)
		var rm := Button.new()
		rm.icon = context.brick_theme.icon("remove")
		rm.flat = true
		rm.tooltip_text = "Remove '%s'" % key
		rm.pressed.connect(func() -> void:
			meta.erase(key)
			changed.call("Remove metadata " + key))
		row.add_child(rm)
		_add_row(key, row)
	var add := HBoxContainer.new()
	var name_le := LineEdit.new()
	name_le.placeholder_text = "new key"
	name_le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add_b := Button.new()
	add_b.icon = context.brick_theme.icon("add")
	add_b.text = "Add"
	var do_add := func() -> void:
		var key := name_le.text.strip_edges()
		if key != "" and not meta.has(key):
			meta[key] = ""
			_folds["meta"] = true
			changed.call("Add metadata " + key)
	add_b.pressed.connect(do_add)
	name_le.text_submitted.connect(func(_t: String) -> void: do_add.call())
	add.add_child(name_le)
	add.add_child(add_b)
	_add_row("", add)
	_target.add_child(_hint("Text values by key: the Metadata brick reads and changes them while the program runs."))
	_target = _body


## The Groups tab (Godot's Node > Groups): the object's groups, add / remove, and
## the groups other objects use (to pick from).
func _show_world_groups(o: Dictionary, changed: Callable) -> void:
	if not o.get("groups") is Array:
		o["groups"] = []
	var groups: Array = o.groups
	_target = _body
	var add := HBoxContainer.new()
	var le := LineEdit.new()
	le.placeholder_text = "group name"
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add_b := Button.new()
	add_b.icon = context.brick_theme.icon("add")
	add_b.text = "Add"
	var do_add := func(g: String) -> void:
		var t := g.strip_edges()
		if t != "" and t not in groups:
			groups.append(t)
			changed.call("Add to group " + t)
	add_b.pressed.connect(func() -> void: do_add.call(le.text))
	le.text_submitted.connect(func(t: String) -> void: do_add.call(t))
	add.add_child(le)
	add.add_child(add_b)
	_body.add_child(add)
	if groups.is_empty():
		_body.add_child(_hint("In no groups yet."))
	for g in groups.duplicate():
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = str(g)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var rm := Button.new()
		rm.icon = context.brick_theme.icon("remove")
		rm.flat = true
		rm.tooltip_text = "Remove from '%s'" % str(g)
		rm.pressed.connect(func() -> void:
			groups.erase(g)
			changed.call("Remove from group " + str(g)))
		row.add_child(rm)
		_body.add_child(row)
	var others := []
	for x in context.world.get("objects", []):
		for g in x.get("groups", []):
			if str(g) not in others and str(g) not in groups:
				others.append(str(g))
	if not others.is_empty():
		var sec := _section("Other groups in the world")
		var flow := HFlowContainer.new()
		for g in others:
			var b := Button.new()
			b.text = "+ " + str(g)
			b.tooltip_text = "Add this object to '%s'" % str(g)
			b.pressed.connect(func() -> void: do_add.call(str(g)))
			flow.add_child(b)
		sec.add_child(flow)
	_body.add_child(_hint("Group bricks find objects by group: Objects in group, Is in group (and add or remove them while the program runs)."))


## A Camera's Snapshot section: what it sees, rendered to a PNG in the project
## (width, height, transparent, which objects), with a preview of the last one.
func _show_snapshot(o: Dictionary, changed: Callable) -> void:
	if not o.get("snapshot") is Dictionary:
		o["snapshot"] = {}
	var snap: Dictionary = o.snapshot
	var sec := _section("Snapshot")
	_target = sec
	for k in [["width", 512], ["height", 288]]:
		var sb := SpinBox.new()
		sb.min_value = 8
		sb.max_value = 4096
		sb.value = int(snap.get(k[0], k[1]))
		sb.value_changed.connect(func(v: float) -> void:
			snap[k[0]] = int(v)
			changed.call("Snapshot " + k[0]))
		_add_row(k[0].capitalize(), sb)
	var tr := CheckBox.new()
	tr.button_pressed = bool(snap.get("transparent", false))
	tr.text = "transparent background"
	tr.toggled.connect(func(on: bool) -> void:
		snap["transparent"] = on
		changed.call("Snapshot transparent"))
	_add_row("Background", tr)
	var subjects := [[0, "Everything"]]
	for x in context.world.get("objects", []):
		var c := str(context.flat_of(x).get("class", ""))
		if CBTypes.is_subclass(c, "Spatial3D") and not CBTypes.is_subclass(c, "Camera3D") and not CBTypes.is_subclass(c, "Light3D"):
			subjects.append([int(x.id), "%s (%s)" % [str(x.name), c]])
	var sub := OptionButton.new()
	sub.fit_to_longest_item = false
	sub.clip_text = true
	for i in subjects.size():
		sub.add_item(subjects[i][1], i)
	sub.select(maxi(0, subjects.map(func(x): return x[0]).find(int(snap.get("subject", 0)))))
	sub.tooltip_text = "What's drawn: everything, or one object and the objects under it (an icon of it)."
	sub.item_selected.connect(func(i: int) -> void:
		snap["subject"] = int(subjects[i][0])
		changed.call("Snapshot subject"))
	_add_row("Shows", sub)
	var path := LineEdit.new()
	path.text = str(snap.get("path", "assets/snapshots/%s.png" % str(o.name).to_snake_case()))
	path.tooltip_text = "Where the PNG goes, from the project folder."
	_on_commit(path, func() -> void:
		snap["path"] = path.text.strip_edges()
		changed.call("Snapshot path"))
	_add_row("Save to", path)
	var take := Button.new()
	take.text = "Take snapshot"
	take.icon = context.brick_theme.icon("file_image")
	take.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var preview := TextureRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(0, 120)
	preview.texture = context.snapshotter.last.get(int(o.id)) if context.snapshotter != null else null
	take.pressed.connect(func() -> void:
		snap["path"] = path.text.strip_edges()
		var subject := int(snap.get("subject", 0))
		var only := {}
		if subject != 0:
			only[subject] = true
			var grew := true
			while grew:
				grew = false
				for x in context.world_flat.get("objects", []):
					if only.has(int(x.get("parent", 0))) and not only.has(int(x.id)):
						only[int(x.id)] = true
						grew = true
		var job := {"world": context.world_flat, "size": Vector2i(int(snap.get("width", 512)), int(snap.get("height", 288))), "transparent": bool(snap.get("transparent", false)), "only": only,
			"camera": {"position": WorldValues.world_transform(context.flat_of(o), WorldValues.by_id(context.world_flat)).origin, "target": WorldValues.vec(WorldValues.field(o, "target")), "fov": WorldValues.number(WorldValues.field(o, "fov"), 60)}}
		var rel := str(snap.path)
		take.disabled = true
		context.snapshotter.render(job, func(img: Image) -> void:
			var full := context.project_dir.path_join(rel)
			DirAccess.make_dir_recursive_absolute(full.get_base_dir())
			var err := img.save_png(full)
			var tex := ImageTexture.create_from_image(img)
			context.snapshotter.last[int(o.id)] = tex
			if is_instance_valid(preview):
				preview.texture = tex
			if is_instance_valid(take):
				take.disabled = false
			if context.on_status.is_valid():
				context.on_status.call("Snapshot saved: %s (%d x %d)" % [rel, img.get_width(), img.get_height()] if err == OK else "Snapshot not saved: %s" % error_string(err))))
	_target.add_child(take)
	_target.add_child(preview)
	_target = _body
