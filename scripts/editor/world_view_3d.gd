class_name WorldView3D
extends SubViewportContainer
## The 3D screen (Godot's 3D viewport): the scene's objects (copies of other scenes opened out) drawn with Godot's
## own 3D as the program will draw them (Shape3Ds' shapes, sizes, colors, placed under
## their parent Spatial3Ds; Camera3Ds and Light3Ds as screen-sized icons at their place), the
## Environment's fog, sky and post effects (PostFx), a grid, and
## an editor camera: right-drag orbits, middle-drag (or Shift + right-drag) pans,
## the wheel zooms, F frames the selected object. Left-click selects (the Scene tree
## and Properties follow); the selected object's X / Y / Z arrows drag its position
## (Ctrl: steps of 0.5), saved to the file when the drag ends.

const Context = preload("res://scripts/editor/context.gd")
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
## The background without an Environment: the runtime's neutral grey (cb_gfx.c cb_look()).
const NO_ENVIRONMENT := "#30343c"
const AXIS_COLORS := [Color(0.95, 0.3, 0.3), Color(0.4, 0.9, 0.35), Color(0.35, 0.55, 1.0)]
const ARROW := 1.5
## A Camera3D's and a Light3D's place is an icon (screen-sized, always facing the view, drawn on top), not a model.
const ICON_PX := 30.0   # how big an icon is on the screen
const ICON_HIT := 16.0  # how near (px) a click has to be to pick it
const ICON_SVGS := {
	"camera": '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><rect x="1.5" y="5" width="9" height="7" rx="1.2" fill="#8ec5ff"/><path d="M10.5 7.4 14.5 5v7l-4-2.4z" fill="#8ec5ff" fill-opacity=".75"/><circle cx="4" cy="3.4" r="1.6" fill="#8ec5ff"/><circle cx="8" cy="3.4" r="1.6" fill="#8ec5ff"/></svg>',
	"light": '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="3.2" fill="#ffd54f"/><g stroke="#ffd54f" stroke-width="1.6" stroke-linecap="round"><path d="M8 1v2M8 13v2M1 8h2M13 8h2M3 3l1.4 1.4M11.6 11.6 13 13M3 13l1.4-1.4M11.6 4.4 13 3"/></g></svg>',
}
static var _icon_textures := {}

var context: Context = null
var _vp: SubViewport = null
var _root: Node3D = null
var _objects: Node3D = null
var _overlay: Node3D = null
var _cam: Camera3D = null
var _env: Environment = null
var _sun: DirectionalLight3D = null
var _post: ColorRect = null      # the Environment's post effects (PostFx)
var _post_btn: CheckBox = null   # "Effects": the preview of them on / off (they tint the grid and gizmos too)
var _look: Dictionary = {}       # the lighting() of the last rebuild
var show_post := true
var _icons := {}                 # object id -> its icon (Sprite3D)
var _yaw := 0.6
var _pitch := -0.55
var _dist := 18.0
var _pivot := Vector3.ZERO
var _picks: Array = []            # [object id, MeshInstance3D-like transform of a unit box]
var _drag_axis := -1
var _drag_start_pos := Vector3.ZERO   # the object's world position when the drag began
var _drag_start_t := 0.0
var _orbiting := false
var _looking := false  # right mouse held: freelook (turn in place) and fly with WASD / QE
var _look_from := Vector2.ZERO  # where the pointer was when the right button went down (it goes back there)
var _panning := false


func _init() -> void:
	stretch = true
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	focus_mode = FOCUS_CLICK
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.handle_input_locally = false
	_vp.msaa_3d = Viewport.MSAA_2X
	add_child(_vp)
	_root = Node3D.new()
	_vp.add_child(_root)
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.6, 0.6, 0.65)
	_env.ambient_light_energy = 0.6
	we.environment = _env
	_root.add_child(we)
	_sun = DirectionalLight3D.new()
	_root.add_child(_sun)
	_cam = Camera3D.new()
	_cam.fov = 55
	_cam.far = 500
	_root.add_child(_cam)
	_root.add_child(_grid())
	_objects = Node3D.new()
	_root.add_child(_objects)
	_overlay = Node3D.new()
	_root.add_child(_overlay)
	_post = PostFx.make()
	add_child(_post)
	_post_btn = CheckBox.new()
	_post_btn.text = "Effects"
	_post_btn.tooltip_text = "Preview the Environment's post effects (vignette, bloom...) over this view. They also tint the grid and the gizmos: turn them off to work."
	_post_btn.button_pressed = true
	_post_btn.visible = false
	_post_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 8)
	_post_btn.toggled.connect(func(on: bool) -> void:
		show_post = on
		_apply_post())
	add_child(_post_btn)
	_place_camera()
	resized.connect(_scale_icons)


func _ready() -> void:
	context.selection_changed.connect(func(_id: int) -> void: _draw_selection())


func _grid() -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-20, 21):
		var c := Color(0.5, 0.5, 0.55, 0.35) if i != 0 else Color(0.7, 0.7, 0.75, 0.6)
		im.surface_set_color(Color(0.95, 0.35, 0.35, 0.7) if i == 0 else c)
		im.surface_add_vertex(Vector3(-20, 0, i))
		im.surface_add_vertex(Vector3(20, 0, i))
		im.surface_set_color(Color(0.4, 0.6, 1.0, 0.7) if i == 0 else c)
		im.surface_add_vertex(Vector3(i, 0, -20))
		im.surface_add_vertex(Vector3(i, 0, 20))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _unshaded()
	return mi


static func _unshaded(on_top := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = on_top
	return m


## WASD flying (Godot's freelook keys): with the right mouse held, or while this view has
## focus. W / S along where the camera looks, A / D sideways, Q / E down / up; Shift: 3x.
## Speed grows with the zoom (far out: faster).
func _process(delta: float) -> void:
	if _post.visible:
		PostFx.update_rect(_post)  # (the view may have moved with its panels)
	if _looking and (not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or not is_visible_in_tree()):
		_looking = false  # (the release went elsewhere: let the pointer go anyway)
		_end_look()
	if not is_visible_in_tree() or not (_looking or has_focus()) or _drag_axis >= 0:
		return
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META):
		return  # (Ctrl+S and friends aren't moves)
	var move := Vector3.ZERO
	var b := _cam.global_transform.basis
	if Input.is_key_pressed(KEY_W): move -= b.z
	if Input.is_key_pressed(KEY_S): move += b.z
	if Input.is_key_pressed(KEY_A): move -= b.x
	if Input.is_key_pressed(KEY_D): move += b.x
	if Input.is_key_pressed(KEY_E): move += Vector3.UP
	if Input.is_key_pressed(KEY_Q): move -= Vector3.UP
	if move == Vector3.ZERO:
		return
	var speed := maxf(4.0, _dist * 0.8) * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	fly(move.normalized() * speed * delta)


## Right mouse down (user, 2026-11-08): the pointer is held (hidden, it can't leave the view)
## while it turns the camera; let go: it's back where it was.
func _begin_look() -> void:
	_look_from = get_viewport().get_mouse_position()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _end_look() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.warp_mouse(_look_from)


## Moves the camera (and the point it orbits) by `by`, in the world.
func fly(by: Vector3) -> void:
	_pivot += by
	_place_camera()


func _place_camera() -> void:
	var dir := Vector3(cos(_pitch) * sin(_yaw), -sin(_pitch), cos(_pitch) * cos(_yaw))
	var at := _pivot + dir * _dist
	_cam.transform = Transform3D(Basis.looking_at(_pivot - at, Vector3.UP), at)  # (works before it's in the tree)
	_scale_icons()


## Draws the world file again (after it changed, or a project opened).
func rebuild() -> void:
	for c in _objects.get_children():
		c.queue_free()
	_picks.clear()
	var world: Dictionary = context.world_flat  # (copies of other scenes opened out)
	build_parts(_objects, world, {}, _picks)
	_icons.clear()
	var l := lighting(world)
	var ids := WorldValues.by_id(world)
	for o in world.get("objects", []):
		var cls := str(o.get("class", ""))
		if CBTypes.is_subclass(cls, "Camera3D"):
			var at := WorldValues.world_transform(o, ids).origin
			var target := WorldValues.vec(WorldValues.field(o, "target"))
			_add_icon(int(o.id), at, "camera")
			_add_line(at, target, Color(0.55, 0.78, 1.0, 0.8))
		elif CBTypes.is_subclass(cls, "Light3D"):
			var at := WorldValues.world_transform(o, ids).origin
			if at.length() < 0.001:
				at = Vector3(0, 6, 0)  # (a light at the middle: its icon up out of the way)
			_add_icon(int(o.id), at, "light")
			_add_line(at, at + (l.direction as Vector3).normalized() * 2.5, Color(1.0, 0.85, 0.2))
	_scale_icons()
	_look = l
	_apply_post()  # (the Environment's vignette, scanlines, grain, posterize, bloom, curve, outline, dither)
	apply_lighting(_env, _sun, l)  # (the scene's Environment, as the game draws it; none: neutral grey)
	_draw_selection()


func _apply_post() -> void:
	PostFx.apply(_post, _look)
	_post_btn.visible = _post.visible  # (the toggle shows only while an effect is on)
	if not show_post:
		_post.visible = false


## The world's sky, ambient light and fog (its first Environment's; none: the runtime's
## grey, no fog) and the sun (its first Light3D: it shines along its -Z in its color and
## energy), as cb_gfx.c's cb_look().
static func lighting(world: Dictionary) -> Dictionary:
	var out := {"sky": NO_ENVIRONMENT, "direction": Vector3(-0.4, -1, -0.6), "ambient": 0.38, "light_color": "WHITE", "energy": 1.0, "fog": 0.0, "fog_color": "", "horizon": "", "ambient_color": "WHITE", "fog_start": 0.0, "vignette": 0.0, "scanlines": 0.0, "grain": 0.0, "posterize": 0.0, "bloom": 0.0, "curve": 0.0, "outline": 0.0, "dither": 0.0, "snap": 0.0}
	var have_env := false
	var have_light := false
	var ids := WorldValues.by_id(world)
	for o in world.get("objects", []):
		var cls := str(o.get("class", ""))
		if CBTypes.is_subclass(cls, "Environment") and not have_env:
			out.sky = WorldValues.field(o, "sky")
			out.ambient = WorldValues.number(WorldValues.field(o, "ambient"), 0.38)
			out.fog = WorldValues.number(WorldValues.field(o, "fog"), 0.0)
			out.fog_color = WorldValues.field(o, "fog_color")
			out.horizon = WorldValues.field(o, "horizon")
			out.ambient_color = WorldValues.field(o, "ambient_color")
			out.fog_start = WorldValues.number(WorldValues.field(o, "fog_start"), 0.0)
			for k in ["vignette", "scanlines", "grain", "posterize", "bloom", "curve", "outline", "dither", "snap"]:
				out[k] = WorldValues.number(WorldValues.field(o, k), 0.0)
			have_env = true
		elif CBTypes.is_subclass(cls, "Light3D") and not have_light:
			out.direction = -WorldValues.world_transform(o, ids).basis.z
			out.light_color = WorldValues.field(o, "color")
			out.energy = WorldValues.number(WorldValues.field(o, "energy"), 1.0)
			have_light = true
	return out


static func apply_lighting(env: Environment, sun: DirectionalLight3D, l: Dictionary) -> void:
	env.background_color = WorldValues.color(str(l.sky))
	# A horizon: the game's gradient sky (sky at the top, horizon below), as a procedural sky.
	if str(l.get("horizon", "")) != "":
		var mat := ProceduralSkyMaterial.new()
		mat.sky_top_color = WorldValues.color(str(l.sky))
		mat.sky_horizon_color = WorldValues.color(str(l.horizon))
		mat.ground_horizon_color = WorldValues.color(str(l.horizon))
		mat.ground_bottom_color = WorldValues.color(str(l.horizon))
		mat.sun_angle_max = 0.0
		var sky := Sky.new()
		sky.sky_material = mat
		env.sky = sky
		env.background_mode = Environment.BG_SKY
	elif env.background_mode == Environment.BG_SKY:
		env.background_mode = Environment.BG_COLOR
	env.ambient_light_color = WorldValues.color(str(l.get("ambient_color", "WHITE")) if str(l.get("ambient_color", "")) != "" else "WHITE")
	env.ambient_light_energy = clampf(float(l.ambient) * 1.6, 0.0, 2.0)
	sun.light_color = WorldValues.color(str(l.get("light_color", "WHITE")))
	sun.light_energy = maxf(float(l.get("energy", 1.0)), 0.0)
	# Fog as the runtime's: exponential with the depth, the sky itself not fogged.
	var fog := float(l.get("fog", 0.0))
	env.fog_enabled = fog > 0.0
	var start := float(l.get("fog_start", 0.0))
	if start > 0.0 and fog > 0.0:  # (Godot's depth fog: from fog_start, mostly hidden ~3 / fog further)
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_depth_begin = start
		env.fog_depth_end = start + 3.0 / fog
	else:
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = fog
	env.fog_sky_affect = 0.0
	env.fog_light_color = WorldValues.color(str(l.fog_color) if str(l.get("fog_color", "")) != "" else str(l.sky))
	var d: Vector3 = l.direction
	if d.length() > 0.001:
		d = d.normalized()
		sun.transform = Transform3D(Basis.looking_at(d, Vector3.UP if absf(d.y) < 0.99 else Vector3.FORWARD), Vector3.ZERO)


## Adds the world's Parts (only: {id: true} limits it to those objects; {} = all) to
## `holder`, as the program draws them; `picks` gets [id, unit-box transform] each.
## Returns the box around them (AABB() when none).
static func build_parts(holder: Node3D, world: Dictionary, only: Dictionary, picks: Array, ghosts := true) -> AABB:
	var ids := WorldValues.by_id(world)
	var bounds := AABB()
	var first := true
	for o in world.get("objects", []):
		if not only.is_empty() and not only.has(int(o.id)):
			continue
		var oc := str(o.get("class", ""))
		if not CBTypes.is_subclass(oc, "Shape3D") and not CBTypes.is_subclass(oc, "Mesh3D"):
			continue
		var made := make_part(o, WorldValues.world_transform(o, ids), ghosts)
		if made.is_empty():
			continue
		holder.add_child(made[0])
		picks.append([int(o.id), made[1]])
		var box: Transform3D = made[1]
		var b := box * AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
		bounds = b if first else bounds.merge(b)
		first = false
	return bounds


## A Shape3D's mesh (a Mesh3D: a ghost box, its mesh is made by bricks while the program
## runs): [MeshInstance3D, its unit box's transform] ([] for a hidden one without ghosts).
static func make_part(o: Dictionary, xf: Transform3D, ghosts := true) -> Array:
	var mesh_part := CBTypes.is_subclass(str(o["class"]), "Mesh3D")
	var size := Vector3.ONE if mesh_part else WorldValues.vec(WorldValues.field(o, "size"))
	var shape := WorldValues.field(o, "shape")
	var mesh: Mesh
	match shape:
		"Sphere":
			var m := SphereMesh.new()
			m.radius = 0.5
			m.height = 1.0
			mesh = m
		"Cylinder":
			var m := CylinderMesh.new()
			m.top_radius = 0.5
			m.bottom_radius = 0.5
			m.height = 1.0
			mesh = m
		"Plane":
			var m := PlaneMesh.new()
			m.size = Vector2(1, 1)
			mesh = m
		_:
			mesh = BoxMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	var col := WorldValues.color(WorldValues.field(o, "color"))
	var visible_field := WorldValues.field(o, "visible") != "false"
	if not visible_field or mesh_part:
		if not ghosts and not visible_field:
			return []
		col.a = 0.3  # hidden, or a mesh made by bricks while the program runs
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = col
	if shape == "Plane":
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	var box := xf * Transform3D(Basis.from_scale(_nonzero(size)), Vector3.ZERO)
	mi.transform = box
	return [mi, box if shape != "Plane" else box * Transform3D(Basis.from_scale(Vector3(1, 0.05, 1)), Vector3.ZERO)]


static func _nonzero(v: Vector3) -> Vector3:
	return Vector3(v.x if absf(v.x) > 0.001 else 0.001, v.y if absf(v.y) > 0.001 else 0.001, v.z if absf(v.z) > 0.001 else 0.001)


func _add_icon(id: int, at: Vector3, kind: String) -> void:
	if not _icon_textures.has(kind):
		var img := Image.new()
		img.load_svg_from_string(ICON_SVGS[kind], 4.0)  # (64 px: crisp when it is drawn at 30)
		img.generate_mipmaps()
		_icon_textures[kind] = ImageTexture.create_from_image(img)
	var sp := Sprite3D.new()
	sp.texture = _icon_textures[kind]
	sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sp.shaded = false
	sp.no_depth_test = true
	sp.render_priority = 5
	sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sp.position = at
	_objects.add_child(sp)
	_icons[id] = sp


## Keeps every icon ICON_PX big on the screen, near or far (a Sprite3D's size is in world units).
func _scale_icons() -> void:
	if _icons.is_empty() or _cam == null or _vp == null:
		return
	var h := maxf(float(_vp.size.y), 1.0)
	var back := -_cam.global_transform.basis.z if _cam.is_inside_tree() else -_cam.transform.basis.z
	var from := _cam.global_position if _cam.is_inside_tree() else _cam.position
	for id in _icons:
		var sp: Sprite3D = _icons[id]
		var d := maxf((sp.position - from).dot(back), 0.1)
		var tex_px := float(sp.texture.get_height())
		sp.pixel_size = 2.0 * d * tan(deg_to_rad(_cam.fov) / 2.0) / h * ICON_PX / tex_px


func _add_line(a: Vector3, b: Vector3, col: Color, parent: Node3D = null) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(col)
	im.surface_add_vertex(a)
	im.surface_add_vertex(b)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _unshaded(parent != null)
	(parent if parent != null else _objects).add_child(mi)


# ------------------------------------------------------------------ selection and arrows

func _selected_id() -> int:
	return int(context.world_object.get("id", 0)) if not context.world_object.is_empty() else 0


## The selected object's outline and, when it can move, its X / Y / Z arrows.
func _draw_selection() -> void:
	for c in _overlay.get_children():
		c.queue_free()
	var id := _selected_id()
	for i in _icons:
		(_icons[i] as Sprite3D).modulate = Color(1.0, 0.65, 0.2) if int(i) == id and id != 0 else Color.WHITE
	if id == 0:
		return
	for p in _picks:
		if int(p[0]) == id:
			_outline(p[1])
	var o: Dictionary = context.flat_of(context.world_object)
	if _movable(o):
		var at := _world_pos(o)
		for i in 3:
			_add_line(at, at + AXES[i] * ARROW, AXIS_COLORS[i], _overlay)
			var tip := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.09
			cone.height = 0.3
			tip.mesh = cone
			var mat := _unshaded(true)
			mat.vertex_color_use_as_albedo = false
			mat.albedo_color = AXIS_COLORS[i]
			tip.material_override = mat
			tip.position = at + AXES[i] * ARROW
			if i == 0:
				tip.rotation = Vector3(0, 0, -PI / 2)
			elif i == 2:
				tip.rotation = Vector3(PI / 2, 0, 0)
			_overlay.add_child(tip)


func _outline(box: Transform3D) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(Color(1.0, 0.65, 0.2))
	var c := []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				c.append(box * Vector3(x, y, z))
	for e in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		im.surface_add_vertex(c[e[0]])
		im.surface_add_vertex(c[e[1]])
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _unshaded(true)
	_overlay.add_child(mi)


static func _movable(o: Dictionary) -> bool:
	return CBTypes.is_subclass(str(o.get("class", "")), "Spatial3D")


func _world_pos(o: Dictionary) -> Vector3:
	return WorldValues.world_transform(o, WorldValues.by_id(context.world_flat)).origin


## The object under a point of the view (0: none): the nearest box the ray enters.
func pick_at(at: Vector2) -> int:
	var near := ICON_HIT
	var icon_id := 0
	for id in _icons:  # an icon is picked by how near the click is to it on the screen
		var pos: Vector3 = (_icons[id] as Sprite3D).position
		if _cam.is_position_behind(pos):
			continue
		var dist := _cam.unproject_position(pos).distance_to(at)
		if dist < near:
			near = dist
			icon_id = int(id)
	if icon_id != 0:
		return icon_id
	var from := _cam.project_ray_origin(at)
	var dir := _cam.project_ray_normal(at)
	var best := INF
	var best_id := 0
	for p in _picks:
		var inv: Transform3D = (p[1] as Transform3D).affine_inverse()
		var o := inv * from
		var d := inv.basis * dir
		var t := _ray_box(o, d)
		if t >= 0.0 and t < best:
			best = t
			best_id = int(p[0])
	return best_id


## Where a ray (in a unit box's space) enters the box -0.5..0.5 (-1: misses).
static func _ray_box(o: Vector3, d: Vector3) -> float:
	var tmin := -INF
	var tmax := INF
	for i in 3:
		if absf(d[i]) < 1e-8:
			if o[i] < -0.5 or o[i] > 0.5:
				return -1.0
		else:
			var t1 := (-0.5 - o[i]) / d[i]
			var t2 := (0.5 - o[i]) / d[i]
			tmin = maxf(tmin, minf(t1, t2))
			tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return -1.0
	return maxf(tmin, 0.0)


## The arrow under a point of the view (-1: none): within 10 px of its line on screen.
func axis_at(at: Vector2) -> int:
	var o: Dictionary = context.world_object
	if o.is_empty() or not _movable(o):
		return -1
	var base := _world_pos(o)
	var best := 10.0
	var hit := -1
	for i in 3:
		var a := _cam.unproject_position(base)
		var b := _cam.unproject_position(base + AXES[i] * ARROW)
		var d := Geometry2D.get_closest_point_to_segment(at, a, b).distance_to(at)
		if d < best and not _cam.is_position_behind(base + AXES[i] * ARROW):
			best = d
			hit = i
	return hit


## How far along an axis line through `base` the view ray at `at` comes closest.
func _axis_param(axis: int, base: Vector3, at: Vector2) -> float:
	var ro := _cam.project_ray_origin(at)
	var rd := _cam.project_ray_normal(at)
	var ad: Vector3 = AXES[axis]
	var w := base - ro
	var b := ad.dot(rd)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-6:
		return 0.0
	return (b * rd.dot(w) - ad.dot(w)) / denom


func begin_drag(axis: int, at: Vector2) -> void:
	_drag_axis = axis
	_drag_start_pos = _world_pos(context.flat_of(context.world_object))
	_drag_start_t = _axis_param(axis, _drag_start_pos, at)


## Moves the selected object along the dragged axis to follow the pointer.
func drag_to(at: Vector2, snap := false) -> void:
	if _drag_axis < 0 or context.world_object.is_empty():
		return
	var o: Dictionary = context.world_object  # (the scene's entry: a copy's position is an override)
	var flat := context.flat_of(o)
	var t := _axis_param(_drag_axis, _drag_start_pos, at) - _drag_start_t
	var world_pos: Vector3 = _drag_start_pos + AXES[_drag_axis] * t
	var local := WorldValues.parent_transform(flat, WorldValues.by_id(context.world_flat)).affine_inverse() * world_pos
	if snap:
		local = local.snapped(Vector3.ONE * 0.5)
	o.fields["position"] = WorldValues.vec_text(local)
	context.world_live.emit(int(o.get("id", 0)), "position", str(o.fields["position"]))
	context.refresh_flat()
	rebuild()


func end_drag() -> void:
	if _drag_axis < 0:
		return
	_drag_axis = -1
	if context.on_world_changed.is_valid():
		context.on_world_changed.call("Move %s" % str(context.world_object.get("name", "")))


func frame_selected() -> void:
	var o: Dictionary = context.flat_of(context.world_object)
	if not o.is_empty() and _movable(o):
		_pivot = _world_pos(o)
		_dist = 8.0
		_place_camera()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					grab_focus()
					var axis := axis_at(mb.position)
					if axis >= 0:
						begin_drag(axis, mb.position)
					else:
						var id := pick_at(mb.position)
						context.show_world_object(_find(id))
				else:
					end_drag()
			MOUSE_BUTTON_RIGHT:  # (Godot's: freelook + WASD; Shift: pan)
				if mb.pressed:
					grab_focus()
				var was_looking := _looking
				_looking = mb.pressed and not mb.shift_pressed
				_panning = mb.pressed and mb.shift_pressed
				if _looking and not was_looking:
					_begin_look()
				elif was_looking and not _looking:
					_end_look()
			MOUSE_BUTTON_MIDDLE:  # (Godot's: orbit; Shift: pan)
				_orbiting = mb.pressed and not mb.shift_pressed
				_panning = mb.pressed and mb.shift_pressed
			MOUSE_BUTTON_WHEEL_UP:
				_dist = maxf(1.5, _dist * 0.9)
				_place_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				_dist = minf(200.0, _dist * 1.1)
				_place_camera()
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null:
		if _drag_axis >= 0:
			drag_to(mm.position, mm.ctrl_pressed)
		elif _looking:  # turn in place: the camera stays, the point it orbits moves
			var eye := _cam.global_transform.origin
			_yaw -= mm.relative.x * 0.006
			_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.5, 1.5)
			var dir := Vector3(cos(_pitch) * sin(_yaw), -sin(_pitch), cos(_pitch) * cos(_yaw))
			_pivot = eye - dir * _dist
			_place_camera()
		elif _orbiting:
			_yaw -= mm.relative.x * 0.008
			_pitch = clampf(_pitch - mm.relative.y * 0.008, -1.5, 1.5)
			_place_camera()
		elif _panning:
			var right := _cam.global_transform.basis.x
			var up := _cam.global_transform.basis.y
			_pivot += (-right * mm.relative.x + up * mm.relative.y) * _dist * 0.002
			_place_camera()
		return
	var k := event as InputEventKey
	if k != null and k.pressed and k.keycode == KEY_F:
		frame_selected()
		accept_event()


## The scene's entry for a picked id (inside a copy: the copy).
func _find(id: int) -> Dictionary:
	for o in context.world_flat.get("objects", []):
		if int(o.id) == id:
			return context.raw_of(o)
	return {}
