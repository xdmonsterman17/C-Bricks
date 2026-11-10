@tool
@icon("res://addons/brickscript/icons/nodes/character_3d.svg")
class_name BrickscriptCharacter3D
extends AnimatableBody3D

## A 3D character in one node, like a Roblox character with its Humanoid: it
## moves and looks around on its player's machine, with no bricks for the
## basics.
##
## It isn't a CharacterBody3D (move_and_slide costs ~230 us a frame on a
## Raspberry Pi 4): it's a kinematic body (others' raycasts and bodies hit it,
## it pushes rigid bodies) that moves itself with shape casts of its own
## shape: sideways (sliding along walls, stepping up ledges up to
## step_height), then up / down (landing, snapping to the floor going down
## slopes). Two casts a frame when nothing is in the way. It has `velocity`
## and is_on_floor() like a CharacterBody3D.
##
## - On the player's machine (the one that owns the character: network
##   ownership, Network Context Engine API 14; offline / without the engine,
##   this machine): reads WASD (the actions below) and moves (walk, jump,
##   gravity), turns with the mouse and tilts the head, and
##   its camera is the current one. A click in the game captures the mouse,
##   Esc frees it.
## - On the server: hands the character's movement to its player (Owner of
##   the character) with a speed limit, and syncs its position and rotation,
##   so everyone sees it.
## - Everywhere else: it glides where its player puts it (its packed state,
##   below), and On the floor / Moving / Falling come from that state.
##
## Health: `health` / `max_health`, changed only where the game runs (the
## server; offline, this machine): damage(), heal(), set_health(),
## set_max_health(). Every machine gets it (sent only when it changes, and
## asked for when a machine's copy is made) and hears health_changed; at 0
## it dies (died, on every machine) and its player's machine stops moving it.
## How it falls and dies (Death settings) can come from its Character
## Spawner.
##
## Network: with the Network Context Engine API 15 it syncs one packed state
## (sync_packed, 17 bytes: position, facing, head tilt, on the floor /
## looking / moving / falling) instead of separate properties; the server
## checks a player's state against the speed limit (_network_check). Its
## velocity elsewhere is worked out from the states.
##
## Made when the scene has none (local-only children: every machine makes
## its own): a capsule shape (Shape settings), and a "Head" at eye height
## (it tilts up / down) with a "Camera" on it (Controlled by Player only:
## an NPC's is made if it's ever seen through). In the editor it adds the
## shape to the scene instead (saved with it: no "no shape" warning, and it
## can be seen and edited); that shape follows the Shape settings.

const Net := preload("res://addons/brickscript/runtime/character_net.gd")
const AirPaths := preload("res://addons/brickscript/runtime/air_paths.gd")

## Humanoid: walks, jumps, falls. Drone: flies (no gravity; see _fly()), a
## ball shape when the scene gives it none; dead, it drops like a humanoid.
enum Kind { HUMANOID, DRONE }
## Falling below fall_limit (From spawner: its Character Spawner's setting;
## not spawned by one: Put back).
enum FallAction { FROM_SPAWNER, DIE, PUT_BACK }
## How it dies: Default (falls over), Scripted (its death scripts do it).
enum DeathLook { FROM_SPAWNER, DEFAULT, SCRIPTED }
## Who steers it: Player (its player's keys and mouse; its camera is theirs)
## or Script (an NPC: bricks / code set move_direction and call jump_now()).
## Either way it moves on the machine that owns it (no player: the server).
enum ControlledBy { PLAYER, SCRIPT }
## How a walk ended (walk_to_end()): it got there; no path gets there, or it
## got stuck; it was stopped (stop_walking(), a newer walk_to() / follow())
## or died.
enum WalkEnd { ARRIVED, CANT_REACH, STOPPED }

## Its health changed (on every machine).
signal health_changed(health: float, max_health: float)
## Its health reached 0 (on every machine). `killer`: the player who did it
## (0: nobody).
signal died(killer: int)
## A walk (walk_to() / follow()) ended: its number and how (WalkEnd).
signal _walk_done(walk: int, end: int)

## How it moves: Humanoid (walks) or Drone (flies).
@export var kind: Kind = Kind.HUMANOID:
	set(value):
		kind = value
		_update_made_shape()
@export var controlled_by: ControlledBy = ControlledBy.PLAYER:
	set(value):
		controlled_by = value
		# A player's character is never slowed down far from the camera (the
		# Cull Throttle Engine's group, shared by name like `local_only`).
		if value == ControlledBy.PLAYER:
			add_to_group(FULL_RATE_GROUP)
		elif is_in_group(FULL_RATE_GROUP):
			remove_from_group(FULL_RATE_GROUP)

@export_group("Movement")
## Walking speed, units a second.
@export var walk_speed: float = 6.0
## Upward speed of a jump, units a second.
@export var jump_power: float = 7.0
## Pull down, units a second per second.
@export var gravity: float = 20.0
## Below this height (it fell off the world) it dies or is put back where it
## started (Death > Fall action).
@export var fall_limit: float = -20.0
## Ledges up to this high are stepped up (stairs); 0: none.
@export var step_height: float = 0.35
## Walking down a slope or a step up to this far, it keeps to the floor
## instead of flying off.
@export var floor_snap: float = 0.25
## Passes through everything but the ground: Terrains, and nodes in the group
## GROUND_GROUP (its casts and rays leave the rest out).
@export var no_clip: bool = false

@export_group("Drone")
## How fast a drone gets to its speed and back to a stop, units a second per
## second (it glides). Its speed is walk_speed.
@export var fly_acceleration: float = 12.0

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
## Scripted: runs where the game runs when it dies (moves the body, scores,
## Remove character). Empty: its Character Spawner's.
@export_file("*.brickserver", "*.gd") var death_server_script: String = ""
## Scripted: runs on every machine when it dies (effects only: sound,
## particles, the camera, UI). Empty: its Character Spawner's.
@export_file("*.bricklocal", "*.gd") var death_local_script: String = ""

@export_group("Camera")
## The eyes above the character's middle.
@export var eye_height: float = 0.7
## How far the view turns per pixel the mouse moves (radians).
@export var mouse_sensitivity: float = 0.0025
## A click in the game captures the mouse (for looking around), Esc frees it.
@export var capture_mouse: bool = true
## The camera's field of view, degrees.
@export var field_of_view: float = 80.0
## Meshes others see but its own camera doesn't (its head and face, which
## would block the view): them and the meshes under them.
@export var hidden_from_own_camera: Array[NodePath] = []

@export_group("Shape")
## The capsule it makes when the scene gives it no CollisionShape3D.
@export var shape_radius: float = 0.4:
	set(value):
		shape_radius = value
		_update_made_shape()
@export var shape_height: float = 1.8:
	set(value):
		shape_height = value
		_update_made_shape()

@export_group("Input")
@export var move_forward: StringName = &"move_forward"
@export var move_back: StringName = &"move_back"
@export var move_left: StringName = &"move_left"
@export var move_right: StringName = &"move_right"
@export var jump: StringName = &"jump"
## A drone rises while jump is held and sinks while this is.
@export var fly_down: StringName = &"fly_down"

@export_group("Network")
## The fastest the server lets its player move it (units a second; a cheat
## check). 0: three times the walk speed, plus a fall.
@export var max_speed: float = 0.0

## Every character is in it while in the game (Nearest character finds
## them there).
const GROUP: StringName = &"brickscript_characters"
## What No clip doesn't pass through: nodes in this group (and Terrains, the
## Terrain Engine's group TERRAINS_GROUP, by name).
const GROUND_GROUP: StringName = &"ground"
const TERRAINS_GROUP: StringName = &"terrain_engine_terrains"
## Marks a shape it made in the editor (it follows the Shape settings).
const MADE_SHAPE_META: StringName = &"_brickscript_made_shape"
## On a shape only shown in the editor (add_preview_shape()).
const PREVIEW_SHAPE_META: StringName = &"_brickscript_preview_shape"
## Editor: it came with its scene when opened (see _ready()).
var _opened: bool = false

## Properties Brickscript's Property (Get) may read but Property (Set) can't
## (node_types.gd marks them read only).
const _BRICKSCRIPT_READ_ONLY: PackedStringArray = ["on_the_floor", "moving", "falling", "dead", "walking"]

## The settings Property (Set) (its change()) can change.
const CHANGEABLE: Array[StringName] = [&"walk_speed", &"jump_power", &"gravity", &"eye_height", &"mouse_sensitivity", &"field_of_view", &"capture_mouse", &"no_clip", &"fly_acceleration"]

## Units a second, as on a CharacterBody3D (on its player's machine: what it
## moves by; elsewhere: worked out from the states).
var velocity: Vector3 = Vector3.ZERO
## The head (it tilts up / down) and the camera on it.
var head: Node3D = null
var camera: Camera3D = null
## Whether the mouse is captured for looking around (on the player's machine).
var looking: bool = false
## Whether this machine's player has the mouse captured (a click captured
## it, Esc not pressed since): a new character of theirs (after dying) starts
## looking around at once (2026-11-02).
static var _mouse_kept: bool = false
## Controlled by Script: where it walks, in world space (up / down ignored,
## but a drone flies up / down too; length 1 = walk_speed, longer is cut to
## 1). Set on the machine that moves it.
var move_direction: Vector3 = Vector3.ZERO
## Whether a Walk to / Follow is steering it (on the machine that moves it);
## read only.
var walking: bool:
	get:
		return _walk != 0
	set(_value):
		_read_only(&"walking")
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

## Where it started (put back there when it falls below fall_limit).
var _start: Vector3 = Vector3.ZERO
var _started: bool = false
## A jump press waiting for the next physics step (a tap between two is kept).
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
## arrival seconds, positions, yaws, head pitches; typed arrays: this runs
## every frame for every character); and how it is there.
var _times: PackedFloat64Array = PackedFloat64Array()
var _spots: PackedVector3Array = PackedVector3Array()
var _yaws: PackedFloat32Array = PackedFloat32Array()
var _pitches: PackedFloat32Array = PackedFloat32Array()
## The head pitch last shown by a glide (set only when it changes), and
## whether its scale is 1 (looked at when a state arrives).
var _shown_pitch: float = 0.0
var _unscaled: bool = true
var _remote_floor: bool = false
var _remote_moving: bool = false
## Whether hidden_from_own_camera's meshes are hidden (it's this machine's).
var _own_view_hidden: bool = false
var _remote_falling: bool = false
## Seconds towards the next regen (where the game runs).
var _regen_wait: float = 0.0
## _roles_here(), and whether it's still right.
var _roles: int = 0
var _roles_known: bool = false

## Whether its last move ended on the floor (its player's machine).
var _on_floor: bool = false

## Walking (walk_to() / follow(), Controlled by Script): the walk going on
## (its number; 0: none), the last one's number, Follow's target (null: a
## Walk to), where it goes and how close is there, its path and the next
## point on it, whether the path must be found (again), Follow's wait for
## that, and its stuck check (where it last got somewhere, and since when).
var _walk: int = 0
var _walks: int = 0
var _follow_target: Node3D = null
## A drone following: how high above its target it keeps (its height above
## it when the Follow began; none below it).
var _follow_height: float = 0.0
var _goal: Vector3 = Vector3.ZERO
var _within: float = 0.5
var _path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _route_needed: bool = false
## A drone's air path being looked for (air_paths.gd), a little each frame.
var _air_search: AirPaths.Search = null
var _map_waits: int = 0
## Navigation maps looked at by _tell_if_empty: the map iteration it found
## polygons in, or -1 once it found none and said so.
static var _empty_maps_told: Dictionary[RID, int] = {}
var _repath_wait: float = 0.0
var _stuck_from: Vector3 = Vector3.ZERO
var _stuck_time: float = 0.0
## The cast of its own shape (made at the first move), the shape's place on
## the body, and during a move: that turned as the body is, where the last
## cast started and how far it went before touching.
var _query: PhysicsShapeQueryParameters3D = null
var _shape_node: CollisionShape3D = null
var _shape_offset: Transform3D = Transform3D.IDENTITY
var _cast_basis: Basis = Basis.IDENTITY
var _cast_offset: Vector3 = Vector3.ZERO
var _from: Vector3 = Vector3.ZERO
var _touch: float = 1.0
## Where its last move left it: anywhere else, something put it there (made,
## a teleport, the server's correction), so it checks it isn't inside
## something first (Jolt's casts don't see what they start in or touch).
var _placed_at: Vector3 = Vector3.INF
## How it was turned then, and whether turning moves its shape (one that
## isn't round about its up axis: a box; turned, it's checked as if placed).
var _placed_basis: Basis = Basis.IDENTITY
var _turning_moves_shape: bool = false
## Resting (_resting()): seconds to its next look at the floor.
var _rest_wait: float = 0.0
## For steps: a ray, the last one's surface normal, how far its shape reaches
## out sideways and down from its origin.
var _ray: PhysicsRayQueryParameters3D = null
var _ray_normal: Vector3 = Vector3.UP
var _reach: float = 0.5
var _feet: float = 1.0
## Its shape's height (feet to top).
var _tall: float = 2.0
## No clip: the look around for what its casts leave out, whether they
## leave some out now, and where / when it last looked.
var _clip_query: PhysicsShapeQueryParameters3D = null
var _clipping: bool = false
var _clip_at: Vector3 = Vector3.INF
var _clip_frame: int = 0

## The gap it keeps when pushed out of something.
const PUSH_GAP: float = 0.01
## How far past the touching point _contact_normal() looks (the shapes must
## overlap there; deeper, a corner's normal turns towards the move).
const CONTACT_DEPTH: float = 0.005
## Standing still, it looks at its floor this often (_resting()).
const REST_CHECK_SEC: float = 0.1
## How far behind where it is its casts start (see _cast()).
const CAST_BACK: float = 0.005
## A floor's normal points at least this much up (45 degrees).
const FLOOR_NORMAL_Y: float = 0.7
## How far past a cast's hit its shape is looked at, to tell a real hit
## from a ghost one (_ghost_hit), in meters.
const GHOST_CHECK: float = 0.02
## How high it's lifted over a rise of the ground too low to be a step
## that it can't slide up (_slide), in meters.
const GROUND_LIFT: float = 0.03
## No clip's look around lasts this many physics frames, while it stays
## this close (meters) to where it looked.
const CLIP_FRAMES: int = 15
const CLIP_MOVE: float = 0.5
## The render layer hidden_from_own_camera meshes are on while it's this
## machine's (its camera leaves it out).
const OWN_VIEW_HIDDEN_LAYER: int = 1 << 19
## A packed state's size (see _network_pack).
const STATE_BYTES: int = 17
## Flags in a packed state.
const ON_FLOOR: int = 1
const LOOKING: int = 2
const MOVING: int = 4
const FALLING: int = 8
## Shown this far behind the newest state (two updates: smooth through one late).
## The Cull Throttle Engine's group of objects never slowed down (by name:
## Brickscript doesn't need that plugin).
const FULL_RATE_GROUP: StringName = &"full_rate"
const GLIDE_DELAY_SEC: float = 0.1
## After the newest state, it runs on with its velocity at most this long.
const RUN_ON_SEC: float = 0.1
## A pause longer than this: the next glide starts from where it stands.
const GLIDE_GAP_SEC: float = 0.125
## Units allowed on top of the speed limit (the server's check).
const MOVE_SLACK: float = 1.0
## Walking: how fast it turns to face where it goes (radians a second); a
## path's point is passed this close (flat), or once it's gone past it along
## the way there (turning earlier cuts a corner the navigation keeps only its
## agent radius from: into the wall, BUGS.md 2026-10-31); no further than STUCK_MOVE in
## STUCK_SEC: stuck (Walk to gives up, Follow finds its path again); Follow
## finds its path again this often or when its target moved REPATH_MOVED; a
## path ending further than Within + PATH_END_SLACK from the goal (flat), or
## PATH_END_HEIGHT above / below it, doesn't get there.
const TURN_SPEED: float = 10.0
const PATH_POINT_REACHED: float = 0.1
const STUCK_MOVE: float = 0.25
const STUCK_SEC: float = 2.0
const REPATH_SEC: float = 0.5
const REPATH_MOVED: float = 1.0
const PATH_END_SLACK: float = 0.5
const PATH_END_HEIGHT: float = 2.0
## Following, blocked this long within its distance + CROWD_REACH of its
## target (others around it already): it stands there.
const CROWD_SEC: float = 0.5
const CROWD_REACH: float = 1.5
## Physics frames a walk waits for its navigation to be ready (see
## _map_ready()); then it goes on with what's there. A Terrain still building
## its navigation in this world is waited for however long it takes.
const MAP_WAIT_FRAMES: int = 60
## A drone's air path search: time it may take each physics frame (us); a
## path point counts as passed this close (all round, meters).
const AIR_SEARCH_USEC: int = 2000
const AIR_POINT_REACHED: float = 0.6


func _init() -> void:
	# (Controlled by Player is the default: its setter only runs when set.)
	add_to_group(FULL_RATE_GROUP)


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
	add_to_group(GROUP)
	if not _has_shape():
		_add_local(_new_shape())
	head = get_node_or_null(^"Head") as Node3D
	if head == null:
		head = Node3D.new()
		head.name = "Head"
		_add_local(head)
	head.position = Vector3(0.0, eye_height, 0.0)
	# (A scene's own camera keeps its field of view.)
	camera = head.get_node_or_null(^"Camera") as Camera3D
	if camera != null:
		camera.cull_mask &= ~OWN_VIEW_HIDDEN_LAYER
	elif controlled_by == ControlledBy.PLAYER:
		# (An NPC gets none: nobody looks through it. Made when it's seen
		# through after all.)
		_make_camera()
	_watching = Net.watch_owners(self, _forget_mine)
	_hand_over.call_deferred()
	Net.ask_health(self)


func _process(delta: float) -> void:
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
	# (Only a player's character is seen through: an NPC's camera stays off.)
	var viewed: bool = mine and controlled_by == ControlledBy.PLAYER
	if viewed and camera == null and head != null:
		_make_camera()
	if camera != null and camera.is_inside_tree() and camera.current != viewed:
		if viewed:
			camera.make_current()
			# (Seen through now: the player had the mouse captured before,
			# e.g. their last character died.)
			if _mouse_kept and capture_mouse and not looking:
				_capture(true)
		else:
			camera.current = false
	if viewed != _own_view_hidden and not hidden_from_own_camera.is_empty():
		_hide_from_own_camera(viewed)
	if regen_per_second > 0.0:
		_regen_wait = Net.regen(self, _regen_wait, delta)


func _physics_process(delta: float) -> void:
	if not is_mine():
		return
	# (Its transform read once: each read of a body's costs.)
	var placed: Transform3D = global_transform
	var dead: bool = health <= 0.0
	if dead and placed.origin.y < fall_limit:
		# Died falling: it stays where it fell.
		return
	if _walk != 0:
		_steer(delta, placed.origin, dead)
		# (It may have turned.)
		placed = global_transform
	if kind == Kind.DRONE and not dead:
		_drone_step(delta, placed)
		return
	var walk: Vector3 = Vector3.ZERO
	if dead:
		pass
	elif controlled_by == ControlledBy.SCRIPT:
		walk = Vector3(move_direction.x, 0.0, move_direction.z).limit_length(1.0) * walk_speed
	else:
		var push: Vector2 = Input.get_vector(move_left, move_right, move_forward, move_back)
		walk = placed.basis * Vector3(push.x, 0.0, push.y) * walk_speed
	if _resting(walk, placed, delta):
		return
	velocity.x = walk.x
	velocity.z = walk.z
	velocity.y -= gravity * delta
	if _jump_pressed and _on_floor and not dead:
		velocity.y = jump_power
	_jump_pressed = false
	var at: Vector3 = _move(delta, placed)
	if not _started:
		_start = at
		_started = true
	elif at.y < fall_limit:
		_fell()


## Standing still on the floor where its last move left it (not walking,
## jumping, put somewhere or turned): no casts, but for a look at the floor
## every REST_CHECK_SEC (gone, it falls). Most characters stand most of the
## time.
func _resting(walk: Vector3, placed: Transform3D, delta: float) -> bool:
	if not _started or not _on_floor or _jump_pressed or walk.length_squared() > 0.0 \
			or placed.origin != _placed_at or _turning_moves_shape and placed.basis != _placed_basis:
		_rest_wait = REST_CHECK_SEC
		return false
	_rest_wait -= delta
	if _rest_wait <= 0.0:
		_rest_wait = REST_CHECK_SEC
		return false
	velocity = Vector3.ZERO
	return true


func _unhandled_input(event: InputEvent) -> void:
	if not is_mine() or controlled_by == ControlledBy.SCRIPT:
		return
	if health <= 0.0 and not event.is_action_pressed(&"ui_cancel"):
		# Dead: no looking around or jumping (Esc still frees the mouse).
		return
	if event.is_action_pressed(jump):
		_jump_pressed = true
	if event is InputEventMouseMotion and looking:
		var motion: Vector2 = (event as InputEventMouseMotion).relative
		rotate_y(-motion.x * mouse_sensitivity)
		if head != null:
			head.rotation.x = clampf(head.rotation.x - motion.y * mouse_sensitivity, -1.5, 1.5)
	elif capture_mouse and event is InputEventMouseButton and (event as InputEventMouseButton).pressed and not looking:
		# The click that captures doesn't count as anything else.
		_capture(true)
		get_viewport().set_input_as_handled()
	elif capture_mouse and event.is_action_pressed(&"ui_cancel") and looking:
		_capture(false)


## Captures the mouse for looking around, or gives it back (remembered for
## the player's next character).
func _capture(on: bool) -> void:
	looking = on
	_mouse_kept = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


## Server: takes `amount` off its health (`by`: the player who did it, 0:
## nobody); at 0 it dies. False elsewhere and when it's dead.
## Jumps at its next move if it's on the floor then (on the machine that
## moves it; for Controlled by Script, but a player's character jumps too).
func jump_now() -> void:
	if is_mine():
		_jump_pressed = true


## Walks (Controlled by Script) along a navigation path to `to` (a Vector3,
## or a Node3D: where it is now) until it's within `within` of it (flat),
## turning to face the way it goes. Await it: true when it got there, false
## when it didn't (walk_to_end() says why). With no navigation area
## (NavigationRegion3D) in its world it walks straight there. Always takes at
## least a physics frame.
func walk_to(to: Variant, within: float = 0.5) -> bool:
	return await walk_to_end(to, within) == WalkEnd.ARRIVED


## walk_to(), giving how it ended (WalkEnd): ARRIVED; CANT_REACH (no path
## gets there, stuck, or it isn't a character that can walk: an error says
## why); STOPPED (stop_walking(), a newer walk_to() / follow(), or it died).
func walk_to_end(to: Variant, within: float = 0.5) -> WalkEnd:
	var goal: Variant = _goal_of(to, &"Walk to")
	if goal == null or not _can_walk(&"Walk to"):
		await get_tree().physics_frame
		return WalkEnd.STOPPED if goal != null and health <= 0.0 else WalkEnd.CANT_REACH
	var walk: int = _start_walk(null, goal, within)
	if _walk != walk:
		# (Something the ended walk ran started another at once.)
		return WalkEnd.STOPPED
	while true:
		var done: Array = await _walk_done
		if done[0] == walk:
			return done[1]
	return WalkEnd.STOPPED


## Walks after `target` (Controlled by Script), keeping within `distance` of
## it, finding its path again as the target moves; standing, it faces it.
## Goes on until stop_walking(), a newer walk, the target leaves or it dies.
func follow(target: Node3D, distance: float = 2.0) -> void:
	if not is_instance_valid(target):
		push_error("Follow: %s has nothing to follow" % name)
		return
	if not _can_walk(&"Follow"):
		return
	if _walk != 0 and _follow_target == target:
		# (Already after it: an NPC's script asking again each tick.)
		_within = maxf(distance, 0.05)
		return
	_follow_height = maxf(global_position.y - target.global_position.y, 0.0) if kind == Kind.DRONE else 0.0
	_start_walk(target, _follow_point(target), distance)


## Where a Follow heads for: its target, a drone _follow_height above it
## (it keeps its height rather than coming down to a walker's, BUGS.md
## 2026-10-31).
func _follow_point(target: Node3D) -> Vector3:
	return target.global_position + Vector3(0.0, _follow_height, 0.0)


## Ends a Walk to (it gets STOPPED) or a Follow; it stands still.
func stop_walking() -> void:
	if _walk != 0:
		_end_walk(WalkEnd.STOPPED)


## The path a character would walk from `from` to `to` in `world`'s
## navigation (empty: no navigation area there yet; otherwise it ends at the
## reachable point closest to `to`).
static func path_between(world: World3D, from: Vector3, to: Vector3) -> PackedVector3Array:
	var map: RID = world.navigation_map
	if not _map_ready(map, from) or NavigationServer3D.map_get_regions(map).is_empty():
		return PackedVector3Array()
	return NavigationServer3D.map_get_path(map, from, to, true)


func _can_walk(brick: StringName) -> bool:
	if controlled_by != ControlledBy.SCRIPT:
		push_error("%s: %s is Controlled by Player (set Controlled by to Script)" % [brick, name])
		return false
	if not is_mine():
		push_error("%s: %s moves on another machine (its player's, or the server's)" % [brick, name])
		return false
	return health > 0.0


func _goal_of(to: Variant, brick: StringName) -> Variant:
	if to is Vector3:
		return to
	if to is Node3D and is_instance_valid(to):
		return (to as Node3D).global_position
	push_error("%s: %s isn't a place (a Vector3 or a 3D node)" % [brick, to])
	return null


## Ends the walk going on (false) and starts another; returns its number.
func _start_walk(target: Node3D, goal: Vector3, within: float) -> int:
	var ended: int = _walk
	_walks += 1
	_walk = _walks
	_follow_target = target
	_goal = goal
	_within = maxf(within, 0.05)
	_path = PackedVector3Array()
	_air_search = null
	_path_index = 0
	_route_needed = true
	_repath_wait = REPATH_SEC
	_stuck_from = global_position
	_stuck_time = 0.0
	if ended != 0:
		_walk_done.emit(ended, WalkEnd.STOPPED)
	return _walks


func _end_walk(end: WalkEnd) -> void:
	var ended: int = _walk
	_walk = 0
	_follow_target = null
	_path = PackedVector3Array()
	_air_search = null
	move_direction = Vector3.ZERO
	_walk_done.emit(ended, end)


## A walk's frame (before it moves): ends it, or sets move_direction along
## its path and turns that way.
func _steer(delta: float, here: Vector3, dead: bool) -> void:
	if dead:
		_end_walk(WalkEnd.STOPPED)
		return
	if _follow_target != null:
		if not is_instance_valid(_follow_target) or not _follow_target.is_inside_tree():
			_end_walk(WalkEnd.STOPPED)
			return
		var at: Vector3 = _follow_point(_follow_target)
		_repath_wait -= delta
		if _repath_wait <= 0.0 or at.distance_squared_to(_goal) > REPATH_MOVED * REPATH_MOVED:
			_goal = at
			_route_needed = true
			_repath_wait = REPATH_SEC
	if _close_to(here, _goal, _within) or _follow_target != null and _stuck_time > CROWD_SEC and _close_to(here, _goal, _within + CROWD_REACH):
		if _follow_target == null:
			_end_walk(WalkEnd.ARRIVED)
			return
		# Close enough, or as close as the others around it let it get: it
		# stands (and rests) instead of pushing.
		move_direction = Vector3.ZERO
		_turn_to(_goal - here, delta)
		_stuck_from = here
		if _stuck_time <= CROWD_SEC:
			_stuck_time = 0.0
		return
	if _route_needed:
		var map: RID = get_world_3d().navigation_map
		if kind == Kind.DRONE:
			# Straight there when nothing is in the way, else an air path
			# (air_paths.gd: looked for a little each frame, hovering).
			if _air_search == null:
				var exclude: Array[RID] = [get_rid()]
				if AirPaths.line_clear(get_world_3d(), here, _goal, shape_radius, exclude):
					_path = PackedVector3Array([_goal])
				else:
					_air_search = AirPaths.search(get_world_3d(), get_tree(), here, _goal, shape_radius, exclude)
			if _air_search != null:
				if _air_search.step(AIR_SEARCH_USEC) == AirPaths.State.SEARCHING:
					move_direction = Vector3.ZERO
					_stuck_from = here
					return
				_path = _air_search.path
				_air_search = null
		elif not _map_ready(map, here) and _map_waits < MAP_WAIT_FRAMES or _terrain_building():
			_map_waits += 1
			return
		elif NavigationServer3D.map_get_regions(map).is_empty():
			_path = PackedVector3Array([_goal])
		else:
			_tell_if_empty(map)
			_path = NavigationServer3D.map_get_path(map, here, _goal, true)
			if _path.is_empty() or not _close_to(_path[_path.size() - 1], _goal, _within + PATH_END_SLACK):
				_path = PackedVector3Array()
		_path_index = 0
		_route_needed = false
		if _path.is_empty():
			if _follow_target == null:
				_end_walk(WalkEnd.CANT_REACH)
			else:
				# Out of reach for now: it waits, and looks again.
				move_direction = Vector3.ZERO
			return
	while _path_index < _path.size() - 1 and _passed(_path_index, here):
		_path_index += 1
	var aim: Vector3 = _path[_path_index] if _path_index < _path.size() - 1 else _goal
	var way: Vector3 = aim - here if kind == Kind.DRONE else Vector3(aim.x - here.x, 0.0, aim.z - here.z)
	move_direction = way.normalized() if way.length_squared() > 0.0001 else Vector3.ZERO
	_turn_to(way, delta)
	if here.distance_squared_to(_stuck_from) >= STUCK_MOVE * STUCK_MOVE:
		_stuck_from = here
		_stuck_time = 0.0
	else:
		_stuck_time += delta
		if _stuck_time > STUCK_SEC:
			_stuck_time = 0.0
			if _follow_target == null:
				_end_walk(WalkEnd.CANT_REACH)
			else:
				_route_needed = true


## Whether a walk's path point `index` is behind it: within
## PATH_POINT_REACHED (flat), or gone past along the way from the point
## before it (or from where the path started).
func _passed(index: int, here: Vector3) -> bool:
	if kind == Kind.DRONE:
		if here.distance_to(_path[index]) < AIR_POINT_REACHED:
			return true
		var before: Vector3 = _path[index - 1] if index > 0 else _stuck_from
		return index > 0 and (_path[index] - before).dot(here - _path[index]) > 0.0
	var point: Vector2 = Vector2(_path[index].x, _path[index].z)
	var at: Vector2 = Vector2(here.x, here.z)
	if at.distance_to(point) < PATH_POINT_REACHED:
		return true
	if index == 0:
		return false
	var way: Vector2 = point - Vector2(_path[index - 1].x, _path[index - 1].z)
	return way.length_squared() > 0.0001 and way.dot(at - point) > 0.0


## A map with regions but no polygons (a NavigationMesh never baked, or
## baked from nothing): every walk can't reach. Said once per map.
func _tell_if_empty(map: RID) -> void:
	# (Looked at once per map change: paths are asked for often.)
	var iteration: int = NavigationServer3D.map_get_iteration_id(map)
	if iteration == 0 or _empty_maps_told.get(map, 0) != 0 and (_empty_maps_told[map] < 0 or _empty_maps_told[map] == iteration):
		return
	_empty_maps_told[map] = iteration
	if NavigationServer3D.map_get_closest_point_owner(map, global_position).is_valid():
		return
	_empty_maps_told[map] = -1
	push_error("Walk to / Follow (%s): the navigation has a NavigationRegion3D but nothing to walk on (its NavigationMesh is empty), so every walk can't reach. Bake it: select the region, Bake NavigationMesh (it reads its children, or the nodes in its Source Group Name with Parsed Geometry Type Static Colliders)." % name)


## Whether a Terrain (the Terrain Engine, by method name) in this world
## bakes navigation and isn't ready yet: a walk started from When ready
## waits for it rather than going straight (BUGS.md 2026-10-31).
func _terrain_building() -> bool:
	for terrain: Node in get_tree().get_nodes_in_group(TERRAINS_GROUP):
		if terrain is Node3D and (terrain as Node3D).get_world_3d() == get_world_3d() and bool(terrain.get(&"navigation")) and terrain.has_method(&"is_ready") and not bool(terrain.call(&"is_ready")):
			return true
	return false


## Whether a navigation map can give paths: synced once, and its regions'
## polygons in it (with async iterations, Godot's default, a region's mesh
## joins a sync or two after the region: paths until then are empty).
static func _map_ready(map: RID, near: Vector3) -> bool:
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return false
	return NavigationServer3D.map_get_regions(map).is_empty() or NavigationServer3D.map_get_closest_point_owner(map, near).is_valid()


## Whether `at` is within `within` of `goal` (flat) and not too far above /
## below it (a drone: within it all round).
func _close_to(at: Vector3, goal: Vector3, within: float) -> bool:
	if kind == Kind.DRONE:
		return at.distance_to(goal) <= within
	return Vector2(goal.x - at.x, goal.z - at.z).length() <= within and absf(goal.y - at.y) <= PATH_END_HEIGHT


## Turns it (its yaw) towards a flat direction, at TURN_SPEED.
func _turn_to(way: Vector3, delta: float) -> void:
	if Vector2(way.x, way.z).length_squared() < 0.0001:
		return
	rotation.y = rotate_toward(rotation.y, atan2(-way.x, -way.z), TURN_SPEED * delta)


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


## Below fall_limit on the machine that moves it: put back where it started,
## or it stays there and dies (killed where the game runs: here, or the
## server when its state arrives).
func _fell() -> void:
	if get_fall_action() == FallAction.PUT_BACK:
		global_position = _start
		velocity = Vector3.ZERO
		return
	velocity = Vector3.ZERO
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


## Whether it's walking (moving sideways faster than a crawl).
func is_moving() -> bool:
	if not is_mine():
		return _remote_moving
	return (velocity.length() if kind == Kind.DRONE else Vector2(velocity.x, velocity.z).length()) > 0.1


## Whether its last move ended on the floor (as CharacterBody3D's).
func is_on_floor() -> bool:
	return _on_floor


## Whether it stands on the floor (moved on another machine: as it was there).
func on_floor() -> bool:
	return _on_floor if is_mine() else _remote_floor


## Whether it's in the air, going down.
func is_falling() -> bool:
	if not is_mine():
		return _remote_falling
	return not is_on_floor() and velocity.y < 0.0 and (kind != Kind.DRONE or health <= 0.0)


## Its state for the network (Network Context Engine sync_packed): position
## (3 x float), yaw and head pitch (16 bits each), flags (ON_FLOOR, LOOKING,
## MOVING, FALLING).
func _network_pack() -> PackedByteArray:
	var state: PackedByteArray = PackedByteArray()
	state.resize(STATE_BYTES)
	state.encode_float(0, position.x)
	state.encode_float(4, position.y)
	state.encode_float(8, position.z)
	state.encode_u16(12, Net.angle_bits(rotation.y))
	state.encode_u16(14, Net.angle_bits(head.rotation.x if head != null else 0.0))
	state[16] = (ON_FLOOR if on_floor() else 0) | (LOOKING if looking else 0) | (MOVING if is_moving() else 0) | (FALLING if is_falling() else 0)
	return state


## How often its states arrive here (every Nth update, Network Context
## Engine API 19, e.g. far away with the Cull Throttle Engine): it glides
## that much further behind, so it doesn't stop between them.
var _rate: int = 1


func _network_rate(interval: int) -> void:
	_rate = maxi(interval, 1)


## A state from the network: glided to (at_once: set, a first state or the
## server's correction).
func _network_unpack(state: PackedByteArray, at_once: bool) -> void:
	if state.size() < STATE_BYTES:
		return
	var where: Vector3 = Vector3(state.decode_float(0), state.decode_float(4), state.decode_float(8))
	var yaw: float = Net.bits_angle(state.decode_u16(12))
	var pitch: float = Net.bits_angle(state.decode_u16(14))
	if not where.is_finite():
		return
	var flags: int = state[16]
	_remote_floor = flags & ON_FLOOR != 0
	_remote_moving = flags & MOVING != 0
	_remote_falling = flags & FALLING != 0
	if at_once or is_mine() or _snaps:
		_clear_states()
		_place(where, yaw, pitch)
		return
	looking = flags & LOOKING != 0
	var now: float = Time.get_ticks_msec() * 0.001
	var count: int = _times.size()
	if count == 0 or now - _times[count - 1] > GLIDE_GAP_SEC * _rate:
		# From rest: glide from where it stands, not from an old state.
		_clear_states()
		_add_state(now - Net.SYNC_SEC * _rate, position, rotation.y, head.rotation.x if head != null else 0.0)
		count = 1
	# Its velocity there, from the last two states (sideways only while
	# moving, up / down only in the air).
	var moved: Vector3 = (where - _spots[count - 1]) / maxf(now - _times[count - 1], 0.01)
	velocity = Vector3(moved.x if _remote_moving else 0.0, 0.0 if _remote_floor else moved.y, moved.z if _remote_moving else 0.0)
	_add_state(now, where, yaw, pitch)
	if count >= 8:
		_drop_oldest()
	# (Read here, not every frame: it costs.)
	_unscaled = scale == Vector3.ONE


## Server: whether a state its player's machine sent can be right (no faster
## than the speed limit; numbers only).
func _network_check(previous: PackedByteArray, state: PackedByteArray, seconds: float) -> bool:
	if state.size() < STATE_BYTES:
		return false
	var to: Vector3 = Vector3(state.decode_float(0), state.decode_float(4), state.decode_float(8))
	if not to.is_finite():
		return false
	if to.y < fall_limit and health > 0.0 and get_fall_action() == FallAction.DIE:
		# Its player's machine has it below the limit (every state is checked
		# here, taken or refused): it dies.
		kill()
	if previous.size() < STATE_BYTES:
		return true
	var from: Vector3 = Vector3(previous.decode_float(0), previous.decode_float(4), previous.decode_float(8))
	return from.distance_to(to) <= _speed_limit() * seconds + MOVE_SLACK


## Shows it GLIDE_DELAY_SEC behind the newest state: between the two around
## that time, or run on a little with its velocity after the newest. (Every
## frame for every character moved elsewhere: kept to plain steps.)
func _glide() -> void:
	var shown: float = Time.get_ticks_msec() * 0.001 - GLIDE_DELAY_SEC * _rate
	var count: int = _times.size()
	while count >= 2 and _times[1] <= shown:
		_drop_oldest()
		count -= 1
	var where: Vector3
	var yaw: float
	var pitch: float
	if count >= 2:
		var start: float = _times[0]
		var span: float = _times[1] - start
		var weight: float = clampf((shown - start) / span, 0.0, 1.0) if span > 0.001 else 1.0
		where = _spots[0].lerp(_spots[1], weight)
		yaw = lerp_angle(_yaws[0], _yaws[1], weight)
		pitch = lerpf(_pitches[0], _pitches[1], weight)
	else:
		var ahead: float = shown - _times[0]
		where = _spots[0] + velocity * clampf(ahead, 0.0, RUN_ON_SEC)
		yaw = _yaws[0]
		pitch = _pitches[0]
		if ahead > RUN_ON_SEC:
			# Settled: nothing to do until the next state (which glides from here).
			_clear_states()
	var turn: Basis = Basis(Vector3.UP, yaw)
	transform = Transform3D(turn if _unscaled else turn * Basis.from_scale(scale), where)
	if head != null and pitch != _shown_pitch:
		_shown_pitch = pitch
		head.rotation.x = pitch


## Where it is and which way it faces, in one go (one transform change).
func _place(where: Vector3, yaw: float, pitch: float) -> void:
	transform = Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(scale), where)
	if head != null:
		head.rotation.x = pitch
		_shown_pitch = pitch


func _add_state(time: float, where: Vector3, yaw: float, pitch: float) -> void:
	_times.append(time)
	_spots.append(where)
	_yaws.append(yaw)
	_pitches.append(pitch)


func _drop_oldest() -> void:
	_times.remove_at(0)
	_spots.remove_at(0)
	_yaws.remove_at(0)
	_pitches.remove_at(0)


func _clear_states() -> void:
	_times.clear()
	_spots.clear()
	_yaws.clear()
	_pitches.clear()


## Changes one of its settings (CHANGEABLE), for `seconds` (0: until changed
## again). On its player's machine it's simply set. On the server, for a
## client's character, the server's copy is set (its speed limit follows)
## and the change goes to that player's machine, which moves it. Health and
## max health are the server's only (set_health / set_max_health). Anywhere
## else it's refused (the character isn't this machine's).
func change(property: StringName, value: Variant, seconds: float = 0.0) -> bool:
	if property == &"health" or property == &"max_health":
		# (The server's alone, for good: Seconds doesn't apply.)
		return Net.change_health(self, property, value)
	if not CHANGEABLE.has(property):
		push_error("Character: '%s' can't be changed on a 3D character (one of %s)." % [property, ", ".join(CHANGEABLE)])
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


## Whether this machine moves the character: its player's machine (or,
## without the engine, this one: single-player).
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


## A change the server sends to this character's player's machine.
@rpc("authority", "call_remote", "reliable")
func _set_from_server(property: StringName, value: Variant, seconds: float) -> void:
	if CHANGEABLE.has(property):
		_apply(property, value, seconds)


## Sets it here, puts it back after `seconds`, and updates what depends on it.
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
	match property:
		&"eye_height":
			if head != null:
				head.position.y = eye_height
		&"field_of_view":
			if camera != null:
				camera.fov = field_of_view
		&"walk_speed", &"gravity":
			# The server's speed limit follows (unless set by hand).
			if max_speed <= 0.0:
				Net.update_limit(self, _handed_to, _speed_limit())


func _speed_limit() -> float:
	return max_speed if max_speed > 0.0 else walk_speed * 3.0 + gravity


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
func add_preview_shape() -> CollisionShape3D:
	if _has_shape():
		return null
	var shape: CollisionShape3D = _new_shape()
	shape.set_meta(MADE_SHAPE_META, true)
	shape.set_meta(PREVIEW_SHAPE_META, true)
	add_child(shape, true)
	child_entered_tree.connect(func(child: Node) -> void:
		if child != shape and (child is CollisionShape3D or child is CollisionPolygon3D) and is_instance_valid(shape):
			shape.queue_free())
	return shape


## Editor: gives it a shape saved in `scene` when it has none (so Godot's
## "no shape" warning goes, and it can be seen and edited). Returns it (null:
## it had one).
func add_scene_shape(scene: Node) -> CollisionShape3D:
	if _has_shape():
		return null
	var shape: CollisionShape3D = _new_shape()
	shape.set_meta(MADE_SHAPE_META, true)
	add_child(shape, true)
	shape.owner = scene
	var editor: Object = Engine.get_singleton(&"EditorInterface") if Engine.is_editor_hint() else null
	if editor != null:
		editor.call(&"mark_scene_as_unsaved")
	return shape


func _has_shape() -> bool:
	return get_children().any(func(child: Node) -> bool: return child is CollisionShape3D or child is CollisionPolygon3D)


func _new_shape() -> CollisionShape3D:
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "Shape"
	shape.shape = _shape_resource()
	return shape


func _shape_resource() -> Shape3D:
	if kind == Kind.DRONE:
		var ball: SphereShape3D = SphereShape3D.new()
		ball.radius = shape_radius
		return ball
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = shape_radius
	capsule.height = shape_height
	return capsule


## The shape it made in the editor follows the Shape settings.
func _update_made_shape() -> void:
	for child: Node in get_children():
		if child is CollisionShape3D and child.has_meta(MADE_SHAPE_META):
			(child as CollisionShape3D).shape = _shape_resource()


#region Movement

## Moves it by velocity * delta from `placed` (its global transform now) and
## returns where it ends: sideways first (sliding along what's in the
## way, stepping up ledges), then up / down (landing on the floor, hitting a
## ceiling, keeping to the floor going down). Worked out on a position of its
## own and set once at the end (every set of a body's transform costs).
func _move(delta: float, placed: Transform3D) -> Vector3:
	if not _prepare_query():
		global_position = placed.origin + velocity * delta
		return global_position
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	_cast_basis = placed.basis * _shape_offset.basis
	_cast_offset = placed.basis * _shape_offset.origin
	var at: Vector3 = placed.origin
	_clip(space, at, velocity.length() * delta + step_height + floor_snap)
	if at.distance_squared_to(_placed_at) > 0.000001 or _turning_moves_shape and not placed.basis.is_equal_approx(_placed_basis):
		_query.transform = Transform3D(_cast_basis, at + _cast_offset)
		at += _push_out(space)
	var was_on_floor: bool = _on_floor
	var side: Vector3 = Vector3(velocity.x, 0.0, velocity.z) * delta
	if side.length_squared() > 0.0000001:
		var from: Vector3 = at
		at = _slide(space, at, side)
		if was_on_floor and step_height > 0.0 and Vector2(at.x - from.x, at.z - from.z).length() < side.length() * 0.5:
			at = _step_up(space, from, at, side)
	if not was_on_floor and velocity.y <= 0.0:
		# Sunk into thin ground (a terrain's height map or triangles, a
		# trimesh floor: no inside to be pushed out of, so the casts would
		# let it fall through), e.g. spawned at the ground's height: it stands
		# on it. A ray down its middle, from its top to its feet.
		var sunk: float = _ray_down(space, at, at.y - _feet + _tall, at.y - _feet)
		if not is_nan(sunk) and _ray_normal.y >= FLOOR_NORMAL_Y:
			at.y = sunk + _feet + PUSH_GAP
			velocity.y = 0.0
			_on_floor = true
			was_on_floor = true
	var fall: float = velocity.y * delta
	# On the floor going down (or standing): look a little further, to keep to it.
	var probe: float = fall - floor_snap if was_on_floor and velocity.y <= 0.0 else fall
	if not is_zero_approx(probe):
		var free: float = _free(space, at, Vector3(0.0, probe, 0.0))
		at = _from
		if free < 1.0:
			at.y += probe * free
			if probe < 0.0:
				_on_floor = true
				velocity.y = 0.0
			else:
				# A ceiling.
				velocity.y = minf(velocity.y, 0.0)
		else:
			at.y += fall
			_on_floor = false
	global_position = at
	_placed_at = at
	_placed_basis = placed.basis
	return at


## A drone's frame (alive, on the machine that moves it): where it wants to
## go (its player's keys, where the head looks, Space / fly_down up and
## down; Controlled by Script: move_direction), then _fly(). Hovering still
## where its last move left it, it does nothing (no casts).
func _drone_step(delta: float, placed: Transform3D) -> void:
	var wanted: Vector3 = Vector3.ZERO
	if controlled_by == ControlledBy.SCRIPT:
		wanted = move_direction.limit_length(1.0)
		if _walk != 0:
			# Slowing down in time to stop there (it glides): inside Within for
			# Walk to, at the Distance for Follow.
			var left: float = maxf(placed.origin.distance_to(_goal) - _within * (1.0 if _follow_target != null else 0.5), 0.0)
			wanted = wanted.limit_length(sqrt(2.0 * fly_acceleration * left) / maxf(walk_speed, 0.01))
	else:
		var push: Vector2 = Input.get_vector(move_left, move_right, move_forward, move_back)
		var look: Basis = placed.basis * head.basis if head != null else placed.basis
		var rise: float = (1.0 if InputMap.has_action(jump) and Input.is_action_pressed(jump) else 0.0) \
			- (1.0 if InputMap.has_action(fly_down) and Input.is_action_pressed(fly_down) else 0.0)
		wanted = (look * Vector3(push.x, 0.0, push.y) + Vector3(0.0, rise, 0.0)).limit_length(1.0)
	_jump_pressed = false
	wanted *= walk_speed
	if _started and wanted == Vector3.ZERO and velocity == Vector3.ZERO and placed.origin == _placed_at \
			and not (_turning_moves_shape and placed.basis != _placed_basis):
		return
	var at: Vector3 = _fly(delta, placed, wanted)
	if not _started:
		_start = at
		_started = true
	elif at.y < fall_limit:
		_fell()


## Flies by velocity, eased toward `wanted` at fly_acceleration (it glides to
## a stop), from `placed` (its global transform now), sliding along what's in
## the way (up to 3 times a move); returns where it ends. No gravity, never
## on the floor.
func _fly(delta: float, placed: Transform3D, wanted: Vector3) -> Vector3:
	velocity = velocity.move_toward(wanted, fly_acceleration * delta)
	_on_floor = false
	if not _prepare_query():
		global_position = placed.origin + velocity * delta
		return global_position
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	_cast_basis = placed.basis * _shape_offset.basis
	_cast_offset = placed.basis * _shape_offset.origin
	var at: Vector3 = placed.origin
	var motion: Vector3 = velocity * delta
	_clip(space, at, motion.length())
	# Pushed out of what it overlaps before every move, not only when moved
	# by something else: sliding along a trimesh (a cave's walls) leaves the
	# ball just touching it, and Jolt's casts don't see what they start
	# touching, so it sank a little deeper each move until it was through.
	_query.transform = Transform3D(_cast_basis, at + _cast_offset)
	at += _push_out(space)
	for i: int in 3:
		if motion.length_squared() <= 0.0000001:
			break
		var free: float = _free(space, at, motion)
		at = _from + motion * free
		if free >= 1.0:
			break
		var normal: Vector3 = _contact_normal(space, at, motion, free)
		motion = (motion * (1.0 - free)).slide(normal)
		if velocity.dot(normal) < 0.0:
			velocity = velocity.slide(normal)
	global_position = at
	_placed_at = at
	_placed_basis = placed.basis
	return at


## No clip: its casts and rays this move see only the ground (Terrains,
## GROUND_GROUP): what else is within `reach` (and its size, and CLIP_MOVE)
## is left out (up to 32 things). One look does for CLIP_FRAMES physics
## frames while it stays within CLIP_MOVE of where it looked. Off: they see
## everything again.
func _clip(space: PhysicsDirectSpaceState3D, at: Vector3, reach: float) -> void:
	if not no_clip:
		if _clipping:
			_clipping = false
			_clip_at = Vector3.INF
			_query.exclude = [get_rid()]
			_ray.exclude = [get_rid()]
		return
	var frame: int = Engine.get_physics_frames()
	if _clipping and frame - _clip_frame < CLIP_FRAMES and at.distance_squared_to(_clip_at) < CLIP_MOVE * CLIP_MOVE:
		return
	_clip_at = at
	_clip_frame = frame
	_clipping = true
	if _clip_query == null:
		_clip_query = PhysicsShapeQueryParameters3D.new()
		_clip_query.shape = SphereShape3D.new()
		_clip_query.exclude = [get_rid()]
	(_clip_query.shape as SphereShape3D).radius = reach + _reach + _tall + CLIP_MOVE + 0.5
	_clip_query.transform = Transform3D(Basis.IDENTITY, at)
	_clip_query.collision_mask = collision_mask
	var left_out: Array[RID] = [get_rid()]
	for hit: Dictionary in space.intersect_shape(_clip_query, 32):
		var collider: Node = hit.get("collider") as Node
		if collider == null or not (collider.is_in_group(TERRAINS_GROUP) or collider.is_in_group(GROUND_GROUP)):
			left_out.append(hit["rid"])
	_query.exclude = left_out
	_ray.exclude = left_out


## `at` moved by `motion` until something's in the way, then along it (once).
func _slide(space: PhysicsDirectSpaceState3D, at: Vector3, motion: Vector3) -> Vector3:
	var free: float = _free(space, at, motion)
	at = _from + motion * free
	if free >= 1.0:
		return at
	var normal: Vector3 = _contact_normal(space, at, motion, free)
	var rest: Vector3 = motion * (1.0 - free)
	var along: Vector3 = Vector3.ZERO
	if normal.y >= FLOOR_NORMAL_Y:
		# Ground rising ahead (a slope, a terrain's gentle bumps, too low to
		# count as a step): up along it.
		along = rest.slide(normal)
	else:
		# Along it sideways only: without the normal's up / down part, so the
		# slide never points into it (a cast starting touching wouldn't stop
		# it).
		normal = Vector3(normal.x, 0.0, normal.z).normalized()
		along = rest - normal * rest.dot(normal) if normal.is_normalized() else Vector3.ZERO
	var start: Vector3 = at
	var ground_in_way: bool = false
	if along.length_squared() > 0.0000001:
		free = _free(space, at, along)
		at = _from + along * free
		if normal.y < FLOOR_NORMAL_Y and free < 1.0 and at.distance_squared_to(start) < 0.000001:
			# Along a wall and at once stopped by the ground it stands on (a
			# terrain's seam by a wall's corner: an NPC stuck there, BUGS.md
			# 2026-11-02): lifted over it like below.
			ground_in_way = _contact_normal(space, at, along, free).y >= FLOOR_NORMAL_Y
			if ground_in_way:
				rest = along
	if (normal.y >= FLOOR_NORMAL_Y or ground_in_way) and at.distance_squared_to(start) < 0.000001:
		# Still where it was against the ground: a rise of a few millimetres
		# (a terrain's height map or trimesh, its triangles' seams) that the
		# slide along it doesn't lift it over and that's too low for a step.
		# Lifted (up to GROUND_LIFT) and on; the move down after sets it back
		# on the floor.
		var up: float = _free(space, start, Vector3(0.0, GROUND_LIFT, 0.0))
		var raised: Vector3 = _from + Vector3(0.0, GROUND_LIFT * up, 0.0)
		free = _free(space, raised, rest)
		if free > 0.0:
			at = _from + rest * free
	return at


## Blocked while walking on the floor: if what's in the way is a step (its
## top a floor at most step_height above the one it stands on, measured
## with a ray just in front), it goes up onto it; else it stays `blocked`.
func _step_up(space: PhysicsDirectSpaceState3D, from: Vector3, blocked: Vector3, side: Vector3) -> Vector3:
	# (Partly up already, its rounded bottom on the step's edge: the floor is
	# further down than its feet.)
	var feet: float = from.y - _feet
	var floor_y: float = _ray_down(space, from, from.y, feet - step_height - 0.2)
	if is_nan(floor_y):
		return blocked
	var ahead: Vector3 = from + side.normalized() * (_reach + 0.05)
	var top: float = _ray_down(space, ahead, floor_y + step_height + 0.05, floor_y - 0.05)
	if is_nan(top) or top - floor_y <= 0.01 or top - floor_y > step_height or _ray_normal.y < FLOOR_NORMAL_Y or top + PUSH_GAP <= feet:
		return blocked
	var rise: float = top - feet + PUSH_GAP
	if _free(space, from, Vector3(0.0, rise, 0.0)) < 1.0:
		# No room above it.
		return blocked
	var at: Vector3 = _from + Vector3(0.0, rise, 0.0)
	var free: float = _free(space, at, side)
	if free <= 0.0:
		return blocked
	# (The move down that follows sets it on the step.)
	return _from + side * free


## Where a ray from `top` down to `bottom` (at `at`'s x / z) hits, or NAN;
## its surface normal in _ray_normal.
func _ray_down(space: PhysicsDirectSpaceState3D, at: Vector3, top: float, bottom: float) -> float:
	_ray.from = Vector3(at.x, top, at.z)
	_ray.to = Vector3(at.x, bottom, at.z)
	var hit: Dictionary = space.intersect_ray(_ray)
	if hit.is_empty():
		return NAN
	_ray_normal = hit["normal"]
	return (hit["position"] as Vector3).y


## How much of `motion` its shape can go from `at` before touching something
## (1: all). Starting inside something, it's pushed out first: `_from` is
## where the cast started (`at`, or pushed out).
func _free(space: PhysicsDirectSpaceState3D, at: Vector3, motion: Vector3) -> float:
	var free: PackedFloat32Array = _cast(space, at, motion)
	_from = at
	if free.size() >= 2 and free[1] <= 0.0:
		_query.transform = Transform3D(_cast_basis, at + _cast_offset)
		_from = at + _push_out(space)
		free = _cast(space, _from, motion)
	_touch = free[1] if free.size() >= 2 else 1.0
	var safe: float = free[0] if not free.is_empty() else 1.0
	if safe >= 1.0:
		return 1.0
	if _ghost_hit(space, motion):
		_touch = 1.0
		return 1.0
	# Stops PUSH_GAP short of what it hit: a cast starting touching something
	# wouldn't see it (Jolt), so the next one would go into it.
	return maxf(safe - PUSH_GAP / maxf(motion.length(), 0.0001), 0.0)


## Whether the hit a cast just reported (at _touch of `motion` from _from)
## isn't there: its shape touches nothing where it hit, nor overlaps
## anything a little past it. Jolt's shape casts catch the edges between the
## triangles of a height map or a trimesh (a terrain's ground) while sliding
## just above it, though nothing is in the way; a real wall or floor is
## touched there (also one met slantwise, a few millimetres deep past it).
func _ghost_hit(space: PhysicsDirectSpaceState3D, motion: Vector3) -> bool:
	var length: float = motion.length()
	if length < 0.000001:
		return false
	_query.motion = Vector3.ZERO
	_query.transform = Transform3D(_cast_basis, _from + motion * _touch + _cast_offset)
	if not space.get_rest_info(_query).is_empty():
		return false
	_query.transform = Transform3D(_cast_basis, _from + motion * _touch + motion * (GHOST_CHECK / length) + _cast_offset)
	return space.collide_shape(_query, 1).is_empty()


## Its shape's cast from `at` by `motion`: [safe, touching] fractions of
## `motion`, as cast_motion gives them. It starts CAST_BACK behind `at`: a
## cast starting exactly touching something doesn't see it (Jolt: one
## moving flush along a wall, or tangent to it, would walk into it), so that
## something is in front of it; ahead within CAST_BACK, it's 0 (touching).
func _cast(space: PhysicsDirectSpaceState3D, at: Vector3, motion: Vector3) -> PackedFloat32Array:
	var length: float = motion.length()
	if length < 0.000001:
		return PackedFloat32Array([1.0, 1.0])
	var back: Vector3 = motion * (CAST_BACK / length)
	_query.transform = Transform3D(_cast_basis, at - back + _cast_offset)
	_query.motion = motion + back
	var free: PackedFloat32Array = space.cast_motion(_query)
	if free.size() < 2 or free[1] >= 1.0:
		return free
	var whole: float = length + CAST_BACK
	return PackedFloat32Array([maxf((free[0] * whole - CAST_BACK) / length, 0.0), maxf((free[1] * whole - CAST_BACK) / length, 0.0)])


## How far out of whatever its shape (at _query's transform) overlaps or
## touches: the deepest contact's depth and a little gap (a cast starting
## touching something wouldn't see it); just touching: a little gap away
## from what it touches (off a wall too, not only up off a floor).
func _push_out(space: PhysicsDirectSpaceState3D) -> Vector3:
	_query.motion = Vector3.ZERO
	var points: Array[Vector3] = space.collide_shape(_query, 8)
	if points.is_empty():
		return Vector3.ZERO
	var push: Vector3 = Vector3.ZERO
	for i: int in range(0, points.size() - 1, 2):
		var depth: Vector3 = points[i + 1] - points[i]
		if depth.length_squared() > push.length_squared():
			push = depth
	if push.length_squared() > 0.000001:
		return push + push.normalized() * PUSH_GAP
	var normal: Vector3 = space.get_rest_info(_query).get("normal", Vector3.ZERO)
	return (normal if normal.is_normalized() else Vector3.UP) * PUSH_GAP


## The surface's normal where `motion` runs into it, `at` being as far as it
## got (`free` of it): looked at just past the touching point, where the
## shapes meet. A capsule or a ball (the shapes it makes) takes it from where
## they touch to its axis there, which is exact also against a corner: the
## normal just past it is the corner seen from a little further on, at right
## angles to a move skimming it, so a slide along that kept running into it
## (an NPC stuck on a wall's corner, BUGS.md 2026-10-31).
func _contact_normal(space: PhysicsDirectSpaceState3D, at: Vector3, motion: Vector3, free: float) -> Vector3:
	var into: Vector3 = motion.normalized()
	var touching: Vector3 = at + motion * maxf(_touch - free, 0.0) + _cast_offset + into * CONTACT_DEPTH
	_query.transform = Transform3D(_cast_basis, touching)
	_query.motion = Vector3.ZERO
	var info: Dictionary = space.get_rest_info(_query)
	var normal: Vector3 = info.get("normal", Vector3.ZERO)
	if info.has("point") and (_query.shape is CapsuleShape3D or _query.shape is SphereShape3D):
		var point: Vector3 = info["point"]
		var axis: Vector3 = touching
		var capsule: CapsuleShape3D = _query.shape as CapsuleShape3D
		if capsule != null:
			var half: Vector3 = _cast_basis.y.normalized() * maxf(capsule.height * 0.5 - capsule.radius, 0.0)
			axis = Geometry3D.get_closest_point_to_segment(point, touching - half, touching + half)
		if axis.distance_squared_to(point) > 0.000001:
			return (axis - point).normalized()
	return normal if normal.is_normalized() else -into


## The cast of its own shape: its first CollisionShape3D, its mask, not itself.
func _prepare_query() -> bool:
	if _query != null and is_instance_valid(_shape_node) and _shape_node.shape == _query.shape:
		return true
	_shape_node = null
	for child: Node in get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null and not (child as CollisionShape3D).disabled:
			_shape_node = child
			break
	if _shape_node == null:
		return false
	_shape_offset = _shape_node.transform
	_query = PhysicsShapeQueryParameters3D.new()
	_query.shape = _shape_node.shape
	_query.collision_mask = collision_mask
	_query.exclude = [get_rid()]
	_ray = PhysicsRayQueryParameters3D.new()
	_ray.collision_mask = collision_mask
	_ray.exclude = [get_rid()]
	var shape: Shape3D = _shape_node.shape
	var half_height: float = 0.5
	var upright: bool = _shape_offset.basis.y.is_equal_approx(Vector3.UP) and is_zero_approx(_shape_offset.origin.x) and is_zero_approx(_shape_offset.origin.z)
	_turning_moves_shape = not (upright and (shape is CapsuleShape3D or shape is CylinderShape3D or shape is SphereShape3D))
	if shape is CapsuleShape3D:
		_reach = (shape as CapsuleShape3D).radius
		half_height = (shape as CapsuleShape3D).height * 0.5
	elif shape is CylinderShape3D:
		_reach = (shape as CylinderShape3D).radius
		half_height = (shape as CylinderShape3D).height * 0.5
	elif shape is SphereShape3D:
		_reach = (shape as SphereShape3D).radius
		half_height = _reach
	elif shape is BoxShape3D:
		_reach = maxf((shape as BoxShape3D).size.x, (shape as BoxShape3D).size.z) * 0.5
		half_height = (shape as BoxShape3D).size.y * 0.5
	_feet = half_height - _shape_offset.origin.y
	_tall = half_height * 2.0
	return true

#endregion


## Its camera on its head (made by each machine for itself, like the head).
func _make_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = field_of_view
	camera.cull_mask &= ~OWN_VIEW_HIDDEN_LAYER
	head.add_child(camera)


## A child every machine makes for itself: never sent, never removed.
## Puts hidden_from_own_camera's meshes on the layer its camera leaves out
## (`hidden`), or back on their own.
func _hide_from_own_camera(hidden: bool) -> void:
	_own_view_hidden = hidden
	var waiting: Array[Node] = []
	for path: NodePath in hidden_from_own_camera:
		var node: Node = get_node_or_null(path)
		if node != null:
			waiting.append(node)
	while not waiting.is_empty():
		var node: Node = waiting.pop_back()
		waiting.append_array(node.get_children())
		var mesh: VisualInstance3D = node as VisualInstance3D
		if mesh == null:
			continue
		if hidden and mesh.layers != OWN_VIEW_HIDDEN_LAYER:
			mesh.set_meta(&"_brickscript_layers", mesh.layers)
			mesh.layers = OWN_VIEW_HIDDEN_LAYER
		elif not hidden and mesh.has_meta(&"_brickscript_layers"):
			mesh.layers = int(mesh.get_meta(&"_brickscript_layers"))
			mesh.remove_meta(&"_brickscript_layers")


func _add_local(child: Node) -> void:
	child.add_to_group(&"local_only")
	add_child(child)
