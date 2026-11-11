#!/usr/bin/env sh
# Exports the C-Bricks editor for this computer into build/<platform>/ (Linux ARM64 / x86_64, macOS, Windows).
# Usage: ./export-editor.sh [--with-toolchains] [path-to-godot]
# Slim by default (user, 2026-11-10: the executable was 300 MB): ~100 MB; the editor's Toolchains window downloads zig,
# DJGPP, DOSBox-X, Emscripten and CMake when they're wanted (toolchains_manifest.json lists where from:
# tools/make_toolchain_release.py). --with-toolchains puts zig, DJGPP and DOSBox-X inside the executable as before
# (~308 MB, for a computer with no internet): unpacked on first use.
# --all (2026-11-10): also the editor for other computers (Linux x86_64, Windows x86_64 / ARM64, macOS universal; Godot's
# export templates carry them all) packed into build/release/ for a GitHub release. Slim only; those builds are untested
# here (no Windows / macOS machine): the examples aren't prebuilt in them (prebuilt/ is for this computer's compiler).
WITH_TOOLCHAINS=0
ALL=0
while [ "${1#--}" != "$1" ]; do
  case "$1" in
    --with-toolchains) WITH_TOOLCHAINS=1 ;;
    --all) ALL=1 ;;
    *) echo "export-editor.sh: unknown option $1"; exit 1 ;;
  esac
  shift
done
GODOT="${1:-godot}"
cd "$(dirname "$0")"
# This computer's preset (export_presets.cfg) and output folder.
case "$(uname -s)-$(uname -m)" in
  Linux-aarch64|Linux-arm64) HOST_NAME="Linux ARM64"; HOST_DIR=linux-arm64 ;;
  Linux-x86_64) HOST_NAME="Linux x86_64"; HOST_DIR=linux-x86_64 ;;
  Darwin-*) HOST_NAME="macOS"; HOST_DIR=macos ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64) HOST_NAME="Windows x86_64"; HOST_DIR=windows-x86_64 ;;
  *) echo "export-editor.sh: no export preset for $(uname -s) $(uname -m): use Godot's Project > Export"; exit 1 ;;
esac
if [ "$WITH_TOOLCHAINS" = 1 ] && [ "$HOST_DIR" != linux-arm64 ]; then
  echo "export-editor.sh: --with-toolchains is only for the Linux ARM64 build"; exit 1
fi
# Started from the file manager (right-click > Execute: no terminal): reopen itself in one, which closes
# 3 seconds after the export is done (user, 2026-11-09).
if [ ! -t 1 ] && [ -z "$CBRICKS_IN_TERMINAL" ] && command -v lxterminal >/dev/null 2>&1; then
  export CBRICKS_IN_TERMINAL=1
  exec lxterminal --title="C-Bricks export" -e "$0" "$@"
fi
# Gently (user, 2026-11-08: videos skipped while things ran): lowest CPU and disk priority.
renice -n 19 -p $$ >/dev/null 2>&1
ionice -c 3 -p $$ >/dev/null 2>&1
mkdir -p "build/$HOST_DIR"
# Every example compiled first (prebuilt/, shipped in the pack): their first Run is instant.
# (only the Linux ARM64 preset ships them; elsewhere an example compiles on its first Run)
if [ "$HOST_DIR" = linux-arm64 ]; then
"$GODOT" --headless --path . -s res://tools/prebuild.gd || echo "export-editor.sh: some examples weren't prebuilt (see above): they compile on their first Run"
fi

if [ "$WITH_TOOLCHAINS" = 1 ]; then
# The toolchains (2026-11-09): zig, DJGPP (MS-DOS) and DOSBox-X are gathered in build/toolchains (kept between
# exports), zipped into toolchains_pack/ and exported INSIDE the executable (2026-11-09, user: one single file):
# the editor unpacks them into its user folder the first time something is built (Toolchains.unpack).
# Taken from where they're installed here (~/.local/opt, /usr/bin); a missing one is skipped.
[ -d build/linux-arm64/toolchains ] && [ ! -d build/toolchains ] && mv build/linux-arm64/toolchains build/toolchains
OUT=build/toolchains
mkdir -p "$OUT"  # (kept between exports: ~600 MB; delete the folder to bundle again)
copy_tool() {  # name, source folder
  if [ -d "$OUT/$1" ]; then echo "export-editor.sh: $1 already bundled"; elif [ -d "$2" ]; then cp -aL "$2" "$OUT/$1" && echo "export-editor.sh: $1 bundled ($(du -sh "$OUT/$1" | cut -f1))"; else echo "export-editor.sh: $1 not found at $2: not bundled"; fi
}
copy_tool zig "$HOME/.local/opt/zig"
copy_tool djgpp "$HOME/.local/opt/djgpp"
# DOSBox-X (2026-11-09: with its libraries): the binary is kept as dosbox-x.bin and started by a small `dosbox-x`
# script that points LD_LIBRARY_PATH at dosbox-x/lib, so a machine without SDL2 and friends runs it too. Bundled:
# every library the binary needs (ldd, transitively) except the ones any Linux desktop has (the C / C++ runtime,
# OpenGL, X11, Wayland, Mesa, audio servers, D-Bus, GLib and the common compression / font libraries): those stay the
# machine's own, whose graphics drivers they must match.
if [ -x "$OUT/dosbox-x/dosbox-x" ] && [ -d "$OUT/dosbox-x/lib" ]; then
  echo "export-editor.sh: dosbox-x already bundled"
elif [ -x /usr/bin/dosbox-x ]; then
  rm -rf "$OUT/dosbox-x"; mkdir -p "$OUT/dosbox-x/lib"
  cp -aL /usr/bin/dosbox-x "$OUT/dosbox-x/dosbox-x.bin"
  SYSTEM='^(linux-vdso|ld-linux|(libc|libm|libdl|libpthread|librt|libgcc_s|libstdc\+\+|libffi|libz|libexpat|libbz2|libgomp|libresolv|libmd|libbsd|libudev|liblzma|libzstd|libcap|libpcre2-8|libselinux)\.so|(libGL|libEGL|libX|libxcb|libwayland|libdrm|libgbm|libasound|libpulse|libdbus|libglib|libgobject|libgmodule|libfreetype|libpng|libbrotli|libxkbcommon|libsystemd|libasyncns|libtinfo|libatomic|libdb)[A-Za-z0-9_.-]*)'
  ldd /usr/bin/dosbox-x | awk '/=> \// {print $1, $3}' | while read -r name path; do
    if ! echo "$name" | grep -Eq "$SYSTEM"; then cp -aL "$path" "$OUT/dosbox-x/lib/$name"; fi
  done
  cat > "$OUT/dosbox-x/dosbox-x" <<'WRAP'
#!/bin/sh
d=$(dirname "$(readlink -f "$0")")
LD_LIBRARY_PATH="$d/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$d/dosbox-x.bin" "$@"
WRAP
  chmod +x "$OUT/dosbox-x/dosbox-x"
  echo "export-editor.sh: dosbox-x bundled with $(ls "$OUT/dosbox-x/lib" | wc -l) libraries ($(du -sh "$OUT/dosbox-x" | cut -f1))"
else
  echo "export-editor.sh: dosbox-x not found: not bundled"
fi
cp thirdparty/TOOLCHAINS.md "$OUT/README.md"
python3 tools/make_toolchain_pack.py "$OUT" toolchains_pack
else
rm -rf toolchains_pack  # (slim: nothing of the toolchains goes into the executable)
echo "export-editor.sh: slim export (no toolchains inside: the Toolchains window downloads them; --with-toolchains bundles them)"
fi
rm -f "build/$HOST_DIR/C-Bricks.pck"
"$GODOT" --headless --path . --export-release "$HOST_NAME"
if [ "$ALL" = 1 ] && [ "$WITH_TOOLCHAINS" = 0 ]; then
  mkdir -p build/release
  # preset | folder | file | archive
  for spec in "Linux ARM64|linux-arm64|C-Bricks.arm64|tar" "Linux x86_64|linux-x86_64|C-Bricks.x86_64|tar" "Windows x86_64|windows-x86_64|C-Bricks.exe|zip" "Windows ARM64|windows-arm64|C-Bricks.exe|zip" "macOS|macos|C-Bricks.zip|copy"; do
    name=${spec%%|*}; rest=${spec#*|}; dir=${rest%%|*}; rest=${rest#*|}; file=${rest%%|*}; kind=${rest#*|}
    if [ "$dir" != "$HOST_DIR" ]; then
      rm -rf "build/$dir"; mkdir -p "build/$dir"
      "$GODOT" --headless --path . --export-release "$name" || { echo "export-editor.sh: $name failed"; continue; }
    fi
    # one archive each: tar.gz for Linux (keeps the executable bit), zip for Windows, macOS's own zip
    case "$kind" in
      tar) tar -C "build/$dir" -czf "build/release/C-Bricks-$dir.tar.gz" "$file" ;;
      zip) rm -f "build/release/C-Bricks-$dir.zip"; (cd "build/$dir" && python3 -m zipfile -c "../release/C-Bricks-$dir.zip" "$file") ;;
      copy) cp "build/$dir/$file" "build/release/C-Bricks-$dir.zip" ;;
    esac
  done
  ls -l build/release/C-Bricks-*
fi
echo "export-editor.sh: done."
if [ -n "$CBRICKS_IN_TERMINAL" ]; then
  echo "(this window closes in 3 seconds)"
  sleep 3
fi
