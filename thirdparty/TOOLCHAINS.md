# Toolchains of the C-Bricks editor

Since 2026-11-10 the editor is slim and its Toolchains window downloads these (`toolchains_manifest.json`: URL, size and sha256 per kind of computer; DJGPP and DOSBox-X from this project's GitHub release `toolchains-1`, made by `tools/make_toolchain_release.py`; zig from ziglang.org, CMake from Kitware, Emscripten from emsdk's tag). `./export.sh --with-toolchains` still embeds zig, DJGPP and DOSBox-X, as described below.

The editor carries (inside its executable; unpacked into its user folder on first use, or a `toolchains/` folder beside it) holds the programs C-Bricks calls to turn the generated C into programs.
The editor looks here first, then on PATH and the usual folders. Nothing here is modified.

| Folder | Program | Licence | Source |
|---|---|---|---|
| `zig/` | zig 0.17.1 (`zig cc`: native, Windows, macOS, Linux, BSDs, WASI cross builds) | MIT | https://ziglang.org/download/ , https://github.com/ziglang/zig |
| `djgpp/` | DJGPP, GCC 12.2 + binutils + the DJGPP C library (MS-DOS builds), built from source with build-djgpp | GPL / LGPL (GCC, binutils), DJGPP's own licence (libc) | https://github.com/andrewwutw/build-djgpp , https://www.delorie.com/djgpp/ |
| `dosbox-x/` | DOSBox-X 2025.02.01 (Run for MS-DOS builds, and the tests): `dosbox-x` is a script starting `dosbox-x.bin` with `lib/` (SDL2, SDL2_net, FluidSynth, libpcap, libslirp, opus / vorbis / FLAC / mp3 and the other libraries it needs, copied from Debian / Raspberry Pi OS) on its library path. The C / C++ runtime, OpenGL, X11, Wayland, audio servers and common system libraries are the machine's own | GPL-2.0 (the libraries: zlib, LGPL-2.1, BSD and similar: their source is Debian's, `apt source <package>`) | https://github.com/joncampbell123/dosbox-x |

The GPL programs are shipped as unmodified binaries: their source is at the links above (the exact versions named here), and the
editor's download page offers it on request. Emscripten (the Web target, ~1 GB) isn't shipped: install it with emsdk; the editor
also looks in `toolchains/emscripten/`.

Also in `thirdparty/` (compiled into MS-DOS network programs, not shipped as tools): `watt32/` (Watt-32, free software: its README.waterloo) and `pktdrvr/` (Crynwr's NE2000 packet driver, GPL).
