/* C-Bricks' raylib backend (2026-11-08): everything that touches raylib (thirdparty/raylib,
   zlib license) is in this file: the window and its frames, the keyboard and mouse, 2D drawing,
   textures, sounds and music, and the 3D renderer (a lit shader, shapes, meshes, render
   targets). The rest of C-Bricks (cbricks_gfx.c: the world, the UI, physics, frames, pause)
   only calls the cb_be_* functions declared in cbricks.h, in C-Bricks' own types (cb_rgba,
   cb_rect, cb_texture / cb_sound / cb_music handles, CB_KEY_* codes): another backend (MS-DOS)
   implements the same functions. Added to projects that use graphics bricks. */
#include "raylib.h"
#include "rlgl.h"  /* transforms, back-face culling, the render batch */
#include "cbricks.h"

static Color RL(cb_rgba c) {
    Color r;
    r.r = c.r; r.g = c.g; r.b = c.b; r.a = c.a;
    return r;
}

static Rectangle RR(cb_rect r) {
    Rectangle o;
    o.x = r.x; o.y = r.y; o.width = r.width; o.height = r.height;
    return o;
}

/* ---- music streams: handles (cb_music.id) to raylib's Music; every playing one is fed each
   frame (cb_be_music_update) ---- */
static Music *cb_musics_all = NULL;  /* every loaded one, by id - 1 */
static int cb_music_all_n = 0;
static int cb_playing[16];  /* ids playing now */
static int cb_playing_n = 0;

cb_music cb_be_music_load(const char *path, bool loop) {
    cb_music h;
    Music m = LoadMusicStream(path);
    m.looping = loop;
    cb_musics_all = (Music *)realloc((void *)cb_musics_all, sizeof(Music) * (size_t)(cb_music_all_n + 1));
    if (!cb_musics_all) { fputs("out of memory\n", stderr); exit(3); }
    cb_musics_all[cb_music_all_n++] = m;
    h.id = m.stream.buffer ? cb_music_all_n : 0;
    h.length = m.stream.buffer ? GetMusicTimeLength(m) : 0;
    h.looping = loop;
    return h;
}

static Music *cb_music_of(cb_music h) {
    return h.id > 0 && h.id <= cb_music_all_n ? &cb_musics_all[h.id - 1] : NULL;
}

static int cb_playing_find(int id) {
    int i;
    for (i = 0; i < cb_playing_n; i++)
        if (cb_playing[i] == id)
            return i;
    return -1;
}

void cb_be_music_play(cb_music h) {
    Music *m = cb_music_of(h);
    if (!m)
        return;
    PlayMusicStream(*m);
    if (cb_playing_find(h.id) < 0 && cb_playing_n < (int)(sizeof cb_playing / sizeof cb_playing[0]))
        cb_playing[cb_playing_n++] = h.id;
}

void cb_be_music_stop(cb_music h) {
    Music *m = cb_music_of(h);
    int i = cb_playing_find(h.id);
    if (!m)
        return;
    StopMusicStream(*m);
    if (i >= 0)
        cb_playing[i] = cb_playing[--cb_playing_n];
}

void cb_be_music_pause(cb_music h) { Music *m = cb_music_of(h); if (m) PauseMusicStream(*m); }
void cb_be_music_resume(cb_music h) { Music *m = cb_music_of(h); if (m) ResumeMusicStream(*m); }
void cb_be_music_volume(cb_music h, double v) { Music *m = cb_music_of(h); if (m) SetMusicVolume(*m, (float)v); }
bool cb_be_music_playing(cb_music h) { Music *m = cb_music_of(h); return m && IsMusicStreamPlaying(*m); }

void cb_be_music_update(void) {
    int i;
    for (i = 0; i < cb_playing_n; i++) {
        int id = cb_playing[i];
        if (id > 0 && id <= cb_music_all_n)
            UpdateMusicStream(cb_musics_all[id - 1]);
    }
}

void cb_be_music_forget_all(void) { cb_playing_n = 0; }

/* ---- the window and its frames ---- */
bool cb_be_open(int width, int height, const char *title, int fps, bool esc_closes) {
    SetTraceLogLevel(LOG_WARNING);  /* raylib's INFO lines would mix with the program's output */
    InitWindow(width, height, title);
    if (!IsWindowReady())
        return false;
    SetTargetFPS(fps);
    if (!esc_closes)
        SetExitKey(KEY_NULL);
    InitAudioDevice();
    return true;
}

void cb_be_close(void) {
    cb_be_music_forget_all();
    CloseAudioDevice();
    CloseWindow();
}

bool cb_be_should_close(void) { return WindowShouldClose(); }
bool cb_be_ready(void) { return IsWindowReady(); }
void cb_be_begin_frame(void) { BeginDrawing(); }
void cb_be_end_frame(void) { EndDrawing(); }
void cb_be_flush(void) { rlDrawRenderBatchActive(); }
int cb_be_width(void) { return GetScreenWidth(); }
int cb_be_height(void) { return GetScreenHeight(); }
int cb_be_fps(void) { return GetFPS(); }
double cb_be_frame_time(void) { return (double)GetFrameTime(); }
double cb_be_time(void) { return GetTime(); }
void cb_be_screenshot(const char *path) { TakeScreenshot(path); }

/* ---- the keyboard and the mouse (CB_KEY_* are raylib's own key numbers) ---- */
bool cb_be_key_down(int key) { return IsKeyDown(key); }
bool cb_be_key_pressed(int key) { return IsKeyPressed(key); }
bool cb_be_key_released(int key) { return IsKeyReleased(key); }
bool cb_be_mouse_down(int button) { return IsMouseButtonDown(button); }
bool cb_be_mouse_pressed(int button) { return IsMouseButtonPressed(button); }
bool cb_be_mouse_released(int button) { return IsMouseButtonReleased(button); }
Vector2 cb_be_mouse_pos(void) { return GetMousePosition(); }
Vector2 cb_be_mouse_delta(void) { return GetMouseDelta(); }
double cb_be_mouse_wheel(void) { return (double)GetMouseWheelMove(); }

/* 0 visible, 1 hidden, 2 captured (hidden and held in the window: mouse look). */
void cb_be_cursor(int mode) {
    if (mode == 2) {
        DisableCursor();
    } else {
        EnableCursor();
        if (mode == 1) HideCursor(); else ShowCursor();
    }
}

bool cb_be_cursor_hidden(void) { return IsCursorHidden(); }

/* ---- 2D drawing ---- */
void cb_be_clear(cb_rgba c) { ClearBackground(RL(c)); }
void cb_be_rect(cb_rect r, Vector2 origin, double rotation, cb_rgba c) { DrawRectanglePro(RR(r), origin, (float)rotation, RL(c)); }
void cb_be_rect_lines(cb_rect r, double thick, cb_rgba c) { DrawRectangleLinesEx(RR(r), (float)thick, RL(c)); }
void cb_be_rect_rounded(cb_rect r, double roundness, cb_rgba c) { DrawRectangleRounded(RR(r), (float)roundness, 8, RL(c)); }
void cb_be_rect_rounded_lines(cb_rect r, double roundness, double thick, cb_rgba c) { DrawRectangleRoundedLinesEx(RR(r), (float)roundness, 8, (float)thick, RL(c)); }
void cb_be_circle(Vector2 at, double radius, cb_rgba c) { DrawCircleV(at, (float)radius, RL(c)); }
void cb_be_line(Vector2 a, Vector2 b, cb_rgba c) { DrawLineV(a, b, RL(c)); }
void cb_be_gradient_v(cb_rect r, cb_rgba top, cb_rgba bottom) { DrawRectangleGradientV((int)r.x, (int)r.y, (int)r.width, (int)r.height, RL(top), RL(bottom)); }

/* Text in the default font, size pixels high, letters size / 10 apart (raylib's DrawText). */
void cb_be_text(const char *text, Vector2 at, Vector2 origin, double rotation, double size, cb_rgba c) {
    DrawTextPro(GetFontDefault(), text, at, origin, (float)rotation, (float)size, (float)size / 10, RL(c));
}

Vector2 cb_be_text_size(const char *text, double size) {
    return MeasureTextEx(GetFontDefault(), text, (float)size, (float)size / 10);
}

void cb_be_begin_2d(Vector2 center, double zoom, double rotation) {
    Camera2D c;
    c.offset = cb_v2(GetScreenWidth() / 2.0, GetScreenHeight() / 2.0);
    c.target = center;
    c.rotation = (float)rotation;
    c.zoom = zoom > 0 ? (float)zoom : 1.0f;
    BeginMode2D(c);
}

void cb_be_end_2d(void) { EndMode2D(); }

/* ---- textures: handles (cb_texture.id) to raylib's ---- */
static Texture2D *cb_texs = NULL;
static int cb_tex_n = 0;

static cb_texture cb_tex_handle(Texture2D t) {
    cb_texture h;
    cb_texs = (Texture2D *)realloc((void *)cb_texs, sizeof(Texture2D) * (size_t)(cb_tex_n + 1));
    if (!cb_texs) { fputs("out of memory\n", stderr); exit(3); }
    cb_texs[cb_tex_n++] = t;
    h.id = t.id ? cb_tex_n : 0;
    h.width = t.width;
    h.height = t.height;
    return h;
}

cb_texture cb_be_texture_load(const char *path) { return cb_tex_handle(LoadTexture(path)); }

void cb_be_texture(cb_texture t, cb_rect src, cb_rect dst, Vector2 origin, double rotation, cb_rgba tint) {
    if (t.id <= 0 || t.id > cb_tex_n)
        return;
    DrawTexturePro(cb_texs[t.id - 1], RR(src), RR(dst), origin, (float)rotation, RL(tint));
}

/* ---- sounds ---- */
static Sound *cb_sounds = NULL;
static int cb_sound_n = 0;

cb_sound cb_be_sound_load(const char *path) {
    cb_sound h;
    Sound s = LoadSound(path);
    cb_sounds = (Sound *)realloc((void *)cb_sounds, sizeof(Sound) * (size_t)(cb_sound_n + 1));
    if (!cb_sounds) { fputs("out of memory\n", stderr); exit(3); }
    cb_sounds[cb_sound_n++] = s;
    h.id = cb_sound_n;
    h.frames = s.frameCount;
    return h;
}

void cb_be_sound_play(cb_sound h) {
    if (h.id > 0 && h.id <= cb_sound_n)
        PlaySound(cb_sounds[h.id - 1]);
}

/* ---- 3D: the camera, a lit shader, shapes and meshes ----------------------
   Everything 3D is drawn as a model with one small shader: its color times a
   sun from above (ambient + diffuse in the Light3D's color and energy), back faces
   lit from their own side, fading into the Environment's fog with distance.
   GLSL 330 (OpenGL 3.3: Windows, macOS), 120 (OpenGL 2.1: Linux, a Pi), 100 (the Web). */
static Shader cb_lit;
static bool cb_lit_ready = false;
static bool cb_lit_ok = false;  /* false: the shader didn't compile, models stay unlit */
static Model cb_shape_models[4];
static bool cb_shapes_ready = false;

/* Order matters: rlgl.h also defines GRAPHICS_API_OPENGL_33 when 2.1 is picked. */
#if defined(GRAPHICS_API_OPENGL_ES2) || defined(PLATFORM_WEB)
#define CB_VS_HEAD "#version 100\n#define ATTR attribute\n#define VARY varying\n"
#define CB_FS_HEAD "#version 100\nprecision mediump float;\n#define VARY varying\n#define FRAG gl_FragColor\n#define TEX texture2D\n"
#elif defined(GRAPHICS_API_OPENGL_21)
#define CB_VS_HEAD "#version 120\n#define ATTR attribute\n#define VARY varying\n"
#define CB_FS_HEAD "#version 120\n#define VARY varying\n#define FRAG gl_FragColor\n#define TEX texture2D\n"
#else
#define CB_VS_HEAD "#version 330\n#define ATTR in\n#define VARY out\n"
#define CB_FS_HEAD "#version 330\n#define VARY in\nout vec4 cb_out;\n#define FRAG cb_out\n#define TEX texture\n"
#endif

static const char cb_vs[] = CB_VS_HEAD
    "ATTR vec3 vertexPosition;\nATTR vec2 vertexTexCoord;\nATTR vec3 vertexNormal;\nATTR vec4 vertexColor;\n"
    "uniform mat4 mvp;\nuniform mat4 matNormal;\n"
    "VARY vec2 fragTexCoord;\nVARY vec4 fragColor;\nVARY vec3 fragNormal;\n"
    "void main() {\n"
    "    fragTexCoord = vertexTexCoord;\n    fragColor = vertexColor;\n"
    "    fragNormal = (matNormal * vec4(vertexNormal, 0.0)).xyz;\n"
    "    gl_Position = mvp * vec4(vertexPosition, 1.0);\n}\n";

static const char cb_fs[] = CB_FS_HEAD
    "VARY vec2 fragTexCoord;\nVARY vec4 fragColor;\nVARY vec3 fragNormal;\n"
    "uniform sampler2D texture0;\nuniform vec4 colDiffuse;\nuniform vec3 lightDir;\nuniform float ambient;\n"
    "uniform vec3 lightCol;\nuniform vec3 fogCol;\nuniform float fogDensity;\nuniform vec3 ambientCol;\nuniform float fogStart;\n"
    "void main() {\n"
    "    vec3 n = normalize(fragNormal);\n"
    "    if (!gl_FrontFacing) n = -n;\n"
    "    vec3 light = ambient * ambientCol + (1.0 - ambient) * max(dot(n, -lightDir), 0.0) * lightCol;\n"
    "    vec4 base = TEX(texture0, fragTexCoord) * colDiffuse * fragColor;\n"
    "    float seen = exp(-fogDensity * max(1.0 / gl_FragCoord.w - fogStart, 0.0));\n"  /* 1 / w: the depth from the camera */
    "    FRAG = vec4(mix(fogCol, base.rgb * light, seen), base.a);\n}\n";


static void cb_3d_ready(void) {
    if (cb_lit_ready)
        return;
    {
        Vector3 sun = cb_v3_normalize(cb_v3(-0.4, -1.0, -0.6));
        float amb = 0.38f;
        cb_lit = LoadShaderFromMemory(cb_vs, cb_fs);
        cb_lit_ok = cb_lit.id != rlGetShaderIdDefault();
        if (!cb_lit_ok) {
            fputs("[warning] 3D lighting isn't available on this GPU: shapes are drawn unlit\n", stderr);
        } else {
            SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "lightDir"), &sun, SHADER_UNIFORM_VEC3);
            SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "ambient"), &amb, SHADER_UNIFORM_FLOAT);
        }
    }
    cb_lit_ready = true;
    {
        cb_rgba white = { 255, 255, 255, 255 };
        cb_set_light_color(white, 1.0);
        cb_set_fog(white, 0.0);
        cb_set_ambient(white, 0.0);
    }
}

static Model cb_lit_model(Mesh mesh) {
    Model m = LoadModelFromMesh(mesh);
    cb_3d_ready();
    if (cb_lit_ok)
        m.materials[0].shader = cb_lit;
    return m;
}

/* 3D drawing from a camera (the neutral side keeps the camera: Set camera, Camera3D, shakes). */
void cb_be_begin_3d(Vector3 position, Vector3 target, double fov, bool ortho) {
    Camera3D cam;
    cam.position = position;
    cam.target = target;
    cam.up = cb_v3(0, 1, 0);
    cam.fovy = (float)fov;
    cam.projection = ortho ? CAMERA_ORTHOGRAPHIC : CAMERA_PERSPECTIVE;
    BeginMode3D(cam);
}

void cb_be_end_3d(void) { EndMode3D(); }

/* Shapes 1 across, their middle at the origin (the cylinder's too). */
static void cb_shapes(void) {
    Mesh cyl;
    int i;
    if (cb_shapes_ready)
        return;
    cb_shape_models[0] = cb_lit_model(GenMeshCube(1.0f, 1.0f, 1.0f));
    cb_shape_models[1] = cb_lit_model(GenMeshSphere(0.5f, 8, 16));
    cyl = GenMeshCylinder(0.5f, 1.0f, 16);
    for (i = 0; i < cyl.vertexCount; i++)
        cyl.vertices[i * 3 + 1] -= 0.5f;
    UpdateMeshBuffer(cyl, 0, cyl.vertices, cyl.vertexCount * 3 * (int)sizeof(float), 0);
    cb_shape_models[2] = cb_lit_model(cyl);
    cb_shape_models[3] = cb_lit_model(GenMeshPlane(1.0f, 1.0f, 1, 1));
    cb_shapes_ready = true;
}

void cb_draw_shape(int kind, Vector3 at, Vector3 size, double turn, cb_rgba color) {
    cb_shapes();
    if (kind < 0 || kind > 3)
        kind = 0;
    DrawModelEx(cb_shape_models[kind], at, cb_v3(0, 1, 0), (float)turn, size, RL(color));
}

/* ---- meshes (Brickscript's mesh bricks) ----
   Triangles are collected (Begin / Add), then built into a model (Finish).
   Corners are stored in OpenGL's order (counter-clockwise from the front):
   a brick's A B C (clockwise, Brickscript's way) is kept as A C B. */
typedef struct cb_tri { Vector3 p[3]; Vector3 n[3]; Color c; int own; } cb_tri;
struct cb_mesh { cb_list *tris; Model model; bool built; bool both; bool smooth; };

cb_mesh *cb_mesh_new(void) {
    cb_mesh *m = (cb_mesh *)cb_alloc(sizeof(cb_mesh));
    m->tris = cb_list_new(sizeof(cb_tri));
    return m;
}

cb_mesh *cb_mesh_begin(cb_mesh *m) {
    if (!m)
        m = cb_mesh_new();
    cb_list_clear(m->tris);
    return m;
}

static Vector3 cb_face_normal(Vector3 a, Vector3 b, Vector3 c) {
    return cb_v3_cross(cb_v3_sub(b, a), cb_v3_sub(c, a));
}

/* One triangle, corners already counter-clockwise; normals given (own) or not. */
static void cb_mesh_add(cb_mesh *m, Vector3 a, Vector3 b, Vector3 c, const Vector3 *normals, Color color) {
    cb_tri *t = (cb_tri *)cb_list_add(m->tris);
    t->p[0] = a; t->p[1] = b; t->p[2] = c;
    t->c = color;
    if (normals) {
        t->n[0] = normals[0]; t->n[1] = normals[1]; t->n[2] = normals[2];
        t->own = 1;
    }
}

void cb_mesh_triangle(cb_mesh *m, Vector3 a, Vector3 b, Vector3 c, cb_rgba color) {
    cb_mesh_add(m, a, c, b, NULL, RL(color));
}

void cb_mesh_quad(cb_mesh *m, Vector3 a, Vector3 b, Vector3 c, Vector3 d, cb_rgba color) {
    cb_mesh_triangle(m, a, b, c, color);
    cb_mesh_triangle(m, a, c, d, color);
}

/* A ready shape's triangles, from raylib's generated mesh (its own normals). */
void cb_mesh_shape(cb_mesh *m, int kind, Vector3 at, Vector3 size, cb_rgba rgba) {
    Color color = RL(rgba);
    Mesh g;
    int i, count;
    switch (kind) {
    case 1: g = GenMeshSphere(0.5f, 8, 16); break;
    case 2: g = GenMeshCylinder(0.5f, 1.0f, 16); break;
    case 3: g = GenMeshPlane(1.0f, 1.0f, 1, 1); break;
    default: g = GenMeshCube(1.0f, 1.0f, 1.0f); break;
    }
    count = g.indices ? g.triangleCount * 3 : g.vertexCount;
    for (i = 0; i + 2 < count; i += 3) {
        Vector3 p[3], n[3];
        int k;
        for (k = 0; k < 3; k++) {
            int v = g.indices ? g.indices[i + k] : i + k;
            float y = g.vertices[v * 3 + 1] - (kind == 2 ? 0.5f : 0.0f);
            p[k] = cb_v3(at.x + g.vertices[v * 3] * size.x, at.y + y * size.y, at.z + g.vertices[v * 3 + 2] * size.z);
            n[k] = cb_v3_normalize(cb_v3(g.normals[v * 3] / size.x, g.normals[v * 3 + 1] / size.y, g.normals[v * 3 + 2] / size.z));
        }
        cb_mesh_add(m, p[0], p[1], p[2], n, color);
    }
    UnloadMesh(g);
}

static unsigned long cb_point_hash(Vector3 p, Color c) {
    unsigned long h = 2166136261u;
    const unsigned char *b = (const unsigned char *)&p;
    size_t i;
    for (i = 0; i < sizeof p; i++)
        h = (h ^ b[i]) * 16777619u;
    h = (h ^ c.r) * 16777619u; h = (h ^ c.g) * 16777619u; h = (h ^ c.b) * 16777619u; h = (h ^ c.a) * 16777619u;
    return h;
}

/* Normals again from the points (Flat: per triangle; Smooth: indexed, averaged). */
static void cb_mesh_normals(Mesh *g, bool skip_own, const cb_list *tris) {
    int i, k, count = g->indices ? g->triangleCount * 3 : g->vertexCount;
    if (g->indices)
        memset(g->normals, 0, (size_t)g->vertexCount * 3 * sizeof(float));
    for (i = 0; i + 2 < count; i += 3) {
        int v[3];
        Vector3 n;
        if (skip_own && tris && ((const cb_tri *)tris->data)[i / 3].own)
            continue;
        for (k = 0; k < 3; k++)
            v[k] = g->indices ? g->indices[i + k] : i + k;
        n = cb_face_normal(cb_v3(g->vertices[v[0] * 3], g->vertices[v[0] * 3 + 1], g->vertices[v[0] * 3 + 2]),
                           cb_v3(g->vertices[v[1] * 3], g->vertices[v[1] * 3 + 1], g->vertices[v[1] * 3 + 2]),
                           cb_v3(g->vertices[v[2] * 3], g->vertices[v[2] * 3 + 1], g->vertices[v[2] * 3 + 2]));
        if (!g->indices)
            n = cb_v3_normalize(n);
        for (k = 0; k < 3; k++) {
            if (g->indices) {
                g->normals[v[k] * 3] += n.x; g->normals[v[k] * 3 + 1] += n.y; g->normals[v[k] * 3 + 2] += n.z;
            } else {
                g->normals[v[k] * 3] = n.x; g->normals[v[k] * 3 + 1] = n.y; g->normals[v[k] * 3 + 2] = n.z;
            }
        }
    }
    if (g->indices) {
        for (i = 0; i < g->vertexCount; i++) {
            Vector3 n = cb_v3(g->normals[i * 3], g->normals[i * 3 + 1], g->normals[i * 3 + 2]);
            if (cb_v3_length(n) == 0)
                continue;  /* a point whose triangles have no area keeps its normal */
            n = cb_v3_normalize(n);
            g->normals[i * 3] = n.x; g->normals[i * 3 + 1] = n.y; g->normals[i * 3 + 2] = n.z;
        }
    }
}

static void cb_put_vertex(Mesh *g, int v, const cb_tri *t, int k) {
    g->vertices[v * 3] = t->p[k].x; g->vertices[v * 3 + 1] = t->p[k].y; g->vertices[v * 3 + 2] = t->p[k].z;
    g->normals[v * 3] = t->n[k].x; g->normals[v * 3 + 1] = t->n[k].y; g->normals[v * 3 + 2] = t->n[k].z;
    g->texcoords[v * 2] = t->p[k].x; g->texcoords[v * 2 + 1] = t->p[k].z;
    g->colors[v * 4] = t->c.r; g->colors[v * 4 + 1] = t->c.g; g->colors[v * 4 + 2] = t->c.b; g->colors[v * 4 + 3] = t->c.a;
}

void cb_mesh_finish(cb_mesh *m, bool smooth, bool both_sides, int file, int brick) {
    Mesh g;
    int count = m->tris->count, corners = count * 3, i, k;
    size_t n_corners = corners > 0 ? (size_t)corners : 1, n_points;
    const cb_tri *tris = (const cb_tri *)m->tris->data;
    if (!IsWindowReady())
        cb_assert(false, file, brick, "Finish mesh needs the window open first (Open window)");
    memset(&g, 0, sizeof g);
    g.triangleCount = count;
    if (!smooth) {
        g.vertexCount = corners;
    } else {
        /* one point per place and color (a shape's own-normal corners stay apart) */
        int size = 16, *slots, *map, unique = 0;
        while (size < corners * 2 + 2)
            size *= 2;
        slots = (int *)calloc((size_t)size, sizeof(int));
        map = (int *)malloc(n_corners * sizeof(int));
        if (!slots || !map) { fputs("out of memory\n", stderr); exit(3); }
        for (i = 0; i < corners; i++) {
            const cb_tri *t = &tris[i / 3];
            int found = -1;
            if (!t->own) {
                unsigned long at = cb_point_hash(t->p[i % 3], t->c) & (unsigned long)(size - 1);
                while (slots[at]) {
                    int j = slots[at] - 1;
                    const cb_tri *u = &tris[j / 3];
                    if (!u->own && memcmp(&u->p[j % 3], &t->p[i % 3], sizeof(Vector3)) == 0 && memcmp(&u->c, &t->c, sizeof(Color)) == 0) {
                        found = map[j];
                        break;
                    }
                    at = (at + 1) & (unsigned long)(size - 1);
                }
                if (found < 0)
                    slots[at] = i + 1;
            }
            map[i] = found >= 0 ? found : unique++;
        }
        free(slots);
        if (unique > 65535) {
            free(map);
            cb_assert(false, file, brick, "a Smooth mesh can have at most 65535 points: use Flat, or split it");
        }
        g.vertexCount = unique;
        g.indices = (unsigned short *)RL_MALLOC(n_corners * sizeof(unsigned short));
        for (i = 0; i < corners; i++)
            g.indices[i] = (unsigned short)map[i];
        free(map);
    }
    n_points = g.vertexCount > 0 ? (size_t)g.vertexCount : 1;
    g.vertices = (float *)RL_CALLOC(n_points * 3, sizeof(float));
    g.normals = (float *)RL_CALLOC(n_points * 3, sizeof(float));
    g.texcoords = (float *)RL_CALLOC(n_points * 2, sizeof(float));
    g.colors = (unsigned char *)RL_CALLOC(n_points * 4, 1);
    for (i = 0; i < count; i++)
        for (k = 0; k < 3; k++)
            cb_put_vertex(&g, g.indices ? g.indices[i * 3 + k] : i * 3 + k, &tris[i], k);
    cb_mesh_normals(&g, true, m->tris);
    if (g.vertexCount > 0)
        UploadMesh(&g, true);
    if (m->built) {
        UnloadMesh(m->model.meshes[0]);  /* keeps the material: its shader is shared */
        m->model.meshes[0] = g;
        m->model.meshCount = 1;
    } else {
        m->model = cb_lit_model(g);
    }
    m->built = g.vertexCount > 0 || m->built;
    m->both = both_sides;
    m->smooth = smooth;
    cb_list_clear(m->tris);
}

void cb_draw_mesh(cb_mesh *m, Vector3 at, Vector3 size, double turn, cb_rgba rgba) {
    Color tint = RL(rgba);
    if (!m || !m->built || m->model.meshes[0].vertexCount == 0)
        return;
    if (m->both)
        rlDisableBackfaceCulling();
    DrawModelEx(m->model, at, cb_v3(0, 1, 0), (float)turn, size, tint);
    if (m->both)
        rlEnableBackfaceCulling();
}

cb_list *cb_mesh_points(const cb_mesh *m) {
    cb_list *l = cb_list_new(sizeof(Vector3));
    int i;
    if (!m || !m->built)
        return l;
    for (i = 0; i < m->model.meshes[0].vertexCount; i++) {
        const float *v = m->model.meshes[0].vertices + i * 3;
        *(Vector3 *)cb_list_add(l) = cb_v3(v[0], v[1], v[2]);
    }
    return l;
}

void cb_mesh_set_points(cb_mesh *m, const cb_list *points, int file, int brick) {
    Mesh *g;
    int i;
    if (!m || !m->built)
        cb_assert(false, file, brick, "the mesh isn't built yet (Finish mesh)");
    g = &m->model.meshes[0];
    if (points->count != g->vertexCount) {
        cb_assert(false, file, brick, cb_format("got %d points for a mesh of %d points", points->count, g->vertexCount));
    }
    for (i = 0; i < g->vertexCount; i++) {
        const Vector3 *p = (const Vector3 *)(points->data + (size_t)i * sizeof(Vector3));
        g->vertices[i * 3] = p->x; g->vertices[i * 3 + 1] = p->y; g->vertices[i * 3 + 2] = p->z;
    }
    cb_mesh_normals(g, false, NULL);
    UpdateMeshBuffer(*g, 0, g->vertices, g->vertexCount * 3 * (int)sizeof(float), 0);
    UpdateMeshBuffer(*g, 2, g->normals, g->vertexCount * 3 * (int)sizeof(float), 0);
}

void cb_show_mesh(FILE *f, const void *value) {
    const cb_mesh *m = *(cb_mesh *const *)value;
    if (!m || !m->built)
        fprintf(f, "mesh (not built%s)", m && m->tris->count ? cb_format(", %d triangles added", m->tris->count) : "");
    else
        fprintf(f, "mesh (%d triangles, %d points, %s)", m->model.meshes[0].triangleCount, m->model.meshes[0].vertexCount, m->smooth ? "smooth" : "flat");
}

void cb_set_light(Vector3 direction, double ambient) {
    Vector3 sun = cb_v3_normalize(direction);
    float amb = (float)ambient;
    cb_3d_ready();
    if (!cb_lit_ok)
        return;
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "lightDir"), &sun, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "ambient"), &amb, SHADER_UNIFORM_FLOAT);
}

/* The sun's color times its energy (Light3D), and the fog (Environment: density 0 = none). */
void cb_set_light_color(cb_rgba color, double energy) {
    float c[3];
    cb_3d_ready();
    if (!cb_lit_ok)
        return;
    c[0] = (float)(color.r / 255.0 * energy);
    c[1] = (float)(color.g / 255.0 * energy);
    c[2] = (float)(color.b / 255.0 * energy);
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "lightCol"), c, SHADER_UNIFORM_VEC3);
}

void cb_set_fog(cb_rgba color, double density) {
    float c[3], d = density > 0 ? (float)density : 0.0f;
    cb_3d_ready();
    if (!cb_lit_ok)
        return;
    c[0] = color.r / 255.0f;
    c[1] = color.g / 255.0f;
    c[2] = color.b / 255.0f;
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "fogCol"), c, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "fogDensity"), &d, SHADER_UNIFORM_FLOAT);
}

/* The ambient light's colour and where fog begins (Environment: ambient_color, fog_start). */
void cb_set_ambient(cb_rgba color, double fog_start) {
    float c[3], st = fog_start > 0 ? (float)fog_start : 0.0f;
    cb_3d_ready();
    if (!cb_lit_ok)
        return;
    c[0] = color.r / 255.0f;
    c[1] = color.g / 255.0f;
    c[2] = color.b / 255.0f;
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "ambientCol"), c, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "fogStart"), &st, SHADER_UNIFORM_FLOAT);
}

/* ---- 3D transforms and lines (the world's placement; Draw shape's lines and grids) ---- */
void cb_be_push(void) { rlPushMatrix(); }
void cb_be_pop(void) { rlPopMatrix(); }
void cb_be_translate(double x, double y, double z) { rlTranslatef((float)x, (float)y, (float)z); }
void cb_be_rotate(double degrees, double x, double y, double z) { rlRotatef((float)degrees, (float)x, (float)y, (float)z); }
void cb_be_scale(double x, double y, double z) { rlScalef((float)x, (float)y, (float)z); }
void cb_be_line3d(Vector3 a, Vector3 b, cb_rgba c) { DrawLine3D(a, b, RL(c)); }
void cb_be_grid(int lines, double spacing) { DrawGrid(lines, (float)spacing); }
void cb_be_wire_box(Vector3 at, Vector3 size, cb_rgba c) { DrawCubeWiresV(at, size, RL(c)); }

/* ---- render targets (Snapshot): draw into an image, then save it or make a texture ---- */
static RenderTexture2D cb_rt;
static bool cb_rt_on = false;

void cb_be_target_begin(int width, int height) {
    cb_rt = LoadRenderTexture(width, height);
    cb_rt_on = true;
    BeginTextureMode(cb_rt);
}

void cb_be_target_end(void) { EndTextureMode(); }

static Image cb_rt_image(void) {
    Image img = LoadImageFromTexture(cb_rt.texture);
    ImageFlipVertical(&img);  /* render textures are upside down */
    return img;
}

bool cb_be_target_save(const char *path) {
    Image img = cb_rt_image();
    bool ok = ExportImage(img, path);
    UnloadImage(img);
    return ok;
}

cb_texture cb_be_target_texture(void) {
    Image img = cb_rt_image();
    cb_texture t = cb_tex_handle(LoadTextureFromImage(img));
    UnloadImage(img);
    return t;
}

void cb_be_target_free(void) {
    if (cb_rt_on)
        UnloadRenderTexture(cb_rt);
    cb_rt_on = false;
}
