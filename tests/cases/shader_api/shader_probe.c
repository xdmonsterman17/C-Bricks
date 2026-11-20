#include <stdio.h>
#include "cbricks.h"
#include "shader_probe.h"

/* Custom shaders: a surface shader (stripes from the mesh's UVs, a tint uniform) spliced into the lit shader, a broken one
   (id 0, not fatal), and a post shader (a blue lift growing down the frame). Three quads: plain, striped red, striped green. */
static const char SURFACE[] =
    "uniform vec3 uTint;\n"
    "vec4 cb_surface(vec4 base, vec2 uv, vec3 normal) {\n"
    "    float s = step(0.5, fract(uv.x * 4.0 + cbTime * 0.0));\n"
    "    return vec4(mix(base.rgb, uTint, s), base.a);\n"
    "}\n";
static const char POST[] =
    "vec3 cb_post(vec3 c, vec2 uv) { return vec3(c.r, c.g, min(c.b + 0.35 * uv.y, 1.0)); }\n";

static cb_mesh *quad(void) {
    cb_mesh *m = cb_mesh_new();
    Vector3 n = cb_v3(0, 0, 1);
    cb_mesh_triangle_nuv(m, cb_v3(-1, -1, 0), cb_v3(-1, 1, 0), cb_v3(1, 1, 0), n, n, n, cb_v2(0, 1), cb_v2(0, 0), cb_v2(1, 0), cb_color("WHITE"));
    cb_mesh_triangle_nuv(m, cb_v3(-1, -1, 0), cb_v3(1, 1, 0), cb_v3(1, -1, 0), n, n, n, cb_v2(0, 1), cb_v2(1, 0), cb_v2(1, 1), cb_color("WHITE"));
    cb_mesh_finish(m, true, true, 0, 0);
    return m;
}

int shader_probe(void) {
    static int frame = 0;
    static cb_mesh *q = NULL;
    static cb_shader surf, bad, post;
    frame++;
    if (!q) {
        q = quad();
        surf = cb_shader_source(CB_SHADER_SURFACE, SURFACE);
        bad = cb_shader_source(CB_SHADER_SURFACE, "this is not glsl");
        post = cb_shader_source(CB_SHADER_POST, POST);
        cb_use_shader(post);
    }
    cb_clear(cb_color("DARKGRAY"));
    cb_camera(cb_v3(0, 0, 8), cb_v3(0, 0, 0), 50.0, false);
    cb_begin_3d();
    cb_draw_mesh(q, cb_v3(-2.5, 0, 0), cb_v3(1, 1, 1), 0, cb_color("WHITE"));
    cb_use_shader(surf);
    cb_shader_vec3(surf, "uTint", 1.0, 0.1, 0.1);
    cb_draw_mesh(q, cb_v3(0, 0, 0), cb_v3(1, 1, 1), 0, cb_color("WHITE"));
    cb_shader_vec3(surf, "uTint", 0.1, 1.0, 0.2);
    cb_draw_mesh(q, cb_v3(2.5, 0, 0), cb_v3(1, 1, 1), 0, cb_color("WHITE"));
    cb_use_default_shader(CB_SHADER_SURFACE);
    cb_end_3d();
    if (frame < 5)
        return 0;
    printf("surface %d, broken %d, post %d\n", surf.id > 0 ? 1 : 0, bad.id, post.id > 0 ? 1 : 0);
    {   /* unloading frees the slot: 40 loads in a row through the 32 slots (a preview reloading on every file change) */
        int i, ok = 0;
        for (i = 0; i < 40; i++) {
            cb_shader t = cb_shader_source(CB_SHADER_SURFACE, SURFACE);
            if (t.id > 0) ok++;
            cb_unload_shader(t);
        }
        printf("reloads %d\n", ok);
    }
    printf("shot %d\n", cb_screenshot("shader.png") ? 1 : 0);
    return 1;
}
