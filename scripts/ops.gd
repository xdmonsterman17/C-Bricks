class_name Ops
extends RefCounted
## Editing operations on a graph, as pure data (after Brickscript's flow_ops.gd).
##
## A graph (also the .cbricks file, version 3):
##   { "format": "c-bricks", "version": 4, "target": "native", "next_id": int,
##     "nodes":  [ { id: int, type, pos: [x, y], size: [w, h] (0 = fit),
##                   fields: {name: value},
##                   args:   {name: {"var": "x"} | {"type": "int", "value": "3"}},
##                   outs:   {name: {"var": "x", "use": bool}}   (use: an existing variable)
##                   links:  {exit group: [target ids, in firing order]} } ],
##     "frames": [ { id, title, color: "#rrggbb", pos, size, nodes: [ids], fit } ],
##     "view":   { scroll: [x, y], zoom } }

const T = preload("res://scripts/node_defs.gd")

## Canvas grid; bricks and frames sit on it.
const GRID: int = 16
## A chain: each brick starts two grid squares after the one it follows.
const CHAIN_GAP: float = 2.0 * GRID
const FRAME_COLOR: Color = Color(0.35, 0.45, 0.6)
const FRAME_SIZE: Vector2 = Vector2(320, 192)

## Why the last refused edit was refused ("" when it wasn't).
static var last_error: String = ""


static func new_graph() -> Dictionary:
	var g := {"format": "c-bricks", "version": 4, "target": "native", "next_id": 1, "nodes": [], "frames": []}
	add_node(g, "start", Vector2(32, 64))
	return g


static func snap(v: Vector2) -> Vector2:
	return v.snapped(Vector2(GRID, GRID))


static func snap_up(v: Vector2) -> Vector2:
	return Vector2(ceilf(v.x / GRID - 0.001) * GRID, ceilf(v.y / GRID - 0.001) * GRID)


static func node_by_id(graph: Dictionary, id: int) -> Dictionary:
	for n in graph.nodes:
		if int(n.id) == id:
			return n
	return {}


static func frame_by_id(graph: Dictionary, id: int) -> Dictionary:
	for f in graph.get("frames", []):
		if int(f.id) == id:
			return f
	return {}


static func _take_id(graph: Dictionary) -> int:
	var id: int = int(graph.get("next_id", 1))
	for n in graph.nodes:
		id = maxi(id, int(n.id) + 1)
	for f in graph.get("frames", []):
		id = maxi(id, int(f.id) + 1)
	graph.next_id = id + 1
	return id


## Functions the project's other scripts define (set by the editor), so Call
## Function can call them: name -> {"returns", "params"}.
static var extra_funcs: Dictionary = {}


static func functions(graph: Dictionary) -> Dictionary:
	var f := extra_funcs.duplicate()
	f.merge(T.collect_functions(graph.get("nodes", [])), true)
	return f


static func layout(graph: Dictionary, node: Dictionary) -> Dictionary:
	return T.layout_for(node.type, node.fields, functions(graph))


# ------------------------------------------------------------------ nodes

## A new brick of `type` at `at` (on the grid), with its defaults. A result's
## variable gets a name no other brick uses yet.
static func add_node(graph: Dictionary, type: String, at: Vector2) -> Dictionary:
	if not T.DEFS.has(type):
		return {}
	var def: Dictionary = T.DEFS[type]
	if def.get("unique", false) and has_type(graph, type):
		last_error = "There can be only one %s." % def.title
		return {}
	var p := snap(at)
	var node := {"id": _take_id(graph), "type": type, "pos": [p.x, p.y], "size": [0, 0], "fields": {}, "args": {}, "outs": {}, "links": {}}
	for f in def.get("fields", []):
		node.fields[f[0]] = f[2].duplicate(true) if f[2] is Array else f[2]
	if type == "function":
		node.fields.name = unique_function_name(graph, "my_function")
	_fill_defaults(graph, node)
	graph.nodes.append(node)
	return node


## Inputs and outputs a node is missing (new node, or a Call Function whose
## function changed) at their defaults.
static func _fill_defaults(graph: Dictionary, node: Dictionary) -> void:
	var lay := layout(graph, node)
	for a in lay.args:
		if not node.args.has(a[0]):
			node.args[a[0]] = default_arg(a)
	for o in lay.outs:
		if not node.outs.has(o[0]):
			var base: String = o[2]
			node.outs[o[0]] = {"var": unique_name(graph, base) if base != "" else "", "use": false}


static func default_arg(a: Array) -> Dictionary:
	if a.size() > 3 and a[3] == true:
		return {"var": ""}
	var t: String = T.type_name(a[1])
	if a[1] == T.ANY:
		t = T.guess_literal_type(str(a[2]))
	return {"type": t, "value": str(a[2])}


static func has_type(graph: Dictionary, type: String) -> bool:
	for n in graph.nodes:
		if n.type == type:
			return true
	return false


## Deletes a brick and the wires to it. A reroute point keeps the wire: what
## led into it leads to where it went.
static func delete_node(graph: Dictionary, node: Dictionary) -> bool:
	var id: int = int(node.id)
	if node_by_id(graph, id).is_empty():
		return false
	var onward: Array = node.get("links", {}).get("next", []) if node.type == "reroute" else []
	for other in graph.nodes:
		for g in other.links:
			var l: Array = other.links[g]
			var at := l.find(id)
			while at >= 0:
				l.remove_at(at)
				for k in onward.size():
					if int(onward[k]) not in l and int(onward[k]) != int(other.id):
						l.insert(at + k, int(onward[k]))
				at = l.find(id)
	graph.nodes.erase(node)
	for f in graph.get("frames", []):
		f.nodes.erase(id)
	return true


## Every variable name the graph uses (outputs, Variable bricks, loop names, inputs).
static func variable_names(graph: Dictionary) -> Dictionary:
	var names := {}
	for n in graph.nodes:
		if n.type == "var":
			names[str(n.fields.get("name", ""))] = true
		for o in n.get("outs", {}).values():
			names[str(o.get("var", ""))] = true
		for p in T.parse_params(n.fields.get("params", [])) if n.type == "function" else []:
			names[p[1]] = true
	names.erase("")
	return names


static func unique_name(graph: Dictionary, base: String) -> String:
	var used := variable_names(graph)
	if not used.has(base):
		return base
	var i := 2
	while used.has("%s_%d" % [base, i]):
		i += 1
	return "%s_%d" % [base, i]


static func unique_function_name(graph: Dictionary, base: String) -> String:
	var used := functions(graph)
	if not used.has(base):
		return base
	var i := 2
	while used.has("%s_%d" % [base, i]):
		i += 1
	return "%s_%d" % [base, i]


## Renames a variable everywhere it's used. False if the name isn't free.
static func rename_variable(graph: Dictionary, old_name: String, new_name: String) -> bool:
	new_name = new_name.strip_edges()
	if not new_name.is_valid_identifier() or new_name == old_name or variable_names(graph).has(new_name):
		return false
	for n in graph.nodes:
		if n.type == "var" and n.fields.get("name") == old_name:
			n.fields.name = new_name
		for o in n.outs.values():
			if o.get("var") == old_name:
				o.var = new_name
		for a in n.args.values():
			if a.get("var") == old_name:
				a.var = new_name
	return true


## A function's new name, and every Call Function of it follows.
static func rename_function(graph: Dictionary, node: Dictionary, new_name: String) -> bool:
	var old: String = str(node.fields.get("name", ""))
	new_name = new_name.strip_edges()
	if not new_name.is_valid_identifier() or new_name == old or functions(graph).has(new_name) or new_name == "main":
		return false
	node.fields.name = new_name
	for n in graph.nodes:
		if n.type == "call" and n.fields.get("function") == old:
			n.fields.function = new_name
	return true


## After a function's inputs change: its calls get rows for the new inputs.
static func refit_calls(graph: Dictionary) -> void:
	for n in graph.nodes:
		if n.type in ["call", "call_method", "fire_server", "fire_clients", "invoke_server"]:
			_fill_defaults(graph, n)


static func set_field(node: Dictionary, name: String, value) -> bool:
	if node.fields.get(name) == value:
		return false
	node.fields[name] = value
	return true


static func set_arg(node: Dictionary, name: String, data: Dictionary) -> bool:
	if node.args.get(name) == data:
		return false
	node.args[name] = data
	return true


static func set_out(node: Dictionary, name: String, variable: String, use: bool) -> bool:
	var data := {"var": variable, "use": use}
	if node.outs.get(name) == data:
		return false
	node.outs[name] = data
	return true


static func set_position(node: Dictionary, pos: Vector2) -> bool:
	var p := snap(pos)
	if Vector2(node.pos[0], node.pos[1]) == p:
		return false
	node.pos = [p.x, p.y]
	return true


static func set_size(node: Dictionary, size: Vector2) -> bool:
	var s := snap_up(size) if size != Vector2.ZERO else Vector2.ZERO
	if Vector2(node.size[0], node.size[1]) == s:
		return false
	node.size = [s.x, s.y]
	return true


# ------------------------------------------------------------------ exits / wires

static func group_links(node: Dictionary, group: String) -> Array:
	if not node.links.has(group):
		node.links[group] = []
	return node.links[group]


static func grows(node: Dictionary) -> bool:
	return not T.DEFS[node.type].get("fixed", false)


## The brick's exit ports, top to bottom: [group, index]. Every group shows its
## wired exits plus a spare ("+ next") that adds another when wired.
static func exits_for(graph: Dictionary, node: Dictionary) -> Array:
	var out := []
	for g in layout(graph, node).groups:
		var n: int = group_links(node, g).size()
		var count: int = n + 1 if grows(node) else 1
		for i in count:
			out.append([g, i])
	return out


## How an exit is labelled (Brickscript's exit_title): "Output 2" / "+ output"
## on events; "" for a lone Next, "+ next", "Next 2", "Loop body", "+ done"...
## An exit group's name: Next, Loop body, True..., a Switch case's value ("= 3").
static func group_title(node: Dictionary, group: String) -> String:
	if group.begins_with("case_"):
		var cases: Array = node.get("fields", {}).get("cases", [])
		var i := group.trim_prefix("case_").to_int()
		return "= %s" % (str(cases[i]) if i < cases.size() else "?")
	if group == "default":
		return "Default"
	return T.EXIT_TITLES.get(group, group.capitalize())


static func exit_title(node: Dictionary, group: String, index: int) -> String:
	var title: String = group_title(node, group)
	var groups: Array = T.DEFS[node.type].get("groups", [])
	var after_branches: bool = group == "next" and groups.size() > 1
	if after_branches:
		title = "Then"
	var wired: int = group_links(node, group).size()
	if T.kind_of(node.type) == "event":
		return "Output %d" % (index + 1) if index < wired else "+ output"
	if not grows(node):
		return ""
	if index >= wired and wired > 0:
		return "+ " + title.to_lower()
	if wired <= 1:
		return "" if group == "next" and not after_branches else title
	return "%s %d" % [title, index + 1]


## Whether `from` leads (along exits) to `to`.
static func leads_to(graph: Dictionary, from: Dictionary, to: Dictionary) -> bool:
	var seen := {}
	var todo := [int(from.id)]
	while not todo.is_empty():
		var id: int = todo.pop_back()
		if id == int(to.id):
			return true
		if seen.has(id):
			continue
		seen[id] = true
		var n := node_by_id(graph, id)
		for g in n.get("links", {}):
			todo.append_array(n.links[g])
	return false


## Wires `from`'s exit (group, index) to `to`. Dropping on a wired exit puts the
## new chain before it. Refuses wires into events and declarations, to the
## brick itself, and wires that would loop back (repeat with a loop brick).
static func connect_exit(graph: Dictionary, from: Dictionary, group: String, index: int, to: Dictionary) -> bool:
	last_error = ""
	if from.is_empty() or to.is_empty() or int(from.id) == int(to.id):
		last_error = "A brick can't lead to itself."
		return false
	if not T.has_input(to.type):
		last_error = "%s starts chains: nothing can lead into it." % T.title_of(to.type, to.fields)
		return false
	if leads_to(graph, to, from):
		last_error = "That wire would loop back. Use While, For range or Repeat to run bricks again."
		return false
	var l := group_links(from, group)
	var old := l.find(int(to.id))
	if old >= 0:
		l.remove_at(old)
		if old < index:
			index -= 1
	if not grows(from):
		l.clear()
		index = 0
	l.insert(clampi(index, 0, l.size()), int(to.id))
	return true


static func disconnect_exit(from: Dictionary, group: String, index: int) -> bool:
	var l := group_links(from, group)
	if index < 0 or index >= l.size():
		return false
	l.remove_at(index)
	return true


## Swaps two chains of one exit group (Properties' ↑ / ↓).
static func swap_exits(node: Dictionary, group: String, a: int, b: int) -> bool:
	var l := group_links(node, group)
	if a < 0 or b < 0 or a >= l.size() or b >= l.size() or a == b:
		return false
	var tmp = l[a]
	l[a] = l[b]
	l[b] = tmp
	return true


## A reroute point on the wire from `from`'s exit, wired in between.
static func insert_reroute(graph: Dictionary, from: Dictionary, group: String, index: int, at: Vector2) -> Dictionary:
	var l := group_links(from, group)
	if index >= l.size():
		return {}
	var target: int = l[index]
	var point := add_node(graph, "reroute", at)
	l[index] = int(point.id)
	point.links["next"] = [target]
	return point


# ------------------------------------------------------------------ clipboard

## Copies of `nodes` with only the wires between them.
static func copy_nodes(nodes: Array) -> Array:
	var ids := nodes.map(func(n): return int(n.id))
	var out := []
	for n in nodes:
		if T.DEFS[n.type].get("unique", false):
			continue
		var c: Dictionary = n.duplicate(true)
		for g in c.links:
			c.links[g] = c.links[g].filter(func(t): return int(t) in ids)
		out.append(c)
	return out


static func clipboard_text(copied: Array) -> String:
	return JSON.stringify({"format": "c-bricks-clip", "nodes": copied})


static func clipboard_data(text: String) -> Array:
	var d = JSON.parse_string(text)
	if d is Dictionary and d.get("format") == "c-bricks-clip":
		var g := {"nodes": d.nodes, "frames": []}
		normalize(g)
		return g.nodes
	return []


## Adds copies to the graph: at `at` (their top-left), or next to where they
## were. Returns the new bricks.
static func paste_nodes(graph: Dictionary, copied: Array, at = null) -> Array:
	if copied.is_empty():
		return []
	var top_left := Vector2(INF, INF)
	for c in copied:
		top_left = top_left.min(Vector2(c.pos[0], c.pos[1]))
	var offset: Vector2 = (at - top_left) if at is Vector2 else Vector2(GRID * 2, GRID * 2)
	var remap := {}
	var made := []
	for c in copied:
		var n: Dictionary = c.duplicate(true)
		n.id = _take_id(graph)
		remap[int(c.id)] = n.id
		var p := snap(Vector2(c.pos[0], c.pos[1]) + offset)
		n.pos = [p.x, p.y]
		for o in n.outs.values():
			if not o.get("use", false) and o.get("var", "") != "":
				o.var = unique_name(graph, o.var)
		graph.nodes.append(n)
		made.append(n)
	for n in made:
		for g in n.links:
			n.links[g] = n.links[g].filter(func(t): return remap.has(int(t))).map(func(t): return remap[int(t)])
	return made


# ------------------------------------------------------------------ arranging

## Brickscript's Arrange: in each chain, every brick starts CHAIN_GAP after the
## right edge of the brick it follows (the furthest, when several lead to it);
## a chain's first brick and every row (y) stay. `sizes`: id -> drawn size.
## `only`: ids whose chains are arranged (empty: all).
static func arranged_x(graph: Dictionary, sizes: Dictionary, only: Array = []) -> Dictionary:
	var leads := {}
	var from_count := {}
	var linked := {}
	for n in graph.nodes:
		leads[int(n.id)] = []
		from_count[int(n.id)] = from_count.get(int(n.id), 0)
		linked[int(n.id)] = linked.get(int(n.id), [])
	for n in graph.nodes:
		for g in n.links:
			for t in n.links[g]:
				t = int(t)
				if not leads.has(t) or t == int(n.id) or t in leads[int(n.id)]:
					continue
				leads[int(n.id)].append(t)
				from_count[t] += 1
				linked[int(n.id)].append(t)
				linked[t].append(int(n.id))
	var wanted := {}
	var todo: Array = only.duplicate() if not only.is_empty() else leads.keys()
	while not todo.is_empty():
		var id: int = todo.pop_back()
		if wanted.has(id) or not leads.has(id):
			continue
		wanted[id] = true
		todo.append_array(linked[id])
	var result := {}
	var ready: Array = from_count.keys().filter(func(id): return from_count[id] == 0)
	while not ready.is_empty():
		var id: int = ready.pop_front()
		var node := node_by_id(graph, id)
		if not result.has(id):
			result[id] = float(node.pos[0])
		var w: float = (sizes.get(id, Vector2.ZERO) as Vector2).x
		var right: float = ceilf((result[id] + w - 0.5) / GRID) * GRID + CHAIN_GAP
		for t in leads[id]:
			result[t] = maxf(result.get(t, -INF), right)
			from_count[t] -= 1
			if from_count[t] == 0:
				ready.append(t)
	for id in result.keys():
		if not wanted.has(id):
			result.erase(id)
	return result


static func arrange(graph: Dictionary, sizes: Dictionary, only: Array = []) -> bool:
	var moved := false
	var places := arranged_x(graph, sizes, only)
	for id in places:
		var n := node_by_id(graph, id)
		if not is_equal_approx(float(n.pos[0]), places[id]):
			n.pos[0] = places[id]
			moved = true
	return moved


## A full layout (columns and rows), for laying out generated graphs: each
## brick level with the first chain it starts, chains stacked in firing order.
static func tidy(graph: Dictionary, sizes: Dictionary) -> void:
	var gap := Vector2(CHAIN_GAP, GRID * 2)
	var entries: Array = graph.nodes.filter(func(n): return n.type == "function") + graph.nodes.filter(func(n): return T.kind_of(n.type) == "event" and n.type != "function")
	var placed := {}
	var st := {"y": 0.0}
	var place := func(self_ref: Callable, n: Dictionary, x: float) -> float:
		placed[int(n.id)] = true
		var y: float = st.y
		n.pos = [x, y]
		var sz: Vector2 = sizes.get(int(n.id), Vector2(176, 64))
		var bottom: float = y + sz.y
		var next_x: float = ceilf((x + sz.x) / GRID) * GRID + gap.x
		for g in layout(graph, n).groups:
			for t in group_links(n, g):
				var c := node_by_id(graph, int(t))
				if not c.is_empty() and not placed.has(int(c.id)):
					bottom = maxf(bottom, self_ref.call(self_ref, c, next_x))
		st.y = maxf(st.y, ceilf((bottom + gap.y) / GRID) * GRID)
		return bottom
	for e in entries:
		place.call(place, e, 0.0)
		st.y += gap.y
	for n in graph.nodes:
		if not placed.has(int(n.id)):
			n.pos = [0.0, st.y]
			st.y += (sizes.get(int(n.id), Vector2(176, 64)) as Vector2).y + gap.y


# ------------------------------------------------------------------ frames

static func add_frame(graph: Dictionary, at: Vector2, ids: Array = []) -> Dictionary:
	var p := snap(at)
	var f := {"id": _take_id(graph), "title": "Comment", "color": FRAME_COLOR.to_html(false), "pos": [p.x, p.y],
		"size": [FRAME_SIZE.x, FRAME_SIZE.y], "nodes": ids.map(func(i): return int(i)), "fit": true}
	for other in graph.frames:
		for i in f.nodes:
			other.nodes.erase(i)
	graph.frames.append(f)
	return f


static func delete_frame(graph: Dictionary, frame: Dictionary) -> bool:
	if frame.is_empty():
		return false
	graph.frames.erase(frame)
	return true


static func attach_to_frame(graph: Dictionary, frame: Dictionary, id: int) -> bool:
	if frame.is_empty() or id in frame.nodes or node_by_id(graph, id).is_empty():
		return false
	for other in graph.frames:
		other.nodes.erase(id)
	frame.nodes.append(id)
	return true


static func detach_from_frame(frame: Dictionary, id: int) -> bool:
	if id not in frame.nodes:
		return false
	frame.nodes.erase(id)
	return true


static func set_frame(frame: Dictionary, key: String, value) -> bool:
	if value is Vector2:
		value = [value.x, value.y]
	if value is Color:
		value = value.to_html(false)
	if frame.get(key) == value:
		return false
	frame[key] = value
	return true


# ------------------------------------------------------------------ files

## JSON numbers come back as floats, and older files (version 1 / 2) store
## things differently: bring a loaded graph up to version 3.
static func normalize(graph: Dictionary) -> Dictionary:
	if not graph.has("frames"):
		graph.frames = []
	if int(graph.get("version", 1)) < 4:
		_upgrade_class_names(graph)
	var next := 1
	var kept := []
	for n in graph.get("nodes", []):
		n = _upgrade_node(n)
		if n.is_empty():
			continue
		n.id = _to_id(n.get("id", 0))
		next = maxi(next, n.id + 1)
		n.pos = [float(n.get("pos", [0, 0])[0]), float(n.get("pos", [0, 0])[1])]
		n.size = [float(n.get("size", [0, 0])[0]), float(n.get("size", [0, 0])[1])]
		for k in ["fields", "args", "outs", "links"]:
			if not n.get(k) is Dictionary:
				n[k] = {}
		var links := {}
		for g in n.links:
			links[_upgrade_group(n.type, str(g))] = Array(n.links[g]).map(func(t): return _to_id(t))
		n.links = links
		for a in n.args.keys():
			var v = n.args[a]
			if not v is Dictionary:
				v = {"value": str(v)}
			if str(v.get("var", "")) != "":
				n.args[a] = {"var": str(v.var)}
			elif v.has("type"):
				n.args[a] = {"type": str(v.type), "value": str(v.get("value", ""))}
			else:
				n.args[a] = {"type": "", "value": str(v.get("value", ""))}
		for o in n.outs.keys():
			var v = n.outs[o]
			n.outs[o] = {"var": str(v), "use": false} if not v is Dictionary else {"var": str(v.get("var", "")), "use": bool(v.get("use", false))}
		kept.append(n)
	graph.nodes = kept
	# Untyped literals (older files): typed from their input, or guessed from the text.
	for n in graph.nodes:
		var lay := layout(graph, n)
		for a in lay.args:
			if n.args.has(a[0]) and n.args[a[0]].get("type", null) == "":
				var t: String = T.type_name(a[1]) if a[1] != T.ANY else T.guess_literal_type(n.args[a[0]].value)
				n.args[a[0]].type = t
		_fill_defaults(graph, n)
	for f in graph.frames:
		f.id = int(f.get("id", 0))
		f.nodes = Array(f.get("nodes", [])).map(func(i): return int(i))
		f.pos = [float(f.pos[0]), float(f.pos[1])]
		f.size = [float(f.size[0]), float(f.size[1])]
		next = maxi(next, f.id + 1)
	graph.next_id = maxi(int(graph.get("next_id", 1)), next)
	graph.version = 4
	return graph


## Files before version 4 (2026-11-07) name the old built-in classes: Object -> Node,
## Part -> Shape3D, Model -> Spatial3D, MeshPart -> Mesh3D, Camera -> Camera3D, Light ->
## Light3D, Label -> Text2D, in the settings that name a class or a type (once: a class
## of the project's own called Camera, later, is left alone).
static func _upgrade_class_names(graph: Dictionary) -> void:
	for n in graph.get("nodes", []):
		var f = n.get("fields", {})
		if not f is Dictionary:
			continue
		for k in ["of", "class", "extends", "type", "returns"]:
			if f.get(k) is String:
				f[k] = CBTypes.renamed_type(f[k])
		for k in ["params", "fields", "values", "args"]:
			if f.get(k) is Array:
				for p in f[k]:
					if p is Array and p.size() >= 2 and p[1] is String:
						p[1] = CBTypes.renamed_type(p[1])


## 5, 5.0 and "n5" (version 2 files) are all brick 5.
static func _to_id(raw) -> int:
	if raw is int or raw is float:
		return int(raw)
	return str(raw).trim_prefix("n").to_int()


static func _upgrade_group(type: String, g: String) -> String:
	if T.kind_of(type) == "event" and g in ["", "out"]:
		return "out"
	match g:
		"": return "next"
		"body": return "loop"
		"then": return "next" if type == "if" else "done"
	return g


## Version 2 bricks that became modes of a family (Declare / Set / Change ->
## Variable), or were replaced (Comment -> frames).
static func _upgrade_node(n: Dictionary) -> Dictionary:
	var f: Dictionary = n.get("fields", {})
	# Variable kinds before Brickscript's names (2026-11-06): Local -> Chain, Global -> Shared.
	if n.get("type", "") == "var" and f.has("scope"):
		f.scope = {"Local": "Chain", "Global": "Shared"}.get(str(f.scope), str(f.scope))
	for o in n.get("outs", {}).values():
		if o is Dictionary and str(o.get("kind", "")) == "Global":
			o.kind = "Shared"
	match n.get("type", ""):
		"comment":
			return {}
		"declare":
			n.type = "var"
			n.fields = {"mode": "Set", "name": f.get("name", "x"), "scope": "Shared" if f.get("global", false) else "Chain"}
			var v = n.get("args", {}).get("value", {})
			if v is Dictionary and str(v.get("var", "")) == "":
				var text := str(v.get("value", ""))
				var ty := str(f.get("type", "int"))
				n.args = {"value": {"type": ty, "value": text if text != "" else {"int": "0", "float": "0.0", "bool": "false", "string": ""}.get(ty, "0")}}
		"set":
			n.type = "var"
			n.fields = {"mode": "Set", "name": f.get("name", "x"), "scope": "Chain"}
		"modify":
			n.type = "var"
			n.fields = {"mode": "Add", "name": f.get("name", "x"), "scope": "Chain"}
			if n.get("args", {}).has("amount"):
				n.args = {"value": n.args.amount}
		"read_int", "read_float":
			n.fields = {"as": "int" if n.type == "read_int" else "float", "prompt": f.get("prompt", "")}
			n.type = "read"
		"math":
			var names := {"+": "Add", "-": "Subtract", "*": "Multiply", "/": "Divide", "%": "Remainder"}
			n.fields.op = names.get(f.get("op", "+"), f.get("op", "Add"))
		"logic":
			n.fields.op = {"&&": "And", "||": "Or"}.get(f.get("op", "&&"), f.get("op", "And"))
		"not":
			n.type = "logic"
			n.fields = {"op": "Not"}
		"pow":
			n.type = "math_func"
			n.fields = {"func": "pow"}
			var args: Dictionary = n.get("args", {})
			n.args = {"x": args.get("base", {"value": "2"}), "exp": args.get("exp", {"value": "2"})}
		"function":
			if f.get("params") is String:
				f.params = T.parse_params(f.params).map(func(p): return [p[1], p[0]])
		"if", "while":
			if not f.has("operator"):
				n.fields = {"operator": "is true"}
				if n.get("args", {}).has("cond"):
					n.args = {"a": n.args.cond}
	if not T.DEFS.has(n.get("type", "")):
		return {}
	return n
