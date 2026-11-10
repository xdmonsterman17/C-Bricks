# C-Bricks API

The reference for **every brick C-Bricks has**: what it does, its inputs, settings, outputs and exits, the C it becomes, when to use it, and what goes wrong. It also explains **how the editor works**. It is written so it can be handed to another person or AI assistant working on, or with, C-Bricks. (Its layout follows the Brickscript addon's `API.md`.)

- App: a Godot 4.7 project, all GDScript (`scripts/`). Programs it makes are plain C99 (`scripts/runtime/` is the C added to every program).
- Last updated 2026-11-07: 97 bricks in 18 palette groups (User Input: keys and the mouse; Network: roles, players as numbers, the world copied to players, remotes, players' keys, ownership, owned Client scripts; Objects: classes and the world; a first-person shooter's bricks).
- Source of truth for bricks: `scripts/node_defs.gd` (`NodeDefs.DEFS`). **The test runner fails if a brick there has no `#### \`type\`` entry in this file** (see section 9).

---

## 0. Getting started

1. **Open or make a project.** The app opens on the **Project Manager**: recent projects, the examples, **New Project…** and **Open Project…**. A project is a folder (section 2.1). Opening an example copies it into `~/Documents/Projects/C-Bricks/` first, so the copy is yours to change.
2. **Hello world.** A new project has no script: FileSystem ▸ New Script (`main.cbricks`), then add **When program starts** to it from the palette. In the **Bricks** tab (left), drag **Print** onto the canvas. Drag from When program starts' `▶ Output 1` to Print's `▶`. In Properties (right), type `Hello` into Print's Value. Press **Run** (F5): the **Console** (bottom) shows `Hello`.
3. **Values go through variables.** There are no data wires. A brick that makes a value puts it **Into** a variable (Properties ▸ Outputs ▸ *New variable…*, a name). Later bricks pick that variable for their inputs.
4. **Order:** a brick's exits run in order, each chain to its end before the next one starts (section 1).
5. **Problems** (bottom tab) list what stops the C from being made, each naming its brick: `Print (node 3) > value: no variable named 'scroe' here: did you mean 'score'?`. Click one to jump to the brick.
6. **Look at the C:** the **Generated C** tab shows each file. The graph is the source; the C is read-only.
7. **A game:** open the *Bouncing Ball* (2D) or *Gem Collector* (3D) example. Open window → Game loop → its Frame chains draw each frame.

---

## 1. How programs work

A **script** (`.cbricks` file) is a graph of **bricks**. Every script becomes one `.c` file; the project becomes one program.

- **Event bricks start chains.** *When program starts* is `main()`; *Define Function* is a C function that any script can call; *When program ends* is an `atexit` handler. A brick that no event reaches never runs (Properties says so: *Not wired to an event yet*).
- **Execution wires** (white `▶` ports) are the only wires. They say what runs next.
- **Every exit grows.** Each exit has a spare (`+ output`, `+ next`, `+ loop body`, `+ true`, `+ false`, `+ draw`…). Wiring the spare makes it `Next 1`, `Next 2`, … and a new spare appears. **The chains on one exit run in order, each to its end, before the next starts.** If's True / False grow too. Dropping a wire on an already wired exit puts the new chain first; Properties ▸ Outputs' ↑ / ↓ reorder chains.
- **Inputs:** each input is either a **Variable** (one usable at that brick, of a fitting type: Brickscript's way, the variables made by what runs **before it in its chain** (walking back along the wires: the bricks wired into it, earlier chains on the same exit, the branches a Next follows), plus what's always there: Globals, Constants, a class's fields, the function's inputs and Self; a variable read before its chain makes it gets a warning naming the brick, as it still holds its starting value there) or a **typed value** (int, float, bool, string, vector3). Number and bool values may be C expressions: `i % 15 == 0`, `SPEED * dt`, `sin(t) * 2`. Strings are quoted for you; `\n` and `\t` work.
- **Outputs:** a value a brick makes goes **Into** a variable: *(don't keep it)*, an existing variable it may write, or **New variable…**, a name and a **Kind** (Chain or Shared). A new variable's type comes from the value. Renaming it (Properties ▸ Name) renames every use.
- **Variables** belong to their **chain** (Brickscript's chain variables): a new one can be used by the bricks after it in its event or function, and is fresh every time that runs. To share one, make it **Shared** where it's made (Variable (Set) or an output's **Kind**): every event and function of the script can use it, and it keeps its value (a `static` in C). A function reading another chain's variable is a problem naming the brick, saying to make it Shared. Shared variables are per script.
- **Brick families:** one brick with a Mode / Do / Operation setting that changes what it does (Variable is Get / Set / Add; List is Make, Add, Insert, …). Inputs that the chosen mode doesn't use are hidden. The brick's title follows its mode (`Variable (Set)`, `Add to list`).
- **No loops through wires.** A wire may not lead back to a brick before it. Repeat with loop bricks (While, For range, Repeat N times, For each item).
- **Memory:** text, lists, maps and meshes are kept until the program ends, then freed in one go. Objects are the exception: **Destroy object** frees one at once.
- **Classes:** a script with a **Class** brick is a class (Godot's way: the script is the class). Its Define Functions are its methods, its Fields belong to each object, and it can extend another class. See 4.6.
- **Sides:** every script runs on a **Side**: Shared (the default), Server or Client (2.4). Until networking comes, one program runs every side.
- **Tracing:** every brick calls `CB_TRACE(file, brick)` first (that's how `--trace`, `--max-steps` and the debugger work). `-DCN_NO_TRACE` compiles it out.
- **Every generated line ends in `// brick <id>`**, so a C compiler error is shown on the brick that made the line.

---

## 2. The editor

The window follows the Brickscript editor's layout:

| Area | What's there |
| --- | --- |
| **Toolbar, row 1** | Project menu · Save · Undo · Redo (the scene's on 2D / 3D, the script's on Bricks) · the project's name · **Target** · status |
| **The Bricks bar** (only on the Bricks screen, under 2D · 3D · Node) | the script tabs · Close (tab) · Find · Frame (a comment frame) · Arrange |
| **Toolbar, row 2** | Build · Run · Trace · Build All · Stop · Export · Toolchains (⚙) |
| **Left** | on 2D / 3D, Godot's docks: **Scene** (the world's tree, 2.10) on top, **FileSystem** (the project's folder) below; on **Node**, the brick palette in their place |
| **Middle** | the main screens' switcher, **2D · 3D · Node** (Godot's); under it, only on Bricks, the script tabs; then the screen: **Node** = the **canvas**, **3D** = the world in 3D (2.11), **2D** = the game window and its Text2Ds (2.11). The screen you pick is remembered. |
| **Right** | **Properties**: the selected brick's Inputs and Outputs, or a palette entry's description |
| **Bottom of the middle** | **Problems** · **Console** · **Generated C** · **Debug**, between the left column and Properties (Godot's bottom panel) |

Every divider can be dragged, and every panel shrinks a long way (text clips with … and a tooltip). Panel sizes are remembered in `user://settings.cfg`.

### 2.1 Projects and files

- **Examples** (2026-11-08): The start page has two lists: **Recent Projects** (they carry on where you left them) and **Example Projects**. Clicking an example always opens a **new copy** of it (kept in the app's own data, numbered) and lists that copy in Recent Projects (marked *example copy*), where it carries on where you left it. **Save** on an example copy asks for a name and a folder (Documents/Projects/C-Bricks by default), keeps it there as your own project and puts that in Recent Projects instead (the copy goes). A copy that drops off Recent Projects is deleted. The built-in examples never change.

```
MyGame/
  project.cbproj        [project] name, version · [run] args, trace · [build] target
  main.cbricks           the script with "When program starts" (main()); none: the build's own main() runs the Main scene
  scripts/util.cbricks   more scripts: one .c each; they call each other's functions
  assets/...            anything else: the program reads it by its path from the project folder
  mylib.c / mylib.h     your own C, compiled in (call it with Call C function)
  .build/               output: src/ (generated C), <target>/ (programs)
```

- **Project menu:** New Project…, Open Project…, New Script… (Ctrl+N), Project Settings… (name, version, run arguments), Show Project Folder, Close Project (back to the Project Manager).
- **Project tab** (Godot's FileSystem dock, for the project folder): the folder as it is on disk, with icons per file type. Double-click a script to open it in a tab; double-click any other file to open it in its own app. Right-click for New Script, New Folder, Open, Rename…, Duplicate…, Delete (to the trash), Show in File Manager, Copy Path. **Files dropped on the window** are copied into the selected folder. Renaming or deleting a file updates its open tab.
- **Script tabs:** each open script has its own tab and its **own undo history**. A `*` marks unsaved changes; Ctrl+S saves the tab, Ctrl+Shift+S all of them. Ctrl+W closes the tab.
- **Duplicate** of a script renames its functions (`_copy`), since one name per function is allowed in a project.

### 2.2 The palette (the Bricks screen's left column)

- A **search box** (every brick, by its title, type, group and mode names: `quad` finds Add to mesh) and **category buttons** (Events, Flow, Input / Output, Variables, Functions, Logic, Math, Text, Lists, Maps & Records, Program, System, Graphics, 3D, Debug / Testing, Advanced).
- **Click** an entry: Properties shows what it does, its inputs, settings, output and exits.
- **Drag** an entry onto the canvas, or **double-click** it to add it in the middle of the view.
- A brick that may be used once (When program starts / ends) is greyed out once the script has it.
- A brick that **can't go in this script** is greyed out (grey, not its group's color) and can't be added; its tooltip says why: the Target can't do it ("MS-DOS (DJGPP, 386+) can't do graphics yet"), or it doesn't belong in this kind of script (Every frame needs a class's script, Player Key isn't for a Client script, When button clicked isn't for a Server one...). Change the Target, the script's Side or its Class and it comes back.

### 2.3 The canvas

- **Add a brick:** right-click empty space (the add menu, by group), drag from the palette, or drag a wire from an exit and drop it on empty space (the new brick is wired to it).
- **Wire:** drag from an exit (`▶` on the right) to a brick's `▶` input (left). Drag a wired exit's end off to disconnect it.
- **Pan:** right-drag or middle-drag (a right-click without moving opens the menu). **Zoom:** the wheel, or the − / 1 / + buttons; the minimap (bottom right) shows where you are.
- **Select:** click; Shift / Ctrl-click or a box drag for several. **Delete** removes them.
- **Copy / Cut / Paste / Duplicate:** Ctrl+C / X / V / D. Pasted bricks keep their wiring among themselves.
- **Reroute:** double-click a wire to add a point that bends it (nothing runs there).
- **Comment frames:** the Bricks bar's **Frame**, or the add menu's *Comment frame*: around the selected bricks, or in the middle of the view. Bricks dropped on a frame join it and move with it; Properties sets its title and color.
- **Arrange** (the Bricks bar): lines the chains up left to right, two grid squares apart (Brickscript's spacing).
- **A brick's right-click menu:** Add / Remove breakpoint (F9), Go to function (on a Call Function), Duplicate, Delete.
- **What a brick shows:** a title bar in its category's color, `▶` ports, and a read-only summary (`score ← score + 1`, `ground at (0, 0, 0)`). A note shows under it in green. A problem outlines it red; a breakpoint marks it with ●; the brick the debugger paused at is outlined yellow; Trace flashes bricks as they run.

### 2.4 Properties

- **Inputs** (top): the brick's settings (Mode, Compare, Of…) then its inputs. Each input has one dropdown: **Variable** (then a second dropdown of the variables usable there that fit, with their type and kind, e.g. `score · int (Local)`), or a value type with a text box. A variable that's not usable there stays shown, marked, and is a problem.
- **Outputs** (below): each result's **Into** dropdown and its **Name** box; then **Runs next**, which lists every exit's chains with ↑ / ↓ to reorder them.
- **Note:** a line of text kept on the brick, shown on the canvas and written as a C comment.
- **Nothing selected:** the script's own settings: its **Side**. *Shared* (both sides: classes and functions everyone uses), *Server* (the game's rules: spawning, scores, damage) or *Client* (one player's input, camera, HUD, sounds). A script may use Shared things, and things of its own side; a Client script calling a Server script's function (or the other way) is a problem, as is a Shared script using either. The rule follows Brickscript's LocalScript / ServerScript; networking itself comes later, and until then one program runs every side.
- **Add / Remove breakpoint**, **Delete brick**.
- While the debugger is paused, inputs that are variables show their value: `now: lines = 16`.
- A palette entry selected instead of a brick: its description, inputs, settings, output and exits.

### 2.5 Building and running

- **Target** (toolbar): what Build makes, e.g. *This computer*, *Windows x86_64*, *Linux ARM64 / Raspberry Pi 64-bit*, *Web*. Section 7 lists them all.
- **Build** (F6): makes the C (`.build/src/`) and compiles it for the target (`.build/<target>/`). **Run** (F5): builds, then starts the program from the project folder with the project's run arguments. The **Console** shows its output, and its input line sends text to the program's stdin. **Stop** ends it.
- **Trace:** Run with `--trace`; the bricks flash as they run (the trace lines aren't printed).
- **Build All:** every target that has a compiler, one after another; the Console lists what was made and what was skipped (and why).
- **Toolchains (⚙):** a window with two tabs. **Toolchains** (first): zig, DJGPP, DOSBox-X, Emscripten and CMake, each with what it enables, licence, website, download size and its state: *Installed* (by this window, with the path; **Remove** deletes it), *Found on this computer* (PATH, the usual folders, a bundle; **Install here** adds the editor's own copy, which is looked in first), or *Not installed* (**Install**). A download shows a progress bar (bytes of bytes; Cancel while downloading, "Checking" / "Unpacking" after); the file is checked against the sha256 in `toolchains_manifest.json` and a mismatch installs nothing. Installs go to `user://toolchains/installed/<tool>`. A tool with no download for this kind of computer says so (DJGPP and DOSBox-X are published for Linux ARM64 only, from this project's GitHub release; zig, CMake and Emscripten come from their own sites). Emscripten is fetched by emsdk (needs Python, about 1 GB). Unpacking uses `tar`. **Commands** (second): which compiler each target uses (found on PATH and in the usual folders: `~/.local/bin`, Homebrew, MSYS2…); any target's command can be overridden (Save keeps these; installing and removing take effect at once).
- **Export ▸ C project (Ctrl+E):** a standalone folder (`src/`, the assets, Makefile, CMakeLists.txt, build.sh, build.bat, README.md; graphics projects also carry raylib) that builds anywhere. **Export ▸ Only the generated C files** writes just `src/`.
- **Generated C** tab: the C of each file (a file picker), read-only.

- **Built programs are kept** (2026-11-08): Build / Run compiles only when something changed. A program is kept with a fingerprint of everything that made it (the target, the compile command, every generated .c / .h, the raylib build it links), beside it in `.build/<target>/` (`<program>.key`) and in a shared cache (`user://build_cache`, the newest 60); an unchanged project, after closing and reopening it too, runs at once ("unchanged since its last build: reused" in the Console). **The examples are compiled with the app** (`tools/prebuild.gd`, run by `export.sh`, into the pack's `prebuilt/`): an example's first Run is instant. A miss builds raylib (once per target) and compiles as before.

- **Export** runs in the background with a **progress bar** (the file it's on, how many of how many: a graphics project copies raylib's ~170 sources too); the window stays usable.

### 2.6 Problems

- The **Problems** tab lists every problem of every script: `scripts/util.cbricks, C Code (node 4) > code: …`. Click one to open its script and show the brick.
- Problems from making the C name the brick and the input (`> value:`), with a guess for misspelled names (`did you mean 'score'?`).
- A brick **in the wrong place** (one the Target can't do, or one that doesn't belong in its script: see 2.2) is drawn grey with a red outline on the canvas; its tooltip and its problem say why.
- **Compiler errors** are mapped back to their brick through the `// brick <id>` markers and outlined red. Warnings on variable declarations have no brick (they belong to the function) and are listed by file and line.
- The status in the toolbar says *Ready · N script(s), N lines of C* or how many problems there are.

### 2.7 The debugger

- **Breakpoints:** F9 on the selected brick, or its right-click menu, or Properties. They're saved in the script.
- **Run** (F5) pauses at a breakpoint: the brick is outlined yellow and shown, and the **Debug** tab lists the variables of the function it's in (and the script's globals) with their types and values. It also says how many calls deep the pause is.
- **Continue** (F8 or F5) · **Step over** (F10): the next brick of this function; the functions it calls run through · **Step into** (F11): the very next brick, inside a called function too · **Step out** (Shift+F11): run until this function returns, then pause in its caller · **Stop**. While it runs, **Pause** (F8) stops at the next brick.
- **Watches:** type an expression into the Debug tab's *Add a watch* box (or double-click a variable): it's worked out at every pause from the variables there, e.g. `score * 2`, `pos.x`, `gems[0].y`, `table["ada"]`, `nums.size()`, `lines > 10 && who == "Ada"`. C operators, fields, list items and map keys work, plus `len()`, `sqrt()`, `abs()`, `min()` / `max()`, `fmax()` / `fmin()`. A name that isn't there gets a guess (`did you mean 'score'?`). Watches are saved in the project (`project.cbproj`); the bin button removes one. Nothing is rebuilt: the editor reads the paused program's values back by their types.
- How it works: the program runs with `--debug <file>`, and the editor appends commands to that file (`continue`, `step`, `next`, `out`, `pause`, `stop`, `break main.cbricks:7`, `clear main.cbricks:7`). stdin stays free for the program's own input. Pauses are reported on stderr (`[pause] main.cbricks:7`, `[depth] 1`, `[var] name<TAB>type<TAB>value`…, `[end]`). The same works from a terminal, with commands written beforehand or as you go (section 6).

### 2.8 Find, notes, functions

- **Find** (Ctrl+F): every brick of every script, by title, settings, values and notes. Pick one to jump to it.
- **Go to function:** a Call Function brick's right-click menu opens the script that defines it.
- **Renaming a function** (Define Function's Name) renames its Call Function bricks in every script.

### 2.10 The Scene tree

The left column's top dock, like Godot's Scene dock or Roblox's Explorer: the **scene** being edited as a tree (the Main scene: the objects the world starts with). **Scene tabs** over it: the open scenes (★ the Main scene); open another by double-clicking a `.cbscene` in FileSystem (right-click there: **New Scene...**, **Set as Main Scene**), or a copy's row, or Properties' **Open**. **Add** opens Godot's **Create New Node** window in the middle of the screen: a search box, a tree of everything that can be added with its icons (Node, then Spatial3D / Spatial2D / Control and the classes under what they extend, your own classes under their parents in green, Scripts, and **Scenes (a copy)**) and a description of the picked one (what it's for, what it extends, its fields); double-click, Enter or **Create** adds it under the selected object. A scene that would hold itself, or that has more than one object at the top, is greyed with the reason. A scene copy of another scene is added that way: it puts a copy of another scene under the selected object (scenes that would hold themselves, or that have more than one object at the top, are greyed with the reason); a copy's row shows the scene's objects greyed under it. Right-click an object: **Change type...** (the same window opens to pick another class, Godot's Change Type: fields the new class hasn't got are dropped; for a Script object, Script / LocalScript / ModuleScript), **Save branch as scene** (Godot's: it and what's under it move to `scenes/<name>.cbscene`, and a copy takes its place). Selecting a copy shows its Scene, its root's class, and its root's fields as overrides (blank: the scene's own value, in grey), groups and metadata. In the 3D / 2D screens copies are drawn whole; clicking any part of one picks the copy. **Delete** removes it and the objects under it. **Drag a row onto another** to put it under that one, or **between two rows** (just above or below one) to put it before or after that one under the same parent: the order siblings are made in, and the order a VBox / HBox stacks them (Godot's way; not onto itself or something under it, nor onto a Script object; its position, rotation and scale stay as they are, now relative to the new parent). Rows have their class's icon (Godot's colours: 3D red, 2D blue; Spatial3D / Spatial2D a circle, a sun for Light3D; your classes the icon of the built-in class they extend). **Undo / Redo** (Ctrl+Z / Ctrl+Shift+Z, or the toolbar's arrows) on the 2D / 3D screens undo the edited scene's changes (moves, adds, deletes, renames, fields, Change type, drags), each scene its own history; on the Bricks screen, the script's. Selecting one shows it in Properties: its **Name** (what Node (Find) looks for), then two tabs (Godot's Inspector and Node > Groups):

- **Properties:** its fields in one fold per class, Godot's way: the object's own class open (e.g. Gem), the classes it extends closed (Shape3D, Spatial3D, Node) until you open them (remembered). Numbers, bools, text, vectors; a blank field keeps the class's starting value, shown in grey. Then **Metadata** (a fold): text values by key (Add a key, edit its value, remove it), read by the Metadata brick.
- **Groups:** the groups it's in (Add a name, remove one; the groups other objects use are buttons to add it to them), read by the Group brick.

Every change is saved to the file at once and rebuilt; problems in it ("World: Floor (Shape3D): Shape3D has no field 'sise'") open this tab.

**Script objects** (Roblox's Script / LocalScript / ModuleScript): Add > Scripts puts one under the selected object and makes its file (`scripts/<name>.cbricks`, with a When program starts). Its **type** is its file's Side (its name in the Scene tree: **Script** orange, **LocalScript** blue, **ModuleScript** purple), shown under Name and changed with right-click ▸ Change type: **Script** = Server, **LocalScript** = Client, **ModuleScript** = Shared. **File** points it at another script; **Open script** (or a double-click) opens it in the Bricks screen. The file's When program starts runs once for each Script object of it, when the world is made (before main's), with the variable **`parent`** = the object it's under (the World at the top level). Its other bricks (functions, records) work as any script's. The FileSystem still lists every file; a script not in the Scene tree is a plain script (main.cbricks, libraries, classes). A class's script can't be a Script object (add an object of the class).

- **One root per scene** (Godot's; user, 2026-11-07): a new scene (and a project's Main scene) starts **empty**; the **first node you Add is its root**, the top row of the tree; the next ones go under the selected node (or the root). The root is renamed like any node (Properties) and its class changed with Change type... (in the Main scene: it's the world while the program runs). A scene with 3D things in it gets a **Spatial3D** root (user, 2026-11-07; older projects' plain Node roots, e.g. Main, are upgraded when opened; a scene without 3D keeps a Node, which doesn't make a text program a graphics one). A scene's root can't be saved as a branch (it's the scene already); a Script object can't be a root.
- **New scene** (the dock's button; also FileSystem ▸ New Scene) makes an empty scene with a safe file name ("My Level" -> `my-level.cbscene`) and opens it.
- **A Script object's name is its file's:** renaming it renames its script to a safe version ("Script Test" -> `scripts/script-test.cbricks`); every scene and open tab follows. FileSystem's New Script, New Scene and Rename make safe names the same way (lower case, spaces to `-`).

### 2.11 The 3D and 2D screens

- **3D:** the scene's objects (copies of other scenes included) drawn as the program will draw them (Shape3Ds in their shapes, sizes and colors, placed under their parent Shape3Ds / Spatial3Ds; Mesh3Ds and hidden Shape3Ds see-through; the Camera3D as a dark box with a line to its target, the Light3D as a yellow marker with its direction), over a grid (x red, z blue). Godot's controls: **right-drag** looks around (the camera turns in place; the pointer is held while the button is down, hidden and kept in the view, and comes back where it was) and, while it's held, **W / A / S / D** fly forward / left / back / right, **Q / E** down / up, **Shift** 3x faster (WASD also flies while the 3D screen has focus); **middle-drag** orbits, **Shift + middle-drag** (or Shift + right-drag) pans, the **wheel** zooms, **F** frames the selected object. **Click** an object to select it (the Scene tree and Properties follow); the selected one gets an orange outline and **X / Y / Z arrows**: drag one to move it along that axis (Ctrl: steps of 0.5): Properties shows the new position as you drag; saved (and undoable) when you let go. Values set by its class's When created aren't shown (the file's and the class's starting values are).
- **Camera3D snapshots:** select a Camera3D: Properties' **Snapshot** section sets Width, Height, a transparent background, what it **Shows** (everything, or one object and the objects under it) and where the PNG goes (**Save to**, from the project folder); **Take snapshot** renders the camera's view (its position, target and fov) and shows a preview. With a transparent background and one object, that's an icon of it (assets for Load texture, a UI...).
- **2D:** the game window's frame, the **UI** drawn over it as the game draws it (Properties: the **anchor grid** (↖ ↑ ↗ / ← ● → / ↙ ↓ ↘ and Full), Label's align; a UI node is picked first and dragged by its offset; the **2D** / **UI** toggles at the top right hide either layer here only), and (its size from the project's Open window brick; its color the scene's Environment's sky (grey without one)) with the world file's **Text2Ds** where they'll be drawn. Click one to select it, drag to move it (its position, shown live in Properties; Ctrl: steps of 10 px). The window's background is the Environment's sky (a gradient down to its horizon when it has one).

- **The scene's Environment** (Scene ▸ Add ▸ Environment) is what the 2D and 3D screens show behind the scene, its sky and its ambient light, as the game draws it; a scene without one has the game's neutral grey (`#30343c`). (The Sky toggle of 2026-11-07 is gone: the Environment decides.)

### 2.9 Keyboard shortcuts

| Keys | Does |
| --- | --- |
| Ctrl+S / Ctrl+Shift+S | save the tab / save all |
| Ctrl+W | close the tab |
| Ctrl+O | open a project |
| Ctrl+N | new script |
| Ctrl+Z / Ctrl+Shift+Z or Ctrl+Y | undo / redo (the edited scene's on the 2D / 3D screens, the script's on Bricks) |
| Ctrl+C / X / V / D, Delete | copy / cut / paste / duplicate / delete bricks |
| Ctrl+F | find a brick in any script |
| Ctrl+E | export the C project |
| F5 | run (or continue when paused) |
| F6 | build |
| F8 | continue / pause |
| F9 | breakpoint on the selected brick |
| F10 / F11 / Shift+F11 | step over / step into / step out |

---

## 3. Types and values

| Type | C type | Typed in as | Notes |
| --- | --- | --- | --- |
| `int` | `int` | `42`, or an expression | whole numbers |
| `float` | `double` | `2.5`, or an expression | `3` becomes `3.0` |
| `bool` | `bool` | `true` / `false`, or a condition | |
| `string` | `const char *` | text (quoted for you) | made text is kept until the program ends |
| `vector3` | `Vector3` (raylib's: three floats) | `x, y, z` (`1` alone = `1, 1, 1`) | a 3D point or direction; each part may be an expression |
| `vector2` | `Vector2` (raylib's: two floats) | `x, y` | a 2D point or direction (Key Direction, mouse movement, screen points) |
| `X list` | `cb_list *` | (made by List: Make) | one type per list: `int list`, `Point list`, `vector3 list`… **Shared** when copied |
| `X map` | `cb_map *` | (made by Map: Make) | text keys → one value type; keeps the order keys were added. **Shared** when copied |
| a record, e.g. `Point` | a C struct | (made by Make record) | fields of any type; **copied** when assigned |
| a class, e.g. `Enemy`; `Object` | `Enemy *` | (made by New object) | an object: a **reference** (copying the variable copies the reference); none = no object. An `Enemy` fits wherever its parent class (`Character`, `Object`) is wanted |
| `texture`, `sound`, `music` | `cb_texture`, `cb_sound`, `cb_music` (handles: the backend keeps the real thing) | (Load texture / Sound / Music) | graphics projects |
| `mesh` | `cb_mesh *` | (Begin mesh) | graphics projects; Brickscript's mesh bricks |

- **Ports** (what an input accepts): numbers (int / float / bool fit each other), string, Anything, a list, a map, a record, vector3. A Variable dropdown only offers fitting variables.
- **Anything** inputs (Print's value, Math's A / B…) take any type; a typed value's type is picked in the dropdown (or guessed: `42` int, `2.5` float, `true` bool, else string).
- **Printing:** `[1, 2, 3]`, `{"a": 1, "b": 2}`, `Point(x: 1, y: 2)`, `(1, 2, 3)` for a vector3.
- **Colors** (graphics) are strings: a name (`RAYWHITE`, `BLACK`, `SKYBLUE`, `MAROON`, `GOLD`, `RED`, `GREEN`, `BLUE`…) or `#rrggbb` / `#rrggbbaa`.

---

## 4. Bricks

Each entry gives the brick's **type** (as saved in `.cbricks` files and in `NodeDefs.DEFS`) and its palette title. **Inputs** are `name: type = default` (an input marked *variable* starts as a Variable dropdown). **Settings** are the dropdowns / boxes above the inputs. **Output** is where the result goes (its default variable name). **Exits** are the brick's `▶` outputs; the last one runs after the brick itself. Everything in *(when …)* is shown only for those settings.

### 4.1 Events

#### `start`: When program starts
- **What:** the program's entry point, `main()`. Its numbered outputs run in order, each chain to its end, before the next.
- **Exits:** `out` (Output 1, 2, …).
- **When:** at most one per project, in any script that isn't a Script object's. Put setup in the first outputs and the main work after.
- **C:** `int main(int argc, char **argv) { cb_start(argc, argv); … return 0; }` (`cb_start` reads the program flags, section 6).
- **Problems:** a second one in the project.
- **None in the project** (2026-11-07): the build writes its own `main()` (`cbricks_main.c`): the Main scene is made (its Script objects' When program starts run), and in a graphics project a window (800 x 450, the project's name, 60 frames a second) runs the Game loop until it's closed (Close window, or the window's close button). Godot's way: running the project runs its Main scene.

#### `frame_start`: When frame starts
- **What:** an event: runs at the start of every frame of the Game loop, before the objects' Every frame (Godot's `_process` for the whole program).
- **Inputs it gives:** `dt` (float: the last frame's length in seconds). **Exits:** `out`.
- **Where:** any plain script (not a class's: objects have Every frame); a Server script's runs where the game's rules run, a Client script's on players' machines; a windowless server runs it too. A text program (no Game loop) never runs it.
- **When:** reading input for the frame, timers, spawning.

#### `frame_end`: When frame ends
- **What:** an event: runs at the end of every frame, after the objects have moved (Every frame) and touched, before the world is drawn.
- **Inputs it gives:** `dt`. **Exits:** `out`. **Where:** as When frame starts.
- **When:** a camera that follows something and a HUD (no frame of lag: they see where everything ended up this frame).

#### `exit`: When program ends
- **What:** runs when `main()` returns or the program exits (Exit program, an Assert). An `atexit` handler.
- **Exits:** `out`.
- **When:** printing a summary, saving a file at the end.
- **Notes:** it shares only **Global** variables with the rest of the program (main's locals are gone by then).

#### `function`: Define Function
- **What:** a C function. Its chain runs when a Call Function calls it; its inputs are variables inside it.
- **Settings:** Name (`my_function`), Gives back (`void` or any type), Inputs (a list of name + type).
- **Exits:** `out`.
- **When:** anything done in more than one place, recursion (see the *Functions Factorial* example), splitting a long chain up. Any script can call any script's functions (their prototypes are in `cbricks.h`).
- **Problems:** two functions with one name in the project; a name that isn't a C identifier.

### 4.2 Flow

#### `if`: If
- **What:** compares A with B (or checks a bool) and runs the True or the False chains, then the Next chains either way.
- **Settings:** Compare: `is true`, `is false`, `==`, `!=`, `<`, `<=`, `>`, `>=`.
- **Inputs:** `a: Anything` (variable), `b: Anything = 0` (when Compare is two-sided). A bool expression typed into A works too (`dx != 0 || dz != 0`).
- **Exits:** `true`, `false`, `next` (all grow).
- **When:** any decision. Two strings are compared by their text (`strcmp`).

#### `while`: While
- **What:** runs the Loop body again and again while the comparison holds, checked before each round. Done runs after.
- **Settings / Inputs:** as If.
- **Exits:** `loop`, `done`.
- **When:** repeating until something changes (input, a search). The body must change what it compares, or it never ends (`--max-steps` catches that in tests).

#### `for`: For range
- **What:** counts Index from From up to, not including, To, by Step, running the Loop body each time.
- **Inputs:** `from: int = 0`, `to: int = 10`, `step: int = 1`.
- **Output:** `index: int` (`i`).
- **Exits:** `loop`, `done`.
- **When:** a known number of rounds with a counter; nested For ranges for grids (the Gem Collector's ground).
- **C:** `for (i = from; i < to; i += step)`.

#### `wait`: Wait
- **What:** pauses its chain for some seconds, then carries on to the next brick (Brickscript's Wait).
- **Inputs:** `seconds: float` (a number, or a variable).
- **C:** `cb_wait(seconds);`. A text program sleeps. A graphics program (one with Open window) keeps the window and the world running meanwhile: frames go on being drawn, objects' Every frame, When touched and When drawn run, moving Shape3Ds move; only the waiting chain (and the Game loop's own Frame chain it's in) pauses. A Wait inside a Frame chain closes that frame, runs the world, then reopens it.
- **When:** a pause between steps (a countdown, "Game over" for 2 seconds, a wave every few seconds from When program starts).
- **Problems:** inside an object's event (Every frame, When touched, When drawn): `Wait can't be in an object's event` (it would hold up the whole world): count time in a field instead (add `dt` each frame). A method called from an event that waits is skipped at run time with a warning.

#### `repeat`: Repeat N times
- **What:** runs the Loop body Times times.
- **Inputs:** `times: int = 3`. **Output:** `counter: int` (optional, from 0).
- **Exits:** `loop`, `done`.
- **When:** "do this N times" with no counter needed.

#### `for_each`: For each item
- **What:** runs the Loop body once per item of a list, the item (and its index, optional) in variables.
- **Inputs:** `list: a list` (variable). **Outputs:** `item` (the list's item type), `index: int` (optional).
- **Exits:** `loop`, `done`.
- **When:** going through a list; through a map, go through its Keys (Map: Keys). A record item is a **copy**: change it, then List (Set) it back at Index.

#### `switch`: Switch
- **What:** runs the chains of the case equal to the value (ints, floats or text), or Default's when none is; then Next.
- **Settings:** Cases (a list of values, e.g. `1`, `2`, `3` or `red`, `green`).
- **Inputs:** `value: Anything` (variable).
- **Exits:** one per case, `default`, `next` (all grow).
- **When:** many Ifs on one value: menu choices, commands, states.

#### `break`: Break
- **What:** inside a Loop body, leaves the loop at once; its Done runs next.
- **Exits:** none.

#### `continue`: Continue
- **What:** inside a Loop body, skips the rest of this round.
- **Exits:** none.

#### `reroute`: Reroute
- **What:** a point on a wire, to bend it round other bricks. Nothing runs there.
- **Exits:** `next`. **How:** double-click a wire.

### 4.3 Input / Output

#### `print`: Print
- **What:** prints a value of any type to stdout.
- **Settings:** New line (on).
- **Inputs:** `value: Anything = "Hello, world!"`.
- **When:** output, and quick checks of a value (or use the debugger).
- **C:** `printf` for numbers / bools / text; lists, maps, records and vectors print with their printers (`[1, 2]`, `{"a": 1}`, `Point(x: 1, y: 2)`, `(1, 2, 3)`).

#### `read`: Read input
- **What:** prints the prompt, then reads what's typed on stdin: a whole number, a number, or a line of text.
- **Settings:** Read: `int` / `float` / `line`; Prompt (`Enter a number: `).
- **Output:** `value` (`n`): int, float or string.
- **When:** interactive text programs (*Guess the Number*, *Read Your Name*). In the editor, type into the Console's input line; in tests, `--input FILE`.
- **Notes:** at the end of input a number reads as 0 (a While waiting for input then loops forever: use `--max-steps`).

#### `time`: Get Time
- **What:** seconds since the Unix epoch, `time(NULL)`.
- **Output:** `seconds: int` (`now`).
- **When:** timestamps, measuring long waits. (In games use Game info.)

### 4.3b User Input

The keys and the mouse (palette group **User Input**, 2026-11-07): what this machine's player does (Input, Mouse position, Mouse mode, Key Direction), and players' keys read where the game's rules run (Player Key, Player Input; 4.6b). They need a window (graphics projects).

#### `input`: Input
- **What:** whether a key or mouse button is held down, or was pressed / released this frame.
- **Settings:** When (Key down, Key pressed, Key released, Mouse down, Mouse pressed, **Mouse over UI**: the pointer is over a UI node that draws something (Label, Panel, Bar, Image, Button; a plain Control doesn't count): skip the game's own clicks then, a click on a Button is the Button's; false while the mouse is captured); Key (A–Z, digits, SPACE, ENTER, arrows, F1–F5…); Button (LEFT / RIGHT / MIDDLE).
- **Output:** `result: bool` (`pressed`).
- **When:** Key down for movement (held), Key pressed for one-off actions (jump, restart).

#### `mouse`: Mouse position
- **What:** the mouse (Get): its **Position** in the window (pixels, ints); its **Movement** since the last frame (floats: mouse look, with Mouse mode Captured; the first moment after capturing reads 0, so the view doesn't jump); how far the **Wheel** turned (X).
- **Settings:** Get. **Outputs:** `x`, `y` (`mouse_x`, `mouse_y`; Wheel: x only).

#### `mouse_mode`: Mouse mode
- **What:** how the mouse behaves (Brickscript's Mouse mode): **Visible**, **Captured** (hidden and kept in the window: mouse look), **Hidden**.
- **When:** a first-person game: Captured after Open window (Esc still closes the window).

#### `key_direction`: Key Direction
- **What:** which way the keys push (Brickscript's Key Direction): a `vector2` at most 1 long, x: Left -1 / Right 1, y: Forward -1 / Back 1 (two keys at once aren't faster).
- **Settings:** Left, Right, Forward, Back (keys; A, D, W, S). **Output:** `result` (`move`).
- **When:** movement: in 3D, x and y as x and z, turned by the camera's yaw (`(kd.x * cos(yaw) + kd.y * sin(yaw), 0, kd.y * cos(yaw) - kd.x * sin(yaw))`), times speed and frame time.

#### `player_key`: Player Key
- **What:** an event family: **Player Pressed** / **Player Released**: runs where the game's rules run when a player presses / releases a key on their machine, with `player`.
- **Settings:** When (Pressed / Released); Key (raylib's names: A-Z, SPACE, ENTER, arrows, digits, F1-F5...). **Inputs it gives:** `player`. **Exits:** `out`.
- **Where:** a plain script, not a Client one (there: Input). **When:** jumping, shooting, using: the server decides what a press does.

#### `player_input`: Player Input
- **What:** a family: **Player Holds?** (a bool: is the player holding Key) · **Player Direction** (a vector2 at most 1 long from four keys, like Key Direction).
- **Settings:** Get; Key (Holds); Left / Right / Forward / Back (Direction). **Inputs:** `player` (blank: the player above the script's object or its owner, e.g. in an owned character's Every frame; else this machine's player; a player who left, or none: no keys). **Output:** `result`.
- **Where:** not in Client scripts (there: Input / Key Direction). **When:** moving a player's character on the server every frame.


### 4.4 Variables

#### `var`: Variable
- **What:** a family. **Get** reads a variable into the Output; **Set** puts a value in it (a new name makes a variable typed like the value); **Add** adds to it (`x += value`; joins text; appends to a list; adds vectors).
- **Settings:** Mode (Get / Set / Add), Variable (a name: pick one or type a new one), Kind (when Set, for a new variable: **Chain**, the default: only later bricks of this event or function, fresh every run; **Shared**: every event and function of the script, keeping its value).
- **Inputs:** `value: Anything = 0` (when Set / Add). **Output:** `copy` (when Get).
- **When:** Set to start a variable or change it; Add for counters and scores (`score` Add `1`), building text, collecting into a list.
- **Problems:** Add on a bool, record or map; any change to a Constant.

#### `convert`: Convert
- **What:** a C cast between number types.
- **Settings:** To: `int` / `float` / `bool`. **Inputs:** `value: Anything` (variable). **Output:** `result` (`converted`).
- **When:** float → int (cuts off the decimals), int → float before a division. Text ↔ numbers: Text (To int / To float / To text).

#### `constant`: Constant
- **What:** a value that never changes, readable by every brick of every script. A declaration: no wires.
- **Settings:** Name (`MAX_SCORE`), Type (int / float / bool / string). **Inputs:** `value = 10`.
- **When:** tuning numbers in one place (the Gem Collector's `ROUND_TIME`, `SPEED`, `GEM_COUNT`).
- **C:** a `#define` in `cbricks.h`. **Problems:** a Variable (Set / Add) on it.

### 4.5 Functions

#### `return`: Return
- **What:** ends the function it's in at once, giving back the value (or nothing: just leave early).
- **Settings:** Gives: A value / Nothing. **Inputs:** `value: Anything = 0` (when A value).
- **Exits:** none.
- **Notes:** a function that ends without a Return gives back its type's zero.

#### `call`: Call Function
- **What:** runs a function and keeps what it gives back. Picking the function gives the brick one input per function input.
- **Settings:** Function (a dropdown of the project's functions).
- **Inputs:** one per function input. **Output:** `result` (when the function gives something back).
- **When:** using a Define Function from any script. Its right-click menu has *Go to function*.
- **Problems:** no function of that name (renaming a function renames its calls everywhere).

### 4.6 Objects

A class is a script with a **Class** brick. Its **fields** belong to each object, and its methods use them by name (`hp`, not `self.hp`). Its **Define Functions** are its **methods**, where **Self** is the object they run for. A class can **extend** another and get that class's fields and methods. A method with a parent's method's name **replaces** it: the object's own class's version runs, even when it's called through the parent class. **When created** runs for every new object, the parent class's first.

Objects are references and are made with New object. **Destroy object** frees one (and the objects under it) at once; using a destroyed object stops the program and names the brick. Every object also has an **id** (a number no other object has), a **name**, a **parent** and **children**: the start of a world tree. `Object` is the class every class comes from.

```
scripts/character.cbricks   Class: Character, extends Object, fields hp int, tag string
                           When created → Variable (Set) hp = 10
                           Define Function hit(dmg int) gives int → Math hp - dmg into hp → Return hp
scripts/enemy.cbricks       Class: Enemy, extends Character, fields power int
                           Define Function describe() → … (replaces Character's)
main.cbricks                New object Enemy into bad → Call method Character.hit(bad, 3) → Print
```

In C, a class is a struct whose first member is its parent (`struct Enemy { Character base; int power; };`), plus a table of its methods' functions and a descriptor (`Enemy_class`) listing its fields with their types and Synced flags. A method is `int Enemy_hit(void *self_, int dmg)`; a call goes through the object's table (`((const Character_vt *)obj->cls->vt)->hit(obj, 3)`).

#### The world

Graphics projects have a **world**: a tree of nodes that the **Game loop runs by itself** every frame, before its Frame chains:
1. every object's **Every frame**;
2. **When touched** runs where two Shape3Ds start overlapping (nothing moves by itself: an object's Every frame moves it, or Move and collide);
3. the world is drawn: the Environment's sky, then in 3D from its first **Camera3D**, lit by its **Light3D** and Environment, then the **2D** on top (through the first **Camera2D**, if there is one).
   (around those: **When frame starts** before the objects' Every frame, **When frame ends** after touches and before drawing, any plain script's)

**The world is the Main scene's root** (user, 2026-11-07): the scene's top node (a Node, a Spatial3D, your own class...) and everything under it; Node (World) gives it. A scene made with no parent becomes the world: the Main scene at the start, and **Change scene** (the old world goes, the new scene's root replaces it). A program whose Main scene is empty gets a plain Node named World the first time something goes in the world. In a network game every machine makes its own root from the Main scene; only its Synced fields travel. A world with nothing in it draws nothing, so games that draw with bricks work as before. **New object** puts a node in the world (*In the world*, on by default). **Node (Set parent)** puts it under another node instead: a **Spatial3D's position, rotation and scale are relative to its parent Spatial3D** (Godot's way; a Spatial2D's to its Spatial2D parent), so a character made of shapes, or a turned group, moves as one. Rotation is in degrees: y turns, x tilts, z rolls.

**The built-in classes are small on purpose** (user, 2026-11-07): they place, draw and light things; a game's own classes extend them with what they need (`Class: Gem, Extends Shape3D`; a Hero with health and speed; its own velocity, moved in its Every frame). Fields with their starting values:

| Class | Extends | Fields | Is |
| --- | --- | --- | --- |
| `Node` | — | (name, parent, children, groups, metadata: every object's) | the root of every class (was Object) |
| `Spatial3D` | Node | position `0, 0, 0`, rotation `0, 0, 0`, scale `1, 1, 1` | a place in 3D: what's under it moves, turns and scales with it (was Model); Synced: all three |
| `Shape3D` | Spatial3D | shape `Box` (Box / Sphere / Cylinder / Plane), size `1, 1, 1`, color `WHITE`, visible `true`, solid `false` | a shape: drawn, touched (When touched), hit by Raycast; solid: Move and collide stops at it (was Part) |
| `Mesh3D` | Spatial3D | mesh, color `WHITE`, visible `true` | a mesh from the mesh bricks (was MeshPart; its scale sizes it) |
| `Camera3D` | Spatial3D | target `0, 0, 0`, fov `60` | what the world is seen from (the first one), looking at target |
| `Light3D` | Spatial3D | color `WHITE`, energy `1` | the sun: it shines along its -Z (turn it with rotation; `-55, 34, 0` is like the old default) in its color, energy times as strong (the ambient light isn't tinted) |
| `Spatial2D` | Node | position `0, 0`, rotation `0`, scale `1, 1` | a place in 2D (window pixels without a Camera2D) |
| `Shape2D` | Spatial2D | shape `Rectangle` (Rectangle / Circle), size `32, 32`, color `WHITE`, visible `true` | a rectangle or circle, centred on its position |
| `Sprite2D` | Spatial2D | texture (a path), color `WHITE` (its tint), visible `true`, columns `1`, rows `1`, frame `0` | a picture, centred on its position; a sprite sheet when Columns / Rows cut it into cells: it shows cell Frame (counted along the rows from the top-left), Godot's hframes / vframes / frame |
| `Text2D` | Spatial2D | text, size `20`, color `BLACK`, visible `true` | text (a score, a message: its top-left at its position; was Label) |
| `Camera2D` | Spatial2D | zoom `1` | the 2D view: its position is the window's middle |
| `Environment` | Node | sky `#87ceeb`, horizon (blank: none), ambient `0.38`, ambient_color `WHITE`, fog `0`, fog_color (blank: the sky's), fog_start `0` | the sky, the ambient light and fog (the first one; none: a neutral grey, no fog). **horizon**: the sky is a gradient from sky at the top of the window to horizon at the bottom. **ambient_color** tints the ambient light (the shaded sides). Fog: 3D things fade into fog_color with their depth from the camera beyond **fog_start**, Godot's exponential fog (seen = e^(-fog × (depth - fog_start)): 0.05 hides half ~14 units further; 0 none); the sky itself isn't fogged; Draw shape's lines, wire boxes and grids neither. The editor's 3D screen previews all of it |

| `Control` | Node | anchor `top_left`, offset `0, 0`, size `120, 32`, visible `true` | **UI** (green): a box in the window, in pixels (see *The UI* below); draws nothing itself: holds other UI |
| `Label` | Control | text `Label`, font_size `20`, color `WHITE`, align `left` (center, right) | text in its box (from the top; align across) |
| `Panel` | Control | color `#000000a0`, border_color (blank: none), border `0`, radius `0` | a box: its colour, a border, rounded corners (radius in pixels) |
| `Bar` | Control | value `50`, max `100`, color `#4caf50`, back `#00000080` | a bar filled value / max of its width (health, loading) |
| `Image` | Control | texture (a path), color `WHITE` (its tint) | a picture stretched over its box |
| `VBox` / `HBox` | Control | separation `4`, padding `0`, fill `false` | containers: the Controls directly in it stacked down (VBox) or across (HBox) in scene-tree order, each its own size, separation apart, padding in from the box's edges; **fill** stretches them across (a VBox's width, an HBox's height). Their anchor and offset don't count; hidden ones take no room; what's inside them lays out as usual. Extend them for your own (a Menu, a toolbar): users are expected to build richer controls themselves |
| `Button` | Control | text `Button`, font_size `18`, text_color `WHITE`, color `#3a4150`, hover_color `#4c5568`, press_color `#2a2f3a`, border_color `#ffffff40`, border `1`, radius `4`, disabled `false` | a box with its text in the middle, in its color (the pointer over it: hover_color; held down on it: press_color; disabled: faded, not clickable). A click (pressed and let go over the same Button, with the left button) runs its class's **When clicked** and every matching **When button clicked**; none while the mouse is captured (mouse look). Something drawn over it covers it |

**The UI** (2026-11-07, agreed with the user; Godot's Control nodes): the frame draws the 3D (through the Camera3D), then the 2D (through the Camera2D), then **the UI on top of everything**, including the Game loop's Draw bricks; UI nodes are in the window in pixels and **no camera moves them**. A UI node's box: its **anchor** names a point of its parent's box (the nearest Control above it; none: the window): `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right`: the same point of its own box goes there, then `offset` pixels further (right / down: `bottom_right` with offset `-10, -10` keeps it 10 px from the window's corner whatever the window's size); `full` fills the parent's box, `offset` in from each side. **Spatial3D / Spatial2D nodes above a UI node don't move it**, so a player's health bar can sit inside their character's scene. A hidden Control hides what's under it. Draw order: the scene tree's (later ones on top). **UI is never sent over the network**: a server's or client's UI stays on its machine (each builds its own, usually in a LocalScript, filled from Synced values or remotes). Set their fields with Record field (Set), e.g. a Label's text, a Bar's value. Buttons: section 4.6c. Containers: VBox / HBox (above).

Old projects are upgraded when they're opened: Part -> Shape3D (its velocity dropped: move it in Every frame), Model -> Spatial3D, MeshPart -> Mesh3D (size -> scale), Label -> Text2D (x, y -> position), Light -> Light3D (direction -> rotation), the Camera's sky and the Light's ambient -> a new Environment, Object -> Node; bricks that read a field that's gone (a Label's x) get a problem naming them.

Their fields are read and set with Record field, or by name inside a class that extends them (`Variable (Add) rotation (0, 90 * dt, 0)` in a Spinner's Every frame).

**Scenes** (`.cbscene` files, edited in the editor's **Scene** dock, 2.10) hold objects: each one's class, name, parent and field values, plus **copies of other scenes** (prefabs, Godot's packed scenes: an enemy made of a body, a sword and its Script object, placed many times). The project's **Main scene** (`main.cbscene` by default; project.cbproj `main_scene`; FileSystem's right-click **Set as Main Scene**) holds the objects the world starts with. A copy can change its **root's** name, fields, groups and metadata; what's under the root is edited in the scene's own file, and a change there shows in every copy. **Every scene has one root** (the first node added); a scene can't hold itself. Old scenes with several objects at the top are upgraded when read: they go under a new root (a Node named after the file, e.g. Main; the Main scene's World settings of 2026-11-07, if any, become its class and name). **Instance scene** and **Change scene** (the Scene brick) use them while the program runs. Old projects' `world.cnworld` is read as the Main scene and renamed to `main.cbscene` when the project is opened.

The Main scene's objects are made before When program starts runs (each one's When created first, then the file's values), and bricks find them by name with **Node (Find)** (`Find "Player" as Player`). The *Gem Hunt* example is built this way: the camera, sun, floor, walls, player and HUD are in its world file; a Player class moves itself, a Gem class spins and is picked up; main only opens the window, makes the gems and runs the Game loop.

#### `class`: Class
- **What:** makes this script a class (one per script). A declaration: no wires.
- **Settings:** Name (`MyClass`); Extends (`Node`, a built-in class, or another class); Fields (a name and a type each: any type, other classes too); Synced (field names, comma-separated: in a network game the server sends their changes to every player, see 4.6b; a name ending in `!` jumps instead of gliding, e.g. `position!`).
- **When:** anything there are several of, each with its own data and behaviour: enemies, items, players, bank accounts.
- **Problems:** a name already used; Extends naming no class, or classes extending each other in a circle; a field named `base`, `cls`, `id`, `name`, `parent`, `children` or `self` (every object has those); a field a parent class already has; Synced naming a non-field, or a field networking can't send yet (lists, maps, records, meshes, textures); a method replacing a parent's with other inputs or another Gives back; When program starts / ends inside a class's script.

#### `created`: When created
- **What:** in a class's script, runs when an object of the class is made, after its parent classes' When created. Self is the new object; its fields start at zero / empty.
- **Exits:** `out`.
- **When:** starting values (`hp = 10`), making the object's own lists or child objects.

#### `every_frame`: Every frame
- **What:** in a class's script: runs once per frame for every object of the class that's in the world, before the Game loop's Frame chains.
- **Inputs it gives:** `dt` (float): the frame's length in seconds. **Exits:** `out`.
- **When:** anything an object does by itself: moving (`position + velocity * dt`), spinning, timers, following the player.

#### `touched`: When touched
- **What:** in the script of a class that extends Shape3D: runs when another Shape3D in the world starts touching this one (their boxes overlap; rotation isn't counted). Both Shape3Ds hear it.
- **Inputs it gives:** `other` (Shape3D). **Exits:** `out`.
- **When:** pickups (a gem touched by the player), hits, triggers. Node (Is a / As) tells what `other` is.

#### `drawn`: When drawn
- **What:** in a class's script: runs while the world is drawn in 3D, in the object's own space (at its position, turned with it).
- **Exits:** `out`.
- **When:** extra drawing that moves with the object: Draw shape bricks (a health bar above an enemy, a glow).

#### `new_object`: New object
- **What:** makes an object of a class: its fields at their starting values, then its When created runs.
- **Settings:** Class; In the world (on: under the world, so it's run and drawn; off: under nothing until Set parent). **Output:** `object` (`obj`), of that class.
- **When:** spawning things: an enemy, a gem, a bullet.

#### `destroy`: Destroy object
- **What:** frees an object and the objects under it (its children).
- **Inputs:** `object` (variable).
- **Notes:** using it afterwards (a method, a field, Class name…) stops the program: `[error] main.cbricks brick 12: the object was destroyed`. Node (Exists) checks first. The runtime keeps the last 1024 destroyed objects' memory a while, so a stale variable is caught rather than meeting a new object at the same address.

#### `call_method`: Call method
- **What:** runs a method of an object. The object's own class's version runs: a subclass's method replaces its parent's.
- **Settings:** Class (the object's class or a parent class of it); Method (that class's methods, its own and inherited).
- **Inputs:** `object` (variable), then one per method input. **Output:** `result` (when the method gives something back).
- **Problems:** the object isn't of that class (`'hero' is a Character, not an Enemy`); the class has no such method (the problem lists the ones it has); the object is none or destroyed when it runs.

#### `scene`: Scene
- **What:** scenes (`.cbscene`, Godot's packed scenes): **Instance scene** makes a copy of a scene's objects under a Parent and gives its root; **Change scene** clears the world (destroys everything in it) and makes another scene in it.
- **Settings:** Do; Scene (the project's scenes). **Inputs:** `parent` (an object variable; blank: the world; Instance). **Output:** `root` (Instance): the copy's root object, typed as its class (a scene whose root is an Enemy gives an Enemy).
- **C:** `cb_scene_<n>_<name>(parent)` (one function per scene in `cbricks_scene.c`) / `cb_change_scene(cb_scene_...)`. The copy's Script objects run their When program starts as it's made.
- **When:** spawning things made of several objects (an enemy with its sword and health label, a pickup with its glow), levels and menus (Change scene). One object of a class: New object.
- **Problems:** no scene picked or no such scene; Instance of a scene with more than one object at the top (`needs one (its root)`: put them under a Spatial3D). Change scene asked for from an object's event (Every frame, When touched, When drawn) happens at the start of the next frame.

#### `group`: Group
- **What:** named groups of objects (Brickscript's / Godot's groups): **Add to group** · **Remove from group** · **Is in group** (a bool) · **Objects in group** (every object in the world in it: an `Node list`). An object can be in many groups.
- **Settings:** Do; Group (its name).
- **Inputs:** `object` (variable; not for Objects in). **Output:** `result` (Is in, Objects in).
- **When:** treat many objects alike without a class for it (every "enemies" takes damage, "pickups" spin). Objects get starting groups in the Scene tree's Groups tab (world.cnworld `"groups"`).

#### `metadata`: Metadata
- **What:** extra text values on any object by key (Godot's metadata): **Set metadata** · **Get metadata** (`""` when there's none) · **Has metadata** (a bool) · **Remove metadata**.
- **Settings:** Do. **Inputs:** `object` (variable), `key: string`, `value: string` (Set; numbers are turned into text). **Output:** `result` (Get, Has).
- **When:** a note on one object that its class has no field for (a door's "key" name, a spawn's "wave"). Starting values: Properties > Metadata (world.cnworld `"meta"`). Text only: To int / To float make numbers of it.

#### `object`: Object
- **What:** a family about objects: **Exists** (not none, not destroyed) · **Is a** class (its own or a parent's) · **As** a class (the object, or none when it isn't one) · **Class name** · **Id** · **Name** (the class's name until Set name) · **Set name** · **Parent** · **Set parent** (under another object; blank: under nothing) · **Children** (an `Node list`, a copy) · **World** (the world's root object) · **Find** an object in the world by Name, as a Class (none when there's none of that name and class).
- **Settings:** Do; Class (Is a, As, Find).
- **Inputs:** `object` (variable; not for World, Find), `name: string` (Set name, Find), `parent` (Set parent).
- **Output:** `result`: a bool, the object, a string, an int, or a Node list.
- **When:** Is a / As to treat an object by its real class (`if obj is a Gem`); Exists before using something that may be destroyed; parents and children to group objects (destroying a parent destroys its children).

### 4.6c UI

Buttons' clicks (2026-11-07). UI runs on the machine whose window it is: click events belong in plain (typically LocalScript) or Shared scripts, not Server ones; tell the server with Fire Server. Tests click without a mouse: `--click X:Y:T` (section 6).

#### `clicked`: When clicked
- **What:** an object event: in the script of a class that extends **Button**, runs when that Button is clicked on this machine (pressed and let go over it with the left button; not while it's disabled, covered by something drawn over it, or the mouse is captured).
- **Exits:** `out`. **Inputs it gives:** Self (the Button).
- **When:** buttons with their own behaviour and data (a level button that knows its level).
- **Problems:** in a class that doesn't extend Button; Wait / Invoke Server in it (an object's event).
- **C:** `cls_X_on_clicked(self)`, called through the class descriptor's `clicked` hook by the runtime's `cb_ui_input` (as each frame begins).

#### `button_clicked`: When button clicked
- **What:** runs when a Button in the world is clicked on this machine, with `button` (the Button: Node (Name), Record field). **Button name**: only that one (blank: any).
- **Settings:** Button name. **Exits:** `out`. **Inputs it gives:** `button: Button`.
- **When:** menus and HUD buttons without a class of their own: a LocalScript's When button clicked "Play" -> Change scene.
- **Problems:** in a class's script (use When clicked); in a Server script (the UI is on players' machines).
- **C:** a handler registered with `cb_on_click(side, name, fn)`.

### 4.6b Network

A network game, Roblox's / Brickscript's way: **one machine runs the game** (a host, which also plays as player 1, or a dedicated server with no player of its own) and players' machines join it. Offline (the default) the program is single-player: its own server and client, you are player 1. UDP on Linux, Windows, macOS, the BSDs and MS-DOS (Watt-32; the Web and WASI have no sockets yet: Host / Join give false there).

- **Players are numbers** (Godot's peer ids; user, 2026-11-07): the host, or you offline, is 1, others count up as they join; 0 is no one. There's no Player class: a game keeps its players' data in its own classes (a Hero, its score...). Player Joined / Left give `player` (an int), the Player brick gives a number's name, whether it's me, whether it's in the game, everyone.
- **Sides:** a script's Side says where it runs: a **Server** script only where the game's rules run (offline, host, dedicated server), a **Client** script only on players' machines (offline, host, client), **Shared** everywhere. This covers its Script objects' When program starts and its Player Joined / Left; the main script always runs.
- **The same build:** a client running a different build of the game (any change to its C) is refused when it joins.
- **The world is the server's** (stage 3b): 30 times a second the server sends every client what changed in the world: objects made (class, parent, name), re-parented, renamed, destroyed, and their **Synced** fields (numbers, bools, text, vectors, objects; a class's Synced setting; Shape3D / Spatial3D placement and looks by default). A client that joins gets the whole world first (Join waits for it). On a client, **the server's objects run no Every frame, When touched, When created or physics** (the server does; When drawn still draws), and Synced vectors **glide** to their new values (a jump of 4 or more, or a field Synced as `name!`, snaps). A field named `rotation` (or ending in it, degrees) glides as an angle: the short way round, snapping only at a 90 degree turn. The Main scene's objects are matched by their place in the scene, so a client's Script objects stay under the server's copies; joining replaces this machine's world with the server's.
- **Local objects:** an object in the group **`local`** (Groups tab, or Group: Add), or of a Client class, isn't sent, nor what's under it: a HUD, a machine's own camera. Every machine makes its own.
- **A dedicated server has no window** (`--server`): Open window opens none, the Game loop runs the world on its own clock at the window's rate, drawing / keyboard / mouse / sound bricks are skipped (their outputs keep their values), Game info's width / height / FPS are 0.
- **A client's changes** to the server's objects stay on that machine until the server changes them again; ask the server instead (next: Fire Server).
- **Remotes** (stage 3c, Roblox's RemoteEvents): messages declared once for the whole project (**Define Remote**: a name, a direction, typed values), sent with **Fire Server** / **Fire Clients** and received by **On Client Fired** / **On Server Fired**, each picking the remote from a dropdown. Synced changes the server made before a Fire Clients have arrived when it runs there. Objects in values travel as the server's object numbers (players as their numbers): the receiving machine gets its own copy, or none.
- **Players' keys on the server** (stage 3d, Brickscript's Player Pressed / Player Holds? / Player Direction): every player's machine sends the keys the project's **Player Key** / **Player Input** bricks name (only those, at most 64) when they change; the server reads any player's. Offline and hosting, your keys are player 1's. These bricks need a window, so they make a project a graphics one. `--press KEY:FROM:TO` holds keys without anyone at the keyboard (tests).
- **Ownership** (Brickscript's Give To / Owner / Mine?): an object can be a player's (the **Ownership** brick's Give to, on the server); what's under it is theirs too; clients are told. The server stays in control. A blank Player in a class's method (Every frame...) or a Script object's start is the owner of the object it's in.
- Example: **Net Gems** (section 5).
- **The do-it-yourself starter player** (user, 2026-11-07; Roblox's StarterPlayer is gone): make a scene for a player (a Hero: your class, with Client and Server Script objects in it); a Server script's **Player Joined** instances it (Scene: Instance scene) and **Gives** it **to** the player. **A Client Script object in an instance made while the game runs starts on the machine of the player who owns it** (a client: when the server's copy arrives and it's theirs; a host or offline: when it's its own player's or no one's), with `parent` = the instance's root; its blank Player is the owner. Server Script objects in it run on the server when it's made. Example: Net Gems (scenes/hero.cbscene).
- Coming next: Moved By (a player's machine moving its own character, with prediction).

#### `network`: Network
- **What:** a family: **Host** (this program becomes the server on Port; its player stays player 1) · **Join** (connect to a server's Address and Port: waits at most Timeout seconds for its welcome) · **Leave** (back to single-player; a host's clients see the game close) · **Network role** (`offline`, `host`, `server` or `client`) · **Is server** (true where the game's rules run: offline and hosting too).
- **Settings:** Do. **Inputs:** `address: string = "127.0.0.1"` (Join), `port: int = 7000` (Host, Join), `timeout: float = 5` (Join).
- **Output:** `result` (`ok`): Host / Join a bool (false: already in a game, the port is taken, nobody answered or the server refused), Role a string, Is server a bool.
- **Problems:** Host / Join / Leave in a Server script (a player's choice: use a Client or Shared script).
- **When:** a menu's Host / Join buttons; Role / Is server to do something only where the rules run. The flags `--host PORT`, `--server PORT`, `--join ADDRESS:PORT`, `--name NAME` do the same from the command line, before the program starts.

#### `player_joined`: Player Joined
- **What:** an event: runs on every machine when a player joins, and once for each player already there when the program starts or joins a game (you included: offline you are player 1), so everyone's things are made the same way.
- **Inputs it gives:** `player` (an int: their number; Player (Name) gives their name). **Exits:** `out`.
- **Where:** a plain script (not a class's); a Server script's runs only where the game's rules run, a Client script's only on players' machines. It runs once the program is ready (after its scene is made), then whenever the network has its turn: in Wait, every frame, in Join / Leave.
- **When:** a welcome line, a score per player, a player's character (once the world is copied to players).

#### `player_left`: Player Left
- **What:** an event: runs on every machine when a player leaves, or stops answering for 5 seconds; `player` can still be read here (name, number), then it's destroyed. When this machine leaves a game, it runs for every player, then Player Joined for you again (single-player).
- **Inputs it gives:** `player` (an int: their number; Player (Name) gives their name). **Exits:** `out`.
- **When:** a goodbye line, removing their things.

#### `remote`: Define Remote
- **What:** a declaration (no wires) of a message between the players' machines and the server, for the whole project (any script; one name each): its Name, its **Direction** (**To server**: a player's machine tells the server; **To clients**: the server tells players; **Both**; **Ask server**: a question a player's machine asks the server and waits for, Invoke Server / On Client Invoked / Answer, Roblox's RemoteFunction), its **Values** (a name and a type each: int, float, bool, string, vector2, vector3, a class; a player is an int) and, for Ask server, its **Answer** type (one of those).
- **Problems:** a name used twice or not an identifier; a value named `sender` or `player` (the bricks' own), two values with one name, a value (or an Answer) of a type that can't travel yet (lists, maps, records).
- **When:** every request a player makes of the game (buy, chat, use, shoot), every event the server announces (round over, someone scored).

#### `fire_server`: Fire Server
- **What:** sends a remote (To server / Both) with its values to the server, where its On Client Fired runs with `sender` = this machine's player. Offline or hosting, this machine is the server: it runs here at once.
- **Settings:** Remote (a dropdown of the project's remotes that go that way). **Inputs:** one row per value of the remote (like Call Function's). **Exits:** `next`.
- **Problems:** in a Server script; no remote / an unknown one; a To clients remote. Values over ~1100 bytes in all aren't sent (a warning naming the brick).

#### `fire_clients`: Fire Clients
- **What:** sends a remote (To clients / Both) with its values to every player's machine (**All**) or one player's (**One player**: e.g. On Client Fired's `sender`, Player Joined's `player`); there its On Server Fired runs. A host is a player too: it runs there as well. The world's Synced changes made before it are sent first, so they've arrived when it runs.
- **Settings:** Remote; To (All / One player). **Inputs:** `player` (One player), then a row per value. **Exits:** `next`.
- **Problems:** in a Client script; no remote / an unknown one; a To server remote; One player without a player (a number).

#### `on_client_fired`: On Client Fired
- **What:** an event: runs on the server when a player's machine fires this remote; its values are variables (typed as the remote says), plus `sender` (the Player who sent it). Several of them for one remote all run, in order.
- **Settings:** Remote. **Inputs it gives:** the remote's values, `sender`. **Exits:** `out`.
- **Where:** a plain script, not a Client one. **Check what you're told:** any client can send anything (is `sender` allowed to do it? is the amount sensible?).

#### `on_server_fired`: On Server Fired
- **What:** an event: runs on a player's machine when the server fires this remote to it; its values are variables.
- **Settings:** Remote. **Inputs it gives:** the remote's values. **Exits:** `out`.
- **Where:** a plain script, not a Server one.

#### `invoke_server`: Invoke Server
- **What:** asks the server a question (a remote whose Direction is **Ask server**) with its values and **waits** for the answer, at most `timeout` seconds; meanwhile the window, the world and the network keep running (as in a Wait). **Answer** gets the answer (a variable of the remote's Answer type), **Answered** whether it came: false when nobody answered in time (a warning naming the brick), when the server's On Client Invoked ran no Answer (then at once, not after the timeout), or when this machine isn't in a game with a server; Answer is then 0 / false / empty text / none. Offline or hosting, the game is its own server: its On Client Invoked runs at once, here.
- **Settings:** Remote (the project's Ask server remotes). **Inputs:** one row per value of the remote, `timeout: float = 5`. **Outputs:** `answer` (the remote's Answer type; `answer`), `answered: bool`. **Exits:** `next`.
- **When:** a question whose answer the player's machine needs before going on: can I buy this, what does it cost, give me my character. For news that needn't wait, Fire Server.
- **Problems:** in a Server script; in an object's event (Every frame, When touched, When drawn: it would hold up the world); no remote / an unknown one / one that isn't Ask server.
- **C:** like Fire Server's values, then `if (cb_net_invoke(timeout, file, brick)) { answer = cb_msg_int(); ... } else { answer = 0; ... }`. On the wire: ASK (remote, a request number, the values) and ANSWER (the request number, answered?, the value); the server sends the world's changes before the answer, so an object it made and answers is there.

#### `on_client_invoked`: On Client Invoked
- **What:** an event: runs on the server when a player's machine asks this remote (Invoke Server); its values are variables, with `sender` (the asking player). An **Answer** brick in its chains sends the answer back; only the first counts, and if none runs, an empty answer goes back when the chains end (Answered false at the asker). Questions are queued like remotes: they run after the world's changes that came before them.
- **Settings:** Remote (Ask server ones). **Inputs it gives:** the remote's values, `sender: int`. **Exits:** `out`.
- **Where:** a plain script, not a Client one. Check the values first: any client can ask anything.
- **Problems:** a Client script; a remote that isn't Ask server.

#### `answer`: Answer
- **What:** sends the answer to the question its On Client Invoked chain is answering, to the asking machine only (Roblox's RemoteFunction's return value). The chain goes on after it; a second Answer to the same question is ignored.
- **Inputs:** `value` (the remote's Answer type; an int fits a float answer; blank for an object: none). **Exits:** `next`.
- **Problems:** outside an On Client Invoked chain; a value of another type.
- **C:** `cb_answer_begin(); cb_msg_put_int(value); cb_net_answer(file, brick);`

#### `ownership`: Ownership
- **What:** a family: **Give To** (a node becomes a player's, with what's under it, on every machine; blank player: no one's again; not in Client scripts; a Client Script object inside it runs on that player's machine) · **Owner** (the player it belongs to, its own or its nearest parent's: 0 when no one's or they left) · **Mine?** (this machine's player's; offline and on a host, no one's things count as yours) · **Owned by** (the nodes given to a player: a Node list, e.g. their Hero, to remove them when they leave).
- **Settings:** Do. **Inputs:** `object` (Give To, Owner, Mine?), `player: int` (Give To, Owned by). **Output:** `result` (Owner: an int; Mine?: a bool; Owned by: a Node list).
- **When:** a player's character, their items; a client checking whether something is theirs to show (Mine?); clearing up after Player Left (Owned by, Destroy).

#### `player`: Player
- **What:** a family about players (numbers): **Me** (this machine's player; 0 on a dedicated server; not in Server scripts) · **Player name** (unique in the game: a second `ada` is `ada_2`; `--name`, else the computer's user name) · **Is me** · **In game** (a number that's a player here now) · **Players** (every player: an `int list`, in the order they joined).
- **Settings:** Do. **Inputs:** `player: int` (Name, Is me, In game). **Output:** `result`: an int, a string, a bool or an int list.
- **A blank player** is the owner of what the script is in (Give To), else this machine's player, so a Client script needn't say which. A Server script must say which (it serves every player), unless it's a Script object's start or a class's method (then the object's owner).
- **Problems:** Me in a Server script; a blank player in a Server script's event or function.
- **When:** showing names and scores, checking who something is about.

### 4.7 Logic

#### `compare`: Compare
- **What:** compares A with B into a bool.
- **Settings:** Comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`. **Inputs:** `a: Anything` (variable), `b: Anything = 0`. **Output:** `result: bool` (`same`).
- **When:** keeping a comparison for later or for Logic; for a branch use If directly. Strings compare by text.

#### `logic`: Logic
- **What:** And (both true), Or (either), Not (the opposite).
- **Settings:** Operation. **Inputs:** `a: bool` (variable), `b: bool = true` (when And / Or). **Output:** `result: bool` (`both`).

### 4.8 Math

#### `formula`: Formula
- **What:** works out a value from a C expression you type: variable names, numbers, operators and `<math.h>` functions (`sin`, `sqrt`, `fmax`, `atan2`…).
- **Settings:** Formula (`a * 2 + 1`), Gives (int / float / bool / string). **Output:** `result`.
- **When:** anything longer than one operation (`fmax(-9.4, fmin(9.4, px))`, `(kd ? 1.0 : 0.0) - (ka ? 1.0 : 0.0)`). Struct fields work too (`p.x` for a vector3).

#### `math`: Math
- **What:** A + B, A − B, A × B, A / B or the remainder of A / B. A float on either side makes a float.
- **Settings:** Operation. **Inputs:** `a: Anything` (variable), `b: Anything = 1`. **Output:** `result` (`sum`).
- **Notes:** int / int is a whole-number division (7 / 2 = 3).

#### `math_func`: Math Function
- **What:** a `<math.h>` function of X: sqrt, sin, cos, tan, fabs, floor, ceil, round, exp, log, log10, pow (X to the power of Exp).
- **Inputs:** `x: float = 0`, `exp: float = 2` (when pow). **Output:** `result: float`.
- **Notes:** angles are in radians.

#### `minmax`: Min / Max
- **What:** the smaller or the larger of A and B.
- **Settings:** Which (min / max). **Inputs:** `a`, `b: Anything = 0`. **Output:** `result`.
- **When:** clamping a value (Min then Max).

#### `random`: Random Int
- **What:** a random whole number from Min to Max, both included.
- **Inputs:** `min: int = 1`, `max: int = 100`. **Output:** `result: int` (`r`).
- **Notes:** `--seed N` makes the numbers repeat run to run (tests).

#### `vector`: Vector
- **What:** a family for `vector3` values (3D points and directions). Make one from X, Y, Z; Split one into its parts; Add / Subtract two; Scale by a factor; its Length; Normalize (length 1; a zero vector stays zero); the Distance between two; Lerp (the point T of the way from A to B); Dot and Cross products.
- **Settings:** Do; Size: 3D (vector3s) or 2D (vector2s: no z; Cross gives a float).
- **Inputs:** `x`, `y`, `z: float = 0` (Make); `a: vector3` (the rest); `b: vector3 = 0, 1, 0` (Add, Subtract, Distance, Lerp, Dot, Cross); `factor: float = 2` (Scale); `t: float = 0.5` (Lerp).
- **Outputs:** `result` (`v`): a vector3, or a float for Length / Distance / Dot; `x`, `y`, `z` (Split).
- **When:** movement (direction × speed × frame time), distances (picking up a gem), cameras that follow (`pos + (0, 7, 9)`). Variable (Add) adds a vector3 too.

### 4.9 Text

#### `text`: Text
- **What:** a family for text.
  - **Join** Text + More · **Format**: fills each `{}` in the Format setting with First, Second, Third, Fourth in order (any type: `"Gems: {}  Time: {}"`) · **Length** · **Substring** (from Start, Length characters) · **Find** (position of What, −1 when it's not there) · **Replace** every What with With · **Upper case** / **Lower case** · **Trim** (spaces at both ends) · **Split** by Separator into a string list · **Join list** (a string list, with Separator) · **To text** (any value) · **To int** / **To float** · **Starts with** / **Ends with** What (bool).
- **Settings:** Do; Format (when Format).
- **Inputs:** `text: string`, `more: string`, `start`, `length: int`, `what`, `with`, `separator: string`, `list` (a string list), `value`, `first` … `fourth: Anything`, each shown for the operations that use it.
- **Output:** `result`: a string, an int (Length, Find, To int), a float, a bool or a string list (Split).
- **When:** building messages and HUD lines (Format), parsing input (Split, To int), cleaning text.
- **Problems:** a list, map or record in a Format (print it, or format its parts); more than 4 `{}`.

### 4.10 Lists, Maps & Records

#### `list`: List
- **What:** a family for lists (one type each). **Make** a new, empty list Of a type · **Add** to its end · **Insert** at an index · **Get** / **Set** the item at an index (from 0) · **Remove** one · **Length** · **Find** a value's index (−1: not there) · **Contains** · **Clear** · **Sort** (numbers and text) · **Reverse**.
- **Settings:** Do; Of (when Make: any type, records too).
- **Inputs:** `list` (variable), `value: Anything = 0` (Add, Insert, Set, Find, Contains), `index: int = 0` (Insert, Get, Set, Remove).
- **Output:** `result` (`items`): the list (Make), an item (Get), an int (Length, Find), a bool (Contains).
- **When:** collections: scores, enemies' positions, lines of a file.
- **Notes:** a wrong index stops the program: `[error] main.cbricks brick 7: no item at index 5 (the list has 3 items)`. Lists are shared: Variable (Set) `b = a` makes both names one list.

#### `map`: Map
- **What:** a family for maps (text key → value, one value type). **Make** a new, empty map Of a type · **Set** a key's value (adds the key or changes it) · **Get** a key's value · **Get or** (its value, or Default when the key isn't there) · **Has** key · **Remove** a key · **Count** · **Keys** (a string list) · **Values** (a list), both in the order keys were added · **Clear**.
- **Settings:** Do; Of (when Make).
- **Inputs:** `map` (variable), `key: string = name`, `value: Anything = 0` (Set), `default: Anything = 0` (Get or).
- **Output:** `result` (`table`).
- **When:** looking things up by name: settings, inventories, word counts.
- **Notes:** Get on a missing key stops the program and names the brick (`no key "ghost" in the map (it has 3 keys)`); use Has or Get or when it may be missing. Remove of a missing key does nothing. Maps are shared like lists. Lookups are hashed (fast for many keys).

#### `record`: Define Record
- **What:** a record type (a C struct): a name and named fields, each of a type (other records, lists and maps too; a list or map of itself, but not itself). Every script can use it. A declaration: no wires.
- **Settings:** Name (`Point`), Fields (name + type; `x float`, `y float`).
- **When:** grouping values that belong together (a player's name, score and tags).

#### `make_record`: Make record
- **What:** a new record of a type: number fields 0, text `""`, lists and maps ready to use.
- **Settings:** Record. **Output:** `result` (`item`), of that record's type.

#### `field`: Record field
- **What:** reads one field of a record variable (Get) or changes it (Set). It works on **objects** too: their fields, their parent classes' included (inside a class's own methods, use the fields by name instead).
- **Settings:** Mode (Get / Set), Field (a dropdown of the record's fields).
- **Inputs:** `record` (a record or object variable), `value: Anything = 0` (Set). **Output:** `value` (Get).
- **Notes:** records are values: a record taken from a list is a copy; change it, then List (Set) it back.

### 4.11 Program

#### `args`: Program Arguments
- **What:** what the program was started with: how many arguments (Count), one by position (At index, from 0), the value of `--name=value` or `--name value` (Option), or whether `--name` was given (Flag).
- **Settings:** Get. **Inputs:** `index: int = 0` (At index), `name: string = name` (Option, Flag). **Output:** `result` (`arg`): int, string or bool.
- **Notes:** C-Bricks' own flags (section 6) are taken out first; after `--` everything is the program's. In the editor, Project Settings ▸ run arguments.

#### `quit`: Exit program
- **What:** ends the program at once with an exit code (0: success). When program ends still runs.
- **Inputs:** `code: int = 0`. **Exits:** none.

#### `read_file`: Read file
- **What:** reads a whole text file (a path from the project folder, or absolute) into a string; `""` when it can't be read.
- **Inputs:** `path: string = assets/hello.txt`. **Output:** `text: string`.
- **Notes:** Run starts programs from the project folder (`--cd`), so `assets/…` paths work there and in exported projects run from their folder.

#### `write_file`: Write file
- **What:** writes text to a file, replacing it (Write) or adding to its end (Append).
- **Settings:** Mode. **Inputs:** `path: string = output.txt`, `text: string`. **Output:** `ok: bool` (optional).

#### `file_exists`: File exists
- **What:** whether a file can be opened for reading.
- **Inputs:** `path: string`. **Output:** `result: bool` (`found`).

### 4.12 System

#### `sleep`: Sleep
- **What:** waits a number of milliseconds.
- **Inputs:** `ms: int = 500`.
- **When:** text animations, polling. (In a Game loop, don't: use the frame time.)

#### `env`: Environment variable
- **What:** an environment variable's text, `""` when it isn't set.
- **Inputs:** `name: string = HOME`. **Output:** `value: string` (`env_value`).

#### `run_command`: Run command
- **What:** runs a command in the system's shell and waits for it.
- **Inputs:** `command: string`. **Output:** `code: int` (its exit code; −1 where there's no shell, e.g. WASI).

#### `terminal`: Terminal
- **What:** controls the terminal with ANSI codes (Windows 10+ too): Clear screen, Color (the text that follows, or its background), Reset, Move cursor (row, column from 1, 1), Hide / Show cursor.
- **Settings:** Do; Color (16 colors, when Color); Background (when Color).
- **Inputs:** `row`, `column: int = 1` (Move cursor).
- **When:** text games and dashboards in a terminal. (The editor's Console shows colors too.)

### 4.13 Graphics (raylib, 2D)

Graphics bricks make windowed programs with [raylib](https://www.raylib.com) 5.5 (bundled). A project that uses one builds raylib in (the first build for a target takes a minute or two). They build for this computer, Windows (zig), macOS (on a Mac) and the Web (Emscripten); other targets are text-only.

#### `window`: Open window
- **What:** opens the program's window (and its sound) at a frame rate.
- **Settings:** **Escape closes** (on: raylib's way, Escape ends the Game loop; off: Escape is a key like any other, e.g. a pause menu: Arena's title menu).
- **Inputs:** `width: int = 800`, `height: int = 450`, `title: string = My game`, `fps: int = 60`.
- **When:** first, before any other graphics brick.
- **Notes:** if no window can open (no display, an OpenGL too old), it says so and exits with code 1. raylib's own log is turned down to warnings, so it doesn't mix with Print.

#### `game_loop`: Game loop
- **What:** runs the Frame chains once per frame until the window is closed (or Escape); then closes it and runs Done.
- **Exits:** `frame`, `done`.
- **When:** every game: read input, move things, then Clear, Draw.

#### `pause`: Pause game
- **What:** **Pause** / **Resume** the game, **Paused?**; **Set time scale** (0.5: half speed, 2: twice) / **Time scale**.
- **Offline**, Pause freezes the world: objects' Every frame and When touched, scripts' When frame starts / ends, Wait (Game info's Frame time is 0); the Game loop's own Frame chains, drawing, the UI and its clicks go on, so a pause menu works. Scripts (and classes) set to **Runs while paused** (the script's Properties, Godot's process mode Always) go on, with the real frame time.
- **In a network game** (hosting, a client, a server) Pause doesn't freeze the shared world: it's remembered (Paused? true, e.g. for a menu) and the world runs on.
- **The time scale** multiplies the world's frame time, offline and in a network game, where it's **the world's speed for everyone**: set where the rules run (a host, a server) and sent to every client (their Time scale and frame time follow); a client's Set time scale does nothing (a warning). Wait counts the world's time (slower, faster, stopped while paused offline).
- **What follows the world's time** (pause and time scale): objects' Every frame / When touched (Frame time), scripts' When frame starts / ends, Wait, **Shake Camera**. **What doesn't** (the real clock / the player's): Game info's **Time**, drawing and the UI, the Game loop's Frame chains (their Frame time is the world's, so scale what moves), music and sounds (they play on while paused). Sprite animations driven by Time keep running: count Frame time up instead to pause them.
- **Settings:** Do. **Inputs:** `scale: float = 1` (Set time scale). **Output:** `result` (Paused?: bool; Time scale: float). **Exits:** `next`.
- **When:** a pause menu (Arena's: Esc), slow motion, a fast-forward.
- **C:** `cb_pause(true / false)`, `cb_is_paused()`, `cb_set_time_scale(x)`, `cb_get_time_scale()`; `cb_frame_time()` is scaled; the network's SCALE operation carries it to clients.

#### `close_window`: Close window
- **What:** ends the Game loop as the window's close button does: the frame under way finishes (the rest of its chains run), then the Game loop closes the window and runs its Done. A Wait under way ends early; a dedicated server's windowless Game loop ends too. Open window forgets an earlier Close window.
- **Exits:** `next`.
- **When:** a Quit button or key, a game that's over, a test that should stop after some frames (instead of Exit program, so the Game loop's Done still runs).
- **C:** `cb_close_window()`; the Game loop is `while (cb_loop_go())`.

#### `clear`: Clear window
- **What:** fills the window with a color. **Inputs:** `color: string = RAYWHITE`.

#### `draw`: Draw
- **What:** draws a Rectangle, Outline, Circle, Line, Text, Texture or Sprite at x, y (pixels from the top left) in a color (for a Texture / Sprite: its tint, WHITE for none). **Rotation** (Rectangle, Text, Texture, Sprite): degrees clockwise, turned round the thing's middle (x, y stays its top-left when it isn't turned). **Sprite:** one cell of a sprite sheet: the texture cut into Columns x Rows equal cells, **Frame** counted from 0 along each row from the top-left (a frame past the last wraps round), drawn Scale times its cell's size; animate it by counting Frame up (e.g. `(int)(time * 8)`).
- **Settings:** Shape.
- **Inputs:** `x`, `y: int = 100`; `width`, `height: int` (Rectangle, Outline); `radius: float` (Circle); `x2`, `y2: int` (Line); `text: string`, `size: int = 20` (Text); `texture` (Texture, Sprite); `frame: int = 0`, `columns: int = 4`, `rows: int = 1`, `scale: float = 1` (Sprite); `rotation: float = 0` (Rectangle, Text, Texture, Sprite); `color: string = MAROON`.
- **When:** inside a Frame. After a Draw 3D, for HUD text on top. Inside a Draw 2D view, in the game's world coordinates.
- **C:** `cb_draw_rect` / `cb_draw_rect_lines` / `cb_draw_circle` / `cb_draw_line` / `cb_draw_text` / `cb_draw_texture`; turned or Sprite: `cb_draw_rect_turned`, `cb_draw_text_turned`, `cb_draw_sprite` (all in `cbricks_gfx.c`, drawn by the backend).

#### `view2d`: Draw 2D view
- **What:** draws its Draw chains through a 2D camera: the world point **Center** is put in the window's middle, everything **Zoom** times as big, the view turned **Rotation** degrees. Next runs after, back in window pixels.
- **Inputs:** `center: vector2 = 0, 0`, `zoom: float = 1`, `rotation: float = 0`.
- **Exits:** `draw`, `next`.
- **When:** a 2D game bigger than its window: Center = the player's position follows them; a HUD goes in Next. (The world's own 2D nodes use a Camera2D node instead.)
- **C:** `cb_begin_2d(center, zoom, rotation)` ... `cb_end_2d()` (the backend's `cb_be_begin_2d`).

#### `game_info`: Game info
- **What:** Frame time (seconds the last frame took), Time (seconds since the window opened), the window's Width / Height, FPS.
- **Settings:** Get. **Output:** `result` (`dt`): a float or an int.
- **When:** smooth movement: `speed × frame time` per frame. Animations: `sin(Time)`.

#### `load_texture`: Load texture
- **What:** loads an image (png, jpg, bmp…) from the project's files, to draw with Draw (Texture). After Open window.
- **Inputs:** `path: string = assets/player.png`. **Output:** `texture` (`image`).

#### `music`: Music
- **What:** streamed music (raylib's music streams: ogg, mp3, wav, flac, xm, mod), read a little at a time instead of loaded whole like a Sound: long songs, background loops.
- **Settings:** Do: Load (Loop: start again at its end; on by default), Play (from the start), Stop, Pause, Resume, Volume, Playing.
- **Inputs:** `path: string` (Load), `music` (the rest), `volume: float = 1` (Volume, 0 to 1). **Outputs:** `music` (Load; `song`), `result: bool` (Playing).
- **When:** after Open window. It plays while the Game loop runs (and during a Wait): the runtime feeds every playing stream each frame (`cb_music_update`). Print shows `music (12.5 s, looping)`. A dedicated server skips it.
- **C:** `cb_music_load`, `cb_music_play`, `cb_music_stop`, `cb_music_pause`, `cb_music_resume`, `cb_music_volume`, `cb_music_playing`.

#### `sound`: Sound
- **What:** loads a sound (wav, ogg, mp3) from the project's files, or plays one. After Open window.
- **Settings:** Mode (Load / Play). **Inputs:** `path: string` (Load), `sound` (Play). **Output:** `sound` (Load; `jump`).

### 4.14 3D

3D draws inside a **Draw 3D** block, seen from the camera. Shapes and meshes are lit by a fixed sun from above (one small shader: GLSL 120 for OpenGL 2.1 on Linux and a Raspberry Pi, 330 for 3.3 on Windows and macOS, 100 for the Web; a GPU that can't compile it draws them unlit, with a warning). y is up. The **mesh bricks** are Brickscript's (its *Mesh* section), working on a `mesh` variable instead of a MeshInstance3D node.

#### `camera3d`: Set camera
- **What:** where the 3D camera is (Position) and what it looks at (Target).
- **Settings:** Projection (Perspective / Orthographic).
- **Inputs:** `position: vector3 = 0, 8, 10`, `target: vector3 = 0, 0, 0`, `fov: float = 60` (the view's height: degrees in Perspective, world units in Orthographic).
- **When:** before Draw 3D; every frame to follow something (`eye = pos + (0, 7, 9)`, target `pos`).

#### `draw3d`: Draw 3D
- **What:** its Draw chains draw in 3D, seen from the camera. Next runs after, back in 2D.
- **Exits:** `draw` (grows: Draw 1, 2, … in order), `next`.
- **When:** inside a Game loop's Frame, after Clear. Put Draw shape bricks in its Draw chains, and HUD text after it.
- **Notes:** a Draw shape outside it draws in screen space (not detected).

#### `shape3d`: Draw shape
- **What:** draws in 3D: a **Box**, **Sphere**, **Cylinder** or **Plane** with its middle At and Size across (a sphere 1 across is 1 wide; a cylinder stands up; a plane faces up), turned Turn degrees round the up axis; a **Wire box**; a **Mesh** placed At, scaled by Size, turned, and tinted (WHITE: its own colors); a 3D **Line** from At to To; a **Grid** on the ground.
- **Settings:** Shape.
- **Inputs:** `mesh` (Mesh), `at: vector3 = 0, 0.5, 0`, `to: vector3 = 0, 2, 0` (Line), `size: vector3 = 1, 1, 1`, `turn: float = 0`, `lines: int = 20` and `spacing: float = 1` (Grid), `color: string = SKYBLUE`.
- **When:** inside Draw 3D. Ready shapes for quick things; meshes for anything you build.

#### `raycast`: Raycast
- **What:** the first Shape3D on a straight line From one point To another (Brickscript's Raycast). Shape3Ds count as their boxes (size, turned with their rotation and their parents'); a ray that starts inside a Shape3D doesn't hit it.
- **Inputs:** `from`, `to: vector3`, `ignore` (an object it passes through, with the objects under it: the shooter; blank: none).
- **Outputs (each optional):** `hit` (the Shape3D, none when nothing is hit), `point` (Hit point; To when nothing), `normal` (the face's direction; 0, 0, 0 when nothing), `distance` (from From; -1 when nothing).
- **Exits:** `hit` (Hit), `missed` (Nothing hit), `next`.
- **When:** shots (from the eye along the look direction), line of sight, the ground under something. Arena's shots: Raycast, As Enemy (or its Parent: the visor), Call method damage.

#### `can_see`: Can see
- **What:** whether a Shape3D sees another object (Brickscript's Can see): within Range, inside its View (degrees across around where it faces: its -Z turned by its rotation; 360: all round) and nothing in the way (a ray that hits the target or something under it).
- **Inputs:** `who`, `target` (objects), `range: float = 20`, `view: float = 120`. **Exits:** `seen` (Seen), `unseen` (Not seen), `next`.

#### `nearest`: Nearest object
- **What:** the object of a Class (or a subclass) in the world closest to a point (Brickscript's Nearest character, for any class): within Range (0: any distance), never Except and the objects under it.
- **Settings:** Class. **Inputs:** `from: vector3`, `range: float = 0`, `except` (an object). **Outputs:** `result` (that class; none when there's none), `distance` (-1 when none).

#### `move_collide`: Move and collide
- **What:** moves a Shape3D by Motion (world units) like a body: it stops at Shape3Ds whose `solid` field is on and slides along them, each axis in turn and swept (a big step can't jump through a wall). Its own box is its size (scaled) **not turned** (2026-11-07: a character turning can't grow into the wall beside it), the solids' boxes are the boxes around them turned. The objects under it don't block it; a solid it's already inside (put there) lets it move out on each axis, not deeper.
- **Inputs:** `part` (a Shape3D: Self in a Shape3D class), `motion: vector3`. **Output:** `blocked: bool` (something stopped it).
- **When:** players and enemies that mustn't walk through walls. (Built-in shapes don't move by themselves: an object's Every frame moves it.)

#### `shake_camera`: Shake Camera
- **What:** shakes the 3D view for a while, fading out (Brickscript's Shake Camera): it jolts what's drawn, not the Camera3D's fields. A new shake replaces one under way.
- **Inputs:** `strength: float = 0.2` (world units), `duration: float = 0.4` (seconds).
- **Time:** the shake follows the world's time (Pause game): paused offline it stands still, jolt and all, and carries on when resumed; at a time scale of 0.5 it lasts twice as long and jitters half as often.

#### `snapshot`: Snapshot
- **What:** what a Camera3D object sees, drawn now into an image of Width x Height: the world from the camera's position, target and fov (or only Subject and the objects under it), over the camera's sky, or over nothing (Transparent).
- **Settings:** Into: **File** (a PNG at Path) / **Texture** (a texture variable); Transparent.
- **Inputs:** `camera` (a Camera3D object variable), `width`, `height: int = 256`, `subject` (an object; blank: everything), `path: string = snapshot.png` (File).
- **Output:** `texture` (Texture) / `ok: bool` (File: whether it was saved).
- **When:** screenshots, portraits of a character (a camera close to it, Transparent), a minimap (a camera high above; Draw (Texture) it each frame), icons made by the game. After Open window. In the editor, a Camera3D's Properties take the same kind of snapshot without running the game (2.11).

#### `begin_mesh`: Begin mesh
- **What:** starts a new mesh in a mesh variable: forgets anything added since its last Begin / Finish. Then Add to mesh, then Finish mesh; until then it keeps showing what it had.
- **Output:** `mesh` (`mesh`): the variable (a new one, or the same one again to rebuild it).

#### `add_mesh`: Add to mesh
- **What:** adds to the mesh being built:
  - **Triangle** A B C: its front is the side its corners go round **clockwise** (as given, `(0,0,0) (1,0,0) (0,0,1)` faces up);
  - **Quad** A B C D, in order round its edge (two triangles, A B C and A C D);
  - **Shape** (Box / Sphere / Cylinder / Plane) with its middle At and Size across; a shape keeps its own shading (a sphere stays round in a Flat mesh).
- **Settings:** Kind; Shape (when Shape).
- **Inputs:** `mesh` (variable), `a`, `b`, `c: vector3`, `d: vector3` (Quad), `at`, `size: vector3` (Shape), `color: string = WHITE`.
- **When:** in loops to build terrain, buildings, characters (the Gem Collector's ground is 400 quads; its gem 8 triangles). Points are in the mesh's own space; Draw shape places it.

#### `finish_mesh`: Finish mesh
- **What:** builds what was added since Begin mesh into the mesh.
- **Settings:** Shading: **Flat** (every triangle its own face) or **Smooth** (corners in the same place and of the same color become one point, shaded round); Sides: **Both sides** (the backs show too) or **One side** (only the fronts: cheaper, for closed shapes).
- **Inputs:** `mesh` (variable).
- **Notes:** after Open window (it needs the graphics card); a Smooth mesh has at most 65535 points (a problem names the brick: use Flat, or split it).

#### `mesh_vertices`: Mesh vertices
- **What:** a finished mesh's points as a `vector3 list` (Get), or puts a changed list back (Set; its shading is worked out again).
- **Settings:** Mode (Get / Set). **Inputs:** `mesh` (variable), `value: a vector3 list` (Set). **Output:** `points` (Get).
- **When:** bending a mesh: Get, For each item, change it (Vector Split → Formula → Vector Make), List Add to a new list, Set. The Gem Collector lifts a flat grid into hills this way.
- **Notes:** a Smooth mesh has one point per corner place, so moving one moves every triangle at it; a Flat mesh has a point per triangle corner. Set needs exactly as many points as the mesh has (`got 1 points for a mesh of 81 points`). Positions only (no Colors mode: colors are set when adding).

### 4.15 Debug / Testing

#### `assert`: Assert
- **What:** stops the program with exit code 1 and a message naming the brick when the comparison doesn't hold.
- **Settings:** Compare (as If). **Inputs:** `a: Anything` (variable), `b: Anything = 0`, `message: string = should hold`.
- **When:** checking what must be true, in tests and while developing.

#### `debug_log`: Debug log
- **What:** prints a value to stderr, only when the program runs with `--verbose` (or `-v`).
- **Inputs:** `value: Anything = here`.
- **When:** diagnostic output you don't want in normal runs.

### 4.16 Advanced

#### `call_c`: Call C function
- **What:** calls a C function: from the C library, or from a `.c` file of your own in the project (every `.c` / `.h` in the project folder is compiled in).
- **Settings:** Function (its name), Gives back (a type or void), Inputs (name + type), Header (`"mylib.h"` or `<time.h>`; blank: the call is declared from Inputs / Gives back).
- **Inputs:** one per Input. **Output:** `result`.
- **When:** something the bricks don't do: your own C, a library function.

#### `raw_c`: C Code
- **What:** C statements, written as they are. The graph's variables can be used by name.
- **Settings:** Code.
- **When:** a last resort for one-off C; prefer bricks (C Code isn't checked until the compiler runs; its errors still land on the brick).

#### `include`: #include
- **What:** adds an `#include` line to the script's file. A declaration: no wires.
- **Settings:** Header (`<string.h>`).

---

## 5. Examples

| Example | Shows |
| --- | --- |
| Hello World | When program starts, For range, Print |
| FizzBuzz | For range, If with C expressions (`i % 15 == 0`), growing exits |
| Functions Factorial | Define Function, recursion, Return, When program ends |
| Guess the Number | Random Int, While, Read input |
| Read Your Name | Read input (line), Print |
| Arguments And Files | two scripts calling each other's function, Program Arguments, Read file, assets, a C Code brick, Debug log, Assert |
| Bouncing Ball | 2D graphics: Open window, Game loop, Clear, Draw, Input, Game info, Text |
| Gem Collector | 3D: Set camera, Draw 3D, Draw shape, all the mesh bricks, Vector, Constants, functions, Format; WASD, collect gems before the time runs out, R to play again |
| Arena | A networked first-person shooter (single-player offline; H hosts on port 7000, J joins 127.0.0.1:7000; or `--host` / `--server` / `--join ... --name`). Each player gets a **Fighter** (`scenes/fighter.cbscene`: Player Joined, Instance scene, Give To) holding two Script objects (user's design): **Input** (a LocalScript: on its owner's machine only, it reads mouse look (Mouse mode Captured, Mouse Movement) and WASD (Key Direction), sends them every frame with Fire Server `input`, and runs that player's camera (their own yaw / pitch at once), HUD and kick, hiding its own body) and **Brain** (a Script: where the rules run, On Client Fired keeps each player's input on their Fighter, When frame starts moves every Fighter (Move and collide against solid walls and crates), shoots (Raycast, Call method damage, Sparks the world copies to everyone) and brings caught players back after 3 s). Enemies chase the nearest Fighter (Nearest object) and bite (a `hurt` method: Fire Clients One player shakes the bitten player's camera). Environment fog. **The HUD is UI** (2026-11-07): a Stats Panel with the score Label and a health Bar, the crosshair Label in the middle, a Message Panel counting down while caught; the Input script sets them each frame. **A title menu** (2026-11-08): a Title Panel with a Menu VBox of Buttons (Play, Host, Join, Quit; When button clicked in main: no class needed), shown at the start and on **Esc** (Open window's Escape closes is off), the mouse captured only in the game, Host / Join disabled in a network game; started with `--join` / `--host` it goes straight into the game. **Tab** shows the scoreboard: a Panel, a VBox of HBox rows (name, score, health) sorted by score (keys `score * 100 + player`, List Sort + Reverse). **Game feel:** a hit marker over the crosshair when your shot lands (the server's `hit` remote to the shooter only; red: a kill), a red flash when bitten (`hurt`), a health bar floating over each enemy (a thin Shape3D child the server sizes: synced). Tests: `arena_menu` (starts on the menu; a `--click` on Play), `--scores` shows the scoreboard in tests. Tests: `arena_shot`, `arena_auto` (single-player, `--autofire`), `arena_net` (a dedicated server and two clients) |
| Net Gems | A network game for 2-5 players (offline: alone; H hosts on port 7000, J joins 127.0.0.1:7000; or `--host 7000`, `--server 7000`, `--join 127.0.0.1:7000 --name ada`), and the do-it-yourself starter player: the server's Player Joined instances `scenes/hero.cbscene` (a Runner with a Welcome Client script) and Gives it To the player (a lane and a colour by their number); the Welcome runs on its owner's machine; a Runner moves with Player Direction (blank: its owner) on the server; Gems score (a Synced score), Fire Clients `picked` / `winner` (first to 10; scores reset); each machine's camera follows its own runner and its HUD lists everyone's score (Text2Ds in the group `local`); Player Left removes what they own (Owned by) |
| Gem Hunt | Objects: a world file (camera, sun, floor, walls in a Spatial3D, the player, a HUD Text2D), a Player class (Every frame: WASD, the camera follows, the HUD), a Gem class (spins; When touched by the Player: Call method add_point, then jumps elsewhere); main is three bricks |

---

## 6. Program flags

Every program built with C-Bricks understands these (`--help` lists them). Everything else reaches the Program Arguments brick.

| Flag | Does |
| --- | --- |
| `-h`, `--help` / `--version` | usage / name and version |
| `--trace` | prints each brick as it runs (`[trace] main.cbricks:4`, stderr) |
| `-v`, `--verbose` | shows the Debug log bricks' output |
| `--seed N` | Random Int gives the same numbers every run |
| `--input FILE` / `--output FILE` | stdin from a file / stdout to a file |
| `--cd DIR` | changes to DIR first (where its assets are) |
| `--max-steps N` | stops with exit code 124 after N bricks (catches endless loops) |
| `--time` | CPU / wall time and bricks run, at exit |
| `--debug FILE` / `--break S:B` | the debugger: pause at breakpoints (`main.cbricks:7`, several with commas), read commands from FILE |
| `--` | passes the rest to the program as it is |
| `--host PORT` / `--server PORT` | (network projects) host a game with your player as player 1 / run a dedicated server (no player of its own, no window) |
| `--join ADDRESS:PORT` / `--name NAME` | (network projects) join a game / your player's name (default: your user name) |
| `--click X:Y:T` | (graphics) a left click at window pixel X, Y, T seconds after the window opened (pressed one frame, let go the next), instead of the mouse; the pointer waits at the next click's place meanwhile (tests; several with commas, e.g. `160:100:0.2,40:22:0.4`) |
| `--press KEY:FROM:TO` | (network projects with Player Key / Player Input) hold KEY from FROM to TO seconds after the start, instead of the keyboard (tests; several with commas, e.g. `D:0.5:1.5,SPACE:1:1.2`) |

**Debugging from a terminal:** `./prog --debug cmds.txt --break main.cbricks:3`, then append commands to `cmds.txt`: `step` (into), `next` (over), `out`, `continue`, `pause`, `stop`, `break S:B`, `clear S:B`. Each pause takes the next resume command (`step` / `next` / `out` / `continue`) and leaves the rest for the next pause, so a file written beforehand replays a whole session. Exit codes: 0 done, 1 an Assert / a runtime error (wrong list index, missing map key; `--host` / `--server` / `--join` that couldn't start), 124 `--max-steps`, 130 `stop`.

---

## 7. Targets and building

| Target | Built with |
| --- | --- |
| This computer | the C compiler found here (cc / gcc / clang / zig / tcc) |
| Linux x86_64, x86, ARM64 (Raspberry Pi 64-bit), ARMv7 (Pi 32-bit), RISC-V 64, POWER, IBM Z, LoongArch, MIPS | zig (static), or a distro cross-gcc |
| Windows x86_64, x86, ARM64 | zig, or MinGW |
| macOS arm64, x86_64 | zig (text programs), or clang on a Mac |
| FreeBSD x86_64 / ARM64, NetBSD x86_64 | zig |
| Android ARM64 (command-line) | the NDK |
| Web (HTML + WASM) | Emscripten (`emcc`); Run serves it with `emrun` |
| WebAssembly WASI | zig |
| MS-DOS (386+, 32-bit protected mode) | DJGPP (`i586-pc-msdosdjgpp-gcc`); Run opens it in DOSBox-X. Text, 2D, the UI, sound and 3D |

Graphics (2D and 3D) build for this computer, Windows and the Web from here, and macOS on a Mac.

**What a target can do** (2026-11-08): a brick or scene object the picked Target can't do is a problem naming it ("Fire Server (node 3): MS-DOS (DJGPP, 386+) can't do networking yet ..."), and Build stops; Build All skips such targets. Graphics and 3D work on raylib's platforms above and on MS-DOS; networking works on every target with sockets (MS-DOS included).

**Graphics backend** (2026-11-09; **Project Settings ▸ Graphics ▸ Backend**, `[graphics] backend` in project.cbproj): what draws and plays a graphics project. *Automatic* (the default) follows the Target: the MS-DOS software renderer for MS-DOS, raylib for everything else. *raylib* and *MS-DOS software renderer* name one; a backend the Target can't use (the MS-DOS renderer for a native build, raylib for MS-DOS) is a problem in Problems ("Graphics backend: ...") and Build stops. The dialog says which backend the current Target will use, and shows the **MS-DOS screen** row only when that backend is the MS-DOS one. The dialog has sections (Project, Run, Graphics); the list of program flags is folded under Run.

**MS-DOS** (the Target "MS-DOS (DJGPP, 386+)"; Run opens DOSBox-X):
- **Works:** everything text (printing, input, files, arguments, ...), and **2D graphics and the UI**: Open window, the Game loop, Draw (rectangles, outlines, circles, lines, text, textures, sprite sheets, turned), Draw 2D view, the world's 2D objects (Shape2D, Text2D, Sprite2D, Camera2D) and the UI classes (Panel, Label, Button, Bar, Image, VBox, HBox), Input / Mouse (keys, buttons, position, wheel), Pause game, Load texture (PNG).
- **Sound:** a **Sound Blaster** (found by the BLASTER variable or the usual ports; DOSBox-X has one), mixed by software: up to 16 sounds at once plus every playing Music, as one 22 kHz, 8-bit, mono stream through DMA. Sound and Music take **WAV, OGG and MP3** files: building for MS-DOS **converts every audio file of the project** (the editor builds a small converter, `scripts/tools/audioconv.c`, once with this computer's C compiler, and runs it on each file that changed) to an 8-bit, mono, 22 kHz WAV in `audio/` beside the program (`audio/a0000001.wav`...: the program maps each brick's path to its file, so the bricks keep their `assets/theme.ogg`), and the program plays those. **Ship the `audio/` folder with the `.exe`.** A Music is held whole in memory (22 KB a second), so keep songs short. Without a Sound Blaster nothing is heard (Playing? still follows the clock). Run the program with `-v` to see what the card played.
- **Two channels: sound effects are PCM, music can be FM** (the OPL2 / OPL3 chip of an AdLib or Sound Blaster, port 388h). A **Music** whose project has an **FM music file** (`.mid` / `.midi`, `.imf`, `.wlf`, `.dro` or `.vgm`) with the same name beside it plays that on the FM chip: `assets/theme.ogg` with `assets/theme.mid` next to it plays the MIDI (so the same bricks give FM music on MS-DOS and the recording elsewhere); naming an FM file in Music Load plays it too. **Sound** always plays PCM. FM files are note data for the chip, so recorded audio can't become one (the editor converts what it can: PCM). IMF: id Software's, 560 Hz (`.wlf`: 700 Hz); DRO: DOSBox raw OPL v1 / v2; VGM: the YM3812 / YM3526 / Y8950 / YMF262 writes. **MIDI** (format 0 or 1, tempo changes followed): the notes are turned into the chip's voices when the file loads, with the **DMXOPL** instrument bank (General MIDI, 128 melodic and 47 percussion instruments; MIT licence, `thirdparty/dmxopl`; the build puts it beside the program as `audio/genmidi.op2`; a file named `genmidi.op2` anywhere in your project replaces it): 9 voices (18 on an OPL3: the oldest note is taken when they're all busy; a two-voice instrument takes two when there are spare), pitch bend (±2 semitones), volume, expression, program changes and the drum channel (10); not the sustain pedal, panning, modulation or SMPTE-timed files. One FM song plays at a time (a new one replaces it); Volume scales the carriers' levels; Pause silences the chip and Resume sets it up again from the file; no OPL chip: silent (Playing? follows the clock). The build copies the FM files to `audio/` with the converted PCM: ship it with the `.exe`.
- **3D:** a software triangle renderer (no GPU): every 3D brick and the world's Spatial3D scene work. Shapes and meshes are triangles drawn with a depth buffer, **Gouraud lighting** from the Light3D sun plus ambient (the same formula as raylib's shader, back faces lit from their own side), Environment **fog** per pixel, near-plane clipping, back-face culling, lines / grids / wire boxes, Camera snapshots and Draw 3D's views; the 256 colours are hidden by ordered dithering. Expect it to be slow on a real 386 / 486 (it's meant for a Pentium-class PC or DOSBox-X's cycles): keep scenes small and use VGA 320 x 200 for speed (in DOSBox-X on a Raspberry Pi the Gem Collector example takes minutes to reach its 40th frame: the scene is large and the emulator's FPU is slow; it was not timed on real hardware). Not here: textures on 3D meshes (flat colours), Snapshot's transparent background.
- **Networking:** UDP through **Watt-32** (BSD sockets for DJGPP, `thirdparty/watt32`; a program that uses the network links it, nothing else does). A DOS PC needs a **packet driver** for its network card loaded before the program (`thirdparty/pktdrvr/NE2000.COM` is Crynwr's for NE2000 cards) and a `WATTCP.CFG` beside the program (`my_ip = dhcp` is the default the build writes; set `my_ip`, `netmask`, `gateway` for a fixed address). **Run** in DOSBox-X sets all that up itself: an emulated NE2000 on DOSBox-X's built-in NAT (the program is 10.0.2.15; the host is **10.0.2.2**, so `--join 10.0.2.2:PORT` reaches a server running on the same computer), the packet driver loaded, DHCP. A DOS program can also host: DOSBox-X's `[ethernet, slirp] udp_port_forwards = HOST:GUEST` sends a host port into it. Tested both ways (the runner's `dos_net` check: a DOS client joins a native server, a native client joins a DOS server). Not tested on real hardware or a real packet driver.
- **The screen** is a 256-colour VGA / VESA mode, set in **Project Settings ▸ MS-DOS screen**: *Auto* (the smallest of the three that fits the Open window's size), *VGA 320 x 200* (every PC and emulator), *VESA 640 x 480* or *800 x 600* (a card with VESA 2.0 and a linear frame buffer; the program says so if there's none). The screen is that size whatever Open window asks for: Game info's width / height and the UI's anchors follow it. Colours are the nearest of a 216-colour cube and 40 greys, so a gradient bands; text is the video card's own 8 x 16 font (size = its height).
- **Keys and mouse:** the letters, digits, space, Enter, Tab, Backspace, Escape (closes, unless Open window's Escape closes is off), the arrows, F1-F5, Shift and Ctrl; the mouse through the DOS mouse driver (DOSBox-X has one), drawn as an arrow unless Mouse mode hides it; the wheel through the CuteMouse wheel call (AX=11h / AX=3's BH) when the driver has one. Ctrl+C closes the window like Escape.
- **File names are 8.3** on DOS (`player.png`, `ui_conta.png`: longer names are cut to eight letters: `ui_containers.png` is `UI_CONTA.PNG`), so keep a project's asset names short and unique. Its `.exe` carries CWSDPMI (`thirdparty/cwsdpmi`), so it runs on plain DOS as well as in DOSBox-X.
- **Tested** in DOSBox-X (**keys and mouse for real**, by the runner's `dos_input` check: DOSBox-X on a virtual display, `xdotool` sending A, Space, Up, Enter, Shift, F5, Ctrl alone and A + Up together, pointer moves, left and right buttons, the program's own Input and Mouse bricks printing what they saw; **the wheel isn't**: SDL on that display drops the synthetic wheel clicks, so only the driver call's answer was seen; VGA, VESA 640 x 480 and 800 x 600; the draw_2d and ui_containers cases' screenshots; the pause and time-effects cases' lines; sound: WAVs, an OGG and an MP3 played through the emulated Sound Blaster's DMA, the mix checked for level; FM: IMF, DRO and VGM files played on the emulated OPL3: neither heard, and the DRO reader is written from the format's description and checked only against files this project made): not on a real PC.

---

## 8. The generated C (what's in `.build/src/`)

| File | Holds |
| --- | --- |
| `<script>.c` | one per script: its functions (and `main` in the script with When program starts), each line marked `// brick <id>`, `CB_TRACE` before every brick, a `cb_frame` of variables per function for the debugger |
| `cbricks.h` | every function's prototype (so scripts call each other), records' typedefs, Constants (`#define`), the runtime's API |
| `cbricks_runtime.c` | the program's name, scripts and help, then the runtime (`scripts/runtime/cb_runtime.c`: flags, arguments, files, asserts, trace, the debugger; `cb_data.c`: memory, lists, maps, text, vectors, printers, system) |
| `cbricks_data.c` | each record's maker and printer (projects with records) |
| `cbricks_gfx.c` | graphics projects: colors, the graphics bricks' functions, the world's drawing, the UI, the camera (`scripts/runtime/cb_gfx.c`; no graphics library in it) |
| `cbricks_backend.c` | graphics projects: the one file that talks to a graphics library (MS-DOS builds get `scripts/runtime/cb_be_dos.c`, with stb's `stb_image.h` / `stb_image_write.h`): the window, input, drawing, textures, sound, music, the 3D renderer (lit shader, shapes, meshes, lights) (`scripts/runtime/cb_be_raylib.c`: raylib; the `cb_be_*` functions declared in `cbricks.h` are what another backend, e.g. MS-DOS, provides) |
| `cbricks_socket.c` | network projects: one UDP socket and a steady clock (`scripts/runtime/cb_socket.c`; Winsock / BSD sockets, its own file so the OS headers stay apart); the protocol, roles and players are appended to `cbricks_runtime.c` (`cb_net.c`) |
| your `.c` / `.h` | copied as they are |

Portable hosted C99, standard library only (plus `chdir`, and sockets in network projects, behind platform guards; Windows builds link `ws2_32`), MSVC-friendly; it compiles warning-free with `-std=c99 -Wall -Wextra -pedantic`.

---

## 9. Working on C-Bricks

- **A brick** is an entry in `NodeDefs.DEFS` (`scripts/node_defs.gd`): `title`, `cat` (the palette group), `kind` (`event`, `action`, `declare`, `reroute`), `args` (`[name, port type, default, starts as a variable, shown_when]`), `outs` (`[name, port type, default variable, title, shown_when]`), `fields` (`[name, kind, default, options, title, shown_when]`), `groups` (its exits; the last runs after the brick), `mode` / `mode_titles` for families, `"graphics": true` for raylib bricks, and `desc` (shown in Properties).
- **Its C** comes from `scripts/codegen.gd` (`_stmt`, or `_graphics` for graphics bricks; result types in `_out_type`), its summary on the canvas from `scripts/editor/brick_view.gd` (`summary`), and runtime helpers from `scripts/runtime/*.c` (declared in `ProjectBuild.header`).
- **Adding a brick:** the def, its C, its summary, its line(s) in its palette group's suite (`tests/make_suites.py`: every brick and mode, checked by the runner's `coverage`), and an entry here. `tests/run_tests.gd` fails when a brick has no `#### \`type\`` heading in this file, or isn't in its suite.
- **Watches** are `scripts/watches.gd` (`CBWatches`): a paused variable's text read back by its type, then Godot's `Expression` over them (the runner's `watches` check tests both).
- **Tests:** `godot --headless --path . -s res://tests/run_tests.gd` (the cases), `godot --path . --resolution 1600x900 -s res://tests/ui_check.gd` (the real window, with screenshots). `DEBUG.md` has the process.
