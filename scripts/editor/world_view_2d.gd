class_name WorldView2D
extends Control
## The 2D screen (Godot's 2D viewport): the game window's frame (its size from the
## project's Open window brick) with the scene's 2D nodes on it as the program draws
## them over the 3D: Text2D, Shape2D and Sprite2D, placed in their Spatial2D parents,
## seen through the first Camera2D (none: window pixels), as cb_gfx.c's 2D pass.
## Click one to select it (the Scene tree and Properties follow), drag it to move it
## (its position; Ctrl: steps of 10 px), saved to the file when the drag ends.
## The UI (Control, Label, Panel, Bar, Image) is drawn on top in window pixels (cameras
## don't move it); a UI node is picked first and dragged by its offset. The 2D / UI toggles
## hide either layer here (not in the game).

const Context = preload("res://scripts/editor/context.gd")

var context: Context = null
var window_size := Vector2(800, 450)
var _dragging := false
var _drag_from := Vector2.ZERO
var _drag_start := Vector2.ZERO
var _textures := {}  # Sprite2D paths -> Texture2D (or null: not found)
var show_2d := true
var show_ui := true
var _drag_field := "position"  # (a UI node: offset)
var _post: ColorRect = null  # the Environment's post effects over the game window's frame (PostFx)


func _init() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	clip_contents = true
	focus_mode = FOCUS_CLICK
	resized.connect(queue_redraw)
	_post = PostFx.make()
	_post.set_anchors_and_offsets_preset(PRESET_TOP_LEFT)
	add_child(_post)
	var bar := HBoxContainer.new()
	add_child(bar)
	bar.set_anchors_and_offsets_preset(PRESET_TOP_RIGHT)
	bar.grow_horizontal = GROW_DIRECTION_BEGIN
	bar.position.y = 2
	for spec in [["2D", "Show the 2D nodes (Shape2D, Sprite2D, Text2D)"], ["UI", "Show the UI (Control, Label, Panel, Bar, Image): drawn on top, in window pixels"]]:
		var cb := CheckBox.new()
		cb.text = spec[0]
		cb.button_pressed = true
		cb.tooltip_text = spec[1]
		cb.focus_mode = FOCUS_NONE
		cb.toggled.connect(func(on: bool) -> void:
			if spec[0] == "2D":
				show_2d = on
			else:
				show_ui = on
			queue_redraw())
		bar.add_child(cb)


func _ready() -> void:
	context.selection_changed.connect(func(_id: int) -> void: queue_redraw())


func _process(_delta: float) -> void:
	if _post.visible:
		PostFx.update_rect(_post)  # (the view may have moved with its panels)


## Reads the window's size from the project's Open window brick, and redraws.
func rebuild(project_dir: String) -> void:
	window_size = Vector2(800, 450)
	_textures.clear()
	if project_dir != "":
		for p in CBProject.list_scripts(project_dir):
			for n in CBProject.read_script(p).get("nodes", []):
				if n.get("type", "") == "window":
					var w := WorldValues.number(str(n.args.get("width", {}).get("value", "800")), 800)
					var h := WorldValues.number(str(n.args.get("height", {}).get("value", "450")), 450)
					window_size = Vector2(maxf(w, 16), maxf(h, 16))
	queue_redraw()


## The game window's rectangle in this view, and its scale.
func _frame() -> Array:
	var margin := 24.0
	var avail := size - Vector2(margin * 2, margin * 2)
	var k := minf(avail.x / window_size.x, avail.y / window_size.y)
	k = maxf(k, 0.05)
	var box := window_size * k
	return [Rect2((size - box) / 2.0, box), k]


func _drawn() -> Array:
	if not show_2d:
		return []
	return context.world_flat.get("objects", []).filter(func(o):
		var c := str(o.get("class", ""))
		return CBTypes.is_subclass(c, "Text2D") or CBTypes.is_subclass(c, "Shape2D") or CBTypes.is_subclass(c, "Sprite2D"))


func _ui_nodes() -> Array:
	if not show_ui:
		return []
	return context.world_flat.get("objects", []).filter(func(o): return WorldValues.is_ui(o))


## The UI, on top (as the game draws it at the end of each frame); hidden ones faint.
func _draw_ui(fr: Rect2, k: float, ids: Dictionary, sel: int) -> void:
	var font := get_theme_default_font()
	for o in _ui_nodes():
		var box := WorldValues.ui_box(o, ids, window_size)
		var r: Rect2 = box.rect
		var vr := Rect2(fr.position + r.position * k, r.size * k)
		var fade := 1.0 if bool(box.shown) else 0.3
		var c := str(o.get("class", ""))
		if CBTypes.is_subclass(c, "Panel"):
			var col := WorldValues.color(WorldValues.field(o, "color"))
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(col, col.a * fade)
			sb.set_corner_radius_all(int(WorldValues.number(WorldValues.field(o, "radius"), 0) * k))
			var bw := int(WorldValues.number(WorldValues.field(o, "border"), 0))
			if bw > 0 and WorldValues.field(o, "border_color") != "":
				sb.set_border_width_all(maxi(1, int(bw * k)))
				var bc := WorldValues.color(WorldValues.field(o, "border_color"))
				sb.border_color = Color(bc, bc.a * fade)
			draw_style_box(sb, vr)
		elif CBTypes.is_subclass(c, "Label"):
			var px := maxi(1, int(WorldValues.number(WorldValues.field(o, "font_size"), 20) * k))
			var col := WorldValues.color(WorldValues.field(o, "color"))
			var text := WorldValues.field(o, "text")
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
			var x := vr.position.x
			match WorldValues.field(o, "align"):
				"center": x += (vr.size.x - w) / 2.0
				"right": x += vr.size.x - w
			draw_string(font, Vector2(x, vr.position.y + px * 0.85), text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(col, col.a * fade))
		elif CBTypes.is_subclass(c, "Bar"):
			var mx := WorldValues.number(WorldValues.field(o, "max"), 100)
			var t := clampf(WorldValues.number(WorldValues.field(o, "value"), 50) / mx, 0.0, 1.0) if mx > 0 else 0.0
			var back := WorldValues.color(WorldValues.field(o, "back"))
			var fill := WorldValues.color(WorldValues.field(o, "color"))
			draw_rect(vr, Color(back, back.a * fade))
			draw_rect(Rect2(vr.position, Vector2(vr.size.x * t, vr.size.y)), Color(fill, fill.a * fade))
		elif CBTypes.is_subclass(c, "Button"):
			var off := WorldValues.field(o, "disabled") == "true"
			var col := WorldValues.color(WorldValues.field(o, "color"))
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(col, col.a * fade * (0.5 if off else 1.0))
			sb.set_corner_radius_all(int(WorldValues.number(WorldValues.field(o, "radius"), 0) * k))
			var bw := int(WorldValues.number(WorldValues.field(o, "border"), 0))
			if bw > 0 and WorldValues.field(o, "border_color") != "":
				sb.set_border_width_all(maxi(1, int(bw * k)))
				sb.border_color = WorldValues.color(WorldValues.field(o, "border_color"))
			draw_style_box(sb, vr)
			var px := maxi(1, int(WorldValues.number(WorldValues.field(o, "font_size"), 18) * k))
			var text := WorldValues.field(o, "text")
			var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px)
			var tc := WorldValues.color(WorldValues.field(o, "text_color"))
			draw_string(font, vr.position + Vector2((vr.size.x - ts.x) / 2.0, (vr.size.y - ts.y) / 2.0 + px * 0.85), text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(tc, tc.a * fade * (0.5 if off else 1.0)))
		elif CBTypes.is_subclass(c, "Image"):
			var tex := _texture(WorldValues.field(o, "texture"))
			var tint := WorldValues.color(WorldValues.field(o, "color"))
			if tex != null:
				draw_texture_rect(tex, vr, false, Color(tint, tint.a * fade))
			else:
				draw_rect(vr, Color(0.55, 0.94, 0.6, 0.5 * fade), false, 1.0)
		else:  # a plain Control: its box, faintly (it draws nothing in the game)
			draw_rect(vr, Color(0.55, 0.94, 0.6, 0.25 * fade), false, 1.0)
		if int(o.id) == sel:
			draw_rect(vr.grow(3), Color(1.0, 0.65, 0.2), false, 1.5)


## The view of the 2D: the first Camera2D's place and zoom ({} without one).
func _camera(ids: Dictionary) -> Dictionary:
	for o in context.world_flat.get("objects", []):
		if CBTypes.is_subclass(str(o.get("class", "")), "Camera2D"):
			var zoom := WorldValues.number(WorldValues.field(o, "zoom"), 1)
			return {"at": WorldValues.place_2d(o, ids).at, "zoom": zoom if zoom > 0 else 1.0}
	return {}


## A 2D node in the game window: {"at" (window pixels), "rot", "k" (its scale on screen), "rect"}.
func _placed(o: Dictionary, ids: Dictionary, cam: Dictionary) -> Dictionary:
	var p := WorldValues.place_2d(o, ids)
	var at: Vector2 = p.at
	var zoom := 1.0
	if not cam.is_empty():
		zoom = cam.zoom
		at = (at - (cam.at as Vector2)) * zoom + window_size / 2.0
	var sc: Vector2 = (p.scale as Vector2) * zoom
	var c := str(o.get("class", ""))
	var r := Rect2(at, Vector2(8, 8))
	if CBTypes.is_subclass(c, "Text2D"):
		var px := WorldValues.number(WorldValues.field(o, "size"), 20) * sc.y
		var w := get_theme_default_font().get_string_size(WorldValues.field(o, "text"), HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(1, int(px))).x
		r = Rect2(at, Vector2(maxf(w, 8), maxf(px, 8)))
	elif CBTypes.is_subclass(c, "Shape2D"):
		var s := WorldValues.vec2(WorldValues.field(o, "size")) * sc
		r = Rect2(at - s / 2.0, s)
	elif CBTypes.is_subclass(c, "Sprite2D"):
		var tex := _texture(WorldValues.field(o, "texture"))
		var s := (sprite_cell(o, tex).size if tex != null else Vector2(32, 32)) * sc
		r = Rect2(at - s / 2.0, s)
	return {"at": at, "rot": p.rot, "k": sc, "rect": r}


## A Sprite2D's cell of its texture: Columns x Rows cells, the Frame-th along the rows
## (as cb_gfx.c draws it).
static func sprite_cell(o: Dictionary, tex: Texture2D) -> Rect2:
	var cols := maxi(1, int(WorldValues.number(WorldValues.field(o, "columns"), 1)))
	var rows := maxi(1, int(WorldValues.number(WorldValues.field(o, "rows"), 1)))
	var cells := cols * rows
	var fr := posmod(int(WorldValues.number(WorldValues.field(o, "frame"), 0)), cells)
	var cell := tex.get_size() / Vector2(cols, rows)
	return Rect2(Vector2(fr % cols, int(fr / float(cols))) * cell, cell)


func _texture(path: String) -> Texture2D:
	if path == "" or context.project_dir == "":
		return null
	if not _textures.has(path):
		var img := Image.load_from_file(context.project_dir.path_join(path)) if FileAccess.file_exists(context.project_dir.path_join(path)) else null
		_textures[path] = ImageTexture.create_from_image(img) if img != null else null
	return _textures[path]


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.13, 0.15))
	var f := _frame()
	var fr: Rect2 = f[0]
	var k: float = f[1]
	var ids := WorldValues.by_id(context.world_flat)
	var look := WorldView3D.lighting(context.world_flat)
	var sky: String = look.sky
	_post.position = fr.position
	_post.size = fr.size
	PostFx.apply(_post, look)
	# The game window's background as the game draws it: the scene's Environment's sky, or
	# (no Environment) the runtime's neutral grey.
	draw_rect(fr, WorldValues.color(sky))
	if str(look.get("horizon", "")) != "":  # the game's gradient sky: sky at the top, horizon at the bottom
		var top := WorldValues.color(sky)
		var bottom := WorldValues.color(str(look.horizon))
		draw_polygon(PackedVector2Array([fr.position, fr.position + Vector2(fr.size.x, 0), fr.end, fr.position + Vector2(0, fr.size.y)]), PackedColorArray([top, top, bottom, bottom]))
	draw_rect(fr, Color(0.8, 0.8, 0.85, 0.8), false, 1.0)
	var font := get_theme_default_font()
	draw_string(font, fr.position + Vector2(0, -6), "Game window %d x %d (the 3D is drawn here, the 2D on top, the UI over both)" % [int(window_size.x), int(window_size.y)], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.6))
	var cam := _camera(ids)
	var sel := int(context.world_object.get("id", 0))
	for o in _drawn():
		var pl := _placed(o, ids, cam)
		var col := WorldValues.color(WorldValues.field(o, "color"))
		if WorldValues.field(o, "visible") == "false":
			col.a = 0.35
		var at: Vector2 = fr.position + (pl.at as Vector2) * k
		var r: Rect2 = pl.rect
		var view_r := Rect2(fr.position + r.position * k, r.size * k)
		var c := str(o.get("class", ""))
		draw_set_transform(at, deg_to_rad(float(pl.rot)), Vector2.ONE)
		if CBTypes.is_subclass(c, "Text2D"):
			var px := maxi(1, int(r.size.y * k))
			draw_string(font, Vector2(0, px * 0.85), WorldValues.field(o, "text"), HORIZONTAL_ALIGNMENT_LEFT, -1, px, col)
		elif CBTypes.is_subclass(c, "Shape2D"):
			if WorldValues.field(o, "shape") == "Circle":
				draw_circle(Vector2.ZERO, view_r.size.x / 2.0, col)
			else:
				draw_rect(Rect2(-view_r.size / 2.0, view_r.size), col)
		elif CBTypes.is_subclass(c, "Sprite2D"):
			var tex := _texture(WorldValues.field(o, "texture"))
			if tex != null:
				draw_texture_rect_region(tex, Rect2(-view_r.size / 2.0, view_r.size), sprite_cell(o, tex), col)
			else:
				draw_rect(Rect2(-view_r.size / 2.0, view_r.size), Color(col, 0.4), false, 1.0)
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
		if int(o.id) == sel:
			draw_rect(view_r.grow(3), Color(1.0, 0.65, 0.2), false, 1.5)
	_draw_ui(fr, k, ids, sel)


## The 2D node under a point of the view ({}: none; the last drawn, on top, wins).
func label_at(at: Vector2) -> Dictionary:
	var f := _frame()
	var fr: Rect2 = f[0]
	var k: float = f[1]
	var ids := WorldValues.by_id(context.world_flat)
	var cam := _camera(ids)
	var found := {}
	for o in _drawn():
		var r: Rect2 = _placed(o, ids, cam).rect
		if Rect2(fr.position + r.position * k, r.size * k).grow(3).has_point(at):
			found = o
	for o in _ui_nodes():  # (on top: a UI node under the pointer wins; the innermost, drawn last)
		var r: Rect2 = WorldValues.ui_box(o, ids, window_size).rect
		if Rect2(fr.position + r.position * k, r.size * k).grow(2).has_point(at):
			found = o
	return found


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			grab_focus()
			var o := label_at(mb.position)
			context.show_world_object(context.raw_of(o))
			_dragging = not o.is_empty() and int(o.get("owner", 0)) == 0  # (inside a copy: edit its scene)
			_drag_from = mb.position
			_drag_field = "offset" if WorldValues.is_ui(o) else "position"
			var holder: Dictionary = WorldValues.by_id(context.world_flat).get(int(o.get("parent", 0)), {})
			if WorldValues.is_ui(o) and (CBTypes.is_subclass(str(holder.get("class", "")), "VBox") or CBTypes.is_subclass(str(holder.get("class", "")), "HBox")):
				_dragging = false  # (its VBox / HBox places it: reorder it in the Scene tree instead)
			_drag_start = WorldValues.vec2(WorldValues.field(o, _drag_field)) if _dragging else Vector2.ZERO
		elif _dragging:
			_dragging = false
			if context.on_world_changed.is_valid():
				context.on_world_changed.call("Move %s" % str(context.world_object.get("name", "")))
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging and not context.world_object.is_empty():
		var k: float = _frame()[1]
		var p := _drag_start + (mm.position - _drag_from) / k
		if mm.ctrl_pressed:
			p = p.snapped(Vector2(10, 10))
		context.world_object.fields[_drag_field] = "%d, %d" % [int(round(p.x)), int(round(p.y))]
		context.world_live.emit(int(context.world_object.get("id", 0)), _drag_field, str(context.world_object.fields[_drag_field]))
		context.refresh_flat()
		queue_redraw()
