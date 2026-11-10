@tool
extends RefCounted

## A ready multiplayer 3D scene: a World root with a floor, a PlayerService
## (spawn point, Players, Characters with the humanoid), and the 3D editor's
## preview sun and sky made real (a DirectionalLight3D and a
## WorldEnvironment, as its "Add Sun / Environment to Scene" buttons do).
## Made by the Scene dock's Create Root Node button "Multiplayer 3D Scene"
## and by Project > Tools > New Multiplayer Scene...

const BUTTON_TEXT: String = "Multiplayer 3D Scene"
const TOOL_MENU_TEXT: String = "New Multiplayer Scene..."
## The Create Root Node buttons ours goes after (the first found), and the 3D
## editor's preview buttons. Godot has no API for either: they're found by
## their (translated) text, and without them it does without / makes its own.
const AFTER_BUTTONS: Array[String] = ["3D Scene", "Other Node"]
const SUN_BUTTON: String = "Add Sun to Scene"
const ENVIRONMENT_BUTTON: String = "Add Environment to Scene"
const PlayerService: GDScript = preload("res://addons/brickscript/runtime/player_service.gd")


## The scene's nodes (owned by its root), without the sun and sky.
static func build() -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "World"
	var floor_body: StaticBody3D = StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	_add(root, floor_body, root)
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "Shape"
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	shape.shape = box
	_add(floor_body, shape, root)
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.name = "Mesh"
	var floor_mesh: BoxMesh = BoxMesh.new()
	floor_mesh.size = box.size
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.45, 0.42)
	floor_mesh.material = material
	mesh.mesh = floor_mesh
	_add(floor_body, mesh, root)
	var service: Node = PlayerService.new()
	service.name = "PlayerService"
	_add(root, service, root)
	service.call(&"fill", root)
	return root


## Gives the scene being edited the 3D editor's preview sun and sky (pressing
## its buttons: the same light and sky you saw, with undo), or a sun and sky
## like Godot's default preview when they can't be found. Each only when the
## scene has none.
static func add_sun_and_environment(root: Node) -> void:
	if _first(root, func(node: Node) -> bool: return node is DirectionalLight3D) == null:
		var sun: Button = _editor_button(SUN_BUTTON, &"Node3DEditor")
		if sun != null:
			sun.pressed.emit()
		if _first(root, func(node: Node) -> bool: return node is DirectionalLight3D) == null:
			_add(root, _default_sun(), root)
	if _first(root, func(node: Node) -> bool: return node is WorldEnvironment) == null:
		var environment: Button = _editor_button(ENVIRONMENT_BUTTON, &"Node3DEditor")
		if environment != null:
			environment.pressed.emit()
		if _first(root, func(node: Node) -> bool: return node is WorldEnvironment) == null:
			_add(root, _default_environment(), root)


## Adds "Multiplayer 3D Scene" to the Scene dock's Create Root Node buttons
## (a copy of the 3D Scene one, so it looks the same). Null when they can't
## be found (another Godot version): the Tools menu item still works.
static func add_root_button(pressed: Callable) -> Button:
	var after: Button = null
	for text: String in AFTER_BUTTONS:
		after = _editor_button(text, &"SceneTreeDock")
		if after != null:
			break
	if after == null:
		return null
	# (No signals: pressing it must not also make a 3D Scene.)
	var button: Button = after.duplicate(0) as Button
	button.name = "BrickscriptMultiplayerScene"
	button.text = BUTTON_TEXT
	button.icon = load("res://addons/brickscript/icons/nodes/player_service.svg")
	button.tooltip_text = "A 3D scene ready for players: a floor, the editor's sun and sky, and a PlayerService (spawn point, Players, Characters with a humanoid and the Host / Join menu)."
	button.pressed.connect(pressed)
	after.add_sibling(button)
	return button


## Makes the scene the root of the empty scene being edited.
static func make_root() -> Node:
	if EditorInterface.get_edited_scene_root() != null:
		return null
	var root: Node3D = build()
	EditorInterface.add_root_node(root)
	add_sun_and_environment(root)
	EditorInterface.set_main_screen_editor("3D")
	EditorInterface.edit_node(root)
	return root


## Saves a new scene at `path`, opens it and gives it the sun and sky.
static func make_file(path: String) -> Error:
	var root: Node3D = build()
	var packed: PackedScene = PackedScene.new()
	var result: Error = packed.pack(root)
	root.free()
	if result == OK:
		result = ResourceSaver.save(packed, path)
	if result != OK:
		return result
	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.open_scene_from_path(path)
	var opened: Node = EditorInterface.get_edited_scene_root()
	if opened != null and opened.scene_file_path == path:
		add_sun_and_environment(opened)
		EditorInterface.set_main_screen_editor("3D")
		EditorInterface.save_scene()
	return OK


static func _default_sun() -> DirectionalLight3D:
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.name = "DirectionalLight3D"
	sun.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(-60.0), deg_to_rad(150.0), 0.0)), Vector3.ZERO)
	sun.shadow_enabled = true
	return sun


static func _default_environment() -> WorldEnvironment:
	var sky_material: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_material.sky_horizon_color = Color(0.662, 0.671, 0.686)
	sky_material.ground_horizon_color = Color(0.662, 0.671, 0.686)
	var sky: Sky = Sky.new()
	sky.sky_material = sky_material
	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.glow_enabled = true
	var world: WorldEnvironment = WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = environment
	return world


## A button of the editor's by its untranslated text, inside its part
## `inside` (an editor class: SceneTreeDock, Node3DEditor).
static func _editor_button(text: String, inside: StringName) -> Button:
	var part: Node = _first(EditorInterface.get_base_control(), func(node: Node) -> bool: return node.get_class() == inside)
	if part == null:
		return null
	var shown: String = String(TranslationServer.get_or_add_domain(&"godot.editor").translate(text))
	return _first(part, func(node: Node) -> bool:
		return node is Button and ((node as Button).text == text or (node as Button).text == shown)) as Button


## The first node under `from` (itself included, internal children too) that
## `matches`.
static func _first(from: Node, matches: Callable) -> Node:
	var waiting: Array[Node] = [from]
	while not waiting.is_empty():
		var node: Node = waiting.pop_back()
		if matches.call(node):
			return node
		waiting.append_array(node.get_children(true))
	return null


static func _add(parent: Node, child: Node, root: Node) -> void:
	parent.add_child(child, true)
	child.owner = root
