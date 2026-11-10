@tool
@icon("res://addons/brickscript/icons/nodes/player_service.svg")
class_name BrickscriptPlayerService
extends Node

## Where a game's players live (like Roblox's Players service with its
## characters), one per scene:
## - SpawnPoints (BrickscriptSpawnPoints): the points characters appear at
##   (order, facing, skipping occupied ones, tags);
## - StarterPlayer / StarterCharacter (BrickscriptStarter): what every player
##   node / character starts with (values, per-player brickscripts);
## - Players (BrickscriptPlayers): one node per player, with their values;
## - Characters (BrickscriptCharacterSpawner): every player's character (named
##   after the player);
## - Menus (BrickscriptMenus): adds each machine's Host / Join menu
##   ("<player>Menu", its own only), with the menu's settings.
## Added in the editor with no children, it makes them (the character: the
## addon's humanoid, assets/player_character.tscn) and the input actions that
## character moves with. The Scene dock warns when something is missing.
## While the game runs it does nothing itself: its children do the work.

## Group it's in (one per scene: a second gets a warning).
const GROUP: StringName = &"brickscript_player_service"
const DEFAULT_CHARACTER: String = "res://addons/brickscript/assets/player_character.tscn"
## The input actions the default character moves with (and fly_down: a
## drone sinks), and their keys
## (physical: the same place on any keyboard layout).
const INPUT_ACTIONS: Dictionary[String, Array] = {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],
	"fly_down": [KEY_CTRL, KEY_C],
}

## Whether it made its children once (deleting them afterwards is kept).
@export_storage var _filled: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	if Engine.is_editor_hint():
		# (Deferred: the Add Node dialog sets the owner after adding it.)
		_fill_in_edited_scene.call_deferred()
		return
	var others: int = get_tree().get_nodes_in_group(GROUP).size()
	if others > 1:
		push_warning("PlayerService: this scene has %d; use one (players and characters would be counted twice)." % others)


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		get_tree().node_added.connect(_on_tree_changed)
		get_tree().node_removed.connect(_on_tree_changed)
		get_tree().node_renamed.connect(_on_tree_changed)


func _exit_tree() -> void:
	for changed: Signal in [get_tree().node_added, get_tree().node_removed, get_tree().node_renamed]:
		if changed.is_connected(_on_tree_changed):
			changed.disconnect(_on_tree_changed)


## Makes SpawnPoints (with Spawn1), StarterPlayer, StarterCharacter,
## Players, Characters (the default character) and Menus, saved in `scene`,
## and the input actions the character needs.
func fill(scene: Node) -> void:
	_filled = true
	var points: Node = _scripted("SpawnPoints", BrickscriptSpawnPoints)
	_add(self, points, scene)
	var spawn: Marker3D = Marker3D.new()
	spawn.name = "Spawn1"
	spawn.set_script(BrickscriptSpawnPoint)
	spawn.position = Vector3(0.0, 1.0, 0.0)
	_add(points, spawn, scene)
	_add(self, _scripted("StarterPlayer", BrickscriptStarter), scene)
	_add(self, _scripted("StarterCharacter", BrickscriptStarter), scene)
	_add(self, _scripted("Players", BrickscriptPlayers), scene)
	var spawner: Node = _scripted("Characters", BrickscriptCharacterSpawner)
	spawner.set(&"character_scene", load(DEFAULT_CHARACTER) as PackedScene)
	spawner.set(&"spawn_points", ^"../SpawnPoints")
	spawner.set(&"starter_character", ^"../StarterCharacter")
	_add(self, spawner, scene)
	_add(self, _scripted("Menus", BrickscriptMenus), scene)
	add_input_actions()


## Adds the INPUT_ACTIONS the project doesn't have (editor: saved in
## project.godot) and returns their names.
static func add_input_actions() -> PackedStringArray:
	var added: PackedStringArray = []
	for action: String in INPUT_ACTIONS:
		if ProjectSettings.has_setting("input/" + action):
			continue
		# (Plain: how the editor saves them.)
		var events: Array = []
		for key: Key in INPUT_ACTIONS[action]:
			var event: InputEventKey = InputEventKey.new()
			event.physical_keycode = key
			events.append(event)
		ProjectSettings.set_setting("input/" + action, {"deadzone": 0.2, "events": events})
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
			for event: InputEvent in events:
				InputMap.action_add_event(action, event)
		added.append(action)
	if not added.is_empty() and Engine.is_editor_hint():
		ProjectSettings.save()
		print("Brickscript: added the input actions %s (Project Settings > Input Map)." % ", ".join(added))
	return added


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	var scene: Node = _scene_root()
	var services: int = get_tree().get_nodes_in_group(GROUP).filter(func(service: Node) -> bool:
		return scene == null or service == scene or scene.is_ancestor_of(service)).size() if is_inside_tree() else 1
	if services > 1:
		warnings.append("This scene has %d PlayerServices: use one (players and characters would be counted twice)." % services)
	var players: Node = _child(func(child: Node) -> bool: return child is BrickscriptPlayers)
	if players == null:
		warnings.append("No Players node (BrickscriptPlayers) under it: one is made while the game runs, with no player values (Object Number...) to start with.")
	else:
		if players.get_children().any(func(child: Node) -> bool: return not child is BrickscriptPlayer):
			warnings.append("%s has children of its own: they aren't copied into players any more. Move them into StarterPlayer." % players.name)
		var starter: NodePath = players.get(&"starter")
		if not starter.is_empty() and not players.get_node_or_null(starter) is BrickscriptStarter:
			warnings.append("%s's starter (%s) isn't a StarterPlayer (BrickscriptStarter): players start with nothing." % [players.name, starter])
	# (Read with get(): in the editor it's a placeholder, see _scripted.)
	var spawner: Node = _child(func(child: Node) -> bool: return child is BrickscriptCharacterSpawner)
	if spawner == null:
		warnings.append("No Character Spawner under it: nobody gets a character.")
	else:
		var character_scene: PackedScene = spawner.get(&"character_scene") as PackedScene
		var spawn_points: NodePath = spawner.get(&"spawn_points")
		if character_scene == null:
			warnings.append("%s has no character scene: pick one (%s is a ready humanoid)." % [spawner.name, DEFAULT_CHARACTER])
		var holder: Node = spawner.get_node_or_null(spawn_points) if not spawn_points.is_empty() else spawner
		if holder == null:
			warnings.append("%s's spawn points (%s) aren't there." % [spawner.name, spawn_points])
		elif not holder.get_children().any(func(point: Node) -> bool: return point is Node3D or point is Node2D):
			warnings.append("No spawn points: add a Marker3D under %s (characters appear where their scene puts them)." % holder.name)
		if character_scene != null and character_scene.resource_path == DEFAULT_CHARACTER:
			var missing: PackedStringArray = []
			for action: String in INPUT_ACTIONS:
				if not ProjectSettings.has_setting("input/" + action):
					missing.append(action)
			if not missing.is_empty():
				warnings.append("The character moves with input actions the project doesn't have: %s (Project Settings > Input Map)." % ", ".join(missing))
	if ProjectSettings.has_setting("autoload/NetworkEngine") and _child(func(child: Node) -> bool: return child is BrickscriptMenus) == null:
		warnings.append("No Menus node (BrickscriptMenus) under it: no Host / Join menu (fine when the scene has its own lobby).")
	if not ProjectSettings.has_setting("autoload/NetworkEngine"):
		warnings.append("The Network Context Engine isn't installed: single-player only (no Host / Join menu).")
	return warnings


func _fill_in_edited_scene() -> void:
	if not is_inside_tree() or _filled or get_child_count() > 0:
		return
	var scene: Node = _scene_root()
	if scene == null or not (scene == self or owner == scene):
		return
	fill(scene)
	# (Not EditorInterface by name: exported games don't have it.)
	Engine.get_singleton(&"EditorInterface").call(&"mark_scene_as_unsaved")


## A Node with `script`, as a scene file makes it: in the editor a script
## that isn't @tool doesn't run (Script.new() would run it: a spawner would
## spawn in the editor).
func _scripted(node_name: String, script: Script) -> Node:
	var node: Node = Node.new()
	node.name = node_name
	node.set_script(script)
	return node


func _add(parent: Node, child: Node, scene: Node) -> void:
	parent.add_child(child, true)
	child.owner = scene


func _child(matches: Callable) -> Node:
	for child: Node in get_children():
		if matches.call(child):
			return child
	return null


func _scene_root() -> Node:
	return get_tree().edited_scene_root if is_inside_tree() and Engine.is_editor_hint() else null


## A node in this scene changed: the warnings may have.
func _on_tree_changed(node: Node) -> void:
	if node == self or is_ancestor_of(node) or node is BrickscriptPlayerService:
		update_configuration_warnings.call_deferred()
