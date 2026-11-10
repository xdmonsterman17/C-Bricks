#!/usr/bin/env python3
"""Packs the bundled toolchains (a staging folder) for export.sh, which puts the result inside the editor's
executable (res://toolchains_pack/). The editor unpacks it on first use (Toolchains.unpack).
Files: toolchains.pak (every file zlib-compressed on its own, one after another: a zip's by-name lookup is too slow
for 20,000 files in Godot's reader), toolchains.idx (one line per file: offset, compressed size, size,
executable 0/1, path) and toolchains.id (what the unpacked folder is named: a new pack unpacks again).
Usage: make_toolchain_pack.py <stage folder> <out folder>"""
import os, sys, zlib, time

stage, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
pak, idx, ident = (os.path.join(out, n) for n in ("toolchains.pak", "toolchains.idx", "toolchains.id"))
files = []
for d, dirs, fs in os.walk(stage):
    dirs.sort()
    for f in sorted(fs):
        files.append(os.path.join(d, f))
newest = max((os.path.getmtime(p) for p in files), default=0)
if all(os.path.exists(p) for p in (pak, idx, ident)) and os.path.getmtime(pak) > newest:
    print("make_toolchain_pack: up to date (%d MB)" % (os.path.getsize(pak) // 2**20))
    sys.exit(0)
lines = []
execs = 0
with open(pak + ".part", "wb") as w:
    for p in files:
        rel = os.path.relpath(p, stage).replace(os.sep, "/")
        data = open(p, "rb").read()
        comp = zlib.compress(data, 3)
        x = 1 if os.access(p, os.X_OK) else 0
        execs += x
        lines.append("%d %d %d %d %s" % (w.tell(), len(comp), len(data), x, rel))
        w.write(comp)
os.replace(pak + ".part", pak)
with open(idx, "w") as f:
    f.write("\n".join(lines) + "\n")
with open(ident, "w") as f:
    f.write(str(int(time.time())))
print("make_toolchain_pack: %d files, %d executable, %d MB" % (len(files), execs, os.path.getsize(pak) // 2**20))
