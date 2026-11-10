
/* ---- objects (classes: a script with a Class brick) -------------------------
   Every object starts with a cb_object (its class, an id, a name, a parent and
   children), then its classes' fields, base class first. New allocates and runs
   each class's field setup and When created, base class first. Destroy frees the
   object (and its children): it waits in a quarantine of the last CB_QUARANTINE
   destroyed objects first, so its address isn't reused at once, and a table of
   live objects lets every use check it still exists. */
#define CB_QUARANTINE 1024

/* The root class: every class extends Object (directly or through its parents). */
const cb_class Node_class = { "Node", NULL, sizeof(cb_object), NULL, NULL, 0, NULL, NULL, NULL, NULL, NULL, 3, NULL, 0 };

static void **cb_live = NULL;    /* open addressing: live objects' addresses (NULL = empty) */
static int cb_live_cap = 0, cb_live_count = 0;
static void *cb_quarantine[CB_QUARANTINE];
static int cb_quarantine_at = 0;
static int cb_next_id = 0;

static size_t cb_ptr_slot(const void *p, int cap) {
    size_t h = (size_t)p;
    h ^= h >> 17;
    h *= 0x9E3779B1u;
    return (h ^ (h >> 15)) & (size_t)(cap - 1);
}

static void cb_live_put(void *p);

static void cb_live_grow(void) {
    void **old = cb_live;
    int i, old_cap = cb_live_cap;
    cb_live_cap = cb_live_cap ? cb_live_cap * 2 : 64;
    cb_live = (void **)calloc((size_t)cb_live_cap, sizeof(void *));
    if (!cb_live) { fputs("out of memory\n", stderr); exit(3); }
    cb_live_count = 0;
    for (i = 0; i < old_cap; i++)
        if (old[i])
            cb_live_put(old[i]);
    free((void *)old);
}

static void cb_live_put(void *p) {
    size_t at;
    if ((cb_live_count + 1) * 2 > cb_live_cap)
        cb_live_grow();
    at = cb_ptr_slot(p, cb_live_cap);
    while (cb_live[at])
        at = (at + 1) & (size_t)(cb_live_cap - 1);
    cb_live[at] = p;
    cb_live_count++;
}

static long cb_live_find(const void *p) {
    size_t at;
    if (!p || !cb_live)
        return -1;
    at = cb_ptr_slot(p, cb_live_cap);
    while (cb_live[at]) {
        if (cb_live[at] == p)
            return (long)at;
        at = (at + 1) & (size_t)(cb_live_cap - 1);
    }
    return -1;
}

/* Linear probing removal: the entries after it move back into the gap. */
static void cb_live_remove(const void *p) {
    long found = cb_live_find(p);
    size_t gap, at;
    if (found < 0)
        return;
    gap = (size_t)found;
    cb_live[gap] = NULL;
    cb_live_count--;
    at = (gap + 1) & (size_t)(cb_live_cap - 1);
    while (cb_live[at]) {
        void *q = cb_live[at];
        cb_live[at] = NULL;
        cb_live_count--;
        cb_live_put(q);
        at = (at + 1) & (size_t)(cb_live_cap - 1);
    }
}

bool cb_alive(const void *o) {
    return cb_live_find(o) >= 0;
}

static void **cb_world_list = NULL;  /* the world's objects this frame (cb_world_objects) */

static void cb_objects_free_all(void) {
    int i;
    free((void *)cb_world_list);
    for (i = 0; i < cb_live_cap; i++)
        if (cb_live[i])
            free(cb_live[i]);
    for (i = 0; i < CB_QUARANTINE; i++)
        free(cb_quarantine[i]);
    free((void *)cb_live);
    cb_live = NULL;
}

static void cb_run_init(const cb_class *cls, void *o) {
    if (cls->parent)
        cb_run_init(cls->parent, o);
    if (cls->init)
        cls->init(o);
}

static void cb_run_created(const cb_class *cls, void *o) {
    if (cls->parent)
        cb_run_created(cls->parent, o);
    if (cls->created)
        cls->created(o);
}

static cb_object *cb_make_object(const cb_class *cls) {
    cb_object *o = (cb_object *)calloc(1, cls->size);
    if (!o) { fputs("out of memory\n", stderr); exit(3); }
    if (cb_next_id == 0)
        atexit(cb_objects_free_all);  /* after the program's own exit handlers */
    o->cls = cls;
    o->id = ++cb_next_id;
    o->name = cls->name;
    o->children = cb_list_new(sizeof(cb_object *));
    o->groups = cb_list_new(sizeof(const char *));
    o->meta = cb_map_new(sizeof(const char *));
    cb_live_put(o);
    cb_run_init(cls, o);
    return o;
}

void *cb_new(const cb_class *cls) {
    cb_object *o = cb_make_object(cls);
    cb_run_created(cls, o);
    return o;
}

/* A client's copy of a server's object (networking): its fields' setup, not its
   When created (the server ran it; what it made comes from the server too). */
void *cb_new_replica(const cb_class *cls) {
    return cb_make_object(cls);
}

/* The object a brick uses: stops the program when it's none or destroyed. */
void *cb_obj(void *o, int file, int brick) {
    if (!o) {
        fprintf(stderr, "[error] %s brick %d: the object is none (not made yet, or an As that didn't fit)\n", cb_files[file], brick);
        exit(1);
    }
    if (!cb_alive(o)) {
        fprintf(stderr, "[error] %s brick %d: the object was destroyed\n", cb_files[file], brick);
        exit(1);
    }
    return o;
}

static void cb_unparent(cb_object *o) {
    int i;
    cb_list *kids;
    if (!o->parent || !cb_alive(o->parent))
        return;
    kids = o->parent->children;
    for (i = 0; i < kids->count; i++) {
        if (((cb_object **)kids->data)[i] == o) {
            cb_list_remove(kids, i, 0, 0);
            break;
        }
    }
    o->parent = NULL;
}

/* Puts an object under another (NULL: under nothing). */
void cb_set_parent(void *child, void *parent, int file, int brick) {
    cb_object *c = (cb_object *)cb_obj(child, file, brick), *p;
    if (parent) {
        p = (cb_object *)cb_obj(parent, file, brick);
        for (; p; p = p->parent)
            if (p == c) {
                fprintf(stderr, "[error] %s brick %d: an object can't go under itself or one of its children\n", cb_files[file], brick);
                exit(1);
            }
    }
    cb_unparent(c);
    c->parent = (cb_object *)parent;
    if (parent)
        *(cb_object **)cb_list_add(((cb_object *)parent)->children) = c;
}

static void cb_destroy_tree(cb_object *o) {
    int i;
    for (i = o->children->count - 1; i >= 0; i--) {
        cb_object *c = ((cb_object **)o->children->data)[i];
        if (cb_alive(c)) {
            c->parent = NULL;
            cb_destroy_tree(c);
        }
    }
    cb_live_remove(o);
    free(cb_quarantine[cb_quarantine_at]);  /* the oldest destroyed one goes for good */
    cb_quarantine[cb_quarantine_at] = o;
    cb_quarantine_at = (cb_quarantine_at + 1) % CB_QUARANTINE;
}

void cb_destroy(void *o, int file, int brick) {
    cb_object *obj = (cb_object *)cb_obj(o, file, brick);
    cb_unparent(obj);
    cb_destroy_tree(obj);
}

bool cb_is_a(const void *o, const cb_class *cls) {
    const cb_class *c;
    if (!cb_alive(o))
        return false;
    for (c = ((const cb_object *)o)->cls; c; c = c->parent)
        if (c == cls)
            return true;
    return false;
}

void *cb_as(void *o, const cb_class *cls) {
    return cb_is_a(o, cls) ? o : NULL;
}

int cb_object_count(void) {
    return cb_live_count;
}

static void cb_show_fields(FILE *f, const cb_class *cls, const void *o, bool *first) {
    int i;
    if (cls->parent)
        cb_show_fields(f, cls->parent, o, first);
    for (i = 0; i < cls->field_count; i++) {
        const cb_field *fd = &cls->fields[i];
        const void *at = (const char *)o + fd->offset;
        fputs(*first ? "" : ", ", f);
        *first = false;
        fprintf(f, "%s: ", fd->name);
        if (strcmp(fd->type, "string") == 0) {
            fputc('"', f); fd->show(f, at); fputc('"', f);
        } else {
            fd->show(f, at);
        }
    }
}

/* An object variable (a pointer to it): Enemy#3(health: 5, ...), none, or destroyed. */
void cb_show_object(FILE *f, const void *value) {
    const cb_object *o = *(const cb_object *const *)value;
    bool first = true;
    if (!o) { fputs("none", f); return; }
    if (!cb_alive(o)) { fputs("(a destroyed object)", f); return; }
    fprintf(f, "%s#%d(", o->cls->name, o->id);
    cb_show_fields(f, o->cls, o, &first);
    fputc(')', f);
}

/* An object's children (a copy: changing the list doesn't move them). */
cb_list *cb_children(void *o, int file, int brick) {
    return cb_list_copy(((cb_object *)cb_obj(o, file, brick))->children);
}

/* ---- the world: the Main scene's root (Godot's scene root), and everything under it ----
   The Game loop runs and draws it. A scene made with no parent (the Main scene at the
   start, Change scene) becomes the world (cb_world_adopt); a program whose Main scene is
   empty gets a plain Node named World the first time something goes in the world. */
static cb_object *cb_world_root = NULL;
static int cb_world_cap = 0;

void *cb_world(void) {
    if (!cb_world_root) {
        cb_world_root = (cb_object *)cb_new(&Node_class);
        cb_world_root->name = "World";
    }
    return cb_world_root;
}

/* `root` (a scene's root, made under nothing) becomes the world; what was in the world
   until now (put there while the scene was made) moves under it, the old root goes. */
void cb_world_adopt(void *root) {
    cb_object *r = (cb_object *)root, *old = cb_world_root;
    if (!r || r == old)
        return;
    cb_world_root = r;
    if (old && cb_alive(old)) {
        while (old->children->count > 0)
            cb_set_parent(((cb_object **)old->children->data)[0], r, 0, 0);
        cb_destroy(old, 0, 0);
    }
}

static int cb_world_put(cb_object *o, int n) {
    if (n >= cb_world_cap) {
        cb_world_cap = cb_world_cap ? cb_world_cap * 2 : 256;
        cb_world_list = (void **)realloc((void *)cb_world_list, sizeof(void *) * (size_t)cb_world_cap);
        if (!cb_world_list) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_world_list[n++] = o;
    return n;
}

static int cb_world_walk(cb_object *o, int n) {
    int i;
    for (i = 0; i < o->children->count; i++) {
        cb_object *c = ((cb_object **)o->children->data)[i];
        n = cb_world_put(c, n);
        n = cb_world_walk(c, n);
    }
    return n;
}

/* Every object in the world, the root first, each before its children (the list is reused each call). */
int cb_world_objects(void ***out) {
    int n = 0;
    if (cb_world_root)
        n = cb_world_walk(cb_world_root, cb_world_put(cb_world_root, 0));
    *out = cb_world_list;
    return n;
}

/* ---- When frame starts / When frame ends (dt): any plain script's, where its Side runs ---- */
typedef struct { int when; int side; int always; void (*fn)(double dt); } cb_frame_handler;  /* always: its script Runs while paused */
static cb_frame_handler *cb_frame_handlers = NULL;
static int cb_frame_handler_n = 0, cb_frame_handler_cap = 0;

void cb_on_frame(int when, int side, int always, void (*fn)(double dt)) {
    if (cb_frame_handler_n == cb_frame_handler_cap) {
        cb_frame_handler_cap = cb_frame_handler_cap ? cb_frame_handler_cap * 2 : 8;
        cb_frame_handlers = (cb_frame_handler *)realloc((void *)cb_frame_handlers, sizeof(cb_frame_handler) * (size_t)cb_frame_handler_cap);
        if (!cb_frame_handlers) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_frame_handlers[cb_frame_handler_n].when = when;
    cb_frame_handlers[cb_frame_handler_n].side = side;
    cb_frame_handlers[cb_frame_handler_n].always = always;
    cb_frame_handlers[cb_frame_handler_n].fn = fn;
    cb_frame_handler_n++;
}

/* when: 0 a frame starts (before the objects' Every frame), 1 it ends (after moves and touches, before drawing).
   frozen (paused, offline): only the handlers of scripts that Run while paused. */
void cb_frame_events(int when, double dt, bool frozen) {
    int i;
    for (i = 0; i < cb_frame_handler_n; i++)
        if (cb_frame_handlers[i].when == when && cb_side_runs(cb_frame_handlers[i].side) && (!frozen || cb_frame_handlers[i].always))
            cb_frame_handlers[i].fn(dt);
}

/* Every frame: each object's Every frame (an object destroyed meanwhile is skipped); frozen
   (paused, offline): only objects of classes that Run while paused. */
void cb_world_step(double dt, bool frozen) {
    void **all;
    int i, n = cb_world_objects(&all);
    void **copy;
    if (n == 0)
        return;
    copy = (void **)malloc(sizeof(void *) * (size_t)n);
    if (!copy) { fputs("out of memory\n", stderr); exit(3); }
    memcpy((void *)copy, (void *)all, sizeof(void *) * (size_t)n);
    cb_world_busy(1);
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)copy[i];
        if (cb_alive(o) && o->cls->frame && !o->net_id && (!frozen || o->cls->always))  /* (a client's copy: the server runs it) */
            o->cls->frame(o, dt);
    }
    cb_world_busy(-1);
    free((void *)copy);
}

/* The first object in the world with that name (NULL: none). */
void *cb_find_object(const char *name) {
    void **all;
    int i, n = cb_world_objects(&all);
    for (i = 0; i < n; i++)
        if (strcmp(((cb_object *)all[i])->name, name) == 0)
            return all[i];
    return NULL;
}

/* ---- groups (Brickscript's) and metadata (Godot's) ---- */
static int cb_group_index(const cb_object *o, const char *group) {
    int i;
    for (i = 0; i < o->groups->count; i++)
        if (strcmp(((const char **)o->groups->data)[i], group) == 0)
            return i;
    return -1;
}

void cb_group_add(void *object, const char *group, int file, int brick) {
    cb_object *o = (cb_object *)cb_obj(object, file, brick);
    if (cb_group_index(o, group) < 0)
        *(const char **)cb_list_add(o->groups) = group;
}

void cb_group_remove(void *object, const char *group, int file, int brick) {
    cb_object *o = (cb_object *)cb_obj(object, file, brick);
    int i = cb_group_index(o, group);
    if (i >= 0)
        cb_list_remove(o->groups, i, file, brick);
}

bool cb_in_group(void *object, const char *group, int file, int brick) {
    return cb_group_index((cb_object *)cb_obj(object, file, brick), group) >= 0;
}

cb_list *cb_objects_in_group(const char *group) {
    cb_list *out = cb_list_new(sizeof(cb_object *));
    void **all;
    int i, n = cb_world_objects(&all);
    for (i = 0; i < n; i++)
        if (cb_group_index((cb_object *)all[i], group) >= 0)
            *(cb_object **)cb_list_add(out) = (cb_object *)all[i];
    return out;
}

void cb_meta_set(void *object, const char *key, const char *value, int file, int brick) {
    *(const char **)cb_map_put(((cb_object *)cb_obj(object, file, brick))->meta, key) = value;
}

const char *cb_meta_get(void *object, const char *key, int file, int brick) {
    cb_map *m = ((cb_object *)cb_obj(object, file, brick))->meta;
    int i = cb_map_find(m, key);
    return i >= 0 ? ((const char **)m->values->data)[i] : "";
}

bool cb_meta_has(void *object, const char *key, int file, int brick) {
    return cb_map_find(((cb_object *)cb_obj(object, file, brick))->meta, key) >= 0;
}

void cb_meta_remove(void *object, const char *key, int file, int brick) {
    cb_map_remove(((cb_object *)cb_obj(object, file, brick))->meta, key);
}

/* ---- Wait (Brickscript's): sleeps, or (graphics, cb_wait_hook) keeps the world running ---- */
void (*cb_wait_hook)(double seconds) = NULL;

/* ---- networking's hooks (cb_net.c sets them in projects that use it) ----
   cb_poll_hook: the network's turn (Wait, every frame); cb_ready_hook: main() calls
   cb_ready() once the world is made (Player Joined runs from then on).
   cb_side_bits: where this program runs scripts: 1 server, 2 client, 3 both (offline,
   hosting); a script's Side is 1 Server, 2 Client, 3 Shared. */
void (*cb_poll_hook)(void) = NULL;
void (*cb_ready_hook)(void) = NULL;
/* A scene's Client Script objects in an instance made while the program runs (networking:
   they wait until the instance is this machine's player's; cb_net.c), and running them
   (cbricks_scene.c: each scene's Client scripts, `parent` = the instance's root). */
void (*cb_scene_client_hook)(void *root, int scene) = NULL;
void (*cb_scene_clients_run)(int scene, void *root) = NULL;
int (*cb_key_hook)(int key) = NULL;   /* a key held now (the window's; networking sends players' keys) */  /* StarterPlayer's scripts (cbricks_scene.c), per player */
int cb_side_bits = 3;
int cb_online = 0;                      /* in a network game (hosting, a server, a client): Pause doesn't freeze then */
double cb_world_scale = 1.0;            /* the time scale: this machine's offline; in a network game the server's, for everyone */
bool cb_headless = false;               /* a dedicated server: no window (graphics bricks skip drawing) */
double (*cb_clock_hook)(void) = NULL;   /* a steady clock (networking's), else CPU time */

double cb_now(void) {
    return cb_clock_hook ? cb_clock_hook() : (double)clock() / CLOCKS_PER_SEC;
}

bool cb_side_runs(int side) {
    return (side & cb_side_bits) != 0;
}

void cb_ready(void) {
    if (cb_ready_hook)
        cb_ready_hook();
}

void cb_wait(double seconds) {
    if (seconds <= 0)
        return;
    if (cb_wait_hook) {
        cb_wait_hook(seconds);
    } else if (cb_poll_hook) {  /* a text program in a network game: keep answering meanwhile */
#if defined(__DJGPP__)
        /* MS-DOS: delay() rounds up to a 55 ms timer tick, so a Wait counted in 10 ms steps ran 5 times too long
           (and each Watt-32 poll costs more): count the clock (DJGPP's clock() is wall time since the start) */
        double until = (double)clock() / CLOCKS_PER_SEC + seconds;
        while ((double)clock() / CLOCKS_PER_SEC < until) {
            cb_sleep_ms(10);
            cb_poll_hook();
        }
#else
        int left = (int)(seconds * 1000.0 + 0.5);
        while (left > 0) {
            int step = left < 10 ? left : 10;
            cb_sleep_ms(step);
            left -= step;
            cb_poll_hook();
        }
#endif
    } else {
        cb_sleep_ms((int)(seconds * 1000.0 + 0.5));
    }
}

/* ---- scenes (.cbscene: cbricks_scene.c has a function per scene) ----
   A scene's Script objects run their When program starts once the outermost scene
   being made is done (so a copy's root has its overrides). Change scene clears the
   world and makes another scene; asked for while the world's events run (Every frame,
   When touched, When drawn), it waits for the frame's start. */
typedef struct { void (*start)(void *parent_); void *parent; } cb_scene_start;
static cb_scene_start *cb_starts = NULL;
static int cb_starts_n = 0, cb_starts_cap = 0, cb_scene_depth = 0;
static bool cb_starts_running = false;
static int cb_busy = 0;
static void *(*cb_next_scene)(void *parent_) = NULL;

void cb_scene_enter(void) {
    cb_scene_depth++;
}

/* ---- scene keys (networking): the Main scene's objects, made at the start on every
   machine, are known by their place in it (a hash of the copies' and the object's ids
   in the scene files), so a client uses its own copy of what the server tells it about. */
static unsigned long cb_key_stack[32];
static int cb_key_depth = 0;
static bool cb_scene_keying = false;
void *(*cb_scene_match_hook)(unsigned long key, const cb_class *cls) = NULL;

void cb_scene_key_push(int id) {
    if (cb_key_depth < 32)
        cb_key_stack[cb_key_depth] = (unsigned long)id;
    cb_key_depth++;
}

void cb_scene_key_pop(void) {
    cb_key_depth--;
}

static unsigned long cb_scene_key(int id) {
    unsigned long h = 2166136261UL;
    int i;
    for (i = 0; i < cb_key_depth && i < 32; i++)
        h = ((h ^ cb_key_stack[i]) * 16777619UL) & 0xFFFFFFFFUL;
    h = ((h ^ (unsigned long)id) * 16777619UL) & 0xFFFFFFFFUL;
    return h ? h : 1;
}

/* A scene's object: the client's copy of the server's (when there's one), else a new one. */
void *cb_scene_new(const cb_class *cls, int id) {
    cb_object *o;
    unsigned long key = cb_scene_keying ? cb_scene_key(id) : 0;
    if (key && cb_scene_match_hook) {
        o = (cb_object *)cb_scene_match_hook(key, cls);
        if (o)
            return o;
    }
    o = (cb_object *)cb_new(cls);
    o->scene_key = key;
    return o;
}

/* Whether the scene sets its values on this object (not on a copy of the server's). */
bool cb_scene_fresh(const void *o) {
    return ((const cb_object *)o)->net_id == 0;
}

void cb_scene_keys(bool on) {
    cb_scene_keying = on;
}

/* A Client Script object of a scene: at the start (the Main scene) or without networking
   it runs where clients run, now; in an instance made while a network game runs, it runs
   on the machine whose player owns the instance (cb_scene_client_hook). */
void cb_scene_client(void (*start)(void *parent_), void *parent, void *root, int scene) {
    if (cb_scene_keying || !cb_scene_client_hook || !root) {
        if (cb_side_runs(2))
            cb_scene_run(start, parent);
        return;
    }
    if (!((cb_object *)root)->scene_of) {
        ((cb_object *)root)->scene_of = scene + 1;
        cb_scene_client_hook(root, scene);
    }
}

void cb_scene_run(void (*start)(void *parent_), void *parent) {
    if (cb_starts_n == cb_starts_cap) {
        cb_starts_cap = cb_starts_cap ? cb_starts_cap * 2 : 16;
        cb_starts = (cb_scene_start *)realloc((void *)cb_starts, sizeof(cb_scene_start) * (size_t)cb_starts_cap);
        if (!cb_starts) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_starts[cb_starts_n].start = start;
    cb_starts[cb_starts_n].parent = parent;
    cb_starts_n++;
}

void cb_scene_leave(void) {
    int i;
    if (--cb_scene_depth > 0 || cb_starts_running)
        return;
    cb_scene_keying = false;  /* (what Script objects make isn't the Main scene's) */
    cb_starts_running = true;
    for (i = 0; i < cb_starts_n; i++)  /* (a start may make more scenes: they're added on the end) */
        cb_starts[i].start(cb_starts[i].parent);
    cb_starts_n = 0;
    cb_starts_running = false;
}

/* The world goes, the scene's root becomes the new world (made under nothing). */
static void cb_change_now(void *(*scene)(void *parent_)) {
    if (cb_world_root) {
        cb_object *old = cb_world_root;
        cb_world_root = NULL;
        cb_destroy(old, 0, 0);
    }
    scene(NULL);
}

void cb_change_scene(void *(*scene)(void *parent_)) {
    if (cb_busy > 0)
        cb_next_scene = scene;
    else
        cb_change_now(scene);
}

void cb_world_busy(int delta) {
    cb_busy += delta;
}

void cb_scene_pending(void) {
    void *(*scene)(void *parent_) = cb_next_scene;
    if (scene && cb_busy == 0) {
        cb_next_scene = NULL;
        cb_change_now(scene);
    }
}
