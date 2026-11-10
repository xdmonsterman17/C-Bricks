extends RefCounted

## Where Export bricks are shown (Shown on), for the editor's Inspector
## (editor/node_inspector.gd), and which nodes are character nodes. Kept out
## of the editor folder so headless tests can use it.

const CHARACTER_SCRIPTS: PackedStringArray = [
	"res://addons/brickscript/runtime/character_3d.gd",
	"res://addons/brickscript/runtime/character_2d.gd",
]
## The compiled table of exports shown elsewhere (flow_compiler.gd SHOWN_ON_CONST).
const SHOWN_ON_CONST: StringName = &"_BRICKSCRIPT_SHOWN_ON"
const SCRIPT_NODE_META: StringName = &"script_node"


## A brickscript's exports shown on other nodes (name -> path from the node
## it acts for).
static func shown_elsewhere(object: Object) -> Dictionary:
	var script: Script = object.get_script() as Script if object != null else null
	var table: Variant = script.get_script_constant_map().get(SHOWN_ON_CONST) if script != null else null
	return table if table is Dictionary else {}


## [script node, export name] of every Export shown on `target`, from the
## brickscripts of `scene` (its nodes, those inside scenes placed in it too).
static func shown_on(target: Node, scene: Node) -> Array[Array]:
	var shown: Array[Array] = []
	var holders: Array[Node] = [scene]
	holders.append_array(scene.find_children("*", "", true, false))
	for holder: Node in holders:
		var table: Dictionary = shown_elsewhere(holder)
		if table.is_empty():
			continue
		# Paths are from the node it acts for: a script node's parent.
		var body: Node = holder.get_parent() if holder.has_meta(SCRIPT_NODE_META) and holder.get_parent() != null else holder
		for name: Variant in table:
			if body.get_node_or_null(NodePath(str(table[name]))) == target:
				shown.append([holder, str(name)])
	return shown


static func is_character(object: Object) -> bool:
	var script: Script = object.get_script() as Script if object != null else null
	return script != null and CHARACTER_SCRIPTS.has(script.resource_path)
