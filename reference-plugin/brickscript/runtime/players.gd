@icon("res://addons/brickscript/icons/nodes/players.svg")
class_name BrickscriptPlayers
extends Node

## The players in the game (like Roblox's Players service): a child
## BrickscriptPlayer per player, named after them, on every machine. Put one
## in the game scene (a scene without one gets one when a brickscript first
## asks for a player). Every player node gets a copy of StarterPlayer's
## children (`starter`, a BrickscriptStarter): Object values (starting at
## those values each game) and per-player brickscripts (LocalScript only on
## that player's machine, ServerScript where the game runs). Nothing is
## saved: the Save / Load player data bricks do that (server brickscripts).
## - Names: each machine sends its profile (username + user ID, saved on
##   that machine: profile.gd); the server gives every player a unique node
##   name in the order they joined (a second "xdmonster" is "xdmonster_2").
## - Values under a player: the server's changes travel with the player's
##   data (the Network Context Engine's player list, by name only), so late
##   joiners get them too.
## Without the engine it's single-player: one player, you (1).

## The group the Players node is in (one per game).
const GROUP: StringName = &"brickscript_players"
const Profile: GDScript = preload("res://addons/brickscript/runtime/profile.gd")
## Player data keys: the profile (each machine its own), the node name
## (the server's), and values ("value:" + the path under the player).
const USERNAME_KEY: String = "username"
const USER_ID_KEY: String = "user_id"
const NAME_KEY: String = "display_name"
const VALUE_KEY: String = "value:"

## Where Save player data keeps players' values (on the server's disk, a
## file per user ID). Tests point it elsewhere.
static var save_folder: String = "user://brickscript_saves/"

## Emitted on every machine when a player's node is added / about to go.
signal player_added(player: BrickscriptPlayer)
signal player_removing(player: BrickscriptPlayer)
## Emitted on every machine when a value under a player changes (the
## server's change, or its arriving here): its path under the player.
signal player_value_changed(player: BrickscriptPlayer, value_name: String, value: Variant)

## One made for a scene without one, until it's in the tree.
static var _made: BrickscriptPlayers = null
## The one of() found last.
static var _current: BrickscriptPlayers = null

## Made for a scene without one (a scene's own replaces it).
var _auto: bool = false
## In the tree and not leaving it.
var _live: bool = false
## The engine it started with was renamed, freed or replaced (tests' stand-ins).
var _stale: bool = false
var _engine: Node = null
## Which engine it started with (a freed one compares equal to null).
var _engine_id: int = 0
var _started: bool = false
## What every player node starts with (empty: none).
@export var starter: NodePath = ^"../StarterPlayer"

var _players: Dictionary[int, BrickscriptPlayer] = {}
## The StarterPlayer found when ready (null: none).
var _starter: BrickscriptStarter = null
var _template_taken: bool = false
## Server: who joined in which order (it names them in that order).
var _order: Array[int] = []


## The game's Players node: the scene's, or one made for it.
static func of(from: Node) -> BrickscriptPlayers:
	# (Asked for every player value a brick gives: the last one found, while
	# it's still the game's, without searching the tree.)
	if is_instance_valid(_current) and _current._live and not _current._stale:
		return _current
	var tree: SceneTree = from.get_tree() if from.is_inside_tree() else Engine.get_main_loop() as SceneTree
	for found: Node in tree.get_nodes_in_group(GROUP):
		if not found.is_queued_for_deletion():
			(found as BrickscriptPlayers)._follow_engine(tree)
			_current = found as BrickscriptPlayers
			return _current
	if is_instance_valid(_made) and not _made.is_queued_for_deletion() and not _made.is_inside_tree():
		_made._follow_engine(tree)
		return _made
	_made = BrickscriptPlayers.new()
	_made.name = "Players"
	_made._auto = true
	_made._start(tree)
	var parent: Node = tree.current_scene if tree.current_scene != null else tree.root
	parent.add_child.call_deferred(_made)
	return _made


## A player's node (null for 0: no player).
static func player_of(from: Node, peer: int) -> BrickscriptPlayer:
	if peer == 0:
		return null
	# (Every event with a player and every brick giving one asks: the known
	# player of the current Players node at once.)
	if is_instance_valid(_current) and _current._live and not _current._stale:
		var known: BrickscriptPlayer = _current._players.get(peer)
		# (A player's node leaves the list as it's freed.)
		if is_instance_valid(known):
			return known
	return of(from).player(peer)


## Sends this machine's profile (username, user ID) to the engine each time
## it starts hosting or joining, so the server knows every player's name
## even when nothing on this machine asks for a player (no Players node
## here: a client whose brickscripts are all server ones). Called once by
## the BrickscriptDebug autoload; a Players node sends it too.
static func announce_profile(engine: Node) -> void:
	if engine == null or not engine.has_signal(&"context_changed") or not engine.has_method(&"set_player_data"):
		return
	engine.connect(&"context_changed", func(_new: int, old: int) -> void:
		# (Leaving offline only: connecting then joined is one session.)
		if old != 0:
			return
		var profile: Dictionary = Profile.load_profile()
		engine.call(&"set_player_data", USERNAME_KEY, profile["username"])
		engine.call(&"set_player_data", USER_ID_KEY, profile["user_id"]))


## A player node's number in the network (0 for null).
static func peer_of(player: Node) -> int:
	return int(player.get(&"peer_id")) if is_instance_valid(player) else 0


func _enter_tree() -> void:
	if not _auto:
		for other: Node in get_tree().get_nodes_in_group(GROUP):
			if other != self and other.get(&"_auto"):
				other.queue_free()
				other.remove_from_group(GROUP)
		_current = self
	_live = true
	add_to_group(GROUP)
	# Every machine builds its own player nodes from the players' data (the
	# engine neither sends the server's nor removes a client's).
	add_to_group(&"local_only")
	_start(get_tree())


func _ready() -> void:
	_take_template()


func _exit_tree() -> void:
	_live = false
	if _made == self:
		_made = null


## The node of player `peer`, made if the game has that player.
func player(peer: int) -> BrickscriptPlayer:
	var found: BrickscriptPlayer = _players.get(peer)
	if is_instance_valid(found) and not found.is_queued_for_deletion():
		return found
	if not _has_player(peer):
		return null
	return _add(peer)


## Every player's node, in join order (on the server; elsewhere by number).
func all() -> Array[BrickscriptPlayer]:
	var found: Array[BrickscriptPlayer] = []
	for peer: int in _peers():
		var node: BrickscriptPlayer = player(peer)
		if node != null:
			found.append(node)
	return found


## A value under a player changed here: heard by Player Value Changed; the
## server sends it with the player (`send`: not when it arrived from there).
func value_changed(player_node: Node, value: Node, send: bool = true) -> void:
	var path: String = String(player_node.get_path_to(value))
	player_value_changed.emit(player_node, path, value.get(&"value"))
	if send and _engine != null and _is_server():
		_ask(&"set_player_data_for", [peer_of(player_node), VALUE_KEY + path, value.get(&"value")])


## Server: writes `player_node`'s values (its Object values, by their path
## under it) to this machine's disk, under its user ID (Save player data).
func save_data(player_node: Node) -> Error:
	var file_path: String = _save_path(player_node, "Save player data")
	if file_path.is_empty():
		return ERR_UNAVAILABLE
	DirAccess.make_dir_recursive_absolute(save_folder)
	var file: ConfigFile = ConfigFile.new()
	for value: Node in _values_of(player_node):
		file.set_value("values", String(player_node.get_path_to(value)), value.get(&"value"))
	file.set_value("player", "username", player_node.get(&"username"))
	return file.save(file_path)


## Server: sets `player_node`'s values to the ones Save player data wrote for
## its user ID (each value it has; the server sends them). False: nothing
## saved for them (or not the server).
func load_data(player_node: Node) -> bool:
	var file_path: String = _save_path(player_node, "Load player data")
	if file_path.is_empty() or not FileAccess.file_exists(file_path):
		return false
	var file: ConfigFile = ConfigFile.new()
	if file.load(file_path) != OK:
		return false
	for value: Node in _values_of(player_node):
		var key: String = String(player_node.get_path_to(value))
		if file.has_section_key("values", key):
			value.set(&"value", file.get_value("values", key))
	return true


## The player's save file, or "" (with an error) when it can't be used here.
func _save_path(player_node: Node, brick: String) -> String:
	if not player_node is BrickscriptPlayer:
		push_error("%s: no player." % brick)
		return ""
	if _engine != null and not _is_server():
		push_error("%s: only the server keeps players' data." % brick)
		return ""
	var user_id: String = str(player_node.get(&"user_id")).validate_filename()
	if user_id.is_empty():
		push_error("%s: %s has no user ID yet." % [brick, player_node.name])
		return ""
	return save_folder.path_join(user_id + ".cfg")


## This machine's username changed (the menu's Name box): saved and sent.
func set_my_username(username: String) -> void:
	var saved: String = Profile.save_username(username)
	if _engine != null:
		_ask(&"set_player_data", [USERNAME_KEY, saved])
	if _is_server():
		_name_everyone()
	elif _engine == null:
		var me: BrickscriptPlayer = player(1)
		if me != null:
			me.username = saved
			me.name = saved


## The engine was replaced (a test's stand-in): start over with this one.
func _follow_engine(tree: SceneTree) -> void:
	var now: Node = tree.root.get_node_or_null(^"NetworkEngine")
	if not _started or not _stale and (now.get_instance_id() if now != null else 0) == _engine_id:
		return
	if is_instance_valid(_engine):
		for hooked: Array in [[&"player_joined", _on_joined], [&"player_left", _on_left], [&"player_data_changed", _on_data], [&"context_changed", _on_context]]:
			if _engine.has_signal(hooked[0]) and _engine.is_connected(hooked[0], hooked[1]):
				_engine.disconnect(hooked[0], hooked[1])
	_started = false
	_stale = false
	_start(tree)


## Calls the engine by name (an older one, or a test's stand-in, may lack a
## method: then `fallback`).
func _ask(method: StringName, args: Array, fallback: Variant = null) -> Variant:
	if _engine == null or not _engine.has_method(method):
		return fallback
	return _engine.callv(method, args)


func _start(tree: SceneTree) -> void:
	if _started:
		return
	_engine = tree.root.get_node_or_null(^"NetworkEngine")
	if _engine != null and not _engine.is_node_ready():
		# (Made before the engine is: once it is.)
		if not _engine.ready.is_connected(_start):
			_engine.ready.connect(_start.bind(tree), CONNECT_ONE_SHOT)
		_engine = null
		return
	_started = true
	_engine_id = _engine.get_instance_id() if _engine != null else 0
	# Told when the engine changes, so a player lookup needs no checks.
	var stale: Callable = func(_a: Variant = null) -> void: _stale = true
	if _engine != null:
		_engine.renamed.connect(stale, CONNECT_ONE_SHOT)
		_engine.tree_exiting.connect(stale, CONNECT_ONE_SHOT)
	elif not tree.root.child_entered_tree.is_connected(_on_root_child):
		tree.root.child_entered_tree.connect(_on_root_child)
	var profile: Dictionary = Profile.load_profile()
	if _engine != null:
		_ask(&"set_player_data", [USERNAME_KEY, profile["username"]])
		_ask(&"set_player_data", [USER_ID_KEY, profile["user_id"]])
		for hooked: Array in [[&"player_joined", _on_joined], [&"player_left", _on_left], [&"player_data_changed", _on_data],
				[&"context_changed", _on_context]]:
			if _engine.has_signal(hooked[0]):
				_engine.connect(hooked[0], hooked[1])
	_rebuild()


## The StarterPlayer: every player's template.
func _take_template() -> void:
	if _template_taken:
		return
	_template_taken = true
	_starter = get_node_or_null(starter) as BrickscriptStarter if not starter.is_empty() else null
	if get_children().any(func(child: Node) -> bool: return not child is BrickscriptPlayer):
		push_warning("Players: its own children aren't copied into players any more: move them into a StarterPlayer (%s)." % starter)
	for peer: int in _players:
		if is_instance_valid(_players[peer]):
			_fill(_players[peer])


func _peers() -> Array[int]:
	var peers: Array[int] = []
	if _engine == null:
		peers.append(1)
		return peers
	if _is_server():
		peers.assign(_order.filter(func(peer: int) -> bool: return _has_player(peer)))
	for peer: int in _ask(&"get_players", [], PackedInt32Array([1])):
		if not peers.has(peer):
			peers.append(peer)
	return peers


func _has_player(peer: int) -> bool:
	if _engine == null:
		return peer == 1
	if not _engine.has_method(&"has_player") and not _engine.has_method(&"get_players"):
		# (An engine without a player list: any player it names is there.)
		return peer > 0
	return bool(_ask(&"has_player", [peer], (_ask(&"get_players", [], PackedInt32Array()) as PackedInt32Array).has(peer)))


func _is_server() -> bool:
	return _engine != null and bool(_ask(&"has_server_authority", [], true))


func _add(peer: int) -> BrickscriptPlayer:
	var made: BrickscriptPlayer = BrickscriptPlayer.new()
	made.peer_id = peer
	_players[peer] = made
	if _is_server() and not _order.has(peer):
		_order.append(peer)
	if _engine != null:
		made.username = str(_ask(&"get_player_data", [peer, USERNAME_KEY, ""], ""))
		made.user_id = str(_ask(&"get_player_data", [peer, USER_ID_KEY, ""], ""))
		var given: String = str(_ask(&"get_player_data", [peer, NAME_KEY, ""], ""))
		made.name = given if not given.is_empty() else (made.username if not made.username.is_empty() else "Player%d" % peer)
	else:
		var profile: Dictionary = Profile.load_profile()
		made.username = profile["username"]
		made.user_id = profile["user_id"]
		made.name = made.username
	_fill(made)
	add_child(made)
	if _is_server():
		# Fresh each game: the template's values, sent with the player.
		for value: Node in _values_of(made):
			value_changed(made, value)
		_name_everyone()
	elif _engine != null:
		for value: Node in _values_of(made):
			var key: String = VALUE_KEY + String(made.get_path_to(value))
			var sent: Variant = _ask(&"get_player_data", [peer, key, null])
			if sent != null:
				value.call(&"arrive", sent)
	player_added.emit(made)
	return made


## Copies StarterPlayer into a player (what it hasn't got; scripts by the
## machine's part, see BrickscriptStarter).
func _fill(made: BrickscriptPlayer) -> void:
	if _starter == null:
		return
	var here: int = int(_ask(&"get_local_peer_id", [], 1)) if _engine != null else 1
	_starter.copy_into(made, made.peer_id, here, _engine == null or _is_server())


func _values_of(made: Node) -> Array[Node]:
	var found: Array[Node] = []
	for node: Node in made.find_children("*", "", true, false):
		if node is BrickscriptObjectValue:
			found.append(node)
	return found


func _remove(peer: int) -> void:
	var gone: BrickscriptPlayer = _players.get(peer)
	_players.erase(peer)
	_order.erase(peer)
	if is_instance_valid(gone):
		player_removing.emit(gone)
		gone.queue_free()


## Back to single-player, hosting or joining: everyone again.
func _rebuild() -> void:
	for peer: int in _players.keys():
		var gone: BrickscriptPlayer = _players[peer]
		if is_instance_valid(gone):
			player_removing.emit(gone)
			if gone.get_parent() == self:
				remove_child(gone)
			gone.queue_free()
	_players.clear()
	_order.clear()
	# Single-player again: the name the server gave (a "_2") was the game's.
	if _engine != null and bool(_ask(&"is_offline", [], false)) and not str(_ask(&"get_player_data", [1, NAME_KEY, ""], "")).is_empty():
		_ask(&"set_player_data", [NAME_KEY, ""])
	if _engine != null and _is_server():
		_order.append(int(_ask(&"get_local_peer_id", [], 1)))
	for peer: int in _peers():
		player(peer)


## Without an engine: one arriving (a test's stand-in) makes this stale.
func _on_root_child(child: Node) -> void:
	if child.name == &"NetworkEngine":
		_stale = true
		get_tree().root.child_entered_tree.disconnect(_on_root_child)


func _on_context(_new: int, _old: int) -> void:
	_rebuild()


func _on_joined(peer: int) -> void:
	player(peer)


func _on_left(peer: int) -> void:
	# After everyone's Player Left (it still answers while they run).
	_remove.call_deferred(peer)


func _on_data(peer: int, key: String, value: Variant) -> void:
	var node: BrickscriptPlayer = _players.get(peer)
	if not is_instance_valid(node):
		return
	if key == NAME_KEY:
		_rename(node, str(value))
	elif key == USERNAME_KEY:
		node.username = str(value)
		if _is_server():
			_name_everyone()
	elif key == USER_ID_KEY:
		node.user_id = str(value)
	elif key.begins_with(VALUE_KEY) and not _is_server():
		var value_node: Node = node.get_node_or_null(NodePath(key.trim_prefix(VALUE_KEY)))
		if value_node != null and value_node.has_method(&"arrive"):
			value_node.call(&"arrive", value)


## Server: unique names, kept for the session (a player keeps theirs when
## others come and go). A newcomer, or a player whose username changed, gets
## their username, or the first free "_2", "_3"... after it (in join order).
func _name_everyone() -> void:
	var taken: Dictionary[String, int] = {}
	var unnamed: Array[int] = []
	for peer: int in _peers():
		var node: BrickscriptPlayer = _players.get(peer)
		if not is_instance_valid(node):
			continue
		var given: String = str(_ask(&"get_player_data", [peer, NAME_KEY, ""], ""))
		if not given.is_empty() and _fits(given, _base_name(node, peer)) and not taken.has(given.to_lower()):
			taken[given.to_lower()] = peer
			_rename(node, given)
		else:
			unnamed.append(peer)
	for peer: int in unnamed:
		var node: BrickscriptPlayer = _players[peer]
		var base: String = _base_name(node, peer)
		var unique: String = base
		var count: int = 2
		while taken.has(unique.to_lower()):
			unique = "%s_%d" % [base, count]
			count += 1
		taken[unique.to_lower()] = peer
		_ask(&"set_player_data_for", [peer, NAME_KEY, unique])
		_rename(node, unique)


func _base_name(node: BrickscriptPlayer, peer: int) -> String:
	var base: String = Profile.clean_name(node.username)
	return base if not base.is_empty() else "Player%d" % peer


## Whether `given` is `base` or `base_<n>` (still the player's username).
static func _fits(given: String, base: String) -> bool:
	if given.to_lower() == base.to_lower():
		return true
	var prefix: String = base.to_lower() + "_"
	return given.to_lower().begins_with(prefix) and given.substr(prefix.length()).is_valid_int()


func _rename(node: BrickscriptPlayer, wanted: String) -> void:
	if wanted.is_empty() or String(node.name) == wanted:
		return
	var holder: Node = get_node_or_null(NodePath(wanted))
	if holder != null and holder != node:
		# (Two swapping names: the other one steps aside until it's named.)
		holder.name = "%s_%d" % [wanted, holder.get_instance_id()]
	node.name = wanted
