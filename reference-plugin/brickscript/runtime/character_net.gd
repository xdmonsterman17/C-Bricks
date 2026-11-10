extends RefCounted

## What BrickscriptCharacter3D and BrickscriptCharacter2D share: who moves a
## character and how the server hands it to its player. The Network Context
## Engine is called by method name only; without it the game is
## single-player and this machine moves every character.

## Seconds between the server's checks for who a character's player is.
const OWNER_CHECK_SEC: float = 0.5
## Marks a character with no player whose packed state the server sends (an
## NPC: hand_over()).
const SERVER_MOVED_META: StringName = &"_brickscript_server_moved"
## How often the engine sends states (its SYNC_INTERVAL_SEC).
const SYNC_SEC: float = 0.05
## A Default death: the body tips over in this long, and the server removes
## it this long after it died.
const FALL_OVER_SEC: float = 0.5
const BODY_STAYS_SEC: float = 2.0
## A Scripted death: the server removes the body this long after it died if
## its death script hasn't (Remove character).
const SCRIPTED_LIMIT_SEC: float = 10.0
## What this machine is for a character (roles(); each character caches it
## in _roles_here(), worked out again when ownership or the session changes:
## asking the engine costs ~8 us a question on a Pi): where the game runs, and
## a networked server (health goes out to the clients).
const RUNS_GAME: int = 1
const HOSTING: int = 2
## Meta a Character Spawner puts on the characters it holds (itself).
const SPAWNER_META: StringName = &"_brickscript_spawner"


## An angle in 16 bits (about 0.0055 degrees a step), and back.
static func angle_bits(angle: float) -> int:
	return roundi((wrapf(angle, -PI, PI) + PI) / TAU * 65535.0)


static func bits_angle(bits: int) -> float:
	return bits / 65535.0 * TAU - PI


## Calls `changed` whenever whose machine moves what may have changed (the
## engine's network_owners_changed and context_changed, API 15). Returns
## false without them (an older engine): then ask every frame.
static func watch_owners(character: Node, changed: Callable) -> bool:
	var found: Node = engine(character)
	if found == null:
		return true
	if not found.has_signal(&"network_owners_changed"):
		return false
	found.connect(&"network_owners_changed", changed)
	found.connect(&"context_changed", changed.unbind(2))
	return true


static func engine(character: Node) -> Node:
	return character.get_node_or_null(^"/root/NetworkEngine") if character.is_inside_tree() else null


## Whether this machine runs the game (the server; offline / without the
## engine, this machine).
static func is_server(character: Node) -> bool:
	var found: Node = engine(character)
	return found == null or bool(found.call(&"has_server_authority"))


## Whether this machine moves the character: its player's machine (or,
## without the engine, this one: single-player).
static func is_mine(character: Node, handed_to: int) -> bool:
	var found: Node = engine(character)
	if found == null or not found.has_method(&"is_owned_here"):
		return true
	if bool(found.call(&"is_owned_here", character)):
		return true
	# Nobody's yet (just spawned) and this machine runs the game: it moves it.
	return handed_to == 0 and int(found.call(&"get_player_of", character)) == 0 and bool(found.call(&"has_server_authority"))


## Server: gives the character's player its movement (network ownership,
## with a speed limit) and syncs where it is. Returns the player it's
## handed to now (`handed_to` when nothing changed).
static func hand_over(character: Node, handed_to: int, speed_limit: float) -> int:
	# (Deferred callers: it may have left already.)
	if not character.is_inside_tree():
		return handed_to
	var found: Node = engine(character)
	if found == null or not is_server(character):
		return handed_to
	var player: int = int(found.call(&"get_player_of", character))
	if player == 0 and character.get(&"controlled_by") == 1 and not character.has_meta(SERVER_MOVED_META) and found.has_method(&"sync_packed"):
		# Nobody's and steered by scripts (an NPC): the server moves it, and
		# every machine sees it move.
		found.call(&"sync_packed", character)
		character.set_meta(SERVER_MOVED_META, true)
	if player == 0 or player == handed_to:
		return handed_to
	if found.has_method(&"sync_packed") and character.has_method(&"_network_pack"):
		# (API 15: its own compact state, one message for all of them.)
		found.call(&"sync_packed", character)
	elif found.has_method(&"sync_property"):
		found.call(&"sync_property", character, "position")
		found.call(&"sync_property", character, "rotation")
	if found.has_method(&"set_network_owner"):
		found.call(&"set_network_owner", character, player, speed_limit)
	return player


## Server: the speed limit follows a changed walk speed / gravity.
static func update_limit(character: Node, handed_to: int, speed_limit: float) -> void:
	var found: Node = engine(character)
	if handed_to != 0 and found != null and is_server(character) and found.has_method(&"set_network_owner"):
		found.call(&"set_network_owner", character, handed_to, speed_limit)


## The player whose machine moves it (0: the server's own).
static func network_owner(character: Node) -> int:
	var found: Node = engine(character)
	return int(found.call(&"get_network_owner", character)) if found != null and found.has_method(&"get_network_owner") else 0


#region Health
# Both character kinds have `health`, `max_health`, the signals
# health_changed(health, max_health) and died(killer), and two RPCs that call
# these: _health_from_server (server -> a machine) and _ask_health (a
# machine -> the server, when its copy is made: late joiners).

## RUNS_GAME / HOSTING for a character on this machine (see RUNS_GAME).
static func roles(character: Node) -> int:
	var found: Node = engine(character)
	var flags: int = RUNS_GAME if is_server(character) else 0
	if found != null and character.multiplayer.has_multiplayer_peer() and bool(found.call(&"is_server")):
		flags |= HOSTING
	return flags


## Server: sets a character's health (0 to `top`) and max health (`top`),
## tells every machine, and it dies when health reaches 0 (`by`: the player
## who did it, 0: nobody). A dead character's health stays 0 (it's made
## again). Returns false elsewhere (with an error) and when it's dead.
static func set_health(character: Node, value: float, top: float, by: int) -> bool:
	if int(character.call(&"_roles_here")) & RUNS_GAME == 0:
		push_error("Character: %s's health is changed by the server only (where the game runs)." % character.name)
		return false
	var before: float = character.get(&"health")
	if before <= 0.0:
		return false
	top = maxf(top, 0.01)
	value = clampf(value, 0.0, top)
	if value == before and top == float(character.get(&"max_health")):
		return true
	show_health(character, value, top, by)
	send_health(character, by, 0)
	return true


## Sets what a character's health is here and tells its scripts (died once,
## when it reaches 0).
static func show_health(character: Node, value: float, top: float, by: int) -> void:
	var before: float = character.get(&"health")
	character.set(&"max_health", top)
	character.set(&"health", value)
	character.emit_signal(&"health_changed", value, top)
	if before > 0.0 and value <= 0.0:
		character.emit_signal(&"died", by)
		# Brickscripts' When character died (Library.DIED_HELPER).
		if character.is_inside_tree():
			var player: int = player_of(character)
			character.get_tree().call_group(&"brickscript_death_listeners", &"_brickscript_on_character_death", character, player, by)
			after_death(character, player, by)


## What follows a death on this machine. Default: the body tips over (not on
## a headless server: nobody sees it), and the server removes it after
## BODY_STAYS_SEC. Scripted: its death scripts are added (the server one where
## the game runs, the local one on every machine) and hear When character
## died at once; the server removes it after SCRIPTED_LIMIT_SEC unless they
## have (Remove character).
static func after_death(character: Node, player: int, by: int) -> void:
	var server: bool = int(character.call(&"_roles_here")) & RUNS_GAME != 0
	if int(character.call(&"get_death_look")) != 2:
		if DisplayServer.get_name() != "headless":
			fall_over(character)
		if server:
			_remove_later(character, BODY_STAYS_SEC)
		return
	for kind: String in ["server", "local"]:
		if kind == "server" and not server:
			continue
		var path: String = character.call(&"get_death_script", kind == "server")
		if path.is_empty():
			continue
		var script: Script = load(path) as Script
		if script == null:
			push_error("Character: %s's death script %s can't be loaded." % [character.name, path])
			continue
		var node: Node = Node.new()
		node.name = "DeathServerScript" if kind == "server" else "DeathLocalScript"
		node.set_meta(&"script_node", kind)
		node.set_script(script)
		# (Every machine makes its own: never sent, never removed by the engine.)
		node.add_to_group(&"local_only", true)
		character.add_child(node)
		if node.has_method(&"_brickscript_on_character_death"):
			# (It joined the listeners after this death was told.)
			node.call(&"_brickscript_on_character_death", character, player, by)
	if server:
		_remove_later(character, SCRIPTED_LIMIT_SEC)


## Server: removes the character after `seconds`, if it's still there.
static func _remove_later(character: Node, seconds: float) -> void:
	# (A weak reference: a body removed sooner is fine.)
	var held: WeakRef = weakref(character)
	character.get_tree().create_timer(seconds).timeout.connect(func() -> void:
		var still: Node = held.get_ref() as Node
		if still != null and still.is_inside_tree() and not still.is_queued_for_deletion():
			remove(still))


## A Default death's look: its children (not its shapes or a 2D camera) turn a
## quarter round about its feet in FALL_OVER_SEC and rise by its shape's
## radius, so the body lies on the floor (the body itself is moved by its
## player's machine and the network).
static func fall_over(character: Node) -> void:
	var parts: Array[Node] = []
	var starts: Array = []
	for child: Node in character.get_children():
		if child is Node3D and not child is CollisionShape3D:
			parts.append(child)
			starts.append((child as Node3D).transform)
		elif child is Node2D and not child is CollisionShape2D and not child is CollisionPolygon2D and not child is Camera2D:
			parts.append(child)
			starts.append((child as Node2D).transform)
	if parts.is_empty():
		return
	var half: float = float(character.get(&"shape_height")) * 0.5
	# (Lying down, its middle would be at the floor: up by its thickness.)
	var thick: float = float(character.get(&"shape_radius"))
	var tilt: Callable = func(amount: float) -> void:
		for i: int in parts.size():
			var part: Node = parts[i]
			if not is_instance_valid(part):
				continue
			if part is Node3D:
				var feet: Vector3 = Vector3(0.0, -half, 0.0)
				var turn: Transform3D = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5 * amount), Vector3.ZERO)
				(part as Node3D).transform = Transform3D(Basis.IDENTITY, feet + Vector3(0.0, thick * amount, 0.0)) * turn * Transform3D(Basis.IDENTITY, -feet) * (starts[i] as Transform3D)
			else:
				# (y grows downwards in 2D: the feet are below.)
				var feet_2d: Vector2 = Vector2(0.0, half)
				var turn_2d: Transform2D = Transform2D(PI * 0.5 * amount, Vector2.ZERO)
				(part as Node2D).transform = Transform2D(0.0, feet_2d - Vector2(0.0, thick * amount)) * turn_2d * Transform2D(0.0, -feet_2d) * (starts[i] as Transform2D)
	character.create_tween().tween_method(tilt, 0.0, 1.0, FALL_OVER_SEC)


## The player a character is (its spawner's spawn_for / Give To; 0: none).
## Without the engine: player 1 (single-player).
static func player_of(character: Node) -> int:
	var found: Node = engine(character)
	if found == null or not found.has_method(&"get_player_of"):
		return 1
	return int(found.call(&"get_player_of", character))


## Set Character's Health / Max health (`property`): the server only.
static func change_health(character: Node, property: StringName, value: Variant) -> bool:
	if int(character.call(&"_roles_here")) & RUNS_GAME == 0:
		push_error("Character: %s's %s is set by the server only (where the game runs)." % [character.name, "health" if property == &"health" else "max health"])
		return false
	var top: float = character.get(&"max_health")
	if property == &"max_health":
		return set_health(character, minf(character.get(&"health"), float(value)), float(value), 0)
	return set_health(character, float(value), top, 0)


## Server: removes a character from the game on every machine (the engine
## despawns what it spawned; anything else is freed). Its spawner makes a
## new one after respawn_seconds.
static func remove(character: Node) -> bool:
	if not is_server(character):
		push_error("Character: %s is removed by the server only (where the game runs)." % character.name)
		return false
	if character.is_queued_for_deletion():
		return true
	var found: Node = engine(character)
	if found != null and found.has_method(&"is_spawned") and bool(found.call(&"is_spawned", character)):
		found.call(&"despawn", character)
	else:
		character.queue_free()
	return true


## Server: sends a character's health to `to` (0: every machine; nothing
## offline). A machine that doesn't have the character yet asks when it does.
static func send_health(character: Node, by: int, to: int) -> void:
	if int(character.call(&"_roles_here")) & HOSTING == 0:
		return
	var found: Node = engine(character)
	var value: float = character.get(&"health")
	var top: float = character.get(&"max_health")
	if to != 0:
		character.rpc_id(to, &"_health_from_server", value, top, by)
		return
	# (Peers ENet still has connected: one leaving can't be sent to.)
	var peers: PackedInt32Array = found.call(&"_reachable_peers") if found.has_method(&"_reachable_peers") else found.call(&"get_connected_peers")
	if peers.size() == character.multiplayer.get_peers().size():
		# Everyone's reachable (nearly always): one message encoded once for
		# all (an rpc_id per client costs ~60 us each on a Pi).
		character.rpc(&"_health_from_server", value, top, by)
		return
	for peer: int in peers:
		character.rpc_id(peer, &"_health_from_server", value, top, by)


## A client's copy, just made: asks the server for its health (it may have
## changed before this machine had the character).
static func ask_health(character: Node) -> void:
	var found: Node = engine(character)
	if found != null and bool(found.call(&"is_client")) and character.multiplayer.has_multiplayer_peer():
		character.rpc_id(1, &"_ask_health")


## Server: health regained a second (`regen_per_second`), once a second while
## alive and hurt. `waited`: seconds since the last; returns the new count.
static func regen(character: Node, waited: float, delta: float) -> float:
	var per_second: float = character.get(&"regen_per_second")
	var value: float = character.get(&"health")
	var top: float = character.get(&"max_health")
	if per_second <= 0.0 or value <= 0.0 or value >= top:
		return 0.0
	waited += delta
	if waited < 1.0:
		return waited
	if int(character.call(&"_roles_here")) & RUNS_GAME != 0:
		set_health(character, value + per_second, top, 0)
	return 0.0


## The Character Spawner that holds a character (it marks those it holds), or
## null.
static func spawner(character: Node) -> Node:
	if not character.has_meta(SPAWNER_META):
		return null
	var found: Variant = character.get_meta(SPAWNER_META)
	return found if found is Node and is_instance_valid(found) else null


## What happens when a character falls below its fall_limit: `own` is its
## fall_action (0: from its spawner); returns 1 (dies) or 2 (put back). Not
## from a spawner: put back (nothing would make it again).
static func fall_action(character: Node, own: int) -> int:
	if own != 0:
		return own
	var holder: Node = spawner(character)
	return int(holder.get(&"fall_action")) + 1 if holder != null else 2


## How a character dies: `own` is its death_look (0: from its spawner);
## returns 1 (Default: falls over) or 2 (Scripted).
static func death_look(character: Node, own: int) -> int:
	if own != 0:
		return own
	var holder: Node = spawner(character)
	return int(holder.get(&"death_look")) + 1 if holder != null else 1


## A character's death script (`property`: death_server_script /
## death_local_script): its own, else its spawner's ("": none).
static func death_script(character: Node, property: StringName) -> String:
	var own: String = character.get(property)
	if not own.is_empty():
		return own
	var holder: Node = spawner(character)
	return String(holder.get(property)) if holder != null else ""

#endregion
