# CWSDPMI r7 (MS-DOS programs' DPMI host)

`CWSDSTUB.EXE` and `cwsdpmi.doc` from `csdpmi7b.zip`
(https://www.delorie.com/pub/djgpp/current/v2misc/csdpmi7b.zip, sha256
deacda0488e1cdd7c4a9f32fab45662b34c0ed6b2d7d4d13bc07041b62004a8c), unmodified.

C-Bricks puts `CWSDSTUB.EXE` in front of every MS-DOS program it builds (DJGPP's COFF image
appended to it, as `cwsdpmi.doc` describes), so the program runs on plain DOS without a
separate CWSDPMI.EXE.

CWSDPMI is Copyright (C) 1995-2010 Charles W Sandmann. Its licence (`cwsdpmi.doc`): it may be
redistributed under the GPL with source, or without source when unmodified and users are told
they may get the source. **The source** is at
https://www.delorie.com/pub/djgpp/current/v2misc/csdpmi7s.zip.
