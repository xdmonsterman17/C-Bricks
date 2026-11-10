@tool
@icon("res://addons/brickscript/icons/nodes/character_2d.svg")
class_name BrickscriptCharacter2D
extends AnimatableBody2D

## A 2D character in one node: it moves on its player's machine, with no
## bricks for the basics. Like BrickscriptCharacter3D it isn't a
## CharacterBody2D: a kinematic body (others' raycasts and bodies hit it)
## that moves itself with casts of its own shape (sideways sliding along
## what's in the way, then up / down for a platformer), with `velocity` and
## is_on_floor() like a CharacterBody2D.
##
## - Platformer: left / right walk, Space jumps, gravity pulls down.
## - Top-down: the four directions move it anywhere (no gravity); Face
##   movement turns it the way it goes.
##
## Who moves it is the same as BrickscriptCharacter3D: its player's machine
## (network ownership; offline / without the engine, this machine); the
## server hands it over with a speed limit and syncs its position and
## rotation; everyone else sees it glide there. With the engine's API 15 it
## syncs one packed state (sync_packed, 11 bytes: position, rotation, on
## the floor / moving / falling), checked by the server (_network_check), and
## On the floor / Moving / Falling elsewhere come from it (its velocity there
## is worked out from the states).
##
## Health and death are as BrickscriptCharacter3D's: `health` /
## `max_health` changed only where the game runs (damage(), heal(),
## set_health(), set_max_health(), kill()), sent to every machine when they
## change; at 0 it dies (died) and stops moving. Falling below fall_limit
## (platformer) it dies or is put back (Death settings, or its Character
## Spawner's).
##
## Made when the scene has none (local-only children: every machine makes
## its own): a shape (a capsule for a platformer, a circle top-down; Shape
## settings) and a "Camera" (Camera2D) that follows it, current only on its
## player's machine. In the editor it adds the shape to the scene instead
## (saved with it: no "no shape" warning, and it can be seen and edited);
## that shape follows the Kind and Shape settings.

const Net := preload("res://addons/brickscript/runtime/character_net.gd")

enum Kind { PLATFORMER, TOP_DOWN }
## (As BrickscriptCharacter3D's.)
enum FallAction { FROM_SPAWNER, DIE, PUT_BACK }
enum DeathLook { FROM_SPAWNER, DEFAULT, SCRIPTED }

## Its health changed (on every machine).
signal health_changed(health: float, max_health: float)
## Its health reached 0 (on every machine). `killer`: the player who did it
## (0: nobody).
signal died(killer: int)

## How it moves.
@export var kind: Kind = Kind.PLATFORMER:
	set(value):
		kind = value
		_update_made_shape()

@export_group("Movement")
## Walking speed, pixels a second.
@export var walk_speed: float = 300.0
## Upward speed of a jump, pixels a second (platformer).
@export var jump_power: float = 600.0
## Pull down, pixels a second per second (platformer).
@export var gravity: float = 1600.0
## Below this height (it fell off the world: y grows downwards) it dies or
## is put back where it started (platformer; Death > Fall action).
@export var fall_limit: float = 2000.0
## Top-down: it turns the way it moves.
@export var face_movement: bool = false
## Platformer: ledges up to this high (pixels) are stepped up; 0: none.
@export var step_height: float = 8.0
## Platformer: walking down a slope or a step up to this far (pixels), it
## keeps to the floor.
@export var floor_snap: float = 8.0

@export_group("Health")
## At 0 it dies. Changed only where the game runs (Damage, Heal, Set
## Character).
@export var health: float = 100.0
@export var max_health: float = 100.0
## Health it gets back a second while alive and hurt (added once a second);
## 0: none.
@export var regen_per_second: float = 0.0

@export_group("Death")
@export var fall_action: FallAction = FallAction.FROM_SPAWNER
@export var death_look: DeathLook = DeathLook.FROM_SPAWNER
## Scripted: runs where the game runs when it dies. Empty: its Character
## Spawner's.
@export_file("*.brickserver", "*.gd") var death_server_script: String = ""
## Scripted: runs on every machine when it dies (effects only). Empty: its
## Character Spawner's.
@export_file("*.bricklocal", "*.gd") var death_local_script: String = ""

@export_group("Shape")
## The shape it makes when the scene gives it no CollisionShape2D: a capsule
## (platformer) or a circle of this radius (top-down).
@export var shape_radius: float = 16.0:
	set(value):
		shape_radius = value
		_update_made_shape()
@export var shape_height: float = 48.0:
	set(value):
		shape_height = value
		_update_made_shape()

@export_group("Input")
@export var move_up: StringName = &"move_forward"
@export var move_down: StringName = &"move_back"
@export var move_left: StringName = &"move_left"
@export var move_right: StringName = &"move_right"
@export var jump: StringName = &"jump"

@export_group("Network")
## The fastest the server lets its player move it (pixels a second; a cheat
## check). 0: three times the walk speed, plus a fall (platformer).
@export var max_speed: float = 0.0

## Marks a shape it made in the editor (it follows the Kind / Shape settings).
const MADE_SHAPE_META: StringName = &"_brickscript_made_shape"
## On a shape only shown in the editor (add_preview_shape()).
const PREVIEW_SHAPE_META: StringName = &"_brickscript_preview_shape"
## Editor: it came with its scene when opened (see _ready()).
var _opened: bool = false

## Properties Brickscript's Property (Get) may read but Property (Set) can't
## (node_types.gd marks them read only).
const _BRICKSCRIPT_READ_ONLY: PackedStringArray = ["on_the_floor", "moving", "falling", "dead"]

## The settings Property (Set) (its change()) can change.
const CHANGEABLE: Array[StringName] = [&"walk_speed", &"jump_power", &"gravity"]

## Pixels a second, as on a CharacterBody2D (on its player's machine: what it
## moves by; elsewhere: worked out from the states).
var velocity: Vector2 = Vector2.ZERO
var camera: Camera2D = null
## (3D characters look around with the mouse; a 2D one never does.)
var looking: bool = false
## What Property (Get) reads (right on every machine: from its packed state
## when another machine moves it); read only.
var on_the_floor: bool:
	get:
		return on_floor()
	set(_value):
		_read_only(&"on_the_floor")
var moving: bool:
	get:
		return is_moving()
	set(_value):
		_read_only(&"moving")
var falling: bool:
	get:
		return is_falling()
	set(_value):
		_read_only(&"falling")
var dead: bool:
	get:
		return health <= 0.0
	set(_value):
		_read_only(&"dead")

var _start: Vector2 = Vector2.ZERO
var _started: bool = false
var _jump_pressed: bool = false
var _handed_to: int = 0
var _owner_wait: float = 0.0
## is_mine(), worked out again only when it may have changed (it's asked
## several times a frame, and asking the engine costs).
var _mine: bool = true
var _mine_known: bool = false
var _watching: bool = false
## A server nobody watches (headless: a dedicated server) sets states at once
## instead of gliding: its game logic wants the newest, and it saves the
## per-frame work. Worked out with is_mine().
var _snaps: bool = false
## Moved on another machine: the states to glide through, oldest first (their
## arrival seconds, positions, rotations; typed arrays: this runs every frame
## for every character); and how it is there.
var _times: PackedFloat64Array = PackedFloat64Array()
var _spots: PackedVector2Array = PackedVector2Array()
var _turns: PackedFloat32Array = PackedFloat32Array()
var _remote_floor: bool = false
var _remote_moving: bool = false
var _remote_falling: bool = false
## Seconds towards the next regen (where the game runs).
var _regen_wait: float = 0.0
## _roles_here(), and whether it's still right.
var _roles: int = 0
var _roles_known: bool = false

## Whether its last move ended on the floor (its player's machine).
var _on_floor: bool = false
## The cast of its own shape and, during a move, where the last cast started.
var _query: PhysicsShapeQueryParameters2D = null
var _shape_node: CollisionShape2D = null
var _from: Vector2 = Vector2.ZERO
var _touch: float = 1.0
## Where its last move left it: anywhere else, something put it there, so it
## checks it isn't inside something first (a cast doesn't see what it starts in).
var _placed_at: Vector2 = Vector2.INF

## A packed state's size (see _network_pack).
const STATE_BYTES: int = 11
## Flags in a packed state.
const ON_FLOOR: int = 1
const MOVING: int = 4
const FALLING: int = 8
## (As BrickscriptCharacter3D.)
const GLIDE_DELAY_SEC: float = 0.1
const RUN_ON_SEC: float = 0.1
const GLIDE_GAP_SEC: float = 0.125
## Pixels allowed on top of the speed limit (the server's check).
const MOVE_SLACK: float = 16.0
## The gap (pixels) it keeps when pushed out of something.
const PUSH_GAP: float = 0.5
## A floor's normal points at least this much up (45 degrees).
const FLOOR_NORMAL_Y: float = 0.7


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		set_physics_process(false)
		set_process_unhandled_input(false)
		# Opened with its scene (its owner set already, or the scene's root),
		# not just added with the Add Node dialog.
		_opened = owner != null or not scene_file_path.is_empty()
		# (Deferred: the Add Node dialog sets the owner after adding it.)
		_shape_in_edited_scene.call_deferred()
		return
	# Moved by setting its transform, at once.
	sync_to_physics = false
	if not _has_shape():
		_add_local(_new_shape())
	camera = get_node_or_null(^"Camera") as Camera2D
	if camera == null:
		camera = Camera2D.new()
		camera.name = "Camera"
		camera.enabled = false
		# Turning with the character would spin the whole view.
		camera.ignore_rotation = true
		_add_local(camera)
	_watching = Net.watch_owners(self, _forget_mine)
	_hand_over.call_deferred()
	Net.ask_health(self)


func _process(delta: float) -> void:
	if regen_per_second > 0.0:
		_regen_wait = Net.regen(self, _regen_wait, delta)
	if _handed_to == 0:
		_owner_wait -= delta
		if _owner_wait <= 0.0:
			_owner_wait = Net.OWNER_CHECK_SEC
			# (Also who its player is: given after it was made.)
			_mine_known = false
			if Net.is_server(self):
				_hand_over()
	var mine: bool = is_mine()
	if not _times.is_empty():
		if mine:
			_clear_states()
		else:
			_glide()
	if camera == null or not camera.is_inside_tree():
		return
	if mine:
		if not camera.is_current():
			camera.enabled = true
			camera.make_current()
	elif camera.enabled:
		camera.enabled = false


func _physics_process(delta: float) -> void:
	if not is_mine():
		return
	var dead: bool = health <= 0.0
	if kind == Kind.TOP_DOWN:
		velocity = Vector2.ZERO if dead else Input.get_vector(move_left, move_right, move_up, move_down) * walk_speed
		if face_movement and velocity.length() > 0.1:
			rotation = velocity.angle()
	else:
		if dead and global_position.y > fall_limit:
			# Died falling: it stays where it fell.
			return
		velocity.x = 0.0 if dead else Input.get_axis(move_left, move_right) * walk_speed
		velocity.y += gravity * delta
		if _jump_pressed and _on_floor and not dead:
			velocity.y = -jump_power
	_jump_pressed = false
	_move(delta)
	if not _started:
		_start = global_position
		_started = true
	elif kind == Kind.PLATFORMER and global_position.y > fall_limit:
		_fell()


func _unhandled_input(event: InputEvent) -> void:
	if is_mine() and health > 0.0 and event.is_action_pressed(jump):
		_jump_pressed = true


## Server: takes `amount` off its health (`by`: the player who did it, 0:
## nobody); at 0 it dies. False elsewhere and when it's dead.
func damage(amount: float, by: int = 0) -> bool:
	return Net.set_health(self, health - amount, max_health, by)


## Server: gives it `amount` health back (up to max_health).
func heal(amount: float) -> bool:
	return Net.set_health(self, health + amount, max_health, 0)


## Server: sets its health (0: it dies; `by`: who did it).
func set_health(value: float, by: int = 0) -> bool:
	return Net.set_health(self, value, max_health, by)


## Server: sets its max health (its health goes no higher).
func set_max_health(value: float) -> bool:
	return Net.set_health(self, minf(health, value), value, 0)


## Server: it dies at once (`by`: who did it).
func kill(by: int = 0) -> bool:
	return Net.set_health(self, 0.0, max_health, by)


func is_dead() -> bool:
	return health <= 0.0


func _read_only(property: StringName) -> void:
	push_error("Character: %s is read only (it follows the character)." % property)


## Server: takes it out of the game on every machine (its spawner makes a new
## one after respawn_seconds).
func remove() -> bool:
	return Net.remove(self)


## Its fall action and death look, with From spawner worked out.
func get_fall_action() -> FallAction:
	return Net.fall_action(self, fall_action) as FallAction


func get_death_look() -> DeathLook:
	return Net.death_look(self, death_look) as DeathLook


## Its death script (`server`: the server one, else the local one), or "".
func get_death_script(server: bool) -> String:
	return Net.death_script(self, &"death_server_script" if server else &"death_local_script")


## Below fall_limit on the machine that moves it (as BrickscriptCharacter3D's).
func _fell() -> void:
	velocity = Vector2.ZERO
	if get_fall_action() == FallAction.PUT_BACK:
		global_position = _start
		return
	if health > 0.0 and Net.is_server(self):
		kill()


## A health from the server.
@rpc("authority", "call_remote", "reliable")
func _health_from_server(value: float, top: float, by: int) -> void:
	Net.show_health(self, value, top, by)


## A machine's copy was just made: the server sends it the health.
@rpc("any_peer", "call_remote", "reliable")
func _ask_health() -> void:
	if Net.is_server(self):
		Net.send_health(self, 0, multiplayer.get_remote_sender_id())


## Whether it's walking (moving sideways, or any way top-down).
func is_moving() -> bool:
	if not is_mine():
		return _remote_moving
	return (absf(velocity.x) if kind == Kind.PLATFORMER else velocity.length()) > 1.0


## Whether it stands on the floor (moved on another machine: as it was there).
func on_floor() -> bool:
	return _on_floor if is_mine() else _remote_floor


## Whether its last move ended on the floor (as CharacterBody2D's; a
## top-down character never is).
func is_on_floor() -> bool:
	return _on_floor


## Whether it's in the air, going down (platformer).
func is_falling() -> bool:
	if not is_mine():
		return _remote_falling
	return kind == Kind.PLATFORMER and not is_on_floor() and velocity.y > 0.0


## Its state for the network (sync_packed): position (2 x float), rotation
## (16 bits), flags (ON_FLOOR, MOVING, FALLING).
func _network_pack() -> PackedByteArray:
	var state: PackedByteArray = PackedByteArray()
	state.resize(STATE_BYTES)
	state.encode_float(0, position.x)
	state.encode_float(4, position.y)
	state.encode_u16(8, Net.angle_bits(rotation))
	state[10] = (ON_FLOOR if on_floor() else 0) | (MOVING if is_moving() else 0) | (FALLING if is_falling() else 0)
	return state


## How often its states arrive here (every Nth update, Network Context
## Engine API 19, e.g. far away with the Cull Throttle Engine): it glides
## that much further behind, so it doesn't stop between them.
var _rate: int = 1


func _network_rate(interval: int) -> void:
	_rate = maxi(interval, 1)


## A state from the network: glided to (at_once: set).
func _network_unpack(state: PackedByteArray, at_once: bool) -> void:
	if state.size() < STATE_BYTES:
		return
	var where: Vector2 = Vector2(state.decode_float(0), state.decode_float(4))
	var turned: float = Net.bits_angle(state.decode_u16(8))
	if not where.is_finite():
		return
	var flags: int = state[10]
	_remote_floor = flags & ON_FLOOR != 0
	_remote_moving = flags & MOVING != 0
	_remote_falling = flags & FALLING != 0
	if at_once or is_mine() or _snaps:
		_clear_states()
		_place(where, turned)
		return
	var now: float = Time.get_ticks_msec() * 0.001
	var count: int = _times.size()
	if count == 0 or now - _times[count - 1] > GLIDE_GAP_SEC * _rate:
		_clear_states()
		_add_state(now - Net.SYNC_SEC * _rate, position, rotation)
		count = 1
	var moved: Vector2 = (where - _spots[count - 1]) / maxf(now - _times[count - 1], 0.01)
	if not _remote_moving:
		moved.x = 0.0
		if kind == Kind.TOP_DOWN:
			moved.y = 0.0
	if kind == Kind.PLATFORMER and _remote_floor:
		moved.y = 0.0
	velocity = moved
	_add_state(now, where, turned)
	if count >= 8:
		_drop_oldest()


## Server: whether a state its player's machine sent can be right.
func _network_check(previous: PackedByteArray, state: PackedByteArray, seconds: float) -> bool:
	if state.size() < STATE_BYTES:
		return false
	var to: Vector2 = Vector2(state.decode_float(0), state.decode_float(4))
	if not to.is_finite():
		return false
	if kind == Kind.PLATFORMER and to.y > fall_limit and health > 0.0 and get_fall_action() == FallAction.DIE:
		# (As BrickscriptCharacter3D's: every state is checked here.)
		kill()
	if previous.size() < STATE_BYTES:
		return true
	var from: Vector2 = Vector2(previous.decode_float(0), previous.decode_float(4))
	return from.distance_to(to) <= _speed_limit() * seconds + MOVE_SLACK


func _glide() -> void:
	var shown: float = Time.get_ticks_msec() * 0.001 - GLIDE_DELAY_SEC * _rate
	while _times.size() >= 2 and _times[1] <= shown:
		_drop_oldest()
	if _times.size() >= 2:
		var span: float = _times[1] - _times[0]
		var weight: float = clampf((shown - _times[0]) / span, 0.0, 1.0) if span > 0.001 else 1.0
		_place(_spots[0].lerp(_spots[1], weight), lerp_angle(_turns[0], _turns[1], weight))
		return
	var ahead: float = shown - _times[0]
	_place(_spots[0] + velocity * clampf(ahead, 0.0, RUN_ON_SEC), _turns[0])
	if ahead > RUN_ON_SEC:
		# Settled: nothing to do until the next state (which glides from here).
		_clear_states()


## Where it is and which way it's turned, in one go (one transform change).
func _place(where: Vector2, turned: float) -> void:
	transform = Transform2D(turned, scale, skew, where)


func _add_state(time: float, where: Vector2, turned: float) -> void:
	_times.append(time)
	_spots.append(where)
	_turns.append(turned)


func _drop_oldest() -> void:
	_times.remove_at(0)
	_spots.remove_at(0)
	_turns.remove_at(0)


func _clear_states() -> void:
	_times.clear()
	_spots.clear()
	_turns.clear()


## Changes one of its settings (CHANGEABLE), for `seconds` (0: until changed
## again); like BrickscriptCharacter3D.change.
func change(property: StringName, value: Variant, seconds: float = 0.0) -> bool:
	if property == &"health" or property == &"max_health":
		# (The server's alone, for good: Seconds doesn't apply.)
		return Net.change_health(self, property, value)
	if not CHANGEABLE.has(property):
		push_error("Character: '%s' can't be changed on a 2D character (one of %s)." % [property, ", ".join(CHANGEABLE)])
		return false
	if is_mine():
		_apply(property, value, seconds)
		return true
	if Net.is_server(self) and Net.engine(self) != null:
		_apply(property, value, seconds)
		var player: int = Net.network_owner(self)
		if player > 1 and multiplayer.has_multiplayer_peer():
			_set_from_server.rpc_id(player, property, value, seconds)
		return true
	push_error("Character: %s isn't this machine's character, so it can't be changed here (its player's machine or the server can)." % name)
	return false


func is_mine() -> bool:
	if not _mine_known:
		_mine = Net.is_mine(self, _handed_to)
		_snaps = DisplayServer.get_name() == "headless" and Net.is_server(self)
		_mine_known = _watching
	return _mine


func _forget_mine() -> void:
	_mine_known = false
	_roles_known = false


## What this machine is for it (Net.RUNS_GAME / HOSTING), worked out again
## only when it may have changed (as is_mine()).
func _roles_here() -> int:
	if not _roles_known:
		_roles = Net.roles(self)
		_roles_known = _watching
	return _roles


@rpc("authority", "call_remote", "reliable")
func _set_from_server(property: StringName, value: Variant, seconds: float) -> void:
	if CHANGEABLE.has(property):
		_apply(property, value, seconds)


func _apply(property: StringName, value: Variant, seconds: float) -> void:
	var before: Variant = get(property)
	set(property, value)
	_changed(property)
	if seconds > 0.0:
		get_tree().create_timer(seconds).timeout.connect(func() -> void:
			if is_instance_valid(self) and get(property) == value:
				set(property, before)
				_changed(property))


func _changed(property: StringName) -> void:
	if (property == &"walk_speed" or property == &"gravity") and max_speed <= 0.0:
		Net.update_limit(self, _handed_to, _speed_limit())


func _speed_limit() -> float:
	if max_speed > 0.0:
		return max_speed
	return walk_speed * 3.0 + (gravity if kind == Kind.PLATFORMER else 0.0)


func _hand_over() -> void:
	var before: int = _handed_to
	_handed_to = Net.hand_over(self, _handed_to, _speed_limit())
	if _handed_to != before:
		_mine_known = false


## Editor: a character in the scene being edited (not inside another scene
## placed in it: that scene's own file gets it) gets its shape there.
func _shape_in_edited_scene() -> void:
	if not is_inside_tree():
		return
	var scene: Node = get_tree().edited_scene_root
	if scene != null and (scene == self or owner == scene):
		if _opened:
			add_preview_shape()
		else:
			add_scene_shape(scene)


## Editor, a scene opened with a character that has no shape: one only shown
## (not saved, not in the Scene dock), so opening the scene doesn't mark it
## changed; the game makes its own. Gone when a shape of the scene's is added.
## Returns it (null: it had one).
func add_preview_shape() -> CollisionShape2D:
	if _has_shape():
		return null
	var shape: CollisionShape2D = _new_shape()
	shape.set_meta(MADE_SHAPE_META, true)
	shape.set_meta(PREVIEW_SHAPE_META, true)
	add_child(shape, true)
	child_entered_tree.connect(func(child: Node) -> void:
		if child != shape and (child is CollisionShape2D or child is CollisionPolygon2D) and is_instance_valid(shape):
			shape.queue_free())
	return shape


## Editor: gives it a shape saved in `scene` when it has none (so Godot's
## "no shape" warning goes, and it can be seen and edited). Returns it (null:
## it had one).
func add_scene_shape(scene: Node) -> CollisionShape2D:
	if _has_shape():
		return null
	var shape: CollisionShape2D = _new_shape()
	shape.set_meta(MADE_SHAPE_META, true)
	add_child(shape, true)
	shape.owner = scene
	var editor: Object = Engine.get_singleton(&"EditorInterface") if Engine.is_editor_hint() else null
	if editor != null:
		editor.call(&"mark_scene_as_unsaved")
	return shape


func _has_shape() -> bool:
	return get_children().any(func(child: Node) -> bool: return child is CollisionShape2D or child is CollisionPolygon2D)


## A capsule for a platformer, a circle top-down.
func _new_shape() -> CollisionShape2D:
	var shape: CollisionShape2D = CollisionShape2D.new()
	shape.name = "Shape"
	shape.shape = _shape_resource()
	return shape


func _shape_resource() -> Shape2D:
	if kind == Kind.TOP_DOWN:
		var circle: CircleShape2D = CircleShape2D.new()
		circle.radius = shape_radius
		return circle
	var capsule: CapsuleShape2D = CapsuleShape2D.new()
	capsule.radius = shape_radius
	capsule.height = shape_height
	return capsule


## The shape it made in the editor follows the Kind and Shape settings.
func _update_made_shape() -> void:
	for child: Node in get_children():
		if child is CollisionShape2D and child.has_meta(MADE_SHAPE_META):
			(child as CollisionShape2D).shape = _shape_resource()


#region Movement

## Moves it by velocity * delta. Top-down: sliding along what's in the way.
## Platformer: sideways (sliding, stepping up ledges), then up / down
## (landing, a ceiling, keeping to the floor going down). Worked out on a
## position of its own, set once at the end.
func _move(delta: float) -> void:
	if not _prepare_query():
		global_position += velocity * delta
		return
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var at: Vector2 = global_position
	if at.distance_squared_to(_placed_at) > 0.0001:
		_query.transform = Transform2D(global_rotation, at) * _shape_node.transform
		at += _push_out(space)
	if kind == Kind.TOP_DOWN:
		at = _slide(space, at, velocity * delta, false)
		global_position = at
		_placed_at = at
		return
	var was_on_floor: bool = _on_floor
	var side: Vector2 = Vector2(velocity.x * delta, 0.0)
	if absf(side.x) > 0.0001:
		var from: Vector2 = at
		at = _slide(space, at, side, true)
		if was_on_floor and step_height > 0.0 and absf(at.x - from.x) < absf(side.x) * 0.5:
			at = _step_up(space, from, at, side)
	var fall: float = velocity.y * delta
	# On the floor going down (or standing): look a little further, to keep to it.
	var probe: float = fall + floor_snap if was_on_floor and velocity.y >= 0.0 else fall
	if not is_zero_approx(probe):
		var free: float = _free(space, at, Vector2(0.0, probe))
		at = _from
		if free < 1.0:
			at.y += probe * free
			if probe > 0.0:
				_on_floor = true
				velocity.y = 0.0
			else:
				# A ceiling.
				velocity.y = maxf(velocity.y, 0.0)
		else:
			at.y += fall
			_on_floor = false
	global_position = at
	_placed_at = at


## `at` moved by `motion` until something's in the way, then along it (once;
## `level`: only sideways, for a platformer).
func _slide(space: PhysicsDirectSpaceState2D, at: Vector2, motion: Vector2, level: bool) -> Vector2:
	var free: float = _free(space, at, motion)
	at = _from + motion * free
	if free >= 1.0:
		return at
	var into: Vector2 = motion.normalized()
	_query.transform = Transform2D(global_rotation, at + motion * maxf(_touch - free, 0.0) + into * 0.5) * _shape_node.transform
	_query.motion = Vector2.ZERO
	var normal: Vector2 = space.get_rest_info(_query).get("normal", -into)
	var rest: Vector2 = motion * (1.0 - free)
	var along: Vector2 = rest - normal * rest.dot(normal)
	if level:
		# A platformer slides only sideways, and never into it (a cast
		# starting touching wouldn't stop it).
		along = Vector2.ZERO if absf(normal.x) > 0.001 else Vector2(rest.x, 0.0)
	if along.length_squared() > 0.0001:
		free = _free(space, at, along)
		at = _from + along * free
	return at


## Blocked low down on the floor: the same move from step_height higher,
## kept if it lands on something there.
func _step_up(space: PhysicsDirectSpaceState2D, from: Vector2, blocked: Vector2, side: Vector2) -> Vector2:
	var up: float = step_height * _free(space, from, Vector2(0.0, -step_height))
	var at: Vector2 = _from + Vector2(0.0, -up)
	var free: float = _free(space, at, side)
	if free <= 0.0:
		return blocked
	at = _from + side * free
	var drop: float = up + floor_snap
	var down: float = _free(space, at, Vector2(0.0, drop))
	if down >= 1.0:
		return blocked
	var landed: Vector2 = _from + Vector2(0.0, drop * down)
	if from.y - landed.y > step_height + 0.5 or not _floor_below(space, landed):
		# Higher than a step, or not on a floor (its rounded bottom on the
		# edge of a ledge too high).
		return blocked
	_on_floor = true
	return landed


## Whether what's under it at `at` faces up enough to stand on (within 45
## degrees; up is -y).
func _floor_below(space: PhysicsDirectSpaceState2D, at: Vector2) -> bool:
	_query.transform = Transform2D(global_rotation, at + Vector2(0.0, PUSH_GAP * 3.0)) * _shape_node.transform
	_query.motion = Vector2.ZERO
	var normal: Vector2 = space.get_rest_info(_query).get("normal", Vector2.ZERO)
	return normal.y <= -FLOOR_NORMAL_Y


## How much of `motion` its shape can go from `at` before touching something
## (1: all); pushed out first when it starts inside something (`_from`: where
## the cast started).
func _free(space: PhysicsDirectSpaceState2D, at: Vector2, motion: Vector2) -> float:
	_query.transform = Transform2D(global_rotation, at) * _shape_node.transform
	_query.motion = motion
	var free: PackedFloat32Array = space.cast_motion(_query)
	_from = at
	if free.size() >= 2 and free[1] <= 0.0:
		_from = at + _push_out(space)
		_query.transform = Transform2D(global_rotation, _from) * _shape_node.transform
		_query.motion = motion
		free = space.cast_motion(_query)
	_touch = free[1] if free.size() >= 2 else 1.0
	var safe: float = free[0] if not free.is_empty() else 1.0
	if safe >= 1.0:
		return 1.0
	# Stops PUSH_GAP short of what it hit, so the next cast sees it.
	return maxf(safe - PUSH_GAP / maxf(motion.length(), 0.0001), 0.0)


## How far out of whatever its shape (at _query's transform) overlaps or
## touches, with a little gap; just touching: up a little.
func _push_out(space: PhysicsDirectSpaceState2D) -> Vector2:
	_query.motion = Vector2.ZERO
	var points: Array[Vector2] = space.collide_shape(_query, 8)
	if points.is_empty():
		return Vector2.ZERO
	var push: Vector2 = Vector2.ZERO
	for i: int in range(0, points.size() - 1, 2):
		var depth: Vector2 = points[i + 1] - points[i]
		if depth.length_squared() > push.length_squared():
			push = depth
	return push + (push.normalized() if push.length_squared() > 0.0001 else Vector2.UP) * PUSH_GAP


func _prepare_query() -> bool:
	if _query != null and is_instance_valid(_shape_node) and _shape_node.shape == _query.shape:
		return true
	_shape_node = null
	for child: Node in get_children():
		if child is CollisionShape2D and (child as CollisionShape2D).shape != null and not (child as CollisionShape2D).disabled:
			_shape_node = child
			break
	if _shape_node == null:
		return false
	_query = PhysicsShapeQueryParameters2D.new()
	_query.shape = _shape_node.shape
	_query.collision_mask = collision_mask
	_query.exclude = [get_rid()]
	return true

#endregion


## A child every machine makes for itself: never sent, never removed.
func _add_local(child: Node) -> void:
	child.add_to_group(&"local_only")
	add_child(child)
