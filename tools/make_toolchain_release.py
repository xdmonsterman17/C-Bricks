#!/usr/bin/env python3
"""Writes toolchains_manifest.json (what the editor's Toolchains window can download) and, for the tools that have no
official download (DJGPP, DOSBox-X: built here), their archives for a GitHub release.

    python3 tools/make_toolchain_release.py [--tag toolchains-1] [--no-archives]

Archives go to build/release/ (from build/toolchains, which export.sh gathers: djgpp/, dosbox-x/); upload them to the
release named by --tag (the manifest's URLs point there):  gh release create toolchains-1 build/release/*
zig (ziglang.org), CMake (Kitware's releases) and Emscripten (emsdk's tag) are downloaded from their own sites: the
manifest only records their URLs, sizes and sha256. Needs the network (zig's index.json, CMake's SHA-256 file)."""
import hashlib, json, os, subprocess, sys, tarfile, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "xdmonsterman17/C-Bricks"
ZIG = "0.17.1"
CMAKE = "3.31.6"
EMSDK = "6.0.13"
HOST = "aarch64-linux"  # what the archives made here run on

# Downloaded from their authors' own releases (pinned: URL, sha256 and size checked when this was written, 2026-11-10).
# DJGPP: andrewwutw/build-djgpp v3.4 (GCC 12.2, the same as the one built here; unpacks to djgpp/). The macOS one is x86_64
# (Apple Silicon runs it through Rosetta), the Windows one x86_64 (Windows on ARM emulates it).
DJGPP_UP = "https://github.com/andrewwutw/build-djgpp/releases/download/v3.4/"
DJGPP_PLATFORMS = {
    "x86_64-linux": ("djgpp-linux64-gcc1220.tar.bz2", "8464f17017d6ab1b2bb2df4ed82357b5bf692e6e2b7fee37e315638f3d505f00", 80596981),
    "x86_64-macos": ("djgpp-osx-gcc1220.tar.bz2", "cf605786efe14166d32aede89c37e41bf1272178ae73a624e7e84761cca38549", 59883520),
    "aarch64-macos": ("djgpp-osx-gcc1220.tar.bz2", "cf605786efe14166d32aede89c37e41bf1272178ae73a624e7e84761cca38549", 59883520),
    "x86_64-windows": ("djgpp-mingw-gcc1220-standalone.zip", "6f88b531d216f4d92668c960b5cde9a829b5611e06d2c3e431041e33f01c1a52", 126821837),
    "aarch64-windows": ("djgpp-mingw-gcc1220-standalone.zip", "6f88b531d216f4d92668c960b5cde9a829b5611e06d2c3e431041e33f01c1a52", 126821837),
}
# DOSBox-X 2026.10.01 (joncampbell123/dosbox-x): official Windows and macOS builds (zips; no strip: the programs sit in
# bin/x64/Release/, bin/ARM64/Release/ and dosbox-x/dosbox-x.app/Contents/MacOS/, which Toolchains.search_dirs knows).
# There is no official Linux x86_64 binary (distros package it): install it yourself there.
DBX_UP = "https://github.com/joncampbell123/dosbox-x/releases/download/dosbox-x-v2026.10.01/"
DBX_PLATFORMS = {
    "x86_64-windows": ("dosbox-x-vsbuild-win64-2026.10.01-portable.zip", "3c50915e63aefe35777d65ebb4391a06b4a2c2342e4c75cbee6bbda4c6916e33", 44575207),
    "aarch64-windows": ("dosbox-x-vsbuild-arm64-2026.10.01-portable.zip", "f1a15bcad81610429aea07ac5b74c81b8f78b58527e34b2fabb19ffafb429614", 40966368),
    "x86_64-macos": ("dosbox-x-macosx-x86_64-2026.10.01.zip", "a0605348355ff4a45c781f124c44122e97156ae3f7d048637f545c9de641bedb", 102364921),
    "aarch64-macos": ("dosbox-x-macosx-arm64-2026.10.01.zip", "8514ab856e8ac2611fbdac7adf334c34085c1e00d700a88711f842adec50240f", 94369585),
}


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def size_of(url):
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"])


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    tag = "toolchains-1"
    if "--tag" in sys.argv:
        tag = sys.argv[sys.argv.index("--tag") + 1]
    tools = {}

    # zig: official index
    idx = json.loads(fetch("https://ziglang.org/download/index.json"))[ZIG]
    plats = {}
    for p in ["x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows", "aarch64-windows"]:
        e = idx[p]
        plats[p] = {"url": e["tarball"], "sha256": e["shasum"], "size": int(e["size"]), "strip": 1}
    tools["zig"] = {"version": ZIG, "platforms": plats}

    # CMake: Kitware's release + its SHA-256 file
    base = "https://github.com/Kitware/CMake/releases/download/v%s/cmake-%s-" % (CMAKE, CMAKE)
    sums = {l.split()[1]: l.split()[0] for l in fetch(base + "SHA-256.txt").decode().splitlines() if len(l.split()) == 2}
    plats = {}
    for p, f in [("x86_64-linux", "linux-x86_64.tar.gz"), ("aarch64-linux", "linux-aarch64.tar.gz"),
                 ("x86_64-macos", "macos-universal.tar.gz"), ("aarch64-macos", "macos-universal.tar.gz"),
                 ("x86_64-windows", "windows-x86_64.zip"), ("aarch64-windows", "windows-arm64.zip")]:
        name = "cmake-%s-%s" % (CMAKE, f)
        plats[p] = {"url": base + f, "sha256": sums[name], "size": size_of(base + f), "strip": 1}
    tools["cmake"] = {"version": CMAKE, "platforms": plats}

    # Emscripten: emsdk's tag (a zip of the emsdk scripts); the editor then runs `emsdk install / activate`
    url = "https://github.com/emscripten-core/emsdk/archive/refs/tags/%s.zip" % EMSDK
    z = os.path.join(ROOT, "build", "release", "emsdk-%s.zip" % EMSDK)
    os.makedirs(os.path.dirname(z), exist_ok=True)
    if not os.path.exists(z):
        open(z, "wb").write(fetch(url))
    em = {"url": url, "sha256": sha(z), "size": os.path.getsize(z), "strip": 1, "emsdk": EMSDK}
    tools["emscripten"] = {"version": EMSDK, "platforms": {p: dict(em) for p in
                           ["x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows", "aarch64-windows"]}}

    # DJGPP and DOSBox-X: built / packaged here, for this machine's kind only
    out = os.path.join(ROOT, "build", "release")
    src = os.path.join(ROOT, "build", "toolchains")
    for name, title in [("djgpp", "DJGPP"), ("dosbox-x", "DOSBox-X")]:
        arc = os.path.join(out, "%s-%s.tar.xz" % (name, HOST))
        if "--no-archives" not in sys.argv and os.path.isdir(os.path.join(src, name)) and not os.path.exists(arc):
            print("packing", name, "(xz: a few minutes)...")
            subprocess.check_call("tar -C '%s' -cf - %s | nice xz -T0 -6 > '%s'" % (src, name, arc), shell=True)
        if os.path.exists(arc):
            version = {"djgpp": "GCC 12.2", "dosbox-x": "2025.02.01"}[name]
            tools[name] = {"version": version, "platforms": {HOST: {
                "url": "https://github.com/%s/releases/download/%s/%s" % (REPO, tag, os.path.basename(arc)),
                "sha256": sha(arc), "size": os.path.getsize(arc), "strip": 1}}}
        else:
            tools[name] = {"version": "", "platforms": {}}
            print("no archive for", title, "(build/toolchains/%s missing)" % name)

    # the other computers' DJGPP / DOSBox-X: the authors' own downloads (pinned above)
    for name, up, table, strip, ver in [("djgpp", DJGPP_UP, DJGPP_PLATFORMS, 1, "GCC 12.2"), ("dosbox-x", DBX_UP, DBX_PLATFORMS, 0, "2026.10.01")]:
        for plat, (fn, h, size) in table.items():
            tools[name]["platforms"][plat] = {"url": up + fn, "sha256": h, "size": size, "strip": strip, "version": ver}

    with open(os.path.join(ROOT, "toolchains_manifest.json"), "w") as f:
        json.dump({"format": 1, "tools": tools}, f, indent=1)
        f.write("\n")
    print("wrote toolchains_manifest.json;", "upload build/release/*.tar.xz to the release", tag)


main()
