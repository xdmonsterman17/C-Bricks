class_name NodeDefs
extends RefCounted
## Every C-Bricks brick (node type). Bricks are C, not Brickscript's game bricks,
## but they follow Brickscript's rules:
##   - Only execution wires. Values travel through variables.
##   - args  : [name, type, default]   each input is a typed value OR a variable
##   - outs  : [name, type, default_variable]   a result, kept in a variable
##   - fields: [name, kind, default, options, title]   settings
##   - groups: execution exits in order. The LAST runs after the brick itself;
##             the others are branches it controls (If's True / False, a loop's
##             Loop body). Every exit grows: wiring its spare adds another, and
##             the chains on one exit fire in order, each to its end.
##   - kind  : "event" (starts chains, numbered outputs), "action", "declare"
##             (no wires), "reroute" (only bends a wire)

enum { EXEC, INT, FLOAT, BOOL, STRING, ANY, LIST, RECORD, MAP, VEC3, OBJECT, VEC2 }

const TYPE_NAMES := ["exec", "int", "float", "bool", "string", "any", "list", "record", "map", "vector3", "object", "vector2"]
const TYPE_TITLES := ["Exec", "int", "float", "bool", "string", "Anything", "a list", "a record", "a map", "vector3", "an object", "vector2"]
const TYPE_HINTS := {
	"int": "A whole number (C int), e.g. 3. Also takes a C expression, e.g. i % 15",
	"float": "A number with decimals (C double), e.g. 2.5. Also takes a C expression",
	"bool": "true or false. Also takes a C condition, e.g. guess != secret",
	"string": "Text (const char*). Escapes like \\n and \\t work",
	"vector3": "A 3D point or direction: x, y, z (e.g. 0, 1.5, -2). Each part may be an expression",
	"vector2": "A 2D point or direction: x, y (e.g. 100, 40). Each part may be an expression",
}
const TYPE_COLORS := [
	Color(0.92, 0.92, 0.92),   # exec
	Color("4fc3f7"),           # int
	Color("81c784"),           # float
	Color("e57373"),           # bool
	Color("ffb74d"),           # string
	Color("b0bec5"),           # any
	Color("ce93d8"),           # list
	Color("80cbc4"),           # record
	Color("f48fb1"),           # map
	Color("fff176"),           # vector3
	Color("ffab91"),           # object
	Color("dce775"),           # vector2
]
const C_TYPES := {"void": "void", "int": "int", "float": "double", "bool": "bool", "string": "const char*"}
const VALUE_TYPES := ["int", "float", "bool", "string"]
const RETURN_TYPES := ["void", "int", "float", "bool", "string"]

## Exit display names (Brickscript's exit_titles).
const EXIT_TITLES := {"seen": "Seen", "unseen": "Not seen", "hit": "Hit", "missed": "Nothing hit", "draw": "Draw", "next": "Next", "loop": "Loop body", "done": "Done", "true": "True", "false": "False", "out": "Output"}

## If / While comparisons (Brickscript's If operators that fit C).
const COMPARE_OPS := ["is true", "is false", "==", "!=", "<", "<=", ">", ">="]
const ONE_SIDED := ["is true", "is false"]
const TWO_SIDED := ["==", "!=", "<", "<=", ">", ">="]

## Arg spec: [name, type, default, starts_as_variable, shown_when {setting: [values]}]
const DEFS := {
	# ---------------------------------------------------------------- Events
	"start": {
		"title": "When program starts", "cat": "events", "kind": "event", "unique": true,
		"groups": ["out"],
		"desc": "The program's entry point: main(). Its outputs run in order, each chain to its end, before the next.",
	},
	"frame_start": {
		"title": "When frame starts", "cat": "events", "kind": "event", "graphics": true,
		"groups": ["out"],
		"desc": "Runs at the start of every frame of the Game loop, with dt (the frame's length in seconds), before the objects' Every frame (Godot's _process for the whole program: reading input, the frame's logic). Any plain script (not a class's); a Server script's runs where the game's rules run, a Client script's on players' machines. A windowless server runs it too.",
	},
	"frame_end": {
		"title": "When frame ends", "cat": "events", "kind": "event", "graphics": true,
		"groups": ["out"],
		"desc": "Runs at the end of every frame of the Game loop, with dt: after the objects have moved (Every frame) and touched, before the world is drawn. The place for a camera that follows something, or a HUD: no frame of lag. Any plain script (not a class's), gated by its Side like When frame starts.",
	},
	"exit": {
		"title": "When program ends", "cat": "events", "kind": "event", "unique": true,
		"groups": ["out"],
		"desc": "Runs when main() returns or exit() is called (atexit). Only Global variables are shared with the rest of the program.",
	},
	# ---------------------------------------------------------------- Flow
	"if": {
		"title": "If", "cat": "flow", "kind": "action",
		"fields": [["operator", "option", "is true", COMPARE_OPS, "Compare"]],
		"args": [["a", ANY, "", true], ["b", ANY, "0", false, {"operator": TWO_SIDED}]],
		"groups": ["true", "false", "next"],
		"desc": "Picks a path: compares A with B (or checks a bool) and runs the True or the False chains, then the Next chains either way.",
	},
	"while": {
		"title": "While", "cat": "flow", "kind": "action",
		"fields": [["operator", "option", "is true", COMPARE_OPS, "Compare"]],
		"args": [["a", ANY, "", true], ["b", ANY, "0", false, {"operator": TWO_SIDED}]],
		"groups": ["loop", "done"],
		"desc": "Runs the Loop body again and again while the comparison holds, checked before each round. The body must change what it compares. Done runs after.",
	},
	"wait": {
		"title": "Wait", "cat": "flow", "kind": "action",
		"args": [["seconds", FLOAT, "1"]],
		"groups": ["next"],
		"desc": "Pauses its chain for some seconds, then carries on (Brickscript's Wait). In a graphics program the window and the world keep running meanwhile (Every frame, touches, drawing; the Game loop's own Frame chains pause); in a text program it sleeps. Not inside an object's event (Every frame, When touched, When drawn).",
	},
	"for": {
		"title": "For range", "cat": "flow", "kind": "action",
		"args": [["from", INT, "0"], ["to", INT, "10"], ["step", INT, "1"]],
		"outs": [["index", INT, "i", "Index"]],
		"groups": ["loop", "done"],
		"desc": "Counts Index from From up to (not including) To, running the Loop body each time. Done runs after.",
	},
	"repeat": {
		"title": "Repeat N times", "cat": "flow", "kind": "action",
		"args": [["times", INT, "3"]],
		"outs": [["counter", INT, "", "Counter"]],
		"groups": ["loop", "done"],
		"desc": "Runs the Loop body a number of times. Counter (optional) counts from 0.",
	},
	"break": {"title": "Break", "cat": "flow", "kind": "action", "groups": [], "desc": "Inside a Loop body: leaves the loop at once; its Done runs next."},
	"continue": {"title": "Continue", "cat": "flow", "kind": "action", "groups": [], "desc": "Inside a Loop body: skips the rest of this round."},
	"reroute": {
		"title": "Reroute", "cat": "flow", "kind": "reroute",
		"groups": ["next"], "fixed": true,
		"desc": "A point on a wire, to bend it around other bricks. Nothing runs there. Double-click a wire to add one.",
	},
	# ---------------------------------------------------------------- Functions
	"function": {
		"title": "Define Function", "cat": "functions", "kind": "event",
		"fields": [
			["name", "line", "my_function", null, "Name"],
			["returns", "type_void", "void", null, "Gives back"],
			["params", "params", [["a", "int"]], null, "Inputs"],
		],
		"groups": ["out"],
		"desc": "A C function. Its chain runs when a Call Function calls it. Its inputs are variables inside it.",
	},
	"return": {
		"title": "Return", "cat": "functions", "kind": "action",
		"fields": [["gives", "option", "A value", ["A value", "Nothing"], "Gives"]],
		"args": [["value", ANY, "0", false, {"gives": ["A value"]}]],
		"groups": [],
		"desc": "Ends the function it's in at once, giving back the value (or nothing: just leave early).",
	},
	"call": {
		"title": "Call Function", "cat": "functions", "kind": "action", "dynamic": true,
		"fields": [["function", "func", "", null, "Function"]],
		"groups": ["next"],
		"desc": "Runs a function and keeps what it gives back. Picking the function gives this brick one row per input.",
	},
	# ---------------------------------------------------------------- Variables
	"var": {
		"title": "Variable", "cat": "variables", "kind": "action",
		"mode": "mode", "mode_titles": {"Get": "Variable (Get)", "Set": "Variable (Set)", "Add": "Variable (Add)"},
		"fields": [
			["mode", "option", "Set", ["Get", "Set", "Add"], "Mode"],
			["name", "var", "x", null, "Variable"],
			["scope", "option", "Chain", ["Chain", "Shared"], "Kind", {"mode": ["Set"]}, "new"],
		],
		"args": [["value", ANY, "0", false, {"mode": ["Set", "Add"]}]],
		"outs": [["copy", ANY, "copy", "Into", {"mode": ["Get"]}]],
		"groups": ["next"],
		"desc": "Reads a variable (Get, into the Output), puts a value in it (Set; a new name makes a variable typed like the value: Kind Chain (the default: only later bricks of its event or function, reset every run) or Shared (every event and function of the script, keeping its value: Brickscript's kinds)), or adds to it (Add: x += value).",
	},
	"formula": {
		"title": "Formula", "cat": "math", "kind": "action",
		"fields": [["expression", "line", "a * 2 + 1", null, "Formula"], ["type", "option", "int", VALUE_TYPES, "Gives"]],
		"outs": [["result", ANY, "result"]],
		"groups": ["next"],
		"desc": "Works out a value from a C expression you type, like (a + b) * 2. Use variable names, numbers, operators and <math.h> functions.",
	},
	"convert": {
		"title": "Convert", "cat": "variables", "kind": "action",
		"fields": [["to", "option", "int", ["int", "float", "bool"], "To"]],
		"args": [["value", ANY, "", true]],
		"outs": [["result", ANY, "converted"]],
		"groups": ["next"],
		"desc": "A C cast between number types.",
	},
	# ---------------------------------------------------------------- Math
	"math": {
		"title": "Math", "cat": "math", "kind": "action",
		"mode": "op", "mode_titles": {"Add": "Add", "Subtract": "Subtract", "Multiply": "Multiply", "Divide": "Divide", "Remainder": "Remainder"},
		"fields": [["op", "option", "Add", ["Add", "Subtract", "Multiply", "Divide", "Remainder"], "Operation"]],
		"args": [["a", ANY, "", true], ["b", ANY, "1"]],
		"outs": [["result", ANY, "sum"]],
		"groups": ["next"],
		"desc": "A + B, A - B, A × B, A / B or the remainder of A / B (Operation). A float on either side makes a float. Longer sums: Formula.",
	},
	"math_func": {
		"title": "Math Function", "cat": "math", "kind": "action",
		"fields": [["func", "option", "sqrt", ["sqrt", "sin", "cos", "tan", "fabs", "floor", "ceil", "round", "exp", "log", "log10", "pow"], "Function"]],
		"args": [["x", FLOAT, "0"], ["exp", FLOAT, "2", false, {"func": ["pow"]}]],
		"outs": [["result", FLOAT, "result"]],
		"groups": ["next"],
		"desc": "A <math.h> function of X (pow: X to the power of Exp).",
	},
	"minmax": {
		"title": "Min / Max", "cat": "math", "kind": "action",
		"mode": "op", "mode_titles": {"min": "Min", "max": "Max"},
		"fields": [["op", "option", "min", ["min", "max"], "Which"]],
		"args": [["a", ANY, "0"], ["b", ANY, "0"]],
		"outs": [["result", ANY, "result"]],
		"groups": ["next"],
		"desc": "The smaller or the larger of A and B.",
	},
	"random": {
		"title": "Random Int", "cat": "math", "kind": "action",
		"args": [["min", INT, "1"], ["max", INT, "100"]],
		"outs": [["result", INT, "r"]],
		"groups": ["next"],
		"desc": "A random whole number from Min to Max (both included).",
	},
	# ---------------------------------------------------------------- Logic
	"compare": {
		"title": "Compare", "cat": "logic", "kind": "action",
		"fields": [["op", "option", "==", ["==", "!=", "<", "<=", ">", ">="], "Comparison"]],
		"args": [["a", ANY, "", true], ["b", ANY, "0"]],
		"outs": [["result", BOOL, "same"]],
		"groups": ["next"],
		"desc": "Compares A with B into a bool. Two strings are compared by their text.",
	},
	"logic": {
		"title": "Logic", "cat": "logic", "kind": "action",
		"mode": "op", "mode_titles": {"And": "And", "Or": "Or", "Not": "Not"},
		"fields": [["op", "option", "And", ["And", "Or", "Not"], "Operation"]],
		"args": [["a", BOOL, "", true], ["b", BOOL, "true", false, {"op": ["And", "Or"]}]],
		"outs": [["result", BOOL, "both"]],
		"groups": ["next"],
		"desc": "A and B (both true), A or B (either), or not A (Operation).",
	},
	# ---------------------------------------------------------------- I/O
	"print": {
		"title": "Print", "cat": "output", "kind": "action",
		"args": [["value", ANY, "Hello, world!"]],
		"fields": [["newline", "check", true, null, "New line"]],
		"groups": ["next"],
		"desc": "Prints a value of any type (printf).",
	},
	"read": {
		"title": "Read input", "cat": "output", "kind": "action",
		"mode": "as", "mode_titles": {"int": "Read int", "float": "Read float", "line": "Read line"},
		"fields": [["as", "option", "int", ["int", "float", "line"], "Read"], ["prompt", "line", "Enter a number: ", null, "Prompt"]],
		"outs": [["value", ANY, "n"]],
		"groups": ["next"],
		"desc": "Prints the prompt, then reads what's typed on stdin: a whole number, a number, or a line of text (Read).",
	},
	"time": {
		"title": "Get Time", "cat": "output", "kind": "action",
		"outs": [["seconds", INT, "now"]],
		"groups": ["next"],
		"desc": "Seconds since the Unix epoch, time(NULL).",
	},
	# ---------------------------------------------------------------- Program
	"args": {
		"title": "Program Arguments", "cat": "program", "kind": "action",
		"mode": "what", "mode_titles": {"Count": "Argument count", "At index": "Argument", "Option": "Option value", "Flag": "Has flag"},
		"fields": [["what", "option", "Option", ["Count", "At index", "Option", "Flag"], "Get"]],
		"args": [["index", INT, "0", false, {"what": ["At index"]}], ["name", STRING, "name", false, {"what": ["Option", "Flag"]}]],
		"outs": [["result", ANY, "arg"]],
		"groups": ["next"],
		"desc": "What the program was started with: how many arguments, one by position (from 0), the value of --name=value (or --name value), or whether --name was given (Get). C-Bricks' own flags (--trace, --seed...) are taken out first.",
	},
	"quit": {
		"title": "Exit program", "cat": "program", "kind": "action",
		"args": [["code", INT, "0"]],
		"groups": [],
		"desc": "Ends the program at once with an exit code (0: success). When program ends still runs.",
	},
	"read_file": {
		"title": "Read file", "cat": "program", "kind": "action",
		"args": [["path", STRING, "assets/hello.txt"]],
		"outs": [["text", STRING, "text"]],
		"groups": ["next"],
		"desc": "Reads a whole text file (a path from the project folder, or absolute) into a string. \"\" when it can't be read.",
	},
	"write_file": {
		"title": "Write file", "cat": "program", "kind": "action",
		"mode": "mode", "mode_titles": {"Write": "Write file", "Append": "Append to file"},
		"fields": [["mode", "option", "Write", ["Write", "Append"], "Mode"]],
		"args": [["path", STRING, "output.txt"], ["text", STRING, "Hello!\\n"]],
		"outs": [["ok", BOOL, ""]],
		"groups": ["next"],
		"desc": "Writes text to a file, replacing it (Write) or adding to its end (Append). Ok: whether it worked.",
	},
	"file_exists": {
		"title": "File exists", "cat": "program", "kind": "action",
		"args": [["path", STRING, "assets/hello.txt"]],
		"outs": [["result", BOOL, "found"]],
		"groups": ["next"],
		"desc": "Whether a file can be opened for reading.",
	},
	# ---------------------------------------------------------------- Debug / testing
	"assert": {
		"title": "Assert", "cat": "debug", "kind": "action",
		"fields": [["operator", "option", "is true", COMPARE_OPS, "Compare"]],
		"args": [["a", ANY, "", true], ["b", ANY, "0", false, {"operator": TWO_SIDED}], ["message", STRING, "should hold"]],
		"groups": ["next"],
		"desc": "Stops the program with exit code 1 and a message naming this brick when the comparison doesn't hold. For tests.",
	},
	"debug_log": {
		"title": "Debug log", "cat": "debug", "kind": "action",
		"args": [["value", ANY, "here"]],
		"groups": ["next"],
		"desc": "Prints a value to stderr, only when the program runs with --verbose (or -v).",
	},
	# ---------------------------------------------------------------- Text
	"text": {
		"title": "Text", "cat": "text", "kind": "action",
		"mode": "op", "mode_titles": {"Join": "Join text", "Format": "Format text", "Length": "Text length", "Substring": "Substring", "Find": "Find in text", "Replace": "Replace in text", "Upper case": "Upper case", "Lower case": "Lower case", "Trim": "Trim", "Split": "Split text", "Join list": "Join list", "To text": "To text", "To int": "Text to int", "To float": "Text to float", "Starts with": "Starts with", "Ends with": "Ends with"},
		"fields": [
			["op", "option", "Join", ["Join", "Format", "Length", "Substring", "Find", "Replace", "Upper case", "Lower case", "Trim", "Split", "Join list", "To text", "To int", "To float", "Starts with", "Ends with"], "Do"],
			["format", "line", "Score: {} of {}", null, "Format", {"op": ["Format"]}],
		],
		"args": [
			["text", STRING, "Hello, ", false, {"op": ["Join", "Length", "Substring", "Find", "Replace", "Upper case", "Lower case", "Trim", "Split", "To int", "To float", "Starts with", "Ends with"]}],
			["more", STRING, "world", false, {"op": ["Join"]}],
			["start", INT, "0", false, {"op": ["Substring"]}],
			["length", INT, "5", false, {"op": ["Substring"]}],
			["what", STRING, "o", false, {"op": ["Find", "Replace", "Starts with", "Ends with"]}],
			["with", STRING, "0", false, {"op": ["Replace"]}],
			["separator", STRING, ", ", false, {"op": ["Split", "Join list"]}],
			["list", LIST, "", true, {"op": ["Join list"]}],
			["value", ANY, "42", false, {"op": ["To text"]}],
			["first", ANY, "1", false, {"op": ["Format"]}],
			["second", ANY, "2", false, {"op": ["Format"]}],
			["third", ANY, "", false, {"op": ["Format"]}],
			["fourth", ANY, "", false, {"op": ["Format"]}],
		],
		"outs": [["result", ANY, "result"]],
		"groups": ["next"],
		"desc": "Works with text (Do): joins two, fills {} in a Format with values (any type, in order), gives a length, a part (Substring from Start, Length characters), a position (Find: -1 when it's not there), replaces every match, changes case, trims spaces, splits into a string list or joins one, and turns values into text or text into numbers. Text made here is kept until the program ends.",
	},
	# ---------------------------------------------------------------- Objects (classes)
	"class": {
		"title": "Class", "cat": "objects", "kind": "declare", "unique": true,
		"fields": [
			["name", "line", "MyClass", null, "Name"],
			["extends", "extends", "Node", null, "Extends"],
			["fields", "params", [["health", "int"]], null, "Fields"],
			["synced", "line", "", null, "Synced"],
		],
		"structural": ["name"],
		"groups": [],
		"desc": "Makes this script a class (one per script): its Name, the class it Extends (Node, a built-in like Shape3D, or another class: it gets that class's fields and methods), its Fields (a name and a type each: every object has its own), and which fields are Synced (names, comma-separated: in a network game the server sends their changes to every player; vectors glide to new values, a name ending in ! jumps instead, e.g. position!; numbers, bools, text, vectors and objects). The script's Define Functions are its methods (Self is the object; a method with a parent's method's name replaces it), When created runs for each new object. A declaration: no wires.",
	},
	"created": {
		"title": "When created", "cat": "objects", "kind": "event", "unique": true,
		"groups": ["out"],
		"desc": "In a class's script: runs when an object of the class is made (New object), after its parent classes' When created. Self is the new object; its fields are set to zero / empty first.",
	},
	"every_frame": {
		"title": "Every frame", "cat": "objects", "kind": "event", "unique": true,
		"groups": ["out"],
		"desc": "In a class's script: runs once per frame for every object of the class that's in the world (the Game loop runs the world), before the Game loop's Frame chains. The input dt is the frame's length in seconds: move by speed * dt.",
	},
	"touched": {
		"title": "When touched", "cat": "objects", "kind": "event", "unique": true,
		"groups": ["out"],
		"desc": "In the script of a class that extends Shape3D: runs when another Shape3D in the world starts touching this one (their boxes overlap; rotation isn't counted). The input other is that Shape3D; Node (Is a / As) tells what it is.",
	},
	"drawn": {
		"title": "When drawn", "cat": "objects", "kind": "event", "unique": true,
		"groups": ["out"],
		"desc": "In a class's script: runs every frame while the world is drawn in 3D, in the object's own space (at its position, turned with it): Draw shape bricks here draw extra things that move with it.",
	},
	# ---------------------------------------------------------------- UI (2026-11-07: Buttons' clicks)
	"clicked": {
		"title": "When clicked", "cat": "ui", "kind": "event", "unique": true, "graphics": true,
		"groups": ["out"],
		"desc": "In the script of a class that extends Button: runs on this machine when its Button is clicked (pressed and let go over it with the left mouse button; not while it's disabled or the mouse is captured). For buttons without a class of their own, use When button clicked.",
	},
	"button_clicked": {
		"title": "When button clicked", "cat": "ui", "kind": "event", "graphics": true,
		"fields": [["button", "line", "", null, "Button name"]],
		"groups": ["out"],
		"desc": "Runs when a Button in the world is clicked on this machine, with button (the Button, a Node: Node (Name) tells which, Record field changes it). Button name: only that one (blank: any). In a plain script (a LocalScript's, typically: UI is on players' machines); not in Server scripts.",
	},
	"new_object": {
		"title": "New object", "cat": "objects", "kind": "action",
		"fields": [["of", "class", "", null, "Class"], ["world", "check", true, null, "In the world"]],
		"outs": [["object", OBJECT, "obj", "Into"]],
		"groups": ["next"],
		"desc": "Makes an object of a class: its fields at their starting values, then its When created runs. In the world (on): it's put under the world, so the Game loop moves and draws it (Shape3Ds, Text2Ds...) and runs its Every frame; off: it's under nothing until Node (Set parent). Objects are references: copying the variable copies the reference, both names are the same object."
	},
	"destroy": {
		"title": "Destroy object", "cat": "objects", "kind": "action",
		"args": [["object", OBJECT, "", true]],
		"groups": ["next"],
		"desc": "Frees an object (and the objects under it). Using it afterwards stops the program with an error naming that brick; check with Node (Exists) when it may be gone.",
	},
	"call_method": {
		"title": "Call method", "cat": "objects", "kind": "action",
		"fields": [["class", "class", "", null, "Class"], ["method", "method", "", null, "Method"]],
		"args": [["object", OBJECT, "", true]],
		"groups": ["next"],
		"desc": "Runs a method of an object (Class: the object's class, or a parent class of it; Method: one of that class's, its own or inherited). The object's own class's version runs (a subclass's method replaces its parent's). Picking the method gives this brick one row per input.",
	},
	"scene": {
		"title": "Scene", "cat": "objects", "kind": "action",
		"mode": "do", "mode_titles": {"Instance": "Instance scene", "Change": "Change scene"},
		"fields": [["do", "option", "Instance", ["Instance", "Change"], "Do"], ["scene", "scene", "", null, "Scene"]],
		"args": [["parent", OBJECT, "", true, {"do": ["Instance"]}]],
		"outs": [["root", OBJECT, "copy", "Into", {"do": ["Instance"]}]],
		"groups": ["next"],
		"desc": "Scenes (.cbscene, Godot's packed scenes): Instance scene makes a copy of a scene's objects under Parent (blank: the world) and gives its root (as the root's class); its Script objects run then. Change scene clears the world and makes another scene in it (levels, menus); asked for from an object's event, it happens at the next frame.",
	},
	"group": {
		"title": "Group", "cat": "objects", "kind": "action",
		"mode": "do", "mode_titles": {"Add": "Add to group", "Remove": "Remove from group", "Is in": "Is in group", "Objects in": "Nodes in group"},
		"fields": [["do", "option", "Add", ["Add", "Remove", "Is in", "Objects in"], "Do"], ["group", "line", "enemies", null, "Group"]],
		"args": [["object", OBJECT, "", true, {"do": ["Add", "Remove", "Is in"]}]],
		"outs": [["result", ANY, "result", "Into", {"do": ["Is in", "Objects in"]}]],
		"groups": ["next"],
		"desc": "Named groups of objects (Brickscript's group bricks; also set in the World tab's Groups): Add an object to a Group, Remove it, whether it Is in one (a bool), every node in the world that's in a group (Nodes in group: a Node list). An object can be in many groups.",
	},
	"metadata": {
		"title": "Metadata", "cat": "objects", "kind": "action",
		"mode": "do", "mode_titles": {"Set": "Set metadata", "Get": "Get metadata", "Has": "Has metadata", "Remove": "Remove metadata"},
		"fields": [["do", "option", "Get", ["Set", "Get", "Has", "Remove"], "Do"]],
		"args": [["object", OBJECT, "", true], ["key", STRING, "note"], ["value", STRING, "", false, {"do": ["Set"]}]],
		"outs": [["result", ANY, "meta", "Into", {"do": ["Get", "Has"]}]],
		"groups": ["next"],
		"desc": "Extra values on any object, by a text key (Godot's metadata; also set in the World tab): Set a key's text, Get it (\"\" when there's none), whether it Has it, Remove it. Text only: To int / To float turn it into numbers.",
	},
	"object": {
		"title": "Node", "cat": "objects", "kind": "action",
		"mode": "op", "mode_titles": {"Exists": "Node exists", "Is a": "Is a", "As": "As class", "Class name": "Class name", "Id": "Node id", "Name": "Node name", "Set name": "Set node name", "Parent": "Parent", "Set parent": "Set parent", "Children": "Children", "World": "The world", "Find": "Find object"},
		"fields": [
			["op", "option", "Exists", ["Exists", "Is a", "As", "Class name", "Id", "Name", "Set name", "Parent", "Set parent", "Children", "World", "Find"], "Do"],
			["of", "class", "", null, "Class", {"op": ["Is a", "As", "Find"]}],
		],
		"args": [
			["object", OBJECT, "", true, {"op": ["Exists", "Is a", "As", "Class name", "Id", "Name", "Set name", "Parent", "Set parent", "Children"]}],
			["name", STRING, "Gem", false, {"op": ["Set name", "Find"]}],
			["parent", OBJECT, "", true, {"op": ["Set parent"]}],
		],
		"outs": [["result", ANY, "result", "Into", {"op": ["Exists", "Is a", "As", "Class name", "Id", "Name", "Parent", "Children", "World", "Find"]}]],
		"groups": ["next"],
		"desc": "About an object (Do): whether it Exists (not none, not destroyed); whether it Is a class (its own or a parent class); As: the object as that class, or none when it isn't one; its Class name; its Id (a number no other object has); its Name (the class's name until Set name); its Parent, Set parent (under another object, or none), its Children (a Node list); The world (its root object); Find an object in the world by its name, as a Class (none when there's none of that name and class: e.g. the Main scene's nodes). Destroying an object destroys its children.",
	},
	# ---------------------------------------------------------------- Network (stage 3, Brickscript's network bricks)
	"network": {
		"title": "Network", "cat": "network", "kind": "action",
		"mode": "do", "mode_titles": {"Host": "Host", "Join": "Join", "Leave": "Leave", "Role": "Network role", "Is server": "Is server"},
		"fields": [["do", "option", "Host", ["Host", "Join", "Leave", "Role", "Is server"], "Do"]],
		"args": [
			["address", STRING, "127.0.0.1", false, {"do": ["Join"]}],
			["port", INT, "7000", false, {"do": ["Host", "Join"]}],
			["timeout", FLOAT, "5", false, {"do": ["Join"]}],
		],
		"outs": [["result", ANY, "ok", "Into", {"do": ["Host", "Join", "Role", "Is server"]}]],
		"groups": ["next"],
		"desc": "Starts or ends a network game (Brickscript's Host / Join / Leave; not in Server scripts: it's a player's choice). Host: this program becomes the server on a Port and its player stays player 1 (true if it started; false if it's already in a game or the port is taken). Join: connects to a server's Address and Port and waits (at most Timeout seconds) for it to answer and send its world: true once joined (this machine's world is replaced by the server's, except objects in the group local; the players already there arrive with Player Joined), false if nobody answered, it refused (a different build of the game) or it's already in a game. Leave: back to single-player (a host's clients see the game close). Role: offline, host, server or client. Is server: true where the game's rules run (offline and hosting too). The flags --host PORT, --server PORT (no player of its own), --join ADDRESS:PORT and --name NAME do the same from the command line.",
	},
	"player_joined": {
		"title": "Player Joined", "cat": "network", "kind": "event",
		"groups": ["out"],
		"desc": "Runs on every machine when a player joins the game, with player (their number: Player (Name) gives their name). It also runs once for each player already there when the program starts or joins, you included (offline you are player 1), so everyone's things are made the same way. A Server script's runs only where the game's rules run, a Client script's only on players' machines.",
	},
	"player_left": {
		"title": "Player Left", "cat": "network", "kind": "event",
		"groups": ["out"],
		"desc": "Runs on every machine when a player leaves (or stops answering for 5 seconds), with player (their number): their name still reads here; right after, they're gone. Also runs for everyone when this machine leaves a game (then Player Joined for you again, back in single-player).",
	},
	"remote": {
		"title": "Define Remote", "cat": "network", "kind": "declare",
		"fields": [
			["name", "line", "my_remote", null, "Name"],
			["direction", "option", "To server", ["To server", "To clients", "Both", "Ask server"], "Direction"],
			["values", "params", [["item", "string"]], null, "Values"],
			["answer", "type", "bool", null, "Answer", {"direction": ["Ask server"]}],
		],
		"groups": [],
		"desc": "A message between the players' machines and the server (Roblox's RemoteEvent / RemoteFunction), for the whole project: its Name, which way it goes (To server: a player's machine tells the server, Fire Server; To clients: the server tells players, Fire Clients; Both; Ask server: a player's machine asks the server and waits for its Answer, Invoke Server), the Values it carries (a name and a type each: numbers, bools, text, vectors, nodes; a player is an int) and, for Ask server, the Answer's type. Fire Server / Fire Clients send it, On Client Fired / On Server Fired receive it; Invoke Server asks it, On Client Invoked answers it. A declaration: no wires.",
	},
	"fire_server": {
		"title": "Fire Server", "cat": "network", "kind": "action", "dynamic": true,
		"fields": [["remote", "remote", "", null, "Remote"]],
		"groups": ["next"],
		"desc": "Sends a remote (To server) with its values to the server: its On Client Fired runs there, with sender = this machine's player. Not in Server scripts. Offline or hosting the game is its own server: it runs here. Picking the remote gives this brick one row per value. The server should check what it's told: any client can send anything.",
	},
	"fire_clients": {
		"title": "Fire Clients", "cat": "network", "kind": "action", "dynamic": true,
		"fields": [["remote", "remote", "", null, "Remote"], ["to", "option", "All", ["All", "One player"], "To"]],
		"groups": ["next"],
		"desc": "Sends a remote (To clients) with its values to every player's machine (All) or one player's (One player: e.g. a sender, or Player Joined's player): their On Server Fired runs. Not in Client scripts. Synced fields changed before it arrive before it. A host is a player too: it runs there as well.",
	},
	"on_client_fired": {
		"title": "On Client Fired", "cat": "network", "kind": "event", "dynamic": true,
		"fields": [["remote", "remote", "", null, "Remote"]],
		"groups": ["out"],
		"desc": "Runs on the server when a player's machine sends this remote (Fire Server): its values as variables, and sender (the Player who sent it). Not in Client scripts. Check the values before trusting them (e.g. that sender owns what it's about).",
	},
	"on_server_fired": {
		"title": "On Server Fired", "cat": "network", "kind": "event", "dynamic": true,
		"fields": [["remote", "remote", "", null, "Remote"]],
		"groups": ["out"],
		"desc": "Runs on a player's machine when the server sends this remote (Fire Clients): its values as variables. Not in Server scripts.",
	},
	"invoke_server": {
		"title": "Invoke Server", "cat": "network", "kind": "action", "dynamic": true,
		"fields": [["remote", "remote", "", null, "Remote"]],
		"groups": ["next"],
		"desc": "Asks the server a question (a remote whose Direction is Ask server: Roblox's InvokeServer) with its values, and waits for the answer (the window and the world keep running, as in a Wait), at most Timeout seconds: Answer gets it (a variable of the remote's Answer type), Answered whether it came (false: no answer in time, the server's On Client Invoked didn't Answer, or not in a game with a server: Answer is then 0 / false / empty / none). Not in Server scripts, nor in an object's event (Every frame...: it would hold up the world). Offline or hosting, the game is its own server: it's answered at once. E.g. can I buy this? what does it cost?",
	},
	"on_client_invoked": {
		"title": "On Client Invoked", "cat": "network", "kind": "event", "dynamic": true,
		"fields": [["remote", "remote", "", null, "Remote"]],
		"groups": ["out"],
		"desc": "Runs on the server when a player's machine asks this remote (Invoke Server, a remote whose Direction is Ask server): its values as variables, and sender (the player who asked). An Answer brick in its chains sends the answer back (only the first counts); if none runs, the asker gets an empty answer (Answered false). Not in Client scripts. Check the values first: any client can ask anything.",
	},
	"answer": {
		"title": "Answer", "cat": "network", "kind": "action",
		"args": [["value", ANY, "true"]],
		"groups": ["next"],
		"desc": "Sends the answer to the question its On Client Invoked chain is answering (Roblox's RemoteFunction's return value): a value of the remote's Answer type, to the asking machine only. Only in an On Client Invoked chain; only the first Answer of a question counts. The chain goes on after it.",
	},
	"player_key": {
		"title": "Player Key", "cat": "input", "kind": "event", "graphics": true,
		"mode": "when", "mode_titles": {"Pressed": "Player Pressed", "Released": "Player Released"},
		"fields": [["when", "option", "Pressed", ["Pressed", "Released"], "When"], ["key", "option", "SPACE", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "SPACE", "ENTER", "ESCAPE", "TAB", "BACKSPACE", "UP", "DOWN", "LEFT", "RIGHT", "LEFT_SHIFT", "LEFT_CONTROL", "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "F1", "F2", "F3", "F4", "F5"], "Key"]],
		"groups": ["out"],
		"desc": "Runs where the game's rules run when a player presses (or releases) a key on their machine, with player (who). Every player's machine sends the keys the project's Player bricks name; offline and hosting, your own keys are player 1's. Not in Client scripts (there, read your own keys with Input).",
	},
	"player_input": {
		"title": "Player Input", "cat": "input", "kind": "action", "graphics": true,
		"mode": "what", "mode_titles": {"Holds": "Player Holds?", "Direction": "Player Direction"},
		"fields": [
			["what", "option", "Holds", ["Holds", "Direction"], "Get"],
			["key", "option", "SPACE", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "SPACE", "ENTER", "ESCAPE", "TAB", "BACKSPACE", "UP", "DOWN", "LEFT", "RIGHT", "LEFT_SHIFT", "LEFT_CONTROL", "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "F1", "F2", "F3", "F4", "F5"], "Key", {"what": ["Holds"]}],
			["left", "option", "A", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Left", {"what": ["Direction"]}],
			["right", "option", "D", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Right", {"what": ["Direction"]}],
			["forward", "option", "W", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Forward", {"what": ["Direction"]}],
			["back", "option", "S", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Back", {"what": ["Direction"]}],
		],
		"args": [["player", INT, "", true]],
		"outs": [["result", ANY, "held", "Into"]],
		"groups": ["next"],
		"desc": "A player's keys, read where the game's rules run (Brickscript's Player Holds? / Player Direction): whether they hold a key (Holds), or which way their keys push (Direction: a vector2 at most 1 long, like Key Direction). A blank Player (a number) is the owner of the object the script is in (Give to), e.g. in a Hero's Every frame; else this machine's player. Not in Client scripts (there, use Input / Key Direction).",
	},
	"ownership": {
		"title": "Ownership", "cat": "network", "kind": "action",
		"mode": "do", "mode_titles": {"Give to": "Give To", "Owner": "Owner", "Is mine": "Mine?", "Owned by": "Owned by"},
		"fields": [["do", "option", "Give to", ["Give to", "Owner", "Is mine", "Owned by"], "Do"]],
		"args": [["object", OBJECT, "", true, {"do": ["Give to", "Owner", "Is mine"]}], ["player", INT, "", true, {"do": ["Give to", "Owned by"]}]],
		"outs": [["result", ANY, "owner", "Into", {"do": ["Owner", "Is mine", "Owned by"]}]],
		"groups": ["next"],
		"desc": "Whose a node is (Brickscript's Give To / Owner / Mine?). Give to (not in Client scripts): makes a node a player's (a number), and everything under it, on every machine (blank: no one's again); a Client Script object inside it runs on that player's machine. Owner: the player it belongs to (its own, or its nearest parent's: 0 when it's no one's or they left). Mine?: whether it's this machine's player's (offline and on a host, no one's things count as yours). Owned by: the nodes given to a player (a Node list: e.g. their Hero). The server stays in control: an owner's machine still asks it (Fire Server) to change things.",
	},

	"player": {
		"title": "Player", "cat": "network", "kind": "action",
		"mode": "op", "mode_titles": {"Me": "Me", "Name": "Player name", "Is me": "Is me", "In game": "In game", "Players": "Players"},
		"fields": [["op", "option", "Me", ["Me", "Name", "Is me", "In game", "Players"], "Do"]],
		"args": [["player", INT, "", true, {"op": ["Name", "Is me", "In game"]}]],
		"outs": [["result", ANY, "result", "Into", {"op": ["Me", "Name", "Is me", "In game", "Players"]}]],
		"groups": ["next"],
		"desc": "Players are numbers (Godot's peer ids; user, 2026-11-07: no Player class: your own classes hold their data): the host, or you offline, is 1, others count up as they join. Me: this machine's player (0 on a dedicated server; not in Server scripts); a player's Name (unique in the game: a second Ada is Ada_2); whether it Is me; whether it's In game (still there); every player (Players: an int list, in the order they joined). A blank Player is the owner of what the script is in (Give to), else this machine's player: so a Client script needn't say which.",
	},

	# ---------------------------------------------------------------- Data (lists, records)
	"list": {
		"title": "List", "cat": "data", "kind": "action",
		"mode": "op", "mode_titles": {"Make": "Make list", "Add": "Add to list", "Insert": "Insert in list", "Get": "Get item", "Set": "Set item", "Remove": "Remove item", "Length": "List length", "Find": "Find in list", "Contains": "List contains", "Clear": "Clear list", "Sort": "Sort list", "Reverse": "Reverse list"},
		"fields": [
			["op", "option", "Add", ["Make", "Add", "Insert", "Get", "Set", "Remove", "Length", "Find", "Contains", "Clear", "Sort", "Reverse"], "Do"],
			["of", "type", "int", null, "Of", {"op": ["Make"]}],
		],
		"args": [
			["list", LIST, "", true, {"op": ["Add", "Insert", "Get", "Set", "Remove", "Length", "Find", "Contains", "Clear", "Sort", "Reverse"]}],
			["value", ANY, "0", false, {"op": ["Add", "Insert", "Set", "Find", "Contains"]}],
			["index", INT, "0", false, {"op": ["Insert", "Get", "Set", "Remove"]}],
		],
		"outs": [["result", ANY, "items", "Into", {"op": ["Make", "Get", "Length", "Find", "Contains"]}]],
		"groups": ["next"],
		"desc": "Lists hold values of one type (Do): Make a new, empty list Of a type; Add to its end; Insert at an index; Get / Set the item at an index (from 0; a wrong index stops the program and names this brick); Remove one; its Length; Find a value's index (-1: not there); Contains; Clear; Sort (numbers and text); Reverse. Lists are kept until the program ends.",
	},
	"vector": {
		"title": "Vector", "cat": "math", "kind": "action",
		"mode": "op", "mode_titles": {"Make": "Make vector", "Split": "Split vector", "Add": "Add vectors", "Subtract": "Subtract vectors", "Scale": "Scale vector", "Length": "Vector length", "Normalize": "Normalize vector", "Distance": "Distance", "Lerp": "Lerp vectors", "Dot": "Dot product", "Cross": "Cross product"},
		"fields": [["op", "option", "Make", ["Make", "Split", "Add", "Subtract", "Scale", "Length", "Normalize", "Distance", "Lerp", "Dot", "Cross"], "Do"], ["dims", "option", "3D", ["3D", "2D"], "Size"]],
		"args": [
			["x", FLOAT, "0", false, {"op": ["Make"]}],
			["y", FLOAT, "0", false, {"op": ["Make"]}],
			["z", FLOAT, "0", false, {"op": ["Make"]}],
			["a", VEC3, "0, 0, 0", true, {"op": ["Split", "Add", "Subtract", "Scale", "Length", "Normalize", "Distance", "Lerp", "Dot", "Cross"]}],
			["b", VEC3, "0, 1, 0", false, {"op": ["Add", "Subtract", "Distance", "Lerp", "Dot", "Cross"]}],
			["factor", FLOAT, "2", false, {"op": ["Scale"]}],
			["t", FLOAT, "0.5", false, {"op": ["Lerp"]}],
		],
		"outs": [
			["result", ANY, "v", "Into", {"op": ["Make", "Add", "Subtract", "Scale", "Length", "Normalize", "Distance", "Lerp", "Dot", "Cross"]}],
			["x", FLOAT, "x", "X", {"op": ["Split"]}],
			["y", FLOAT, "y", "Y", {"op": ["Split"]}],
			["z", FLOAT, "z", "Z", {"op": ["Split"]}],
		],
		"groups": ["next"],
		"desc": "Works with vector3 values (3D points and directions) (Do): Make one from X, Y, Z; Split one into its parts; Add / Subtract two; Scale by a factor; its Length; Normalize (length 1; a zero vector stays zero); the Distance between two; Lerp: the point T of the way from A to B (0.5: half way); Dot and Cross products. Size: 3D (vector3s, typed in as \"x, y, z\") or 2D (vector2s, \"x, y\"; Cross gives a float there).",
	},
	"map": {
		"title": "Map", "cat": "data", "kind": "action",
		"mode": "op", "mode_titles": {"Make": "Make map", "Set": "Set in map", "Get": "Get from map", "Get or": "Get from map or", "Has": "Map has key", "Remove": "Remove from map", "Count": "Map count", "Keys": "Map keys", "Values": "Map values", "Clear": "Clear map"},
		"fields": [
			["op", "option", "Set", ["Make", "Set", "Get", "Get or", "Has", "Remove", "Count", "Keys", "Values", "Clear"], "Do"],
			["of", "type", "int", null, "Of", {"op": ["Make"]}],
		],
		"args": [
			["map", MAP, "", true, {"op": ["Set", "Get", "Get or", "Has", "Remove", "Count", "Keys", "Values", "Clear"]}],
			["key", STRING, "name", false, {"op": ["Set", "Get", "Get or", "Has", "Remove"]}],
			["value", ANY, "0", false, {"op": ["Set"]}],
			["default", ANY, "0", false, {"op": ["Get or"]}],
		],
		"outs": [["result", ANY, "table", "Into", {"op": ["Make", "Get", "Get or", "Has", "Count", "Keys", "Values"]}]],
		"groups": ["next"],
		"desc": "Maps look values up by a text key (a dictionary), all values of one type (Do): Make a new, empty map Of a type; Set a key's value (adds the key, or changes it); Get a key's value (a missing key stops the program and names this brick); Get or: its value, or Default when the key isn't there; Has key; Remove a key; Count its keys; Keys (a string list) and Values (a list) in the order they were added; Clear. Maps are kept until the program ends; Variable (Set) b = a makes both names one map.",
	},
	"for_each": {
		"title": "For each item", "cat": "flow", "kind": "action",
		"args": [["list", LIST, "", true]],
		"outs": [["item", ANY, "item", "Item"], ["index", INT, "", "Index"]],
		"groups": ["loop", "done"],
		"desc": "Runs the Loop body once per item of a list, the item (and its index, optional) in variables. Done runs after.",
	},
	"record": {
		"title": "Define Record", "cat": "data", "kind": "declare",
		"fields": [["name", "line", "Point", null, "Name"], ["fields", "params", [["x", "float"], ["y", "float"]], null, "Fields"]],
		"structural": ["name"],
		"groups": [],
		"desc": "A record type (a C struct): a name and named fields, each of a type (other records and lists too). Every script can use it. A declaration: no wires.",
	},
	"make_record": {
		"title": "Make record", "cat": "data", "kind": "action",
		"fields": [["of", "record", "", null, "Record"]],
		"outs": [["result", RECORD, "item"]],
		"groups": ["next"],
		"desc": "A new record of a type, its fields at zero / empty (its lists ready to use).",
	},
	"field": {
		"title": "Record field", "cat": "data", "kind": "action",
		"mode": "mode", "mode_titles": {"Get": "Get field", "Set": "Set field"},
		"fields": [["mode", "option", "Get", ["Get", "Set"], "Mode"], ["field", "field", "", null, "Field"]],
		"args": [["record", RECORD, "", true], ["value", ANY, "0", false, {"mode": ["Set"]}]],
		"outs": [["value", ANY, "value", "Into", {"mode": ["Get"]}]],
		"groups": ["next"],
		"desc": "Reads one field of a record variable (Get), or changes it (Set). A record read from a list is a copy: Set item puts it back.",
	},
	"switch": {
		"title": "Switch", "cat": "flow", "kind": "action", "dynamic": true,
		"fields": [["cases", "cases", ["1", "2", "3"], null, "Cases"]],
		"args": [["value", ANY, "", true]],
		"groups": ["next"],
		"desc": "Runs the chains of the case that equals the value (ints, floats or text), or Default's when none does; then Next.",
	},
	"constant": {
		"title": "Constant", "cat": "variables", "kind": "declare",
		"fields": [["name", "line", "MAX_SCORE", null, "Name"], ["type", "option", "int", VALUE_TYPES, "Type"]],
		"args": [["value", ANY, "10"]],
		"groups": [],
		"desc": "A value that never changes, readable by every brick of every script. A declaration: no wires.",
	},
	# ---------------------------------------------------------------- System
	"sleep": {
		"title": "Sleep", "cat": "system", "kind": "action",
		"args": [["ms", INT, "500"]],
		"groups": ["next"],
		"desc": "Waits a number of milliseconds.",
	},
	"env": {
		"title": "Environment variable", "cat": "system", "kind": "action",
		"args": [["name", STRING, "HOME"]],
		"outs": [["value", STRING, "env_value"]],
		"groups": ["next"],
		"desc": "An environment variable's text (\"\" when it isn't set).",
	},
	"run_command": {
		"title": "Run command", "cat": "system", "kind": "action",
		"args": [["command", STRING, "echo Hello from the shell"]],
		"outs": [["code", INT, ""]],
		"groups": ["next"],
		"desc": "Runs a command in the system's shell and waits for it; Code is its exit code (-1 where there's no shell, e.g. WASI).",
	},
	"terminal": {
		"title": "Terminal", "cat": "system", "kind": "action",
		"mode": "mode", "mode_titles": {"Clear screen": "Clear screen", "Color": "Text color", "Reset": "Reset color", "Move cursor": "Move cursor", "Hide cursor": "Hide cursor", "Show cursor": "Show cursor"},
		"fields": [
			["mode", "option", "Color", ["Clear screen", "Color", "Reset", "Move cursor", "Hide cursor", "Show cursor"], "Do"],
			["color", "option", "green", ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "bright black", "bright red", "bright green", "bright yellow", "bright blue", "bright magenta", "bright cyan", "bright white"], "Color", {"mode": ["Color"]}],
			["background", "check", false, null, "Background", {"mode": ["Color"]}],
		],
		"args": [["row", INT, "1", false, {"mode": ["Move cursor"]}], ["column", INT, "1", false, {"mode": ["Move cursor"]}]],
		"groups": ["next"],
		"desc": "Controls the terminal (ANSI codes; Windows 10+ too): clear it, color the text that follows, move the cursor (from 1, 1), hide / show it.",
	},
	# ---------------------------------------------------------------- Graphics (raylib)
	"window": {
		"title": "Open window", "cat": "graphics", "kind": "action", "graphics": true,
		"fields": [["esc_closes", "check", true, null, "Escape closes"]],
		"args": [["width", INT, "800"], ["height", INT, "450"], ["title", STRING, "My game"], ["fps", INT, "60"]],
		"groups": ["next"],
		"desc": "Opens the program's window (and its sound) at a frame rate. Escape closes (on: raylib's way, Escape ends the Game loop; off: Escape is a key like any other, e.g. for a pause menu: Close window ends the game then). Then a Game loop draws in it. Graphics bricks use raylib: they build for this computer, Windows and macOS / the web where their toolchains are installed.",
	},
	"game_loop": {
		"title": "Game loop", "cat": "graphics", "kind": "action", "graphics": true,
		"groups": ["frame", "done"],
		"desc": "Runs the Frame chains once per frame (draw there: Clear, Draw...) until the window is closed (or Escape); then closes it and runs Done.",
	},
	"close_window": {
		"title": "Close window", "cat": "graphics", "kind": "action", "graphics": true,
		"groups": ["next"],
		"desc": "Ends the Game loop as if the window's close button was pressed: the frame under way finishes (the rest of its chains run), then the Game loop closes the window and runs its Done. A Wait under way ends early. A dedicated server (no window) ends its Game loop the same way. Open window clears it, so a later window opens as usual.",
	},
	"pause": {
		"title": "Pause game", "cat": "graphics", "kind": "action", "graphics": true,
		"mode": "do", "mode_titles": {"Pause": "Pause game", "Resume": "Resume game", "Is paused": "Paused?", "Set time scale": "Set time scale", "Time scale": "Time scale"},
		"fields": [["do", "option", "Pause", ["Pause", "Resume", "Is paused", "Set time scale", "Time scale"], "Do"]],
		"args": [["scale", FLOAT, "1", false, {"do": ["Set time scale"]}]],
		"outs": [["result", ANY, "paused", "Into", {"do": ["Is paused", "Time scale"]}]],
		"groups": ["next"],
		"desc": "Pauses the game, or resumes it; Paused? asks; Set time scale makes the world slower (0.5: half speed) or faster (2), Time scale asks. Offline, Pause freezes the world: objects' Every frame, touches, When frame starts / ends and Wait stop (frame time 0), while the Game loop's own Frame chains, drawing, the UI and its clicks go on (a pause menu works); scripts set to Run while paused go on too. In a network game (hosting, a client) Pause and the time scale are only remembered (Paused? says so, e.g. for a menu): the shared world keeps running at its speed.",
	},
	"clear": {
		"title": "Clear window", "cat": "graphics", "kind": "action", "graphics": true,
		"args": [["color", STRING, "RAYWHITE"]],
		"groups": ["next"],
		"desc": "Fills the window with a color: a name (RAYWHITE, BLACK, SKYBLUE, MAROON, GOLD...) or #rrggbb.",
	},
	"draw": {
		"title": "Draw", "cat": "graphics", "kind": "action", "graphics": true,
		"mode": "shape", "mode_titles": {"Rectangle": "Draw rectangle", "Outline": "Draw outline", "Circle": "Draw circle", "Line": "Draw line", "Text": "Draw text", "Texture": "Draw texture", "Sprite": "Draw sprite"},
		"fields": [["shape", "option", "Rectangle", ["Rectangle", "Outline", "Circle", "Line", "Text", "Texture", "Sprite"], "Shape"]],
		"args": [
			["texture", RECORD, "", true, {"shape": ["Texture", "Sprite"]}],
			["text", STRING, "Hello!", false, {"shape": ["Text"]}],
			["x", INT, "100"], ["y", INT, "100"],
			["frame", INT, "0", false, {"shape": ["Sprite"]}],
			["columns", INT, "4", false, {"shape": ["Sprite"]}],
			["rows", INT, "1", false, {"shape": ["Sprite"]}],
			["scale", FLOAT, "1", false, {"shape": ["Sprite"]}],
			["width", INT, "120", false, {"shape": ["Rectangle", "Outline"]}],
			["height", INT, "60", false, {"shape": ["Rectangle", "Outline"]}],
			["radius", FLOAT, "40", false, {"shape": ["Circle"]}],
			["x2", INT, "300", false, {"shape": ["Line"]}],
			["y2", INT, "200", false, {"shape": ["Line"]}],
			["size", INT, "20", false, {"shape": ["Text"]}],
			["rotation", FLOAT, "0", false, {"shape": ["Rectangle", "Text", "Texture", "Sprite"]}],
			["color", STRING, "MAROON"],
		],
		"groups": ["next"],
		"desc": "Draws a shape, text, a texture or a sprite at x, y (pixels from the top-left) in a color (Texture / Sprite: its tint, WHITE for none). Rotation (Rectangle, Text, Texture, Sprite): degrees clockwise, turned round its middle (x, y stays its top-left when not turned). Sprite: one Frame of a sprite sheet (a texture cut into Columns x Rows equal cells, counted from 0 along each row from the top-left), Scale times its cell's size. Inside a Game loop's Frame.",
	},
	"view2d": {
		"title": "Draw 2D view", "cat": "graphics", "kind": "action", "graphics": true,
		"args": [["center", VEC2, "0, 0"], ["zoom", FLOAT, "1"], ["rotation", FLOAT, "0"]],
		"groups": ["draw", "next"],
		"desc": "Draws its Draw chains through a 2D camera (raylib's Camera2D): the point Center is in the window's middle, things Zoom times as big, the view turned Rotation degrees. Draw bricks there use the game's world coordinates (follow a player: Center = their position). Next runs after, back in window pixels (a HUD on top). Inside a Game loop's Frame.",
	},
	"camera3d": {
		"title": "Set camera", "cat": "3d", "kind": "action", "graphics": true,
		"fields": [["projection", "option", "Perspective", ["Perspective", "Orthographic"], "Projection"]],
		"args": [["position", VEC3, "0, 8, 10"], ["target", VEC3, "0, 0, 0"], ["fov", FLOAT, "60"]],
		"groups": ["next"],
		"desc": "Where the 3D camera is (Position) and what it looks at (Target), y up. FOV: the view's height in degrees (Perspective) or in world units (Orthographic). Set it before Draw 3D, e.g. every frame to follow a player.",
	},
	"draw3d": {
		"title": "Draw 3D", "cat": "3d", "kind": "action", "graphics": true,
		"groups": ["draw", "next"],
		"desc": "Draws its Draw chains in 3D, seen from the camera (Set camera): put Draw shape bricks there. Next runs after, back in 2D (text on top of the 3D, a score...). Inside a Game loop's Frame.",
	},
	"shape3d": {
		"title": "Draw shape", "cat": "3d", "kind": "action", "graphics": true,
		"mode": "shape", "mode_titles": {"Box": "Draw box", "Wire box": "Draw wire box", "Sphere": "Draw sphere", "Cylinder": "Draw cylinder", "Plane": "Draw plane", "Mesh": "Draw mesh", "Line": "Draw 3D line", "Grid": "Draw grid"},
		"fields": [["shape", "option", "Box", ["Box", "Wire box", "Sphere", "Cylinder", "Plane", "Mesh", "Line", "Grid"], "Shape"]],
		"args": [
			["mesh", RECORD, "", true, {"shape": ["Mesh"]}],
			["at", VEC3, "0, 0.5, 0", false, {"shape": ["Box", "Wire box", "Sphere", "Cylinder", "Plane", "Mesh", "Line"]}],
			["to", VEC3, "0, 2, 0", false, {"shape": ["Line"]}],
			["size", VEC3, "1, 1, 1", false, {"shape": ["Box", "Wire box", "Sphere", "Cylinder", "Plane", "Mesh"]}],
			["turn", FLOAT, "0", false, {"shape": ["Box", "Sphere", "Cylinder", "Plane", "Mesh"]}],
			["lines", INT, "20", false, {"shape": ["Grid"]}],
			["spacing", FLOAT, "1", false, {"shape": ["Grid"]}],
			["color", STRING, "SKYBLUE", false, {"shape": ["Box", "Wire box", "Sphere", "Cylinder", "Plane", "Mesh", "Line", "Grid"]}],
		],
		"groups": ["next"],
		"desc": "Draws in 3D (inside Draw 3D): a shape with its middle At and Size across (as Add to mesh's shapes: a sphere 1 across is 1 wide, a cylinder stands up, a plane faces up), turned Turn degrees round the up axis, lit by the sun; a mesh (made with Begin / Add / Finish mesh) placed At, scaled by Size and tinted (WHITE: its own colors); a line from At to To; a grid on the ground (Lines across, Spacing apart).",
	},
	"snapshot": {
		"title": "Snapshot", "cat": "3d", "kind": "action", "graphics": true,
		"mode": "into", "mode_titles": {"File": "Snapshot to file", "Texture": "Snapshot to texture"},
		"fields": [
			["into", "option", "File", ["File", "Texture"], "Into"],
			["transparent", "check", false, null, "Transparent"],
		],
		"args": [
			["camera", OBJECT, "", true],
			["width", INT, "256"],
			["height", INT, "256"],
			["subject", OBJECT, "", true],
			["path", STRING, "snapshot.png", false, {"into": ["File"]}],
		],
		"outs": [
			["texture", RECORD, "shot", "Into", {"into": ["Texture"]}],
			["ok", BOOL, "", "Saved", {"into": ["File"]}],
		],
		"groups": ["next"],
		"desc": "What a Camera3D sees, drawn now into an image Width x Height: the world (or only Subject and the objects under it; blank: everything) from the camera's place, target and fov, over the Environment's sky or, Transparent, over nothing. Into File: a PNG at Path (Saved: whether it worked); Into Texture: a texture variable to draw (Draw: Texture), e.g. a portrait or a minimap. After Open window.",
	},
	"raycast": {
		"title": "Raycast", "cat": "3d", "kind": "action", "graphics": true,
		"args": [["from", VEC3, "0, 1, 0"], ["to", VEC3, "0, -10, 0"], ["ignore", OBJECT, "", true]],
		"outs": [["hit", RECORD, "", "Hit"], ["point", VEC3, "", "Hit point"], ["normal", VEC3, "", "Normal"], ["distance", FLOAT, "", "Distance"]],
		"groups": ["hit", "missed", "next"],
		"desc": "The first Shape3D on a straight line From one point To another (Brickscript's Raycast): Hit or Nothing hit runs, then Next. Fills (each optional) Hit: the Shape3D (none when nothing is hit); Hit point: where (To when nothing); Normal: which way the face it hit points (0, 0, 0 when nothing); Distance: how far from From (-1 when nothing). Ignore: an object it passes through, with the objects under it (the shooter itself). Shape3Ds count as boxes (their size, turned with their rotation; spheres and cylinders too). For shots, line of sight, the ground under something.",
	},
	"can_see": {
		"title": "Can see", "cat": "3d", "kind": "action", "graphics": true,
		"args": [["who", OBJECT, "", true], ["target", OBJECT, "", true], ["range", FLOAT, "20"], ["view", FLOAT, "120"]],
		"groups": ["seen", "unseen", "next"],
		"desc": "Whether a Shape3D sees another object (Brickscript's Can see): within Range, inside its View (degrees across, around where it faces: its -Z turned by its rotation; 360: all round) and nothing in the way (a ray from it to the target that hits the target, or something under it). Seen or Not seen runs, then Next.",
	},
	"nearest": {
		"title": "Nearest object", "cat": "3d", "kind": "action", "graphics": true,
		"fields": [["of", "class", "Shape3D", null, "Class"]],
		"args": [["from", VEC3, "0, 0, 0"], ["range", FLOAT, "0"], ["except", OBJECT, "", true]],
		"outs": [["result", OBJECT, "nearest", "Into"], ["distance", FLOAT, "", "Distance"]],
		"groups": ["next"],
		"desc": "The object of a Class (its own or a subclass) in the world closest to a point (Brickscript's Nearest character, for any class): only within Range (0: any distance), never Except (and the objects under it). Distance: how far it is, -1 when there's none; none then (Object: Exists).",
	},
	"shake_camera": {
		"title": "Shake Camera", "cat": "3d", "kind": "action", "graphics": true,
		"args": [["strength", FLOAT, "0.2"], ["duration", FLOAT, "0.4"]],
		"groups": ["next"],
		"desc": "Shakes the 3D view for a while, fading out (Brickscript's Shake Camera): hits, explosions, landing. It jolts what's drawn, not the Camera's fields, so it doesn't fight what moves the camera. Strength in world units; a new shake replaces one under way.",
	},
	"move_collide": {
		"title": "Move and collide", "cat": "3d", "kind": "action", "graphics": true,
		"args": [["part", OBJECT, "", true], ["motion", VEC3, "0, 0, -0.1"]],
		"outs": [["blocked", BOOL, "", "Blocked"]],
		"groups": ["next"],
		"desc": "Moves a Shape3D by Motion (world units) like a body: it stops at Shape3Ds whose solid field is on and slides along them (each axis in turn), so walls can't be walked through. Blocked: whether something stopped it. Boxes count as their size turned with their rotation (the box around it). The Shape3D's own solid doesn't matter; the objects under it don't block it.",
	},
	"begin_mesh": {
		"title": "Begin mesh", "cat": "3d", "kind": "action", "graphics": true,
		"outs": [["mesh", RECORD, "mesh", "Mesh"]],
		"groups": ["next"],
		"desc": "Starts a new mesh in a mesh variable (Brickscript's Begin mesh): forgets anything added since its last Begin / Finish. Then Add to mesh, then Finish mesh (until then it shows what it had).",
	},
	"add_mesh": {
		"title": "Add to mesh", "cat": "3d", "kind": "action", "graphics": true,
		"mode": "kind", "mode_titles": {"Triangle": "Add triangle", "Quad": "Add quad", "Shape": "Add shape"},
		"fields": [
			["kind", "option", "Triangle", ["Triangle", "Quad", "Shape"], "Kind"],
			["shape", "option", "Box", ["Box", "Sphere", "Cylinder", "Plane"], "Shape", {"kind": ["Shape"]}],
		],
		"args": [
			["mesh", RECORD, "", true],
			["a", VEC3, "0, 0, 0", false, {"kind": ["Triangle", "Quad"]}],
			["b", VEC3, "1, 0, 0", false, {"kind": ["Triangle", "Quad"]}],
			["c", VEC3, "0, 0, 1", false, {"kind": ["Triangle", "Quad"]}],
			["d", VEC3, "0, 0, 1", false, {"kind": ["Quad"]}],
			["at", VEC3, "0, 0, 0", false, {"kind": ["Shape"]}],
			["size", VEC3, "1, 1, 1", false, {"kind": ["Shape"]}],
			["color", STRING, "WHITE"],
		],
		"groups": ["next"],
		"desc": "Adds to the mesh being built (Kind): a Triangle A B C, its front the side its corners go round clockwise (as given, facing up); a Quad A B C D in order round its edge (two triangles, A B C and A C D); or a ready Shape (Box / Sphere / Cylinder / Plane) with its middle At and Size across, which keeps its own shading. Points are in the mesh's own space.",
	},
	"finish_mesh": {
		"title": "Finish mesh", "cat": "3d", "kind": "action", "graphics": true,
		"fields": [
			["shading", "option", "Flat", ["Flat", "Smooth"], "Shading"],
			["sides", "option", "Both sides", ["Both sides", "One side"], "Sides"],
		],
		"args": [["mesh", RECORD, "", true]],
		"groups": ["next"],
		"desc": "Builds what was added since Begin mesh into the mesh (after Open window). Shading Flat: every triangle its own face; Smooth: corners in the same place and of the same color become one point, shaded round. Sides: Both sides shows the backs too; One side only the fronts (cheaper, for closed shapes).",
	},
	"mesh_vertices": {
		"title": "Mesh vertices", "cat": "3d", "kind": "action", "graphics": true,
		"mode": "mode", "mode_titles": {"Get": "Get mesh vertices", "Set": "Set mesh vertices"},
		"fields": [["mode", "option", "Get", ["Get", "Set"], "Mode"]],
		"args": [["mesh", RECORD, "", true], ["value", LIST, "", true, {"mode": ["Set"]}]],
		"outs": [["points", LIST, "points", "Into", {"mode": ["Get"]}]],
		"groups": ["next"],
		"desc": "A finished mesh's points as a vector3 list (Get), or puts a changed list back (Set: as many points as it has; its shading is worked out again). A Smooth mesh has one point per corner place, so moving one moves every triangle at it; a Flat one has a point per triangle corner. To bend a mesh: Get, For each item, change it, Add to a new list, Set.",
	},
	"input": {
		"title": "Input", "cat": "input", "kind": "action", "graphics": true,
		"mode": "when", "mode_titles": {"Key down": "Key down?", "Key pressed": "Key pressed?", "Key released": "Key released?", "Mouse down": "Mouse down?", "Mouse pressed": "Mouse clicked?", "Mouse over UI": "Mouse over UI?"},
		"fields": [
			["when", "option", "Key down", ["Key down", "Key pressed", "Key released", "Mouse down", "Mouse pressed", "Mouse over UI"], "When"],
			["key", "option", "SPACE", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "SPACE", "ENTER", "ESCAPE", "TAB", "BACKSPACE", "UP", "DOWN", "LEFT", "RIGHT", "LEFT_SHIFT", "LEFT_CONTROL", "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "F1", "F2", "F3", "F4", "F5"], "Key", {"when": ["Key down", "Key pressed", "Key released"]}],
			["button", "option", "LEFT", ["LEFT", "RIGHT", "MIDDLE"], "Button", {"when": ["Mouse down", "Mouse pressed"]}],
		],
		"outs": [["result", BOOL, "pressed"]],
		"groups": ["next"],
		"desc": "Whether a key or mouse button is held down, or was pressed / released this frame (When); Mouse over UI: whether the pointer is over a UI node that draws something (a Label, Panel, Bar, Image or Button): skip the game's own clicks then (a click on a Button is the Button's).",
	},
	"mouse": {
		"title": "Mouse position", "cat": "input", "kind": "action", "graphics": true,
		"mode": "what", "mode_titles": {"Position": "Mouse position", "Movement": "Mouse movement", "Wheel": "Mouse wheel"},
		"fields": [["what", "option", "Position", ["Position", "Movement", "Wheel"], "Get"]],
		"outs": [["x", ANY, "mouse_x", "X"], ["y", ANY, "mouse_y", "Y", {"what": ["Position", "Movement"]}]],
		"groups": ["next"],
		"desc": "The mouse (Get): its Position in the window (pixels, ints); its Movement since the last frame (floats: for mouse look, with Cursor (Lock)); how far the Wheel turned this frame (X, a float: + away from you).",
	},
	"key_direction": {
		"title": "Key Direction", "cat": "input", "kind": "action", "graphics": true,
		"fields": [
			["left", "option", "A", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Left"],
			["right", "option", "D", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Right"],
			["forward", "option", "W", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Forward"],
			["back", "option", "S", ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "UP", "DOWN", "LEFT", "RIGHT"], "Back"],
		],
		"outs": [["result", VEC2, "move", "Into"]],
		"groups": ["next"],
		"desc": "Which way the keys push (Brickscript's Key Direction): a vector2 at most 1 long (x: Left -1 / Right 1, y: Forward -1 / Back 1), so two keys at once aren't faster. In 3D use x and y as x and z (turned by a camera's yaw for first-person movement); scale it by speed * frame time.",
	},
	"mouse_mode": {
		"title": "Mouse mode", "cat": "input", "kind": "action", "graphics": true,
		"fields": [["mode", "option", "Captured", ["Visible", "Captured", "Hidden"], "Mode"]],
		"groups": ["next"],
		"desc": "How the mouse behaves (Brickscript's Mouse mode): Visible (the usual pointer), Captured (hidden and kept in the window, for mouse look: read how it moves with Mouse position (Movement)), Hidden (only not shown). After Open window.",
	},
	"game_info": {
		"title": "Game info", "cat": "graphics", "kind": "action", "graphics": true,
		"mode": "what", "mode_titles": {"Frame time": "Frame time", "Time": "Time since start", "Width": "Window width", "Height": "Window height", "FPS": "Frames per second"},
		"fields": [["what", "option", "Frame time", ["Frame time", "Time", "Width", "Height", "FPS"], "Get"]],
		"outs": [["result", ANY, "dt"]],
		"groups": ["next"],
		"desc": "Seconds the last frame took (to move things smoothly: speed * frame time), seconds since the window opened, the window's size, the frame rate.",
	},
	"load_texture": {
		"title": "Load texture", "cat": "graphics", "kind": "action", "graphics": true,
		"args": [["path", STRING, "assets/player.png"]],
		"outs": [["texture", RECORD, "image"]],
		"groups": ["next"],
		"desc": "Loads an image (png, jpg, bmp...) from the project's files, to draw with Draw texture. After Open window.",
	},
	"music": {
		"title": "Music", "cat": "graphics", "kind": "action", "graphics": true,
		"mode": "do", "mode_titles": {"Load": "Load music", "Play": "Play music", "Stop": "Stop music", "Pause": "Pause music", "Resume": "Resume music", "Volume": "Music volume", "Playing": "Music playing?"},
		"fields": [
			["do", "option", "Play", ["Load", "Play", "Stop", "Pause", "Resume", "Volume", "Playing"], "Do"],
			["loop", "check", true, null, "Loop", {"do": ["Load"]}],
		],
		"args": [
			["path", STRING, "assets/song.ogg", false, {"do": ["Load"]}],
			["music", RECORD, "", true, {"do": ["Play", "Stop", "Pause", "Resume", "Volume", "Playing"]}],
			["volume", FLOAT, "1", false, {"do": ["Volume"]}],
		],
		"outs": [["music", RECORD, "song", "Into", {"do": ["Load"]}], ["result", BOOL, "playing", "Into", {"do": ["Playing"]}]],
		"groups": ["next"],
		"desc": "Streamed music (raylib's music streams: ogg, mp3, wav, flac, xm, mod), read from the file a little at a time instead of loaded whole like a Sound. Load it from the project's files (Loop: start again at its end), Play it from the start, Stop, Pause, Resume, set its Volume (0 to 1), or ask whether it's Playing. It plays while the Game loop runs (Wait too). After Open window.",
	},
	"sound": {
		"title": "Sound", "cat": "graphics", "kind": "action", "graphics": true,
		"mode": "mode", "mode_titles": {"Load": "Load sound", "Play": "Play sound"},
		"fields": [["mode", "option", "Play", ["Load", "Play"], "Mode"]],
		"args": [["path", STRING, "assets/jump.wav", false, {"mode": ["Load"]}], ["sound", RECORD, "", true, {"mode": ["Play"]}]],
		"outs": [["sound", RECORD, "jump", "Into", {"mode": ["Load"]}]],
		"groups": ["next"],
		"desc": "Loads a sound (wav, ogg, mp3) from the project's files, or plays one. After Open window.",
	},
	# ---------------------------------------------------------------- Advanced
	"call_c": {
		"title": "Call C function", "cat": "advanced", "kind": "action", "dynamic": true,
		"fields": [
			["name", "line", "my_c_function", null, "Function"],
			["returns", "type_void", "int", null, "Gives back"],
			["args", "params", [["x", "int"]], null, "Inputs"],
			["header", "line", "", null, "Header"],
		],
		"groups": ["next"],
		"desc": "Calls a C function: from the C library, or from a .c file of your own in the project (it's compiled in). Header: the file to #include (\"mylib.h\" or <time.h>); blank: the call is declared from Inputs / Gives back.",
	},
	"raw_c": {
		"title": "C Code", "cat": "advanced", "kind": "action",
		"fields": [["code", "text", "/* any C statements */", null, "Code"]],
		"groups": ["next"],
		"desc": "C statements written as they are. The graph's variables can be used by name.",
	},
	"include": {
		"title": "#include", "cat": "advanced", "kind": "declare",
		"fields": [["header", "line", "<string.h>", null, "Header"]],
		"groups": [],
		"desc": "Adds an #include line to the file. A declaration: no wires.",
	},
}


static func type_from_name(n: String) -> int:
	return CBTypes.port(n)


static func type_name(t: int) -> String:
	return TYPE_NAMES[t] if t >= 0 and t < TYPE_NAMES.size() else "any"


static func is_compatible(a: int, b: int) -> bool:
	if a == b or a == ANY or b == ANY:
		return true
	var numeric := [INT, FLOAT, BOOL]
	if (a == RECORD and b == OBJECT) or (a == OBJECT and b == RECORD):
		return true  # the field brick reads records and objects
	return a in numeric and b in numeric


## Whether a variable of type name `t` fits an input of port type `p`.
static func fits(p: int, t: String) -> bool:
	return is_compatible(p, CBTypes.port(t))


## The literal types an input can be typed as (its mode dropdown).
static func literal_types(ptype: int) -> PackedStringArray:
	if ptype == LIST or ptype == RECORD or ptype == MAP or ptype == OBJECT:
		return PackedStringArray()
	if ptype == ANY:
		return PackedStringArray(VALUE_TYPES)
	return PackedStringArray([type_name(ptype)])


## What type a typed-in default is (for an Anything input).
static func guess_literal_type(text: String) -> String:
	var t := text.strip_edges()
	if t.is_valid_int():
		return "int"
	if t.is_valid_float():
		return "float"
	if t == "true" or t == "false":
		return "bool"
	return "string"


## Whether a field / arg / out is used with the node's current settings
## (Brickscript's shown_when: {setting: [values]}).
static func shown(spec: Array, fields: Dictionary, at: int) -> bool:
	if spec.size() <= at or not spec[at] is Dictionary:
		return true
	for key in spec[at]:
		if str(fields.get(key, "")) not in spec[at][key]:
			return false
	return true


## The title a brick shows: its mode's ("Subtract", "Variable (Get)").
static func title_of(type: String, fields: Dictionary) -> String:
	var def: Dictionary = DEFS.get(type, {})
	if def.has("mode"):
		return def.mode_titles.get(str(fields.get(def.mode, "")), def.title)
	return def.get("title", type)


static func kind_of(type: String) -> String:
	return DEFS.get(type, {}).get("kind", "action")


static func has_input(type: String) -> bool:
	return kind_of(type) in ["action", "reroute"]


## [["a","int"], ...] from a Define Function's params (also the older "int a, int b" text).
static func parse_params(value) -> Array:
	var out := []
	if value is Array:
		for p in value:
			if p is Array and p.size() == 2 and str(p[0]).is_valid_identifier() and (str(p[1]) in VALUE_TYPES or str(p[1]).trim_suffix(" list").trim_suffix(" map").is_valid_identifier()):
				out.append([str(p[1]), str(p[0])])
		return out
	for part in str(value).split(",", false):
		var bits := part.strip_edges().split(" ", false)
		if bits.size() == 2 and bits[0] in VALUE_TYPES and bits[1].is_valid_identifier():
			out.append([bits[0], bits[1]])
	return out


## {name: {"returns": String, "params": [[type, name], ...]}} from node dicts.
static func collect_functions(nodes: Array) -> Dictionary:
	var funcs := {}
	for n in nodes:
		if n.type == "function":
			var f: Dictionary = n.get("fields", {})
			funcs[str(f.get("name", ""))] = {
				"returns": str(f.get("returns", "void")),
				"params": parse_params(f.get("params", [])),
			}
	return funcs


## {name: [[field, type], ...]} from Define Record bricks.
static func collect_records(nodes: Array) -> Dictionary:
	var out := {}
	for n in nodes:
		if n.type == "record":
			var name := str(n.get("fields", {}).get("name", ""))
			if name.is_valid_identifier():
				var fields := []
				for p in parse_params(n.fields.get("fields", [])):
					fields.append([p[1], p[0]])
				out[name] = fields
	return out


## Args / outs / groups of a node (Call Function's come from its function).
static func layout_for(type: String, fields: Dictionary, funcs: Dictionary) -> Dictionary:
	var def: Dictionary = DEFS[type]
	if type == "call":
		var args := []
		var outs := []
		var f = funcs.get(str(fields.get("function", "")))
		if f != null:
			for p in f.params:
				args.append([p[1], type_from_name(p[0]), "0" if p[0] != "string" else ""])
			if f.returns != "void":
				outs.append(["result", type_from_name(f.returns), "result"])
		return {"args": args, "outs": outs, "groups": def.groups}
	if type in ["fire_server", "fire_clients", "invoke_server"]:
		# A row per value of the picked remote (Define Remote).
		var args := []
		var outs := []
		if type == "fire_clients":
			args.append(["player", INT, "", true, {"to": ["One player"]}])
		var r = CBTypes.remotes.get(str(fields.get("remote", "")))
		if r != null:
			for p in r.params:
				args.append([p[1], type_from_name(p[0]), "0" if p[0] != "string" else "", CBTypes.is_class_type(p[0])])
		if type == "invoke_server":
			args.append(["timeout", FLOAT, "5"])
			var at := str(r.get("answer", "bool")) if r != null else "bool"
			outs.append(["answer", type_from_name(at), "answer", "Answer"])
			outs.append(["answered", BOOL, "", "Answered"])
		return {"args": args, "outs": outs, "groups": def.groups}
	if type == "call_method":
		var args := [["object", OBJECT, "", true]]
		var outs := []
		var m = CBTypes.all_methods(str(fields.get("class", ""))).get(str(fields.get("method", "")))
		if m != null:
			for p in m.params:
				args.append([p[1], type_from_name(p[0]), "0" if p[0] != "string" else ""])
			if m.returns != "void":
				outs.append(["result", type_from_name(m.returns), "result"])
		return {"args": args, "outs": outs, "groups": def.groups}
	if type == "vector" and str(fields.get("dims", "3D")) == "2D":
		# The same brick with vector2s: no z.
		var args := []
		for a in def.args:
			if a[0] == "z":
				continue
			var c: Array = a.duplicate()
			if c[1] == VEC3:
				c[1] = VEC2
				c[2] = ", ".join(str(c[2]).split(",").slice(0, 2)).replace(" ,", ",").strip_edges()
			args.append(c)
		var outs: Array = (def.outs as Array).filter(func(o): return o[0] != "z")
		return {"args": args, "outs": outs, "groups": def.groups}
	if type == "call_c":
		var args := []
		for p in parse_params(fields.get("args", [])):
			args.append([p[1], type_from_name(p[0]), "0" if p[0] != "string" else ""])
		var ret := str(fields.get("returns", "void"))
		return {"args": args, "outs": [["result", type_from_name(ret), "result"]] if ret != "void" else [], "groups": def.groups}
	if type == "switch":
		var groups := []
		var cases: Array = fields.get("cases", [])
		for i in cases.size():
			groups.append("case_%d" % i)
		groups.append_array(["default", "next"])
		return {"args": def.args, "outs": [], "groups": groups}
	return {"args": def.get("args", []), "outs": def.get("outs", []), "groups": def.get("groups", [])}
