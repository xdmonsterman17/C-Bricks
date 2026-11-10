# Watt-32 (TCP/IP for MS-DOS: BSD sockets for the DJGPP target)

Built 2026-11-09 from https://github.com/gvanem/Watt-32 commit `b619bfef4f9b4bcdaef20b18b3844d50f274af13`
(Waterloo TCP by Erick Engelke, Watt-32 by Gisle Vanem and contributors: free software, "you may use it and
pass it on": `README.waterloo` is its own text). `lib/libwatt.a` (sha256 `e6a9ea72...a95b`) and `inc/` are what
a DJGPP program needs; the source is the repository above.

How it was built here (a Pi, aarch64, cross-compiling): `util/{bin2c,mkdep,mklang,mkmake}.c` compiled with the
host gcc (mkmake against libslang.so.2 with a stub `slang.h`), `sh configur.sh djgpp`, `util/errnos.c` built for DJGPP
and run in DOSBox-X (`-s` > `src/build/djgpp/syserr.c`, `-e` > `inc/sys/djgpp.err`), nasm (Debian's) for
`asmpkt.nas`, then `make -f djgpp.mak` with `WATT_ROOT` set.
