@icon("res://addons/brickscript/icons/nodes/player.svg")
class_name BrickscriptPlayer
extends Node

## One player in the game (like Roblox's Player): a child of the Players node,
## named after the player (a second "xdmonster" is "xdmonster_2"). It's what a
## Player value in a brickscript is: Owner, Me, Player Joined... give it. Its
## child values (Object Number, Object Text...) are that player's: the server
## changes them and every machine sees it. Every machine has the same player
## nodes; it's removed when the player leaves.

## The player's number in the network (the host is 1; offline you are 1).
@export var peer_id: int = 0
## The name they picked (the node's name may have a _2: two can pick the same).
@export var username: String = ""
## Their profile's ID: made once on their machine, the same every game.
@export var user_id: String = ""


## The player's character (a Character Spawner's, or what Give To made it).
func get_character() -> Node:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or not engine.has_method(&"get_player_character"):
		return null
	return engine.call(&"get_player_character", peer_id) as Node


## Whether this player is the one playing on this machine.
func is_me() -> bool:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	return peer_id == (int(engine.call(&"get_local_peer_id")) if engine != null else 1)


## Printed (Print, str() in a Formula): the player's name.
func _to_string() -> String:
	return String(name)
