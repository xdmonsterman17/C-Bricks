/* ---- shader graphs (.cbshader), the C emitter (2026-11-18) ----
   Appended to cbricks_gfx.c (after the generated `cb_sg_table_parts`: the node table, scripts/shader_nodes.json).
   It must give the same GLSL text as scripts/shader_graph.gd (ShaderGraph.compile): see that file for the format and
   the emission rules; runner check `shader_graph` compares them. cb_shadergraph_glsl returns malloc'd GLSL, or NULL
   with a message in err. */

typedef struct cb_jv {
    int t;                 /* 0 null / true / false, 1 number, 2 string, 3 array, 4 object */
    double n;
    char *s;
    struct cb_jv *kids;
    char **keys;           /* objects only */
    int count;
} cb_jv;

static void cb_jv_free(cb_jv *v) {
    int i;
    for (i = 0; i < v->count; i++) {
        cb_jv_free(&v->kids[i]);
        if (v->keys) free(v->keys[i]);
    }
    free(v->kids);
    free(v->keys);
    free(v->s);
}

static void cb_jv_ws(const char **p) { while (**p == ' ' || **p == '\n' || **p == '\r' || **p == '\t') (*p)++; }

static char *cb_jv_string(const char **p) {   /* at the opening quote */
    size_t cap = 16, n = 0;
    char *s = (char *)malloc(cap);
    if (!s) return NULL;
    (*p)++;
    while (**p && **p != '"') {
        char ch = **p;
        (*p)++;
        if (ch == '\\') {
            ch = **p;
            if (ch) (*p)++;
            if (ch == 'n') ch = '\n';
            else if (ch == 't') ch = '\t';
            else if (ch == 'u') { int k; for (k = 0; k < 4 && **p; k++) (*p)++; ch = '?'; }
        }
        if (n + 2 > cap) { cap *= 2; s = (char *)realloc(s, cap); if (!s) return NULL; }
        s[n++] = ch;
    }
    if (**p == '"') (*p)++;
    s[n] = 0;
    return s;
}

static int cb_jv_parse(const char **p, cb_jv *v, int depth) {
    memset(v, 0, sizeof *v);
    cb_jv_ws(p);
    if (depth > 32) return 0;
    if (**p == '{' || **p == '[') {
        char close = **p == '{' ? '}' : ']';
        v->t = **p == '{' ? 4 : 3;
        (*p)++;
        for (;;) {
            char *key = NULL;
            cb_jv_ws(p);
            if (**p == close) { (*p)++; break; }
            if (!**p) return 0;
            if (v->t == 4) {
                if (**p != '"') return 0;
                key = cb_jv_string(p);
                cb_jv_ws(p);
                if (**p != ':') { free(key); return 0; }
                (*p)++;
            }
            v->kids = (cb_jv *)realloc((void *)v->kids, sizeof(cb_jv) * (size_t)(v->count + 1));
            if (v->t == 4) v->keys = (char **)realloc((void *)v->keys, sizeof(char *) * (size_t)(v->count + 1));
            if (!v->kids || (v->t == 4 && !v->keys)) return 0;
            if (v->t == 4) v->keys[v->count] = key;
            if (!cb_jv_parse(p, &v->kids[v->count], depth + 1)) { v->count++; return 0; }
            v->count++;
            cb_jv_ws(p);
            if (**p == ',') (*p)++;
        }
        return 1;
    }
    if (**p == '"') { v->t = 2; v->s = cb_jv_string(p); return v->s != NULL; }
    if (**p == 't') { v->t = 1; v->n = 1; (*p) += 4; return 1; }
    if (**p == 'f') { (*p) += 5; return 1; }
    if (**p == 'n') { (*p) += 4; return 1; }
    {
        char *end;
        v->n = strtod(*p, &end);
        if (end == *p) return 0;
        v->t = 1;
        *p = end;
        return 1;
    }
}

static const cb_jv *cb_jv_get(const cb_jv *o, const char *k) {
    int i;
    if (!o || o->t != 4) return NULL;
    for (i = 0; i < o->count; i++)
        if (strcmp(o->keys[i], k) == 0) return &o->kids[i];
    return NULL;
}
static const char *cb_jv_str(const cb_jv *v, const char *d) { return v && v->t == 2 ? v->s : d; }

#define CB_SG_EXPR 512
/* snprintf whose result is checked (a too-long expression is cut, never overflows) */
static int cb_sg_cut;
#define CB_SG_PF(buf, size, ...) do { if (snprintf(buf, size, __VA_ARGS__) >= (int)(size)) cb_sg_cut = 1; } while (0)
typedef struct { int id; char out[32]; char type[8]; } cb_sg_var;
typedef struct {
    const cb_jv *nodes, *wires, *tab;
    char kl;
    char *text; size_t len, cap;
    cb_sg_var *vars; int nvars;
    char *state;
    char err[240];
} cb_sg;

static void cb_sg_problem(cb_sg *g, const char *title, int id, const char *msg) {
    if (g->err[0]) return;
    snprintf(g->err, sizeof g->err, "%s (node %d): %s", title, id, msg);
}

static void cb_sg_add(cb_sg *g, const char *s) {
    size_t n = strlen(s);
    if (g->len + n + 1 > g->cap) {
        g->cap = (g->len + n + 1) * 2;
        g->text = (char *)realloc(g->text, g->cap);
        if (!g->text) { fputs("out of memory\n", stderr); exit(3); }
    }
    memcpy(g->text + g->len, s, n + 1);
    g->len += n;
}

static int cb_sg_size(const char *t) {
    return strcmp(t, "vec2") == 0 ? 2 : strcmp(t, "vec3") == 0 ? 3 : strcmp(t, "vec4") == 0 ? 4 : 1;
}

static void cb_sg_num(char *dst, size_t n, double v) {
    size_t l;
    snprintf(dst, n, "%.4f", v);
    l = strlen(dst);
    while (l > 1 && dst[l - 1] == '0' && dst[l - 2] != '.') dst[--l] = 0;
    if (strcmp(dst, "-0.0") == 0) strcpy(dst, "0.0");
}

static void cb_sg_literal(char *dst, const cb_jv *vals, const char *type) {
    int n = cb_sg_size(type), i;
    char part[40], all[CB_SG_EXPR];
    all[0] = 0;
    for (i = 0; i < n; i++) {
        double v = 0;
        if (vals && vals->t == 3 && vals->count > 0)
            v = vals->kids[i < vals->count ? i : vals->count - 1].n;
        cb_sg_num(part, sizeof part, v);
        if (i) strcat(all, ", ");
        strcat(all, part);
    }
    if (n == 1) CB_SG_PF(dst, CB_SG_EXPR, "%s", all);
    else CB_SG_PF(dst, CB_SG_EXPR, "%s(%s)", type, all);
}

static void cb_sg_coerce(char *dst, const char *e, const char *from, const char *to) {
    int fs = cb_sg_size(from), ts = cb_sg_size(to);
    if (strcmp(from, to) == 0) CB_SG_PF(dst, CB_SG_EXPR, "%s", e);
    else if (fs == 1) CB_SG_PF(dst, CB_SG_EXPR, "%s(%s)", to, e);
    else if (fs > ts) CB_SG_PF(dst, CB_SG_EXPR, "%s.%.*s", e, ts, "xyzw");
    else if (fs == 2 && ts == 3) CB_SG_PF(dst, CB_SG_EXPR, "vec3(%s, 0.0)", e);
    else if (fs == 2 && ts == 4) CB_SG_PF(dst, CB_SG_EXPR, "vec4(%s, 0.0, 1.0)", e);
    else CB_SG_PF(dst, CB_SG_EXPR, "vec4(%s, 1.0)", e);
}

static int cb_sg_index(cb_sg *g, int id) {
    int i;
    for (i = 0; i < g->nodes->count; i++) {
        const cb_jv *n = cb_jv_get(&g->nodes->kids[i], "id");
        if (n && (int)n->n == id) return i;
    }
    return -1;
}

static const char *cb_sg_var_type(cb_sg *g, int id, const char *out) {
    int i;
    for (i = 0; i < g->nvars; i++)
        if (g->vars[i].id == id && strcmp(g->vars[i].out, out) == 0) return g->vars[i].type;
    return NULL;
}

static const char *cb_sg_type_of(const cb_jv *node, const char *t) {
    if (strcmp(t, "gen") != 0) return t;
    return cb_jv_str(cb_jv_get(node, "t"), "float");
}

static const cb_jv *cb_sg_def(cb_sg *g, const cb_jv *node) { return cb_jv_get(g->tab, cb_jv_str(cb_jv_get(node, "type"), "")); }
static int cb_sg_id(const cb_jv *node) { const cb_jv *n = cb_jv_get(node, "id"); return n ? (int)n->n : 0; }

static void cb_sg_emit_node(cb_sg *g, int idx, char *first);

static void cb_sg_input_expr(cb_sg *g, const cb_jv *node, const cb_jv *inp, char *dst) {
    const cb_jv *def = cb_sg_def(g, node);
    const char *iname = inp->kids[0].s;
    const char *want = cb_sg_type_of(node, inp->kids[1].s);
    const cb_jv *w = NULL;
    int i, nid = cb_sg_id(node);
    for (i = 0; i < g->wires->count; i++) {
        const cb_jv *c = &g->wires->kids[i];
        const cb_jv *to = cb_jv_get(c, "to");
        if (to && (int)to->n == nid && strcmp(cb_jv_str(cb_jv_get(c, "in"), ""), iname) == 0) { w = c; break; }
    }
    if (w) {
        const cb_jv *from = cb_jv_get(w, "from");
        int sid = from ? (int)from->n : -1;
        int si = cb_sg_index(g, sid);
        const char *oname = cb_jv_str(cb_jv_get(w, "out"), "");
        if (si < 0) {
            cb_sg_problem(g, cb_jv_str(cb_jv_get(def, "title"), "?"), nid, "a wire comes from a missing node.");
        } else {
            char srct[8];
            const char *vt;
            cb_sg_emit_node(g, si, srct);
            vt = cb_sg_var_type(g, sid, oname);
            if (vt) {
                char name[80];
                snprintf(name, sizeof name, "v%d_%s", sid, oname);
                cb_sg_coerce(dst, name, vt, want);
                return;
            }
            if (srct[0])
                cb_sg_problem(g, cb_jv_str(cb_jv_get(def, "title"), "?"), nid, "a wire reads an output that does not exist.");
        }
        strcpy(dst, "0.0");
        return;
    }
    if (inp->kids[2].t == 2) { CB_SG_PF(dst, CB_SG_EXPR, "%s", inp->kids[2].s); return; }
    {
        const cb_jv *vals = cb_jv_get(cb_jv_get(node, "values"), iname);
        cb_sg_literal(dst, vals ? vals : &inp->kids[2], want);
    }
}

static void cb_sg_emit_node(cb_sg *g, int idx, char *first) {
    const cb_jv *node = &g->nodes->kids[idx];
    const cb_jv *def = cb_sg_def(g, node);
    const cb_jv *ins, *outs, *code;
    int id = cb_sg_id(node), i, k;
    char subs[8][CB_SG_EXPR];
    first[0] = 0;
    if (!def) {
        cb_sg_problem(g, "Node", id, "unknown type.");
        return;
    }
    ins = cb_jv_get(def, "in"); outs = cb_jv_get(def, "out"); code = cb_jv_get(def, "code");
    if (g->state[idx] == 2) {
        if (outs->count) { const char *t = cb_sg_var_type(g, id, outs->kids[0].kids[0].s); snprintf(first, 8, "%s", t ? t : "float"); }
        return;
    }
    if (g->state[idx] == 1) {
        cb_sg_problem(g, cb_jv_str(cb_jv_get(def, "title"), "?"), id, "the wires loop back to it.");
        return;
    }
    g->state[idx] = 1;
    if (!strchr(cb_jv_str(cb_jv_get(def, "kinds"), ""), g->kl))
        cb_sg_problem(g, cb_jv_str(cb_jv_get(def, "title"), "?"), id, g->kl == 'p' ? "not available in post shaders." : "not available in surface shaders.");
    for (i = 0; i < ins->count && i < 8; i++)
        cb_sg_input_expr(g, node, &ins->kids[i], subs[i]);
    for (k = 0; k < outs->count; k++) {
        const cb_jv *o = &outs->kids[k];
        const char *ot = cb_sg_type_of(node, o->kids[1].s);
        const char *c = code->kids[k].s;
        char line[CB_SG_EXPR * 2], expr[CB_SG_EXPR * 2];
        size_t n = 0;
        while (*c && n + 2 < sizeof expr) {
            if (*c == '{') {
                const char *e = strchr(c, '}');
                if (e) {
                    for (i = 0; i < ins->count && i < 8; i++) {
                        size_t l = strlen(ins->kids[i].kids[0].s);
                        if ((size_t)(e - c - 1) == l && strncmp(c + 1, ins->kids[i].kids[0].s, l) == 0) {
                            size_t sl = strlen(subs[i]);
                            if (n + sl + 1 < sizeof expr) { memcpy(expr + n, subs[i], sl); n += sl; }
                            break;
                        }
                    }
                    c = e + 1;
                    continue;
                }
            }
            expr[n++] = *c++;
        }
        expr[n] = 0;
        CB_SG_PF(line, sizeof line, "    %s v%d_%s = %s;\n", ot, id, o->kids[0].s, expr);
        cb_sg_add(g, line);
        g->vars = (cb_sg_var *)realloc((void *)g->vars, sizeof(cb_sg_var) * (size_t)(g->nvars + 1));
        if (!g->vars) { fputs("out of memory\n", stderr); exit(3); }
        g->vars[g->nvars].id = id;
        snprintf(g->vars[g->nvars].out, sizeof g->vars[g->nvars].out, "%s", o->kids[0].s);
        snprintf(g->vars[g->nvars].type, sizeof g->vars[g->nvars].type, "%s", ot);
        g->nvars++;
        if (!first[0]) snprintf(first, 8, "%s", ot);
    }
    g->state[idx] = 2;
}

char *cb_shadergraph_glsl(const char *json, int kind, char *err, size_t errn) {
    cb_jv graph, table;
    cb_sg g;
    const char *p = json;
    const char *outtype = kind == CB_SHADER_POST ? "post_out" : "surface_out";
    const cb_jv *outdef, *gk;
    char *text = NULL;
    int i, oi = -1;
    char exprs[2][CB_SG_EXPR];
    size_t tl = 0;
    memset(&g, 0, sizeof g);
    memset(&table, 0, sizeof table);
    err[0] = 0;
    cb_sg_cut = 0;
    if (!cb_jv_parse(&p, &graph, 0) || graph.t != 4) { snprintf(err, errn, "not a shader graph (the JSON does not parse)"); cb_jv_free(&graph); return NULL; }
    for (i = 0; (size_t)i < sizeof(cb_sg_table_parts) / sizeof(cb_sg_table_parts[0]); i++) tl += strlen(cb_sg_table_parts[i]);
    text = (char *)malloc(tl + 1);
    if (!text) { cb_jv_free(&graph); return NULL; }
    text[0] = 0;
    for (i = 0; (size_t)i < sizeof(cb_sg_table_parts) / sizeof(cb_sg_table_parts[0]); i++) strcat(text, cb_sg_table_parts[i]);
    p = text;
    if (!cb_jv_parse(&p, &table, 0)) { snprintf(err, errn, "the node table does not parse"); goto done; }
    g.tab = cb_jv_get(&table, "nodes");
    g.nodes = cb_jv_get(&graph, "nodes");
    g.wires = cb_jv_get(&graph, "wires");
    gk = cb_jv_get(&graph, "kind");
    if (!g.tab || !g.nodes || g.nodes->t != 3) { snprintf(err, errn, "not a shader graph (no nodes)"); goto done; }
    {
        static const cb_jv none = {3, 0, NULL, NULL, NULL, 0};
        if (!g.wires) g.wires = &none;
    }
    if (strcmp(cb_jv_str(gk, "surface"), kind == CB_SHADER_POST ? "post" : "surface") != 0) {
        snprintf(err, errn, "this is a %s shader, used as a %s shader", cb_jv_str(gk, "surface"), kind == CB_SHADER_POST ? "post" : "surface");
        goto done;
    }
    g.kl = kind == CB_SHADER_POST ? 'p' : 's';
    g.state = (char *)calloc((size_t)g.nodes->count + 1, 1);
    for (i = 0; i < g.nodes->count; i++)
        if (strcmp(cb_jv_str(cb_jv_get(&g.nodes->kids[i], "type"), ""), outtype) == 0) { oi = i; break; }
    if (oi < 0) { snprintf(err, errn, "no output node"); goto done; }
    outdef = cb_jv_get(g.tab, outtype);
    {
        const cb_jv *ins = cb_jv_get(outdef, "in");
        for (i = 0; i < ins->count && i < 2; i++)
            cb_sg_input_expr(&g, &g.nodes->kids[oi], &ins->kids[i], exprs[i]);
    }
    if (!g.err[0] && cb_sg_cut) snprintf(g.err, sizeof g.err, "an expression is too long");
    if (g.err[0]) { snprintf(err, errn, "%s", g.err); goto done; }
    {
        char head[CB_SG_EXPR * 2 + 120];
        if (kind == CB_SHADER_POST) snprintf(head, sizeof head, "    return %s;\n}\n", exprs[0]);
        else snprintf(head, sizeof head, "    return vec4(%s, %s);\n}\n", exprs[0], exprs[1]);
        {
            char *out;
            const char *start = kind == CB_SHADER_POST ? "vec3 cb_post(vec3 c, vec2 uv) {\n" : "vec4 cb_surface(vec4 base, vec2 uv, vec3 normal) {\n";
            cb_sg_add(&g, "");  /* g.text exists even for a graph with no lines */
            out = (char *)malloc(strlen(start) + g.len + strlen(head) + 1);
            if (out) {
                strcpy(out, start);
                if (g.text) strcat(out, g.text);
                strcat(out, head);
                free(g.text); free(g.vars); free(g.state); free(text);
                cb_jv_free(&graph); cb_jv_free(&table);
                return out;
            }
        }
    }
done:
    free(g.text); free(g.vars); free(g.state); free(text);
    cb_jv_free(&graph); cb_jv_free(&table);
    return NULL;
}
