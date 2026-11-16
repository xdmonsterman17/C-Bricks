/* The C-Bricks backend contract (CB_BACKEND_API 1).
 *
 * A backend is ONE C file (cbricks_backend.c in a built project) that does everything a platform
 * or graphics library does for C-Bricks: the window, the input, drawing, and, if it can, sound,
 * textures and 3D. The rest of C-Bricks (cbricks_gfx.c: the world, UI, physics, frames, pause,
 * the bricks' cb_* functions) calls ONLY the functions below, in C-Bricks' own types (cb_rgba,
 * cb_rect, Vector2 / Vector3, the cb_texture / cb_sound / cb_music handles, CB_KEY_* codes), so a
 * new target (a console, a handheld, a custom machine) needs only this file.
 *
 * This header is included by cbricks.h after its types; it needs nothing else.
 *
 * REQUIRED CORE (write these first; ~30 functions: a window you can see and a keyboard that works):
 *   window, frame, timing, keyboard, mouse, clear, rectangles, circle, line, text.
 *
 * OPTIONAL GROUPS: a backend that provides a group says so with a define at the top of its file:
 *       #define CB_BE_HAVE_TEXTURES 1
 *   and implements every function of that group. A group it does not provide gets the harmless
 *   defaults of cb_be_stubs.c (appended after the backend: drawing does nothing, loading returns a
 *   handle with id 0, "playing" is false), so a first version can run a program before the
 *   backend is finished. Groups:
 *     CB_BE_HAVE_2D_EXTRA    rounded rectangles, vertical gradient, the 2D camera
 *     CB_BE_HAVE_TEXTURES    textures
 *     CB_BE_HAVE_FONTS       fonts loaded from a file (without: the default font draws)
 *     CB_BE_HAVE_SOUND       sounds and music
 *     CB_BE_HAVE_3D          the 3D view, transforms, 3D lines, shapes, meshes, lights, fog
 *     CB_BE_HAVE_LOOK        post effects, shading / splat settings (needs 3D to matter)
 *     CB_BE_HAVE_TARGETS     render targets (camera snapshots, scene thumbnails)
 *     CB_BE_HAVE_SCREENSHOT  cb_be_screenshot
 *
 * Conventions: colors are cb_rgba (0..255); coordinates are pixels, y down; 3D is right-handed,
 * y up; times are seconds; key / button codes are the CB_KEY_* / mouse numbers of cbricks.h.
 * A handle with id 0 means "not loaded". Fatal problems print to stderr and exit(3).
 * The backend must stay C99 and -pedantic clean.
 */
#ifndef CB_BACKEND_H
#define CB_BACKEND_H
#define CB_BACKEND_API 1

/* ======== REQUIRED CORE ======== */
/* window and frames */
bool cb_be_open(int width, int height, const char *title, int fps, bool esc_closes);
void cb_be_close(void);
bool cb_be_should_close(void);
bool cb_be_ready(void);              /* the window is open */
void cb_be_begin_frame(void);        /* start drawing a frame */
void cb_be_end_frame(void);          /* show it, wait for the frame rate, poll input */
void cb_be_flush(void);              /* draw what is queued now (before a render target / screenshot) */
int cb_be_width(void);
int cb_be_height(void);
int cb_be_fps(void);
double cb_be_frame_time(void);       /* seconds the last frame took */
double cb_be_time(void);             /* seconds since the window opened */
/* keyboard, mouse */
bool cb_be_key_down(int key);
bool cb_be_key_pressed(int key);
bool cb_be_key_released(int key);
bool cb_be_mouse_down(int button);
bool cb_be_mouse_pressed(int button);
bool cb_be_mouse_released(int button);
int cb_be_char_typed(void);          /* the next typed character (Unicode), or 0 */
Vector2 cb_be_mouse_pos(void);
Vector2 cb_be_mouse_delta(void);
double cb_be_mouse_wheel(void);
void cb_be_cursor(int mode);         /* 0 shown, 1 hidden, 2 captured */
bool cb_be_cursor_hidden(void);
/* 2D drawing */
void cb_be_clear(cb_rgba c);
void cb_be_rect(cb_rect r, Vector2 origin, double rotation, cb_rgba c);
void cb_be_rect_lines(cb_rect r, double thick, cb_rgba c);
void cb_be_circle(Vector2 at, double radius, cb_rgba c);
void cb_be_line(Vector2 a, Vector2 b, cb_rgba c);
void cb_be_text(const char *text, Vector2 at, Vector2 origin, double rotation, double size, cb_rgba c);
Vector2 cb_be_text_size(const char *text, double size);

/* ======== CB_BE_HAVE_2D_EXTRA ======== */
void cb_be_rect_rounded(cb_rect r, double roundness, cb_rgba c);
void cb_be_rect_rounded_lines(cb_rect r, double roundness, double thick, cb_rgba c);
void cb_be_gradient_v(cb_rect r, cb_rgba top, cb_rgba bottom);
void cb_be_begin_2d(Vector2 center, double zoom, double rotation);
void cb_be_end_2d(void);

/* ======== CB_BE_HAVE_TEXTURES ======== */
cb_texture cb_be_texture_load(const char *path);   /* PNG; id 0 when it can't be read */
void cb_be_texture(cb_texture t, cb_rect src, cb_rect dst, Vector2 origin, double rotation, cb_rgba tint);

/* ======== CB_BE_HAVE_FONTS ======== */
cb_font cb_be_font_load(const char *path, int size);   /* TTF / OTF rasterized at size pixels; id 0 when it can't be read */
void cb_be_text_font(cb_font f, const char *text, Vector2 at, Vector2 origin, double rotation, double size, cb_rgba c);
Vector2 cb_be_text_size_font(cb_font f, const char *text, double size);   /* id 0 = the default font */
void cb_be_fonts_forget_all(void);                     /* before the window closes */

/* ======== CB_BE_HAVE_SOUND ======== */
cb_sound cb_be_sound_load(const char *path);
void cb_be_sound_play(cb_sound s);
cb_music cb_be_music_load(const char *path, bool loop);
void cb_be_music_play(cb_music m);
void cb_be_music_stop(cb_music m);
void cb_be_music_pause(cb_music m);
void cb_be_music_resume(cb_music m);
void cb_be_music_volume(cb_music m, double volume);
bool cb_be_music_playing(cb_music m);
void cb_be_music_update(void);       /* every frame: feed the streams */
void cb_be_music_forget_all(void);

/* ======== CB_BE_HAVE_3D ======== */
void cb_be_begin_3d(Vector3 position, Vector3 target, double fov, bool ortho);
void cb_be_end_3d(void);
void cb_be_splat(bool on);           /* the shapes / meshes drawn next are point splats */
void cb_be_push(void);
void cb_be_pop(void);
void cb_be_translate(double x, double y, double z);
void cb_be_rotate(double degrees, double x, double y, double z);
void cb_be_scale(double x, double y, double z);
void cb_be_line3d(Vector3 a, Vector3 b, cb_rgba c);
void cb_be_grid(int lines, double spacing);
void cb_be_wire_box(Vector3 at, Vector3 size, cb_rgba c);
void cb_draw_shape(int kind, Vector3 at, Vector3 size, double turn, cb_rgba color);
cb_mesh *cb_mesh_new(void);
cb_mesh *cb_mesh_begin(cb_mesh *mesh);
/* front = the side where a, b, c go round CLOCKWISE (Add to mesh: (0,0,0) (1,0,0) (0,0,1) faces up) */
void cb_mesh_triangle(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, cb_rgba color);
void cb_mesh_quad(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, Vector3 d, cb_rgba color);
/* the same winding (clockwise), with a normal and a texture coordinate (u, v) at each corner: the normals are used as given
   (not recomputed, not averaged by Smooth); a backend without textured meshes may ignore the texture coordinates */
void cb_mesh_triangle_nuv(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, Vector3 na, Vector3 nb, Vector3 nc, Vector2 ua, Vector2 ub, Vector2 uc, cb_rgba color);
void cb_mesh_shape(cb_mesh *mesh, int kind, Vector3 at, Vector3 size, cb_rgba color);
void cb_mesh_finish(cb_mesh *mesh, bool smooth, bool both_sides, int file, int brick);
void cb_draw_mesh(cb_mesh *mesh, Vector3 at, Vector3 size, double turn, cb_rgba tint);
void cb_draw_mesh_rot(cb_mesh *mesh, Vector3 at, Vector3 size, Vector3 rot, cb_rgba tint);
cb_list *cb_mesh_points(const cb_mesh *mesh);
void cb_mesh_set_points(cb_mesh *mesh, const cb_list *points, int file, int brick);
void cb_show_mesh(FILE *f, const void *value);
void cb_set_light(Vector3 direction, double ambient);
void cb_set_light_color(cb_rgba color, double energy);
void cb_set_fog(cb_rgba color, double density);
void cb_set_ambient(cb_rgba color, double fog_start);

/* ======== CB_BE_HAVE_LOOK ======== */
void cb_be_post(double vignette, double scanlines, double grain, double posterize, double bloom, double curve, double outline, double dither, double snap);
void cb_be_set_look(int what, int value);   /* 0 shading (lit toon unlit wire), 1 splatting (off mixed full), 2 pixel size */
int cb_be_splat_mode(void);

/* ======== CB_BE_HAVE_TARGETS ======== */
void cb_be_target_begin(int width, int height);
void cb_be_target_end(void);
bool cb_be_target_save(const char *path);
cb_texture cb_be_target_texture(void);
void cb_be_target_free(void);

/* ======== CB_BE_HAVE_SCREENSHOT ======== */
bool cb_be_screenshot(const char *path);

#endif
