/* ---- memory: every block is kept until the program ends, then freed ---- */
typedef union cb_block { union cb_block *next; double d; long l; void *p; } cb_block;
static cb_block *cb_blocks = NULL;
static cb_list *cb_lists = NULL;

void *cb_alloc(size_t size) {
    cb_block *b = (cb_block *)calloc(1, sizeof(cb_block) + size);
    if (!b) {
        fputs("out of memory\n", stderr);
        exit(3);
    }
    b->next = cb_blocks;
    cb_blocks = b;
    return b + 1;
}

static void cb_free_all(void) {
    while (cb_lists) {
        cb_list *next = cb_lists->next_list;
        free(cb_lists->data);
        cb_lists = next;
    }
    while (cb_blocks) {
        cb_block *next = cb_blocks->next;
        free(cb_blocks);
        cb_blocks = next;
    }
}

static void cb_error(int file, int brick, const char *what, int index, int count) {
    fprintf(stderr, "[error] %s brick %d: %s %d (the list has %d item%s)\n", cb_files[file], brick, what, index, count, count == 1 ? "" : "s");
    exit(1);
}

/* ---- lists ---- */
cb_list *cb_list_new(size_t elem) {
    cb_list *l = (cb_list *)cb_alloc(sizeof(cb_list));
    l->elem = elem;
    l->next_list = cb_lists;
    cb_lists = l;
    return l;
}

static void cb_list_grow(cb_list *l) {
    if (l->count < l->cap)
        return;
    l->cap = l->cap ? l->cap * 2 : 8;
    l->data = (char *)realloc(l->data, (size_t)l->cap * l->elem);
    if (!l->data) {
        fputs("out of memory\n", stderr);
        exit(3);
    }
}

void *cb_list_add(cb_list *l) {
    cb_list_grow(l);
    memset(l->data + (size_t)l->count * l->elem, 0, l->elem);
    return l->data + (size_t)(l->count++) * l->elem;
}

void *cb_list_insert(cb_list *l, int index, int file, int brick) {
    if (index < 0 || index > l->count)
        cb_error(file, brick, "can't insert at index", index, l->count);
    cb_list_grow(l);
    memmove(l->data + (size_t)(index + 1) * l->elem, l->data + (size_t)index * l->elem, (size_t)(l->count - index) * l->elem);
    l->count++;
    memset(l->data + (size_t)index * l->elem, 0, l->elem);
    return l->data + (size_t)index * l->elem;
}

void *cb_list_at(cb_list *l, int index, int file, int brick) {
    if (index < 0 || index >= l->count)
        cb_error(file, brick, "no item at index", index, l->count);
    return l->data + (size_t)index * l->elem;
}

void cb_list_remove(cb_list *l, int index, int file, int brick) {
    if (index < 0 || index >= l->count)
        cb_error(file, brick, "no item to remove at index", index, l->count);
    memmove(l->data + (size_t)index * l->elem, l->data + (size_t)(index + 1) * l->elem, (size_t)(l->count - index - 1) * l->elem);
    l->count--;
}

void cb_list_clear(cb_list *l) {
    l->count = 0;
}

void cb_list_reverse(cb_list *l) {
    int i;
    char *tmp = (char *)cb_alloc(l->elem);
    for (i = 0; i < l->count / 2; i++) {
        char *a = l->data + (size_t)i * l->elem;
        char *b = l->data + (size_t)(l->count - 1 - i) * l->elem;
        memcpy(tmp, a, l->elem);
        memcpy(a, b, l->elem);
        memcpy(b, tmp, l->elem);
    }
}

int cb_cmp_int(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

int cb_cmp_float(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int cb_cmp_bool(const void *a, const void *b) {
    return (int)*(const bool *)a - (int)*(const bool *)b;
}

int cb_cmp_string(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* ---- text ---- */
static char *cb_copy(const char *text, size_t n) {
    char *out = (char *)cb_alloc(n + 1);
    memcpy(out, text, n);
    out[n] = 0;
    return out;
}

const char *cb_join(const char *a, const char *b) {
    size_t na = strlen(a), nb = strlen(b);
    char *out = (char *)cb_alloc(na + nb + 1);
    memcpy(out, a, na);
    memcpy(out + na, b, nb + 1);
    return out;
}

const char *cb_format(const char *format, ...) {
    va_list args;
    int n;
    char *out;
    va_start(args, format);
    n = vsnprintf(NULL, 0, format, args);
    va_end(args);
    if (n < 0)
        return "";
    out = (char *)cb_alloc((size_t)n + 1);
    va_start(args, format);
    vsnprintf(out, (size_t)n + 1, format, args);
    va_end(args);
    return out;
}

int cb_len(const char *text) {
    return (int)strlen(text);
}

const char *cb_substr(const char *text, int start, int length) {
    int n = (int)strlen(text);
    if (start < 0) start = 0;
    if (start > n) start = n;
    if (length < 0 || start + length > n) length = n - start;
    return cb_copy(text + start, (size_t)length);
}

int cb_find(const char *text, const char *what) {
    const char *at = strstr(text, what);
    return at ? (int)(at - text) : -1;
}

const char *cb_replace(const char *text, const char *what, const char *with) {
    size_t nw = strlen(what), nn = strlen(with), count = 0;
    const char *p = text;
    char *out, *o;
    if (nw == 0)
        return text;
    while ((p = strstr(p, what)) != NULL) { count++; p += nw; }
    out = o = (char *)cb_alloc(strlen(text) + count * nn - count * nw + 1);
    p = text;
    for (;;) {
        const char *at = strstr(p, what);
        size_t k = at ? (size_t)(at - p) : strlen(p);
        memcpy(o, p, k);
        o += k;
        if (!at) break;
        memcpy(o, with, nn);
        o += nn;
        p = at + nw;
    }
    *o = 0;
    return out;
}

const char *cb_upper(const char *text) {
    char *out = cb_copy(text, strlen(text));
    char *p;
    for (p = out; *p; p++) *p = (char)toupper((unsigned char)*p);
    return out;
}

const char *cb_lower(const char *text) {
    char *out = cb_copy(text, strlen(text));
    char *p;
    for (p = out; *p; p++) *p = (char)tolower((unsigned char)*p);
    return out;
}

const char *cb_trim(const char *text) {
    const char *end = text + strlen(text);
    while (*text && isspace((unsigned char)*text)) text++;
    while (end > text && isspace((unsigned char)end[-1])) end--;
    return cb_copy(text, (size_t)(end - text));
}

cb_list *cb_split(const char *text, const char *separator) {
    cb_list *l = cb_list_new(sizeof(const char *));
    size_t ns = strlen(separator);
    for (;;) {
        const char *at = ns ? strstr(text, separator) : NULL;
        size_t k = at ? (size_t)(at - text) : strlen(text);
        *(const char **)cb_list_add(l) = cb_copy(text, k);
        if (!at) break;
        text = at + ns;
    }
    return l;
}

const char *cb_join_list(const cb_list *l, const char *separator) {
    size_t total = 1, ns = strlen(separator);
    int i;
    char *out, *o;
    for (i = 0; i < l->count; i++)
        total += strlen(((const char **)l->data)[i]) + (i ? ns : 0);
    out = o = (char *)cb_alloc(total);
    for (i = 0; i < l->count; i++) {
        const char *item = ((const char **)l->data)[i];
        size_t k = strlen(item);
        if (i) { memcpy(o, separator, ns); o += ns; }
        memcpy(o, item, k);
        o += k;
    }
    *o = 0;
    return out;
}

int cb_to_int(const char *text) {
    return (int)strtol(text, NULL, 10);
}

double cb_to_float(const char *text) {
    return strtod(text, NULL);
}

bool cb_starts_with(const char *text, const char *what) {
    return strncmp(text, what, strlen(what)) == 0;
}

bool cb_ends_with(const char *text, const char *what) {
    size_t n = strlen(text), k = strlen(what);
    return k <= n && strcmp(text + n - k, what) == 0;
}

/* ---- maps: text keys -> values of one type, in the order they were added ----
   keys / values are lists (index i belongs together); slots is a hash index
   (open addressing, a power-of-two size, each slot = item index + 1, 0 = empty). */
static unsigned long cb_hash(const char *key) {
    unsigned long h = 5381;
    while (*key)
        h = h * 33u + (unsigned char)*key++;
    return h;
}

static void cb_map_index(cb_map *m) {
    int i, size = 16;
    while (size < m->keys->count * 2 + 2)
        size *= 2;
    cb_list_clear(m->slots);
    for (i = 0; i < size; i++)
        *(int *)cb_list_add(m->slots) = 0;
    for (i = 0; i < m->keys->count; i++) {
        unsigned long at = cb_hash(((const char **)m->keys->data)[i]) & (unsigned long)(size - 1);
        while (((int *)m->slots->data)[at])
            at = (at + 1) & (unsigned long)(size - 1);
        ((int *)m->slots->data)[at] = i + 1;
    }
}

cb_map *cb_map_new(size_t elem) {
    cb_map *m = (cb_map *)cb_alloc(sizeof(cb_map));
    m->keys = cb_list_new(sizeof(const char *));
    m->values = cb_list_new(elem);
    m->slots = cb_list_new(sizeof(int));
    cb_map_index(m);
    return m;
}

int cb_map_find(const cb_map *m, const char *key) {
    unsigned long size = (unsigned long)m->slots->count;
    unsigned long at = cb_hash(key) & (size - 1);
    int slot;
    while ((slot = ((const int *)m->slots->data)[at]) != 0) {
        if (strcmp(((const char **)m->keys->data)[slot - 1], key) == 0)
            return slot - 1;
        at = (at + 1) & (size - 1);
    }
    return -1;
}

void *cb_map_put(cb_map *m, const char *key) {
    int i = cb_map_find(m, key);
    if (i >= 0)
        return m->values->data + (size_t)i * m->values->elem;
    *(const char **)cb_list_add(m->keys) = cb_copy(key, strlen(key));
    if (m->keys->count * 2 + 2 > m->slots->count)
        cb_map_index(m);
    else {
        unsigned long size = (unsigned long)m->slots->count;
        unsigned long at = cb_hash(key) & (size - 1);
        while (((int *)m->slots->data)[at])
            at = (at + 1) & (size - 1);
        ((int *)m->slots->data)[at] = m->keys->count;
    }
    return cb_list_add(m->values);
}

void *cb_map_get(cb_map *m, const char *key, int file, int brick) {
    int i = cb_map_find(m, key);
    if (i < 0) {
        fprintf(stderr, "[error] %s brick %d: no key \"%s\" in the map (it has %d key%s)\n", cb_files[file], brick, key, m->keys->count, m->keys->count == 1 ? "" : "s");
        exit(1);
    }
    return m->values->data + (size_t)i * m->values->elem;
}

void cb_map_remove(cb_map *m, const char *key) {
    int i = cb_map_find(m, key);
    if (i < 0)
        return;
    cb_list_remove(m->keys, i, 0, 0);
    cb_list_remove(m->values, i, 0, 0);
    cb_map_index(m);
}

void cb_map_clear(cb_map *m) {
    cb_list_clear(m->keys);
    cb_list_clear(m->values);
    cb_map_index(m);
}

static cb_list *cb_list_copy(const cb_list *from) {
    cb_list *l = cb_list_new(from->elem);
    int i;
    for (i = 0; i < from->count; i++)
        memcpy(cb_list_add(l), from->data + (size_t)i * from->elem, from->elem);
    return l;
}

cb_list *cb_map_keys(const cb_map *m) { return cb_list_copy(m->keys); }
cb_list *cb_map_values(const cb_map *m) { return cb_list_copy(m->values); }

/* ---- showing values (Print, the debugger) ---- */
void cb_show_int(FILE *f, const void *value) { fprintf(f, "%d", *(const int *)value); }
void cb_show_float(FILE *f, const void *value) { fprintf(f, "%g", *(const double *)value); }
void cb_show_bool(FILE *f, const void *value) { fputs(*(const bool *)value ? "true" : "false", f); }
void cb_show_string(FILE *f, const void *value) { fputs(*(const char *const *)value, f); }

void cb_show_list(FILE *f, const cb_list *l, void (*show)(FILE *, const void *)) {
    int i;
    fputc('[', f);
    for (i = 0; l && i < l->count; i++) {
        if (i) fputs(", ", f);
        show(f, l->data + (size_t)i * l->elem);
    }
    fputc(']', f);
}

void cb_show_map(FILE *f, const cb_map *m, void (*show)(FILE *, const void *)) {
    int i;
    fputc('{', f);
    for (i = 0; m && i < m->keys->count; i++) {
        if (i) fputs(", ", f);
        fprintf(f, "\"%s\": ", ((const char **)m->keys->data)[i]);
        show(f, m->values->data + (size_t)i * m->values->elem);
    }
    fputc('}', f);
}

/* ---- system ---- */
void cb_sleep_ms(int ms) {
    if (ms <= 0)
        return;
#if defined(_WIN32)
    Sleep((unsigned long)ms);
#elif defined(__DJGPP__)
    {   /* MS-DOS: DJGPP's <dos.h> delay(), declared here (-std=c99 hides it) */
        void delay(unsigned msec);
        delay((unsigned)ms);
    }
#elif defined(__unix__) || defined(__APPLE__) || defined(__wasi__) || defined(__HAIKU__)
    {
        struct timespec t;
        t.tv_sec = ms / 1000;
        t.tv_nsec = (long)(ms % 1000) * 1000000L;
        nanosleep(&t, NULL);
    }
#else
    {   /* no sleep call on this platform: wait on the clock */
        clock_t until = clock() + (clock_t)((double)ms * CLOCKS_PER_SEC / 1000.0);
        while (clock() < until) { }
    }
#endif
}

const char *cb_env(const char *name) {
    const char *v = getenv(name);
    return v ? v : "";
}

int cb_run(const char *command) {
#if defined(__wasi__)
    (void)command;
    return -1;
#else
    fflush(stdout);
    return system(command);
#endif
}

/* Lists of the basic types, for the debugger (a pointer to the list variable). */
void cb_show_int_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_int); }
void cb_show_float_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_float); }
void cb_show_bool_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_bool); }
void cb_show_string_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_string); }
void cb_show_int_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_int); }
void cb_show_float_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_float); }
void cb_show_bool_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_bool); }
void cb_show_string_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_string); }

/* ---- vectors (vector3: raylib's Vector3, floats) ---- */
Vector3 cb_v3(double x, double y, double z) {
    Vector3 v;
    v.x = (float)x; v.y = (float)y; v.z = (float)z;
    return v;
}
Vector3 cb_v3_add(Vector3 a, Vector3 b) { return cb_v3(a.x + b.x, a.y + b.y, a.z + b.z); }
Vector3 cb_v3_sub(Vector3 a, Vector3 b) { return cb_v3(a.x - b.x, a.y - b.y, a.z - b.z); }
Vector3 cb_v3_scale(Vector3 a, double k) { return cb_v3(a.x * k, a.y * k, a.z * k); }
double cb_v3_dot(Vector3 a, Vector3 b) { return (double)a.x * b.x + (double)a.y * b.y + (double)a.z * b.z; }
double cb_v3_length(Vector3 a) { return sqrt(cb_v3_dot(a, a)); }
Vector3 cb_v3_normalize(Vector3 a) {
    double n = cb_v3_length(a);
    return n > 0 ? cb_v3_scale(a, 1.0 / n) : a;
}
Vector3 cb_v3_lerp(Vector3 a, Vector3 b, double t) { return cb_v3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t); }
Vector3 cb_v3_cross(Vector3 a, Vector3 b) {
    return cb_v3((double)a.y * b.z - (double)a.z * b.y, (double)a.z * b.x - (double)a.x * b.z, (double)a.x * b.y - (double)a.y * b.x);
}
const char *cb_v3_text(Vector3 a) { return cb_format("(%g, %g, %g)", a.x, a.y, a.z); }
void cb_show_vector3(FILE *f, const void *value) {
    const Vector3 *v = (const Vector3 *)value;
    fprintf(f, "(%g, %g, %g)", v->x, v->y, v->z);
}
void cb_show_vector3_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_vector3); }
void cb_show_vector3_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_vector3); }

/* ---- vectors (vector2: raylib's Vector2, floats) ---- */
Vector2 cb_v2(double x, double y) {
    Vector2 v;
    v.x = (float)x; v.y = (float)y;
    return v;
}
Vector2 cb_v2_add(Vector2 a, Vector2 b) { return cb_v2(a.x + b.x, a.y + b.y); }
Vector2 cb_v2_sub(Vector2 a, Vector2 b) { return cb_v2(a.x - b.x, a.y - b.y); }
Vector2 cb_v2_scale(Vector2 a, double k) { return cb_v2(a.x * k, a.y * k); }
double cb_v2_dot(Vector2 a, Vector2 b) { return (double)a.x * b.x + (double)a.y * b.y; }
double cb_v2_length(Vector2 a) { return sqrt(cb_v2_dot(a, a)); }
Vector2 cb_v2_normalize(Vector2 a) {
    double n = cb_v2_length(a);
    return n > 0 ? cb_v2_scale(a, 1.0 / n) : a;
}
Vector2 cb_v2_lerp(Vector2 a, Vector2 b, double t) { return cb_v2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t); }
double cb_v2_cross(Vector2 a, Vector2 b) { return (double)a.x * b.y - (double)a.y * b.x; }
const char *cb_v2_text(Vector2 a) { return cb_format("(%g, %g)", a.x, a.y); }
void cb_show_vector2(FILE *f, const void *value) {
    const Vector2 *v = (const Vector2 *)value;
    fprintf(f, "(%g, %g)", v->x, v->y);
}
void cb_show_vector2_list(FILE *f, const void *value) { cb_show_list(f, *(cb_list *const *)value, cb_show_vector2); }
void cb_show_vector2_map(FILE *f, const void *value) { cb_show_map(f, *(cb_map *const *)value, cb_show_vector2); }
