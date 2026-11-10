extends GraphNode
## One brick on the canvas (after Brickscript's flow_graph_node.gd). The top
## rows carry the exec ports: the input on the left of the first row (not on
## events), one exit per row on the right (events: Output 1, 2... and a spare;
## If: True / False / Next, each growing). Below them a read-only summary of its
## settings, inputs and output; editing happens in Properties.
##
## Its position and size are whole grid squares. It fits its content unless its
## corner was dragged to make it bigger (saved in the node's "size").

const Context = preload("res://scripts/editor/context.gd")
const T = preload("res://scripts/node_defs.gd")

const EXEC_PORT: int = 0
const EXEC_COLOR: Color = Color(0.92, 0.92, 0.92)
const MIN_WIDTH: float = 176.0
const TEXT_SIZE: int = 15
const TITLE_SIZE: int = 15
const OUTLINE_COLOR: Color = Color(0, 0, 0, 0.55)
const OUTLINE_SIZE: int = 3
const ERROR_COLOR: Color = Color(1.0, 0.3, 0.3)
const FLASH_COLOR: Color = Color(1.6, 1.6, 1.1)

var node: Dictionary = {}
## Right-side port index -> [group, index in group].
var exits: Array = []
var _text_color: Color = Color.WHITE
var _resizing: bool = false
var _flash: Tween = null


func setup(flow_node: Dictionary, context: Context) -> void:
	node = flow_node
	name = str(int(node.id))
	position_offset = Ops.snap(Vector2(node.pos[0], node.pos[1]))
	custom_minimum_size.x = MIN_WIDTH
	resizable = true
	resize_request.connect(func(new_size: Vector2) -> void:
		_resizing = true
		size = Ops.snap_up(new_size.max(get_combined_minimum_size())), CONNECT_DEFERRED)
	resize_end.connect(func(_s: Vector2) -> void: _resizing = false)
	var def: Dictionary = T.DEFS[node.type]
	title = T.title_of(node.type, node.fields)
	tooltip_text = "Click to edit in Properties. Drag from a ▶ port to wire what runs next."
	_text_color = context.brick_theme.brick_text_color()
	var misplaced: String = str(context.misplaced_bricks.get(int(node.id), ""))
	if misplaced != "":
		_text_color = _text_color.lerp(context.brick_theme.background(), 0.45)
	_style(MISPLACED_GREY if misplaced != "" else context.brick_theme.category_color(def.cat), context)
	if misplaced != "":
		_mark_error(misplaced)
		tooltip_text = "Can't be here: %s" % misplaced.substr(misplaced.find(": ") + 2) if misplaced.contains(": ") else misplaced
	elif context.error_bricks.has(int(node.id)):
		_mark_error(context.error_bricks[int(node.id)])
	if int(node.id) in context.breakpoints().map(func(x): return int(x)):
		title = "● " + title
		tooltip_text = "Breakpoint: the program pauses here when it's run from the editor (F9 or right-click to remove)."
	if context.paused_brick == int(node.id):
		_mark_paused()
	if node.type == "reroute":
		_setup_reroute()
		return
	var kind: String = T.kind_of(node.type)
	var has_input: bool = kind == "action"
	exits = Ops.exits_for(context.graph, node) if kind != "declare" else []
	var rows: int = maxi(1, exits.size()) if has_input or not exits.is_empty() else 0
	for row in rows:
		var label := Ops.exit_title(node, exits[row][0], exits[row][1]) if row < exits.size() else ""
		add_child(_port_row("▶" if row == 0 and has_input else "", label))
		set_slot(row, row == 0 and has_input, EXEC_PORT, EXEC_COLOR, row < exits.size(), EXEC_PORT, EXEC_COLOR)
	for row in get_children():
		for label in row.get_children():
			_readable(label as Label)
	for line in summary(node, context.graph):
		var label := Label.new()
		label.text = line
		_readable(label)
		add_child(label)
	var note := str(node.get("note", ""))
	if note != "":
		var nl := Label.new()
		nl.text = "// " + note
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size.x = 160
		_readable(nl, TEXT_SIZE - 2)
		nl.modulate = Color(0.75, 0.95, 0.75, 0.9)
		add_child(nl)
		tooltip_text = note + "\n\n" + tooltip_text
	var title_label: Label = get_titlebar_hbox().get_child(0) as Label if get_titlebar_hbox().get_child_count() > 0 else null
	if title_label != null:
		_readable(title_label, TITLE_SIZE)
	ready.connect(fit)
	minimum_size_changed.connect(_snap_size)
	resized.connect(func() -> void:
		if size != Ops.snap_up(size):
			_snap_size.call_deferred())


func _setup_reroute() -> void:
	title = ""
	resizable = false
	custom_minimum_size = Vector2.ZERO
	tooltip_text = "A reroute point: it only bends the wire. Drag it; delete it to straighten the wire."
	exits = [["next", 0]]
	var dot := Label.new()
	dot.text = "●"
	dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_readable(dot)
	add_child(dot)
	set_slot(0, true, EXEC_PORT, EXEC_COLOR, true, EXEC_PORT, EXEC_COLOR)
	ready.connect(func() -> void: size = Ops.snap_up(get_combined_minimum_size()))


func fit() -> void:
	size = Ops.snap_up(Vector2(node.size[0], node.size[1]).max(get_combined_minimum_size()))


func _snap_size() -> void:
	var kept: Vector2 = size if _resizing or Vector2(node.size[0], node.size[1]) != Vector2.ZERO else Vector2.ZERO
	size = Ops.snap_up(kept.max(get_combined_minimum_size()))


## Read-only lines describing the brick: settings, inputs, output.
static func summary(n: Dictionary, graph: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var f: Dictionary = n.fields
	var into := func(out_name: String) -> String:
		var o: Dictionary = n.outs.get(out_name, {})
		var v := str(o.get("var", ""))
		return "→ (not kept)" if v == "" else "→ %s%s" % ["into " if o.get("use", false) else "", v]
	var kept := func(out_name: String, expr: String) -> String:
		var v := str(n.outs.get(out_name, {}).get("var", ""))
		return "%s ← %s" % [v, expr] if v != "" else expr + "  (not kept)"
	match n.type:
		"start", "exit", "break", "continue":
			pass
		"function":
			var params := []
			for p in T.parse_params(f.get("params", [])):
				params.append("%s %s" % [p[0], p[1]])
			lines.append("%s %s(%s)" % [f.get("returns", "void"), _or_blank(f.get("name", "")), ", ".join(params)])
		"if", "while":
			var op := str(f.get("operator", "is true"))
			var a := describe_input(n, "a")
			lines.append("%s %s %s %s" % [n.type, a, op, describe_input(n, "b")] if op in T.TWO_SIDED else "%s %s %s" % [n.type, a, op])
		"for":
			var step := describe_input(n, "step")
			lines.append("%s = %s .. %s%s" % [_or_blank(n.outs.get("index", {}).get("var", "")), describe_input(n, "from"), describe_input(n, "to"), "" if step == "1" else ", step " + step])
		"repeat":
			var c := str(n.outs.get("counter", {}).get("var", ""))
			lines.append("repeat %s times%s" % [describe_input(n, "times"), "" if c == "" else " → " + c])
		"var":
			var name := _or_blank(f.get("name", ""))
			match str(f.get("mode", "Set")):
				"Get": lines.append(kept.call("copy", name))
				"Add": lines.append("%s += %s" % [name, describe_input(n, "value")])
				_: lines.append("%s ← %s%s" % [name, describe_input(n, "value"), " (shared)" if f.get("scope") in ["Shared", "Global"] else ""])
		"formula":
			lines.append(kept.call("result", str(f.get("expression", "")) if str(f.get("expression", "")) != "" else "(type a formula)"))
		"convert":
			lines.append(kept.call("result", "(%s) %s" % [f.get("to", "int"), describe_input(n, "value")]))
		"math":
			var op: String = {"Add": "+", "Subtract": "-", "Multiply": "×", "Divide": "/", "Remainder": "%"}.get(str(f.get("op", "Add")), "+")
			lines.append(kept.call("result", "%s %s %s" % [describe_input(n, "a"), op, describe_input(n, "b")]))
		"math_func":
			var fn := str(f.get("func", "sqrt"))
			lines.append(kept.call("result", "pow(%s, %s)" % [describe_input(n, "x"), describe_input(n, "exp")] if fn == "pow" else "%s(%s)" % [fn, describe_input(n, "x")]))
		"minmax":
			lines.append(kept.call("result", "%s(%s, %s)" % [f.get("op", "min"), describe_input(n, "a"), describe_input(n, "b")]))
		"random":
			lines.append(kept.call("result", "random %s .. %s" % [describe_input(n, "min"), describe_input(n, "max")]))
		"compare":
			lines.append(kept.call("result", "%s %s %s" % [describe_input(n, "a"), f.get("op", "=="), describe_input(n, "b")]))
		"logic":
			var op := str(f.get("op", "And"))
			lines.append(kept.call("result", "not %s" % describe_input(n, "a") if op == "Not" else "%s %s %s" % [describe_input(n, "a"), op.to_lower(), describe_input(n, "b")]))
		"print":
			lines.append("print %s%s" % [describe_input(n, "value"), "" if f.get("newline", true) else "  (no new line)"])
		"read":
			if str(f.get("prompt", "")) != "":
				lines.append("\"%s\"" % str(f.prompt).strip_edges())
			lines.append("read %s %s" % [f.get("as", "int"), into.call("value")])
		"time":
			lines.append(kept.call("seconds", "time"))
		"call":
			var args := []
			var funcs := Ops.functions(graph)
			var fi = funcs.get(str(f.get("function", "")))
			if fi != null:
				for p in fi.params:
					args.append(describe_input(n, p[1]))
			lines.append("%s(%s)" % [_or_blank(f.get("function", "")), ", ".join(args)])
			if fi != null and fi.returns != "void":
				lines.append(into.call("result"))
		"return":
			lines.append("return" if f.get("gives", "A value") == "Nothing" else "return %s" % describe_input(n, "value"))
		"raw_c":
			var code := str(f.get("code", "")).split("\n")
			for i in mini(3, code.size()):
				lines.append(code[i].left(40))
			if code.size() > 3:
				lines.append("…")
		"include":
			lines.append("#include %s" % f.get("header", ""))
		"args":
			match str(f.get("what", "Option")):
				"Count": lines.append(kept.call("result", "argument count"))
				"At index": lines.append(kept.call("result", "argument %s" % describe_input(n, "index")))
				"Flag": lines.append(kept.call("result", "has --%s" % str(n.args.get("name", {}).get("value", "?"))))
				_: lines.append(kept.call("result", "--%s=…" % str(n.args.get("name", {}).get("value", "?"))))
		"quit":
			lines.append("exit(%s)" % describe_input(n, "code"))
		"read_file":
			lines.append(kept.call("text", "read %s" % describe_input(n, "path")))
		"write_file":
			lines.append("%s %s" % ["append to" if f.get("mode") == "Append" else "write", describe_input(n, "path")])
			lines.append("  " + describe_input(n, "text").left(36))
		"file_exists":
			lines.append(kept.call("result", "exists %s" % describe_input(n, "path")))
		"assert":
			var op := str(f.get("operator", "is true"))
			lines.append("assert %s %s%s" % [describe_input(n, "a"), op, " " + describe_input(n, "b") if op in T.TWO_SIDED else ""])
		"debug_log":
			lines.append("debug %s  (-v)" % describe_input(n, "value"))
		"text":
			var op := str(f.get("op", "Join"))
			match op:
				"Join": lines.append(kept.call("result", "%s + %s" % [describe_input(n, "text"), describe_input(n, "more")]))
				"Format":
					var vals := []
					for k in ["first", "second", "third", "fourth"].slice(0, str(f.get("format", "")).count("{}")):
						vals.append(describe_input(n, k))
					lines.append(kept.call("result", "format \"%s\"" % str(f.get("format", "")).left(28)))
					if not vals.is_empty():
						lines.append("  with " + ", ".join(vals))
				"Substring": lines.append(kept.call("result", "%s[%s, %s chars]" % [describe_input(n, "text"), describe_input(n, "start"), describe_input(n, "length")]))
				"Find", "Starts with", "Ends with": lines.append(kept.call("result", "%s %s %s" % [describe_input(n, "text"), op.to_lower(), describe_input(n, "what")]))
				"Replace": lines.append(kept.call("result", "%s: %s → %s" % [describe_input(n, "text"), describe_input(n, "what"), describe_input(n, "with")]))
				"Split": lines.append(kept.call("result", "split %s by %s" % [describe_input(n, "text"), describe_input(n, "separator")]))
				"Join list": lines.append(kept.call("result", "join %s with %s" % [describe_input(n, "list"), describe_input(n, "separator")]))
				"To text": lines.append(kept.call("result", "text of %s" % describe_input(n, "value")))
				_: lines.append(kept.call("result", "%s %s" % [op.to_lower(), describe_input(n, "text")]))
		"list":
			var op := str(f.get("op", "Add"))
			var l := describe_input(n, "list")
			match op:
				"Make": lines.append(kept.call("result", "new %s list" % f.get("of", "int")))
				"Add": lines.append("%s += %s" % [l, describe_input(n, "value")])
				"Insert": lines.append("%s[%s] ← insert %s" % [l, describe_input(n, "index"), describe_input(n, "value")])
				"Get": lines.append(kept.call("result", "%s[%s]" % [l, describe_input(n, "index")]))
				"Set": lines.append("%s[%s] ← %s" % [l, describe_input(n, "index"), describe_input(n, "value")])
				"Remove": lines.append("remove %s[%s]" % [l, describe_input(n, "index")])
				"Length": lines.append(kept.call("result", "length of %s" % l))
				"Find", "Contains": lines.append(kept.call("result", "%s %s %s" % [l, op.to_lower(), describe_input(n, "value")]))
				_: lines.append("%s %s" % [op.to_lower(), l])
		"map":
			var op := str(f.get("op", "Set"))
			var m := describe_input(n, "map")
			var k := describe_input(n, "key")
			match op:
				"Make": lines.append(kept.call("result", "new %s map" % f.get("of", "int")))
				"Set": lines.append("%s[%s] ← %s" % [m, k, describe_input(n, "value")])
				"Get": lines.append(kept.call("result", "%s[%s]" % [m, k]))
				"Get or": lines.append(kept.call("result", "%s[%s] or %s" % [m, k, describe_input(n, "default")]))
				"Has": lines.append(kept.call("result", "%s has %s" % [m, k]))
				"Remove": lines.append("remove %s[%s]" % [m, k])
				"Count": lines.append(kept.call("result", "count of %s" % m))
				"Keys", "Values": lines.append(kept.call("result", "%s of %s" % [op.to_lower(), m]))
				_: lines.append("%s %s" % [op.to_lower(), m])
		"for_each":
			var item := str(n.outs.get("item", {}).get("var", ""))
			lines.append("%s in %s" % [item if item != "" else "each", describe_input(n, "list")])
		"record":
			var fl := []
			for p in T.parse_params(f.get("fields", [])):
				fl.append("%s %s" % [p[0], p[1]])
			lines.append("record %s" % _or_blank(f.get("name", "")))
			for x in fl.slice(0, 5):
				lines.append("  " + x)
			if fl.size() > 5:
				lines.append("  …")
		"make_record":
			lines.append(kept.call("result", "new %s" % _or_blank(f.get("of", ""))))
		"field":
			var r := describe_input(n, "record")
			if str(f.get("mode", "Get")) == "Set":
				lines.append("%s.%s ← %s" % [r, _or_blank(f.get("field", "")), describe_input(n, "value")])
			else:
				lines.append(kept.call("value", "%s.%s" % [r, _or_blank(f.get("field", ""))]))
		"switch":
			lines.append("switch %s" % describe_input(n, "value"))
		"constant":
			lines.append("%s %s = %s" % [f.get("type", "int"), _or_blank(f.get("name", "")), describe_input(n, "value")])
		"sleep":
			lines.append("sleep %s ms" % describe_input(n, "ms"))
		"env":
			lines.append(kept.call("value", "env %s" % describe_input(n, "name")))
		"run_command":
			lines.append("run %s" % describe_input(n, "command").left(36))
		"terminal":
			var m := str(f.get("mode", "Color"))
			lines.append(("%s%s" % [f.get("color", "green"), " background" if f.get("background", false) else ""]) if m == "Color" else m.to_lower())
		"window":
			lines.append("%s x %s, \"%s\"" % [describe_input(n, "width"), describe_input(n, "height"), str(n.args.get("title", {}).get("value", "")).left(24)])
			lines.append("%s frames / s" % describe_input(n, "fps"))
		"game_loop":
			lines.append("until the window closes")
		"close_window":
			lines.append("end the Game loop after this frame")
		"pause":
			match str(f.get("do", "Pause")):
				"Resume": lines.append("resume the game")
				"Is paused": lines.append(kept.call("result", "paused?"))
				"Set time scale": lines.append("time scale %s" % describe_input(n, "scale"))
				"Time scale": lines.append(kept.call("result", "time scale"))
				_: lines.append("pause the game (offline: the world stops)")
		"view2d":
			lines.append("centre %s, zoom %s" % [describe_input(n, "center"), describe_input(n, "zoom")])
			if describe_input(n, "rotation") not in ["0", "0.0"]:
				lines.append("turned %s°" % describe_input(n, "rotation"))
		"music":
			var mdo := str(f.get("do", "Play"))
			match mdo:
				"Load": lines.append(kept.call("music", "load %s%s" % [describe_input(n, "path"), ", looping" if f.get("loop", true) else ""]))
				"Volume": lines.append("%s volume %s" % [describe_input(n, "music"), describe_input(n, "volume")])
				"Playing": lines.append(kept.call("result", "%s playing?" % describe_input(n, "music")))
				_: lines.append("%s %s" % [mdo.to_lower(), describe_input(n, "music")])
		"clear":
			lines.append("clear %s" % describe_input(n, "color"))
		"draw":
			var at := "(%s, %s)" % [describe_input(n, "x"), describe_input(n, "y")]
			match str(f.get("shape", "Rectangle")):
				"Circle": lines.append("circle at %s r %s" % [at, describe_input(n, "radius")])
				"Line": lines.append("line %s to (%s, %s)" % [at, describe_input(n, "x2"), describe_input(n, "y2")])
				"Text": lines.append("%s at %s" % [describe_input(n, "text").left(28), at])
				"Texture": lines.append("%s at %s" % [describe_input(n, "texture"), at])
				"Sprite": lines.append("%s frame %s (%sx%s) at %s" % [describe_input(n, "texture"), describe_input(n, "frame"), describe_input(n, "columns"), describe_input(n, "rows"), at])
				var shape: lines.append("%s %sx%s at %s" % [shape.to_lower(), describe_input(n, "width"), describe_input(n, "height"), at])
			var turn := describe_input(n, "rotation") if str(f.get("shape", "Rectangle")) in ["Rectangle", "Text", "Texture", "Sprite"] else "0"
			lines.append("  " + describe_input(n, "color") + ("" if turn in ["0", "0.0", ""] else ", turned %s°" % turn))
		"class":
			lines.append("class %s extends %s" % [_or_blank(f.get("name", "")), str(f.get("extends", "Node"))])
			var fl := []
			for p in T.parse_params(f.get("fields", [])):
				fl.append("%s %s" % [p[0], p[1]])
			for x in fl.slice(0, 5):
				lines.append("  " + x)
			if fl.size() > 5:
				lines.append("  …")
			if str(f.get("synced", "")).strip_edges() != "":
				lines.append("  synced: " + str(f.get("synced", "")))
		"created":
			lines.append("Self is the new object")
		"new_object":
			lines.append(kept.call("object", "new %s" % _or_blank(f.get("of", ""))))
		"destroy":
			lines.append("destroy %s" % describe_input(n, "object"))
		"call_method":
			var margs := []
			for a in n.args:
				if a != "object":
					margs.append(describe_input(n, a))
			lines.append(kept.call("result", "%s.%s(%s)" % [describe_input(n, "object"), _or_blank(f.get("method", "")), ", ".join(margs)]) if n.outs.has("result") else "%s.%s(%s)" % [describe_input(n, "object"), _or_blank(f.get("method", "")), ", ".join(margs)])
		"object":
			var o := describe_input(n, "object")
			match str(f.get("op", "Exists")):
				"Exists": lines.append(kept.call("result", "%s exists" % o))
				"Is a": lines.append(kept.call("result", "%s is a %s" % [o, _or_blank(f.get("of", ""))]))
				"As": lines.append(kept.call("result", "%s as %s" % [o, _or_blank(f.get("of", ""))]))
				"Set name": lines.append("%s.name ← %s" % [o, describe_input(n, "name")])
				"Set parent": lines.append("%s under %s" % [o, describe_input(n, "parent")])
				var op: lines.append(kept.call("result", "%s of %s" % [op.to_lower(), o]))
		"network":
			match str(f.get("do", "Host")):
				"Host": lines.append(kept.call("result", "host on port %s" % describe_input(n, "port")))
				"Join": lines.append(kept.call("result", "join %s:%s" % [describe_input(n, "address"), describe_input(n, "port")]))
				"Leave": lines.append("leave: back to single-player")
				"Role": lines.append(kept.call("result", "offline / host / server / client"))
				_: lines.append(kept.call("result", "the rules run here?"))
		"remote":
			var vals := []
			for p in T.parse_params(f.get("values", [])):
				vals.append("%s %s" % [p[0], p[1]])
			lines.append("%s (%s)" % [_or_blank(f.get("name", "")), ", ".join(vals)])
			lines.append(str(f.get("direction", "To server")).to_lower() + (" → %s" % str(f.get("answer", "bool")) if str(f.get("direction", "")) == "Ask server" else ""))
		"invoke_server":
			var vals := []
			var r = CBTypes.remotes.get(str(f.get("remote", "")))
			if r != null:
				for p in r.params:
					vals.append(describe_input(n, str(p[1])))
			lines.append("ask %s(%s)" % [_or_blank(f.get("remote", "")), ", ".join(vals)])
			lines.append(into.call("answer"))
		"answer":
			lines.append("answer %s" % describe_input(n, "value"))
		"fire_server", "fire_clients":
			var vals := []
			var r = CBTypes.remotes.get(str(f.get("remote", "")))
			if r != null:
				for p in r.params:
					vals.append(describe_input(n, str(p[1])))
			var whom := "server" if n.type == "fire_server" else ("every client" if str(f.get("to", "All")) == "All" else describe_input(n, "player"))
			lines.append("%s(%s) → %s" % [_or_blank(f.get("remote", "")), ", ".join(vals), whom])
		"on_client_fired", "on_server_fired", "on_client_invoked":
			var vals := []
			var r = CBTypes.remotes.get(str(f.get("remote", "")))
			if r != null:
				for p in r.params:
					vals.append(str(p[1]))
			if n.type in ["on_client_fired", "on_client_invoked"]:
				vals.append("sender")
			lines.append("%s: %s" % [_or_blank(f.get("remote", "")), ", ".join(vals)])
		"clicked":
			lines.append("this Button was clicked")
		"button_clicked":
			var bn := str(f.get("button", "")).strip_edges()
			lines.append(("%s was clicked" % bn) if bn != "" else "any Button clicked")
			lines.append("→ button")
		"player_joined", "player_left":
			lines.append("player: who %s" % ("joined" if n.type == "player_joined" else "left"))
		"player":
			var who := describe_input(n, "player")
			if who == "(variable?)" or who == "0":
				who = "my player"  # (blank: the player this script is under, else this machine's)
			match str(f.get("op", "Me")):
				"Me": lines.append(kept.call("result", "my player"))
				"Number": lines.append(kept.call("result", "number of %s" % who))
				"Name": lines.append(kept.call("result", "name of %s" % who))
				"Is me": lines.append(kept.call("result", "%s is me" % who))
				"Players": lines.append(kept.call("result", "every player"))
				_: lines.append(kept.call("result", "player #%s" % describe_input(n, "number")))
		"vector":
			var op := str(f.get("op", "Make"))
			var va := describe_input(n, "a")
			var vb := describe_input(n, "b")
			match op:
				"Make": lines.append(kept.call("result", "(%s, %s, %s)" % [describe_input(n, "x"), describe_input(n, "y"), describe_input(n, "z")]))
				"Split":
					var parts := []
					for p in ["x", "y", "z"]:
						var v := str(n.outs.get(p, {}).get("var", ""))
						parts.append(v if v != "" else "_")
					lines.append("%s → %s" % [va, ", ".join(parts)])
				"Add": lines.append(kept.call("result", "%s + %s" % [va, vb]))
				"Subtract": lines.append(kept.call("result", "%s - %s" % [va, vb]))
				"Scale": lines.append(kept.call("result", "%s * %s" % [va, describe_input(n, "factor")]))
				"Lerp": lines.append(kept.call("result", "%s → %s at %s" % [va, vb, describe_input(n, "t")]))
				"Distance", "Dot", "Cross": lines.append(kept.call("result", "%s %s %s" % [op.to_lower(), va, vb]))
				_: lines.append(kept.call("result", "%s %s" % [op.to_lower(), va]))
		"camera3d":
			lines.append("eye %s" % describe_input(n, "position"))
			lines.append("looks at %s" % describe_input(n, "target"))
		"draw3d":
			lines.append("Draw chains in 3D")
		"shape3d":
			var shape := str(f.get("shape", "Box"))
			match shape:
				"Line": lines.append("line %s → %s" % [describe_input(n, "at"), describe_input(n, "to")])
				"Grid": lines.append("grid %s lines, %s apart" % [describe_input(n, "lines"), describe_input(n, "spacing")])
				"Mesh": lines.append("%s at %s" % [describe_input(n, "mesh"), describe_input(n, "at")])
				_: lines.append("%s at %s" % [shape.to_lower(), describe_input(n, "at")])
			if shape not in ["Line", "Grid"]:
				var extra := "size %s" % describe_input(n, "size")
				if shape != "Wire box" and describe_input(n, "turn") not in ["0", "0.0"]:
					extra += ", turn %s°" % describe_input(n, "turn")
				lines.append("  " + extra)
			if shape != "Grid":
				lines.append("  " + describe_input(n, "color"))
		"begin_mesh":
			lines.append("new mesh → %s" % str(n.outs.get("mesh", {}).get("var", "")))
		"add_mesh":
			var m := describe_input(n, "mesh")
			match str(f.get("kind", "Triangle")):
				"Quad": lines.append("%s += quad %s %s %s %s" % [m, describe_input(n, "a"), describe_input(n, "b"), describe_input(n, "c"), describe_input(n, "d")])
				"Shape": lines.append("%s += %s at %s, size %s" % [m, str(f.get("shape", "Box")).to_lower(), describe_input(n, "at"), describe_input(n, "size")])
				_: lines.append("%s += triangle %s %s %s" % [m, describe_input(n, "a"), describe_input(n, "b"), describe_input(n, "c")])
			lines.append("  " + describe_input(n, "color"))
		"finish_mesh":
			lines.append("build %s (%s, %s)" % [describe_input(n, "mesh"), str(f.get("shading", "Flat")).to_lower(), str(f.get("sides", "Both sides")).to_lower()])
		"mesh_vertices":
			if str(f.get("mode", "Get")) == "Set":
				lines.append("%s points ← %s" % [describe_input(n, "mesh"), describe_input(n, "value")])
			else:
				lines.append(kept.call("points", "points of %s" % describe_input(n, "mesh")))
		"input":
			var when := str(f.get("when", "Key down"))
			lines.append(kept.call("result", "%s %s" % [f.get("key", "SPACE") if when.begins_with("Key") else str(f.get("button", "LEFT")).to_lower() + " button", when.to_lower().trim_prefix("key ").trim_prefix("mouse ")]))
		"mouse":
			lines.append("→ %s, %s" % [str(n.outs.get("x", {}).get("var", "")), str(n.outs.get("y", {}).get("var", ""))])
		"game_info":
			lines.append(kept.call("result", str(f.get("what", "Frame time")).to_lower()))
		"load_texture":
			lines.append(kept.call("texture", "load %s" % describe_input(n, "path")))
		"sound":
			if str(f.get("mode", "Play")) == "Load":
				lines.append(kept.call("sound", "load %s" % describe_input(n, "path")))
			else:
				lines.append("play %s" % describe_input(n, "sound"))
		"call_c":
			var args := []
			for p in T.parse_params(f.get("args", [])):
				args.append(describe_input(n, p[1]))
			lines.append("%s(%s)" % [_or_blank(f.get("name", "")), ", ".join(args)])
			if str(f.get("returns", "void")) != "void":
				lines.append(into.call("result"))
	return lines


static func _or_blank(text) -> String:
	return str(text) if str(text) != "" else "(?)"


static func describe_input(n: Dictionary, input: String) -> String:
	var data: Dictionary = n.args.get(input, {})
	if data.has("var"):
		return str(data.var) if str(data.var) != "" else "(variable?)"
	var value := str(data.get("value", ""))
	if data.get("type", "") == "string":
		return "\"%s\"" % value
	if data.get("type", "") == "vector3":
		return value if value.begins_with("(") else "(%s)" % value
	return value if value != "" else "0"


func _port_row(left: String, right: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var left_label := Label.new()
	left_label.text = left
	left_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left_label)
	var right_label := Label.new()
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


func flash() -> void:
	if _flash != null and _flash.is_valid():
		_flash.kill()
	self_modulate = FLASH_COLOR
	_flash = create_tween()
	_flash.tween_property(self, ^"self_modulate", Color.WHITE, 0.5)


## The program is paused here (the debugger): a yellow outline.
func _mark_paused() -> void:
	for style_name: StringName in [&"titlebar", &"titlebar_selected", &"panel", &"panel_selected"]:
		var style: StyleBoxFlat = (get_theme_stylebox(style_name) as StyleBoxFlat).duplicate()
		style.border_color = Color(1.0, 0.85, 0.2)
		style.set_border_width_all(4)
		if style_name.begins_with("titlebar"):
			style.border_width_bottom = 0
		else:
			style.border_width_top = 0
		style.shadow_color = Color(1.0, 0.85, 0.2, 0.35)
		style.shadow_size = 8
		add_theme_stylebox_override(style_name, style)
	tooltip_text = "Paused here: the Debug tab shows the variables. Continue (F8), Step (F10)."


## A brick in the wrong place (the Target can't do it, it doesn't belong in this script):
## grey instead of its category's color, outlined in red (2026-11-08, user).
const MISPLACED_GREY := Color(0.42, 0.42, 0.45)


## A C compiler complained here: a red outline, its message as the tip.
func _mark_error(text: String) -> void:
	for style_name: StringName in [&"titlebar", &"titlebar_selected", &"panel", &"panel_selected"]:
		var style: StyleBoxFlat = (get_theme_stylebox(style_name) as StyleBoxFlat).duplicate()
		style.border_color = ERROR_COLOR
		style.set_border_width_all(3)
		if style_name.begins_with("titlebar"):
			style.border_width_bottom = 0
		else:
			style.border_width_top = 0
		add_theme_stylebox_override(style_name, style)
	tooltip_text = "The C compiler stopped here: %s" % text


## Title bar in the category color; body a faint tint of it.
func _style(color: Color, context: Context) -> void:
	for selected_state: bool in [false, true]:
		var bar := StyleBoxFlat.new()
		bar.bg_color = context.brick_theme.background().lerp(color, 0.45 if selected_state else 0.32)
		bar.border_color = context.brick_theme.accent_color() if selected_state else color
		bar.set_border_width_all(2)
		bar.border_width_bottom = 0
		bar.corner_radius_top_left = 6
		bar.corner_radius_top_right = 6
		bar.set_content_margin_all(6)
		add_theme_stylebox_override(&"titlebar_selected" if selected_state else &"titlebar", bar)
		var body := StyleBoxFlat.new()
		body.bg_color = context.brick_theme.background().lerp(color, 0.1)
		body.border_color = context.brick_theme.accent_color() if selected_state else color.darkened(0.2)
		body.set_border_width_all(2)
		body.border_width_top = 0
		body.corner_radius_bottom_left = 6
		body.corner_radius_bottom_right = 6
		body.content_margin_left = 10
		body.content_margin_right = 10
		body.content_margin_top = 4
		body.content_margin_bottom = 6
		add_theme_stylebox_override(&"panel_selected" if selected_state else &"panel", body)
