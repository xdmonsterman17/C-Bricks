#include <stdio.h>
#include "cbricks.h"
#include "api_probe.h"

/* The runtime calls a program's own C can use: drawing a mesh turned about two axes, a line that lies on a
   surface, and the input queries (nothing is typed or released here). */
int api_probe(void) {
    static int frame = 0;
    static cb_mesh *m = NULL;
    frame++;
    if (!m) {
        m = cb_mesh_new();
        cb_mesh_triangle(m, cb_v3(-1, 0, 0), cb_v3(0, 0, 1), cb_v3(1, 0, 0), cb_color("ORANGE"));
        cb_mesh_finish(m, false, true, 0, 0);
    }
    cb_clear(cb_color("SKYBLUE"));
    cb_camera(cb_v3(0, 3, 4), cb_v3(0, 0, 0), 60.0, false);
    cb_begin_3d();
    cb_draw_mesh_rot(m, cb_v3(0, 0, 0), cb_v3(1, 1, 1), cb_v3(90, 0, 0), cb_color("ORANGE"));
    cb_draw_mesh_rot(m, cb_v3(1.5, 0, 0), cb_v3(1, 1, 1), cb_v3(0, 45, 30), cb_color("GREEN"));
    cb_draw_line3d_biased(cb_v3(-1, 0, 0), cb_v3(1, 0, 0), cb_color("BLACK"));
    cb_end_3d();
    if (frame < 5)
        return 0;
    printf("released %d, typed %d\n", cb_mouse_released(CB_MOUSE_LEFT) ? 1 : 0, cb_char_typed());
    printf("shot %d\n", cb_screenshot("api.png") ? 1 : 0);
    return 1;
}
