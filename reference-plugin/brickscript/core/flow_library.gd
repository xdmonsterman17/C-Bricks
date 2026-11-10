@tool
extends RefCounted

## Every node of Brickscript's wire graphs, and the GDScript each becomes.
##
## Each entry:
## - kind:     EVENT (starts chains; numbered exits &"1", &"2", ... fired in
##             order), ACTION (one exec input; `exits`, default [&"next"]) or
##             DECLARE (no wires at all: declares a script variable before
##             the game starts; Constant, Export).
## - category, title: palette group and the name shown on the node.
## - description: one or two sentences on what it does (shown in Properties
##             when its palette entry is clicked).
## - inputs:   Array of {name, types (allowed ValueTypes, [] = any), default
##             ({"type", "value"} or {"var": ""})}. Each input takes a
##             variable or a typed-in value; see BrickscriptFlowNode.inputs.
## - settings: Array of {name, kind ("action" / "text" / "bool" / "choice"
##             with `options` / "name": a variable name the node makes /
##             "node_path", "node_class", "node_script", "scene": what a
##             Node is (see core/node_types.gd) / "property", "method": a
##             member of the node in the input named by `target` / "group":
##             a group name, picked from the project's groups),
##             title, info (how it's set, for the palette info), default}:
##             typed-in only, never a variable.
## - variadic: {"inputs": [input specs], "min", "default_count"}: inputs
##             repeated per row as <name>_1, <name>_2, ... (count in
##             settings.count; + / - in Properties). `result` is then built
##             with `join` {"open", "row", "separator", "close"}.
## - writes:   on an input: the node changes that variable in place (a List
##             or Table), so it must be a variable that may be changed.
## - literal_only: on an input: typed in only (a declaration's value).
## - shown_when: on an input: {"setting", "value"} (or "values": a list):
##             the input is only used (and shown) while that setting has
##             that value (one of them).
## - exit_titles: display names of exits (e.g. &"loop": "Loop body").
## - contexts: where the brick can be used ([&"local"] / [&"server"]; all
##             when missing): the palette only offers it there.
## - local_target: an input naming the node the brick changes. In a local
##             brickscript it must be local-only (core/node_types.gd
##             is_local_only: UI, a camera, a sound, particles, or what the
##             script spawned): checked by its Type when compiling, and again
##             when the game runs (_brickscript_local_only).
## - network:  only offered while the Network Context Engine is installed.
## - helper:   GDScript appended once to a script that uses the brick
##             (`helpers`: several, each once).
## - input_signal / each_holder: a server event on players' input
##             (NetworkEngine player_action_pressed / _released, or every
##             frame for each player holding the action; flow_compiler.gd
##             _input_event).
## - output:   true: the node makes a value (an Output Var) though it has no
##             `result` template (compiled specially).
## - waits:    the node pauses its chain (await): an event that runs one gets
##             its own function, so it doesn't hold up other events.
## - EVENT:    function + function_params ([name, type] pairs; events with the
##             same function share it), optional guard (condition for its
##             chains to run, {setting} placeholders), provides ({name: type}
##             values its chains can read, e.g. delta), annotation (put
##             before the function, e.g. @rpc), prelude (first lines of the
##             function).
## - ACTION:   code ({input} placeholders) for nodes that only do something;
## - branch:   {"cases": [[exit, condition], ...]}: exits taken like an
##             If's after its code, the first whose condition holds (Raycast's
##             Hit / Nothing hit, Walk to's Arrived / Can't reach / Stopped).
##             `result` for nodes that make a value: the expression, with
##             `returns` = a ValueType or a rule (see flow_compiler.gd:
##             &"arith", &"divide"). Formula, If and Set Var are compiled
##             specially (`special`).

const Types = preload("flow_types.gd")
const T = Types.ValueType

enum Kind { EVENT, ACTION, DECLARE }

const PROCESS_PARAMS: Array = [["delta", "float"]]
## Server brickscripts: an event can also run on its player's machine, which
## then moves its node at once (client-side prediction, Network Context
## Engine API 13); the server still runs the game and corrects it.
const PREDICTED: String = "The server and its player's machine (predicted)"
## Property's and Variable's Mode: Get reads (into the Output), Set and Add
## write. Until format 7 Property was Get property + Set property (and its
## Add the Change property brick until format 6), Variable was Set Var. A
## brick saved without a mode is Set (mode_of()).
const ACCESS_MODES: PackedStringArray = ["Get", "Set", "Add"]
## Their value input: only when writing.
const WRITING: Dictionary = {"setting": &"mode", "values": ["Set", "Add"], "if_missing": "Set"}
## The property / variable types Add takes.
const ADDABLE_TYPES: Array[int] = [T.ANY, T.NUMBER, T.WHOLE, T.VECTOR2, T.VECTOR3]
const RUNS_ON_SETTING: Dictionary = {"name": &"runs_on", "kind": "choice", "title": "Runs on", "options": ["The server", PREDICTED], "default": "The server", "context": &"server",
	"info": "server brickscripts: the server only, or also on the machine of the player this node belongs to, which then moves it at once (prediction: their own moves show without waiting for the server). Only for moving it: no spawning, freeing or player data there"}
## Bricks a predicted event may not run: they'd happen on the player's
## machine too (twice, or where only the server may).
const PREDICT_REFUSED: Array[StringName] = [&"spawn_scene", &"free_node", &"set_owner", &"tell_clients", &"play_animation", &"stop_animation", &"tween_property", &"stop_tweens",
	&"add_to_group", &"remove_from_group", &"finish_mesh"]
const PREDICTION_HELPER: String = """func _brickscript_predicting() -> bool:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	return engine != null and engine.has_method(&"is_predicting") and bool(engine.call(&"is_predicting", _brickscript_body))


func _brickscript_set_predicted() -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and engine.has_method(&"set_predicted"):
		engine.call(&"set_predicted", _brickscript_body, true)"""
const INPUT_PARAMS: Array = [["event", "InputEvent"]]
const ACTION_SETTING: Dictionary = {"name": &"action", "kind": "action", "default": "ui_accept", "info": "an Input Map action (type it or pick one)"}
## Input events: in a networked game every machine has a copy of every
## player's node, so by default input only drives the copy this machine owns.
const INPUT_WHO: PackedStringArray = ["Only nodes I own", "Every copy"]
const INPUT_WHO_SETTING: Dictionary = {"name": &"who", "kind": "choice", "title": "Runs on", "options": INPUT_WHO, "default": "Only nodes I own",
	"info": "networked: only the copy that is your player's (your own character; on the host and offline also what's no one's), or every copy of it"}
const SET_OWNER_AS: PackedStringArray = ["Just the node", "Their character"]
## Players' input (server brickscripts): whose presses run the event.
const PLAYER_WHOSE: PackedStringArray = ["Any player", "This node's player"]
const PLAYER_WHOSE_SETTING: Dictionary = {"name": &"whose", "kind": "choice", "title": "Whose", "options": PLAYER_WHOSE, "default": "Any player",
	"info": "any player's, or only the player this node belongs to (Owner: e.g. their character)"}
## A player's input on the server (NetworkEngine API 6+). Without the engine
## the game is single-player: player 1's input is this machine's.
const PLAYER_INPUT_HELPER: String = """func _brickscript_player_strength(player: int, action: StringName) -> float:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or not engine.has_method(&"get_player_action_strength"):
		return Input.get_action_strength(action) if player == 1 else 0.0
	return float(engine.call(&"get_player_action_strength", player, action))"""
## Player Direction / Player Holds? with no player: this node's Owner; a node
## no player owns is yours in single-player (player 1), no one's in a game.
const OWNER_OR_ME_HELPER: String = """func _brickscript_owner_or_me(node: Node) -> BrickscriptPlayer:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	var player: int = 1
	if engine != null:
		player = int(engine.call(&"get_player_of", node)) if engine.has_method(&"get_player_of") else 0
		if player == 0 and bool(engine.call(&"is_offline")):
			player = 1
	return BrickscriptPlayers.player_of(self, player)"""
const OWNER_OR_ME: String = "_brickscript_owner_or_me(%s)"
## Key Direction / Player Direction's actions. A new brick gets the
## characters' move_* when the project has them (Ops.add_node:
## `preferred`), else ui_*.
const DIRECTION_SETTINGS: Array[Dictionary] = [
	{"name": &"left", "kind": "action", "title": "Left", "default": "ui_left", "preferred": "move_left", "info": "an Input Map action"},
	{"name": &"right", "kind": "action", "title": "Right", "default": "ui_right", "preferred": "move_right", "info": "an Input Map action"},
	{"name": &"up", "kind": "action", "title": "Up", "default": "ui_up", "preferred": "move_forward", "info": "an Input Map action"},
	{"name": &"down", "kind": "action", "title": "Down", "default": "ui_down", "preferred": "move_back", "info": "an Input Map action"},
]
const PLAYER_DIRECTION_HELPER: String = """func _brickscript_player_direction(player: int, left: StringName, right: StringName, up: StringName, down: StringName) -> Vector2:
	return Vector2(_brickscript_player_strength(player, right) - _brickscript_player_strength(player, left),
		_brickscript_player_strength(player, down) - _brickscript_player_strength(player, up)).limit_length(1.0)"""
const PLAYERS_HOLDING_HELPER: String = """func _brickscript_players_holding(action: StringName) -> PackedInt32Array:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or not engine.has_method(&"get_players_holding"):
		return PackedInt32Array([1]) if Input.is_action_pressed(action) else PackedInt32Array()
	return engine.call(&"get_players_holding", action)"""
## Player Pressed / releases: the engine's signal; without it, this
## machine's input as player 1's (checked every frame).
const PLAYER_ACTIONS_HELPER: String = """var _brickscript_action_events: Array = []
var _brickscript_actions_held: Dictionary = {}


func _brickscript_on_player_actions(signal_name: StringName, callback: Callable) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and engine.has_signal(signal_name):
		engine.connect(signal_name, callback)
		return
	_brickscript_action_events.append([signal_name == &"player_action_pressed", callback])
	if not get_tree().process_frame.is_connected(_brickscript_poll_actions):
		get_tree().process_frame.connect(_brickscript_poll_actions)


func _brickscript_poll_actions() -> void:
	for action: StringName in InputMap.get_actions():
		var held: bool = Input.is_action_pressed(action)
		if held == _brickscript_actions_held.has(action):
			continue
		if held:
			_brickscript_actions_held[action] = true
		else:
			_brickscript_actions_held.erase(action)
		for entry: Array in _brickscript_action_events:
			if entry[0] == held:
				(entry[1] as Callable).call(1, action)"""
const VALUE_WHOSE: PackedStringArray = ["Any player", "Me"]
## Player Value Changed: the Players node's signal; the values already there
## count as changing once (deferred, as players already there count as
## joining; skipped for a value that changed in the meantime).
const PLAYER_VALUES_HELPER: String = """var _brickscript_value_listeners: Array = []


func _brickscript_on_player_values(callback: Callable) -> void:
	var players: BrickscriptPlayers = BrickscriptPlayers.of(self)
	var changed: Dictionary = {}
	_brickscript_value_listeners.append([changed, callback])
	if not players.player_value_changed.is_connected(_brickscript_player_value_heard):
		players.player_value_changed.connect(_brickscript_player_value_heard)
	for player: BrickscriptPlayer in players.all():
		for value: Node in player.find_children("*", "", true, false):
			if value is BrickscriptObjectValue:
				var path: String = String(player.get_path_to(value))
				(func() -> void:
					if is_instance_valid(value) and not changed.has([player, path]):
						callback.call(player, path, value.get(&"value"))).call_deferred()


func _brickscript_player_value_heard(player: BrickscriptPlayer, value_name: String, value: Variant) -> void:
	for listener: Array in _brickscript_value_listeners:
		(listener[0] as Dictionary)[[player, value_name]] = true
		(listener[1] as Callable).call(player, value_name, value)"""
## Player Renamed: each player node's renamed, looked at once the frame's
## renames are done (two players swapping names step through a stand-in) and
## only when the name really changed; players added later are followed too.
## Every hook on another node's signal is a method of this script, not a
## lambda: taking a ServerScript's script off (a client joining) then takes
## its connections with it (Network Context Engine server_parts.gd), where a
## lambda would be left calling methods that are gone. One connection per
## signal hands each event its turn (two bindings of one method are one
## connection to Godot).
const PLAYER_RENAMED_HELPER: String = """var _brickscript_rename_listeners: Array = []


func _brickscript_on_player_renamed(callback: Callable) -> void:
	var players: BrickscriptPlayers = BrickscriptPlayers.of(self)
	var known: Dictionary = {}
	_brickscript_rename_listeners.append([known, callback])
	for player: BrickscriptPlayer in players.all():
		known[player] = String(player.name)
		_brickscript_watch_renames(player)
	if not players.player_added.is_connected(_brickscript_player_added_renames):
		players.player_added.connect(_brickscript_player_added_renames)


func _brickscript_player_added_renames(player: BrickscriptPlayer) -> void:
	for listener: Array in _brickscript_rename_listeners:
		(listener[0] as Dictionary)[player] = String(player.name)
	_brickscript_watch_renames(player)


func _brickscript_watch_renames(player: BrickscriptPlayer) -> void:
	if not player.renamed.is_connected(_brickscript_check_rename):
		player.renamed.connect(_brickscript_check_rename.bind(player), CONNECT_DEFERRED)


func _brickscript_check_rename(player: BrickscriptPlayer) -> void:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return
	for listener: Array in _brickscript_rename_listeners:
		if (listener[0] as Dictionary).get(player, "") != String(player.name):
			(listener[0] as Dictionary)[player] = String(player.name)
			(listener[1] as Callable).call(player, String(player.name))"""
## A Player value is the player's node (Players/<name>); the engine knows
## players by number. These turn one into the other.
const PLAYER_NODE_HELPER: String = """func _brickscript_player(peer: int) -> BrickscriptPlayer:
	return BrickscriptPlayers.player_of(self, peer)


func _brickscript_peer(player: Node) -> int:
	return BrickscriptPlayers.peer_of(player)"""
## A Player as text (Print, a Formula's str(player)): their name, or "no
## player" (str() of null would be "<null>").
const PLAYER_TEXT_HELPER: String = """func _brickscript_player_text(player: Variant) -> String:
	return str(player) if is_instance_valid(player) else \"no player\""""
## Save / Load player data: a player's values on the server's disk, by user
## ID (BrickscriptPlayers.save_data / load_data). A Player arrives as a node,
## or as its number from an engine-facing input.
const PLAYER_DATA_HELPER: String = """func _brickscript_player_data(player: Variant, save: bool) -> bool:
	var node: Node = player as Node if player is Node else BrickscriptPlayers.player_of(self, int(player)) if player is int else null
	if node == null:
		push_error("%s player data: no player." % ("Save" if save else "Load"))
		return false
	var players: BrickscriptPlayers = BrickscriptPlayers.of(self)
	return players.save_data(node) == OK if save else players.load_data(node)"""
## Message values travel over the network: a Player (a node) goes as its
## number and arrives as that player's node there.
const WIRE_HELPER: String = """func _brickscript_wired(values: Array) -> Array:
	return values.map(func(value: Variant) -> Variant: return {"_brickscript_player": BrickscriptPlayers.peer_of(value)} if value is BrickscriptPlayer else value)


func _brickscript_unwired(values: Array) -> Array:
	return values.map(func(value: Variant) -> Variant:
		if value is Dictionary and (value as Dictionary).size() == 1 and (value as Dictionary).has("_brickscript_player"):
			return BrickscriptPlayers.player_of(self, int(value["_brickscript_player"]))
		return value)"""
## Give To: hands the node over, and (as their character) records it in the
## player's data (NetworkEngine.set_player_character, API 5+).
const SET_OWNER_HELPER: String = """func _brickscript_set_owner(node: Node, player: int, character: bool) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null:
		return
	engine.call(&"set_node_owner", node, player)
	if character and player != 0 and engine.has_method(&"set_player_character"):
		engine.call(&"set_player_character", player, node)"""
## Moved By: whose machine moves a node (0: the server), with a speed limit.
const MOVED_BY_HELPER: String = """func _brickscript_moved_by(node: Node, player: int, max_speed: float) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null:
		if player == 1:
			node.set_meta(&"_brickscript_yours", true)
		elif node.has_meta(&"_brickscript_yours"):
			node.remove_meta(&"_brickscript_yours")
	elif engine.has_method(&"set_network_owner"):
		engine.call(&"set_network_owner", node, player, max_speed)"""
## Character: NetworkEngine.get_player_character (API 5+).
const CHARACTER_OF_HELPER: String = """func _brickscript_character_of(player: int) -> Node:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or not engine.has_method(&"get_player_character"):
		return null
	return engine.call(&"get_player_character", player) as Node"""
## Owner: NetworkEngine.get_player_of (API 4+). Without the engine the
## game is single-player and everything is yours (player 1).
const PLAYER_OF_HELPER: String = """func _brickscript_player_of(node: Node) -> int:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null:
		return 1
	return int(engine.call(&"get_player_of", node)) if engine.has_method(&"get_player_of") else 0"""
const MY_PLAYER_HELPER: String = """func _brickscript_my_player() -> int:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	return int(engine.call(&"get_local_peer_id")) if engine != null else 1"""
## Whether a node is this machine's player's (Mine?, and input events' Only
## nodes I own). An input event (`brick` given) on a client for a node no
## player owns says once why nothing happens (BUGS.md 2026-10-31: a client's
## key did nothing, silently).
const OWNS_HELPER: String = """func _brickscript_owns(node: Node, brick: String = "") -> bool:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null:
		return true
	var mine: bool = bool(engine.call(&"is_mine", node)) if engine.has_method(&"is_mine") else bool(engine.call(&"is_authority", node))
	if not mine and not brick.is_empty() and engine.has_method(&"get_player_of") and bool(engine.call(&"is_client")) \\
			and int(engine.call(&"get_player_of", node)) == 0 and not node.has_meta(&"_brickscript_told_unowned"):
		node.set_meta(&"_brickscript_told_unowned", true)
		push_warning("%s: this machine's key is for %s, which no player owns, so it runs only on the host (Runs on: Only nodes I own). Set Runs on to Every copy (and send the press to the server with Fire Server), or give the node to this player first (Give To / Moved By in its server brickscript)." % [brick, node.name])
	return mine"""
## Calls a NetworkEngine method by name (the plugins never reference each
## other); ERR_UNAVAILABLE without the engine.
const NETWORK_HELPER: String = """func _brickscript_network(method: StringName, args: Array) -> Variant:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	return engine.callv(method, args) if engine != null else ERR_UNAVAILABLE"""
## Only the server registers a synced property; the engine tells every client
## (and later joiners) itself.
const SYNC_HELPER: String = """func _brickscript_sync(node: Node, property: String, smooth: bool) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and bool(engine.call(&"has_server_authority")):
		engine.call(&"sync_property", node, property, smooth)"""
## Server brickscripts spawn for every machine.
## For a player (Spawn scene's For): made theirs right away (Give To), and
## their character if asked, before anyone else sees it.
## Spawn scene: its parent must be there, or it says which brick and the
## chain stops (2026-11-02, a blind run: a wrong path gave only Godot's own
## errors and the chain carried on).
const SPAWN_PARENT_HELPER: String = """func _brickscript_spawn_parent(parent: Node, brick: String) -> bool:
	if is_instance_valid(parent) and parent.is_inside_tree():
		return true
	push_error("%s: its Parent isn't there (check the path or the node in Parent): nothing was spawned, and the rest of the chain is skipped" % brick)
	return false"""
const SPAWN_HELPER: String = """func _brickscript_spawn(scene: PackedScene, parent: Node, properties: Dictionary, player: int = 0, character: bool = false) -> Node:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null:
		var made: Node = scene.instantiate()
		for property: String in properties:
			made.set(property, properties[property])
		parent.add_child(made)
		return made
	var spawned: Node = null
	if player != 0 and engine.has_method(&"spawn_for"):
		# Theirs already in its _ready (API 9).
		spawned = engine.call(&"spawn_for", player, scene, parent, properties)
	else:
		spawned = engine.call(&"spawn", scene, parent, 1, properties)
		if spawned != null and player != 0:
			engine.call(&"set_node_owner", spawned, player)
	if spawned != null and character and player != 0 and engine.has_method(&"set_player_character"):
		engine.call(&"set_player_character", player, spawned)
	return spawned"""
## Player Joined / leaves: also once for every player already in the
## game when the node is ready (offline: you, peer 1), so the host's and a
## single player's own character are made the same way.
## Player Joined waits (at most PLAYER_NAME_WAIT_SEC, like the Character
## Spawner) for a joining player's username, so it gives their name, not the
## stand-in Player<number>; not if they left meanwhile.
const PLAYER_NAME_WAIT_SEC: float = 2.0
const PLAYERS_HELPER: String = """## Players whose Player Joined waits for their name: one who leaves
## meanwhile was never announced, so Player Left isn't either.
var _brickscript_joining: Dictionary = {}


func _brickscript_on_players(signal_name: StringName, callback: Callable) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null:
		if signal_name == &"player_joined":
			callback.call_deferred(1)
		return
	if signal_name == &"player_left":
		engine.connect(signal_name, func(peer: int) -> void:
			if not _brickscript_joining.has(peer):
				callback.call(peer))
		return
	if signal_name != &"player_joined":
		engine.connect(signal_name, callback)
		return
	engine.connect(signal_name, _brickscript_named_join.bind(callback))
	for peer: int in engine.call(&"get_players"):
		_brickscript_named_join.call_deferred(peer, callback)


func _brickscript_named_join(peer: int, callback: Callable) -> void:
	_brickscript_joining[peer] = true
	var left: float = %s
	while left > 0.0 and is_inside_tree():
		var named: BrickscriptPlayer = BrickscriptPlayers.player_of(self, peer)
		if named == null or not named.username.is_empty():
			break
		await get_tree().create_timer(0.1).timeout
		left -= 0.1
	_brickscript_joining.erase(peer)
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if is_inside_tree() and engine != null and bool(engine.call(&"has_player", peer)):
		callback.call(peer)""" % PLAYER_NAME_WAIT_SEC
const SET_VAR_KIND_SYNCED: String = "Synced"
## Host / Join: only from single-player (already in a game, they
## give false instead of making the engine complain).
const CONNECT_HELPER: String = """func _brickscript_connect(method: StringName, args: Array) -> Error:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null:
		return ERR_UNAVAILABLE
	if not bool(engine.call(&"is_offline")):
		return ERR_ALREADY_IN_USE
	return engine.callv(method, args)"""
const SYNC_UPDATES: PackedStringArray = ["Smooth", "Jump"]
## Play sound: a player node of its own, freed when the sound ends.
const PLAY_SOUND_HELPER: String = """func _brickscript_play_sound(sound: Resource, volume_db: float) -> void:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.stream = sound as AudioStream
	player.volume_db = volume_db
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()"""
## A local brickscript only changes what this machine alone sees: the
## compiler checks a node's Type, and this checks the node itself when the
## game runs (a path or a List can hold something else). Skipped, with an
## error naming the brick, otherwise.
const LOCAL_ONLY_HELPER: String = """var _brickscript_local_reported: Dictionary = {}


func _brickscript_local_only(node: Node, brick: String, asked_again: bool = false) -> bool:
	if node == null:
		return true
	# What this machine's player moves (their character, its parts): theirs to
	# change (network ownership, NetworkEngine API 14; without the engine, the
	# character spawned for player 1).
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and engine.has_method(&"is_owned_here") and bool(engine.call(&"is_owned_here", node)):
		return true
	var mine: Node = node
	while mine != null:
		if engine == null and mine.has_meta(&"_brickscript_yours"):
			return true
		# A character its player moves (Controlled by: Player) that this
		# machine's keys move: one placed in the scene, offline or on the host,
		# is nobody's but moves with your keys, so it's yours here too
		# (BUGS.md 2026-10-31).
		if (mine is BrickscriptCharacter2D or mine is BrickscriptCharacter3D and (mine as BrickscriptCharacter3D).controlled_by == BrickscriptCharacter3D.ControlledBy.PLAYER) and mine.call(&"is_mine"):
			return true
		mine = mine.get_parent()
	var at: Node = node
	while at != null:
		if at.is_in_group(&"local_only") or at is CanvasLayer or at is Control:
			return true
		at = at.get_parent()
	for local: StringName in [&"Camera2D", &"Camera3D", &"AudioStreamPlayer", &"AudioStreamPlayer2D", &"AudioStreamPlayer3D", &"GPUParticles2D", &"GPUParticles3D", &"CPUParticles2D", &"CPUParticles3D"]:
		if node.is_class(local):
			return true
	# Given to this machine's player (Give To / Spawn For them) but its
	# Moved By hasn't arrived yet (a separate message, a frame or so later):
	# skipped quietly for a second, an error after that.
	if engine != null and engine.has_method(&"get_player_of") and int(engine.call(&"get_player_of", node)) == int(engine.call(&"get_local_peer_id")):
		var now: int = Time.get_ticks_msec()
		if not node.has_meta(&"_brickscript_waiting_since"):
			node.set_meta(&"_brickscript_waiting_since", now)
		if now - int(node.get_meta(&"_brickscript_waiting_since")) < 1000:
			return false
		_brickscript_refuse(node, brick, "%s: %s is this machine's player's, but the server didn't let their machine move it: give it with Moved By in the server brickscript (or change it from there)." % [brick, node.name])
		return false
	# The game's first second: the server brickscript may not have given it
	# yet (Player Joined -> Moved By runs after the first frames). Asked
	# again after it; still refused then, it's reported (asked_again: a slow
	# start can leave the physics frames short of a second by then, which
	# used to swallow the refusal: BUGS.md 2026-11-03).
	if not asked_again and Engine.get_physics_frames() < Engine.physics_ticks_per_second:
		var key: String = "%d %s first second" % [node.get_instance_id(), brick]
		if not _brickscript_local_reported.has(key):
			_brickscript_local_reported[key] = true
			get_tree().create_timer(1.0).timeout.connect(_brickscript_ask_again.bind(weakref(node), brick))
		return false
	_brickscript_refuse(node, brick, "%s: a local brickscript only changes UI, cameras, sounds, particles, what it spawned itself and what this machine's player moves (their character), not %s (%s). Change it from the server brickscript, or have that give it to this player with Moved By (then their machine may change it)." % [brick, node.name, node.get_class()])
	return false


func _brickscript_ask_again(held: WeakRef, brick: String) -> void:
	var node: Node = held.get_ref() as Node
	if node != null and node.is_inside_tree():
		_brickscript_local_only(node, brick, true)


## Each refusal once per brick, node and reason (a brick in an event that
## runs every frame would say it every frame).
func _brickscript_refuse(node: Node, brick: String, message: String) -> void:
	var key: String = "%d %s" % [node.get_instance_id(), message]
	if not _brickscript_local_reported.has(key):
		_brickscript_local_reported[key] = true
		push_error(message)"""
## When signal received in a server brickscript: never a signal a local
## script declares (on the host it would run for the host's player only;
## Fire Server is the way). A node's own class signals (body_entered...)
## are fine.
const SERVER_SIGNAL_HELPER: String = """func _brickscript_listen(source: Object, signal_name: StringName, callback: Callable) -> void:
	if source == null:
		return
	var node: Node = source as Node
	var script: Script = source.get_script() as Script
	var path: String = script.resource_path if script != null else ""
	var local: bool = path.ends_with(".bricklocal") or path.ends_with(".local.gd") or (node != null and str(node.get_meta(&"script_node", "")) == "local")
	if local and not ClassDB.class_has_signal(source.get_class(), signal_name):
		push_error("%s: a server brickscript can't react to %s's own signal %s (a local script's; on the host it would run for the host's player only). Send it with Fire Server, and react with On Client Fired." % [get_script().resource_path.get_file(), node.name if node != null else source, signal_name])
		return
	source.connect(signal_name, callback)"""
## Get node / Find node with a Type: a node that is something else is an
## error naming the brick (the `as` after it would quietly give null).
const TYPED_NODE_HELPER: String = """func _brickscript_typed(found: Node, wanted: StringName, brick: String) -> Node:
	if found != null and not found.is_class(wanted):
		push_error("%s: %s is a %s, not a %s (the brick's Type). Set its Type to what the node is." % [brick, found.name, found.get_class(), wanted])
		return null
	return found"""
## Local Spawn scene: the copy is this machine's alone (an effect).
const LOCAL_SPAWN_HELPER: String = """func _brickscript_local_spawn(made: Node) -> Node:
	made.add_to_group(&"local_only", true)
	return made"""
const SPAWN_PLACES: PackedStringArray = ["As in the scene", "At a position"]
## Spawn scene's For (server brickscripts): whose the new node is.
const SPAWN_FOR: PackedStringArray = ["No one", "A player", "A player: their character"]
const MATH_TYPES: Array[int] = [T.NUMBER, T.WHOLE, T.VECTOR2, T.VECTOR3]
const ZERO: Dictionary = {"type": T.NUMBER, "value": 0.0}
## If's comparisons. The unary ones test A alone (no B): a Bool, or whether a
## Node / Resource / Anything value is null (a freed node counts as null).
const IF_OPERATORS: PackedStringArray = ["is true", "is false", "is null", "is not null", "==", "!=", "<", "<=", ">", ">="]
const IF_UNARY: PackedStringArray = ["is true", "is false", "is null", "is not null"]
const IF_NULL: PackedStringArray = ["is null", "is not null"]
## For "is null" on an Anything value: null, or a freed object.
const IS_NULL_HELPER: String = """func _brickscript_is_null(value: Variant) -> bool:
	return value == null or (value is Object and not is_instance_valid(value))"""
const IF_ORDERING: PackedStringArray = ["<", "<=", ">", ">="]
## What a new name in Set Var becomes (Constants and Exports have their own
## bricks; older Set Vars set to those are upgraded, see Ops.upgrade_graph).
const SET_VAR_KINDS: PackedStringArray = ["Shared", "Chain", "Synced"]
## Bricks that declare a script variable, by type -> its kind.
const DECLARATIONS: Dictionary = {&"constant": "Constant", &"export": "Export"}
const LOOP_EXITS: Array = [&"loop", &"done"]
const LOOP_EXIT_TITLES: Dictionary = {&"loop": "Loop body", &"done": "Done"}
const COLLECTION_TYPES: Array[int] = [T.LIST, T.TABLE, T.TEXT]
const ANY_TEXT_KEY: Dictionary = {"type": T.TEXT, "value": "key"}
## Make list's Items: worked out from the items (Auto), or picked.
## Call Function From: A file: the shared brickscript's one copy on this
## machine, made on first use (under the BrickscriptDebug autoload when
## there, else the root), kept by path in Engine metadata.
const SHARED_HELPER: String = """## This script's own note of the copies it used (a quicker look-up).
var _brickscript_shared_used: Dictionary = {}


func _brickscript_shared(path: String) -> Variant:
	var used: Variant = _brickscript_shared_used.get(path)
	if is_instance_valid(used):
		return used
	var all: Dictionary = Engine.get_meta(&"_brickscript_shared", {})
	var found: Variant = all.get(path)
	if is_instance_valid(found):
		_brickscript_shared_used[path] = found
		return found
	var script: Script = load(path) as Script
	if script == null or not script.can_instantiate():
		push_error("Call Function: the shared brickscript %s can't be loaded." % path)
		return null
	var made: Node = script.new() as Node
	made.name = "Shared_" + path.get_file().get_basename().validate_node_name()
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var holder: Node = tree.root.get_node_or_null(^"BrickscriptDebug") if tree != null else null
	if holder != null:
		holder.add_child(made)
	elif tree != null:
		tree.root.add_child.call_deferred(made)
	all[path] = made
	Engine.set_meta(&"_brickscript_shared", all)
	_brickscript_shared_used[path] = made
	return made"""
## Call Function From: A node: the node's script node (or the node itself)
## running `path` (or, unpicked, a brickscript of the caller's side) that has
## the function; called at once, or waited for.
const NODE_FUNCTION_HELPER: String = """func _brickscript_function_target(node: Variant, path: String, server: bool, method: StringName, brick: String) -> Node:
	if not is_instance_valid(node) or not node is Node:
		push_error("%s: there's no node to call %s on." % [brick, String(method).trim_prefix("_bf_")])
		return null
	var side: String = "server" if server else "local"
	# The one found before is noted on the node (a quicker look-up next time).
	var noted: Dictionary = (node as Node).get_meta(&"_brickscript_calls") if (node as Node).has_meta(&"_brickscript_calls") else {}
	var known: Variant = noted.get(side + path)
	if is_instance_valid(known) and ((known as Node).get_parent() == node or known == node) and (known as Node).has_method(method):
		return known
	for candidate: Node in [node as Node] + (node as Node).get_children():
		var script: Script = candidate.get_script()
		if script == null:
			continue
		var runs: bool = script.resource_path == path if not path.is_empty() \\
			else str(candidate.get_meta(&"script_node", "")) == side or candidate == node and script.resource_path.get_extension() == ("brickserver" if server else "bricklocal")
		if runs and candidate.has_method(method):
			noted[side + path] = candidate
			(node as Node).set_meta(&"_brickscript_calls", noted)
			return candidate
	push_error("%s: %s has no %s brickscript with a function %s." % [brick, (node as Node).name, side, String(method).trim_prefix("_bf_")])
	return null


func _brickscript_call_node(node: Variant, path: String, server: bool, method: StringName, args: Array, brick: String) -> Variant:
	var target: Node = _brickscript_function_target(node, path, server, method, brick)
	return target.callv(method, args) if target != null else null


func _brickscript_await_node(node: Variant, path: String, server: bool, method: StringName, args: Array, brick: String) -> Variant:
	var target: Node = _brickscript_function_target(node, path, server, method, brick)
	if target == null:
		return null
	return await target.callv(method, args)"""
## Return: a value back, or nothing (leave the function).
const RETURN_GIVES: PackedStringArray = ["A value", "Nothing"]
## Call Function: where the function is.
const FUNCTION_FROM: PackedStringArray = ["This brickscript", "A file", "A node"]
## The types a function's input can be (Define Function).
const FUNCTION_INPUT_TYPES: PackedStringArray = ["Number", "Whole", "Text", "Bool", "Vector2", "Vector3", "Color", "Node", "Resource", "List", "Table", "Player", "Anything"]
const LIST_ITEMS_AUTO: String = "Auto"
const LIST_ITEM_CHOICES: PackedStringArray = ["Auto", "Anything", "Number", "Whole", "Text", "Bool", "Vector2", "Vector3", "Color", "Node", "Resource", "List", "Table"]
const MESSAGE_SETTING: Dictionary = {"name": &"message", "kind": "text", "title": "Message", "default": "hello", "required": true,
	"info": "the message's name: a Tell brick and a When brick with the same name go together"}
## Values sent with a message: rows of inputs, received as the List `values`.
const MESSAGE_VALUES: Dictionary = {"inputs": [{"name": &"value", "types": [], "default": ZERO}], "min": 0, "default_count": 1}
const MESSAGE_JOIN: Dictionary = {"open": "[", "row": "{value}", "separator": ", ", "close": "]"}
const TELL_CLIENTS_TO: PackedStringArray = ["All clients", "One client"]
## A Node input that starts as Self (the path "." is the node running the
## brickscript; in a script node, a new brick gets Self.Parent instead:
## Ops.add_node()).
const THIS_NODE: Dictionary = {"type": T.NODE, "value": "."}
## Most node bricks start at the parent instead (the path ".."; user's
## choice, 2026-10-22). Graph files older than format 2 keep "this node"
## where they used the default (BrickFile.from_text()).
const PARENT_NODE: Dictionary = {"type": T.NODE, "value": ".."}
## Export's Shown on: which node's Inspector shows it.
const EXPORT_SHOWN_ON: PackedStringArray = ["This script node", "The node it acts for", "A node"]
const NODE_CLASS_SETTING: Dictionary = {"name": &"node_class", "kind": "node_class", "title": "Type", "default": "",
	"info": "the node's class (e.g. Sprite2D); filled in from your scenes when it can tell"}
const NODE_SCRIPT_SETTING: Dictionary = {"name": &"node_script", "kind": "node_script", "title": "Script", "default": "",
	"info": "the script it runs (a .gd or a brickscript), if any: its variables show up in the property dropdowns"}
## As script: the node if it runs the script (or one extending it), else null.
## As script: the node itself if it runs the script, else its script node
## (a child running it for the node: LocalScript / ServerScript), whose
## variables are the script's.
const AS_SCRIPT_HELPER: String = """func _brickscript_as_script(node: Variant, path: String) -> Node:
	if not is_instance_valid(node) or not node is Node:
		return null
	for candidate: Node in [node as Node] + (node as Node).get_children():
		var script: Script = candidate.get_script()
		while script != null:
			if script.resource_path == path:
				return candidate
			script = script.get_base_script()
	return null"""
## Node bricks compiled by flow_compiler.gd _node_brick() (the physics
## queries too).
const NODE_BRICKS: Array[StringName] = [&"get_node", &"set_property", &"call_method", &"spawn_scene", &"emit_signal", &"wait_for_signal",
	&"find_node", &"get_root", &"find_ancestor", &"get_children", &"nodes_in_group", &"as_script", &"host", &"join", &"bodies_near", &"raycast", &"get_character", &"get_player",
	&"screen_to_world", &"player_aim", &"world_to_screen", &"find_path", &"nearest_character", &"terrain_ray", &"random_open_spot"]
## Physics queries: what they find (index passed to the helpers).
const LOOK_FOR: PackedStringArray = ["Bodies", "Areas", "Bodies and areas"]
## Physics queries: which collision layers they look at (layer numbers,
## e.g. "1, 3"; blank: all).
const LAYERS_SETTING: Dictionary = {"name": &"layers", "kind": "layers", "title": "Layers", "default": "",
	"info": "the collision layers it looks at, as numbers (e.g. 1, 3); blank: all of them"}
const ALL_LAYERS: int = 0xFFFFFFFF
## Raycast's exits: something was hit, or not.
const RAY_EXITS: Array[StringName] = [&"hit", &"missed"]
## Raycast's From / To: world positions, or in a node's own space.
const RAY_RELATIVE: String = "Relative to a node"
const RAY_SPACES: PackedStringArray = ["World positions", RAY_RELATIVE]
const RAY_EXIT_TITLES: Dictionary = {&"hit": "Hit", &"missed": "Nothing hit"}
const LOOK_FOR_SETTING: Dictionary = {"name": &"look_for", "kind": "choice", "title": "Finds", "options": LOOK_FOR, "default": "Bodies",
	"info": "physics bodies (StaticBody, RigidBody, CharacterBody), areas (Area2D / Area3D), or both"}
## Bodies near: what touches a ball (3D) or circle (2D) around a point. A
## radius of 0 checks just the point. The node running the brickscript (in a
## server brickscript, its body) is left out.
const BODIES_NEAR_HELPER: String = """var _brickscript_near_shapes: Dictionary = {}
var _brickscript_near_query_3d: PhysicsShapeQueryParameters3D = null
var _brickscript_near_query_2d: PhysicsShapeQueryParameters2D = null


func _brickscript_bodies_near(at: Variant, radius: float, look_for: int, skip: Node, mask: int) -> Array[Node]:
	# (Untyped: a typed one would copy every hit to check it.)
	var hits: Array = []
	var size: float = maxf(radius, 0.001)
	if at is Vector3:
		if _brickscript_near_query_3d == null:
			_brickscript_near_query_3d = PhysicsShapeQueryParameters3D.new()
		var query: PhysicsShapeQueryParameters3D = _brickscript_near_query_3d
		query.shape = _brickscript_near_shape(size, true)
		query.transform = Transform3D(Basis.IDENTITY, at)
		query.collision_mask = mask
		query.collide_with_bodies = look_for != 1
		query.collide_with_areas = look_for != 0
		query.exclude = [(skip as CollisionObject3D).get_rid()] if skip is CollisionObject3D else []
		hits = get_viewport().find_world_3d().direct_space_state.intersect_shape(query, 64)
	else:
		if _brickscript_near_query_2d == null:
			_brickscript_near_query_2d = PhysicsShapeQueryParameters2D.new()
		var query: PhysicsShapeQueryParameters2D = _brickscript_near_query_2d
		query.shape = _brickscript_near_shape(size, false)
		query.transform = Transform2D(0.0, at)
		query.collision_mask = mask
		query.collide_with_bodies = look_for != 1
		query.collide_with_areas = look_for != 0
		query.exclude = [(skip as CollisionObject2D).get_rid()] if skip is CollisionObject2D else []
		hits = get_viewport().find_world_2d().direct_space_state.intersect_shape(query, 64)
	var found: Array[Node] = []
	var seen: Dictionary = {}
	for hit: Variant in hits:
		var collider: Object = (hit as Dictionary).get("collider")
		if collider is Node and not seen.has(collider):
			seen[collider] = true
			found.append(collider)
	return found


## Bodies near's ball (circle in 2D): one per radius, made once (at most 32:
## a radius from a variable could be new every time).
func _brickscript_near_shape(radius: float, three_d: bool) -> Resource:
	var key: Vector2 = Vector2(radius, 1.0 if three_d else 0.0)
	var shape: Resource = _brickscript_near_shapes.get(key)
	if shape == null:
		if _brickscript_near_shapes.size() >= 32:
			_brickscript_near_shapes.clear()
		if three_d:
			var ball: SphereShape3D = SphereShape3D.new()
			ball.radius = radius
			shape = ball
		else:
			var circle: CircleShape2D = CircleShape2D.new()
			circle.radius = radius
			shape = circle
		_brickscript_near_shapes[key] = shape
	return shape"""
## Raycast: the first thing on the line from -> to (of class `wanted`, if
## given: other things are looked past, up to 16 of them), or null. Leaves
## out the node running the brickscript, like Bodies near. The whole hit
## (position, normal) is kept in _brickscript_ray_hit for the Hit point /
## Normal / Distance names and the Hit / Nothing hit exits ({} when nothing
## was hit).
const RAYCAST_HELPER: String = """var _brickscript_ray_hit: Dictionary = {}
var _brickscript_ray_3d: PhysicsRayQueryParameters3D = null
var _brickscript_ray_2d: PhysicsRayQueryParameters2D = null
var _brickscript_ray_exclude: Array[RID] = []


func _brickscript_raycast(from: Variant, to: Variant, look_for: int, skip: Node, mask: int, wanted: StringName) -> Node:
	_brickscript_ray_exclude.clear()
	if skip is CollisionObject3D:
		_brickscript_ray_exclude.append((skip as CollisionObject3D).get_rid())
	elif skip is CollisionObject2D:
		_brickscript_ray_exclude.append((skip as CollisionObject2D).get_rid())
	var hit: Dictionary = {}
	if from is Vector3:
		if _brickscript_ray_3d == null:
			_brickscript_ray_3d = PhysicsRayQueryParameters3D.new()
		var query: PhysicsRayQueryParameters3D = _brickscript_ray_3d
		query.from = from
		query.to = to
		query.collision_mask = mask
		query.collide_with_bodies = look_for != 1
		query.collide_with_areas = look_for != 0
		var space: PhysicsDirectSpaceState3D = get_viewport().find_world_3d().direct_space_state
		for _try: int in 16:
			query.exclude = _brickscript_ray_exclude
			hit = space.intersect_ray(query)
			if _brickscript_ray_done(hit, wanted):
				break
			hit = {}
	else:
		if _brickscript_ray_2d == null:
			_brickscript_ray_2d = PhysicsRayQueryParameters2D.new()
		var query: PhysicsRayQueryParameters2D = _brickscript_ray_2d
		query.from = from
		query.to = to
		query.collision_mask = mask
		query.collide_with_bodies = look_for != 1
		query.collide_with_areas = look_for != 0
		var space: PhysicsDirectSpaceState2D = get_viewport().find_world_2d().direct_space_state
		for _try: int in 16:
			query.exclude = _brickscript_ray_exclude
			hit = space.intersect_ray(query)
			if _brickscript_ray_done(hit, wanted):
				break
			hit = {}
	_brickscript_ray_hit = hit
	return hit.get("collider") as Node


## A ray's hit that ends the search: nothing, no Type wanted, or one of it.
## Else it's looked past (excluded for the next try).
func _brickscript_ray_done(hit: Dictionary, wanted: StringName) -> bool:
	var collider: Object = hit.get("collider")
	if hit.is_empty() or wanted.is_empty() or (collider != null and collider.is_class(wanted)):
		return true
	_brickscript_ray_exclude.append(hit["rid"])
	return false"""
## Camera bricks: which camera (this screen's current one, or a node), in
## 3D or 2D, and where the screen point comes from.
const CAMERA_NODE: String = "A camera node"
const CAMERA_WHICH: PackedStringArray = ["This screen's camera", CAMERA_NODE]
const CAMERA_WHICH_SETTING: Dictionary = {"name": &"camera_is", "kind": "choice", "title": "Camera", "options": CAMERA_WHICH, "default": "This screen's camera",
	"info": "the screen's current camera (the one you see through), or a Camera3D / Camera2D node (Camera)"}
const CAMERA_INPUT: Dictionary = {"name": &"camera", "types": [T.NODE], "default": {"var": ""}, "shown_when": {"setting": &"camera_is", "value": CAMERA_NODE}, "unused": "null"}
const CAMERA_SPACES: PackedStringArray = ["3D", "2D"]
const CAMERA_SPACE_SETTING: Dictionary = {"name": &"space", "kind": "choice", "title": "World", "options": CAMERA_SPACES, "default": "3D",
	"info": "3D: a ray from the camera through the point (From / To, for Raycast); 2D: the point's world position"}
const SCREEN_POINT: String = "A screen point"
const SCREEN_MIDDLE: String = "The middle of the screen"
const SCREEN_POINT_FROM: PackedStringArray = ["The mouse", SCREEN_POINT, SCREEN_MIDDLE]
## Player Aim: through their mouse, or the middle of their screen (where
## their camera looks: a first-person game with a captured mouse).
const AIM_THROUGH: PackedStringArray = ["The mouse", SCREEN_MIDDLE]
const MOUSE_MODES: Dictionary = {"Visible": "Input.MOUSE_MODE_VISIBLE", "Captured": "Input.MOUSE_MODE_CAPTURED", "Confined": "Input.MOUSE_MODE_CONFINED", "Hidden": "Input.MOUSE_MODE_HIDDEN"}
const RAY_LENGTH_INPUT: Dictionary = {"name": &"length", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 100.0}, "shown_when": {"setting": &"space", "value": "3D"}, "unused": "0.0"}
const RAY_FROM_SETTING: Dictionary = {"name": &"from_name", "kind": "name", "title": "From", "default": "", "suggest": "ray_from",
	"info": "3D: where the ray starts, on the camera (2D: the point too) (blank: not kept)"}
## The camera a camera brick uses: the one given, else this screen's current
## one. null if there's none (an error naming the brick, once per brick).
const CAMERA_HELPER: String = """var _brickscript_camera_reported: Dictionary = {}


func _brickscript_camera(camera: Variant, three_d: bool, brick: String) -> Node:
	var wanted: String = "Camera3D" if three_d else "Camera2D"
	var found: Node = null
	if camera == null:
		found = get_viewport().get_camera_3d() if three_d else get_viewport().get_camera_2d()
	elif is_instance_valid(camera) and (camera as Object).is_class(wanted):
		found = camera
	if found == null and not _brickscript_camera_reported.has(brick):
		_brickscript_camera_reported[brick] = true
		push_error("%s: %s" % [brick, "this screen has no current %s" % wanted if camera == null else "%s isn't a %s" % [camera, wanted]])
	return found"""
## Mouse to World (and Player Aim): 3D: the end of a ray from the camera
## through a screen point (`length` away; its start kept in
## _brickscript_ray_from for the From name); 2D: the point's world position
## (through the canvas transform: where the Camera2D looks).
const SCREEN_TO_WORLD_HELPER: String = """var _brickscript_ray_from: Variant = null


func _brickscript_screen_to_world(camera: Variant, point: Vector2, three_d: bool, length: float, brick: String) -> Variant:
	if not three_d:
		var camera_2d: Node = _brickscript_camera(camera, false, brick) if camera != null else null
		var viewport: Viewport = camera_2d.get_viewport() if camera_2d != null else get_viewport()
		_brickscript_ray_from = viewport.get_canvas_transform().affine_inverse() * point
		return _brickscript_ray_from
	var camera_3d: Camera3D = _brickscript_camera(camera, true, brick) as Camera3D
	if camera_3d == null:
		_brickscript_ray_from = Vector3.ZERO
		return Vector3.ZERO
	_brickscript_ray_from = camera_3d.project_ray_origin(point)
	return _brickscript_ray_from + camera_3d.project_ray_normal(point) * length"""
## Player Aim: a player's mouse (or the middle of their screen) through their
## camera (NetworkEngine API 10 get_player_aim; "eye" / "forward" API 12, on
## the server). This machine's own player (offline, or the host) is read
## here, through this node's screen. (0, 0, 0) until a player's first aim
## arrives. Who "me" is comes from this node's own multiplayer (1 offline),
## cheaper than asking the engine every frame.
const PLAYER_AIM_HELPER: String = """func _brickscript_player_aim(player: int, three_d: bool, length: float, brick: String, middle: bool = false) -> Variant:
	if player == (multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1):
		var point: Vector2 = get_viewport().get_visible_rect().get_center() if middle else get_viewport().get_mouse_position()
		return _brickscript_screen_to_world(null, point, three_d, length, brick)
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	var aim: Dictionary = engine.call(&"get_player_aim", player) if engine != null and engine.has_method(&"get_player_aim") else {}
	if not three_d:
		_brickscript_ray_from = aim.get("point", Vector2.ZERO)
		return _brickscript_ray_from
	_brickscript_ray_from = aim.get("eye" if middle else "origin", Vector3.ZERO)
	return _brickscript_ray_from + aim.get("forward" if middle else "direction", Vector3.ZERO) * length"""
## World to Screen: where a world position shows on the screen (pixels from
## its top left), and whether it's on it (_brickscript_on_screen: in front
## of the camera and inside the screen).
const WORLD_TO_SCREEN_HELPER: String = """var _brickscript_on_screen: bool = false


func _brickscript_world_to_screen(camera: Variant, at: Variant, brick: String) -> Vector2:
	_brickscript_on_screen = false
	if at is Vector3:
		var camera_3d: Camera3D = _brickscript_camera(camera, true, brick) as Camera3D
		if camera_3d == null:
			return Vector2.ZERO
		var shown: Vector2 = camera_3d.unproject_position(at)
		_brickscript_on_screen = not camera_3d.is_position_behind(at) and camera_3d.get_viewport().get_visible_rect().has_point(shown)
		return shown
	var camera_2d: Node = _brickscript_camera(camera, false, brick) if camera != null else null
	var viewport: Viewport = camera_2d.get_viewport() if camera_2d != null else get_viewport()
	var at_2d: Vector2 = at
	var point: Vector2 = viewport.get_canvas_transform() * at_2d
	_brickscript_on_screen = viewport.get_visible_rect().has_point(point)
	return point"""
## Shake Camera: jolts the camera's offset (Camera3D h_offset / v_offset,
## Camera2D offset), fading out, then puts it back. Offsets only, so it
## doesn't fight what moves the camera. A new shake replaces one under way.
## The tween belongs to the camera (nothing of this script runs later).
const SHAKE_HELPER: String = """func _brickscript_shake(camera: Variant, strength: float, duration: float, brick: String) -> void:
	var target: Node = null
	if camera == null:
		target = get_viewport().get_camera_3d()
		if target == null:
			target = get_viewport().get_camera_2d()
	elif is_instance_valid(camera) and (camera is Camera3D or camera is Camera2D):
		target = camera
	if target == null:
		push_error("%s: %s" % [brick, "this screen has no current camera" if camera == null else "%s isn't a Camera3D or Camera2D" % camera])
		return
	var three_d: bool = target is Camera3D
	if target.has_meta(&"_brickscript_shake"):
		(target.get_meta(&"_brickscript_shake") as Tween).kill()
	var base: Vector2 = target.get_meta(&"_brickscript_shake_base") if target.has_meta(&"_brickscript_shake_base") \
		else Vector2(target.get(&"h_offset"), target.get(&"v_offset")) if three_d else target.get(&"offset")
	target.set_meta(&"_brickscript_shake_base", base)
	var tween: Tween = target.create_tween()
	target.set_meta(&"_brickscript_shake", tween)
	var steps: int = maxi(ceili(duration * 30.0), 1)
	for step: int in steps + 1:
		var fade: float = pow(1.0 - float(step) / steps, 2.0)
		var at: Vector2 = base + Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * strength * fade
		if three_d:
			tween.tween_property(target, ^"h_offset", at.x, duration / (steps + 1))
			tween.parallel().tween_property(target, ^"v_offset", at.y, duration / (steps + 1))
		else:
			tween.tween_property(target, ^"offset", at, duration / (steps + 1))
	tween.tween_callback(target.remove_meta.bind(&"_brickscript_shake"))
	tween.tween_callback(target.remove_meta.bind(&"_brickscript_shake_base"))"""
## Animation bricks: an AnimationPlayer, AnimatedSprite2D or AnimatedSprite3D
## (a child "AnimationPlayer" of this node by default) and one of its
## animations.
const ANIMATION_BRICKS: Array[StringName] = [&"play_animation", &"play_ui_animation", &"stop_animation", &"stop_ui_animation"]
const ANIMATION_CLASSES: Array[StringName] = [&"AnimationPlayer", &"AnimatedSprite2D", &"AnimatedSprite3D"]
const ANIMATION_THEN: PackedStringArray = ["Go on at once", "Wait until it ends"]
const ANIMATION_PLAYER_INPUT: Dictionary = {"name": &"player", "types": [T.NODE], "default": {"type": T.NODE, "value": "AnimationPlayer"}}
const ANIMATION_PLAY_INPUTS: Array = [ANIMATION_PLAYER_INPUT, {"name": &"speed", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 1.0}}]
const ANIMATION_PLAY_SETTINGS: Array = [
	{"name": &"animation", "kind": "animation", "title": "Animation", "default": "", "required": true, "target": &"player",
		"info": "one of the node's animations, picked from your scenes (or typed in)"},
	{"name": &"direction", "kind": "choice", "title": "Direction", "options": ["Forwards", "Backwards"], "default": "Forwards",
		"codes": {"Forwards": "false", "Backwards": "true"}, "info": "from the start, or backwards from the end"},
	{"name": &"then", "kind": "choice", "title": "Then", "options": ANIMATION_THEN, "default": "Go on at once",
		"info": "carry on at once, or wait until it ends (a looping animation doesn't wait)"},
]
const ANIMATION_STOP_SETTINGS: Array = [{"name": &"how", "kind": "choice", "title": "How", "options": ["Stop", "Pause"], "default": "Stop",
	"codes": {"Stop": "false", "Pause": "true"}, "info": "stop (back to the start), or pause where it is (playing it again carries on)"}]
## Whether a node can play `animation` (an error naming the brick if not).
const CAN_ANIMATE_HELPER: String = """func _brickscript_can_animate(node: Variant, animation: StringName, brick: String) -> bool:
	if not is_instance_valid(node) or not (node is AnimationPlayer or node is AnimatedSprite2D or node is AnimatedSprite3D):
		push_error("%s: %s can't play animations: it needs an AnimationPlayer, AnimatedSprite2D or AnimatedSprite3D" % [brick, node])
		return false
	var has: bool = (node as AnimationPlayer).has_animation(animation) if node is AnimationPlayer \\
		else node.get(&"sprite_frames") != null and (node.get(&"sprite_frames") as SpriteFrames).has_animation(animation)
	if animation != &"" and not has:
		push_error("%s: %s has no animation '%s'" % [brick, (node as Node).name, animation])
	return has or animation == &""


## Waits until the animation ends (not for a looping one, or one that isn't
## playing).
func _brickscript_animation_end(node: Variant, animation: StringName) -> void:
	if not is_instance_valid(node) or not bool(node.call(&"is_playing")):
		return
	var loops: bool = (node as AnimationPlayer).get_animation(animation).loop_mode != Animation.LOOP_NONE if node is AnimationPlayer \\
		else (node.get(&"sprite_frames") as SpriteFrames).get_animation_loop(animation)
	if not loops:
		await node.animation_finished"""
## Play animation / Stop animation (server): on every machine through the
## Network Context Engine (API 11), here alone without it (single-player).
const PLAY_ANIMATION_HELPER: String = """func _brickscript_play_animation(node: Variant, animation: StringName, speed: float, backwards: bool, brick: String) -> void:
	if not _brickscript_can_animate(node, animation, brick):
		return
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and engine.has_method(&"play_animation"):
		# Godot plays backwards from the end only with a negative speed.
		engine.call(&"play_animation", node, animation, -absf(speed) if backwards else speed, backwards)
	else:
		_brickscript_play_here(node, animation, speed, backwards)


func _brickscript_stop_animation(node: Variant, pause: bool, brick: String) -> void:
	if not _brickscript_can_animate(node, &"", brick):
		return
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and engine.has_method(&"stop_animation"):
		engine.call(&"stop_animation", node, pause)
	else:
		node.call(&"pause" if pause else &"stop")"""
## Playing on this machine only.
## Backwards: from the end with a negative speed (Godot plays backwards only
## then).
const PLAY_HERE_HELPER: String = """func _brickscript_play_here(node: Variant, animation: StringName, speed: float, backwards: bool) -> void:
	var signed: float = -absf(speed) if backwards else speed
	if node is AnimationPlayer:
		(node as AnimationPlayer).play(animation, -1.0, signed, backwards)
	else:
		node.call(&"play", animation, signed, backwards)"""
## Tween property: how it moves (Godot's transitions, Roblox's easing
## styles) and which end the easing is at.
const TWEEN_EASINGS: Dictionary = {"Linear": "Tween.TRANS_LINEAR", "Sine": "Tween.TRANS_SINE", "Quad": "Tween.TRANS_QUAD", "Cubic": "Tween.TRANS_CUBIC",
	"Quart": "Tween.TRANS_QUART", "Quint": "Tween.TRANS_QUINT", "Expo": "Tween.TRANS_EXPO", "Circ": "Tween.TRANS_CIRC", "Back": "Tween.TRANS_BACK",
	"Bounce": "Tween.TRANS_BOUNCE", "Elastic": "Tween.TRANS_ELASTIC", "Spring": "Tween.TRANS_SPRING"}
const TWEEN_DIRECTIONS: Dictionary = {"In": "Tween.EASE_IN", "Out": "Tween.EASE_OUT", "In-Out": "Tween.EASE_IN_OUT", "Out-In": "Tween.EASE_OUT_IN"}
## (Their names, in that order, for the dropdowns.)
const TWEEN_EASING_NAMES: PackedStringArray = ["Linear", "Sine", "Quad", "Cubic", "Quart", "Quint", "Expo", "Circ", "Back", "Bounce", "Elastic", "Spring"]
const TWEEN_DIRECTION_NAMES: PackedStringArray = ["In", "Out", "In-Out", "Out-In"]
## What can be tweened: numbers, vectors, colors.
const TWEEN_TYPES: Array[int] = [T.NUMBER, T.WHOLE, T.VECTOR2, T.VECTOR3, T.COLOR]
## Tween property / Stop tweens: a server brickscript's on every machine
## through the Network Context Engine (API 17); a local brickscript's (and
## without the engine) on this machine. A new tween of a property replaces
## the one running on it.
const TWEEN_HELPER: String = """func _brickscript_tween(node: Variant, property: StringName, to: Variant, seconds: float, transition: int, easing: int, repeats: int, reverses: bool, everywhere: bool, brick: String) -> Tween:
	if not is_instance_valid(node) or not node is Node:
		push_error("%s: there's no node to tween (%s)" % [brick, node])
		return null
	if not property in node:
		push_error("%s: %s has no property %s" % [brick, (node as Node).name, property])
		return null
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if everywhere and engine != null and engine.has_method(&"tween_property"):
		return engine.call(&"tween_property", node, property, to, seconds, transition, easing, repeats, reverses) as Tween
	var tweens: Dictionary = node.get_meta(&"_brickscript_tweens") if node.has_meta(&"_brickscript_tweens") else {}
	if tweens.get(property) is Tween and (tweens[property] as Tween).is_valid():
		(tweens[property] as Tween).kill()
	var from: Variant = node.get(property)
	var made: Tween = (node as Node).create_tween()
	made.set_trans(transition as Tween.TransitionType).set_ease(easing as Tween.EaseType)
	# Godot counts every round; 0 is forever.
	made.set_loops(0 if repeats < 0 else repeats + 1)
	made.tween_property(node, NodePath(property), to, maxf(seconds, 0.001)).from(from)
	if reverses:
		made.tween_property(node, NodePath(property), from, maxf(seconds, 0.001))
	tweens[property] = made
	node.set_meta(&"_brickscript_tweens", tweens)
	return made


## Waits until a tween ends (or is stopped); not for one that repeats forever.
func _brickscript_tween_end(tween: Tween) -> void:
	if tween == null or not tween.is_valid() or tween.get_loops_left() < 0:
		return
	while tween.is_valid():
		await get_tree().process_frame


func _brickscript_stop_tweens(node: Variant, everywhere: bool, brick: String) -> void:
	if not is_instance_valid(node) or not node is Node:
		push_error("%s: there's no node to stop (%s)" % [brick, node])
		return
	if node.has_meta(&"_brickscript_tweens"):
		for running: Variant in (node.get_meta(&"_brickscript_tweens") as Dictionary).values():
			if running is Tween and (running as Tween).is_valid():
				(running as Tween).kill()
		node.remove_meta(&"_brickscript_tweens")
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if everywhere and engine != null and engine.has_method(&"stop_tweens"):
		engine.call(&"stop_tweens", node)"""
## Play UI animation / Stop UI animation (local): only on this machine, and
## only if everything the animation animates is local-only (UI, cameras,
## sounds, particles, this script's effects): each of an AnimationPlayer's
## tracks is checked; an animated sprite must be local-only itself.
const UI_ANIMATION_HELPER: String = """func _brickscript_ui_animation_ok(node: Variant, animation: StringName, brick: String) -> bool:
	if not node is AnimationPlayer:
		return _brickscript_local_only(node, brick)
	var player: AnimationPlayer = node
	var clip: Animation = player.get_animation(animation if animation != &"" else player.assigned_animation) if player.has_animation(animation if animation != &"" else player.assigned_animation) else null
	var root: Node = player.get_node_or_null(player.root_node)
	if clip == null or root == null:
		return true
	for track: int in clip.get_track_count():
		var target: Node = root.get_node_or_null(NodePath(String(clip.track_get_path(track).get_concatenated_names())))
		if target != null and not _brickscript_local_only(target, "%s (animation %s)" % [brick, clip.resource_name if not clip.resource_name.is_empty() else String(animation)]):
			return false
	return true


func _brickscript_play_ui_animation(node: Variant, animation: StringName, speed: float, backwards: bool, brick: String) -> void:
	if _brickscript_can_animate(node, animation, brick) and _brickscript_ui_animation_ok(node, animation, brick):
		_brickscript_play_here(node, animation, speed, backwards)


func _brickscript_stop_ui_animation(node: Variant, pause: bool, brick: String) -> void:
	if _brickscript_can_animate(node, &"", brick) and _brickscript_ui_animation_ok(node, &"", brick):
		node.call(&"pause" if pause else &"stop")"""
## A character's settings (BrickscriptCharacter3D / 2D: a 2D one has only
## Walk speed, Jump power, Gravity, Health and Max health). Set property
## (Set / Add) of one of them on a character go through its change():
## to the machine that moves it; Health and Max health only from the server.
const CHARACTER_PROPERTIES: PackedStringArray = ["walk_speed", "jump_power", "gravity", "health", "max_health",
	"eye_height", "mouse_sensitivity", "field_of_view", "capture_mouse"]
const CHARACTER_SERVER_PROPERTIES: PackedStringArray = ["health", "max_health"]
## The scripts of the character nodes (and the classes they declare).
const CHARACTER_SCRIPTS: PackedStringArray = ["res://addons/brickscript/runtime/character_3d.gd", "res://addons/brickscript/runtime/character_2d.gd"]
## Get Character's From and Get Player's From.
const CHARACTER_FROM: PackedStringArray = ["A player", "A user ID"]
const PLAYER_FROM: PackedStringArray = ["A character", "A user ID"]
const CHARACTER_HELPER: String = """## The character a node is or is inside of (a script node's body, a part).
func _brickscript_character_node(of: Variant, brick: String) -> Node:
	var at: Node = of as Node if is_instance_valid(of) else null
	while at != null:
		if at.has_method(&"change") and at.has_method(&"is_mine"):
			return at
		at = at.get_parent()
	push_error("%s: %s isn't a character (use a Character3D / Character2D node: BrickscriptCharacter3D / 2D)" % [brick, of])
	return null


## Set property (Set / Add) of a character's setting: on its player's machine
## at once; from the server, to that machine (the server's copy too, so its
## speed limit follows).
func _brickscript_set_character(of: Variant, property: StringName, value: Variant, seconds: float, brick: String) -> void:
	var character: Node = _brickscript_character_node(of, brick)
	if character != null:
		character.call(&"change", property, value, seconds)
"""
## Damage / Heal / Kill character / Remove character (server): the character
## node's own methods (it tells every machine). `by`: the player's number (0:
## nobody).
const HEALTH_HELPER: String = """func _brickscript_damage(of: Variant, amount: float, by: int, brick: String) -> void:
	var character: Node = _brickscript_character_node(of, brick)
	if character != null:
		character.call(&"damage", amount, by)


func _brickscript_heal(of: Variant, amount: float, brick: String) -> void:
	var character: Node = _brickscript_character_node(of, brick)
	if character != null:
		character.call(&"heal", amount)


func _brickscript_kill(of: Variant, by: int, brick: String) -> void:
	var character: Node = _brickscript_character_node(of, brick)
	if character != null:
		character.call(&"kill", by)


func _brickscript_remove_character(of: Variant, brick: String) -> void:
	var character: Node = _brickscript_character_node(of, brick)
	if character != null:
		character.call(&"remove")"""
## When character died: a dying character calls every brickscript in the
## group (on every machine); each event hears it through the script's own
## signal, filtered by its Whose (0 any, 1 this node's, 2 my player's).
const DIED_HELPER: String = """signal _brickscript_character_died(character: Node, player: int, killer: int)


func _brickscript_hear_deaths(callback: Callable, whose: int, node: Node) -> void:
	add_to_group(&"brickscript_death_listeners")
	_brickscript_character_died.connect(func(character: Node, player: int, killer: int) -> void:
		if whose == 0 or (whose == 1 and is_instance_valid(node) and (character == node or character.is_ancestor_of(node))) or (whose == 2 and _brickscript_is_my_peer(player)):
			callback.call(character, player, killer))


## Called by a dying character (BrickscriptCharacter3D / 2D).
func _brickscript_on_character_death(character: Node, player: int, killer: int) -> void:
	_brickscript_character_died.emit(character, player, killer)


func _brickscript_is_my_peer(player: int) -> bool:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or not engine.has_method(&"get_local_peer_id"):
		return player == 1
	return int(engine.call(&"get_local_peer_id")) == player"""
## Is culled here / When culled or shown: the Cull Throttle Engine (Plugin 3,
## API 3), called by method name; without it nothing is ever culled.
const CULL_HELPER: String = """func _brickscript_cull_engine() -> Node:
	var engine: Node = get_node_or_null(^"/root/CullThrottleEngine") if is_inside_tree() else null
	if engine == null or not engine.has_method(&"get_api_version") or int(engine.call(&"get_api_version")) < 3:
		return null
	return engine


func _brickscript_is_culled_here(node: Node) -> bool:
	var engine: Node = _brickscript_cull_engine()
	return engine != null and is_instance_valid(node) and bool(engine.call(&"is_culled_here", node))


## Each When culled / shown: [callback, which (0 culled or shown, 1 culled,
## 2 shown), whose (the node, its object; null: any)]. One connection for
## them all (a method bound twice is one connection to Godot).
var _brickscript_culling: Array[Array] = []


func _brickscript_hear_culling(callback: Callable, which: int, whose: Node) -> void:
	var engine: Node = _brickscript_cull_engine()
	if engine == null:
		return
	_brickscript_culling.append([callback, which, whose])
	if not engine.is_connected(&"culled_here_changed", _brickscript_on_culling):
		engine.connect(&"culled_here_changed", _brickscript_on_culling)


func _brickscript_on_culling(node: Node3D, culled: bool) -> void:
	var engine: Node = _brickscript_cull_engine()
	for listener: Array in _brickscript_culling:
		var which: int = listener[1]
		if (which == 1 and not culled) or (which == 2 and culled):
			continue
		var whose: Node = listener[2]
		if whose != null and (not is_instance_valid(whose) or engine == null or engine.call(&"object_of", whose) != node):
			continue
		(listener[0] as Callable).call(node, culled)"""
## The Mesh bricks: what's added collects on the MeshInstance3D until Finish
## mesh builds it (runtime/meshes.gd, by path: no class_name to register).
const MESH_HELPER: String = """const _BrickscriptMeshes = preload("res://addons/brickscript/runtime/meshes.gd")


func _brickscript_mesh_node(mesh: Variant, brick: String) -> MeshInstance3D:
	if is_instance_valid(mesh) and mesh is MeshInstance3D:
		return mesh as MeshInstance3D
	var given: String = "nothing"
	if is_instance_valid(mesh) and mesh is Node:
		given = "%s (a %s)" % [(mesh as Node).name, (mesh as Node).get_class()]
	push_error("%s: needs a MeshInstance3D, not %s" % [brick, given])
	return null


func _brickscript_mesh_begin(mesh: Variant, brick: String) -> void:
	var node: MeshInstance3D = _brickscript_mesh_node(mesh, brick)
	if node != null:
		_BrickscriptMeshes.begin(node)


func _brickscript_mesh_add(mesh: Variant, step: Array, brick: String) -> void:
	var node: MeshInstance3D = _brickscript_mesh_node(mesh, brick)
	if node != null:
		_BrickscriptMeshes.add_step(node, step)


## A server brickscript's mesh goes to every machine (Network Context Engine
## API 20, node data), players who join later too.
func _brickscript_mesh_finish(mesh: Variant, smooth: bool, both_sides: bool, everywhere: bool, brick: String) -> void:
	var node: MeshInstance3D = _brickscript_mesh_node(mesh, brick)
	if node == null:
		return
	var steps: Array = _BrickscriptMeshes.take_steps(node)
	node.mesh = _BrickscriptMeshes.build(steps, smooth, both_sides)
	if everywhere:
		_brickscript_mesh_share(node, _BrickscriptMeshes.RECIPE_KEY, [steps, smooth, both_sides])
		_brickscript_mesh_share(node, _BrickscriptMeshes.POINTS_KEY, null)
		_brickscript_mesh_share(node, _BrickscriptMeshes.COLORS_KEY, null)


func _brickscript_mesh_share(node: MeshInstance3D, key: StringName, value: Variant) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null and engine.has_method(&"set_node_data") and bool(engine.call(&"has_server_authority")):
		engine.call(&"set_node_data", node, key, value)


func _brickscript_mesh_points(mesh: Variant, brick: String) -> Array[Vector3]:
	var node: MeshInstance3D = _brickscript_mesh_node(mesh, brick)
	return _BrickscriptMeshes.points(node) if node != null else [] as Array[Vector3]


func _brickscript_mesh_colors(mesh: Variant, brick: String) -> Array[Color]:
	var node: MeshInstance3D = _brickscript_mesh_node(mesh, brick)
	return _BrickscriptMeshes.colors(node) if node != null else [] as Array[Color]


func _brickscript_mesh_set(mesh: Variant, values: Array, as_colors: bool, everywhere: bool, brick: String) -> void:
	var node: MeshInstance3D = _brickscript_mesh_node(mesh, brick)
	if node == null:
		return
	var problem: String = _BrickscriptMeshes.set_points(node, values, as_colors)
	if not problem.is_empty():
		push_error("%s: %s" % [brick, problem])
	elif everywhere:
		_brickscript_mesh_share(node, _BrickscriptMeshes.COLORS_KEY if as_colors else _BrickscriptMeshes.POINTS_KEY,
			PackedColorArray(values) if as_colors else PackedVector3Array(values))"""
## The MeshInstance3D a Mesh brick works on (checked when its Type is known).
const MESH_INPUT: Dictionary = {"name": &"mesh", "types": [T.NODE], "default": PARENT_NODE, "node_class": &"MeshInstance3D"}
const MESH_COLOR_INPUT: Dictionary = {"name": &"color", "types": [T.COLOR], "default": {"type": T.COLOR, "value": Color.WHITE}}
## Add shape's Shape (runtime/meshes.gd Shape).
const MESH_SHAPES: Dictionary = {"Box": "0", "Sphere": "1", "Cylinder": "2", "Plane": "3"}
const MESH_SHAPE_NAMES: PackedStringArray = ["Box", "Sphere", "Cylinder", "Plane"]
## Mesh vertices' Mode and Of.
const MESH_MODES: PackedStringArray = ["Get", "Set"]
const MESH_POINTS_OF: PackedStringArray = ["Positions", "Colors"]
## When culled / shown's When and Whose.
const CULL_WHICH: PackedStringArray = ["Culled or shown", "Culled", "Shown"]
const CULL_WHOSE: PackedStringArray = ["This node", "Any node"]
## When character died's Whose.
const DIED_WHOSE: PackedStringArray = ["Any character", "This node's character", "My character"]
## Walk to's exits (by BrickscriptCharacter3D.WalkEnd: 0, 1, 2).
const WALK_EXITS: Array[StringName] = [&"arrived", &"unreachable", &"stopped"]
const WALK_EXIT_TITLES: Dictionary = {&"arrived": "Arrived", &"unreachable": "Can't reach", &"stopped": "Stopped"}
## Walk to / Follow / Stop walking (server): the character's own walk_to(),
## follow(), stop_walking() (BrickscriptCharacter3D, Controlled by Script).
const WALK_HELPER: String = """var _brickscript_walked: int = 0


func _brickscript_walker(who: Variant, brick: String) -> Node:
	var character: Node = _brickscript_character_node(who, brick)
	if character != null and not character.has_method(&"walk_to"):
		push_error("%s: %s can't walk to places (a Character3D can)" % [brick, character.name])
		return null
	return character


## How it ended: 0 Arrived, 1 Can't reach, 2 Stopped (Character3D.WalkEnd).
func _brickscript_walk_to(who: Variant, to: Variant, within: float, brick: String) -> int:
	var character: Node = _brickscript_walker(who, brick)
	if character == null:
		await get_tree().physics_frame
		return 1
	return int(await character.call(&"walk_to_end", to, within))


func _brickscript_follow(who: Variant, target: Variant, distance: float, brick: String) -> void:
	var character: Node = _brickscript_walker(who, brick)
	if character == null:
		return
	if not target is Node3D or not is_instance_valid(target):
		push_error("%s: %s isn't a 3D node to follow" % [brick, target])
		return
	character.call(&"follow", target, distance)


func _brickscript_stop_walking(who: Variant, brick: String) -> void:
	var character: Node = _brickscript_walker(who, brick)
	if character != null:
		character.call(&"stop_walking")"""
## The senses' places: a node, or its closest 3D ancestor (a script node's
## body), or null.
const PLACE_HELPER: String = """func _brickscript_place_node(of: Variant) -> Node3D:
	var at: Node = of as Node if is_instance_valid(of) else null
	while at != null and not at is Node3D:
		at = at.get_parent()
	return at as Node3D"""
## Can see's exits.
const SEE_EXITS: Array[StringName] = [&"seen", &"unseen"]
const SEE_EXIT_TITLES: Dictionary = {&"seen": "Seen", &"unseen": "Not seen"}
## Can see: from a node's eyes (a character's Head; else the node itself),
## within Range, inside its View (degrees across, about where the eyes face:
## -Z; 360: all round), and nothing in the way (a ray on every layer, past
## the looker's own character; what it hits counts as seen when it's the
## target, inside it, or holds it).
const CAN_SEE_HELPER: String = """var _brickscript_seen: bool = false


func _brickscript_can_see(who: Variant, target: Variant, reach: float, view: float, brick: String) -> bool:
	var looker: Node3D = _brickscript_place_node(who)
	if looker == null:
		push_error("%s: %s isn't a 3D node to look from" % [brick, who])
		return false
	var target_node: Node3D = null
	var at: Vector3 = Vector3.ZERO
	if target is Vector3:
		at = target
	elif _brickscript_place_node(target) != null:
		target_node = _brickscript_place_node(target)
		at = target_node.global_position
	else:
		push_error("%s: %s isn't a place to see (a Vector3 or a 3D node)" % [brick, target])
		return false
	var eyes: Node3D = looker
	var skip: Array[RID] = []
	var holder: Node = looker
	while holder != null:
		if holder is CollisionObject3D:
			skip.append((holder as CollisionObject3D).get_rid())
		if holder.has_method(&"walk_to"):
			var head: Node3D = holder.get(&"head") as Node3D
			eyes = head if is_instance_valid(head) and (eyes == looker or not head.is_ancestor_of(eyes)) else eyes
			break
		holder = holder.get_parent()
	var from: Vector3 = eyes.global_position
	var way: Vector3 = at - from
	if way.length() > reach:
		return false
	if view < 360.0 and way.length_squared() > 0.000001 and rad_to_deg((-eyes.global_basis.z).angle_to(way)) > view * 0.5:
		return false
	var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, at, 0xFFFFFFFF, skip)
	var hit: Dictionary = looker.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():
		return true
	var collider: Node = hit.get("collider") as Node
	return target_node != null and collider != null and (collider == target_node or target_node.is_ancestor_of(collider) or collider.is_ancestor_of(target_node))"""
## Nearest character's Among.
const NEAREST_AMONG: PackedStringArray = ["Players' characters", "All characters"]
## Nearest character: the closest Character3D (in the group every character
## is in, in this 3D world) to a place; not the node measured from or the
## character it's in, not dead ones; within Range (0: any). Its distance in
## _brickscript_nearest_distance (-1: none).
const NEAREST_HELPER: String = """var _brickscript_nearest_distance: float = -1.0


func _brickscript_nearest(from: Variant, players_only: bool, reach: float, brick: String) -> Node3D:
	_brickscript_nearest_distance = -1.0
	var at: Vector3 = Vector3.ZERO
	var skip: Node = null
	if from is Vector3:
		at = from
	elif _brickscript_place_node(from) != null:
		skip = _brickscript_place_node(from)
		at = (skip as Node3D).global_position
	else:
		push_error("%s: %s isn't a place (a Vector3 or a 3D node)" % [brick, from])
		return null
	var world: World3D = get_viewport().find_world_3d()
	var best: Node3D = null
	var best_distance: float = INF
	for found: Node in get_tree().get_nodes_in_group(&"brickscript_characters"):
		var character: Node3D = found as Node3D
		if character == null or character == skip or (skip != null and character.is_ancestor_of(skip)) or character.get_world_3d() != world:
			continue
		if players_only and int(character.get(&"controlled_by")) != 0 or character.call(&"is_dead"):
			continue
		var distance: float = at.distance_to(character.global_position)
		if distance < best_distance and (reach <= 0.0 or distance <= reach):
			best = character
			best_distance = distance
	if best != null:
		_brickscript_nearest_distance = best_distance
	return best"""
## Random reachable spot: a random point on the navigation within Radius
## (flat) of a place that a path from there gets to (up to 10 tries, then
## the closest navigation point to it); no navigation area (or not ready
## yet): a random point in the circle at its height. On Terrain: a random
## point in the circle on the Terrain's ground (TERRAIN_HELPER).
const RANDOM_SPOT_HELPER: String = """func _brickscript_random_spot(around: Variant, radius: float, brick: String, on: int = 0, given: Variant = null) -> Vector3:
	var center: Vector3 = Vector3.ZERO
	if around is Vector3:
		center = around
	elif _brickscript_place_node(around) != null:
		center = _brickscript_place_node(around).global_position
	else:
		push_error("%s: %s isn't a place (a Vector3 or a 3D node)" % [brick, around])
		return center
	if on == 1:
		return _brickscript_terrain_spot(center, radius, given, brick)
	var map: RID = get_viewport().find_world_3d().navigation_map
	var ready: bool = NavigationServer3D.map_get_iteration_id(map) != 0 and NavigationServer3D.map_get_closest_point_owner(map, center).is_valid()
	if not ready and on == 2:
		# Navigation, else Terrain: no navigation there (yet).
		return _brickscript_terrain_spot(center, radius, given, brick)
	if not ready:
		var turn: float = randf() * TAU
		return center + Vector3(cos(turn), 0.0, sin(turn)) * radius * sqrt(randf())
	var start: Vector3 = NavigationServer3D.map_get_closest_point(map, center)
	for attempt: int in 10:
		var turn: float = randf() * TAU
		var spot: Vector3 = NavigationServer3D.map_get_closest_point(map, center + Vector3(cos(turn), 0.0, sin(turn)) * radius * sqrt(randf()))
		if Vector2(spot.x - center.x, spot.z - center.z).length() > radius:
			continue
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map, start, spot, true)
		if not path.is_empty() and path[-1].distance_to(spot) < 0.3:
			return spot
	return start"""
## Terrain height / Has ground at / Random reachable spot On Terrain: the
## scene's Terrain (the Terrain Engine plugin: a node in its group
## terrain_engine_terrains, called by method name; the first in this
## brickscript's 3D world, else the first anywhere: a SubViewport's scene has
## its own); without one the spot's own height, no ground, a spot in the
## circle.
const TERRAIN_HELPER: String = """func _brickscript_terrain(given: Variant = null, brick: String = "") -> Node3D:
	if given != null:
		# (The brick's Terrain input: a Terrain node, else an error.)
		if is_instance_valid(given) and given is Node3D and (given as Node3D).has_method(&"height_at"):
			return given
		push_error("%s: %s isn't a Terrain (the Terrain Engine plugin's node)" % [brick, given])
		return null
	if not is_inside_tree():
		return null
	var mine: World3D = get_viewport().find_world_3d() if get_viewport() != null else null
	var any: Node3D = null
	for found: Node in get_tree().get_nodes_in_group(&"terrain_engine_terrains"):
		if found is Node3D and found.has_method(&"height_at"):
			if (found as Node3D).get_world_3d() == mine:
				return found
			if any == null:
				any = found
	return any


func _brickscript_terrain_place(at: Variant, brick: String) -> Variant:
	if at is Vector3:
		return at
	if _brickscript_place_node(at) != null:
		return _brickscript_place_node(at).global_position
	push_error("%s: %s isn't a place (a Vector3 or a 3D node)" % [brick, at])
	return null


func _brickscript_terrain_height(at: Variant, brick: String, given: Variant = null) -> float:
	var spot: Variant = _brickscript_terrain_place(at, brick)
	if spot == null:
		return 0.0
	var terrain: Node3D = _brickscript_terrain(given, brick)
	var ground: float = float(terrain.call(&"height_at", spot)) if terrain != null else NAN
	return (spot as Vector3).y if is_nan(ground) else ground


func _brickscript_has_ground(at: Variant, brick: String, given: Variant = null) -> bool:
	var spot: Variant = _brickscript_terrain_place(at, brick)
	var terrain: Node3D = _brickscript_terrain(given, brick)
	return spot != null and terrain != null and bool(terrain.call(&"has_ground_at", spot))


func _brickscript_terrain_spot(center: Vector3, radius: float, given: Variant = null, brick: String = "") -> Vector3:
	var terrain: Node3D = _brickscript_terrain(given, brick)
	for attempt: int in 10:
		var turn: float = randf() * TAU
		var spot: Vector3 = center + Vector3(cos(turn), 0.0, sin(turn)) * radius * sqrt(randf())
		if terrain == null:
			return spot
		var ground: float = float(terrain.call(&"height_at", spot))
		if not is_nan(ground):
			spot.y = ground
			return spot
	return center"""
## The Terrain Engine's node script: a Terrain input's and When terrain
## ready's node type (when the plugin is there; the bricks still call it by
## method name, so Brickscript works without it).
const TERRAIN_SCRIPT: String = "res://addons/terrain_engine/runtime/terrain.gd"
## Every terrain brick's Terrain (2026-11-02, user: "a selectable terrain
## node type"): a Terrain node (its picker lists the scenes' Terrains); left
## blank, the scene's first Terrain, as before the input existed.
const TERRAIN_INPUT: Dictionary = {"name": &"terrain", "types": [T.NODE], "default": {"type": T.NODE, "value": ""}, "blank": "null", "node_script": TERRAIN_SCRIPT,
	"placeholder": "blank: the scene's Terrain"}
## Biome at / Solid at / Build / Clear terrain / Terrain ray (2026-11-02).
const TERRAIN_MORE_HELPER: String = """var _brickscript_terrain_hit: Dictionary = {}


func _brickscript_terrain_or_error(given: Variant, brick: String) -> Node3D:
	var terrain: Node3D = _brickscript_terrain(given, brick)
	if terrain == null and given == null and not _brickscript_terrain_missing.has(brick):
		_brickscript_terrain_missing[brick] = true
		push_error("%s: there's no Terrain in the scene (the Terrain Engine plugin)" % brick)
	return terrain


func _brickscript_biome_at(given: Variant, at: Variant, brick: String) -> String:
	var spot: Variant = _brickscript_terrain_place(at, brick)
	var terrain: Node3D = _brickscript_terrain_or_error(given, brick)
	return str(terrain.call(&"biome_at", spot)) if spot != null and terrain != null else ""


func _brickscript_solid_at(given: Variant, at: Variant, brick: String) -> bool:
	var spot: Variant = _brickscript_terrain_place(at, brick)
	var terrain: Node3D = _brickscript_terrain_or_error(given, brick)
	return spot != null and terrain != null and bool(terrain.call(&"solid_at", spot))


func _brickscript_build_terrain(given: Variant, seed_mode: int, new_seed: int, brick: String) -> void:
	var terrain: Node3D = _brickscript_terrain_or_error(given, brick)
	if terrain == null:
		return
	if seed_mode == 1:
		terrain.set(&"world_seed", randi())
	elif seed_mode == 2:
		terrain.set(&"world_seed", new_seed)
	terrain.call(&"build")


func _brickscript_clear_terrain(given: Variant, brick: String) -> void:
	var terrain: Node3D = _brickscript_terrain_or_error(given, brick)
	if terrain != null:
		terrain.call(&"clear_world")


## {hit, position (To when it doesn't), normal}.
func _brickscript_terrain_ray(given: Variant, from: Variant, to: Variant, brick: String) -> Dictionary:
	var start: Variant = _brickscript_terrain_place(from, brick)
	var end: Variant = _brickscript_terrain_place(to, brick)
	var terrain: Node3D = _brickscript_terrain_or_error(given, brick)
	var found: Dictionary = {}
	if start != null and end != null and terrain != null:
		found = terrain.call(&"raycast", start, end)
	if found.is_empty():
		return {"hit": false, "position": end if end != null else Vector3.ZERO, "normal": Vector3.ZERO}
	return {"hit": true, "position": found["position"], "normal": found["normal"]}"""
## Random open spot (2026-11-02, user): a spot in open space (a cave, the
## air) within a height range, from the Terrain's shape; with nodes, also
## clear of other bodies (their collision).
const OPEN_SPOT_HELPER: String = """var _brickscript_open_spot: Dictionary = {}


## {found, position}: up to `tries` random spots within `radius` (flat) of
## `around`, between `low` and `high` (world y, or blocks under the surface
## when `by_depth`), with `room` meters of open space around (On a floor:
## above the floor, the position the floor itself).
func _brickscript_random_open_spot(given: Variant, around: Variant, radius: float, low: float, high: float, room: float, tries: int,
		on_floor: bool, by_depth: bool, with_nodes: bool, brick: String) -> Dictionary:
	var center: Variant = _brickscript_terrain_place(around, brick)
	var terrain: Node3D = _brickscript_terrain_or_error(given, brick)
	var none: Dictionary = {"found": false, "position": center if center != null else Vector3.ZERO}
	if center == null or terrain == null:
		return none
	room = maxf(room, 0.1)
	var lowest: float = minf(low, high)
	var highest: float = maxf(low, high)
	for attempt: int in maxi(tries, 1):
		var turn: float = randf() * TAU
		var spot: Vector3 = (center as Vector3) + Vector3(cos(turn), 0.0, sin(turn)) * radius * sqrt(randf())
		var top: float = float(terrain.call(&"height_at", spot))
		if is_nan(top):
			# (Outside a Fixed world's edges.)
			continue
		var picked: float = randf_range(lowest, highest)
		spot.y = top - picked if by_depth else picked
		var middle: Vector3 = spot
		if on_floor:
			# Down to the range's bottom: the first floor (a ray starting in
			# rock goes on through it into the cave under it).
			var bottom: float = top - highest if by_depth else lowest
			var hit: Dictionary = terrain.call(&"raycast", spot + Vector3(0.0, room, 0.0), Vector3(spot.x, bottom, spot.z))
			if hit.is_empty() or (hit["normal"] as Vector3).y < 0.5:
				continue
			spot = hit["position"]
			middle = spot + Vector3(0.0, room + 0.05, 0.0)
		if not _brickscript_open_around(terrain, middle, room):
			continue
		if with_nodes and not _brickscript_clear_of_nodes(terrain, middle, room):
			continue
		return {"found": true, "position": spot}
	return none


## Whether the ground leaves `room` meters open around a point (it and 6
## points that far along each axis).
func _brickscript_open_around(terrain: Node3D, middle: Vector3, room: float) -> bool:
	for offset: Vector3 in [Vector3.ZERO, Vector3(room, 0, 0), Vector3(-room, 0, 0), Vector3(0, room, 0), Vector3(0, -room, 0), Vector3(0, 0, room), Vector3(0, 0, -room)]:
		if bool(terrain.call(&"solid_at", middle + offset)):
			return false
	return true


## Whether no body but the Terrain's ground is within `room` of a point
## (their collision: only where it's in place).
func _brickscript_clear_of_nodes(terrain: Node3D, middle: Vector3, room: float) -> bool:
	var ball: SphereShape3D = SphereShape3D.new()
	ball.radius = room
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = ball
	query.transform = Transform3D(Basis.IDENTITY, middle)
	query.collide_with_areas = false
	for found: Dictionary in terrain.get_world_3d().direct_space_state.intersect_shape(query, 16):
		if found.get("collider") != terrain:
			return false
	return true"""
## Random open spot's exits, Must be, Height is and Checks.
const OPEN_SPOT_EXITS: Array[StringName] = [&"found", &"none"]
const OPEN_SPOT_EXIT_TITLES: Dictionary = {&"found": "Found", &"none": "None found"}
const OPEN_SPOT_MUST_BE: PackedStringArray = ["In the air", "On a floor"]
const OPEN_SPOT_HEIGHT_IS: PackedStringArray = ["World Y", "Depth under the surface"]
const OPEN_SPOT_CHECKS: PackedStringArray = ["Terrain", "Terrain + nodes"]
## Build terrain's Seed: keep the Terrain's, a random one, or one given.
const TERRAIN_SEEDS: PackedStringArray = ["Keep it", "A random one", "This one"]
## Terrain ray's exits: it met the ground, or not.
const TERRAIN_RAY_EXITS: Array[StringName] = [&"hit", &"missed"]
const TERRAIN_RAY_EXIT_TITLES: Dictionary = {&"hit": "Hit ground", &"missed": "No ground"}
## When terrain cleared: every Terrain's cleared (clear_world(); on a client
## the server's), the ones there now and the ones added later.
const TERRAIN_CLEARED_HELPER: String = """var _brickscript_cleared_listeners: Array[Callable] = []


func _brickscript_on_terrain_cleared(callback: Callable) -> void:
	_brickscript_cleared_listeners.append(callback)
	for terrain: Node in get_tree().get_nodes_in_group(&"terrain_engine_terrains"):
		_brickscript_hook_cleared(terrain, callback)
	if not get_tree().node_added.is_connected(_brickscript_cleared_terrain_added):
		get_tree().node_added.connect(_brickscript_cleared_terrain_added)


func _brickscript_cleared_terrain_added(node: Node) -> void:
	for callback: Callable in _brickscript_cleared_listeners:
		_brickscript_hook_cleared(node, callback)


func _brickscript_hook_cleared(terrain: Node, callback: Callable) -> void:
	if not terrain.is_in_group(&"terrain_engine_terrains") or not terrain.has_signal(&"cleared"):
		return
	if terrain is Node3D and get_viewport() != null and get_viewport().find_world_3d() != null and (terrain as Node3D).get_world_3d() != get_viewport().find_world_3d():
		return
	var heard: Callable = callback.bind(terrain)
	if not terrain.is_connected(&"cleared", heard):
		terrain.connect(&"cleared", heard)"""
## Dig / Fill / Paint terrain (server): the scene's Terrain changes its
## ground in a ball and sends it to every machine (late joiners too); kept
## for the session. Without a Terrain: an error, once per brick.
const TERRAIN_CHANGE_HELPER: String = """var _brickscript_terrain_missing: Dictionary = {}


func _brickscript_change_terrain(method: StringName, at: Variant, size: float, strength: float, color: Color, brick: String, given: Variant = null) -> void:
	var spot: Variant = _brickscript_terrain_place(at, brick)
	if spot == null:
		return
	var terrain: Node3D = _brickscript_terrain(given, brick)
	if terrain == null or not terrain.has_method(method):
		if not _brickscript_terrain_missing.has(brick):
			_brickscript_terrain_missing[brick] = true
			push_error("%s: there's no Terrain in the scene (the Terrain Engine plugin) to change" % brick)
		return
	if method == &"paint":
		terrain.call(method, spot, size, color, strength)
	else:
		terrain.call(method, spot, size, strength)"""
## When terrain ready: every Terrain's terrain_ready, the ones there now and
## the ones added later; one already ready counts once at the start.
const TERRAIN_READY_HELPER: String = """var _brickscript_terrain_listeners: Array[Callable] = []


func _brickscript_on_terrain_ready(callback: Callable) -> void:
	_brickscript_terrain_listeners.append(callback)
	for terrain: Node in get_tree().get_nodes_in_group(&"terrain_engine_terrains"):
		_brickscript_hook_terrain(terrain, callback)
	if not get_tree().node_added.is_connected(_brickscript_terrain_added):
		get_tree().node_added.connect(_brickscript_terrain_added)


func _brickscript_terrain_added(node: Node) -> void:
	for callback: Callable in _brickscript_terrain_listeners:
		_brickscript_hook_terrain(node, callback)


func _brickscript_hook_terrain(terrain: Node, callback: Callable) -> void:
	if not terrain.is_in_group(&"terrain_engine_terrains") or not terrain.has_signal(&"terrain_ready"):
		return
	# (Only a Terrain in this brickscript's 3D world: another SubViewport's
	# scene has its own.)
	if terrain is Node3D and get_viewport() != null and get_viewport().find_world_3d() != null and (terrain as Node3D).get_world_3d() != get_viewport().find_world_3d():
		return
	var heard: Callable = callback.bind(terrain)
	if not terrain.is_connected(&"terrain_ready", heard):
		terrain.connect(&"terrain_ready", heard)
		if terrain.call(&"is_ready"):
			heard.call_deferred()"""
## Random reachable spot's On: the navigation (a path gets there), or the
## Terrain's ground (any machine, no navigation needed).
## Random reachable spot's On (codes 0 / 1 / 2 in _brickscript_random_spot).
## Navigation, else Terrain (user, 2026-11-03): the navigation when there is
## one and it's ready there, else the Terrain's ground (instead of a flat
## circle at the center's height).
const SPOT_ON: PackedStringArray = ["Navigation", "Terrain", "Navigation, else Terrain"]
## Find path: the navigation's path in this node's 3D world (empty: no way
## there, or the navigation isn't ready yet, before the first physics
## frame), straight there with no navigation area; its length. No point
## twice in a row.
const FIND_PATH_HELPER: String = """var _brickscript_path_length: float = 0.0


func _brickscript_find_path(from: Variant, to: Variant, brick: String) -> Array[Vector3]:
	var points: Array[Vector3] = []
	_brickscript_path_length = 0.0
	var places: Array[Vector3] = []
	for place: Variant in [from, to]:
		if place is Vector3:
			places.append(place)
		elif place is Node3D and is_instance_valid(place):
			places.append((place as Node3D).global_position)
		else:
			push_error("%s: %s isn't a place (a Vector3 or a 3D node)" % [brick, place])
			return points
	var map: RID = get_viewport().find_world_3d().navigation_map
	if NavigationServer3D.map_get_regions(map).is_empty():
		points.append_array(places)
	elif NavigationServer3D.map_get_iteration_id(map) != 0 and NavigationServer3D.map_get_closest_point_owner(map, places[0]).is_valid():
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map, places[0], places[1], true)
		if path.is_empty() or Vector2(path[-1].x - places[1].x, path[-1].z - places[1].z).length() > 1.0 or absf(path[-1].y - places[1].y) > 2.0:
			return points
		# (Without the points Godot gives twice in a row, at corners.)
		for point: Vector3 in path:
			if points.is_empty() or not points[-1].is_equal_approx(point):
				points.append(point)
	for i: int in range(1, points.size()):
		_brickscript_path_length += points[i - 1].distance_to(points[i])
	return points"""
## Damage / Kill character's By.
const HEALTH_BY: PackedStringArray = ["Nobody", "A player"]
## Get Character / Get Player From a user ID: the player in the game now
## with that user ID (its BrickscriptPlayer under Players), or nothing.
const USER_ID_HELPER: String = """func _brickscript_player_with_user_id(user_id: String) -> BrickscriptPlayer:
	var players: BrickscriptPlayers = BrickscriptPlayers.of(self)
	if players == null or user_id.is_empty():
		return null
	for player: BrickscriptPlayer in players.all():
		if player.user_id == user_id:
			return player
	return null"""
## When character spawned: every Character Spawner's character_spawned, and
## once for the characters a spawner made already.
const SPAWNED_HELPER: String = """func _brickscript_on_spawned(callback: Callable) -> void:
	for spawner: Node in get_tree().get_nodes_in_group(&"brickscript_character_spawner"):
		if not spawner.is_connected(&"character_spawned", callback):
			spawner.connect(&"character_spawned", callback)
			var made: Dictionary = spawner.call(&"spawned")
			for player: Variant in made:
				callback.call(int(player), made[player])"""
## Invoke Server (like Roblox's RemoteFunction): the local script asks its
## own copy on the server (the same way as Fire Server), which hands the
## question to its server side (On Client Invoked); Answer sends the value
## back to the asking machine. The asker waits for it, at most
## INVOKE_TIMEOUT_SEC (then nothing, with a warning).
const INVOKE_HELPER: String = """var _brickscript_next_request: int = 0
var _brickscript_answers: Dictionary = {}


func _brickscript_invoke(message: String, values: Array, brick: String) -> Variant:
	_brickscript_next_request += 1
	var request: int = _brickscript_next_request
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine != null:
		engine.call(&"call_on_server", self, &"_brickscript_client_invoked", [message, _brickscript_wired(values), request])
	else:
		# Single-player without the engine: the game is its own server.
		_brickscript_hand_invoke.call_deferred(message, values, 1, request)
	var waited: float = 0.0
	while not _brickscript_answers.has(request):
		if waited > 5.0 or not is_inside_tree():
			push_warning("%s: no answer to \\"%s\\" within 5 s (does its On Client Invoked Answer?)" % [brick, message])
			return null
		await get_tree().process_frame
		waited += get_process_delta_time()
	var answer: Variant = _brickscript_answers[request]
	_brickscript_answers.erase(request)
	return answer


@rpc("any_peer", "call_remote", "reliable")
func _brickscript_client_invoked(message: String, values: Array, request: int) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or not bool(engine.call(&"has_server_authority")):
		return
	# (Offline the call is direct: no caller, so it's this machine's player.)
	var caller: int = int(engine.call(&"get_caller_id"))
	_brickscript_hand_invoke.call_deferred(message, values, caller if caller > 0 else int(engine.call(&"get_local_peer_id")), request)


func _brickscript_hand_invoke(message: String, values: Array, sender: int, request: int) -> void:
	values = _brickscript_unwired(values)
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	var part: Node = engine.call(&"get_server_part", self) if engine != null else get_node_or_null(^"ServerPart")
	var handlers: Array[Node] = []
	if part != null:
		handlers.append(part)
	elif get_parent() != null:
		handlers.assign(get_parent().get_children().filter(func(sibling: Node) -> bool: return sibling != self))
	for handler: Node in handlers:
		if handler.has_method(&"_brickscript_on_client_invoked"):
			handler.call(&"_brickscript_on_client_invoked", message, values, sender, request, self)


## The server answers (through the asker's copy here): to the asking machine.
func _brickscript_reply(sender: int, request: int, value: Variant) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or sender == int(engine.call(&"get_local_peer_id")):
		_brickscript_answers[request] = value
	else:
		engine.call(&"call_on_peer", sender, self, &"_brickscript_answered", [request, _brickscript_wired([value])])


@rpc("authority", "call_remote", "reliable")
func _brickscript_answered(request: int, value: Array) -> void:
	_brickscript_answers[request] = _brickscript_unwired(value)[0]"""
## Answer: back to whoever invoked.
const ANSWER_HELPER: String = """func _brickscript_answer(asker: Node, sender: int, request: int, value: Variant) -> void:
	if is_instance_valid(asker) and asker.has_method(&"_brickscript_reply"):
		asker.call(&"_brickscript_reply", sender, request, value)"""
const SEARCH_OPTIONS: PackedStringArray = ["All descendants", "Direct children"]
## Get root: the root of the scene a node was made in, or of the whole game.
const ROOT_OF: PackedStringArray = ["Its scene", "The game's scene"]
## Its scene: a placed scene's root is its own; inside one, its owner (Godot
## sets it for every node saved in the scene); a node made in code: the
## first parent that is one of those.
const SCENE_ROOT_HELPER: String = """func _brickscript_scene_root(node: Node) -> Node:
	var at: Node = node
	while at != null:
		if not at.scene_file_path.is_empty():
			return at
		if at.owner != null:
			return at.owner
		at = at.get_parent()
	return null"""
## Find first ancestor: up from a node's parent, the first with the name
## (blank: any) that `fits` (its Type; not valid: any type).
const ANCESTOR_HELPER: String = """func _brickscript_find_ancestor(node: Node, wanted: String, fits: Callable) -> Node:
	var at: Node = node.get_parent() if node != null else null
	while at != null:
		if (wanted.is_empty() or String(at.name) == wanted) and (not fits.is_valid() or fits.call(at)):
			return at
		at = at.get_parent()
	return null"""
## The game's scene: the top node it's in, right under the window (the main
## scene running; in a SubViewport, that viewport's scene).
const GAME_ROOT_HELPER: String = """func _brickscript_game_root(node: Node) -> Node:
	var at: Node = node
	while at.get_parent() != null and not at.get_parent() is Viewport:
		at = at.get_parent()
	return at"""
const CHILDREN_SEARCH: PackedStringArray = ["Direct children", "All descendants"]
const GROUP_SETTING: Dictionary = {"name": &"group", "kind": "group", "title": "Group", "default": "", "required": true, "info": "a group name (pick one your project uses, or type a new one)"}
## Remote messages (see API.md "Network"). A local script tells the server
## through its own copy on the server, which hands the message to its server
## part; the server part tells the clients through its node's local script.
## The Network Context Engine is reached by name only.
const TELL_SERVER_HELPER: String = """func _brickscript_tell_server(message: String, values: Array) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	var relay: Node = get_node_or_null(^"/root/BrickscriptDebug")
	if engine != null and has_meta(&"_brickscript_starter_copy") and relay != null:
		# A starter's LocalScript copy is only on its player's machine: the
		# autoload (on every machine) carries it to the ServerScripts beside it.
		engine.call(&"call_on_server", relay, &"relay_told", [get_path(), message, _brickscript_wired(values)])
	elif engine != null:
		engine.call(&"call_on_server", self, &"_brickscript_client_told", [message, _brickscript_wired(values)])
	else:
		# Single-player without the engine: the game is its own server.
		_brickscript_hand_to_server_part.call_deferred(message, values, 1)


@rpc("any_peer", "call_remote", "reliable")
func _brickscript_client_told(message: String, values: Array) -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if engine == null or not bool(engine.call(&"has_server_authority")):
		return
	# Deferred: a node's server part is added just after the node enters the
	# tree, so a message sent from When ready would arrive before it.
	_brickscript_hand_to_server_part.call_deferred(message, values, int(engine.call(&"get_caller_id")))


func _brickscript_hand_to_server_part(message: String, values: Array, sender: int) -> void:
	values = _brickscript_unwired(values)
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	var part: Node = engine.call(&"get_server_part", self) if engine != null else get_node_or_null(^"ServerPart")
	if part != null and part.has_method(&"_brickscript_on_client_told"):
		part.call(&"_brickscript_on_client_told", message, values, sender)
	elif part == null and get_parent() != null:
		# A LocalScript node: its server side is the ServerScript nodes
		# beside it.
		for sibling: Node in get_parent().get_children():
			if sibling != self and sibling.has_method(&"_brickscript_on_client_told"):
				sibling.call(&"_brickscript_on_client_told", message, values, sender)"""
## Without the Network Context Engine the game is single-player and its own
## server: a local brickscript's node runs its server brickscript
## (<name>.brickserver next to it, or its server_script metadata) itself, as
## the engine would (a child named ServerPart).
const SERVER_PART_ALONE_HELPER: String = """func _brickscript_server_part_alone() -> void:
	if get_node_or_null(^"/root/NetworkEngine") != null or has_node(^"ServerPart"):
		return
	var script: Script = get_meta(&"server_script") as Script if has_meta(&"server_script") else null
	var path: String = get_script().resource_path.get_basename() + ".brickserver"
	if script == null and ResourceLoader.exists(path):
		script = load(path) as Script
	var part: Node = script.new() as Node if script != null and script.can_instantiate() else null
	if part != null:
		part.name = "ServerPart"
		add_child(part)"""
## Brickscripts are files: a copy of one built into a scene ("Make Unique",
## a built-in script) is cut off from its graph, so it refuses to run. The
## editor puts the file back when it finds one (plugin_main.gd).
const FROM_FILE_HELPER: String = """func _brickscript_from_file(path: String) -> bool:
	var script: Script = get_script() as Script
	if script != null and script.resource_path == path:
		return true
	push_error("%s runs a copy of %s built into the scene, so it does nothing: brickscripts must be files. Put %s back on the node." % [name, path.get_file(), path])
	set_process(false)
	set_physics_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	return false"""
## Fire Clients: `client` is a Player (peer id); -1 sends to all clients, 0
## (no player) to nobody.
## The local side is the node this is the server part of (its parent), or,
## for script nodes, the LocalScript nodes beside this one (the parent's
## children with On Server Fired).
const TELL_CLIENTS_HELPER: String = """func _brickscript_tell_clients(message: String, values: Array, client: int) -> void:
	var body: Node = get_parent()
	if body == null or client == 0:
		return
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	var relay: Node = get_node_or_null(^"/root/BrickscriptDebug")
	if engine != null and relay != null and body.has_meta(&"_brickscript_has_starter_copies") and not body.has_method(&"_brickscript_server_told"):
		# A starter's LocalScript copies are on their player's machine only:
		# the autoload (on every machine) hands it to those beside this node.
		var args: Array = [body.get_path(), message, _brickscript_wired(values)]
		if client < 0:
			engine.call(&"call_on_all", relay, &"relay_server_told", args)
		elif client == int(engine.call(&"get_local_peer_id")) or (engine.call(&"get_connected_peers") as PackedInt32Array).has(client):
			engine.call(&"call_on_peer", client, relay, &"relay_server_told", args)
		return
	var targets: Array[Node] = []
	if body.has_method(&"_brickscript_server_told"):
		targets.append(body)
	else:
		for sibling: Node in body.get_children():
			if sibling != self and sibling.has_method(&"_brickscript_server_told"):
				targets.append(sibling)
	if engine != null:
		values = _brickscript_wired(values)
	for target: Node in targets:
		if engine == null:
			target.call(&"_brickscript_server_told", message, values)
		elif client < 0:
			engine.call(&"call_on_all", target, &"_brickscript_server_told", [message, values])
		elif client == int(engine.call(&"get_local_peer_id")) or (engine.call(&"get_connected_peers") as PackedInt32Array).has(client):
			# (A player who has left is skipped.)
			engine.call(&"call_on_peer", client, target, &"_brickscript_server_told", [message, values])"""

const NODES: Dictionary[StringName, Dictionary] = {
	# Events
	&"event_ready": {
		"kind": Kind.EVENT, "category": "events", "title": "When ready", "description": "Runs once, when the node enters the scene tree. Set things up here.",
		"function": "_ready", "function_params": [],
	},
	&"event_process": {
		"kind": Kind.EVENT, "category": "events", "title": "Every frame", "description": "Runs every rendered frame. delta is the time since the last frame, in seconds.",
		"function": "_process", "function_params": PROCESS_PARAMS, "provides": {"delta": T.NUMBER}, "settings": [RUNS_ON_SETTING],
	},
	&"event_physics_process": {
		"kind": Kind.EVENT, "category": "events", "title": "Every physics frame", "description": "Runs every physics tick at a fixed rate, before Godot moves physics bodies. Use it for movement. delta is the tick time.",
		"function": "_physics_process", "function_params": PROCESS_PARAMS, "provides": {"delta": T.NUMBER}, "settings": [RUNS_ON_SETTING],
	},
	&"event_action_pressed": {
		"kind": Kind.EVENT, "category": "events", "title": "When action pressed", "contexts": [&"local"], "description": "Runs when an Input Map action is pressed on this machine (e.g. ui_accept: Space / Enter). Your machine's keys: for what it shows (menus, the camera), for your own character (Only nodes I own: one the server gave you with Moved By), and for the game: send it to the server with Fire Server (the Roblox model). Server-authoritative games read players' keys on the server instead: Player Pressed.",
		"settings": [ACTION_SETTING, INPUT_WHO_SETTING], "function": "_unhandled_input", "function_params": INPUT_PARAMS,
		"guard": "event.is_action_pressed({action})",
	},
	&"event_action_released": {
		"kind": Kind.EVENT, "category": "events", "title": "When action released", "contexts": [&"local"], "description": "Runs when an Input Map action is released on this machine (the server brickscript has Player Released).",
		"settings": [ACTION_SETTING, INPUT_WHO_SETTING], "function": "_unhandled_input", "function_params": INPUT_PARAMS,
		"guard": "event.is_action_released({action})",
	},
	&"event_action_held": {
		"kind": Kind.EVENT, "category": "events", "title": "While action held", "contexts": [&"local"], "description": "Runs every frame while an Input Map action is held down on this machine. delta is the time since the last frame. Moves your own character (Only nodes I own: one the server gave you with Moved By); anything else in the game goes through Fire Server, or the server reads players' keys with Player Holding.",
		"settings": [ACTION_SETTING, INPUT_WHO_SETTING], "function": "_process", "function_params": PROCESS_PARAMS,
		"guard": "Input.is_action_pressed({action})", "provides": {"delta": T.NUMBER},
	},
	&"key_direction": {
		"kind": Kind.ACTION, "category": "events", "title": "Key Direction", "contexts": [&"local"],
		"description": "Which way this machine's keys push, as a Vector2 at most 1 long (x: left -1 / right 1, y: up -1 / down 1), from four Input Map actions (the characters' move_left / move_right / move_forward / move_back when the project has them); analog sticks give in-between values. For moving your own character from its local brickscript (one the server gave you with Moved By); the server reads a player's with Player Direction. For 3D, use x and y as x and z.",
		"settings": DIRECTION_SETTINGS,
		"result": "Input.get_vector({left}, {right}, {up}, {down})", "returns": T.VECTOR2,
	},
	# Players' input, on the server
	&"event_player_pressed": {
		"kind": Kind.EVENT, "category": "events", "title": "Player Pressed", "contexts": [&"server"], "special": true,
		"description": "Server: runs when a player presses an Input Map action, with that player (offline: you, player 1). Their machine sends it; a local brickscript's own input events are only for what that machine shows.",
		"settings": [ACTION_SETTING, PLAYER_WHOSE_SETTING, RUNS_ON_SETTING], "function": "", "function_params": [], "provides": {"player": T.PLAYER},
		"input_signal": &"player_action_pressed", "guard": "action == {action}",
	},
	&"event_player_released": {
		"kind": Kind.EVENT, "category": "events", "title": "Player Released", "contexts": [&"server"], "special": true,
		"description": "Server: runs when a player lets go of an Input Map action, with that player.",
		"settings": [ACTION_SETTING, PLAYER_WHOSE_SETTING, RUNS_ON_SETTING], "function": "", "function_params": [], "provides": {"player": T.PLAYER},
		"input_signal": &"player_action_released", "guard": "action == {action}",
	},
	&"event_player_holds": {
		"kind": Kind.EVENT, "category": "events", "title": "Player Holding", "contexts": [&"server"], "special": true,
		"description": "Server: runs every frame for each player holding an Input Map action down, with that player; delta is the time since the last frame. E.g. move their character.",
		"settings": [ACTION_SETTING, PLAYER_WHOSE_SETTING, RUNS_ON_SETTING], "function": "", "function_params": [], "provides": {"player": T.PLAYER, "delta": T.NUMBER},
		"each_holder": true,
	},
	&"player_held": {
		"kind": Kind.ACTION, "category": "events", "title": "Player Holds?", "contexts": [&"server"],
		"description": "Server: whether a player holds an Input Map action down right now (a Bool, for If). E.g. jump while they hold Space. Player left blank: this node's Owner (single-player: you).",
		"inputs": [{"name": &"player", "types": [T.PLAYER], "default": {"var": ""}, "blank": OWNER_OR_ME}], "settings": [ACTION_SETTING],
		"result": "_brickscript_player_strength({player}, {action}) > 0.0", "returns": T.BOOL, "helpers": [PLAYER_INPUT_HELPER, OWNER_OR_ME_HELPER],
	},
	&"player_direction": {
		"kind": Kind.ACTION, "category": "events", "title": "Player Direction", "contexts": [&"server"],
		"description": "Server: which way a player is pushing, as a Vector2 at most 1 long (x: left -1 / right 1, y: up -1 / down 1), from four Input Map actions (the characters' move_left / move_right / move_forward / move_back when the project has them). Analog sticks give in-between values. For 3D, use x and y as x and z. Player left blank: this node's Owner (single-player: you), so Every frame into Player Direction moves a node.",
		"inputs": [{"name": &"player", "types": [T.PLAYER], "default": {"var": ""}, "blank": OWNER_OR_ME}],
		"settings": DIRECTION_SETTINGS,
		"result": "_brickscript_player_direction({player}, {left}, {right}, {up}, {down})", "returns": T.VECTOR2,
		"helpers": [PLAYER_INPUT_HELPER, PLAYER_DIRECTION_HELPER, OWNER_OR_ME_HELPER],
	},
	# Network (with the Network Context Engine)
	&"event_server_tells": {
		"kind": Kind.EVENT, "category": "network", "title": "On Server Fired", "contexts": [&"local"], "network": true,
		"description": "Runs when the server sends this message with Fire Clients. values is the List of values sent with it.",
		"settings": [MESSAGE_SETTING], "function": "_brickscript_server_told", "function_params": [["message", "String"], ["values", "Array"]],
		"guard": "message == {message}", "provides": {"values": T.LIST},
		"annotation": "@rpc(\"any_peer\", \"call_remote\", \"reliable\")",
		# Only the server may send it (a client owning the node could otherwise).
		# A Player sent with it arrives as its number: this machine's node.
		"prelude": "\tif multiplayer.get_remote_sender_id() > 1:\n\t\treturn\n\tvalues = _brickscript_unwired(values)", "event_helpers": [WIRE_HELPER],
	},
	&"event_player_joined": {
		"kind": Kind.EVENT, "category": "network", "title": "Player Joined", "special": true, "network": true,
		"description": "Runs when a player joins the game, with that player. Also once for each player already there when this node is ready, you included (offline: you, player 1), so make every player's character here.",
		"function": "", "function_params": [], "provides": {"player": T.PLAYER}, "players_signal": &"player_joined",
	},
	&"event_player_value_changed": {
		"kind": Kind.EVENT, "category": "network", "title": "Player Value Changed", "special": true,
		"description": "Runs on every machine when a value under a player (Players/<name>/gems: an Object Number, Object Text...) changes, with the player and the new value. Also once for the values already there when this node is ready, so a score shows from the start. Whose: any player's, or only yours (Me).",
		"settings": [{"name": &"value_name", "kind": "text", "title": "Value", "default": "gems", "required": true, "info": "the value's name under the player (stats/kills for one in a folder)"},
			{"name": &"whose", "kind": "choice", "title": "Whose", "options": VALUE_WHOSE, "default": "Any player", "info": "any player's value, or only your own (Me: this machine's player)"}],
		"function": "", "function_params": [], "provides": {"player": T.PLAYER, "value": T.ANY}, "player_values": true,
		"guard": "value_name == {value_name}",
	},
	&"event_player_renamed": {
		"kind": Kind.EVENT, "category": "network", "title": "Player Renamed", "special": true,
		"description": "Runs on every machine when a player's name changes, with the player and their new name: a joining player's username arriving (for their first moment they can be Player<number>), or a player changing it. Whose: any player's, or only yours (Me).",
		"settings": [{"name": &"whose", "kind": "choice", "title": "Whose", "options": VALUE_WHOSE, "default": "Any player", "info": "any player's name, or only your own (Me: this machine's player)"}],
		"function": "", "function_params": [], "provides": {"player": T.PLAYER, "new_name": T.TEXT}, "player_renamed": true,
	},
	&"save_player_data": {
		"kind": Kind.ACTION, "category": "network", "title": "Save player data", "contexts": [&"server"],
		"description": "Server: saves a player's values (their Object values under Players/<name>) on the server's disk, under their user ID. Nothing is saved unless a brick says so: save when they leave, or after a change. Saved: whether it worked.",
		"inputs": [{"name": &"player", "types": [T.PLAYER], "default": {"var": ""}}],
		"result": "_brickscript_player_data({player}, true)", "returns": T.BOOL, "helper": PLAYER_DATA_HELPER,
	},
	&"load_player_data": {
		"kind": Kind.ACTION, "category": "network", "title": "Load player data", "contexts": [&"server"],
		"description": "Server: sets a player's values to the ones Save player data saved for their user ID (each value they have; everyone sees them). Found: whether anything was saved for them (false: a new player, their values stay as StarterPlayer gave them). Use it in Player Joined.",
		"inputs": [{"name": &"player", "types": [T.PLAYER], "default": {"var": ""}}],
		"result": "_brickscript_player_data({player}, false)", "returns": T.BOOL, "helper": PLAYER_DATA_HELPER,
	},
	&"event_player_left": {
		"kind": Kind.EVENT, "category": "network", "title": "Player Left", "special": true, "network": true,
		"description": "Runs when a player leaves the game, with that player.",
		"function": "", "function_params": [], "provides": {"player": T.PLAYER}, "players_signal": &"player_left",
	},
	&"host": {
		"kind": Kind.ACTION, "category": "network", "title": "Host", "contexts": [&"local"], "network": true, "special": true, "output": true,
		"description": "Starts a game others can join, on a port. Its Output Var (optional) is true if it started (false if this machine is already in a game, or the port is taken).",
		"inputs": [{"name": &"port", "types": [T.WHOLE], "default": {"type": T.WHOLE, "value": 7000}}],
	},
	&"join": {
		"kind": Kind.ACTION, "category": "network", "title": "Join", "contexts": [&"local"], "network": true, "special": true, "output": true,
		"description": "Joins a hosted game at an address (127.0.0.1 is this computer) and port. Its Output Var (optional) is true if it started connecting (false if this machine is already in a game: Leave first).",
		"inputs": [{"name": &"address", "types": [T.TEXT], "default": {"type": T.TEXT, "value": "127.0.0.1"}}, {"name": &"port", "types": [T.WHOLE], "default": {"type": T.WHOLE, "value": 7000}}],
	},
	&"leave": {
		"kind": Kind.ACTION, "category": "network", "title": "Leave", "contexts": [&"local"], "network": true,
		"description": "Leaves the game (or stops hosting it): back to single-player.",
		"code": "_brickscript_network(&\"leave\", [])", "helper": NETWORK_HELPER,
	},
	&"this_player": {
		"kind": Kind.ACTION, "category": "network", "title": "Owner", "network": true,
		"description": "The player a node belongs to (this node by default): the one Give To handed it, or one of its parents, to. Everything under a player's character is theirs. The server's things (never handed over) are no player: check with If is null.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": THIS_NODE}],
		"result": "_brickscript_player_of({of})", "returns": T.PLAYER, "helper": PLAYER_OF_HELPER,
	},
	&"my_player": {
		"kind": Kind.ACTION, "category": "network", "title": "Me", "network": true, "contexts": [&"local"],
		"description": "The player of this machine (the host is player 1; offline, you are). Compare it with Owner to ask \"is this mine?\" about a player.",
		"result": "_brickscript_my_player()", "returns": T.PLAYER, "helper": MY_PLAYER_HELPER,
	},
	&"is_mine": {
		"kind": Kind.ACTION, "category": "network", "title": "Mine?", "network": true,
		"description": "Whether a node (this node by default) is this machine's player's: your own character, say (Give To gave it to you). On the host and offline, what's no one's counts as yours too.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": THIS_NODE}],
		"result": "_brickscript_owns({node})", "returns": T.BOOL, "helper": OWNS_HELPER,
	},
	&"set_owner": {
		"kind": Kind.ACTION, "category": "network", "title": "Give To", "contexts": [&"server"], "network": true,
		"description": "Makes a node (and its children, also ones added later) a player's: Owner is them, and Mine? is true on their machine. The server stays in control of it; to let their machine move it (their character, the Roblox way) add Moved By. As their character: Character finds it from the player. No player: no one's again.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": THIS_NODE}, {"name": &"player", "types": [T.PLAYER], "default": {"var": ""}}],
		"settings": [{"name": &"as", "kind": "choice", "title": "As", "options": SET_OWNER_AS, "default": "Just the node", "codes": {"Just the node": "false", "Their character": "true"},
			"info": "just give it, or also make it the player's character (Character finds it, on every machine)"}],
		"code": "_brickscript_set_owner({node}, {player}, {as})", "helper": SET_OWNER_HELPER,
	},
	&"set_network_owner": {
		"kind": Kind.ACTION, "category": "network", "title": "Moved By", "contexts": [&"server"], "network": true,
		"description": "Server: whose machine moves a node (this node by default): a player's (their machine changes it at once and everyone sees it; its local brickscript may move it: the Roblox way for their character) or no player (the server). A Max speed above 0 refuses moves faster than that (units a second: a cheat check).",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": THIS_NODE}, {"name": &"player", "types": [T.PLAYER], "default": {"var": ""}},
			{"name": &"max_speed", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 0.0}}],
		"code": "_brickscript_moved_by({node}, {player}, {max_speed})", "helper": MOVED_BY_HELPER,
	},
	&"sync_property": {
		"kind": Kind.DECLARE, "category": "network", "title": "Sync", "contexts": [&"server"], "network": true, "special": true,
		"description": "Server: keeps a property of a node (this brickscript's node by default) the same on every machine: the server's changes are sent to everyone. No wires: it's set up when the node is ready. Then a plain Property (Set) here (Set or Add) shows up for everyone.",
		"settings": [{"name": &"path", "kind": "node_path", "title": "Node", "default": "", "info": "a path from Self (blank: Self)"},
			NODE_CLASS_SETTING, NODE_SCRIPT_SETTING,
			{"name": &"property", "kind": "property", "title": "Property", "default": "", "info": "picked from the node's type"},
			{"name": &"smooth", "kind": "choice", "title": "Updates", "options": SYNC_UPDATES, "default": "Smooth", "info": "Smooth (glide between updates, for positions, colors...) or Jump (for teleports)"}],
		"exits": [],
	},
	&"tell_server": {
		"kind": Kind.ACTION, "category": "network", "title": "Fire Server", "contexts": [&"local"], "network": true,
		"description": "Sends a message, with values, to this node's server brickscript (its On Client Fired brick). Offline, the game is its own server.",
		"settings": [MESSAGE_SETTING], "variadic": MESSAGE_VALUES, "join": MESSAGE_JOIN,
		"code": "_brickscript_tell_server({message}, {values})", "helper": TELL_SERVER_HELPER, "helpers": [WIRE_HELPER],
	},
	&"invoke_server": {
		"kind": Kind.ACTION, "category": "network", "title": "Invoke Server", "contexts": [&"local"], "network": true, "special": true, "output": true, "waits": true,
		"description": "Asks this node's server brickscript (its On Client Invoked) with values, and waits for its Answer, which goes in the Output Var: can I buy this? (at most 5 s; then nothing, with a warning). Like Roblox's RemoteFunction. Offline, the game is its own server.",
		"settings": [MESSAGE_SETTING], "variadic": MESSAGE_VALUES, "join": MESSAGE_JOIN,
	},
	&"event_client_invokes": {
		"kind": Kind.EVENT, "category": "network", "title": "On Client Invoked", "contexts": [&"server"], "network": true,
		"description": "Runs on the server when a client (or the host) asks this message with Invoke Server: values is the List sent, sender the player who asked. Answer the asker (it waits); check the values first.",
		"settings": [MESSAGE_SETTING], "function": "_brickscript_on_client_invoked", "function_params": [["message", "String"], ["values", "Array"], ["sender", "int"], ["request", "int"], ["asker", "Node"]],
		"guard": "message == {message}", "provides": {"values": T.LIST, "sender": T.PLAYER},
	},
	&"answer_client": {
		"kind": Kind.ACTION, "category": "network", "title": "Answer", "contexts": [&"server"], "network": true, "special": true,
		"description": "In an On Client Invoked chain: the answer the asking machine's Invoke Server is waiting for (true / false, a price, a List...).",
		"inputs": [{"name": &"value", "types": [], "default": {"type": T.BOOL, "value": true}}],
	},
	&"event_client_tells": {
		"kind": Kind.EVENT, "category": "network", "title": "On Client Fired", "contexts": [&"server"], "network": true,
		"description": "Runs on the server when a client (or the host itself) sends this message with Fire Server. values is the List sent; sender is the player who sent it. Check it before trusting the values.",
		"settings": [MESSAGE_SETTING], "function": "_brickscript_on_client_told", "function_params": [["message", "String"], ["values", "Array"], ["sender", "int"]],
		"guard": "message == {message}", "provides": {"values": T.LIST, "sender": T.PLAYER},
	},
	&"tell_clients": {
		"kind": Kind.ACTION, "category": "network", "title": "Fire Clients", "contexts": [&"server"], "network": true,
		"description": "Sends a message, with values, to this node's local brickscript (its On Server Fired brick) on every client and the host, or on one client.",
		"settings": [MESSAGE_SETTING, {"name": &"to", "kind": "choice", "title": "To", "options": TELL_CLIENTS_TO, "default": "All clients", "info": "All clients, or One client (a player)"}],
		"inputs": [{"name": &"client", "types": [T.PLAYER], "default": {"var": ""}, "shown_when": {"setting": &"to", "value": "One client"}, "unused": "-1"}],
		"variadic": MESSAGE_VALUES, "join": MESSAGE_JOIN,
		"code": "_brickscript_tell_clients({message}, {values}, {client})", "helper": TELL_CLIENTS_HELPER, "helpers": [WIRE_HELPER],
	},
	# Signals
	&"event_signal": {
		"kind": Kind.EVENT, "category": "signals", "title": "When signal received", "special": true,
		"description": "Runs when a node sends a signal: a Timer's timeout, a Button's pressed, an Area2D's body_entered, another brickscript's own signal... The signal's values are provided (e.g. body).",
		"settings": [{"name": &"path", "kind": "node_path", "title": "Node", "default": "", "info": "the node that sends it, as a path from Self (blank: Self)"},
			NODE_CLASS_SETTING, NODE_SCRIPT_SETTING,
			{"name": &"signal", "kind": "signal", "title": "Signal", "default": "", "info": "picked from the node's type (or typed in)"}],
		# The function, its parameters and the values provided come from the
		# signal (flow_compiler.gd _signal_event()).
		"function": "", "function_params": [],
	},
	&"emit_signal": {
		"kind": Kind.ACTION, "category": "signals", "title": "Emit signal", "special": true,
		"description": "Sends this brickscript's own signal, with values (+ / - for more). Other bricks (When signal received) and scripts can listen to it. It's declared for you from what you send.",
		"settings": [{"name": &"signal", "kind": "text", "title": "Signal", "default": "something_happened", "required": true, "info": "the signal's name (a plain name, like hit or scored)"}],
		"variadic": {"inputs": [{"name": &"value", "types": [], "default": ZERO}], "min": 0, "default_count": 0},
	},
	&"wait_for_signal": {
		"kind": Kind.ACTION, "category": "signals", "title": "Wait for signal", "special": true, "waits": true,
		"description": "Pauses the rest of this chain until a node sends a signal (e.g. an animation's animation_finished). The event's other chains and events keep running.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": PARENT_NODE}],
		"settings": [{"name": &"signal", "kind": "signal", "title": "Signal", "target": &"of", "default": "", "info": "picked from the node's type (or typed in)"}],
	},
	# Output
	&"play_sound": {
		"kind": Kind.ACTION, "category": "output", "title": "Play sound", "description": "Plays a sound file (.wav, .ogg, .mp3) once, at a volume in decibels (0: as recorded, -6: about half as loud).",
		"inputs": [{"name": &"sound", "types": [T.RESOURCE], "default": {"type": T.RESOURCE, "value": ""}, "resource_class": &"AudioStream"},
			{"name": &"volume", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 0.0}}],
		"code": "_brickscript_play_sound({sound}, {volume})", "helper": PLAY_SOUND_HELPER,
	},
	&"print": {
		"kind": Kind.ACTION, "category": "output", "title": "Print", "description": "Writes a value to the Output panel (and the playground's on-screen log).",
		"inputs": [{"name": &"value", "types": [], "default": {"type": T.TEXT, "value": "Hello!"}}],
		"code": "print({value})",
	},
	# Variables and logic
	&"set_var": {
		"kind": Kind.ACTION, "category": "variables", "title": "Variable", "description": "Reads a variable (Mode Get, into the Output), puts a value into it, or makes a new one: Shared (every event can use it) or Chain (only later bricks of this event). Not wired, a Shared Variable (Set) gives its starting value. Mode Add adds to a number or vector variable (score += 1; a negative value takes away). Constants and Exports have their own bricks.", "special": true,
		"settings": [
			{"name": &"mode", "kind": "choice", "title": "Mode", "options": ACCESS_MODES, "default": "Set", "info": "Get: read it into the Output. Set: variable = value (or a new variable). Add: variable += value (an existing number or vector variable)"},
			{"name": &"name", "kind": "text", "title": "Variable", "info": "pick one, or New variable… for a new name", "default": ""},
			{"name": &"var_kind", "kind": "choice", "title": "Kind", "options": SET_VAR_KINDS, "default": "Shared", "place": "outputs",
				"info": "for a new name: Shared (every event, kept; the default), Chain (this run of this event) or Synced (Shared, and the same on every machine: the server sets it, a local brickscript only reads it)"},
		],
		"inputs": [{"name": &"value", "types": [], "default": ZERO, "shown_when": WRITING}],
	},
	&"formula": {
		"kind": Kind.ACTION, "category": "math", "title": "Formula", "description": "Works out a value from a formula you type, like (speed * delta + 1) * 2. Use variable names, numbers and maths functions.", "special": true,
		"settings": [{"name": &"expression", "kind": "text", "title": "Formula", "info": "typed in, e.g. (speed * delta + 1) * 2", "default": ""}],
	},
	&"if": {
		"kind": Kind.ACTION, "category": "flow", "title": "If", "description": "Picks a path: compares A with B (or checks a Bool) and continues through True or False.", "special": true,
		"settings": [{"name": &"operator", "kind": "choice", "title": "Compare", "options": IF_OPERATORS, "default": "is true"}],
		"inputs": [
			{"name": &"a", "types": [], "default": {"var": ""}},
			{"name": &"b", "types": [], "default": ZERO},
		],
		"exits": [&"true", &"false"],
	},
	&"for_each": {
		"kind": Kind.ACTION, "category": "flow", "title": "For each item", "description": "Runs the Loop body once for every item of a List, filling item and index each time. Done runs afterwards.", "special": true,
		"inputs": [{"name": &"list", "types": [T.LIST], "default": {"var": ""}}],
		"settings": [
			{"name": &"item_name", "kind": "name", "title": "Item", "default": "item"},
			{"name": &"index_name", "kind": "name", "title": "Index", "default": "index"},
		],
		"exits": LOOP_EXITS, "exit_titles": LOOP_EXIT_TITLES,
	},
	&"for_each_pair": {
		"kind": Kind.ACTION, "category": "flow", "title": "For each key/value", "description": "Runs the Loop body once for every key of a Table, filling key and value each time. Done runs afterwards.", "special": true,
		"inputs": [{"name": &"table", "types": [T.TABLE], "default": {"var": ""}}],
		"settings": [
			{"name": &"key_name", "kind": "name", "title": "Key", "default": "key"},
			{"name": &"value_name", "kind": "name", "title": "Value", "default": "value"},
		],
		"exits": LOOP_EXITS, "exit_titles": LOOP_EXIT_TITLES,
	},
	&"wait": {
		"kind": Kind.ACTION, "category": "flow", "title": "Wait", "waits": true,
		"description": "Pauses the rest of this chain for some seconds, then carries on. Other events keep running meanwhile.",
		"inputs": [{"name": &"seconds", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 1.0}}],
		"code": "await get_tree().create_timer({seconds}).timeout",
	},
	&"repeat": {
		"kind": Kind.ACTION, "category": "flow", "title": "Repeat N times", "description": "Runs the Loop body a number of times. Optionally counts from 0 in a variable. Done runs afterwards.", "special": true,
		"inputs": [{"name": &"times", "types": Types.NUMERIC, "default": {"type": T.WHOLE, "value": 3}}],
		"settings": [{"name": &"index_name", "kind": "name", "title": "Counter", "default": ""}],
		"exits": LOOP_EXITS, "exit_titles": LOOP_EXIT_TITLES,
	},
	&"while": {
		"kind": Kind.ACTION, "category": "flow", "title": "While", "special": true,
		"description": "Runs the Loop body again and again while a comparison holds (like If: A compared with B, or a Bool), checked before each round. Done runs once it doesn't. Its Safety limit stops a loop that would never end, with an error naming the brick.",
		"settings": [{"name": &"operator", "kind": "choice", "title": "Compare", "options": IF_OPERATORS, "default": "is true"}],
		"inputs": [
			{"name": &"a", "types": [], "default": {"var": ""}},
			{"name": &"b", "types": [], "default": ZERO},
			{"name": &"limit", "types": Types.NUMERIC, "default": {"type": T.WHOLE, "value": 10000}},
		],
		"exits": LOOP_EXITS, "exit_titles": LOOP_EXIT_TITLES,
	},
	&"reroute": {
		"kind": Kind.ACTION, "category": "flow", "title": "Reroute", "special": true,
		"description": "A point on a wire, to bend it around other bricks: nothing runs here, what it's wired to runs next. Double-click a wire to put one on it; deleting one keeps the wire.",
	},
	&"break": {
		"kind": Kind.ACTION, "category": "flow", "title": "Break", "special": true, "exits": [],
		"description": "Leaves the loop it's in (For each, Repeat, While) at once: its Done runs next. Only inside a Loop body (an If inside one is fine).",
	},
	&"continue": {
		"kind": Kind.ACTION, "category": "flow", "title": "Continue", "special": true, "exits": [],
		"description": "Skips the rest of this round of the loop it's in: the next round starts (the next item; While checks its comparison again). Only inside a Loop body.",
	},
	# Functions
	&"define_function": {
		"kind": Kind.EVENT, "category": "functions", "title": "Define Function", "special": true,
		"description": "Starts a function: a chain that runs when a Call Function brick calls it, with the values given to its inputs (each input is a read-only value in the chain, like an event's). It gives back what a Return brick gives, or nothing. A Wait in it makes the caller wait too.",
		"settings": [{"name": &"name", "kind": "text", "title": "Name", "default": "my_function", "required": true,
			"info": "the function's name (letters, digits and _): Call Function picks it by this name"}],
		"function": "", "function_params": [],
	},
	&"return_value": {
		"kind": Kind.ACTION, "category": "functions", "title": "Return", "special": true, "exits": [],
		"description": "Ends the function it's in at once and gives back a value to the Call Function that called it (or nothing: leaves early). Only in a Define Function's chain. Every Return of one function gives the same type, or none of them gives anything.",
		"inputs": [{"name": &"value", "types": [], "default": ZERO, "shown_when": {"setting": &"gives", "value": "A value"}}],
		"settings": [{"name": &"gives", "kind": "choice", "title": "Gives", "options": RETURN_GIVES, "default": "A value",
			"info": "a value back to the caller, or nothing (just leave the function)"}],
	},
	&"call_function": {
		"kind": Kind.ACTION, "category": "functions", "title": "Call Function", "special": true, "output": true,
		"description": "Runs a function (a Define Function chain) with values for its inputs, and keeps what it gives back (its Return) in the Output. If the function waits, this waits for it. From: this brickscript, a shared brickscript (.brickshared), or a node's brickscript (a local brickscript calls its LocalScript's functions, a server one its ServerScript's).",
		"settings": [{"name": &"from", "kind": "choice", "title": "From", "options": FUNCTION_FROM, "default": "This brickscript",
				"info": "where the function is defined"},
			{"name": &"file", "kind": "shared_file", "title": "File", "default": "", "info": "a shared brickscript (.brickshared)"},
			{"name": &"function_script", "kind": "function_script", "title": "Its brickscript", "default": "",
				"info": "the node's brickscript (optional): its functions to pick from, typed; without it the function is called by name, checked when the game runs"},
			{"name": &"function", "kind": "function", "title": "Function", "default": "", "required": true, "info": "the function's name"}],
		"inputs": [{"name": &"node", "types": [T.NODE], "default": {"var": ""}, "shown_when": {"setting": &"from", "value": "A node"}}],
		"variadic": {"inputs": [{"name": &"arg", "types": [], "default": ZERO}], "min": 0, "default_count": 0},
	},
	&"constant": {
		"kind": Kind.DECLARE, "category": "variables", "title": "Constant", "special": true,
		"description": "Declares a Constant: one fixed value for the whole script that nothing can change. No wires: it's set before the game starts, and every brick can read it.",
		"settings": [{"name": &"name", "kind": "declare", "title": "Name", "info": "the constant's name", "default": "CONSTANT"}],
		"inputs": [{"name": &"value", "types": [], "default": {"type": T.WHOLE, "value": 0}, "literal_only": true}],
		"exits": [],
	},
	&"export": {
		"kind": Kind.DECLARE, "category": "variables", "title": "Export", "special": true,
		"description": "Declares an Export: a value set per node in the Inspector, starting at this value. No wires: it's set before the game starts, and every brick can read it. Shown on: which node's Inspector shows it (the script node, the node it acts for, e.g. the character, or another node); its value is kept on the script node either way.",
		"settings": [{"name": &"name", "kind": "declare", "title": "Name", "info": "the export's name (shown in the Inspector)", "default": "setting"},
			NODE_CLASS_SETTING, NODE_SCRIPT_SETTING,
			{"name": &"shown_on", "kind": "choice", "title": "Shown on", "options": EXPORT_SHOWN_ON, "default": EXPORT_SHOWN_ON[0],
				"info": "the node whose Inspector shows it: this script node, the node it acts for (its parent: the character, the door...), or a node (a path from the node it acts for)"}],
		"inputs": [{"name": &"value", "types": [], "default": {"type": T.NUMBER, "value": 0.0}, "literal_only": true},
			{"name": &"shown_node", "types": [T.NODE], "default": {"type": T.NODE, "value": "."}, "literal_only": true, "shown_when": {"setting": &"shown_on", "value": EXPORT_SHOWN_ON[2]}}],
		"exits": [],
	},
	# Nodes
	&"get_node": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Get node", "special": true, "output": true,
		"description": "Finds a node by its path from Self (e.g. Self.Sprite2D, Self.Parent.Gun, Self.Parent.Parent.Enemy) and puts it in a Node variable. Its Type is filled in from the scenes that use this brickscript, so later bricks know its properties.",
		"settings": [{"name": &"path", "kind": "node_path", "title": "Path", "default": "", "info": "a path from Self (blank: Self); pick one found in your scenes"},
			NODE_CLASS_SETTING, NODE_SCRIPT_SETTING],
	},
	&"set_property": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Property", "special": true, "output": true,
		"description": "A property of a node (position, visible, a script's variable, ...). Mode Get reads it into a variable; Set gives it a value (visible = false, modulate = red); Add adds to a number or vector property (position += velocity * delta; a negative value takes away).",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": PARENT_NODE}, {"name": &"value", "types": [], "default": ZERO, "shown_when": WRITING}], "local_target": &"of",
		"settings": [{"name": &"mode", "kind": "choice", "title": "Mode", "options": ACCESS_MODES, "default": "Get", "info": "Get: read it into the Output. Set: property = value. Add: property += value (numbers and vectors only)"},
			{"name": &"property", "kind": "property", "title": "Property", "target": &"of", "default": "", "info": "picked from the node's type (or typed in)"}],
	},
	&"call_method": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Call method", "special": true, "output": true,
		"description": "Calls a method of a node (hide, play, look_at, move_and_slide, a script's function...) with values (+ / - for more). What it returns can go in an Output Var.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": PARENT_NODE}],
		"settings": [{"name": &"method", "kind": "method", "title": "Method", "target": &"of", "default": "", "info": "picked from the node's type (or typed in); picking one sets up its values"}], "local_target": &"of",
		"variadic": {"inputs": [{"name": &"arg", "types": [], "default": ZERO}], "min": 0, "default_count": 0},
	},
	&"spawn_scene": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Spawn scene", "special": true, "output": true,
		"description": "Makes a copy of a scene (.tscn) and adds it as a child of a node (the parent by default). The new node can go in an Output Var; its Type comes from the scene. In a server brickscript it's made for every machine, and can be a player's from the start (For: e.g. their character, from Player Joined).",
		"settings": [{"name": &"scene", "kind": "scene", "title": "Scene", "default": "", "info": "a .tscn file in the project"}, NODE_CLASS_SETTING, NODE_SCRIPT_SETTING,
			{"name": &"place", "kind": "choice", "title": "Place", "options": SPAWN_PLACES, "default": "As in the scene", "info": "where the scene has it, or at a position (set before it's added, on every machine)"},
			{"name": &"for", "kind": "choice", "title": "For", "options": SPAWN_FOR, "default": "No one",
				"info": "server: no one's, a player's (Owner of it is them), or also their character (Character finds it), from the start"}],
		"inputs": [{"name": &"parent", "types": [T.NODE], "default": PARENT_NODE},
			{"name": &"at", "types": Types.VECTORS, "default": {"type": T.VECTOR2, "value": Vector2.ZERO}, "shown_when": {"setting": &"place", "value": "At a position"}},
			{"name": &"player", "types": [T.PLAYER], "default": {"var": ""}, "shown_when": {"setting": &"for", "values": ["A player", "A player: their character"]}}],
	},
	&"find_node": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Find node", "special": true, "output": true,
		"description": "Searches under a node (the parent by default) for a node with a name, which can come from a variable. Nothing (null) if there is none. Set its Type so later bricks know its properties.",
		"inputs": [{"name": &"name", "types": [T.TEXT], "default": {"type": T.TEXT, "value": "Player"}}, {"name": &"under", "types": [T.NODE], "default": PARENT_NODE}],
		"settings": [{"name": &"search", "kind": "choice", "title": "Search", "options": SEARCH_OPTIONS, "default": "All descendants", "info": "all descendants, or direct children only"},
			NODE_CLASS_SETTING],
	},
	&"get_root": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Get root", "special": true, "output": true,
		"description": "The root of a scene. Its scene: the root of the scene a node (Self.Parent by default) was made in, however deep it sits: a script inside coin.tscn gets the Coin, wherever the coin is placed (a placed scene's root gets itself). The game's scene: the main scene running (the top node, right under the window). For Its scene the Type is filled in from your scenes, so later bricks know its properties; set it yourself for the game's scene.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": THIS_NODE, "shown_when": {"setting": &"root", "value": ROOT_OF[0]}}],
		"settings": [{"name": &"root", "kind": "choice", "title": "Root", "options": ROOT_OF, "default": ROOT_OF[0], "info": "the root of the scene the node was made in, or the game's main scene"},
			NODE_CLASS_SETTING, NODE_SCRIPT_SETTING],
	},
	&"find_ancestor": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Find first ancestor", "special": true, "output": true,
		"description": "Goes up from a node's parent (Self's by default: in a script node its parent counts, like Roblox's script:FindFirstAncestor) to the first node with the Name and of the Type. Leave Name blank for any name, Type blank for any type (both blank: the parent). Nothing (null) if no ancestor fits: check with If is null.",
		"inputs": [{"name": &"name", "types": [T.TEXT], "default": {"type": T.TEXT, "value": ""}}, {"name": &"of", "types": [T.NODE], "default": THIS_NODE, "stays_self": true}],
		"settings": [{"name": &"node_class", "kind": "node_class", "title": "Type", "default": "", "info": "blank: any type; else the first ancestor that is one (e.g. Character3D, Area3D)"}],
	},
	&"as_script": {
		"kind": Kind.ACTION, "category": "nodes", "title": "As script", "special": true, "output": true,
		"description": "The node known to run a script (a .gd or a brickscript), so later bricks offer that script's variables and methods: the node itself, or its script node (a LocalScript / ServerScript child running it for the node). Nothing (null) if neither runs it: check with If is null.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": {"var": ""}}],
		"settings": [{"name": &"node_script", "kind": "node_script", "title": "Script", "default": "", "required": true,
			"info": "the script the node should run; its variables and methods show up in the next bricks' dropdowns"}],
	},
	&"get_children": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Get children", "special": true, "output": true,
		"description": "A node's children as a List (the parent's by default), oldest first. Only those of a Type, if one is set; all descendants, if chosen. For each item then knows what each one is.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": PARENT_NODE}],
		"settings": [{"name": &"search", "kind": "choice", "title": "Search", "options": CHILDREN_SEARCH, "default": "Direct children", "info": "direct children, or all descendants"},
			NODE_CLASS_SETTING, NODE_SCRIPT_SETTING],
	},
	&"nodes_in_group": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Nodes in group", "special": true, "output": true,
		"description": "Every node in a group (anywhere in the game) as a List. Only those of a Type, if one is set (picking a group fills it in from your scenes).",
		"settings": [GROUP_SETTING, NODE_CLASS_SETTING, NODE_SCRIPT_SETTING],
	},
	&"add_to_group": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Add to group", "description": "Puts a node (the parent by default) in a group. Nodes in group and Is in group find it there.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": PARENT_NODE}], "settings": [GROUP_SETTING], "local_target": &"node",
		"code": "{node}.add_to_group({group})",
	},
	&"remove_from_group": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Remove from group", "description": "Takes a node (the parent by default) out of a group.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": PARENT_NODE}], "settings": [GROUP_SETTING], "local_target": &"node",
		"code": "{node}.remove_from_group({group})",
	},
	&"is_in_group": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Is in group", "description": "Whether a node (the parent by default) is in a group: a Bool, for If.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": PARENT_NODE}], "settings": [GROUP_SETTING],
		"result": "{node}.is_in_group({group})", "returns": T.BOOL,
	},
	&"free_node": {
		"kind": Kind.ACTION, "category": "nodes", "title": "Free node", "description": "Removes a node (and its children) from the game at the end of this frame.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": {"var": ""}}], "local_target": &"node",
		"code": "{node}.queue_free()",
	},
	# Physics
	&"bodies_near": {
		"kind": Kind.ACTION, "category": "physics", "title": "Bodies near", "special": true, "output": true,
		"description": "What touches a point, or a ball (circle in 2D) around it, as a List: e.g. is this spot free before spawning something there? A Vector3 looks in 3D, a Vector2 in 2D. The node running this brickscript isn't counted.",
		"inputs": [{"name": &"at", "types": Types.VECTORS, "default": {"type": T.VECTOR3, "value": Vector3.ZERO}},
			{"name": &"radius", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 0.5}}],
		"settings": [LOOK_FOR_SETTING, NODE_CLASS_SETTING, LAYERS_SETTING],
	},
	&"raycast": {
		"kind": Kind.ACTION, "category": "physics", "title": "Raycast", "special": true, "output": true,
		"description": "The first body (or area) on a straight line from one point to another (of a Type, if set: other things are looked past), then Hit or Nothing hit runs: ground under a character, a wall in the way, line of sight. Vector3s look in 3D, Vector2s in 2D. The node running this brickscript isn't hit.",
		"exits": RAY_EXITS, "exit_titles": RAY_EXIT_TITLES, "branch": {"cases": [[&"hit", "not _brickscript_ray_hit.is_empty()"], [&"missed", "_brickscript_ray_hit.is_empty()"]]},
		"inputs": [{"name": &"from", "types": Types.VECTORS, "default": {"type": T.VECTOR3, "value": Vector3.ZERO}},
			{"name": &"to", "types": Types.VECTORS, "default": {"type": T.VECTOR3, "value": Vector3(0, -10, 0)}},
			{"name": &"relative_to", "types": [T.NODE], "default": THIS_NODE, "shown_when": {"setting": &"space", "value": RAY_RELATIVE}}],
		"settings": [{"name": &"space", "kind": "choice", "title": "Points are", "options": RAY_SPACES, "default": "World positions",
				"info": "world positions, or relative to a node (Relative to): in its own space, so they move and turn with it, like Godot's RayCast nodes"},
			LOOK_FOR_SETTING, NODE_CLASS_SETTING, LAYERS_SETTING,
			{"name": &"point_name", "kind": "name", "title": "Hit point", "default": "", "suggest": "hit_point",
				"info": "where the ray hit (a Vector3, or Vector2 in 2D); To when nothing is hit (blank: not kept)"},
			{"name": &"normal_name", "kind": "name", "title": "Normal", "default": "", "suggest": "hit_normal",
				"info": "which way the surface it hit faces, length 1; (0, 0, 0) when nothing is hit (blank: not kept)"},
			{"name": &"distance_name", "kind": "name", "title": "Distance", "default": "", "suggest": "hit_distance", "made_type": T.NUMBER,
				"info": "how far from From the hit is (a Number); -1 when nothing is hit (blank: not kept)"}],
		"names_header": "Also fills", "names_hint": "Chain variables later bricks of this event can read, or existing ones it writes into. When nothing is hit: Hit point is To, Normal (0, 0, 0), Distance -1.",
	},
	# Animation
	&"play_animation": {
		"kind": Kind.ACTION, "category": "animation", "title": "Play animation", "contexts": [&"server"], "special": true, "can_wait": true,
		"description": "Server: plays an animation of an AnimationPlayer (or AnimatedSprite2D / 3D) on every machine: each plays it itself, smoothly, and a player who joins later starts it where it is. Pick the animation from the node's. Don't also Sync what it animates.",
		"inputs": ANIMATION_PLAY_INPUTS, "settings": ANIMATION_PLAY_SETTINGS,
	},
	&"stop_animation": {
		"kind": Kind.ACTION, "category": "animation", "title": "Stop animation", "contexts": [&"server"], "special": true,
		"description": "Server: stops (or pauses) what an AnimationPlayer or animated sprite is playing, on every machine.",
		"inputs": [ANIMATION_PLAYER_INPUT], "settings": ANIMATION_STOP_SETTINGS,
	},
	&"play_ui_animation": {
		"kind": Kind.ACTION, "category": "animation", "title": "Play UI animation", "contexts": [&"local"], "special": true, "can_wait": true,
		"description": "Plays an animation on this machine only, for what only it shows: menus, labels, the HUD. Everything the animation moves must be UI (or a camera, sound, particles, an effect); one that moves game nodes is refused (the server plays those: Play animation).",
		"inputs": ANIMATION_PLAY_INPUTS, "settings": ANIMATION_PLAY_SETTINGS,
	},
	&"stop_ui_animation": {
		"kind": Kind.ACTION, "category": "animation", "title": "Stop UI animation", "contexts": [&"local"], "special": true,
		"description": "Stops (or pauses) a UI animation on this machine.",
		"inputs": [ANIMATION_PLAYER_INPUT], "settings": ANIMATION_STOP_SETTINGS,
	},
	&"tween_property": {
		"kind": Kind.ACTION, "category": "animation", "title": "Tween property", "special": true, "can_wait": true,
		"description": "Moves a property smoothly to a value over some seconds (like Roblox's TweenService): a door sliding open, a label fading, a pickup bobbing. Easing sets how it speeds up and slows down. Repeat: more rounds after the first (-1: forever); Reverses: each round goes back again. In a server brickscript every machine runs the same tween (smooth everywhere, players who join later too); a local brickscript tweens what Property (Set) may change there (UI, cameras, effects, your own character).",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": PARENT_NODE}, {"name": &"to", "types": [], "default": ZERO},
			{"name": &"seconds", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 1.0}},
			{"name": &"repeat", "types": [T.WHOLE], "default": {"type": T.WHOLE, "value": 0}},
			{"name": &"reverses", "types": [T.BOOL], "default": {"type": T.BOOL, "value": false}}],
		"settings": [{"name": &"property", "kind": "property", "title": "Property", "target": &"of", "default": "", "info": "a number, vector or color property, picked from the node's type"},
			{"name": &"easing", "kind": "choice", "title": "Easing", "options": TWEEN_EASING_NAMES, "default": "Quad", "info": "how it moves: Linear keeps one speed; Sine, Quad... speed up or slow down; Back overshoots, Bounce bounces, Elastic springs"},
			{"name": &"direction", "kind": "choice", "title": "Direction", "options": TWEEN_DIRECTION_NAMES, "default": "Out", "info": "where the easing is: at the start (In), the end (Out), both (In-Out)"},
			{"name": &"then", "kind": "choice", "title": "Then", "options": ANIMATION_THEN, "default": "Go on at once",
				"info": "carry on at once, or wait until it ends (one that repeats forever doesn't wait)"}],
	},
	&"stop_tweens": {
		"kind": Kind.ACTION, "category": "animation", "title": "Stop tweens", "special": true,
		"description": "Stops a node's tweens where they are (from a server brickscript: on every machine, where the server has them).",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": PARENT_NODE}],
	},
	# Character
	&"event_character_spawned": {
		"kind": Kind.EVENT, "category": "character", "title": "When character spawned", "contexts": [&"server"], "special": true,
		"description": "Server: runs when a Character Spawner gives a player their character (on joining, and each respawn), with the player and the character: give them their starting health, a team color...",
		"function": "", "function_params": [], "provides": {"player": T.PLAYER, "character": T.NODE}, "spawner_signal": true,
	},
	&"get_character": {
		"kind": Kind.ACTION, "category": "character", "title": "Get Character", "special": true, "output": true,
		"description": "A player's character (the node a Character Spawner or Give To made theirs, on every machine): From a player, or From a user ID (the ID saved with each player's profile; only players in the game now). Nothing (null) if they have none (yet), or it's gone: check with If is null. Read and change it with Property (Get) / Property (Set).",
		"inputs": [{"name": &"player", "types": [T.PLAYER], "default": {"var": ""}, "shown_when": {"setting": &"from", "value": "A player"}},
			{"name": &"user_id", "types": [T.TEXT], "default": {"type": T.TEXT, "value": ""}, "shown_when": {"setting": &"from", "value": "A user ID"}}],
		"settings": [{"name": &"from", "kind": "choice", "title": "From", "options": CHARACTER_FROM, "default": "A player", "info": "a player, or a player's user ID"},
			NODE_CLASS_SETTING, NODE_SCRIPT_SETTING],
	},
	&"get_player": {
		"kind": Kind.ACTION, "category": "character", "title": "Get Player", "special": true, "output": true,
		"description": "The player of a character (or of a node inside it: this node by default), or the player with a user ID (only players in the game now). No player (null) if there's none: check with If is null. For whose any node is (a car given to someone), Owner.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": THIS_NODE, "shown_when": {"setting": &"from", "value": "A character"}},
			{"name": &"user_id", "types": [T.TEXT], "default": {"type": T.TEXT, "value": ""}, "shown_when": {"setting": &"from", "value": "A user ID"}}],
		"settings": [{"name": &"from", "kind": "choice", "title": "From", "options": PLAYER_FROM, "default": "A character", "info": "a character (or a node inside it), or a user ID"}],
	},
	&"damage": {
		"kind": Kind.ACTION, "category": "character", "title": "Damage", "contexts": [&"server"],
		"description": "Server: takes Amount off a character's health (a Character3D / Character2D node; this node's character by default). At 0 it dies (When character died, on every machine). By: the player who did it (the killer When character died gets), or nobody. Every machine gets the new health.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": THIS_NODE}, {"name": &"amount", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 10.0}},
			{"name": &"by", "types": [T.PLAYER], "default": {"var": ""}, "shown_when": {"setting": &"by_whom", "value": "A player"}, "unused": "0"}],
		"settings": [{"name": &"by_whom", "kind": "choice", "title": "By", "options": HEALTH_BY, "default": "Nobody", "info": "who did it: nobody, or a player (When character died gets them as the killer)"}],
		"code": "_brickscript_damage({of}, {amount}, {by}, {brick})", "helper": HEALTH_HELPER, "helpers": [CHARACTER_HELPER],
	},
	&"heal": {
		"kind": Kind.ACTION, "category": "character", "title": "Heal", "contexts": [&"server"],
		"description": "Server: gives a character Amount of health back (up to its max health). A dead character stays dead (it's made again: respawn).",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": THIS_NODE}, {"name": &"amount", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 10.0}}],
		"code": "_brickscript_heal({of}, {amount}, {brick})", "helper": HEALTH_HELPER, "helpers": [CHARACTER_HELPER],
	},
	&"kill_character": {
		"kind": Kind.ACTION, "category": "character", "title": "Kill character", "contexts": [&"server"],
		"description": "Server: a character dies at once (its health to 0; When character died runs on every machine). By: the player who did it, or nobody.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": THIS_NODE},
			{"name": &"by", "types": [T.PLAYER], "default": {"var": ""}, "shown_when": {"setting": &"by_whom", "value": "A player"}, "unused": "0"}],
		"settings": [{"name": &"by_whom", "kind": "choice", "title": "By", "options": HEALTH_BY, "default": "Nobody", "info": "who did it: nobody, or a player (the killer)"}],
		"code": "_brickscript_kill({of}, {by}, {brick})", "helper": HEALTH_HELPER, "helpers": [CHARACTER_HELPER],
	},
	&"remove_character": {
		"kind": Kind.ACTION, "category": "character", "title": "Remove character", "contexts": [&"server"],
		"description": "Server: removes a character from the game, on every machine (dead or alive). Its Character Spawner makes the player a new one after its Respawn seconds. A Scripted death ends with this.",
		"inputs": [{"name": &"of", "types": [T.NODE], "default": THIS_NODE}],
		"code": "_brickscript_remove_character({of}, {brick})", "helper": HEALTH_HELPER, "helpers": [CHARACTER_HELPER],
	},
	&"event_character_died": {
		"kind": Kind.EVENT, "category": "character", "title": "When character died", "special": true,
		"description": "Runs when a character's health reaches 0, on every machine: in a server brickscript for the game (scores, who killed whom, Remove character), in a local one for what this machine shows (a sound, particles, \"You died\"). Gives the character, its player and the killer (no player when nobody). Whose: any character, this node's character (a script on or inside it), or my character (this machine's player's).",
		"function": "", "function_params": [], "provides": {"character": T.NODE, "player": T.PLAYER, "killer": T.PLAYER}, "died_signal": true,
		"settings": [{"name": &"whose", "kind": "choice", "title": "Whose", "options": DIED_WHOSE, "default": "Any character", "info": "any character's death, the one this script is on or in, or this machine's player's"}],
	},
	# AI
	&"walk_to": {
		"kind": Kind.ACTION, "category": "ai", "title": "Walk to", "contexts": [&"server"], "waits": true,
		"description": "Server: a character steered by scripts (a Character3D with Controlled by: Script, an NPC) walks to a spot or a node (where it is now) along the navigation (a NavigationRegion3D, baked in the editor), around what's in the way, turning to face where it goes. The chain waits; then Arrived, Can't reach (no path there, or stuck) or Stopped (Stop walking, another Walk to or Follow took over, or it died). With no navigation area it walks straight there.",
		"exits": WALK_EXITS, "exit_titles": WALK_EXIT_TITLES, "branch": {"cases": [[&"arrived", "_brickscript_walked == 0"], [&"unreachable", "_brickscript_walked == 1"], [&"stopped", "_brickscript_walked == 2"]]},
		"inputs": [{"name": &"who", "types": [T.NODE], "default": THIS_NODE}, {"name": &"to", "types": [T.VECTOR3, T.NODE], "default": {"type": T.VECTOR3, "value": Vector3.ZERO}},
			{"name": &"within", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 0.5}}],
		"code": "_brickscript_walked = await _brickscript_walk_to({who}, {to}, {within}, {brick})", "helper": WALK_HELPER, "helpers": [CHARACTER_HELPER],
	},
	&"follow": {
		"kind": Kind.ACTION, "category": "ai", "title": "Follow", "contexts": [&"server"],
		"description": "Server: a character steered by scripts (Controlled by: Script) walks after a node and keeps within Distance of it, finding its path again as it moves; standing, it faces it. Carries on at once; the following goes on until Stop walking, a Walk to, the target is gone or the character dies.",
		"inputs": [{"name": &"who", "types": [T.NODE], "default": THIS_NODE}, {"name": &"target", "types": [T.NODE], "default": {"var": ""}},
			{"name": &"distance", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 2.0}}],
		"code": "_brickscript_follow({who}, {target}, {distance}, {brick})", "helper": WALK_HELPER, "helpers": [CHARACTER_HELPER],
	},
	&"stop_walking": {
		"kind": Kind.ACTION, "category": "ai", "title": "Stop walking", "contexts": [&"server"],
		"description": "Server: a character's Walk to (it goes on through Can't reach) or Follow stops; it stands still.",
		"inputs": [{"name": &"who", "types": [T.NODE], "default": THIS_NODE}],
		"code": "_brickscript_stop_walking({who}, {brick})", "helper": WALK_HELPER, "helpers": [CHARACTER_HELPER],
	},
	&"find_path": {
		"kind": Kind.ACTION, "category": "ai", "title": "Find path", "special": true, "output": true,
		"description": "The way a character would walk from one spot (or node) to another along the navigation, as a List of Vector3 points from start to end; empty when no path gets there (or before the navigation is ready: its first few physics frames). Straight there with no navigation area. Length (Also fills): how long it is.",
		"inputs": [{"name": &"from", "types": [T.VECTOR3, T.NODE], "default": {"type": T.VECTOR3, "value": Vector3.ZERO}}, {"name": &"to", "types": [T.VECTOR3, T.NODE], "default": {"type": T.VECTOR3, "value": Vector3.ZERO}}],
		"settings": [{"name": &"length_name", "kind": "name", "title": "Length", "default": "", "suggest": "path_length", "made_type": T.NUMBER,
			"info": "how long the path is (a Number); 0 when there's none (blank: not kept)"}],
		"names_header": "Also fills", "names_hint": "A chain variable later bricks of this event can read, or an existing one it writes into.",
	},
	&"can_see": {
		"kind": Kind.ACTION, "category": "ai", "title": "Can see",
		"description": "Whether a node (a character: from its eyes) sees a spot or a node: within Range, inside its View (degrees across, about where it faces; 360: all round) and nothing in the way (a ray past the looker's own character). Then Seen or Not seen runs. 3D.",
		"exits": SEE_EXITS, "exit_titles": SEE_EXIT_TITLES, "branch": {"cases": [[&"seen", "_brickscript_seen"], [&"unseen", "not _brickscript_seen"]]},
		"inputs": [{"name": &"who", "types": [T.NODE], "default": THIS_NODE}, {"name": &"target", "types": [T.VECTOR3, T.NODE], "default": {"var": ""}},
			{"name": &"range", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 20.0}},
			{"name": &"view", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 120.0}}],
		"code": "_brickscript_seen = _brickscript_can_see({who}, {target}, {range}, {view}, {brick})", "helper": CAN_SEE_HELPER, "helpers": [PLACE_HELPER],
	},
	&"nearest_character": {
		"kind": Kind.ACTION, "category": "ai", "title": "Nearest character", "special": true, "output": true,
		"description": "The character (a Character3D) closest to a spot or a node: Among players' characters (Controlled by Player) or all characters (NPCs too). Not the node it's measured from or the character it's in, not dead ones; within Range (0: any distance). Nothing (null) when there's none: check with If is null. Distance (Also fills): how far it is (-1 when none).",
		"inputs": [{"name": &"from", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE},
			{"name": &"range", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 0.0}}],
		"settings": [{"name": &"among", "kind": "choice", "title": "Among", "options": NEAREST_AMONG, "default": "Players' characters", "info": "players' characters only, or every character (NPCs too)"},
			{"name": &"distance_name", "kind": "name", "title": "Distance", "default": "", "suggest": "nearest_distance", "made_type": T.NUMBER,
				"info": "how far it is (a Number); -1 when there's none (blank: not kept)"}],
		"names_header": "Also fills", "names_hint": "A chain variable later bricks of this event can read, or an existing one it writes into.",
	},
	&"random_spot": {
		"kind": Kind.ACTION, "category": "ai", "title": "Random reachable spot",
		"description": "A random spot within Radius of a spot or a node. On Navigation: on the navigation, that a path from there gets to: somewhere to wander to (Walk to it); with no navigation area (or before it's ready) a random spot in the circle. On Terrain: on the ground of the scene's Terrain (the Terrain Engine plugin), at its height there: where to put a gem or an NPC; works on every machine, no navigation needed. On Navigation, else Terrain: the navigation where it's there and ready, else the Terrain's ground (an NPC spawned before the navigation is baked, a client, a Terrain with Navigation off).",
		"inputs": [{"name": &"around", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE},
			{"name": &"radius", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 10.0}},
			{"name": &"terrain", "types": [T.NODE], "default": {"type": T.NODE, "value": ""}, "blank": "null", "node_script": TERRAIN_SCRIPT,
				"placeholder": "blank: the scene's Terrain", "shown_when": {"setting": &"on", "values": ["Terrain", "Navigation, else Terrain"]}, "unused": "null"}],
		"settings": [{"name": &"on", "kind": "choice", "title": "On", "options": SPOT_ON, "default": "Navigation", "codes": {"Navigation": "0", "Terrain": "1", "Navigation, else Terrain": "2"},
			"info": "the navigation (a path gets there), the Terrain's ground (its height there; no navigation needed), or the navigation where there is one and it's ready, else the Terrain's ground"}],
		"result": "_brickscript_random_spot({around}, {radius}, {brick}, {on}, {terrain})", "returns": T.VECTOR3, "helper": RANDOM_SPOT_HELPER, "helpers": [PLACE_HELPER, TERRAIN_HELPER],
	},
	# Terrain (the Terrain Engine plugin, by group and method name)
	&"terrain_height": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Terrain height",
		"description": "The height of the ground of the scene's Terrain (the Terrain Engine plugin) at a spot or a node's position: where to put something on the ground. Works anywhere, built there yet or not (it comes from the terrain's seed). Without a Terrain, or outside a Fixed world's edges: the spot's own height.",
		"inputs": [TERRAIN_INPUT, {"name": &"at", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE}],
		"result": "_brickscript_terrain_height({at}, {brick}, {terrain})", "returns": T.NUMBER, "helper": TERRAIN_HELPER, "helpers": [PLACE_HELPER],
	},
	&"dig_terrain": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Dig terrain", "contexts": [&"server"],
		"description": "Digs a ball of ground away from the scene's Terrain (the Terrain Engine plugin) at a spot or a node's position: Size is its radius in meters, Strength (0-1) how much of it goes. Every machine sees it (players who join later too), collision and navigation too; only the chunks it reaches are built again (a moment later). Kept for the session: the saved world isn't changed. Server: a player's dig comes as Fire Server.",
		"inputs": [TERRAIN_INPUT, {"name": &"at", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE},
			{"name": &"size", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 2.0}},
			{"name": &"strength", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 1.0}}],
		"code": "_brickscript_change_terrain(&\"dig\", {at}, {size}, {strength}, Color.BLACK, {brick}, {terrain})", "helper": TERRAIN_CHANGE_HELPER, "helpers": [TERRAIN_HELPER, PLACE_HELPER],
	},
	&"fill_terrain": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Fill terrain", "contexts": [&"server"],
		"description": "Adds a ball of ground to the scene's Terrain at a spot or a node's position (see Dig terrain): close a hole, build a wall or a mound.",
		"inputs": [TERRAIN_INPUT, {"name": &"at", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE},
			{"name": &"size", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 2.0}},
			{"name": &"strength", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 1.0}}],
		"code": "_brickscript_change_terrain(&\"fill\", {at}, {size}, {strength}, Color.BLACK, {brick}, {terrain})", "helper": TERRAIN_CHANGE_HELPER, "helpers": [TERRAIN_HELPER, PLACE_HELPER],
	},
	&"paint_terrain": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Paint terrain", "contexts": [&"server"],
		"description": "Paints the ground of the scene's Terrain in a ball at a spot or a node's position (cave walls too), Strength (0-1) mixing the color in (see Dig terrain).",
		"inputs": [TERRAIN_INPUT, {"name": &"at", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE},
			{"name": &"size", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 2.0}},
			{"name": &"color", "types": [T.COLOR], "default": {"type": T.COLOR, "value": Color(0.8, 0.2, 0.2)}},
			{"name": &"strength", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 1.0}}],
		"code": "_brickscript_change_terrain(&\"paint\", {at}, {size}, {strength}, {color}, {brick}, {terrain})", "helper": TERRAIN_CHANGE_HELPER, "helpers": [TERRAIN_HELPER, PLACE_HELPER],
	},
	&"has_ground_at": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Has ground at",
		"description": "Whether the scene's Terrain has its ground in place at a spot or a node's position, collision too: a body dropped there lands. A Streamed terrain builds only around its viewers (players' characters, the camera), so check before spawning far away, or wait. False without a Terrain.",
		"inputs": [TERRAIN_INPUT, {"name": &"at", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE}],
		"result": "_brickscript_has_ground({at}, {brick}, {terrain})", "returns": T.BOOL, "helper": TERRAIN_HELPER, "helpers": [PLACE_HELPER],
	},
	&"biome_at": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Biome at",
		"description": "The name of the Terrain's biome (its TerrainBiome's name) with the most say at a spot or a node's position; empty Text when the Terrain has no biomes. From the seed: works anywhere, built there yet or not.",
		"inputs": [TERRAIN_INPUT, {"name": &"at", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE}],
		"result": "_brickscript_biome_at({terrain}, {at}, {brick})", "returns": T.TEXT, "helper": TERRAIN_MORE_HELPER, "helpers": [TERRAIN_HELPER, TERRAIN_CHANGE_HELPER, PLACE_HELPER],
	},
	&"solid_at": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Solid at",
		"description": "Whether a spot (or a node's position) is inside the Terrain's ground: caves, hand edits and digs counted. From the shape, so no collision needed: is a tunnel here, is this spot buried.",
		"inputs": [TERRAIN_INPUT, {"name": &"at", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE}],
		"result": "_brickscript_solid_at({terrain}, {at}, {brick})", "returns": T.BOOL, "helper": TERRAIN_MORE_HELPER, "helpers": [TERRAIN_HELPER, TERRAIN_CHANGE_HELPER, PLACE_HELPER],
	},
	&"build_terrain": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Build terrain", "contexts": [&"server"],
		"description": "Builds the Terrain's world again from its settings (what was there goes), first keeping its seed, picking a random one or a given one (Which seed): for a Terrain with Build on load off, or a new world each round. Every machine builds it too (players who join later as well); When terrain ready runs when it's done.",
		"inputs": [TERRAIN_INPUT, {"name": &"seed", "types": [T.WHOLE], "default": {"type": T.WHOLE, "value": 0}, "shown_when": {"setting": &"seed_is", "value": "This one"}, "unused": "0"}],
		"settings": [{"name": &"seed_is", "kind": "choice", "title": "Which seed", "options": TERRAIN_SEEDS, "default": "Keep it",
			"codes": {"Keep it": "0", "A random one": "1", "This one": "2"}, "info": "keep the Terrain's seed, pick a random one, or use Seed"}],
		"code": "_brickscript_build_terrain({terrain}, {seed_is}, {seed}, {brick})", "helper": TERRAIN_MORE_HELPER, "helpers": [TERRAIN_HELPER, TERRAIN_CHANGE_HELPER, PLACE_HELPER],
	},
	&"clear_terrain": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Clear terrain", "contexts": [&"server"],
		"description": "Takes the Terrain's world away on every machine (meshes, collision, navigation); Terrain height and Solid at still answer from its settings. Build terrain brings it back. When terrain cleared runs.",
		"inputs": [TERRAIN_INPUT],
		"code": "_brickscript_clear_terrain({terrain}, {brick})", "helper": TERRAIN_MORE_HELPER, "helpers": [TERRAIN_HELPER, TERRAIN_CHANGE_HELPER, PLACE_HELPER],
	},
	&"terrain_ray": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Terrain ray", "special": true, "output": true,
		"description": "Where a straight line from one point to another first meets the Terrain's ground (caves and digs counted), then Hit ground or No ground runs. From the shape, so no collision needed (works where the ground isn't built yet, or on a machine without collision). The Output is the point (To when there's no ground); Normal (Also fills): which way the ground faces there.",
		"exits": TERRAIN_RAY_EXITS, "exit_titles": TERRAIN_RAY_EXIT_TITLES, "branch": {"cases": [[&"hit", "_brickscript_terrain_hit[\"hit\"]"], [&"missed", "not _brickscript_terrain_hit[\"hit\"]"]]},
		"inputs": [TERRAIN_INPUT, {"name": &"from", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE},
			{"name": &"to", "types": [T.VECTOR3, T.NODE], "default": {"type": T.VECTOR3, "value": Vector3(0, -100, 0)}}],
		"settings": [{"name": &"normal_name", "kind": "name", "title": "Normal", "default": "", "suggest": "ground_normal", "made_type": T.VECTOR3,
			"info": "which way the ground faces where the line meets it, length 1; (0, 0, 0) when there's no ground (blank: not kept)"}],
		"names_header": "Also fills", "names_hint": "A chain variable later bricks of this event can read, or an existing one it writes into.",
	},
	&"random_open_spot": {
		"kind": Kind.ACTION, "category": "terrain", "title": "Random open spot", "special": true, "output": true,
		"description": "A random spot in open space (a cave, the air: not inside the Terrain's ground) within Radius of a spot or a node, between Height from and Height to: world Y, or how deep under the surface (Height is). Room: how much open space it needs around it. On a floor: open space with the ground right under it (the Output is the floor point: where to put a crystal or a monster). Checks Terrain + nodes: also clear of other bodies (crates, walls, characters; their collision, so only where it's in place). Up to Tries spots are tried, then Found or None found runs. From the Terrain's shape: works on every machine, built there yet or not.",
		"exits": OPEN_SPOT_EXITS, "exit_titles": OPEN_SPOT_EXIT_TITLES, "branch": {"cases": [[&"found", "_brickscript_open_spot[\"found\"]"], [&"none", "not _brickscript_open_spot[\"found\"]"]]},
		"inputs": [TERRAIN_INPUT, {"name": &"around", "types": [T.VECTOR3, T.NODE], "default": THIS_NODE},
			{"name": &"radius", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 20.0}},
			{"name": &"height_from", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 4.0}},
			{"name": &"height_to", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 30.0}},
			{"name": &"room", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 1.0}},
			{"name": &"tries", "types": [T.WHOLE], "default": {"type": T.WHOLE, "value": 30}}],
		"settings": [{"name": &"must_be", "kind": "choice", "title": "Must be", "options": OPEN_SPOT_MUST_BE, "default": "In the air",
				"codes": {"In the air": "false", "On a floor": "true"}, "info": "anywhere in open space, or on a floor (open space with the ground under it; the Output is the floor point)"},
			{"name": &"height_is", "kind": "choice", "title": "Height is", "options": OPEN_SPOT_HEIGHT_IS, "default": "Depth under the surface",
				"codes": {"World Y": "false", "Depth under the surface": "true"}, "info": "Height from / to as world Y, or as meters under the ground's surface there (caves on hills too)"},
			{"name": &"checks", "kind": "choice", "title": "Checks", "options": OPEN_SPOT_CHECKS, "default": "Terrain",
				"codes": {"Terrain": "false", "Terrain + nodes": "true"}, "info": "only the Terrain's ground, or also other bodies (crates, walls, characters: their collision, only where it's in place)"}],
	},
	&"event_terrain_ready": {
		"kind": Kind.EVENT, "category": "terrain", "title": "When terrain ready", "special": true,
		"description": "Runs when a Terrain (the Terrain Engine plugin) has built its ground (Streamed: around its viewers), with its collision and, on the server, its navigation: spawn players, NPCs or gems on it then. Also once at the start for a Terrain already ready, and again whenever one builds again (another seed). Gives the terrain. Never runs without the plugin.",
		"function": "", "function_params": [], "provides": {"terrain": T.NODE}, "terrain_signal": &"terrain_ready",
	},
	&"event_terrain_cleared": {
		"kind": Kind.EVENT, "category": "terrain", "title": "When terrain cleared", "special": true,
		"description": "Runs when a Terrain's world is taken away (Clear terrain, its clear_world(); on a client when the server's was): hide or remove what stood on it. Gives the terrain. Never runs without the plugin.",
		"function": "", "function_params": [], "provides": {"terrain": T.NODE}, "terrain_signal": &"cleared",
	},
	# Camera
	&"screen_to_world": {
		"kind": Kind.ACTION, "category": "camera", "title": "Mouse to World", "contexts": [&"local"], "special": true, "output": true,
		"description": "Where the mouse (or a screen point) points in the world, through a camera. 3D: a ray from the camera: the Output is its far end (To, Length away), From (Also fills) its start on the camera; give both to Raycast to find what's under the mouse. 2D: the mouse's world position. The server asks with Player Aim.",
		"inputs": [{"name": &"point", "types": [T.VECTOR2], "default": {"type": T.VECTOR2, "value": Vector2.ZERO}, "shown_when": {"setting": &"point_is", "value": SCREEN_POINT}, "unused": "get_viewport().get_mouse_position()"},
			RAY_LENGTH_INPUT, CAMERA_INPUT],
		"settings": [CAMERA_SPACE_SETTING,
			{"name": &"point_is", "kind": "choice", "title": "Point", "options": SCREEN_POINT_FROM, "default": "The mouse",
				"info": "the mouse, a point on the screen (Point: pixels from its top left), or the middle of the screen (a crosshair)"},
			CAMERA_WHICH_SETTING, RAY_FROM_SETTING],
		"names_header": "Also fills", "names_hint": "A chain variable later bricks of this event can read, or an existing one it writes into.",
	},
	&"player_aim": {
		"kind": Kind.ACTION, "category": "camera", "title": "Player Aim", "contexts": [&"server"], "special": true, "output": true,
		"description": "Server: where a player's mouse points through their camera, as their machine sees it (each client sends it when it moves). 3D: the Output is the far end of the ray (To, Length away), From (Also fills) its start; give both to Raycast for what they point at. 2D: their mouse's world position. (0, 0, 0) until their first aim arrives, or without a Camera3D in 3D.",
		"inputs": [{"name": &"player", "types": [T.PLAYER], "default": {"var": ""}}, RAY_LENGTH_INPUT],
		"settings": [CAMERA_SPACE_SETTING,
			{"name": &"through", "kind": "choice", "title": "Through", "options": AIM_THROUGH, "default": "The mouse",
				"info": "their mouse, or the middle of their screen: where their camera looks (a first-person game, the mouse captured; 3D)"},
			RAY_FROM_SETTING],
		"names_header": "Also fills", "names_hint": "A chain variable later bricks of this event can read, or an existing one it writes into.",
	},
	&"event_mouse_moved": {
		"kind": Kind.EVENT, "category": "camera", "title": "When mouse moves", "contexts": [&"local"],
		"description": "Runs when this machine's mouse moves: motion is how far (pixels; also while it's captured: mouse look), screen_point where it is now. For what this machine shows, like turning its camera; the server reads where players look with Player Aim.",
		"function": "_input", "function_params": INPUT_PARAMS, "guard": "event is InputEventMouseMotion",
		"prelude": "\tvar motion: Vector2 = (event as InputEventMouseMotion).relative if event is InputEventMouseMotion else Vector2.ZERO\n\tvar screen_point: Vector2 = (event as InputEventMouseMotion).position if event is InputEventMouseMotion else Vector2.ZERO",
		"provides": {"motion": T.VECTOR2, "screen_point": T.VECTOR2},
	},
	&"event_culled": {
		"kind": Kind.EVENT, "category": "camera", "title": "When culled / shown", "contexts": [&"local"], "special": true,
		"description": "Runs when a node is culled for this machine (out of its camera's view, or too small to see from here: hidden and slowed by the Cull Throttle Engine) or seen again. For what this machine shows: stop a sound or an effect nobody here sees, start it again. Gives the node (the object culled) and culled (true: culled, false: shown). Whose: this node (the object it's part of) or any node. Needs the Cull Throttle Engine plugin; without it, it never runs.",
		"function": "", "function_params": [], "provides": {"node": T.NODE, "culled": T.BOOL}, "culled_signal": true,
		"settings": [{"name": &"which", "kind": "choice", "title": "When", "options": CULL_WHICH, "default": "Culled or shown", "info": "on being culled, on being shown again, or both"},
			{"name": &"whose", "kind": "choice", "title": "Whose", "options": CULL_WHOSE, "default": "This node", "info": "this node (the object it's part of), or any node"}],
	},
	&"is_culled_here": {
		"kind": Kind.ACTION, "category": "camera", "title": "Is culled here", "contexts": [&"local"],
		"description": "Whether a node (the parent by default) is culled for this machine right now: out of its camera's view or too small to see from here (the Cull Throttle Engine hides it and slows it). A Bool, for If: skip costly effects nobody here sees. Always false without the Cull Throttle Engine plugin.",
		"inputs": [{"name": &"node", "types": [T.NODE], "default": PARENT_NODE}],
		"result": "_brickscript_is_culled_here({node})", "returns": T.BOOL, "helper": CULL_HELPER,
	},
	&"mouse_mode": {
		"kind": Kind.ACTION, "category": "camera", "title": "Mouse mode", "contexts": [&"local"],
		"description": "How this machine's mouse behaves: Visible (normal), Captured (hidden and locked: mouse look in a first-person game; When mouse moves still gets motion), Confined (kept in the window) or Hidden.",
		"settings": [{"name": &"mode", "kind": "choice", "title": "Mode", "options": ["Visible", "Captured", "Confined", "Hidden"], "default": "Captured", "codes": MOUSE_MODES,
			"info": "Captured for mouse look; Visible to give the mouse back (e.g. on Esc)"}],
		"code": "Input.mouse_mode = {mode}",
	},
	&"world_to_screen": {
		"kind": Kind.ACTION, "category": "camera", "title": "World to Screen", "contexts": [&"local"], "special": true, "output": true,
		"description": "Where a world position shows on the screen, through a camera (pixels from the screen's top left, a Vector2): for name tags and markers over things. On screen (Also fills) is false when it's behind the camera or off the edges. A Vector3 goes through a Camera3D, a Vector2 through the 2D view.",
		"inputs": [{"name": &"position", "types": Types.VECTORS, "default": {"type": T.VECTOR3, "value": Vector3.ZERO}}, CAMERA_INPUT],
		"settings": [CAMERA_WHICH_SETTING,
			{"name": &"on_screen_name", "kind": "name", "title": "On screen", "default": "", "suggest": "on_screen", "made_type": T.BOOL,
				"info": "whether it's on the screen: in front of the camera and inside the edges (blank: not kept)"}],
		"names_header": "Also fills", "names_hint": "A chain variable later bricks of this event can read, or an existing one it writes into.",
	},
	&"shake_camera": {
		"kind": Kind.ACTION, "category": "camera", "title": "Shake Camera", "contexts": [&"local"],
		"description": "Shakes a camera (this screen's by default) for a while, fading out: hits, explosions, landing. It moves the camera's offset only, so it doesn't fight what moves the camera. Strength is in world units for a Camera3D (try 0.2), pixels for a Camera2D (try 8).",
		"inputs": [{"name": &"strength", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 0.2}},
			{"name": &"duration", "types": Types.NUMERIC, "default": {"type": T.NUMBER, "value": 0.4}}, CAMERA_INPUT],
		"settings": [CAMERA_WHICH_SETTING],
		"code": "_brickscript_shake({camera}, {strength}, {duration}, {brick})", "helper": SHAKE_HELPER,
	},
	# Mesh
	&"begin_mesh": {
		"kind": Kind.ACTION, "category": "mesh", "title": "Begin mesh",
		"description": "Starts building a new mesh for a MeshInstance3D (the parent by default): Add triangle, Add quad and Add shape add to it, Finish mesh shows it (until then the node keeps the mesh it has).",
		"inputs": [MESH_INPUT],
		"code": "_brickscript_mesh_begin({mesh}, {brick})", "helper": MESH_HELPER,
	},
	&"add_triangle": {
		"kind": Kind.ACTION, "category": "mesh", "title": "Add triangle",
		"description": "Adds a triangle (corners A, B, C, in the MeshInstance3D's own space) in a color to the mesh being built. Its front is the side the corners go round clockwise; Finish mesh's Sides: Both sides shows the back too.",
		"inputs": [MESH_INPUT, {"name": &"a", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3.ZERO}},
			{"name": &"b", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3(1, 0, 0)}},
			{"name": &"c", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3(0, 0, 1)}}, MESH_COLOR_INPUT],
		"code": "_brickscript_mesh_add({mesh}, [_BrickscriptMeshes.TRIANGLE, {a}, {b}, {c}, {color}], {brick})", "helper": MESH_HELPER,
	},
	&"add_quad": {
		"kind": Kind.ACTION, "category": "mesh", "title": "Add quad",
		"description": "Adds a four-cornered face (corners A, B, C, D in order round its edge: two triangles, A B C and A C D) in a color to the mesh being built. Its front is the side they go round clockwise.",
		"inputs": [MESH_INPUT, {"name": &"a", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3.ZERO}},
			{"name": &"b", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3(1, 0, 0)}},
			{"name": &"c", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3(1, 0, 1)}},
			{"name": &"d", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3(0, 0, 1)}}, MESH_COLOR_INPUT],
		"code": "_brickscript_mesh_add({mesh}, [_BrickscriptMeshes.QUAD, {a}, {b}, {c}, {d}, {color}], {brick})", "helper": MESH_HELPER,
	},
	&"add_shape": {
		"kind": Kind.ACTION, "category": "mesh", "title": "Add shape",
		"description": "Adds a box, sphere, cylinder or plane (facing up) to the mesh being built: its middle At, Size across (a sphere 1 wide is 1 across; a cylinder's y is its height; a plane uses x and z), in a color.",
		"inputs": [MESH_INPUT, {"name": &"at", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3.ZERO}},
			{"name": &"size", "types": [T.VECTOR3], "default": {"type": T.VECTOR3, "value": Vector3.ONE}}, MESH_COLOR_INPUT],
		"settings": [{"name": &"shape", "kind": "choice", "title": "Shape", "options": MESH_SHAPE_NAMES, "default": "Box", "codes": MESH_SHAPES,
			"info": "a box, a sphere, a cylinder (standing up) or a flat plane facing up"}],
		"code": "_brickscript_mesh_add({mesh}, [_BrickscriptMeshes.SHAPE, {shape}, {at}, {size}, {color}], {brick})", "helper": MESH_HELPER,
	},
	&"finish_mesh": {
		"kind": Kind.ACTION, "category": "mesh", "title": "Finish mesh",
		"description": "Builds what was added since Begin mesh into the MeshInstance3D's mesh, colored by what was added. Shading: Flat (each triangle a face of its own: a cut-gem look) or Smooth (corners in the same place are one point, shaded round). Sides: Both sides, or One side (only the fronts: cheaper, for closed shapes).",
		"inputs": [MESH_INPUT], "local_target": &"mesh",
		"settings": [{"name": &"shading", "kind": "choice", "title": "Shading", "options": ["Flat", "Smooth"], "default": "Flat", "codes": {"Flat": "false", "Smooth": "true"},
				"info": "Flat: every triangle its own face (shapes keep their own shading); Smooth: shared corners joined and shaded round (deforming with Mesh vertices keeps it whole)"},
			{"name": &"sides", "kind": "choice", "title": "Sides", "options": ["Both sides", "One side"], "default": "Both sides", "codes": {"Both sides": "true", "One side": "false"},
				"info": "show the back of each triangle too, or only its front (clockwise)"}],
		"code": "_brickscript_mesh_finish({mesh}, {shading}, {sides}, {server}, {brick})", "helper": MESH_HELPER,
	},
	&"mesh_vertices": {
		"kind": Kind.ACTION, "category": "mesh", "title": "Mesh vertices", "special": true, "output": true, "returns": T.LIST,
		"description": "A MeshInstance3D's points (Positions: a List of Vector3s, in its own space) or their Colors (a List of Colors). Get reads them into the Output; Set puts a List of as many back (its shading is worked out again). To deform a mesh: Get, change them (For each item, Formula), Set. Any mesh's first surface works; a Smooth one has one point per corner, a Flat one a point per triangle corner.",
		"inputs": [MESH_INPUT, {"name": &"value", "types": [T.LIST], "default": {"var": ""}, "shown_when": {"setting": &"mode", "value": "Set"}}],
		"settings": [{"name": &"mode", "kind": "choice", "title": "Mode", "options": MESH_MODES, "default": "Get", "info": "Get reads them (into the Output); Set puts a List back"},
			{"name": &"of", "kind": "choice", "title": "Of", "options": MESH_POINTS_OF, "default": "Positions", "info": "where the points are (Vector3s), or their colors"}],
	},
	# Lists and tables
	&"make_list": {
		"kind": Kind.ACTION, "category": "lists", "title": "Make list", "description": "Builds a List from values (+ / - for more or fewer). It knows what its items are (a List of Number, of Label...): Auto works it out from the values, or pick it.",
		"variadic": {"inputs": [{"name": &"item", "types": [], "default": ZERO}], "min": 0, "default_count": 2},
		"settings": [{"name": &"items", "kind": "choice", "title": "Items", "options": LIST_ITEM_CHOICES, "default": LIST_ITEMS_AUTO,
			"info": "Auto: from the values (mixed values make a List of Anything), or the type every item must be"}],
		"result": "", "join": {"open": "[", "row": "{item}", "separator": ", ", "close": "]"}, "returns": T.LIST,
	},
	&"make_table": {
		"kind": Kind.ACTION, "category": "lists", "title": "Make table", "description": "Builds a Table from key/value rows (+ / - for more or fewer). It knows what its keys and values are (a Table of Text -> Number...): Auto works them out from the rows, or pick them.",
		"variadic": {"inputs": [{"name": &"key", "types": [], "default": ANY_TEXT_KEY}, {"name": &"value", "types": [], "default": ZERO}], "min": 0, "default_count": 1},
		"settings": [{"name": &"keys", "kind": "choice", "title": "Keys", "options": LIST_ITEM_CHOICES, "default": LIST_ITEMS_AUTO,
				"info": "Auto: from the keys (mixed keys make Anything), or the type every key must be"},
			{"name": &"values", "kind": "choice", "title": "Values", "options": LIST_ITEM_CHOICES, "default": LIST_ITEMS_AUTO,
				"info": "Auto: from the values (mixed values make Anything), or the type every value must be"}],
		"result": "", "join": {"open": "{", "row": "{key}: {value}", "separator": ", ", "close": "}"}, "returns": T.TABLE,
	},
	&"get_item": {
		"kind": Kind.ACTION, "category": "lists", "title": "Get item", "description": "Reads one item of a List by its index (0 is the first). Out of range is an error when the game runs.",
		"inputs": [{"name": &"list", "types": [T.LIST], "default": {"var": ""}}, {"name": &"index", "types": Types.NUMERIC, "default": {"type": T.WHOLE, "value": 0}}],
		"result": "{list}[{index}]", "returns": T.ANY,
	},
	&"unpack_table": {
		"kind": Kind.ACTION, "category": "lists", "title": "Unpack table", "special": true,
		"description": "Reads chosen keys of a Table into variables named after them, at once: keys speed and jump make the chain variables speed and jump (or write into existing ones of those names). A missing key gives its type's zero (0, \"\", false; nothing for Anything). Keys are names: letters, digits and _.",
		"inputs": [{"name": &"table", "types": [T.TABLE], "default": {"var": ""}}],
		"variadic": {"inputs": [{"name": &"key", "types": [T.TEXT], "default": {"type": T.TEXT, "value": "key"}, "literal_only": true}], "min": 1, "default_count": 2},
	},
	&"get_value": {
		"kind": Kind.ACTION, "category": "lists", "title": "Get value", "description": "Reads a Table's value for a key, or the fallback if the key isn't there. From a typed Table (Text -> Number...) it's of the values' type.",
		"inputs": [{"name": &"table", "types": [T.TABLE], "default": {"var": ""}}, {"name": &"key", "types": [], "default": ANY_TEXT_KEY}, {"name": &"fallback", "types": [], "default": ZERO}],
		"result": "{table}.get({key}, {fallback})", "returns": T.ANY,
	},
	&"list_add": {
		"kind": Kind.ACTION, "category": "lists", "title": "Add to list", "description": "Adds a value to the end of a List variable.",
		"inputs": [{"name": &"list", "types": [T.LIST], "default": {"var": ""}, "writes": true}, {"name": &"value", "types": [], "default": ZERO}],
		"code": "{list}.append({value})",
	},
	&"list_remove": {
		"kind": Kind.ACTION, "category": "lists", "title": "Remove item at", "description": "Removes the item at an index from a List variable.",
		"inputs": [{"name": &"list", "types": [T.LIST], "default": {"var": ""}, "writes": true}, {"name": &"index", "types": Types.NUMERIC, "default": {"type": T.WHOLE, "value": 0}}],
		"code": "{list}.remove_at({index})",
	},
	&"table_set": {
		"kind": Kind.ACTION, "category": "lists", "title": "Set value in table", "description": "Sets (or adds) a key's value in a Table variable.",
		"inputs": [{"name": &"table", "types": [T.TABLE], "default": {"var": ""}, "writes": true}, {"name": &"key", "types": [], "default": ANY_TEXT_KEY}, {"name": &"value", "types": [], "default": ZERO}],
		"code": "{table}[{key}] = {value}",
	},
	&"table_remove": {
		"kind": Kind.ACTION, "category": "lists", "title": "Remove key", "description": "Removes a key (and its value) from a Table variable.",
		"inputs": [{"name": &"table", "types": [T.TABLE], "default": {"var": ""}, "writes": true}, {"name": &"key", "types": [], "default": ANY_TEXT_KEY}],
		"code": "{table}.erase({key})",
	},
	&"size": {
		"kind": Kind.ACTION, "category": "lists", "title": "Size", "description": "How many items a List has, keys a Table has, or characters a Text has.",
		"inputs": [{"name": &"of", "types": COLLECTION_TYPES, "default": {"var": ""}}],
		"result": "len({of})", "returns": T.WHOLE,
	},
	&"has": {
		"kind": Kind.ACTION, "category": "lists", "title": "Has", "description": "Whether a List contains an item, a Table has a key, or a Text contains some text.",
		"inputs": [{"name": &"collection", "types": COLLECTION_TYPES, "default": {"var": ""}}, {"name": &"item", "types": [], "default": ANY_TEXT_KEY}],
		"result": "{item} in {collection}", "returns": T.BOOL,
	},
	# Math
	&"add": {
		"kind": Kind.ACTION, "category": "math", "title": "Add", "description": "Adds two numbers or vectors.",
		"inputs": [{"name": &"a", "types": MATH_TYPES, "default": ZERO}, {"name": &"b", "types": MATH_TYPES, "default": ZERO}],
		"result": "{a} + {b}", "returns": &"arith",
	},
	&"subtract": {
		"kind": Kind.ACTION, "category": "math", "title": "Subtract", "description": "Subtracts B from A (numbers or vectors).",
		"inputs": [{"name": &"a", "types": MATH_TYPES, "default": ZERO}, {"name": &"b", "types": MATH_TYPES, "default": ZERO}],
		"result": "{a} - {b}", "returns": &"arith",
	},
	&"multiply": {
		"kind": Kind.ACTION, "category": "math", "title": "Multiply", "description": "Multiplies two numbers, or scales a vector by a number.",
		"inputs": [{"name": &"a", "types": MATH_TYPES, "default": ZERO}, {"name": &"b", "types": MATH_TYPES, "default": ZERO}],
		"result": "{a} * {b}", "returns": &"arith",
	},
	&"divide": {
		"kind": Kind.ACTION, "category": "math", "title": "Divide", "description": "Divides A by B. Two whole numbers give a decimal (7 / 2 = 3.5).",
		"inputs": [{"name": &"a", "types": MATH_TYPES, "default": ZERO}, {"name": &"b", "types": MATH_TYPES, "default": {"type": T.NUMBER, "value": 1.0}}],
		"result": "{a} / {b}", "returns": &"divide",
	},
	&"make_vector2": {
		"kind": Kind.ACTION, "category": "math", "title": "Construct Vector2", "description": "Builds a Vector2 from x and y.",
		"inputs": [{"name": &"x", "types": Types.NUMERIC, "default": ZERO}, {"name": &"y", "types": Types.NUMERIC, "default": ZERO}],
		"result": "Vector2({x}, {y})", "returns": T.VECTOR2,
	},
	&"make_vector3": {
		"kind": Kind.ACTION, "category": "math", "title": "Construct Vector3", "description": "Builds a Vector3 from x, y and z.",
		"inputs": [{"name": &"x", "types": Types.NUMERIC, "default": ZERO}, {"name": &"y", "types": Types.NUMERIC, "default": ZERO}, {"name": &"z", "types": Types.NUMERIC, "default": ZERO}],
		"result": "Vector3({x}, {y}, {z})", "returns": T.VECTOR3,
	},
}


## Brick families (user, 2026-11-03): bricks that do one thing several ways
## share one palette entry (and one add-menu item), and the first dropdown in
## Properties picks the way. The way is the brick's type: picking another
## one changes it (Ops.change_type()), so files, the compiler and the code
## made are the members' own; the canvas shows the member's title.
## Each: title (the palette's), setting (the dropdown's name), description,
## members: [[option, type], ...] (the first usable one is what's added).
## Members share a category and a kind (all events or all actions).
const FAMILIES: Dictionary[StringName, Dictionary] = {
	&"action_input": {"title": "When action", "setting": "When", "members": [["Pressed", &"event_action_pressed"], ["Released", &"event_action_released"], ["Held", &"event_action_held"]],
		"description": "Runs when an Input Map action is pressed, when it's released, or every frame while it's held (When). Local brickscripts: this machine's keys."},
	&"player_input": {"title": "Player action", "setting": "When", "members": [["Pressed", &"event_player_pressed"], ["Released", &"event_player_released"], ["Held", &"event_player_holds"]],
		"description": "Server brickscripts: runs when a player presses an Input Map action, releases it, or every frame while they hold it (When), giving the player."},
	&"math": {"title": "Math", "setting": "Operation", "members": [["Add", &"add"], ["Subtract", &"subtract"], ["Multiply", &"multiply"], ["Divide", &"divide"]],
		"description": "A + B, A - B, A × B or A / B (Operation), numbers or vectors. Longer sums: Formula."},
	&"construct_vector": {"title": "Construct vector", "setting": "Size", "members": [["Vector2", &"make_vector2"], ["Vector3", &"make_vector3"]],
		"description": "Builds a Vector2 from x and y, or a Vector3 from x, y and z (Size)."},
	&"change_terrain": {"title": "Change terrain", "setting": "Mode", "members": [["Dig", &"dig_terrain"], ["Fill", &"fill_terrain"], ["Paint", &"paint_terrain"]],
		"description": "Digs a ball of the scene's Terrain away, fills one in, or paints its ground (Mode), at a spot or a node's position. Every machine sees it, players who join later too."},
	&"build_clear_terrain": {"title": "Build or clear terrain", "setting": "Mode", "members": [["Build", &"build_terrain"], ["Clear", &"clear_terrain"]],
		"description": "Builds the Terrain's world again from its settings (Build on load off, a new seed each round), or takes it away (Mode). On every machine, players who join later too."},
	&"terrain_event": {"title": "When terrain", "setting": "When", "members": [["Ready", &"event_terrain_ready"], ["Cleared", &"event_terrain_cleared"]],
		"description": "Runs when the Terrain's world is built and ready (collision too), or when it's cleared away (When)."},
	&"add_to_mesh": {"title": "Add to mesh", "setting": "Kind", "members": [["Triangle", &"add_triangle"], ["Quad", &"add_quad"], ["Shape", &"add_shape"]],
		"description": "Adds a triangle, a quad, or a shape (box, sphere, cylinder, plane) to the mesh a Begin mesh started (Kind)."},
	&"walk": {"title": "Walk", "setting": "Mode", "members": [["To a spot", &"walk_to"], ["Follow", &"follow"], ["Stop", &"stop_walking"]],
		"description": "Server: a character steered by scripts (Controlled by: Script) walks to a spot or a node along the navigation, keeps following a node, or stops walking (Mode)."},
	&"group": {"title": "Group", "setting": "Mode", "members": [["Add", &"add_to_group"], ["Remove", &"remove_from_group"], ["Check", &"is_in_group"]],
		"description": "Puts a node in a group, takes it out, or checks whether it's in one (Mode; Check gives true / false)."},
	&"health": {"title": "Health", "setting": "Mode", "members": [["Damage", &"damage"], ["Heal", &"heal"], ["Kill", &"kill_character"]],
		"description": "Takes health from a character, gives it back, or kills it (Mode). Server brickscripts."},
	&"network_session": {"title": "Network session", "setting": "Action", "members": [["Host", &"host"], ["Join", &"join"], ["Leave", &"leave"]],
		"description": "Hosts a networked game, joins one at an address, or leaves the one this machine is in (Action). Local brickscripts, with the Network Context Engine."},
	&"player_presence": {"title": "When player joins or leaves", "setting": "When", "members": [["Joined", &"event_player_joined"], ["Left", &"event_player_left"]],
		"description": "Runs when a player joins the game or leaves it (When), giving the player."},
	&"player_data": {"title": "Player data", "setting": "Mode", "members": [["Save", &"save_player_data"], ["Load", &"load_player_data"]],
		"description": "Saves a player's values (under Players/<name>) on the server's disk under their user ID, or loads the saved ones back (Mode). Server brickscripts."},
	&"animation": {"title": "Animation", "setting": "Mode", "members": [["Play", &"play_animation"], ["Stop", &"stop_animation"]],
		"description": "Plays an animation of an AnimationPlayer or animated sprite, or stops it (Mode), on every machine. Server brickscripts (UI animation: local ones)."},
	&"ui_animation": {"title": "UI animation", "setting": "Mode", "members": [["Play", &"play_ui_animation"], ["Stop", &"stop_ui_animation"]],
		"description": "Plays or stops an animation of this machine's UI, camera or effects (Mode). Local brickscripts."},
	&"tween": {"title": "Tween", "setting": "Mode", "members": [["Start", &"tween_property"], ["Stop", &"stop_tweens"]],
		"description": "Moves a property smoothly to a value over some seconds, or stops a node's tweens (Mode)."},
}
static var _family_by_type: Dictionary[StringName, StringName] = {}


## The family `type` belongs to (&"" if none).
static func family_of(type: StringName) -> StringName:
	if _family_by_type.is_empty():
		for family: StringName in FAMILIES:
			for member: Array in FAMILIES[family]["members"]:
				_family_by_type[member[1]] = family
	return _family_by_type.get(type, &"")


## A family's member types, in order.
static func family_types(family: StringName) -> Array[StringName]:
	var types: Array[StringName] = []
	for member: Array in FAMILIES.get(family, {}).get("members", []):
		types.append(member[1])
	return types


## The option that picks `type` in its family's dropdown ("" if none).
static func family_option(type: StringName) -> String:
	for member: Array in FAMILIES.get(family_of(type), {}).get("members", []):
		if member[1] == type:
			return member[0]
	return ""


## Whether `type` is listed in the palette / add menu: a brick outside any
## family, or the first of its family's members that `usable` allows (the
## one a family's entry adds). `usable`: type -> bool (context.can_use).
static func listed(type: StringName, usable: Callable) -> bool:
	if not usable.call(type):
		return false
	var family: StringName = family_of(type)
	if family == &"":
		return true
	for member: StringName in family_types(family):
		if usable.call(member):
			return member == type
	return false


## The palette title of `type`'s entry: its family's, or its own.
static func listed_title(type: StringName) -> String:
	var family: StringName = family_of(type)
	return FAMILIES[family]["title"] if family != &"" else get_definition(type).get("title", String(type))


## What a palette search matches for `type`'s entry: a family's entry also
## matches its members' titles, options and type names ("Dig" finds Change
## terrain).
static func search_text(type: StringName) -> String:
	var family: StringName = family_of(type)
	if family == &"":
		return "%s %s" % [get_definition(type).get("title", ""), type]
	var parts: PackedStringArray = [FAMILIES[family]["title"], family]
	for member: Array in FAMILIES[family]["members"]:
		parts.append_array([member[0], get_definition(member[1]).get("title", ""), member[1]])
	return " ".join(parts)


static func get_definition(type: StringName) -> Dictionary:
	return NODES.get(type, {})


## Exit names of an action node (events number theirs).
static func exits_of(type: StringName) -> Array:
	return get_definition(type).get("exits", [&"next"])


## Whether the node makes a value (and so has an Output section).
## Property's / Variable's mode (a brick saved without one: Set).
static func mode_of(node: BrickscriptFlowNode) -> String:
	return str(node.settings.get(&"mode", "Set"))


## Whether this brick gives an Output (has_output(), and for Property /
## Variable only in Get mode).
static func node_has_output(node: BrickscriptFlowNode) -> bool:
	if node.type == &"set_property" or node.type == &"set_var":
		return mode_of(node) == "Get"
	if node.type == &"mesh_vertices":
		return str(node.settings.get(&"mode", "Get")) == "Get"
	return has_output(node.type)


static func has_output(type: StringName) -> bool:
	var definition: Dictionary = get_definition(type)
	return definition.has("result") or definition.get("output", false) or type == &"formula"


## Whether a brick may be used in a graph of `graph_context` (&"local" /
## &"server"), with or without the Network Context Engine. A shared
## brickscript holds only functions (no other events); Used by Both (local)
## only bricks that work on either side.
static func usable_in(type: StringName, graph_context: StringName, network_available: bool, shared: bool = false) -> bool:
	var definition: Dictionary = get_definition(type)
	if definition.is_empty() or definition.get("network", false) and not network_available:
		return false
	if shared and definition["kind"] == Kind.EVENT and type != &"define_function":
		return false
	if not definition.has("contexts"):
		return true
	if shared and graph_context == &"local":
		return (definition["contexts"] as Array).has(&"local") and (definition["contexts"] as Array).has(&"server")
	return (definition["contexts"] as Array).has(graph_context)
