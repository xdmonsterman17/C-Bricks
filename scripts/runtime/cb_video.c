/* C-Bricks video (2026-11-20): MPEG-1 video + MP2 audio (.mpg) decoded by pl_mpeg (MIT, thirdparty/pl_mpeg),
   shown as a texture and played through the backend's audio stream (cb_backend.h CB_BE_HAVE_VIDEO).
   Two layers:
     cb_video_*   a player you can use from your own C (cbricks.h);
     the Video class (types.gd BUILTIN: file, playing, loop, volume, speed, time, duration, ended): every frame,
     cb_video_world_update() makes each Video object's player match its fields. A Shape3D / Mesh3D / Sprite2D /
     Image whose Texture names a Video object shows its picture (cb_texture_ref, cbricks_gfx.c).
   This file is its own program file (cbricks_video.c). A project that never uses video gets the stubs at the end
   (CB_NO_VIDEO is defined above this text then: pl_mpeg isn't compiled at all). */
#include "cbricks.h"

#ifndef CB_NO_VIDEO
#if defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wsign-compare"
#pragma GCC diagnostic ignored "-Wpedantic"
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wunused-variable"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif
#define PL_MPEG_IMPLEMENTATION
#include "cb_pl_mpeg.h"

struct cb_video {
    plm_t *plm;
    cb_texture tex;
    unsigned char *rgba;     /* the newest picture */
    int w, h;
    int dirty;               /* a picture is waiting to be uploaded */
    int audio;               /* the backend's stream (0: none) */
    double volume;
    int loop;
};

static void cb_video_on_picture(plm_t *p, plm_frame_t *f, void *user) {
    cb_video *v = (cb_video *)user;
    (void)p;
    plm_frame_to_rgba(f, v->rgba, v->w * 4);
    v->dirty = 1;
}

static void cb_video_on_audio(plm_t *p, plm_samples_t *s, void *user) {
    cb_video *v = (cb_video *)user;
    (void)p;
    cb_be_audio_push(v->audio, s->interleaved, (int)s->count);
}

cb_video *cb_video_open(const char *path) {
    cb_video *v;
    plm_t *plm = plm_create_with_filename(path);
    if (!plm)
        return NULL;
    if (!plm_probe(plm, 5000 * 1024) || plm_get_num_video_streams(plm) < 1 || plm_get_width(plm) <= 0) {
        plm_destroy(plm);
        return NULL;
    }
    v = (cb_video *)calloc(1, sizeof(cb_video));
    if (!v) {
        plm_destroy(plm);
        return NULL;
    }
    v->plm = plm;
    v->w = plm_get_width(plm);
    v->h = plm_get_height(plm);
    v->volume = 1.0;
    v->rgba = (unsigned char *)malloc((size_t)v->w * (size_t)v->h * 4);
    if (!v->rgba) {
        plm_destroy(plm);
        free(v);
        return NULL;
    }
    memset(v->rgba, 0xFF, (size_t)v->w * (size_t)v->h * 4);   /* (plm_frame_to_rgba writes R G B only: the alpha stays opaque) */
    v->tex = cb_be_texture_create(v->w, v->h);
    plm_set_video_decode_callback(plm, cb_video_on_picture, v);
    if (plm_get_num_audio_streams(plm) > 0 && (v->audio = cb_be_audio_open(plm_get_samplerate(plm))) > 0) {
        plm_set_audio_enabled(plm, 1);
        plm_set_audio_stream(plm, 0);
        plm_set_audio_decode_callback(plm, cb_video_on_audio, v);
    } else {
        v->audio = 0;
        plm_set_audio_enabled(plm, 0);
    }
    plm_set_loop(plm, 0);
    /* the first picture, so the texture isn't black before it plays */
    plm_decode(plm, 0.0);
    {
        plm_frame_t *first = plm_seek_frame(plm, 0.0, 0);
        if (first) {
            plm_frame_to_rgba(first, v->rgba, v->w * 4);
            v->dirty = 1;
        }
    }
    if (v->dirty && v->tex.id) {
        cb_be_texture_update(v->tex, v->rgba);
        v->dirty = 0;
    }
    return v;
}

void cb_video_close(cb_video *v) {
    if (!v)
        return;
    if (v->audio)
        cb_be_audio_close(v->audio);
    plm_destroy(v->plm);
    free(v->rgba);
    free(v);
}

void cb_video_update(cb_video *v, double dt) {
    if (!v || dt <= 0)
        return;
    if (dt > 0.25)
        dt = 0.25;   /* a stall (a dragged window) doesn't make it race through the film */
    plm_decode(v->plm, dt);
    if (v->dirty && v->tex.id) {
        cb_be_texture_update(v->tex, v->rgba);
        v->dirty = 0;
    }
}

cb_texture cb_video_texture(const cb_video *v) {
    cb_texture none;
    if (v)
        return v->tex;
    none.id = 0; none.width = 0; none.height = 0;
    return none;
}

void cb_video_seek(cb_video *v, double seconds) {
    plm_frame_t *f;
    if (!v)
        return;
    if (seconds < 0)
        seconds = 0;
    f = plm_seek_frame(v->plm, seconds, 1);   /* exact: decodes on from the nearest key frame */
    if (v->audio)
        cb_be_audio_flush(v->audio);
    if (f) {
        plm_frame_to_rgba(f, v->rgba, v->w * 4);
        v->dirty = 1;
        if (v->tex.id) {
            cb_be_texture_update(v->tex, v->rgba);
            v->dirty = 0;
        }
    }
}

void cb_video_set_loop(cb_video *v, bool loop) {
    if (v && v->loop != (loop ? 1 : 0)) {
        v->loop = loop ? 1 : 0;
        plm_set_loop(v->plm, v->loop);
    }
}

void cb_video_set_volume(cb_video *v, double volume) {
    if (!v)
        return;
    v->volume = volume < 0 ? 0 : volume;
    if (v->audio)
        cb_be_audio_volume(v->audio, v->volume);
}

double cb_video_time(const cb_video *v) { return v ? plm_get_time(v->plm) : 0.0; }
double cb_video_duration(const cb_video *v) { return v ? plm_get_duration(v->plm) : 0.0; }
bool cb_video_ended(const cb_video *v) { return v ? plm_has_ended(v->plm) != 0 : false; }
int cb_video_width(const cb_video *v) { return v ? v->w : 0; }
int cb_video_height(const cb_video *v) { return v ? v->h : 0; }

/* ---- the Video class: one player per Video object, kept in step with its fields every frame ---- */
typedef struct cb_vid_slot {
    cb_object *obj;
    int id;
    cb_video *v;
    char file[260];
    double last_time;      /* the time we wrote into the object's `time` (a different value = the script asked to seek) */
    int warned;
} cb_vid_slot;
static cb_vid_slot *cb_vid_slots = NULL;
static int cb_vid_n = 0;

static cb_vid_slot *cb_vid_slot_of(cb_object *o) {
    int i;
    for (i = 0; i < cb_vid_n; i++)
        if (cb_vid_slots[i].obj == o && cb_vid_slots[i].id == o->id)
            return &cb_vid_slots[i];
    cb_vid_slots = (cb_vid_slot *)realloc((void *)cb_vid_slots, sizeof(cb_vid_slot) * (size_t)(cb_vid_n + 1));
    if (!cb_vid_slots) { fputs("out of memory\n", stderr); exit(3); }
    memset(&cb_vid_slots[cb_vid_n], 0, sizeof(cb_vid_slot));
    cb_vid_slots[cb_vid_n].obj = o;
    cb_vid_slots[cb_vid_n].id = o->id;
    return &cb_vid_slots[cb_vid_n++];
}

/* Players of objects that were destroyed are closed. */
static void cb_vid_sweep(void) {
    int i = 0;
    while (i < cb_vid_n) {
        cb_vid_slot *s = &cb_vid_slots[i];
        if (!cb_alive(s->obj) || s->obj->id != s->id) {
            cb_video_close(s->v);
            cb_vid_slots[i] = cb_vid_slots[--cb_vid_n];
        } else
            i++;
    }
}

void cb_video_world_update(double dt) {
    void **all;
    int i, n = cb_world_objects(&all);
    cb_vid_sweep();
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)all[i];
        cls_Video *vo;
        cb_vid_slot *s;
        if (!cb_is_a(o, &cls_Video_class))
            continue;
        vo = (cls_Video *)o;
        s = cb_vid_slot_of(o);
        if (strcmp(s->file, vo->f_file) != 0) {   /* a new file (or the first time): open it (after the window, so a graphics card is ready) */
            cb_video_close(s->v);
            s->v = NULL;
            snprintf(s->file, sizeof s->file, "%s", vo->f_file);
            s->last_time = 0;
            s->warned = 0;
            if (vo->f_file[0]) {
                s->v = cb_video_open(vo->f_file);
                if (!s->v && !s->warned) {
                    fprintf(stderr, "Video %s: can't open %s (an MPEG-1 .mpg file, in the project folder)\n", o->name, vo->f_file);
                    s->warned = 1;
                }
            }
            vo->f_time = 0;
            vo->f_ended = false;
        }
        if (!s->v) {
            vo->f_duration = 0;
            continue;
        }
        cb_video_set_loop(s->v, vo->f_loop);
        cb_video_set_volume(s->v, vo->f_volume);
        if (fabs(vo->f_time - s->last_time) > 0.05)   /* the script set `time`: jump there */
            cb_video_seek(s->v, vo->f_time);
        if (vo->f_playing && !(cb_video_ended(s->v) && !vo->f_loop))
            cb_video_update(s->v, dt * (vo->f_speed > 0 ? vo->f_speed : 0));
        s->last_time = cb_video_time(s->v);
        vo->f_time = s->last_time;
        vo->f_duration = cb_video_duration(s->v);
        vo->f_ended = cb_video_ended(s->v) && !vo->f_loop;
    }
}

cb_texture cb_video_object_texture(void *o) {
    cb_vid_slot *s = cb_vid_slot_of((cb_object *)o);
    return cb_video_texture(s->v);
}

void cb_video_forget_all(void) {
    int i;
    for (i = 0; i < cb_vid_n; i++)
        cb_video_close(cb_vid_slots[i].v);
    free(cb_vid_slots);
    cb_vid_slots = NULL;
    cb_vid_n = 0;
}

#else /* CB_NO_VIDEO: nothing in this program uses video */
cb_video *cb_video_open(const char *path) { (void)path; return NULL; }
void cb_video_close(cb_video *v) { (void)v; }
void cb_video_update(cb_video *v, double dt) { (void)v; (void)dt; }
cb_texture cb_video_texture(const cb_video *v) { cb_texture t; (void)v; t.id = 0; t.width = 0; t.height = 0; return t; }
void cb_video_seek(cb_video *v, double seconds) { (void)v; (void)seconds; }
void cb_video_set_loop(cb_video *v, bool loop) { (void)v; (void)loop; }
void cb_video_set_volume(cb_video *v, double volume) { (void)v; (void)volume; }
double cb_video_time(const cb_video *v) { (void)v; return 0.0; }
double cb_video_duration(const cb_video *v) { (void)v; return 0.0; }
bool cb_video_ended(const cb_video *v) { (void)v; return false; }
int cb_video_width(const cb_video *v) { (void)v; return 0; }
int cb_video_height(const cb_video *v) { (void)v; return 0; }
void cb_video_world_update(double dt) { (void)dt; }
cb_texture cb_video_object_texture(void *o) { cb_texture t; (void)o; t.id = 0; t.width = 0; t.height = 0; return t; }
void cb_video_forget_all(void) {}
#endif
