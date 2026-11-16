/* Defaults for the backend's optional groups (see cb_backend.h): appended after the backend, so a
   group the backend does not declare (#define CB_BE_HAVE_<GROUP> 1) does nothing instead of
   failing to link. A program that uses it still runs; it just draws / plays nothing. */
#ifndef CB_BE_HAVE_2D_EXTRA
void cb_be_rect_rounded(cb_rect r, double roundness, cb_rgba c) { (void)roundness; cb_be_rect(r, cb_v2(0, 0), 0, c); }
void cb_be_rect_rounded_lines(cb_rect r, double roundness, double thick, cb_rgba c) { (void)roundness; cb_be_rect_lines(r, thick, c); }
void cb_be_gradient_v(cb_rect r, cb_rgba top, cb_rgba bottom) { (void)bottom; cb_be_rect(r, cb_v2(0, 0), 0, top); }
void cb_be_begin_2d(Vector2 center, double zoom, double rotation) { (void)center; (void)zoom; (void)rotation; }
void cb_be_end_2d(void) {}
#endif

#ifndef CB_BE_HAVE_TEXTURES
cb_texture cb_be_texture_load(const char *path) { cb_texture t; (void)path; t.id = 0; t.width = 0; t.height = 0; return t; }
void cb_be_texture(cb_texture t, cb_rect src, cb_rect dst, Vector2 origin, double rotation, cb_rgba tint) {
    (void)t; (void)src; (void)dst; (void)origin; (void)rotation; (void)tint;
}
#endif

#ifndef CB_BE_HAVE_FONTS
cb_font cb_be_font_load(const char *path, int size) { cb_font f; (void)path; (void)size; f.id = 0; return f; }
void cb_be_text_font(cb_font f, const char *text, Vector2 at, Vector2 origin, double rotation, double size, cb_rgba c) {
    (void)f; cb_be_text(text, at, origin, rotation, size, c);
}
Vector2 cb_be_text_size_font(cb_font f, const char *text, double size) { (void)f; return cb_be_text_size(text, size); }
void cb_be_fonts_forget_all(void) {}
#endif

#ifndef CB_BE_HAVE_SOUND
cb_sound cb_be_sound_load(const char *path) { cb_sound s; (void)path; s.id = 0; s.frames = 0; return s; }
void cb_be_sound_play(cb_sound s) { (void)s; }
cb_music cb_be_music_load(const char *path, bool loop) { cb_music m; (void)path; m.id = 0; m.length = 0; m.looping = loop; return m; }
void cb_be_music_play(cb_music m) { (void)m; }
void cb_be_music_stop(cb_music m) { (void)m; }
void cb_be_music_pause(cb_music m) { (void)m; }
void cb_be_music_resume(cb_music m) { (void)m; }
void cb_be_music_volume(cb_music m, double volume) { (void)m; (void)volume; }
bool cb_be_music_playing(cb_music m) { (void)m; return false; }
void cb_be_music_update(void) {}
void cb_be_music_forget_all(void) {}
#endif

#ifndef CB_BE_HAVE_3D
struct cb_mesh { int triangles; };
void cb_be_begin_3d(Vector3 position, Vector3 target, double fov, bool ortho) { (void)position; (void)target; (void)fov; (void)ortho; }
void cb_be_end_3d(void) {}
void cb_be_splat(bool on) { (void)on; }
void cb_be_push(void) {}
void cb_be_pop(void) {}
void cb_be_translate(double x, double y, double z) { (void)x; (void)y; (void)z; }
void cb_be_rotate(double degrees, double x, double y, double z) { (void)degrees; (void)x; (void)y; (void)z; }
void cb_be_scale(double x, double y, double z) { (void)x; (void)y; (void)z; }
void cb_be_line3d(Vector3 a, Vector3 b, cb_rgba c) { (void)a; (void)b; (void)c; }
void cb_be_grid(int lines, double spacing) { (void)lines; (void)spacing; }
void cb_be_wire_box(Vector3 at, Vector3 size, cb_rgba c) { (void)at; (void)size; (void)c; }
void cb_draw_shape(int kind, Vector3 at, Vector3 size, double turn, cb_rgba color) { (void)kind; (void)at; (void)size; (void)turn; (void)color; }
cb_mesh *cb_mesh_new(void) { return (cb_mesh *)cb_alloc(sizeof(cb_mesh)); }
cb_mesh *cb_mesh_begin(cb_mesh *mesh) { if (!mesh) mesh = cb_mesh_new(); mesh->triangles = 0; return mesh; }
void cb_mesh_triangle(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, cb_rgba color) { (void)a; (void)b; (void)c; (void)color; mesh->triangles++; }
void cb_mesh_triangle_nuv(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, Vector3 na, Vector3 nb, Vector3 nc, Vector2 ua, Vector2 ub, Vector2 uc, cb_rgba color) { (void)a; (void)b; (void)c; (void)na; (void)nb; (void)nc; (void)ua; (void)ub; (void)uc; (void)color; mesh->triangles++; }
void cb_mesh_quad(cb_mesh *mesh, Vector3 a, Vector3 b, Vector3 c, Vector3 d, cb_rgba color) { (void)a; (void)b; (void)c; (void)d; (void)color; mesh->triangles += 2; }
void cb_mesh_shape(cb_mesh *mesh, int kind, Vector3 at, Vector3 size, cb_rgba color) { (void)kind; (void)at; (void)size; (void)color; mesh->triangles++; }
void cb_mesh_finish(cb_mesh *mesh, bool smooth, bool both_sides, int file, int brick) { (void)mesh; (void)smooth; (void)both_sides; (void)file; (void)brick; }
void cb_draw_mesh(cb_mesh *mesh, Vector3 at, Vector3 size, double turn, cb_rgba tint) { (void)mesh; (void)at; (void)size; (void)turn; (void)tint; }
void cb_draw_mesh_rot(cb_mesh *mesh, Vector3 at, Vector3 size, Vector3 rot, cb_rgba tint) { (void)mesh; (void)at; (void)size; (void)rot; (void)tint; }
cb_list *cb_mesh_points(const cb_mesh *mesh) { (void)mesh; return cb_list_new(sizeof(Vector3)); }
void cb_mesh_set_points(cb_mesh *mesh, const cb_list *points, int file, int brick) { (void)mesh; (void)points; (void)file; (void)brick; }
void cb_show_mesh(FILE *f, const void *value) { const cb_mesh *m = *(cb_mesh *const *)value; fprintf(f, "mesh (%d triangles)", m ? m->triangles : 0); }
void cb_set_light(Vector3 direction, double ambient) { (void)direction; (void)ambient; }
void cb_set_light_color(cb_rgba color, double energy) { (void)color; (void)energy; }
void cb_set_fog(cb_rgba color, double density) { (void)color; (void)density; }
void cb_set_ambient(cb_rgba color, double fog_start) { (void)color; (void)fog_start; }
#endif

#ifndef CB_BE_HAVE_LOOK
void cb_be_post(double vignette, double scanlines, double grain, double posterize, double bloom, double curve, double outline, double dither, double snap) {
    (void)vignette; (void)scanlines; (void)grain; (void)posterize; (void)bloom; (void)curve; (void)outline; (void)dither; (void)snap;
}
void cb_be_set_look(int what, int value) { (void)what; (void)value; }
int cb_be_splat_mode(void) { return 0; }
#endif

#ifndef CB_BE_HAVE_TARGETS
void cb_be_target_begin(int width, int height) { (void)width; (void)height; }
void cb_be_target_end(void) {}
bool cb_be_target_save(const char *path) { (void)path; return false; }
cb_texture cb_be_target_texture(void) { cb_texture t; t.id = 0; t.width = 0; t.height = 0; return t; }
void cb_be_target_free(void) {}
#endif

#ifndef CB_BE_HAVE_SCREENSHOT
bool cb_be_screenshot(const char *path) { (void)path; return false; }
#endif
