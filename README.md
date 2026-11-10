# C-Bricks

A Godot 4.7 app, in GDScript, for writing C programs with bricks and wires. **[API.md](API.md)** is the full reference: every brick (what it does, its inputs, settings and outputs, when to use it) and how the editor works. Its editor follows the **Brickscript** editor's design and behavior (the `brickscript` addon in the user's plugin-test project). Each project becomes readable, portable C99 that builds for any platform, and the program runs in a built-in console.

## Projects

A project is a folder, like a Godot project:

```
MyGame/
  project.cbproj        name, version, run arguments, target
  main.cbricks           a script; the one with "When program starts" is main()
  scripts/util.cbricks   more scripts: each becomes its own .c file, and they call each other's functions
  assets/model.obj      everything else is an asset: the program reads it by its path from the project folder
  .build/               output (generated C in src/, binaries per target)
```

- The **Project Manager** start page lists your recent projects and the examples. The start page has two lists: **Recent Projects** (they carry on where you left them) and **Example Projects**. Clicking an example always opens a **new copy** of it (kept in the app's own data, numbered) and lists that copy in Recent Projects (marked *example copy*), where it carries on where you left it. **Save** on an example copy asks for a name and a folder (Documents/Projects/C-Bricks by default), keeps it there as your own project and puts that in Recent Projects instead (the copy goes). A copy that drops off Recent Projects is deleted. The built-in examples never change. **New Project…** makes a folder with `project.cbproj` and `assets/`: no script (user, 2026-11-07). Add nodes to the Main scene and Run: without a **When program starts** brick the build's own `main()` runs the Main scene (its Script objects start; with 3D / 2D things in it, a window and the Game loop). Add a script with When program starts when you want `main()` yourself.
- The **project dock** is the folder as it is on disk. Double-click a script to open it in a tab; double-click any other file to open it in its own app. Right-click for New Script, New Folder, Rename, Duplicate, Delete (to the trash), Show in File Manager and Copy Path. Files dropped on the window are copied into the selected folder.

## How programs work (Brickscript's rules)

- **Event bricks start chains.** *When program starts* becomes `main()`, *Define Function* a C function (callable from every script), and *When program ends* an `atexit` handler.
- **Execution wires (white ▶ ports) are the only wires.** Values travel through **variables**.
- **Outputs grow.** Every exit has a spare (`+ output`, `+ next`, `+ loop body`, `+ true`…). The chains on one exit run in order, each to its end before the next starts. Dropping a wire on a wired exit puts the new chain first, and Properties' ↑ / ↓ reorder chains.
- **Inputs:** each input is either a **Variable** (picked from those usable at that brick) or a typed value (int, float, bool, string). Number and bool values also take C expressions, e.g. `i % 15 == 0`.
- **Outputs:** an **Into** dropdown offers *(don't keep it)*, an existing variable, or **New variable…** with a name box and a **Kind**: **Chain** (default: only later bricks of its event or function) or **Shared** (every event and function of the script). Renaming the variable renames every use.
- **Classes and sides:** a script with a **Class** brick is a class (one per script, Godot's way). With nothing selected, Properties shows the script's **Side**: Shared (default), Server or Client. A script may use Shared things and its own side's, like Brickscript's LocalScript / ServerScript; until networking comes, one program runs every side.
- **Brick families:** one brick, with a Mode / Operation setting that changes what it does. *Variable* is Get / Set / Add; *Math* is Add … Remainder; *Logic* is And / Or / Not; *Read input* is int / float / line; *Write file* is Write / Append; *Program Arguments* is Count / At index / Option / Flag. *If*, *While* and *Assert* have a Compare setting. Inputs a setting doesn't use are hidden.
- **Problems** name their brick, e.g. `Print (node 3) > value: no variable named 'scroe' here: did you mean 'score'?`. Click one to jump to the brick, even in another script. Every generated line ends in `// brick <id>`, so a **C compiler error lands on its brick** too, outlined in red.

## Values, types and bricks

- **Types:** `int`, `float`, `bool` and `string`, plus **records** (structs you define with *Define Record*: named fields of any type, lists too), **lists** of one type each (`int list`, `string list`, `Point list`…), **maps** from text keys to one type each (`int map`, `Point map`…), **`vector3`** (a 3D point or direction: three floats, typed in as `x, y, z`, each part may be an expression, e.g. `0, sin(t) * 2, -1`), **`vector2`** (`x, y`), and, in graphics projects, `texture`, `sound` and `mesh`. Text, lists and maps are kept in memory until the program ends; everything is freed then. Lists and maps are shared when copied (both variables see the same one); records are copied.
- **Bricks** (the palette's groups):
  - **Events:** When program starts / ends, Define Function.
  - **Objects:** **Class** (makes the script a class: Name, Extends, Fields, Synced), **When created**, **New object**, **Destroy object**, **Call method**, **Node** (Exists, Is a, As, Class name, Id, Name, Set name, Parent, Set parent, Children). A class's Define Functions are its methods; a subclass's method of the same name replaces its parent's; objects are references; Destroy frees one at once (using it afterwards stops the program naming the brick). Record field reads and sets objects' fields too.
  - **The world** (graphics; small built-in classes, Godot's way: a game's own classes extend them): **Node** (the root class), **Spatial3D** (position, rotation, scale) -> **Shape3D**, **Mesh3D**, **Camera3D**, **Light3D**; **Spatial2D** -> **Shape2D**, **Sprite2D**, **Text2D**, **Camera2D**; **Environment** (sky, ambient, fog). **UI** (green, on top of the 3D and 2D, in window pixels, never moved by a camera or sent over the network): **Control** (anchor, offset, size), **Label**, **Panel**, **Bar**, **Image**, **Button**, **VBox** / **HBox** (containers to extend) (palette group **UI**: When clicked, When button clicked; Input's Mouse over UI?). A Light3D has a color and energy; a Sprite2D can show one frame of a sprite sheet (columns, rows, frame). Object events **Every frame** (`dt`), **When touched** (`other`, Shape3Ds), **When drawn**. The Game loop runs the world by itself (events, touches, drawing from its Camera3D, Light3D and Environment, the 2D on top); New object puts objects in it. A Spatial3D's position / rotation / scale are relative to its parent Spatial3D. Old projects (Part, Model, Camera, Light, Label, Object) are upgraded when opened.
  - **First-person bricks** (after Brickscript's): **Mouse mode** (Captured for mouse look; example **Arena**: a networked shooter, each player's Fighter with a Client Input script and a Server Brain script), Mouse position's **Movement**, **Key Direction** (a vector2), **Raycast** (Hit / Nothing hit, point, normal, distance), **Can see**, **Nearest object**, **Move and collide** (Shape3Ds with `solid` on stop it), **Shake Camera**. Example: *Arena*.
  - **Snapshot** (a Camera3D's view now: to a PNG, or into a texture; transparent; one subject or everything). In the editor, a Camera3D's Properties take snapshots too (Take snapshot), and the Scene tree shows thumbnails of Shape3Ds and Models.
  - **Scenes** (`.cbscene`, Godot's packed scenes): objects plus copies of other scenes (prefabs), edited in the **Scene** dock with a tab per open scene (Add, Delete, Name, Parent, Fields, Groups, Metadata in Properties; Add > Scenes for a copy; right-click **Save branch as scene**). A copy can change its root's fields, groups and metadata. The **Main scene** (`main.cbscene`) is what the world starts with, made before When program starts runs; bricks find its objects with **Node (Find)**, and the **Scene** brick spawns copies (**Instance scene**) or swaps the world for another scene (**Change scene**). Old projects' `world.cnworld` is upgraded to `main.cbscene` when opened. Scenes start empty and **the first node added is the root** (Godot's; one per scene); the Main scene's root is the world while the program runs; every node's Class can change; **New scene** in the dock. **When frame starts / When frame ends** (dt) run every frame around the world, in any plain script. Renaming a Script object renames its file (`Script Test` -> `script-test.cbricks`); new scripts and scenes get safe names. The 2D / 3D screens show the scene's **Environment** (its sky and ambient light) as the game will, a neutral grey without one. Example: *Gem Hunt*.
  - **Groups and metadata:** **Group** (Add to / Remove from / Is in / Objects in group) and **Metadata** (Set / Get / Has / Remove a text value by key) on any object; starting ones set in the Scene tree (Properties' Metadata fold, the Groups tab).
  - **Script objects** (Roblox's Script / LocalScript / ModuleScript): a script file placed in the Scene tree under an object; its When program starts runs once for that object (`parent`), before main's; its type is the file's Side (Server / Client / Shared), switched by a dropdown.
  - **Network** (Brickscript's / Roblox's model: one machine runs the game, players join it): **Network** (Host, Join, Leave, Network role, Is server), **Player Joined** / **Player Left** (`player`: a number), **Player** (Me, Player name, Is me, In game, Players: **players are numbers**, the host / you offline are 1), **Define Remote**, **Fire Server**, **Fire Clients**, **On Client Fired**, **On Server Fired**, **Invoke Server** / **On Client Invoked** / **Answer** (a question to the server that waits for a typed answer: a remote whose Direction is Ask server), **Ownership** (Give To, Owner, Mine?, Owned by). A script's Side says where it runs. Flags `--host PORT`, `--server PORT` (a dedicated server, no window), `--join ADDRESS:PORT`, `--name NAME`. The server's world is copied to every player 30 times a second (Synced fields gliding; late joiners get it all; the group `local` stays on its machine; clients' copies run no events). **The do-it-yourself starter player:** a Server script's Player Joined instances a player's scene and Gives it To them; a Client Script object inside it runs on that player's machine. Example: **Net Gems**.
  - **User Input:** Input (key / mouse down, pressed, released), Mouse position (position, movement, wheel), Mouse mode, Key Direction, and players' keys where the rules run: Player Key (Pressed / Released), Player Input (Holds? / Direction).
  - **Flow:** If / While (with Compare), For range, Repeat, **For each item**, **Switch** (an exit per case, plus Default), Break, Continue, Reroute, **Wait** (seconds; in a graphics program the window and the world keep running).
  - **Variables:** Variable (Get / Set / Add: Add joins text and appends to lists), Convert, **Constant**.
  - **Math and logic:** Math, **Formula** (any C expression), Math Function, Min / Max, Random, **Vector** (Make, Split, Add, Subtract, Scale, Length, Normalize, Distance, Lerp, Dot, Cross); Compare, Logic. Variable (Add) adds vectors too.
  - **Text:** Join, Format (`"{} has {} points"`), Length, Substring, Find, Replace, Upper / Lower case, Trim, Split, Join list, To text / int / float, Starts / Ends with.
  - **Lists, Maps & Records:** List (Make, Add, Insert, Get, Set, Remove, Length, Find, Contains, Clear, Sort, Reverse), **Map** (Make, Set, Get, Get or (a default for a missing key), Has, Remove, Count, Keys, Values, Clear; keys keep the order they were added in), Define Record, Make record, Record field (Get / Set). A wrong list index or a missing map key (with Get) stops the program with an error naming the brick. To loop over a map, loop over its Keys with For each item.
  - **Input / Output:** Print (lists, maps and records print as `[1, 2]` / `{"a": 1}` / `Point(x: 1, y: 2)`), Read input, Get Time.
  - **Program:** Program Arguments, Exit program, Read / Write file, File exists.
  - **System:** Sleep, Environment variable, Run command, Terminal (clear, colors, cursor).
  - **Graphics** and **3D (raylib):** see below.
  - **Debug / Testing:** Assert, Debug log.
  - **Advanced:** C Code, #include, **Call C function** (the C library's, or your own: every `.c` / `.h` in the project folder is compiled in).

## The debugger

- **Breakpoints:** press **F9** on a brick (or right-click it → Add breakpoint, or use the button in Properties). A red ● marks it.
- **Run** (F5): the program pauses at a breakpoint. The brick gets a yellow outline, the **Debug** tab lists every variable (and the file's globals) with its type and value, and Properties shows `now: x = …` beside the selected brick's variables.
- **Controls:** **Continue** (F8 or F5); **Step over** (F10): the next brick of this function, the functions it calls run through; **Step into** (F11): the very next brick, inside a called function too; **Step out** (Shift+F11): run until this function returns, pause in its caller; **Stop**. While it runs, **Pause** (F8) stops at the next brick. The Debug tab says how many calls deep the pause is.
- **Watches:** type an expression into the Debug tab's *Add a watch* box (or double-click a variable): it's worked out at every pause from the variables there, e.g. `score * 2`, `pos.x`, `gems[0].y`, `table["ada"]`, `nums.size()`, `lines > 10 && who == "Ada"`. C operators, fields, list items and map keys work, plus `len()`, `sqrt()`, `abs()`, `min()` / `max()`, `fmax()` / `fmin()`. A name that isn't there gets a guess (`did you mean 'score'?`). Watches are saved in the project (`project.cbproj`); the bin button removes one. Nothing is rebuilt: the editor reads the paused program's values back by their types.
- **How it works:** it uses the same channel as Trace. The program runs with `--debug <file>` and reads the editor's commands from that file, so stdin stays free for the program's own input. You can also debug from a terminal: `--debug cmds.txt --break main.cbricks:7`, then append `step` (into), `next` (over), `out`, `continue` or `stop` to `cmds.txt`. Commands can be written beforehand too: each pause takes the next resume command (`step` / `next` / `out` / `continue`) and leaves the rest for the next pause, so a whole session can be replayed.

## Graphics (raylib)

Graphics bricks make windowed programs and games with [raylib](https://www.raylib.com) (bundled in `thirdparty/raylib`, zlib license): **Open window**, **Game loop** (its *Frame* chains run once per frame), **Close window** (ends the Game loop after this frame), **Pause game** (Pause / Resume / Paused?; offline it freezes the world, a script can Run while paused; Set time scale / Time scale: offline, and in a network game the world's speed for everyone), **Clear window**, **Draw** (rectangle, outline, circle, line, text, texture, a sprite sheet's frame; rectangles, text, textures and sprites turned by a Rotation), **Draw 2D view** (a 2D camera: center, zoom, rotation), **Input** (keys / mouse buttons: down, pressed, released), **Mouse position**, **Game info** (frame time, time, window size, FPS), **Load texture**, **Sound** (load / play), **Music** (streamed: load, play, stop, pause, resume, volume, playing?). Colors are names (`RAYWHITE`, `MAROON`, `SKYBLUE`…) or `#rrggbb` (`#rrggbbaa` with see-through). The example *Bouncing Ball* shows the pattern.

### 3D

- **Set camera:** where the camera is and what it looks at (vector3s), its field of view, Perspective or Orthographic. Set it every frame to follow something.
- **Draw 3D:** its *Draw* chains draw in 3D, seen from the camera; *Next* runs after, back in 2D (a score on top).
- **Draw shape:** Box, Wire box, Sphere, Cylinder, Plane (middle *At*, *Size* across, *Turn* degrees round the up axis), Mesh, a 3D Line, a Grid. Shapes and meshes are lit by a sun from above.
- **Meshes** (Brickscript's mesh bricks): **Begin mesh** (into a `mesh` variable) → **Add to mesh** (Triangle A B C, its front the side its corners go round clockwise; Quad A B C D; or a ready Shape: Box / Sphere / Cylinder / Plane) → **Finish mesh** (Shading Flat / Smooth, Sides both / one; after Open window). **Mesh vertices** gets a finished mesh's points as a `vector3 list` and puts a changed list back (bend a grid into hills, wave a flag).
- The example ***Gem Collector*** is a small 3D game made of these: rolling hills (a grid of quads lifted by a `height(x, z)` function through Mesh vertices), walls, a hero built from shapes, faceted gems built from 8 triangles. WASD to move; collect gems before the 60 s run out; R to play again.

raylib is compiled for a target the first time you build for it (a minute or two), then cached. Windowed programs build for:
- **This computer.** On Linux this needs the X11 / OpenGL dev packages: `sudo apt install libx11-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev libgl-dev`. Linux builds use X11 and OpenGL 2.1, which every Linux GPU has (a Raspberry Pi's included). If the window can't open, Open window says so and the program exits with code 1.
- **Windows** (x86_64, x86, ARM64), from anywhere, with zig.
- **macOS**, on a Mac.
- **The Web**, with Emscripten.

Other targets stay text-only. An exported graphics project carries raylib's source, and its Makefile, CMake and scripts build it. raylib sits behind a small backend layer (`cb_be_raylib.c`): the bricks and the runtime never call it directly, so another backend can take its place: MS-DOS has its own (`cb_be_dos.c`: software drawing into a VGA / VESA screen).

## Debugging and testing a program

Every program built with C-Bricks understands these flags (`--help` lists them):

| Flag | What it does |
| --- | --- |
| `-h`, `--help` / `--version` | usage / name and version |
| `--trace` | prints each brick as it runs (`[trace] main.cbricks:4`, stderr) |
| `-v`, `--verbose` | shows the *Debug log* bricks' output |
| `--seed N` | Random Int gives the same numbers every run |
| `--input FILE` / `--output FILE` | stdin from a file / stdout to a file |
| `--cd DIR` | changes to DIR first (where its assets are) |
| `--max-steps N` | stops with exit code 124 after N bricks (catches endless loops) |
| `--time` | CPU / wall time and bricks run, at exit |
| `--debug FILE` / `--break S:B` | the debugger: pause at breakpoints (`main.cbricks:7`), read commands from FILE |
| `--` | passes the rest to the program as it is |

Everything else reaches the **Program Arguments** brick (`--name=Ada`, `--name Ada`, positional arguments, flags). *Assert* stops the program with exit code 1 and names its brick, and *Exit program* exits with a code. In the editor, **Run** starts the program from the project folder with the project's **run arguments** (Project ▸ Project Settings). **Trace** lights bricks up as they run.

## The editor

| Area | What it does |
| --- | --- |
| Toolbar | Project menu (New / Open / New Script / Settings / Close), Save, Undo, Redo, Close tab, Frame, Arrange, the target, status, Build, Run, Trace, Build All, Stop, Export, Toolchains |
| Left | on 2D / 3D: **Scene** (the world file's objects as a tree: Add, Delete) on top, **FileSystem** (the project's folder) below; on Bricks: the brick palette (search, category buttons; drag an entry in or double-click it) |
| Middle | **2D · 3D · Node** (Godot's main screens). **Node**: the script tabs, then the canvas (right-click to add a brick; right-drag pans; double-click a wire for a reroute point; Ctrl+C / X / V / D; comment frames; **Arrange**). **3D**: the world drawn live, orbit / pan / zoom, click to select, drag the X / Y / Z arrows to move. **2D**: the game window with its Text2Ds, drag to move |
| Right | Properties: the selected brick's Inputs and Outputs, what runs next, Delete; a frame's title and color; a Scene object's Name / Parent, then **Properties** (a fold per class, its own open; Metadata) and **Groups** tabs; a Script object's Type and File |
| Bottom of the middle (between the left column and Properties) | Problems (every script) · Console (the running program, with stdin) · Generated C (each file) · Debug (watches and variables when paused; Continue / Step over / Step into / Step out / Stop) |

Shortcuts: Ctrl+S (Shift: all), Ctrl+W, Ctrl+O, Ctrl+N (new script), Ctrl+F (find a brick in any script), Ctrl+Z / Shift+Z / Y, Ctrl+E (export), F5 (run / continue), F6 (build), F8 (continue / pause), F9 (breakpoint), F10 / F11 / Shift+F11 (step over / into / out).

Every brick can carry a **note** (Properties): it shows on the brick and becomes a comment in the C. **Find** (Ctrl+F) searches every script's bricks. A Call Function brick's menu has **Go to function**. Renaming a function also renames its calls in the other scripts.

## Building for other platforms

**zig** (installed in `~/.local/bin/zig`) cross-compiles to almost everything, from any machine. The Target dropdown and Build All cover:
- Linux: x86_64, x86, ARM64, ARMv7, RISC-V 64, POWER, IBM Z, LoongArch and MIPS
- Windows: x86_64, x86 and ARM64
- macOS: arm64 and x86_64
- FreeBSD: x86_64 and ARM64
- NetBSD: x86_64
- an Android ARM64 command-line program, and WASI

**Toolchains:** the exported editor is one file: it carries zig, DJGPP and DOSBox-X inside itself and unpacks them (600 MB, with a progress window) into its user folder the first time you build; a `toolchains/` folder beside it is used instead if there is one; the bundled tools are used first (`thirdparty/TOOLCHAINS.md`: licences and source); DOSBox-X brings its own libraries. Emscripten (the Web target) isn't bundled.

**MS-DOS** (text programs, 2D graphics, the UI, sound, music and 3D by a software renderer; pick the backend in Project Settings ▸ Graphics) uses DJGPP (`~/.local/opt/djgpp`, built from source once). Run opens the program in DOSBox-X; the `.exe` carries CWSDPMI, so it also runs on plain DOS. A brick the chosen target can't do (a window on MS-DOS, say) shows up in Problems by name. **Networking** works there too (UDP through Watt-32 and a packet driver, `thirdparty/watt32` / `thirdparty/pktdrvr`; Run in DOSBox-X wires up an emulated NE2000: the host is 10.0.2.2).

Web (HTML + WASM) uses Emscripten's `emcc`, installed here in `~/.local/opt/emsdk`. Run serves the page with `emrun` and opens it in your browser. Compilers are found on PATH and in the usual install folders (`~/.local/bin`, Homebrew, MSYS2…), and the Toolchains dialog can override any target's command.

**Export ▸ C project** writes a standalone project that builds anywhere:

- `src/` holds one `.c` per script, `cbricks.h` and `cbricks_runtime.c`. It's plain hosted C99 using only the standard library, with an MSVC guard, so any C99 compiler builds it: `cc -std=c99 src/*.c -lm`.
- The assets are copied as they are.
- `Makefile`: `make` builds for this computer, `make TARGET=<zig target>` cross-compiles, `make all-targets` builds for every zig platform, and `make web` uses Emscripten.
- `CMakeLists.txt` works with Visual Studio, Xcode, Ninja and Make, Android NDK and iOS toolchain files, and `emcmake`.
- `build.sh` / `build.bat` do the same without make: `./build.sh`, `./build.sh all`, `./build.sh <zig target>`.
- `README.md` lists the command for every platform.

## Exporting the editor

`./export.sh` exports the editor for this machine (Linux ARM64) into `build/linux-arm64/`. Only the app and the examples are exported.

## Tests

`godot --headless --path . -s res://tests/run_tests.gd` runs the **suites** (`tests/suites/`: one project per palette group, every brick and mode, labelled output lines; a `coverage` check makes sure nothing is left out) and the **scenario cases** in `tests/cases/` (error exits, flags, examples, games, bug guards). Each builds a project, runs it with fixed arguments, seed and stdin, and checks its output and exit code; network cases (`peers` in case.cfg) run the program several times at once, a server and its clients on this machine, and check each one's output. The report goes to `tests/reports/latest.md`. `godot --path . -s res://tests/ui_check.gd` drives the real window and saves screenshots there. `DEBUG.md` has the process.

## Code layout

```
scripts/node_defs.gd            the bricks: inputs, outputs, settings, exits, families
scripts/ops.gd                  graph edits as pure data (wiring, growing exits, frames, arrange, file upgrades)
scripts/codegen.gd              one script -> one .c file, problems, variable scopes
scripts/project.gd              CBProject: the project folder, scripts and assets
scripts/project_build.gd        ProjectBuild: the whole project -> .c files + cbricks.h + the runtime + records (cbricks_data.c)
scripts/types.gd                CBTypes: type names (basic, records, lists, maps, graphics handles) -> C
scripts/runtime/*.c             the C runtime appended to every program: flags + debugger (cb_runtime.c),
                                memory / lists / maps / text / system (cb_data.c), objects (cb_object.c),
                                graphics (cb_gfx.c; the raylib backend: cb_be_raylib.c), networking (cb_net.c; the UDP socket: cb_socket.c)
thirdparty/raylib/              raylib 5.5's source (zlib license), compiled for graphics projects
thirdparty/dmxopl/              DMXOPL's GENMIDI.op2 (MIT; credit: sneakernets): the FM instrument bank for MIDI music on MS-DOS
thirdparty/watt32/              Watt-32 (BSD sockets for DJGPP: MS-DOS networking), built here; its licence and how
thirdparty/pktdrvr/             Crynwr's NE2000 packet driver (GPL) that DOS networking needs
thirdparty/cwsdpmi/             CWSDPMI's loader stub (the DOS programs' DPMI host; source: see its README)
scripts/toolchains.gd           targets, compiler lookup, builds, the exported C project
scripts/editor/editor_panel.gd  the window: toolbar, project manager, tabs, undo, build / run / trace
scripts/editor/project_dock.gd  the project folder as a tree
scripts/editor/canvas.gd        the wire canvas (GraphEdit)
scripts/editor/brick_view.gd    one brick
scripts/editor/palette.gd       the brick palette
scripts/editor/inspector.gd     Properties
scripts/editor/brick_theme.gd   colors, the app theme, icons
examples/<project>/             example projects
tests/                          run_tests.gd, suites/ (make_suites.py), cases/ (net_*: make_net_cases.py), ui_check.gd
```

The working notes for Claude sessions are `CLAUDE.md`, `PROGRESS.md`, `DECISIONS.md`, `BUGS.md` and `DEBUG.md`. The startup shell is `./SetupClaude.sh` (`--check` only checks).
