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

    with open(os.path.join(ROOT, "toolchains_manifest.json"), "w") as f:
        json.dump({"format": 1, "tools": tools}, f, indent=1)
        f.write("\n")
    print("wrote toolchains_manifest.json;", "upload build/release/*.tar.xz to the release", tag)


main()
