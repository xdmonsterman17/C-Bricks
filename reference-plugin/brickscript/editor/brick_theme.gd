@tool
extends RefCounted

## Colors and icons for the Brickscript editor, taken from the editor's
## GDScript syntax highlighting so blocks follow the user's theme: events use
## the function-definition color, math the number color, and so on.
## Outside the editor (headless tests) it falls back to Godot's defaults.

const HIGHLIGHTING: String = "text_editor/theme/highlighting/"
## Palette category -> [syntax highlighting setting, fallback color].
const CATEGORY_COLORS: Dictionary[String, Array] = {
	"events": ["gdscript/function_definition_color", Color(0.4, 0.9, 1.0)],
	"flow": ["control_flow_keyword_color", Color(1.0, 0.55, 0.8)],
	"lists": ["base_type_color", Color(0.26, 1.0, 0.76)],
	"output": ["gdscript/global_function_color", Color(0.64, 0.64, 0.96)],
	"variables": ["member_variable_color", Color(0.736, 0.88, 1.0)],
	"math": ["number_color", Color(0.63, 1.0, 0.88)],
	"network": ["gdscript/annotation_color", Color(1.0, 0.69, 0.45)],
	"nodes": ["engine_type_color", Color(0.56, 1.0, 0.86)],
	"signals": ["gdscript/node_reference_color", Color(1.0, 0.85, 0.5)],
	"physics": ["gdscript/string_name_color", Color(1.0, 0.7, 0.7)],
	"camera": ["gdscript/node_path_color", Color(0.72, 0.8, 1.0)],
	"animation": ["string_color", Color(1.0, 0.93, 0.63)],
	"character": ["gdscript/function_definition_color", Color(0.55, 0.85, 1.0)],
	"ai": ["user_type_color", Color(0.78, 1.0, 0.6)],
	"mesh": ["symbol_color", Color(0.85, 0.75, 1.0)],
	"terrain": ["comment_color", Color(0.6, 0.85, 0.5)],
	"functions": ["keyword_color", Color(1.0, 0.44, 0.52)],
}
const CATEGORY_ORDER: PackedStringArray = ["events", "signals", "network", "flow", "output", "variables", "functions", "nodes", "physics", "character", "ai", "camera", "animation", "mesh", "terrain", "lists", "math"]
const CATEGORY_TITLES: Dictionary[String, String] = {
	"events": "Events", "network": "Network", "flow": "Flow", "output": "Output", "variables": "Variables", "functions": "Functions", "nodes": "Nodes", "signals": "Signals", "physics": "Physics", "character": "Character", "ai": "AI", "camera": "Camera", "animation": "Animation", "mesh": "Mesh", "terrain": "Terrain", "lists": "Lists", "math": "Math",
}
const FALLBACK_BACKGROUND: Color = Color(0.103, 0.103, 0.103)
const FALLBACK_TEXT: Color = Color(1, 1, 1, 0.75)
const FALLBACK_ACCENT: Color = Color(0.44, 0.73, 0.98)

## Per variable kind: [editor icon, name, one-line hint]. Indexed by
## BrickscriptVariable.Kind.
const KIND_INFO: Array[Array] = [
	["MemberConstant", "Constant", "The same for every node. Blocks can't change it."],
	["MemberAnnotation", "Export", "Set per node in the Inspector. Blocks can only read it."],
	["MemberProperty", "Shared", "Changed by blocks, shared by every chain of this node."],
	["LocalVariable", "Chain", "Only inside its own chain; starts over each time the chain runs."],
]
const VALUE_TYPE_NAMES: Dictionary[int, String] = {1: "Number", 4: "Whole", 2: "Text"}
const VALUE_TYPE_HINTS: Dictionary[int, String] = {
	1: "A number with decimals (float), e.g. 2.5",
	4: "A whole number (int), e.g. 3. Decimals written into it are rounded.",
	2: "Text (String)",
}

var _settings: Object = null
var _theme: Theme = null


func _init() -> void:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var editor: Object = Engine.get_singleton(&"EditorInterface")
		_settings = editor.call(&"get_editor_settings")
		_theme = editor.call(&"get_editor_theme")


func category_color(category: String) -> Color:
	var entry: Array = CATEGORY_COLORS.get(category, ["", FALLBACK_TEXT])
	return _setting(HIGHLIGHTING + entry[0], entry[1])


## Block fill: the category color mixed into the code editor background, so
## light and dark themes both stay readable; outlined in the full color.
func block_style(category: String, round: bool) -> StyleBoxFlat:
	var color: Color = category_color(category)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = background().lerp(color, 0.28)
	style.border_color = color
	style.set_border_width_all(2)
	style.set_corner_radius_all(12 if round else 4)
	style.content_margin_left = 10 if round else 8
	style.content_margin_right = 10 if round else 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style


## The selected block: same fill, thicker outline in the editor's accent color.
func selected_block_style(category: String, round: bool) -> StyleBoxFlat:
	var style: StyleBoxFlat = block_style(category, round)
	style.border_color = accent_color()
	style.set_border_width_all(3)
	style.shadow_color = Color(accent_color(), 0.35)
	style.shadow_size = 4
	return style


## Outline around each area of the panel (palette, canvas, properties, ...).
func frame_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = background().lerp(Color.BLACK, 0.12)
	style.border_color = Color(text_color(), 0.22)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	return style


## Minor and major grid lines on the canvas.
func grid_colors() -> Array[Color]:
	return [Color(text_color(), 0.05), Color(text_color(), 0.11)]


func accent_color() -> Color:
	if _settings != null and _settings.call(&"has_setting", "interface/theme/accent_color"):
		var value: Variant = _settings.call(&"get_setting", "interface/theme/accent_color")
		if value is Color:
			return value
	return FALLBACK_ACCENT


func background() -> Color:
	return _setting(HIGHLIGHTING + "background_color", FALLBACK_BACKGROUND)


func text_color() -> Color:
	return _setting(HIGHLIGHTING + "text_color", FALLBACK_TEXT)


## Text on the canvas bricks: the editor's text color, fully opaque and a
## little brighter, so it stands out on the tinted brick fills.
func brick_text_color() -> Color:
	return Color(text_color(), 1.0).lerp(Color.WHITE, 0.3)


## An editor icon by name, or null outside the editor.
func icon(icon_name: StringName) -> Texture2D:
	if _theme == null or not _theme.has_icon(icon_name, &"EditorIcons"):
		return null
	return _theme.get_icon(icon_name, &"EditorIcons")


func kind_icon(kind: int) -> Texture2D:
	return icon(StringName(KIND_INFO[kind][0]))


func kind_name(kind: int) -> String:
	return KIND_INFO[kind][1]


func kind_hint(kind: int) -> String:
	return KIND_INFO[kind][2]


func _setting(path: String, fallback: Color) -> Color:
	if _settings != null and _settings.call(&"has_setting", path):
		var value: Variant = _settings.call(&"get_setting", path)
		if value is Color:
			return value
	return fallback
