@icon("res://addons/brickscript/icons/nodes/character_spawner.svg")
class_name BrickscriptCharacterSpawner
extends Node

## Characters for every player, automatically (like Roblox's
## CharacterAutoLoads with SpawnLocations): put it in the game scene and set
## the character scene. Where the game runs (the server; offline or without
## the Network Context Engine, this machine as player 1):
## - every player (the ones there already, and each who joins) gets their
##   character at the next spawn point, as their character (Character of
##   finds it; a Character3D / Character2D hands them its movement);
## - a player who leaves loses theirs;
## - a character that goes (freed: it fell, it was killed) comes back after
##   `respawn_seconds`, while its player is still there.
## A character is named after its player (their node under Players:
## "xdmonster", "xdmonster_2"): a joining player's username is waited for (up
## to NAME_WAIT_SEC), and when a player's name changes their character is
## made again where it stands (the engine can't rename what it spawned).
## Brickscripts hear about it with When character spawned (character_spawned).
## Its Character defaults are how the characters it holds fall and die when
## theirs say From spawner (every machine marks the ones it holds).

const Net := preload("res://addons/brickscript/runtime/character_net.gd")

## Emitted where the game runs, when a player's character is made.
signal character_spawned(player: int, character: Node)

## The character scene (its root a BrickscriptCharacter3D / 2D, say).
@export var character_scene: PackedScene = null
## A node whose children (Marker3D, or any Node3D / Node2D) are the spawn
## points: a BrickscriptSpawnPoints picks among them by its settings (order,
## facing, skipping occupied ones, tags), any other node in turn. Empty: this
## node's own children.
@export var spawn_points: NodePath = ^""
## What every character starts with (a BrickscriptStarter: its children are
## copied into each character on every machine; LocalScripts only on its
## player's, ServerScripts where the game runs). Empty: nothing.
@export var starter_character: NodePath = ^""
## Where characters go. Empty: this node.
@export var container: NodePath = ^""
## How long after a character goes it comes back (0: it doesn't).
@export var respawn_seconds: float = 3.0

enum FallAction { DIE, PUT_BACK }
enum DeathLook { DEFAULT, SCRIPTED }

@export_group("Character defaults")
## For its characters whose Fall action is From spawner: falling below their
## fall_limit they die, or are put back where they started.
@export var fall_action: FallAction = FallAction.DIE
## For its characters whose Death look is From spawner: Default (falls over),
## Scripted (the death scripts do it).
@export var death_look: DeathLook = DeathLook.DEFAULT
## For its characters with no death scripts of their own (Scripted): runs
## where the game runs when one dies.
@export_file("*.brickserver", "*.gd") var death_server_script: String = ""
## Runs on every machine when one dies (effects only).
@export_file("*.bricklocal", "*.gd") var death_local_script: String = ""

## Group the spawner is in (Brickscript events find it).
const GROUP: StringName = &"brickscript_character_spawner"
## The longest the server waits for a joining player's username before
## spawning their character under the stand-in name (Player<n>).
const NAME_WAIT_SEC: float = 2.0

var _next_point: int = 0
## player -> their character (where the game runs).
var _characters: Dictionary[int, Node] = {}
## Players whose username is being waited for, and ones waited for already.
var _waiting: Dictionary[int, bool] = {}
var _waited: Dictionary[int, bool] = {}
## player -> their node under Players whose renames are followed.
var _watched: Dictionary[int, Node] = {}
## Characters being made again under a new name -> where they stood.
var _replacing: Dictionary[Node, Variant] = {}


func _ready() -> void:
	add_to_group(GROUP)
	# (Every machine fills the characters it gets: the server's spawns too.)
	var holder: Node = get_node_or_null(container) if not container.is_empty() else self
	if holder != null:
		holder.child_entered_tree.connect(_on_character_entered)
	var engine: Node = _engine()
	if engine != null:
		engine.connect(&"player_joined", _on_player_joined)
		engine.connect(&"player_left", _on_player_left)
		# Back to single-player (leaving a game), or hosting: everyone gets
		# theirs again (a client's were the server's).
		engine.connect(&"context_changed", func(_new_context: int, _old_context: int) -> void: _spawn_everyone.call_deferred())
	_spawn_everyone.call_deferred()
	_watch_players.call_deferred()


## The players with a character from this spawner and their characters.
func spawned() -> Dictionary:
	var found: Dictionary = {}
	for player: int in _characters:
		if is_instance_valid(_characters[player]):
			found[player] = _characters[player]
	return found


## The character of `player` this spawner made (where the game runs), or null.
func character_of(player: int) -> Node:
	var character: Node = _characters.get(player)
	return character if is_instance_valid(character) else null


func _spawn_everyone() -> void:
	# (Deferred calls can come after it left: a game ending as it closes.)
	if not is_inside_tree() or not _runs_game():
		return
	var engine: Node = _engine()
	var players: Array = Array(engine.call(&"get_players")) if engine != null and engine.has_method(&"get_players") else [1]
	for player: Variant in players:
		_spawn(int(player))


func _on_player_joined(player: int) -> void:
	if _runs_game():
		_spawn.call_deferred(player)


func _on_player_left(player: int) -> void:
	var character: Node = character_of(player)
	_characters.erase(player)
	if character != null and is_inside_tree() and _runs_game():
		character.queue_free()


## `at`: where it stands (a Transform3D / Transform2D), instead of the next
## spawn point.
func _spawn(player: int, at: Variant = null) -> void:
	if not is_inside_tree():
		return
	if character_scene == null:
		push_error("Character Spawner: pick a character scene.")
		return
	if character_of(player) != null or not _still_here(player) or _waiting.has(player):
		return
	var parent: Node = get_node_or_null(container) if not container.is_empty() else self
	if parent == null:
		push_error("Character Spawner: no node at %s to put characters in." % container)
		return
	var named: BrickscriptPlayer = BrickscriptPlayers.player_of(self, player)
	if named != null and named.username.is_empty() and not _waited.has(player) and at == null:
		_wait_for_name(player)
		return
	var character_name: String = String(named.name) if named != null else ""
	var engine: Node = _engine()
	var character: Node = null
	if engine != null and engine.has_method(&"spawn_for"):
		var named_spawns: bool = engine.has_method(&"get_api_version") and int(engine.call(&"get_api_version")) >= 16
		character = engine.call(&"spawn_for", player, character_scene, parent, {}, character_name) if named_spawns else engine.call(&"spawn_for", player, character_scene, parent, {})
	else:
		character = character_scene.instantiate()
		if not character_name.is_empty() and not parent.has_node(NodePath(character_name)):
			character.name = character_name
		parent.add_child(character, true)
	if character == null:
		return
	if at is Transform3D and character is Node3D:
		(character as Node3D).global_transform = at
	elif at is Transform2D and character is Node2D:
		(character as Node2D).global_transform = at
	else:
		_place(character, named)
	_watch(player, named)
	if engine != null and engine.has_method(&"set_player_character"):
		engine.call(&"set_player_character", player, character)
	_characters[player] = character
	character.tree_exiting.connect(_on_character_gone.bind(player, character), CONNECT_ONE_SHOT)
	character_spawned.emit(player, character)


## At the next spawn point: a BrickscriptSpawnPoints' pick, else in turn.
func _place(character: Node, named: Node) -> void:
	var holder: Node = get_node_or_null(spawn_points) if not spawn_points.is_empty() else self
	if holder is BrickscriptSpawnPoints:
		var others: Array[Node] = []
		others.assign(spawned().values().filter(func(other: Node) -> bool: return other != character))
		var chosen: Node = (holder as BrickscriptSpawnPoints).pick(named, others)
		var facing: bool = (holder as BrickscriptSpawnPoints).face_point
		if character is Node3D and chosen is Node3D:
			(character as Node3D).global_position = (chosen as Node3D).global_position
			if facing:
				(character as Node3D).global_rotation = Vector3(0.0, (chosen as Node3D).global_rotation.y, 0.0)
		elif character is Node2D and chosen is Node2D:
			(character as Node2D).global_position = (chosen as Node2D).global_position
			if facing:
				(character as Node2D).global_rotation = (chosen as Node2D).global_rotation
		return
	var points: Array[Node] = []
	if holder != null:
		points.assign(holder.get_children().filter(func(point: Node) -> bool: return point is Node3D or point is Node2D))
	if points.is_empty():
		return
	var point: Node = points[_next_point % points.size()]
	_next_point += 1
	if character is Node3D and point is Node3D:
		(character as Node3D).global_position = (point as Node3D).global_position
	elif character is Node2D and point is Node2D:
		(character as Node2D).global_position = (point as Node2D).global_position


## A character arrived in the container (spawned here, or the server's on a
## client): StarterCharacter's copy, by this machine's part.
func _on_character_entered(character: Node) -> void:
	# (Its characters' From spawner settings are read from here.)
	character.set_meta(Net.SPAWNER_META, self)
	if starter_character.is_empty():
		return
	var starter: BrickscriptStarter = get_node_or_null(starter_character) as BrickscriptStarter
	if starter == null:
		return
	var engine: Node = _engine()
	var player: int = int(engine.call(&"get_player_of", character)) if engine != null and engine.has_method(&"get_player_of") else 1
	var here: int = int(engine.call(&"get_local_peer_id")) if engine != null else 1
	starter.copy_into(character, player, here, _runs_game())


## Waits (a moment, at most NAME_WAIT_SEC) for a joining player's username,
## then spawns their character.
func _wait_for_name(player: int) -> void:
	_waiting[player] = true
	var left: float = NAME_WAIT_SEC
	while left > 0.0 and is_inside_tree():
		await get_tree().create_timer(0.1).timeout
		left -= 0.1
		var named: BrickscriptPlayer = BrickscriptPlayers.player_of(self, player) if is_inside_tree() else null
		if named == null or not named.username.is_empty():
			break
	_waiting.erase(player)
	if is_inside_tree() and _runs_game():
		# (Without a username by now: the stand-in name; made again when it
		# comes, see _on_player_renamed.)
		_waited[player] = true
		_spawn(player)
		_waited.erase(player)


## Player nodes made again (hosting, leaving a game) are followed too.
func _watch_players() -> void:
	if not is_inside_tree():
		return
	var players: BrickscriptPlayers = BrickscriptPlayers.of(self)
	if players != null and not players.player_added.is_connected(_on_player_added):
		players.player_added.connect(_on_player_added)


func _on_player_added(named: BrickscriptPlayer) -> void:
	if character_of(named.peer_id) != null:
		_watch(named.peer_id, named)
		_on_player_renamed(named.peer_id, named)


## Follows `named`'s renames (their character takes the new name).
func _watch(player: int, named: Node) -> void:
	if named != null and _watched.get(player) != named:
		_watched[player] = named
		named.renamed.connect(_on_player_renamed.bind(player, named))


## A player's name changed (the username arrived, or they changed it): their
## character is made again where it stands, with the new name.
func _on_player_renamed(player: int, named: Node) -> void:
	var character: Node = character_of(player)
	if character == null or not is_instance_valid(named) or String(character.name) == String(named.name) or not is_inside_tree() or not _runs_game():
		return
	_replacing[character] = (character as Node3D).global_transform if character is Node3D else (character as Node2D).global_transform if character is Node2D else null
	_characters.erase(player)
	character.queue_free()


func _on_character_gone(player: int, character: Node) -> void:
	if _replacing.has(character):
		var at: Variant = _replacing[character]
		_replacing.erase(character)
		# (Deferred: its name is free once it has left.)
		_spawn.call_deferred(player, at)
		return
	if _characters.get(player) == character:
		_characters.erase(player)
	if respawn_seconds > 0.0 and is_inside_tree() and not is_queued_for_deletion() and _runs_game():
		get_tree().create_timer(respawn_seconds).timeout.connect(func() -> void:
			if is_instance_valid(self) and is_inside_tree() and _runs_game():
				_spawn(player))


func _still_here(player: int) -> bool:
	var engine: Node = _engine()
	return engine == null or not engine.has_method(&"has_player") or bool(engine.call(&"has_player", player))


func _runs_game() -> bool:
	var engine: Node = _engine()
	return engine == null or bool(engine.call(&"has_server_authority"))


func _engine() -> Node:
	return get_node_or_null(^"/root/NetworkEngine")
