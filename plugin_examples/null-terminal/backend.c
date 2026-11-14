/* Null terminal backend: the required core of cb_backend.h and nothing else. Text drawn is printed
   ("text: ..." lines), every other drawing call does nothing, nobody presses a key. The program
   closes after CB_NULL_FRAMES frames (default 3) so it always ends. The plugin's setting "frames"
   (target.cfg [setting.frames], Project Settings > Plugins) arrives as CB_PLUGIN_NULL_TERMINAL_FRAMES. */
#include "cbricks.h"

static bool nt_open = false;
static int nt_width = 640, nt_height = 480, nt_fps = 60, nt_frames = 0, nt_limit = 3;
static double nt_time = 0;

bool cb_be_open(int width, int height, const char *title, int fps, bool esc_closes) {
    const char *env = getenv("CB_NULL_FRAMES");
    (void)esc_closes;
#ifdef CB_PLUGIN_NULL_TERMINAL_FRAMES
    nt_limit = CB_PLUGIN_NULL_TERMINAL_FRAMES;
#endif
    nt_width = width; nt_height = height; nt_fps = fps > 0 ? fps : 60;
    if (env && atoi(env) > 0) nt_limit = atoi(env);
    printf("window: %dx%d \"%s\"\n", width, height, title);
    nt_open = true;
    return true;
}
void cb_be_close(void) { nt_open = false; }
bool cb_be_should_close(void) { return nt_frames >= nt_limit; }
bool cb_be_ready(void) { return nt_open; }
void cb_be_begin_frame(void) {}
void cb_be_end_frame(void) { nt_frames++; nt_time += 1.0 / nt_fps; printf("frame %d\n", nt_frames); }
void cb_be_flush(void) {}
int cb_be_width(void) { return nt_width; }
int cb_be_height(void) { return nt_height; }
int cb_be_fps(void) { return nt_fps; }
double cb_be_frame_time(void) { return 1.0 / nt_fps; }
double cb_be_time(void) { return nt_time; }

bool cb_be_key_down(int key) { (void)key; return false; }
bool cb_be_key_pressed(int key) { (void)key; return false; }
bool cb_be_key_released(int key) { (void)key; return false; }
bool cb_be_mouse_down(int button) { (void)button; return false; }
bool cb_be_mouse_pressed(int button) { (void)button; return false; }
bool cb_be_mouse_released(int button) { (void)button; return false; }
int cb_be_char_typed(void) { return 0; }
Vector2 cb_be_mouse_pos(void) { return cb_v2(0, 0); }
Vector2 cb_be_mouse_delta(void) { return cb_v2(0, 0); }
double cb_be_mouse_wheel(void) { return 0; }
void cb_be_cursor(int mode) { (void)mode; }
bool cb_be_cursor_hidden(void) { return false; }

void cb_be_clear(cb_rgba c) { (void)c; }
void cb_be_rect(cb_rect r, Vector2 origin, double rotation, cb_rgba c) { (void)r; (void)origin; (void)rotation; (void)c; }
void cb_be_rect_lines(cb_rect r, double thick, cb_rgba c) { (void)r; (void)thick; (void)c; }
void cb_be_circle(Vector2 at, double radius, cb_rgba c) { (void)at; (void)radius; (void)c; }
void cb_be_line(Vector2 a, Vector2 b, cb_rgba c) { (void)a; (void)b; (void)c; }
void cb_be_text(const char *text, Vector2 at, Vector2 origin, double rotation, double size, cb_rgba c) {
    (void)origin; (void)rotation; (void)size; (void)c;
    printf("text: %s at %d,%d\n", text, (int)at.x, (int)at.y);
}
Vector2 cb_be_text_size(const char *text, double size) { return cb_v2((double)strlen(text) * size * 0.5, size); }
