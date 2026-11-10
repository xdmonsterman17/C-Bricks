extends RefCounted

## Air paths for flying characters (a Character3D of kind Drone, Controlled
## by Script): Walk to / Follow fly straight when nothing is in the way, else
## along a path through a coarse grid of open air (cells of CELL meters).
## A cell is open when a ball (the flyer's radius and a margin) at its middle
## touches nothing static: StaticBody3D (not AnimatableBody3D: characters),
## a Terrain's ground (its collision), CSG and the like; and its middle isn't
## inside a Terrain's ground (asked by method name, solid_at: a collision
## surface has no inside, so a ball deep in the ground touches nothing). A
## triangle mesh collider of your own has the same blind inside: only its
## surface blocks. Cells are looked at
## when a search first needs them and kept CELL_LIFE_MSEC (walls and crates
## that move are seen again after that); a Terrain's chunk built again (a
## dig) forgets the cells it covers. Only what has collision counts: a
## Streamed Terrain's ground far from every player has none yet.
##
## The search (A*, 6 neighbors, a little greedy: GREED; only within BOX_CELLS
## of the box round start and goal) runs a little each physics frame (step(),
## within a time budget), so a long one never holds up a frame; the flyer
## hovers meanwhile. The path is then straightened (cell middles it can fly
## between in a straight line are skipped).

## A cell's side, in meters.
const CELL: float = 1.5
## Added to the flyer's radius for the ball a cell is looked at with.
const MARGIN: float = 0.3
## Cells a search may look at before it gives up (no way there).
const MAX_EXPANSIONS: int = 12000
## How far past the box round start and goal a search may go (cells).
const BOX_CELLS: int = 20
## The estimate's weight (over 1: it heads for the goal first, a path a
## little longer at worst; the path is straightened after anyway).
const GREED: float = 3.0
const STEPS: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
## How long a looked-at cell is believed (ms).
const CELL_LIFE_MSEC: int = 5000
## How far (cells) the start / the goal may move to the nearest open cell.
const SNAP_CELLS: int = 2

enum State { SEARCHING, FOUND, NONE }

## World3D -> Grid.
static var _grids: Dictionary = {}


## One World3D's cells: Vector3i -> [open, when looked at (ms)].
class Grid:
	extends RefCounted
	var world: WeakRef = null
	var cells: Dictionary[Vector3i, Array] = {}
	var hooked: Dictionary[int, bool] = {}
	## The Terrains in this world (weak refs): their inside is solid.
	var terrains: Array[WeakRef] = []
	var _query: PhysicsShapeQueryParameters3D = null

	func open(cell: Vector3i, radius: float, exclude: Array[RID]) -> bool:
		var now: int = Time.get_ticks_msec()
		var known: Array = cells.get(cell, [])
		if not known.is_empty() and now - int(known[1]) < CELL_LIFE_MSEC:
			return known[0]
		var found: World3D = world.get_ref() as World3D
		if found == null:
			return true
		if _query == null:
			_query = PhysicsShapeQueryParameters3D.new()
			_query.shape = SphereShape3D.new()
		(_query.shape as SphereShape3D).radius = radius + MARGIN
		_query.transform = Transform3D(Basis.IDENTITY, middle(cell))
		_query.exclude = exclude
		var free: bool = true
		for held: WeakRef in terrains:
			var terrain: Node = held.get_ref() as Node
			if terrain != null and bool(terrain.call(&"solid_at", middle(cell))):
				cells[cell] = [false, now]
				return false
		for hit: Dictionary in found.direct_space_state.intersect_shape(_query, 8):
			var collider: Object = hit.get("collider")
			if collider is AnimatableBody3D or collider is CharacterBody3D or collider is RigidBody3D:
				continue
			free = false
			break
		cells[cell] = [free, now]
		return free

	## Forgets the cells in a box (world space).
	func forget(low: Vector3, high: Vector3) -> void:
		var from: Vector3i = cell_of(low) - Vector3i.ONE
		var to: Vector3i = cell_of(high) + Vector3i.ONE
		for cell: Vector3i in cells.keys():
			if cell.x >= from.x and cell.x <= to.x and cell.y >= from.y and cell.y <= to.y and cell.z >= from.z and cell.z <= to.z:
				cells.erase(cell)

	static func cell_of(at: Vector3) -> Vector3i:
		return Vector3i((at / CELL).floor())

	static func middle(cell: Vector3i) -> Vector3:
		return (Vector3(cell) + Vector3(0.5, 0.5, 0.5)) * CELL


## A search under way (search()); step() it until it isn't SEARCHING.
class Search:
	extends RefCounted
	var path: PackedVector3Array = PackedVector3Array()
	var state: State = State.SEARCHING
	var expanded: int = 0
	var _grid: Grid = null
	var _radius: float = 0.4
	var _exclude: Array[RID] = []
	var _from: Vector3 = Vector3.ZERO
	var _to: Vector3 = Vector3.ZERO
	var _start: Vector3i = Vector3i.ZERO
	var _goal: Vector3i = Vector3i.ZERO
	var _heap: Array[Array] = []
	var _cost: Dictionary[Vector3i, float] = {}
	var _came: Dictionary[Vector3i, Vector3i] = {}
	var _closed: Dictionary[Vector3i, bool] = {}
	var _began: bool = false
	var _low: Vector3i = Vector3i.ZERO
	var _high: Vector3i = Vector3i.ZERO

	func _init(grid: Grid, from: Vector3, to: Vector3, radius: float, exclude: Array[RID]) -> void:
		_grid = grid
		_from = from
		_to = to
		_radius = radius
		_exclude = exclude

	## Works for up to `budget_usec`; the state then.
	func step(budget_usec: int) -> State:
		if state != State.SEARCHING:
			return state
		var until: int = Time.get_ticks_usec() + budget_usec
		if not _began:
			_began = true
			_start = Grid.cell_of(_from)
			var goal: Variant = _nearest_open(Grid.cell_of(_to), _to)
			if goal == null:
				state = State.NONE
				return state
			_goal = goal
			_low = _start.min(_goal) - Vector3i.ONE * BOX_CELLS
			_high = _start.max(_goal) + Vector3i.ONE * BOX_CELLS
			_cost[_start] = 0.0
			_push(_start, _guess(_start))
		while not _heap.is_empty():
			if Time.get_ticks_usec() > until:
				return state
			var cell: Vector3i = _pop()
			if _closed.has(cell):
				continue
			if cell == _goal:
				_finish()
				return state
			_closed[cell] = true
			expanded += 1
			if expanded > MAX_EXPANSIONS:
				state = State.NONE
				return state
			for move: Vector3i in STEPS:
				var next: Vector3i = cell + move
				if _closed.has(next) or next.x < _low.x or next.y < _low.y or next.z < _low.z or next.x > _high.x or next.y > _high.y or next.z > _high.z:
					continue
				if not _grid.open(next, _radius, _exclude):
					continue
				var cost: float = float(_cost[cell]) + 1.0
				if cost < float(_cost.get(next, INF)):
					_cost[next] = cost
					_came[next] = cell
					_push(next, cost + _guess(next) * GREED)
		state = State.NONE
		return state

	## The open cell nearest `cell` (within SNAP_CELLS), nearest `at` first;
	## null if none.
	func _nearest_open(cell: Vector3i, at: Vector3) -> Variant:
		if _grid.open(cell, _radius, _exclude):
			return cell
		var best: Variant = null
		var best_distance: float = INF
		for dz: int in range(-SNAP_CELLS, SNAP_CELLS + 1):
			for dy: int in range(-SNAP_CELLS, SNAP_CELLS + 1):
				for dx: int in range(-SNAP_CELLS, SNAP_CELLS + 1):
					var near: Vector3i = cell + Vector3i(dx, dy, dz)
					var distance: float = Grid.middle(near).distance_squared_to(at)
					if distance < best_distance and _grid.open(near, _radius, _exclude):
						best = near
						best_distance = distance
		return best

	func _guess(cell: Vector3i) -> float:
		return Vector3(cell - _goal).length()

	## The cells back to the start, straightened: from each point, the
	## furthest it can fly to in a straight line through open cells.
	func _finish() -> void:
		var cells: Array[Vector3i] = [_goal]
		while cells[-1] != _start:
			cells.append(_came[cells[-1]])
		cells.reverse()
		var points: PackedVector3Array = PackedVector3Array([_from])
		for cell: Vector3i in cells.slice(1):
			points.append(Grid.middle(cell))
		points.append(_to)
		var kept: PackedVector3Array = PackedVector3Array()
		var at: int = 0
		while at < points.size() - 1:
			var reach: int = at + 1
			for further: int in range(points.size() - 1, at + 1, -1):
				if _line_open(points[at], points[further]):
					reach = further
					break
			kept.append(points[reach])
			at = reach
		path = kept
		state = State.FOUND

	## Whether every cell a straight line passes through is open.
	func _line_open(a: Vector3, b: Vector3) -> bool:
		var steps: int = ceili(a.distance_to(b) / (CELL * 0.34))
		for i: int in range(1, steps):
			var cell: Vector3i = Grid.cell_of(a.lerp(b, float(i) / steps))
			if cell != _start and cell != _goal and not _grid.open(cell, _radius, _exclude):
				return false
		return true

	func _push(cell: Vector3i, priority: float) -> void:
		_heap.append([priority, cell])
		var i: int = _heap.size() - 1
		while i > 0:
			var parent: int = (i - 1) / 2
			if float(_heap[parent][0]) <= priority:
				break
			_heap[i] = _heap[parent]
			_heap[parent] = [priority, cell]
			i = parent

	func _pop() -> Vector3i:
		var top: Vector3i = _heap[0][1]
		var last: Array = _heap.pop_back()
		if not _heap.is_empty():
			_heap[0] = last
			var i: int = 0
			while true:
				var left: int = i * 2 + 1
				var smallest: int = i
				if left < _heap.size() and float(_heap[left][0]) < float(_heap[smallest][0]):
					smallest = left
				if left + 1 < _heap.size() and float(_heap[left + 1][0]) < float(_heap[smallest][0]):
					smallest = left + 1
				if smallest == i:
					break
				var held: Array = _heap[i]
				_heap[i] = _heap[smallest]
				_heap[smallest] = held
				i = smallest
		return top


## The grid of a 3D world (made when first asked; a Terrain there forgets
## the cells of a chunk it builds again).
static func grid(world: World3D, tree: SceneTree) -> Grid:
	var found: Grid = _grids.get(world, null)
	if found == null:
		for old: Variant in _grids.keys():
			if not is_instance_valid(old):
				_grids.erase(old)
		found = Grid.new()
		found.world = weakref(world)
		_grids[world] = found
	if tree != null:
		for terrain: Node in tree.get_nodes_in_group(&"terrain_engine_terrains"):
			if terrain is Node3D and (terrain as Node3D).get_world_3d() == world and not found.hooked.has(terrain.get_instance_id()) and terrain.has_signal(&"chunk_built"):
				found.hooked[terrain.get_instance_id()] = true
				terrain.connect(&"chunk_built", _forget_chunk.bind(weakref(found), weakref(terrain)))
				if terrain.has_method(&"solid_at"):
					found.terrains.append(weakref(terrain))
	return found


static func _forget_chunk(chunk: Vector3i, held_grid: WeakRef, held_terrain: WeakRef) -> void:
	var found: Grid = held_grid.get_ref() as Grid
	var terrain: Node3D = held_terrain.get_ref() as Node3D
	if found == null or terrain == null:
		return
	var side: float = float(terrain.get(&"chunk_size")) * float(terrain.get(&"block_size"))
	var low: Vector3 = terrain.to_global(Vector3(chunk) * side)
	found.forget(low, low + Vector3.ONE * side)


## Whether a ball of `radius` can fly straight from `from` to `to` (a shape
## cast, past characters and moving bodies).
static func line_clear(world: World3D, from: Vector3, to: Vector3, radius: float, exclude: Array[RID]) -> bool:
	if from.distance_squared_to(to) < 0.0001:
		return true
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	var ball: SphereShape3D = SphereShape3D.new()
	ball.radius = radius
	query.shape = ball
	query.transform = Transform3D(Basis.IDENTITY, from)
	query.motion = to - from
	var skip: Array[RID] = exclude.duplicate()
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	for attempt: int in 8:
		query.exclude = skip
		var free: PackedFloat32Array = space.cast_motion(query)
		if free.is_empty() or free[0] >= 1.0:
			return true
		# Past a character or a moving body: look again without it.
		query.transform = Transform3D(Basis.IDENTITY, from + (to - from) * free[1])
		var info: Dictionary = space.get_rest_info(query)
		var collider: Object = instance_from_id(int(info.get("collider_id", 0))) if info.has("collider_id") else null
		if not (collider is AnimatableBody3D or collider is CharacterBody3D or collider is RigidBody3D):
			return false
		skip.append(info["rid"])
		query.transform = Transform3D(Basis.IDENTITY, from)
	return false


## Starts a search for a path from `from` to `to` (world space) for a ball
## of `radius`; step() it each physics frame.
static func search(world: World3D, tree: SceneTree, from: Vector3, to: Vector3, radius: float, exclude: Array[RID]) -> Search:
	return Search.new(grid(world, tree), from, to, radius, exclude)
