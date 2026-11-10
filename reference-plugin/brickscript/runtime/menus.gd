@icon("res://addons/brickscript/icons/nodes/menus.svg")
class_name BrickscriptMenus
extends Node

## Where each machine's Host / Join / Leave menu lives (a PlayerService's
## Menus): when the Network Context Engine is installed it adds this
## machine's own copy under itself, named after its player
## ("xdmonsterMenu"; UI, never synced). One menu per game, even with two
## Menus nodes. A scene without one has no menu (its own lobby, say).
## A dedicated server build shows no menu: there it hosts at once, on the
## menu's port (nobody is there to press Host).

## Off: no menu (the scene has its own lobby).
@export var enabled: bool = true
## The menu's scene (its root a BrickscriptNetworkMenu). Empty: the addon's
## assets/network_menu.tscn, so editing that one changes every game's;
## without it, one made in code.
@export var menu_scene: PackedScene = null
## The menu's heading. Empty: the menu scene's own.
@export var menu_title: String = ""
## A line under the heading (the game's controls, say). Empty: the menu
## scene's own.
@export_multiline var menu_help: String = ""

const NetworkMenu: GDScript = preload("res://addons/brickscript/runtime/network_menu.gd")
## The menu every Menus node uses when its menu_scene is empty.
const DEFAULT_MENU: String = "res://addons/brickscript/assets/network_menu.tscn"


func _ready() -> void:
	if enabled:
		# (Deferred: a scene's own menu, if any, is in its group by then.)
		_add_menu.call_deferred()


func _add_menu() -> void:
	var engine: Node = get_node_or_null(^"/root/NetworkEngine")
	if not is_inside_tree() or engine == null or not engine.has_method(&"host") or not get_tree().get_nodes_in_group(NetworkMenu.GROUP).is_empty():
		return
	var scene: PackedScene = menu_scene
	if scene == null and ResourceLoader.exists(DEFAULT_MENU):
		scene = load(DEFAULT_MENU) as PackedScene
	var menu: Node = scene.instantiate() if scene != null else NetworkMenu.new()
	if menu.get_script() != NetworkMenu:
		push_error("Menus: the menu scene's root isn't a BrickscriptNetworkMenu (%s)." % scene.resource_path)
		menu.free()
		return
	if OS.has_feature("dedicated_server"):
		if bool(engine.call(&"is_offline")):
			var port: int = int(menu.get(&"port"))
			var hosted: int = int(engine.call(&"host", port))
			print("Menus: a dedicated server: %s on port %d." % ["hosting" if hosted == OK else "couldn't host (%s)" % error_string(hosted), port])
		menu.free()
		return
	# (Renamed "<player>Menu" by the menu itself.)
	menu.name = "NetworkMenu"
	if not menu_title.is_empty():
		menu.set(&"title", menu_title)
	if not menu_help.is_empty():
		menu.set(&"help", menu_help)
	# (Its own on every machine: UI, never synced.)
	add_child(menu, true)
