extends Node

## The "BrickscriptDebug" autoload (registered by plugin_main.gd): while the
## game runs under the editor's debugger, it watches the engine's errors, and
## for one that comes from a brickscript it finds the brick that made that
## line (every line a brick makes ends with `  # brick <id>`, see
## flow_compiler.gd marker()) and tells the editor, which shows it on that
## brick. Outside a debug session (exported games, plain runs) it only sends
## this machine's profile when it hosts or joins (BrickscriptPlayers
## announce_profile: every player's name reaches the server). On a client it
## also builds the meshes server brickscripts made (runtime/meshes.gd, from
## the Network Context Engine's node_data_changed).

const Locate = preload("brick_debug_locate.gd")
const Meshes = preload("meshes.gd")
const MESSAGE: String = "brickscript:error"
const TRACE_MESSAGE: String = "brickscript:trace"
## How often the bricks that ran are sent to the editor (seconds).
const TRACE_EVERY: float = 0.1


## Hears every error the engine logs (on any thread).
class ErrorWatch extends Logger:
	var on_error: Callable = Callable()

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		var where: Array = Locate.locate(file, line, script_backtraces)
		if where.is_empty():
			return
		var text: String = rationale if not rationale.is_empty() else code
		# Right away on the main thread: under the editor's debugger a script
		# error pauses the game at once, so a deferred report would wait until
		# it's resumed (or never come). Other threads hand it over.
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			on_error.call(where[0], where[1], text)
		else:
			on_error.call_deferred(where[0], where[1], text)


## Sends a report; replaced in tests. func(message: String, data: Array).
var sender: Callable = Callable()
## Reports already sent (file / brick / text): an error in Every frame would
## otherwise flood the editor.
var _sent: Dictionary = {}
var _watch: ErrorWatch = null
## Bricks that ran since the last send: file -> {brick id: true}.
var _ran: Dictionary = {}
var _since_sent: float = 0.0


func _ready() -> void:
	var engine: Node = get_tree().root.get_node_or_null(^"NetworkEngine")
	BrickscriptPlayers.announce_profile(engine)
	if engine != null and engine.has_signal(&"node_data_changed"):
		engine.connect(&"node_data_changed", Meshes.on_node_data)
	if OS.is_debug_build() and EngineDebugger.is_active():
		start(func(message: String, data: Array) -> void: EngineDebugger.send_message(message, data))


## Fire Server from a LocalScript a starter copied (StarterCharacter /
## StarterPlayer): that copy is only on its player's machine, so the server
## has no copy of it to call; the message comes here instead (this autoload
## is on every machine) and the server hands it to the ServerScript nodes
## beside where the copy is (On Client Fired), with who sent it.
@rpc("any_peer", "call_remote", "reliable")
func relay_told(path: NodePath, message: String, values: Array) -> void:
	var engine: Node = get_tree().root.get_node_or_null(^"NetworkEngine")
	if engine == null or not bool(engine.call(&"has_server_authority")):
		return
	# Deferred, as a script node's own message is (TELL_SERVER_HELPER).
	_hand_relayed.call_deferred(path, message, values, int(engine.call(&"get_caller_id")))


func _hand_relayed(path: NodePath, message: String, values: Array, sender: int) -> void:
	var count: int = path.get_name_count()
	if not path.is_absolute() or count < 3:
		return
	var names: PackedStringArray = []
	for index: int in count - 1:
		names.append(String(path.get_name(index)))
	var parent: Node = get_tree().root.get_node_or_null(NodePath("/" + "/".join(names)))
	if parent == null:
		return
	var from: String = String(path.get_name(count - 1))
	var unwired: Array = values.map(func(value: Variant) -> Variant:
		if value is Dictionary and (value as Dictionary).size() == 1 and (value as Dictionary).has("_brickscript_player"):
			return BrickscriptPlayers.player_of(parent, int(value["_brickscript_player"]))
		return value)
	for sibling: Node in parent.get_children():
		if String(sibling.name) != from and sibling.has_method(&"_brickscript_on_client_told"):
			sibling.call(&"_brickscript_on_client_told", message, unwired, sender)


## Fire Clients from a ServerScript beside a starter's LocalScript copies
## (StarterCharacter / StarterPlayer): those copies are on their player's
## machine only, so the server sends it here (on every machine) with the
## node's path, and each machine hands it to the LocalScripts beside that node
## (On Server Fired). Only the server's word counts.
@rpc("any_peer", "call_remote", "reliable")
func relay_server_told(path: NodePath, message: String, values: Array) -> void:
	var engine: Node = get_tree().root.get_node_or_null(^"NetworkEngine")
	if engine == null:
		return
	var caller: int = int(engine.call(&"get_caller_id"))
	if caller != 1 and caller != int(engine.call(&"get_local_peer_id")):
		return
	_hand_server_told.call_deferred(path, message, values)


func _hand_server_told(path: NodePath, message: String, values: Array) -> void:
	if not path.is_absolute():
		return
	var body: Node = get_tree().root.get_node_or_null(path)
	if body == null:
		return
	for child: Node in body.get_children():
		if child.has_method(&"_brickscript_server_told"):
			child.call(&"_brickscript_server_told", message, values)


## Starts watching; reports go to `send`.
func start(send: Callable) -> void:
	sender = send
	if _watch == null:
		_watch = ErrorWatch.new()
		_watch.on_error = report
		OS.add_logger(_watch)


## A brick ran (traced brickscripts call this, see Compiler.TRACE_HELPER).
func trace(file: String, brick: int) -> void:
	(_ran.get_or_add(file, {}) as Dictionary)[brick] = true


## Sends the bricks that ran, a few times a second ([file, [ids...]] per file).
func _process(delta: float) -> void:
	_since_sent += delta
	if _since_sent < TRACE_EVERY or _ran.is_empty():
		return
	_since_sent = 0.0
	flush_trace()


func flush_trace() -> void:
	if sender.is_valid():
		for file: String in _ran:
			sender.call(TRACE_MESSAGE, [file, (_ran[file] as Dictionary).keys()])
	_ran.clear()


func _exit_tree() -> void:
	if _watch != null:
		OS.remove_logger(_watch)
		_watch = null


## Finds the brick of a brickscript line and sends
## [file, brick id (0: none found), line, text] once per brick and text.
func report(file: String, line: int, text: String) -> void:
	# Already loaded (it's running): take it from the cache, no loading here.
	var script: Script = ResourceLoader.get_cached_ref(file) as Script if ResourceLoader.has_cached(file) else null
	if script == null and ResourceLoader.exists(file):
		script = load(file) as Script
	var brick: int = Locate.brick_at_line(script.source_code if script != null else "", line)
	var key: String = "%s|%d|%s" % [file, brick, text]
	if _sent.has(key) or not sender.is_valid():
		return
	_sent[key] = true
	sender.call(MESSAGE, [file, brick, line, text])
