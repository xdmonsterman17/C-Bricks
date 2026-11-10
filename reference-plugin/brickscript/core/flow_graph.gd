@tool
@icon("res://addons/brickscript/icons/brickscript.svg")
class_name BrickscriptFlowGraph
extends Resource

## A Brickscript wire graph: event nodes start chains, exec wires set the order
## the following nodes run in, and values pass between them through named
## variables. flow_compiler.gd turns it into a GDScript file. Saved as a
## .bricklocal / .brickserver file (brick_file.gd).

## Node class the generated script extends.
@export var base_type: StringName = &"Node"
## Where it runs: &"local" (every machine) or &"server" (only where the game
## has server authority: the host / server, or offline single-player; uses
## the Network Context Engine when it is installed). See CONTEXTS. Set by
## the file's extension (.bricklocal / .brickserver).
@export var context: StringName = &"local"
## The node type of the node's parent (what the path ".." is), as the
## editor finds it in the scenes that use this brickscript; {} if unknown.
## Kept in the graph so the game, which compiles without looking at scenes,
## compiles the same code.
@export var parent_type: Dictionary = {}
## Server brickscripts: the node type of the node that carries this one as
## its own server script (`server_script` metadata, e.g. a node whose local
## script is built into the scene), as the editor finds it in the scenes; {}
## when a paired local file says instead (or nothing does). Kept for the
## game's compile, like parent_type.
@export var body_type: Dictionary = {}
## A script node: the brickscript runs on a child node of its own (a
## LocalScript / ServerScript node in the scene) and acts for that node's
## parent: "this node" is the parent (its type in body_type, from the
## scenes), paths start there, and the script itself extends plain Node.
## New brickscripts are script nodes; older ones (false) act on the node
## they're attached to (a server one on the node it's the server part of).
@export var script_node: bool = false
## A shared brickscript (`.brickshared`, like a Roblox ModuleScript): only
## functions (Define Function) and its variables, one copy per machine that
## any brickscript there calls (Call Function From: A file). Its context says
## who may: local = Used by Both (only bricks that work on either side, with
## a local brickscript's rules), server = Server only.
@export var shared: bool = false

const CONTEXTS: Array[StringName] = [&"local", &"server"]
## Constants, exports and shared variables, in declaration order. Chain
## variables are not listed: nodes make them by naming their output.
@export var variables: Array[BrickscriptVariable] = []
@export var nodes: Array[BrickscriptFlowNode] = []
## Comment frames (editor-only, never compiled): {"id", "title", "color",
## "position", "size", "nodes" (ids of the nodes attached to it)}. Ids come
## from next_node_id, so frames and nodes never share one.
@export var frames: Array[Dictionary] = []
## Ids are never reused, so a wire to a deleted node reports an error instead
## of silently leading to a new one.
@export var next_node_id: int = 1
@export var next_variable_id: int = 1


## Adds a node of `type` at `position` and returns it.
func add_node(type: StringName, position: Vector2 = Vector2.ZERO) -> BrickscriptFlowNode:
	var node: BrickscriptFlowNode = BrickscriptFlowNode.new()
	node.id = next_node_id
	next_node_id += 1
	node.type = type
	node.position = position
	nodes.append(node)
	return node


func node_by_id(id: int) -> BrickscriptFlowNode:
	for node: BrickscriptFlowNode in nodes:
		if node != null and node.id == id:
			return node
	return null


## Wires `from`'s exit to `to` (replacing what that exit led to). Returns `to`,
## so chains can be written link by link.
func wire(from: BrickscriptFlowNode, exit: StringName, to: BrickscriptFlowNode) -> BrickscriptFlowNode:
	from.exits[exit] = to.id
	return to


## Adds a constant, export or shared variable.
func add_variable(var_name: String, kind: BrickscriptVariable.Kind, type: int, value: Variant = null) -> BrickscriptVariable:
	var variable: BrickscriptVariable = BrickscriptVariable.new()
	variable.id = next_variable_id
	next_variable_id += 1
	variable.name = var_name
	variable.kind = kind
	variable.type = type
	if value is String and type == 2:
		variable.text = value
	elif (value is int or value is float) and (type == 1 or type == 4):
		variable.number = value
	else:
		variable.value = value
	variables.append(variable)
	return variable
