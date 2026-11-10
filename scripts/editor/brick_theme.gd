extends RefCounted
## Colors, styles and icons for the C-Bricks editor, after Brickscript's
## brick_theme.gd. Brickscript takes its colors from the Godot editor's syntax
## highlighting; an exported app has no editor, so this uses the same colors
## Brickscript falls back to, and builds an app-wide Theme that looks like the
## Godot editor's dark theme.

## Palette category -> color (Brickscript's fallbacks for the matching category).
const CATEGORY_COLORS: Dictionary = {
	"events": Color(0.4, 0.9, 1.0),
	"flow": Color(1.0, 0.55, 0.8),
	"output": Color(0.64, 0.64, 0.96),
	"input": Color(1.0, 0.76, 0.45),
	"variables": Color(0.736, 0.88, 1.0),
	"functions": Color(1.0, 0.44, 0.52),
	"logic": Color(1.0, 0.85, 0.5),
	"math": Color(0.63, 1.0, 0.88),
	"text": Color(1.0, 0.93, 0.63),
	"data": Color(0.26, 1.0, 0.76),
	"system": Color(0.72, 0.8, 1.0),
	"graphics": Color(0.78, 1.0, 0.6),
	"3d": Color(1.0, 0.8, 0.45),
	"objects": Color(1.0, 0.67, 0.57),
	"network": Color(0.55, 0.85, 1.0),
	"ui": Color(0.56, 0.94, 0.59),
	"program": Color(0.56, 1.0, 0.86),
	"debug": Color(1.0, 0.7, 0.7),
	"advanced": Color(0.85, 0.75, 1.0),
}
const CATEGORY_ORDER: PackedStringArray = ["events", "flow", "output", "input", "variables", "functions", "objects", "ui", "network", "logic", "math", "text", "data", "program", "system", "graphics", "3d", "debug", "advanced"]
## Short names for the palette's category buttons (the list's headers use the full ones).
const CATEGORY_SHORT: Dictionary = {"output": "In / Out", "data": "Data", "debug": "Debug"}
const CATEGORY_TITLES: Dictionary = {
	"events": "Events", "flow": "Flow", "output": "Input / Output", "input": "User Input", "variables": "Variables",
	"functions": "Functions", "objects": "Objects", "ui": "UI", "network": "Network", "logic": "Logic", "math": "Math", "text": "Text", "data": "Lists, Maps & Records", "system": "System", "graphics": "Graphics", "3d": "3D", "program": "Program", "debug": "Debug / Testing", "advanced": "Advanced",
}

## The code editor background, text and accent of Godot's default editor theme.
const BACKGROUND: Color = Color(0.114, 0.133, 0.161)
const TEXT: Color = Color(0.804, 0.812, 0.824)
const ACCENT: Color = Color(0.44, 0.73, 0.98)
## Editor chrome around the areas.
const BASE: Color = Color(0.129, 0.149, 0.18)
const DARK: Color = Color(0.094, 0.11, 0.133)
const SERVER_COLOR: Color = Color(1.0, 0.62, 0.3)
const LOCAL_COLOR: Color = Color(0.55, 0.82, 1.0)
const ERROR_COLOR: Color = Color(1.0, 0.47, 0.42)
const WARNING_COLOR: Color = Color(1.0, 0.87, 0.4)
const SUCCESS_COLOR: Color = Color(0.45, 0.95, 0.5)
## A script's colour by where it runs (user, 2026-11-07 / 11-08): Server (a Script) orange,
## Client (a LocalScript) blue, Shared (a ModuleScript) purple. Bright for names (the Scene
## tree, the canvas's label); script_tint() darkens it into the canvas's background.
const SIDE_COLORS := {"Server": Color("ffa64d"), "Client": Color("6fa8ff"), "Shared": Color("c58cff")}
const SIDE_TYPES := {"Server": "Script", "Client": "LocalScript", "Shared": "ModuleScript"}
const SIDE_WHERE := {"Server": "runs on the server", "Client": "runs on players' machines", "Shared": "runs on both: the server and players' machines"}


static func side_color(side: String) -> Color:
	return SIDE_COLORS.get(side, SIDE_COLORS["Shared"])


## The canvas's background for a script of this side: the usual dark grey, tinted.
func script_tint(side: String) -> Color:
	return BACKGROUND.lerp(side_color(side), 0.14).darkened(0.12)

var _icons: Dictionary = {}


func category_color(category: String) -> Color:
	return CATEGORY_COLORS.get(category, Color(TEXT, 0.75))


func background() -> Color:
	return BACKGROUND


func text_color() -> Color:
	return TEXT


func accent_color() -> Color:
	return ACCENT


## Text on the canvas bricks: a little brighter than the text color.
func brick_text_color() -> Color:
	return Color(TEXT, 1.0).lerp(Color.WHITE, 0.3)


## Outline around each area of the window (palette, canvas, properties, ...).
func frame_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = BACKGROUND.lerp(Color.BLACK, 0.12)
	style.border_color = Color(TEXT, 0.22)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	return style


func grid_colors() -> Array[Color]:
	return [Color(TEXT, 0.05), Color(TEXT, 0.11)]


## A bundled icon by name (res://icons/<name>.svg), or null.
func icon(icon_name: String) -> Texture2D:
	if _icons.has(icon_name):
		return _icons[icon_name]
	var path: String = "res://icons/%s.svg" % icon_name
	var tex: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
	_icons[icon_name] = tex
	return tex


static func flat_box(color: Color, radius: int = 3, margin: float = 4.0) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin + 2.0
	style.content_margin_right = margin + 2.0
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style


## The window's look: Godot's dark editor theme, approximated.
static func make_app_theme() -> Theme:
	var t: Theme = Theme.new()
	t.default_font_size = 13
	var field: StyleBoxFlat = flat_box(DARK, 3, 3.0)
	field.border_color = Color(TEXT, 0.12)
	field.set_border_width_all(1)
	var field_focus: StyleBoxFlat = field.duplicate()
	field_focus.border_color = ACCENT
	var button: StyleBoxFlat = flat_box(Color(0.2, 0.23, 0.28), 3, 3.0)
	var button_hover: StyleBoxFlat = flat_box(Color(0.25, 0.28, 0.34), 3, 3.0)
	var button_pressed: StyleBoxFlat = flat_box(Color(ACCENT, 0.3), 3, 3.0)
	var button_disabled: StyleBoxFlat = flat_box(Color(0.17, 0.19, 0.23), 3, 3.0)
	var focus: StyleBoxFlat = flat_box(Color(0, 0, 0, 0), 3, 3.0)
	focus.border_color = Color(ACCENT, 0.6)
	focus.set_border_width_all(1)
	focus.draw_center = false
	var empty: StyleBoxEmpty = StyleBoxEmpty.new()
	for type: StringName in [&"Button", &"OptionButton", &"MenuButton", &"CheckBox", &"CheckButton"]:
		t.set_stylebox(&"normal", type, button if type in [&"Button", &"OptionButton"] else empty)
		t.set_stylebox(&"hover", type, button_hover)
		t.set_stylebox(&"pressed", type, button_pressed)
		t.set_stylebox(&"disabled", type, button_disabled if type in [&"Button", &"OptionButton"] else empty)
		t.set_stylebox(&"focus", type, focus)
		t.set_color(&"font_color", type, TEXT)
		t.set_color(&"font_hover_color", type, Color.WHITE)
		t.set_color(&"font_pressed_color", type, Color.WHITE)
		t.set_color(&"font_disabled_color", type, Color(TEXT, 0.35))
		t.set_color(&"icon_normal_color", type, Color(TEXT, 0.95))
		t.set_constant(&"h_separation", type, 6)
	for type: StringName in [&"LineEdit", &"TextEdit", &"CodeEdit", &"SpinBox"]:
		t.set_stylebox(&"normal", type, field)
		t.set_stylebox(&"focus", type, field_focus)
		t.set_stylebox(&"read_only", type, field)
		t.set_color(&"font_color", type, TEXT)
		t.set_color(&"font_placeholder_color", type, Color(TEXT, 0.4))
		t.set_color(&"caret_color", type, Color.WHITE)
		t.set_color(&"selection_color", type, Color(ACCENT, 0.35))
	t.set_color(&"background_color", &"CodeEdit", BACKGROUND)
	t.set_color(&"font_readonly_color", &"CodeEdit", TEXT)
	t.set_color(&"font_readonly_color", &"LineEdit", Color(TEXT, 0.6))
	var panel: StyleBoxFlat = flat_box(BASE, 0, 0.0)
	t.set_stylebox(&"panel", &"Panel", panel)
	t.set_stylebox(&"panel", &"PanelContainer", panel)
	var popup: StyleBoxFlat = flat_box(Color(0.16, 0.18, 0.22), 4, 6.0)
	popup.border_color = Color(TEXT, 0.18)
	popup.set_border_width_all(1)
	popup.shadow_color = Color(0, 0, 0, 0.4)
	popup.shadow_size = 6
	t.set_stylebox(&"panel", &"PopupMenu", popup)
	t.set_stylebox(&"panel", &"PopupPanel", popup)
	t.set_stylebox(&"hover", &"PopupMenu", flat_box(Color(ACCENT, 0.25), 3, 2.0))
	t.set_color(&"font_color", &"PopupMenu", TEXT)
	t.set_color(&"font_hover_color", &"PopupMenu", Color.WHITE)
	t.set_color(&"font_separator_color", &"PopupMenu", Color(ACCENT, 0.9))
	t.set_color(&"font_disabled_color", &"PopupMenu", Color(TEXT, 0.35))
	var window: StyleBoxFlat = flat_box(BASE, 4, 8.0)
	window.border_color = Color(TEXT, 0.2)
	window.set_border_width_all(1)
	window.expand_margin_top = 28
	window.border_width_top = 28
	window.border_color = Color(0.17, 0.19, 0.23)
	t.set_stylebox(&"embedded_border", &"Window", window)
	t.set_stylebox(&"embedded_unfocused_border", &"Window", window)
	t.set_color(&"title_color", &"Window", TEXT)
	for type: StringName in [&"ItemList", &"Tree"]:
		t.set_stylebox(&"panel", type, flat_box(DARK, 3, 2.0))
		t.set_stylebox(&"focus", type, empty)
		t.set_stylebox(&"selected", type, flat_box(Color(ACCENT, 0.25), 2, 2.0))
		t.set_stylebox(&"selected_focus", type, flat_box(Color(ACCENT, 0.32), 2, 2.0))
		t.set_stylebox(&"hovered", type, flat_box(Color(1, 1, 1, 0.05), 2, 2.0))
		t.set_color(&"font_color", type, TEXT)
		t.set_color(&"font_selected_color", type, Color.WHITE)
	var tab_sel: StyleBoxFlat = flat_box(BACKGROUND.lerp(Color.BLACK, 0.12), 0, 4.0)
	tab_sel.border_color = ACCENT
	tab_sel.border_width_top = 2
	var tab_unsel: StyleBoxFlat = flat_box(Color(0, 0, 0, 0), 0, 4.0)
	t.set_stylebox(&"tab_selected", &"TabContainer", tab_sel)
	t.set_stylebox(&"tab_unselected", &"TabContainer", tab_unsel)
	t.set_stylebox(&"tab_hovered", &"TabContainer", flat_box(Color(1, 1, 1, 0.05), 0, 4.0))
	t.set_stylebox(&"panel", &"TabContainer", empty)
	t.set_color(&"font_selected_color", &"TabContainer", Color.WHITE)
	t.set_color(&"font_unselected_color", &"TabContainer", Color(TEXT, 0.7))
	t.set_color(&"font_hovered_color", &"TabContainer", TEXT)
	for type: StringName in [&"Label"]:
		t.set_color(&"font_color", type, TEXT)
	var grabber: StyleBoxFlat = flat_box(Color(TEXT, 0.25), 4, 0.0)
	var grabber_hl: StyleBoxFlat = flat_box(Color(TEXT, 0.4), 4, 0.0)
	var scroll: StyleBoxFlat = flat_box(Color(0, 0, 0, 0), 4, 2.0)
	for type: StringName in [&"VScrollBar", &"HScrollBar"]:
		t.set_stylebox(&"scroll", type, scroll)
		t.set_stylebox(&"grabber", type, grabber)
		t.set_stylebox(&"grabber_highlight", type, grabber_hl)
		t.set_stylebox(&"grabber_pressed", type, grabber_hl)
	t.set_constant(&"separation", &"HSplitContainer", 6)
	t.set_constant(&"separation", &"VSplitContainer", 6)
	var sep: StyleBoxLine = StyleBoxLine.new()
	sep.color = Color(TEXT, 0.15)
	t.set_stylebox(&"separator", &"HSeparator", sep)
	var vsep: StyleBoxLine = StyleBoxLine.new()
	vsep.color = Color(TEXT, 0.15)
	vsep.vertical = true
	t.set_stylebox(&"separator", &"VSeparator", vsep)
	var tip: StyleBoxFlat = flat_box(Color(0.16, 0.18, 0.22), 3, 5.0)
	tip.border_color = Color(TEXT, 0.2)
	tip.set_border_width_all(1)
	t.set_stylebox(&"panel", &"TooltipPanel", tip)
	t.set_color(&"font_color", &"TooltipLabel", TEXT)
	return t
