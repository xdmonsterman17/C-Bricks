@tool
class_name BrickscriptVariable
extends Resource

## A script variable of a Brickscript wire graph (constant, export or shared).
## Nodes refer to it by name; renaming through flow_ops.gd updates them.
## Create through BrickscriptFlowGraph.add_variable(), which hands out ids.

enum Kind {
	## `const`: one fixed value for every node. Read-only.
	CONSTANT,
	## `@export var`: set per node in the Inspector. Read-only in nodes.
	EXPORT,
	## `var` on the node: shared by all of its chains, kept while it exists.
	SHARED,
	## Not used in graphs: chain variables are made by naming a node's Output
	## Var (the compiler rejects a listed one). Kept so saved kinds stay valid.
	CHAIN,
}

@export var id: int = 0
@export var name: String = ""
@export var kind: Kind = Kind.SHARED
## flow_types.gd ValueType (NUMBER 1 decimal, TEXT 2, WHOLE 4, BOOL 5, VECTOR2 6,
## VECTOR3 7, COLOR 8, NODE 9, LIST 10, TABLE 11).
@export_enum("Number:1", "Text:2", "Whole number:4", "Bool:5", "Vector2:6", "Vector3:7", "Color:8", "Node:9", "List:10", "Table:11") var type: int = 1
## Starting (or constant) value, for NUMBER and WHOLE variables (WHOLE rounds).
@export var number: float = 0.0
## Starting (or constant) value, for TEXT variables.
@export var text: String = ""
## Starting (or constant) value for the other types (null: the type's default).
## For NODE, a node path.
@export var value: Variant = null


func get_value() -> Variant:
	match type:
		1, 4: return number
		2: return text
	return value
