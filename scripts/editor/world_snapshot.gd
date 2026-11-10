class_name WorldSnapshot
extends Node
## Renders world.cnworld's Parts to images with Godot (synchronously: RenderingServer.force_draw), as the 3D screen draws them
## (no grid, no markers): a Camera's snapshot (Properties: Take snapshot) and the
## Scene tree's thumbnails. Jobs wait in a queue and render one at a time.
##
## A job: {"world", "size": Vector2i, "transparent": bool, "only": {id: true} ({} = all),
##         "camera": {"position", "target", "fov"} (none: a 3/4 view framing them)}.

var _vp: SubViewport = null
var _holder: Node3D = null
var _env: Environment = null
var _sun: DirectionalLight3D = null
var _cam: Camera3D = null
var _queue: Array = []   # [job, done (Callable(Image))]
var _busy := false
## Thumbnails already made: key (the objects' data) -> Texture2D.
var icons: Dictionary = {}
## The last snapshot of each Camera object: id -> Texture2D (the Properties preview).
var last: Dictionary = {}


func _init() -> void:
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.msaa_3d = Viewport.MSAA_4X
	add_child(_vp)
	var root := Node3D.new()
	_vp.add_child(root)
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.6, 0.6, 0.65)
	we.environment = _env
	root.add_child(we)
	_sun = DirectionalLight3D.new()
	root.add_child(_sun)
	_cam = Camera3D.new()
	_cam.far = 1000
	root.add_child(_cam)
	_holder = Node3D.new()
	root.add_child(_holder)


func render(job: Dictionary, done: Callable) -> void:
	_queue.append([job, done])
	_next()


func _next() -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	var item: Array = _queue.pop_front()
	_render_now(item[0], item[1])


func _render_now(job: Dictionary, done: Callable) -> void:
	for c in _holder.get_children():
		c.free()
	var world: Dictionary = job.get("world", {})
	var bounds := WorldView3D.build_parts(_holder, world, job.get("only", {}), [], false)
	WorldView3D.apply_lighting(_env, _sun, WorldView3D.lighting(world))
	var transparent := bool(job.get("transparent", false))
	if transparent:
		_env.background_mode = Environment.BG_CLEAR_COLOR
	elif _env.background_mode != Environment.BG_SKY:  # (a horizon: apply_lighting's gradient sky)
		_env.background_mode = Environment.BG_COLOR
	_vp.transparent_bg = transparent
	var size: Vector2i = job.get("size", Vector2i(256, 256))
	_vp.size = Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	var cam: Dictionary = job.get("camera", {})
	if not cam.is_empty():
		_cam.fov = clampf(float(cam.get("fov", 60.0)), 1.0, 179.0)
		var at: Vector3 = cam.position
		var target: Vector3 = cam.target
		if at.distance_to(target) < 0.0001:
			target = at + Vector3.FORWARD
		var up := Vector3.UP if absf((target - at).normalized().y) < 0.999 else Vector3.BACK
		_cam.transform = Transform3D(Basis.looking_at(target - at, up), at)
	else:
		# A 3/4 view from above, far enough to fit the objects.
		_cam.fov = 30.0
		var center := bounds.get_center() if bounds.size != Vector3.ZERO else Vector3.ZERO
		var radius := maxf(bounds.size.length() * 0.5, 0.25)
		var dir := Vector3(1.0, 0.8, 1.0).normalized()
		var dist := radius / sin(deg_to_rad(_cam.fov * 0.5)) * 1.02
		_cam.transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), center + dir * dist)
	# New / moved nodes' transforms reach the renderer later in the frame: push them
	# now (the meshes, the camera, the sun). Then draw now instead of waiting for a
	# frame: the editor runs in low-processor mode (project.godot), where frames are
	# only drawn when something changes.
	await get_tree().process_frame
	for c in _holder.get_children():
		(c as Node3D).force_update_transform()
	_cam.force_update_transform()
	_sun.force_update_transform()
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.force_draw(false)
	var img := _vp.get_texture().get_image()
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	done.call(img)
	_busy = false
	_next.call_deferred()  # the next job at the next idle moment: the window stays responsive


## A thumbnail for an object (a Part / MeshPart / Model, with the objects under it):
## from the cache, or rendered (then `ready` gets the texture). Returns the cached one or null.
func icon_for(world: Dictionary, o: Dictionary, ready: Callable, px := 40) -> Texture2D:
	var only := {int(o.id): true}
	var grew := true
	while grew:
		grew = false
		for x in world.get("objects", []):
			if only.has(int(x.get("parent", 0))) and not only.has(int(x.id)):
				only[int(x.id)] = true
				grew = true
	var parts := []
	for x in world.get("objects", []):
		if only.has(int(x.id)):
			parts.append([x.get("class", ""), x.get("parent", 0), x.get("fields", {})])
	var key := JSON.stringify([parts, WorldView3D.lighting(world)])
	if icons.has(key):
		return icons[key]
	icons[key] = null  # rendering: not again meanwhile
	render({"world": world, "size": Vector2i(px, px), "transparent": true, "only": only}, func(img: Image) -> void:
		var tex := ImageTexture.create_from_image(img)
		icons[key] = tex
		ready.call(tex))
	return null
