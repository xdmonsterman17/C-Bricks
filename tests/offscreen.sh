#!/usr/bin/env sh
# Runs a command (the editor's UI check, the example layout tool, the export) where it can't
# bother the person at this computer (user, 2026-11-08: videos skipped while tests ran):
# lowest CPU and disk priority, its windows on a private virtual display (Xvfb: nothing opens
# on the screen, nothing takes the keyboard's focus), Mesa's software OpenGL on 2 threads.
#   tests/offscreen.sh godot --path . --resolution 1600x900 -s res://tests/ui_check.gd
# Without xvfb-run it still runs at low priority, on the real display.
export LP_NUM_THREADS=2
if command -v xvfb-run >/dev/null 2>&1; then
    exec nice -n 19 ionice -c 3 xvfb-run -a -s "-screen 0 1920x1080x24 -nolisten tcp" "$@"
fi
exec nice -n 19 ionice -c 3 "$@"
