# pl_mpeg

`pl_mpeg.h` from https://github.com/phoboslab/pl_mpeg (Dominic Szablewski, MIT licence, SPDX identifier at the top of the
header), unmodified. A single-header MPEG-1 video + MP2 audio decoder and MPEG-PS demuxer in plain C.

C-Bricks compiles it (as `cb_pl_mpeg.h` + `cbricks_video.c`, see `scripts/runtime/cb_video.c`) only into programs that use video:
a `Video` object in a scene, or `cb_video_` calls in the project's own C. sha256 of the copied file:
3a8cb30c83c2a1147719c30fe0c8b93da2987aa43140077c575b39aaa75fc2c9
