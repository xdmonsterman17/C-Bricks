/* ---- C-Bricks runtime: flags, program arguments, files, asserts, trace, debugger ----
   Portable C99; the OS-specific bits (sleep, chdir, the Windows console) are behind
   platform checks. cb_program, cb_version, cb_files, cb_help and cb_register()
   come from the generated part above. */
#include <stdarg.h>
#include <ctype.h>
#if defined(_WIN32)
/* The four Win32 calls the runtime needs, declared here instead of including
   <windows.h>, which clashes with raylib.h (Rectangle, CloseWindow...). */
__declspec(dllimport) void __stdcall Sleep(unsigned long ms);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned long which);
__declspec(dllimport) int __stdcall GetConsoleMode(void *console, unsigned long *mode);
__declspec(dllimport) int __stdcall SetConsoleMode(void *console, unsigned long mode);
#include <direct.h>
#define CB_CHDIR(d) _chdir(d)
#elif defined(__DJGPP__)
/* MS-DOS (DJGPP): its headers hide chdir under -std=c99 (__STRICT_ANSI__); its libc has it. */
int chdir(const char *path);
#define CB_CHDIR(d) chdir(d)
#elif defined(__unix__) || defined(__APPLE__) || defined(__wasi__) || defined(__HAIKU__)
#include <unistd.h>
#define CB_CHDIR(d) chdir(d)
#else
#define CB_CHDIR(d) (-1)
#endif

bool cb_verbose = false;
static bool cb_trace_on = false;
static bool cb_timing = false;
static long cb_steps = 0;
const char *cb_click_spec = NULL;  /* --click X:Y:AT (tests: a left click in the window; cb_gfx.c) */
static long cb_max_steps = 0;
static clock_t cb_clock0;
static time_t cb_time0;
static int cb_argc_ = 0;
static char **cb_argv_ = NULL;

static void cb_free_all(void);
static void cb_break_set(const char *spec, bool on);

static void cb_usage(const char *exe) {
    printf("%s %s (made with C-Bricks)\n\nUsage: %s [options] [program arguments]\n\nOptions:\n%s", cb_program, cb_version, exe, cb_help);
}

static void cb_report_time(void) {
    fprintf(stderr, "[time] %.3f s CPU, %.0f s wall, %ld bricks run\n",
            (double)(clock() - cb_clock0) / CLOCKS_PER_SEC, difftime(time(NULL), cb_time0), cb_steps);
}

static void cb_fail(const char *what, const char *value) {
    fprintf(stderr, "%s: %s%s\n", cb_program, what, value ? value : "");
    exit(2);
}

/* --flag=value or --flag value */
static const char *cb_value(int *i, int argc, char **argv, const char *flag) {
    size_t n = strlen(flag);
    if (argv[*i][n] == '=')
        return argv[*i] + n + 1;
    if (*i + 1 >= argc)
        cb_fail("missing value for ", flag);
    *i += 1;
    return argv[*i];
}

static bool cb_is(const char *arg, const char *flag) {
    size_t n = strlen(flag);
    return strncmp(arg, flag, n) == 0 && (arg[n] == 0 || arg[n] == '=');
}

static long cb_number(const char *text, const char *flag) {
    char *end = NULL;
    long v = strtol(text, &end, 10);
    if (end == text || *end != 0)
        cb_fail("not a number for ", flag);
    return v;
}

/* ---- the debugger: breakpoints, pause, step, variables ----
   The editor runs the program with --debug FILE and appends commands to FILE:
   continue, step (into), next (step over), out (step out), pause, stop,
   break <script>:<brick>, clear <script>:<brick>.
   Call depth comes from the frames seen: each function call has its own
   cb_frame (a local), so a frame not on the stack is a new call, and one
   lower on it means the calls above it have returned (pointer equality only).
   Pausing prints "[pause] <script>:<brick>", one "[var] name<TAB>type<TAB>value"
   per variable and "[end]" on stderr, then waits for a command. */
static const char *cb_debug_file = NULL;
static long cb_debug_offset = 0;
enum { CB_RUN, CB_STEP_INTO, CB_STEP_OVER, CB_STEP_OUT };
static int cb_step_mode = CB_RUN;
static int cb_step_depth = 0;       /* the depth paused at, for over / out */
static const cb_frame **cb_calls = NULL;  /* the live frames, outermost first */
static int cb_depth = 0, cb_calls_cap = 0;
static bool cb_pause_asked = false;
static bool cb_paused = false;
static int *cb_bps = NULL;          /* pairs: file, brick */
static int cb_bp_count = 0;
static clock_t cb_last_poll = 0;

static int cb_file_index(const char *name, size_t n) {
    int i;
    for (i = 0; i < (int)(sizeof cb_files / sizeof cb_files[0]); i++)
        if (strlen(cb_files[i]) == n && strncmp(cb_files[i], name, n) == 0)
            return i;
    return -1;
}

/* "main.cbricks:4" (several with commas) on or off. */
static void cb_break_set(const char *spec, bool on) {
    while (*spec) {
        const char *end = strchr(spec, ',');
        const char *colon;
        size_t n = end ? (size_t)(end - spec) : strlen(spec);
        colon = spec + n;
        while (colon > spec && *colon != ':') colon--;
        if (*colon == ':') {
            int file = cb_file_index(spec, (size_t)(colon - spec));
            int brick = atoi(colon + 1);
            int i, at = -1;
            for (i = 0; i < cb_bp_count; i++)
                if (cb_bps[2 * i] == file && cb_bps[2 * i + 1] == brick)
                    at = i;
            if (on && at < 0 && file >= 0) {
                cb_bps = (int *)realloc(cb_bps, sizeof(int) * 2 * (size_t)(cb_bp_count + 1));
                if (cb_bps) {
                    cb_bps[2 * cb_bp_count] = file;
                    cb_bps[2 * cb_bp_count + 1] = brick;
                    cb_bp_count++;
                }
            } else if (!on && at >= 0) {
                cb_bps[2 * at] = cb_bps[2 * (cb_bp_count - 1)];
                cb_bps[2 * at + 1] = cb_bps[2 * (cb_bp_count - 1) + 1];
                cb_bp_count--;
            }
        }
        spec += n;
        if (*spec == ',') spec++;
    }
}

static void cb_debug_command(char *line) {
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' ')) line[--n] = 0;
    if (strcmp(line, "continue") == 0) { cb_paused = false; cb_step_mode = CB_RUN; }
    else if (strcmp(line, "step") == 0) { cb_paused = false; cb_step_mode = CB_STEP_INTO; }
    else if (strcmp(line, "next") == 0) { cb_paused = false; cb_step_mode = CB_STEP_OVER; }
    else if (strcmp(line, "out") == 0) { cb_paused = false; cb_step_mode = CB_STEP_OUT; }
    else if (strcmp(line, "pause") == 0) cb_pause_asked = true;
    else if (strcmp(line, "stop") == 0) { fprintf(stderr, "[stopped]\n"); exit(130); }
    else if (strncmp(line, "break ", 6) == 0) cb_break_set(line + 6, true);
    else if (strncmp(line, "clear ", 6) == 0) cb_break_set(line + 6, false);
}

/* Reads the commands added to the file since last time. */
static void cb_debug_poll(void) {
    FILE *f;
    char line[512];
    if (!cb_debug_file)
        return;
    f = fopen(cb_debug_file, "rb");
    if (!f)
        return;
    if (fseek(f, cb_debug_offset, SEEK_SET) == 0) {
        while (fgets(line, sizeof line, f)) {
            if (strchr(line, '\n') == NULL)
                break;  /* a line still being written: read it next time */
            if (!cb_paused && (strncmp(line, "continue", 8) == 0 || strncmp(line, "step", 4) == 0
                               || strncmp(line, "next", 4) == 0 || strncmp(line, "out", 3) == 0))
                break;  /* resumes are for a pause: it stays in the file until one */
            cb_debug_offset += (long)strlen(line);
            {
                bool was_paused = cb_paused;
                cb_debug_command(line);
                if (was_paused && !cb_paused)
                    break;  /* one resume per pause: the next lines wait for the next pause */
            }
        }
    }
    fclose(f);
    cb_last_poll = clock();
}

/* A value on one line (newlines and tabs escaped), at most ~400 characters. */
static void cb_debug_value(const cb_var *v) {
#if defined(__wasi__)
    v->show(stderr, v->ptr);  /* WASI has no tmpfile(): printed as it is */
}
#else
    FILE *t = tmpfile();
    int c, count = 0;
    if (!t) {
        v->show(stderr, v->ptr);
        return;
    }
    v->show(t, v->ptr);
    rewind(t);
    while ((c = fgetc(t)) != EOF) {
        if (++count > 400) { fputs("...", stderr); break; }
        if (c == '\n') fputs("\\n", stderr);
        else if (c == '\t') fputs("\\t", stderr);
        else fputc(c, stderr);
    }
    fclose(t);
}
#endif

static void cb_debug_pause(int file, int brick, const cb_frame *frame) {
    int i;
    fflush(stdout);
    fprintf(stderr, "[pause] %s:%d\n", cb_files[file], brick);
    fprintf(stderr, "[depth] %d\n", cb_depth);
    for (i = 0; frame && i < frame->count; i++) {
        fprintf(stderr, "[var] %s\t%s\t", frame->vars[i].name, frame->vars[i].type);
        cb_debug_value(&frame->vars[i]);
        fputc('\n', stderr);
    }
    for (i = 0; frame && i < frame->global_count; i++) {
        fprintf(stderr, "[global] %s\t%s\t", frame->globals[i].name, frame->globals[i].type);
        cb_debug_value(&frame->globals[i]);
        fputc('\n', stderr);
    }
    fputs("[end]\n", stderr);
    fflush(stderr);
    cb_step_mode = CB_RUN;
    cb_step_depth = cb_depth;
    cb_pause_asked = false;
    cb_paused = true;
    while (cb_paused) {
        cb_debug_poll();
        if (cb_paused)
            cb_sleep_ms(30);
    }
    fputs("[resume]\n", stderr);
}

/* Which call this brick runs in: 0 = the outermost (main, or an exit handler). */
static void cb_track_depth(const cb_frame *frame) {
    int i;
    for (i = cb_depth; i >= 0 && cb_calls; i--) {
        if (cb_calls[i] == frame) {
            cb_depth = i;  /* the same call, or the calls above it returned */
            return;
        }
    }
    if (cb_calls == NULL) {
        cb_depth = 0;  /* the first brick: the outermost call */
    } else {
        cb_depth++;
    }
    if (cb_depth >= cb_calls_cap) {
        cb_calls_cap = cb_calls_cap ? cb_calls_cap * 2 : 64;
        cb_calls = (const cb_frame **)realloc((void *)cb_calls, sizeof(const cb_frame *) * (size_t)cb_calls_cap);
        if (!cb_calls) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_calls[cb_depth] = frame;
}

void cb_trace_hit(int file, int brick, const cb_frame *frame) {
    cb_steps++;
    if (cb_trace_on)
        fprintf(stderr, "[trace] %s:%d\n", cb_files[file], brick);
    if (cb_max_steps > 0 && cb_steps > cb_max_steps) {
        fprintf(stderr, "[%s] stopped after %ld bricks (--max-steps), at %s brick %d\n", cb_program, cb_max_steps, cb_files[file], brick);
        exit(124);
    }
    if (cb_debug_file) {
        int i;
        bool hit;
        cb_track_depth(frame);
        hit = cb_pause_asked || cb_step_mode == CB_STEP_INTO
            || (cb_step_mode == CB_STEP_OVER && cb_depth <= cb_step_depth)
            || (cb_step_mode == CB_STEP_OUT && cb_depth < cb_step_depth);
        /* Look for new commands (Pause, breakpoints) about 10 times a second. */
        if ((cb_steps & 255) == 0 && clock() - cb_last_poll > CLOCKS_PER_SEC / 10)
            cb_debug_poll();
        hit = hit || cb_pause_asked;
        for (i = 0; !hit && i < cb_bp_count; i++)
            hit = cb_bps[2 * i] == file && cb_bps[2 * i + 1] == brick;
        if (hit)
            cb_debug_pause(file, brick, frame);
    }
}

void cb_start(int argc, char **argv) {
    int i, kept = 1;
    unsigned seed = (unsigned)time(NULL);
    atexit(cb_free_all);  /* registered first: runs last */
    setvbuf(stdout, NULL, _IONBF, 0);
#if defined(_WIN32)
    {   /* ANSI colors / cursor codes (Terminal brick) in the Windows console */
        void *out = GetStdHandle((unsigned long)-11 /* STD_OUTPUT_HANDLE */);
        unsigned long mode = 0;
        if (out != (void *)-1 && GetConsoleMode(out, &mode))
            SetConsoleMode(out, mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
    }
#endif
    cb_clock0 = clock();
    cb_time0 = time(NULL);
    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--") == 0) { i++; break; }
        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) { cb_usage(argv[0]); exit(0); }
        else if (strcmp(a, "--version") == 0) { printf("%s %s\n", cb_program, cb_version); exit(0); }
        else if (strcmp(a, "--trace") == 0) cb_trace_on = true;
        else if (strcmp(a, "-v") == 0 || strcmp(a, "--verbose") == 0) cb_verbose = true;
        else if (strcmp(a, "--time") == 0) cb_timing = true;
        else if (cb_is(a, "--seed")) seed = (unsigned)cb_number(cb_value(&i, argc, argv, "--seed"), "--seed");
        else if (cb_is(a, "--max-steps")) cb_max_steps = cb_number(cb_value(&i, argc, argv, "--max-steps"), "--max-steps");
        else if (cb_is(a, "--input")) { const char *f = cb_value(&i, argc, argv, "--input"); if (!freopen(f, "r", stdin)) cb_fail("can't read --input ", f); }
        else if (cb_is(a, "--output")) { const char *f = cb_value(&i, argc, argv, "--output"); if (!freopen(f, "w", stdout)) cb_fail("can't write --output ", f); setvbuf(stdout, NULL, _IONBF, 0); }
        else if (cb_is(a, "--cd")) { const char *d = cb_value(&i, argc, argv, "--cd"); if (CB_CHDIR(d) != 0) cb_fail("can't change to --cd ", d); }
        else if (cb_is(a, "--debug")) cb_debug_file = cb_value(&i, argc, argv, "--debug");
        else if (cb_is(a, "--break")) cb_break_set(cb_value(&i, argc, argv, "--break"), true);
        else if (cb_is(a, "--click")) cb_click_spec = cb_value(&i, argc, argv, "--click");
#if defined(CB_NET)
        else if (cb_is(a, "--server")) cb_net_option("server", cb_value(&i, argc, argv, "--server"));
        else if (cb_is(a, "--host")) cb_net_option("host", cb_value(&i, argc, argv, "--host"));
        else if (cb_is(a, "--join")) cb_net_option("join", cb_value(&i, argc, argv, "--join"));
        else if (cb_is(a, "--name")) cb_net_option("name", cb_value(&i, argc, argv, "--name"));
        else if (cb_is(a, "--press")) cb_net_option("press", cb_value(&i, argc, argv, "--press"));
#endif
        else argv[kept++] = argv[i];
    }
    for (; i < argc; i++)
        argv[kept++] = argv[i];
    cb_argc_ = kept;
    cb_argv_ = argv;
    srand(seed);
    if (cb_timing)
        atexit(cb_report_time);
    if (cb_debug_file)
        cb_debug_poll();  /* commands written before the start (breakpoints) */
    cb_register();
}

int cb_arg_count(void) { return cb_argc_ > 0 ? cb_argc_ - 1 : 0; }

const char *cb_arg(int index) {
    return (index >= 0 && index + 1 < cb_argc_) ? cb_argv_[index + 1] : "";
}

/* Program option --name=value / --name value / -name value ("" when not given). */
const char *cb_option(const char *name) {
    int i;
    size_t n = strlen(name);
    for (i = 1; i < cb_argc_; i++) {
        const char *a = cb_argv_[i];
        while (*a == '-') a++;
        if (a == cb_argv_[i] || strncmp(a, name, n) != 0) continue;
        if (a[n] == '=') return a + n + 1;
        if (a[n] == 0 && i + 1 < cb_argc_) return cb_argv_[i + 1];
    }
    return "";
}

bool cb_flag(const char *name) {
    int i;
    size_t n = strlen(name);
    for (i = 1; i < cb_argc_; i++) {
        const char *a = cb_argv_[i];
        while (*a == '-') a++;
        if (a != cb_argv_[i] && strncmp(a, name, n) == 0 && (a[n] == 0 || a[n] == '='))
            return strcmp(a + n, "=false") != 0 && strcmp(a + n, "=0") != 0;
    }
    return false;
}

const char *cb_read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    char *text;
    long size;
    size_t got;
    if (!f) {
        if (cb_verbose) fprintf(stderr, "[debug] can't read %s\n", path);
        return "";
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    text = (char *)cb_alloc(size > 0 ? (size_t)size + 1 : 1);
    got = size > 0 ? fread(text, 1, (size_t)size, f) : 0;
    text[got] = 0;
    fclose(f);
    return text;  /* kept until the program ends */
}

bool cb_write_file(const char *path, const char *text, bool append) {
    FILE *f = fopen(path, append ? "ab" : "wb");
    bool ok;
    if (!f) return false;
    ok = fputs(text, f) >= 0;
    return fclose(f) == 0 && ok;
}

bool cb_file_exists(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fclose(f);
    return true;
}

void cb_assert(bool ok, int file, int brick, const char *message) {
    if (ok) return;
    fprintf(stderr, "[assert] %s brick %d: %s\n", cb_files[file], brick, message);
    exit(1);
}

