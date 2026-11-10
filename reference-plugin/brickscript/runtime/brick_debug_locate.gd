@tool
extends RefCounted

## Where in a brickscript an error happened, and which brick made that line.
## Kept apart from the autoload so the game and the editor (and tests) share
## it without loading the compiler.

const EXTENSIONS: PackedStringArray = ["bricklocal", "brickserver"]
static var _marker: RegEx = RegEx.create_from_string("  # brick (\\d+)$")


## [file, line] of the brickscript line an error comes from: the error's own
## place if that's a brickscript (a script error), else the first brickscript
## frame of its backtrace (an engine error raised by a call it made); [] if
## no brickscript is involved.
static func locate(file: String, line: int, backtraces: Array) -> Array:
	if EXTENSIONS.has(file.get_extension()):
		return [file, line]
	for backtrace: Variant in backtraces:
		var frames: ScriptBacktrace = backtrace as ScriptBacktrace
		if frames == null:
			continue
		for index: int in frames.get_frame_count():
			if EXTENSIONS.has(frames.get_frame_file(index).get_extension()):
				return [frames.get_frame_file(index), frames.get_frame_line(index)]
	return []


## The brick a line of generated code belongs to: its marker, or the nearest
## marked line above it in the same function (0 if none). `line` counts from
## 1, as errors do.
static func brick_at_line(source: String, line: int) -> int:
	var lines: PackedStringArray = source.split("\n")
	for index: int in range(mini(line, lines.size()) - 1, -1, -1):
		var hit: RegExMatch = _marker.search(lines[index])
		if hit != null:
			return int(hit.get_string(1))
		if index < line - 1 and lines[index].begins_with("func "):
			break
	return 0
