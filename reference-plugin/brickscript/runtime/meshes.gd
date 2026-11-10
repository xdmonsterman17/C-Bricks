extends RefCounted

## Procedural meshes for the Mesh bricks (preloaded by their helper, no
## class_name: generated scripts and exported games reach it by path).
##
## Begin mesh / Add triangle / Add quad / Add shape collect steps on the
## MeshInstance3D (metadata), Finish mesh builds them into an ArrayMesh. A
## step is plain data, so a whole mesh can be sent as its list of steps:
##   [TRIANGLE, a, b, c, color]
##   [QUAD, a, b, c, d, color]
##   [SHAPE, Shape, at, size, color]
## Front faces go clockwise, seen from the side that shows (Godot's way);
## Both sides shows the other side too.

const TRIANGLE: int = 0
const QUAD: int = 1
const SHAPE: int = 2
enum Shape { BOX, SPHERE, CYLINDER, PLANE }
## Metadata on the MeshInstance3D: the steps added since Begin mesh.
const STEPS_META: StringName = &"_brickscript_mesh_steps"
## Metadata on a mesh made here: it belongs to that node alone, so it may be
## changed in place (a mesh from a scene may be shared by other nodes).
const OWN_META: StringName = &"_brickscript_own_mesh"
## A server's mesh on every machine (Network Context Engine API 20 node
## data): the recipe [steps, smooth, both sides] Finish mesh built, then the
## points / colors Mesh vertices set since (null: none since).
const RECIPE_KEY: StringName = &"brickscript_mesh"
const POINTS_KEY: StringName = &"brickscript_mesh_points"
const COLORS_KEY: StringName = &"brickscript_mesh_colors"
## Shapes' detail: around a sphere / cylinder, and a sphere's rings.
const SEGMENTS: int = 16
const RINGS: int = 8

## [one side, both sides]: shows the vertex colors.
static var _materials: Array[StandardMaterial3D] = [null, null]
## Shape -> [vertices, normals, uvs] of the unit shape, as triangle lists.
static var _unit_shapes: Dictionary[int, Array] = {}


## A client: the server's mesh data for a node arrived (the engine's
## node_data_changed, heard by the BrickscriptDebug autoload); build it here.
static func on_node_data(node: Node, key: StringName, value: Variant) -> void:
	if not node is MeshInstance3D or value == null:
		return
	var mesh_node: MeshInstance3D = node
	match key:
		RECIPE_KEY:
			if value is Array and (value as Array).size() == 3 and value[0] is Array:
				mesh_node.mesh = build(value[0], bool(value[1]), bool(value[2]))
		POINTS_KEY, COLORS_KEY:
			if value is PackedVector3Array or value is PackedColorArray:
				var problem: String = set_points(mesh_node, Array(value), key == COLORS_KEY)
				if not problem.is_empty():
					push_error("Brickscript: the server's mesh for %s: %s" % [mesh_node.name, problem])


static func begin(node: MeshInstance3D) -> void:
	node.set_meta(STEPS_META, [])


static func add_step(node: MeshInstance3D, step: Array) -> void:
	if not node.has_meta(STEPS_META):
		node.set_meta(STEPS_META, [])
	(node.get_meta(STEPS_META) as Array).append(step)


## The steps added since Begin mesh, forgotten on the node.
static func take_steps(node: MeshInstance3D) -> Array:
	var steps: Array = node.get_meta(STEPS_META, [])
	node.remove_meta(STEPS_META)
	return steps


## The mesh the steps make. Flat: every triangle added is its own face (shapes
## keep their own shading); Smooth: shaded round across the triangles that
## meet at a place, and corners in the same place and of the same color are
## one point (texture spots then come from the place: x, z).
static func build(steps: Array, smooth: bool, both_sides: bool) -> ArrayMesh:
	var vertices: PackedVector3Array = []
	var normals: PackedVector3Array = []
	var colors: PackedColorArray = []
	var uvs: PackedVector2Array = []
	for step: Array in steps:
		match int(step[0]):
			TRIANGLE:
				_add_triangle(step[1], step[2], step[3], step[4], vertices, normals, colors, uvs)
			QUAD:
				_add_triangle(step[1], step[2], step[3], step[5], vertices, normals, colors, uvs)
				_add_triangle(step[1], step[3], step[4], step[5], vertices, normals, colors, uvs)
			SHAPE:
				_add_shape(int(step[1]), step[2], step[3], step[4], vertices, normals, colors, uvs)
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.set_meta(OWN_META, true)
	if vertices.is_empty():
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if smooth:
		# Godot's SurfaceTool, natively: normals averaged over the corners in
		# each place, then corners alike (place, color) joined into one point.
		# Texture spots from the place (x, z), so a sphere's seam joins too.
		var flat_uvs: PackedVector2Array = []
		flat_uvs.resize(vertices.size())
		for i: int in vertices.size():
			flat_uvs[i] = Vector2(vertices[i].x, vertices[i].z)
		arrays[Mesh.ARRAY_TEX_UV] = flat_uvs
		var tool: SurfaceTool = SurfaceTool.new()
		tool.create_from_arrays(arrays)
		tool.generate_normals()
		tool.index()
		tool.commit(mesh)
	else:
		arrays[Mesh.ARRAY_NORMAL] = normals
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material(both_sides))
	return mesh


## Normals worked out from the triangles: with indices, each point's is the
## average of the faces sharing it (bigger faces count more); without, each
## triangle's corners get its face's. A point whose faces have no area (a
## sphere's pole) keeps its normal from `before` (else up).
static func normals_for(vertices: PackedVector3Array, indices: PackedInt32Array, before: PackedVector3Array = PackedVector3Array()) -> PackedVector3Array:
	var normals: PackedVector3Array = []
	normals.resize(vertices.size())
	if indices.is_empty():
		for i: int in range(0, vertices.size() - 2, 3):
			var face: Vector3 = _face(vertices[i], vertices[i + 1], vertices[i + 2]).normalized()
			normals[i] = face
			normals[i + 1] = face
			normals[i + 2] = face
		return normals
	for i: int in range(0, indices.size() - 2, 3):
		var a: int = indices[i]
		var b: int = indices[i + 1]
		var c: int = indices[i + 2]
		var face: Vector3 = (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
		normals[a] += face
		normals[b] += face
		normals[c] += face
	var kept: bool = before.size() == normals.size()
	for i: int in normals.size():
		var normal: Vector3 = normals[i]
		normals[i] = normal.normalized() if not normal.is_zero_approx() else before[i] if kept else Vector3.UP
	return normals



## The material a built mesh gets: its vertex colors, lit; Both sides shows
## the back of each triangle too.
static func material(both_sides: bool) -> StandardMaterial3D:
	var at: int = 1 if both_sides else 0
	if _materials[at] == null:
		var made: StandardMaterial3D = StandardMaterial3D.new()
		made.vertex_color_use_as_albedo = true
		made.cull_mode = BaseMaterial3D.CULL_DISABLED if both_sides else BaseMaterial3D.CULL_BACK
		_materials[at] = made
	return _materials[at]


## The mesh's points (or their colors: white where it has none), one per
## corner its first surface has. Empty without a mesh.
static func points(node: MeshInstance3D) -> Array[Vector3]:
	var found: Array[Vector3] = []
	var arrays: Array = _arrays_of(node)
	if not arrays.is_empty():
		found.assign(Array(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array))
	return found


static func colors(node: MeshInstance3D) -> Array[Color]:
	var found: Array[Color] = []
	var arrays: Array = _arrays_of(node)
	if arrays.is_empty():
		return found
	if arrays[Mesh.ARRAY_COLOR] == null:
		found.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
		found.fill(Color.WHITE)
		return found
	found.assign(Array(arrays[Mesh.ARRAY_COLOR] as PackedColorArray))
	return found


## Puts points (or colors) back into the mesh's first surface, one per point
## it has; new points get their normals worked out again (normals_for).
## Returns why it can't ("" when done). A mesh not made here is copied first,
## so other nodes sharing it don't change.
static func set_points(node: MeshInstance3D, values: Array, as_colors: bool) -> String:
	var arrays: Array = _arrays_of(node)
	if arrays.is_empty():
		return "%s has no mesh to change (build one with Finish mesh, or give it one)" % node.name
	var count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if values.size() != count:
		return "got %d %s for a mesh of %d points (Get them, change them, Set them back)" % [values.size(), "colors" if as_colors else "points", count]
	var wanted: int = TYPE_COLOR if as_colors else TYPE_VECTOR3
	# (A typed List, as bricks give, needn't be looked through.)
	if not values.is_typed() or values.get_typed_builtin() != wanted:
		for value: Variant in values:
			if typeof(value) != wanted:
				return "%s isn't a %s" % [value, "Color" if as_colors else "Vector3"]
	if as_colors:
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray(values)
	else:
		var moved: PackedVector3Array = PackedVector3Array(values)
		arrays[Mesh.ARRAY_VERTEX] = moved
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var before: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		arrays[Mesh.ARRAY_NORMAL] = normals_for(moved, indices, before)
		arrays[Mesh.ARRAY_TANGENT] = null
	var old: Mesh = node.mesh
	var primitive: Mesh.PrimitiveType = (old as ArrayMesh).surface_get_primitive_type(0) if old is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
	var kept: Material = old.surface_get_material(0)
	var target: ArrayMesh = old as ArrayMesh if old is ArrayMesh and old.has_meta(OWN_META) and old.get_surface_count() == 1 else null
	if target == null:
		target = ArrayMesh.new()
		target.set_meta(OWN_META, true)
		for surface: int in range(1, old.get_surface_count()):
			target.add_surface_from_arrays((old as ArrayMesh).surface_get_primitive_type(surface) if old is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES, old.surface_get_arrays(surface))
			target.surface_set_material(surface, old.surface_get_material(surface))
		_add_first(target, primitive, arrays, kept)
		node.mesh = target
		return ""
	target.clear_surfaces()
	_add_first(target, primitive, arrays, kept)
	return ""


## Surface 0 of `target`, with any later surfaces it already has moved after it.
static func _add_first(target: ArrayMesh, primitive: Mesh.PrimitiveType, arrays: Array, kept: Material) -> void:
	var later: Array = []
	for surface: int in target.get_surface_count():
		later.append([target.surface_get_primitive_type(surface), target.surface_get_arrays(surface), target.surface_get_material(surface)])
	target.clear_surfaces()
	target.add_surface_from_arrays(primitive, arrays)
	target.surface_set_material(0, kept)
	for surface: Array in later:
		target.add_surface_from_arrays(surface[0], surface[1])
		target.surface_set_material(target.get_surface_count() - 1, surface[2])


static func _arrays_of(node: MeshInstance3D) -> Array:
	if node.mesh == null or node.mesh.get_surface_count() == 0:
		return []
	return node.mesh.surface_get_arrays(0)


## A front face's normal (not normalized: its length is twice the area).
static func _face(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	return (c - a).cross(b - a)


static func _add_triangle(a: Vector3, b: Vector3, c: Vector3, color: Color, vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, uvs: PackedVector2Array) -> void:
	var face: Vector3 = _face(a, b, c)
	face = face.normalized() if not face.is_zero_approx() else Vector3.UP
	vertices.append(a)
	vertices.append(b)
	vertices.append(c)
	normals.append(face)
	normals.append(face)
	normals.append(face)
	colors.append(color)
	colors.append(color)
	colors.append(color)
	uvs.append(Vector2(a.x, a.z))
	uvs.append(Vector2(b.x, b.z))
	uvs.append(Vector2(c.x, c.z))


## A unit shape scaled to `size` (across: a box's sides, a sphere's or a
## cylinder's width / height, a plane's x and z) with its middle at `at`.
static func _add_shape(shape: int, at: Vector3, size: Vector3, color: Color, vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, uvs: PackedVector2Array) -> void:
	var unit: Array = _unit_shape(shape)
	var unit_vertices: PackedVector3Array = unit[0]
	var unit_normals: PackedVector3Array = unit[1]
	# Whole arrays at once (Godot transforms a packed array natively).
	vertices.append_array(Transform3D(Basis.from_scale(size), at) * unit_vertices)
	if size.x == size.y and size.y == size.z and size.x > 0.0:
		normals.append_array(unit_normals)
	else:
		# Normals stretch the other way (inverse scale); a flat axis stays flat.
		var inverse: Vector3 = Vector3(_inverse(size.x), _inverse(size.y), _inverse(size.z))
		for normal: Vector3 in unit_normals:
			normals.append((normal * inverse).normalized())
	var shade: PackedColorArray = []
	shade.resize(unit_vertices.size())
	shade.fill(color)
	colors.append_array(shade)
	uvs.append_array(unit[2])


static func _inverse(scale: float) -> float:
	return 1.0 / scale if absf(scale) > 0.000001 else 1000000.0 * signf(scale if scale != 0.0 else 1.0)


## Godot's primitive mesh of size 1, as triangle lists (made once per shape).
static func _unit_shape(shape: int) -> Array:
	if _unit_shapes.has(shape):
		return _unit_shapes[shape]
	var primitive: PrimitiveMesh
	match shape:
		Shape.SPHERE:
			var sphere: SphereMesh = SphereMesh.new()
			sphere.radius = 0.5
			sphere.height = 1.0
			sphere.radial_segments = SEGMENTS
			sphere.rings = RINGS
			primitive = sphere
		Shape.CYLINDER:
			var cylinder: CylinderMesh = CylinderMesh.new()
			cylinder.top_radius = 0.5
			cylinder.bottom_radius = 0.5
			cylinder.height = 1.0
			cylinder.radial_segments = SEGMENTS
			cylinder.rings = 0
			primitive = cylinder
		Shape.PLANE:
			var plane: PlaneMesh = PlaneMesh.new()
			plane.size = Vector2.ONE
			primitive = plane
		_:
			primitive = BoxMesh.new()
	var arrays: Array = primitive.get_mesh_arrays()
	var source_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var source_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	# (Filled here, then put in the Array: a packed array read out of an Array
	# is a copy.)
	var unit_vertices: PackedVector3Array = []
	var unit_normals: PackedVector3Array = []
	var unit_uvs: PackedVector2Array = []
	for index: int in arrays[Mesh.ARRAY_INDEX] as PackedInt32Array:
		unit_vertices.append(source_vertices[index])
		unit_normals.append(source_normals[index])
		unit_uvs.append(source_uvs[index])
	var unit: Array = [unit_vertices, unit_normals, unit_uvs]
	_unit_shapes[shape] = unit
	return unit
