# Brickscript API

Reference for **every brick (node) Brickscript has**, what it does, and what is planned. It is written so it can be handed to another person or AI assistant working on, or with, Brickscript. Everything under "Working bricks" exists and is covered by tests; everything under "Planned bricks" does **not** exist yet, and its names may change.

- Plugin: `addons/brickscript/` (Godot 4.7, GDScript 2.0, strictly typed). Editor tab "Brickscript".
- Status: wire editor, compiler, network bricks, characters, navigation and AI bricks, procedural mesh bricks (3D) working. Last updated 2026-10-30.
- Source of truth for bricks: `core/flow_library.gd` (`NODES`). A test fails if a brick there is missing from this file.

---

## 0. Getting started

The rest of this file is the full reference (with notes for people working on the plugin). To start:

1. **A brickscript is a script node.** In the Scene dock, right-click the node it should act for and pick **Add LocalScript (Brickscript)...** or **Add ServerScript (Brickscript)...**. That adds a child node running a new `.bricklocal` / `.brickserver` file and opens it in the **Brickscript** tab. In it, **Self** is the script node and **Self.Parent** the node it acts for.
2. **Hello world:** drag **When ready** (Events) and **Print** (Output) onto the canvas, wire When ready's output into Print, type `hello` into its value, save, and play the scene: `hello` is printed. Then try **When action pressed** (action `ui_accept`) into another Print.
3. **Local or server?** A **LocalScript** shows things on one machine: UI, cameras, sounds, effects, and reads input. A **ServerScript** runs the game: scores, spawning, damage, moving things. A single-player game is its own server, so its rules go in ServerScripts too, and a local brickscript changing a game node is refused (see "What a local brickscript may change").
4. **Moving something with the keys:** a **Character3D / Character2D** node (Characters) moves itself with WASD, no bricks needed. For any other node, use the server, in its ServerScript: **Every frame** into **Player Direction** (leave its Player blank: this node's Owner, in single-player you) into a **Formula** `Vector3(dir.x, 0, dir.y) * 5 * delta` (2D: `dir * 200 * delta`) into **Property (Add)** `position` of Self.Parent. All four directions in one chain; new direction bricks use the characters' `move_forward` / `move_back` / `move_left` / `move_right` when the project has them (a PlayerService adds them), else `ui_up` / `ui_down` / `ui_left` / `ui_right`. **Player Holding** is for one action (run while Space is held). Moving it from a LocalScript with **Key Direction** only works once the server gave it to your player with **Moved By**. **In a network game** add two bricks to that ServerScript: **Give To** (Player Joined -> Give To the player: the blank Player Direction follows its Owner; given to no one, nobody moves it) and **Sync** `position` (or the clients never see it move).
5. **Values go through variables:** a brick's result goes in its **Output** name; later bricks pick that name for their inputs. There are no data wires.
6. **Problems:** the Brickscript tab's toolbar says when the brickscript can't be generated ("N problem(s)"), and each problem names its brick, e.g. `Property (node 4) > of: ...`; a misspelled variable gets a guess (`no variable named 'scroe' here: did you mean 'score'?`), and a brick used in the wrong kind of brickscript says which script node to add it to. Errors while the game runs name the brickscript and brick, and the brick gets a red outline in the tab.
7. **Building brickscripts in code** (tools, tests, generators): section 4, "Example: the double jump" and what follows it.

---

## 1. How Brickscript works

A Brickscript **graph** compiles to GDScript. A `.bricklocal` / `.brickserver` file **is a script** to Godot: put it on a node (or in a scene) like a `.gd`, and Brickscript's loader compiles it when it loads, in the editor and in the game. The compiled code has no other dependency on Brickscript.

- **Event bricks** start chains (e.g. "When ready" becomes `_ready()`).
- **Execution wires** (white ▶ ports) decide what runs next. There are **no data wires**.
- **Values travel through variables.**
  - A brick that makes a value has an **Output** dropdown ("Into"): **(don't keep it)**, the existing variables it may write into, or **New variable…** with a name box. A new one is a *chain variable*, which later bricks of the same event can read; renaming it renames its uses in the events that reach it only (2026-11-03: not a chain variable of the same name another event makes; a Shared / Synced variable is renamed everywhere). Picking an existing one writes into it (stored as `use_var`).
  - The existing variables offered are the ones usable at that brick (found the same way as input dropdowns, walking back along the wires) that may be written and fit the value's type (Get node: Node variables only; a Formula's value can be anything, so every writable variable). A new variable starts with a name from the brick: the node it finds (`Player/Gun` → `gun`), the property, method or group it reads, or a word for what it makes (Add → `sum`).
  - Loop names (For each's Item / Index, For each key/value's Key / Value, Repeat's Counter) use the same dropdown: a new chain variable, an existing one to fill (Index / Counter: Whole ones), or not kept.
- **Inputs:** every input has one dropdown. Pick **Variable** and choose the variable from a second dropdown, or pick a value type (Number, Bool, Vector3, ...) and type the value.
  - The variable dropdown shows only what is usable *at that brick* and fits the input: script variables, the event's own values (e.g. `delta`), and chain variables made by bricks that run earlier in the same event. A List input lists only Lists, a math input only numbers and vectors, and so on.
  - Outputs, loop names and Variable (Set) list only variables that may be written (no Constants, Exports or event values), and offer "New variable…" (a name box for a new variable).
  - A name that isn't usable at that brick (e.g. after a variable was deleted) stays shown, marked "(not usable here)", and is a compile error.
  - Names that *create* variables are typed into the name box under "New variable…" (outputs, loop names, Variable (Set)).
- **Editor:** Properties shows the selected brick's **Inputs** (settings and inputs) with its **Outputs** below (the Output dropdown, Variable's target or new variable's name and kind, loop names, an event's outputs and values, what runs next). There is no variables list: variables come from bricks. Clicking a palette entry shows its description, inputs, settings, output and exits in Properties (from each brick's `description` in `flow_library.gd`). Right-drag or middle-drag pans; a right-click without dragging opens the add menu.
  - The list comes from the compiler (`flow_compiler.gd` `scopes`) plus a walk backwards along the brick's wires (`flow_ops.gd` `upstream_names`), so chain variables made upstream are offered even before the chain is wired to an event. A brick with a problem still makes the variable it names (type Anything), so bricks after it keep their dropdowns and don't each report "no variable named".
- **Event outputs:** an event has numbered outputs (1, 2, 3, ... plus a spare to wire next). They fire **in order**, each chain running to its end before the next starts, all in the same frame. Later outputs can read chain variables made by earlier ones.
- **More outputs on every brick:** an action brick's Next works the same way: once it's wired, a spare **+ next** appears; wired, it's Next 2 (and another spare). Next 1, Next 2, ... run in order, each chain to its end (a Wait in Next 1's chain holds Next 2 back), and later ones can read what earlier ones made. A loop's Loop body and Done grow too (Loop body 2: another chain each time round, after the first; Done 2: after Done). If's True / False, Raycast's Hit / Nothing hit, Break / Continue and reroute points don't. Exit names: `next`, `next_2`, `next_3`, ... (`loop_2`, `done_2`, ...); `Ops.exits_for` / `exit_title` / `outputs_of`, compiled by `_emit_outputs`.
- **Merging and loops:**
  - Several wires may lead into one brick. When every way out of a branching brick (If, Raycast, Walk to, Can see...) always leads on to it (no dead end, Break, Continue or Return on the way), what follows is written once, after the if / else (2026-10-29; before, it was written out once per path, which doubled the code at every such join). Otherwise each path keeps its own copy.
  - Wires may not loop back. Repeating is done by loop bricks (For each item, For each key/value, Repeat N times).
- **Saving:** a graph is a **`.bricklocal`** or **`.brickserver`** file (see "Brickscript files" below). Nodes and scenes use that file as their script; no `.gd` is written. Saving rebuilds the already loaded script, so open scenes update. A brickscript with problems still loads: its node reports them (push_error) when it is ready.
  - In the editor they have their own icons in the FileSystem; server ones are also tinted orange there.
  - Double-clicking one opens it in the Brickscript tab.
  - The tab shows a **start page** until a brickscript is open: New local / New server brickscript (asks where to save it), Open..., and a list of the project's brickscripts (double-click or Enter to open): the open scene's first (marked "In this scene:", the scripts on its nodes), then the rest by path, with a **filter** box above it (only paths holding each of its words, any case; Enter opens the selected one, or the first). The toolbar's **Close** goes back to it.
  - FileSystem > right-click > **Create New > Brickscript (local)...** makes `new_brickscript.bricklocal`; **Brickscript (server)...** (offered when the Network Context Engine is installed) makes `new_brickscript.brickserver`.
  - Scene dock > right-click a node: **Add LocalScript (Brickscript)... / Add ServerScript (Brickscript)...** add a script node running a new brickscript for the node (see Script nodes). The Network Context Engine adds the same two for `.gd` scripts. (Godot's own Attach Script dialog only lists script languages, so brickscripts can't appear in its Language dropdown.)
  - **The palette (and the canvas's add menu) lists only the bricks the open brickscript can use:** a brick's `contexts` (local / server) must include the graph's, and network bricks need the Network Context Engine. A brick pasted into the wrong kind of brickscript is a compile error.
  - Older `.brick` files and graphs saved as `.tres` still open; they still write `<name>.gd` next to them when saved.
  - Generated code starts with `# Generated by Brickscript. Do not edit: this file is rewritten from its graph.` Brickscript never overwrites a `.gd` that lacks that header.

### Script nodes (LocalScript / ServerScript)

**In the Scene dock** (2026-11-03): the plugins' own nodes (Character3D / 2D, PlayerService and its parts, Menus, the Object values, Terrain, CullThrottleSettings) show no script icon, like Godot's own nodes. Script nodes keep theirs (it opens their brickscript), and so does a node running a script of your own.

The way new brickscripts are attached: a **script node** is a child Node of its own (named LocalScript / ServerScript) running a brickscript **for its parent**. A node can have several, each switched on or off on its own, and the Scene dock shows which is which (each has its brickscript's icon). Older brickscripts attached to the node itself keep working (and still pair by file name); the editor only adds script nodes now.

- **Scene dock > right-click a node > Add LocalScript (Brickscript)... / Add ServerScript (Brickscript)...** (the server one with the Network Context Engine) adds the child, marked with the metadata `script_node` = `"local"` / `"server"` (the Network Context Engine reads it), running a new `<node>_local.bricklocal` / `<node>_server.brickserver` (the `_local` / `_server` names keep them from pairing by file name), undoable, and opens it.
- **The graph:** `script_node: true` (Brickscript toolbar: **Acts for** > Script node / The node). New brickscript files are script nodes. Paths are Roblox style (2026-10-28, see "Self and Self.Parent" under Node types): **Self** (`.`) is the script node itself (its own variables, like Roblox's `script`), **Self.Parent** (`..`) the node it works for (like `script.Parent`), whose type is found in the scenes (`body_type`, like a server part's); node paths start at the script node, and the path pickers list paths from it (`NodeTypes.guess_from_scenes`). New bricks' Node inputs start at Self.Parent there (`Ops.add_node` / `start_paths`).
- **The script:** `extends Node` (Extends is fixed), `@icon(...)` (the local or server brickscript icon) after the header, `@onready var _brickscript_body: <the parent's class> = get_parent()`; Self compiles to `self`, Self.Parent to `_brickscript_body` and Self.Parent.UI to `_brickscript_body.get_node(NodePath("UI"))` (`_script_node_path`). The rules of the context still hold: a LocalScript only changes what its machine alone sees (its parent is usually the game, so it reads it and shows things), a ServerScript runs only where the game has server authority.
- **A server brickscript never reacts to a local script's own signals** (When signal received on a signal a `.bricklocal` / `.local.gd` declares): on the host that would run for the host's player only, never for clients. It's an error when the Type says so; when it doesn't, the signal isn't connected when the game runs (`_brickscript_listen`, with an error). A node's own class signals (`body_entered`, `pressed`...) are fine. Local to server is Fire Server / On Client Fired.
- **Talking:** Fire Server from a LocalScript reaches the ServerScript nodes beside it (the parent's children with On Client Fired); Fire Clients from a ServerScript reaches the LocalScript nodes beside it (with On Server Fired), on every client or one. A server part / its node works as before.
- **Without the Network Context Engine** a LocalScript doesn't add a server part: its ServerScript sibling is already in the scene.
- **With the Network Context Engine (API 8+):** a ServerScript node never runs on a client: its script is taken off as it enters the tree there (before its `_ready`), and put back (with its `_ready`) when that machine runs the game again (leaving a game). Script nodes never get a server part, are never sent as nodes the server added (they're part of every machine's scene) and come along when the server sends a node made in code. `.gd` scripts work the same: a script node is marked `script_node` (Add LocalScript / ServerScript does it), or runs a `.server.gd` / `.brickserver` file itself. The Network Context Engine's Scene dock menu has **Add LocalScript (.gd)... / Add ServerScript (.gd)...** (`<node>_local.gd` / `<node>_server.gd`, with `body` = the parent).
- **Built-in scripts are discouraged** (Network Context Engine API 8): a built-in `.gd` script on a game node (as its script or its `server_script`) logs an error naming the node when the game runs (once per script; it still runs), and the editor lists such nodes in a warning (toast and Output) when a scene is opened or saved and when a node's script or metadata is edited. Built-in brickscript copies refuse to run and are put back (see above). "Attach built-in script (server)..." is gone from the Scene dock menu.

### Local and server brickscripts

- **Context:** a graph's `context` is `&"local"` (runs on every machine) or `&"server"`. The file's extension sets it (`.bricklocal` / `.brickserver`); the toolbar's **Runs on** shows it (it can only be changed for older `.brick` files and unsaved graphs). A server graph's title shows `[server]`, tinted.
- **A server brickscript's script:**
  - starts with `# Server brickscript: ...`
  - every event function begins with
    ```gdscript
    if not _brickscript_has_server_authority():
    	return
    ```
  - a helper at the end asks `/root/NetworkEngine` (by name) for `has_server_authority()`. That is true on the host / server and offline. Without the Network Context Engine the game is single-player and its own server, so everything runs.
- **Server parts:** the Network Context Engine (API 2+) adds `<name>.brickserver` as the **server part** of every node running `<name>.bricklocal`: a child "ServerPart", only where the game has server authority. (It pairs `<name>.local.gd` / `<name>.gd` with `<name>.server.gd` the same way, and mixed pairs work too.) So a node runs its local brickscript everywhere and its server brickscript only on the server, and the two talk with the Network bricks.
- **A node can carry its server script itself** (Network Context Engine API 3+): its metadata `server_script` holds the script, and wins over the file pairing. That's how a node whose local script is **built into the scene** (Godot's "Built-in Script", which has no file name to pair by) gets a server part. (Older scenes only: the editor no longer makes these; use a ServerScript node.) With no paired file, the brickscript's "this node" type comes from the scene that carries it (stored in the graph as `body_type`, see the data format).
- **Without the Network Context Engine** a local brickscript adds its server part itself: `_brickscript_server_part_alone()` (deferred from the start of `_ready`, in every local brickscript compiled from a file) loads `<name>.brickserver` next to it, or the node's `server_script` metadata, as a child "ServerPart". Fire Server then hands its message straight to that part. Single-player is its own server either way.
- **Brickscripts themselves can't be built in:** they are their graph files. Enforced: every brickscript compiled from a file starts `_ready` with `if not _brickscript_from_file("<its path>"): return`, so a copy built into a scene does nothing (an error says to put the file back, and its processing is turned off); and the editor puts the file back itself (plugin_main.gd `put_back_built_in_copies`: when a scene is opened or saved, and when a node's script or metadata is edited, with a toast). A built-in copy of one (e.g. after "Make Unique" on a node's script) is plain generated GDScript cut off from its graph; opening it in the script editor shows a warning saying so.

### Characters (Character3D and Character2D nodes)

Like a Roblox character with its Humanoid, in one node: a **Character3D** (`BrickscriptCharacter3D`, `addons/brickscript/runtime/character_3d.gd`) or a **Character2D** (`BrickscriptCharacter2D`, `runtime/character_2d.gd`) as the character's root is a playable character with no bricks for the basics. (Replaces the older Character child node, 2026-10-26.) Their script nodes (LocalScript / ServerScript children) hold the brickscripts as usual. The Inspector doesn't show their Script row (the node is its script).

- **Not CharacterBody3D / 2D** (2026-10-27): they extend **AnimatableBody3D / 2D**, kinematic bodies moved by setting their transform (others' raycasts and bodies hit them, they push rigid bodies), and move themselves with casts of their own shape: sideways first (sliding along walls; Character3D steps up a ledge whose top is a floor at most `step_height` 0.35 above the one it stands on, measured with a ray just in front), then up / down (landing, a ceiling, `floor_snap` 0.25 keeps it to the floor going down slopes and steps). Two casts a frame when nothing is in the way; after every hit it stays `PUSH_GAP` (1 cm) short, since Jolt's casts don't see what they start touching; something else putting it somewhere (made, a teleport, the server's correction) gets it out of what it's in first. They have `velocity` and `is_on_floor()` like a CharacterBody (code reading those keeps working). Cost (Raspberry Pi 4, throttled, both timed in turns): a walking character 114-143 us a frame against 195-230 us for a CharacterBody3D with move_and_slide (about 1.6x cheaper; the rest is GDScript); a character moved elsewhere (only shown) ~2 us either way. Character2D: Platformer steps up `step_height` 8 px (a lift, kept only onto a floor), `floor_snap` 8 px; Top-down slides along what's in the way.

- **On its player's machine** (the one that owns it, Network Context Engine API 14; offline or without the engine, this machine): it reads the input actions (default `move_forward` / `move_back` / `move_left` / `move_right`, `jump`) and moves (move_and_slide). Its **camera** is the current one there, and only there.
  - **Character3D, kind Drone** (2026-10-31): it flies, no gravity: WASD where its head looks (up and down too), Space (`jump`) rises, `fly_down` (Ctrl / C; a PlayerService adds the action) sinks; it gets to `walk_speed` and back to a stop at `fly_acceleration` (12 units/s², Drone group: it glides), sliding along what it runs into (up to 3 times a move). The shape it makes when its scene has none is a ball (`shape_radius`). Hovering still it does no casts. Its forward is its head's -Z (Godot's forward), as for a humanoid. Controlled by Script: `move_direction` counts up / down too, and **Walk to / Follow fly** (2026-11-01, air paths): straight there when nothing is in the way, else along a path through the open air, round or over walls, crates and the Terrain's ground, into caves through their mouths (`runtime/air_paths.gd`: a grid of 1.5 m cells, each open when a ball of its radius + 0.3 touches nothing static and, with a Terrain, isn't inside its ground; looked at as a search needs them, believed 5 s; a dig forgets them). The search runs up to 2 ms a physics frame and the drone hovers meanwhile: around a wall or from cave to cave a fraction of a second, from high in the sky into a deep tunnel whose mouth is 20 m aside ~6 s (Pi 4). No way there (or more than 12,000 cells looked at, or 30 m outside the box round start and goal): Can't reach. It slows down to stop at the goal, Within measured all round. Only static things with collision are gone round: characters aren't (it slides past them), and a triangle-mesh collider of your own blocks only at its surface. Cost: 5 drones following a target through the caves ~0.5 ms a physics tick in all. **Following** (2026-10-31) it keeps the height above its target it had when the Follow began (none if it was below it) and stops at the Distance from that point, instead of coming down to a walker's height. Dead, it drops like a humanoid. Never On the floor; Falling only once dead.
  - **No clip** (`no_clip`, Movement, any kind, 2026-10-31): it passes through everything but the ground: Terrains and nodes in the group **`ground`** (add a floor of your own to it). Its casts and rays leave the rest out (one look around a move, up to 32 things near it); others still hit it (raycasts, bodies). Set it with Property (Set) like the other settings. Through a floor that isn't ground it falls on, and below `fall_limit` it's put back where it started (or dies: Death settings), as any fall off the world.
  - **Character3D** (`kind` Humanoid): walk speed, jump power, gravity; the mouse turns it (yaw: everyone sees where you face) and tilts the head (pitch). A first-person Camera3D on a "Head" child at eye height (only for Controlled by Player: an NPC has its Head, for its eyes, but no camera unless it's ever seen through). A click in the game captures the mouse (that click goes no further: it isn't a shot), Esc frees it (`capture_mouse`); `looking` says whether it's captured. A player who had it captured when their character died keeps it captured on their next character (2026-11-02).
  - **Character2D** `kind` **Platformer** (default): left / right walk, `jump`, gravity pulls down (+y). **Top-down**: the four directions move it any way, no gravity (floating motion); `face_movement` turns it the way it goes. A Camera2D "Camera" follows it (it doesn't turn with it).
- **Made when the scene has none** (local-only children, in the `local_only` group: every machine makes its own, never sent): a shape (3D: a capsule `shape_radius` 0.4 / `shape_height` 1.8; 2D: a capsule 16 / 48 for a platformer, a circle of `shape_radius` top-down), the Head / Camera (3D) or Camera (2D). A scene's own shape, Head or Camera is kept. **In the editor** (both are `@tool`; nothing else runs there) a character **added** to the edited scene with no shape (the Add Node dialog, a new scene's root) gets one added to the scene instead (saved with it, metadata `_brickscript_made_shape`: it follows the Shape settings, and Kind in 2D), so there is no "no shape" warning and the shape can be seen and edited; replace or edit it freely. A scene **opened** with a shapeless character (one written by hand or in code) gets one that is only shown (`add_preview_shape()`: no owner, so not saved and not in the Scene dock; metadata `_brickscript_preview_shape`), so opening the scene doesn't mark it changed (2026-10-30); it goes when you add a shape of your own.
- **On the server:** it hands the character's movement to its player (Owner of the character: `set_network_owner`) and syncs it, so everyone sees it. The speed limit (`max_speed`, or 0 for three times the walk speed plus the gravity; top-down: three times the walk speed) is checked by the character itself on the server (`_network_check`): a state further than that is refused and its player's machine is put back.
- **Elsewhere:** it glides where its player puts it, 0.1 s behind (it runs on with its velocity for up to 0.1 s when a state is late); a server with no screen (a dedicated, headless one) sets each state at once instead, since its game logic wants the newest and nobody watches it. On the floor / Moving / Falling there come from its player's machine, and its velocity is worked out from the states, so Property (Get) reads them right on every machine (before, the server didn't know whether a client's character stood on the floor).
- **Network format** (Network Context Engine API 15, `sync_packed`): one packed state per character instead of synced properties: Character3D 17 bytes (position 3 x float32, yaw and head pitch 16 bits each, flags on the floor / looking / moving / falling), Character2D 11 bytes (position 2 x float32, rotation 16 bits, flags). The engine sends every changed state of an update in one message per client (a 1-2 byte number and a size byte before each; each client's message leaves out what it moves itself), and all of them once a second. Other machines see the head tilt too. An older engine (API 14): position and rotation synced as before. **Update rate** (Network Context Engine API 19, 2026-10-30): a character the server sends some machine only every Nth update (the Cull Throttle Engine: far away) is told (`_network_rate(N)`) and glides N times as far behind there, so it doesn't stop between states; culled for that machine, it's hidden there and comes back where it is.
- **Settings (Inspector):** Character3D: `kind` (Humanoid / Drone), `controlled_by`, Movement (`walk_speed` 6, `jump_power` 7, `gravity` 20, `fall_limit` -20, `no_clip`), Drone (`fly_acceleration` 12), Camera (`eye_height` 0.7, `mouse_sensitivity` 0.0025, `capture_mouse`, `field_of_view` 80, `hidden_from_own_camera`: meshes others see but its own camera doesn't, e.g. its head: on its player's machine they and the meshes under them go on render layer 20, which its camera leaves out), Shape, Input (the action names), Network (`max_speed`). Character2D (pixels): `kind`, Movement (`walk_speed` 300, `jump_power` 600, `gravity` 1600, `fall_limit` 2000: below it a platformer is put back where it started, `face_movement`), Shape, Input (`move_up` / `move_down` default `move_forward` / `move_back`, ...), Network.
- **Stored values** (for `.tscn` files and code): `kind` Humanoid = 0, Drone = 1; `controlled_by` Player = 0, Script = 1; `fall_action` From spawner = 0, Die = 1, Put back = 2; `death_look` From spawner = 0, Default = 1, Scripted = 2 (each enum in its Inspector order).
- **Controlled by** (Character3D, 2026-10-29): **Player** (default: its player's keys and mouse, its camera is theirs) or **Script** (an NPC: it ignores the keyboard and mouse, its camera stays off; it walks where `move_direction` points (world space, up / down ignored, length 1 = `walk_speed`, longer is cut to 1) and jumps on `jump_now()` when on the floor). Either way it moves on the machine that owns it: with no player, the server (offline: this machine), and everyone else sees it glide like any character. A character standing still on the floor **rests** (2026-10-29): no shape casts until something moves it, with a look at its floor every 0.1 s (gone, it falls). Bricks that steer it: Walk to, Follow, Stop walking (section 2, AI). Case: `tests/cases/character_npc`.
- **Health** (2026-10-27): `health` / `max_health` (100 / 100) and `regen_per_second` (0: none; added once a second while alive and hurt). Only where the game runs (the server; offline, this machine) changes them: `damage(amount, by = 0)`, `heal(amount)`, `set_health(value, by = 0)`, `set_max_health(value)` (health goes no higher), `kill(by = 0)`; anywhere else they're refused with an error (`false`). `by` is the player who did it (a peer number, 0: nobody). Every machine gets the new health (one reliable message from the server, only when it changes; a machine that gets the character later asks the server for it) and hears `health_changed(health, max_health)`; at 0 it **dies**: `died(killer)` on every machine, once (a dead character's health stays 0: damage / heal return false), `is_dead()`, and its player's machine stops moving it (no walking or jumping; gravity still pulls). Cost: nothing per frame beyond a compare or two (no regen: one), nothing on the network until health changes; then one reliable message to every client (~31-34 bytes each with ENet's overhead), one `rpc()` when all are reachable. A Damage / Heal call ~7.5 us on a Pi 4 (what the machine is, cached per character); a hit sent to 4 clients ~215 us under load (`tests/run_network_stress_test.sh`, its firefight stage).
- **Death settings** (Death group): `fall_action` (From spawner / Die / Put back): what happens below `fall_limit` (Character2D: platformer only). Die: its player's machine stops it there, and the server kills it (offline / its own: at once; a client's: when a state below the limit arrives, checked in `_network_check`, so a refused state counts too). Put back: where it started, as before. `death_look` (From spawner / Default: falls over / Scripted: its death scripts do it), `death_server_script` (a `.brickserver` / `.gd`: runs where the game runs when it dies) and `death_local_script` (a `.bricklocal` / `.gd`: runs on every machine, effects only); empty: the spawner's. From spawner: its Character Spawner's Character defaults (below); not from a spawner: Put back and Default. `get_fall_action()`, `get_death_look()`, `get_death_script(server)` give them with From spawner worked out.
- **After a death** (on every machine, right after `died` and When character died): **Default**: the body lies down: its children (not its shapes or a 2D camera; a 3D head and camera too) turn a quarter round about its feet and rise by its `shape_radius` (lying on the floor, not half in it) in 0.5 s (`FALL_OVER_SEC`; not on a headless server: nobody sees it), and the server removes it 2 s after it died (`BODY_STAYS_SEC`, Remove character's way). **Scripted**: its death scripts are added as script nodes, `DeathServerScript` (the server one, only where the game runs) and `DeathLocalScript` (the local one, on every machine; local rules: effects only), `local_only` (every machine makes its own), and When character died runs in them at once ("this node" is the character); the server one ends it with Remove character, and if nothing has 10 s after the death (`SCRIPTED_LIMIT_SEC`) the server removes it anyway. Either way its Character Spawner makes a new one `respawn_seconds` after it's gone. A dead character's player's machine doesn't look around or jump with it (Esc still frees the mouse).
- `on_floor()`, `is_moving()`, `is_falling()` (right on every machine; Property (Get) reads them as `on_the_floor`, `moving`, `falling`), `is_mine()` (worked out again only when the engine says ownership or the session changed: `network_owners_changed`, `context_changed`).
- Its `change(property, value, seconds)` is what Property (Set or Add) of one of its settings calls (Seconds: 0 from a brick): on its player's machine it's set at once (put back after `seconds` when given); on the server, for a client's character, the server's copy is set (its speed limit follows walk speed and gravity) and the change is sent to that player's machine; anywhere else it's refused with an error. A Character2D has only `walk_speed`, `jump_power`, `gravity` (others are refused with an error).

**Automatic characters: the Character Spawner** (`BrickscriptCharacterSpawner`, `addons/brickscript/runtime/character_spawner.gd`), like Roblox's CharacterAutoLoads with SpawnLocations: put it in the game scene and set `character_scene`, `spawn_points` (a node whose children are the spawn points: a **SpawnPoints** node picks by its settings, below, any other node in turn; empty: its own children), `starter_character` (a StarterCharacter: copied into every character), `container` (where characters go; empty: the spawner) and `respawn_seconds` (3; 0: no respawn). **Character defaults** (2026-10-27) for its characters whose own settings say From spawner: `fall_action` (Die, the default / Put back), `death_look` (Default / Scripted), `death_server_script`, `death_local_script` (used when a character has none of its own). Every machine marks the characters entering its container with the spawner (metadata `_brickscript_spawner`), so they read these settings there. Where the game runs (the server; offline or without the Network Context Engine, this machine as player 1) every player (there already, or joining) gets their character at the next spawn point (`spawn_for` + `set_player_character`: Character of finds it, a Character3D / Character2D hands them its movement), a player who leaves loses it, and a character that goes (freed) comes back after `respawn_seconds` while its player is there. After leaving a game, single-player gets its own again. No Player Joined / Spawn scene chains needed. **Characters are named after their player** (their node under Players: `Characters/xdmonster`, `Characters/xdmonster_2`; Network Context Engine API 16 named spawns, an older engine: `<root>_<n>`): the server waits for a joining player's username (at most `NAME_WAIT_SEC`, 2 s; then the stand-in `Player<n>`), and when a player's name changes (the username arriving late, the menu's Name box) their character is made again where it stands with the new name (the engine can't rename what it spawned; it's a respawn: When character spawned runs again).

**The PlayerService** (`BrickscriptPlayerService`, `addons/brickscript/runtime/player_service.gd`, `@tool`), like Roblox's Players service with its characters: one per scene, holding `SpawnPoints` (a SpawnPoints with Spawn1, a SpawnPoint), `StarterPlayer` / `StarterCharacter`, `Players` (a BrickscriptPlayers), `Characters` (a Character Spawner: the characters, named after their players) and `Menus` (each machine's own Host / Join menu, `<player>Menu`). Added in the editor with no children, it makes them once: Spawn1 at (0, 1, 0), and Characters spawning the addon's humanoid `res://addons/brickscript/assets/player_character.tscn` (a Character3D with a blocky body, its head hidden from its own camera) at SpawnPoints; and it adds the input actions that character moves with (`move_forward` / `move_back` / `move_left` / `move_right`: WASD and the arrows, `jump`: Space) when the project lacks them. Its Scene dock warnings: a second PlayerService in the scene, no Players, no Character Spawner, no character scene, no spawn points, a missing menu container, missing input actions (for the humanoid), no Network Context Engine. While the game runs it does nothing itself (a second one prints a warning).

A PlayerService **written by hand or in code** (a `.tscn` made outside the editor) gets no children made: give it them yourself. The smallest that spawns everyone's character (the names are what the code looks for; the scripts are under `addons/brickscript/runtime/`):

```
[ext_resource type="Script" path="res://addons/brickscript/runtime/player_service.gd" id="ps"]
[ext_resource type="Script" path="res://addons/brickscript/runtime/spawn_points.gd" id="sp"]
[ext_resource type="Script" path="res://addons/brickscript/runtime/starter.gd" id="st"]
[ext_resource type="Script" path="res://addons/brickscript/runtime/players.gd" id="pl"]
[ext_resource type="Script" path="res://addons/brickscript/runtime/character_spawner.gd" id="cs"]
[ext_resource type="PackedScene" path="res://addons/brickscript/assets/player_character.tscn" id="hero"]

[node name="PlayerService" type="Node" parent="."]
script = ExtResource("ps")
_filled = true

[node name="SpawnPoints" type="Node" parent="PlayerService"]
script = ExtResource("sp")

[node name="Spawn1" type="Marker3D" parent="PlayerService/SpawnPoints"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0)

[node name="StarterPlayer" type="Node" parent="PlayerService"]
script = ExtResource("st")

[node name="StarterCharacter" type="Node" parent="PlayerService"]
script = ExtResource("st")

[node name="Players" type="Node" parent="PlayerService"]
script = ExtResource("pl")

[node name="Characters" type="Node" parent="PlayerService"]
script = ExtResource("cs")
character_scene = ExtResource("hero")
spawn_points = NodePath("../SpawnPoints")
starter_character = NodePath("../StarterCharacter")
```

(`_filled = true`: the editor won't add children when it's opened. Add a Menus node, `runtime/menus.gd`, for the Host / Join menu; the input actions `move_forward` / `move_back` / `move_left` / `move_right` / `jump` must be in the Input Map, which the editor's PlayerService adds.)

**SpawnPoints** (`BrickscriptSpawnPoints`, `runtime/spawn_points.gd`): the spawner's spawn points node with settings: `order` (**In turn** (default) / **Random** / **Farthest** from the other characters), `face_point` (on: characters start turned the way their point faces, a Marker3D's -Z / a Marker2D's rotation), `skip_occupied` + `occupied_radius` (1: a point with a character within that is skipped for the next free one; all taken: the one picked anyway), `tag_value` (the name of a player value, e.g. `team`: a player starts only at points tagged with that value's value, or untagged ones; none matching: any). Its points: Marker3D / Marker2D, or **SpawnPoint** / **SpawnPoint2D** (`BrickscriptSpawnPoint`, `runtime/spawn_point.gd` / `spawn_point_2d.gd`) with `enabled` and `tag`.

**A ready scene:** the Scene dock's Create Root Node panel has **Multiplayer 3D Scene** (under 3D Scene), and Project > Tools has **New Multiplayer Scene...** (asks where to save it): a `World` root with a 40 x 40 floor, a PlayerService as above, and the 3D editor's preview sun and sky made real (its own "Add Sun / Environment to Scene", so they match what the editor showed; Godot's default look when those buttons can't be found). Godot has no API for that panel: the button is found by the 3D Scene button's text, and without it only the Tools item is there. Press Play and you walk around as the humanoid, with the Host / Join menu.

**The Host / Join menu: the Menus node** (`BrickscriptMenus`, `addons/brickscript/runtime/menus.gd`; a PlayerService's `Menus`; before 2026-10-27 the Character Spawner's settings): when the Network Context Engine is installed it adds this machine's own Host / Join / Leave menu under itself (it's UI, never synced; one per game even with two Menus nodes), named after this machine's player (`xdmonsterMenu`, following renames). A scene without a Menus node has no menu. In a dedicated server build it shows none and hosts at once on the menu's port. Settings: `enabled` (on; off: the scene has its own lobby), `menu_scene` (empty: the addon's `res://addons/brickscript/assets/network_menu.tscn`, so editing that scene changes every game's menu; without it, one made in code with the same nodes), `menu_title` and `menu_help` (the game's controls; empty: the scene's own). The menu (`BrickscriptNetworkMenu`, `addons/brickscript/runtime/network_menu.gd`, the menu scene's root): a **Name** box (this machine's username: saved with its profile and sent to everyone, see "Players and their values"), an address box (`host` or `host:port`), Host / Join / Leave (Cancel while joining) and a status line: single-player, hosting (port, players, the addresses others on the network join with), joining, in a game (players), and why a game ended (left, the host ended it, no answer, couldn't reach, kicked, connection lost) or couldn't start (a taken port). It finds its nodes by name (Title, Help, Name, Address, Host, Join, Leave, Status, Hint: restyle or move them in the scene; missing ones are made); its own settings `address` (127.0.0.1), `port` (7000), `toggle_key` (F1 hides / shows it). Its buttons can't take focus (Space doesn't press them), and a click in the game takes typing out of the address box. It calls the engine by name: without it (or an engine without host / join / leave) it removes itself with a warning; a dedicated server build shows none. Leave out the Menus node (or turn `enabled` off) when the scene has its own lobby (a brick-made one, like the sandbox's). Tested by `tests/run_network_menu_test.sh` (single-player, a real host and client).

#### `event_character_spawned`: When character spawned
- Server brickscripts only. Runs when a Character Spawner gives a player their character (joining, each respawn), with the player and the character: starting health, a team color.
- **Provides:** `player` (Player), `character` (Node).
- **GDScript:** its own function `_brickscript_spawned_<id>(player: int, character: Node)`, connected at the end of `_ready` (deferred: spawners may be ready later) by `_brickscript_on_spawned(<function>)`: every spawner's `character_spawned`, and once for the characters a spawner made already.
- **Exits:** numbered outputs.

**Reading and changing a character** (2026-10-27: Get / Set Character were folded into the generic bricks): **Property (Get)** reads its settings (`walk_speed`, `jump_power`, `gravity`, `health`, `max_health`, `eye_height`, `mouse_sensitivity`, `field_of_view`, `capture_mouse`, `no_clip`, `fly_acceleration`), `velocity` (Vector3 / Vector2) and its read-only states `on_the_floor`, `moving`, `falling`, `dead` (properties whose getters call `on_floor()`, `is_moving()`, `is_falling()`: right on every machine) and `looking`. **Property (Set)** (Set or Add) of one of its settings goes through its `change()` (see Characters above): at once on its player's machine (sprinting in their local brickscript), from the server to that machine; `health` / `max_health` only in a server brickscript (a compile error in a local one). Its states can't be set (read only: the script lists them in `_BRICKSCRIPT_READ_ONLY`, which `core/node_types.gd` honours for any script). Set Character's Seconds is gone: Set, Wait, Set back. Older files (format 3) are upgraded when read: Get Character -> Property (Get), Set Character -> Property (Set) (Seconds dropped), Character -> Get Character From a player (`Ops.character_bricks_upgrade`).

#### `get_character`: Get Character
- A player's character (the node a Character Spawner or Give To As: Their character made theirs), on every machine. Nothing (null) when they have none (yet) or it's gone: check with If `is null`. Replaces the Character brick (2026-10-27).
- **Settings:** `from` (**From**: **A player** (default) / **A user ID**: the ID saved with each player's profile, `BrickscriptPlayer.user_id`; only players in the game now), `node_class` (Type) / `node_script` (Script): what the character is, so the next bricks offer its properties.
- **Inputs:** `player: Player` (From a player: e.g. Me, or Player Joined's `player`), `user_id: Text` (From a user ID).
- **Output:** Node, of that node type.
- **GDScript:** `<output> = _brickscript_character_of(<player's number>) as <Type>` (helper: `NetworkEngine.get_player_character`, API 5; null without the engine); From a user ID: `_brickscript_character_of(_brickscript_peer(_brickscript_player_with_user_id(<user_id>)))` (the player under Players with that `user_id`).
- **Exits:** `next`.

#### `get_player`: Get Player
- The player of a character (or of a node inside it), or the player with a user ID. No player (null) when there's none: check with If `is null`. For whose any node is (a car given to someone), Owner does the same for every node.
- **Settings:** `from` (**From**: **A character** (default) / **A user ID**).
- **Inputs:** `of: Node = this node` (From a character), `user_id: Text` (From a user ID).
- **Output:** Player.
- **GDScript:** `<output> = _brickscript_player(_brickscript_player_of(<of>))` (as Owner); From a user ID: `<output> = _brickscript_player_with_user_id(<user_id>)`.
- **Exits:** `next`.

#### `damage`: Damage
- Server brickscripts only. Takes Amount off a character's health; at 0 it dies (When character died on every machine). Every machine gets the new health (the character node sends it).
- **Inputs:** `of: Node = this node` (the character, or a node inside it), `amount: Number or Whole = Number 10`, `by: Player` (shown when By is A player).
- **Settings:** `by_whom` (**By**: Nobody (default) / A player: the killer When character died gets).
- **GDScript:** `_brickscript_damage(<of>, <amount>, <by: the player's number, 0: nobody>, "Damage (brick <id>)")` (the character's `damage(amount, by)`; a dead character's health stays 0).
- **Exits:** `next`.

#### `heal`: Heal
- Server brickscripts only. Gives a character Amount of health back, up to its max health. A dead character stays dead (it's made again).
- **Inputs:** `of: Node = this node`, `amount: Number or Whole = Number 10`.
- **GDScript:** `_brickscript_heal(<of>, <amount>, "Heal (brick <id>)")`. **Exits:** `next`.

#### `kill_character`: Kill character
- Server brickscripts only. A character dies at once (health 0).
- **Inputs:** `of: Node = this node`, `by: Player` (shown when By is A player). **Settings:** `by_whom` (**By**: Nobody / A player).
- **GDScript:** `_brickscript_kill(<of>, <by>, "Kill character (brick <id>)")`. **Exits:** `next`.

#### `remove_character`: Remove character
- Server brickscripts only. Takes a character out of the game on every machine, dead or alive (the engine despawns what it spawned; anything else is freed). Its Character Spawner makes the player a new one after `respawn_seconds`. A Scripted death ends with it.
- **Inputs:** `of: Node = this node`.
- **GDScript:** `_brickscript_remove_character(<of>, "Remove character (brick <id>)")` (the character's `remove()`). **Exits:** `next`.

#### `event_character_died`: When character died
- Local and server brickscripts. Runs on every machine when a character's health reaches 0: in a server brickscript for the game (scores, who killed whom, Remove character), in a local one for what this machine shows (a sound, particles, "You died": effects only, local rules as usual).
- **Provides:** `character` (Node), `player` (Player: the character's; none when it isn't a player's), `killer` (Player: who did it; none for nobody, a fall, Property (Set) health 0).
- **Settings:** `whose` (**Whose**: Any character (default), This node's character (the script is on or inside it: a StarterCharacter or death script), My character (this machine's player's)).
- In a character's **death script** (Death look Scripted: `death_server_script` / `death_local_script`, added when it dies) it runs at once, for that death.
- **GDScript:** its own function `_brickscript_died_<id>(character: Node, player: int, killer: int)`, connected in `_ready` by `_brickscript_hear_deaths(<function>, <whose 0 / 1 / 2>, <this node>)`: the script joins the group `brickscript_death_listeners`, and a dying character calls `_brickscript_on_character_death(character, player, killer)` on that group; each event filters by its Whose. Nothing runs until a death (no per-frame cost).
- **Exits:** numbered outputs.

### Predicted events (client-side prediction)

In a server brickscript, **Every frame**, **Every physics frame**, **Player Pressed / Released** and **Player Holding** have **Runs on** (`runs_on`): **The server** (default), or **The server and its player's machine (predicted)**. A predicted event also runs on the machine of the player its node belongs to (Owner), which then moves that node at once, without waiting a round trip for the server: your own character answers your keys immediately. The server still runs the game; its values come back and correct the player's machine (Network Context Engine API 13: small differences over a few frames, big ones such as a wall or a teleport at once). Other machines see the node glide as usual.

- **How:** the brickscript marks its node predicted on the server (`_brickscript_set_predicted()`, NetworkEngine.set_predicted), and the Network Context Engine keeps the node's ServerScript on its player's machine (it's taken off on other clients). There, every function holding a predicted event checks `_brickscript_has_server_authority() or _brickscript_predicting()`; the brickscript's other events check `_brickscript_has_server_authority()` on their own, and `_ready` sets up only the predicted events' connections there (the rest: marking it predicted, other connections, Sync, When ready, under `if _brickscript_has_server_authority():`). Players' input bricks read the player's own keys locally there (Player Direction, Player Holds?, the press events), Player Aim their own screen.
- **Only for moving the node:** a predicted event can't use Spawn scene, Free node, Give To, Fire Clients, Play / Stop animation, Add to / Remove from group or a Wait (they'd happen twice, or where only the server may): a compile error names the brick. Put those in events that Run on: The server.
- **Without the engine, or offline,** it's the same as The server (the game is its own server). In a local brickscript Runs on isn't shown and is ignored.
- Example: an older FPS example's movement (2026-10-24; its characters are Character3D nodes now).

### What a local brickscript may change

The game belongs to the server. A local brickscript runs on every machine, so it only **reads** the game and changes **what this machine alone sees**; the server brickscript changes everything else, and a single-player game puts its game logic there too (offline the game is its own server). Enforced, not advised:

- **Local-only nodes:** UI (Controls, CanvasLayers, and anything inside either), cameras (`Camera2D` / `Camera3D`), sounds (`AudioStreamPlayer*`), particles (`GPUParticles*` / `CPUParticles*`), and what the local brickscript spawned itself (an effect: put in the `local_only` group). `core/node_types.gd` `LOCAL_ONLY_CLASSES` / `is_local_only()`.
- **Bricks that change a node** (Property (Set), Call method, Free node, Add to group, Remove from group: their `local_target` input) only take a local-only node there. The compiler checks the node's **Type**: another Type, or none ("some Node"), is an error on that brick (set the Type if it is one of those). When the game runs the node is checked again (2026-10-29: each refusal is reported once per node and reason, not every time the brick runs; in the game's first second it's asked again a second later and only reported if still refused, since the server's Moved By may not have arrived yet), since a path, a List or a parent can turn out to be something else: `if not _brickscript_local_only(<node>, "<brick title> (brick <id>)"): return`, then the change. A node that isn't local-only is left alone, with an error naming the brick (and saying the server brickscript can give it to the player with Moved By), and **the chain stops there** (2026-10-31: before, the rest ran as if it had worked; such a chain runs in a function of its own, `_brickscript_run_<event id>`, so other events sharing its callback go on; in a Define Function's chain the change is only skipped). A Call method with an Output Var gets nothing (its type's default) then.
- **What this machine's player moves** (Roblox's network ownership, Network Context Engine API 14): what Moved By gave them (their character), and everything under it. A local brickscript may change it: that's how players move their own character, at once, with input read in the local brickscript (the Roblox way); the server checks it (Moved By's Max speed) and everyone sees it. Without the engine, what Moved By gave player 1 counts. **A character placed in the scene** (2026-10-31: a Character3D with Controlled by: Player, or a Character2D, no spawner, given to nobody) counts too wherever this machine's keys move it: offline and on the host (a client's keys move only what the server gave it). Because ownership is only known when the game runs, the node a brickscript acts for ("this node") and character-like bodies (CharacterBody2D / 3D, RigidBody2D / 3D: `NodeTypes.is_movable`) aren't refused when compiling: they're checked when the game runs, like an unknown node. A node given to this machine's player (Give To, Spawn scene For them) whose Moved By hasn't arrived yet (it's a separate message, a frame or so after the spawn) is skipped quietly for a second; after that it's an error saying to give it with Moved By.
- **Allowed anyway:** a Godot method that only reads (a `const` method: `get_child_count`, `is_on_floor`, `get_global_transform`...), and the brickscript's own variables through "this node" (like Variable (Set)).
- **Synced variables are read-only there:** the server sets them (Property (Set) on the node from its server brickscript; with script nodes, the LocalScript is the node: Property (Set) `<name>` of `../LocalScript`, a Node input with Type: that LocalScript's brickscript, from the ServerScript next to it). Variable (Set) or Property (Set) (Add) on one from the local brickscript is an error; its starting value is fine.
- **Spawn scene** in a local brickscript only spawns **effects**: a scene with a physics body or area anywhere in it (`NodeTypes.scene_bodies()`) is an error. The copy goes in `local_only`, so it can be changed there, and is never synced.
- **Server-only bricks** (Give To, Sync, Fire Clients, On Client Fired) aren't offered in a local brickscript, and are an error in one.
- **Still local:** events, input, logic, maths, variables, lists, Print, Play sound, Wait, signals, Host / Join / Leave, Fire Server (and the username, in the network menu: the one thing about the game a player writes; the server receives it).

### Variables

| Kind | GDScript | Who can change it | Lifetime |
|---|---|---|---|
| Constant | `const` | nobody | fixed |
| Export | `@export var` | set per node in the Inspector; bricks can only read it | per node |
| Shared | `var` | bricks (an Output into it, Variable (Set)) | kept while the node exists |
| Chain | local `var` at the top of the event's run | bricks of that event | reset every time the event fires |

- **Every variable comes from a brick.**
  - **Constant** and **Export** are their own bricks, with no wires: declarations, set before the game starts, with a typed-in value.
  - **Variable (Set)** with a new name makes a **Shared** (default) or **Chain** variable. A Shared Variable (Set) no event reaches gives the variable's starting value.
  - A brick's Output Var name makes a chain variable.
- **Older graphs** are converted when opened in the editor (`Ops.variables_to_bricks`, `Ops.upgrade_graph`):
  - Listed variables (`BrickscriptFlowGraph.variables`) become Constant / Export / Variable (Set) bricks in a "Variables" frame.
  - Variable (Set) bricks set to Constant / Export become those bricks.
  - The compiler still accepts both older forms.
- Event values are read-only chain values provided by the event, e.g. `delta` in "Every frame".
- **Name lookup order:** chain variables, then event values, then script variables. Chain and script variables can never share a name.
- **Names** must be plain identifiers. They must not be:
  - a GDScript keyword or built-in type
  - a common global function (`print`, `min`, ...)
  - `delta` or `event`
  - a member of the base class (e.g. `position` on Node2D)

### Value types

`flow_types.gd` `ValueType`. These numbers are also `BrickscriptVariable.type`.

| Id | Name | GDScript | Typed-in value | Default |
|---|---|---|---|---|
| 1 | Number | `float` | number box | `0.0` |
| 4 | Whole | `int` | number box (rounded) | `0` |
| 2 | Text | `String` | text box | `""` |
| 5 | Bool | `bool` | checkbox | `false` |
| 6 | Vector2 | `Vector2` | x / y | `Vector2(0, 0)` |
| 7 | Vector3 | `Vector3` | x / y / z | `Vector3(0, 0, 0)` |
| 8 | Color | `Color` | color picker | `Color(0, 0, 0, 1)` |
| 9 | Node | `Node`, or its node type's class | node path, shown Roblox style (`get_node(...)`; `.` = Self, `self`; `..` = Self.Parent, `get_parent()`) | `null` |
| 10 | List | `Array`, or `Array[<item type>]` for a typed List (`Array[float]`, `Array[Label]`) | empty only (`[]`), with an "of" dropdown for its item type (stored as an empty typed Array, e.g. `Array[float]([])`; typed in from code: `.input_value(&"value", T.LIST, Array([], TYPE_VECTOR3, &"", null))`) | `[]` |
| 11 | Table | `Dictionary`, or `Dictionary[<keys>, <values>]` for a typed Table (`Dictionary[String, float]`) | empty only (`{}`), with "of" dropdowns for its key and value types | `{}` |
| 12 | Resource | `Resource`, or its class (`Texture2D`, `AudioStream`, ...) | a project file (`res://...`), picked from a dropdown; `load("<file>")` (`preload` for a Constant) | `null` |
| 13 | Player | `BrickscriptPlayer` (the player's node, `Players/<name>`; null = no player) | (not typed in: Owner, Me) | `null` (no player; stored as `0` in graph files) |
| 0 | Anything | `Variant` | (not typed in) | `null` |

- **Node paths are Text.** A Godot property, method value or return value that is a `NodePath` (a RemoteTransform's `remote_path`, `has_node(path)`, `get_node_or_null(path)`, `get_path()`) is Text in Brickscript, so those members are offered in the dropdowns. Text going in becomes `NodePath(<text>)`; a node path coming out becomes `str(...)`. A signal value that is a node path arrives as Anything (`str()` it).
- **Number and Whole fit each other's inputs.** A decimal written into a Whole is rounded with `roundi()`.
- **Player** is a player: their node under the Players node (`Players/xdmonster`, see "Players and their values"), on every machine. It doesn't mix with numbers. It goes into Node inputs (Find node `under` a player finds their values; Property (Get) reads `username`, `user_id`, `peer_id`). `str(player)` is their name. "No player" is checked with If `is null` / `is not null`; two Players compare with `==` / `!=`. A List of Players is an `Array[Node]` (a typed Array takes only built-in classes). **In the code:** the engine knows players by number, so the bricks that talk to it pass `_brickscript_peer(<player>)` and turn its answers into nodes with `_brickscript_player(<number>)`; an event that gets a player's number from the engine (Player Joined, On Client Fired's `sender`...) takes `_peer_<name>: int` and starts with `var <name>: BrickscriptPlayer = _brickscript_player(_peer_<name>)`. A Player sent with Fire Server / Fire Clients / Invoke Server goes as its number and arrives as that player's node there.
- **Anything** is the type of an item of an untyped List (a List of Anything), a Table value (Get value, For each key/value), and Formulas that read Lists, Tables or Nodes. It fits every input, and GDScript checks the real value when the game runs.
- **Typed lists:** a List knows what its items are (a List of Number, of Text, of Label...), and its variable is declared as a typed Array (`var nums: Array[float] = []`).
  - Where the type comes from: Make list works it out from its values (Items: Auto) or takes the one picked in Items. Get children and Nodes in group make a List of their Type (`Array[Node]` without one). A typed-in empty List takes the type from its "of" dropdown (default Anything).
  - Get item and For each item give items of that type: a Get item of a List of Label is a Label, with its properties in the dropdowns.
  - Add to list (and a Make list with Items picked) refuses a value of another type with a compile error ("a List of Number can't hold a Text"). A Whole goes into a List of Number. A decimal going into a List of Whole is rounded (`roundi`).
  - When a List goes into a variable or property holding another kind of List: a List of Anything, or a List of Whole into a List of Number, is converted (`Array(<list>, TYPE_FLOAT, &"", null)`, checked when the game runs). A List of Number into a List of Whole is rounded (`.map(roundi)` first). Lists of unrelated types are a compile error ("'nums' is a List of Number, not a List of Text"). Any List goes into a List of Anything as it is.
  - Signals and network messages (Emit signal, Fire Server / clients `values`) carry Lists untyped.
- **Typed tables:** a Table knows what its keys and its values are (a Table of Text -> Number, of Text -> Label...), each side like a List's items, and its variable is declared as a typed Dictionary (`var scores: Dictionary[String, float] = {}`; Anything is `Variant`, both Anything a plain `Dictionary`).
  - Where the types come from: Make table works each side out from its rows (Keys / Values: Auto) or takes the type picked; a typed-in empty Table from its two "of" dropdowns (`Dictionary[String, int]({})` in the graph's text, `{}` in the code).
  - Get value of a typed Table is of the values' type; For each key/value fills `key` and `value` with the keys' and values' types.
  - Get value's key and fallback, and Set value in table's key and value, must fit (compile error: "Table of Text -> Number's values can't hold a Text"); a Whole goes where Numbers go; a decimal into Whole values is rounded (`roundi`).
  - A Table going into a variable of another kind of Table: a Table with Anything on a side the other has typed (or Whole where Numbers go) is converted (`Dictionary(<table>, TYPE_STRING, &"", null, TYPE_INT, &"", null)`, checked when the game runs); unrelated types, or Numbers into Whole, are a compile error ("'counts' is a Table of Text -> Whole, not a Table of Text -> Number").
  - Signals and network messages carry Tables untyped.
- **Typed-in text is safe:** it is written with `var_to_str()`, so it can never become code.

### Node types

A Node value also knows **what kind of node** it is: a node type `{"class": StringName, "script": String}` (`core/node_types.gd`), e.g. `{"class": &"CharacterBody2D", "script": "res://enemy.bricklocal"}`. `{}` means "some Node".

- **Where it comes from:** Get node and Spawn scene's **Type** / **Script** settings (a Type can also name a script class: `ObjectWhole` is a Node running `objects/object_whole.gd`, so its `value` is known; Find node has only Type); an Export's Type (for a Node value); Self (path `.`) is the brickscript's Extends type plus its own variables (a script node: `Node` plus its own variables); Self.Parent (path `..`) is the graph's `parent_type` (a script node: the node it works for). Variable (Set) and Output Vars carry it on.
- **Node inputs start at the parent:** the node bricks' Node input (Property (Get / Set), Call method, Wait for signal, Spawn scene's parent, Find node's under, Get children, the group bricks) defaults to `..`, Self.Parent (`get_parent()`; in a script node that's the node it works for, `_brickscript_body`; in a server brickscript, the parent of the node it's the server part of). Type Self (`.`) for Self. Mine? and Give To default to this node (they are about your own character). Graph files older than format 2 keep "this node" where an input was left at its default (`BrickFile.from_text`).
- **The parent's type:** the editor looks through the scenes that use this brickscript, or that instance a scene using it (a script on a scene's root has its parent there). It stores the type in the graph as `parent_type` when the brickscript is opened or saved, so the game's own compile gives the same code. If no scene says, it's "some Node": its members are used by name, with a warning. **Used under parents of different types** (2026-11-03): the type they all share (the nearest class; their script if all have the same one), and Properties (nothing selected) says which scene has which; a member only some of them have is used by name, with that warning.
- **Filled in for you:** picking a Get node path looks through the project's scenes that use this brickscript and fills in the class and script of the node at that path. Picking a scene for Spawn scene fills in its root's. Scenes are read as text, never loaded.
- **Self and Self.Parent** (user's choice, 2026-10-28: like Roblox's `script` / `script.Parent`): paths are shown and typed Roblox style. **Self** is the node the brickscript is: a script node itself (a brickscript attached to a node: that node; a server part: the node it's the server part of). **Self.Parent** is its parent, **Self.Parent.UI.Score** a child of the parent, **Self.Label** a child of Self. Files keep Godot's paths (`.`, `..`, `../UI/Score`, `Label`): `Types.path_shown` / `path_typed` convert, exactly both ways (Godot node names can't hold `.`). The box also takes Godot paths and `self` / `parent` in any case; an absolute path (`/root/...`), a `%Unique` name, a `:property` path or one through a node really named Parent stay Godot's. Long paths get long (`Self.Parent.Parent.Parent.UI.Panel`), as in Roblox.
- **Picking a path:** every node path (Get node's Path, a signal's Node, Sync's Node, and every typed-in Node input such as Property (Set)'s `of` or Spawn scene's `parent`) has a text box, a **dropdown** of the paths found (`Self.Parent.Parent.UI.Score · Label`), and a **step-by-step** picker: a tree starting at Self (its children) and Self.Parent (its other children, and its own parent, and so on), so you walk to the node instead of counting Parents.
- **A typed-in Node input keeps the node type its picker found** (stored with it as `"node"`, refreshed when the brickscript is opened or saved), so the next bricks offer its properties and the code uses them directly, in the editor and in the game.
- **Spawned scenes:** a scene no scene file contains (only spawned while the game runs) is placed where a brickscript's Spawn scene puts it (a typed-in `parent`, from the spawning node in its scenes). So a gem spawned under `Gems` knows its parent is the Gems node, and `../..` the level, with their types (`core/node_types.gd` `spawn_placements`).
- **What it gives:** Node variables are declared with the class (`var enemy: CharacterBody2D`, `@export var target: Sprite2D`), and the property / method dropdowns of the node bricks list what that type has: its script's variables first (another brickscript's Constants, Exports and Shared variables; a `.gd`'s variables, constants and methods), then the class's properties and methods from Godot's class data. Members whose types Brickscript doesn't have (Transform2D, NodePath arguments, ...) aren't listed.
- **In the code:** a class member is written directly (`sprite.position += step`); a script member by name (`enemy.get(&"health")`, `.set(...)`, `.call(...)`), since Godot's class data doesn't know it; this brickscript's own variables directly (`health += 5`). A member name that isn't known is a warning and is used by name.
- **Checked:** values against the member's type, read-only members and Constants, Property (Set)'s Add only on numbers / vectors, method value counts and types, Node classes against each other (a Label variable can't take a Sprite2D).

### Resources

Files such as textures, sounds, scenes and materials are **Resource** values. A Resource carries its class the way a Node carries its node type: a property or method value that takes one says which class (Sprite2D's `texture`: Texture2D; AudioStreamPlayer's `stream`: AudioStream; `material`: Material, the class its allowed kinds share).

- **Typing one in:** pick a project file. The dropdown next to the path lists only the files that fit (images for a texture, `.wav` / `.ogg` / `.mp3` for a sound; `.tres` / `.res` can hold anything). Picking a property or method sets the value's type to Resource for you.
- **A path as Text:** wherever a Resource goes, a Text value or variable also works, e.g. a path a Formula builds (`"res://sounds/" + name + ".wav"`). It's loaded with `load(<path>)` when the brick runs, so it can't be checked before: a wrong or missing file gives nothing (null). There's no separate file-path type.
- **In the code:** `load("<file>")` where it's used; a Constant uses `preload("<file>")` (constants need a constant expression, so the file must exist). A variable holding one is typed by its class (`var pic: Texture2D`).
- **Checked:** a file of the wrong kind is an error (a sound as a texture); a file that doesn't exist yet is a warning. A file's kind comes from its extension (`core/node_types.gd` `resource_class_of`, `resource_fits`, `resource_files`).

---

### Debugging

- **Every generated line names its brick:** the code a brick makes ends with `  # brick <id>` (`flow_compiler.gd` `marker()`), so the generated code reads back to the graph.
- **Runtime errors land on their brick:** while a game runs from the editor (under the debugger), the **BrickscriptDebug** autoload (`runtime/brick_debug.gd`, registered and removed with the plugin) watches the engine's errors. For one in a brickscript (a script error there, or an engine error raised by a call it made, found through the backtrace), it finds the brick of that line (`runtime/brick_debug_locate.gd`) and sends it to the editor (`EngineDebugger` message `brickscript:error`: file, brick id, line, text), once per brick and error. Outside a debug session (exported games, plain runs) it does nothing.
- **In the editor:**
  - the Brickscript tab lists **"Runtime error in <file>, <brick> (node <id>): <error>"** first under Problems (also on the start page)
  - clicking one opens that brickscript and selects and centres the brick
  - the brick is outlined in red, with the error as its tooltip, until the game runs again
  - when the debugger opens a brickscript at an error line (it does so by itself when the game stops at an error), the Brickscript tab shows that line's brick instead
- **Note:** a script error stops the rest of that function (normal GDScript behaviour), so later bricks of that event run don't run that time.
- **Arrange (spacing, user's choice 2026-10-28):** in a chain, each brick starts two grid squares (32 px) after the right edge of the brick it follows; a brick that several lead to, after the furthest; a chain's first brick (an event, an unwired brick) and every row (y) stay. The toolbar's **Arrange** does it for the selected bricks' chains, or every chain when none is selected (one undo step; `Ops.arranged_x` / `Ops.arrange` with the drawn sizes, `flow_canvas.gd` `arrange_chains`). A brick added by dropping a wire on empty space lands two squares after the brick it follows (on its row when dropped beside it, else on the row it was dropped on: a branch). Dropping one from the palette doesn't wire it, so it stays where it's dropped. `tests/run_layout_tests.sh` checks every project brickscript keeps this spacing, inside a headless editor (its sizes); `--arrange` arranges them all. That runs through the plugin's test hook: `godot --editor -- --brickscript-job=res://tests/<job>.gd` runs the job's `static func run(panel, args) -> int` with the editor's own Brickscript panel, then quits (plugin_main.gd `_start_job`; nothing happens without the argument).
- **Trace (running bricks light up):** the **Trace** toggle on the Brickscript toolbar (off by default; saved as the project setting `brickscript/debug/trace_bricks`, removed when off). With it on, a game run from the editor loads its brickscripts with a report before every brick (`_brickscript_trace(<id>)`; `brick_file.gd` `trace_enabled()`: debug build, debugger attached, setting on). The BrickscriptDebug autoload gathers which bricks ran and sends them about ten times a second (`brickscript:trace`: file, brick ids). In the open brickscript each brick that ran brightens and fades back over half a second, so busy chains (Every frame) glow and branches show which way they went. Exported games and runs with Trace off contain no tracing code. It takes effect from the next run, and the game runs a little slower while it's on.

---

## 2. Working bricks

Notation:
- **Inputs** list `name: allowed types = default`. "any" means every type.
- **Output** is the type of the brick's result, which goes to its Output Var.
- **Exits** are the brick's execution outputs. Every action brick has one execution input. `next`, `loop` and `done` also grow (`next_2`, ...: see "More outputs on every brick" in section 1).

### Brick families

Bricks that do one thing several ways share one palette entry (and one item in the canvas's add menu), named after the family. On the canvas the brick shows its own title ("Dig terrain", "Subtract"); the first dropdown in Properties (Mode, When, Operation...) switches it to another member. **The choice is the brick's type**: switching changes `type` (`Ops.change_type(graph, node, type)`), keeping the inputs and settings of the same name (new ones at their defaults), the Output if the new type still makes one, and its wires (an exit the new type lacks hands its wire to the exit at the same place: Walk to's Arrived becomes Follow's Next; the others are dropped). So files store the member's type and each member below keeps its own entry, code and rules. The dropdown offers only the members usable in the brickscript (a family's members share a palette group and a kind). Searching the palette for a member's name or option ("Dig", "Subtract") finds its family. Families: `core/flow_library.gd` `FAMILIES` (2026-11-03).

| Family (palette) | Dropdown | Members (option `type`) | Group |
|---|---|---|---|
| **When action** | When | Pressed `event_action_pressed`, Released `event_action_released`, Held `event_action_held` | Events (local) |
| **Player action** | When | Pressed `event_player_pressed`, Released `event_player_released`, Held `event_player_holds` | Events (server) |
| **Math** | Operation | Add `add`, Subtract `subtract`, Multiply `multiply`, Divide `divide` | Math |
| **Construct vector** | Size | Vector2 `make_vector2`, Vector3 `make_vector3` | Math |
| **Change terrain** | Mode | Dig `dig_terrain`, Fill `fill_terrain`, Paint `paint_terrain` | Terrain (server) |
| **Build or clear terrain** | Mode | Build `build_terrain`, Clear `clear_terrain` | Terrain (server) |
| **When terrain** | When | Ready `event_terrain_ready`, Cleared `event_terrain_cleared` | Terrain |
| **Add to mesh** | Kind | Triangle `add_triangle`, Quad `add_quad`, Shape `add_shape` | Mesh |
| **Walk** | Mode | To a spot `walk_to`, Follow `follow`, Stop `stop_walking` | AI (server) |
| **Group** | Mode | Add `add_to_group`, Remove `remove_from_group`, Check `is_in_group` | Nodes |
| **Health** | Mode | Damage `damage`, Heal `heal`, Kill `kill_character` | Character (server) |
| **Network session** | Action | Host `host`, Join `join`, Leave `leave` | Network (local, with the engine) |
| **When player joins or leaves** | When | Joined `event_player_joined`, Left `event_player_left` | Network |
| **Player data** | Mode | Save `save_player_data`, Load `load_player_data` | Network (server) |
| **Animation** | Mode | Play `play_animation`, Stop `stop_animation` | Animation (server) |
| **UI animation** | Mode | Play `play_ui_animation`, Stop `stop_ui_animation` | Animation (local) |
| **Tween** | Mode | Start `tween_property`, Stop `stop_tweens` | Animation |

### Events

Several events that map to the same Godot callback are merged into one function, each behind its own `if` guard.

#### `event_ready`: When ready
- Runs once when the node enters the scene tree.
- **GDScript:** `func _ready() -> void:`
- **Exits:** numbered outputs `1`, `2`, ...

#### `event_process`: Every frame
- Runs every rendered frame.
- **Settings:** `runs_on` (server brickscripts: see "Predicted events" in section 1).
- **Provides:** `delta` (Number, seconds since the last frame).
- **GDScript:** `func _process(delta: float) -> void:` (the parameter becomes `_delta` when unused)
- **Exits:** numbered outputs.

#### `event_physics_process`: Every physics frame
- Runs every physics tick, at a fixed rate, before Godot moves physics bodies. Godot has no "after physics" callback.
- **Settings:** `runs_on` (server brickscripts: see "Predicted events" in section 1).
- **Provides:** `delta` (Number).
- **GDScript:** `func _physics_process(delta: float) -> void:`
- **Exits:** numbered outputs.

**This machine's input vs. players' input.** The three events below are **local** only: keys pressed on this machine, for what this machine shows (a menu, the camera). The game runs in the server brickscript, which reads **players'** input with the five bricks after them: each client sends its held Input Map actions to the server when they change (Network Context Engine API 6+, its `PlayerInput`); the server's own player (the host, offline: player 1) is read from Input. Without the engine, player 1's input is this machine's. While a text box has focus, typing isn't input (every action counts as released). A tap shorter than a frame still counts (as held for one update).

#### `event_action_pressed`: When action pressed
- Local brickscripts only. Runs when an Input Map action is pressed on this machine (unhandled input).
- **Settings:** `action` (Input Map action name, default `ui_accept`; an unknown action gives a warning), `who` (Runs on: **Only nodes I own** (default) / Every copy).
- **Only nodes I own:** input only ever happens on the machine whose keys were pressed, but in a networked game that machine has a copy of every player's node, all running the same local brickscript. So by default the event only runs on the copy that is this machine's player's (Mine?: its own character; on the host and offline also what's no one's). Every copy runs it on all of them (e.g. a menu). The check is only added in projects with the Network Context Engine. On a client, a key for a node **no player owns** (not given to anyone) doesn't run it, and says so once with a warning naming the brick (2026-10-31): set Runs on to Every copy and send the press to the server (Fire Server), or give the node to the player first.
- **GDScript:** inside `_unhandled_input(event: InputEvent)`: `if event.is_action_pressed("<action>") and _brickscript_owns(self, "When action pressed (node <id>)"):` (`_brickscript_owns(node, brick)` asks `/root/NetworkEngine.is_mine(node)` (API 7; `is_authority` before), true without it).
- **Exits:** numbered outputs.

#### `event_action_released`: When action released
- Same as above (also `who`), for release: `if event.is_action_released("<action>") and _brickscript_owns(self):`

#### `event_action_held`: While action held
- Runs every frame while the action is held.
- **Settings:** `action`, `who` (as above).
- **Provides:** `delta`.
- **GDScript:** inside `_process(delta)`: `if Input.is_action_pressed("<action>") and _brickscript_owns(self):`

#### `key_direction`: Key Direction
- Local brickscripts only. Which way this machine's keys push: a Vector2 at most 1 long (x: left -1 / right 1, y: up -1 / down 1). Analog sticks give in-between values. In 3D use x and y as x and z. For moving your own character from its local brickscript once the server gave it to you with Moved By (the Roblox model), single-player too: without Moved By the change is refused. Without a Moved By, move it from the server instead: Every frame into Player Direction (Player blank) into Property (Add) in its ServerScript.
- **Settings:** `left`, `right`, `up`, `down` (actions; a new brick gets `move_left`, `move_right`, `move_forward`, `move_back` when the project has them, else the defaults `ui_left`, `ui_right`, `ui_up`, `ui_down`, as Player Direction).
- **Output:** Vector2. **GDScript:** `<output> = Input.get_vector("<left>", "<right>", "<up>", "<down>")`.
- **Exits:** `next`.

#### `event_player_pressed`: Player Pressed / `event_player_released`: Player Released
- Server brickscripts only. Runs when a player's Input Map action goes down / up.
- **Settings:** `action` (default `ui_accept`), `whose` (**Any player** (default) / **This node's player**: only the player Owner gives for this brickscript's node, e.g. their character), `runs_on` (see "Predicted events" in section 1).
- **Provides:** `player` (Player).
- **GDScript:** its own function `_brickscript_action_pressed_<id>(player: int, action: StringName)` (`_released_`) with `if action == "<action>":` (and `and player == _brickscript_player_of(_brickscript_body)` for This node's player), connected at the start of `_ready` by `_brickscript_on_player_actions(&"player_action_pressed", <function>)`: `NetworkEngine.player_action_pressed / _released`; without the engine, this machine's actions are checked every frame (`Input.is_action_just_pressed`) as player 1's.
- **Exits:** numbered outputs.

#### `event_player_holds`: Player Holding
- Server brickscripts only. Runs every frame for each player holding an action (one run per player).
- **Settings:** `action` (default `ui_accept`), `whose` (as above), `runs_on` (as above).
- **Provides:** `player` (Player), `delta`.
- **GDScript:** its own function `_brickscript_held_<id>(player: int, delta: float)`, called from `_process(delta)`: `for _holder: int in _brickscript_players_holding("<action>"): _brickscript_held_<id>(_holder, delta)` (`NetworkEngine.get_players_holding`; without the engine `[1]` while this machine holds it).
- **Exits:** numbered outputs.

#### `player_held`: Player Holds?
- Server brickscripts only. Whether a player holds an action right now.
- **Inputs:** `player: Player` (blank: this node's Owner, in single-player you, as Player Direction's). **Settings:** `action`.
- **Output:** Bool. **GDScript:** `<output> = _brickscript_player_strength(<player>, "<action>") > 0.0` (`NetworkEngine.get_player_action_strength`, 0..1).
- **Exits:** `next`.

#### `player_direction`: Player Direction
- Server brickscripts only. Which way a player is pushing: a Vector2 at most 1 long (x: left -1 / right 1, y: up -1 / down 1), like `Input.get_vector`. Analog sticks give in-between values. In 3D use x and y as x and z.
- **Inputs:** `player: Player`, **blank** (2026-10-30): this node's Owner; a node no player owns is yours in single-player (player 1), no one's in a network game. So **Every frame** into Player Direction moves a node in all four directions (Getting started, step 4). **Settings:** `left`, `right`, `up`, `down` (actions). A new brick (`Ops.add_node`, the editor) gets the characters' `move_left`, `move_right`, `move_forward`, `move_back` when the project's Input Map has them (setting key `preferred`), else the defaults `ui_left`, `ui_right`, `ui_up`, `ui_down` (also what a file without these settings compiles with).
- **Output:** Vector2. **GDScript:** `<output> = _brickscript_player_direction(_brickscript_peer(<player>), "<left>", "<right>", "<up>", "<down>")`; a blank player is `_brickscript_owner_or_me(<this node>)` (a spec's `blank` code in `flow_library.gd`).
- **Exits:** `next`.

### Flow

#### `if`: If
- Branches on a condition.
- **Settings:** `operator`, one of `is true`, `is false`, `is null`, `is not null`, `==`, `!=`, `<`, `<=`, `>`, `>=` (default `is true`).
- **Inputs:**
  - `a: any = Variable ("")`
  - `b: any = Number 0`. B is used only by the two-sided comparisons.
- **Rules:**
  - `is true` / `is false` need A to be a Bool.
  - `is null` / `is not null` need A to be a Node, a Resource, a Player or Anything (e.g. a List item). A node that was freed counts as null, so this is also the "is it still valid?" check (e.g. before using a node kept in a List). A Player is null when it's "no player" (`a == 0`). Other types are never null, so they're a compile error.
  - `<`, `<=`, `>`, `>=` need numbers (Number or Whole) on both sides; Anything is allowed and checked at runtime.
  - `==` and `!=` need matching types.
- **GDScript:** `if a:` / `if not a:` / `if a < b:`, with an `else:` when the False exit is wired. `is null` is `if not is_instance_valid(a):` for a Node or Resource and `if _brickscript_is_null(a):` for Anything (a helper at the end: null, or a freed object); `is not null` is the opposite.
- **Exits:** `true`, `false`. There is no "next": put shared follow-up bricks after both branches, and they are written into each branch.

#### `for_each`: For each item
- Runs the Loop body once per item of a List. **A node freed while still in the List** (an enemy that died) **is passed over** (2026-11-03): the body doesn't run for it, so it can't error; null and other values still run. Only Lists that may hold nodes (of a node type, or Anything) get this check (`if typeof(item) == TYPE_OBJECT and not is_instance_valid(item): continue`). Get item still gives a freed node; If's `is null` counts it as null.
- **Inputs:** `list: List = Variable ("")`
- **Settings:**
  - `item_name` (default `item`): chain variable, the List's item type (Anything for an untyped List).
  - `index_name` (default `index`): chain variable, type Whole.
  - Blank names are not kept.
- **GDScript:**
  ```gdscript
  for _i_<id>: int in range(len(list)):
      if typeof(list[_i_<id>]) == TYPE_OBJECT and not is_instance_valid(list[_i_<id>]): continue  # a List that may hold nodes
      index = _i_<id>
      item = list[_i_<id>]
      <Loop body>
  <Done>
  ```
  The named variables keep their last values after the loop. The hidden counter means nested loops never clash.
- **Exits:** `loop` (Loop body), `done` (Done, runs after the loop).

#### `for_each_pair`: For each key/value
- Runs the Loop body once per key of a Table. A freed node as its key or value is passed over, as in For each item (2026-11-03).
- **Inputs:** `table: Table = Variable ("")`
- **Settings:** `key_name` (default `key`), `value_name` (default `value`). Both are chain variables: of the Table's key and value types (Anything for an untyped Table).
- **GDScript:** `for _k_<id>: Variant in table:` then (keys / values that may be nodes) the freed checks, `key = _k_<id>`, `value = table[_k_<id>]`.
- **Exits:** `loop`, `done`.

#### `repeat`: Repeat N times
- Runs the Loop body a number of times.
- **Inputs:** `times: Number or Whole = Whole 3` (a Number is rounded).
- **Settings:** `index_name` (Counter, default blank = not kept): chain variable, Whole, counting from 0.
- **GDScript:** `for _i_<id>: int in range(times):`
- **Exits:** `loop`, `done`.

#### `while`: While
- Runs the Loop body again and again while a comparison holds, checked before each round (so it may run 0 times); Done runs once it doesn't. The comparison is If's (see `if`: `operator`, `a`, `b`; the same rules and errors), so the Loop body must change what it compares (a Shared variable, a property), or it runs until the Safety limit.
- **Inputs:** `a: any`, `b: any` (only for the two-sided comparisons), `limit: Number or Whole = Whole 10000` (the Safety limit: the most rounds; a Number is rounded). **Settings:** `operator` (Compare).
- **GDScript:** `for _w_<id>: int in range(<limit> + 1):` then, in the loop, `if not (<comparison>): break` and `if _w_<id> == <limit>: push_error("While (brick <id>): stopped at its Safety limit (<limit> rounds); does its comparison ever change?" ...); break`, then the Loop body. A Wait in the body makes a loop that waits each round (the event gets its own function, like any Wait).
- **Exits:** `loop`, `done`.

#### `reroute`: Reroute
- A point on a wire, to bend it around other bricks (a small dot: no title, not resizable). Nothing runs there: what it's wired to runs next.
- **Editor:** double-click a wire to put one on it (wired in between: `Ops.insert_reroute`); deleting one keeps the wire, straight to what it led to (`Ops.delete_node`). It's also in the palette (Flow).
- **GDScript:** none (a branch or Loop body with only reroutes gets `pass`); Trace never lights it.
- **Exits:** `next`.

#### `break`: Break / `continue`: Continue
- Inside a Loop body (For each item, For each key/value, Repeat, While; an If inside one is fine): **Break** leaves the loop at once, its Done runs next; **Continue** skips the rest of this round, the next round starts (While checks its comparison again). In nested loops, the innermost one.
- **GDScript:** `break` / `continue`.
- **Rules:** anywhere else is a compile error ("only works inside a loop's Loop body").
- **Exits:** none (nothing runs after it in this round).

#### `wait`: Wait
- Pauses the rest of its chain for some seconds, then carries on. Other events keep running meanwhile.
- **Inputs:** `seconds: Number or Whole = Number 1`.
- **GDScript:** `await get_tree().create_timer(<seconds>).timeout`
- **Exits:** `next`.
- **Waiting events:** an event whose chains use Wait or Wait for signal runs in its own function, `_brickscript_run_<event id>(<its parameters>)`, called (without waiting) from Godot's callback. So a Wait in one "When action pressed" doesn't hold up another event that shares `_unhandled_input`. Within the event, outputs still run in order: output 2 starts when output 1, Wait included, has finished. A Wait under Every frame starts a new wait every frame.

### Signals

Godot nodes announce things with signals (a Timer's `timeout`, a Button's `pressed`, an Area2D's `body_entered`). The signal dropdowns list what the node's type has (see "Node types"), including another brickscript's own signals, and for this node the ones its Emit signal bricks send.

#### `event_signal`: When signal received
- An event: runs when the node sends the signal.
- **Settings:** `path` (Node: a path from Self, blank = Self, with the Path dropdown of Get node; a new one in a script node starts at Self.Parent; its own signals (an Emit signal here) are Self's), `node_class` / `node_script` (filled in from the path), `signal`.
- **Provides:** the signal's values by name and type (e.g. `body` as a Node2D for `body_entered`; `value_1`, `value_2`, ... for a brickscript's own signals). A signal Brickscript doesn't know (a warning) gives its values as the List `values`.
- **GDScript:** `func _brickscript_signal_<id>(<values>) -> void:`, connected as the first thing in `_ready` (`get_node(NodePath("<path>")).connect(&"<signal>", _brickscript_signal_<id>)`; `self.connect(...)` for this node). An unknown signal's function takes `...values: Array`.
- **Exits:** numbered outputs.

#### `emit_signal`: Emit signal
- Sends this brickscript's own signal.
- **Settings:** `signal` (its name: a plain name, not a variable's).
- **Inputs:** rows `value_1`, `value_2`, ... (any; + / −; starts with none).
- **GDScript:** `<signal>.emit(<values>)`; the script declares `signal <signal>(value_1: <type>, ...)` from the values. Every Emit signal of one signal must send the same kinds of values.
- **Exits:** `next`.

#### `wait_for_signal`: Wait for signal
- Pauses the rest of its chain until a node sends a signal (e.g. `animation_finished`). Counts as a Wait (see above).
- **Inputs:** `of: Node = parent`.
- **Settings:** `signal` (dropdown of what `of` has).
- **GDScript:** `await Signal(<of>, &"<signal>")`
- **Exits:** `next`.

### Network

Offered only while the Network Context Engine is installed. Two pairs of bricks send **messages**: a name (the **Message** setting, typed in) and values (rows of inputs, + / - for more). A Tell brick and a When brick with the same message name go together. Values arrive as the List `values` (read items with Get item); Nodes can't be sent.

The local script (`.bricklocal`, on every machine) talks to its node's server part (`.brickserver`, only where the game has server authority) through its own copy on the server. Offline and on the host, the game is its own server and client, so the same bricks work there without a network.

#### `tell_server`: Fire Server
- Local brickscripts only. Sends the message to this node's server brickscript (its **On Client Fired** with the same name).
- **Settings:** `message` (Text, default `hello`, must not be empty).
- **Inputs:** rows `value_1`, `value_2`, ... (any; default 1 row).
- **GDScript:** `_brickscript_tell_server("<message>", [<values>])`. The script also gets:
  - `_brickscript_tell_server(message, values)`: calls `NetworkEngine.call_on_server(self, "_brickscript_client_told", [message, values])`; without the engine it hands the message (sender 1) to the node's own "ServerPart" (see "Without the Network Context Engine").
  - `@rpc("any_peer", "call_remote", "reliable") _brickscript_client_told(message, values)`: runs on the server's copy of the node; hands the message, with `get_caller_id()` as the sender, to `NetworkEngine.get_server_part(self)` (deferred one step, so a message sent from When ready arrives after the server part exists).
- **Exits:** `next`.

#### `invoke_server`: Invoke Server / `event_client_invokes`: On Client Invoked / `answer_client`: Answer
- Like Roblox's RemoteFunction: a local brickscript asks its server side a question and waits for the answer (can I buy this? what does it cost?).
- **Invoke Server** (local brickscripts): settings `message`; rows of `value_N` (any), sent as a List; the Output Var (optional) gets the answer (Anything). It waits (like a Wait: its event gets its own function), at most 5 s, then gives nothing (null) with a warning naming the brick. Offline, or without the engine, the game is its own server. **GDScript:** `<output> = await _brickscript_invoke("<message>", [<values>], "Invoke Server (brick <id>)")`.
- **On Client Invoked** (server brickscripts): runs for that message, with `values` (List) and `sender` (Player, the asker); check the values first. **GDScript:** `func _brickscript_on_client_invoked(message: String, values: Array, sender: int, request: int, asker: Node)` with `if message == "<message>":` (one function for every On Client Invoked of the brickscript).
- **Answer** (server, only in an On Client Invoked chain, and not after a Wait: compile errors otherwise): input `value: any = Bool true`, sent back to the asking machine only. **GDScript:** `_brickscript_answer(asker, sender, request, <value>)`.
- **How:** the question goes to the asking node's own copy on the server (`call_on_server`, like Fire Server), which hands it to its server side (the ServerScript nodes beside it, or its server part) with a request number; Answer replies through that copy (`call_on_peer` to the asker; on the host / offline directly), and the asker matches the number.
- **Exits:** `next` (Invoke Server, Answer); numbered outputs (On Client Invoked).

#### `event_client_tells`: On Client Fired
- Server brickscripts only. Runs on the server when a client (or the host itself) sends this message with Fire Server.
- **Settings:** `message` (Text, default `hello`).
- **Provides:** `values` (List, read-only), `sender` (Player: who sent it; player 1 = the host / offline). Check `sender` before trusting the values: any client can send any message (e.g. If `sender == Owner` of the node it's about).
- **GDScript:** `func _brickscript_on_client_told(message: String, values: Array, sender: int) -> void:` with `if message == "<message>":` (events with different messages share the function).
- **Exits:** numbered outputs.

#### `tell_clients`: Fire Clients
- Server brickscripts only. Sends the message to this node's local brickscript (its **On Server Fired** with the same name) on every client and the host, or on one client.
- **Settings:** `message` (Text, default `hello`), `to` (All clients / One client).
- **Inputs:** `client: Player` (only used for One client: e.g. `sender`, the `player` of Player Joined, or Owner of a character), then rows `value_1`, ... (any).
- **GDScript:** `_brickscript_tell_clients("<message>", [<values>], <client, or -1 for all>)`. The helper calls the parent node's `_brickscript_server_told` through `NetworkEngine.call_on_all` (-1) or `call_on_peer` (a player), or directly without the engine. Nothing happens if the local script has no On Server Fired, if that player has left the game, or for no player (0).
- **Synced values arrive first** (Network Context Engine API 18, 2026-10-30): a Synced variable or Sync'd property the server changed before Fire Clients (or Answer, Fire Clients to one client) already has its new value when On Server Fired runs there. The engine sends the changes made so far, reliably, just before the message; only movement (position, rotation...) still glides in, so it may read a moment behind. Before API 18 the message could arrive first and read the old value (a usability run found it).
- **Exits:** `next`.

#### How a networked game fits together

- **Every machine has a copy of every node.** A local brickscript runs on all of them; a server brickscript (the server part) only on the server, and there its **"this node" is the node it belongs to** (its parent, `_brickscript_body` in the code: node paths start from there too, and its dropdowns come from the paired local brickscript's variables and its class).
- **The server runs the game** (Network Context Engine API 7): it is in control of every node. Nodes a server brickscript (or any server script) adds to the game scene reach every machine, late joiners too; a client that adds one, frees a spawned one or changes a synced value has it undone, with an error. Local-only nodes (UI, cameras, sounds, particles, timers, the `local_only` group) stay where they were made.
- **Input (the Roblox model):** a local brickscript reads its machine's keys (When action pressed / released, While action held, Key Direction, Mouse to World). It moves its own character with them (the server gave it with Moved By), shows what only it sees, and sends the rest to the server with Fire Server / Invoke Server, where the server brickscript checks it and changes the game. Server-authoritative games can instead read players' keys on the server (Player Pressed, Player Holding, Player Direction, Player Aim; each machine sends them).
- **Changes reach everyone** when what's changed is synced: a Synced variable, or a property named by a Sync brick (a server brick). Changes come from the server: local brickscripts don't change the game (see "What a local brickscript may change").
- **The server decides** what must be fair: clients ask with Fire Server; the server brickscript checks and changes synced things.
- **Spawning:** a server brickscript's Spawn scene spawns for every machine. Player Joined (which also runs for the players already there, you included) is where to make each player's character: Spawn scene For a player: their character.
- **Joining** replaces the single-player world: what this machine spawned offline is freed (Network Context Engine), and the server's arrives.
- Example: the sandbox `game/sandbox/` (the main scene, and the project's main example), built the Roblox way around a **PlayerService** (see "Players and their values" and the Character Spawner): SpawnPoints (four), StarterPlayer (`gems`, `collected`), StarterCharacter (a ServerScript, `ping_on_hit.brickserver`), Players, Characters (spawns the FPS character for every player) and Menus (the Host / Join menu, its title and controls line). No brick spawns characters or runs the lobby. The character is the reusable first-person one in `game/characters/fps/` (`player.tscn`, a **Character3D**: WASD / Space on its player's machine, its own camera at its eyes, mouse look; `player.bricklocal` sprints with Shift (Set Character) and shoots: a click while looking around sends the ray through the middle of the camera (Mouse to World: The middle of the screen) with Fire Server "shoot"; `player.brickserver` believes it only from that character's own player (sender == Owner), starting at its eyes, at most 100 m long, casts it, prints who hit where ("player Tester hit (x, y, z)"), emits its own signal `hit` (where, who), and when what it hit is a character (`target.has_method("damage")`) does **Damage** `DAMAGE` (an Export, 25, shown on the character's Inspector) By the shooter). The sandbox reacts without touching the character: StarterCharacter's `ping_on_hit.brickserver` (copied into every character, on the server) hears that `hit` (When signal received, path `ServerScript`) and spawns `ping.tscn` there under Pings for everyone, freed 1.5 s later. StarterCharacter also holds `health_hud.bricklocal` (a LocalScript: only on that character's player's machine): its health in the HUD (When ready, the character's `health_changed` signal, When character died: "Health: 0 (you died)"). `sandbox.brickserver` prints every player's death (When character died, If player is not null: "Tester_2 killed Tester", or "Tester died" with no killer, a fall). **An NPC** (`game/characters/npc/npc.tscn`, in the group `npcs`: a Character3D with Controlled by: Script, walk speed 3.5, three Timers and a ServerScript, `npc.brickserver`, whose Exports SIGHT 12, VIEW 140, TOUCH 1.6, BITE 10 are on the NPC's Inspector): Think (4 times a second: Nearest character within SIGHT, Can see it, Follow it; out of sight, Stop walking), Wander (every second, not chasing and not walking: Walk to a Random reachable spot within 6), Bite (every second: Damage a player's character within TOUCH by BITE). The sandbox keeps `NPCS` of them (an Export on its ServerScript, 1) from its GemTimer (Get children of Npcs, then Spawn scene at a Random reachable spot) and says who took one down ("Tester took down the NPC"). **The ground is a Terrain** (the Terrain Engine plugin, 2026-10-31): Smooth, 32 x 32 blocks, seed 5, gentle hills 0.5 to 2.1 m high, grass colors; the Walls (the arena's edges) and the Crates stand on it. Its navigation comes from the Terrain (on the server: baked per chunk column, the Walls and Crates in the group `navigation_geometry` cut out; call its `rebuild_navigation()` after moving them); there's no NavigationRegion3D. The GemTimer puts each gem 0.75 m above the ground with **Terrain height**; the spawn points and crates are set at the ground's height. `sandbox.bricklocal` shows your gems and collected kinds in a corner (Player Value Changed, Whose: Me) and prints who joins / leaves; `sandbox.brickserver` tops gems up from a Timer (only where Bodies near finds nothing, not on a spawn point) and prints each new character (When character spawned). `gem.brickserver` spins the gem, gives its mesh its kind's material (the kind is its LocalScript's Synced variable: the sandbox sets it through As script) and syncs rotation, visibility and the material; it takes a gem when a body that is a player's character touches it, adds one to Owner's `gems` and its kind to their `collected` and tells only them, whose `gem.bricklocal` plays a sound and shakes their camera a little. `tests/run_brickscript_sandbox_test.sh` plays it with a real host and client (`tests/brickscript_sandbox_test.gd` single-player; also inside exported builds, where the dedicated server hosts by itself).

#### `host`: Host / `join`: Join / `leave`: Leave
- Local brickscripts only.
- **Inputs:** Host: `port: Whole = 7000`. Join: `address: Text = "127.0.0.1"`, `port: Whole = 7000`. Leave: none.
- **Output:** Host / Join: optional Bool, true if it started; false if this machine is already in a game (Leave first) or hosting failed (port taken).
- **GDScript:** `_brickscript_connect(&"host", [<port>])` (`== OK` into the output), `_brickscript_connect(&"join", [<address>, <port>])` (both only from single-player, else `ERR_ALREADY_IN_USE`), `_brickscript_network(&"leave", [])`; both helpers call `/root/NetworkEngine` by name.
- **Leaving** frees what the server had spawned on this machine (Network Context Engine), so single-player starts clean and a later Join doesn't clash with leftovers.
- **Exits:** `next`.

#### `event_player_joined`: Player Joined / `event_player_left`: Player Left
- **Provides:** `player` (Player: who joined / left; the host is player 1). While Player Left runs, the player's data, Character and Owner still answer (e.g. to free their character); right after, they're gone.
- Player Joined also runs once for each player already in the game when this node is ready, you included (offline: you, player 1), so the host's and a single player's own character are made the same way as everyone else's.
- **It waits for the username** (2026-10-30, at most `PLAYER_NAME_WAIT_SEC`, 2 s, like the Character Spawner): `player` is then `Tester_2`, not the stand-in `Player<number>`, so a "Welcome, <name>!" chain greets them by name. A player who leaves meanwhile isn't announced, and (2026-10-30) neither is their leaving: that brickscript's Player Left skips a player its Player Joined never announced, so a chat shows no goodbye without a welcome. Otherwise Player Left runs at once.
- **GDScript:** `func _brickscript_player_joined_<id>(_peer_player: int) -> void:` (`_left_`) starting with `var player: BrickscriptPlayer = _brickscript_player(_peer_player)`, connected at the start of `_ready` with `_brickscript_on_players(&"player_joined", ...)` (the engine's `player_joined` / `player_left` signals; Player Joined through `_brickscript_named_join`, which waits for the name).
- **Exits:** numbered outputs.

#### `this_player`: Owner
- The player a node belongs to: the one **Give To** handed it to, or handed one of its parents to. So everything under a player's character belongs to that player, including nodes added under it later, on every machine (clients and late joiners are told).
- **The server's things are no player:** a node that was never handed over (a gem, a door, the level) gives "no player", even on the host. Check with If `is null`. The host's own character is player 1 once Give To hands it to player 1.
- A player who leaves owns nothing any more.
- **Inputs:** `of: Node = this node`.
- **Output:** Player.
- **GDScript:** `<output> = _brickscript_player(_brickscript_player_of(<of>))` (helper: `NetworkEngine.get_player_of(node)`, API 4; 1 without the engine, where the game is single-player; then that player's node).
- **Exits:** `next`.

#### `my_player`: Me
- Local brickscripts only. The player of this machine (the host is player 1; offline you are player 1). `Owner == Me` asks "does this belong to me?" about a player (Mine? asks it about a node).
- **Output:** Player.
- **GDScript:** `<output> = _brickscript_player(_brickscript_my_player())` (`NetworkEngine.get_local_peer_id()`, then that player's node).
- **Exits:** `next`.

#### Players and their values (`BrickscriptPlayers`, `BrickscriptPlayer`, the Object values)
Like Roblox's Players service: a **Players** node (`addons/brickscript/runtime/players.gd`) holds a node per player, **`Players/<name>`** (`BrickscriptPlayer`, `runtime/player.gd`), on every machine; it's removed when they leave (after Player Left runs). Put a Players node in the game scene (the FPS example: `PlayerService/Players`); a scene without one gets one (`Players`, under the scene's root) the first time a brickscript asks for a player.

- **Names:** each machine has a **profile**, saved on it (`user://brickscript_profile.cfg`, `runtime/profile.gd`): a username (first the computer's user name; changed in the network menu's Name box) and a **user ID**, made once at random and never changed (two players with the same name are still different users, and a rename keeps it; there are no logins, so a modified game could still send any ID). The server names everyone's node in the order they joined: a second `xdmonster` is `xdmonster_2`. A player node has `peer_id` (their number in the network: the host is 1), `username`, `user_id`, `get_character()`, `is_me()`; `str()` of it is its name.
- **Values (Object Bool / Number / Whole / Text / Vector2 / Vector3 / Color):** nodes with one `value` and a `changed` signal (`ObjectBool`, `ObjectNumber`, `ObjectWhole`, `ObjectText`, `ObjectVector2`, `ObjectVector3`, `ObjectColor`, `runtime/objects/`, like Roblox's BoolValue / NumberValue...). Add them as children of **StarterPlayer** (a `BrickscriptStarter`, the Players node's `starter`, default `../StarterPlayer`): every player gets a copy, starting at those values each game (Players/xdmonster/gems). (Before 2026-10-27 the Players node's own children were the template; a Players node with children of its own now says to move them.) A value **under a player** travels with the player's data (late joiners get it); a value **anywhere else** is synced like a Sync brick's property. **Only the server changes them** (a local brickscript can't: they aren't local-only nodes); a player asks with Fire Server, and the server checks it. Read and change them with the node bricks: Find node (`under`: the player, `name`: `gems`, Type: `ObjectWhole`) then Property (Get) / Property (Set or Add) `value`.
- **Names while joining:** the server learns a player's username only after they join, so for that first moment their node is `Player<number>`; it's renamed when the username arrives. Every machine sends its profile as it hosts or joins (2026-10-30, the BrickscriptDebug autoload: `BrickscriptPlayers.announce_profile`), even one whose brickscripts never ask for a player (until then a client sent it only once something there asked, so a game with only server brickscripts showed clients as `Player<number>` in Player Pressed and the like). Back in single-player (you left, or the host did) you are your profile's name again, not the game's `_2` (2026-10-30). Player Joined and the Character Spawner wait for it (up to 2 s), so they see the real name; other bricks reading the Players node in that moment see the stand-in. A name stays for the session: when others leave nobody is renamed; a newcomer gets the first free `_2`, `_3`...
- **Every machine builds its own player nodes** from the players' data (the Players node is in the `local_only` group: the engine doesn't send the server's or remove a client's); in a Formula `player.peer_id`, `player.username` and `player.user_id` read them.
- Examples: the sandbox (`gems`, `collected`), the sandbox's `PlayerService/Players`; tested by `tests/run_players_test.sh` (host + client: names, values arriving, Player Value Changed, a rename).
- **Saved:** the profile (username + user ID) on each machine. Players' values only when a server brickscript says so: **Save player data** / **Load player data** (below); otherwise they start fresh every game.
- **StarterPlayer and StarterCharacter** (`BrickscriptStarter`, `runtime/starter.gd`, like Roblox's StarterPlayer / StarterCharacterScripts): their children are copied into every player node (the Players node's `starter`) / every character (the Character Spawner's `starter_character`): Object values and other nodes on every machine, **LocalScript** nodes only on that player's own machine, **ServerScript** nodes only where the game runs. While the game runs the templates aren't in the scene, so nothing runs there. A character's copies are made by every machine itself (in the `local_only` group; values in them are synced from the server by path). In the editor, a brickscript inside them acts for what it runs on: in StarterPlayer for a player node (BrickscriptPlayer: the values beside it are under it, its parent is Players), in StarterCharacter for the spawner's character (its scene's root type, with that scene's nodes: Head, Shape...; its parent is where characters go). (2026-11-01) A LocalScript copy's **Fire Server** reaches the ServerScript nodes beside it (its On Client Fired, with `sender`) although the server has no copy of that LocalScript: it goes through the BrickscriptDebug autoload (`relay_told`), so a StarterCharacter's local script can ask its character's server script for something (the cave game's click to dig: `game/caves/dig.bricklocal` / `dig.brickserver`). Check `sender` there (any client can name any character). The other way works too: **Fire Clients** from a ServerScript beside such copies (the node a starter copied into) goes through the autoload (`relay_server_told`) and reaches the LocalScript copies beside it on their player's machine (On Server Fired; One client / All clients as usual). The cave game answers a dig with Fire Clients dug, and the digger's camera shakes.
- Replaces the player data bricks (Get Data, Set Data, Set My Data, Data Changed), removed 2026-10-27.

#### `event_player_value_changed`: Player Value Changed
- Runs on every machine when a value under a player changes (the server's change, or its arriving on this machine), with the player and the new value. Also once for the values already there when this node is ready, so a score shows from the start.
- **Settings:** `value_name` (**Value**: the value's name under the player, default `gems`; `stats/kills` for one in a folder), `whose` (**Whose**: Any player (default) / Me: only this machine's player).
- **Provides:** `player` (Player), `value` (Anything: the new value).
- **GDScript:** `func _brickscript_value_changed_<id>(player: BrickscriptPlayer, value_name: String, value: Variant) -> void:` guarded by `if value_name == "<value>"` (`and player.is_me()` for Me), connected at the start of `_ready` with `_brickscript_on_player_values(...)` (the Players node's `player_value_changed`, plus a deferred call per value already there).
- **Exits:** numbered outputs.

#### `event_player_renamed`: Player Renamed
- (2026-10-30) Runs on every machine when a player's name changes, with the player and their new name: a joining player's username arriving (for their first moment a player can be the stand-in `Player<number>`: bricks reading the Players node then, before Player Joined's wait, see that name), or a player changing it (the menu's Name box; in code the Players node's `set_my_username(name)`, e.g. `BrickscriptPlayers.of(self).set_my_username("Zed")`: there's no brick for it). Two players swapping names report only their final names; a name set back to what it was isn't reported.
- **Settings:** `whose` (**Whose**: Any player (default) / Me: only this machine's player).
- **Provides:** `player` (Player), `new_name` (Text: their name now, the same as `str(player)`).
- **GDScript:** `func _brickscript_player_renamed_<id>(player: BrickscriptPlayer, new_name: String) -> void:` (guarded by `if player.is_me()` for Me), connected at the start of `_ready` with `_brickscript_on_player_renamed(...)` (each player node's `renamed`, checked once the frame's renames are done; players added later are followed too).
- **Exits:** numbered outputs.

#### `save_player_data`: Save player data
- Server brickscripts only. Saves a player's values (their Object values under `Players/<name>`, by their path under the player) on the server's disk, in a file under their user ID (`user://brickscript_saves/<user ID>.cfg`). Nothing is saved unless a brick says so: in Player Left (the player node still answers there), or after a change.
- **Inputs:** `player: Player`.
- **Output:** Bool `Saved`: whether it worked (false, with an error: no player, not the server, no user ID yet).
- **GDScript:** `<output> = _brickscript_player_data(<player>, true)` (helper: `BrickscriptPlayers.of(self).save_data(node)`).
- **Exits:** `next`.

#### `load_player_data`: Load player data
- Server brickscripts only. Sets a player's values to the ones Save player data saved for their user ID (each value they have; the server sends them, so everyone sees them). Use it in Player Joined. User IDs aren't proof (no logins: a modified game could send another's ID).
- **Inputs:** `player: Player`.
- **Output:** Bool `Found`: whether anything was saved for them (false: a new player; their values stay as StarterPlayer gave them).
- **GDScript:** `<output> = _brickscript_player_data(<player>, false)` (helper: `BrickscriptPlayers.of(self).load_data(node)`).
- **Exits:** `next`.

#### `is_mine`: Mine?
- **Inputs:** `node: Node = this node`.
- **Output:** Bool: whether it is this machine's player's (Owner is this machine's: Give To gave it to them, or to a node above it). On the host and offline, a node that is no one's counts as yours too; without the engine, always.
- **GDScript:** `<output> = _brickscript_owns(<node>)` (`NetworkEngine.is_mine`, API 7).
- **Exits:** `next`.

#### `set_owner`: Give To
- Server brickscripts only. Makes a node (and its children) a player's: Owner of it (and of everything under it, also what's added later) is them, on every machine, and Mine? is true on theirs. The server stays in control of it (API 7; before, the player's machine got control). No player (0) makes it no one's again.
- **Inputs:** `node: Node = this node`, `player: Player` (e.g. the `player` of Player Joined).
- **Settings:** `as`: **Just the node** (default) or **Their character**: also records it as the player's character, in their player data (`character`, a node path), so Get Character finds it on every machine, late joiners too.
- To let their machine move it (the Roblox way for a character), add **Moved By** right after (the sandbox does; a Character3D / Character2D a Character Spawner made for them does it by itself; one placed in the scene counts as this machine's where its keys move it, see What this machine's player moves).
- **GDScript:** `_brickscript_set_owner(<node>, <player>, <false / true>)` (helper: `NetworkEngine.set_node_owner`, then `set_player_character` for Their character, API 5).
- **Exits:** `next`.

#### `set_network_owner`: Moved By
- Server brickscripts only (Network Context Engine API 14). Whose machine moves a node: a player's (their machine changes its synced properties at once, everyone sees them, and their local brickscripts may change it: Roblox's network ownership) or no player (0: the server moves it).
- **Inputs:** `node: Node = this node`, `player: Player`, `max_speed: Number or Whole = Number 0` (units a second: a position that moves it faster, plus 1 unit, is refused and its owner put back; 0: no limit).
- The way to let a player's machine move their character (Give To / Spawn scene As their character don't by themselves; a Character3D / Character2D does). Then that character's local brickscript moves it (Key Direction, While action held Only nodes I own, Property (Set) on this node...): checked when the game runs, since only then is it known whose machine it is.
- **GDScript:** `_brickscript_moved_by(<node>, <player>, <max_speed>)` (`NetworkEngine.set_network_owner`; without the engine, player 1's is marked as this machine's).
- **Exits:** `next`.

#### `sync_property`: Sync
- Server brickscripts only (the server changes the game, so it says what's synced). No wires: set up at the start of `_ready` (the engine tells every client and later joiners).
- **Settings:** `path` (Node, a path from Self; blank / `.` = Self: the node the brickscript is on, or **in a script node the script node itself**, whose own variables it can sync; a new Sync in a script node starts at `..`, Self.Parent: the node it acts for) with `node_class` / `node_script`, `property` (writable ones), `smooth` (Smooth: glide between updates; Jump: switch at once, e.g. teleports).
- **Rules:** a property Self hasn't got (blank / `.`: its type is known exactly) is an error (2026-10-29; in a script node it says to pick Self.Parent); one not known on another node's type is a warning (synced by name).
- **Values:** plain values, and Resources saved to a file (a material, a texture: sent by their path and loaded where they arrive; Network Context Engine API 6+). A Resource made in code arrives as null, with a warning.
- **GDScript:** `_brickscript_sync(self, "<property>", <smooth>)` (Self), `_brickscript_sync(_brickscript_body, ...)` (a script node's Self.Parent), or `..get_node(NodePath("<path>"))` for other paths (`NetworkEngine.sync_property`).

#### `event_server_tells`: On Server Fired
- Local brickscripts only. Runs when the server sends this message with Fire Clients.
- **Settings:** `message` (Text, default `hello`).
- **Provides:** `values` (List, read-only).
- **GDScript:** `@rpc("any_peer", "call_remote", "reliable") func _brickscript_server_told(message: String, values: Array) -> void:`, starting with `if multiplayer.get_remote_sender_id() > 1: return` (only the server, peer 1, or a local call may run it), then `if message == "<message>":`.
- **Exits:** numbered outputs.

### Output

#### `play_sound`: Play sound
- Plays a sound file once.
- **Inputs:** `sound: Resource (AudioStream: .wav / .ogg / .mp3)`, `volume: Number or Whole = Number 0` (decibels: 0 as recorded, -6 about half as loud).
- **GDScript:** `_brickscript_play_sound(<sound>, <volume>)`: the helper adds an AudioStreamPlayer child, plays it, and frees it when the sound ends.
- **Exits:** `next`.

#### `print`: Print
- Prints a value to the Output panel.
- **Inputs:** `value: any = Text "Hello!"`
- **GDScript:** `print(<value>)`; a Player (2026-10-30): `print(_brickscript_player_text(<value>))`, their name, or `no player` (not `<null>`).
- **Exits:** `next`.

### Variables

#### `set_var`: Variable
- Reads or writes a variable by name (2026-10-28: it was Set Var; a brick saved without a mode is Set).
- **Mode** (`mode`, 2026-10-28): **Get** reads the variable into the Output (any variable there: Constants, Exports and event values too; an error if there's none by that name; it declares nothing). **Set** (default) writes the value (or makes a new variable). **Add** adds it to an existing number or vector variable (`score += 1`; a negative value takes away): its name must exist there (an error otherwise), hold a Number, Whole, Vector2 or Vector3 (or Anything), and take a vector for a vector (a Number added to a Whole is rounded). Get and Add never make a variable, so an unwired one declares nothing. Properties: Get's Variable dropdown lists everything readable, Add's only the writable number / vector variables; neither has New variable… or Kind. Faces: `→ copy = score`, `score ← 0`, `score += 5`.
- **Settings:**
  - `name`: the variable, picked from a dropdown of writable variables, or "New variable…" and a name. Renaming it in Properties renames its uses.
  - `var_kind`: what a new name becomes, `Shared` (default), `Chain` or `Synced`. Older graphs have a `keep` flag instead (on = Shared, off = Chain), or `Constant` / `Export` (upgraded to those bricks).
- **Inputs:** `value: any = Number 0`
- **Rules:**
  - If the name exists (chain or script variable), it is written. Constants, Exports and event values are refused.
  - If the name is new, it depends on the kind:
    - **Shared:** a Shared variable is declared, typed like the value, and every event can use it. If no event reaches this Variable (Set), the value must be typed in and is the starting value.
    - **Chain:** a chain variable is made; only later bricks of the same event can use it.
    - **Synced:** a Shared variable that is the same on every machine: the server changes it (Property (Set) on this node, from the server brickscript), everyone else receives it; the local brickscript only reads it. Registered with `_brickscript_sync(self, "<name>", true)` at the start of `_ready`: on the server it calls `NetworkEngine.sync_property`, which tells every client (and later joiners) itself. Only in local brickscripts (a server brickscript's own variables exist only on the server); a server brickscript changes it with Property (Set or Add) on this node (with script nodes: on the LocalScript, `../LocalScript` from the ServerScript beside it, its Type that brickscript; in code `input_node(&"of", "../LocalScript", &"Node", "res://....bricklocal")`).
  - For Constants and Exports, use the Constant / Export bricks.
- **GDScript:** Get: `<output> = <name>`. Set: `<name> = <value>` (plus a `var` declaration for new names); declarations go at the top of the script. Add: `<name> = <name> + <value>` (`roundi(...)` for a Whole given a Number).
- **Exits:** `next`.

#### `constant`: Constant
- Declares a Constant: one fixed value for the whole script that nothing can change. Every brick in every event can read it.
- **No wires:** no exec input and no exits. It is set before the game starts, wherever it sits on the canvas.
- **Settings:** `name` (a free name is picked when it is added; renaming it in Properties renames its uses).
- **Inputs:** `value: any = Whole 0`, typed in only (no Variable option).
- **Rules:** a Node can't be a Constant (use an Export). Declaring a name twice is an error. A wire can't lead into it.
- **GDScript:** `const <name>: <type> = <value>` at the top of the script.

#### `export`: Export
- Declares an Export: a value set per node in the Inspector, starting at this value. Every brick can read it; none can change it (copy it into a Shared variable with Variable (Set) to change it).
- **No wires**, like Constant.
- **Settings:** `name`; for a Node value also `node_class` (Type) and `node_script` (Script), see "Node types"; `shown_on` (**Shown on**: This script node (default) / The node it acts for (its parent: the character, the door...) / A node).
- **Inputs:** `value: any = Number 0`, typed in only. For a Node, the value is ignored: pick the node in the Inspector. `shown_node: Node` (only for Shown on: A node; typed in, a path from the node it acts for).
- **Shown on** another node: that node's Inspector shows it at the top ("Speed (LocalScript)", Godot's own editor for its type, undoable) and the script node's own doesn't; the value is still kept on the script node (a plain @export, saved with the scene like any other), so nothing changes when the game runs. Found in the scene being edited, scenes placed in it too (editor/node_inspector.gd + core/shown_exports.gd).
- **GDScript:** `@export var <name>: <type> = <value>` (`@export var <name>: <Type's class, or Node>` for a Node); with Shown on another node also `const _BRICKSCRIPT_SHOWN_ON: Dictionary = { "<name>": "<path from the node it acts for>" }` (read by the editor's Inspector).

### Functions

A function is a chain that runs when a brick calls it: give it values, it gives one back. Like Roblox / Lua functions. Functions can live in the brickscript that calls them, in a **shared brickscript** (`.brickshared`, like a Roblox ModuleScript) that any brickscript calls, or in another node's brickscript (Call Function From: A node).

**Shared brickscripts (`.brickshared`).** FileSystem > right-click > Create New > Brickscript (shared functions).
- **What's in one:** only Define Functions and its variables (Constants, Shared Variable (Set) bricks giving starting values). Other events are an error, and the palette doesn't offer them.
- **Used by** (the toolbar's dropdown, stored as the graph's context):
  - **Both** (local): local and server brickscripts may call it. Only bricks that work on either side; its node changes follow a local brickscript's rules (it may run on a client).
  - **Server only** (server): only server brickscripts may call it (a local caller is an error), and it may use server bricks (Give To, changing Object values...). For game rules: damage, prices.
- **One copy per machine:** the first call on a machine makes its copy (a plain Node named `Shared_<file>`, under the BrickscriptDebug autoload, else the root), and every later call there, from any brickscript, uses it. So its Shared variables are shared by all callers on that machine; they aren't synced, so the server's copy and each client's are separate. The copies are kept by path in `Engine.get_meta(&"_brickscript_shared")`.
- **"This node"** in a shared brickscript is its own copy (it acts for no node in the scene).
- **The graph:** `shared = true` (saved in the file; `.brickshared` files are always shared). It compiles to `extends Node` with its functions and variables, no server guard on functions.

#### `define_function`: Define Function
- An event-like start brick: its chain runs when a Call Function calls it. Local and server brickscripts.
- **Settings:** `name` (Text, default `my_function`: letters, digits and _, not starting with a digit; one function per name in a brickscript).
- **Inputs (its own, in Properties):** a list of inputs, each a name and a type (`Number`, `Whole`, `Text`, `Bool`, `Vector2`, `Vector3`, `Color`, `Node`, `Resource`, `List`, `Table`, `Player`, `Anything`), stored in the setting `params` as `[[name, type name], ...]`. Each is a read-only value in the chain, like an event's (`Ops.provides_of`).
- **Gives back:** what its Returns give. Every Return of the function gives the same type (Whole and Number together make Number; a Return giving Anything, e.g. the function calling itself, takes the others' type), or none of them gives anything. A chain that ends without a Return gives the type's default (0, "", null...).
- **Waits:** a Wait (or Invoke Server, or a call of a function that waits) in it makes it wait, and every Call Function of it waits for it.
- **GDScript:** `func _bf_<name>(<input>: <type>, ...) -> <type or void>:` (the inputs typed; unused ones get a leading `_`). It has no server guard of its own: the chains that call it are guarded.
- **Exits:** numbered outputs, like any event (each runs to its end, in order).

#### `return_value`: Return
- Ends the function it's in at once. Only in a Define Function's chain (error elsewhere).
- **Settings:** `gives`: **A value** (default) or **Nothing** (just leave the function early).
- **Inputs:** `value: any = Number 0` (only for A value).
- **GDScript:** `return <value>` / `return`.
- **Exits:** none.

#### `call_function`: Call Function
- Runs a function and keeps what it gives back.
- **Settings:** `from`: **This brickscript** (a Define Function in the same file), **A file** (a shared brickscript) or **A node** (another node's brickscript); `file` (A file only: the `.brickshared` path, picked from the project's shared brickscripts); `function_script` (A node only, optional: the node's brickscript, picked from the project's brickscripts of the caller's side); `function`: the function's name (picked from the functions there; typed in for A node without its brickscript).
- **From: A node:** the `node` input (Node, A node only) is the node; the function runs in its script node of the caller's side (a local brickscript calls the node's LocalScript, a server one its ServerScript; an older brickscript on the node itself counts too), found when the game runs: the one running `function_script` if picked. With `function_script` the function, its rows and types are checked when compiling (picking the server / local side wrong, or a shared file, is an error); without it the rows are added by hand (+), nothing is checked until the game runs, and a missing function or node is an error naming the brick then.
- **Inputs:** one row per input of the function, `arg_1`, `arg_2`, ... (picking the function sets the rows and types them like its inputs; the editor labels each row with the input's name). A value must fit its input's type (a Whole goes into a Number, `float(...)`; Whole and Player mix), else it's an error naming the input. Too few or too many rows: an error listing the inputs.
- **Output:** what the function gives back, typed like its Returns. A function that gives nothing: a warning, the Output stays empty.
- **GDScript:** `<output> = _bf_<name>(<args>)`, or `await _bf_<name>(...)` for a function that waits (then the calling chain waits too, and runs in its own function like any chain that waits). From A file: `_brickscript_shared("<path>")._bf_<name>(<args>)` (SHARED_HELPER: the file's copy on this machine, made on first use). From A node: `_brickscript_call_node(<node>, "<function_script>", <server>, &"_bf_<name>", [<args>], "<brick>")` (the script node found is noted on the node, meta `_brickscript_calls`, for the next call), or `await _brickscript_await_node(...)` when the function waits or isn't known (by name: always waited for; an await on a value that doesn't wait just gives it) (NODE_FUNCTION_HELPER).
- **Rules:** the function must be defined there (error naming it otherwise). Types and waiting are learned over the compiler's passes, so a function may be called before it's defined, and may call itself. A file is compiled once per version (`Compiler.shared_file`, by its content) to learn its functions; a file with problems, one that isn't a `.brickshared`, a Server only file called from a local brickscript, are errors on the brick. Brickscripts calling each other's functions in a loop is fine: the one compiled second sees the first's functions untyped (waited for, Anything).
- **Exits:** `next`.

### Nodes

Node inputs (`of`, `parent`) start as **Self** (the typed-in path `.`; in a script node, **Self.Parent**). See "Node types" above for how the dropdowns know what a node has.

#### `get_node`: Get node
- Finds a node by its path from Self (`Self.Sprite2D`, `Self.Parent.Gun`, `Self.Parent.Parent.Enemy`, `/root/Main`) into a Node variable. A blank path is Self.
- **Settings:** `path` (Text; dropdown of the paths found in the scenes using this brickscript), `node_class` (Type), `node_script` (Script). Picking a path fills in Type and Script.
- **Output:** Node, of that node type.
- **GDScript:** `<output> = _brickscript_typed(get_node_or_null(NodePath("<path>")), &"<class>", "Get node (brick <id>)") as <class>` with a Type (null if it isn't there; a node of another class is null too, with an error naming the brick), plain `get_node_or_null(...)` without one.
- **Exits:** `next`.

#### `set_property`: Property
- One brick for a node's property (2026-10-28: it was Get property + Set property; file format 7, `Ops.access_modes_upgrade()`, turns a Get property into Property, Mode Get, and gives a Set property without a mode Mode Set).
- **Mode** (`mode`): **Get** (a new brick's default) reads it into the Output; **Set** gives it a value; **Add** adds the value to a number or vector property (`position += velocity * delta`; a negative value takes away; until format 6 its own brick, Change property: `Ops.change_property_upgrade()`, its `amount` the `value`). A brick saved without a mode is Set.
- **Inputs:** `of: Node = parent`; `value: any` with Set / Add only (picking a property sets its type). With Add: a Number, Whole, Vector2 or Vector3 (a vector property needs a vector value).
- **Settings:** `mode` (Get / Set / Add), `property` (Get: everything `of` has; Set: writable ones only; Add: writable numbers / vectors only; a script's `_BRICKSCRIPT_READ_ONLY` properties are refused).
- **Output** (Get only): the property's type (and node type, for a Node property). On a character: also its read-only states (`on_the_floor`, `moving`, `falling`, `dead`; see "Reading and changing a character").
- **On a character's setting** (`walk_speed`, `health`...), Set / Add: `_brickscript_set_character(<of>, &"<property>", <value>, 0.0, "Property (brick <id>)")` (Add: `<of>.<property> + <value>`, numbers only), its `change()` (to the machine that moves it; allowed in a local brickscript for its own player's character, refused there when it runs otherwise); `health` / `max_health` only in a server brickscript.
- **GDScript:** Get: `<output> = <of>.<property>` (a script member: `<of>.get(&"<property>")`). Set: `<of>.<property> = <value>` (a script member: `<of>.set(&"<property>", <value>)`). Add: `<of>.<property> += <value>` (a script member: `<of>.set(&"<property>", <of>.get(&"<property>") + <value>)`). In a local brickscript, Set / Add need `of` local-only (see "What a local brickscript may change"): `if _brickscript_local_only(<of>, "Property (brick <id>)"): ...`, or this brickscript itself for its own (not Synced) variables. Get reads anything.
- **Face:** `Self.Parent.health` then `→ hp`; `Self.Parent.visible = false`; `Self.Parent.rotation += turn`.
- **Exits:** `next`.

#### `call_method`: Call method
- **Inputs:** `of: Node = parent`, then rows `arg_1`, `arg_2`, ... (+ / −; picking a method sets one typed row per value it takes).
- **Settings:** `method` (dropdown, or typed in).
- **Output:** optional: what the method returns (an error if it returns nothing).
- **GDScript:** `<of>.<method>(<args>)` (a script method: `<of>.call(&"<method>", <args>)`), into the output if named. A value the method takes as a node path is Text, written `NodePath(<text>)`; a node path it returns is `str(...)` (see "Node paths are Text"). In a local brickscript `of` must be local-only, unless the method only reads (`const`).
- **Exits:** `next`.

#### `spawn_scene`: Spawn scene
- **In a server brickscript it spawns for every machine** (`NetworkEngine.spawn`), and freeing such a node on the server removes it everywhere. In a local brickscript it spawns only on this machine, and only effects: no physics bodies or areas in the scene (an error otherwise); the copy is put in the `local_only` group.
- **Place:** `place` = At a position shows an `at` input (Vector2 / Vector3), set before the node is added, on every machine.
- **For** (server brickscripts): `for` = **No one** (default), **A player** or **A player: their character** shows a `player` input (Player): the new node is that player's from the start (Owner, Mine? on their machine; like Give To right after), and with their character also what Character finds. A player's character in one brick, from Player Joined. In a local brickscript anything but No one is an error.
- **Parent not there** (a wrong path, a freed node; 2026-11-02): when it runs, an error naming the brick (`Spawn scene (brick N): its Parent isn't there ...`), nothing is spawned and the rest of the chain is skipped (in a Define function's chain: the error only).
- Makes a copy of a scene and adds it as a child of `parent`.
- **Settings:** `scene` (a `res://...tscn`; dropdown of the project's scenes), `node_class` / `node_script` (filled in from the scene's root).
- **Inputs:** `parent: Node = parent`, `at` (with At a position), `player: Player` (with For a player).
- **Output:** optional: the new node, of the scene root's type.
- **GDScript:** `<output> = _brickscript_local_spawn((load("<scene>") as PackedScene).instantiate()) as <class>` (then `<output>.position = <at>`) and `<parent>.add_child(<output>)`; in a server brickscript `<output> = _brickscript_spawn(load("<scene>"), <parent>, {"position": <at>}) as <class>`, with `, <player>, <true for their character>` added For a player (the helper spawns it, then `set_node_owner` and `set_player_character`).
- **Exits:** `next`.

#### `find_node`: Find node
- Searches under a node for a node with a name; null if there is none.
- **Inputs:** `name: Text = "Player"` (a variable works), `under: Node = parent`.
- **Settings:** `search` (All descendants / Direct children), `node_class` (Type of what it finds; blank = some Node). It has no Script setting (removed 2026-10-22; one stored in an older graph is ignored): use As script on what it finds to reach a script's variables.
- **Output:** Node, of that node type.
- **GDScript:** `<output> = _brickscript_typed(<under>.find_child(<name>, <recursive>, false), &"<class>", "Find node (brick <id>)") as <class>` with a Type (`owned` false, so nodes added while the game runs are found too; a node of another class is null, with an error naming the brick).
- **Exits:** `next`.

#### `get_root`: Get root
- The root of a scene (2026-10-28, user's idea). **Its scene:** the root of the scene file a node was made in, however deep it sits: a script inside `coin.tscn` gets the Coin wherever the coin is placed, without counting Parents. A placed scene's root gets itself (the Coin of the level's Coins/Coin); a node of the level gets the level's root; a node made in code: its first parent that is one of those. **The game's scene:** the main scene running (the top node, right under the window; in a SubViewport, that viewport's scene).
- **Inputs:** `of: Node = Self` (Self.Parent in a script node; shown with Its scene).
- **Settings:** `root` (**Root**: Its scene (default) / The game's scene), `node_class` / `node_script` (Type / Script of the root). A blank Type is filled in from the scenes when the brickscript is opened or saved (`NodeTypes.root_type_guess`: the root of the scene file the node is saved in, a placed scene's own); left blank when the scenes don't say (a path above that scene's root, a script in a StarterPlayer / StarterCharacter) and for The game's scene (a brickscript may run in any level, not only the main scene: set its Type yourself). Clear it to have it found again.
- **Output:** Node, of that node type.
- **GDScript:** `<output> = _brickscript_scene_root(<of>)` (SCENE_ROOT_HELPER: the node itself if it's a placed scene's root (`scene_file_path`), else its `owner`, else up its parents) or `_brickscript_game_root(self)` (GAME_ROOT_HELPER: up to the node under a Viewport); with a Type `_brickscript_typed(..., &"<class>", "Get root (brick <id>)") as <class>`. A few steps up the tree, no per-frame cost.
- **Exits:** `next`.

#### `find_ancestor`: Find first ancestor
- Like Roblox's `FindFirstAncestor` / `FindFirstAncestorWhichIsA` in one brick (2026-10-28, user's choice): goes up from a node's parent to the first node with the Name and of the Type. A blank Name is any name, a blank Type any type (both blank: the parent). Null if none fits: check with If `is null`.
- **Inputs:** `name: Text = ""` (a variable works), `of: Node = Self` (it stays Self in a script node, `stays_self`, so the script node's parent, e.g. the character, is the first one looked at, as with Roblox's `script:FindFirstAncestor`).
- **Settings:** `node_class` (**Type**: blank = any type; a class or a script class, e.g. `Area3D`, `Character3D`).
- **Output:** Node, of that Type.
- **GDScript:** `<output> = _brickscript_find_ancestor(<of>, <name>, func(found: Node) -> bool: return found is <class>) as <class>` with a Type, `_brickscript_find_ancestor(<of>, <name>, Callable())` without (ANCESTOR_HELPER: a loop up the parents).
- **Exits:** `next`.

#### `as_script`: As script
- The same node, known to run a script (a `.gd` or a brickscript), so the next bricks' dropdowns offer that script's variables and methods (like GDScript's `as`). Null if the node doesn't run that script (or one extending it).
- **Inputs:** `node: Node = Variable ("")`.
- **Settings:** `node_script` (Script, required; the script dropdown lists the project's scripts).
- **Output:** Node of type `{"class": <the script's base class>, "script": <path>}`.
- **GDScript:** `<output> = _brickscript_as_script(<node>, "<script>") as <class>`. The helper returns the node if `get_script()` (or a script it extends) has that path, else null. Check with If `is null`.
- **Rules:** a node whose class can't be the script's base class is an error ("a Label can't run gem.gd"); no Script picked is an error; a missing file is a warning.
- **Exits:** `next`.

#### `get_children`: Get children
- A node's children as a List, oldest first.
- **Inputs:** `of: Node = parent`.
- **Settings:** `search` (Direct children / All descendants), `node_class` / `node_script`: only children of that Type (and script).
- **Output:** a List of nodes, which keeps its Type (see "Lists of nodes").
- **GDScript:** `<output> = <of>.find_children("*", "<class or empty>", <recursive>, false)` (plus `.filter(...)` on the script).
- **Exits:** `next`.

#### `nodes_in_group`: Nodes in group
- Every node in a group, anywhere in the game, as a List.
- **Settings:** `group` (dropdown of the project's groups: Project Settings > Groups and the groups scenes put nodes in; picking one fills in the Type its nodes share), `node_class` / `node_script`: only nodes of that Type.
- **Output:** a List of nodes, which keeps its Type.
- **GDScript:** `<output> = get_tree().get_nodes_in_group(&"<group>")` (plus `.filter(func(found: Node) -> bool: return found is <class>)` and on the script).
- **Exits:** `next`.

#### `add_to_group`: Add to group / `remove_from_group`: Remove from group
- **Inputs:** `node: Node = parent`. **Settings:** `group`.
- **GDScript:** `<node>.add_to_group("<group>")` / `<node>.remove_from_group("<group>")`. In a local brickscript `node` must be local-only.
- **Exits:** `next`.

#### `is_in_group`: Is in group
- **Inputs:** `node: Node = parent`. **Settings:** `group`.
- **Output:** Bool. **GDScript:** `<output> = <node>.is_in_group("<group>")`
- **Exits:** `next`.

**Groups the Cull Throttle Engine reads** (2026-10-30, with that plugin): Add to group **`no_cull`**: never culled (still slowed when far, at most every 10th update), for things that must always be seen or heard, like a goal marker; **`full_rate`**: never slowed (may still be culled when out of view), for things that must move smoothly everywhere. A player-controlled Character3D is always in `full_rate`; Controlled by Script (an NPC) isn't, so a far NPC thinks every 4th frame at slowest. Metadata `cull_radius` (a Number) sets how big an object counts as.

**Lists of nodes:** a List made by Get children or Nodes in group is a List of its Type (`Array[Label]`; Godot gives an `Array[Node]`, converted with `Array(<found>, TYPE_OBJECT, &"Label", null)` when a Type is set; dropdowns show "List of Label"). For each item and Get item over it give that Type, so Property (Get / Set) and Call method offer its properties. See "Typed lists" in section 1.

#### `free_node`: Free node
- Removes a node (and its children) at the end of this frame. `.` frees this node.
- **Inputs:** `node: Node`.
- **GDScript:** `<node>.queue_free()`. In a local brickscript `node` must be local-only (its effects, UI).
- **Exits:** `next`.

### Physics

Questions for the physics world: what is at a place, what is in the way. A Vector3 looks in the 3D world, a Vector2 in the 2D world (the viewport's, `get_viewport().find_world_3d()` / `find_world_2d()`), so they work from any brickscript, a server one included. The node running the brickscript (in a server brickscript, its body) is never found, so a body can ask about the space around itself. They see bodies once they've been through a physics step (not ones added this very frame).

Both have **Finds** (`look_for`): `Bodies` (default: StaticBody, RigidBody, CharacterBody), `Areas` (Area2D / Area3D), or `Bodies and areas`; **Type** (`node_class`): only nodes of that class; and **Layers** (`layers`): the collision layers to look at, as numbers (`1, 3`; blank: all). Its dropdown lists the project's layers (by name where Project Settings > Layer Names gives one) and switches one on or off. A number outside 1 to 32 is an error.

#### `bodies_near`: Bodies near
- What overlaps a ball (a circle in 2D) around a point: any body reaching into it, the floor under it too, e.g. is this spot free before spawning a gem there?
- **Inputs:** `at: Vector2 or Vector3 = Vector3 (0, 0, 0)`, `radius: Number or Whole = Number 0.5` (0 checks just the point).
- **Settings:** `look_for`, `node_class`.
- **Output:** a List of the nodes found (a List of the Type when one is set, like Get children), each once.
- **GDScript:** `<output> = _brickscript_bodies_near(<at>, <radius>, <0 / 1 / 2>, <self or _brickscript_body>, <mask>)` (a helper: `intersect_shape` with a SphereShape3D / CircleShape2D, at most 64 results), plus `.filter(...)` and a typed conversion for a Type.
- **Exits:** `next`.

#### `raycast`: Raycast
- The first body (or area) on a straight line, or nothing: ground under a character, a wall in the way, line of sight. Then **Hit** or **Nothing hit** runs.
- **Inputs:** `from`, `to`: both Vector2 or both Vector3 (defaults (0, 0, 0) and (0, -10, 0)); `relative_to: Node = this node` (only with Points are: Relative to a node).
- **Points are** (`space`): **World positions** (default), or **Relative to a node**: From and To are in that node's own space (`to_global`), so they move and turn with it, like Godot's RayCast2D / RayCast3D. E.g. relative to a character, from (0, 0, 0) to (0, -2, 0) is "2 below me", tilting with it. The node must be a Node3D for Vector3s (Node2D for Vector2s); some other kind is an error, an unknown node is checked when the game runs. Hit point stays a world position; a ray that starts inside a shape doesn't hit it.
- **Settings:** `look_for`, `node_class`, and three names it can fill (in Outputs, "Also fills"; blank: not kept), each a new chain variable or an existing one:
  - `point_name` (**Hit point**): where the ray hit, a Vector3 (Vector2 in 2D); To when nothing is hit.
  - `normal_name` (**Normal**): which way the surface it hit faces (length 1); (0, 0, 0) when nothing is hit.
  - `distance_name` (**Distance**): how far the hit is from From, a Number; -1 when nothing is hit.
- **Output:** Node (of the Type, if set), or null when nothing is hit (the Nothing hit exit runs then). Optional when one of the names is set or an exit is wired.
- **Type filters:** something of another Type is looked past (up to 16 of them), so a ray through an Area3D still finds the StaticBody3D behind it.
- **Rules:** a Vector2 with a Vector3 is an error.
- **Exits:** `hit` (**Hit**) and `missed` (**Nothing hit**), like an If's True / False: `if not _brickscript_ray_hit.is_empty():` ... `else:`. A graph saved with the older single `next` exit carries on after the cast either way; opening it in the editor wires both exits to where `next` led.
- **GDScript:** (relative: `<relative_to>.to_global(<from>)`, the same for To) `<output> = _brickscript_raycast(<from>, <to>, <0 / 1 / 2>, <self or _brickscript_body>, <mask>, &"<Type>")` (`intersect_ray`, again past things of another Type), `as <Type>` when one is set. The helper keeps the hit in `_brickscript_ray_hit`, so the names are `<point> = _brickscript_ray_hit.get("position", <to>)`, `<normal> = _brickscript_ray_hit.get("normal", Vector3.ZERO)`, `<distance> = (<from>).distance_to(_brickscript_ray_hit["position"]) if not _brickscript_ray_hit.is_empty() else -1.0`.

### AI

Steering characters from scripts (NPCs): the character is a **Character3D with Controlled by: Script** (see Characters), moved on the machine that owns it, which for one with no player is the server; everyone else sees it glide like any character. So Walk to, Follow and Stop walking are **server bricks** (offline the game is its own server). Paths come from Godot's navigation: a **NavigationRegion3D** with a NavigationMesh **baked in the editor** (select it, Bake NavigationMesh; its agent radius / height should fit the characters: radius at least the character's `shape_radius` (0.4), better 0.1-0.2 more, since a bake cuts a wall's corner across and keeps only about 0.7 of the radius there; a character grazing a corner slides round it (2026-10-31)), or baked while the game runs or from a tool script (`region.bake_navigation_mesh(false)`, then `ResourceSaver.save(region.navigation_mesh, "res://....tres")` to keep it). It bakes what it's told to parse: by default its own children's meshes; for floors and walls elsewhere set the NavigationMesh's Geometry > Parsed Geometry Type to Static Colliders and Source Geometry Mode to Groups With Children, and put them in its Source Group Name's group (Godot's default name is `navigation_mesh_source_group`; the sandbox sets it to `navigation_geometry`). A region whose mesh is empty (never baked, or baked from nothing) makes every walk Can't reach: Walk to / Follow say so once with an error (2026-10-30), "nothing to walk on: bake it". With no navigation area in the world they go straight. The navigation is ready a few physics frames after the game starts (Godot syncs the map on a thread, and a region's mesh joins a sync after the region): a Walk to or Follow started earlier waits for it by itself (up to 1 s; for a Terrain that bakes navigation, until it's ready however long that takes (2026-10-31): start them from When ready as usual); Find path is empty until then. 2D comes later.

#### `walk_to`: Walk to
- Server: a character walks to a spot or a node (where the node is when it starts; to keep up with one that moves, Follow) along the navigation (a drone: an air path, see Character3D, kind Drone), around what's in the way, turning to face where it goes (yaw; 10 radians a second). The chain **waits** until it ends (the event's other chains and events go on), then **Arrived** or **Can't reach**.
- **Inputs:** `who: Node = this node` (the character, or a node inside it: a script node), `to: Vector3 or Node = Vector3 (0, 0, 0)`, `within: Number or Whole = Number 0.5` (close enough, flat distance).
- **Can't reach:** no path gets there (the path's end is more than Within + 0.5 from it, flat, or 2 above / below), stuck (no further than 0.25 in 2 s), or it isn't a character steered by scripts (an error says which: Controlled by Player, moved on another machine, not a character), or the navigation is empty (an error once: bake it).
- **Stopped** (2026-10-29): Stop walking, another Walk to or a Follow of the same character took over, or it died. (Until then this was Can't reach too, so a "can't reach: try somewhere else" chain fought a Follow.)
- **Exits:** `arrived` (**Arrived**), `unreachable` (**Can't reach**) and `stopped` (**Stopped**), like an If's. An unwired one does nothing. Always at least a physics frame later (a Can't reach that walks again doesn't loop in one frame).
- **GDScript:** `_brickscript_walked = await _brickscript_walk_to(<who>, <to>, <within>, "Walk to (brick N)")` (0 Arrived, 1 Can't reach, 2 Stopped) then `if _brickscript_walked == 0:` ... `elif _brickscript_walked == 1:` ... `else:` (only the wired exits). The helper finds the character (`_brickscript_character_node`) and awaits its `walk_to_end(to, within) -> WalkEnd` (`BrickscriptCharacter3D.WalkEnd`: ARRIVED, CANT_REACH, STOPPED); `walk_to(to, within) -> bool` is the same, true when it arrived.

#### `follow`: Follow
- Server: a character walks after a node and keeps within Distance of it, finding its path again every 0.5 s or when the target moved 1; standing, it faces it; out of reach, it waits and looks again; stuck, it finds its path again; blocked for 0.5 s within Distance + 1.5 (others crowding the target), it stands there instead of pushing. Following the same target again (a script asking every tick) only changes the Distance: the walk goes on. Carries on at once; it goes on until Stop walking, a Walk to, the target leaves the tree or the character dies. A drone keeps its height above the target and stops at the Distance from there (see Character3D, kind Drone).
- **Inputs:** `who: Node = this node`, `target: Node` (a 3D node; anything else is an error when the game runs), `distance: Number or Whole = Number 2.0`.
- **Exits:** `next`.
- **GDScript:** `_brickscript_follow(<who>, <target>, <distance>, <brick>)` (the character's `follow(target, distance)`).

#### `stop_walking`: Stop walking
- Server: a character's Walk to (its chain goes on through Can't reach) or Follow ends; it stands still.
- **Inputs:** `who: Node = this node`. **Exits:** `next`.
- **GDScript:** `_brickscript_stop_walking(<who>, <brick>)` (the character's `stop_walking()`).

#### `find_path`: Find path
- The way a character would walk between two places along the navigation (any brickscript; nothing moves).
- **Inputs:** `from`, `to`: Vector3 or Node (a node: where it is), defaults (0, 0, 0).
- **Settings:** `length_name` (**Length**, in Outputs, "Also fills"; blank: not kept): the path's length, a Number; 0 when there's none.
- **Output:** a List of Vector3s from start to end (no point twice in a row: Godot gives corners twice); empty when no path gets there (its end more than 1 from To, flat, or 2 above / below) or before the navigation is ready (its first few physics frames). With no navigation area: From and To (straight there). Optional when Length is set.
- **Exits:** `next`.
- **GDScript:** `<output> = _brickscript_find_path(<from>, <to>, <brick>)` (`NavigationServer3D.map_get_path` in `get_viewport().find_world_3d()`'s map), `<length> = _brickscript_path_length`.

**Senses** (any brickscript; nothing moves, so a local one may use them too, e.g. a marker over what your character sees). A node that isn't a 3D node (a LocalScript / ServerScript node) stands for its closest 3D ancestor (its body). Behaviour (patrol, chase, flee) is built from these with If, While, Wait and variables: there's no state-machine brick.

#### `can_see`: Can see
- Whether a node sees a spot or a node: within **Range**, inside its **View** (degrees across, about where it faces, its -Z; 360: all round, no facing) and nothing in the way. From a character (the node, or a node inside it: a script node), it looks from its eyes (its Head: Character3D's head, at eye height, tilted with its pitch). Then **Seen** or **Not seen** runs.
- **Inputs:** `who: Node = this node`, `target: Vector3 or Node` (a node: its position, a character's middle), `range: Number or Whole = Number 20`, `view: Number or Whole = Number 120`.
- **In the way:** a ray from the eyes to the target, on every collision layer, past the looker's own character (and every body it's inside). Hitting the target, something inside it, or something holding it counts as seen; a target that's a spot is seen when nothing is hit. Areas don't block it.
- **Exits:** `seen` (**Seen**) and `unseen` (**Not seen**), like an If's True / False.
- **GDScript:** `_brickscript_seen = _brickscript_can_see(<who>, <target>, <range>, <view>, <brick>)` then `if _brickscript_seen:` ... `else:`.

#### `nearest_character`: Nearest character
- The character (a Character3D) closest to a spot or a node.
- **Inputs:** `from: Vector3 or Node = this node`, `range: Number or Whole = Number 0` (only within it; 0: any distance).
- **Settings:** `among` (**Among**): **Players' characters** (default: Controlled by Player) or **All characters** (NPCs too); `distance_name` (**Distance**, in Outputs, "Also fills"; blank: not kept): how far it is, a Number, -1 when there's none.
- **Not counted:** the node it's measured from and the character that node is in (an NPC finding the nearest other one), dead ones, ones in another 3D world (another viewport).
- **Output:** Node (a Character3D), or null when there's none: check with If is null. Optional when Distance is set.
- **Exits:** `next`.
- **GDScript:** `<output> = _brickscript_nearest(<from>, <true: players' characters only>, <range>, <brick>)` (characters are in the group `brickscript_characters`), `<distance> = _brickscript_nearest_distance`.

#### `random_spot`: Random reachable spot
- A random spot within **Radius** (flat) of a spot or a node. **On Navigation** (default): on the navigation, that a path from there gets to: somewhere to wander to (give it to Walk to). **On Terrain** (2026-10-31): on the ground of the scene's Terrain (the Terrain Engine plugin), at its height there: where to put a gem or an NPC; works on every machine, no navigation needed (see Terrain). **On Navigation, else Terrain** (2026-11-03): the navigation where there is some around Around and it's ready, else the Terrain's ground, as On Terrain (an NPC spawned before the navigation is baked, a client (navigation is baked on the server), a Terrain with Navigation off).
- **Inputs:** `around: Vector3 or Node = this node`, `radius: Number or Whole = Number 10`, `terrain: Node (a Terrain) = blank` (shown with On Terrain and Navigation, else Terrain, 2026-11-02; blank: the scene's Terrain).
- **Settings:** `on` (**On**: Navigation (default) / Terrain / Navigation, else Terrain).
- **Output:** Vector3. Navigation: up to 10 random tries (each checked with a path), then the navigation's closest point to Around. With no navigation area, or before it's ready (its first few physics frames): a random spot in the circle at Around's height. Terrain: a random spot in the circle at the Terrain's height there (up to 10 tries for one inside a Fixed world's edges, else Around); without a Terrain, a spot in the circle at Around's height. A Terrain's navigation (on the server) also makes On Navigation work there. A Character3D spawned at the ground's height stands up out of it (2026-10-31).
- **Exits:** `next`.
- **GDScript:** `<output> = _brickscript_random_spot(<around>, <radius>, <brick>, <on: 0 Navigation / 1 Terrain / 2 Navigation, else Terrain>, <terrain or null>)` (`map_get_closest_point`, `map_get_path`; On Terrain, and Navigation, else Terrain without navigation there, `_brickscript_terrain_spot`).

### Animation

Animations of an **AnimationPlayer**, **AnimatedSprite2D** or **AnimatedSprite3D** (input `player: Node`, default the typed-in path `AnimationPlayer`: a child of Self, in a script node `../AnimationPlayer`, Self.Parent.AnimationPlayer; a known Type of another class is an error). Two kinds, like the rest of the game:
- **Play animation / Stop animation** (server brickscripts): the game's animations (a door, an enemy's walk). Through the Network Context Engine (API 11, `play_animation` / `stop_animation`) the server plays it and every client plays it itself (smooth, no property synced); a player who joins later starts it where the server is (paused ones too). Without the engine it plays here (single-player). Don't also Sync a property the animation animates: the clients' own playing would be put back. Doing so gives a warning from the Network Context Engine when the animation plays or the Sync starts, once each, naming the node, the property and the animation (2026-11-03).
- **Play UI animation / Stop UI animation** (local brickscripts): what only this machine shows (a menu sliding in, a label pulsing). When it plays, every track of the AnimationPlayer's animation must animate a local-only node (UI, cameras, sounds, particles, the script's effects: see "What a local brickscript may change"); an animated sprite must be local-only itself. Otherwise it's refused, with an error naming the brick, the animation and the node.
- **Tween property / Stop tweens** (both kinds): no AnimationPlayer needed: one property moved smoothly to a value (see below). For a number in between by hand, Formula has `lerp(from, to, weight)` / `inverse_lerp`.

#### `play_animation`: Play animation / `play_ui_animation`: Play UI animation
- **Inputs:** `player: Node = "AnimationPlayer"`, `speed: Number or Whole = Number 1.0` (2 is twice as fast).
- **Settings:** `animation` (**Animation**: picked from the node's animations, read from the scenes that use this brickscript, or typed in; required), `direction` (`Forwards` / `Backwards`: from the end), `then` (**Then**: `Go on at once` / `Wait until it ends`: the chain waits for it, like a Wait; a looping animation doesn't wait).
- **GDScript:** `_brickscript_play_animation(<player>, &"<animation>", <speed>, <backwards>, "Play animation (brick <id>)")` (the UI one `_brickscript_play_ui_animation(...)`), then with Wait until it ends `await _brickscript_animation_end(<player>, &"<animation>")`. A missing animation or a node that can't play one is an error naming the brick when the game runs.
- **Exits:** `next`.

#### `stop_animation`: Stop animation / `stop_ui_animation`: Stop UI animation
- **Inputs:** `player: Node = "AnimationPlayer"`. **Settings:** `how` (`Stop`: back to the start / `Pause`: where it is; playing it again carries on).
- **GDScript:** `_brickscript_stop_animation(<player>, <pause>, "Stop animation (brick <id>)")` (`_brickscript_stop_ui_animation(...)`, checked like the UI play).
- **Exits:** `next`.

#### `tween_property`: Tween property
- Moves a property smoothly to a value over some seconds, like Roblox's TweenService (2026-10-28, user's choice): a door sliding open, a label fading, a pickup bobbing (Repeat -1 + Reverses). Usable in both kinds of brickscript, with Property (Set)'s rules: the property must be writable, a number, vector or color (Whole, Number, Vector2, Vector3, Color; an unknown one is tweened by name, with a warning); a local brickscript only tweens what it may change (UI, cameras, effects, its own variables, its own player's character, checked when the game runs as for Property (Set)); a character's settings (walk speed...) go through Property (Set) instead (an error).
- **Server brickscripts: on every machine** through the Network Context Engine (API 17, `tween_property`): the server sends each client the start value, the target and the timing once, and each runs the same tween itself (smooth everywhere, no value sent every frame); a player who joins later starts it where the server is, or gets the value it ended (or was stopped) on. Don't also Sync a property it tweens. Without the engine (single-player) it tweens here.
- **Inputs:** `of: Node = Self.Parent` (`..`), `to` (the property's type, set when it's picked; a Whole into a Number property becomes a float: both ends must be the same type), `seconds: Number or Whole = 1.0`, `repeat: Whole = 0` (more rounds after the first; -1: forever), `reverses: Bool = false` (each round goes back to the start).
- **Settings:** `property` (writable number / vector / color properties of the node's type), `easing` (Linear, Sine, Quad (default), Cubic, Quart, Quint, Expo, Circ, Back, Bounce, Elastic, Spring: Godot's `Tween.TRANS_*`), `direction` (In, Out (default), In-Out, Out-In: `Tween.EASE_*`), `then` (Go on at once / Wait until it ends; one that repeats forever isn't waited for, one that's stopped ends the wait).
- **GDScript:** `_brickscript_tween(<of>, &"<property>", <to>, <seconds>, Tween.TRANS_<easing>, Tween.EASE_<direction>, <repeat>, <reverses>, <everywhere: true in a server brickscript>, "Tween property (brick <id>)")` (TWEEN_HELPER), which returns the Tween; `await _brickscript_tween_end(...)` around it for Wait until it ends. A new tween of a property replaces the one running on it. Not in a predicted event (it would run twice).
- **Exits:** `next`.

#### `stop_tweens`: Stop tweens
- Stops a node's tweens where they are; from a server brickscript on every machine (each ends where the server stopped them).
- **Inputs:** `of: Node = Self.Parent` (`..`).
- **GDScript:** `_brickscript_stop_tweens(<of>, <everywhere>, "Stop tweens (brick <id>)")`.
- **Exits:** `next`.

### Camera

Between the screen and the world. **Mouse to World**, **World to Screen** and **Shake Camera** are local (they use this machine's screen); the server asks where a player points with **Player Aim**. The camera is **This screen's camera** (default: the viewport's current Camera3D / Camera2D, the one you see through) or **A camera node** (`camera_is`, then input `camera: Node`; a known Type that isn't a Camera3D (3D) / Camera2D (2D) is an error). A missing camera is an error naming the brick when the game runs, once per brick; the brick then gives zeros. In 2D the view is the viewport's canvas transform (where its Camera2D looks), so no Camera2D is needed. Screen points are pixels from the screen's top left (the viewport's: a SubViewport's own).

#### `screen_to_world`: Mouse to World
- Local brickscripts only. Where the mouse (or a screen point) points in the world. 3D: a ray from the camera through the point: the Output is its far end (To, Length away) and **From** its start on the camera; give both to Raycast to find what's under the mouse. 2D: the point's world position.
- **Settings:** `space` (**World**: `3D` (default) / `2D`), `point_is` (**Point**: **The mouse** (default) / **A screen point** / **The middle of the screen**: a crosshair, `get_viewport().get_visible_rect().get_center()`), `camera_is`, and a name it can fill (Outputs, "Also fills"; blank: not kept): `from_name` (**From**: the ray's start, a Vector3; in 2D the point too).
- **Inputs:** `point: Vector2 = (0, 0)` (only with A screen point; else `get_viewport().get_mouse_position()`), `length: Number or Whole = Number 100` (3D only), `camera: Node` (only with A camera node).
- **Output:** Vector3 in 3D, Vector2 in 2D. Optional when From is set.
- **GDScript:** `<output> = _brickscript_screen_to_world(<camera or null>, <point>, <true / false>, <length>, "Mouse to World (brick <id>)")` (3D: `project_ray_origin` + `project_ray_normal * length` of the camera, the origin kept in `_brickscript_ray_from`; 2D: `get_canvas_transform().affine_inverse() * point`), then `<from> = _brickscript_ray_from`.
- **Exits:** `next`.

#### `player_aim`: Player Aim
- Server brickscripts only. Where a player's mouse points through their camera, as their machine sees it: the server-side Mouse to World. Each client sends its aim (Network Context Engine API 10, `get_player_aim`: its root viewport's current Camera3D ray through the mouse and the mouse's 2D world position) while it moves (at most 30 a second, then once reliably when it settles, and reliably just before a key or button changes, so a click on the server goes with the aim it was made with). The server's own player (the host; offline and without the engine player 1) is read through this node's screen. (0, 0, 0) until a player's first aim arrives, or for a player without a Camera3D in 3D.
- **Inputs:** `player: Player`, `length: Number or Whole = Number 100` (3D only). **Settings:** `space` (`3D` / `2D`), `through` (**Through**: **The mouse** (default) / **The middle of the screen**: where their camera itself looks, for a first-person game with the mouse captured; the client sends it too, `eye` / `forward`, Network Context Engine API 12; 3D), `from_name` (**From**, as above).
- **Output:** Vector3 in 3D (the ray's far end), Vector2 in 2D (their mouse in the world).
- **GDScript:** `<output> = _brickscript_player_aim(<player>, <true / false>, <length>, "Player Aim (brick <id>)"[, true for the middle of the screen])`, then `<from> = _brickscript_ray_from`.
- **Rules:** the aim is what the client says, like its keys: check it on the server where it matters (e.g. that From is near their character).
- **Exits:** `next`.

#### `event_mouse_moved`: When mouse moves
- Local brickscripts only. Runs when this machine's mouse moves (also while it's captured: mouse look). For what this machine shows, like turning its camera; the server reads where players look with Player Aim (Through: The middle of the screen). Always this machine's mouse (no "Runs on" setting).
- **Provides:** `motion` (Vector2: how far it moved, in the game's pixels; `InputEventMouseMotion.relative`), `screen_point` (Vector2: where it is).
- **GDScript:** in `_input(event: InputEvent)`, with `var motion` / `var screen_point` first and `if event is InputEventMouseMotion:`.
- **Exits:** numbered outputs.

#### `mouse_mode`: Mouse mode
- Local brickscripts only. How this machine's mouse behaves.
- **Settings:** `mode` (**Visible** / **Captured** (default: hidden and locked to the window, for mouse look) / **Confined** (kept in the window) / **Hidden**).
- **GDScript:** `Input.mouse_mode = Input.MOUSE_MODE_<MODE>`.
- **Exits:** `next`.

#### `world_to_screen`: World to Screen
- Local brickscripts only. Where a world position shows on the screen (a Vector2 in pixels): for name tags and markers over things. A Vector3 goes through a Camera3D, a Vector2 through the 2D view.
- **Inputs:** `position: Vector2 or Vector3 = Vector3 (0, 0, 0)`, `camera: Node` (only with A camera node). **Settings:** `camera_is`, `on_screen_name` (**On screen**, a Bool: in front of the camera and inside the screen's edges; blank: not kept).
- **Output:** Vector2. Optional when On screen is set.
- **GDScript:** `<output> = _brickscript_world_to_screen(<camera or null>, <position>, "World to Screen (brick <id>)")` (3D: `unproject_position`, on screen = not `is_position_behind` and inside `get_visible_rect()`; 2D: `get_canvas_transform() * position`), then `<on screen> = _brickscript_on_screen`.
- **Exits:** `next`.

#### `shake_camera`: Shake Camera
- Local brickscripts only. Shakes a camera for a while, fading out: hits, explosions, landing. It jolts the camera's offset only (Camera3D `h_offset` / `v_offset`, Camera2D `offset`), so it doesn't fight what moves the camera, and puts it back after. A new shake replaces one under way.
- **Inputs:** `strength: Number or Whole = Number 0.2` (world units for a Camera3D; pixels for a Camera2D, try 8), `duration: Number or Whole = Number 0.4` (seconds), `camera: Node` (only with A camera node). **Settings:** `camera_is` (This screen's camera: its Camera3D, else its Camera2D).
- **GDScript:** `_brickscript_shake(<camera or null>, <strength>, <duration>, "Shake Camera (brick <id>)")`: a Tween of the camera's (30 random steps a second, fading as (1 - t)²), so nothing of this script runs later.
- **Exits:** `next`.

**Culled for this machine** (2026-10-30; needs the **Cull Throttle Engine** plugin, `addons/cull_throttle_engine/`, its reference in `addons/cull_throttle_engine/README.md`): with it, an object (a Node3D with a script, a LocalScript / ServerScript, a moving body, or spawned) is **culled** for this machine when it's outside its camera's wide view (200 degrees) or too small to see from here (its radius / distance under 0.004; closer than 6 m never), and then hidden here (its `visible` isn't changed) and its processing slowed; in a network game the server culls it for each player by their character and stops sending it to them, so their machine hides it and it doesn't move there until seen again (it comes back where it is). Only the objects themselves: a brickscript on a part of one (a mesh, a light) asks about the object it's part of. Without the plugin nothing is ever culled. The two bricks are local (what this machine shows).

#### `event_culled`: When culled / shown
- Local brickscripts only (2026-10-30). Runs when a node is culled for this machine, or seen again: stop a sound, an effect or an expensive animation nobody here sees, start it again. Offline and on a host: by this machine's camera; on a client: when the server culls it for this player (Network Context Engine API 19). Never on a dedicated server (it has no camera).
- **Settings:** `which` (**When**: **Culled or shown** (default) / **Culled** / **Shown**), `whose` (**Whose**: **This node** (default: the object this script is on or part of; in a script node, Self.Parent) / **Any node**).
- **Provides:** `node` (Node: the object culled or shown), `culled` (Bool: true culled, false shown).
- **GDScript:** its own function `_brickscript_culled_<id>(node: Node3D, culled: bool)`, connected in `_ready` with `_brickscript_hear_culling(<function>, <0 / 1 / 2>, <this node or null>)` to the CullThrottleEngine's `culled_here_changed` (one connection per script; nothing without the plugin, or an older one than API 3).
- **Exits:** numbered outputs.

#### `is_culled_here`: Is culled here
- Local brickscripts only (2026-10-30). Whether a node is culled for this machine right now (the object it's part of; see above): a Bool, for If. E.g. skip particles or a costly Every frame for something nobody here sees. Always false without the Cull Throttle Engine, on a dedicated server, and for a node it doesn't follow (UI, a camera).
- **Inputs:** `node: Node = parent`.
- **Output:** Bool. **GDScript:** `<output> = _brickscript_is_culled_here(<node>)` (the CullThrottleEngine's `is_culled_here`).
- **Exits:** `next`.

### Mesh

Procedural meshes, 3D (2026-10-30). Each brick works on a **MeshInstance3D** (input `mesh: Node = parent`: in a script node Self.Parent; a known Type that isn't a MeshInstance3D is an error). Building goes in steps: **Begin mesh**, then any number of **Add triangle / Add quad / Add shape**, then **Finish mesh**, which puts the new mesh on the node (until then it keeps the one it has). Points are in the MeshInstance3D's own space (they move and turn with it). **Mesh vertices** reads a mesh's points (or colors) and puts changed ones back, to deform it. The building code is `runtime/meshes.gd` (preloaded by path by the generated helper `_brickscript_mesh_*`): what's added is kept on the node as a list of steps (metadata `_brickscript_mesh_steps`: `[0, a, b, c, color]` triangle, `[1, a, b, c, d, color]` quad, `[2, shape, at, size, color]` shape) and built into an `ArrayMesh` with one surface, colored by its vertex colors (a lit `StandardMaterial3D`, `vertex_color_use_as_albedo`; a `material_override` on the node wins as usual).
- **Which side shows:** a triangle's front is the side its corners go round **clockwise** (Godot's way). Finish mesh's Sides: **Both sides** (default) shows the back too.
- **Where it runs:** a server brickscript's mesh is on **every machine** (2026-10-30, Network Context Engine API 20, `set_node_data`): Finish mesh sends its recipe (the list of steps, Shading, Sides: a shape is a few numbers, a triangle its three corners) and every client builds the same mesh; Mesh vertices (Set) sends the new points (or colors) after it. Compressed when big (a 2,000-point list: ~3.5 KB instead of 24 KB). A player who joins later gets the recipe, then the points set since. Clients build them through the BrickscriptDebug autoload (it hears the engine's `node_data_changed`; `runtime/meshes.gd` `on_node_data`), so a client needs no brickscript of its own. Without the engine (or single-player) it's built here only; what was built before hosting goes to players who join. Each Finish mesh / Set is one reliable message to every client: fine when building or changing a mesh now and then, too much every frame (animate with a Tween or an AnimationPlayer instead). Not in a predicted event (Finish mesh is refused there). A local brickscript's mesh stays on its machine, and it may only **Finish mesh** / **Set** a mesh it may change (one it spawned itself: see "What a local brickscript may change"); Begin / Add only collect.
- **Cost** (Raspberry Pi 4, measured 2026-10-30; every client builds it too): a box + a sphere (138 points) 0.26 ms Flat / 1.2 ms Smooth, Set 0.4 ms, sent as 184 B (its points 673 B); 20 spheres 5 / 21 ms; a 64 x 64 grid of quads 42 ms Flat / 71 ms Smooth, Set 17 ms, ~42 KB a message. An Add brick ~8 µs. Fine when a level starts or now and then; not every frame.
- **Example:** a ServerScript under a MeshInstance3D: When ready → Begin mesh → Add shape (Box, At (0, 0.5, 0), Size (2, 1, 2), brown) → Add shape (Sphere, At (0, 1.5, 0), Size (1, 1, 1), green) → Finish mesh: a box with a ball on top. To bend it: Mesh vertices (Get) → For each item → Formula `item + Vector3(0, item.x * 0.2, 0)` → Add to list → Mesh vertices (Set) the new List.

#### `begin_mesh`: Begin mesh
- Starts a new mesh for a MeshInstance3D: forgets anything added since the last Begin / Finish.
- **Inputs:** `mesh: Node = parent`.
- **GDScript:** `_brickscript_mesh_begin(<mesh>, <brick>)`.
- **Exits:** `next`.

#### `add_triangle`: Add triangle
- Adds a triangle to the mesh being built (without Begin mesh, the first Add starts one). Flat-shaded by its own face (Finish mesh's Shading: Smooth joins it to its neighbours).
- **Inputs:** `mesh: Node = parent`, `a: Vector3 = (0, 0, 0)`, `b: Vector3 = (1, 0, 0)`, `c: Vector3 = (0, 0, 1)` (as given, it faces up), `color: Color = white`.
- **GDScript:** `_brickscript_mesh_add(<mesh>, [_BrickscriptMeshes.TRIANGLE, <a>, <b>, <c>, <color>], <brick>)`.
- **Exits:** `next`.

#### `add_quad`: Add quad
- Adds a four-cornered face: corners A, B, C, D in order round its edge (two triangles, A B C and A C D; for a flat face, keep them in one plane).
- **Inputs:** `mesh: Node = parent`, `a: Vector3 = (0, 0, 0)`, `b: Vector3 = (1, 0, 0)`, `c: Vector3 = (1, 0, 1)`, `d: Vector3 = (0, 0, 1)` (a square facing up), `color: Color = white`.
- **GDScript:** `_brickscript_mesh_add(<mesh>, [_BrickscriptMeshes.QUAD, <a>, <b>, <c>, <d>, <color>], <brick>)`.
- **Exits:** `next`.

#### `add_shape`: Add shape
- Adds a ready shape: its middle **At**, **Size** across (a box's sides; a sphere 1 across is 1 wide; a cylinder stands up, y its height; a plane faces up and uses x and z). Spheres and cylinders have 16 sides round (a sphere 8 rings); shapes keep their own shading (a sphere is round even when Flat). UVs as Godot's BoxMesh / SphereMesh / CylinderMesh / PlaneMesh.
- **Inputs:** `mesh: Node = parent`, `at: Vector3 = (0, 0, 0)`, `size: Vector3 = (1, 1, 1)`, `color: Color = white`.
- **Settings:** `shape` (**Shape**: **Box** (default) / **Sphere** / **Cylinder** / **Plane**; stored as 0-3).
- **GDScript:** `_brickscript_mesh_add(<mesh>, [_BrickscriptMeshes.SHAPE, <0-3>, <at>, <size>, <color>], <brick>)`.
- **Exits:** `next`.

#### `finish_mesh`: Finish mesh
- Builds what was added since Begin mesh into the node's mesh (a new `ArrayMesh`; nothing added: an empty mesh). Changes the node, so in a local brickscript only on a node it may change.
- **Inputs:** `mesh: Node = parent`.
- **Settings:** `shading` (**Shading**: **Flat** (default): every triangle its own face, a point per triangle corner; **Smooth**: shaded round: corners in the same place and of the same color are one point (indexed), its normal the average of the faces meeting there; texture coordinates then come from the place (x, z); built with Godot's SurfaceTool (`generate_normals`, `index`)), `sides` (**Sides**: **Both sides** (default) / **One side**: only the fronts, cheaper, for closed shapes).
- **GDScript:** `_brickscript_mesh_finish(<mesh>, <smooth: true / false>, <both sides: true / false>, <server brickscript: true / false>, <brick>)` (a server brickscript's also `set_node_data(<mesh>, &"brickscript_mesh", [steps, smooth, both sides])` and forgets the points / colors set before).
- **Exits:** `next`.

#### `mesh_vertices`: Mesh vertices
- A MeshInstance3D's points, or their colors, of its mesh's first surface (any mesh: one built here, or a BoxMesh... from a scene). **Mode Get** (default) reads them into the Output; **Mode Set** puts a List back. A Smooth mesh has one point per corner place (one more where the color changes there), so moving a point moves every triangle at it; a Flat one has a point per triangle corner (they come apart when moved one by one: move points by where they are, a Formula of the point). After Set a point whose triangles have no area (a sphere's pole) keeps its normal. After Set, normals are worked out again (indexed meshes smooth, others flat; a Flat sphere then looks faceted). A mesh the node didn't build here (one from the scene, maybe shared) is copied first, so other nodes keep theirs.
- **Inputs:** `mesh: Node = parent`; Set: `value: List` (as many items as the mesh has points).
- **Settings:** `mode` (**Mode**: **Get** / **Set**), `of` (**Of**: **Positions** (default: Vector3s, in the node's own space) / **Colors** (Colors; white for a mesh without colors; a mesh keeps colors to 1/255, so a color read back may differ a little from the one added: 0.55 comes back 0.549)).
- **Output (Get):** a List of Vector3s (Positions) or of Colors. No mesh: an empty List.
- **Errors when it runs:** a List of another length (`got 1 points for a mesh of 3 points`), an item of the wrong type, no mesh, not a MeshInstance3D. Compile errors: Set with a typed List of something else, a local brickscript's Set on a node it may not change.
- **GDScript:** Get `<output> = _brickscript_mesh_points(<mesh>, <brick>)` / `_brickscript_mesh_colors(...)`; Set `_brickscript_mesh_set(<mesh>, <value>, <as colors: true / false>, <server brickscript: true / false>, <brick>)` (a server brickscript's also `set_node_data(<mesh>, &"brickscript_mesh_points" / &"brickscript_mesh_colors", <PackedVector3Array / PackedColorArray>)`).
- **Exits:** `next`.

### Terrain

Ground from the **Terrain Engine** plugin (Plugin 4, 2026-10-31): every terrain brick has a **`terrain` input** (2026-11-02): a Terrain node (its picker's dropdown lists only the scenes' Terrains; a variable holding one, e.g. When terrain ready's `terrain`; another kind of node is a compile error, one whose type isn't known is checked when it runs). **Left blank** (the default, and in brickscripts saved before it): the scene's **Terrain** (the first in the group `terrain_engine_terrains` in the brickscript's own 3D world, else the first: a SubViewport's scene has its own, 2026-10-31); the brick shows "the scene's Terrain". Called by method name (blank Terrain: `null` in the GDScript); without the plugin or a Terrain they still compile and run (the spot's own height, no ground, never ready). A Terrain builds itself from its seed on every machine (the server sends the seed and settings), with collision; on the server (or single-player) it also bakes navigation where the players are, with the static colliders in the group `navigation_geometry` (crates, walls) cut out, so Walk to, Follow, Find path and Random reachable spot work on it. Its reference: `addons/terrain_engine/README.md`. Example: case `terrain_bricks`.

#### `terrain_height`: Terrain height
- The height of the Terrain's ground at a spot or a node's position: where to put something on the ground. Works anywhere, built there yet or not (it comes from the seed). Without a Terrain, or outside a Fixed world's edges: the spot's own height.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `at: Vector3 or Node = this node`.
- With caves or hand edits (2026-10-31): the highest ground there, edits counted; over a cave's mouth, the cave's floor.
- **Output:** Number (world y).
- **Exits:** `next`.
- **GDScript:** `<output> = _brickscript_terrain_height(<at>, <brick>, <terrain>)` (the Terrain's `height_at`).

#### `dig_terrain`: Dig terrain
- Server brickscripts only (2026-10-31). Digs a ball of ground away from the scene's Terrain at a spot or a node's position: **Size** is its radius in meters, **Strength** (0-1) how much of it goes (0.5: about half as deep). Every machine sees it, players who join later too (the Terrain sends its digs as node data, Network Context Engine API 20: 16 digs a message, ~600 bytes at most); collision, navigation and Terrain height follow. Only the chunks it reaches are built again, on the Terrain's threads: the hole shows a moment later (a frame or a few). **Kept for the session:** the saved world (the editor's edits) isn't changed; a game started again has its ground back. A player digging is the usual pattern: their LocalScript's click goes **Fire Server** (with where), the server checks it (in reach? allowed?) and digs. Without a Terrain: an error naming the brick, once. Example: case `terrain_digging`.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `at: Vector3 or Node = this node`, `size: Number = 2`, `strength: Number = 1`.
- **Exits:** `next`.
- **GDScript:** `_brickscript_change_terrain(&"dig", <at>, <size>, <strength>, Color.BLACK, <brick>, <terrain>)` (the Terrain's `dig(at, radius, strength)`).

#### `fill_terrain`: Fill terrain
- Server brickscripts only (2026-10-31). Adds a ball of ground at a spot or a node's position: close a hole, build a mound or a wall (otherwise as Dig terrain). Filling above the world's highest ground builds the whole Terrain again (slow on a big world).
- **Inputs:** `terrain: Node (a Terrain) = blank`, `at: Vector3 or Node = this node`, `size: Number = 2`, `strength: Number = 1`.
- **Exits:** `next`.
- **GDScript:** `_brickscript_change_terrain(&"fill", <at>, <size>, <strength>, Color.BLACK, <brick>, <terrain>)` (the Terrain's `fill(at, radius, strength)`).

#### `paint_terrain`: Paint terrain
- Server brickscripts only (2026-10-31). Paints the ground's color in a ball at a spot or a node's position (cave walls too), Strength (0-1) mixing it in (otherwise as Dig terrain).
- **Inputs:** `terrain: Node (a Terrain) = blank`, `at: Vector3 or Node = this node`, `size: Number = 2`, `color: Color = (0.8, 0.2, 0.2)`, `strength: Number = 1`.
- **Exits:** `next`.
- **GDScript:** `_brickscript_change_terrain(&"paint", <at>, <size>, <strength>, <color>, <brick>, <terrain>)` (the Terrain's `paint(at, radius, color, strength)`).

#### `has_ground_at`: Has ground at
- Whether the Terrain's ground is in place at a spot or a node's position, with its collision: a body dropped there lands. A Streamed terrain builds only around its viewers (players' characters, the camera, the group `terrain_viewers`), so check before spawning far away, or wait. False without a Terrain.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `at: Vector3 or Node = this node`.
- **Output:** Bool.
- **Exits:** `next`.
- **GDScript:** `<output> = _brickscript_has_ground(<at>, <brick>, <terrain>)` (the Terrain's `has_ground_at`).

#### `event_terrain_ready`: When terrain ready
- Runs when a Terrain has built its ground (Streamed: around its viewers) with its collision and, on the server, its navigation (in the map: paths work at once): spawn players, NPCs or gems then. Also once at the start for a Terrain already ready, and again whenever one builds again (another seed), but not when digs or edits are built in (2026-10-31: Dig terrain from it would run it again). Only Terrains in the brickscript's own 3D world. Never runs without the plugin. Every machine (each builds its own).
- **Provides:** `terrain` (Node, typed as a **Terrain** (2026-11-02): Property / Call method list its settings and methods (`world_seed`, `biomes`, `is_built`...) without "isn't known" warnings; it fits every Terrain input. Without the plugin, a plain Node3D).
- **GDScript:** `func _brickscript_terrain_ready_<id>(terrain: Node3D) -> void:`, connected at the start of `_ready` with `_brickscript_on_terrain_ready(...)` (every Terrain's `terrain_ready`, the ones added later too; one already ready: a deferred call). Its members are read by name (`terrain.get(&"world_seed")`, typed from the Terrain's script).
- **Exits:** numbered outputs.

#### `event_terrain_cleared`: When terrain cleared
- Runs when a Terrain's world is taken away (Clear terrain, its `clear_world()`; on a client when the server's was, 2026-11-02): hide or remove what stood on it. Only Terrains in the brickscript's own 3D world. Never runs without the plugin.
- **Provides:** `terrain` (Node, typed as a Terrain, as When terrain ready's).
- **GDScript:** `func _brickscript_terrain_cleared_<id>(terrain: Node3D) -> void:`, connected with `_brickscript_on_terrain_cleared(...)` (every Terrain's `cleared`, the ones added later too).
- **Exits:** numbered outputs.

#### `biome_at`: Biome at
- The name of the Terrain's biome (its TerrainBiome's `name`) with the most say at a spot or a node's position (2026-11-02); empty Text when the Terrain has no biomes. From the seed: works anywhere, built there yet or not. Without a Terrain: empty, and an error naming the brick, once.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `at: Vector3 or Node = this node`.
- **Output:** Text.
- **Exits:** `next`.
- **GDScript:** `<output> = _brickscript_biome_at(<terrain>, <at>, <brick>)` (the Terrain's `biome_at`).

#### `solid_at`: Solid at
- Whether a spot (or a node's position) is inside the Terrain's ground: caves, hand edits and digs counted (2026-11-02). From the shape, no collision needed. Without a Terrain: false, and an error once.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `at: Vector3 or Node = this node`.
- **Output:** Bool.
- **Exits:** `next`.
- **GDScript:** `<output> = _brickscript_solid_at(<terrain>, <at>, <brick>)` (the Terrain's `solid_at`).

#### `build_terrain`: Build terrain
- Server brickscripts only (2026-11-02). Builds the Terrain's world again from its settings (what was there goes): for a Terrain with Build on load off, or a new world each round. **Which seed** first: Keep it (default), A random one, or This one (a `seed` input). Every machine builds it too, players who join later as well (the Terrain sends its settings); When terrain ready runs when it's done. Without a Terrain: an error once.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `seed: Whole = 0` (shown with Seed This one).
- **Settings:** `seed_is` (**Which seed**: Keep it / A random one / This one).
- **Exits:** `next`.
- **GDScript:** `_brickscript_build_terrain(<terrain>, <0 keep / 1 random / 2 given>, <seed>, <brick>)` (sets `world_seed`, then the Terrain's `build()`).

#### `clear_terrain`: Clear terrain
- Server brickscripts only (2026-11-02). Takes the Terrain's world away on every machine (meshes, collision, navigation); Terrain height and Solid at still answer from its settings; Build terrain brings it back. When terrain cleared runs.
- **Inputs:** `terrain: Node (a Terrain) = blank`.
- **Exits:** `next`.
- **GDScript:** `_brickscript_clear_terrain(<terrain>, <brick>)` (the Terrain's `clear_world()`).

#### `terrain_ray`: Terrain ray
- Where a straight line from one point to another first meets the Terrain's ground, caves and digs counted (2026-11-02), then **Hit ground** or **No ground** runs. From the shape, so no collision needed: works where the ground isn't built yet, or on a machine without collision (a dedicated server builds collision only near players). Raycast finds bodies; this finds only the ground.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `from: Vector3 or Node = this node`, `to: Vector3 or Node = (0, -100, 0)`.
- **Settings (Also fills):** `normal_name` (**Normal**: which way the ground faces there, length 1; (0, 0, 0) with no ground).
- **Output:** Vector3: the point (To when there's no ground).
- **Exits:** `hit` (Hit ground), `missed` (No ground).
- **GDScript:** `_brickscript_terrain_hit = _brickscript_terrain_ray(<terrain>, <from>, <to>, <brick>)` (the Terrain's `raycast`; `{hit, position, normal}`), then `<output> = _brickscript_terrain_hit["position"]`, `if _brickscript_terrain_hit["hit"]:`.

#### `random_open_spot`: Random open spot
- A random spot in **open space** (a cave, the air: not inside the Terrain's ground) within **Radius** (flat) of a spot or a node, between **Height from** and **Height to** (2026-11-02, user): where to put a crystal in a cave, spawn a monster at a depth, drop loot into a cavern. From the Terrain's shape (caves, cave biomes, hand edits and digs counted), so it works on every machine, built there yet or not. Up to **Tries** random spots are tried, then **Found** or **None found** runs.
- **Inputs:** `terrain: Node (a Terrain) = blank`, `around: Vector3 or Node = this node`, `radius: Number = 20`, `height_from: Number = 4`, `height_to: Number = 30`, `room: Number = 1` (how much open space it needs around it, meters: about 1 for a crystal, 1.5-2 for a character), `tries: Whole = 30`.
- **Settings:** `must_be` (**Must be**: In the air (default: anywhere open) / On a floor (open space with the ground right under it: the Output is the floor point, Room counted above it)), `height_is` (**Height is**: Depth under the surface (default: meters under the ground's surface at that spot, so "4 to 30 deep" works on hills too) / World Y), `checks` (**Checks**: Terrain (default) / Terrain + nodes: also no other body (crates, walls, characters, not areas) within Room; their collision, so only where it's in place).
- **Output:** Vector3: the spot (On a floor: the floor under it); Around when none was found.
- **Exits:** `found` (Found), `none` (None found: no open space there in Tries tries: none in that range, or Room too big).
- In the air checks the spot and 6 points Room away (up, down and around); On a floor casts down from the picked height to the range's bottom (a ray starting in rock goes on into the cave under it) and checks open space Room above the floor it meets (facing up). Without a Terrain: None found, and an error naming the brick, once. **Cost** (Pi 4, measured 2026-11-02, a 48 x 48 Caves world): about 0.5 ms a call In the air, 2 ms On a floor (its ray down), each failed try ~0.17 ms (30 tries finding nothing: ~5 ms): fine when spawning, not every frame.
- **GDScript:** `_brickscript_open_spot = _brickscript_random_open_spot(<terrain>, <around>, <radius>, <height_from>, <height_to>, <room>, <tries>, <on floor: true / false>, <by depth: true / false>, <with nodes: true / false>, <brick>)` (the Terrain's `height_at`, `raycast`, `solid_at`; nodes: `intersect_shape` with a SphereShape3D, the Terrain's own bodies left out), then `<output> = _brickscript_open_spot["position"]`, `if _brickscript_open_spot["found"]:`. Example: case `open_spot`.

### Lists and tables

Lists (`Array`) and Tables (`Dictionary`) can only be typed in empty (e.g. a Variable (Set) that starts an empty List; its "of" dropdown picks the item type). Fill them with Make list / Make table or the edit bricks. Lists are typed (see "Typed lists" in section 1): items read from a List of Number are Numbers, from a List of Anything they're Anything. Tables too ("Typed tables"): values read from a Table of Text -> Number are Numbers.

#### `make_list`: Make list
- **Inputs:** `item_1`, `item_2`, ...: any (default Number 0). Use **+ / −** in Properties to add or remove values (starts with 2; the count is stored in `settings.count`).
- **Settings:** `items` (default `Auto`; or Anything, Number, Whole, Text, Bool, Vector2, Vector3, Color, Node, Resource, List, Table). Auto: from the values. All one type gives a List of it, Whole and Number mixed a List of Number, nodes a List of their nearest shared class, anything else mixed a List of Anything. A picked type: every value must fit it (compile error otherwise).
- **Output:** List of those items
- **GDScript:** `<output> = [item_1, item_2, ...]` (Whole values in a List of Number are written `float(...)`, decimals in a List of Whole `roundi(...)`), e.g. `var nums: Array[float] = []` ... `nums = [1.5, float(2)]`
- **Exits:** `next`.

#### `make_table`: Make table
- **Inputs:** rows of `key_N` (any, default Text "key") and `value_N` (any, default Number 0). Use **+ / −** for rows (starts with 1).
- **Settings:** `keys`, `values` (each default `Auto`; or Anything, Number, Whole, Text, ...: the same choices as Make list's Items). Auto works each side out like Make list (all one type, Whole and Number mixed: Number, nodes: their shared class, else Anything); a picked type: every key / value must fit it.
- **Output:** Table of those keys and values
- **GDScript:** `<output> = {key_1: value_1, ...}` (Whole values among Numbers written `float(...)`, decimals among Wholes `roundi(...)`), e.g. `var stats: Dictionary[String, int] = {}` ... `stats = {"hp": 5}`
- **Exits:** `next`.

#### `get_item`: Get item
- **Inputs:** `list: List = Variable ("")`, `index: Number or Whole = Whole 0`
- **Output:** the List's item type (a Number from a List of Number, a Label from a List of Label; Anything from an untyped List)
- **GDScript:** `<output> = list[index]`. An index out of range is an error when the game runs.
- **Exits:** `next`.

#### `unpack_table`: Unpack table
- Reads chosen keys of a Table into variables named after them, at once (instead of a Get value per key): keys `speed` and `jump` fill `speed` and `jump`.
- **Inputs:** `table: Table = Variable ("")`; rows of `key_N: Text` (typed in only: each names the variable it fills; + / − for rows, starts with 2).
- **Fills:** each key's variable: a new chain variable of the Table's value type (Anything for an untyped Table), or an existing variable of that name (which must take that type).
- **GDScript:** `<key> = <table>.get("<key>", <zero>)` per key; `<zero>` is the value type's zero (`0.0`, `0`, `""`, `false`, `Vector3(0, 0, 0)`, `[]`, `{}`), `null` for Anything, Nodes and Resources.
- **Rules:** a key must be a valid name (letters, digits, `_`; not a GDScript word); a Table whose keys are typed but not Text is an error.
- **Exits:** `next`.

#### `get_value`: Get value
- **Inputs:** `table: Table = Variable ("")`, `key: any = Text "key"`, `fallback: any = Number 0` (from a typed Table, the key must fit its keys and the fallback its values)
- **Output:** of the Table's value type (Anything for an untyped Table); the fallback when the key is missing
- **GDScript:** `<output> = table.get(key, fallback)`
- **Exits:** `next`.

#### `list_add`: Add to list
- **Inputs:** `list: List = Variable ("")` (changed in place), `value: any = Number 0`
- **GDScript:** `list.append(value)` (`roundi(value)` for a decimal into a List of Whole)
- **Rules:** the list must be a variable that may change. Not a Constant; not an Export (make a changeable Shared copy). The value must fit a typed List's items ("a List of Number can't hold a Text"; Anything is checked when the game runs).
- **Exits:** `next`.

#### `list_remove`: Remove item at
- **Inputs:** `list: List` (changed in place), `index: Number or Whole = Whole 0`
- **GDScript:** `list.remove_at(index)`
- **Exits:** `next`.

#### `table_set`: Set value in table
- **Inputs:** `table: Table` (changed in place), `key: any = Text "key"`, `value: any = Number 0` (for a typed Table they must fit its keys and values)
- **GDScript:** `table[key] = value` (`roundi(value)` for a decimal into Whole values)
- **Exits:** `next`.

#### `table_remove`: Remove key
- **Inputs:** `table: Table` (changed in place), `key: any = Text "key"`
- **GDScript:** `table.erase(key)`
- **Exits:** `next`.

#### `size`: Size
- **Inputs:** `of: List, Table or Text = Variable ("")`
- **Output:** Whole
- **GDScript:** `<output> = len(of)`
- **Exits:** `next`.

#### `has`: Has
- True if a List contains the item, a Table has the key, or a Text contains the text.
- **Inputs:** `collection: List, Table or Text = Variable ("")`, `item: any = Text "key"`
- **Output:** Bool
- **GDScript:** `<output> = item in collection`
- **Exits:** `next`.

### Math

All math bricks have an **Output** dropdown (see "How Brickscript works"). Not keeping the result gives a warning.

#### `formula`: Formula
- Arithmetic typed as one line of text, e.g. `(speed * delta + 1) * 2`.
- **Settings:** `expression`.
- **Output:** worked out by trying the formula once with sample values (Number, Whole, Text, Bool, Vector2, Vector3 or Color). A formula that reads a List, Table, Node or Anything variable can't be tried, so its output is Anything.
- **A variable named like a built-in function** (`seed`, `sign`, `hash`, `step`...) can't be read in a formula (Godot reads the name as that function): the error says so; rename the variable (2026-11-02).
- **Allowed names:**
  - variables (chain, event values, script)
  - members after a dot (`spot.x`)
  - `and or not true false PI TAU INF abs sign min max clamp clampf clampi lerp lerpf inverse_lerp sqrt pow exp log floor ceil round floori ceili roundi sin cos tan asin acos atan atan2 deg_to_rad rad_to_deg snapped fmod fposmod posmod wrapf wrapi move_toward is_zero_approx is_equal_approx randf randi randf_range randi_range str int float bool len Vector2 Vector3 Color typeof TYPE_NIL TYPE_BOOL TYPE_INT TYPE_FLOAT TYPE_STRING TYPE_VECTOR2 TYPE_VECTOR3 TYPE_COLOR TYPE_OBJECT TYPE_ARRAY TYPE_DICTIONARY` (`typeof(x) == TYPE_VECTOR3`: check what a message's values are before trusting them)
  - Anything else is an error, which keeps out `OS.*` and similar.
- **Limits:**
  - one line
  - `/` between two whole numbers truncates, as in GDScript; use the Divide brick for decimals
- **GDScript:** `<output> = <expression>`; `str(player)` of a Player variable (2026-10-30) is `_brickscript_player_text(player)`: their name, or `no player` (not `<null>`).
- **Exits:** `next`.

#### `add`: Add / `subtract`: Subtract / `multiply`: Multiply
- **Inputs:** `a`, `b`: Number, Whole, Vector2 or Vector3 (default Number 0).
- **Output:**
  - Whole if both are Whole; Number for other number mixes.
  - the vector type for two vectors of the same kind.
  - Multiply also scales a vector by a number (either order).
  - Anything if either side is Anything.
- **GDScript:** `<output> = a + b` / `a - b` / `a * b`
- **Exits:** `next`.

#### `divide`: Divide
- **Inputs:** `a`, `b`: Number, Whole, Vector2 or Vector3 (defaults 0 and 1).
- **Output:**
  - Number for numbers: two Wholes become `float(a) / b`, so 7 ÷ 2 = 3.5.
  - A vector divided by a number, or by a vector of the same kind, gives that vector.
- **GDScript:** `<output> = a / b`
- **Exits:** `next`.

#### `make_vector2`: Construct Vector2
- **Inputs:** `x`, `y`: Number or Whole (default 0)
- **Output:** Vector2
- **GDScript:** `Vector2(x, y)`
- **Exits:** `next`.

#### `make_vector3`: Construct Vector3
- **Inputs:** `x`, `y`, `z`: Number or Whole (default 0)
- **Output:** Vector3
- **GDScript:** `Vector3(x, y, z)`
- **Exits:** `next`.

### Not bricks, but on the canvas
- **Comment frames:** titled, colored boxes that group bricks. Bricks attached to a frame move with it. Editor-only: never compiled.
  - **Putting bricks in and out:** drop a brick on a frame to put it in. Drag a brick on its own (without its frame) and the frame stays put; dropped with its middle still inside the frame it stays in, dropped outside it leaves the frame. Making a frame smaller lets go of the bricks whose middle it no longer covers.
  - **Adding one:** the toolbar's **Frame** button (around the selected bricks, or empty in the middle of the view), or right-click the canvas > Comment frame.
  - **Size:** a frame holding bricks fits itself around them (growing and shrinking as they're moved or resized) until you drag its corner; from then on it keeps your size, only growing when a brick would stick out. You can drag its corner inside its bricks: the ones whose middle ends up outside leave it; dragging it over bricks that are in no frame takes them in (their middle inside; another frame's bricks stay with it). **Fit to its bricks** in Properties fits it again. (Its title is one line: a frame is at least as wide as its title.)
  - **Title:** a long title wraps to the frame's width (the frame doesn't widen for it): each extra line makes the title bar a line taller and the frame a grid square taller above its bricks.
  - **Properties** (click it): title, color (picker, or a row of quick colors), Release nodes, Fit to its bricks, Delete frame.
  - Stored in `frames` (see the data format) with `fit` (false once resized by hand).

---

## 3. Planned bricks (not built yet; names may change)

| Planned brick | What it will do | Status |
|---|---|---|
| Run outputs together | An option for an event's outputs to start at once instead of one after another (matters with Wait) | idea |


---

## 4. Data format (for building or reading graphs in code)

### Brickscript files

- **Kinds:** `<name>.bricklocal` (context local), `<name>.brickserver` (context server), `<name>.brickshared` (a shared brickscript: `shared` true, its stored context says Used by Both (local) or Server only (server)). The extension decides the context of the first two. All three load (`ResourceLoader.load`) as a **GDScript** compiled from the graph; the editor lists them as type `Script` (not `GDScript`, which the editor would re-read as GDScript source). Older `<name>.brick` files load as a `BrickscriptFlowGraph`, keep their stored context and generate `<name>.gd`.
- **Code:** `core/brick_file.gd`: `load_graph(path)` / `save_graph(graph, path)` (the graph, for editing), `load_script(path)` (what the loader returns), `script_source(graph, path)` (the compiled code, or for a graph with problems a script extending its base type that reports them in `_ready`), `refresh_loaded_script(graph, path)` (after saving), `is_script_path`, `context_of_path`, `is_server_path`, `new_graph`. A server graph is a `BrickscriptServerGraph` (`core/brick_server_graph.gd`).
- **Layout:** plain text. The first line is
  `# Brickscript graph. Edit it in the Brickscript tab; this file is rewritten on save.`
  followed by Godot value text (`var_to_str`) of `{"format": 7, "graph": <snapshot>}` (the current format: `core/brick_file.gd` `FORMAT`). `<snapshot>` is `flow_ops.gd` `snapshot(graph)`: `base_type`, `context`, `parent_type` (the parent's node type, see Node types), `body_type` (a script node's parent, or a server brickscript carried in a node's `server_script` metadata: that node's type, found in the scenes by the editor; `{}` otherwise), `script_node` (missing in older files: false), `nodes` (each node's fields below, as a Dictionary), `variables` (older graphs), `frames`, `next_node_id`, `next_variable_id`.
- **Text:** `core/brick_file.gd` `to_text` / `from_text`. `core/brick_loader.gd` (`BrickscriptFileLoader`) and `core/brick_saver.gd` (`BrickscriptFileSaver`) have a `class_name`, so Godot registers them itself. Loaders added by hand are dropped whenever the editor refreshes its script classes.
- **Safety:** reading never creates objects. `Ops.decode_data` refuses text that uses `Object(`, `Resource(`, `ExtResource(` or `SubResource(` outside a quoted string. Plain `str_to_var` would build them. Clipboard paste uses the same check.
- **Versioning:** `format` is bumped when the data changes shape; files with a newer format are refused. 2 (2026-10-22): Node inputs default to the parent; format 1 files get "this node" stored where they used the default. 3 (2026-10-22): players are Players; in older files Give To's input `peer` becomes `player`, and uses of Player Joined / leaves's `peer` are renamed `player` (`flow_ops.gd` `players_upgrade`; left alone if a brick makes its own variable called `player`). 4 (2026-10-27): Get / Set Character are Property (Get / Set), the Character brick is Get Character (`character_bricks_upgrade`). 5 (2026-10-28): a script node's paths start at the script node (Self), not its parent; in older script-node files every typed-in path and Node setting moves one step up (`.` / blank -> `..`, `..` -> `../..`, `Hat` -> `../Hat`; inputs left at their default are written out first) so it names the same node; an unwired Variable's starting value and When signal received of its own signal (already the script node's) stay (`flow_ops.gd` `script_node_paths`, also run when **Acts for** changes, either way). 6 (2026-10-28): Change property is Property's Add mode (`change_property_upgrade`: amount -> value). 7 (2026-10-28): Get property and Set property are one brick, Property, and Set Var is Variable, each with Mode Get / Set / Add (`access_modes_upgrade`; a brick saved without a mode is Set). Brick families (2026-11-03) kept format 7: a family's dropdown picks the type, which files already store (see Brick families in section 2).
- **The game loads brickscript files itself:** the loader has a `class_name`, so Godot registers it in exported games too, and compiles each file once when it is first loaded. Checked in Linux arm64 exports (`tests/run_export_check.sh`); `.bricklocal` / `.brickserver` are included by the default "Export all resources" filter.

```gdscript
# BrickscriptFlowGraph (core/flow_graph.gd), a Resource
base_type: StringName                 # e.g. &"Node", &"CharacterBody3D"
context: StringName                   # &"local" / &"server" (set by the file's extension)
parent_type: Dictionary               # the parent's node type (what ".." is), from the scenes
body_type: Dictionary                 # what "this node" is when it isn't the node itself: a script node's parent, or a server brickscript's carrier
script_node: bool                     # a script node (acts for its parent); false: acts on the node it's on (older)
shared: bool                          # a shared brickscript (.brickshared): only functions and variables, one copy per machine
variables: Array[BrickscriptVariable] # older graphs only (now: Variable (Set) bricks)
nodes: Array[BrickscriptFlowNode]
frames: Array[Dictionary]             # {id, title, color, position, size, nodes: [node ids], fit}
next_node_id: int                     # ids are never reused (shared by nodes and frames)
next_variable_id: int

# BrickscriptFlowNode (core/flow_node.gd)
id: int
type: StringName                      # a key of flow_library.gd NODES, e.g. &"if"
inputs: Dictionary[StringName, Dictionary]  # {"var": "name"} or {"type": ValueType, "value": v}; a Node path may add "node": its node type
# (kinds: events start chains, actions run in them, Constant / Export declare and have no wires)
settings: Dictionary[StringName, Variant]   # action, expression, operator, Variable (Set) name / var_kind, loop names, count, message, to, path, node_class, node_script, property, method, scene, signal
output_name: String                   # "" = result not kept
use_var: bool                         # true: write into an existing variable
exits: Dictionary[StringName, int]    # exit name -> target node id (&"next", &"true", &"false", &"1", &"2", ...)
position: Vector2                     # editor only, 16 px grid
size: Vector2                         # editor only, ZERO = fit content

# BrickscriptVariable (core/brick_variable.gd)
id, name, kind (CONSTANT / EXPORT / SHARED), type (ValueType), number / text / value
```

### Example: the double jump, built and compiled in code

```gdscript
const Ops = preload("res://addons/brickscript/core/flow_ops.gd")
const Compiler = preload("res://addons/brickscript/core/flow_compiler.gd")
const T = preload("res://addons/brickscript/core/flow_types.gd").ValueType

var graph := BrickscriptFlowGraph.new()
# Variables come from bricks: a Constant brick (no wires), and an unwired
# Shared Variable (Set) for a starting value.
Ops.add_node(graph, &"constant", Vector2(-240, 0)).setting(&"name", "MAX_JUMPS") \
	.input_value(&"value", T.WHOLE, 2)
Ops.add_node(graph, &"set_var", Vector2(-240, 160)).setting(&"name", "jumps") \
	.setting(&"var_kind", "Shared").input_value(&"value", T.WHOLE, 0)
var pressed := Ops.add_node(graph, &"event_action_pressed", Vector2(0, 0))
var check := Ops.add_node(graph, &"if", Vector2(240, 0)).input_variable(&"a", "jumps") \
	.setting(&"operator", "<").input_variable(&"b", "MAX_JUMPS")
var count := Ops.add_node(graph, &"add", Vector2(480, 0)).input_variable(&"a", "jumps") \
	.input_value(&"b", T.WHOLE, 1).output("jumps", true)   # into the existing variable jumps
var say := Ops.add_node(graph, &"print", Vector2(480, 160)).input_value(&"value", T.TEXT, "No jumps left")
Ops.connect_exit(graph, pressed, &"1", check)
Ops.connect_exit(graph, check, &"true", count)
Ops.connect_exit(graph, check, &"false", say)

var compiler := Compiler.new()
var source: String = compiler.compile(graph)  # "" if compiler.errors isn't empty
```

**Running it:** in a tool script of your own, e.g. `tools/build_jump.gd` starting with `extends SceneTree`, the code above in `func _initialize() -> void:` ending with `quit()`, run headless from the project root: `godot --headless --path . -s res://tools/build_jump.gd`. The plugin needn't be enabled and no editor is needed (`BrickscriptFlowGraph` / `BrickscriptFlowNode` are global classes). Load brickscript files (`load("res://x.bricklocal")`) in `_initialize` or later, not in `_init`: Godot registers the brickscript loader only after `_init` has run, so there `load()` fails ("No loader found") and a scene packed and saved there loses its brickscripts. If it must happen in `_init`, call `BrickscriptFileLoader.ensure_registered()` first (2026-10-30; it registers the loader and saver, once). A scene with brickscripts added to the tree in `_initialize`, before the first frame, may not have run its server brickscripts' When ready by the end of `add_child` (a blind usability run found a mesh not built yet): `await process_frame` once before adding it when you need its results at once. To keep it, save it: `const BrickFile = preload("res://addons/brickscript/core/brick_file.gd")`, then `BrickFile.save_graph(graph, "res://jump.bricklocal")` (returns an Error, OK = 0); the file loads as a script.

**A node's builder methods** (`core/flow_node.gd`; each returns the node, so they chain):
- `.setting(name, value)`: a setting, e.g. `.setting(&"mode", "Add")`. A choice is stored as its label text (`"Only nodes I own"`), as the editor shows it.
- `.input_value(name, type, value)`: a typed-in value, `type` from `flow_types.gd` `ValueType` (`T.WHOLE`, `T.TEXT`, `T.NODE` with a path...).
- `.input_variable(name, variable)`: read a variable.
- `.input_node(name, path, class = &"", script = "")` (2026-10-30): a Node input typed in as a path **with the node's type**, as the editor's path picker stores it from the scenes, e.g. `.input_node(&"of", "../UI/Score", &"Label")`. Without the type the node is "some Node": a local brickscript's Property (Set) on that Label is refused (not UI), and its members are used by name.
- `.output(name, into_existing = false)`: where the result goes (true: an existing variable).

The node's data is plain: `inputs` (`{"var": name}` or `{"type": T.X, "value": v}`, a Node's also `"node": {"class", "script"}`), `settings`, `output_name`, `exits` (`{exit: node id}`). Saving one graph from the editor and reading the file shows every field.

**When a call refuses:** `Ops.add_node` gives null for an unknown brick type and `Ops.connect_exit` false for a wire it won't make (into an event, to itself, an exit the brick doesn't have, back into what leads to it: a loop). **`Ops.last_error`** says why (empty after one that worked), and outside the editor it's also a warning (`Brickscript connect_exit: ...`).

Building other brickscripts in code (what the editor sets up for you):
- **A server brickscript:** `BrickFile.new_graph(&"server")` (`core/brick_file.gd`; `&"local"` is the default), which sets `context`. Save it with `BrickFile.save_graph(graph, "res://.../name.brickserver")` (`.bricklocal` for a local one); the file loads as a script.
- **A script node's** (a LocalScript / ServerScript child): also set `graph.script_node = true` and `parent_type` (and, as the editor does, `body_type`; with only `parent_type` set the body is typed from it) to the node it acts for, e.g. `{"class": &"AnimatableBody3D", "script": "res://addons/brickscript/runtime/character_3d.gd"}` for a Character3D. Self is then the script node and Self.Parent (`..`) that node; `Ops.add_node` gives Node inputs and settings the editor's defaults for it.
- **Bricks with rows** (Make list, Make table, Unpack table, Call Function, Call method, Emit signal, Fire Server, Invoke Server, Fire Clients): the number of rows is `settings.count`. The editor sets it (+ / −, or picking a function); in code set it yourself, e.g. `.setting(&"count", 1)` on a Call Function of a one-value function, or the compiler says how many values the function takes.

### Editing API (`core/flow_ops.gd`, all static, pure data, testable headless)

- **Nodes and wires:** `add_node`, `exits_for` (an event's outputs plus the spare), `connect_exit` (refuses wires into events, self-wires and loops; why: `last_error`), `disconnect_exit`, `delete_node`, `swap_outputs`, `leads_to`.
- **Inputs:** `input_of`, `input_spec`, `input_shown`, `literal_types`, `set_input`, `set_input_type`, `set_setting`, `set_output`.
- **Variables:** `known_names`, `unique_name`, `rename_made_variable` (a Variable's own variable, and every use of it: inputs, outputs, Variable (Set), loop names, formulas), `references`, `upstream_names` (what a brick can read, walking back along the wires), `variables_to_bricks` (older graphs' listed variables into Variable (Set) bricks). For older graphs' listed variables: `add_variable`, `rename_variable`, `delete_variable`, `set_variable_type`, `set_variable_value`.
- **Grid:** `GRID` (16), `snap`, `snap_up`, `set_position`, `set_size`.
- **Frames:** `add_frame`, `frame_by_id`, `attach_to_frame`, `release_frame`, `delete_frame`, `set_frame`.
- **Snapshots / clipboard:** `snapshot`, `restore`, `copy_nodes`, `paste_nodes`, `clipboard_text`, `clipboard_data`.

### Compiler (`core/flow_compiler.gd`)

`compile(graph) -> String` returns the source, or `""` if there are `errors`.

- **Errors** (no script): each starts with its location, e.g. `If (node 4) > a: ...`.
- **Warnings** (script still written): unknown Input Map actions, results not kept, bricks not connected to an event.

---

## 5. Rules for contributors (people or AI)

- **Code style:** strictly typed GDScript 2.0. Every editor object is created in `_enter_tree` and freed in `_exit_tree` (no editor leaks).
- **Brickscript and the Network Context Engine stay decoupled.**
  - Detect it only through `ProjectSettings.has_setting("autoload/NetworkEngine")`.
  - Call `/root/NetworkEngine` methods by name.
  - Check `get_api_version()` (currently `5`: 1 + server parts (2) + server scripts carried by the node (3) + players of nodes, `get_player_of` (4) + characters, `set_player_character` / `get_player_character` (5)).
  - Never reference its scripts or `class_name`s. The only shared conventions are file names (`<name>.bricklocal` / `<name>.local.gd` and `<name>.brickserver` / `<name>.server.gd`) and the node metadata `server_script` (a node's own server script).
- **Adding a brick:**
  1. Add it to `NODES` in `core/flow_library.gd` (with a `description`; a test checks every brick has one).
     Optional keys: `contexts` (`[&"local"]` / `[&"server"]`, where the palette offers it), `network` (only with the Network Context Engine), `helper` (GDScript added once to scripts that use it), `shown_when` on an input (used only while a setting has a value); for events `annotation` (e.g. `@rpc(...)`) and `prelude` (first lines of the function).
  2. If its code isn't a simple template, compile it in `core/flow_compiler.gd`.
  3. Add tests to `tests/brickscript_flow_tests.gd`.
  4. Document it here (a test checks that every brick appears). If it's another way of doing what an existing brick does, make it a member of that brick's family (`FAMILIES`, same category and kind) instead of a new palette entry, and add it to the Brick families table.
  5. Use it in a test case (`tests/cases/<name>/`, see `DEBUG.md`): the case runner fails if a brick is used by no case or game brickscript. If it fits, use it in the sandbox (`game/sandbox/`) too,.
- **Run before handing back** (from the project root):
  - `godot --headless --path . -s res://tests/brickscript_flow_tests.gd`
  - `godot --headless --path . -s res://tests/brickscript_flow_editor_tests.gd`
  - `godot --headless --path . -s res://tests/run_cases.gd` (the test cases; report in `tests/reports/latest.md`)
  - `godot --headless --path . -s res://tests/brickscript_sandbox_test.gd` (plays the sandbox single-player; its brickscripts must compile without problems)
  - `tests/run_brickscript_network_test.sh` and `tests/run_brickscript_sandbox_test.sh` (the network bricks and the sandbox over a real host and client; need the Network Context Engine; any ERROR line fails them)
  - The exit code is the number of failed checks.
