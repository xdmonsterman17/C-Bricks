class_name CBWatches
extends RefCounted
## Watch expressions for the debugger. When the program pauses it reports each
## variable as "name, type, value text" (the same text Print shows). These are
## read back into values by their type (lists -> Array, maps and records ->
## Dictionary, vector3 -> Vector3), and a watch is evaluated over them with
## Godot's Expression: C-like operators (+ - * / %, == != < <= > >=, && || !),
## fields (p.x, player.name), items (gems[0], table["key"]), .size(), Godot's
## math functions (sqrt, abs, sin, min, max...) and the helpers below.
## Nothing is recompiled: a watch works in any function, at any pause.

const KEYWORDS := ["true", "false", "null", "and", "or", "not", "in", "PI", "TAU", "INF", "NAN"]


## Functions a watch may call besides Godot's (C names for C users).
class Helpers:
	extends RefCounted
	func len(v: Variant) -> int:
		if v is Array or v is Dictionary or v is String:
			return v.size() if not v is String else (v as String).length()
		return 0
	func fmax(a: float, b: float) -> float:
		return maxf(a, b)
	func fmin(a: float, b: float) -> float:
		return minf(a, b)
	func fabs(a: float) -> float:
		return absf(a)


## A variable's value text (as the program printed it) as a value of its type.
## A text that doesn't read back (cut at 400 characters, an unknown type) stays text.
static func parse_value(text: String, type: String, records: Dictionary) -> Variant:
	match type:
		"int": return text.to_int()
		"float": return text.to_float()
		"bool": return text == "true"
		"string": return text.replace("\\n", "\n").replace("\\t", "\t")
	var r := _read(text, 0, type, records, false)
	if r.is_empty() or int(r[1]) != text.length():
		return text
	return r[0]


## Reads one value of `type` from s at i: [value, end] or [] when it can't.
## quoted: strings are in quotes there (inside a record), else they run to the next ", " / closer.
static func _read(s: String, i: int, type: String, records: Dictionary, quoted: bool) -> Array:
	if CBTypes.is_list(type):
		return _read_seq(s, i, "[", "]", CBTypes.elem(type), records, false)
	if CBTypes.is_map(type):
		return _read_seq(s, i, "{", "}", CBTypes.map_value(type), records, true)
	if type == "vector2":
		var close2 := s.find(")", i)
		if not s.substr(i).begins_with("(") or close2 < 0:
			return []
		var parts2 := s.substr(i + 1, close2 - i - 1).split(",")
		if parts2.size() != 2:
			return []
		return [Vector2(parts2[0].to_float(), parts2[1].to_float()), close2 + 1]
	if type == "vector3":
		var close := s.find(")", i)
		if not s.substr(i).begins_with("(") or close < 0:
			return []
		var parts := s.substr(i + 1, close - i - 1).split(",")
		if parts.size() != 3:
			return []
		return [Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float()), close + 1]
	if records.has(type):
		var head := "%s(" % type
		if not s.substr(i).begins_with(head):
			return []
		i += head.length()
		var rec := {}
		var fields: Array = records[type]
		for k in fields.size():
			var name := "%s: " % fields[k][0]
			if not s.substr(i).begins_with(name):
				return []
			i += name.length()
			var r := _read(s, i, str(fields[k][1]), records, true)
			if r.is_empty():
				return []
			rec[str(fields[k][0])] = r[0]
			i = r[1]
			if k < fields.size() - 1:
				if not s.substr(i).begins_with(", "):
					return []
				i += 2
		if not s.substr(i).begins_with(")"):
			return []
		return [rec, i + 1]
	if type == "string" and quoted:
		if not s.substr(i).begins_with("\""):
			return []
		var end := s.find("\"", i + 1)
		return [] if end < 0 else [s.substr(i + 1, end - i - 1), end + 1]
	# A number, a bool or an unquoted string: up to the next ", " or closing bracket.
	var j := i
	while j < s.length():
		var c := s[j]
		if (c == "," and s.substr(j, 2) == ", ") or c == "]" or c == "}" or c == ")":
			break
		j += 1
	var t := s.substr(i, j - i)
	match type:
		"int": return [t.to_int(), j]
		"float": return [t.to_float(), j]
		"bool": return [t == "true", j]
	return [t, j]


static func _read_seq(s: String, i: int, open: String, close: String, elem: String, records: Dictionary, keyed: bool) -> Array:
	if not s.substr(i).begins_with(open):
		return []
	i += 1
	var arr := []
	var dict := {}
	if s.substr(i).begins_with(close):
		return [dict if keyed else arr, i + 1]
	while true:
		var key := ""
		if keyed:
			if not s.substr(i).begins_with("\""):
				return []
			var end := s.find("\": ", i + 1)
			if end < 0:
				return []
			key = s.substr(i + 1, end - i - 1)
			i = end + 3
		var r := _read(s, i, elem, records, false)
		if r.is_empty():
			return []
		if keyed:
			dict[key] = r[0]
		else:
			arr.append(r[0])
		i = r[1]
		if s.substr(i).begins_with(", "):
			i += 2
		elif s.substr(i).begins_with(close):
			return [dict if keyed else arr, i + 1]
		else:
			return []
	return []


## Evaluates a watch over the paused program's variables.
## vars: [[name, type, text], ...] (locals after globals: a local hides a global).
## Returns {"ok": bool, "text": what to show, "type": a type name}.
static func evaluate(expression: String, vars: Array, records: Dictionary) -> Dictionary:
	var src := expression.strip_edges()
	if src == "":
		return {"ok": false, "text": "type an expression", "type": ""}
	var by_name := {}
	for v in vars:
		if str(v[0]).is_valid_identifier():
			by_name[str(v[0])] = parse_value(str(v[2]), str(v[1]), records)
	# A name that isn't a variable here: say so (with a guess), as Problems do.
	var re := RegEx.create_from_string("(?<![\\w.\"])([A-Za-z_]\\w*)(?!\\w*\\s*\\()")
	var in_quotes := _quoted_ranges(src)
	for m in re.search_all(src):
		var name := m.get_string(1)
		if by_name.has(name) or name in KEYWORDS or _inside(m.get_start(1), in_quotes):
			continue
		# The same guess as Problems' (CodeGen: a swap of two letters is one edit).
		var guess := ""
		var best_d := maxi(1, name.length() / 3) + 1
		for known in by_name:
			var d := CodeGen.edit_distance(name.to_lower(), str(known).to_lower())
			if d < best_d:
				best_d = d
				guess = known
		return {"ok": false, "text": "no variable named '%s' here%s" % [name, ": did you mean '%s'?" % guess if guess != "" else ""], "type": ""}
	var e := Expression.new()
	if e.parse(src, PackedStringArray(by_name.keys())) != OK:
		return {"ok": false, "text": "can't read it: %s" % e.get_error_text(), "type": ""}
	var value: Variant = e.execute(by_name.values(), Helpers.new(), false)
	if e.has_execute_failed():
		var why := e.get_error_text()
		if why.begins_with("Invalid index") or why.begins_with("Invalid access"):
			why = "no item, key or field there (%s)" % why
		return {"ok": false, "text": why, "type": ""}
	return {"ok": true, "text": show(value), "type": type_of(value)}


static func _quoted_ranges(s: String) -> Array:
	var out := []
	var start := -1
	for i in s.length():
		if s[i] == "\"" and (i == 0 or s[i - 1] != "\\"):
			if start < 0:
				start = i
			else:
				out.append([start, i])
				start = -1
	return out


static func _inside(at: int, ranges: Array) -> bool:
	for r in ranges:
		if at > int(r[0]) and at < int(r[1]):
			return true
	return false


## A value the way the program prints it (numbers as %g, text quoted inside lists).
static func show(v: Variant, nested := false) -> String:
	match typeof(v):
		TYPE_NIL: return "nothing"
		TYPE_BOOL: return "true" if v else "false"
		TYPE_INT: return str(v)
		TYPE_FLOAT: return _num(v)
		TYPE_STRING, TYPE_STRING_NAME: return "\"%s\"" % v if nested else str(v)
		TYPE_VECTOR3: return "(%s, %s, %s)" % [_num(v.x), _num(v.y), _num(v.z)]
		TYPE_VECTOR2: return "(%s, %s)" % [_num(v.x), _num(v.y)]
		TYPE_ARRAY:
			return "[%s]" % ", ".join((v as Array).map(func(x): return show(x, true)))
		TYPE_DICTIONARY:
			var parts := []
			for k in v:
				parts.append("%s: %s" % [show(k, true), show(v[k], true)])
			return "{%s}" % ", ".join(parts)
	return str(v)


static func _num(f: float) -> String:
	if is_equal_approx(f, roundf(f)) and absf(f) < 1e15:
		return str(int(roundf(f)))
	return String.num(f, 6)


static func type_of(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING, TYPE_STRING_NAME: return "string"
		TYPE_VECTOR3: return "vector3"
		TYPE_VECTOR2: return "vector2"
		TYPE_ARRAY: return "list"
		TYPE_DICTIONARY: return "map / record"
	return type_string(typeof(v))
