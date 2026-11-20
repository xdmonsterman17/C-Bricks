class_name ShaderGraph
extends RefCounted
## The visual shader editor's engine (phase 2, 2026-11-18): a `.cbshader` graph -> GLSL text.
##
## FILE (documented JSON, API.md section 11):
##   {"cbshader": 1, "kind": "surface" | "post",
##    "nodes": [{"id": 1, "type": "uv", "t": "vec3", "values": {"scale": [8]}, "pos": [x, y]}, ...],
##    "wires": [{"from": 1, "out": "uv", "to": 2, "in": "uv"}, ...]}
## The NODE TABLE is data (`shader_nodes.json`: inputs, outputs, one GLSL expression per output); the runtime
## carries the same table, so C-Vert and exported programs compile graphs with the C emitter in
## `runtime/cb_shadergraph.c`. The two emitters must give identical text (runner check `shader_graph`).
##
## EMISSION (the C emitter does exactly this):
##   * from the output node, depth first, an input's wire first, in the table's input order; each node reached
##     emits one line per output: `    <type> v<id>_<out> = <expression>;`
##   * `gen` types take the node's `t` (float when absent); an unwired input = its value literal (the node's
##     `values[input]` or the table's default; a list of numbers, the last one repeats; a string default is raw GLSL)
##   * a wire is coerced to the input's type: float -> splat, vector -> `.x` / `.xy` / `.xyz`, smaller -> larger pads
##     (0.0, then 1.0 for the last one)
##   * numbers print as `%.4f` with the trailing zeros cut (at least one decimal); -0 prints 0.0

const NODES_PATH := "res://scripts/shader_nodes.json"
const TYPES := ["float", "vec2", "vec3", "vec4"]
const SWIZ := "xyzw"

static var _table := {}


static func table() -> Dictionary:
	if _table.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(NODES_PATH))
		_table = (parsed as Dictionary).get("nodes", {}) if parsed is Dictionary else {}
	return _table


## The table as one line of JSON (the C runtime embeds it).
static func table_text() -> String:
	return JSON.stringify({"nodes": table()}, "", false)


static func size_of(t: String) -> int:
	return TYPES.find(t) + 1


## How a number prints in GLSL (identical in C: snprintf "%.4f", cut zeros, keep one decimal).
static func num(v: float) -> String:
	var s := "%.4f" % v
	while s.ends_with("0") and not s.ends_with(".0"):
		s = s.substr(0, s.length() - 1)
	if s == "-0.0":
		s = "0.0"
	return s


static func literal(vals: Array, t: String) -> String:
	var n := size_of(t)
	var parts := PackedStringArray()
	for i in n:
		var v: float = 0.0
		if not vals.is_empty():
			v = float(vals[mini(i, vals.size() - 1)])
		parts.append(num(v))
	return parts[0] if n == 1 else "%s(%s)" % [t, ", ".join(parts)]


static func coerce(e: String, from: String, to: String) -> String:
	if from == to:
		return e
	var fs := size_of(from)
	var ts := size_of(to)
	if fs == 1:
		return "%s(%s)" % [to, e]
	if fs > ts:
		return "%s.%s" % [e, SWIZ.substr(0, ts)]
	if fs == 2 and ts == 3:
		return "vec3(%s, 0.0)" % e
	if fs == 2 and ts == 4:
		return "vec4(%s, 0.0, 1.0)" % e
	return "vec4(%s, 1.0)" % e  # vec3 -> vec4


## graph -> {"glsl": String ("" when there are problems), "problems": PackedStringArray}
static func compile(graph: Dictionary) -> Dictionary:
	var problems := PackedStringArray()
	var tab := table()
	var kind := str(graph.get("kind", "surface"))
	var kl := "p" if kind == "post" else "s"
	var by_id := {}
	for nd in graph.get("nodes", []):
		by_id[int((nd as Dictionary).get("id", 0))] = nd
	var out_id := 0
	var out_type := "post_out" if kind == "post" else "surface_out"
	for id in by_id:
		if str(by_id[id].get("type", "")) == out_type:
			out_id = id
			break
	if out_id == 0:
		return {"glsl": "", "problems": PackedStringArray(["No %s node." % str(tab[out_type].title).to_lower()])}
	var wires: Array = graph.get("wires", [])
	var lines := PackedStringArray()
	var vars := {}      # "id:out" -> type
	var state := {}     # id -> 1 (in progress) / 2 (done)

	var result := _emit(out_id, by_id, wires, tab, kl, lines, vars, state, problems)
	if not problems.is_empty() or not result.ok:
		return {"glsl": "", "problems": problems}
	var exprs: Array = result.exprs
	var body := "\n".join(lines)
	if not lines.is_empty():
		body += "\n"
	var glsl := ""
	if kind == "post":
		glsl = "vec3 cb_post(vec3 c, vec2 uv) {\n%s    return %s;\n}\n" % [body, exprs[0]]
	else:
		glsl = "vec4 cb_surface(vec4 base, vec2 uv, vec3 normal) {\n%s    return vec4(%s, %s);\n}\n" % [body, exprs[0], exprs[1]]
	return {"glsl": glsl, "problems": problems}


## Emits what the output node reads: {ok, exprs: one expression per output-node input}.
static func _emit(out_id: int, by_id: Dictionary, wires: Array, tab: Dictionary, kl: String, lines: PackedStringArray, vars: Dictionary, state: Dictionary, problems: PackedStringArray) -> Dictionary:
	var exprs := []
	var node: Dictionary = by_id[out_id]
	var def: Dictionary = tab[str(node.type)]
	for inp in def["in"]:
		var e := _input_expr(node, inp, by_id, wires, tab, kl, lines, vars, state, problems)
		exprs.append(e)
	return {"ok": problems.is_empty(), "exprs": exprs}


static func _wire_to(wires: Array, id: int, inname: String) -> Variant:
	for w in wires:
		if int(w.get("to", -1)) == id and str(w.get("in", "")) == inname:
			return w
	return null


static func _type_of(node: Dictionary, def: Dictionary, t: String) -> String:
	return str(node.get("t", "float")) if t == "gen" else t


static func _title(node: Dictionary, def: Dictionary) -> String:
	return "%s (node %d)" % [def.title, int(node.id)]


## The expression an input reads (a coerced variable, or its value literal).
static func _input_expr(node: Dictionary, inp: Array, by_id: Dictionary, wires: Array, tab: Dictionary, kl: String, lines: PackedStringArray, vars: Dictionary, state: Dictionary, problems: PackedStringArray) -> String:
	var def: Dictionary = tab[str(node.type)]
	var want := _type_of(node, def, str(inp[1]))
	var w: Variant = _wire_to(wires, int(node.id), str(inp[0]))
	if w != null:
		var sid := int(w.get("from", -1))
		if not by_id.has(sid):
			problems.append("%s: a wire comes from a missing node." % _title(node, def))
		else:
			var src_type := _emit_node(sid, by_id, wires, tab, kl, lines, vars, state, problems)
			var key := "%d:%s" % [sid, str(w.get("out", ""))]
			if vars.has(key):
				return coerce("v%d_%s" % [sid, str(w.get("out", ""))], str(vars[key]), want)
			if src_type != "":
				problems.append("%s: a wire reads an output that does not exist." % _title(node, def))
		return "0.0"
	var d: Variant = inp[2]
	if d is String:
		return str(d)
	var vals: Array = (node.get("values", {}) as Dictionary).get(str(inp[0]), d)
	return literal(vals, want)


## Emits a node's lines once; returns its first output's type ("" on a problem).
static func _emit_node(id: int, by_id: Dictionary, wires: Array, tab: Dictionary, kl: String, lines: PackedStringArray, vars: Dictionary, state: Dictionary, problems: PackedStringArray) -> String:
	var node: Dictionary = by_id[id]
	if not tab.has(str(node.get("type", ""))):
		problems.append("Node (node %d): unknown type." % id)
		return ""
	var def: Dictionary = tab[str(node.type)]
	if state.get(id, 0) == 2:
		return str(vars.get("%d:%s" % [id, def["out"][0][0]], "float")) if not def["out"].is_empty() else ""
	if state.get(id, 0) == 1:
		problems.append("%s: the wires loop back to it." % _title(node, def))
		return ""
	state[id] = 1
	if str(def.kinds).find(kl) < 0:
		problems.append("%s: not available in %s shaders." % [_title(node, def), "post" if kl == "p" else "surface"])
	var subs := {}
	for inp in def["in"]:
		subs[str(inp[0])] = _input_expr(node, inp, by_id, wires, tab, kl, lines, vars, state, problems)
	var first := ""
	for i in def["out"].size():
		var o: Array = def["out"][i]
		var ot := _type_of(node, def, str(o[1]))
		var code: String = def["code"][i]
		for k in subs:
			code = code.replace("{%s}" % k, subs[k])
		lines.append("    %s v%d_%s = %s;" % [ot, id, o[0], code])
		vars["%d:%s" % [id, o[0]]] = ot
		if first == "":
			first = ot
	state[id] = 2
	return first
