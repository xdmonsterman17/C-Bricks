class_name WorldValues
extends RefCounted
## Reading a scene's objects the way the program will: a field's value is
## the file's, else its class's starting value; colors by name or #rrggbb (as
## cb_color() in cb_gfx.c); where a Spatial3D is (relative to its parent Spatial3D,
## rotation Y then X then Z, then its scale, as the runtime draws it).

const NAMED := {
	"LIGHTGRAY": Color8(200, 200, 200), "GRAY": Color8(130, 130, 130), "DARKGRAY": Color8(80, 80, 80),
	"YELLOW": Color8(253, 249, 0), "GOLD": Color8(255, 203, 0), "ORANGE": Color8(255, 161, 0),
	"PINK": Color8(255, 109, 194), "RED": Color8(230, 41, 55), "MAROON": Color8(190, 33, 55),
	"GREEN": Color8(0, 228, 48), "LIME": Color8(0, 158, 47), "DARKGREEN": Color8(0, 117, 44),
	"SKYBLUE": Color8(102, 191, 255), "BLUE": Color8(0, 121, 241), "DARKBLUE": Color8(0, 82, 172),
	"PURPLE": Color8(200, 122, 255), "VIOLET": Color8(135, 60, 190), "DARKPURPLE": Color8(112, 31, 126),
	"BEIGE": Color8(211, 176, 131), "BROWN": Color8(127, 106, 79), "DARKBROWN": Color8(76, 63, 47),
	"WHITE": Color8(255, 255, 255), "BLACK": Color8(0, 0, 0), "BLANK": Color8(0, 0, 0, 0),
	"MAGENTA": Color8(255, 0, 255), "RAYWHITE": Color8(245, 245, 245),
}


## The text of a field: the file's value, else the class's starting value ("" if none).
static func field(o: Dictionary, name: String) -> String:
	if o.get("fields", {}).has(name):
		return str(o.fields[name])
	for c in CBTypes.lineage(str(o.get("class", ""))):
		for f in CBTypes.BUILTIN.get(c, {}).get("fields", []):
			if f[0] == name:
				return str(f[2])
	return ""


static func number(text: String, otherwise := 0.0) -> float:
	var t := text.strip_edges()
	return t.to_float() if t.is_valid_float() or t.is_valid_int() else otherwise


## "x, y, z" (one number: all three); parts that aren't numbers count as 0.
static func vec(text: String) -> Vector3:
	var s := text.strip_edges().trim_prefix("(").trim_suffix(")")
	var parts := s.split(",")
	if parts.size() == 1 and s != "":
		var v := number(parts[0])
		return Vector3(v, v, v)
	var out := Vector3.ZERO
	for i in mini(3, parts.size()):
		out[i] = number(parts[i])
	return out


static func vec_text(v: Vector3) -> String:
	return "%s, %s, %s" % [_num(v.x), _num(v.y), _num(v.z)]


static func _num(f: float) -> String:
	var r := snappedf(f, 0.001)
	return str(int(r)) if is_equal_approx(r, roundf(r)) else String.num(r, 3)


static func color(text: String) -> Color:
	var t := text.strip_edges()
	if t.begins_with("#"):
		return Color.html(t) if Color.html_is_valid(t) else Color.WHITE
	return NAMED.get(t.to_upper(), Color.WHITE)


static func by_id(world: Dictionary) -> Dictionary:
	var out := {}
	for o in world.get("objects", []):
		out[int(o.id)] = o
	return out


static func is_placed(o: Dictionary) -> bool:
	return CBTypes.is_subclass(str(o.get("class", "")), "Spatial3D")


## An object's own placement (a Spatial3D: position, rotation, scale; others: none).
static func local(o: Dictionary) -> Transform3D:
	if not is_placed(o):
		return Transform3D.IDENTITY
	var r := vec(field(o, "rotation")) * (PI / 180.0)
	return Transform3D(Basis.from_euler(r, EULER_ORDER_YXZ).scaled_local(vec(field(o, "scale"))), vec(field(o, "position")))


## "x, y" as a Vector2 (one number: both).
static func vec2(text: String) -> Vector2:
	var v := vec(text)
	var parts := text.strip_edges().trim_prefix("(").trim_suffix(")").split(",")
	return Vector2(v.x, v.x if parts.size() == 1 else v.y)


## Where a Spatial2D is in the window (its Spatial2D parents first): {"at", "rot" (degrees), "scale"}.
static func place_2d(o: Dictionary, ids: Dictionary) -> Dictionary:
	var chain := [o]
	var p := int(o.get("parent", 0))
	var guard := 0
	while p != 0 and ids.has(p) and guard < 64:
		chain.push_front(ids[p])
		p = int(ids[p].get("parent", 0))
		guard += 1
	var at := Vector2.ZERO
	var rot := 0.0
	var sc := Vector2.ONE
	for x in chain:
		if not CBTypes.is_subclass(str(x.get("class", "")), "Spatial2D"):
			continue
		var pos := vec2(field(x, "position")) * sc
		at += pos.rotated(deg_to_rad(rot))
		rot += number(field(x, "rotation"))
		sc *= vec2(field(x, "scale"))
	return {"at": at, "rot": rot, "scale": sc}


## Where an object is in the world: its parents' placements, then its own.
static func world_transform(o: Dictionary, ids: Dictionary) -> Transform3D:
	var t := local(o)
	var p := int(o.get("parent", 0))
	var guard := 0
	while p != 0 and ids.has(p) and guard < 64:
		t = local(ids[p]) * t
		p = int(ids[p].get("parent", 0))
		guard += 1
	return t


## The parents' placement only (to turn a world position back into the object's own).
static func parent_transform(o: Dictionary, ids: Dictionary) -> Transform3D:
	var p := int(o.get("parent", 0))
	if p == 0 or not ids.has(p):
		return Transform3D.IDENTITY
	return world_transform(ids[p], ids)


## A scene with its copies of other scenes opened out (for drawing and picking): a copy's
## root takes the copy's id, name, parent and overrides (fields over the scene's own);
## the objects under it get new ids and "owner": the copy's id (picking them picks the copy).
## Scenes inside themselves stop at the loop. `dir`: the project folder.
static func expand(scene: Dictionary, dir: String) -> Dictionary:
	var out := {"objects": []}
	var next := [1000000]
	_expand_into(out.objects, scene.get("objects", []), dir, {}, 0, [], next)
	return out


static func _expand_into(into: Array, objects: Array, dir: String, remap: Dictionary, owner: int, stack: Array, next: Array) -> void:
	for o in objects:
		var id := int(o.id)
		if not remap.has(id):
			remap[id] = id if owner == 0 else _fresh(next)
	for o in objects:
		var x: Dictionary = o.duplicate(true)
		var pid := int(o.get("parent", 0))
		x.id = remap[int(o.id)]
		x.parent = remap.get(pid, pid) if pid != 0 else int(remap.get(0, 0))
		if owner != 0:
			x["owner"] = owner
		if not o.has("scene"):
			into.append(x)
			continue
		var rel := str(o.scene)
		var inner := CBProject.read_scene(dir.path_join(rel)) if dir != "" and rel not in stack else {}
		var roots: Array = inner.get("objects", []).filter(func(y): return int(y.get("parent", 0)) == 0 and not CBTypes.is_script_object(y))
		if roots.size() != 1:
			x["class"] = "Spatial3D"  # (a broken copy: drawn as nothing, still listed)
			into.append(x)
			continue
		# The inner scene: its root is this copy (its id, name, parent, overrides).
		var sub_remap := {int(roots[0].id): x.id, 0: x.id}
		var sub := []
		_expand_into(sub, inner.objects, dir, sub_remap, owner if owner != 0 else x.id, stack + [rel], next)
		for y in sub:
			if int(y.id) == int(x.id):
				y.name = x.get("name", y.get("name", ""))
				y.parent = x.parent
				var f: Dictionary = y.get("fields", {})
				f.merge(x.get("fields", {}), true)
				y.fields = f
				y.groups = x.get("groups", [])
				y.meta = x.get("meta", {})
				y["scene"] = rel
				if owner == 0:
					y.erase("owner")
		into.append_array(sub)


static func _fresh(next: Array) -> int:
	next[0] += 1
	return int(next[0])


## A UI node's box in the game window (pixels), as cb_gfx.c's cb_ui_box: its anchor's point
## of its parent Control's box (none: the window), `offset` from there; "full" fills it,
## inset by offset. {"rect": Rect2, "shown": false when it or a Control above is hidden}.
static func ui_box(o: Dictionary, ids: Dictionary, window: Vector2) -> Dictionary:
	var parent := Rect2(Vector2.ZERO, window)
	var shown := field(o, "visible") != "false"
	var up: Dictionary = ids.get(int(o.get("parent", 0)), {})
	while not up.is_empty() and not CBTypes.is_subclass(str(up.get("class", "")), "Control"):
		up = ids.get(int(up.get("parent", 0)), {})
	if not up.is_empty():
		var pb := ui_box(up, ids, window)
		parent = pb.rect
		shown = shown and bool(pb.shown)
	var direct: Dictionary = ids.get(int(o.get("parent", 0)), {})
	if not up.is_empty() and direct == up and (CBTypes.is_subclass(str(up.get("class", "")), "VBox") or CBTypes.is_subclass(str(up.get("class", "")), "HBox")):
		return {"rect": _box_slot(up, parent, o, ids), "shown": shown}
	var a := field(o, "anchor")
	var off := vec2(field(o, "offset"))
	if a == "full":
		return {"rect": Rect2(parent.position + off, parent.size - off * 2.0), "shown": shown}
	var ax := 1.0 if a.contains("right") else (0.5 if a in ["top", "center", "bottom"] else 0.0)
	var ay := 1.0 if a.begins_with("bottom") else (0.5 if a in ["left", "center", "right"] else 0.0)
	var sz := vec2(field(o, "size"))
	var at := parent.position + Vector2(ax, ay) * parent.size - Vector2(ax, ay) * sz + off
	return {"rect": Rect2(at, sz), "shown": shown}


## A VBox / HBox child's place, as cb_gfx.c's cb_ui_slot: the Controls directly in the box,
## in order, their own size (fill: stretched across), separation apart, padding inside;
## hidden ones take no room.
static func _box_slot(box: Dictionary, b: Rect2, child: Dictionary, ids: Dictionary) -> Rect2:
	var vertical := CBTypes.is_subclass(str(box.get("class", "")), "VBox")
	var sep := number(field(box, "separation"), 4)
	var pad := number(field(box, "padding"), 0)
	var fill := field(box, "fill") == "true"
	var at := pad
	for k in ids.values():
		if int(k.get("parent", 0)) != int(box.id) or not is_ui(k):
			continue
		if int(k.id) == int(child.id):
			break
		if field(k, "visible") != "false":
			var ks := vec2(field(k, "size"))
			at += (ks.y if vertical else ks.x) + sep
	var sz := vec2(field(child, "size"))
	if vertical:
		return Rect2(b.position + Vector2(pad, at), Vector2(b.size.x - 2.0 * pad if fill else sz.x, sz.y))
	return Rect2(b.position + Vector2(at, pad), Vector2(sz.x, b.size.y - 2.0 * pad if fill else sz.y))


static func is_ui(o: Dictionary) -> bool:
	return CBTypes.is_subclass(str(o.get("class", "")), "Control")
