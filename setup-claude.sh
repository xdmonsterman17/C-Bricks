#!/usr/bin/env bash
# Startup shell for C-Bricks: checks the workspace and its tools, then starts
# Claude Code with the resume prompt (CLAUDE.md's startup protocol).
#   ./SetupClaude.sh            check, then launch Claude
#   ./SetupClaude.sh --check    only check (no Claude)

set -e
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"

echo "--------------------------------------------------------"
echo "  C-Bricks: setting up the Claude workspace"
echo "--------------------------------------------------------"

missing=0
# 1. The project's folders
for d in scripts scripts/editor examples tests/cases icons; do
	if [ -d "$d" ]; then echo "ok   $d/"; else echo "MISSING: $d/"; missing=1; fi
done
if [ -d "../plugin-test/addons/brickscript" ]; then
	echo "ok   ../plugin-test/addons/brickscript/ (the design reference)"
else
	echo "WARNING: ../plugin-test/addons/brickscript/ not found: the editor's design reference (the user's Brickscript addon) is missing."
fi

# 2. The docs Claude works from
for f in CLAUDE.md PROGRESS.md DECISIONS.md BUGS.md DEBUG.md README.md; do
	if [ -f "$f" ]; then
		echo "ok   $f"
	else
		case "$f" in
			CLAUDE.md) echo "WARNING: CLAUDE.md not found: Claude has no instructions; recreate it from PROGRESS.md and the code." ;;
			PROGRESS.md) echo "WARNING: PROGRESS.md not found: Claude will need to rebuild it from the code and git history." ;;
			DECISIONS.md) echo "WARNING: DECISIONS.md not found: Claude should rebuild it from PROGRESS.md's history." ;;
			BUGS.md) echo "WARNING: BUGS.md not found: Claude should start one (Open / Fixed / Potential)." ;;
			DEBUG.md) echo "WARNING: DEBUG.md not found: Claude should rebuild it from tests/run_tests.gd." ;;
			README.md) echo "WARNING: README.md not found: Claude should rebuild it from scripts/node_defs.gd and the editor." ;;
		esac
	fi
done

# 3. Tools (installing system ones needs sudo: run those yourself)
command -v godot >/dev/null && echo "ok   godot ($(godot --version 2>/dev/null | head -1))" || { echo "MISSING: godot (4.7.2) on PATH"; missing=1; }
command -v cc >/dev/null || command -v gcc >/dev/null && echo "ok   C compiler ($(command -v cc || command -v gcc))" || echo "WARNING: no C compiler: sudo apt install build-essential"
command -v zig >/dev/null && echo "ok   zig $(zig version) (cross-compiling)" || echo "WARNING: zig missing (cross targets): download from ziglang.org into ~/.local/opt/zig, link ~/.local/bin/zig"
command -v cmake >/dev/null && echo "ok   $(cmake --version | head -1) (CMakeLists tests)" || echo "WARNING: cmake missing (testing exported CMakeLists.txt): sudo apt install cmake"
if command -v emcc >/dev/null || [ -x "$HOME/.local/opt/emsdk/upstream/emscripten/emcc" ]; then echo "ok   emcc (Emscripten, Web target)"; else echo "note: emcc (Emscripten) not installed: the Web target can't be built here (emsdk into ~/.local/opt/emsdk)"; fi
if [ -f /usr/include/X11/Xlib.h ] && [ -f /usr/include/GL/gl.h ]; then echo "ok   X11 / OpenGL headers (native raylib builds)"; else echo "note: no X11 / OpenGL dev headers: graphics projects can't build natively here (sudo apt install libx11-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev libgl-dev)"; fi

# 4. A quick health check: every script parses
bad=0
for f in scripts/*.gd scripts/editor/*.gd tests/*.gd; do
	if godot --headless --path . --check-only --script "$f" 2>&1 | grep -q "SCRIPT ERROR"; then
		echo "PARSE ERROR: $f"; bad=1
	fi
done
[ $bad -eq 0 ] && echo "ok   every GDScript file parses"

if [ $missing -ne 0 ]; then
	echo "Something essential is missing (above); fix it before starting."
fi
if [ "${1:-}" = "--check" ]; then
	exit $missing
fi

echo "--------------------------------------------------------"
echo "Launching Claude Code..."
echo "--------------------------------------------------------"

# 5. Launch Claude with the resume prompt (never asks to regenerate existing files)
claude "Read CLAUDE.md and run its startup protocol. Read PROGRESS.md and DECISIONS.md: briefly summarize where we are, run the test cases, read ~/Documents/Projects/C-Bricks/C-Vert/EDITOR-NOTES.md (editor notes from a separate run that used the editor; it is updated over time: summarize what's new or still open, and re-check entries against the code), then ask me the questions under 'Open (waiting on the user)' before starting new work. Keep all existing files; if PROGRESS.md disagrees with the code on disk, trust the code and sync PROGRESS.md before continuing."
