#!/usr/bin/env python3
"""Makes the MS-DOS examples: copies of other examples with Target MS-DOS (so they stay in
step with their generators: run those first). examples/dos_* is generated: change this.
  python3 tests/make_dos_examples.py
  tests/offscreen.sh godot --path . -s res://tests/layout_example.gd -- dos_gem_collector   (and dos_gem_hunt: the layout)"""
import os, re, shutil, subprocess, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "examples")
for src, name in [("hello_world", "Hello World (MS-DOS)"), ("fizzbuzz", "FizzBuzz (MS-DOS)"),
                  ("gem_collector", "Gem Collector (MS-DOS)"), ("gem_hunt", "Gem Hunt (MS-DOS)"), ("net_gems", "Net Gems (MS-DOS)")]:
    dst = os.path.join(root, "dos_" + src)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(os.path.join(root, src), dst, ignore=shutil.ignore_patterns(".build", "*.uid"))
    if src in ("gem_collector", "gem_hunt"):   # its own, lighter version (320 x 200; Gem Hunt is the scene-tree one): then laid out by the app
        subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "make_" + src + ".py"), dst], env=dict(os.environ, DOS="1"), check=True)
    p = os.path.join(dst, "project.cbproj")
    s = open(p).read()
    s = re.sub(r'name="[^"]*"', 'name="%s"' % name, s, count=1)
    s = s.replace('target="native"', 'target="dos"')
    open(p, "w").write(s)
    print("wrote", dst)
