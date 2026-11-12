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
static float cb_splat_q = 1.0f;  /* the quality level 0.05..1: the share of every object's points drawn; follows the frame time */
static long cb_splat_drawn = 0;  /* points drawn this frame */
static int cb_target_fps = 60;
bool cb_be_open(int width, int height, const char *title, int fps, bool esc_closes) {
    unsigned int flags = 0;
    SetTraceLogLevel(LOG_WARNING);  /* raylib's INFO lines would mix with the program's output */
    if (CB_MSAA && CB_PIXEL == 1)
        flags |= FLAG_MSAA_4X_HINT;
    if (CB_VSYNC)
        flags |= FLAG_VSYNC_HINT;
    if (CB_WINDOW == 1 || CB_PIXEL > 1)
        flags |= FLAG_WINDOW_RESIZABLE;
    if (CB_WINDOW == 2)
        flags |= FLAG_BORDERLESS_WINDOWED_MODE;
    if (CB_WINDOW == 3)
        flags |= FLAG_WINDOW_UNDECORATED;
    if (flags)
        SetConfigFlags(flags);
    InitWindow(width, height, title);
    if (!IsWindowReady())
        return false;
    SetTargetFPS(fps);
    cb_target_fps = fps > 0 ? fps : 60;
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
/* The look's settings start as Project Settings > Graphics (CB_SHADING, CB_SPLAT, CB_PIXEL) and the Graphics
   setting brick changes them while the program runs. A pixel size change waits for the next frame, so a frame is
   drawn at one size. */
static int cb_shading_v = CB_SHADING, cb_splat_v = CB_SPLAT, cb_pixel_v = CB_PIXEL, cb_pixel_next = CB_PIXEL;
static void cb_shade_uniform(void);
void cb_be_set_look(int what, int value) {
    if (what == 0) { cb_shading_v = value < 0 ? 0 : value > 3 ? 3 : value; cb_shade_uniform(); }
    else if (what == 1) cb_splat_v = value < 0 ? 0 : value > 2 ? 2 : value;
    else if (what == 2) cb_pixel_next = value < 1 ? 1 : value > 16 ? 16 : value;
}
int cb_be_splat_mode(void) { return cb_splat_v; }

/* Pixel size (Project Settings > Graphics): the frame is drawn into a smaller texture, cb_pixel_v times smaller
   than the window, and stretched up without smoothing at the end. The program sees the small size
   (cb_be_width / height, the mouse). */
static RenderTexture2D cb_low;
static bool cb_low_ok = false, cb_low_in_frame = false;

static void cb_low_size(int *w, int *h) {
    *w = (GetScreenWidth() + cb_pixel_v - 1) / cb_pixel_v;
    *h = (GetScreenHeight() + cb_pixel_v - 1) / cb_pixel_v;
    if (*w < 1) *w = 1;
    if (*h < 1) *h = 1;
}

/* Post effects (Environment: vignette, scanlines, grain, posterize): the frame goes through a full-screen shader
   on its way to the window, so it is drawn into the texture even at pixel size 1. */
static float cb_post_fx[4] = { 0, 0, 0, 0 };   /* vignette, scanlines, grain, posterize */
static float cb_post_fx2[4] = { 0, 0, 0, 0 };  /* bloom, curve, outline, dither */
static float cb_snap_px = 0;                   /* vertex snapping: the grid in frame pixels (0 off) */
static bool cb_post_on = false;
static void cb_post_draw(Rectangle src, Rectangle dst);
static void cb_snap_apply(void);

static float cb_unit(double v) { return v > 0 ? (v > 1 ? 1.0f : (float)v) : 0.0f; }

void cb_be_post(double vignette, double scanlines, double grain, double posterize, double bloom, double curve, double outline, double dither, double snap) {
    int i;
    cb_post_fx[0] = cb_unit(vignette);
    cb_post_fx[1] = cb_unit(scanlines);
    cb_post_fx[2] = cb_unit(grain);
    cb_post_fx[3] = posterize >= 2 ? (posterize > 64 ? 64.0f : (float)posterize) : 0.0f;
    cb_post_fx2[0] = cb_unit(bloom);
    cb_post_fx2[1] = cb_unit(curve);
    cb_post_fx2[2] = cb_unit(outline);
    cb_post_fx2[3] = cb_unit(dither);
    cb_snap_px = snap >= 1 ? (snap > 32 ? 32.0f : (float)snap) : 0.0f;
    cb_post_on = false;
    for (i = 0; i < 4; i++)
        if (cb_post_fx[i] > 0 || cb_post_fx2[i] > 0)
            cb_post_on = true;
}

void cb_be_begin_frame(void) {
    cb_pixel_v = cb_pixel_next;
    BeginDrawing();
    cb_snap_apply();
    if (cb_pixel_v > 1 || cb_post_on) {
        int w, h;
        cb_low_size(&w, &h);
        if (!cb_low_ok || cb_low.texture.width != w || cb_low.texture.height != h) {
            if (cb_low_ok)
                UnloadRenderTexture(cb_low);
            cb_low = LoadRenderTexture(w, h);
            SetTextureFilter(cb_low.texture, TEXTURE_FILTER_POINT);
            cb_low_ok = true;
        }
        BeginTextureMode(cb_low);
        cb_low_in_frame = true;
    }
}

#ifdef CB_SPLAT_PROFILE
void cb_prof_report(void);
#endif
/* Splat quality follows the frame time: slower than the target frame rate (by 12%): fewer points, each bigger;
   faster by 20%: more again. It moves a little each frame so it doesn't flicker. */
static void cb_splat_adapt(void) {
    if (cb_splat_drawn > 0) {
        double dt = (double)GetFrameTime(), want = 1.0 / (double)cb_target_fps;
        if (dt > want * 1.12)
            cb_splat_q *= 0.92f;
        else if (dt < want * 0.8)
            cb_splat_q *= 1.03f;
        if (cb_splat_q > 1.0f) cb_splat_q = 1.0f;
        if (cb_splat_q < 0.05f) cb_splat_q = 0.05f;
    }
    cb_splat_drawn = 0;
}

void cb_be_end_frame(void) {
#ifdef CB_SPLAT_PROFILE
    { static int n = 0; if (++n % 30 == 0) cb_prof_report(); }
#endif
    if (cb_low_in_frame) {
        Rectangle src, dst;
        EndTextureMode();
        cb_low_in_frame = false;
        src.x = 0; src.y = 0; src.width = (float)cb_low.texture.width; src.height = -(float)cb_low.texture.height;
        dst.x = 0; dst.y = 0; dst.width = (float)(cb_low.texture.width * cb_pixel_v); dst.height = (float)(cb_low.texture.height * cb_pixel_v);
        ClearBackground(BLACK);
        cb_post_draw(src, dst);
    }
    cb_splat_adapt();
    EndDrawing();
}
void cb_be_flush(void) { rlDrawRenderBatchActive(); }
int cb_be_width(void) { int w, h; if (cb_pixel_v > 1) { cb_low_size(&w, &h); return w; } return GetScreenWidth(); }
int cb_be_height(void) { int w, h; if (cb_pixel_v > 1) { cb_low_size(&w, &h); return h; } return GetScreenHeight(); }
int cb_be_fps(void) { return GetFPS(); }
double cb_be_frame_time(void) { return (double)GetFrameTime(); }
double cb_be_time(void) { return GetTime(); }
static RenderTexture2D cb_shot;
static bool cb_shot_ok = false;

bool cb_be_screenshot(const char *path) {
    bool ok;
    if (cb_low_in_frame) {  /* the frame so far, at its own (small) size, with the post effects */
        Image img;
        if (cb_post_on) {
            Rectangle src, dst;
            int w = cb_low.texture.width, h = cb_low.texture.height;
            if (!cb_shot_ok || cb_shot.texture.width != w || cb_shot.texture.height != h) {
                if (cb_shot_ok)
                    UnloadRenderTexture(cb_shot);
                cb_shot = LoadRenderTexture(w, h);
                cb_shot_ok = true;
            }
            EndTextureMode();
            src.x = 0; src.y = 0; src.width = (float)w; src.height = -(float)h;
            dst.x = 0; dst.y = 0; dst.width = (float)w; dst.height = (float)h;
            BeginTextureMode(cb_shot);
            ClearBackground(BLACK);
            cb_post_draw(src, dst);
            EndTextureMode();
            BeginTextureMode(cb_low);
            img = LoadImageFromTexture(cb_shot.texture);
        } else {
            img = LoadImageFromTexture(cb_low.texture);
        }
        ImageFlipVertical(&img);
        ok = ExportImage(img, path);
        UnloadImage(img);
        return ok;
    }
    {   /* (raylib's TakeScreenshot drops the folder: this writes exactly where asked) */
        Image img = LoadImageFromScreen();
        ok = ExportImage(img, path);
        UnloadImage(img);
    }
    return ok;
}

/* ---- the keyboard and the mouse (CB_KEY_* are raylib's own key numbers) ---- */
bool cb_be_key_down(int key) { return IsKeyDown(key); }
bool cb_be_key_pressed(int key) { return IsKeyPressed(key); }
bool cb_be_key_released(int key) { return IsKeyReleased(key); }
bool cb_be_mouse_down(int button) { return IsMouseButtonDown(button); }
bool cb_be_mouse_pressed(int button) { return IsMouseButtonPressed(button); }
bool cb_be_mouse_released(int button) { return IsMouseButtonReleased(button); }
Vector2 cb_be_mouse_pos(void) { Vector2 p = GetMousePosition(); p.x /= cb_pixel_v; p.y /= cb_pixel_v; return p; }
Vector2 cb_be_mouse_delta(void) { Vector2 p = GetMouseDelta(); p.x /= cb_pixel_v; p.y /= cb_pixel_v; return p; }
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
    c.offset = cb_v2(cb_be_width() / 2.0, cb_be_height() / 2.0);
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
static bool cb_lit_ok = false;
/* The light, fog and ambient as last set (the shader has them for models; splats are lit in C with the same numbers). */
static Vector3 cb_sun = { -0.3f, -0.8f, -0.5f };
static float cb_sun_amb = 0.38f, cb_sun_col[3] = { 1, 1, 1 }, cb_fog_col[3] = { 1, 1, 1 }, cb_fog_dens = 0.0f;
static float cb_amb_col[3] = { 1, 1, 1 }, cb_fog_start = 0.0f;  /* false: the shader didn't compile, models stay unlit */
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
    "uniform mat4 mvp;\nuniform mat4 matNormal;\nuniform vec2 snapGrid;\n"
    "VARY vec2 fragTexCoord;\nVARY vec4 fragColor;\nVARY vec3 fragNormal;\n"
    "void main() {\n"
    "    fragTexCoord = vertexTexCoord;\n    fragColor = vertexColor;\n"
    "    fragNormal = (matNormal * vec4(vertexNormal, 0.0)).xyz;\n"
    "    gl_Position = mvp * vec4(vertexPosition, 1.0);\n"
    "    if (snapGrid.x > 0.5) {\n"  /* PS1 wobble: the vertex on screen jumps to a grid of snapGrid points across */
    "        vec2 g = snapGrid * 0.5;\n"
    "        gl_Position.xy = floor(gl_Position.xy / gl_Position.w * g + 0.5) / g * gl_Position.w;\n    }\n}\n";

static const char cb_fs[] = CB_FS_HEAD
    "VARY vec2 fragTexCoord;\nVARY vec4 fragColor;\nVARY vec3 fragNormal;\n"
    "uniform sampler2D texture0;\nuniform vec4 colDiffuse;\nuniform vec3 lightDir;\nuniform float ambient;\n"
    "uniform float shade;\nuniform vec3 lightCol;\nuniform vec3 fogCol;\nuniform float fogDensity;\nuniform vec3 ambientCol;\nuniform float fogStart;\n"
    "void main() {\n"
    "    vec3 n = normalize(fragNormal);\n"
    "    if (!gl_FrontFacing) n = -n;\n"
    "    float diff = max(dot(n, -lightDir), 0.0);\n"
    "    if (shade > 0.5 && shade < 1.5) diff = floor(diff * 3.0 + 0.5) / 3.0;\n"  /* toon: three steps of light */
    "    vec3 light = ambient * ambientCol + (1.0 - ambient) * diff * lightCol;\n"
    "    if (shade > 1.5) light = vec3(1.0);\n"  /* unlit */
    "    vec4 base = TEX(texture0, fragTexCoord) * colDiffuse * fragColor;\n"
    "    float seen = exp(-fogDensity * max(1.0 / gl_FragCoord.w - fogStart, 0.0));\n"  /* 1 / w: the depth from the camera */
    "    FRAG = vec4(mix(fogCol, base.rgb * light, seen), base.a);\n}\n";


static bool cb_wire_3d = false;

/* The lit shader's shade uniform follows the shading setting; the vertex snap its grid. Both wait for the shader. */
static void cb_shade_uniform(void) {
    if (cb_lit_ready && cb_lit_ok) {
        float shade = cb_shading_v == 1 ? 1.0f : cb_shading_v == 2 ? 2.0f : 0.0f;
        SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "shade"), &shade, SHADER_UNIFORM_FLOAT);
    }
}

static void cb_snap_apply(void) {
    if (cb_lit_ready && cb_lit_ok) {
        float g[2];
        g[0] = cb_snap_px > 0 ? (float)cb_be_width() / cb_snap_px : 0.0f;
        g[1] = cb_snap_px > 0 ? (float)cb_be_height() / cb_snap_px : 0.0f;
        SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "snapGrid"), g, SHADER_UNIFORM_VEC2);
    }
}

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
            cb_shade_uniform();
            cb_snap_apply();
        }
        cb_sun = sun;
        cb_sun_amb = amb;
    }
    cb_lit_ready = true;
    {
        cb_rgba white = { 255, 255, 255, 255 };
        cb_set_light_color(white, 1.0);
        cb_set_fog(white, 0.0);
        cb_set_ambient(white, 0.0);
    }
}

/* The post shader (raylib's own vertex shader: fragTexCoord, fragColor). fx = vignette, scanlines, grain, posterize;
   fx2 = bloom, curve, outline, dither. (The editor's preview, scripts/editor/post_fx.gd, is the same maths.) */
static const char cb_post_fs[] = CB_FS_HEAD
    "VARY vec2 fragTexCoord;\nVARY vec4 fragColor;\n"
    "uniform sampler2D texture0;\nuniform vec4 fx;\nuniform vec4 fx2;\nuniform vec2 res;\n"
    "vec3 src(vec2 uv) { return TEX(texture0, uv).rgb; }\n"
    "float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }\n"
    "float b2(float a, float b) { return mod(2.0 * a + 3.0 * b, 4.0); }\n"
    "void main() {\n"
    "    vec2 uv = fragTexCoord;\n"
    "    if (fx2.y > 0.0) {\n"  /* CRT curve: the screen bulges, outside it is black */
    "        vec2 w = uv * 2.0 - 1.0;\n"
    "        w *= vec2(1.0 + w.y * w.y * fx2.y * 0.25, 1.0 + w.x * w.x * fx2.y * 0.25);\n"
    "        uv = w * 0.5 + 0.5;\n"
    "        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { FRAG = vec4(0.0, 0.0, 0.0, 1.0); return; }\n"
    "    }\n"
    "    vec2 px = 1.0 / res;\n"
    "    vec3 c = src(uv);\n"
    "    if (fx2.z > 0.0) {\n"  /* outline: dark where the picture changes sharply (Sobel on the brightness) */
    "        float tl = luma(src(uv + px * vec2(-1.0, -1.0))), t = luma(src(uv + px * vec2(0.0, -1.0))), tr = luma(src(uv + px * vec2(1.0, -1.0)));\n"
    "        float l = luma(src(uv + px * vec2(-1.0, 0.0))), r = luma(src(uv + px * vec2(1.0, 0.0)));\n"
    "        float bl = luma(src(uv + px * vec2(-1.0, 1.0))), bo = luma(src(uv + px * vec2(0.0, 1.0))), br = luma(src(uv + px * vec2(1.0, 1.0)));\n"
    "        float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl), gy = (bl + 2.0 * bo + br) - (tl + 2.0 * t + tr);\n"
    "        c *= 1.0 - fx2.z * clamp(sqrt(gx * gx + gy * gy) * 3.0, 0.0, 1.0);\n"
    "    }\n"
    "    if (fx2.x > 0.0) {\n"  /* bloom: the bright parts of 12 nearby points spill over */
    "        vec3 glow = vec3(0.0);\n"
    "        vec2 o1 = px * 2.5, o2 = px * 5.0;\n"
    "        glow += max(src(uv + vec2(o1.x, 0.0)) - 0.6, 0.0) + max(src(uv - vec2(o1.x, 0.0)) - 0.6, 0.0);\n"
    "        glow += max(src(uv + vec2(0.0, o1.y)) - 0.6, 0.0) + max(src(uv - vec2(0.0, o1.y)) - 0.6, 0.0);\n"
    "        glow += max(src(uv + o1) - 0.6, 0.0) + max(src(uv - o1) - 0.6, 0.0);\n"
    "        glow += max(src(uv + vec2(o1.x, -o1.y)) - 0.6, 0.0) + max(src(uv - vec2(o1.x, -o1.y)) - 0.6, 0.0);\n"
    "        glow += max(src(uv + vec2(o2.x, 0.0)) - 0.6, 0.0) + max(src(uv - vec2(o2.x, 0.0)) - 0.6, 0.0);\n"
    "        glow += max(src(uv + vec2(0.0, o2.y)) - 0.6, 0.0) + max(src(uv - vec2(0.0, o2.y)) - 0.6, 0.0);\n"
    "        c += glow * (fx2.x * 0.25);\n"
    "    }\n"
    "    vec2 d = uv - vec2(0.5);\n"
    "    c *= 1.0 - fx.x * clamp(dot(d, d) * 2.0, 0.0, 1.0);\n"                       /* vignette: dark corners */
    "    c *= 1.0 - fx.y * 0.55 * mod(floor(uv.y * res.y), 2.0);\n"                    /* scanlines: every other row */
    "    c += (fract(sin(dot(floor(uv * res), vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * fx.z * 0.35;\n"  /* grain */
    "    if (fx2.w > 0.0) {\n"  /* dither: a 4 x 4 ordered pattern, one posterize step (or 1/31) wide */
    "        vec2 p = mod(floor(uv * res), 4.0);\n"
    "        float m = (4.0 * b2(mod(p.x, 2.0), mod(p.y, 2.0)) + b2(floor(p.x / 2.0), floor(p.y / 2.0))) / 16.0 - 0.46875;\n"
    "        c += m * fx2.w / (fx.w > 1.5 ? fx.w - 1.0 : 31.0);\n"
    "    }\n"
    "    if (fx.w > 1.5) c = floor(clamp(c, 0.0, 1.0) * (fx.w - 1.0) + 0.5) / (fx.w - 1.0);\n"  /* posterize: fx.w levels a channel */
    "    FRAG = vec4(c, 1.0);\n}\n";

static Shader cb_post_shader;
static bool cb_post_ready = false, cb_post_ok = false;

static void cb_post_draw(Rectangle src, Rectangle dst) {
    if (!cb_post_ready) {
        cb_post_shader = LoadShaderFromMemory(NULL, cb_post_fs);
        cb_post_ok = cb_post_shader.id != rlGetShaderIdDefault();
        cb_post_ready = true;
        if (!cb_post_ok)
            fputs("[warning] post effects aren't available on this GPU\n", stderr);
    }
    if (cb_post_on && cb_post_ok) {
        float res[2];
        res[0] = (float)cb_low.texture.width; res[1] = (float)cb_low.texture.height;
        SetShaderValue(cb_post_shader, GetShaderLocation(cb_post_shader, "fx"), cb_post_fx, SHADER_UNIFORM_VEC4);
        SetShaderValue(cb_post_shader, GetShaderLocation(cb_post_shader, "fx2"), cb_post_fx2, SHADER_UNIFORM_VEC4);
        SetShaderValue(cb_post_shader, GetShaderLocation(cb_post_shader, "res"), res, SHADER_UNIFORM_VEC2);
        BeginShaderMode(cb_post_shader);
        DrawTexturePro(cb_low.texture, src, dst, cb_v2(0, 0), 0.0f, WHITE);
        EndShaderMode();
    } else {
        DrawTexturePro(cb_low.texture, src, dst, cb_v2(0, 0), 0.0f, WHITE);
    }
}

static Model cb_lit_model(Mesh mesh) {
    Model m = LoadModelFromMesh(mesh);
    cb_3d_ready();
    if (cb_lit_ok)
        m.materials[0].shader = cb_lit;
    return m;
}


/* ---- point splatting (2026-11-11): a model drawn as screen-facing discs (or squares) sprinkled over its
   triangles instead of filled triangles. The points are picked per triangle by area (CB_SPLAT_DENSITY a
   square world unit; the object's scale counts, so a big floor and a small box get the same spacing), once
   per model and scale, and kept; they are lit in C with the light, ambient and fog set above, then drawn as
   rlgl quads facing the camera, CB_SPLAT_SIZE across: so splats shrink with distance like real ones. ---- */
typedef struct cb_pt { float p[3], n[3]; unsigned char c[4]; } cb_pt;
#define CB_SPLAT_CHUNK 16384  /* points in one vertex buffer: 4 corners each, so indices fit 16 bits */
/* thin: the points' size factor when the cap thinned them. On the GPU path the points live in vertex buffers
   (chunks of CB_SPLAT_CHUNK points, 4 corner vertices each) and pts is freed; center / radius bound them for culling. */
typedef struct cb_splat_set { const void *key; int qx, qy, qz, stamp; cb_pt *pts; int count; float thin; unsigned int *vao, *vbo; int chunks; float center[3], radius; } cb_splat_set;
#define CB_SPLAT_SETS 48
#define CB_SPLAT_MAX 150000  /* points of one model */
static cb_splat_set cb_splats[CB_SPLAT_SETS];
static int cb_splat_tick = 0;
static bool cb_splat_now = (CB_SPLAT == 2);

void cb_be_splat(bool on) { cb_splat_now = on; }

static void cb_splat_free(cb_splat_set *set) {
    int i;
    for (i = 0; i < set->chunks; i++) {
        rlUnloadVertexArray(set->vao[i]);
        rlUnloadVertexBuffer(set->vbo[i]);
    }
    free(set->vao); free(set->vbo); free(set->pts);
    memset(set, 0, sizeof *set);
}

static void cb_splat_forget(void) {
    int i;
    for (i = 0; i < CB_SPLAT_SETS; i++)
        cb_splat_free(&cb_splats[i]);
}

static int cb_scale_step(float s) { return s > 0.0001f ? (int)floor(log((double)s) / log(1.15) + 0.5) : -999; }

static float cb_rand01(unsigned long *seed) {
    *seed = *seed * 1103515245UL + 12345UL;
    return (float)((*seed >> 8) & 0xFFFFFFUL) / 16777216.0f;
}

static void cb_splat_upload(cb_splat_set *set);

static cb_splat_set *cb_splats_for(const void *key, const Mesh *g, float sx, float sy, float sz) {
    int qx = cb_scale_step(sx), qy = cb_scale_step(sy), qz = cb_scale_step(sz), i, slot = 0, oldest = 0x7fffffff;
    cb_splat_set *set;
    unsigned long seed = 12345UL;
    int cap = 0, t;
    float dens = 1.0f;
    float ex = (float)pow(1.15, qx), ey = (float)pow(1.15, qy), ez = (float)pow(1.15, qz);
    for (i = 0; i < CB_SPLAT_SETS; i++) {
        if (cb_splats[i].key == key && cb_splats[i].qx == qx && cb_splats[i].qy == qy && cb_splats[i].qz == qz) {
            cb_splats[i].stamp = ++cb_splat_tick;
            return &cb_splats[i];
        }
        if (cb_splats[i].stamp < oldest) {
            oldest = cb_splats[i].stamp;
            slot = i;
        }
    }
    set = &cb_splats[slot];
    cb_splat_free(set);
    set->key = key; set->qx = qx; set->qy = qy; set->qz = qz;
    set->stamp = ++cb_splat_tick;
    set->thin = 1.0f;
    {   /* a big object (a floor) would pass the cap and lose its far triangles: thin every triangle evenly instead,
           and let the points grow to keep the surface covered */
        double total = 0.0;
        for (t = 0; t < g->triangleCount; t++) {
            int k;
            float v[3][3], e1[3], e2[3], cr[3];
            for (k = 0; k < 3; k++) {
                int j, ix = g->indices ? (int)g->indices[t * 3 + k] : t * 3 + k;
                for (j = 0; j < 3; j++)
                    v[k][j] = g->vertices[ix * 3 + j];
            }
            for (k = 0; k < 3; k++) {
                e1[k] = (v[1][k] - v[0][k]) * (k == 0 ? ex : k == 1 ? ey : ez);
                e2[k] = (v[2][k] - v[0][k]) * (k == 0 ? ex : k == 1 ? ey : ez);
            }
            cr[0] = e1[1] * e2[2] - e1[2] * e2[1];
            cr[1] = e1[2] * e2[0] - e1[0] * e2[2];
            cr[2] = e1[0] * e2[1] - e1[1] * e2[0];
            total += 0.5 * sqrt((double)(cr[0] * cr[0] + cr[1] * cr[1] + cr[2] * cr[2])) * CB_SPLAT_DENSITY;
        }
        if (total > (double)CB_SPLAT_MAX * 0.95) {
            dens = (float)((double)CB_SPLAT_MAX * 0.95 / total);
            set->thin = 1.0f / sqrtf(dens);
        }
    }
    for (t = 0; t < g->triangleCount && set->count < CB_SPLAT_MAX; t++) {
        int idx[3], k, want;
        float v[3][3], e1[3], e2[3], cr[3], area, expect;
        for (k = 0; k < 3; k++) {
            int j;
            idx[k] = g->indices ? (int)g->indices[t * 3 + k] : t * 3 + k;
            for (j = 0; j < 3; j++)
                v[k][j] = g->vertices[idx[k] * 3 + j];
        }
        for (k = 0; k < 3; k++) {  /* the triangle as the scaled object shows it */
            e1[k] = (v[1][k] - v[0][k]) * (k == 0 ? ex : k == 1 ? ey : ez);
            e2[k] = (v[2][k] - v[0][k]) * (k == 0 ? ex : k == 1 ? ey : ez);
        }
        cr[0] = e1[1] * e2[2] - e1[2] * e2[1];
        cr[1] = e1[2] * e2[0] - e1[0] * e2[2];
        cr[2] = e1[0] * e2[1] - e1[1] * e2[0];
        area = 0.5f * sqrtf(cr[0] * cr[0] + cr[1] * cr[1] + cr[2] * cr[2]);
        expect = area * (float)CB_SPLAT_DENSITY * dens;
        want = (int)expect;
        if (cb_rand01(&seed) < expect - (float)want)
            want++;
        if (set->count + want > cap) {
            cap = (set->count + want) * 2 + 64;
            set->pts = (cb_pt *)realloc((void *)set->pts, sizeof(cb_pt) * (size_t)cap);
            if (!set->pts) { fputs("out of memory\n", stderr); exit(3); }
        }
        for (k = 0; k < want && set->count < CB_SPLAT_MAX; k++) {
            float r1 = sqrtf(cb_rand01(&seed)), r2 = cb_rand01(&seed);
            float w[3], len;
            int j;
            cb_pt *pt = &set->pts[set->count++];
            w[0] = 1.0f - r1; w[1] = r1 * (1.0f - r2); w[2] = r1 * r2;
            for (j = 0; j < 3; j++)
                pt->p[j] = w[0] * v[0][j] + w[1] * v[1][j] + w[2] * v[2][j];
            for (j = 0; j < 3; j++) {
                pt->n[j] = g->normals ? w[0] * g->normals[idx[0] * 3 + j] + w[1] * g->normals[idx[1] * 3 + j] + w[2] * g->normals[idx[2] * 3 + j] : cr[j];
            }
            len = sqrtf(pt->n[0] * pt->n[0] + pt->n[1] * pt->n[1] + pt->n[2] * pt->n[2]);
            if (len > 0.00001f)
                for (j = 0; j < 3; j++)
                    pt->n[j] /= len;
            for (j = 0; j < 4; j++)
                pt->c[j] = g->colors ? (unsigned char)(w[0] * g->colors[idx[0] * 4 + j] + w[1] * g->colors[idx[1] * 4 + j] + w[2] * g->colors[idx[2] * 4 + j] + 0.5f) : 255;
        }
    }
    for (t = set->count - 1; t > 0; t--) {  /* shuffled: any prefix is an even sample (the quality level draws a prefix) */
        int u = (int)(cb_rand01(&seed) * (float)(t + 1));
        cb_pt tmp;
        if (u > t) u = t;
        tmp = set->pts[t]; set->pts[t] = set->pts[u]; set->pts[u] = tmp;
    }
    cb_splat_upload(set);
    return set;
}


/* ---- the GPU path: the points sit in static vertex buffers and a vertex shader does the rest (transform,
   light, fog, the camera-facing corner), so a frame costs the CPU a handful of draw calls however many points
   there are. Each point is 4 vertices (position, normal + which corner, color) and 6 indices. The quality level
   draws a prefix of the shuffled points. If the GPU has no vertex arrays or the shader fails, the C loop below
   draws the points as before. ---- */
static const char cb_splat_vs[] = CB_VS_HEAD
    "ATTR vec3 vertexPosition;\nATTR vec4 vertexNormal;\nATTR vec4 vertexColor;\n"
    "uniform mat4 matModel;\nuniform mat4 matView;\nuniform mat4 matProj;\nuniform float splatHalf;\nuniform vec4 tint;\n"
    "uniform vec3 sunEye;\nuniform float ambient;\nuniform float shade;\nuniform vec3 lightCol;\nuniform vec3 ambientCol;\n"
    "uniform vec3 fogCol;\nuniform float fogDensity;\nuniform float fogStart;\n"
    "VARY vec4 fragColor;\nVARY vec2 fragCorner;\n"
    "void main() {\n"
    "    float k = floor(vertexNormal.w * 127.0 + 0.5);\n"  /* the corner: 0 (-,-), 1 (+,-), 2 (+,+), 3 (-,+) */
    "    vec2 cn = vec2((k > 0.5 && k < 2.5) ? 1.0 : -1.0, k > 1.5 ? 1.0 : -1.0);\n"
    "    vec4 e = matView * (matModel * vec4(vertexPosition, 1.0));\n"
    "    vec3 n = (matView * (matModel * vec4(vertexNormal.xyz, 0.0))).xyz;\n"
    "    n = dot(n, n) > 0.00000001 ? normalize(n) : vec3(0.0, 0.0, 1.0);\n"
    "    if (n.z < 0.0) n = -n;\n"  /* two-sided, like the lit shader */
    "    float diff = max(dot(n, -sunEye), 0.0);\n"
    "    if (shade > 0.5 && shade < 1.5) diff = floor(diff * 3.0 + 0.5) / 3.0;\n"
    "    vec3 light = ambient * ambientCol + (1.0 - ambient) * diff * lightCol;\n"
    "    if (shade > 1.5) light = vec3(1.0);\n"
    "    float depth = -e.z;\n"
    "    float seen = fogDensity > 0.0 ? exp(-fogDensity * max(depth - fogStart, 0.0)) : 1.0;\n"
    "    fragColor = vec4(mix(fogCol, vertexColor.rgb * tint.rgb * light, seen), tint.a);\n"
    "    fragCorner = cn;\n"
    "    e.xy += cn * splatHalf;\n"
    "    gl_Position = matProj * e;\n}\n";

static const char cb_splat_fs[] = CB_FS_HEAD
    "VARY vec4 fragColor;\nVARY vec2 fragCorner;\nuniform float hexa;\n"
    "void main() {\n"
    "    if (hexa > 0.5) {\n"  /* a hexagon, as the C path draws */
    "        vec2 a = abs(fragCorner);\n"
    "        if (max(a.x * 0.8660254 + a.y * 0.5, a.y) > 0.8660254) discard;\n    }\n"
    "    FRAG = fragColor;\n}\n";

static Shader cb_splat_sh;
static int cb_splat_gpu = 0;  /* 0 not tried, 1 works, -1 not available */
static unsigned int cb_splat_ebo = 0;
static int cb_splat_loc[16];
static const char *const cb_splat_names[16] = { "matModel", "matView", "matProj", "splatHalf", "tint", "sunEye", "ambient", "shade",
    "lightCol", "ambientCol", "fogCol", "fogDensity", "fogStart", "hexa", "", "" };

static bool cb_splat_gpu_ok(void) {
    if (cb_splat_gpu)
        return cb_splat_gpu > 0;
    cb_splat_gpu = -1;
    if (!cb_lit_ok)
        return false;
    cb_splat_sh = LoadShaderFromMemory(cb_splat_vs, cb_splat_fs);
    if (cb_splat_sh.id == rlGetShaderIdDefault() || cb_splat_sh.id == 0)
        return false;
    {
        unsigned short *idx = (unsigned short *)malloc(sizeof(unsigned short) * 6 * CB_SPLAT_CHUNK);
        unsigned int vao, i;
        if (!idx)
            return false;
        for (i = 0; i < CB_SPLAT_CHUNK; i++) {
            idx[i * 6] = (unsigned short)(i * 4); idx[i * 6 + 1] = (unsigned short)(i * 4 + 1); idx[i * 6 + 2] = (unsigned short)(i * 4 + 2);
            idx[i * 6 + 3] = (unsigned short)(i * 4); idx[i * 6 + 4] = (unsigned short)(i * 4 + 2); idx[i * 6 + 5] = (unsigned short)(i * 4 + 3);
        }
        vao = rlLoadVertexArray();  /* 0: the GPU has no vertex arrays */
        if (vao == 0) {
            free(idx);
            return false;
        }
        rlEnableVertexArray(vao);  /* the index buffer is loaded with a vertex array bound (core profiles insist) */
        cb_splat_ebo = rlLoadVertexBufferElement(idx, (int)(sizeof(unsigned short) * 6 * CB_SPLAT_CHUNK), false);
        rlDisableVertexArray();
        rlUnloadVertexArray(vao);
        free(idx);
    }
    for (int i = 0; i < 14; i++)
        cb_splat_loc[i] = GetShaderLocation(cb_splat_sh, cb_splat_names[i]);
    {
        float hexa = CB_SPLAT_ROUND ? 1.0f : 0.0f;
        SetShaderValue(cb_splat_sh, cb_splat_loc[13], &hexa, SHADER_UNIFORM_FLOAT);
    }
    cb_splat_gpu = 1;
    return true;
}

/* Packs the points into vertex buffers (and frees them from RAM). A failure leaves them for the C loop. */
static void cb_splat_upload(cb_splat_set *set) {
    static const signed char cx[4] = { 0, 1, 2, 3 };
    int i, c, chunks;
    float lo[3] = { 1e30f, 1e30f, 1e30f }, hi[3] = { -1e30f, -1e30f, -1e30f };
    unsigned char *buf;
    if (set->count == 0)
        return;
    for (i = 0; i < set->count; i++)
        for (c = 0; c < 3; c++) {
            if (set->pts[i].p[c] < lo[c]) lo[c] = set->pts[i].p[c];
            if (set->pts[i].p[c] > hi[c]) hi[c] = set->pts[i].p[c];
        }
    for (c = 0; c < 3; c++)
        set->center[c] = (lo[c] + hi[c]) * 0.5f;
    set->radius = 0.0f;
    for (i = 0; i < set->count; i++) {
        float d[3], r;
        for (c = 0; c < 3; c++)
            d[c] = set->pts[i].p[c] - set->center[c];
        r = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        if (r > set->radius) set->radius = r;
    }
    if (!cb_splat_gpu_ok())
        return;
    chunks = (set->count + CB_SPLAT_CHUNK - 1) / CB_SPLAT_CHUNK;
    set->vao = (unsigned int *)calloc((size_t)chunks, sizeof(unsigned int));
    set->vbo = (unsigned int *)calloc((size_t)chunks, sizeof(unsigned int));
    buf = (unsigned char *)malloc((size_t)CB_SPLAT_CHUNK * 4 * 20);
    if (!set->vao || !set->vbo || !buf) {
        free(set->vao); free(set->vbo); free(buf);
        set->vao = NULL; set->vbo = NULL;
        return;
    }
    for (c = 0; c < chunks; c++) {
        int first = c * CB_SPLAT_CHUNK, n = set->count - first, k;
        unsigned int vao;
        if (n > CB_SPLAT_CHUNK) n = CB_SPLAT_CHUNK;
        for (i = 0; i < n; i++) {
            const cb_pt *pt = &set->pts[first + i];
            for (k = 0; k < 4; k++) {
                unsigned char *v = buf + ((size_t)i * 4 + (size_t)k) * 20;
                signed char nb[4];
                int j;
                memcpy(v, pt->p, 12);
                for (j = 0; j < 3; j++) {
                    float f = pt->n[j] * 127.0f;
                    nb[j] = (signed char)(f < -127.0f ? -127 : f > 127.0f ? 127 : (int)(f < 0 ? f - 0.5f : f + 0.5f));
                }
                nb[3] = cx[k];
                memcpy(v + 12, nb, 4);
                memcpy(v + 16, pt->c, 4);
            }
        }
        vao = rlLoadVertexArray();
        if (vao == 0)
            break;
        rlEnableVertexArray(vao);
        set->vbo[c] = rlLoadVertexBuffer(buf, n * 4 * 20, false);
        rlSetVertexAttribute(0, 3, RL_FLOAT, false, 20, 0);
        rlEnableVertexAttribute(0);
        rlSetVertexAttribute(2, 4, 0x1400 /* GL_BYTE */, true, 20, 12);
        rlEnableVertexAttribute(2);
        rlSetVertexAttribute(3, 4, RL_UNSIGNED_BYTE, true, 20, 16);
        rlEnableVertexAttribute(3);
        rlEnableVertexBufferElement(cb_splat_ebo);
        rlDisableVertexArray();
        set->vao[c] = vao;
        set->chunks = c + 1;
    }
    free(buf);
    if (set->chunks == chunks) {
        free(set->pts);
        set->pts = NULL;
    } else {  /* a vertex array failed half way: drop the buffers, keep the points for the C loop */
        int saved = set->chunks;
        cb_pt *pts = set->pts;
        set->chunks = saved;
        set->pts = NULL;
        {
            int u;
            for (u = 0; u < saved; u++) { rlUnloadVertexArray(set->vao[u]); rlUnloadVertexBuffer(set->vbo[u]); }
        }
        free(set->vao); free(set->vbo);
        set->vao = NULL; set->vbo = NULL; set->chunks = 0;
        set->pts = pts;
    }
}

static bool cb_splat_draw_gpu(cb_splat_set *set, cb_rgba tint, Matrix mdl, Matrix view, Matrix proj, float half, int n, float scale_max) {
    float sun[3], shade, tintv[4], ex, ey, depth, rad, reach_x, reach_y, margin;
    int persp = proj.m15 == 0.0f, c, left;
    if (!set->chunks)
        return false;
    reach_x = 1.0f / (proj.m0 != 0.0f ? proj.m0 : 1.0f);  /* the frustum's side planes, as the C loop tests them */
    reach_y = 1.0f / (proj.m5 != 0.0f ? proj.m5 : 1.0f);
    margin = half * 1.5f + 0.0001f;
    {   /* the whole object off screen: no draw at all */
        float wx = mdl.m0 * set->center[0] + mdl.m4 * set->center[1] + mdl.m8 * set->center[2] + mdl.m12;
        float wy = mdl.m1 * set->center[0] + mdl.m5 * set->center[1] + mdl.m9 * set->center[2] + mdl.m13;
        float wz = mdl.m2 * set->center[0] + mdl.m6 * set->center[1] + mdl.m10 * set->center[2] + mdl.m14;
        ex = view.m0 * wx + view.m4 * wy + view.m8 * wz + view.m12;
        ey = view.m1 * wx + view.m5 * wy + view.m9 * wz + view.m13;
        depth = -(view.m2 * wx + view.m6 * wy + view.m10 * wz + view.m14);
        rad = set->radius * scale_max + margin;
        if (persp) {
            if (depth + rad < 0.02f
                || (fabsf(ex) - depth * reach_x) / sqrtf(1.0f + reach_x * reach_x) > rad
                || (fabsf(ey) - depth * reach_y) / sqrtf(1.0f + reach_y * reach_y) > rad)
                return true;
        } else if (fabsf(ex) > reach_x + rad || fabsf(ey) > reach_y + rad) {
            return true;
        }
    }
    sun[0] = view.m0 * cb_sun.x + view.m4 * cb_sun.y + view.m8 * cb_sun.z;  /* the light in the camera's space */
    sun[1] = view.m1 * cb_sun.x + view.m5 * cb_sun.y + view.m9 * cb_sun.z;
    sun[2] = view.m2 * cb_sun.x + view.m6 * cb_sun.y + view.m10 * cb_sun.z;
    shade = cb_shading_v == 1 ? 1.0f : cb_shading_v == 2 ? 2.0f : 0.0f;
    tintv[0] = tint.r / 255.0f; tintv[1] = tint.g / 255.0f; tintv[2] = tint.b / 255.0f; tintv[3] = tint.a / 255.0f;
    rlDrawRenderBatchActive();
    rlDisableBackfaceCulling();
    SetShaderValueMatrix(cb_splat_sh, cb_splat_loc[0], mdl);
    SetShaderValueMatrix(cb_splat_sh, cb_splat_loc[1], view);
    SetShaderValueMatrix(cb_splat_sh, cb_splat_loc[2], proj);
    SetShaderValue(cb_splat_sh, cb_splat_loc[3], &half, SHADER_UNIFORM_FLOAT);
    SetShaderValue(cb_splat_sh, cb_splat_loc[4], tintv, SHADER_UNIFORM_VEC4);
    SetShaderValue(cb_splat_sh, cb_splat_loc[5], sun, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_splat_sh, cb_splat_loc[6], &cb_sun_amb, SHADER_UNIFORM_FLOAT);
    SetShaderValue(cb_splat_sh, cb_splat_loc[7], &shade, SHADER_UNIFORM_FLOAT);
    SetShaderValue(cb_splat_sh, cb_splat_loc[8], cb_sun_col, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_splat_sh, cb_splat_loc[9], cb_amb_col, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_splat_sh, cb_splat_loc[10], cb_fog_col, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_splat_sh, cb_splat_loc[11], &cb_fog_dens, SHADER_UNIFORM_FLOAT);
    SetShaderValue(cb_splat_sh, cb_splat_loc[12], &cb_fog_start, SHADER_UNIFORM_FLOAT);
    rlEnableShader(cb_splat_sh.id);
    left = n;
    for (c = 0; c < set->chunks && left > 0; c++) {
        int k = left > CB_SPLAT_CHUNK ? CB_SPLAT_CHUNK : left;
        if (rlEnableVertexArray(set->vao[c]))
            rlDrawVertexArrayElements(0, k * 6, NULL);
        left -= k;
    }
    rlDisableVertexArray();
    rlDisableShader();
    rlEnableBackfaceCulling();
    return true;
}

#ifdef CB_SPLAT_PROFILE
static double cb_prof_t0 = 0, cb_prof_ms = 0;
static long cb_prof_pts = 0, cb_prof_draws = 0, cb_prof_emit = 0;
void cb_prof_report(void) { fprintf(stderr, "[splat] draws %ld, points %ld, drawn %ld, %.1f ms in the draws, quality %.2f\n", cb_prof_draws, cb_prof_pts, cb_prof_emit, cb_prof_ms, (double)cb_splat_q); cb_prof_emit = 0; cb_prof_draws = 0; cb_prof_pts = 0; cb_prof_ms = 0; }
#endif

/* Draws mesh g's points (the current transform is the object's placement). */
static void cb_splat_draw(const void *key, const Mesh *g, cb_rgba tint) {
    Matrix view = rlGetMatrixModelview(), mdl = rlGetMatrixTransform();
    float sx = sqrtf(mdl.m0 * mdl.m0 + mdl.m1 * mdl.m1 + mdl.m2 * mdl.m2);
    float sy = sqrtf(mdl.m4 * mdl.m4 + mdl.m5 * mdl.m5 + mdl.m6 * mdl.m6);
    float sz = sqrtf(mdl.m8 * mdl.m8 + mdl.m9 * mdl.m9 + mdl.m10 * mdl.m10);
    float rx = view.m0, ry = view.m4, rz = view.m8;  /* the camera's right, up and back in the world */
    float ux = view.m1, uy = view.m5, uz = view.m9;
    float bx = view.m2, by = view.m6, bz = view.m10;
    Matrix proj = rlGetMatrixProjection();
    int persp = proj.m15 == 0.0f;
    float half, margin_x, margin_y, reach_x, reach_y;
    int i, n, shaded = cb_shading_v != 2;
    cb_splat_set *set = cb_splats_for(key, g, sx, sy, sz);
    static const float ring[6][2] = { { 1.0f, 0.0f }, { 0.5f, 0.8660254f }, { -0.5f, 0.8660254f }, { -1.0f, 0.0f }, { -0.5f, -0.8660254f }, { 0.5f, -0.8660254f } };
    if (set->count == 0)
        return;
    n = (int)((float)set->count * cb_splat_q + 0.5f);  /* the quality level: a prefix of the shuffled points, grown to cover the same */
    if (n < 1) n = 1;
    if (n > set->count) n = set->count;
    half = (float)CB_SPLAT_SIZE * 0.5f * set->thin / sqrtf((float)n / (float)set->count);
    reach_x = 1.0f / (proj.m0 != 0.0f ? proj.m0 : 1.0f);  /* how far from the view's axis a splat can still show: its eye-space x per depth (or flat when orthographic) */
    reach_y = 1.0f / (proj.m5 != 0.0f ? proj.m5 : 1.0f);
    margin_x = half * 1.5f; margin_y = half * 1.5f;
    cb_splat_drawn += n;
    if (set->chunks && cb_splat_draw_gpu(set, tint, mdl, view, proj, half, n, fmaxf(sx, fmaxf(sy, sz))))
        return;
#ifdef CB_SPLAT_PROFILE
    cb_prof_t0 = GetTime();
    cb_prof_pts += n;
#endif
    rlDrawRenderBatchActive();
    rlDisableBackfaceCulling();
    rlPushMatrix();
    rlLoadIdentity();  /* the points are placed in the world by hand below */
    rlSetTexture(0);
    rlBegin(RL_QUADS);
    for (i = 0; i < n; i++) {
        const cb_pt *pt = &set->pts[i];
        float wx = mdl.m0 * pt->p[0] + mdl.m4 * pt->p[1] + mdl.m8 * pt->p[2] + mdl.m12;
        float wy = mdl.m1 * pt->p[0] + mdl.m5 * pt->p[1] + mdl.m9 * pt->p[2] + mdl.m13;
        float wz = mdl.m2 * pt->p[0] + mdl.m6 * pt->p[1] + mdl.m10 * pt->p[2] + mdl.m14;
        float col[3], k, ex, ey, depth;
        int j;
        ex = view.m0 * wx + view.m4 * wy + view.m8 * wz + view.m12;  /* the point in the camera's space: off screen ones are skipped */
        ey = view.m1 * wx + view.m5 * wy + view.m9 * wz + view.m13;
        depth = -(view.m2 * wx + view.m6 * wy + view.m10 * wz + view.m14);
        if (persp) {
            if (depth < 0.02f || fabsf(ex) > depth * reach_x + margin_x || fabsf(ey) > depth * reach_y + margin_y)
                continue;
        } else if (fabsf(ex) > reach_x + margin_x || fabsf(ey) > reach_y + margin_y) {
            continue;
        }
        col[0] = pt->c[0] / 255.0f * tint.r / 255.0f;
        col[1] = pt->c[1] / 255.0f * tint.g / 255.0f;
        col[2] = pt->c[2] / 255.0f * tint.b / 255.0f;
        if (shaded) {
            float nx = mdl.m0 * pt->n[0] + mdl.m4 * pt->n[1] + mdl.m8 * pt->n[2];
            float ny = mdl.m1 * pt->n[0] + mdl.m5 * pt->n[1] + mdl.m9 * pt->n[2];
            float nz = mdl.m2 * pt->n[0] + mdl.m6 * pt->n[1] + mdl.m10 * pt->n[2];
            float len = sqrtf(nx * nx + ny * ny + nz * nz), diff;
            if (len > 0.00001f) { nx /= len; ny /= len; nz /= len; }
            if (nx * bx + ny * by + nz * bz < 0.0f) { nx = -nx; ny = -ny; nz = -nz; }  /* two-sided, like the shader */
            diff = -(nx * cb_sun.x + ny * cb_sun.y + nz * cb_sun.z);
            if (diff < 0.0f) diff = 0.0f;
            if (cb_shading_v == 1) diff = floorf(diff * 3.0f + 0.5f) / 3.0f;
            for (j = 0; j < 3; j++)
                col[j] *= cb_sun_amb * cb_amb_col[j] + (1.0f - cb_sun_amb) * diff * cb_sun_col[j];
        }
        {
            float seen;
            seen = cb_fog_dens > 0.0f ? expf(-cb_fog_dens * (depth > cb_fog_start ? depth - cb_fog_start : 0.0f)) : 1.0f;
            for (j = 0; j < 3; j++) {
                k = cb_fog_col[j] + (col[j] - cb_fog_col[j]) * seen;
                col[j] = k < 0.0f ? 0.0f : k > 1.0f ? 1.0f : k;
            }
        }
#ifdef CB_SPLAT_PROFILE
        cb_prof_emit++;
#endif
        rlColor4ub((unsigned char)(col[0] * 255.0f), (unsigned char)(col[1] * 255.0f), (unsigned char)(col[2] * 255.0f), tint.a);
#define CB_CORNER(ax, ay) rlVertex3f(wx + half * ((ax) * rx + (ay) * ux), wy + half * ((ax) * ry + (ay) * uy), wz + half * ((ax) * rz + (ay) * uz))
        if (CB_SPLAT_ROUND) {  /* a hexagon: three quads around the middle */
            for (j = 0; j < 3; j++) {
                const float *a = ring[j * 2], *b = ring[j * 2 + 1], *c = ring[(j * 2 + 2) % 6];
                rlVertex3f(wx, wy, wz);
                CB_CORNER(a[0], a[1]);
                CB_CORNER(b[0], b[1]);
                CB_CORNER(c[0], c[1]);
            }
        } else {
            CB_CORNER(-1.0f, -1.0f);
            CB_CORNER(1.0f, -1.0f);
            CB_CORNER(1.0f, 1.0f);
            CB_CORNER(-1.0f, 1.0f);
        }
#undef CB_CORNER
    }
    rlEnd();
    rlDrawRenderBatchActive();
#ifdef CB_SPLAT_PROFILE
    cb_prof_ms += (GetTime() - cb_prof_t0) * 1000.0;
    cb_prof_draws++;
#endif
    rlPopMatrix();
    rlEnableBackfaceCulling();
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
#if !defined(GRAPHICS_API_OPENGL_ES2)
    cb_wire_3d = (cb_shading_v == 3);
    if (cb_wire_3d)
        rlEnableWireMode();
#endif
}

void cb_be_end_3d(void) {
#if !defined(GRAPHICS_API_OPENGL_ES2)
    if (cb_wire_3d)
        rlDisableWireMode();
    cb_wire_3d = false;
#endif
    EndMode3D();
}

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
    if (cb_splat_now) {
        rlPushMatrix();
        rlTranslatef(at.x, at.y, at.z);
        rlRotatef((float)turn, 0, 1, 0);
        rlScalef(size.x, size.y, size.z);
        cb_splat_draw(&cb_shape_models[kind], &cb_shape_models[kind].meshes[0], color);
        rlPopMatrix();
        return;
    }
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

/* One triangle (INTERNAL: corners already counter-clockwise: your code calls cb_mesh_triangle, clockwise); normals given (own) or not. */
static void cb_mesh_add(cb_mesh *m, Vector3 a, Vector3 b, Vector3 c, const Vector3 *normals, Color color) {
    cb_tri *t = (cb_tri *)cb_list_add(m->tris);
    t->p[0] = a; t->p[1] = b; t->p[2] = c;
    t->c = color;
    if (normals) {
        t->n[0] = normals[0]; t->n[1] = normals[1]; t->n[2] = normals[2];
        t->own = 1;
    }
}

/* The public triangle: its front is the side where a, b, c go round CLOCKWISE (the Add to mesh
   brick's rule: (0,0,0) (1,0,0) (0,0,1) faces up). It is stored counter-clockwise (a, c, b). */
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
    cb_splat_forget();
    m->built = g.vertexCount > 0 || m->built;
    m->both = both_sides;
    m->smooth = smooth;
    cb_list_clear(m->tris);
}

void cb_draw_mesh(cb_mesh *m, Vector3 at, Vector3 size, double turn, cb_rgba rgba) {
    Color tint = RL(rgba);
    if (!m || !m->built || m->model.meshes[0].vertexCount == 0)
        return;
    if (cb_splat_now) {
        rlPushMatrix();
        rlTranslatef(at.x, at.y, at.z);
        rlRotatef((float)turn, 0, 1, 0);
        rlScalef(size.x, size.y, size.z);
        cb_splat_draw(m, &m->model.meshes[0], rgba);
        rlPopMatrix();
        return;
    }
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
    cb_splat_forget();
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
    cb_sun = sun;
    cb_sun_amb = amb;
    if (!cb_lit_ok)
        return;
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "lightDir"), &sun, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "ambient"), &amb, SHADER_UNIFORM_FLOAT);
}

/* The sun's color times its energy (Light3D), and the fog (Environment: density 0 = none). */
void cb_set_light_color(cb_rgba color, double energy) {
    cb_3d_ready();
    cb_sun_col[0] = (float)(color.r / 255.0 * energy);
    cb_sun_col[1] = (float)(color.g / 255.0 * energy);
    cb_sun_col[2] = (float)(color.b / 255.0 * energy);
    if (cb_lit_ok)
        SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "lightCol"), cb_sun_col, SHADER_UNIFORM_VEC3);
}

void cb_set_fog(cb_rgba color, double density) {
    cb_3d_ready();
    cb_fog_col[0] = color.r / 255.0f;
    cb_fog_col[1] = color.g / 255.0f;
    cb_fog_col[2] = color.b / 255.0f;
    cb_fog_dens = density > 0 ? (float)density : 0.0f;
    if (!cb_lit_ok)
        return;
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "fogCol"), cb_fog_col, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "fogDensity"), &cb_fog_dens, SHADER_UNIFORM_FLOAT);
}

/* The ambient light's colour and where fog begins (Environment: ambient_color, fog_start). */
void cb_set_ambient(cb_rgba color, double fog_start) {
    cb_3d_ready();
    cb_amb_col[0] = color.r / 255.0f;
    cb_amb_col[1] = color.g / 255.0f;
    cb_amb_col[2] = color.b / 255.0f;
    cb_fog_start = fog_start > 0 ? (float)fog_start : 0.0f;
    if (!cb_lit_ok)
        return;
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "ambientCol"), cb_amb_col, SHADER_UNIFORM_VEC3);
    SetShaderValue(cb_lit, GetShaderLocation(cb_lit, "fogStart"), &cb_fog_start, SHADER_UNIFORM_FLOAT);
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

void cb_be_target_end(void) {
    EndTextureMode();
    if (cb_low_in_frame)
        BeginTextureMode(cb_low);  /* back into the frame's small texture */
}

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
