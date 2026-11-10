@tool
extends RefCounted

## Every edit the wire editor makes to a BrickscriptFlowGraph, as plain data
## operations (no UI), so they can be tested headless. Each returns whether it
## changed anything (or what it made); the editor redraws after a change.

const Library = preload("flow_library.gd")
const Types = preload("flow_types.gd")
const Kind = BrickscriptVariable.Kind

## The editor's grid: node positions and sizes are whole squares of it.
const GRID: int = 16

## Default names for new script variables, by kind.
const NEW_NAMES: Array[String] = ["CONSTANT", "setting", "value"]


#region Nodes and wires

## Adds a node of `type` at `position` (snapped to the grid) with every
## setting at its default. In a script node, a Node input that starts at
## Self (Owner, Give To, Damage...) or inside it (Play animation's
## AnimationPlayer) starts one step up: at the node it works for
## (Self.Parent), not the script node. One that starts at the parent (Get
## property...) is that node already; Find first ancestor's stays at Self
## (`stays_self`: it searches from Self's parent).
static func add_node(graph: BrickscriptFlowGraph, type: StringName, position: Vector2) -> BrickscriptFlowNode:
	var definition: Dictionary = Library.get_definition(type)
	if definition.is_empty():
		_refuse("add_node", "there's no brick type '%s' (API.md lists them: the name after ####, e.g. `print`)" % type)
		return null
	last_error = ""
	var node: BrickscriptFlowNode = graph.add_node(type, snap(position))
	for setting: Dictionary in definition.get("settings", []):
		# A declared name must be free (worked out before this node has one).
		node.settings[setting["name"]] = unique_name(graph, setting["default"]) if setting["kind"] == "declare" else _new_default(setting)
	start_paths(graph, node)
	return node


## A new brick's Node inputs in a script node (see add_node()); a blank
## Node setting (When signal received, Get node, Sync) starts at Self.Parent
## too.
static func start_paths(graph: BrickscriptFlowGraph, node: BrickscriptFlowNode) -> void:
	if not graph.script_node or graph.shared:
		return
	for setting: Dictionary in Library.get_definition(node.type).get("settings", []):
		if setting.get("kind", "") == "node_path" and str(node.settings.get(setting["name"], "")).strip_edges().is_empty():
			node.settings[setting["name"]] = ".."
	for spec: Dictionary in Library.get_definition(node.type).get("inputs", []):
		var default: Dictionary = spec.get("default", {})
		# (A blank that means something stays blank: a Terrain input's "the
		# scene's Terrain", spec `blank`.)
		if int(default.get("type", -1)) == Types.ValueType.NODE and not default.has("var") and default != Library.PARENT_NODE and not spec.get("stays_self", false) and not node.inputs.has(spec["name"]) \
				and not (spec.has("blank") and str(default.get("value", "")).strip_edges().is_empty()):
			node.inputs[spec["name"]] = {"type": Types.ValueType.NODE, "value": _moved_path(str(default["value"]), true)}


## Constant / Export: declares a script variable, no wires.
static func is_declaration(node: BrickscriptFlowNode) -> bool:
	return node != null and Library.get_definition(node.type).get("kind", -1) == Library.Kind.DECLARE


## The nearest grid point.
static func snap(point: Vector2) -> Vector2:
	return point.snapped(Vector2(GRID, GRID))


## Float noise ignored by snap_up (GraphEdit's zoom leaves sizes like
## 176.0001: not a grid square more).
const SNAP_SLACK: float = 0.01


## Rounded up to whole grid squares (a size never shrinks below its content).
static func snap_up(extent: Vector2) -> Vector2:
	return ((extent - Vector2(SNAP_SLACK, SNAP_SLACK)) / GRID).ceil() * GRID


static func set_position(node: BrickscriptFlowNode, position: Vector2) -> bool:
	position = snap(position)
	if node.position == position:
		return false
	node.position = position
	return true


## A size the user dragged the node to (snapped up to the grid), or ZERO to
## fit its content again.
static func set_size(node: BrickscriptFlowNode, extent: Vector2) -> bool:
	extent = snap_up(extent) if extent != Vector2.ZERO else Vector2.ZERO
	if node.size == extent:
		return false
	node.size = extent
	return true


static func is_event(node: BrickscriptFlowNode) -> bool:
	return node != null and Library.get_definition(node.type).get("kind", -1) == Library.Kind.EVENT


## The exits to show on `node`: an action's fixed ones; for an event its
## numbered outputs up to the highest wired one, plus one spare to wire next.
static func exits_for(node: BrickscriptFlowNode) -> Array[StringName]:
	var result: Array[StringName] = []
	if not is_event(node):
		# Next / Loop body / Done grow like an event's outputs: wiring the
		# last one adds another (they run in order, each chain to its end).
		for base: StringName in Library.exits_of(node.type):
			if not grows(node, base):
				result.append(base)
				continue
			for number: int in range(1, highest_of(node, base) + 2):
				result.append(exit_name(base, number))
		return result
	for number: int in range(1, highest_output(node) + 2):
		result.append(StringName(str(number)))
	return result


## Exits that grow (see exits_for): an action's Next, a loop's Loop body and
## Done. If's True / False and Raycast's Hit / Nothing hit don't; nor does a
## reroute point (it only bends one wire).
const GROWING_EXITS: Array[StringName] = [&"next", &"loop", &"done"]


static func grows(node: BrickscriptFlowNode, base: StringName) -> bool:
	return GROWING_EXITS.has(base) and node.type != &"reroute" and not is_event(node)


## &"next_2" -> &"next" (and &"next" -> &"next").
static func exit_base(exit: StringName) -> StringName:
	var text: String = String(exit)
	var cut: int = text.rfind("_")
	return StringName(text.left(cut)) if cut > 0 and text.substr(cut + 1).is_valid_int() and GROWING_EXITS.has(StringName(text.left(cut))) else exit


## &"next" is 1, &"next_2" is 2.
static func exit_number(exit: StringName) -> int:
	var base: StringName = exit_base(exit)
	return 1 if base == exit else int(String(exit).substr(String(base).length() + 1))


static func exit_name(base: StringName, number: int) -> StringName:
	return base if number <= 1 else StringName("%s_%d" % [base, number])


## The highest wired number of a growing exit (0 if none is wired).
static func highest_of(node: BrickscriptFlowNode, base: StringName) -> int:
	var highest: int = 0
	for exit: StringName in node.exits:
		if node.exits[exit] > 0 and exit_base(exit) == base:
			highest = maxi(highest, exit_number(exit))
	return highest


## What a growing exit's wires lead to, in order (gaps skipped).
static func outputs_of(node: BrickscriptFlowNode, base: StringName) -> Array[int]:
	var ids: Array[int] = []
	for number: int in range(1, highest_of(node, base) + 1):
		var id: int = node.exits.get(exit_name(base, number), 0)
		if id > 0:
			ids.append(id)
	return ids


## How an exit is labelled: "Loop body", "Done 2", "Next 2", "+ next" (the
## spare one), "" for a lone unwired Next.
static func exit_title(node: BrickscriptFlowNode, exit: StringName) -> String:
	var base: StringName = exit_base(exit)
	var title: String = Library.get_definition(node.type).get("exit_titles", {}).get(base, "Next" if base == &"next" else String(base).capitalize())
	if not grows(node, base):
		return title
	var number: int = exit_number(exit)
	var highest: int = highest_of(node, base)
	if number == 1 and highest == 0:
		return "" if base == &"next" else title
	if number > highest:
		return "+ " + title.to_lower()
	if highest == 1:
		return "" if base == &"next" else title
	return "%s %d" % [title, number]


## The highest numbered output of an event that is wired (0 if none).
static func highest_output(node: BrickscriptFlowNode) -> int:
	var highest: int = 0
	for exit: StringName in node.exits:
		if String(exit).is_valid_int() and node.exits[exit] > 0:
			highest = maxi(highest, int(String(exit)))
	return highest


## Wires `from`'s `exit` to `to`, replacing what it led to. Refuses wires into
## events, to the node itself, and wires that would loop back.
static func connect_exit(graph: BrickscriptFlowGraph, from: BrickscriptFlowNode, exit: StringName, to: BrickscriptFlowNode) -> bool:
	var problem: String = _wire_problem(graph, from, exit, to)
	if not problem.is_empty():
		_refuse("connect_exit", problem)
		return false
	last_error = ""
	if from.exits.get(exit, 0) == to.id:
		return false
	from.exits[exit] = to.id
	return true


## Why `from`'s `exit` can't lead to `to` ("" if it can).
static func _wire_problem(graph: BrickscriptFlowGraph, from: BrickscriptFlowNode, exit: StringName, to: BrickscriptFlowNode) -> String:
	if from == null or to == null:
		return "a brick is null (add_node gave null for an unknown type?)"
	var title: String = str(Library.get_definition(to.type).get("title", to.type))
	if from == to:
		return "a brick can't lead to itself"
	if is_event(to):
		return "'%s' (node %d) is an event: events start chains, nothing leads into them" % [title, to.id]
	if is_declaration(to):
		return "'%s' (node %d) declares a script variable: it takes no wires" % [title, to.id]
	if not exits_for(from).has(exit):
		return "'%s' (node %d) has no exit '%s' (its exits: %s)" % [str(Library.get_definition(from.type).get("title", from.type)), from.id, exit, ", ".join(exits_for(from))]
	if from.exits.get(exit, 0) != to.id and leads_to(graph, to, from):
		return "'%s' (node %d) already leads back here: wires can't make a loop; repeat with For each / Repeat / While (their Loop body exit)" % [title, to.id]
	return ""


## Why the last add_node / connect_exit refused ("" when it didn't): for
## graphs built in code. Outside the editor it's also a warning.
static var last_error: String = ""


static func _refuse(what: String, problem: String) -> void:
	last_error = problem
	if not Engine.is_editor_hint():
		push_warning("Brickscript %s: %s" % [what, problem])


static func disconnect_exit(from: BrickscriptFlowNode, exit: StringName) -> bool:
	if not from.exits.has(exit):
		return false
	from.exits.erase(exit)
	return true


## Whether following exec wires from `start` ever reaches `target`.
static func leads_to(graph: BrickscriptFlowGraph, start: BrickscriptFlowNode, target: BrickscriptFlowNode) -> bool:
	var seen: Dictionary[int, bool] = {}
	var waiting: Array[int] = [start.id]
	while not waiting.is_empty():
		var id: int = waiting.pop_back()
		if id == target.id:
			return true
		if seen.has(id):
			continue
		seen[id] = true
		var node: BrickscriptFlowNode = graph.node_by_id(id)
		if node != null:
			for next: int in node.exits.values():
				if next > 0:
					waiting.append(next)
	return false


## The bricks that can see a chain variable `maker` makes: everything the
## events (and functions) that reach `maker` run; when none reaches it, what
## it leads to itself. Renaming such a variable stays in here.
static func chain_scope(graph: BrickscriptFlowGraph, maker: BrickscriptFlowNode) -> Array[BrickscriptFlowNode]:
	var starts: Array[BrickscriptFlowNode] = []
	for node: BrickscriptFlowNode in graph.nodes:
		if node != null and is_event(node) and leads_to(graph, node, maker):
			starts.append(node)
	if starts.is_empty():
		starts.append(maker)
	var seen: Dictionary[int, bool] = {}
	var scope: Array[BrickscriptFlowNode] = []
	var waiting: Array[BrickscriptFlowNode] = starts.duplicate()
	while not waiting.is_empty():
		var current: BrickscriptFlowNode = waiting.pop_back()
		if current == null or seen.has(current.id):
			continue
		seen[current.id] = true
		scope.append(current)
		for next: int in current.exits.values():
			if next > 0:
				waiting.append(graph.node_by_id(next))
	return scope


## Removes the node and every wire leading to it.
static func delete_node(graph: BrickscriptFlowGraph, node: BrickscriptFlowNode) -> bool:
	if node == null or not graph.nodes.has(node):
		return false
	graph.nodes.erase(node)
	for frame: Dictionary in graph.frames:
		frame["nodes"].erase(node.id)
	# A reroute point only bent its wire: the wire stays, straight to what it
	# led to.
	var through: int = node.exits.get(&"next", 0) if node.type == &"reroute" else 0
	for other: BrickscriptFlowNode in graph.nodes:
		if other == null:
			continue
		for exit: StringName in other.exits.keys():
			if other.exits[exit] == node.id:
				if through > 0 and through != other.id:
					other.exits[exit] = through
				else:
					other.exits.erase(exit)
	return true


## Puts a reroute point on the wire from `from`'s `exit` (at `position`):
## from -> reroute -> what it led to. null if that exit has no wire.
static func insert_reroute(graph: BrickscriptFlowGraph, from: BrickscriptFlowNode, exit: StringName, position: Vector2) -> BrickscriptFlowNode:
	var to: BrickscriptFlowNode = graph.node_by_id(from.exits.get(exit, 0)) if from != null else null
	if to == null:
		return null
	var point: BrickscriptFlowNode = add_node(graph, &"reroute", position)
	connect_exit(graph, from, exit, point)
	connect_exit(graph, point, &"next", to)
	return point


## Swaps two numbered outputs of an event (what they lead to), so they fire
## in the other order.
static func swap_outputs(event: BrickscriptFlowNode, a: int, b: int) -> bool:
	if not is_event(event) or a < 1 or b < 1 or a == b:
		return false
	var key_a: StringName = StringName(str(a))
	var key_b: StringName = StringName(str(b))
	var target_a: int = event.exits.get(key_a, 0)
	var target_b: int = event.exits.get(key_b, 0)
	if target_a == 0 and target_b == 0:
		return false
	for pair: Array in [[key_a, target_b], [key_b, target_a]]:
		if pair[1] > 0:
			event.exits[pair[0]] = pair[1]
		else:
			event.exits.erase(pair[0])
	return true

#endregion


#region Arranging

## The spacing in a chain (user, 2026-10-28): each brick starts two grid
## squares after the right edge of the brick it follows.
const CHAIN_GAP: float = 2.0 * GRID


## Where each brick of the chains goes across (id -> x): a chain's first brick
## (an event, an unwired brick) stays; every other brick starts CHAIN_GAP
## after the right edge (on the grid) of the brick it follows, the furthest
## one when several lead to it. Rows (y) stay. `sizes`: id -> the brick's
## drawn size. `only`: ids whose chains (everything wired to them) are
## arranged; empty: all. A brick on a loop of wires keeps its place.
static func arranged_x(graph: BrickscriptFlowGraph, sizes: Dictionary, only: Array = []) -> Dictionary[int, float]:
	var leads_to: Dictionary[int, Array] = {}
	var from_count: Dictionary[int, int] = {}
	var linked: Dictionary[int, Array] = {}
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		leads_to[node.id] = []
		from_count[node.id] = from_count.get(node.id, 0)
		linked[node.id] = linked.get(node.id, [])
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		for target: int in node.exits.values():
			if not leads_to.has(target) or target == node.id or leads_to[node.id].has(target):
				continue
			leads_to[node.id].append(target)
			from_count[target] += 1
			linked[node.id].append(target)
			linked[target].append(node.id)
	# The chains wanted: everything wired (either way) to `only`.
	var wanted: Dictionary[int, bool] = {}
	var todo: Array = only.duplicate() if not only.is_empty() else leads_to.keys()
	while not todo.is_empty():
		var id: int = todo.pop_back()
		if wanted.has(id) or not leads_to.has(id):
			continue
		wanted[id] = true
		todo.append_array(linked[id])
	# In wire order (a brick after all that lead to it).
	var result: Dictionary[int, float] = {}
	var ready: Array = from_count.keys().filter(func(id: int) -> bool: return from_count[id] == 0)
	while not ready.is_empty():
		var id: int = ready.pop_front()
		var node: BrickscriptFlowNode = graph.node_by_id(id)
		if not result.has(id):
			result[id] = node.position.x
		var right: float = ceilf((result[id] + (sizes.get(id, Vector2.ZERO) as Vector2).x - SNAP_SLACK) / GRID) * GRID + CHAIN_GAP
		for target: int in leads_to[id]:
			result[target] = maxf(result.get(target, -INF), right)
			from_count[target] -= 1
			if from_count[target] == 0:
				ready.append(target)
	for id: int in result.keys():
		if not wanted.has(id):
			result.erase(id)
	return result


## Moves the chains' bricks to arranged_x(); true if one moved.
static func arrange(graph: BrickscriptFlowGraph, sizes: Dictionary, only: Array = []) -> bool:
	var moved: bool = false
	var places: Dictionary[int, float] = arranged_x(graph, sizes, only)
	for id: int in places:
		var node: BrickscriptFlowNode = graph.node_by_id(id)
		if not is_equal_approx(node.position.x, places[id]):
			node.position.x = places[id]
			moved = true
	return moved

#endregion


#region Comment frames

const FRAME_COLOR: Color = Color(0.35, 0.45, 0.6)
const FRAME_SIZE: Vector2 = Vector2(320, 192)


## Adds a comment frame at `position`, holding the nodes with `node_ids`.
static func add_frame(graph: BrickscriptFlowGraph, position: Vector2, node_ids: Array = [], title: String = "Comment") -> Dictionary:
	# fit: sized around its nodes; false once the user resizes it (then it
	# only grows, to keep its nodes inside).
	var frame: Dictionary = {
		"id": graph.next_node_id, "title": title, "color": FRAME_COLOR,
		"position": snap(position), "size": FRAME_SIZE, "nodes": [], "fit": true,
	}
	graph.next_node_id += 1
	graph.frames.append(frame)
	for id: int in node_ids:
		attach_to_frame(graph, frame, id)
	return frame


static func frame_by_id(graph: BrickscriptFlowGraph, id: int) -> Dictionary:
	for frame: Dictionary in graph.frames:
		if frame["id"] == id:
			return frame
	return {}


## Attaches a node to `frame` (moving with it), taking it out of any other.
static func attach_to_frame(graph: BrickscriptFlowGraph, frame: Dictionary, node_id: int) -> bool:
	if graph.node_by_id(node_id) == null or frame["nodes"].has(node_id):
		return false
	for other: Dictionary in graph.frames:
		other["nodes"].erase(node_id)
	frame["nodes"].append(node_id)
	return true


## Lets go of one node (dragged out of the frame); it stays where it is.
static func detach_from_frame(frame: Dictionary, node_id: int) -> bool:
	if not frame["nodes"].has(node_id):
		return false
	frame["nodes"].erase(node_id)
	return true


## Lets go of every node in the frame (they stay where they are).
static func release_frame(frame: Dictionary) -> bool:
	if frame["nodes"].is_empty():
		return false
	frame["nodes"].clear()
	return true


## Deletes the frame; its nodes stay.
static func delete_frame(graph: BrickscriptFlowGraph, frame: Dictionary) -> bool:
	var index: int = graph.frames.find(frame)
	if index == -1:
		return false
	graph.frames.remove_at(index)
	return true


static func set_frame(frame: Dictionary, key: String, value: Variant) -> bool:
	if key == "position":
		value = snap(value)
	elif key == "size":
		value = snap_up(value)
	if frame.get(key) == value:
		return false
	frame[key] = value
	return true

#endregion


#region Functions

## A Define Function's inputs, in order: [[name, type], ...] (type a
## Types.ValueType), from its `params` setting ([[name, type name], ...]).
static func function_params(node: BrickscriptFlowNode) -> Array:
	var params: Array = []
	for param: Variant in node.settings.get(&"params", []):
		if param is Array and (param as Array).size() >= 2:
			params.append([str(param[0]), type_from_name(str(param[1]))])
	return params


## Sets a Define Function's inputs ([[name, type name], ...]).
static func set_function_params(node: BrickscriptFlowNode, params: Array) -> bool:
	if node.settings.get(&"params", []) == params:
		return false
	node.settings[&"params"] = params.duplicate(true)
	return true


## A type's name (Types.NAMES) back to its type (Anything for unknown ones).
static func type_from_name(name: String) -> int:
	for type: int in Types.NAMES:
		if Types.NAMES[type] == name:
			return type
	return Types.ValueType.ANY


## The functions a graph defines: name -> its Define Function node (the first
## one with that name).
static func functions_of(graph: BrickscriptFlowGraph) -> Dictionary:
	var found: Dictionary = {}
	for node: BrickscriptFlowNode in graph.nodes:
		if node != null and node.type == &"define_function":
			var name: String = str(node.settings.get(&"name", "")).strip_edges()
			if not name.is_empty() and not found.has(name):
				found[name] = node
	return found


## The values an event gives its chains: name -> type (a Define Function's
## inputs, or its definition's `provides`).
static func provides_of(node: BrickscriptFlowNode) -> Dictionary:
	if node.type == &"define_function":
		var found: Dictionary = {}
		for param: Array in function_params(node):
			found[param[0]] = param[1]
		return found
	return Library.get_definition(node.type).get("provides", {})

#endregion


#region Inputs, settings, output

## The input's current value: {"var": name} or {"type", "value"} (its default
## if never set).
static func input_of(node: BrickscriptFlowNode, input: StringName) -> Dictionary:
	if node.inputs.has(input):
		return node.inputs[input]
	return input_spec(node.type, input).get("default", {"type": Types.ValueType.NUMBER, "value": 0.0})


static func input_spec(type: StringName, input: StringName) -> Dictionary:
	var definition: Dictionary = Library.get_definition(type)
	for spec: Dictionary in definition.get("inputs", []):
		if spec["name"] == input:
			return spec
	# A repeated input: <name>_<row>.
	var row: String = String(input).get_slice("_", String(input).get_slice_count("_") - 1)
	var base: String = String(input).trim_suffix("_" + row)
	if row.is_valid_int():
		for spec: Dictionary in definition.get("variadic", {}).get("inputs", []):
			if String(spec["name"]) == base:
				var copy: Dictionary = spec.duplicate()
				copy["name"] = input
				return copy
	return {}


## Every input of the node, in order: the fixed ones, then each row of
## repeated ones (Make list: item_1, item_2, ...; Make table: key_1, value_1,
## ...).
static func input_specs(node: BrickscriptFlowNode) -> Array[Dictionary]:
	var definition: Dictionary = Library.get_definition(node.type)
	var result: Array[Dictionary] = []
	result.assign(definition.get("inputs", []))
	for row: int in range(1, row_count(node) + 1):
		for spec: Dictionary in definition.get("variadic", {}).get("inputs", []):
			result.append(input_spec(node.type, StringName("%s_%d" % [spec["name"], row])))
	return result


## How many rows of repeated inputs the node has (0 for other nodes).
static func row_count(node: BrickscriptFlowNode) -> int:
	var variadic: Dictionary = Library.get_definition(node.type).get("variadic", {})
	if variadic.is_empty():
		return 0
	return maxi(variadic["min"], int(node.settings.get(&"count", variadic["default_count"])))


## Sets how many rows of repeated inputs the node has; rows dropped lose
## their values.
static func set_row_count(node: BrickscriptFlowNode, count: int) -> bool:
	var variadic: Dictionary = Library.get_definition(node.type).get("variadic", {})
	if variadic.is_empty():
		return false
	count = maxi(variadic["min"], count)
	if count == row_count(node):
		return false
	node.settings[&"count"] = count
	for input: StringName in node.inputs.keys():
		var row: String = String(input).get_slice("_", String(input).get_slice_count("_") - 1)
		if row.is_valid_int() and int(row) > count and not input_spec(node.type, input).is_empty():
			node.inputs.erase(input)
	return true


## Whether an input is in use: If's B isn't for "is true" / "is false", and
## an input with `shown_when` only while its setting has that value (or one
## of its `values`).
static func input_shown(node: BrickscriptFlowNode, input: StringName) -> bool:
	if (node.type == &"if" or node.type == &"while") and input == &"b":
		return not Library.IF_UNARY.has(str(node.settings.get(&"operator", "is true")))
	var shown_when: Dictionary = input_spec(node.type, input).get("shown_when", {})
	if shown_when.is_empty():
		return true
	var setting: StringName = shown_when["setting"]
	var picked: String = str(node.settings.get(setting, shown_when.get("if_missing", _setting_default(node.type, setting))))
	if shown_when.has("values"):
		return (shown_when["values"] as Array).has(picked)
	return picked == str(shown_when["value"])


## A new brick's setting: its default, or the `preferred` action when the
## project's Input Map has it (Key Direction: the characters' move_left,
## else ui_left).
static func _new_default(setting: Dictionary) -> Variant:
	if setting.has("preferred") and ProjectSettings.has_setting("input/" + str(setting["preferred"])):
		return setting["preferred"]
	return setting["default"]


static func _setting_default(type: StringName, setting: StringName) -> Variant:
	for spec: Dictionary in Library.get_definition(type).get("settings", []):
		if spec["name"] == setting:
			return spec["default"]
	return null


## Types an input can be typed in as (Lists and Tables only empty).
static func literal_types(spec: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var allowed: Array = spec.get("types", [])
	for type: int in Types.ORDER:
		if allowed.is_empty() or allowed.has(type):
			result.append(type)
	return result


static func set_input(node: BrickscriptFlowNode, input: StringName, data: Dictionary) -> bool:
	# Compared as text: == calls an empty Array[float] and [] equal.
	if var_to_str(input_of(node, input)) == var_to_str(data):
		return false
	node.inputs[input] = data
	return true


## Switches an input to a typed-in value of `type`, keeping what it can
## (numbers stay numbers; anything else starts from the type's default).
static func set_input_type(node: BrickscriptFlowNode, input: StringName, type: int) -> bool:
	var old: Dictionary = input_of(node, input)
	var value: Variant = Types.default_value(type)
	if old.has("value") and Types.literal_problem(type, old["value"]).is_empty():
		value = old["value"]
	if type == Types.ValueType.NODE:
		value = old.get("value", "") if old.get("value") is String and not str(old.get("value")).is_empty() else "."
	return set_input(node, input, {"type": type, "value": value})


static func set_setting(node: BrickscriptFlowNode, setting: StringName, value: Variant) -> bool:
	if node.settings.get(setting) == value:
		return false
	node.settings[setting] = value
	return true


## A brick family's dropdown (Library.FAMILIES): the brick becomes another
## member of its family. What fits stays: inputs and settings of the same
## name (new ones at their defaults), the Output (when it still makes one),
## its wires (an exit the new type doesn't have takes the place of the one
## at the same place: Walk to's Arrived -> Follow's Next; the rest go).
static func change_type(graph: BrickscriptFlowGraph, node: BrickscriptFlowNode, type: StringName) -> bool:
	if node == null or node.type == type:
		return false
	var family: StringName = Library.family_of(node.type)
	if family == &"" or Library.family_of(type) != family:
		_refuse("change_type", "'%s' and '%s' aren't in the same brick family (Library.FAMILIES)" % [node.type, type])
		return false
	last_error = ""
	var old_exits: Array = Library.exits_of(node.type)
	var event: bool = is_event(node)
	node.type = type
	var definition: Dictionary = Library.get_definition(type)
	var settings: Dictionary[StringName, Variant] = {}
	for setting: Dictionary in definition.get("settings", []):
		settings[setting["name"]] = node.settings[setting["name"]] if node.settings.has(setting["name"]) else _new_default(setting)
	if definition.has("variadic") and node.settings.has(&"count"):
		settings[&"count"] = node.settings[&"count"]
	node.settings = settings
	var names: Array = input_specs(node).map(func(spec: Dictionary) -> StringName: return spec["name"])
	for input: StringName in node.inputs.keys():
		if not names.has(input):
			node.inputs.erase(input)
	start_paths(graph, node)
	if not Library.node_has_output(node):
		node.output_name = ""
		node.use_var = false
	if not event:
		var new_exits: Array = Library.exits_of(type)
		var exits: Dictionary[StringName, int] = {}
		for exit: StringName in node.exits:
			var base: StringName = exit_base(exit)
			if new_exits.has(base):
				exits[exit] = node.exits[exit]
		for exit: StringName in node.exits:
			var base: StringName = exit_base(exit)
			var place: int = old_exits.find(base)
			if new_exits.has(base) or exit_number(exit) != 1 or place < 0 or place >= new_exits.size() or exits.has(new_exits[place]):
				continue
			exits[new_exits[place]] = node.exits[exit]
		node.exits = exits
	return true


static func set_output(node: BrickscriptFlowNode, output_name: String, use_var: bool) -> bool:
	output_name = output_name.strip_edges()
	if node.output_name == output_name and node.use_var == use_var:
		return false
	node.output_name = output_name
	node.use_var = use_var
	return true

#endregion


#region Variables

## Adds a constant, export or shared variable with a free name.
static func add_variable(graph: BrickscriptFlowGraph, kind: BrickscriptVariable.Kind, type: int = Types.ValueType.NUMBER) -> BrickscriptVariable:
	if kind == Kind.CHAIN:
		return null
	return graph.add_variable(unique_name(graph, NEW_NAMES[kind]), kind, type)


## Every variable name the graph knows of: script variables, then names nodes
## make (Output Var, Set Var), then event values. For hints and checks only:
## the compiler decides what is visible where.
static func known_names(graph: BrickscriptFlowGraph) -> PackedStringArray:
	var names: PackedStringArray = []
	for variable: BrickscriptVariable in graph.variables:
		if variable != null and not names.has(variable.name):
			names.append(variable.name)
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		var made: String = node.output_name if not node.use_var and Library.node_has_output(node) else ""
		if node.type == &"set_var" and Library.mode_of(node) == "Set" or is_declaration(node):
			made = str(node.settings.get(&"name", ""))
		if not made.is_empty() and not names.has(made):
			names.append(made)
		for setting: String in made_by_settings(node):
			if not names.has(setting):
				names.append(setting)
		for value: Variant in provides_of(node).keys():
			if not names.has(str(value)):
				names.append(str(value))
	return names


## Variable names a node makes through settings (a loop's item / index / ...).
static func made_by_settings(node: BrickscriptFlowNode) -> PackedStringArray:
	var names: PackedStringArray = []
	for setting: Dictionary in Library.get_definition(node.type).get("settings", []):
		var made: String = str(node.settings.get(setting["name"], ""))
		if setting["kind"] == "name" and not made.is_empty():
			names.append(made)
	return names


static func unique_name(graph: BrickscriptFlowGraph, base: String) -> String:
	var taken: PackedStringArray = known_names(graph)
	if not taken.has(base):
		return base
	var n: int = 2
	while taken.has("%s_%d" % [base, n]):
		n += 1
	return "%s_%d" % [base, n]


## Renames a script variable and every node that refers to it by name
## (inputs, outputs, Set Var, formulas). Refuses invalid or taken names.
static func rename_variable(graph: BrickscriptFlowGraph, variable: BrickscriptVariable, new_name: String) -> bool:
	new_name = new_name.strip_edges()
	if new_name == variable.name or not new_name.is_valid_ascii_identifier() or known_names(graph).has(new_name):
		return false
	var old_name: String = variable.name
	variable.name = new_name
	for node: BrickscriptFlowNode in graph.nodes:
		if node != null:
			rename_in_node(node, old_name, new_name)
	return true


static func rename_in_node(node: BrickscriptFlowNode, old_name: String, new_name: String) -> void:
	for input: StringName in node.inputs:
		if str(node.inputs[input].get("var", "")) == old_name:
			node.inputs[input] = {"var": new_name}
	if node.output_name == old_name:
		node.output_name = new_name
	if (node.type == &"set_var" or is_declaration(node)) and str(node.settings.get(&"name", "")) == old_name:
		node.settings[&"name"] = new_name
	for setting: Dictionary in Library.get_definition(node.type).get("settings", []):
		if setting["kind"] == "name" and str(node.settings.get(setting["name"], "")) == old_name:
			node.settings[setting["name"]] = new_name
	if node.type == &"formula":
		node.settings[&"expression"] = rename_in_formula(str(node.settings.get(&"expression", "")), old_name, new_name)


## Replaces the name `old_name` in a formula, but not inside quotes or after a
## "." (a member like speed.x).
static func rename_in_formula(text: String, old_name: String, new_name: String) -> String:
	var word: RegEx = RegEx.create_from_string("(?<![\\w.])%s(?!\\w)" % old_name)
	var result: String = ""
	var quote: String = ""
	var start: int = 0
	var i: int = 0
	while i <= text.length():
		var c: String = text[i] if i < text.length() else ""
		if quote.is_empty() and (c == "\"" or c == "'" or c.is_empty()):
			result += word.sub(text.substr(start, i - start), new_name, true)
			start = i
			quote = c
		elif not quote.is_empty() and c == "\\":
			i += 1
		elif not quote.is_empty() and c == quote:
			result += text.substr(start, i + 1 - start)
			start = i + 1
			quote = ""
		i += 1
	return result + text.substr(start)


## Renames the variable a Set Var makes (its own new name) and every node
## that uses it. Refuses invalid or taken names.
static func rename_made_variable(graph: BrickscriptFlowGraph, maker: BrickscriptFlowNode, new_name: String) -> bool:
	new_name = new_name.strip_edges()
	var old_name: String = str(maker.settings.get(&"name", ""))
	if new_name == old_name or not new_name.is_valid_ascii_identifier() or known_names(graph).has(new_name):
		return false
	# A Chain variable lives in its event's chains only; a Shared / Synced
	# one is the whole brickscript's.
	# (FlowCompiler.set_var_kind(), which Ops can't load.)
	var kind: String = str(maker.settings[&"var_kind"]) if maker.settings.has(&"var_kind") else ("Shared" if maker.settings.get(&"keep", true) else "Chain")
	var chain: bool = kind == "Chain"
	for node: BrickscriptFlowNode in (chain_scope(graph, maker) if chain else graph.nodes):
		if node != null:
			rename_in_node(node, old_name, new_name)
	maker.settings[&"name"] = new_name
	return true


## Renames the new variable a node makes through its Output Var (`setting`
## &"") or a name setting (a loop's item, index, ...), and every use of it.
## False if the name isn't valid or is already used.
static func rename_made_output(graph: BrickscriptFlowGraph, maker: BrickscriptFlowNode, setting: StringName, new_name: String) -> bool:
	new_name = new_name.strip_edges()
	var old_name: String = maker.output_name if setting == &"" else str(maker.settings.get(setting, ""))
	if new_name == old_name or not new_name.is_valid_ascii_identifier() or known_names(graph).has(new_name):
		return false
	if not old_name.is_empty():
		# (A chain variable: only its own events' bricks, not a variable of
		# the same name another event makes.)
		for node: BrickscriptFlowNode in chain_scope(graph, maker):
			rename_in_node(node, old_name, new_name)
	if setting == &"":
		maker.output_name = new_name
		maker.use_var = false
	else:
		maker.settings[setting] = new_name
	return true


## Turns listed script variables (older graphs) into Constant / Export bricks
## and unwired (Shared) Set Var bricks, the value as their typed-in value, in a
## "Variables" frame left of the graph, and empties the list. Returns how
## many it turned. List / Table starting values can't be typed in and start
## empty.
static func variables_to_bricks(graph: BrickscriptFlowGraph) -> int:
	var listed: Array[BrickscriptVariable] = []
	for variable: BrickscriptVariable in graph.variables:
		if variable != null and variable.kind != Kind.CHAIN:
			listed.append(variable)
	if listed.is_empty():
		return 0
	var left: float = 0.0
	var top: float = 0.0
	for node: BrickscriptFlowNode in graph.nodes:
		if node != null:
			left = minf(left, node.position.x)
			top = minf(top, node.position.y)
	var ids: Array = []
	for i: int in listed.size():
		var variable: BrickscriptVariable = listed[i]
		var maker: BrickscriptFlowNode = add_node(graph, [&"constant", &"export", &"set_var"][variable.kind], Vector2(left - 320, top + i * 128))
		maker.settings[&"name"] = variable.name
		var value: Variant = variable.get_value()
		if variable.type == Types.ValueType.WHOLE:
			value = roundi(value)
		if Types.literal_problem(variable.type, value).is_empty():
			maker.inputs[&"value"] = {"type": variable.type, "value": value}
		else:
			maker.inputs[&"value"] = {"type": variable.type, "value": Types.default_value(variable.type)}
		ids.append(maker.id)
	graph.variables.clear()
	add_frame(graph, Vector2.ZERO, ids, "Variables")
	return listed.size()


## Older Set Vars set to Constant / Export become Constant / Export bricks
## (declarations have no wires: theirs are removed). Returns how many.
static func upgrade_graph(graph: BrickscriptFlowGraph) -> int:
	var upgraded: int = 0
	for node: BrickscriptFlowNode in graph.nodes:
		# Raycast had one exit (next); now Hit / Nothing hit: both lead on.
		if node != null and node.type == &"raycast" and node.exits.has(&"next"):
			var after: int = node.exits[&"next"]
			node.exits.erase(&"next")
			node.exits[&"hit"] = after
			node.exits[&"missed"] = after
			upgraded += 1
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null or node.type != &"set_var":
			continue
		var kind: String = str(node.settings.get(&"var_kind", ""))
		var type: StringName = Library.DECLARATIONS.find_key(kind) if Library.DECLARATIONS.values().has(kind) else &""
		if type == &"":
			continue
		node.type = type
		node.settings.erase(&"var_kind")
		node.settings.erase(&"keep")
		node.exits.clear()
		if input_of(node, &"value").has("var"):
			node.inputs[&"value"] = input_spec(type, &"value")["default"]
		for other: BrickscriptFlowNode in graph.nodes:
			if other != null:
				for exit: StringName in other.exits.keys():
					if other.exits[exit] == node.id:
						other.exits.erase(exit)
		upgraded += 1
	return upgraded


## Graph files before format 2: Node inputs left at their default meant
## "this node"; those whose default is now the parent keep "this node".
static func keep_this_node(graph: BrickscriptFlowGraph) -> void:
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		for spec: Dictionary in input_specs(node):
			if spec["default"] == Library.PARENT_NODE and not node.inputs.has(spec["name"]):
				node.inputs[spec["name"]] = Library.THIS_NODE.duplicate()


## Format 3 (players): Give To's `peer` input is now `player`, and When a
## player joins / leaves give `player` instead of `peer`, so the graph's uses
## of `peer` are renamed (unless one of its bricks makes a variable called
## player: then they're left, and show up as problems).
static func players_upgrade(graph: BrickscriptFlowGraph) -> void:
	var has_player_events: bool = false
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		if node.type == &"set_owner" and node.inputs.has(&"peer"):
			node.inputs[&"player"] = node.inputs[&"peer"]
			node.inputs.erase(&"peer")
		if node.type in [&"event_player_joined", &"event_player_left"]:
			has_player_events = true
	if has_player_events and not _makes_name(graph, "player"):
		for node: BrickscriptFlowNode in graph.nodes:
			if node != null:
				rename_in_node(node, "peer", "player")


## Format 4: Get / Set Character became Get / Set property on the character
## (its settings by their property names; its states as read-only
## properties), and the Character brick became Get Character (From a
## player). Set Character's Seconds is dropped (Set, Wait, Set back).
const OLD_CHARACTER_NAMES: Dictionary = {
	"On the floor": "on_the_floor", "Moving": "moving", "Falling": "falling", "Velocity": "velocity", "Velocity 2D": "velocity",
	"Looking around": "looking", "Dead": "dead", "Health": "health", "Max health": "max_health", "Walk speed": "walk_speed",
	"Jump power": "jump_power", "Gravity": "gravity", "Eye height": "eye_height", "Mouse sensitivity": "mouse_sensitivity",
	"Field of view": "field_of_view", "Capture mouse": "capture_mouse",
}


static func character_bricks_upgrade(graph: BrickscriptFlowGraph) -> void:
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		if node.type == &"get_character" or node.type == &"set_character":
			var getting: bool = node.type == &"get_character"
			var picked: String = str(node.settings.get(&"property", "On the floor" if getting else "Walk speed"))
			node.type = &"get_property" if getting else &"set_property"
			node.settings[&"property"] = OLD_CHARACTER_NAMES.get(picked, picked)
			if not node.inputs.has(&"of"):
				# (Their "of" was this node by default; Get / Set property's is the parent.)
				node.inputs[&"of"] = {"type": Types.ValueType.NODE, "value": "."}
			node.inputs.erase(&"seconds")
		elif node.type == &"player_character":
			node.type = &"get_character"
			node.settings[&"from"] = "A player"


## Format 7: Get property and Set property are one brick, Property (type
## set_property, Mode Get / Set / Add), and Set Var is Variable with the same
## modes: Get property becomes Mode Get; a Property or Variable saved without
## a mode is Set (new ones start at Get / Set).
static func access_modes_upgrade(graph: BrickscriptFlowGraph) -> void:
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		if node.type == &"get_property":
			node.type = &"set_property"
			node.settings[&"mode"] = "Get"
		elif (node.type == &"set_property" or node.type == &"set_var") and not node.settings.has(&"mode"):
			node.settings[&"mode"] = "Set"


## Format 6: Change property became Set property's Add mode (its amount
## is the value).
static func change_property_upgrade(graph: BrickscriptFlowGraph) -> void:
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null or node.type != &"change_property":
			continue
		node.type = &"set_property"
		node.settings[&"mode"] = "Add"
		if node.inputs.has(&"amount"):
			node.inputs[&"value"] = node.inputs[&"amount"]
			node.inputs.erase(&"amount")
		else:
			# (Its amount's default: 1.0; Set property's value defaults to 0.)
			node.inputs[&"value"] = {"type": Types.ValueType.NUMBER, "value": 1.0}


## Format 5 (Roblox-style paths): a script node's paths start at the script
## node itself (Self; its parent, the node it works for, is Self.Parent),
## no longer at its parent. Every typed-in path of a script-node brickscript
## moves one step up (`up`), so it still names the same node: "." / blank
## become "..", ".." "../..", "UI" "../UI". Unwired Set Var / Constant /
## Export values were already read from the script node and stay, and so
## does When signal received of its own signal (an Emit signal here: the
## script node's). Also used when Acts for changes (`up` false: script node
## -> the node it's on; a path to the script node itself or inside it stays
## as it is).
static func script_node_paths(graph: BrickscriptFlowGraph, up: bool) -> void:
	var wired: Dictionary[int, bool] = {}
	var own_signals: Dictionary[String, bool] = {}
	for node: BrickscriptFlowNode in graph.nodes:
		if node != null:
			for target: int in node.exits.values():
				wired[target] = true
			if node.type == &"emit_signal":
				own_signals[str(node.settings.get(&"signal", "")).strip_edges()] = true
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		var declared: bool = is_declaration(node) or (node.type == &"set_var" and not wired.has(node.id))
		for spec: Dictionary in input_specs(node):
			if not spec.get("types", []).has(Types.ValueType.NODE) or (declared and spec["name"] == &"value"):
				continue
			var data: Dictionary = input_of(node, spec["name"])
			if data.has("var") or int(data.get("type", -1)) != Types.ValueType.NODE:
				continue
			if spec.has("blank") and str(data.get("value", "")).strip_edges().is_empty():
				# Blank means something (the scene's Terrain): not a path.
				continue
			var moved: Dictionary = data.duplicate()
			moved["value"] = _moved_path(str(data.get("value", "")), up)
			node.inputs[spec["name"]] = moved
		var own: bool = node.type == &"event_signal" and own_signals.has(str(node.settings.get(&"signal", "")).strip_edges())
		for setting: Dictionary in Library.get_definition(node.type).get("settings", []):
			var path: String = str(node.settings.get(setting["name"], setting.get("default", ""))).strip_edges()
			if setting.get("kind", "") == "node_path" and not (own and path in ["", "."]):
				node.settings[setting["name"]] = _moved_path(path, up)


## One path, one step up (from the script node's parent to the script node)
## or back down.
static func _moved_path(path: String, up: bool) -> String:
	var text: String = path.strip_edges()
	if text.begins_with("/") or text.begins_with("%"):
		return text
	if up:
		return ".." if text.is_empty() or text == "." else "../" + text.trim_prefix("./")
	if text == "..":
		return "."
	return text.trim_prefix("../") if text.begins_with("../") else text


## Whether a brick of the graph makes a variable `name` (an Output Var, a Set
## Var, a declaration or a loop name); event values don't count.
static func _makes_name(graph: BrickscriptFlowGraph, name: String) -> bool:
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		if (node.output_name == name and not node.use_var) or made_by_settings(node).has(name):
			return true
		if (node.type == &"set_var" and Library.mode_of(node) == "Set" or is_declaration(node)) and str(node.settings.get(&"name", "")) == name:
			return true
	return false


## How many nodes refer to `name`.
static func references(graph: BrickscriptFlowGraph, name: String) -> int:
	var count: int = 0
	for node: BrickscriptFlowNode in graph.nodes:
		if node == null:
			continue
		var probe: BrickscriptFlowNode = node.duplicate(true)
		rename_in_node(probe, name, "\u0001")
		if probe.inputs != node.inputs or probe.output_name != node.output_name or probe.settings != node.settings:
			count += 1
	return count


## Deletes the variable. Nodes that used it stay and show an error, so nothing
## disappears without the user seeing it.
static func delete_variable(graph: BrickscriptFlowGraph, variable: BrickscriptVariable) -> bool:
	if not graph.variables.has(variable):
		return false
	graph.variables.erase(variable)
	return true


## Changes a variable's type, keeping its value where it fits.
static func set_variable_type(variable: BrickscriptVariable, type: int) -> bool:
	if variable.type == type or not Types.is_known(type):
		return false
	var old: Variant = variable.get_value()
	variable.type = type
	match type:
		1, 4:
			variable.number = float(old) if old is float or old is int else 0.0
		2:
			variable.text = str(old) if old is String else ""
		_:
			variable.value = old if Types.of_value(old) == type else Types.default_value(type)
	return true


## Sets a variable's starting (or constant) value.
static func set_variable_value(variable: BrickscriptVariable, value: Variant) -> bool:
	if variable.get_value() == value:
		return false
	match variable.type:
		1, 4:
			variable.number = float(value)
		2:
			variable.text = str(value)
		_:
			variable.value = value
	return true

#endregion


#region Snapshots and clipboard

## Marks clipboard text as Brickscript nodes.
const CLIPBOARD_PREFIX: String = "BRICKSCRIPT_NODES:"
## Where pasted copies go relative to the originals, when not at the mouse.
const PASTE_OFFSET: Vector2 = Vector2(32, 32)


## The whole graph as plain data (no resources), for undo / redo. Two
## snapshots are equal (==) exactly when the graphs are.
static func snapshot(graph: BrickscriptFlowGraph) -> Dictionary:
	var nodes: Array = []
	for node: BrickscriptFlowNode in graph.nodes:
		if node != null:
			nodes.append(node_to_data(node))
	var variables: Array = []
	for variable: BrickscriptVariable in graph.variables:
		if variable != null:
			variables.append({
				"id": variable.id, "name": variable.name, "kind": variable.kind, "type": variable.type,
				"number": variable.number, "text": variable.text, "value": _copy(variable.value),
			})
	return {
		"base_type": graph.base_type, "context": graph.context, "parent_type": _copy(graph.parent_type), "body_type": _copy(graph.body_type), "script_node": graph.script_node, "shared": graph.shared, "nodes": nodes, "variables": variables, "frames": _copy(graph.frames),
		"next_node_id": graph.next_node_id, "next_variable_id": graph.next_variable_id,
	}


## Puts the graph back to a snapshot (same graph resource, new contents).
static func restore(graph: BrickscriptFlowGraph, data: Dictionary) -> void:
	graph.base_type = data["base_type"]
	graph.context = data.get("context", &"local")
	graph.parent_type = _copy(data.get("parent_type", {}))
	graph.body_type = _copy(data.get("body_type", {}))
	graph.script_node = bool(data.get("script_node", false))
	graph.shared = bool(data.get("shared", false))
	graph.next_node_id = data["next_node_id"]
	graph.next_variable_id = data["next_variable_id"]
	graph.nodes.clear()
	for node_data: Dictionary in data["nodes"]:
		graph.nodes.append(node_from_data(node_data))
	graph.variables.clear()
	for variable_data: Dictionary in data["variables"]:
		var variable: BrickscriptVariable = BrickscriptVariable.new()
		variable.id = variable_data["id"]
		variable.name = variable_data["name"]
		variable.kind = variable_data["kind"]
		variable.type = variable_data["type"]
		variable.number = variable_data["number"]
		variable.text = variable_data["text"]
		variable.value = _copy(variable_data["value"])
		graph.variables.append(variable)
	graph.frames.assign(_copy(data.get("frames", [])))


static func node_to_data(node: BrickscriptFlowNode) -> Dictionary:
	return {
		"id": node.id, "type": node.type, "inputs": _copy(node.inputs), "settings": _copy(node.settings),
		"output_name": node.output_name, "use_var": node.use_var, "exits": _copy(node.exits),
		"position": node.position, "size": node.size,
	}


static func node_from_data(data: Dictionary) -> BrickscriptFlowNode:
	var node: BrickscriptFlowNode = BrickscriptFlowNode.new()
	node.id = int(data.get("id", 0))
	node.type = StringName(data.get("type", &""))
	node.inputs.assign(_copy(data.get("inputs", {})))
	node.settings.assign(_copy(data.get("settings", {})))
	node.output_name = str(data.get("output_name", ""))
	node.use_var = bool(data.get("use_var", false))
	node.exits.assign(_copy(data.get("exits", {})))
	node.position = data.get("position", Vector2.ZERO)
	node.size = data.get("size", Vector2.ZERO)
	return node


## The nodes as plain data, keeping only the wires between them.
static func copy_nodes(nodes: Array) -> Array:
	var ids: Dictionary[int, bool] = {}
	for node: BrickscriptFlowNode in nodes:
		ids[node.id] = true
	var result: Array = []
	for node: BrickscriptFlowNode in nodes:
		var data: Dictionary = node_to_data(node)
		for exit: StringName in data["exits"].keys():
			if not ids.has(data["exits"][exit]):
				data["exits"].erase(exit)
		result.append(data)
	return result


## Adds copies of copied nodes with new ids, rewiring them among themselves.
## With `at` (a canvas position), the top-left one lands there; otherwise
## each lands PASTE_OFFSET from where it was copied. Returns the new nodes.
static func paste_nodes(graph: BrickscriptFlowGraph, copied: Array, at: Variant = null) -> Array[BrickscriptFlowNode]:
	var pasted: Array[BrickscriptFlowNode] = []
	if copied.is_empty():
		return pasted
	var top_left: Vector2 = Vector2.INF
	for data: Dictionary in copied:
		top_left = top_left.min(data.get("position", Vector2.ZERO))
	var shift: Vector2 = (at - top_left) if at is Vector2 else PASTE_OFFSET
	var new_ids: Dictionary[int, int] = {}
	for data: Dictionary in copied:
		if Library.get_definition(StringName(data.get("type", &""))).is_empty():
			continue
		var node: BrickscriptFlowNode = node_from_data(data)
		new_ids[node.id] = graph.next_node_id
		node.id = graph.next_node_id
		graph.next_node_id += 1
		node.position = snap(node.position + shift)
		graph.nodes.append(node)
		pasted.append(node)
	for node: BrickscriptFlowNode in pasted:
		for exit: StringName in node.exits.keys():
			if new_ids.has(node.exits[exit]):
				node.exits[exit] = new_ids[node.exits[exit]]
			else:
				node.exits.erase(exit)
	return pasted


## Copied nodes as clipboard text (so they paste into other graphs too).
static func clipboard_text(copied: Array) -> String:
	return CLIPBOARD_PREFIX + var_to_str(copied)


## Copied nodes from clipboard text, or [] if it isn't Brickscript's.
static func clipboard_data(text: String) -> Array:
	if not text.begins_with(CLIPBOARD_PREFIX):
		return []
	var data: Variant = decode_data(text.trim_prefix(CLIPBOARD_PREFIX))
	if not data is Array:
		return []
	return (data as Array).filter(func(entry: Variant) -> bool: return entry is Dictionary and entry.has("type"))


## Constructors in Godot's value text that create objects or load resources.
const UNSAFE_CONSTRUCTORS: PackedStringArray = ["Object", "Resource", "ExtResource", "SubResource"]


## Plain data from Godot value text (var_to_str), or null. str_to_var() alone
## would build any Object or Resource the text describes, and clipboard text
## and files aren't trusted, so text that names one of UNSAFE_CONSTRUCTORS
## outside a quoted string is refused before it is parsed.
static func decode_data(text: String) -> Variant:
	var word: RegEx = RegEx.create_from_string("(?<![\\w])(%s)\\s*\\(" % "|".join(UNSAFE_CONSTRUCTORS))
	if word.search(_outside_strings(text)) != null:
		return null
	return str_to_var(text)


## The text with every quoted string blanked out ("...", &"...", ^"...").
static func _outside_strings(text: String) -> String:
	var result: String = ""
	var quoted: bool = false
	var i: int = 0
	while i < text.length():
		var c: String = text[i]
		if quoted:
			if c == "\\":
				i += 1
			elif c == "\"":
				quoted = false
				result += c
		else:
			if c == "\"":
				quoted = true
			result += c
		i += 1
	return result


## A deep copy of plain data (Arrays and Dictionaries nested in each other).
static func _copy(value: Variant) -> Variant:
	if value is Array or value is Dictionary:
		return value.duplicate(true)
	return value

#endregion


#region Walking back along the wires

## The chain variables a node can read because nodes *before it on its
## wires* make them, found by walking the exec wires backwards from it:
## Output Vars (without Use Var), new Set Var names, a loop's names (inside
## its body and after it), an event's values (delta), and what earlier
## outputs of the same event make. Works even before the chain is wired to an
## event. name -> {"type", "writable", "origin"}; types the editor can't know
## without compiling (e.g. a Formula's) are Anything.
static func upstream_names(graph: BrickscriptFlowGraph, node: BrickscriptFlowNode) -> Dictionary:
	var incoming: Dictionary = {}
	for other: BrickscriptFlowNode in graph.nodes:
		if other == null:
			continue
		for exit: StringName in other.exits:
			if other.exits[exit] > 0:
				incoming.get_or_add(other.exits[exit], []).append([other, exit])
	var found: Dictionary = {}
	var seen: Dictionary = {node.id: true}
	var waiting: Array = incoming.get(node.id, []).duplicate()
	while not waiting.is_empty():
		var link: Array = waiting.pop_back()
		var before: BrickscriptFlowNode = link[0]
		if is_event(before):
			_names_of_event(graph, before, int(String(link[1])), found)
		else:
			_names_made_by(before, found)
			# A later Next / Loop body / Done: what the earlier ones make.
			var base: StringName = exit_base(link[1])
			var earlier: Array = range(1, exit_number(link[1])).map(func(number: int) -> int: return before.exits.get(exit_name(base, number), 0))
			_names_of_chains(graph, earlier, found)
		if seen.has(before.id):
			continue
		seen[before.id] = true
		waiting.append_array(incoming.get(before.id, []))
	return found


## What a node makes for the nodes after it.
static func _names_made_by(node: BrickscriptFlowNode, found: Dictionary) -> void:
	var definition: Dictionary = Library.get_definition(node.type)
	var made: Dictionary = {}
	if node.type == &"set_var" and Library.mode_of(node) == "Set":
		var target: String = str(node.settings.get(&"name", ""))
		var value: Dictionary = input_of(node, &"value")
		made[target] = value.get("type", Types.ValueType.ANY) if not value.has("var") else Types.ValueType.ANY
	elif Library.node_has_output(node) and not node.use_var:
		var returns: Variant = definition.get("returns", null)
		made[node.output_name] = returns if returns is int else Types.ValueType.ANY
	match node.type:
		&"for_each":
			made[str(node.settings.get(&"item_name", ""))] = Types.ValueType.ANY
			made[str(node.settings.get(&"index_name", ""))] = Types.ValueType.WHOLE
		&"for_each_pair":
			made[str(node.settings.get(&"key_name", ""))] = Types.ValueType.ANY
			made[str(node.settings.get(&"value_name", ""))] = Types.ValueType.ANY
		&"repeat":
			made[str(node.settings.get(&"index_name", ""))] = Types.ValueType.WHOLE
		&"unpack_table":
			for row: int in range(1, row_count(node) + 1):
				made[str(input_of(node, StringName("key_%d" % row)).get("value", ""))] = Types.ValueType.ANY
		&"screen_to_world", &"player_aim":
			var vector: int = Types.ValueType.VECTOR2 if str(node.settings.get(&"space", "3D")) == "2D" else Types.ValueType.VECTOR3
			if not node.use_var and not node.output_name.is_empty():
				made[node.output_name] = vector
			made[str(node.settings.get(&"from_name", ""))] = vector
		&"world_to_screen":
			if not node.use_var and not node.output_name.is_empty():
				made[node.output_name] = Types.ValueType.VECTOR2
			made[str(node.settings.get(&"on_screen_name", ""))] = Types.ValueType.BOOL
		&"raycast":
			var vector: int = int(input_of(node, &"from").get("type", Types.ValueType.ANY))
			made[str(node.settings.get(&"point_name", ""))] = vector
			made[str(node.settings.get(&"normal_name", ""))] = vector
			made[str(node.settings.get(&"distance_name", ""))] = Types.ValueType.NUMBER
		&"find_path":
			if not node.use_var and not node.output_name.is_empty():
				made[node.output_name] = Types.ValueType.LIST
			made[str(node.settings.get(&"length_name", ""))] = Types.ValueType.NUMBER
		&"terrain_ray":
			if not node.use_var and not node.output_name.is_empty():
				made[node.output_name] = Types.ValueType.VECTOR3
			made[str(node.settings.get(&"normal_name", ""))] = Types.ValueType.VECTOR3
		&"random_open_spot":
			if not node.use_var and not node.output_name.is_empty():
				made[node.output_name] = Types.ValueType.VECTOR3
		&"nearest_character":
			if not node.use_var and not node.output_name.is_empty():
				made[node.output_name] = Types.ValueType.NODE
			made[str(node.settings.get(&"distance_name", ""))] = Types.ValueType.NUMBER
	for name: String in made:
		if not name.strip_edges().is_empty() and not found.has(name):
			found[name] = {"type": made[name], "writable": true, "origin": "chain"}


## An event's values, plus everything its earlier outputs make (they run
## first, to the end).
static func _names_of_event(graph: BrickscriptFlowGraph, event: BrickscriptFlowNode, output: int, found: Dictionary) -> void:
	var provides: Dictionary = provides_of(event)
	for value_name: Variant in provides:
		found[str(value_name)] = {"type": provides[value_name], "writable": false, "origin": "event"}
	_names_of_chains(graph, range(1, output).map(func(earlier: int) -> int: return event.exits.get(StringName(str(earlier)), 0)), found)


## Everything the chains starting at `starts` (node ids; 0 = none) make:
## they run first, to the end.
static func _names_of_chains(graph: BrickscriptFlowGraph, starts: Array, found: Dictionary) -> void:
	for start_id: Variant in starts:
		var start: BrickscriptFlowNode = graph.node_by_id(int(start_id))
		var seen: Dictionary = {}
		var waiting: Array = [start] if start != null else []
		while not waiting.is_empty():
			var current: BrickscriptFlowNode = waiting.pop_back()
			if current == null or seen.has(current.id):
				continue
			seen[current.id] = true
			_names_made_by(current, found)
			for next: int in current.exits.values():
				waiting.append(graph.node_by_id(next))

#endregion
