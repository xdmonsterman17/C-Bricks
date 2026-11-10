DJGPP and DOSBox-X for the C-Bricks editor's Toolchains window (Linux ARM64 only).

These two files are downloaded by the editor when you press **Install** on DJGPP or DOSBox-X (it checks each
file's sha256 against the editor's `toolchains_manifest.json`). You don't need to download them by hand.
zig, CMake and Emscripten are downloaded from their own sites.

| File | Contents | sha256 |
|---|---|---|
| `djgpp-aarch64-linux.tar.xz` | DJGPP: GCC 12.2 + binutils + the DJGPP C library, built from source with build-djgpp, unmodified (builds MS-DOS programs) | 5f475ee0a1997d426e31ea5e143cd4d1e3c45497a9683b2bcb59bc7d8ee9f981 |
| `dosbox-x-aarch64-linux.tar.xz` | DOSBox-X 2025.02.01 (Debian's binary, unmodified) with the shared libraries it needs in `lib/` and a `dosbox-x` start script | 076fe16f4b2ecaa60010f13de9f714306d8cee40898386d67290c619b4f5e577 |

**Licenses and source (GPL).** These are GPL / LGPL programs, offered unmodified; this repository's
`LICENSE` does not apply to them.
- DJGPP: GCC and binutils are GPL, the DJGPP library has its own terms. Source and build recipe:
  https://github.com/andrewwutw/build-djgpp, https://www.delorie.com/djgpp/
- DOSBox-X 2025.02.01: GPL-2.0. Source: https://github.com/joncampbell123/dosbox-x . The bundled libraries (SDL2,
  FluidSynth, libpcap, libslirp, opus, vorbis, FLAC and others) are Debian's: `apt source <package>` for the
  version in Debian 13 (trixie).
- Full list with licenses: `NOTICE.md` and `thirdparty/TOOLCHAINS.md` in the repository.
If a source link stops working, ask the author for the source.
