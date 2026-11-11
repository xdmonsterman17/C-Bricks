/* ---- C-Bricks graphics backend: MS-DOS (DJGPP), 2D and UI ----
   The cb_be_* functions (declared in cbricks.h) for a DOS program: a 256-colour screen (VGA
   mode 13h, 320 x 200, or a VESA mode: 640 x 480, 800 x 600), drawn by software into a back
   buffer and copied to the screen each frame; the keyboard through its own interrupt handler,
   the mouse through INT 33h, the clock through uclock(), PNG textures through stb_image.
   Text is the video card's own 8 x 16 font (read from the BIOS). Sound is a Sound Blaster (software mixer, WAV files) and FM (OPL); 3D is a software
   triangle renderer (depth buffer, Gouraud lighting, fog, dithering: see "3D" below).
   Strict C99 apart from DJGPP's own headers. */
/* DJGPP's headers show their DOS parts (go32, dpmi, uclock...) only when not in strict ISO mode
   (-std=c99 defines __STRICT_ANSI__): lifted for these includes, put back after. */
#ifdef __STRICT_ANSI__
#undef __STRICT_ANSI__
#define CB_DOS_STRICT 1
#endif
#include <time.h>
#include <signal.h>
#include <go32.h>
#include <dpmi.h>
#include <pc.h>
#include <sys/nearptr.h>
#include <sys/movedata.h>
#ifdef CB_DOS_STRICT
#define __STRICT_ANSI__ 1
#endif
#include "cbricks.h"
#include "cbricks_audio.h"   /* the project's audio files and what they were converted to */

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wsign-compare"
#pragma GCC diagnostic ignored "-Wimplicit-fallthrough"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#pragma GCC diagnostic ignored "-Wpedantic"
#define STBI_ONLY_PNG
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_NO_SIMD
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STBI_WRITE_NO_STDIO_DUMMY
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#pragma GCC diagnostic pop

#ifndef CB_DOS_SCREEN
#define CB_DOS_SCREEN 0  /* 0: the smallest mode the window's size fits; else the width: 320, 640, 800 */
#endif

/* ---------------------------------------------------------------- state */
static bool cb_dos_open = false;
static bool cb_dos_closing = false;
static bool cb_dos_esc = true;
static int cb_dos_w = 0, cb_dos_h = 0, cb_dos_fps = 60;
static unsigned char *cb_dos_back = NULL;   /* what's drawn: w x h palette indexes */
static unsigned char *cb_dos_vram = NULL;   /* the screen (through the near-pointer trick) */
static uclock_t cb_dos_t0 = 0, cb_dos_frame_start = 0;
static double cb_dos_dt = 1.0 / 60.0;
static long cb_dos_frames = 0;
static uclock_t cb_dos_tlast = 0;   /* when the last frame ended */
static uclock_t cb_dos_t10 = 0;   /* when frame 10 ended (the stats' steady part: loading is over) */
static int cb_dos_cursor = 0;               /* 0 visible, 1 hidden, 2 captured */
static unsigned char cb_dos_font[256 * 16];
static void cb_dos_audio_start(void);
static void cb_dos_audio_stop(void);
static void cb_dos_opl_start(void);
static void cb_dos_fm_close(void);
static void cb_dos_fm_update(void);

/* ---------------------------------------------------------------- colours: 6x6x6 cube + 40 greys */
static unsigned char cb_dos_pal[256][3];

static void cb_dos_make_palette(void) {
    int i, r, g, b;
    for (r = 0; r < 6; r++)
        for (g = 0; g < 6; g++)
            for (b = 0; b < 6; b++) {
                i = r * 36 + g * 6 + b;
                cb_dos_pal[i][0] = (unsigned char)(r * 51);
                cb_dos_pal[i][1] = (unsigned char)(g * 51);
                cb_dos_pal[i][2] = (unsigned char)(b * 51);
            }
    for (i = 0; i < 40; i++) {
        unsigned char v = (unsigned char)((i * 255 + 19) / 39);
        cb_dos_pal[216 + i][0] = v;
        cb_dos_pal[216 + i][1] = v;
        cb_dos_pal[216 + i][2] = v;
    }
}

static unsigned char cb_dos_quant(int r, int g, int b) {
    int mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    int mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    if (mx - mn < 14)
        return (unsigned char)(216 + (((r + g + b) / 3) * 39 + 127) / 255);
    return (unsigned char)(((r * 5 + 127) / 255) * 36 + ((g * 5 + 127) / 255) * 6 + (b * 5 + 127) / 255);
}

static void cb_dos_set_dac(void) {
    int i;
    outportb(0x3C8, 0);
    for (i = 0; i < 256; i++) {
        outportb(0x3C9, (unsigned char)(cb_dos_pal[i][0] >> 2));
        outportb(0x3C9, (unsigned char)(cb_dos_pal[i][1] >> 2));
        outportb(0x3C9, (unsigned char)(cb_dos_pal[i][2] >> 2));
    }
}

/* a colour over the pixel there (alpha 255 and 0 are the quick cases) */
static void cb_dos_plot(int x, int y, cb_rgba c) {
    unsigned char *p;
    if (c.a == 0 || x < 0 || y < 0 || x >= cb_dos_w || y >= cb_dos_h)
        return;
    p = cb_dos_back + (size_t)y * (size_t)cb_dos_w + (size_t)x;
    if (c.a == 255) {
        *p = cb_dos_quant(c.r, c.g, c.b);
    } else {
        const unsigned char *o = cb_dos_pal[*p];
        int a = c.a;
        *p = cb_dos_quant((c.r * a + o[0] * (255 - a)) / 255, (c.g * a + o[1] * (255 - a)) / 255, (c.b * a + o[2] * (255 - a)) / 255);
    }
}

/* ---------------------------------------------------------------- 2D transform: the camera and each shape's own */
typedef struct { double a, b, c, d, tx, ty; } cb_aff;   /* x' = a x + c y + tx, y' = b x + d y + ty */
static cb_aff cb_dos_cam = {1, 0, 0, 1, 0, 0};

static cb_aff cb_aff_mul(cb_aff p, cb_aff q) {   /* p after q */
    cb_aff m;
    m.a = p.a * q.a + p.c * q.b;
    m.b = p.b * q.a + p.d * q.b;
    m.c = p.a * q.c + p.c * q.d;
    m.d = p.b * q.c + p.d * q.d;
    m.tx = p.a * q.tx + p.c * q.ty + p.tx;
    m.ty = p.b * q.tx + p.d * q.ty + p.ty;
    return m;
}

static cb_aff cb_aff_inv(cb_aff m) {
    cb_aff r;
    double det = m.a * m.d - m.b * m.c;
    if (det == 0) det = 1e-12;
    r.a = m.d / det; r.b = -m.b / det; r.c = -m.c / det; r.d = m.a / det;
    r.tx = -(r.a * m.tx + r.c * m.ty);
    r.ty = -(r.b * m.tx + r.d * m.ty);
    return r;
}

/* local (0..w, 0..h) -> the screen: put `origin` of the shape at `at`, turned by rot degrees, under the camera */
static cb_aff cb_dos_local(Vector2 at, Vector2 origin, double rot) {
    double a = rot * 3.14159265358979323846 / 180.0, co = cos(a), si = sin(a);
    cb_aff m;
    m.a = co; m.b = si; m.c = -si; m.d = co;
    m.tx = at.x - (co * origin.x - si * origin.y);
    m.ty = at.y - (si * origin.x + co * origin.y);
    return cb_aff_mul(cb_dos_cam, m);
}

/* the pixels a transformed w x h box covers, each asked for its colour: fn(u, v) in local coordinates */
typedef bool (*cb_dos_sampler)(const void *ud, double u, double v, cb_rgba *out);

static void cb_dos_raster(cb_aff m, double w, double h, cb_dos_sampler fn, const void *ud) {
    double xs[4], ys[4], minx, maxx, miny, maxy;
    int x0, x1, y0, y1, x, y, i;
    cb_aff inv;
    xs[0] = m.tx; ys[0] = m.ty;
    xs[1] = m.a * w + m.tx; ys[1] = m.b * w + m.ty;
    xs[2] = m.c * h + m.tx; ys[2] = m.d * h + m.ty;
    xs[3] = m.a * w + m.c * h + m.tx; ys[3] = m.b * w + m.d * h + m.ty;
    minx = maxx = xs[0]; miny = maxy = ys[0];
    for (i = 1; i < 4; i++) {
        if (xs[i] < minx) minx = xs[i];
        if (xs[i] > maxx) maxx = xs[i];
        if (ys[i] < miny) miny = ys[i];
        if (ys[i] > maxy) maxy = ys[i];
    }
    x0 = (int)floor(minx); x1 = (int)ceil(maxx); y0 = (int)floor(miny); y1 = (int)ceil(maxy);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > cb_dos_w) x1 = cb_dos_w;
    if (y1 > cb_dos_h) y1 = cb_dos_h;
    inv = cb_aff_inv(m);
    for (y = y0; y < y1; y++)
        for (x = x0; x < x1; x++) {
            double px = x + 0.5, py = y + 0.5;
            double u = inv.a * px + inv.c * py + inv.tx, v = inv.b * px + inv.d * py + inv.ty;
            cb_rgba c;
            if (u < 0 || v < 0 || u >= w || v >= h)
                continue;
            if (fn(ud, u, v, &c))
                cb_dos_plot(x, y, c);
        }
}

/* a solid, unturned rectangle: spans (the common case: panels, bars, buttons) */
static void cb_dos_fill_box(double x0, double y0, double x1, double y1, cb_rgba c) {
    int ix0 = (int)ceil(x0 - 0.5), ix1 = (int)ceil(x1 - 0.5), iy0 = (int)ceil(y0 - 0.5), iy1 = (int)ceil(y1 - 0.5), x, y;
    if (c.a == 0)
        return;
    if (ix0 < 0) ix0 = 0;
    if (iy0 < 0) iy0 = 0;
    if (ix1 > cb_dos_w) ix1 = cb_dos_w;
    if (iy1 > cb_dos_h) iy1 = cb_dos_h;
    if (ix1 <= ix0)
        return;
    if (c.a == 255) {
        unsigned char q = cb_dos_quant(c.r, c.g, c.b);
        for (y = iy0; y < iy1; y++)
            memset(cb_dos_back + (size_t)y * (size_t)cb_dos_w + (size_t)ix0, q, (size_t)(ix1 - ix0));
    } else {
        for (y = iy0; y < iy1; y++)
            for (x = ix0; x < ix1; x++)
                cb_dos_plot(x, y, c);
    }
}

/* ---------------------------------------------------------------- shapes */
typedef struct { cb_rgba c; double w, h, radius, thick; } cb_dos_shape;

/* inside a w x h box with round corners (radius r) at (u, v)? */
static bool cb_dos_in_round(double u, double v, double w, double h, double r) {
    double cx, cy, dx, dy;
    if (u < 0 || v < 0 || u >= w || v >= h)
        return false;
    if (r <= 0)
        return true;
    cx = u < r ? r : (u > w - r ? w - r : u);
    cy = v < r ? r : (v > h - r ? h - r : v);
    dx = u - cx; dy = v - cy;
    return dx * dx + dy * dy <= r * r;
}

static bool cb_dos_s_fill(const void *ud, double u, double v, cb_rgba *out) {
    const cb_dos_shape *s = (const cb_dos_shape *)ud;
    *out = s->c;
    return cb_dos_in_round(u, v, s->w, s->h, s->radius);
}

static bool cb_dos_s_ring(const void *ud, double u, double v, cb_rgba *out) {
    const cb_dos_shape *s = (const cb_dos_shape *)ud;
    double t = s->thick, ri = s->radius - t;
    *out = s->c;
    if (!cb_dos_in_round(u, v, s->w, s->h, s->radius))
        return false;
    return !cb_dos_in_round(u - t, v - t, s->w - 2 * t, s->h - 2 * t, ri > 0 ? ri : 0);
}

static bool cb_dos_unturned(cb_aff m) {
    return fabs(m.b) < 1e-9 && fabs(m.c) < 1e-9 && m.a > 0 && m.d > 0;
}

void cb_be_rect(cb_rect r, Vector2 origin, double rotation, cb_rgba c) {
    cb_aff m = cb_dos_local(cb_v2(r.x, r.y), origin, rotation);
    cb_dos_shape s;
    if (cb_dos_unturned(m)) {
        cb_dos_fill_box(m.tx, m.ty, m.tx + m.a * r.width, m.ty + m.d * r.height, c);
        return;
    }
    s.c = c; s.w = r.width; s.h = r.height; s.radius = 0; s.thick = 0;
    cb_dos_raster(m, r.width, r.height, cb_dos_s_fill, &s);
}

void cb_be_rect_lines(cb_rect r, double thick, cb_rgba c) {
    cb_aff m = cb_dos_local(cb_v2(r.x, r.y), cb_v2(0, 0), 0);
    cb_dos_shape s;
    if (thick < 1) thick = 1;
    if (cb_dos_unturned(m)) {   /* four strips */
        double x0 = m.tx, y0 = m.ty, x1 = m.tx + m.a * r.width, y1 = m.ty + m.d * r.height, tx = thick * m.a, ty = thick * m.d;
        cb_dos_fill_box(x0, y0, x1, y0 + ty, c);
        cb_dos_fill_box(x0, y1 - ty, x1, y1, c);
        cb_dos_fill_box(x0, y0 + ty, x0 + tx, y1 - ty, c);
        cb_dos_fill_box(x1 - tx, y0 + ty, x1, y1 - ty, c);
        return;
    }
    s.c = c; s.w = r.width; s.h = r.height; s.radius = 0; s.thick = thick;
    cb_dos_raster(m, r.width, r.height, cb_dos_s_ring, &s);
}

static double cb_dos_radius(cb_rect r, double roundness) {
    double m = r.width < r.height ? r.width : r.height;
    return roundness <= 0 ? 0 : (roundness > 1 ? 1 : roundness) * m / 2;
}

void cb_be_rect_rounded(cb_rect r, double roundness, cb_rgba c) {
    cb_dos_shape s;
    s.c = c; s.w = r.width; s.h = r.height; s.radius = cb_dos_radius(r, roundness); s.thick = 0;
    cb_dos_raster(cb_dos_local(cb_v2(r.x, r.y), cb_v2(0, 0), 0), r.width, r.height, cb_dos_s_fill, &s);
}

void cb_be_rect_rounded_lines(cb_rect r, double roundness, double thick, cb_rgba c) {
    cb_dos_shape s;
    s.c = c; s.w = r.width; s.h = r.height; s.radius = cb_dos_radius(r, roundness); s.thick = thick < 1 ? 1 : thick;
    cb_dos_raster(cb_dos_local(cb_v2(r.x, r.y), cb_v2(0, 0), 0), r.width, r.height, cb_dos_s_ring, &s);
}

void cb_be_circle(Vector2 at, double radius, cb_rgba c) {
    double sc = sqrt(fabs(cb_dos_cam.a * cb_dos_cam.d - cb_dos_cam.b * cb_dos_cam.c));
    double cx = cb_dos_cam.a * at.x + cb_dos_cam.c * at.y + cb_dos_cam.tx, cy = cb_dos_cam.b * at.x + cb_dos_cam.d * at.y + cb_dos_cam.ty;
    double r = radius * sc;
    int x, y, x0 = (int)floor(cx - r), x1 = (int)ceil(cx + r), y0 = (int)floor(cy - r), y1 = (int)ceil(cy + r);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > cb_dos_w) x1 = cb_dos_w;
    if (y1 > cb_dos_h) y1 = cb_dos_h;
    for (y = y0; y < y1; y++)
        for (x = x0; x < x1; x++) {
            double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
            if (dx * dx + dy * dy <= r * r)
                cb_dos_plot(x, y, c);
        }
}

void cb_be_line(Vector2 a, Vector2 b, cb_rgba c) {
    double x0 = cb_dos_cam.a * a.x + cb_dos_cam.c * a.y + cb_dos_cam.tx, y0 = cb_dos_cam.b * a.x + cb_dos_cam.d * a.y + cb_dos_cam.ty;
    double x1 = cb_dos_cam.a * b.x + cb_dos_cam.c * b.y + cb_dos_cam.tx, y1 = cb_dos_cam.b * b.x + cb_dos_cam.d * b.y + cb_dos_cam.ty;
    int ix0 = (int)floor(x0), iy0 = (int)floor(y0), ix1 = (int)floor(x1), iy1 = (int)floor(y1);
    int dx = abs(ix1 - ix0), dy = -abs(iy1 - iy0), sx = ix0 < ix1 ? 1 : -1, sy = iy0 < iy1 ? 1 : -1, err = dx + dy, guard = 0;
    for (;;) {
        int e2;
        cb_dos_plot(ix0, iy0, c);
        if ((ix0 == ix1 && iy0 == iy1) || ++guard > 4000)
            break;
        e2 = 2 * err;
        if (e2 >= dy) { err += dy; ix0 += sx; }
        if (e2 <= dx) { err += dx; iy0 += sy; }
    }
}

static unsigned char cb_dither(int x, int y, float r, float g, float b);

/* a vertical gradient, dithered (a smooth sky in 256 colours: banding would show) */
void cb_be_gradient_v(cb_rect r, cb_rgba top, cb_rgba bottom) {
    int y, y0 = (int)floor(r.y), y1 = (int)ceil(r.y + r.height);
    if (top.a == 255 && bottom.a == 255 && (top.r != bottom.r || top.g != bottom.g || top.b != bottom.b)) {
        int x0 = (int)ceil(r.x - 0.5), x1 = (int)ceil(r.x + r.width - 0.5), x;
        if (x0 < 0) x0 = 0;
        if (x1 > cb_dos_w) x1 = cb_dos_w;
        for (y = y0 < 0 ? 0 : y0; y < y1 && y < cb_dos_h; y++) {
            double k = r.height > 0 ? (y + 0.5 - r.y) / r.height : 0;
            float fr, fg, fb;
            if (k < 0) k = 0;
            if (k > 1) k = 1;
            fr = (float)((top.r + (bottom.r - top.r) * k) / 255.0); fg = (float)((top.g + (bottom.g - top.g) * k) / 255.0); fb = (float)((top.b + (bottom.b - top.b) * k) / 255.0);
            for (x = x0; x < x1; x++)
                cb_dos_back[(size_t)y * (size_t)cb_dos_w + (size_t)x] = cb_dither(x, y, fr, fg, fb);
        }
        return;
    }
    for (y = y0; y < y1; y++) {
        double k = r.height > 0 ? (y + 0.5 - r.y) / r.height : 0;
        cb_rgba c;
        if (k < 0) k = 0;
        if (k > 1) k = 1;
        c.r = (unsigned char)(top.r + (bottom.r - top.r) * k);
        c.g = (unsigned char)(top.g + (bottom.g - top.g) * k);
        c.b = (unsigned char)(top.b + (bottom.b - top.b) * k);
        c.a = (unsigned char)(top.a + (bottom.a - top.a) * k);
        cb_dos_fill_box(r.x, (double)y, r.x + r.width, (double)y + 1, c);
    }
}

static bool cb_rt_transparent;   /* (the render target was cleared clear: its pictureless pixels stay see-through) */
void cb_be_clear(cb_rgba c) {
    if (c.a == 0) cb_rt_transparent = true;
    memset(cb_dos_back, cb_dos_quant(c.r, c.g, c.b), (size_t)cb_dos_w * (size_t)cb_dos_h);
}

/* ---------------------------------------------------------------- text: the video card's 8 x 16 font */
typedef struct { const char *text; double scale; cb_rgba c; int len; } cb_dos_text_ud;

static bool cb_dos_s_text(const void *ud, double u, double v, cb_rgba *out) {
    const cb_dos_text_ud *t = (const cb_dos_text_ud *)ud;
    int col = (int)(u / (8 * t->scale)), row = (int)(v / t->scale), px, py;
    unsigned char ch;
    if (col < 0 || col >= t->len || row < 0 || row >= 16)
        return false;
    ch = (unsigned char)t->text[col];
    if (ch >= 0x80) ch = '?';   /* (UTF-8 and the like: one glyph per byte would be wrong) */
    px = (int)(fmod(u, 8 * t->scale) / t->scale);
    py = row;
    if (px < 0 || px > 7 || !(cb_dos_font[ch * 16 + (unsigned)py] & (0x80 >> px)))
        return false;
    *out = t->c;
    return true;
}

Vector2 cb_be_text_size(const char *text, double size) {
    double s = size / 16.0;
    return cb_v2((double)strlen(text) * 8 * s, 16 * s);
}

/* unturned text: which glyph and which column of it each screen column shows is worked out once for the line (the
   general path asks a division and an fmod per pixel) */
static void cb_dos_text_flat(cb_aff m, double w, double h, const cb_dos_text_ud *t) {
    int x0 = (int)floor(m.tx), x1 = (int)ceil(m.a * w + m.tx), y0 = (int)floor(m.ty), y1 = (int)ceil(m.d * h + m.ty), x, y;
    short gcol[1024];
    signed char gpx[1024];
    double gw = 8 * t->scale, ia = 1.0 / m.a, id = 1.0 / m.d;
    unsigned char q = cb_dos_quant(t->c.r, t->c.g, t->c.b);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > cb_dos_w) x1 = cb_dos_w;
    if (y1 > cb_dos_h) y1 = cb_dos_h;
    if (x1 - x0 > 1024) x1 = x0 + 1024;
    for (x = x0; x < x1; x++) {
        double u = (x + 0.5 - m.tx) * ia;
        int col;
        if (u < 0 || u >= w) { gcol[x - x0] = -1; continue; }
        col = (int)(u / gw);
        gcol[x - x0] = (short)col;
        gpx[x - x0] = (signed char)(int)((u - col * gw) / t->scale);
    }
    for (y = y0; y < y1; y++) {
        double v = (y + 0.5 - m.ty) * id;
        int row;
        if (v < 0 || v >= h) continue;
        row = (int)(v / t->scale);
        if (row < 0 || row >= 16) continue;
        for (x = x0; x < x1; x++) {
            int col = gcol[x - x0], px;
            unsigned char ch;
            if (col < 0 || col >= t->len) continue;
            ch = (unsigned char)t->text[col];
            if (ch >= 0x80) ch = '?';
            px = gpx[x - x0];
            if (px < 0 || px > 7 || !(cb_dos_font[ch * 16 + (unsigned)row] & (0x80 >> px))) continue;
            if (t->c.a == 255) cb_dos_back[(size_t)y * (size_t)cb_dos_w + (size_t)x] = q;
            else cb_dos_plot(x, y, t->c);
        }
    }
}

void cb_be_text(const char *text, Vector2 at, Vector2 origin, double rotation, double size, cb_rgba c) {
    cb_dos_text_ud t;
    Vector2 m = cb_be_text_size(text, size);
    cb_aff la;
    t.text = text; t.scale = size / 16.0; t.c = c; t.len = (int)strlen(text);
    if (t.len == 0 || size <= 0)
        return;
    la = cb_dos_local(at, origin, rotation);
    if (la.b == 0 && la.c == 0 && la.a > 0 && la.d > 0) { cb_dos_text_flat(la, m.x, m.y, &t); return; }
    cb_dos_raster(la, m.x, m.y, cb_dos_s_text, &t);
}

static void cb_dos_load_font(void) {
    __dpmi_regs r;
    memset(&r, 0, sizeof r);
    r.x.ax = 0x1130;   /* get font pointer: 8 x 16 */
    r.h.bh = 6;
    __dpmi_int(0x10, &r);
    memset(cb_dos_font, 0, sizeof cb_dos_font);
    if (r.x.es != 0 || r.x.bp != 0)
        dosmemget((unsigned long)r.x.es * 16UL + r.x.bp, sizeof cb_dos_font, cb_dos_font);
}

/* ---------------------------------------------------------------- textures (PNG, kept as RGBA) */
typedef struct { int w, h; unsigned char *rgba; } cb_dos_tex;
static cb_dos_tex *cb_dos_texs = NULL;
static int cb_dos_tex_n = 0;

cb_texture cb_be_texture_load(const char *path) {
    cb_texture t = {0, 0, 0};
    int w, h, n;
    unsigned char *px = stbi_load(path, &w, &h, &n, 4);
    cb_dos_tex *grown;
    if (!px)
        return t;
    grown = (cb_dos_tex *)realloc((void *)cb_dos_texs, sizeof(cb_dos_tex) * (size_t)(cb_dos_tex_n + 1));
    if (!grown) { stbi_image_free(px); return t; }
    cb_dos_texs = grown;
    cb_dos_texs[cb_dos_tex_n].w = w;
    cb_dos_texs[cb_dos_tex_n].h = h;
    cb_dos_texs[cb_dos_tex_n].rgba = px;
    cb_dos_tex_n++;
    t.id = cb_dos_tex_n; t.width = w; t.height = h;
    return t;
}

typedef struct { const cb_dos_tex *tex; cb_rect src; double dw, dh; cb_rgba tint; } cb_dos_tex_ud;

static bool cb_dos_s_tex(const void *ud, double u, double v, cb_rgba *out) {
    const cb_dos_tex_ud *t = (const cb_dos_tex_ud *)ud;
    int sx = (int)(t->src.x + u / t->dw * t->src.width), sy = (int)(t->src.y + v / t->dh * t->src.height);
    const unsigned char *p;
    if (sx < 0 || sy < 0 || sx >= t->tex->w || sy >= t->tex->h)
        return false;
    p = t->tex->rgba + ((size_t)sy * (size_t)t->tex->w + (size_t)sx) * 4;
    if (p[3] == 0)
        return false;
    out->r = (unsigned char)(p[0] * t->tint.r / 255);
    out->g = (unsigned char)(p[1] * t->tint.g / 255);
    out->b = (unsigned char)(p[2] * t->tint.b / 255);
    out->a = (unsigned char)(p[3] * t->tint.a / 255);
    return true;
}

void cb_be_texture(cb_texture t, cb_rect src, cb_rect dst, Vector2 origin, double rotation, cb_rgba tint) {
    cb_dos_tex_ud u;
    if (t.id < 1 || t.id > cb_dos_tex_n || dst.width <= 0 || dst.height <= 0)
        return;
    u.tex = &cb_dos_texs[t.id - 1]; u.src = src; u.dw = dst.width; u.dh = dst.height; u.tint = tint;
    cb_dos_raster(cb_dos_local(cb_v2(dst.x, dst.y), origin, rotation), dst.width, dst.height, cb_dos_s_tex, &u);
}

/* ---------------------------------------------------------------- the 2D camera (Draw 2D view) */
void cb_be_begin_2d(Vector2 center, double zoom, double rotation) {
    double a = rotation * 3.14159265358979323846 / 180.0, co = cos(a) * zoom, si = sin(a) * zoom;
    if (zoom <= 0) { co = cos(a); si = sin(a); }
    cb_dos_cam.a = co; cb_dos_cam.b = si; cb_dos_cam.c = -si; cb_dos_cam.d = co;
    cb_dos_cam.tx = cb_dos_w / 2.0 - (co * center.x - si * center.y);
    cb_dos_cam.ty = cb_dos_h / 2.0 - (si * center.x + co * center.y);
}

void cb_be_end_2d(void) {
    cb_dos_cam.a = 1; cb_dos_cam.b = 0; cb_dos_cam.c = 0; cb_dos_cam.d = 1; cb_dos_cam.tx = 0; cb_dos_cam.ty = 0;
}

/* ---------------------------------------------------------------- keyboard: our own interrupt 9 handler */
static volatile unsigned char cb_dos_kdown[128], cb_dos_kpress[128], cb_dos_krel[128];
static unsigned char cb_dos_kpressed[128], cb_dos_kreleased[128];   /* this frame's */
static _go32_dpmi_seginfo cb_dos_old_kb, cb_dos_new_kb;
static bool cb_dos_kb_on = false;

static void cb_dos_kb_isr(void) {
    unsigned char sc = inportb(0x60);
    if (sc != 0xE0 && sc != 0xE1) {   /* (arrows come as E0 + the number pad's codes: the same keys here) */
        int k = sc & 0x7F;
        if (sc & 0x80) { cb_dos_kdown[k] = 0; cb_dos_krel[k] = 1; }
        else { if (!cb_dos_kdown[k]) cb_dos_kpress[k] = 1; cb_dos_kdown[k] = 1; }
    }
}
static void cb_dos_kb_isr_end(void) { }

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"  /* (the handler's address: DJGPP wants it as a pointer) */
static void cb_dos_kb_start(void) {
    if (cb_dos_kb_on)
        return;
    _go32_dpmi_lock_code((void *)cb_dos_kb_isr, (unsigned long)cb_dos_kb_isr_end - (unsigned long)cb_dos_kb_isr);
    _go32_dpmi_lock_data((void *)cb_dos_kdown, sizeof cb_dos_kdown);
    _go32_dpmi_lock_data((void *)cb_dos_kpress, sizeof cb_dos_kpress);
    _go32_dpmi_lock_data((void *)cb_dos_krel, sizeof cb_dos_krel);
    _go32_dpmi_get_protected_mode_interrupt_vector(9, &cb_dos_old_kb);
    cb_dos_new_kb.pm_offset = (unsigned long)cb_dos_kb_isr;
    cb_dos_new_kb.pm_selector = (unsigned short)_my_cs();
    _go32_dpmi_chain_protected_mode_interrupt_vector(9, &cb_dos_new_kb);
    cb_dos_kb_on = true;
}

#pragma GCC diagnostic pop

static void cb_dos_kb_stop(void) {
    if (!cb_dos_kb_on)
        return;
    _go32_dpmi_set_protected_mode_interrupt_vector(9, &cb_dos_old_kb);
    cb_dos_kb_on = false;
}

/* raylib's key numbers (CB_KEY_*) -> set 1 scan codes */
static int cb_dos_scan(int key) {
    static const unsigned char letters[26] = {0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C};
    if (key >= 'A' && key <= 'Z') return letters[key - 'A'];
    if (key >= '1' && key <= '9') return 0x02 + (key - '1');
    if (key == '0') return 0x0B;
    if (key >= 290 && key <= 294) return 0x3B + (key - 290);   /* F1 - F5 */
    switch (key) {
        case 32: return 0x39;    /* space */
        case 256: return 0x01;   /* escape */
        case 257: return 0x1C;   /* enter */
        case 258: return 0x0F;   /* tab */
        case 259: return 0x0E;   /* backspace */
        case 262: return 0x4D;   /* right */
        case 263: return 0x4B;   /* left */
        case 264: return 0x50;   /* down */
        case 265: return 0x48;   /* up */
        case 340: return 0x2A;   /* left shift */
        case 341: return 0x1D;   /* left control */
    }
    return -1;
}

bool cb_be_key_down(int key) { int s = cb_dos_scan(key); return s >= 0 && (cb_dos_kdown[s] || cb_dos_kpressed[s]); }
bool cb_be_key_pressed(int key) { int s = cb_dos_scan(key); return s >= 0 && cb_dos_kpressed[s]; }
bool cb_be_key_released(int key) { int s = cb_dos_scan(key); return s >= 0 && cb_dos_kreleased[s]; }

/* ---------------------------------------------------------------- the mouse (INT 33h) */
static bool cb_dos_mouse_ok = false;
static int cb_dos_mx = 0, cb_dos_my = 0, cb_dos_mdx = 0, cb_dos_mdy = 0, cb_dos_mb = 0, cb_dos_mb_prev = 0, cb_dos_wheel = 0;
static bool cb_dos_wheel_ok = false;

static void cb_dos_mouse_start(void) {
    __dpmi_regs r;
    memset(&r, 0, sizeof r);
    r.x.ax = 0;
    __dpmi_int(0x33, &r);
    cb_dos_mouse_ok = r.x.ax == 0xFFFF;
    if (!cb_dos_mouse_ok)
        return;
    /* the wheel (CuteMouse's API, which DOSBox-X and the usual drivers share): AX=11h answers 574Dh ("WM") when
       there is one, and from then on AX=3's BH is how far it turned since the last call */
    memset(&r, 0, sizeof r); r.x.ax = 0x11; __dpmi_int(0x33, &r);
    cb_dos_wheel_ok = r.x.ax == 0x574D && (r.x.cx & 1);
    memset(&r, 0, sizeof r); r.x.ax = 7; r.x.cx = 0; r.x.dx = (unsigned short)(cb_dos_w - 1); __dpmi_int(0x33, &r);
    memset(&r, 0, sizeof r); r.x.ax = 8; r.x.cx = 0; r.x.dx = (unsigned short)(cb_dos_h - 1); __dpmi_int(0x33, &r);
    memset(&r, 0, sizeof r); r.x.ax = 4; r.x.cx = (unsigned short)(cb_dos_w / 2); r.x.dx = (unsigned short)(cb_dos_h / 2); __dpmi_int(0x33, &r);
    cb_dos_mx = cb_dos_w / 2; cb_dos_my = cb_dos_h / 2;
}

static void cb_dos_mouse_poll(void) {
    __dpmi_regs r;
    if (!cb_dos_mouse_ok)
        return;
    memset(&r, 0, sizeof r); r.x.ax = 3; __dpmi_int(0x33, &r);
    cb_dos_mx = (short)r.x.cx; cb_dos_my = (short)r.x.dx;
    cb_dos_mb_prev = cb_dos_mb;
    cb_dos_mb = r.x.bx & 7;
    if (cb_dos_wheel_ok)
        cb_dos_wheel += (signed char)r.h.bh;
    memset(&r, 0, sizeof r); r.x.ax = 0x0B; __dpmi_int(0x33, &r);
    cb_dos_mdx = (short)r.x.cx; cb_dos_mdy = (short)r.x.dx;
}

bool cb_be_mouse_down(int b) { return b >= 0 && b < 3 && (cb_dos_mb & (1 << b)); }
bool cb_be_mouse_pressed(int b) { return b >= 0 && b < 3 && (cb_dos_mb & (1 << b)) && !(cb_dos_mb_prev & (1 << b)); }
bool cb_be_mouse_released(int b) { return b >= 0 && b < 3 && !(cb_dos_mb & (1 << b)) && (cb_dos_mb_prev & (1 << b)); }
Vector2 cb_be_mouse_pos(void) { return cb_v2(cb_dos_mx, cb_dos_my); }
Vector2 cb_be_mouse_delta(void) { return cb_v2(cb_dos_mdx, cb_dos_mdy); }
double cb_be_mouse_wheel(void) { double w = cb_dos_wheel; cb_dos_wheel = 0; return -w; }
void cb_be_cursor(int mode) { cb_dos_cursor = mode; }
bool cb_be_cursor_hidden(void) { return cb_dos_cursor != 0; }

/* our own pointer (the driver's isn't drawn in these modes): an arrow, over the picture as it's shown */
static const char *const cb_dos_arrow[] = {
    "X          ", "XX         ", "X.X        ", "X..X       ", "X...X      ", "X....X     ", "X.....X    ", "X......X   ",
    "X.......X  ", "X........X ", "X.....XXXXX", "X..X..X    ", "X.X X..X   ", "XX  X..X   ", "X    X..X  ", "     X..X  ", "      XX   "};
#define CB_DOS_ARROW_ROWS 17
static unsigned char cb_dos_under[CB_DOS_ARROW_ROWS][11];

static void cb_dos_cursor_draw(bool put) {
    int x, y;
    for (y = 0; y < CB_DOS_ARROW_ROWS; y++)
        for (x = 0; x < 11; x++) {
            int px = cb_dos_mx + x, py = cb_dos_my + y;
            char ch = cb_dos_arrow[y][x];
            unsigned char *p;
            if (px < 0 || py < 0 || px >= cb_dos_w || py >= cb_dos_h || ch == ' ')
                continue;
            p = cb_dos_back + (size_t)py * (size_t)cb_dos_w + (size_t)px;
            if (put) { cb_dos_under[y][x] = *p; *p = ch == 'X' ? 0 + 216 : 255 - 0; }
            else *p = cb_dos_under[y][x];
        }
}

/* ---------------------------------------------------------------- the screen */
static unsigned long cb_dos_lfb_addr = 0;

static void cb_dos_text_mode(void) {
    __dpmi_regs r;
    memset(&r, 0, sizeof r);
    r.x.ax = 0x0003;
    __dpmi_int(0x10, &r);
}

static bool cb_dos_vesa(int mode, int w, int h) {
    __dpmi_regs r;
    unsigned char info[256];
    unsigned attrs;
    unsigned long phys;
    __dpmi_meminfo mi;
    memset(&r, 0, sizeof r);
    r.x.ax = 0x4F01; r.x.cx = (unsigned short)mode; r.x.es = (unsigned short)(__tb >> 4); r.x.di = (unsigned short)(__tb & 15);
    __dpmi_int(0x10, &r);
    if (r.x.ax != 0x004F)
        return false;
    dosmemget(__tb, sizeof info, info);
    attrs = (unsigned)(info[0] | (info[1] << 8));
    phys = (unsigned long)info[0x28] | ((unsigned long)info[0x29] << 8) | ((unsigned long)info[0x2A] << 16) | ((unsigned long)info[0x2B] << 24);
    if (!(attrs & 1) || !(attrs & 0x80) || phys == 0)   /* supported, with a linear frame buffer */
        return false;
    mi.address = phys;
    mi.size = (unsigned long)w * (unsigned long)h;
    mi.size = (mi.size + 4095UL) & ~4095UL;
    if (__dpmi_physical_address_mapping(&mi) != 0)
        return false;
    memset(&r, 0, sizeof r);
    r.x.ax = 0x4F02; r.x.bx = (unsigned short)(mode | 0x4000);
    __dpmi_int(0x10, &r);
    if (r.x.ax != 0x004F)
        return false;
    cb_dos_lfb_addr = mi.address;
    return true;
}

static void cb_dos_close_all(void) {
    if (cb_dos_open) {
        cb_dos_fm_close();
        if (cb_verbose && cb_dos_frames > 0) {
            double secs = (double)(uclock() - cb_dos_t0) / UCLOCKS_PER_SEC;
            double steady = cb_dos_frames > 10 ? (double)(cb_dos_frames - 10) / ((double)(cb_dos_tlast - cb_dos_t10) / UCLOCKS_PER_SEC) : 0;
            printf("[video] %ld frames in %.1f s: %.1f fps after the first 10, at %d x %d\n", cb_dos_frames, secs, steady, cb_dos_w, cb_dos_h);
        }
        cb_dos_audio_stop();
        cb_dos_kb_stop();
        cb_dos_text_mode();
        __djgpp_nearptr_disable();
        cb_dos_open = false;
    }
}

static void cb_dos_on_break(int sig) { (void)sig; cb_dos_closing = true; }

bool cb_be_open(int width, int height, const char *title, int fps, bool esc_closes) {
    int want = CB_DOS_SCREEN;
    (void)title;
    if (cb_dos_open)
        return true;
    if (want == 0)
        want = (width <= 320 && height <= 200) ? 320 : (width <= 640 && height <= 480) ? 640 : 800;
    if (!__djgpp_nearptr_enable()) {
        fputs("MS-DOS graphics: the DPMI host doesn't allow direct memory access (near pointers)\n", stderr);
        return false;
    }
    cb_dos_make_palette();
    cb_dos_load_font();
    if (want == 320) {
        __dpmi_regs r;
        memset(&r, 0, sizeof r);
        r.x.ax = 0x0013;
        __dpmi_int(0x10, &r);
        cb_dos_w = 320; cb_dos_h = 200;
        cb_dos_vram = (unsigned char *)(0xA0000 + __djgpp_conventional_base);
    } else {
        int mode = want == 640 ? 0x101 : 0x103;
        cb_dos_w = want == 640 ? 640 : 800; cb_dos_h = want == 640 ? 480 : 600;
        if (!cb_dos_vesa(mode, cb_dos_w, cb_dos_h)) {
            fprintf(stderr, "MS-DOS graphics: this video card has no %d x %d VESA mode with a linear frame buffer (VBE 2.0); use the 320 x 200 screen\n", cb_dos_w, cb_dos_h);
            __djgpp_nearptr_disable();
            return false;
        }
        cb_dos_vram = (unsigned char *)(cb_dos_lfb_addr + (unsigned long)__djgpp_conventional_base);
    }
    cb_dos_back = (unsigned char *)calloc((size_t)cb_dos_w * (size_t)cb_dos_h, 1);
    if (!cb_dos_back) {
        cb_dos_text_mode();
        return false;
    }
    cb_dos_set_dac();
    cb_dos_kb_start();
    cb_dos_mouse_start();
    cb_dos_audio_start();
    cb_dos_opl_start();
    cb_dos_esc = esc_closes;
    cb_dos_fps = fps > 0 ? fps : 60;
    cb_dos_open = true;
    cb_dos_t0 = cb_dos_frame_start = uclock();
    signal(SIGINT, cb_dos_on_break);
    atexit(cb_dos_close_all);
    return true;
}

void cb_be_close(void) { cb_dos_close_all(); }
bool cb_be_should_close(void) { return cb_dos_closing || (cb_dos_esc && cb_dos_kdown[0x01]); }
bool cb_be_ready(void) { return cb_dos_open; }

void cb_be_begin_frame(void) {
    int k;
    for (k = 0; k < 128; k++) {
        cb_dos_kpressed[k] = cb_dos_kpress[k]; cb_dos_kpress[k] = 0;
        cb_dos_kreleased[k] = cb_dos_krel[k]; cb_dos_krel[k] = 0;
    }
    cb_dos_mouse_poll();
}

void cb_be_flush(void) { }
void cb_be_post(double vignette, double scanlines, double grain, double posterize, double bloom, double curve, double outline, double dither, double snap) { (void)vignette; (void)scanlines; (void)grain; (void)posterize; (void)bloom; (void)curve; (void)outline; (void)dither; (void)snap; }
void cb_be_set_look(int what, int value) { (void)what; (void)value; }
int cb_be_splat_mode(void) { return 0; }

void cb_be_end_frame(void) {
    uclock_t now;
    bool arrow = cb_dos_cursor == 0 && cb_dos_mouse_ok;
    if (arrow) cb_dos_cursor_draw(true);
    memcpy(cb_dos_vram, cb_dos_back, (size_t)cb_dos_w * (size_t)cb_dos_h);
    if (arrow) cb_dos_cursor_draw(false);
    do {   /* the frame rate: wait out the rest of the frame (keeping the sound card fed) */
        cb_be_music_update();
        now = uclock();
    } while ((double)(now - cb_dos_frame_start) / UCLOCKS_PER_SEC < 1.0 / cb_dos_fps);
    cb_dos_dt = (double)(now - cb_dos_frame_start) / UCLOCKS_PER_SEC;
    cb_dos_frame_start = now;
    cb_dos_tlast = now;
    if (++cb_dos_frames == 10) cb_dos_t10 = now;
}

int cb_be_width(void) { return cb_dos_w; }
int cb_be_height(void) { return cb_dos_h; }
int cb_be_fps(void) { return cb_dos_dt > 0 ? (int)(1.0 / cb_dos_dt + 0.5) : cb_dos_fps; }
double cb_be_frame_time(void) { return cb_dos_dt; }
double cb_be_time(void) { return (double)(uclock() - cb_dos_t0) / UCLOCKS_PER_SEC; }

void cb_be_screenshot(const char *path) {
    size_t n = (size_t)cb_dos_w * (size_t)cb_dos_h, i;
    unsigned char *rgb = (unsigned char *)malloc(n * 3);
    if (!rgb)
        return;
    for (i = 0; i < n; i++) {
        rgb[i * 3] = cb_dos_pal[cb_dos_back[i]][0];
        rgb[i * 3 + 1] = cb_dos_pal[cb_dos_back[i]][1];
        rgb[i * 3 + 2] = cb_dos_pal[cb_dos_back[i]][2];
    }
    stbi_write_png(path, cb_dos_w, cb_dos_h, 3, rgb, cb_dos_w * 3);
    free(rgb);
}

/* ---------------------------------------------------------------- sound and music: a Sound Blaster, mixed by software
   One 22222 Hz, 8-bit, mono DMA buffer played round and round (auto-init); the mixer fills what the
   card has played, from cb_be_music_update (each frame, Wait's frames, the frame-rate wait). WAV files
   are read whole and converted to that format. The interrupt isn't used: it's masked at the PIC, and
   the card's acknowledged by hand. Without a Sound Blaster (or a failed reset) everything still
   "plays" on the clock, silently, so Playing? and the like behave. */
#define CB_DOS_RATE 22222
#define CB_DOS_DMA 8192
#define CB_DOS_VOICES 16

typedef struct { signed char *s; int n; } cb_dos_pcm;
static cb_dos_pcm *cb_dos_pcms = NULL;
static int cb_dos_pcm_n = 0;
typedef struct { int pcm; double pos; double vol; bool loop; bool on; bool paused; int fm; } cb_dos_voice;   /* fm: 1 + the FM song (cb_dos_fms) this plays instead of pcm */
static cb_dos_voice cb_dos_voices[CB_DOS_VOICES];                 /* Sound plays */
static cb_dos_voice *cb_dos_songs = NULL;                          /* one per Music handle (id - 1 into cb_dos_pcms is its pcm) */
static int cb_dos_song_n = 0;

static int cb_dos_sb = 0;                    /* the card's base port (0: none) */
static int cb_dos_sb_irq = 0, cb_dos_sb_dma = 1;
static unsigned long cb_dos_dma_phys = 0;
static int cb_dos_dma_sel = 0, cb_dos_dma_seg = 0;
static unsigned long cb_dos_dma_off = 0;     /* the buffer's offset in conventional memory */
static int cb_dos_peak = 0;                  /* the loudest mixed sample (-v reports it) */
static long cb_dos_played = 0, cb_dos_written = 0;   /* in samples, since the start */
static int cb_dos_last_pos = 0;
static uclock_t cb_dos_audio_t = 0;
static unsigned char cb_dos_old_mask = 0;

static int cb_dos_sb_wait_write(void) { int i; for (i = 0; i < 100000; i++) if (!(inportb(cb_dos_sb + 0xC) & 0x80)) return 1; return 0; }
static void cb_dos_sb_write(unsigned char v) { if (cb_dos_sb_wait_write()) outportb(cb_dos_sb + 0xC, v); }

static bool cb_dos_sb_reset(int base) {
    int i, j;
    outportb(base + 6, 1);
    for (j = 0; j < 8; j++) (void)inportb(base + 6);   /* ~3 microseconds */
    outportb(base + 6, 0);
    for (i = 0; i < 20000; i++)
        if ((inportb(base + 0xE) & 0x80) && inportb(base + 0xA) == 0xAA)
            return true;
    return false;
}

/* the BLASTER variable ("A220 I7 D1 H5 T6"), else the usual ports */
static bool cb_dos_sb_find(void) {
    const char *b = getenv("BLASTER");
    int base = 0, irq = 0, dma = 1, k;
    if (b) {
        const char *q = b;
        for (; *q; q++) {
            if (*q == 'A' || *q == 'a') base = (int)strtol(q + 1, NULL, 16);
            else if (*q == 'I' || *q == 'i') irq = (int)strtol(q + 1, NULL, 10);
            else if (*q == 'D' || *q == 'd') dma = (int)strtol(q + 1, NULL, 10);
        }
    }
    if (base && cb_dos_sb_reset(base)) { cb_dos_sb = base; cb_dos_sb_irq = irq; cb_dos_sb_dma = dma; return true; }
    for (k = 0x220; k <= 0x280; k += 0x20)
        if (cb_dos_sb_reset(k)) { cb_dos_sb = k; cb_dos_sb_irq = irq; cb_dos_sb_dma = dma; return true; }
    return false;
}

static void cb_dos_audio_start(void) {
    static const unsigned char pages[4] = {0x87, 0x83, 0x81, 0x82};
    int dma, paras, seg, i;
    unsigned long phys;
    unsigned char fill[CB_DOS_DMA];
    cb_dos_audio_t = uclock();
    if (!cb_dos_sb_find() || cb_dos_sb_dma < 0 || cb_dos_sb_dma > 3) { cb_dos_sb = 0; return; }
    dma = cb_dos_sb_dma;
    paras = (CB_DOS_DMA * 2 + 15) / 16;   /* room to keep the buffer inside one 64 KB page */
    seg = __dpmi_allocate_dos_memory(paras, &cb_dos_dma_sel);
    if (seg == -1) { cb_dos_sb = 0; return; }
    cb_dos_dma_seg = seg;
    phys = (unsigned long)seg * 16UL;
    if ((phys & 0xFFFFUL) + CB_DOS_DMA > 0x10000UL)
        phys = (phys + 0xFFFFUL) & ~0xFFFFUL;
    cb_dos_dma_phys = phys;
    cb_dos_dma_off = phys;
    for (i = 0; i < CB_DOS_DMA; i++) fill[i] = 128;
    dosmemput(fill, CB_DOS_DMA, phys);
    if (cb_dos_sb_irq > 0 && cb_dos_sb_irq < 8) {   /* keep the card's interrupt off: nothing handles it */
        cb_dos_old_mask = inportb(0x21);
        outportb(0x21, (unsigned char)(cb_dos_old_mask | (1 << cb_dos_sb_irq)));
    }
    outportb(0x0A, (unsigned char)(4 | dma));                    /* mask the channel */
    outportb(0x0C, 0);                                           /* clear the flip-flop */
    outportb(0x0B, (unsigned char)(0x58 | dma));                 /* read from memory, auto-init */
    outportb((unsigned short)(dma * 2), (unsigned char)(phys & 0xFF));
    outportb((unsigned short)(dma * 2), (unsigned char)((phys >> 8) & 0xFF));
    outportb(pages[dma], (unsigned char)((phys >> 16) & 0xFF));
    outportb(0x0C, 0);
    outportb((unsigned short)(dma * 2 + 1), (unsigned char)((CB_DOS_DMA - 1) & 0xFF));
    outportb((unsigned short)(dma * 2 + 1), (unsigned char)(((CB_DOS_DMA - 1) >> 8) & 0xFF));
    outportb(0x0A, (unsigned char)dma);                          /* unmask */
    cb_dos_sb_write(0xD1);                                       /* speaker on */
    cb_dos_sb_write(0x40); cb_dos_sb_write((unsigned char)(256 - 1000000 / CB_DOS_RATE));   /* the rate */
    cb_dos_sb_write(0x48); cb_dos_sb_write((unsigned char)((CB_DOS_DMA / 2 - 1) & 0xFF)); cb_dos_sb_write((unsigned char)((CB_DOS_DMA / 2 - 1) >> 8));  /* the block */
    cb_dos_sb_write(0x1C);                                       /* 8-bit auto-init DMA */
    cb_dos_last_pos = 0;
    cb_dos_played = 0;
    cb_dos_written = CB_DOS_DMA / 2;
}

static void cb_dos_audio_stop(void) {
    if (!cb_dos_sb)
        return;
    cb_dos_sb_write(0xD0);   /* halt */
    cb_dos_sb_write(0xDA);   /* leave auto-init */
    cb_dos_sb_write(0xD3);   /* speaker off */
    outportb(0x0A, (unsigned char)(4 | cb_dos_sb_dma));
    if (cb_dos_sb_irq > 0 && cb_dos_sb_irq < 8)
        outportb(0x21, cb_dos_old_mask);
    cb_dos_sb_reset(cb_dos_sb);
    if (cb_verbose)
        printf("[audio] Sound Blaster at %Xh, DMA %d: %ld samples played, loudest mixed sample %d of 127\n", cb_dos_sb, cb_dos_sb_dma, cb_dos_played, cb_dos_peak);
    __dpmi_free_dos_memory(cb_dos_dma_sel);
    cb_dos_sb = 0;
}

/* the next n samples of every voice, added into the 8-bit unsigned mix */
static void cb_dos_mix(unsigned char *out, int n) {
    int i, v;
    for (i = 0; i < n; i++) {
        int acc = 0;
        for (v = 0; v < CB_DOS_VOICES + cb_dos_song_n; v++) {
            cb_dos_voice *c = v < CB_DOS_VOICES ? &cb_dos_voices[v] : &cb_dos_songs[v - CB_DOS_VOICES];
            const cb_dos_pcm *p;
            int at;
            if (!c->on || c->paused || c->fm)
                continue;
            p = &cb_dos_pcms[c->pcm];
            at = (int)c->pos;
            if (at >= p->n) {
                if (c->loop && p->n > 0) { c->pos = 0; at = 0; }
                else { c->on = false; continue; }
            }
            acc += (int)(p->s[at] * c->vol);
            c->pos += 1.0;
        }
        if (acc > 127) acc = 127;
        if (acc < -128) acc = -128;
        if ((acc < 0 ? -acc : acc) > cb_dos_peak) cb_dos_peak = acc < 0 ? -acc : acc;
        out[i] = (unsigned char)(acc + 128);
    }
}

void cb_be_music_update(void) {
    uclock_t now;
    unsigned char scratch[CB_DOS_DMA];
    if (!cb_dos_open)
        return;
    cb_dos_fm_update();
    now = uclock();
    if (!cb_dos_sb) {   /* no card: the voices advance on the clock, unheard */
        int n = (int)((double)(now - cb_dos_audio_t) / UCLOCKS_PER_SEC * CB_DOS_RATE);
        if (n > CB_DOS_DMA) n = CB_DOS_DMA;
        if (n > 0) { cb_dos_mix(scratch, n); cb_dos_audio_t = now; }
        return;
    }
    {
        int lo, hi, count, pos, delta, n, w;
        long ahead;
        (void)inportb(cb_dos_sb + 0xE);   /* acknowledge the card */
        outportb(0x0C, 0);
        lo = inportb((unsigned short)(cb_dos_sb_dma * 2 + 1));
        hi = inportb((unsigned short)(cb_dos_sb_dma * 2 + 1));
        count = lo | (hi << 8);
        pos = CB_DOS_DMA - 1 - count;
        if (pos < 0) pos = 0;
        if (pos >= CB_DOS_DMA) pos = CB_DOS_DMA - 1;
        delta = (pos - cb_dos_last_pos + CB_DOS_DMA) % CB_DOS_DMA;
        cb_dos_played += delta;
        cb_dos_last_pos = pos;
        ahead = cb_dos_written - cb_dos_played;
        if (ahead < 0) { cb_dos_written = cb_dos_played; ahead = 0; }   /* it ran dry: carry on from where it is */
        n = (CB_DOS_DMA * 3) / 4 - (int)ahead;
        if (n <= 0)
            return;
        w = (int)(cb_dos_written % CB_DOS_DMA);
        while (n > 0) {
            int chunk = CB_DOS_DMA - w < n ? CB_DOS_DMA - w : n;
            cb_dos_mix(scratch, chunk);
            dosmemput(scratch, (size_t)chunk, cb_dos_dma_off + (unsigned long)w);
            cb_dos_written += chunk;
            w = (w + chunk) % CB_DOS_DMA;
            n -= chunk;
        }
    }
}

/* the file a brick's path means: the editor converted every WAV / OGG / MP3 of the project to
   audio/<name> beside the program (8-bit, mono, 22 kHz; cbricks_audio.h says which is which). A
   path that isn't in the table is opened as it is (a WAV the project doesn't list, or one added later). */
extern char **__crt0_argv;

static int cb_dos_same_path(const char *a, const char *b) {
    for (;;) {
        char x = *a == '\\' ? '/' : *a, y = *b == '\\' ? '/' : *b;
        if (x >= 'A' && x <= 'Z') x = (char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = (char)(y + 32);
        if (x != y) return 0;
        if (!x) return 1;
        a++; b++;
    }
}

/* an entry of cbricks_audio.h: the project's file, its converted PCM (or 0), its FM version (or 0) */
static int cb_dos_audio_index(const char *path) {
    int i;
    while (path[0] == '.' && (path[1] == '/' || path[1] == '\\')) path += 2;
    for (i = 0; cb_dos_audio_from[i]; i++)
        if (cb_dos_same_path(path, cb_dos_audio_from[i]))
            return i;
    return -1;
}

/* audio/<name> beside the program, else in the folder it runs in */
static FILE *cb_dos_open_named(const char *name) {
    char full[260];
    const char *exe = __crt0_argv && __crt0_argv[0] ? __crt0_argv[0] : "";
    size_t dir = strlen(exe);
    FILE *f;
    while (dir > 0 && exe[dir - 1] != '\\' && exe[dir - 1] != '/') dir--;
    if (dir + 20 < sizeof full) {
        memcpy(full, exe, dir);
        strcpy(full + dir, "audio/");
        strcat(full, name);
        f = fopen(full, "rb");
        if (f) return f;
    }
    strcpy(full, "audio/");
    strcat(full, name);
    f = fopen(full, "rb");
    if (!f)
        fprintf(stderr, "[audio] audio/%s isn't beside the program (build it for MS-DOS in the editor)\n", name);
    return f;
}

/* the file a brick's PCM path means (the converted one), or the path itself when it isn't listed */
static FILE *cb_dos_open_audio(const char *path, bool *converted) {
    int i = cb_dos_audio_index(path);
    *converted = false;
    if (i >= 0) {
        if (!cb_dos_audio_pcm[i])
            return NULL;   /* an FM file (or one with nothing to play as sound) */
        *converted = true;
        return cb_dos_open_named(cb_dos_audio_pcm[i]);
    }
    return fopen(path, "rb");
}

/* a WAV (PCM, 8 or 16 bits, mono or stereo, any rate) as 22222 Hz mono; -1: not one we can read */
static int cb_dos_wav(const char *path) {
    bool converted;
    FILE *f = cb_dos_open_audio(path, &converted);
    unsigned char h[12];
    long size;
    unsigned char *buf;
    int ch = 0, bits = 0, rate = 0, fmt = 0, i, out_n;
    const unsigned char *data = NULL;
    long data_n = 0, at;
    signed char *out;
    cb_dos_pcm *grown;
    if (!f)
        return -1;
    fseek(f, 0, SEEK_END); size = ftell(f); fseek(f, 0, SEEK_SET);
    if (size < 44 || size > 64L * 1024 * 1024 || fread(h, 1, 12, f) != 12 || memcmp(h, "RIFF", 4) != 0 || memcmp(h + 8, "WAVE", 4) != 0) { fclose(f); return -1; }
    buf = (unsigned char *)malloc((size_t)size);
    if (!buf) { fclose(f); return -1; }
    fseek(f, 12, SEEK_SET);
    size = (long)fread(buf, 1, (size_t)(size - 12), f);
    fclose(f);
    for (at = 0; at + 8 <= size; ) {
        long len = (long)(buf[at + 4] | (buf[at + 5] << 8) | (buf[at + 6] << 16) | ((long)buf[at + 7] << 24));
        if (memcmp(buf + at, "fmt ", 4) == 0 && at + 8 + 16 <= size) {
            fmt = buf[at + 8] | (buf[at + 9] << 8); ch = buf[at + 10] | (buf[at + 11] << 8);
            rate = buf[at + 12] | (buf[at + 13] << 8) | (buf[at + 14] << 16); bits = buf[at + 22] | (buf[at + 23] << 8);
        } else if (memcmp(buf + at, "data", 4) == 0) {
            data = buf + at + 8; data_n = len; if (at + 8 + data_n > size) data_n = size - at - 8;
            break;
        }
        at += 8 + len + (len & 1);
    }
    if (!data || (fmt != 1 && fmt != 0xFFFE) || (ch != 1 && ch != 2) || (bits != 8 && bits != 16) || rate < 1000) { free(buf); return -1; }
    {
        long frames = data_n / (ch * (bits / 8));
        out_n = (int)((double)frames * CB_DOS_RATE / rate);
        out = (signed char *)malloc((size_t)(out_n > 0 ? out_n : 1));
        if (!out) { free(buf); return -1; }
        for (i = 0; i < out_n; i++) {
            long fr = (long)((double)i * rate / CB_DOS_RATE);
            int c, sum = 0;
            if (fr >= frames) fr = frames - 1;
            for (c = 0; c < ch; c++) {
                const unsigned char *q = data + (fr * ch + c) * (bits / 8);
                sum += bits == 8 ? (int)q[0] - 128 : (short)(q[0] | (q[1] << 8)) / 256;
            }
            out[i] = (signed char)(sum / ch);
        }
    }
    free(buf);
    grown = (cb_dos_pcm *)realloc((void *)cb_dos_pcms, sizeof(cb_dos_pcm) * (size_t)(cb_dos_pcm_n + 1));
    if (!grown) { free(out); return -1; }
    cb_dos_pcms = grown;
    cb_dos_pcms[cb_dos_pcm_n].s = out;
    cb_dos_pcms[cb_dos_pcm_n].n = out_n;
    return cb_dos_pcm_n++;
}

cb_sound cb_be_sound_load(const char *path) {
    cb_sound s = {0, 0};
    int p = cb_dos_wav(path);
    if (p >= 0) { s.id = p + 1; s.frames = (unsigned)cb_dos_pcms[p].n; }
    return s;
}

void cb_be_sound_play(cb_sound s) {
    int v, free_v = -1;
    if (s.id < 1 || s.id > cb_dos_pcm_n)
        return;
    for (v = 0; v < CB_DOS_VOICES; v++)
        if (!cb_dos_voices[v].on) { free_v = v; break; }
    if (free_v < 0) free_v = 0;   /* all busy: the first is cut */
    cb_dos_voices[free_v].pcm = s.id - 1; cb_dos_voices[free_v].pos = 0; cb_dos_voices[free_v].vol = 1;
    cb_dos_voices[free_v].loop = false; cb_dos_voices[free_v].on = true; cb_dos_voices[free_v].paused = false;
}

/* ---------------------------------------------------------------- music: FM synthesis (OPL2 / OPL3) from IMF, DRO and VGM files
   Music that has a FM version plays on the FM chip (AdLib, Sound Blaster, ports 388h / 38Ah): the
   build maps a music path to it (theme.ogg -> a theme.imf / .dro / .vgm beside it), or the path is
   such a file. A file is read at load into a list of timed register writes, played back from the
   clock (cb_be_music_update). One FM song at a time. Without an OPL chip it "plays" silently.
   IMF: records of (register, value, delay) at 560 Hz (.wlf: 700 Hz). DRO (DOSBox raw OPL) v1 and v2.
   VGM: the YM3812 / YM3526 / Y8950 / YMF262 writes and the waits. */
typedef struct { unsigned long us; unsigned char bank, reg, val; } cb_dos_fmev;
typedef struct { cb_dos_fmev *ev; long n; long cap; double length; } cb_dos_fmsong;
static cb_dos_fmsong *cb_dos_fms = NULL;
static int cb_dos_fm_n = 0;
static bool cb_dos_opl = false, cb_dos_opl3 = false;
static long cb_dos_opl_writes = 0;
static unsigned char cb_dos_opl_shadow[2][256];
static int cb_dos_fm_cur = -1;               /* the playing song: an index into cb_dos_songs */
static long cb_dos_fm_next = 0;
static uclock_t cb_dos_fm_t0 = 0;
static double cb_dos_fm_paused_us = 0;

static void cb_dos_opl_raw(int bank, int reg, int val) {
    int i, port = 0x388 + bank * 2;
    outportb((unsigned short)port, (unsigned char)reg);
    for (i = 0; i < 6; i++) (void)inportb(0x388);
    outportb((unsigned short)(port + 1), (unsigned char)val);
    for (i = 0; i < 35; i++) (void)inportb(0x388);
}

static void cb_dos_opl_start(void) {
    int st1, st2, r;
    uclock_t t;
    cb_dos_opl_raw(0, 4, 0x60); cb_dos_opl_raw(0, 4, 0x80);
    st1 = inportb(0x388);
    cb_dos_opl_raw(0, 2, 0xFF); cb_dos_opl_raw(0, 4, 0x21);
    t = uclock(); while (uclock() - t < 200) { }   /* about 170 microseconds */
    st2 = inportb(0x388);
    cb_dos_opl_raw(0, 4, 0x60); cb_dos_opl_raw(0, 4, 0x80);
    cb_dos_opl = (st1 & 0xE0) == 0 && (st2 & 0xE0) == 0xC0;
    if (!cb_dos_opl)
        return;
    cb_dos_opl3 = (inportb(0x388) & 6) == 0;
    for (r = 0x01; r <= 0xF5; r++) { cb_dos_opl_raw(0, r, 0); if (cb_dos_opl3) cb_dos_opl_raw(1, r, 0); }
    cb_dos_opl_raw(0, 1, 0x20);
    if (cb_dos_opl3) cb_dos_opl_raw(1, 5, 0);
    memset(cb_dos_opl_shadow, 0, sizeof cb_dos_opl_shadow);
}

/* silence: every voice keyed off, every level to its quietest */
static void cb_dos_opl_silence(void) {
    int c, b;
    if (!cb_dos_opl) return;
    for (b = 0; b < (cb_dos_opl3 ? 2 : 1); b++) {
        for (c = 0; c < 9; c++) cb_dos_opl_raw(b, 0xB0 + c, cb_dos_opl_shadow[b][0xB0 + c] & 0x1F);
        for (c = 0x40; c <= 0x55; c++) cb_dos_opl_raw(b, c, 0x3F);
    }
    cb_dos_opl_raw(0, 0xBD, 0);
    memset(cb_dos_opl_shadow, 0, sizeof cb_dos_opl_shadow);
}

static void cb_dos_fm_close(void) {
    if (!cb_dos_opl) return;
    cb_dos_opl_silence();
    if (cb_dos_opl3) cb_dos_opl_raw(1, 5, 0);
    if (cb_verbose)
        printf("[audio] FM chip: %s at 388h, %ld register writes\n", cb_dos_opl3 ? "OPL3" : "OPL2", cb_dos_opl_writes);
}

static bool cb_dos_is_carrier(int reg) {
    static const unsigned char car[9] = {0x03, 0x04, 0x05, 0x0B, 0x0C, 0x0D, 0x13, 0x14, 0x15};
    int k, off = reg & 0x1F;
    if (reg < 0x40 || reg > 0x55) return false;
    for (k = 0; k < 9; k++) if (car[k] == off) return true;
    return false;
}

static double cb_dos_fm_vol(void) { return cb_dos_fm_cur >= 0 ? cb_dos_songs[cb_dos_fm_cur].vol : 1.0; }

/* one register write of the song, its carriers' levels scaled by the Music's volume */
static void cb_dos_fm_emit(int bank, int reg, int val) {
    if (!cb_dos_opl || (bank == 1 && !cb_dos_opl3)) return;
    cb_dos_opl_shadow[bank][reg] = (unsigned char)val;
    if (cb_dos_is_carrier(reg)) {
        int tl = val & 0x3F;
        tl = tl + (int)((63 - tl) * (1.0 - cb_dos_fm_vol()) + 0.5);
        val = (val & 0xC0) | tl;
    }
    cb_dos_opl_raw(bank, reg, val);
    cb_dos_opl_writes++;
}

static void cb_dos_fm_revolume(void) {
    int b, r;
    if (!cb_dos_opl) return;
    for (b = 0; b < (cb_dos_opl3 ? 2 : 1); b++)
        for (r = 0x40; r <= 0x55; r++)
            if (cb_dos_is_carrier(r)) cb_dos_fm_emit(b, r, cb_dos_opl_shadow[b][r]);
}

static double cb_dos_fm_elapsed_us(void) { return (double)(uclock() - cb_dos_fm_t0) * 1e6 / UCLOCKS_PER_SEC; }

static void cb_dos_fm_update(void) {
    cb_dos_voice *v;
    const cb_dos_fmsong *song;
    double us;
    if (cb_dos_fm_cur < 0) return;
    v = &cb_dos_songs[cb_dos_fm_cur];
    if (!v->on || v->paused) return;
    song = &cb_dos_fms[v->fm - 1];
    us = cb_dos_fm_elapsed_us();
    while (cb_dos_fm_next < song->n && (double)song->ev[cb_dos_fm_next].us <= us) {
        const cb_dos_fmev *e = &song->ev[cb_dos_fm_next++];
        cb_dos_fm_emit(e->bank, e->reg, e->val);
    }
    if (cb_dos_fm_next >= song->n && us >= song->length * 1e6) {
        cb_dos_opl_silence();
        if (v->loop && song->n > 0) { cb_dos_fm_next = 0; cb_dos_fm_t0 = uclock(); }
        else { v->on = false; cb_dos_fm_cur = -1; }
    }
}

/* the list of timed writes being built */
static bool cb_dos_fm_add(cb_dos_fmsong *s, double us, int bank, int reg, int val) {
    if (s->n == s->cap) {
        long cap = s->cap ? s->cap * 2 : 1024;
        cb_dos_fmev *g = (cb_dos_fmev *)realloc((void *)s->ev, sizeof(cb_dos_fmev) * (size_t)cap);
        if (!g) return false;
        s->ev = g; s->cap = cap;
    }
    s->ev[s->n].us = (unsigned long)us; s->ev[s->n].bank = (unsigned char)bank; s->ev[s->n].reg = (unsigned char)reg; s->ev[s->n].val = (unsigned char)val;
    s->n++;
    return true;
}

static unsigned cb_dos_u16(const unsigned char *p) { return (unsigned)(p[0] | (p[1] << 8)); }
static unsigned long cb_dos_u32(const unsigned char *p) { return (unsigned long)p[0] | ((unsigned long)p[1] << 8) | ((unsigned long)p[2] << 16) | ((unsigned long)p[3] << 24); }

static bool cb_dos_parse_imf(cb_dos_fmsong *s, const unsigned char *d, long n, double hz) {
    long at = 0, end = n;
    double us = 0;
    if (n >= 2 && cb_dos_u16(d) != 0) {   /* type 1: a length first (bytes of music), then maybe tags */
        long len = (long)cb_dos_u16(d);
        at = 2;
        if (len > 0 && 2 + len <= n) end = 2 + len;
    }
    for (; at + 4 <= end; at += 4) {
        if (!cb_dos_fm_add(s, us, 0, d[at], d[at + 1])) return false;
        us += (double)cb_dos_u16(d + at + 2) * 1e6 / hz;
    }
    s->length = us / 1e6;
    return true;
}

static bool cb_dos_parse_dro(cb_dos_fmsong *s, const unsigned char *d, long n) {
    double ms = 0;
    long at;
    if (n < 16 || memcmp(d, "DBRAWOPL", 8) != 0) return false;
    if (cb_dos_u16(d + 8) == 2) {   /* v2.0: pairs of (index, value); a codemap names the registers; the high bit of the index picks the chip */
        long pairs = (long)cb_dos_u32(d + 12);
        int short_code, long_code, map_n;
        const unsigned char *map;
        long i;
        if (n < 26) return false;
        short_code = d[23]; long_code = d[24]; map_n = d[25];
        map = d + 26;
        at = 26 + map_n;
        for (i = 0; i < pairs && at + 2 <= n; i++, at += 2) {
            int idx = d[at], val = d[at + 1];
            if (idx == short_code) ms += val + 1;
            else if (idx == long_code) ms += (double)(val + 1) * 256.0;
            else if ((idx & 0x7F) < map_n && !cb_dos_fm_add(s, ms * 1000.0, (idx & 0x80) ? 1 : 0, map[idx & 0x7F], val)) return false;
        }
    } else {   /* v0.1 / v1.0: a data length, then bytes: 0 / 1 delay (1 / 2 bytes of milliseconds), 2 / 3 the chip, 4 escapes a register, else a register and its value */
        int bank = 0;
        at = 24;
        if (n < 24) return false;
        while (at < n) {
            int c = d[at++];
            if (c == 0 && at < n) ms += d[at++] + 1;
            else if (c == 1 && at + 1 < n) { ms += cb_dos_u16(d + at) + 1; at += 2; }
            else if (c == 2) bank = 0;
            else if (c == 3) bank = 1;
            else {
                if (c == 4 && at < n) c = d[at++];
                if (at >= n) break;
                if (!cb_dos_fm_add(s, ms * 1000.0, bank, c, d[at++])) return false;
            }
        }
    }
    s->length = ms / 1000.0;
    return true;
}

static bool cb_dos_parse_vgm(cb_dos_fmsong *s, const unsigned char *d, long n) {
    long at;
    double us = 0;
    if (n < 0x40 || memcmp(d, "Vgm ", 4) != 0) return false;
    at = cb_dos_u32(d + 0x08) >= 0x150 ? 0x34 + (long)cb_dos_u32(d + 0x34) : 0x40;
    if (at < 0x40 || at >= n) at = 0x40;
    while (at < n) {
        int c = d[at++];
        if (c == 0x66) break;
        if (c == 0x5A || c == 0x5B || c == 0x5C || c == 0x5E || c == 0x5F) {   /* YM3812, YM3526, Y8950; YMF262 ports 0 / 1 */
            if (at + 2 > n) break;
            if (!cb_dos_fm_add(s, us, c == 0x5F ? 1 : 0, d[at], d[at + 1])) return false;
            at += 2;
        } else if (c == 0x61) { if (at + 2 > n) break; us += (double)cb_dos_u16(d + at) * 1e6 / 44100.0; at += 2; }
        else if (c == 0x62) us += 735.0 * 1e6 / 44100.0;
        else if (c == 0x63) us += 882.0 * 1e6 / 44100.0;
        else if (c >= 0x70 && c <= 0x7F) us += (double)((c & 15) + 1) * 1e6 / 44100.0;
        else if (c == 0x67) { if (at + 6 > n) break; at += 6 + (long)cb_dos_u32(d + at + 2); }   /* a data block: skipped */
        else if (c == 0x68) at += 11;
        else if (c >= 0x30 && c <= 0x3F) at += 1;
        else if (c == 0x4F || c == 0x50) at += 1;
        else if ((c >= 0x40 && c <= 0x4E) || (c >= 0x51 && c <= 0x5F) || (c >= 0xA0 && c <= 0xBF)) at += 2;
        else if (c >= 0xC0 && c <= 0xDF) at += 3;
        else if (c >= 0xE0) at += 4;
        else if (c >= 0x80 && c <= 0x8F) us += (double)(c & 15) * 1e6 / 44100.0;
    }
    s->length = us / 1e6;
    return true;
}

/* ---- MIDI: compiled at load into timed register writes, with an OP2 instrument bank (audio/genmidi.op2: DMXOPL)
   The notes are given to the chip's voices as they would be live (the oldest is taken when all are busy), so what
   the player does is the same as for the other formats: play the writes from the clock. 9 voices (18 on an OPL3);
   a two-voice instrument takes two when there are voices to spare. Pitch bend (+-2 semitones), volume and
   expression, program changes and the drum channel (10) are followed; the sustain pedal, panning, modulation and
   the other controllers are not. */
typedef struct { unsigned char tv, ad, sr, wave, ksl, level; } cb_dos_op;
typedef struct { cb_dos_op mod, car; unsigned char fb; int base; } cb_dos_ivoice;
typedef struct { unsigned flags; int fixed; cb_dos_ivoice v[2]; } cb_dos_instr;
static cb_dos_instr cb_dos_bank[175];
static int cb_dos_bank_state = 0;   /* 0 not tried, 1 loaded, -1 failed */

static bool cb_dos_bank_load(void) {
    unsigned char buf[8 + 175 * 36];
    FILE *f;
    int i, k;
    if (cb_dos_bank_state)
        return cb_dos_bank_state > 0;
    cb_dos_bank_state = -1;
    f = cb_dos_open_named("genmidi.op2");
    if (!f)
        return false;
    if (fread(buf, 1, sizeof buf, f) != sizeof buf || memcmp(buf, "#OPL_II#", 8) != 0) { fclose(f); return false; }
    fclose(f);
    for (i = 0; i < 175; i++) {
        const unsigned char *p = buf + 8 + i * 36;
        cb_dos_bank[i].flags = cb_dos_u16(p);
        cb_dos_bank[i].fixed = p[3];
        for (k = 0; k < 2; k++) {
            const unsigned char *q = p + 4 + k * 16;
            cb_dos_ivoice *v = &cb_dos_bank[i].v[k];
            v->mod.tv = q[0]; v->mod.ad = q[1]; v->mod.sr = q[2]; v->mod.wave = q[3]; v->mod.ksl = q[4]; v->mod.level = q[5];
            v->fb = q[6];
            v->car.tv = q[7]; v->car.ad = q[8]; v->car.sr = q[9]; v->car.wave = q[10]; v->car.ksl = q[11]; v->car.level = q[12];
            v->base = (short)cb_dos_u16(q + 14);
        }
    }
    cb_dos_bank_state = 1;
    return true;
}

typedef struct { unsigned long tick; unsigned long seq; unsigned long tempo; unsigned char type, a, b; } cb_dos_mev;
typedef struct { bool on; int ch, note, instr, voice; unsigned long born; unsigned char b0; } cb_dos_slot;

static int cb_dos_mev_cmp(const void *x, const void *y) {
    const cb_dos_mev *a = (const cb_dos_mev *)x, *b = (const cb_dos_mev *)y;
    if (a->tick != b->tick) return a->tick < b->tick ? -1 : 1;
    return a->seq < b->seq ? -1 : (a->seq > b->seq ? 1 : 0);
}

static unsigned long cb_dos_vlq(const unsigned char *d, long n, long *at) {
    unsigned long v = 0;
    int k;
    for (k = 0; k < 4 && *at < n; k++) {
        unsigned char c = d[(*at)++];
        v = (v << 7) | (c & 0x7F);
        if (!(c & 0x80)) break;
    }
    return v;
}

static const unsigned char cb_dos_op_off[9] = {0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12};

typedef struct {
    cb_dos_fmsong *song;
    double us;
    unsigned char shadow[2][256];
    cb_dos_slot slot[18];
    int nslots;
    int prog[16], vol[16], expr[16], bend[16];
    unsigned long born;
} cb_dos_mc;

static void cb_dos_mput(cb_dos_mc *c, int bank, int reg, int val, bool force) {
    if (!force && c->shadow[bank][reg] == (unsigned char)val) return;
    c->shadow[bank][reg] = (unsigned char)val;
    cb_dos_fm_add(c->song, c->us, bank, reg, val);
}

/* the chip's frequency registers for a note (semitones, fractional) */
static void cb_dos_freq(double semis, int *fnum, int *block) {
    double f = 440.0 * pow(2.0, (semis - 69.0) / 12.0), n;
    int b = 0;
    for (; b < 7; b++) {
        n = f * (double)(1L << (20 - b)) / 49716.0;
        if (n <= 1023.0) break;
    }
    n = f * (double)(1L << (20 - b)) / 49716.0;
    if (n > 1023.0) n = 1023.0;
    if (n < 0) n = 0;
    *fnum = (int)(n + 0.5); *block = b;
}

static int cb_dos_atten(double v) {   /* a loudness (0..1) as the 0.75 dB steps of a level register */
    int a;
    if (v < 0.0008) return 63;
    a = (int)(-20.0 * log10(v) / 0.75 + 0.5);
    return a > 63 ? 63 : a;
}

static double cb_dos_mvol(const cb_dos_mc *c, int ch, int vel) {
    return (double)vel / 127.0 * (double)c->vol[ch] / 127.0 * (double)c->expr[ch] / 127.0;
}

/* a slot's levels: the instrument's own plus the note's loudness */
static void cb_dos_mlevels(cb_dos_mc *c, int s, const cb_dos_ivoice *v, int ch, int vel) {
    int bank = s / 9, ch9 = s % 9, off = cb_dos_op_off[ch9], a = cb_dos_atten(cb_dos_mvol(c, ch, vel)), tl;
    tl = (v->car.level & 0x3F) + a; if (tl > 63) tl = 63;
    cb_dos_mput(c, bank, 0x40 + off + 3, (v->car.ksl & 0xC0) | tl, false);
    tl = v->mod.level & 0x3F;
    if (v->fb & 1) { tl += a; if (tl > 63) tl = 63; }   /* additive: the modulator is heard too */
    cb_dos_mput(c, bank, 0x40 + off, (v->mod.ksl & 0xC0) | tl, false);
}

static void cb_dos_mkeyoff(cb_dos_mc *c, int s) {
    if (!c->slot[s].on) return;
    cb_dos_mput(c, s / 9, 0xB0 + s % 9, c->slot[s].b0 & 0x1F, true);
    c->slot[s].on = false;
}

static void cb_dos_mfreq(cb_dos_mc *c, int s, bool key) {
    const cb_dos_slot *sl = &c->slot[s];
    const cb_dos_instr *in = &cb_dos_bank[sl->instr];
    double semis = (double)((in->flags & 1) ? in->fixed : sl->note) + in->v[sl->voice].base + (double)(c->bend[sl->ch] - 8192) / 8192.0 * 2.0;
    int fnum, block;
    cb_dos_freq(semis, &fnum, &block);
    cb_dos_mput(c, s / 9, 0xA0 + s % 9, fnum & 0xFF, false);
    c->slot[s].b0 = (unsigned char)((key ? 0x20 : 0) | (block << 2) | ((fnum >> 8) & 3));
    cb_dos_mput(c, s / 9, 0xB0 + s % 9, c->slot[s].b0, true);
}

static int cb_dos_mslot(cb_dos_mc *c) {
    int s, oldest = 0;
    for (s = 0; s < c->nslots; s++)
        if (!c->slot[s].on) return s;
    for (s = 1; s < c->nslots; s++)
        if (c->slot[s].born < c->slot[oldest].born) oldest = s;
    cb_dos_mkeyoff(c, oldest);
    return oldest;
}

static void cb_dos_mnote_on(cb_dos_mc *c, int ch, int note, int vel) {
    int instr = ch == 9 ? 128 + (note < 35 ? 0 : (note > 81 ? 46 : note - 35)) : c->prog[ch], voices = 1, k;
    const cb_dos_instr *in;
    if (instr < 0 || instr > 174) return;
    in = &cb_dos_bank[instr];
    if ((in->flags & 4) && c->nslots >= 16) voices = 2;
    for (k = 0; k < voices; k++) {
        int s = cb_dos_mslot(c), bank = s / 9, ch9 = s % 9, off = cb_dos_op_off[ch9];
        const cb_dos_ivoice *v = &in->v[k];
        c->slot[s].on = true; c->slot[s].ch = ch; c->slot[s].note = note; c->slot[s].instr = instr; c->slot[s].voice = k; c->slot[s].born = c->born++;
        cb_dos_mput(c, bank, 0xB0 + ch9, 0, false);   /* (key off first, so the new note starts) */
        cb_dos_mput(c, bank, 0x20 + off, v->mod.tv, false);     cb_dos_mput(c, bank, 0x23 + off, v->car.tv, false);
        cb_dos_mput(c, bank, 0x60 + off, v->mod.ad, false);     cb_dos_mput(c, bank, 0x63 + off, v->car.ad, false);
        cb_dos_mput(c, bank, 0x80 + off, v->mod.sr, false);     cb_dos_mput(c, bank, 0x83 + off, v->car.sr, false);
        cb_dos_mput(c, bank, 0xE0 + off, v->mod.wave & 3, false); cb_dos_mput(c, bank, 0xE3 + off, v->car.wave & 3, false);
        cb_dos_mput(c, bank, 0xC0 + ch9, (v->fb & 0x0F) | (bank == 1 || c->nslots > 9 ? 0x30 : 0), false);
        cb_dos_mlevels(c, s, v, ch, vel);
        cb_dos_mfreq(c, s, true);
    }
}

static void cb_dos_mnote_off(cb_dos_mc *c, int ch, int note) {
    int s;
    for (s = 0; s < c->nslots; s++)
        if (c->slot[s].on && c->slot[s].ch == ch && c->slot[s].note == note)
            cb_dos_mkeyoff(c, s);
}

static bool cb_dos_parse_midi(cb_dos_fmsong *song, const unsigned char *d, long n) {
    unsigned ntrk, div, t;
    long at = 14;
    cb_dos_mev *ev = NULL;
    long nev = 0, cap = 0, i;
    unsigned long seq = 0, last_tick = 0, tempo = 500000;
    cb_dos_mc *c;
    if (n < 14 || memcmp(d, "MThd", 4) != 0 || !cb_dos_bank_load()) return false;
    ntrk = (unsigned)((d[10] << 8) | d[11]); div = (unsigned)((d[12] << 8) | d[13]);
    if (div == 0 || (div & 0x8000)) return false;   /* (SMPTE time isn't read) */
    for (t = 0; t < ntrk && at + 8 <= n; t++) {
        unsigned long len = ((unsigned long)d[at + 4] << 24) | ((unsigned long)d[at + 5] << 16) | ((unsigned long)d[at + 6] << 8) | d[at + 7];
        long p = at + 8, end = at + 8 + (long)len;
        unsigned long tick = 0;
        int running = 0;
        if (memcmp(d + at, "MTrk", 4) != 0) break;
        if (end > n) end = n;
        while (p < end) {
            int st;
            cb_dos_mev e;
            tick += cb_dos_vlq(d, end, &p);
            if (p >= end) break;
            st = d[p];
            if (st < 0x80) st = running; else p++;
            memset(&e, 0, sizeof e);
            e.tick = tick; e.seq = seq++;
            if (st == 0xFF) {   /* meta */
                int type;
                unsigned long mlen;
                if (p >= end) break;
                type = d[p++]; mlen = cb_dos_vlq(d, end, &p);
                if (type == 0x51 && mlen == 3 && p + 3 <= end) { e.type = 0xFF; e.tempo = ((unsigned long)d[p] << 16) | ((unsigned long)d[p + 1] << 8) | d[p + 2]; }
                p += (long)mlen;
                if (type == 0x2F) { p = end; }
                if (e.type != 0xFF) continue;
            } else if (st == 0xF0 || st == 0xF7) {
                unsigned long slen = cb_dos_vlq(d, end, &p);
                p += (long)slen;
                continue;
            } else if (st >= 0x80) {
                int need = ((st & 0xF0) == 0xC0 || (st & 0xF0) == 0xD0) ? 1 : 2;
                running = st;
                if (p + need > end) break;
                e.type = (unsigned char)st; e.a = d[p]; e.b = need == 2 ? d[p + 1] : 0;
                p += need;
                if ((st & 0xF0) >= 0xA0 && (st & 0xF0) != 0xC0 && (st & 0xF0) != 0xE0 && (st & 0xF0) != 0xB0) continue;  /* aftertouch, channel pressure */
            } else break;
            if (nev == cap) {
                long nc = cap ? cap * 2 : 2048;
                cb_dos_mev *g = (cb_dos_mev *)realloc((void *)ev, sizeof(cb_dos_mev) * (size_t)nc);
                if (!g) { free(ev); return false; }
                ev = g; cap = nc;
            }
            ev[nev++] = e;
        }
        at = end;
    }
    qsort(ev, (size_t)nev, sizeof(cb_dos_mev), cb_dos_mev_cmp);
    c = (cb_dos_mc *)calloc(1, sizeof(cb_dos_mc));
    if (!c) { free(ev); return false; }
    c->song = song;
    c->nslots = cb_dos_opl3 ? 18 : 9;
    for (i = 0; i < 16; i++) { c->vol[i] = 100; c->expr[i] = 127; c->bend[i] = 8192; }
    cb_dos_mput(c, 0, 0x01, 0x20, true);
    if (cb_dos_opl3) cb_dos_mput(c, 1, 0x05, 1, true);   /* OPL3 mode: the second bank's nine voices */
    for (i = 0; i < nev; i++) {
        const cb_dos_mev *e = &ev[i];
        int ch = e->type & 15, s;
        c->us += (double)(e->tick - last_tick) * (double)tempo / (double)div;
        last_tick = e->tick;
        if (e->type == 0xFF) { tempo = e->tempo ? e->tempo : 500000; continue; }
        switch (e->type & 0xF0) {
            case 0x90:
                if (e->b > 0) { cb_dos_mnote_on(c, ch, e->a, e->b); break; }
                cb_dos_mnote_off(c, ch, e->a);
                break;
            case 0x80: cb_dos_mnote_off(c, ch, e->a); break;
            case 0xC0: c->prog[ch] = e->a & 0x7F; break;
            case 0xE0:
                c->bend[ch] = e->a | (e->b << 7);
                for (s = 0; s < c->nslots; s++) if (c->slot[s].on && c->slot[s].ch == ch) cb_dos_mfreq(c, s, true);
                break;
            case 0xB0:
                if (e->a == 7) c->vol[ch] = e->b;
                else if (e->a == 11) c->expr[ch] = e->b;
                if (e->a == 7 || e->a == 11) {   /* the sounding notes follow the new loudness */
                    for (s = 0; s < c->nslots; s++)
                        if (c->slot[s].on && c->slot[s].ch == ch) cb_dos_mlevels(c, s, &cb_dos_bank[c->slot[s].instr].v[c->slot[s].voice], ch, 100);
                } else if (e->a == 120 || e->a == 123) {
                    for (s = 0; s < c->nslots; s++) if (c->slot[s].on && c->slot[s].ch == ch) cb_dos_mkeyoff(c, s);
                }
                break;
            default: break;
        }
    }
    for (i = 0; i < c->nslots; i++) cb_dos_mkeyoff(c, (int)i);
    song->length = c->us / 1e6;
    free(c); free(ev);
    return song->n > 0;
}

static bool cb_dos_has_ext(const char *path, const char *ext) {
    size_t a = strlen(path), b = strlen(ext), i;
    if (a < b + 1 || path[a - b - 1] != '.') return false;
    for (i = 0; i < b; i++) {
        char c = path[a - b + i];
        if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
        if (c != ext[i]) return false;
    }
    return true;
}

/* an FM song from a file (named: beside the program's audio/ folder; else a path): its number + 1, 0 if unreadable */
static int cb_dos_fm_load(FILE *f, const char *name) {
    long size;
    unsigned char *buf;
    cb_dos_fmsong song;
    cb_dos_fmsong *grown;
    bool ok;
    if (!f) return 0;
    fseek(f, 0, SEEK_END); size = ftell(f); fseek(f, 0, SEEK_SET);
    if (size < 4 || size > 16L * 1024 * 1024) { fclose(f); return 0; }
    buf = (unsigned char *)malloc((size_t)size);
    if (!buf) { fclose(f); return 0; }
    size = (long)fread(buf, 1, (size_t)size, f);
    fclose(f);
    memset(&song, 0, sizeof song);
    if (cb_dos_has_ext(name, "mid") || cb_dos_has_ext(name, "midi")) ok = cb_dos_parse_midi(&song, buf, size);
    else if (cb_dos_has_ext(name, "vgm")) ok = cb_dos_parse_vgm(&song, buf, size);
    else if (cb_dos_has_ext(name, "dro")) ok = cb_dos_parse_dro(&song, buf, size);
    else ok = cb_dos_parse_imf(&song, buf, size, cb_dos_has_ext(name, "wlf") ? 700.0 : 560.0);
    free(buf);
    if (!ok || song.n == 0) { free(song.ev); return 0; }
    grown = (cb_dos_fmsong *)realloc((void *)cb_dos_fms, sizeof(cb_dos_fmsong) * (size_t)(cb_dos_fm_n + 1));
    if (!grown) { free(song.ev); return 0; }
    cb_dos_fms = grown;
    cb_dos_fms[cb_dos_fm_n] = song;
    return ++cb_dos_fm_n;
}

static cb_dos_voice *cb_dos_new_song(void) {
    cb_dos_voice *grown = (cb_dos_voice *)realloc((void *)cb_dos_songs, sizeof(cb_dos_voice) * (size_t)(cb_dos_song_n + 1));
    if (!grown) return NULL;
    cb_dos_songs = grown;
    memset(&cb_dos_songs[cb_dos_song_n], 0, sizeof(cb_dos_voice));
    cb_dos_songs[cb_dos_song_n].vol = 1;
    return &cb_dos_songs[cb_dos_song_n];
}

/* a Music handle: its own voice, in cb_dos_songs (its id is the song's number + 1). The FM version
   of the file, if there is one, is what plays; else the converted PCM. */
cb_music cb_be_music_load(const char *path, bool loop) {
    cb_music m = {0, 0, false};
    int i = cb_dos_audio_index(path), fm = 0, p = -1;
    cb_dos_voice *v;
    if (i >= 0 && cb_dos_audio_fm[i])
        fm = cb_dos_fm_load(cb_dos_open_named(cb_dos_audio_fm[i]), cb_dos_audio_fm[i]);
    else if (i < 0 && (cb_dos_has_ext(path, "imf") || cb_dos_has_ext(path, "wlf") || cb_dos_has_ext(path, "dro") || cb_dos_has_ext(path, "vgm") || cb_dos_has_ext(path, "mid") || cb_dos_has_ext(path, "midi")))
        fm = cb_dos_fm_load(fopen(path, "rb"), path);
    if (!fm) {
        p = cb_dos_wav(path);
        if (p < 0)
            return m;
    }
    v = cb_dos_new_song();
    if (!v)
        return m;
    v->pcm = p < 0 ? 0 : p; v->fm = fm; v->loop = loop;
    cb_dos_song_n++;
    m.id = cb_dos_song_n; m.looping = loop;
    m.length = fm ? (float)cb_dos_fms[fm - 1].length : (float)cb_dos_pcms[p].n / CB_DOS_RATE;
    return m;
}

static cb_dos_voice *cb_dos_song(cb_music m) { return m.id >= 1 && m.id <= cb_dos_song_n ? &cb_dos_songs[m.id - 1] : NULL; }

static void cb_dos_fm_begin(int song_index) {
    if (cb_dos_fm_cur >= 0 && cb_dos_fm_cur != song_index)
        cb_dos_songs[cb_dos_fm_cur].on = false;   /* one FM song at a time */
    cb_dos_opl_silence();
    cb_dos_fm_cur = song_index;
    cb_dos_fm_next = 0;
    cb_dos_fm_t0 = uclock();
}

void cb_be_music_play(cb_music m) {
    cb_dos_voice *v = cb_dos_song(m);
    if (!v) return;
    v->pos = 0; v->on = true; v->paused = false;
    if (v->fm) cb_dos_fm_begin(m.id - 1);
}

void cb_be_music_stop(cb_music m) {
    cb_dos_voice *v = cb_dos_song(m);
    if (!v) return;
    v->on = false; v->pos = 0; v->paused = false;
    if (v->fm && cb_dos_fm_cur == m.id - 1) { cb_dos_opl_silence(); cb_dos_fm_cur = -1; }
}

void cb_be_music_pause(cb_music m) {
    cb_dos_voice *v = cb_dos_song(m);
    if (!v || !v->on) return;
    v->paused = true;
    if (v->fm && cb_dos_fm_cur == m.id - 1) { cb_dos_fm_paused_us = cb_dos_fm_elapsed_us(); cb_dos_opl_silence(); }
}

void cb_be_music_resume(cb_music m) {
    cb_dos_voice *v = cb_dos_song(m);
    if (!v) return;
    if (v->fm && v->paused && v->on && cb_dos_fm_cur == m.id - 1) {
        /* the chip was silenced for the pause: set it up again by replaying every write made so far, then carry on */
        const cb_dos_fmsong *song = &cb_dos_fms[v->fm - 1];
        long k;
        cb_dos_fm_t0 = uclock() - (uclock_t)(cb_dos_fm_paused_us / 1e6 * UCLOCKS_PER_SEC);
        for (k = 0; k < cb_dos_fm_next; k++)
            cb_dos_fm_emit(song->ev[k].bank, song->ev[k].reg, song->ev[k].val);
    }
    v->paused = false;
}

void cb_be_music_volume(cb_music m, double volume) {
    cb_dos_voice *v = cb_dos_song(m);
    if (!v) return;
    v->vol = volume < 0 ? 0 : (volume > 1 ? 1 : volume);
    if (v->fm && cb_dos_fm_cur == m.id - 1) cb_dos_fm_revolume();
}

bool cb_be_music_playing(cb_music m) { cb_dos_voice *v = cb_dos_song(m); return v && v->on && !v->paused; }

void cb_be_music_forget_all(void) {
    int i;
    for (i = 0; i < cb_dos_song_n; i++) cb_dos_songs[i].on = false;
    cb_dos_opl_silence();
    cb_dos_fm_cur = -1;
}

/* ---------------------------------------------------------------- 3D: a software triangle renderer
   Everything is triangles, drawn with a depth buffer: Gouraud shading (the sun + ambient light of the raylib
   backend's shader: ambient * ambient colour + (1 - ambient) * max(n . -sun, 0) * sun colour, back faces lit
   from their own side), fog per pixel (exp(-density * (depth - start))), near-plane clipping, back faces
   culled (a mesh can ask for both sides), and the 256 colours hidden by ordered dithering. Matrices are
   OpenGL's (column-major) so the world's placement (translate, rotate, scale) composes the same way. */
typedef struct { double m[16]; } cb_m4;
static cb_m4 cb_m_stack[32];
static int cb_m_top = 0;
static cb_m4 cb_m_view, cb_m_cur;
static bool cb_3d_on = false, cb_3d_ortho = false;
static double cb_3d_f = 1, cb_3d_aspect = 1, cb_3d_top = 1;   /* the projection: 1 / tan(fov / 2); width / height; the orthographic half height */
static int *cb_zbuf = NULL;   /* the depth key per pixel, in whole numbers (integer compares are cheap): bigger is nearer (1 / depth; orthographic: 1 - depth / 1000) times CB_ZSCALE */
#define CB_ZSCALE 67108864.0
static int cb_zkey(double k) { return k <= 0 ? 0 : (k >= 31.9 ? 2140000000 : (int)(k * CB_ZSCALE)); }
static bool cb_zdirty = true;
static bool cb_rt_on;           /* (drawing into a render target: the smooth renderer's job) */
static bool cb_3d_fast = false; /* this 3D view is drawn by the fast renderer (flat triangles, painter's order) */
#define CB_NEAR 0.05
#define CB_ORTHO_FAR 1000.0

/* the sun and the fog (the Light3D, Environment) */
static Vector3 cb_sun = {-0.3714, -0.9285, -0.5571};
static double cb_amb = 0.38, cb_fog_density = 0, cb_fog_start = 0;
static double cb_sun_col[3] = {1, 1, 1}, cb_amb_col[3] = {1, 1, 1}, cb_fog_col[3] = {1, 1, 1};
static float cb_fog_lut[4096];
static int cb_fog_lut16[4096], cb_fog_col16[3];   /* the same in 16.16 */   /* "seen" by depth, in steps of 1/16 */
static bool cb_fog_dirty = true;

static cb_m4 cb_vc;                 /* view * current matrix (cb_vc_get) */
static bool cb_vc_dirty = true;
static double cb_pk_x, cb_pk_y, cb_pk_cx, cb_pk_cy, cb_fr_tx, cb_fr_ty, cb_fr_hx, cb_fr_hy;   /* + the view cone: tan of the half angles, and sqrt(1 + tan^2) */   /* the projection's constants: x = vx / z * pk_x + cx ... */
static cb_m4 cb_m4_id(void) { cb_m4 r; int i; for (i = 0; i < 16; i++) r.m[i] = (i % 5 == 0) ? 1.0 : 0.0; return r; }
static cb_m4 cb_m4_mul(const cb_m4 *a, const cb_m4 *b) {   /* a * b */
    cb_m4 r;
    int c, row, k;
    for (c = 0; c < 4; c++)
        for (row = 0; row < 4; row++) {
            double v = 0;
            for (k = 0; k < 4; k++) v += a->m[k * 4 + row] * b->m[c * 4 + k];
            r.m[c * 4 + row] = v;
        }
    return r;
}
static cb_m4 cb_m4_mul_aff(const cb_m4 *a, const cb_m4 *b) {   /* a * b of two affine matrices (36 products, not 64) */
    cb_m4 r;
    int c, row;
    for (c = 0; c < 4; c++) {
        for (row = 0; row < 3; row++)
            r.m[c * 4 + row] = a->m[row] * b->m[c * 4] + a->m[4 + row] * b->m[c * 4 + 1] + a->m[8 + row] * b->m[c * 4 + 2] + (c == 3 ? a->m[12 + row] : 0.0);
        r.m[c * 4 + 3] = c == 3 ? 1.0 : 0.0;
    }
    return r;
}
static const cb_m4 *cb_vc_get(void) {
    if (cb_vc_dirty) { cb_vc = cb_m4_mul_aff(&cb_m_view, &cb_m_cur); cb_vc_dirty = false; }
    return &cb_vc;
}
static Vector3 cb_m4_pt(const cb_m4 *a, Vector3 p) {
    return cb_v3(a->m[0] * p.x + a->m[4] * p.y + a->m[8] * p.z + a->m[12], a->m[1] * p.x + a->m[5] * p.y + a->m[9] * p.z + a->m[13], a->m[2] * p.x + a->m[6] * p.y + a->m[10] * p.z + a->m[14]);
}

void cb_be_push(void) { if (cb_m_top < 31) cb_m_stack[cb_m_top++] = cb_m_cur; }
void cb_be_pop(void) { if (cb_m_top > 0) { cb_m_cur = cb_m_stack[--cb_m_top]; cb_vc_dirty = true; } }
void cb_be_translate(double x, double y, double z) { cb_m4 t = cb_m4_id(); t.m[12] = x; t.m[13] = y; t.m[14] = z; cb_m_cur = cb_m4_mul(&cb_m_cur, &t); cb_vc_dirty = true; }
void cb_be_scale(double x, double y, double z) { cb_m4 t = cb_m4_id(); t.m[0] = x; t.m[5] = y; t.m[10] = z; cb_m_cur = cb_m4_mul(&cb_m_cur, &t); cb_vc_dirty = true; }
void cb_be_rotate(double degrees, double x, double y, double z) {   /* about an axis, counter-clockwise looking down it (glRotatef) */
    double len = sqrt(x * x + y * y + z * z), a = degrees * 3.14159265358979323846 / 180.0, c = cos(a), s = sin(a), t;
    cb_m4 r = cb_m4_id();
    if (len == 0) return;
    x /= len; y /= len; z /= len; t = 1 - c;
    r.m[0] = t * x * x + c;     r.m[4] = t * x * y - s * z; r.m[8] = t * x * z + s * y;
    r.m[1] = t * x * y + s * z; r.m[5] = t * y * y + c;     r.m[9] = t * y * z - s * x;
    r.m[2] = t * x * z - s * y; r.m[6] = t * y * z + s * x;  r.m[10] = t * z * z + c;
    cb_m_cur = cb_m4_mul(&cb_m_cur, &r);
    cb_vc_dirty = true;
}

static bool cb_fast_wanted(void);
static void cb_fast_flush(void);
static size_t cb_fn = 0;
void cb_be_begin_3d(Vector3 position, Vector3 target, double fov, bool ortho) {
    Vector3 f = cb_v3_normalize(cb_v3_sub(target, position)), up = cb_v3(0, 1, 0), s, u;
    cb_m4 v = cb_m4_id();
    if (fabs(f.y) > 0.9999) up = cb_v3(0, 0, -1);
    s = cb_v3_normalize(cb_v3_cross(f, up));
    u = cb_v3_cross(s, f);
    v.m[0] = s.x; v.m[4] = s.y; v.m[8] = s.z;
    v.m[1] = u.x; v.m[5] = u.y; v.m[9] = u.z;
    v.m[2] = -f.x; v.m[6] = -f.y; v.m[10] = -f.z;
    v.m[12] = -(s.x * position.x + s.y * position.y + s.z * position.z);
    v.m[13] = -(u.x * position.x + u.y * position.y + u.z * position.z);
    v.m[14] = f.x * position.x + f.y * position.y + f.z * position.z;
    cb_m_view = v;
    cb_3d_ortho = ortho;
    cb_3d_aspect = cb_dos_h > 0 ? (double)cb_dos_w / (double)cb_dos_h : 1;
    cb_3d_f = 1.0 / tan((fov > 1 ? fov : 1) * 3.14159265358979323846 / 360.0);
    cb_3d_top = (fov > 0.01 ? fov : 0.01) / 2.0;
    cb_m_cur = cb_m4_id();
    cb_m_top = 0;
    cb_vc_dirty = true;
    cb_pk_x = cb_3d_f / cb_3d_aspect * 0.5 * cb_dos_w; cb_pk_y = cb_3d_f * 0.5 * cb_dos_h; cb_pk_cx = 0.5 * cb_dos_w; cb_pk_cy = 0.5 * cb_dos_h;
    cb_fr_tx = cb_3d_aspect / cb_3d_f; cb_fr_ty = 1.0 / cb_3d_f; cb_fr_hx = sqrt(1.0 + cb_fr_tx * cb_fr_tx); cb_fr_hy = sqrt(1.0 + cb_fr_ty * cb_fr_ty);
    cb_3d_on = true;
    cb_3d_fast = cb_fast_wanted() && !cb_rt_on;
    cb_fn = 0;
    if (cb_3d_fast) return;   /* no depth buffer: the triangles are sorted instead */
    if (!cb_zbuf) cb_zbuf = (int *)calloc((size_t)cb_dos_w * (size_t)cb_dos_h, sizeof(int));
    if (cb_zbuf && cb_zdirty) memset(cb_zbuf, 0, (size_t)cb_dos_w * (size_t)cb_dos_h * sizeof(int));
}
void cb_be_splat(bool on) { (void)on; }  /* (no point splatting in the software renderer) */
void cb_be_end_3d(void) {
    if (cb_3d_on && cb_3d_fast) cb_fast_flush();
    cb_3d_on = false; cb_3d_fast = false; cb_zdirty = true;
}

/* ---- lighting state ---- */
void cb_set_light(Vector3 direction, double ambient) { cb_sun = cb_v3_normalize(direction); cb_amb = ambient; }
void cb_set_light_color(cb_rgba color, double energy) { cb_sun_col[0] = color.r / 255.0 * energy; cb_sun_col[1] = color.g / 255.0 * energy; cb_sun_col[2] = color.b / 255.0 * energy; }
void cb_set_fog(cb_rgba color, double density) { cb_fog_col[0] = color.r / 255.0; cb_fog_col[1] = color.g / 255.0; cb_fog_col[2] = color.b / 255.0; cb_fog_density = density > 0 ? density : 0; cb_fog_dirty = true; }
void cb_set_ambient(cb_rgba color, double fog_start) { cb_amb_col[0] = color.r / 255.0; cb_amb_col[1] = color.g / 255.0; cb_amb_col[2] = color.b / 255.0; cb_fog_start = fog_start > 0 ? fog_start : 0; cb_fog_dirty = true; }

static void cb_fog_build(void) {
    int i;
    for (i = 0; i < 4096; i++) {
        double d = i / 16.0 - cb_fog_start;
        cb_fog_lut[i] = (float)exp(-cb_fog_density * (d > 0 ? d : 0));
        cb_fog_lut16[i] = (int)(cb_fog_lut[i] * 65536.0f);
    }
    for (i = 0; i < 3; i++) cb_fog_col16[i] = (int)(cb_fog_col[i] * 65536.0);
    cb_fog_dirty = false;
}

/* ---- the rasteriser ---- */
typedef struct { double x, y, k, z; float r, g, b, a; } cb_sv;   /* screen position, depth key, view depth, lit colour */

static const unsigned char cb_bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

static unsigned char cb_dither(int x, int y, float r, float g, float b) {
    float thr = (cb_bayer[(y & 3) * 4 + (x & 3)] + 0.5f) / 16.0f;
    float mx = r > g ? (r > b ? r : b) : (g > b ? g : b), mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    r = r < 0 ? 0 : (r > 1 ? 1 : r); g = g < 0 ? 0 : (g > 1 ? 1 : g); b = b < 0 ? 0 : (b > 1 ? 1 : b);
    mx = r > g ? (r > b ? r : b) : (g > b ? g : b); mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    if (mx - mn < 0.055f) {   /* (near) grey: the 40 greys */
        int v = (int)(((r + g + b) / 3.0f) * 39.0f + thr);
        return (unsigned char)(216 + (v > 39 ? 39 : v));
    } else {
        int ri = (int)(r * 5.0f + thr), gi = (int)(g * 5.0f + thr), bi = (int)(b * 5.0f + thr);
        return (unsigned char)((ri > 5 ? 5 : ri) * 36 + (gi > 5 ? 5 : gi) * 6 + (bi > 5 ? 5 : bi));
    }
}

/* The common pixel (opaque, no fog) in whole numbers: colours in 16.16, the dither the same as cb_dither's
   (its threshold table in 16.16). The emulated FPU is the slow part on the machines that run DOS programs
   today (a Raspberry Pi running DOSBox-X: floating point per pixel took 3 s a frame at 800 x 600). */
static const int cb_thr16[16] = {2048, 34816, 10240, 43008, 51200, 18432, 59392, 26624, 14336, 47104, 6144, 38912, 63488, 30720, 55296, 22528};   /* (bayer + 0.5) / 16 in 16.16 */

static void cb_span_fast(int y, int x0, int x1, double xa, const cb_sv *a, const cb_sv *b, double inv) {
    double t0 = (x0 + 0.5) - xa, dkd = (b->k - a->k) * inv;
    int k = cb_zkey(a->k + dkd * t0), dk = (int)(dkd * CB_ZSCALE);
    int r = (int)((a->r + (b->r - a->r) * inv * t0) * 65536.0), g = (int)((a->g + (b->g - a->g) * inv * t0) * 65536.0), bl = (int)((a->b + (b->b - a->b) * inv * t0) * 65536.0);
    int dr = (int)((b->r - a->r) * inv * 65536.0), dg = (int)((b->g - a->g) * inv * 65536.0), db = (int)((b->b - a->b) * inv * 65536.0);
    int *zp = cb_zbuf + (size_t)y * (size_t)cb_dos_w + (size_t)x0;
    unsigned char *bp = cb_dos_back + (size_t)y * (size_t)cb_dos_w + (size_t)x0;
    const int *thr = cb_thr16 + (y & 3) * 4;
    int x;
    for (x = x0; x < x1; x++, k += dk, r += dr, g += dg, bl += db, zp++, bp++) {
        int rr, gg, bb, mx, mn, t;
        if (k <= *zp)
            continue;
        *zp = k;
        rr = r < 0 ? 0 : (r > 65536 ? 65536 : r); gg = g < 0 ? 0 : (g > 65536 ? 65536 : g); bb = bl < 0 ? 0 : (bl > 65536 ? 65536 : bl);
        mx = rr > gg ? (rr > bb ? rr : bb) : (gg > bb ? gg : bb); mn = rr < gg ? (rr < bb ? rr : bb) : (gg < bb ? gg : bb);
        t = thr[x & 3];
        if (mx - mn < 3604) {   /* (near) grey: the 40 greys */
            int v = (((rr + gg + bb) / 3) * 39 + t) >> 16;
            *bp = (unsigned char)(216 + (v > 39 ? 39 : v));
        } else {
            int ri = (rr * 5 + t) >> 16, gi = (gg * 5 + t) >> 16, bi = (bb * 5 + t) >> 16;
            *bp = (unsigned char)((ri > 5 ? 5 : ri) * 36 + (gi > 5 ? 5 : gi) * 6 + (bi > 5 ? 5 : bi));
        }
    }
}

static void cb_span(int y, double xa, double xb, const cb_sv *a, const cb_sv *b) {   /* a, b: the edge's attributes at xa, xb */
    int x0 = (int)ceil(xa - 0.5), x1 = (int)ceil(xb - 0.5), x;
    double len = xb - xa, inv = len > 1e-9 ? 1.0 / len : 0;
    double dk, dr, dg, db, da;
    double k, r, g, bl, al, t0;
    if (x0 < 0) x0 = 0;
    if (x1 > cb_dos_w) x1 = cb_dos_w;
    if (x1 <= x0) return;
    if (cb_fog_density <= 0 && a->a >= 0.98f && b->a >= 0.98f) {
        cb_span_fast(y, x0, x1, xa, a, b, inv);
        return;
    }
    dk = (b->k - a->k) * inv; dr = (b->r - a->r) * inv; dg = (b->g - a->g) * inv; db = (b->b - a->b) * inv; da = (b->a - a->a) * inv;
    t0 = (x0 + 0.5) - xa;
    k = a->k + dk * t0; r = a->r + dr * t0; g = a->g + dg * t0; bl = a->b + db * t0; al = a->a + da * t0;
    for (x = x0; x < x1; x++, k += dk, r += dr, g += dg, bl += db, al += da) {
        int *zp = cb_zbuf + (size_t)y * (size_t)cb_dos_w + (size_t)x;
        float rr = (float)r, gg = (float)g, bb = (float)bl;
        int zk = cb_zkey(k);
        if (zk <= *zp)
            continue;
        if (al < 0.5) continue;
        if (cb_fog_density > 0) {
            double z = cb_3d_ortho ? (1.0 - k) * CB_ORTHO_FAR : 1.0 / k;
            int li = (int)(z * 16.0);
            float seen = cb_fog_lut[li < 0 ? 0 : (li > 4095 ? 4095 : li)];
            rr = (float)(cb_fog_col[0] + (rr - cb_fog_col[0]) * seen);
            gg = (float)(cb_fog_col[1] + (gg - cb_fog_col[1]) * seen);
            bb = (float)(cb_fog_col[2] + (bb - cb_fog_col[2]) * seen);
        }
        *zp = zk;
        if (al < 0.98) {   /* see-through: over what's there */
            const unsigned char *o = cb_dos_pal[cb_dos_back[(size_t)y * (size_t)cb_dos_w + (size_t)x]];
            rr = (float)(rr * al + o[0] / 255.0 * (1 - al)); gg = (float)(gg * al + o[1] / 255.0 * (1 - al)); bb = (float)(bb * al + o[2] / 255.0 * (1 - al));
        }
        cb_dos_back[(size_t)y * (size_t)cb_dos_w + (size_t)x] = cb_dither(x, y, rr, gg, bb);
    }
}

static cb_sv cb_sv_lerp(const cb_sv *a, const cb_sv *b, double t) {
    cb_sv r;
    r.x = a->x + (b->x - a->x) * t; r.y = a->y + (b->y - a->y) * t; r.k = a->k + (b->k - a->k) * t; r.z = a->z + (b->z - a->z) * t;
    r.r = (float)(a->r + (b->r - a->r) * t); r.g = (float)(a->g + (b->g - a->g) * t); r.b = (float)(a->b + (b->b - a->b) * t); r.a = (float)(a->a + (b->a - a->a) * t);
    return r;
}

static void cb_tri_screen(const cb_sv *p0, const cb_sv *p1, const cb_sv *p2) {
    const cb_sv *v[3];
    const cb_sv *t;
    int y, y0, y1;
    v[0] = p0; v[1] = p1; v[2] = p2;
    if (v[0]->y > v[1]->y) { t = v[0]; v[0] = v[1]; v[1] = t; }
    if (v[1]->y > v[2]->y) { t = v[1]; v[1] = v[2]; v[2] = t; }
    if (v[0]->y > v[1]->y) { t = v[0]; v[0] = v[1]; v[1] = t; }
    y0 = (int)ceil(v[0]->y - 0.5); y1 = (int)ceil(v[2]->y - 0.5);
    if (y0 < 0) y0 = 0;
    if (y1 > cb_dos_h) y1 = cb_dos_h;
    for (y = y0; y < y1; y++) {
        double py = y + 0.5, tl, ts;
        cb_sv a, b;
        const cb_sv *lo = v[0], *mid = v[1], *hi = v[2];
        if (py < lo->y || py > hi->y) continue;
        ts = hi->y > lo->y ? (py - lo->y) / (hi->y - lo->y) : 0;
        a = cb_sv_lerp(lo, hi, ts);                      /* the long edge */
        if (py < mid->y) { tl = mid->y > lo->y ? (py - lo->y) / (mid->y - lo->y) : 0; b = cb_sv_lerp(lo, mid, tl); }
        else { tl = hi->y > mid->y ? (py - mid->y) / (hi->y - mid->y) : 0; b = cb_sv_lerp(mid, hi, tl); }
        if (a.x <= b.x) cb_span(y, a.x, b.x, &a, &b); else cb_span(y, b.x, a.x, &b, &a);
    }
}


/* ---- the fast renderer (the default on MS-DOS) ----
   The smooth renderer's per-pixel work (depth test, colour steps, dither) is what an emulated Pentium chokes on
   (0.3 frames a second at 800 x 600 on a Raspberry Pi). This one does almost nothing per pixel: each triangle is
   lit once (its three corners' average, fogged by its depth), turned into the palette's colours with the dither
   worked out once per triangle (a 4 x 4 pattern: one 32-bit word per row), and filled with word stores. The
   triangles are collected during the 3D view, sorted far to near (a radix sort: no depth buffer to clear) and
   drawn at its end (the painter's algorithm: a very long triangle can sort wrongly against what stands on it).
   Lines (Grid, Wire box) are sorted with them. See-through triangles are drawn as every other pixel.
   CBRICKS_3D=smooth in the environment (or -DCB_DOS_3D_SMOOTH) brings the per-pixel renderer back. */
typedef struct { float x[3], y[3]; int ix[3], iy[3]; unsigned w[4]; unsigned short key; unsigned char kind, stipple; } cb_fi;   /* kind 0: a triangle (floats), 1: a line, 3: a triangle in 16.16 */
static cb_fi *cb_fitems = NULL;
static size_t cb_fcap = 0;
#define CB_FAST_MAX 60000

static bool cb_fast_wanted(void) {
#ifdef CB_DOS_3D_SMOOTH
    return false;
#else
    static int pref = -1;
    if (pref < 0) { const char *e = getenv("CBRICKS_3D"); pref = !(e && e[0] == 's'); }
    return pref != 0;
#endif
}

static unsigned char cb_quant16(int rr, int gg, int bb, int t) {   /* the palette's colour for 16.16 colours at a dither threshold */
    int mx, mn;
    rr = rr < 0 ? 0 : (rr > 65536 ? 65536 : rr); gg = gg < 0 ? 0 : (gg > 65536 ? 65536 : gg); bb = bb < 0 ? 0 : (bb > 65536 ? 65536 : bb);
    mx = rr > gg ? (rr > bb ? rr : bb) : (gg > bb ? gg : bb); mn = rr < gg ? (rr < bb ? rr : bb) : (gg < bb ? gg : bb);
    if (mx - mn < 3604) {
        int v = (((rr + gg + bb) / 3) * 39 + t) >> 16;
        return (unsigned char)(216 + (v > 39 ? 39 : v));
    } else {
        int ri = (rr * 5 + t) >> 16, gi = (gg * 5 + t) >> 16, bi = (bb * 5 + t) >> 16;
        return (unsigned char)((ri > 5 ? 5 : ri) * 36 + (gi > 5 ? 5 : gi) * 6 + (bi > 5 ? 5 : bi));
    }
}

/* the four words of a triangle's colour: a 4 x 4 dither pattern, one word per row (a small triangle: one colour) */
static void cb_fast_words(int rr, int gg, int bb, int big, unsigned w[4]) {
    int mx, mn, grey, base, r5, g5, b5, n = big ? 16 : 1, j, i;
    unsigned char q[16];
    rr = rr < 0 ? 0 : (rr > 65536 ? 65536 : rr); gg = gg < 0 ? 0 : (gg > 65536 ? 65536 : gg); bb = bb < 0 ? 0 : (bb > 65536 ? 65536 : bb);
    mx = rr > gg ? (rr > bb ? rr : bb) : (gg > bb ? gg : bb); mn = rr < gg ? (rr < bb ? rr : bb) : (gg < bb ? gg : bb);
    grey = mx - mn < 3604; base = ((rr + gg + bb) / 3) * 39; r5 = rr * 5; g5 = gg * 5; b5 = bb * 5;
    for (j = 0; j < n; j++) {
        int t = big ? cb_thr16[j] : 32768;
        if (grey) { int v = (base + t) >> 16; q[j] = (unsigned char)(216 + (v > 39 ? 39 : v)); }
        else {
            int ri = (r5 + t) >> 16, gi = (g5 + t) >> 16, bi = (b5 + t) >> 16;
            q[j] = (unsigned char)((ri > 5 ? 5 : ri) * 36 + (gi > 5 ? 5 : gi) * 6 + (bi > 5 ? 5 : bi));
        }
    }
    for (i = 0; i < 4; i++)
        w[i] = big ? (unsigned)q[i * 4] | ((unsigned)q[i * 4 + 1] << 8) | ((unsigned)q[i * 4 + 2] << 16) | ((unsigned)q[i * 4 + 3] << 24) : q[0] * 0x01010101u;
}

static cb_fi *cb_fast_item(void) {
    if (cb_fn >= CB_FAST_MAX) return NULL;
    if (cb_fn >= cb_fcap) {
        size_t cap = cb_fcap ? cb_fcap * 2 : 1024;
        cb_fi *n = (cb_fi *)realloc(cb_fitems, cap * sizeof *n);
        if (!n) return NULL;
        cb_fitems = n; cb_fcap = cap;
    }
    return &cb_fitems[cb_fn++];
}

static unsigned short cb_fast_key(double z) {   /* farther = bigger, 1 / 64 of a unit apart */
    double k = z * 64.0;
    return (unsigned short)(k < 0 ? 0 : (k > 65535 ? 65535 : (int)k));
}

static void cb_fast_push_d(const cb_sv *a, const cb_sv *b, const cb_sv *c, int depth);
static cb_sv cb_fast_mid(const cb_sv *a, const cb_sv *b) {   /* the middle of an edge on screen (perspective: 1 / depth is what's linear) */
    cb_sv m = *a;
    m.x = (a->x + b->x) * 0.5; m.y = (a->y + b->y) * 0.5; m.k = (a->k + b->k) * 0.5;
    m.z = cb_3d_ortho ? (a->z + b->z) * 0.5 : (m.k > 1e-9 ? 1.0 / m.k : a->z);
    return m;
}
static void cb_fast_push(const cb_sv *a, const cb_sv *b, const cb_sv *c) { cb_fast_push_d(a, b, c, 0); }

static void cb_fast_push_d(const cb_sv *a, const cb_sv *b, const cb_sv *c, int depth) {
    double minx = a->x, maxx = a->x, miny = a->y, maxy = a->y, r, g, bl, al, z;
    cb_fi *it;
    int rr, gg, bb, i;
    const cb_sv *v[3];
    v[0] = a; v[1] = b; v[2] = c;
    for (i = 1; i < 3; i++) {
        if (v[i]->x < minx) minx = v[i]->x;
        if (v[i]->x > maxx) maxx = v[i]->x;
        if (v[i]->y < miny) miny = v[i]->y;
        if (v[i]->y > maxy) maxy = v[i]->y;
    }
    if (maxx < 0 || minx > cb_dos_w || maxy < 0 || miny > cb_dos_h) return;
    if (depth < 3 && (maxx - minx) * (maxy - miny) > 1200) {   /* a big triangle across a lot of depth sorts wrongly as one: cut it in four */
        double zlo = a->z < b->z ? (a->z < c->z ? a->z : c->z) : (b->z < c->z ? b->z : c->z), zhi = a->z > b->z ? (a->z > c->z ? a->z : c->z) : (b->z > c->z ? b->z : c->z);
        if (zhi > zlo * 1.3 + 0.5) {
            cb_sv ab = cb_fast_mid(a, b), bc = cb_fast_mid(b, c), ca = cb_fast_mid(c, a);
            cb_fast_push_d(a, &ab, &ca, depth + 1); cb_fast_push_d(&ab, b, &bc, depth + 1);
            cb_fast_push_d(&ca, &bc, c, depth + 1); cb_fast_push_d(&ab, &bc, &ca, depth + 1);
            return;
        }
    }
    al = (a->a + b->a + c->a) / 3.0;
    if (al < 0.5) return;
    r = (a->r + b->r + c->r) / 3.0; g = (a->g + b->g + c->g) / 3.0; bl = (a->b + b->b + c->b) / 3.0;
    z = (a->z + b->z + c->z) / 3.0;
    if (cb_fog_density > 0) {
        int li = (int)(z * 16.0);
        double seen = cb_fog_lut[li < 0 ? 0 : (li > 4095 ? 4095 : li)];
        r = cb_fog_col[0] + (r - cb_fog_col[0]) * seen; g = cb_fog_col[1] + (g - cb_fog_col[1]) * seen; bl = cb_fog_col[2] + (bl - cb_fog_col[2]) * seen;
    }
    it = cb_fast_item();
    if (!it) return;
    for (i = 0; i < 3; i++) { it->x[i] = (float)v[i]->x; it->y[i] = (float)v[i]->y; }
    it->kind = 0; it->stipple = al < 0.98; it->key = cb_fast_key(z);
    rr = (int)(r * 65536.0); gg = (int)(g * 65536.0); bb = (int)(bl * 65536.0);
    cb_fast_words(rr, gg, bb, (maxx - minx) * (maxy - miny) > 40, it->w);
}

static void cb_fast_line(const cb_sv *a, const cb_sv *b, unsigned char q) {
    cb_fi *it = cb_fast_item();
    if (!it) return;
    it->x[0] = (float)a->x; it->y[0] = (float)a->y; it->x[1] = (float)b->x; it->y[1] = (float)b->y;
    it->kind = 1; it->stipple = 0; it->key = cb_fast_key((a->z + b->z) / 2.0 - 0.1);
    it->w[0] = q;
}

static void cb_fast_row(int y, int x0, int x1, unsigned w) {
    unsigned char *d = cb_dos_back + (size_t)y * (size_t)cb_dos_w + (size_t)x0;
    int n = x1 - x0;
    while (n > 0 && (x0 & 3)) { *d++ = (unsigned char)(w >> (8 * (x0 & 3))); x0++; n--; }
    for (; n >= 4; n -= 4, d += 4) *(unsigned *)d = w;
    for (x0 = 0; n > 0; n--, x0++) *d++ = (unsigned char)(w >> (8 * x0));
}

static int cb_fast_clampx(double x) { return x <= 0 ? 0 : (x >= cb_dos_w ? cb_dos_w : (int)(x + 0.5)); }

static void cb_fast_tri_slow(const cb_fi *it) {
    double vx[3], vy[3], t;
    int i, j, y, y0, y1;
    double sl, s1, s2, xa, xb;
    for (i = 0; i < 3; i++) { vx[i] = it->x[i]; vy[i] = it->y[i]; }
    for (i = 0; i < 2; i++)
        for (j = 0; j < 2 - i; j++)
            if (vy[j] > vy[j + 1]) { t = vy[j]; vy[j] = vy[j + 1]; vy[j + 1] = t; t = vx[j]; vx[j] = vx[j + 1]; vx[j + 1] = t; }
    y0 = vy[0] <= 0 ? 0 : (int)(vy[0] + 0.5);
    y1 = vy[2] >= cb_dos_h ? cb_dos_h : (vy[2] <= 0 ? 0 : (int)(vy[2] + 0.5));
    if (y1 <= y0) return;
    sl = vy[2] > vy[0] ? (vx[2] - vx[0]) / (vy[2] - vy[0]) : 0;
    s1 = vy[1] > vy[0] ? (vx[1] - vx[0]) / (vy[1] - vy[0]) : 0;
    s2 = vy[2] > vy[1] ? (vx[2] - vx[1]) / (vy[2] - vy[1]) : 0;
    xa = vx[0] + sl * (y0 + 0.5 - vy[0]);
    for (y = y0; y < y1; y++, xa += sl) {
        double py = y + 0.5;
        int ix0, ix1;
        xb = py < vy[1] ? vx[0] + s1 * (py - vy[0]) : vx[1] + s2 * (py - vy[1]);
        if (xa <= xb) { ix0 = cb_fast_clampx(xa); ix1 = cb_fast_clampx(xb); }
        else { ix0 = cb_fast_clampx(xb); ix1 = cb_fast_clampx(xa); }
        if (ix1 <= ix0) continue;
        if (it->stipple) {
            unsigned w = it->w[y & 3];
            unsigned char *d = cb_dos_back + (size_t)y * (size_t)cb_dos_w;
            int x;
            for (x = ix0; x < ix1; x++) if (((x + y) & 1) == 0) d[x] = (unsigned char)(w >> (8 * (x & 3)));
        } else
            cb_fast_row(y, ix0, ix1, it->w[y & 3]);
    }
}

/* the same in whole numbers (16.16 edges: no floating point per row), when the corners are within reach of them */
static void cb_fast_tri(const cb_fi *it) {
    double vx[3], vy[3], t, sl, s1, s2;
    int i, j, y, y0, y1, ym, xa, xb, da, db, db2;
    for (i = 0; i < 3; i++) { vx[i] = it->x[i]; vy[i] = it->y[i]; if (vx[i] < -30000 || vx[i] > 30000) { cb_fast_tri_slow(it); return; } }
    for (i = 0; i < 2; i++)
        for (j = 0; j < 2 - i; j++)
            if (vy[j] > vy[j + 1]) { t = vy[j]; vy[j] = vy[j + 1]; vy[j + 1] = t; t = vx[j]; vx[j] = vx[j + 1]; vx[j + 1] = t; }
    y0 = vy[0] <= 0 ? 0 : (int)(vy[0] + 0.5);
    y1 = vy[2] >= cb_dos_h ? cb_dos_h : (vy[2] <= 0 ? 0 : (int)(vy[2] + 0.5));
    if (y1 <= y0) return;
    sl = vy[2] > vy[0] ? (vx[2] - vx[0]) / (vy[2] - vy[0]) : 0;
    s1 = vy[1] > vy[0] ? (vx[1] - vx[0]) / (vy[1] - vy[0]) : 0;
    s2 = vy[2] > vy[1] ? (vx[2] - vx[1]) / (vy[2] - vy[1]) : 0;
    if (fabs(sl) > 30000 || fabs(s1) > 30000 || fabs(s2) > 30000) { cb_fast_tri_slow(it); return; }
    ym = vy[1] <= 0 ? 0 : (int)(vy[1] + 0.5);
    if (ym < y0) ym = y0;
    if (ym > y1) ym = y1;
    xa = (int)((vx[0] + sl * (y0 + 0.5 - vy[0])) * 65536.0); da = (int)(sl * 65536.0);
    xb = (int)((vx[0] + s1 * (y0 + 0.5 - vy[0])) * 65536.0); db = (int)(s1 * 65536.0);
    db2 = (int)(s2 * 65536.0);
    for (y = y0; y < y1; y++, xa += da, xb += db) {
        int ix0, ix1;
        if (y == ym) { xb = (int)((vx[1] + s2 * (y + 0.5 - vy[1])) * 65536.0); db = db2; }
        if (xa <= xb) { ix0 = (xa + 32768) >> 16; ix1 = (xb + 32768) >> 16; }
        else { ix0 = (xb + 32768) >> 16; ix1 = (xa + 32768) >> 16; }
        if (ix0 < 0) ix0 = 0;
        if (ix1 > cb_dos_w) ix1 = cb_dos_w;
        if (ix1 <= ix0) continue;
        if (it->stipple) {
            unsigned w = it->w[y & 3];
            unsigned char *d = cb_dos_back + (size_t)y * (size_t)cb_dos_w;
            int x;
            for (x = ix0; x < ix1; x++) if (((x + y) & 1) == 0) d[x] = (unsigned char)(w >> (8 * (x & 3)));
        } else
            cb_fast_row(y, ix0, ix1, it->w[y & 3]);
    }
}

/* ---- the same in whole numbers (16.16): the emulated floating point is what costs; 32 x 32 -> 64 bit products and
   the CPU's own divide are single instructions there ---- */
typedef long long cb_ll;
#define CB_FXM(a, b) ((int)(((cb_ll)(a) * (cb_ll)(b)) >> 16))
static int cb_fxdiv(int a, int b) {   /* a / b in 16.16; the quotient must fit (|a| < 32768 * |b|) */
    int q, rem;
    __asm__("idivl %4" : "=a"(q), "=d"(rem) : "a"((int)((unsigned)a << 16)), "d"(a >> 16), "r"(b) : "cc");
    (void)rem;
    return q;
}
typedef struct { int x, y, z; } cb_fxv;   /* a corner: the screen position and the view depth, 16.16 */
#define CB_FX_REACH (16000 << 16)           /* corners farther off the screen than this go the floating way */

static void cb_fast_push_fx(const cb_fxv *a, const cb_fxv *b, const cb_fxv *c, int rr, int gg, int bb, int al, int depth) {
    int minx = a->x, maxx = a->x, miny = a->y, maxy = a->y, zlo = a->z, zhi = a->z;
    cb_ll area;
    cb_fi *it;
    if (b->x < minx) minx = b->x;
    if (c->x < minx) minx = c->x;
    if (b->x > maxx) maxx = b->x;
    if (c->x > maxx) maxx = c->x;
    if (b->y < miny) miny = b->y;
    if (c->y < miny) miny = c->y;
    if (b->y > maxy) maxy = b->y;
    if (c->y > maxy) maxy = c->y;
    if (maxx < 0 || minx > (cb_dos_w << 16) || maxy < 0 || miny > (cb_dos_h << 16)) return;
    area = (cb_ll)((maxx - minx) >> 16) * (cb_ll)((maxy - miny) >> 16);
    if (b->z < zlo) zlo = b->z;
    if (c->z < zlo) zlo = c->z;
    if (b->z > zhi) zhi = b->z;
    if (c->z > zhi) zhi = c->z;
    if (depth < 3 && area > 1200 && (cb_ll)zhi * 10 > (cb_ll)zlo * 13 + 327680) {   /* a big triangle across a lot of depth sorts wrongly as one: cut it in four */
        cb_fxv ab, bc, ca;
        ab.x = a->x + ((b->x - a->x) >> 1); ab.y = a->y + ((b->y - a->y) >> 1); ab.z = a->z + ((b->z - a->z) >> 1);
        bc.x = b->x + ((c->x - b->x) >> 1); bc.y = b->y + ((c->y - b->y) >> 1); bc.z = b->z + ((c->z - b->z) >> 1);
        ca.x = c->x + ((a->x - c->x) >> 1); ca.y = c->y + ((a->y - c->y) >> 1); ca.z = c->z + ((a->z - c->z) >> 1);
        cb_fast_push_fx(a, &ab, &ca, rr, gg, bb, al, depth + 1); cb_fast_push_fx(&ab, b, &bc, rr, gg, bb, al, depth + 1);
        cb_fast_push_fx(&ca, &bc, c, rr, gg, bb, al, depth + 1); cb_fast_push_fx(&ab, &bc, &ca, rr, gg, bb, al, depth + 1);
        return;
    }
    if (al < 32768) return;
    it = cb_fast_item();
    if (!it) return;
    it->ix[0] = a->x; it->ix[1] = b->x; it->ix[2] = c->x; it->iy[0] = a->y; it->iy[1] = b->y; it->iy[2] = c->y;
    it->kind = 3; it->stipple = al < 64225;
    {
        int key = (int)(((((cb_ll)a->z + b->z + c->z) * 21845) >> 16) >> 10);
        it->key = (unsigned short)(key < 0 ? 0 : (key > 65535 ? 65535 : key));
    }
    cb_fast_words(rr, gg, bb, area > 40, it->w);
}

static void cb_fast_tri_fx(const cb_fi *it) {
    int vx[3], vy[3], i, j, t, y, y0, y1, ym, xa, xb, da, db, sl, s1, s2, yc, dy, dx;
    for (i = 0; i < 3; i++) { vx[i] = it->ix[i]; vy[i] = it->iy[i]; }
    for (i = 0; i < 2; i++)
        for (j = 0; j < 2 - i; j++)
            if (vy[j] > vy[j + 1]) { t = vy[j]; vy[j] = vy[j + 1]; vy[j + 1] = t; t = vx[j]; vx[j] = vx[j + 1]; vx[j + 1] = t; }
    y0 = (vy[0] + 32768) >> 16; if (y0 < 0) y0 = 0;
    y1 = (vy[2] + 32768) >> 16; if (y1 > cb_dos_h) y1 = cb_dos_h;
    if (y1 <= y0) return;
    ym = (vy[1] + 32768) >> 16;
    if (ym < y0) ym = y0;
    if (ym > y1) ym = y1;
    dy = vy[2] - vy[0]; dx = vx[2] - vx[0];
    sl = 0; s1 = 0; s2 = 0;
    if (dy > 0) { if ((cb_ll)(dx < 0 ? -dx : dx) >= ((cb_ll)dy << 15)) goto slow; sl = cb_fxdiv(dx, dy); }
    dy = vy[1] - vy[0]; dx = vx[1] - vx[0];
    if (dy > 0) { if ((cb_ll)(dx < 0 ? -dx : dx) >= ((cb_ll)dy << 15)) goto slow; s1 = cb_fxdiv(dx, dy); }
    dy = vy[2] - vy[1]; dx = vx[2] - vx[1];
    if (dy > 0) { if ((cb_ll)(dx < 0 ? -dx : dx) >= ((cb_ll)dy << 15)) goto slow; s2 = cb_fxdiv(dx, dy); }
    yc = (y0 << 16) + 32768 - vy[0];
    xa = vx[0] + CB_FXM(sl, yc); da = sl;
    xb = vx[0] + CB_FXM(s1, yc); db = s1;
    for (y = y0; y < y1; y++, xa += da, xb += db) {
        int ix0, ix1;
        if (y == ym) { xb = vx[1] + CB_FXM(s2, (y << 16) + 32768 - vy[1]); db = s2; }
        if (xa <= xb) { ix0 = (xa + 32768) >> 16; ix1 = (xb + 32768) >> 16; }
        else { ix0 = (xb + 32768) >> 16; ix1 = (xa + 32768) >> 16; }
        if (ix0 < 0) ix0 = 0;
        if (ix1 > cb_dos_w) ix1 = cb_dos_w;
        if (ix1 <= ix0) continue;
        if (it->stipple) {
            unsigned w = it->w[y & 3];
            unsigned char *d = cb_dos_back + (size_t)y * (size_t)cb_dos_w;
            int x;
            for (x = ix0; x < ix1; x++) if (((x + y) & 1) == 0) d[x] = (unsigned char)(w >> (8 * (x & 3)));
        } else {
            unsigned w = it->w[y & 3];
            unsigned char *d = cb_dos_back + (size_t)y * (size_t)cb_dos_w + (size_t)ix0;
            int n = ix1 - ix0, head = (4 - (ix0 & 3)) & 3, k;
            if (head > n) head = n;
            for (k = 0; k < head; k++) *d++ = (unsigned char)(w >> (8 * ((ix0 + k) & 3)));
            for (n -= head; n >= 4; n -= 4, d += 4) *(unsigned *)d = w;
            for (k = 0; k < n; k++) *d++ = (unsigned char)(w >> (8 * k));
        }
    }
    return;
slow:   /* (an edge nearly flat across a wide span) */
    {
        cb_fi f = *it;
        for (i = 0; i < 3; i++) { f.x[i] = (float)(it->ix[i] / 65536.0); f.y[i] = (float)(it->iy[i] / 65536.0); }
        cb_fast_tri_slow(&f);
    }
}

static void cb_fast_draw_line(const cb_fi *it) {
    int x0 = (int)floor(it->x[0]), y0 = (int)floor(it->y[0]), x1 = (int)floor(it->x[1]), y1 = (int)floor(it->y[1]);
    int dx = abs(x1 - x0), dy = -abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy, steps = 0;
    unsigned char q = (unsigned char)it->w[0];
    for (;;) {
        int e2;
        if (x0 >= 0 && y0 >= 0 && x0 < cb_dos_w && y0 < cb_dos_h) cb_dos_back[(size_t)y0 * (size_t)cb_dos_w + (size_t)x0] = q;
        if ((x0 == x1 && y0 == y1) || steps > 5000) break;
        e2 = 2 * err; steps++;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

static void cb_fast_flush(void) {
    size_t n = cb_fn, i;
    unsigned *a, *b;
    unsigned cnt[256];
    int pass;
    if (n == 0) return;
    a = (unsigned *)malloc(n * sizeof *a); b = (unsigned *)malloc(n * sizeof *b);
    if (!a || !b) { free(a); free(b); cb_fn = 0; return; }
    for (i = 0; i < n; i++) a[i] = (unsigned)i;
    for (pass = 0; pass < 2; pass++) {   /* least significant byte first: the order stays stable */
        unsigned *t;
        int sh = pass * 8, k;
        memset(cnt, 0, sizeof cnt);
        for (i = 0; i < n; i++) cnt[(cb_fitems[a[i]].key >> sh) & 255]++;
        { unsigned sum = 0; for (k = 0; k < 256; k++) { unsigned c = cnt[k]; cnt[k] = sum; sum += c; } }
        for (i = 0; i < n; i++) b[cnt[(cb_fitems[a[i]].key >> sh) & 255]++] = a[i];
        t = a; a = b; b = t;
    }
    for (i = n; i-- > 0;) {   /* far to near */
        const cb_fi *it = &cb_fitems[a[i]];
        if (it->kind == 3) cb_fast_tri_fx(it); else if (it->kind) cb_fast_draw_line(it); else cb_fast_tri(it);
    }
    free(a); free(b);
    cb_fn = 0;
}

/* a view-space vertex (with its lit colour) -> the screen */
static cb_sv cb_project(Vector3 v, float r, float g, float b, float a) {
    cb_sv s;
    double z = -v.z;
    if (cb_3d_ortho) {
        s.x = (v.x / (cb_3d_top * cb_3d_aspect) * 0.5 + 0.5) * cb_dos_w;
        s.y = (1.0 - (v.y / cb_3d_top * 0.5 + 0.5)) * cb_dos_h;
        s.k = 1.0 - z / CB_ORTHO_FAR;
    } else {
        double rz = 1.0 / z;
        s.x = v.x * rz * cb_pk_x + cb_pk_cx;
        s.y = cb_pk_cy - v.y * rz * cb_pk_y;
        s.k = rz;
    }
    s.z = z; s.r = r; s.g = g; s.b = b; s.a = a;
    return s;
}

typedef struct { Vector3 v; float r, g, b, a; } cb_cv;   /* a clipped-space (view) vertex with its colour */

/* clip a triangle (view space) at the near plane and draw what's in front */
static void cb_tri_draw(const cb_cv *c0, const cb_cv *c1, const cb_cv *c2) {
    const cb_cv *in[3];
    cb_cv out[4];
    int n = 0, i;
    in[0] = c0; in[1] = c1; in[2] = c2;
    for (i = 0; i < 3; i++) {
        const cb_cv *a = in[i], *b = in[(i + 1) % 3];
        bool ain = -a->v.z >= CB_NEAR, bin = -b->v.z >= CB_NEAR;
        if (ain) out[n++] = *a;
        if (ain != bin) {
            double t = (-CB_NEAR - a->v.z) / (b->v.z - a->v.z);
            cb_cv m;
            m.v = cb_v3(a->v.x + (b->v.x - a->v.x) * t, a->v.y + (b->v.y - a->v.y) * t, -CB_NEAR);
            m.r = (float)(a->r + (b->r - a->r) * t); m.g = (float)(a->g + (b->g - a->g) * t); m.b = (float)(a->b + (b->b - a->b) * t); m.a = (float)(a->a + (b->a - a->a) * t);
            out[n++] = m;
        }
    }
    if (n < 3 || (!cb_3d_fast && !cb_zbuf))
        return;
    {
        cb_sv s[4];
        for (i = 0; i < n; i++) s[i] = cb_project(out[i].v, out[i].r, out[i].g, out[i].b, out[i].a);
        if (cb_3d_fast) {
            cb_fast_push(&s[0], &s[1], &s[2]);
            if (n == 4) cb_fast_push(&s[0], &s[2], &s[3]);
            return;
        }
        cb_tri_screen(&s[0], &s[1], &s[2]);
        if (n == 4) cb_tri_screen(&s[0], &s[2], &s[3]);
    }
}

/* ---- triangles with a normal and a colour per corner: what shapes and meshes are drawn from ---- */
static void cb_light_rgb(Vector3 n, float cr, float cg, float cb_, float ca, float *out_r, float *out_g, float *out_b, float *out_a) {
    double d = -(n.x * cb_sun.x + n.y * cb_sun.y + n.z * cb_sun.z), lr, lg, lb;
    if (d < 0) d = 0;
    lr = cb_amb * cb_amb_col[0] + (1.0 - cb_amb) * d * cb_sun_col[0];
    lg = cb_amb * cb_amb_col[1] + (1.0 - cb_amb) * d * cb_sun_col[1];
    lb = cb_amb * cb_amb_col[2] + (1.0 - cb_amb) * d * cb_sun_col[2];
    *out_r = (float)(cr * lr); *out_g = (float)(cg * lg); *out_b = (float)(cb_ * lb); *out_a = ca;
}

/* the normal matrix of `m`: the inverse transpose of its upper 3 x 3 (so a scaled shape keeps its normals true) */
static void cb_normal_matrix(const cb_m4 *m, double out[9]) {
    double a = m->m[0], b = m->m[4], c = m->m[8], d = m->m[1], e = m->m[5], f = m->m[9], g = m->m[2], h = m->m[6], i = m->m[10];
    double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g, det = a * A + b * B + c * C, k;
    if (fabs(det) < 1e-12) det = 1e-12;
    k = 1.0 / det;
    /* (the cofactor matrix over the determinant is the inverse transpose) */
    out[0] = A * k; out[3] = B * k; out[6] = C * k;
    out[1] = -(b * i - c * h) * k; out[4] = (a * i - c * g) * k; out[7] = -(a * h - b * g) * k;
    out[2] = (b * f - c * e) * k; out[5] = -(a * f - c * d) * k; out[8] = (a * e - b * d) * k;
}

/* a triangle list (3 corners each) under `model` (on top of the current matrix): positions, normals, colours (0..255 + alpha) */
/* a mesh's vertices are shared by its triangles: each is moved into view and lit once per draw (as if seen from the
   front), the triangles pick them up by index (floating point is what's slow on an emulated PC) */
static cb_cv *cb_vcache = NULL;
static unsigned *cb_vstamp = NULL;
static size_t cb_vcap = 0;
static unsigned cb_vtick = 0;

static void cb_vertex_lit(const float *nrm, const unsigned char *col, int vi, const double nm[9], cb_rgba tint, bool front, cb_cv *c) {
    double nx = nrm[vi * 3], ny = nrm[vi * 3 + 1], nz = nrm[vi * 3 + 2];
    Vector3 n = cb_v3(nm[0] * nx + nm[3] * ny + nm[6] * nz, nm[1] * nx + nm[4] * ny + nm[7] * nz, nm[2] * nx + nm[5] * ny + nm[8] * nz);
    n = cb_v3_normalize(n);
    if (!front) n = cb_v3(-n.x, -n.y, -n.z);
    cb_light_rgb(n, col[vi * 4] * tint.r / 65025.0f, col[vi * 4 + 1] * tint.g / 65025.0f, col[vi * 4 + 2] * tint.b / 65025.0f, col[vi * 4 + 3] * tint.a / 65025.0f, &c->r, &c->g, &c->b, &c->a);
}

/* the fast renderer's triangles: a mesh's corners are moved into view once per draw; each triangle is lit once from its
   own (view space) normal, which is also what the back-face test needs. A draw whose bounding sphere is behind the eye
   or off the screen costs nothing more than the test. Most triangles go through cb_draw_tris_fx (whole numbers, see
   cb_fast_push_fx); the floating-point version is for what doesn't fit it: a draw far from the origin or very large,
   orthographic views, and triangles that cross the near plane. */
static int *cb_vfx = NULL;   /* per vertex: its view-space x, y, z in 16.16 (stamped like cb_vcache) */
static bool cb_vcache_room(int vi) {
    if ((size_t)vi >= cb_vcap) {
        size_t cap = cb_vcap ? cb_vcap : 256;
        cb_cv *nc;
        unsigned *ns;
        int *nf;
        while (cap <= (size_t)vi) cap *= 2;
        nc = (cb_cv *)realloc(cb_vcache, cap * sizeof *nc);
        ns = (unsigned *)realloc(cb_vstamp, cap * sizeof *ns);
        nf = (int *)realloc(cb_vfx, cap * 3 * sizeof *nf);
        if (nc) cb_vcache = nc;
        if (ns) cb_vstamp = ns;
        if (nf) cb_vfx = nf;
        if (!nc || !ns || !nf) return false;
        memset(cb_vstamp + cb_vcap, 0, (cap - cb_vcap) * sizeof *ns);
        cb_vcap = cap;
    }
    return true;
}

static void cb_draw_tris_fast(const float *pos, const unsigned char *col, const unsigned short *idx, int tri_count, const cb_m4 *mv, const Vector3 *sv, cb_rgba tint, bool both) {
    double ar = cb_amb * cb_amb_col[0], ag = cb_amb * cb_amb_col[1], ab = cb_amb * cb_amb_col[2];
    double sr = (1.0 - cb_amb) * cb_sun_col[0], sg = (1.0 - cb_amb) * cb_sun_col[1], sb = (1.0 - cb_amb) * cb_sun_col[2];
    double tr = tint.r / (3.0 * 65025.0), tg = tint.g / (3.0 * 65025.0), tb = tint.b / (3.0 * 65025.0), ta = tint.a / (3.0 * 65025.0);
    int t, k;
    if (cb_fog_dirty) cb_fog_build();
    if (++cb_vtick == 0) { memset(cb_vstamp, 0, cb_vcap * sizeof *cb_vstamp); cb_vtick = 1; }
    for (t = 0; t < tri_count; t++) {
        cb_cv c[3];
        int vi[3];
        Vector3 nv;
        double facing, d, len, lr, lg, lb;
        float cr, cg, cb2, ca;
        for (k = 0; k < 3; k++) {
            vi[k] = idx ? idx[t * 3 + k] : t * 3 + k;
            if (!cb_vcache_room(vi[k])) return;
            if (cb_vstamp[vi[k]] != cb_vtick) {
                cb_vcache[vi[k]].v = cb_m4_pt(mv, cb_v3(pos[vi[k] * 3], pos[vi[k] * 3 + 1], pos[vi[k] * 3 + 2]));
                cb_vstamp[vi[k]] = cb_vtick;
            }
            c[k].v = cb_vcache[vi[k]].v;
        }
        nv = cb_v3_cross(cb_v3_sub(c[1].v, c[0].v), cb_v3_sub(c[2].v, c[0].v));
        facing = cb_3d_ortho ? nv.z : -(nv.x * c[0].v.x + nv.y * c[0].v.y + nv.z * c[0].v.z);   /* > 0: its front faces the eye */
        if (facing <= 0 && !both)
            continue;
        if (c[0].v.z > -CB_NEAR && c[1].v.z > -CB_NEAR && c[2].v.z > -CB_NEAR)
            continue;   /* wholly behind the eye */
        len = sqrt(nv.x * nv.x + nv.y * nv.y + nv.z * nv.z);
        d = len > 1e-12 ? -(nv.x * sv->x + nv.y * sv->y + nv.z * sv->z) / len : 0;
        if (facing <= 0) d = -d;
        if (d < 0) d = 0;
        lr = ar + d * sr; lg = ag + d * sg; lb = ab + d * sb;
        {
            const unsigned char *p0 = col + vi[0] * 4, *p1 = col + vi[1] * 4, *p2 = col + vi[2] * 4;
            cr = (float)((p0[0] + p1[0] + p2[0]) * tr * lr); cg = (float)((p0[1] + p1[1] + p2[1]) * tg * lg);
            cb2 = (float)((p0[2] + p1[2] + p2[2]) * tb * lb); ca = (float)((p0[3] + p1[3] + p2[3]) * ta);
        }
        for (k = 0; k < 3; k++) { c[k].r = cr; c[k].g = cg; c[k].b = cb2; c[k].a = ca; }
        cb_tri_draw(&c[0], &c[1], &c[2]);
    }
}

/* a triangle (corners as 16.16 view-space numbers) the floating-point way: near-plane clipping, wild coordinates */
static void cb_fx_float_tri(const int *a, const int *b, const int *c, int rr, int gg, int bb, int al) {
    cb_cv v[3];
    const int *p[3];
    int k;
    p[0] = a; p[1] = b; p[2] = c;
    for (k = 0; k < 3; k++) {
        v[k].v = cb_v3(p[k][0] / 65536.0, p[k][1] / 65536.0, p[k][2] / 65536.0);
        v[k].r = (float)(rr / 65536.0); v[k].g = (float)(gg / 65536.0); v[k].b = (float)(bb / 65536.0); v[k].a = (float)(al / 65536.0);
    }
    cb_tri_draw(&v[0], &v[1], &v[2]);
}

static void cb_draw_tris_fx(const int *fpos, const unsigned char *col, const unsigned short *idx, int tri_count, const cb_m4 *mv, const Vector3 *svf, cb_rgba tint, bool both) {
    int mm[12], sv[3], ar[3], sr[3], pkx = (int)(cb_pk_x * 65536.0), pky = (int)(cb_pk_y * 65536.0), cx = (int)(cb_pk_cx * 65536.0), cy = (int)(cb_pk_cy * 65536.0);
    int t, k;
    static const int pick[12] = {0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14};
    for (k = 0; k < 12; k++) mm[k] = (int)(mv->m[pick[k]] * 65536.0);
    sv[0] = (int)(svf->x * 65536.0); sv[1] = (int)(svf->y * 65536.0); sv[2] = (int)(svf->z * 65536.0);
    for (k = 0; k < 3; k++) { ar[k] = (int)(cb_amb * cb_amb_col[k] * 65536.0); sr[k] = (int)((1.0 - cb_amb) * cb_sun_col[k] * 65536.0); }
    if (cb_fog_dirty) cb_fog_build();
    if (++cb_vtick == 0) { memset(cb_vstamp, 0, cb_vcap * sizeof *cb_vstamp); cb_vtick = 1; }
    for (t = 0; t < tri_count; t++) {
        int vi[3];
        const int *a, *b, *c;
        int e1x, e1y, e1z, e2x, e2y, e2z, n0, n1, n2, sh = 0, d16, rr, gg, bb, al, front, lr, lg, lb, c16;
        cb_ll nx, ny, nz, am, facing, dotv;
        unsigned R, G, B, A;
        const unsigned char *p0, *p1, *p2;
        for (k = 0; k < 3; k++) {
            vi[k] = idx ? idx[t * 3 + k] : t * 3 + k;
            if (!cb_vcache_room(vi[k])) return;
            if (cb_vstamp[vi[k]] != cb_vtick) {
                const int *p = fpos + vi[k] * 3;
                int *o = cb_vfx + vi[k] * 3;
                o[0] = (int)(((cb_ll)mm[0] * p[0] + (cb_ll)mm[1] * p[1] + (cb_ll)mm[2] * p[2]) >> 16) + mm[3];
                o[1] = (int)(((cb_ll)mm[4] * p[0] + (cb_ll)mm[5] * p[1] + (cb_ll)mm[6] * p[2]) >> 16) + mm[7];
                o[2] = (int)(((cb_ll)mm[8] * p[0] + (cb_ll)mm[9] * p[1] + (cb_ll)mm[10] * p[2]) >> 16) + mm[11];
                cb_vstamp[vi[k]] = cb_vtick;
            }
        }
        a = cb_vfx + vi[0] * 3; b = cb_vfx + vi[1] * 3; c = cb_vfx + vi[2] * 3;
        e1x = b[0] - a[0]; e1y = b[1] - a[1]; e1z = b[2] - a[2];
        e2x = c[0] - a[0]; e2y = c[1] - a[1]; e2z = c[2] - a[2];
        nx = (cb_ll)e1y * e2z - (cb_ll)e1z * e2y; ny = (cb_ll)e1z * e2x - (cb_ll)e1x * e2z; nz = (cb_ll)e1x * e2y - (cb_ll)e1y * e2x;
        am = nx < 0 ? -nx : nx;
        if ((ny < 0 ? -ny : ny) > am) am = ny < 0 ? -ny : ny;
        if ((nz < 0 ? -nz : nz) > am) am = nz < 0 ? -nz : nz;
        if (am == 0) continue;
        while (am > 0x3FFFFFFFLL) { am >>= 3; sh += 3; }
        n0 = (int)(nx >> sh); n1 = (int)(ny >> sh); n2 = (int)(nz >> sh);
        facing = -((cb_ll)n0 * a[0] + (cb_ll)n1 * a[1] + (cb_ll)n2 * a[2]);   /* > 0: its front faces the eye */
        if (facing <= 0 && !both) continue;
        front = (a[2] < -3277) + (b[2] < -3277) + (c[2] < -3277);   /* corners in front of the near plane (0.05) */
        if (front == 0) continue;
        {
            cb_ll sq = (cb_ll)n0 * n0 + (cb_ll)n1 * n1 + (cb_ll)n2 * n2;
            dotv = -((cb_ll)n0 * sv[0] + (cb_ll)n1 * sv[1] + (cb_ll)n2 * sv[2]);
            d16 = sq > 0 ? (int)((double)dotv / sqrt((double)sq)) : 0;
        }
        if (facing <= 0) d16 = -d16;
        if (d16 < 0) d16 = 0;
        if (d16 > 65536) d16 = 65536;
        lr = ar[0] + CB_FXM(d16, sr[0]); lg = ar[1] + CB_FXM(d16, sr[1]); lb = ar[2] + CB_FXM(d16, sr[2]);
        p0 = col + vi[0] * 4; p1 = col + vi[1] * 4; p2 = col + vi[2] * 4;
        R = (unsigned)(p0[0] + p1[0] + p2[0]) * (unsigned)tint.r; G = (unsigned)(p0[1] + p1[1] + p2[1]) * (unsigned)tint.g;
        B = (unsigned)(p0[2] + p1[2] + p2[2]) * (unsigned)tint.b; A = (unsigned)(p0[3] + p1[3] + p2[3]) * (unsigned)tint.a;
        c16 = (int)((R * 22017u) >> 16); rr = CB_FXM(c16, lr);   /* (22017 / 65536 = 65536 / (3 * 255 * 255)) */
        c16 = (int)((G * 22017u) >> 16); gg = CB_FXM(c16, lg);
        c16 = (int)((B * 22017u) >> 16); bb = CB_FXM(c16, lb);
        al = (int)((A * 22017u) >> 16);
        if (cb_fog_density > 0) {
            int li = (int)(((cb_ll)(-a[2]) - b[2] - c[2]) / 3) >> 12, seen;
            seen = cb_fog_lut16[li < 0 ? 0 : (li > 4095 ? 4095 : li)];
            rr = cb_fog_col16[0] + CB_FXM(rr - cb_fog_col16[0], seen); gg = cb_fog_col16[1] + CB_FXM(gg - cb_fog_col16[1], seen); bb = cb_fog_col16[2] + CB_FXM(bb - cb_fog_col16[2], seen);
        }
        if (front < 3) { cb_fx_float_tri(a, b, c, rr, gg, bb, al); continue; }
        {
            cb_fxv s[3];
            const int *pv[3];
            bool wild = false;
            pv[0] = a; pv[1] = b; pv[2] = c;
            for (k = 0; k < 3; k++) {
                int zd = -pv[k][2], ax = pv[k][0] < 0 ? -pv[k][0] : pv[k][0], ay = pv[k][1] < 0 ? -pv[k][1] : pv[k][1];
                cb_ll sx, sy;
                if ((ax >> 14) >= zd || (ay >> 14) >= zd) { wild = true; break; }
                sx = (cb_ll)cx + (((cb_ll)cb_fxdiv(pv[k][0], zd) * pkx) >> 16);
                sy = (cb_ll)cy - (((cb_ll)cb_fxdiv(pv[k][1], zd) * pky) >> 16);
                if (sx > CB_FX_REACH || sx < -CB_FX_REACH || sy > CB_FX_REACH || sy < -CB_FX_REACH) { wild = true; break; }
                s[k].x = (int)sx; s[k].y = (int)sy; s[k].z = zd;
            }
            if (wild) { cb_fx_float_tri(a, b, c, rr, gg, bb, al); continue; }
            cb_fast_push_fx(&s[0], &s[1], &s[2], rr, gg, bb, al, 0);
        }
    }
}

/* a draw in the fast renderer: bounding-sphere test first, then the whole-number or the floating-point triangles */
static void cb_draw_fast(const float *pos, const int *fpos, const float *bound, const unsigned char *col, const unsigned short *idx, int tri_count, const cb_m4 *model, cb_rgba tint, bool both) {
    cb_m4 mv = cb_m4_mul_aff(cb_vc_get(), model);
    Vector3 c = cb_m4_pt(&mv, cb_v3(bound[0], bound[1], bound[2])), sv;
    double s0 = mv.m[0] * mv.m[0] + mv.m[1] * mv.m[1] + mv.m[2] * mv.m[2], s1 = mv.m[4] * mv.m[4] + mv.m[5] * mv.m[5] + mv.m[6] * mv.m[6], s2 = mv.m[8] * mv.m[8] + mv.m[9] * mv.m[9] + mv.m[10] * mv.m[10];
    double rs, zc = -c.z;
    if (s1 > s0) s0 = s1;
    if (s2 > s0) s0 = s2;
    rs = bound[3] * sqrt(s0);
    if (zc + rs < CB_NEAR) return;   /* behind the eye */
    if (cb_3d_ortho) {
        if (fabs(c.x) - rs > cb_3d_top * cb_3d_aspect || fabs(c.y) - rs > cb_3d_top) return;
    } else {
        if (c.x - cb_fr_tx * zc > rs * cb_fr_hx || -c.x - cb_fr_tx * zc > rs * cb_fr_hx) return;   /* off to a side */
        if (c.y - cb_fr_ty * zc > rs * cb_fr_hy || -c.y - cb_fr_ty * zc > rs * cb_fr_hy) return;
    }
    sv = cb_v3(cb_m_view.m[0] * cb_sun.x + cb_m_view.m[4] * cb_sun.y + cb_m_view.m[8] * cb_sun.z,
               cb_m_view.m[1] * cb_sun.x + cb_m_view.m[5] * cb_sun.y + cb_m_view.m[9] * cb_sun.z,
               cb_m_view.m[2] * cb_sun.x + cb_m_view.m[6] * cb_sun.y + cb_m_view.m[10] * cb_sun.z);
    /* whole numbers when everything stays within 16.16 (and the view is perspective) */
    if (fpos && !cb_3d_ortho && fabs(c.x) + rs < 16000 && fabs(c.y) + rs < 16000 && fabs(c.z) + rs < 16000 && s0 < 1e6 && cb_pk_x < 30000 && cb_pk_y < 30000
        && fabs(mv.m[12]) < 16000 && fabs(mv.m[13]) < 16000 && fabs(mv.m[14]) < 16000)
        cb_draw_tris_fx(fpos, col, idx, tri_count, &mv, &sv, tint, both);
    else
        cb_draw_tris_fast(pos, col, idx, tri_count, &mv, &sv, tint, both);
}

static void cb_draw_tris(const float *pos, const int *fpos, const float *bound, const float *nrm, const unsigned char *col, const unsigned short *idx, int tri_count, const cb_m4 *model, cb_rgba tint, bool both) {
    cb_m4 world, mv;
    double nm[9];
    int t, k;
    if (!cb_3d_on)
        return;
    if (cb_3d_fast) { cb_draw_fast(pos, fpos, bound, col, idx, tri_count, model, tint, both); return; }
    world = cb_m4_mul(&cb_m_cur, model); mv = cb_m4_mul(&cb_m_view, &world);
    cb_normal_matrix(&world, nm);
    if (cb_fog_dirty) cb_fog_build();
    if (++cb_vtick == 0) { memset(cb_vstamp, 0, cb_vcap * sizeof *cb_vstamp); cb_vtick = 1; }
    for (t = 0; t < tri_count; t++) {
        cb_cv c[3];
        int vis[3];
        Vector3 e1, e2, nv;
        double facing;
        bool front;
        for (k = 0; k < 3; k++) {
            int vi = idx ? idx[t * 3 + k] : t * 3 + k;
            vis[k] = vi;
            if ((size_t)vi >= cb_vcap) {
                size_t cap = cb_vcap ? cb_vcap : 256;
                cb_cv *nc;
                unsigned *ns;
                while (cap <= (size_t)vi) cap *= 2;
                nc = (cb_cv *)realloc(cb_vcache, cap * sizeof *nc);
                ns = (unsigned *)realloc(cb_vstamp, cap * sizeof *ns);
                if (!nc || !ns) return;
                cb_vcache = nc; cb_vstamp = ns;
                memset(cb_vstamp + cb_vcap, 0, (cap - cb_vcap) * sizeof *ns);
                cb_vcap = cap;
            }
            if (cb_vstamp[vi] != cb_vtick) {
                cb_vcache[vi].v = cb_m4_pt(&mv, cb_v3(pos[vi * 3], pos[vi * 3 + 1], pos[vi * 3 + 2]));
                cb_vertex_lit(nrm, col, vi, nm, tint, true, &cb_vcache[vi]);
                cb_vstamp[vi] = cb_vtick;
            }
            c[k] = cb_vcache[vi];
        }
        e1 = cb_v3_sub(c[1].v, c[0].v); e2 = cb_v3_sub(c[2].v, c[0].v);
        nv = cb_v3_cross(e1, e2);
        facing = cb_3d_ortho ? nv.z : -(nv.x * c[0].v.x + nv.y * c[0].v.y + nv.z * c[0].v.z);   /* > 0: its front faces the eye */
        front = facing > 0;
        if (!front && !both)
            continue;
        if (!front)
            for (k = 0; k < 3; k++)
                cb_vertex_lit(nrm, col, vis[k], nm, tint, false, &c[k]);
        cb_tri_draw(&c[0], &c[1], &c[2]);
    }
}

/* ---- shapes: a cube, a sphere, a cylinder and a plane, 1 across, their middle at the origin ---- */
typedef struct { float *pos, *nrm; unsigned char *col; int tris; int *fpos; float bound[4]; } cb_dshape;
/* fixed-point copies of a mesh's points, and the sphere around them (centre of the box, farthest point) */
static int *cb_fix_points(const float *pos, int n, float bound[4]) {
    int *f = (int *)malloc((size_t)(n > 0 ? n : 1) * 3 * sizeof(int));
    float lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f}, r2 = 0;
    int i, k;
    for (i = 0; i < n; i++)
        for (k = 0; k < 3; k++) {
            float v = pos[i * 3 + k];
            if (v < lo[k]) lo[k] = v;
            if (v > hi[k]) hi[k] = v;
            if (f) f[i * 3 + k] = (int)(v * 65536.0f);
        }
    for (k = 0; k < 3; k++) bound[k] = n > 0 ? (lo[k] + hi[k]) * 0.5f : 0;
    for (i = 0; i < n; i++) {
        float dx = pos[i * 3] - bound[0], dy = pos[i * 3 + 1] - bound[1], dz = pos[i * 3 + 2] - bound[2], d = dx * dx + dy * dy + dz * dz;
        if (d > r2) r2 = d;
    }
    bound[3] = (float)sqrt((double)r2) * 1.001f + 0.001f;
    for (i = 0; i < n * 3; i++) if (f && (pos[i] > 30000.0f || pos[i] < -30000.0f)) { free(f); return NULL; }
    return f;
}

static cb_dshape cb_dshapes[4];
static bool cb_dshapes_ready = false;

typedef struct { float *pos, *nrm; int n, cap; } cb_gen;
static void cb_gen_tri(cb_gen *g, Vector3 a, Vector3 b, Vector3 c, Vector3 na, Vector3 nb, Vector3 nc) {
    Vector3 cr = cb_v3_cross(cb_v3_sub(b, a), cb_v3_sub(c, a)), avg = cb_v3(na.x + nb.x + nc.x, na.y + nb.y + nc.y, na.z + nb.z + nc.z);
    Vector3 pp[3], nn[3];
    int k;
    if (cr.x * avg.x + cr.y * avg.y + cr.z * avg.z < 0) {   /* wound clockwise from outside: turn it round */
        pp[0] = a; pp[1] = c; pp[2] = b; nn[0] = na; nn[1] = nc; nn[2] = nb;
    } else {
        pp[0] = a; pp[1] = b; pp[2] = c; nn[0] = na; nn[1] = nb; nn[2] = nc;
    }
    if (g->n + 3 > g->cap) {
        g->cap = g->cap ? g->cap * 2 : 192;
        g->pos = (float *)realloc((void *)g->pos, sizeof(float) * 3 * (size_t)g->cap);
        g->nrm = (float *)realloc((void *)g->nrm, sizeof(float) * 3 * (size_t)g->cap);
        if (!g->pos || !g->nrm) { fputs("out of memory\n", stderr); exit(3); }
    }
    for (k = 0; k < 3; k++) {
        g->pos[(g->n + k) * 3] = (float)pp[k].x; g->pos[(g->n + k) * 3 + 1] = (float)pp[k].y; g->pos[(g->n + k) * 3 + 2] = (float)pp[k].z;
        g->nrm[(g->n + k) * 3] = (float)nn[k].x; g->nrm[(g->n + k) * 3 + 1] = (float)nn[k].y; g->nrm[(g->n + k) * 3 + 2] = (float)nn[k].z;
    }
    g->n += 3;
}

static void cb_gen_quad(cb_gen *g, Vector3 a, Vector3 b, Vector3 c, Vector3 d, Vector3 n) {
    cb_gen_tri(g, a, b, c, n, n, n);
    cb_gen_tri(g, a, c, d, n, n, n);
}

static void cb_gen_shape(int kind, cb_gen *g) {
    const double pi = 3.14159265358979323846;
    int i, j;
    memset(g, 0, sizeof *g);
    if (kind == 0) {   /* the cube */
        static const double fx[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
        for (i = 0; i < 6; i++) {
            Vector3 n = cb_v3(fx[i][0], fx[i][1], fx[i][2]), u, v, o;
            u = cb_v3_normalize(cb_v3_cross(n, fabs(n.y) > 0.5 ? cb_v3(1, 0, 0) : cb_v3(0, 1, 0)));
            v = cb_v3_cross(n, u);
            o = cb_v3(n.x * 0.5, n.y * 0.5, n.z * 0.5);
            cb_gen_quad(g, cb_v3(o.x - u.x * 0.5 - v.x * 0.5, o.y - u.y * 0.5 - v.y * 0.5, o.z - u.z * 0.5 - v.z * 0.5),
                           cb_v3(o.x + u.x * 0.5 - v.x * 0.5, o.y + u.y * 0.5 - v.y * 0.5, o.z + u.z * 0.5 - v.z * 0.5),
                           cb_v3(o.x + u.x * 0.5 + v.x * 0.5, o.y + u.y * 0.5 + v.y * 0.5, o.z + u.z * 0.5 + v.z * 0.5),
                           cb_v3(o.x - u.x * 0.5 + v.x * 0.5, o.y - u.y * 0.5 + v.y * 0.5, o.z - u.z * 0.5 + v.z * 0.5), n);
        }
    } else if (kind == 1) {   /* the sphere: 8 rings of 16 */
        for (i = 0; i < 8; i++)
            for (j = 0; j < 16; j++) {
                double la0 = -pi / 2 + pi * i / 8.0, la1 = -pi / 2 + pi * (i + 1) / 8.0, lo0 = 2 * pi * j / 16.0, lo1 = 2 * pi * (j + 1) / 16.0;
                Vector3 n[4], p[4];
                double las[4] = {la0, la0, la1, la1}, los[4] = {lo0, lo1, lo1, lo0};
                int k;
                for (k = 0; k < 4; k++) {
                    n[k] = cb_v3(cos(las[k]) * cos(los[k]), sin(las[k]), cos(las[k]) * sin(los[k]));
                    p[k] = cb_v3(n[k].x * 0.5, n[k].y * 0.5, n[k].z * 0.5);
                }
                if (i > 0) cb_gen_tri(g, p[0], p[1], p[2], n[0], n[1], n[2]);
                if (i < 7) cb_gen_tri(g, p[0], p[2], p[3], n[0], n[2], n[3]);
            }
    } else if (kind == 2) {   /* the cylinder: radius 0.5, y from -0.5 to 0.5, 16 sides */
        for (j = 0; j < 16; j++) {
            double a0 = 2 * pi * j / 16.0, a1 = 2 * pi * (j + 1) / 16.0;
            Vector3 n0 = cb_v3(cos(a0), 0, sin(a0)), n1 = cb_v3(cos(a1), 0, sin(a1));
            Vector3 b0 = cb_v3(n0.x * 0.5, -0.5, n0.z * 0.5), b1 = cb_v3(n1.x * 0.5, -0.5, n1.z * 0.5), t0 = cb_v3(n0.x * 0.5, 0.5, n0.z * 0.5), t1 = cb_v3(n1.x * 0.5, 0.5, n1.z * 0.5);
            cb_gen_tri(g, b0, b1, t1, n0, n1, n1);
            cb_gen_tri(g, b0, t1, t0, n0, n1, n0);
            cb_gen_tri(g, cb_v3(0, 0.5, 0), t0, t1, cb_v3(0, 1, 0), cb_v3(0, 1, 0), cb_v3(0, 1, 0));
            cb_gen_tri(g, cb_v3(0, -0.5, 0), b0, b1, cb_v3(0, -1, 0), cb_v3(0, -1, 0), cb_v3(0, -1, 0));
        }
    } else {   /* the plane: 1 x 1, facing up */
        cb_gen_quad(g, cb_v3(-0.5, 0, 0.5), cb_v3(0.5, 0, 0.5), cb_v3(0.5, 0, -0.5), cb_v3(-0.5, 0, -0.5), cb_v3(0, 1, 0));
    }
}

static void cb_dshapes_make(void) {
    int k, i;
    if (cb_dshapes_ready) return;
    for (k = 0; k < 4; k++) {
        cb_gen g;
        cb_gen_shape(k, &g);
        cb_dshapes[k].pos = g.pos; cb_dshapes[k].nrm = g.nrm; cb_dshapes[k].tris = g.n / 3;
        cb_dshapes[k].fpos = cb_fix_points(g.pos, g.n, cb_dshapes[k].bound);
        cb_dshapes[k].col = (unsigned char *)malloc((size_t)g.n * 4);
        for (i = 0; i < g.n * 4; i++) cb_dshapes[k].col[i] = 255;
    }
    cb_dshapes_ready = true;
}

static cb_m4 cb_model(Vector3 at, Vector3 size, double turn) {   /* translate * turn about Y * scale */
    cb_m4 m = cb_m4_id();
    double a = turn * 3.14159265358979323846 / 180.0, c = cos(a), s = sin(a);
    m.m[0] = c * size.x; m.m[2] = -s * size.x;
    m.m[5] = size.y;
    m.m[8] = s * size.z; m.m[10] = c * size.z;
    m.m[12] = at.x; m.m[13] = at.y; m.m[14] = at.z;
    return m;
}

void cb_draw_shape(int kind, Vector3 at, Vector3 size, double turn, cb_rgba color) {
    cb_m4 m;
    cb_dshapes_make();
    if (kind < 0 || kind > 3) kind = 0;
    m = cb_model(at, size, turn);
    cb_draw_tris(cb_dshapes[kind].pos, cb_dshapes[kind].fpos, cb_dshapes[kind].bound, cb_dshapes[kind].nrm, cb_dshapes[kind].col, NULL, cb_dshapes[kind].tris, &m, color, false);
}

/* ---- meshes (the mesh bricks): triangles collected, then built (Finish): the same rules as the raylib backend ---- */
typedef struct cb_tri { Vector3 p[3]; Vector3 n[3]; cb_rgba c; int own; } cb_tri;
struct cb_mesh { cb_list *tris; float *pos, *nrm; unsigned char *col; unsigned short *idx; int vcount, tcount; bool built, both, smooth; int *fpos; float bound[4]; bool prepared; };

cb_mesh *cb_mesh_new(void) {
    cb_mesh *m = (cb_mesh *)cb_alloc(sizeof(cb_mesh));
    m->tris = cb_list_new(sizeof(cb_tri));
    return m;
}

cb_mesh *cb_mesh_begin(cb_mesh *m) {
    if (!m) m = cb_mesh_new();
    cb_list_clear(m->tris);
    return m;
}

static void cb_mesh_add(cb_mesh *m, Vector3 a, Vector3 b, Vector3 c, const Vector3 *normals, cb_rgba color) {
    cb_tri *t = (cb_tri *)cb_list_add(m->tris);
    t->p[0] = a; t->p[1] = b; t->p[2] = c;
    t->c = color;
    if (normals) { t->n[0] = normals[0]; t->n[1] = normals[1]; t->n[2] = normals[2]; t->own = 1; }
}

void cb_mesh_triangle(cb_mesh *m, Vector3 a, Vector3 b, Vector3 c, cb_rgba color) { cb_mesh_add(m, a, c, b, NULL, color); }   /* (a brick's A B C is clockwise: kept as A C B) */
void cb_mesh_quad(cb_mesh *m, Vector3 a, Vector3 b, Vector3 c, Vector3 d, cb_rgba color) { cb_mesh_triangle(m, a, b, c, color); cb_mesh_triangle(m, a, c, d, color); }

void cb_mesh_shape(cb_mesh *m, int kind, Vector3 at, Vector3 size, cb_rgba color) {
    cb_gen g;
    int i, k;
    if (kind < 0 || kind > 3) kind = 0;
    cb_gen_shape(kind, &g);
    for (i = 0; i + 2 < g.n; i += 3) {
        Vector3 p[3], n[3];
        for (k = 0; k < 3; k++) {
            p[k] = cb_v3(at.x + g.pos[(i + k) * 3] * size.x, at.y + g.pos[(i + k) * 3 + 1] * size.y, at.z + g.pos[(i + k) * 3 + 2] * size.z);
            n[k] = cb_v3_normalize(cb_v3(g.nrm[(i + k) * 3] / size.x, g.nrm[(i + k) * 3 + 1] / size.y, g.nrm[(i + k) * 3 + 2] / size.z));
        }
        cb_mesh_add(m, p[0], p[1], p[2], n, color);
    }
    free(g.pos); free(g.nrm);
}

static unsigned long cb_point_hash(Vector3 p, cb_rgba c) {
    unsigned long h = 2166136261u;
    const unsigned char *b = (const unsigned char *)&p;
    size_t i;
    for (i = 0; i < sizeof p; i++) h = (h ^ b[i]) * 16777619u;
    h = (h ^ c.r) * 16777619u; h = (h ^ c.g) * 16777619u; h = (h ^ c.b) * 16777619u; h = (h ^ c.a) * 16777619u;
    return h;
}

/* normals again from the points (flat: per triangle; smooth: indexed, averaged) */
static void cb_mesh_normals(cb_mesh *m, bool skip_own, const cb_list *tris) {
    int i, k, count = m->tcount * 3;
    if (m->idx) memset(m->nrm, 0, (size_t)m->vcount * 3 * sizeof(float));
    for (i = 0; i + 2 < count; i += 3) {
        int v[3];
        Vector3 n, p[3];
        if (skip_own && tris && ((const cb_tri *)tris->data)[i / 3].own) continue;
        for (k = 0; k < 3; k++) {
            v[k] = m->idx ? m->idx[i + k] : i + k;
            p[k] = cb_v3(m->pos[v[k] * 3], m->pos[v[k] * 3 + 1], m->pos[v[k] * 3 + 2]);
        }
        n = cb_v3_cross(cb_v3_sub(p[1], p[0]), cb_v3_sub(p[2], p[0]));
        if (!m->idx) n = cb_v3_normalize(n);
        for (k = 0; k < 3; k++) {
            if (m->idx) { m->nrm[v[k] * 3] += (float)n.x; m->nrm[v[k] * 3 + 1] += (float)n.y; m->nrm[v[k] * 3 + 2] += (float)n.z; }
            else { m->nrm[v[k] * 3] = (float)n.x; m->nrm[v[k] * 3 + 1] = (float)n.y; m->nrm[v[k] * 3 + 2] = (float)n.z; }
        }
    }
    if (m->idx)
        for (i = 0; i < m->vcount; i++) {
            Vector3 n = cb_v3(m->nrm[i * 3], m->nrm[i * 3 + 1], m->nrm[i * 3 + 2]);
            if (cb_v3_length(n) == 0) continue;
            n = cb_v3_normalize(n);
            m->nrm[i * 3] = (float)n.x; m->nrm[i * 3 + 1] = (float)n.y; m->nrm[i * 3 + 2] = (float)n.z;
        }
}

void cb_mesh_finish(cb_mesh *m, bool smooth, bool both_sides, int file, int brick) {
    int count = m->tris->count, corners = count * 3, i, k, nv;
    size_t n_corners = corners > 0 ? (size_t)corners : 1, n_points;
    const cb_tri *tris = (const cb_tri *)m->tris->data;
    unsigned short *idx = NULL;
    if (!cb_dos_open)
        cb_assert(false, file, brick, "Finish mesh needs the window open first (Open window)");
    if (!smooth) {
        nv = corners;
    } else {   /* one point per place and colour (a shape's own-normal corners stay apart) */
        int size = 16, *slots, *map, unique = 0;
        while (size < corners * 2 + 2) size *= 2;
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
                    if (!u->own && memcmp(&u->p[j % 3], &t->p[i % 3], sizeof(Vector3)) == 0 && memcmp(&u->c, &t->c, sizeof(cb_rgba)) == 0) { found = map[j]; break; }
                    at = (at + 1) & (unsigned long)(size - 1);
                }
                if (found < 0) slots[at] = i + 1;
            }
            map[i] = found >= 0 ? found : unique++;
        }
        free(slots);
        if (unique > 65535) { free(map); cb_assert(false, file, brick, "a Smooth mesh can have at most 65535 points: use Flat, or split it"); }
        nv = unique;
        idx = (unsigned short *)malloc(n_corners * sizeof(unsigned short));
        for (i = 0; i < corners; i++) idx[i] = (unsigned short)map[i];
        free(map);
    }
    n_points = nv > 0 ? (size_t)nv : 1;
    free(m->pos); free(m->nrm); free(m->col); free(m->idx);
    m->pos = (float *)calloc(n_points * 3, sizeof(float));
    m->nrm = (float *)calloc(n_points * 3, sizeof(float));
    m->col = (unsigned char *)calloc(n_points * 4, 1);
    m->idx = idx; m->vcount = nv; m->tcount = count;
    for (i = 0; i < count; i++)
        for (k = 0; k < 3; k++) {
            int v = idx ? idx[i * 3 + k] : i * 3 + k;
            const cb_tri *t = &tris[i];
            m->pos[v * 3] = (float)t->p[k].x; m->pos[v * 3 + 1] = (float)t->p[k].y; m->pos[v * 3 + 2] = (float)t->p[k].z;
            m->nrm[v * 3] = (float)t->n[k].x; m->nrm[v * 3 + 1] = (float)t->n[k].y; m->nrm[v * 3 + 2] = (float)t->n[k].z;
            m->col[v * 4] = t->c.r; m->col[v * 4 + 1] = t->c.g; m->col[v * 4 + 2] = t->c.b; m->col[v * 4 + 3] = t->c.a;
        }
    cb_mesh_normals(m, true, m->tris);
    m->built = nv > 0 || m->built;
    m->both = both_sides; m->smooth = smooth; m->prepared = false;
    cb_list_clear(m->tris);
}

void cb_draw_mesh(cb_mesh *m, Vector3 at, Vector3 size, double turn, cb_rgba tint) {
    cb_m4 mm;
    if (!m || !m->built || m->vcount == 0) return;
    mm = cb_model(at, size, turn);
    if (!m->prepared) { free(m->fpos); m->fpos = cb_fix_points(m->pos, m->vcount, m->bound); m->prepared = true; }
    cb_draw_tris(m->pos, m->fpos, m->bound, m->nrm, m->col, m->idx, m->tcount, &mm, tint, m->both);
}

cb_list *cb_mesh_points(const cb_mesh *m) {
    cb_list *l = cb_list_new(sizeof(Vector3));
    int i;
    if (!m || !m->built) return l;
    for (i = 0; i < m->vcount; i++) *(Vector3 *)cb_list_add(l) = cb_v3(m->pos[i * 3], m->pos[i * 3 + 1], m->pos[i * 3 + 2]);
    return l;
}

void cb_mesh_set_points(cb_mesh *m, const cb_list *points, int file, int brick) {
    int i;
    if (!m || !m->built) cb_assert(false, file, brick, "the mesh isn't built yet (Finish mesh)");
    if (points->count != m->vcount) cb_assert(false, file, brick, cb_format("got %d points for a mesh of %d points", points->count, m->vcount));
    for (i = 0; i < m->vcount; i++) {
        const Vector3 *p = (const Vector3 *)(points->data + (size_t)i * sizeof(Vector3));
        m->pos[i * 3] = (float)p->x; m->pos[i * 3 + 1] = (float)p->y; m->pos[i * 3 + 2] = (float)p->z;
    }
    cb_mesh_normals(m, false, NULL);
    m->prepared = false;
}

void cb_show_mesh(FILE *f, const void *value) {
    const cb_mesh *m = *(cb_mesh *const *)value;
    if (!m || !m->built)
        fprintf(f, "mesh (not built%s)", m && m->tris->count ? cb_format(", %d triangles added", m->tris->count) : "");
    else
        fprintf(f, "mesh (%d triangles, %d points, %s)", m->tcount, m->vcount, m->smooth ? "smooth" : "flat");
}

/* ---- lines (Draw shape's Line, Grid, Wire box): unlit, depth-tested ---- */
static void cb_line3d_view(Vector3 a, Vector3 b, cb_rgba c) {   /* view-space endpoints */
    double za = -a.z, zb = -b.z;
    cb_sv s0, s1;
    int x0, y0, x1, y1, dx, dy, sx, sy, err, steps = 0, total;
    unsigned char q = cb_dos_quant(c.r, c.g, c.b);
    if (za < CB_NEAR && zb < CB_NEAR) return;
    if (za < CB_NEAR) { double t = (-CB_NEAR - a.z) / (b.z - a.z); a = cb_v3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, -CB_NEAR); }
    else if (zb < CB_NEAR) { double t = (-CB_NEAR - b.z) / (a.z - b.z); b = cb_v3(b.x + (a.x - b.x) * t, b.y + (a.y - b.y) * t, -CB_NEAR); }
    s0 = cb_project(a, 1, 1, 1, 1); s1 = cb_project(b, 1, 1, 1, 1);
    if (fabs(s0.x) > 1e6 || fabs(s0.y) > 1e6 || fabs(s1.x) > 1e6 || fabs(s1.y) > 1e6) return;
    if (cb_3d_fast) { cb_fast_line(&s0, &s1, q); return; }
    x0 = (int)floor(s0.x); y0 = (int)floor(s0.y); x1 = (int)floor(s1.x); y1 = (int)floor(s1.y);
    dx = abs(x1 - x0); dy = -abs(y1 - y0); sx = x0 < x1 ? 1 : -1; sy = y0 < y1 ? 1 : -1; err = dx + dy;
    total = dx > -dy ? dx : -dy;
    for (;;) {
        int e2;
        if (x0 >= 0 && y0 >= 0 && x0 < cb_dos_w && y0 < cb_dos_h) {
            double t = total > 0 ? (double)steps / total : 0, k = s0.k + (s1.k - s0.k) * t;
            int *zp = cb_zbuf + (size_t)y0 * (size_t)cb_dos_w + (size_t)x0, zk = cb_zkey(k);
            if (zk > *zp) { *zp = zk; cb_dos_back[(size_t)y0 * (size_t)cb_dos_w + (size_t)x0] = q; }
        }
        if ((x0 == x1 && y0 == y1) || steps > 5000) break;
        e2 = 2 * err; steps++;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

void cb_be_line3d(Vector3 a, Vector3 b, cb_rgba c) {
    cb_m4 mv;
    if (!cb_3d_on || (!cb_3d_fast && !cb_zbuf)) return;
    mv = cb_m4_mul(&cb_m_view, &cb_m_cur);
    cb_line3d_view(cb_m4_pt(&mv, a), cb_m4_pt(&mv, b), c);
}

void cb_be_grid(int lines, double spacing) {
    int half = lines / 2, i;
    for (i = -half; i <= half; i++) {
        cb_rgba c = i == 0 ? (cb_rgba){128, 128, 128, 255} : (cb_rgba){192, 192, 192, 255};
        cb_be_line3d(cb_v3(i * spacing, 0, -half * spacing), cb_v3(i * spacing, 0, half * spacing), c);
        cb_be_line3d(cb_v3(-half * spacing, 0, i * spacing), cb_v3(half * spacing, 0, i * spacing), c);
    }
}

void cb_be_wire_box(Vector3 at, Vector3 size, cb_rgba c) {
    double x = size.x / 2, y = size.y / 2, z = size.z / 2;
    int i;
    Vector3 p[8];
    static const int e[12][2] = {{0, 1}, {1, 3}, {3, 2}, {2, 0}, {4, 5}, {5, 7}, {7, 6}, {6, 4}, {0, 4}, {1, 5}, {2, 6}, {3, 7}};
    for (i = 0; i < 8; i++) p[i] = cb_v3(at.x + ((i & 1) ? x : -x), at.y + ((i & 2) ? y : -y), at.z + ((i & 4) ? z : -z));
    for (i = 0; i < 12; i++) cb_be_line3d(p[e[i][0]], p[e[i][1]], c);
}

/* ---- render targets (Snapshot): the picture is drawn into a buffer of its own, then saved or made a texture ---- */
static unsigned char *cb_rt_saved_back = NULL;
static int *cb_rt_saved_z = NULL;
static int cb_rt_saved_w = 0, cb_rt_saved_h = 0;
static unsigned char *cb_rt_back = NULL;
static int *cb_rt_z = NULL;
static int cb_rt_w = 0, cb_rt_h = 0;
static bool cb_rt_transparent = false, cb_rt_on = false;

void cb_be_target_begin(int width, int height) {
    cb_rt_saved_back = cb_dos_back; cb_rt_saved_z = cb_zbuf; cb_rt_saved_w = cb_dos_w; cb_rt_saved_h = cb_dos_h;
    free(cb_rt_back); free(cb_rt_z);
    cb_rt_back = (unsigned char *)calloc((size_t)width * (size_t)height, 1);
    cb_rt_z = (int *)calloc((size_t)width * (size_t)height, sizeof(int));
    cb_rt_w = width; cb_rt_h = height; cb_rt_transparent = false; cb_rt_on = true;
    cb_dos_back = cb_rt_back; cb_zbuf = cb_rt_z; cb_dos_w = width; cb_dos_h = height;
    cb_zdirty = true;
}

void cb_be_target_end(void) {
    if (!cb_rt_on) return;
    cb_dos_back = cb_rt_saved_back; cb_zbuf = cb_rt_saved_z; cb_dos_w = cb_rt_saved_w; cb_dos_h = cb_rt_saved_h;
    cb_zdirty = true;
}

/* the picture as RGBA (a pixel nothing was drawn on is clear when the target was cleared clear) */
static unsigned char *cb_rt_rgba(void) {
    size_t n = (size_t)cb_rt_w * (size_t)cb_rt_h, i;
    unsigned char *px = (unsigned char *)malloc(n * 4);
    if (!px) return NULL;
    for (i = 0; i < n; i++) {
        px[i * 4] = cb_dos_pal[cb_rt_back[i]][0]; px[i * 4 + 1] = cb_dos_pal[cb_rt_back[i]][1]; px[i * 4 + 2] = cb_dos_pal[cb_rt_back[i]][2];
        px[i * 4 + 3] = (cb_rt_transparent && cb_rt_z[i] <= 0) ? 0 : 255;
    }
    return px;
}

bool cb_be_target_save(const char *path) {
    unsigned char *px = cb_rt_rgba();
    int ok;
    if (!px) return false;
    ok = stbi_write_png(path, cb_rt_w, cb_rt_h, 4, px, cb_rt_w * 4);
    free(px);
    return ok != 0;
}

cb_texture cb_be_target_texture(void) {
    cb_texture t = {0, 0, 0};
    unsigned char *px = cb_rt_rgba();
    cb_dos_tex *grown;
    if (!px) return t;
    grown = (cb_dos_tex *)realloc((void *)cb_dos_texs, sizeof(cb_dos_tex) * (size_t)(cb_dos_tex_n + 1));
    if (!grown) { free(px); return t; }
    cb_dos_texs = grown;
    cb_dos_texs[cb_dos_tex_n].w = cb_rt_w; cb_dos_texs[cb_dos_tex_n].h = cb_rt_h; cb_dos_texs[cb_dos_tex_n].rgba = px;
    cb_dos_tex_n++;
    t.id = cb_dos_tex_n; t.width = cb_rt_w; t.height = cb_rt_h;
    return t;
}

void cb_be_target_free(void) {
    free(cb_rt_back); free(cb_rt_z);
    cb_rt_back = NULL; cb_rt_z = NULL; cb_rt_on = false;
}
