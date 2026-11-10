@icon("res://addons/brickscript/icons/nodes/network_menu.svg")
class_name BrickscriptNetworkMenu
extends CanvasLayer

## The Host / Join / Leave menu a Menus node gives every player (each
## machine makes its own copy: it's UI, never synced). Its look is the scene
## res://addons/brickscript/assets/network_menu.tscn (edit it there: every
## game's Menus node uses the latest); without that scene Menus makes one in code, laid out
## the same. It calls the Network Context Engine by name (host, join, leave)
## and shows what's happening: hosting (with the addresses others can join),
## joining, in a game, and why a game ended. Without the engine (not
## installed, or an older one) there's nothing to host or join: it removes
## itself and says so. A dedicated server build shows none.
##
## The Name box is this machine's username (saved with its profile; the
## Players node gives it to everyone). The menu is named after this machine's
## player: "xdmonsterMenu" (it follows renames).
##
## The nodes it uses, found by name: Title, Help, Name, Address, Host, Join, Leave,
## Status, Hint (any can be moved or restyled; missing ones are made).

## The menu's heading (the Menus node's menu_title replaces it when set).
@export var title: String = "Multiplayer"
## A line under the heading (controls, say). Empty: none.
@export_multiline var help: String = ""
## The address Join starts with.
@export var address: String = "127.0.0.1"
@export_range(1, 65535) var port: int = 7000
## Shows / hides the menu while playing.
@export var toggle_key: Key = KEY_F1

## Group a menu is in while the game runs (a Menus node adds none then).
const GROUP: StringName = &"brickscript_network_menu"
## The engine methods the menu uses.
const Profile: GDScript = preload("res://addons/brickscript/runtime/profile.gd")
const NEEDED: Array[StringName] = [&"host", &"join", &"leave", &"is_offline", &"is_server", &"is_client", &"get_players"]

var _engine: Node = null
var _panel: Control = null
var _address: LineEdit = null
var _name: LineEdit = null
var _host: Button = null
var _join: Button = null
var _leave: Button = null
var _status: Label = null
## Why the last game ended (shown when back in single-player).
var _ended: String = ""
## This machine's player node whose name the menu's follows.
var _me: Node = null


func _ready() -> void:
	add_to_group(GROUP)
	_engine = get_node_or_null(^"/root/NetworkEngine")
	var missing: Array[StringName] = NEEDED.filter(func(method: StringName) -> bool: return _engine == null or not _engine.has_method(method))
	if not missing.is_empty():
		push_warning("Network Menu: %s, so there's nothing to host or join: the menu is removed." % ("the Network Context Engine isn't installed (autoload NetworkEngine)" if _engine == null else "this Network Context Engine is too old (no %s)" % ", ".join(missing)))
		queue_free()
		return
	# (A dedicated server build; a headless run still gets one: tests press it.)
	if OS.has_feature("dedicated_server"):
		queue_free()
		return
	_build()
	_engine.connect(&"context_changed", func(_new: int, _old: int) -> void: _refresh())
	_engine.connect(&"player_joined", func(_player: int) -> void: _refresh())
	# (While player_left runs, the player still counts.)
	_engine.connect(&"player_left", func(_player: int) -> void: _refresh.call_deferred())
	if _engine.has_signal(&"session_ended"):
		_engine.connect(&"session_ended", _on_session_ended)
	BrickscriptPlayers.of(self).player_added.connect(func(_player: BrickscriptPlayer) -> void: _update_name())
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if _panel == null:
		return
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == toggle_key:
		_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		# A click in the game: typing stops going into the address box.
		get_viewport().gui_release_focus()


## Takes the scene's nodes (by name), making what's missing.
func _build() -> void:
	_panel = get_child(0) as Control if get_child_count() > 0 else null
	if _panel == null:
		_panel = _made_panel()
	var box: Node = _found(&"Box")
	if box == null:
		box = _panel
	var heading: Label = _found(&"Title") as Label
	if heading == null:
		heading = Label.new()
		heading.name = "Title"
		heading.add_theme_font_size_override(&"font_size", 20)
		box.add_child(heading)
	heading.text = title
	var lines: Label = _found(&"Help") as Label
	if lines == null:
		lines = Label.new()
		lines.name = "Help"
		box.add_child(lines)
	lines.text = help
	lines.visible = not help.is_empty()
	_name = _found(&"Name") as LineEdit
	if _name == null:
		_name = _labelled(box, "Name", "Your name")
	_name.text = str(Profile.load_profile()["username"])
	_name.max_length = 24
	_name.text_submitted.connect(func(_text: String) -> void: _name.release_focus())
	_name.focus_exited.connect(_on_name)
	_address = _found(&"Address") as LineEdit
	if _address == null:
		_address = _labelled(box, "Address", "host or host:port")
	_address.text = address
	_address.text_submitted.connect(func(_text: String) -> void: _address.release_focus())
	var buttons: Node = _found(&"Buttons")
	if buttons == null:
		buttons = HBoxContainer.new()
		buttons.name = "Buttons"
		box.add_child(buttons)
	_host = _button(buttons, "Host", _on_host)
	_join = _button(buttons, "Join", _on_join)
	_leave = _button(buttons, "Leave", _on_leave)
	_status = _found(&"Status") as Label
	if _status == null:
		_status = Label.new()
		_status.name = "Status"
		_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(_status)
	var hint: Label = _found(&"Hint") as Label
	if hint == null:
		hint = Label.new()
		hint.name = "Hint"
		hint.modulate = Color(1, 1, 1, 0.6)
		box.add_child(hint)
	hint.text = "%s: hide / show this menu" % OS.get_keycode_string(toggle_key)


func _made_panel() -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.position = Vector2(12, 12)
	add_child(panel)
	var margin: MarginContainer = MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var box: VBoxContainer = VBoxContainer.new()
	box.name = "Box"
	box.custom_minimum_size = Vector2(320, 0)
	margin.add_child(box)
	return panel


## A row: a label and a text box named `text`.
func _labelled(box: Node, text: String, hint: String) -> LineEdit:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = text + "Row"
	box.add_child(row)
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(72, 0)
	row.add_child(label)
	var field: LineEdit = LineEdit.new()
	field.name = text
	field.placeholder_text = hint
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	return field


func _found(node_name: StringName) -> Node:
	return find_child(node_name, true, false)


func _button(parent: Node, text: String, pressed: Callable) -> Button:
	var button: Button = _found(StringName(text)) as Button
	if button == null:
		button = Button.new()
		button.name = text
		button.text = text
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		parent.add_child(button)
	# (Not focusable: Space / Enter while playing don't press it.)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(pressed)
	return button


## Address and port from the box: "host" or "host:port".
func _target() -> Array:
	var text: String = _address.text.strip_edges()
	if text.is_empty():
		text = address
	var colon: int = text.rfind(":")
	if colon > 0 and text.count(":") == 1 and text.substr(colon + 1).is_valid_int():
		return [text.left(colon), clampi(text.substr(colon + 1).to_int(), 1, 65535)]
	return [text, port]


## The Name box: saved, and sent to everyone (a name already taken in the
## game gets a _2 there).
func _on_name() -> void:
	var players: Node = BrickscriptPlayers.of(self)
	players.call(&"set_my_username", _name.text)
	_name.text = str(Profile.load_profile()["username"])


func _on_host() -> void:
	_ended = ""
	var result: int = int(_engine.call(&"host", port))
	if result != OK:
		_ended = "Couldn't host on port %d: %s (is another game using it?)" % [port, error_string(result)]
	_refresh()


func _on_join() -> void:
	_ended = ""
	var target: Array = _target()
	var result: int = int(_engine.call(&"join", target[0], target[1]))
	if result != OK:
		_ended = "Couldn't join %s:%d: %s" % [target[0], target[1], error_string(result)]
	_refresh()


func _on_leave() -> void:
	_engine.call(&"leave")
	_refresh()


func _on_session_ended(reason: int, message: String) -> void:
	var reason_name: String = String(_engine.call(&"get_end_reason_name", reason)) if _engine.has_method(&"get_end_reason_name") else ""
	var target: Array = _target()
	match reason_name:
		"LEFT": _ended = "Left the game."
		"KICKED": _ended = "Kicked from the game."
		"SERVER_CLOSED": _ended = "The host ended the game."
		"CONNECTION_FAILED": _ended = "Couldn't reach %s:%d." % target
		"TIMEOUT": _ended = "No answer from %s:%d (is a game hosted there?)." % target
		"CONNECTION_LOST": _ended = "Lost the connection."
		_: _ended = "The game ended."
	if not message.is_empty():
		_ended += " " + message
	_refresh()


## Named "<this machine's player>Menu" (the profile's username before there
## is a player node).
func _update_name() -> void:
	if not is_inside_tree():
		return
	var players: BrickscriptPlayers = BrickscriptPlayers.of(self)
	var me: BrickscriptPlayer = players.player(int(_engine.call(&"get_local_peer_id"))) if players != null else null
	if me != _me:
		if is_instance_valid(_me) and _me.renamed.is_connected(_update_name):
			_me.renamed.disconnect(_update_name)
		_me = me
		if me != null:
			me.renamed.connect(_update_name)
	var base: String = String(me.name) if me != null else str(Profile.load_profile()["username"])
	var wanted: String = (base + "Menu").validate_node_name()
	if String(name) != wanted:
		name = wanted


func _refresh() -> void:
	_update_name()
	if _status == null:
		return
	var offline: bool = bool(_engine.call(&"is_offline"))
	var server: bool = bool(_engine.call(&"is_server"))
	var client: bool = bool(_engine.call(&"is_client"))
	var players: int = (_engine.call(&"get_players") as PackedInt32Array).size()
	_host.disabled = not offline
	_join.disabled = not offline
	_address.editable = offline
	_leave.disabled = offline
	_leave.text = "Cancel" if not (offline or server or client) else "Leave"
	if offline:
		_status.text = (_ended + "\n" if not _ended.is_empty() else "") + "Single-player. Host a game, or join one."
	elif server:
		var here: PackedStringArray = _lan_addresses()
		_status.text = "Hosting on port %d: %d player%s.%s" % [port, players, "" if players == 1 else "s",
				("\nOthers join with: " + ", ".join(here)) if not here.is_empty() else ""]
	elif client:
		var target: Array = _target()
		_status.text = "In the game at %s:%d: %d player%s." % [target[0], target[1], players, "" if players == 1 else "s"]
	else:
		var target: Array = _target()
		_status.text = "Joining %s:%d..." % target


## This machine's addresses on the local network (IPv4, not loopback).
func _lan_addresses() -> PackedStringArray:
	var found: PackedStringArray = []
	for ip: String in IP.get_local_addresses():
		if ip.count(".") == 3 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			found.append(ip)
	return found
