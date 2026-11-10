@icon("res://addons/brickscript/icons/nodes/object_value.svg")
class_name BrickscriptObjectValue
extends Node

## What Object Bool / Number / Whole / Text / Vector2 / Vector3 / Color share
## (Roblox's BoolValue, NumberValue...): one `value`, and `changed` when it
## changes. The server changes it and every machine sees it (late joiners
## too); a client's own change is put back by the server's next one.
## - Under a player (Players/<name>/...): that player's value, sent with the
##   player (fresh each game: a player starts with the value the Players
##   node's template has).
## - Anywhere else: synced like a Sync brick's property (the server
##   registers it when it's ready).

signal changed(value: Variant)

## Set while a value arrives from the server (not sent back out).
var _arriving: bool = false


func _ready() -> void:
	if _player() != null:
		return
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and engine.has_method(&"sync_property") and bool(engine.call(&"has_server_authority")):
		engine.call(&"sync_property", self, "value", false)


## Sets the value as it arrived from the server.
func arrive(value: Variant) -> void:
	_arriving = true
	set(&"value", value)
	_arriving = false


## The subclasses' setters call this after storing a new value.
func _value_changed() -> void:
	changed.emit(get(&"value"))
	var player: Node = _player()
	if player != null and player.is_inside_tree():
		# (Player Value Changed hears it on every machine; the server also
		# sends it with the player.)
		var players: Node = player.get_parent()
		if players != null and players.has_method(&"value_changed"):
			players.call(&"value_changed", player, self, not _arriving)


## The player this value belongs to (the nearest BrickscriptPlayer above it).
func _player() -> Node:
	var at: Node = get_parent()
	while at != null:
		if at is BrickscriptPlayer:
			return at
		at = at.get_parent()
	return null
