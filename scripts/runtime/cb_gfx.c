/* C-Bricks graphics (2026-11-08: backend-neutral): colors by name or #rrggbb, how Print shows a
   texture / sound / music, the graphics bricks' C functions, the world (placement, physics,
   drawing), the UI, frames, pause. Everything that touches a graphics library goes through the
   cb_be_* functions (cbricks.h), which the target's backend implements (cbricks_backend.c:
   raylib's today). Added to projects that use graphics bricks. */
#include "cbricks.h"
#include <ctype.h>

static int cb_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = (char)tolower((unsigned char)c);
    if (c >= 'a' && c <= 'f') return 10 + c - 'a';
    return 0;
}

cb_rgba cb_color(const char *name) {
    static const struct { const char *name; cb_rgba color; } named[] = {
        { "LIGHTGRAY", { 200, 200, 200, 255 } }, { "GRAY", { 130, 130, 130, 255 } }, { "DARKGRAY", { 80, 80, 80, 255 } },
        { "YELLOW", { 253, 249, 0, 255 } }, { "GOLD", { 255, 203, 0, 255 } }, { "ORANGE", { 255, 161, 0, 255 } },
        { "PINK", { 255, 109, 194, 255 } }, { "RED", { 230, 41, 55, 255 } }, { "MAROON", { 190, 33, 55, 255 } },
        { "GREEN", { 0, 228, 48, 255 } }, { "LIME", { 0, 158, 47, 255 } }, { "DARKGREEN", { 0, 117, 44, 255 } },
        { "SKYBLUE", { 102, 191, 255, 255 } }, { "BLUE", { 0, 121, 241, 255 } }, { "DARKBLUE", { 0, 82, 172, 255 } },
        { "PURPLE", { 200, 122, 255, 255 } }, { "VIOLET", { 135, 60, 190, 255 } }, { "DARKPURPLE", { 112, 31, 126, 255 } },
        { "BEIGE", { 211, 176, 131, 255 } }, { "BROWN", { 127, 106, 79, 255 } }, { "DARKBROWN", { 76, 63, 47, 255 } },
        { "WHITE", { 255, 255, 255, 255 } }, { "BLACK", { 0, 0, 0, 255 } }, { "BLANK", { 0, 0, 0, 0 } },
        { "MAGENTA", { 255, 0, 255, 255 } }, { "RAYWHITE", { 245, 245, 245, 255 } },
    };
    size_t i, n;
    cb_rgba c = { 0, 0, 0, 255 };
    if (!name) return c;
    if (name[0] == '#') {
        n = strlen(name + 1);
        if (n >= 6) {
            c.r = (unsigned char)(cb_hex(name[1]) * 16 + cb_hex(name[2]));
            c.g = (unsigned char)(cb_hex(name[3]) * 16 + cb_hex(name[4]));
            c.b = (unsigned char)(cb_hex(name[5]) * 16 + cb_hex(name[6]));
            c.a = n >= 8 ? (unsigned char)(cb_hex(name[7]) * 16 + cb_hex(name[8])) : 255;
        }
        return c;
    }
    for (i = 0; i < sizeof named / sizeof named[0]; i++) {
        const char *a = name, *b = named[i].name;
        while (*a && *b && toupper((unsigned char)*a) == *b) { a++; b++; }
        if (*a == 0 && *b == 0)
            return named[i].color;
    }
    return c;
}

void cb_show_texture(FILE *f, const void *value) {
    const cb_texture *t = (const cb_texture *)value;
    fprintf(f, "texture %dx%d%s", t->width, t->height, t->id ? "" : " (not loaded)");
}

void cb_show_sound(FILE *f, const void *value) {
    const cb_sound *s = (const cb_sound *)value;
    fprintf(f, "sound (%u frames)", s->frames);
}

void cb_show_music(FILE *f, const void *value) {
    const cb_music *m = (const cb_music *)value;
    if (!m->id)
        fputs("music (not loaded)", f);
    else
        fprintf(f, "music (%.1f s%s)", (double)m->length, m->looping ? ", looping" : "");
}

static cb_rect cb_rect_of(double x, double y, double width, double height) {
    cb_rect r;
    r.x = (float)x; r.y = (float)y; r.width = (float)width; r.height = (float)height;
    return r;
}

/* ---- the graphics bricks (the generated C calls these) ---- */
bool cb_open_window(int width, int height, const char *title, int fps, bool esc_closes) {
    return cb_be_open(width, height, title, fps, esc_closes);
}

void cb_window_end(void) { cb_be_close(); }
void cb_clear(cb_rgba c) { cb_be_clear(c); }
void cb_draw_rect(int x, int y, int width, int height, cb_rgba c) { cb_be_rect(cb_rect_of(x, y, width, height), cb_v2(0, 0), 0, c); }
void cb_draw_rect_lines(int x, int y, int width, int height, cb_rgba c) { cb_be_rect_lines(cb_rect_of(x, y, width, height), 1, c); }
void cb_draw_circle(int x, int y, double radius, cb_rgba c) { cb_be_circle(cb_v2(x, y), radius, c); }
void cb_draw_line(int x1, int y1, int x2, int y2, cb_rgba c) { cb_be_line(cb_v2(x1 + 0.5, y1 + 0.5), cb_v2(x2 + 0.5, y2 + 0.5), c); }
void cb_draw_text(const char *text, int x, int y, int size, cb_rgba c) { cb_be_text(text, cb_v2(x, y), cb_v2(0, 0), 0, size < 10 ? 10 : size, c); }

void cb_draw_texture(cb_texture t, int x, int y, cb_rgba tint) {
    cb_be_texture(t, cb_rect_of(0, 0, t.width, t.height), cb_rect_of(x, y, t.width, t.height), cb_v2(0, 0), 0, tint);
}

cb_texture cb_load_texture(const char *path) { return cb_be_texture_load(path); }
cb_sound cb_sound_load(const char *path) { return cb_be_sound_load(path); }
void cb_sound_play(cb_sound s) { cb_be_sound_play(s); }
cb_music cb_music_load(const char *path, bool loop) { return cb_be_music_load(path, loop); }
void cb_music_play(cb_music m) { cb_be_music_play(m); }
void cb_music_stop(cb_music m) { cb_be_music_stop(m); }
void cb_music_pause(cb_music m) { cb_be_music_pause(m); }
void cb_music_resume(cb_music m) { cb_be_music_resume(m); }
void cb_music_volume(cb_music m, double v) { cb_be_music_volume(m, v); }
bool cb_music_playing(cb_music m) { return cb_be_music_playing(m); }
bool cb_key_down(int key) { return cb_be_key_down(key); }
bool cb_key_pressed(int key) { return cb_be_key_pressed(key); }
bool cb_key_released(int key) { return cb_be_key_released(key); }
bool cb_mouse_down(int button) { return cb_be_mouse_down(button); }
bool cb_mouse_pressed(int button) { return cb_be_mouse_pressed(button); }
int cb_mouse_x(void) { return (int)cb_be_mouse_pos().x; }
int cb_mouse_y(void) { return (int)cb_be_mouse_pos().y; }
double cb_mouse_wheel(void) { return cb_be_mouse_wheel(); }
void cb_cursor(int mode) { cb_be_cursor(mode); }
int cb_screen_width(void) { return cb_headless ? 0 : cb_be_width(); }
int cb_screen_height(void) { return cb_headless ? 0 : cb_be_height(); }
int cb_fps(void) { return cb_headless ? 0 : cb_be_fps(); }
void cb_draw_line3d(Vector3 a, Vector3 b, cb_rgba c) { cb_be_line3d(a, b, c); }
void cb_draw_grid(int lines, double spacing) { cb_be_grid(lines, spacing); }
void cb_draw_wire_box(Vector3 at, Vector3 size, cb_rgba c) { cb_be_wire_box(at, size, c); }

/* ---- 2D: turned shapes and text, sprite sheets, the 2D view ----
   x, y is the top-left when not turned; turning goes round the middle. */
void cb_draw_rect_turned(int x, int y, int width, int height, double rotation, cb_rgba color) {
    cb_be_rect(cb_rect_of(x + width / 2.0, y + height / 2.0, width, height), cb_v2(width / 2.0, height / 2.0), rotation, color);
}

void cb_draw_text_turned(const char *text, int x, int y, int size, double rotation, cb_rgba color) {
    Vector2 m = cb_be_text_size(text, size);
    cb_be_text(text, cb_v2(x + m.x / 2.0, y + m.y / 2.0), cb_v2(m.x / 2.0, m.y / 2.0), rotation, size, color);
}

/* One cell (Frame, counted along the rows from the top-left) of a texture cut into
   Columns x Rows, Scale times its size. */
void cb_draw_sprite(cb_texture texture, int x, int y, int frame, int columns, int rows, double scale, double rotation, cb_rgba tint) {
    cb_rect src, dst;
    int cells;
    if (columns < 1) columns = 1;
    if (rows < 1) rows = 1;
    cells = columns * rows;
    frame = ((frame % cells) + cells) % cells;
    src.width = (float)texture.width / columns;
    src.height = (float)texture.height / rows;
    src.x = (frame % columns) * src.width;
    src.y = (frame / columns) * src.height;
    dst.width = (float)(src.width * scale);
    dst.height = (float)(src.height * scale);
    dst.x = x + dst.width / 2;
    dst.y = y + dst.height / 2;
    cb_be_texture(texture, src, dst, cb_v2(dst.width / 2, dst.height / 2), rotation, tint);
}

void cb_begin_2d(Vector2 center, double zoom, double rotation) { cb_be_begin_2d(center, zoom, rotation); }
void cb_end_2d(void) { cb_be_end_2d(); }

/* ---- 3D: the camera (kept here: Set camera, the world's Camera3D, shakes, Snapshot) ---- */
typedef struct { Vector3 position, target; double fov; bool ortho; } cb_camera_state;
static cb_camera_state cb_cam = { { 0.0f, 8.0f, 10.0f }, { 0.0f, 0.0f, 0.0f }, 60.0, false };

void cb_camera(Vector3 position, Vector3 target, double fov, bool ortho) {
    cb_cam.position = position;
    cb_cam.target = target;
    cb_cam.fov = fov;
    cb_cam.ortho = ortho;
}

void cb_begin_3d(void) { cb_be_begin_3d(cb_cam.position, cb_cam.target, cb_cam.fov, cb_cam.ortho); }
void cb_end_3d(void) { cb_be_end_3d(); }

static Vector3 cb_shake_offset(double dt);

/* ---- the world: small built-in classes, Godot's way ----
   Node; Spatial3D (position, rotation, scale: what's under it is placed in it) ->
   Shape3D (a box / sphere / cylinder / plane: drawn, touched, solid), Mesh3D, Camera3D
   (the first one is the view), Light3D (the sun: it shines along its -Z);
   Spatial2D (position, rotation, scale) -> Shape2D, Sprite2D, Text2D, Camera2D (the
   first one moves and zooms the 2D view; without one, 2D is in window pixels);
   Environment (the sky, the ambient light). The Game loop runs the world each frame:
   cb_world_step (Every frame), cb_world_physics (touches), cb_world_draw (3D from its
   Camera3D, lit by its Light3D and Environment, then the 2D on top). */

static int cb_shape_kind(const char *shape) {
    if (strcmp(shape, "Sphere") == 0) return 1;
    if (strcmp(shape, "Cylinder") == 0) return 2;
    if (strcmp(shape, "Plane") == 0) return 3;
    return 0;
}

/* A placement: a rotation (3x3, row major), a position and a scale (the parents' too). */
typedef struct cb_place { float r[9]; Vector3 t; Vector3 s; } cb_place;

static cb_place cb_place_of(Vector3 pos, Vector3 deg) {
    /* Y (turn), then X (tilt), then Z (roll): R = Ry * Rx * Rz */
    double d = 3.14159265358979323846 / 180.0;
    double cy = cos(deg.y * d), sy = sin(deg.y * d), cx = cos(deg.x * d), sx = sin(deg.x * d), cz = cos(deg.z * d), sz = sin(deg.z * d);
    cb_place p;
    p.r[0] = (float)(cy * cz + sy * sx * sz); p.r[1] = (float)(-cy * sz + sy * sx * cz); p.r[2] = (float)(sy * cx);
    p.r[3] = (float)(cx * sz);                p.r[4] = (float)(cx * cz);                 p.r[5] = (float)(-sx);
    p.r[6] = (float)(-sy * cz + cy * sx * sz); p.r[7] = (float)(sy * sz + cy * sx * cz); p.r[8] = (float)(cy * cx);
    p.t = pos;
    p.s = cb_v3(1, 1, 1);
    return p;
}

/* a then b (b inside a: its position scaled and turned by a). */
static cb_place cb_place_mul(cb_place a, cb_place b) {
    cb_place o;
    Vector3 bt = cb_v3(b.t.x * a.s.x, b.t.y * a.s.y, b.t.z * a.s.z);
    int i, j;
    for (i = 0; i < 3; i++)
        for (j = 0; j < 3; j++)
            o.r[i * 3 + j] = a.r[i * 3] * b.r[j] + a.r[i * 3 + 1] * b.r[3 + j] + a.r[i * 3 + 2] * b.r[6 + j];
    o.t = cb_v3(a.r[0] * bt.x + a.r[1] * bt.y + a.r[2] * bt.z + a.t.x,
                a.r[3] * bt.x + a.r[4] * bt.y + a.r[5] * bt.z + a.t.y,
                a.r[6] * bt.x + a.r[7] * bt.y + a.r[8] * bt.z + a.t.z);
    o.s = cb_v3(a.s.x * b.s.x, a.s.y * b.s.y, a.s.z * b.s.z);
    return o;
}

static bool cb_local(const cb_object *o, cb_place *out) {
    const cls_Spatial3D *sp;
    if (!cb_is_a(o, &cls_Spatial3D_class))
        return false;
    sp = (const cls_Spatial3D *)o;
    *out = cb_place_of(sp->f_position, sp->f_rotation);
    out->s = sp->f_scale;
    return true;
}

/* Where an object is in the world: its placement after its parents'. */
static cb_place cb_world_place(const cb_object *o) {
    cb_place p = cb_place_of(cb_v3(0, 0, 0), cb_v3(0, 0, 0)), mine;
    if (o->parent)
        p = cb_world_place(o->parent);
    if (cb_local(o, &mine))
        p = cb_place_mul(p, mine);
    return p;
}

/* The box around a Shape3D in the world (turned boxes: the box around the turned box). */
static void cb_part_box(cls_Shape3D *p, Vector3 *center, Vector3 *half) {
    cb_place w = cb_world_place((cb_object *)p);
    Vector3 s = cb_v3(fabs(p->f_size.x * w.s.x) / 2, fabs(p->f_size.y * w.s.y) / 2, fabs(p->f_size.z * w.s.z) / 2);
    *center = w.t;
    *half = cb_v3(fabs(w.r[0]) * s.x + fabs(w.r[1]) * s.y + fabs(w.r[2]) * s.z,
                  fabs(w.r[3]) * s.x + fabs(w.r[4]) * s.y + fabs(w.r[5]) * s.z,
                  fabs(w.r[6]) * s.x + fabs(w.r[7]) * s.y + fabs(w.r[8]) * s.z);
}

/* Touching pairs of the last frame (ids), so When touched runs when a touch starts. */
static int *cb_touch_pairs = NULL, cb_touch_count = 0, cb_touch_cap = 0;

static bool cb_was_touching(int a, int b) {
    int i;
    for (i = 0; i < cb_touch_count; i++)
        if (cb_touch_pairs[2 * i] == a && cb_touch_pairs[2 * i + 1] == b)
            return true;
    return false;
}

typedef struct cb_box { cls_Shape3D *part; int id; Vector3 lo, hi; } cb_box;

/* Touches: Shape3Ds whose boxes start to overlap hear When touched (both). Nothing
   moves by itself: an object's Every frame moves it (or Move and collide). */
void cb_world_physics(double dt) {
    void **all;
    int i, j, n = cb_world_objects(&all), boxes = 0, *now = NULL, now_count = 0, now_cap = 0;
    cb_box *box;
    (void)dt;
    if (n == 0)
        return;
    box = (cb_box *)malloc(sizeof(cb_box) * (size_t)n);
    if (!box) { fputs("out of memory\n", stderr); exit(3); }
    for (i = 0; i < n; i++) {
        if (cb_is_a(all[i], &cls_Shape3D_class)) {
            Vector3 c, h;
            cb_part_box((cls_Shape3D *)all[i], &c, &h);
            box[boxes].part = (cls_Shape3D *)all[i];
            box[boxes].id = ((cb_object *)all[i])->id;
            box[boxes].lo = cb_v3_sub(c, h);
            box[boxes].hi = cb_v3_add(c, h);
            boxes++;
        }
    }
    for (i = 0; i < boxes; i++) {
        for (j = i + 1; j < boxes; j++) {
            cb_box *a = &box[i], *b = &box[j];
            int lo_id, hi_id;
            if (a->lo.x > b->hi.x || b->lo.x > a->hi.x || a->lo.y > b->hi.y || b->lo.y > a->hi.y || a->lo.z > b->hi.z || b->lo.z > a->hi.z)
                continue;
            lo_id = a->id < b->id ? a->id : b->id;
            hi_id = a->id < b->id ? b->id : a->id;
            if (now_count >= now_cap) {
                now_cap = now_cap ? now_cap * 2 : 64;
                now = (int *)realloc(now, sizeof(int) * 2 * (size_t)now_cap);
                if (!now) { fputs("out of memory\n", stderr); exit(3); }
            }
            now[2 * now_count] = lo_id;
            now[2 * now_count + 1] = hi_id;
            now_count++;
            if (!cb_was_touching(lo_id, hi_id)) {
                /* a touch starts: both hear it (either may be destroyed by the first) */
                if (cb_alive(a->part) && cb_alive(b->part) && ((cb_object *)a->part)->cls->touched && !((cb_object *)a->part)->net_id)
                    ((cb_object *)a->part)->cls->touched(a->part, b->part);
                if (cb_alive(a->part) && cb_alive(b->part) && ((cb_object *)b->part)->cls->touched && !((cb_object *)b->part)->net_id)
                    ((cb_object *)b->part)->cls->touched(b->part, a->part);
            }
        }
    }
    free(box);
    free(cb_touch_pairs);
    cb_touch_pairs = now;
    cb_touch_count = now_count;
    cb_touch_cap = now_cap;
}

static void cb_push_local(cb_object *o) {
    if (cb_is_a(o, &cls_Spatial3D_class)) {
        cls_Spatial3D *sp = (cls_Spatial3D *)o;
        cb_be_translate(sp->f_position.x, sp->f_position.y, sp->f_position.z);
        cb_be_rotate(sp->f_rotation.y, 0, 1, 0);
        cb_be_rotate(sp->f_rotation.x, 1, 0, 0);
        cb_be_rotate(sp->f_rotation.z, 0, 0, 1);
        cb_be_scale(sp->f_scale.x, sp->f_scale.y, sp->f_scale.z);
    }
}

static void cb_draw_object(cb_object *o) {
    int i;
    if (cb_is_a(o, &cls_Spatial2D_class))
        return;  /* (2D: drawn on top, cb_world_draw_2d) */
    cb_be_push();
    cb_push_local(o);
    if (cb_is_a(o, &cls_Shape3D_class)) {
        cls_Shape3D *p = (cls_Shape3D *)o;
        if (p->f_visible)
            cb_draw_shape(cb_shape_kind(p->f_shape), cb_v3(0, 0, 0), p->f_size, 0, cb_color(p->f_color));
    } else if (cb_is_a(o, &cls_Mesh3D_class)) {
        cls_Mesh3D *m = (cls_Mesh3D *)o;
        if (m->f_visible && m->f_mesh)
            cb_draw_mesh(m->f_mesh, cb_v3(0, 0, 0), cb_v3(1, 1, 1), 0, cb_color(m->f_color));
    }
    if (o->cls->drawn)
        o->cls->drawn(o);
    for (i = 0; i < o->children->count; i++) {
        cb_object *c = ((cb_object **)o->children->data)[i];
        if (cb_alive(c))
            cb_draw_object(c);
    }
    cb_be_pop();
}

/* The world's Environment (sky, ambient, fog), Light3D (its -Z, color, energy) and Camera3D (the first of each). */
typedef struct { const char *sky; double ambient; Vector3 sun; const char *light_color; double energy; const char *fog_color; double fog; const char *horizon; const char *ambient_color; double fog_start; cls_Camera3D *cam; cls_Camera2D *cam2d; } cb_scene_look;

/* Sets the shader's light and fog from a look. */
static void cb_use_look(const cb_scene_look *l) {
    cb_set_light(l->sun, l->ambient);
    cb_set_light_color(cb_color(l->light_color), l->energy);
    cb_set_fog(cb_color(l->fog_color[0] ? l->fog_color : l->sky), l->fog);
    cb_set_ambient(cb_color(l->ambient_color[0] ? l->ambient_color : "WHITE"), l->fog_start);
}

/* The sky: flat, or (horizon set) a gradient from sky at the top to horizon at the bottom. */
static void cb_draw_sky(const cb_scene_look *l, int width, int height) {
    cb_be_clear(cb_color(l->sky));
    if (l->horizon[0])
        cb_be_gradient_v(cb_rect_of(0, 0, width, height), cb_color(l->sky), cb_color(l->horizon));
}

static cb_scene_look cb_look(void) {
    void **all;
    int i, n = cb_world_objects(&all);
    cb_scene_look l;
    bool env = false, light = false;
    l.sky = "#30343c";  /* no Environment: a neutral grey */
    l.ambient = 0.38;
    l.sun = cb_v3(-0.4, -1, -0.6);
    l.light_color = "WHITE";
    l.energy = 1;
    l.fog_color = "";
    l.fog = 0;
    l.horizon = "";
    l.ambient_color = "WHITE";
    l.fog_start = 0;
    l.cam = NULL;
    l.cam2d = NULL;
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)all[i];
        if (!env && cb_is_a(o, &cls_Environment_class)) {
            l.sky = ((cls_Environment *)o)->f_sky;
            l.ambient = ((cls_Environment *)o)->f_ambient;
            l.fog = ((cls_Environment *)o)->f_fog;
            l.fog_color = ((cls_Environment *)o)->f_fog_color;
            l.horizon = ((cls_Environment *)o)->f_horizon;
            l.ambient_color = ((cls_Environment *)o)->f_ambient_color;
            l.fog_start = ((cls_Environment *)o)->f_fog_start;
            env = true;
        } else if (!light && cb_is_a(o, &cls_Light3D_class)) {
            cb_place w = cb_world_place(o);
            l.sun = cb_v3(-w.r[2], -w.r[5], -w.r[8]);
            l.light_color = ((cls_Light3D *)o)->f_color;
            l.energy = ((cls_Light3D *)o)->f_energy;
            light = true;
        } else if (!l.cam && cb_is_a(o, &cls_Camera3D_class)) {
            l.cam = (cls_Camera3D *)o;
        } else if (!l.cam2d && cb_is_a(o, &cls_Camera2D_class)) {
            l.cam2d = (cls_Camera2D *)o;
        }
    }
    return l;
}

/* ---- 2D: Spatial2D objects, placed in their Spatial2D parents, under the Camera2D ---- */
typedef struct { Vector2 t; double rot; Vector2 s; } cb_place2;

static cb_place2 cb_place2_of(const cb_object *o) {
    cb_place2 p;
    p.t = cb_v2(0, 0); p.rot = 0; p.s = cb_v2(1, 1);
    if (o->parent)
        p = cb_place2_of(o->parent);
    if (cb_is_a(o, &cls_Spatial2D_class)) {
        const cls_Spatial2D *sp = (const cls_Spatial2D *)o;
        double a = p.rot * 3.14159265358979323846 / 180.0;
        double x = sp->f_position.x * p.s.x, y = sp->f_position.y * p.s.y;
        p.t = cb_v2(p.t.x + x * cos(a) - y * sin(a), p.t.y + x * sin(a) + y * cos(a));
        p.rot += sp->f_rotation;
        p.s = cb_v2(p.s.x * sp->f_scale.x, p.s.y * sp->f_scale.y);
    }
    return p;
}

/* Sprite2D textures, loaded once by path. */
typedef struct { const char *path; cb_texture tex; } cb_sprite_tex;
static cb_sprite_tex *cb_sprite_texs = NULL;
static int cb_sprite_tex_n = 0;

static cb_texture cb_sprite_texture(const char *path) {
    int i;
    cb_texture t;
    for (i = 0; i < cb_sprite_tex_n; i++)
        if (strcmp(cb_sprite_texs[i].path, path) == 0)
            return cb_sprite_texs[i].tex;
    t = cb_be_texture_load(path);
    cb_sprite_texs = (cb_sprite_tex *)realloc((void *)cb_sprite_texs, sizeof(cb_sprite_tex) * (size_t)(cb_sprite_tex_n + 1));
    if (!cb_sprite_texs) { fputs("out of memory\n", stderr); exit(3); }
    cb_sprite_texs[cb_sprite_tex_n].path = path;
    cb_sprite_texs[cb_sprite_tex_n].tex = t;
    cb_sprite_tex_n++;
    return t;
}

static void cb_world_draw_2d(cls_Camera2D *cam) {
    void **all;
    int i, n = cb_world_objects(&all);
    Vector2 view = cb_v2(0, 0), half = cb_v2(cb_be_width() / 2.0, cb_be_height() / 2.0);
    double zoom = 1;
    if (cam) {
        view = cb_place2_of((cb_object *)cam).t;
        zoom = cam->f_zoom > 0 ? cam->f_zoom : 1;
    }
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)all[i];
        cb_place2 p;
        Vector2 at;
        double k;
        if (!cb_is_a(o, &cls_Spatial2D_class) || cb_is_a(o, &cls_Camera2D_class))
            continue;
        p = cb_place2_of(o);
        at = cam ? cb_v2((p.t.x - view.x) * zoom + half.x, (p.t.y - view.y) * zoom + half.y) : p.t;
        k = cam ? zoom : 1;
        if (cb_is_a(o, &cls_Text2D_class)) {
            cls_Text2D *t = (cls_Text2D *)o;
            float size = (float)(t->f_size * p.s.y * k);
            if (t->f_visible && t->f_text[0])
                cb_be_text(t->f_text, at, cb_v2(0, 0), p.rot, size, cb_color(t->f_color));
        } else if (cb_is_a(o, &cls_Shape2D_class)) {
            cls_Shape2D *s = (cls_Shape2D *)o;
            float w = (float)(s->f_size.x * p.s.x * k), h = (float)(s->f_size.y * p.s.y * k);
            cb_rect r;
            if (!s->f_visible)
                continue;
            if (strcmp(s->f_shape, "Circle") == 0) {
                cb_be_circle(at, w / 2, cb_color(s->f_color));
            } else {
                r.x = at.x; r.y = at.y; r.width = w; r.height = h;
                cb_be_rect(r, cb_v2(w / 2, h / 2), p.rot, cb_color(s->f_color));  /* centred on its position */
            }
        } else if (cb_is_a(o, &cls_Sprite2D_class)) {
            cls_Sprite2D *s = (cls_Sprite2D *)o;
            cb_texture tex;
            cb_rect src, dst;
            if (!s->f_visible || !s->f_texture[0])
                continue;
            tex = cb_sprite_texture(s->f_texture);
            {   /* a sprite sheet: Columns x Rows cells, the Frame-th one (along the rows) */
                int cols = s->f_columns > 0 ? s->f_columns : 1, rows = s->f_rows > 0 ? s->f_rows : 1;
                int cells = cols * rows, fr = ((s->f_frame % cells) + cells) % cells;
                src.width = (float)tex.width / cols; src.height = (float)tex.height / rows;
                src.x = (fr % cols) * src.width; src.y = (fr / cols) * src.height;
            }
            dst.x = at.x; dst.y = at.y; dst.width = (float)(src.width * p.s.x * k); dst.height = (float)(src.height * p.s.y * k);
            cb_be_texture(tex, src, dst, cb_v2(dst.width / 2, dst.height / 2), p.rot, cb_color(s->f_color));
        }
    }
}

/* ---- UI: Controls in the window, in pixels, drawn on top (2026-11-07) ----
   A Control lines up the corner (or edge, or middle) its anchor names with the same point of
   its parent Control's box (no Control above it: the window), `offset` pixels from there
   (right / down); "full" fills the parent, `offset` in from each side. 2D / 3D parents
   don't move it. Hidden: it and what's under it. */
static bool cb_ui_box(const cb_object *o, cb_rect *r);

/* A child of a VBox / HBox (2026-11-07): the box stacks the Controls directly in it, in
   order, each its own size (fill: stretched across), separation apart, padding inside;
   their anchor and offset don't count; hidden ones take no room. */
static void cb_ui_slot(const cb_object *box, cb_rect b, const cb_object *child, cb_rect *r) {
    bool vertical = cb_is_a(box, &cls_VBox_class);
    double sep = vertical ? ((const cls_VBox *)box)->f_separation : ((const cls_HBox *)box)->f_separation;
    double pad = vertical ? ((const cls_VBox *)box)->f_padding : ((const cls_HBox *)box)->f_padding;
    bool fill = vertical ? ((const cls_VBox *)box)->f_fill : ((const cls_HBox *)box)->f_fill;
    double at = pad;
    int i;
    for (i = 0; i < box->children->count; i++) {
        const cb_object *k = ((cb_object **)box->children->data)[i];
        const cls_Control *kc = (const cls_Control *)k;
        if (!cb_alive(k) || !cb_is_a(k, &cls_Control_class))
            continue;
        if (k == child)
            break;
        if (kc->f_visible)
            at += (vertical ? kc->f_size.y : kc->f_size.x) + sep;
    }
    r->width = ((const cls_Control *)child)->f_size.x;
    r->height = ((const cls_Control *)child)->f_size.y;
    if (vertical) {
        r->x = (float)(b.x + pad); r->y = (float)(b.y + at);
        if (fill) r->width = (float)(b.width - 2 * pad);
    } else {
        r->x = (float)(b.x + at); r->y = (float)(b.y + pad);
        if (fill) r->height = (float)(b.height - 2 * pad);
    }
}

static bool cb_ui_box(const cb_object *o, cb_rect *r) {
    const cls_Control *c = (const cls_Control *)o;
    cb_rect p;
    const char *a = c->f_anchor;
    double ax = 0, ay = 0;
    const cb_object *up = o->parent;
    while (up && !cb_is_a(up, &cls_Control_class))
        up = up->parent;
    if (up) {
        if (!cb_ui_box(up, &p))
            return false;
    } else {
        p.x = 0; p.y = 0; p.width = (float)cb_be_width(); p.height = (float)cb_be_height();
    }
    if (!c->f_visible)
        return false;
    if (up && up == o->parent && (cb_is_a(up, &cls_VBox_class) || cb_is_a(up, &cls_HBox_class))) {
        cb_ui_slot(up, p, o, r);
        return true;
    }
    if (strcmp(a, "full") == 0) {
        r->x = p.x + c->f_offset.x; r->y = p.y + c->f_offset.y;
        r->width = p.width - 2 * c->f_offset.x; r->height = p.height - 2 * c->f_offset.y;
        return true;
    }
    if (strstr(a, "right")) ax = 1; else if (strcmp(a, "top") == 0 || strcmp(a, "center") == 0 || strcmp(a, "bottom") == 0) ax = 0.5;
    if (strncmp(a, "bottom", 6) == 0) ay = 1; else if (strcmp(a, "left") == 0 || strcmp(a, "center") == 0 || strcmp(a, "right") == 0) ay = 0.5;
    r->width = c->f_size.x; r->height = c->f_size.y;
    r->x = (float)(p.x + ax * p.width - ax * r->width + c->f_offset.x);
    r->y = (float)(p.y + ay * p.height - ay * r->height + c->f_offset.y);
    return true;
}

/* Buttons (2026-11-07): the one under the pointer (hovered), the one pressed on (held),
   and clicks: pressed and let go over the same Button. Worked out as each frame begins;
   none while the mouse is captured (mouse look) or the program has no window. */
static int cb_ui_hover_id = 0, cb_ui_press_id = 0;
static bool cb_ui_over = false;
typedef struct { int side; const char *name; void (*fn)(void *button); } cb_click_handler;
static cb_click_handler *cb_click_handlers = NULL;
static int cb_click_handler_n = 0, cb_click_handler_cap = 0;

void cb_on_click(int side, const char *name, void (*fn)(void *button)) {
    if (cb_click_handler_n == cb_click_handler_cap) {
        cb_click_handler_cap = cb_click_handler_cap ? cb_click_handler_cap * 2 : 8;
        cb_click_handlers = (cb_click_handler *)realloc((void *)cb_click_handlers, sizeof(cb_click_handler) * (size_t)cb_click_handler_cap);
        if (!cb_click_handlers) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_click_handlers[cb_click_handler_n].side = side;
    cb_click_handlers[cb_click_handler_n].name = name;
    cb_click_handlers[cb_click_handler_n].fn = fn;
    cb_click_handler_n++;
}

/* Whether the pointer is over a UI node that draws something (Mouse over UI?). */
bool cb_mouse_over_ui(void) {
    return cb_ui_over;
}

static bool cb_ui_box(const cb_object *o, cb_rect *r);

/* --click X:Y:AT (several with commas): the pointer goes to X, Y and presses the left
   button AT seconds after the window opened, letting go the frame after (tests). */
static int cb_click_next = 0, cb_click_phase = 0;  /* which click; 1: pressed, let go next frame */

static bool cb_test_click(Vector2 *m, bool *pressed, bool *released) {
    const char *p = cb_click_spec;
    int k = 0;
    double x, y, at;
    *pressed = *released = false;
    if (!p)
        return false;
    while (p && k < cb_click_next) {  /* the next click's spec */
        p = strchr(p, ',');
        if (p) p++;
        k++;
    }
    if (!p || sscanf(p, "%lf:%lf:%lf", &x, &y, &at) != 3)
        return false;
    *m = cb_v2(x, y);
    if (cb_click_phase == 1) {
        *released = true;
        cb_click_phase = 0;
        cb_click_next++;
    } else if (cb_game_time() >= at) {
        *pressed = true;
        cb_click_phase = 1;
    }
    return true;
}

static void cb_ui_input(void) {
    void **all;
    int i, n, hover = 0;
    Vector2 m;
    bool pressed, released;
    cb_object *clicked = NULL;
    cb_ui_over = false;
    if (cb_headless || cb_be_cursor_hidden()) {
        cb_ui_hover_id = cb_ui_press_id = 0;
        return;
    }
    if (!cb_test_click(&m, &pressed, &released)) {
        m = cb_be_mouse_pos();
        pressed = cb_be_mouse_pressed(CB_MOUSE_LEFT);
        released = cb_be_mouse_released(CB_MOUSE_LEFT);
    }
    n = cb_world_objects(&all);
    for (i = 0; i < n; i++) {  /* the last drawn under the pointer is on top */
        cb_object *o = (cb_object *)all[i];
        cb_rect r;
        if (!cb_is_a(o, &cls_Control_class) || !cb_ui_box(o, &r) || m.x < r.x || m.y < r.y || m.x >= r.x + r.width || m.y >= r.y + r.height)
            continue;
        if (o->cls != &cls_Control_class)
            cb_ui_over = true;
        if (cb_is_a(o, &cls_Button_class))
            hover = ((cls_Button *)o)->f_disabled ? 0 : o->id;
        else if (o->cls != &cls_Control_class)
            hover = 0;  /* (something drawn over a Button covers it) */
    }
    cb_ui_hover_id = hover;
    if (pressed)
        cb_ui_press_id = hover;
    if (released) {
        if (cb_ui_press_id && cb_ui_press_id == hover)
            for (i = 0; i < n; i++)
                if (((cb_object *)all[i])->id == hover)
                    clicked = (cb_object *)all[i];
        cb_ui_press_id = 0;
    }
    if (clicked) {
        int h, id = clicked->id;
        if (clicked->cls->clicked)
            clicked->cls->clicked(clicked);
        for (h = 0; h < cb_click_handler_n && cb_alive(clicked) && clicked->id == id; h++)
            if (cb_side_runs(cb_click_handlers[h].side) && (!cb_click_handlers[h].name[0] || strcmp(cb_click_handlers[h].name, clicked->name) == 0))
                cb_click_handlers[h].fn(clicked);
    }
}

static void cb_world_draw_ui(void) {
    void **all;
    int i, n = cb_world_objects(&all);
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)all[i];
        cb_rect r;
        if (!cb_is_a(o, &cls_Control_class) || !cb_ui_box(o, &r))
            continue;
        if (cb_is_a(o, &cls_Panel_class)) {
            cls_Panel *pn = (cls_Panel *)o;
            float m = r.width < r.height ? r.width : r.height;
            float round = m > 0 && pn->f_radius > 0 ? (float)(2 * pn->f_radius / m) : 0.0f;
            if (round > 1) round = 1;
            if (round > 0) cb_be_rect_rounded(r, round, cb_color(pn->f_color));
            else cb_be_rect(r, cb_v2(0, 0), 0, cb_color(pn->f_color));
            if (pn->f_border > 0 && pn->f_border_color[0]) {
                if (round > 0) cb_be_rect_rounded_lines(r, round, (float)pn->f_border, cb_color(pn->f_border_color));
                else cb_be_rect_lines(r, (float)pn->f_border, cb_color(pn->f_border_color));
            }
        } else if (cb_is_a(o, &cls_Label_class)) {
            cls_Label *lb = (cls_Label *)o;
            float fs = (float)(lb->f_font_size > 0 ? lb->f_font_size : 20);
            Vector2 m = cb_be_text_size(lb->f_text, fs);
            float x = r.x;
            if (strcmp(lb->f_align, "center") == 0) x = r.x + (r.width - m.x) / 2;
            else if (strcmp(lb->f_align, "right") == 0) x = r.x + r.width - m.x;
            cb_be_text(lb->f_text, cb_v2(x, r.y), cb_v2(0, 0), 0, fs, cb_color(lb->f_color));
        } else if (cb_is_a(o, &cls_Bar_class)) {
            cls_Bar *b = (cls_Bar *)o;
            double k = b->f_max > 0 ? b->f_value / b->f_max : 0;
            cb_rect fill = r;
            if (k < 0) k = 0;
            if (k > 1) k = 1;
            fill.width = (float)(r.width * k);
            cb_be_rect(r, cb_v2(0, 0), 0, cb_color(b->f_back));
            cb_be_rect(fill, cb_v2(0, 0), 0, cb_color(b->f_color));
        } else if (cb_is_a(o, &cls_Button_class)) {
            cls_Button *bt = (cls_Button *)o;
            const char *col = bt->f_color;
            float m = r.width < r.height ? r.width : r.height;
            float round = m > 0 && bt->f_radius > 0 ? (float)(2 * bt->f_radius / m) : 0.0f;
            float fs = (float)(bt->f_font_size > 0 ? bt->f_font_size : 18);
            Vector2 ts = cb_be_text_size(bt->f_text, fs);
            cb_rgba tc = cb_color(bt->f_text_color), bc;
            if (!bt->f_disabled && o->id == cb_ui_press_id && o->id == cb_ui_hover_id) col = bt->f_press_color;
            else if (!bt->f_disabled && o->id == cb_ui_hover_id) col = bt->f_hover_color;
            bc = cb_color(col);
            if (bt->f_disabled) { bc.a = (unsigned char)(bc.a / 2); tc.a = (unsigned char)(tc.a / 2); }
            if (round > 1) round = 1;
            if (round > 0) cb_be_rect_rounded(r, round, bc);
            else cb_be_rect(r, cb_v2(0, 0), 0, bc);
            if (bt->f_border > 0 && bt->f_border_color[0]) {
                if (round > 0) cb_be_rect_rounded_lines(r, round, (float)bt->f_border, cb_color(bt->f_border_color));
                else cb_be_rect_lines(r, (float)bt->f_border, cb_color(bt->f_border_color));
            }
            cb_be_text(bt->f_text, cb_v2(r.x + (r.width - ts.x) / 2, r.y + (r.height - ts.y) / 2), cb_v2(0, 0), 0, fs, tc);
        } else if (cb_is_a(o, &cls_Image_class)) {
            cls_Image *im = (cls_Image *)o;
            cb_texture t;
            cb_rect src;
            if (!im->f_texture[0])
                continue;
            t = cb_sprite_texture(im->f_texture);
            src.x = 0; src.y = 0; src.width = (float)t.width; src.height = (float)t.height;
            cb_be_texture(t, src, r, cb_v2(0, 0), 0, cb_color(im->f_color));
        }
    }
}

/* A screenshot of the frame so far with the UI on it (the UI is otherwise drawn as the frame
   ends): for tests' C Code bricks, which take screenshots mid-frame. */
void cb_screenshot(const char *path) {
    cb_be_flush();
    cb_world_draw_ui();
    cb_be_flush();
    cb_be_screenshot(path);
}

/* Draws the world, if it has anything in it: the sky, 3D from its Camera3D, then 2D. (The
   UI is drawn as the frame ends: over the Frame chains' Draw bricks too.) */
void cb_world_draw(void) {
    void **all;
    int n = cb_world_objects(&all);
    cb_scene_look l;
    cb_object *root;
    if (n == 0)
        return;
    l = cb_look();
    cb_use_look(&l);
    cb_draw_sky(&l, cb_be_width(), cb_be_height());
    if (l.cam) {
        cb_place w = cb_world_place((cb_object *)l.cam);
        cb_camera(w.t, l.cam->f_target, l.cam->f_fov, false);
    }
    {
        Vector3 jolt = cb_shake_offset(cb_frame_time());  /* (the world's time: paused, it holds; slowed, it slows) */
        cb_cam.position = cb_v3_add(cb_cam.position, jolt);
        cb_cam.target = cb_v3_add(cb_cam.target, jolt);
    }
    root = (cb_object *)cb_world();
    cb_begin_3d();
    cb_draw_object(root);  /* the root too: its place, its shape, then everything under it */
    cb_end_3d();
    cb_world_draw_2d(cb_look().cam2d);  /* (When drawn may have changed the world) */
}

/* ---- snapshots: what a Camera3D sees, drawn into an image now ---- */
static void cb_push_parents(cb_object *o) {
    if (!o)
        return;
    cb_push_parents(o->parent);
    cb_push_local(o);
}

/* Draws what a Camera3D sees into the backend's render target (the caller saves it, or makes
   a texture of it, then frees it). */
static void cb_snapshot_draw(void *camera, int width, int height, bool transparent, void *subject, int file, int brick) {
    cls_Camera3D *cam;
    cb_camera_state was = cb_cam;
    cb_scene_look l = cb_look();
    if (!cb_is_a(cb_obj(camera, file, brick), &cls_Camera3D_class))
        cb_assert(false, file, brick, "Snapshot needs a Camera3D");
    cam = (cls_Camera3D *)camera;
    if (width < 1) width = 1;
    if (height < 1) height = 1;
    cb_use_look(&l);
    cb_camera(cb_world_place((cb_object *)cam).t, cam->f_target, cam->f_fov, false);
    cb_be_target_begin(width, height);
    if (transparent) {
        cb_rgba none = { 0, 0, 0, 0 };
        cb_be_clear(none);
    } else {
        cb_draw_sky(&l, width, height);
    }
    cb_begin_3d();
    if (subject) {
        cb_object *s = (cb_object *)cb_obj(subject, file, brick);
        cb_be_push();
        cb_push_parents(s->parent);
        cb_draw_object(s);
        cb_be_pop();
    } else {
        cb_draw_object((cb_object *)cb_world());
    }
    cb_end_3d();
    cb_be_target_end();
    cb_cam = was;
}

bool cb_snapshot_file(void *camera, int width, int height, bool transparent, void *subject, const char *path, int file, int brick) {
    bool ok;
    cb_snapshot_draw(camera, width, height, transparent, subject, file, brick);
    ok = cb_be_target_save(path);
    cb_be_target_free();
    return ok;
}

cb_texture cb_snapshot_texture(void *camera, int width, int height, bool transparent, void *subject, int file, int brick) {
    cb_texture t;
    cb_snapshot_draw(camera, width, height, transparent, subject, file, brick);
    t = cb_be_target_texture();
    cb_be_target_free();
    return t;
}

/* ---- rays and solid Shape3Ds (Raycast, Move and collide) ----
   A Shape3D counts as its box: its size (and scale), turned with its rotation and its parents'. */

static bool cb_under(const cb_object *o, const cb_object *top) {
    for (; o; o = o->parent)
        if (o == top)
            return true;
    return false;
}

void *cb_raycast(Vector3 from, Vector3 to, void *ignore, Vector3 *point, Vector3 *normal, double *distance) {
    void **all;
    int i, n = cb_world_objects(&all);
    Vector3 dir = cb_v3_sub(to, from);
    double best = 2.0;
    void *hit = NULL;
    Vector3 best_normal = cb_v3(0, 0, 0);
    for (i = 0; i < n; i++) {
        cls_Shape3D *p;
        cb_place w;
        double o[3], d[3], size[3], tmin = -1e30, tmax = 1e30;
        int k, axis = -1;
        bool miss = false;
        if (!cb_is_a(all[i], &cls_Shape3D_class) || (ignore && cb_under((cb_object *)all[i], (cb_object *)ignore)))
            continue;
        p = (cls_Shape3D *)all[i];
        w = cb_world_place((cb_object *)p);
        size[0] = fabs(p->f_size.x * w.s.x); size[1] = fabs(p->f_size.y * w.s.y); size[2] = fabs(p->f_size.z * w.s.z);
        /* the ray in the box's own space (R transposed), scaled so the box is -0.5 .. 0.5 */
        for (k = 0; k < 3; k++) {
            double rx = from.x - w.t.x, ry = from.y - w.t.y, rz = from.z - w.t.z;
            o[k] = (w.r[k] * rx + w.r[3 + k] * ry + w.r[6 + k] * rz) / (size[k] > 1e-6 ? size[k] : 1e-6);
            d[k] = (w.r[k] * dir.x + w.r[3 + k] * dir.y + w.r[6 + k] * dir.z) / (size[k] > 1e-6 ? size[k] : 1e-6);
        }
        for (k = 0; k < 3 && !miss; k++) {
            if (fabs(d[k]) < 1e-12) {
                if (o[k] < -0.5 || o[k] > 0.5)
                    miss = true;
            } else {
                double t1 = (-0.5 - o[k]) / d[k], t2 = (0.5 - o[k]) / d[k];
                double lo = t1 < t2 ? t1 : t2, hi = t1 < t2 ? t2 : t1;
                if (lo > tmin) { tmin = lo; axis = k; }
                if (hi < tmax) tmax = hi;
            }
        }
        /* a ray that starts inside a shape doesn't hit it (tmin < 0), as Brickscript's */
        if (miss || tmax < tmin || tmin < 0 || tmin > 1 || axis < 0 || tmin >= best)
            continue;
        best = tmin;
        hit = p;
        {
            double sgn = d[axis] > 0 ? -1.0 : 1.0;
            best_normal = cb_v3(w.r[axis] * sgn, w.r[3 + axis] * sgn, w.r[6 + axis] * sgn);
        }
    }
    if (!hit) {
        *point = to;
        *normal = cb_v3(0, 0, 0);
        *distance = -1;
        return NULL;
    }
    *point = cb_v3_add(from, cb_v3_scale(dir, best));
    *normal = best_normal;
    *distance = cb_v3_length(dir) * best;
    return hit;
}

static bool cb_boxes_overlap(Vector3 ac, Vector3 ah, Vector3 bc, Vector3 bh) {
    const double e = 1e-4;  /* touching faces don't count */
    return fabs(ac.x - bc.x) < ah.x + bh.x - e && fabs(ac.y - bc.y) < ah.y + bh.y - e && fabs(ac.z - bc.z) < ah.z + bh.z - e;
}

static double cb_axis(Vector3 v, int k) { return k == 0 ? v.x : k == 1 ? v.y : v.z; }
static void cb_set_axis(Vector3 *v, int k, double x) {
    if (k == 0) v->x = (float)x; else if (k == 1) v->y = (float)x; else v->z = (float)x;
}

/* Moves a Shape3D, stopping at solid ones one axis at a time (so it slides along them). */
/* The mover's own box: its size (with its and its parents' scale) but not turned, so
   a character turning (its yaw) never grows into a wall it stands against. (It used to be
   the box around the turned shape: at 45 degrees it reached into the wall, the wall then
   counted as "already inside" and was skipped: players and enemies walked through.) */
static void cb_mover_box(cls_Shape3D *p, Vector3 *center, Vector3 *half) {
    cb_place w = cb_world_place((cb_object *)p);
    *center = w.t;
    *half = cb_v3(fabs(p->f_size.x * w.s.x) / 2, fabs(p->f_size.y * w.s.y) / 2, fabs(p->f_size.z * w.s.z) / 2);
}

bool cb_move_collide(void *part, Vector3 motion, int file, int brick) {
    void **all;
    int i, k, n, solids = 0;
    cls_Shape3D *p;
    Vector3 c, h, start, *sc, *sh;
    bool blocked = false, *inside;
    if (!cb_is_a(cb_obj(part, file, brick), &cls_Shape3D_class))
        cb_assert(false, file, brick, "Move and collide needs a Shape3D");
    p = (cls_Shape3D *)part;
    cb_mover_box(p, &c, &h);
    start = c;
    n = cb_world_objects(&all);
    sc = (Vector3 *)malloc(sizeof(Vector3) * (size_t)(n ? n : 1));
    sh = (Vector3 *)malloc(sizeof(Vector3) * (size_t)(n ? n : 1));
    inside = (bool *)malloc(sizeof(bool) * (size_t)(n ? n : 1));
    if (!sc || !sh || !inside) { fputs("out of memory\n", stderr); exit(3); }
    for (i = 0; i < n; i++) {
        cls_Shape3D *o;
        if (!cb_is_a(all[i], &cls_Shape3D_class) || cb_under((cb_object *)all[i], (cb_object *)p))
            continue;
        o = (cls_Shape3D *)all[i];
        if (!o->f_solid)
            continue;
        cb_part_box(o, &sc[solids], &sh[solids]);
        /* already inside it (placed there, or it moved into us): it may move out of it,
           not deeper (see below) */
        inside[solids] = cb_boxes_overlap(c, h, sc[solids], sh[solids]);
        solids++;
    }
    /* Each axis in turn, swept: the move stops at the nearest solid face it would
       cross (not only where it ends), so a big step can't jump through a wall. */
    for (k = 0; k < 3; k++) {
        double m = cb_axis(motion, k), from = cb_axis(c, k), to = from + m;
        if (m == 0)
            continue;
        for (i = 0; i < solids; i++) {
            int a1 = (k + 1) % 3, a2 = (k + 2) % 3;
            double face;
            const double e = 1e-4;
            /* only boxes it overlaps on the other two axes can stop it on this one */
            if (fabs(cb_axis(c, a1) - cb_axis(sc[i], a1)) >= cb_axis(h, a1) + cb_axis(sh[i], a1) - e ||
                fabs(cb_axis(c, a2) - cb_axis(sc[i], a2)) >= cb_axis(h, a2) + cb_axis(sh[i], a2) - e)
                continue;
            if (inside[i]) {
                /* inside it: on this axis, moving toward its middle is refused, away is free */
                if (fabs(cb_axis(c, k) - cb_axis(sc[i], k)) < cb_axis(h, k) + cb_axis(sh[i], k) - e
                    && (m > 0) == (cb_axis(sc[i], k) > from)) {
                    to = from;
                    blocked = true;
                }
                continue;
            }
            if (m > 0) {
                face = cb_axis(sc[i], k) - cb_axis(sh[i], k) - cb_axis(h, k);  /* where it would touch */
                if (face >= from - e && face < to) { to = face - e; blocked = true; }
            } else {
                face = cb_axis(sc[i], k) + cb_axis(sh[i], k) + cb_axis(h, k);
                if (face <= from + e && face > to) { to = face + e; blocked = true; }
            }
        }
        cb_set_axis(&c, k, to);
    }
    free(sc);
    free(sh);
    free((void *)inside);
    {
        /* the move in the world, back into the shape's own space (its parents' turn and scale) */
        Vector3 dw = cb_v3_sub(c, start);
        cb_place pw = cb_place_of(cb_v3(0, 0, 0), cb_v3(0, 0, 0));
        if (((cb_object *)p)->parent)
            pw = cb_world_place(((cb_object *)p)->parent);
        ((cls_Spatial3D *)p)->f_position = cb_v3_add(((cls_Spatial3D *)p)->f_position,
            cb_v3((pw.r[0] * dw.x + pw.r[3] * dw.y + pw.r[6] * dw.z) / (pw.s.x != 0 ? pw.s.x : 1),
                  (pw.r[1] * dw.x + pw.r[4] * dw.y + pw.r[7] * dw.z) / (pw.s.y != 0 ? pw.s.y : 1),
                  (pw.r[2] * dw.x + pw.r[5] * dw.y + pw.r[8] * dw.z) / (pw.s.z != 0 ? pw.s.z : 1)));
    }
    return blocked;
}

/* ---- Key Direction, Can see, Nearest object, Shake Camera (Brickscript's) ---- */
Vector2 cb_key_direction(bool left, bool right, bool forward, bool back) {
    Vector2 v = cb_v2((right ? 1 : 0) - (left ? 1 : 0), (back ? 1 : 0) - (forward ? 1 : 0));
    return cb_v2_length(v) > 1 ? cb_v2_normalize(v) : v;
}

bool cb_can_see(void *who, void *target, double range, double view, int file, int brick) {
    cb_place w;
    Vector3 eye, at, to, facing, point, normal;
    double dist, far;
    void *hit;
    cb_object *t = (cb_object *)cb_obj(target, file, brick);
    w = cb_world_place((cb_object *)cb_obj(who, file, brick));
    eye = w.t;
    at = cb_world_place(t).t;
    to = cb_v3_sub(at, eye);
    dist = cb_v3_length(to);
    if (range > 0 && dist > range)
        return false;
    if (view < 360 && dist > 1e-6) {
        facing = cb_v3(-w.r[2], -w.r[5], -w.r[8]);  /* its -Z, turned */
        if (cb_v3_dot(cb_v3_normalize(to), cb_v3_normalize(facing)) < cos(view * 0.5 * 3.14159265358979323846 / 180.0))
            return false;
    }
    hit = cb_raycast(eye, at, who, &point, &normal, &far);
    return !hit || cb_under((cb_object *)hit, t);
}

void *cb_nearest(const cb_class *cls, Vector3 from, double range, void *except, double *distance) {
    void **all;
    int i, n = cb_world_objects(&all);
    void *best = NULL;
    double best_d = -1;
    for (i = 0; i < n; i++) {
        double d;
        if (!cb_is_a(all[i], cls) || (except && cb_under((cb_object *)all[i], (cb_object *)except)))
            continue;
        d = cb_v3_length(cb_v3_sub(cb_world_place((cb_object *)all[i]).t, from));
        if (range > 0 && d > range)
            continue;
        if (!best || d < best_d) {
            best = all[i];
            best_d = d;
        }
    }
    *distance = best ? best_d : -1;
    return best;
}

static double cb_shake_strength = 0, cb_shake_left = 0, cb_shake_total = 0;

void cb_shake(double strength, double duration) {
    cb_shake_strength = strength;
    cb_shake_total = duration > 0 ? duration : 0.0001;
    cb_shake_left = cb_shake_total;
}

/* The camera's jolt this frame (fading as (1 - t)^2), used while the world is drawn. dt is the
   world's frame time (user, 2026-11-08): paused it's 0, so the shake stops where it is (the same
   jolt, held, while the picture stands still); at a slower time scale it fades and jitters
   slower (a new random jolt every 1/60 s of the world's time, at most one a frame). */
static Vector3 cb_shake_jolt = {0, 0, 0};
static double cb_shake_clock = 0;

static Vector3 cb_shake_offset(double dt) {
    double k;
    if (cb_shake_left <= 0) {
        cb_shake_jolt = cb_v3(0, 0, 0);
        return cb_shake_jolt;
    }
    if (dt <= 0)
        return cb_shake_jolt;
    cb_shake_left -= dt;
    k = cb_shake_left > 0 ? cb_shake_left / cb_shake_total : 0;
    k = cb_shake_strength * k * k;
    cb_shake_clock += dt;
    if (cb_shake_clock >= 1.0 / 60.0 - 1e-9 || (cb_shake_jolt.x == 0 && cb_shake_jolt.y == 0 && cb_shake_jolt.z == 0)) {
        cb_shake_clock = 0;
        cb_shake_jolt = cb_v3(((double)(rand() % 2001 - 1000) / 1000.0) * k, ((double)(rand() % 2001 - 1000) / 1000.0) * k, ((double)(rand() % 2001 - 1000) / 1000.0) * k);
    }
    return cb_shake_jolt;
}

/* Seconds of shake left (for tests: how the world's time moves it). */
double cb_shake_remaining(void) { return cb_shake_left > 0 ? cb_shake_left : 0; }

/* ---- the mouse: captured for mouse look ----
   Right after capturing, the pointer jumps to the window's middle and raylib reports
   that jump as movement: it's left out for a moment so the view doesn't lurch. */
static double cb_captured_at = -1;

void cb_capture_mouse(void) {
    cb_be_cursor(2);
    cb_captured_at = cb_be_time();
}

Vector2 cb_mouse_motion(void) {
    if (cb_captured_at >= 0 && cb_be_time() - cb_captured_at < 0.1)
        return cb_v2(0, 0);
    return cb_be_mouse_delta();
}

/* ---- a dedicated server (--server): no window ----
   Frames come at the Open window's rate on a steady clock; the world runs (Every
   frame, moves, touches) but nothing is drawn, and the drawing / input bricks skip. */
static int cb_headless_rate = 60;
static double cb_headless_last = -1, cb_headless_dt = 1.0 / 60, cb_headless_start = 0;

void cb_headless_fps(int fps) {
    cb_headless_rate = fps > 0 ? fps : 60;
    cb_headless_start = cb_now();  /* "Time since start", as a window's time */
}

/* Waits for the next frame's time; always true (a server runs until it's stopped). */
bool cb_headless_frame(void) {
    double now = cb_now(), next;
    if (cb_headless_last < 0)
        cb_headless_last = now - 1.0 / cb_headless_rate;
    next = cb_headless_last + 1.0 / cb_headless_rate;
    if (next > now) {
        cb_sleep_ms((int)((next - now) * 1000.0));
        now = cb_now();
    }
    cb_headless_dt = now - cb_headless_last;
    if (cb_headless_dt > 0.25)
        cb_headless_dt = 0.25;
    cb_headless_last = now;
    return true;
}

/* Close window: the Game loop (and a Wait) end after the frame under way. */
static bool cb_close_asked = false;

void cb_close_window(void) {
    cb_close_asked = true;
}

void cb_window_opened(void) {
    cb_close_asked = false;
}

/* The Game loop's (and Wait's) test: another frame? */
bool cb_loop_go(void) {
    if (cb_close_asked)
        return false;
    return cb_headless ? cb_headless_frame() : !cb_be_should_close();
}

/* A key held now, for networking (cb_key_hook): the window's keyboard. */
int cb_window_key(int key) {
    return cb_be_key_down(key);
}

/* ---- Pause and time scale (2026-11-08) ----
   Offline, Pause freezes the world: objects' Every frame, touches, When frame starts / ends
   and Wait stop (scripts and classes that Run while paused go on, with the real frame
   time); the Game loop's Frame chains, drawing, the UI and the network go on. In a network
   game Pause is only remembered (Paused? answers, the shared world runs on). The time scale
   (user: "timescale applies online globally! and also works offline") multiplies the frame
   time (slow motion < 1, fast > 1) offline and, in a network game, for the whole world:
   set where the rules run (a host, a server), sent to every client (cb_net.c's SCALE). */
static bool cb_paused = false;
static double cb_play_time = 0;  /* the world's time: frame times as scaled (Wait counts it) */

void cb_pause(bool on) { cb_paused = on; }
bool cb_is_paused(void) { return cb_paused; }
void cb_set_time_scale(double scale) {
    if (cb_online && cb_side_bits == 2) {  /* a client: the world's speed is the server's */
        static bool told = false;
        if (!told) { fputs("[warning] Set time scale on a client does nothing: the server sets the world's speed\n", stderr); told = true; }
        return;
    }
    cb_world_scale = scale > 0 ? scale : 0;
}
double cb_get_time_scale(void) { return cb_world_scale; }

static bool cb_frozen(void) {
    return cb_paused && !cb_online;
}

static double cb_real_frame_time(void) {
    return cb_headless ? cb_headless_dt : cb_be_frame_time();
}

/* The last frame's length as the world sees it (scaled; 0 while paused offline). */
double cb_frame_time(void) {
    if (cb_online)
        return cb_real_frame_time() * cb_world_scale;
    return cb_paused ? 0.0 : cb_real_frame_time() * cb_world_scale;
}

double cb_game_time(void) {
    return cb_headless ? cb_now() - cb_headless_start : cb_be_time();
}

/* ---- frames and Wait ----
   The Game loop opens and closes each frame through these, so a Wait inside its
   Frame chains can close the frame, keep the world running, then open it again. */
static bool cb_frame_open = false;
static int cb_world_depth = 0;  /* inside the world's events: a Wait there would nest */

static void cb_world_frame(void) {
    bool frozen = cb_frozen();
    double dt = frozen ? cb_real_frame_time() : cb_frame_time();  /* (frozen: for what Runs while paused) */
    cb_world_depth++;
    cb_world_busy(1);
    cb_play_time += cb_frame_time();
    cb_frame_events(0, dt, frozen);  /* When frame starts */
    cb_world_step(dt, frozen);
    if (!frozen)
        cb_world_physics(dt);
    cb_frame_events(1, dt, frozen);  /* When frame ends: after moves and touches, before drawing */
    if (!cb_headless)
        cb_world_draw();
    cb_world_busy(-1);
    cb_world_depth--;
}

void cb_frame_begin(void) {
    if (cb_poll_hook)
        cb_poll_hook();  /* the network's turn (players joining, the world from the server...) */
    cb_scene_pending();  /* a Change scene asked for during the last frame's events */
    cb_ui_input();  /* Buttons: hover, press, clicks (When clicked, When button clicked) */
    if (!cb_headless) {
        cb_be_music_update();
        cb_be_begin_frame();
    }
    cb_frame_open = true;
    cb_world_frame();
}

void cb_frame_end(void) {
    cb_frame_open = false;
    if (!cb_headless) {
        cb_world_draw_ui();  /* the UI, on top of everything drawn this frame */
        cb_be_end_frame();
    }
}

void cb_wait_world(double seconds) {
    double until = cb_play_time + seconds;  /* (the world's time: slower, faster, stopped while paused) */
    bool reopen = cb_frame_open;
    if (cb_world_depth > 0) {  /* called from an object's event (through a method): don't nest frames */
        static bool told = false;
        if (!told) { fputs("[warning] Wait inside an object's event is skipped (it would hold up the world)\n", stderr); told = true; }
        return;
    }
    if (reopen)
        cb_frame_end();
    while (cb_play_time < until && cb_loop_go()) {
        void **all;
        if (cb_poll_hook)
            cb_poll_hook();
        cb_scene_pending();
        cb_ui_input();
        if (!cb_headless) {
            cb_be_music_update();
            cb_be_begin_frame();
            if (cb_world_objects(&all) == 0)
                cb_be_clear(cb_color("RAYWHITE"));
        }
        cb_world_frame();
        if (!cb_headless) {
            cb_world_draw_ui();
            cb_be_end_frame();
        }
    }
    if (reopen) {
        if (!cb_headless)
            cb_be_begin_frame();
        cb_frame_open = true;
    }
}
