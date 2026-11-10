@icon("res://addons/brickscript/icons/nodes/spawn_points.svg")
class_name BrickscriptSpawnPoints
extends Node

## Where a Character Spawner puts characters (like Roblox's SpawnLocations):
## its children are the spawn points (Marker3D / Marker2D, or a
## BrickscriptSpawnPoint / SpawnPoint2D for on / off and a tag; any Node3D /
## Node2D works). Plain children use only their position; these settings
## pick among them.

enum Order {
	## One after the other.
	IN_TURN,
	## Any of them.
	RANDOM,
	## The one farthest from the other characters.
	FARTHEST,
}

## Which point the next character gets.
@export var order: Order = Order.IN_TURN
## Characters start turned the way their point faces (a Marker3D's forward,
## -Z; a Marker2D's rotation).
@export var face_point: bool = true
## A point with a character standing on it (within occupied_radius) is
## skipped for the next free one (all taken: the one picked anyway).
@export var skip_occupied: bool = true
@export var occupied_radius: float = 1.0
## Tags: the name of a player value (an Object Text / Whole under the player,
## e.g. "team") whose value picks the points tagged with it; untagged points
## are for everyone. Empty: tags aren't used.
@export var tag_value: String = ""

var _next: int = 0


## The point for `player_node`'s character (null: no points). `others`:
## the characters already there.
func pick(player_node: Node, others: Array[Node]) -> Node:
	var points: Array[Node] = points_for(player_node)
	if points.is_empty():
		return null
	match order:
		Order.FARTHEST:
			var best: Node = points[0]
			var best_distance: float = -1.0
			for point: Node in points:
				var nearest: float = INF
				for other: Node in others:
					nearest = minf(nearest, _distance(point, other))
				if nearest > best_distance:
					best_distance = nearest
					best = point
			return best
		Order.RANDOM:
			points.shuffle()
			for point: Node in points:
				if not _occupied(point, others):
					return point
			return points[0]
		_:
			for step: int in points.size():
				var index: int = (_next + step) % points.size()
				if not _occupied(points[index], others):
					_next = index + 1
					return points[index]
			var first: Node = points[_next % points.size()]
			_next += 1
			return first


## The points `player_node` may use: switched on, and with its tag (or none)
## when tag_value is set. None of them with its tag: all switched-on ones.
func points_for(player_node: Node) -> Array[Node]:
	var on: Array[Node] = get_children().filter(func(point: Node) -> bool:
		return (point is Node3D or point is Node2D) and bool(point.get(&"enabled") if &"enabled" in point else true))
	if tag_value.is_empty() or player_node == null:
		return on
	var holder: Node = player_node.get_node_or_null(NodePath(tag_value))
	var wanted: String = str(holder.get(&"value")) if holder != null else ""
	var tagged: Array[Node] = on.filter(func(point: Node) -> bool:
		var tag: String = str(point.get(&"tag")) if &"tag" in point else ""
		return tag.is_empty() or tag == wanted)
	return tagged if not tagged.is_empty() else on


func _occupied(point: Node, others: Array[Node]) -> bool:
	return skip_occupied and others.any(func(other: Node) -> bool: return _distance(point, other) < occupied_radius)


func _distance(point: Node, other: Node) -> float:
	if point is Node3D and other is Node3D:
		return (point as Node3D).global_position.distance_to((other as Node3D).global_position)
	if point is Node2D and other is Node2D:
		return (point as Node2D).global_position.distance_to((other as Node2D).global_position)
	return INF
