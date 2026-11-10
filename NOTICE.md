# Third-party notices

C-Bricks' own code is under the license in `LICENSE`. These components are not C-Bricks' and keep their
own licenses. "In your program?" says whether it can end up inside what you build and ship with the
editor; "What it asks of you" is the short version, not the license text (read that too).

## Inside the editor

| Component | License | Notes |
|---|---|---|
| **Godot Engine 4.7** (the editor is a Godot app) | MIT (+ the licenses of the libraries Godot itself includes: FreeType, ENet, mbedTLS, zlib, ...) | Godot's license and full list of third-party components: https://godotengine.org/license/ and `COPYRIGHT.txt` in https://github.com/godotengine/godot. The MIT notice must stay with copies of the engine. |

## In your programs (compiled in or copied beside what you build)

| Component | Where | License | In your program? | What it asks of you |
|---|---|---|---|---|
| **raylib 5.5** (Ramon Santamaria) | `thirdparty/raylib/` | zlib (`thirdparty/raylib/LICENSE`) | Yes, in every graphics program (PC targets, Web) | Don't misrepresent its origin; keep the notice if you ship its source. A binary needs no notice. |
| **GLFW** (inside raylib) | `thirdparty/raylib/src/external/glfw/` | zlib (`LICENSE.md` there) | Yes, with raylib's desktop backend | Same as raylib. |
| **stb_image, stb_image_write, stb_vorbis** (Sean Barrett) | `thirdparty/raylib/src/external/`, `stb_vorbis.c` in raylib's source | Public domain or MIT (each file's end says which) | stb_image / stb_image_write: yes, in MS-DOS programs and raylib programs; stb_vorbis: raylib's audio | Nothing. |
| **dr_wav, dr_mp3, dr_flac, miniaudio** (David Reid) | `thirdparty/raylib/src/external/` | Public domain or MIT-0 (each file's header) | Yes, in raylib's audio | Nothing. |
| **Other raylib-bundled headers** (cgltf, par_shapes, m3d, qoi, jar_xm, jar_mod, ...) | `thirdparty/raylib/src/external/` | Each has its own permissive license at its top (MIT, public domain, zlib) | Only when a program's features use them | Read the header. |
| **DJGPP's C library** | in the DJGPP toolchain (below) | DJGPP's own terms, with BSD-style and GPL-with-runtime-exception parts | Yes, in MS-DOS programs | Its terms allow distributing programs built with it; see https://www.delorie.com/djgpp/ for the details (not reviewed in depth here). |
| **zig's bundled C libraries** (musl, mingw-w64, ...) | in the zig download | Permissive (MIT and similar) | Yes, in programs cross-built with zig | See https://ziglang.org/ and each library's license (not reviewed in depth here). |
| **CWSDPMI r7** (Charles W Sandmann) | `thirdparty/cwsdpmi/` | GPL, or redistributable without source when unmodified *and your users are told they can get the source* (`cwsdpmi.doc`) | Yes, in front of every MS-DOS program (`CWSDSTUB.EXE`) | If you ship an MS-DOS program, tell users the source is at https://www.delorie.com/pub/djgpp/current/v2misc/csdpmi7s.zip. |
| **Watt-32** (Gisle Vanem; Waterloo TCP by Erick Engelke; BSD code) | `thirdparty/watt32/` | Free software: "you may use it and pass it on" (`README.waterloo`) and BSD (`inc/copying.bsd`) | Yes, in MS-DOS programs that use the network | Keep the BSD copyright notices if you ship its source or headers. |
| **DMXOPL** `GENMIDI.op2` (sneakernets) | `thirdparty/dmxopl/` | MIT (`LICENSE` there; the README asks for credit) | Copied beside an MS-DOS program that plays MIDI (unless you supply your own bank) | Keep its MIT notice with the file; credit is appreciated. |
| **Crynwr NE2000 packet driver** `NE2000.COM` | `thirdparty/pktdrvr/` | **GPL** (`GPL.DOC`, `COPYING.DOC`); source in http://crynwr.com/drivers/pktd11.zip | Not in what you build: the editor copies it beside a program only to Run it in DOSBox-X | If you ship it with a game yourself, the GPL applies to that file: ship its source or an offer for it. Real PCs use the driver for their own network card. |

## Programs the Toolchains window can download (not part of C-Bricks, not in your programs)

| Tool | License | Source / website |
|---|---|---|
| zig | MIT | https://ziglang.org/ , https://github.com/ziglang/zig |
| DJGPP (GCC 12.2, binutils, DJGPP libc) | GPL / LGPL (GCC, binutils); DJGPP's own terms (libc) | https://www.delorie.com/djgpp/ , https://github.com/andrewwutw/build-djgpp |
| DOSBox-X 2025.02.01 (with its libraries) | GPL-2.0 (libraries: LGPL, BSD, zlib and similar) | https://github.com/joncampbell123/dosbox-x ; the libraries' source is Debian's (`apt source <package>`) |
| Emscripten (via emsdk) | MIT / NCSA (+ LLVM's license) | https://emscripten.org/ |
| CMake | BSD-3-Clause | https://cmake.org/ |

The GPL programs (DJGPP, DOSBox-X) are offered as unmodified binaries from this project's GitHub release
`toolchains-1`; their source is at the links above, at the versions named. If a link is gone, ask the
author for the source.

The Brickscript addon is the author's own design reference; none of its code is in C-Bricks' released files.
