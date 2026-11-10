/* ---- C-Bricks networking, part 2: roles, players, the protocol ----------------------
   Appended to cbricks_runtime.c in projects that use networking (the Network bricks,
   the Player class). The sockets are in cbricks_socket.c (cb_udp_*).

   Roles: offline (the default: single-player, this machine is its own server and its
   player is player 1), host (a server with its own player, player 1), dedicated server
   (--server: no player of its own) and client (--join, or the Join brick).
   Every machine keeps a Player object per player under the Players object (Roblox's
   Players service; outside the world, so Change scene keeps them): Player Joined runs
   for each, the players already there included, Player Left before one is destroyed.
   Scripts run where their Side says: cb_side_bits (cbricks_runtime.c) is 1 on a server,
   2 on a client, 3 offline / hosting (both).

   Protocol (UDP, every packet "CN", a version, a kind):
     DATA  seq (4 bytes) + one message: sent until the other side ACKs it, delivered in
           order (one ahead of a gap is kept until the gap fills)
     ACK   seq          PING  (nothing: keeps a quiet link alive)
     BYE   (leaving: sent a few times, not acknowledged)
   Messages: HELLO build + name (client -> server), WELCOME your number + every player,
   REFUSE why, JOINED number + name, LEFT number.
   A link that hears nothing for CB_NET_TIMEOUT seconds is closed. */
typedef struct cb_addr { unsigned char ip[4]; unsigned short port; } cb_addr;
bool cb_udp_open(int port);
void cb_udp_close(void);
bool cb_udp_resolve(const char *host, int port, cb_addr *out);
bool cb_udp_send(const cb_addr *to, const void *data, int size);
int cb_udp_recv(cb_addr *from, void *buffer, int capacity);
int cb_udp_port(void);
const char *cb_udp_error(void);
double cb_udp_now(void);

#define CB_NET_VERSION 1
#define CB_NET_PEERS 32       /* clients a server takes */
#define CB_NET_MTU 1200
#define CB_NET_WINDOW 64      /* messages kept that arrived ahead of a gap */
#define CB_NET_RESEND 0.15
#define CB_NET_KEEPALIVE 0.5
#define CB_NET_TIMEOUT 5.0

enum { CB_K_DATA = 1, CB_K_ACK, CB_K_PING, CB_K_BYE };
enum { CB_M_HELLO = 1, CB_M_WELCOME, CB_M_REFUSE, CB_M_JOINED, CB_M_LEFT, CB_M_WORLD, CB_M_REMOTE, CB_M_KEYS, CB_M_ASK, CB_M_ANSWER };
enum { CB_ROLE_OFFLINE, CB_ROLE_HOST, CB_ROLE_SERVER, CB_ROLE_CLIENT };

typedef struct { unsigned char d[CB_NET_MTU]; int n; } cb_pack;
typedef struct { const unsigned char *d; int n, at; bool bad; } cb_unpack;
typedef struct { unsigned long seq; int size; double sent; unsigned char data[CB_NET_MTU]; } cb_waiting;

typedef struct {
    bool used, welcomed;
    bool synced;                /* (a server's client) has been sent the whole world */
    cb_addr addr;
    int number;                 /* their player's number (a server's peers) */
    double heard, said;         /* when we last got / sent anything */
    unsigned long send_seq;     /* the next DATA's number */
    unsigned long recv_seq;     /* the DATA expected next */
    cb_waiting *out;            /* sent, not acknowledged yet */
    int out_n, out_cap;
    unsigned char *early[CB_NET_WINDOW];  /* arrived ahead: by seq % window */
    int early_size[CB_NET_WINDOW];
} cb_peer;

typedef struct { bool joined; int side; void (*fn)(int player); } cb_net_handler;
static void cb_world_message(cb_unpack *u);
static int cb_owner_number(cb_object *o);
static unsigned long cb_get32u(cb_unpack *u);
static void cb_keys_set(int number, unsigned long hi, unsigned long lo);
static void cb_remote_arrived(cb_unpack *u, cb_peer *from);
static void cb_ask_arrived(cb_unpack *u, cb_peer *from);
static void cb_answer_arrived(cb_unpack *u);
static void cb_ask_run(int remote, int sender, long request, const unsigned char *data, int size, bool local);
static void cb_copies_release(void);
static void cb_rep_clear(void);
/* A queued event: a player joined / left, or a remote arrived (remote >= 0: its values
   in data, for the handlers of `side`: 1 On Client Fired, 2 On Server Fired, 4 On Client
   Invoked: an Invoke Server's question, `request` its number at the asker). */
typedef struct { bool joined; int player; int remote, side, size; unsigned char *data; int key; long request; } cb_net_event;  /* key >= 0: a Player Key (joined: pressed) */
typedef struct { int key; bool pressed; void (*fn)(int player); } cb_key_handler;
static cb_key_handler *cb_key_handlers = NULL;
static int cb_key_handler_n = 0, cb_key_handler_cap = 0;
typedef struct { int remote, side; void (*fn)(int sender); } cb_remote_handler;
static cb_remote_handler *cb_remote_handlers = NULL;
static int cb_remote_handler_n = 0, cb_remote_handler_cap = 0;
static cb_unpack cb_msg_in;  /* the values a remote's handler reads */

static int cb_net_role = CB_ROLE_OFFLINE;
static cb_peer cb_peers[CB_NET_PEERS];   /* a client's server is cb_peers[0] */
static int cb_net_next_number = 2;       /* player 1: the host, or you offline */
static char cb_net_name[48] = "";        /* this machine's player name (--name) */
static char cb_net_build[64] = "";       /* program + version + build: others must match */
static char cb_net_refused[160] = "";
static int cb_net_want = CB_ROLE_OFFLINE, cb_net_want_port = 7000;
static char cb_net_want_address[128] = "127.0.0.1";
static int cb_net_me_num = 0;            /* this machine's player (0: none, a dedicated server) */
static cb_net_handler *cb_net_handlers = NULL;
static int cb_net_handler_n = 0, cb_net_handler_cap = 0;
static cb_net_event *cb_net_events = NULL;
static int cb_net_event_n = 0, cb_net_event_cap = 0;
static bool cb_net_is_ready = false, cb_net_delivering = false;

static void cb_net_note(const char *what) {
    fprintf(stderr, "[net] %s\n", what);
}

/* ---- packing ---- */
static void cb_put8(cb_pack *p, int v) { if (p->n < CB_NET_MTU) p->d[p->n++] = (unsigned char)(v & 255); }
static void cb_put16(cb_pack *p, int v) { cb_put8(p, v >> 8); cb_put8(p, v); }
static void cb_put32(cb_pack *p, unsigned long v) { cb_put16(p, (int)((v >> 16) & 0xFFFF)); cb_put16(p, (int)(v & 0xFFFF)); }
static void cb_put_text(cb_pack *p, const char *s) {
    int n = (int)strlen(s);
    if (n > 255) n = 255;
    cb_put8(p, n);
    while (n-- > 0) cb_put8(p, (unsigned char)*s++);
}
static int cb_get8(cb_unpack *u) { if (u->at >= u->n) { u->bad = true; return 0; } return u->d[u->at++]; }
static int cb_get16(cb_unpack *u) { int a = cb_get8(u); return (a << 8) | cb_get8(u); }
static void cb_get_text(cb_unpack *u, char *out, int cap) {
    int n = cb_get8(u), i;
    for (i = 0; i < n; i++) {
        int c = cb_get8(u);
        if (i < cap - 1) out[i] = (char)c;
    }
    out[n < cap - 1 ? n : cap - 1] = 0;
}
static void cb_head(cb_pack *p, int kind) { p->n = 0; cb_put8(p, 'C'); cb_put8(p, 'N'); cb_put8(p, CB_NET_VERSION); cb_put8(p, kind); }

static bool cb_same_addr(const cb_addr *a, const cb_addr *b) {
    return memcmp(a->ip, b->ip, 4) == 0 && a->port == b->port;
}

/* ---- players: numbers (the host, or you offline, is 1), each machine's own table ----
   (user, 2026-11-07: no Player class; a game's own classes hold players' data.)
   A leaving player still answers (name) while Player Left runs, then goes. */
typedef struct { int number; char name[48]; bool leaving; } cb_player_rec;
static cb_player_rec *cb_player_recs = NULL;
static int cb_player_n = 0, cb_player_cap = 0;

static const char *cb_net_copy(const char *s) {
    char *t = (char *)cb_alloc(strlen(s) + 1);
    strcpy(t, s);
    return t;
}

static cb_player_rec *cb_player_rec_of(int number) {
    int i;
    for (i = 0; i < cb_player_n; i++)
        if (cb_player_recs[i].number == number)
            return &cb_player_recs[i];
    return NULL;
}

/* Whether a number is a player in the game now (not one leaving). */
bool cb_net_in_game(int number) {
    cb_player_rec *r = cb_player_rec_of(number);
    return r != NULL && !r->leaving;
}

const char *cb_net_player_name(int number) {
    cb_player_rec *r = cb_player_rec_of(number);
    return r ? cb_net_copy(r->name) : "";
}

static void cb_player_drop(int number) {
    int i;
    for (i = 0; i < cb_player_n; i++) {
        if (cb_player_recs[i].number == number) {
            cb_player_recs[i] = cb_player_recs[--cb_player_n];
            return;
        }
    }
}

static cb_net_event *cb_net_queue_slot(void) {
    cb_net_event *e;
    if (cb_net_event_n == cb_net_event_cap) {
        cb_net_event_cap = cb_net_event_cap ? cb_net_event_cap * 2 : 16;
        cb_net_events = (cb_net_event *)realloc((void *)cb_net_events, sizeof(cb_net_event) * (size_t)cb_net_event_cap);
        if (!cb_net_events) { fputs("out of memory\n", stderr); exit(3); }
    }
    e = &cb_net_events[cb_net_event_n++];
    memset(e, 0, sizeof *e);
    e->remote = -1;
    e->key = -1;
    return e;
}

static void cb_net_queue(bool joined, int player) {
    cb_net_event *e = cb_net_queue_slot();
    e->joined = joined;
    e->player = player;
}

/* A remote's values (a copy) for this machine's handlers of `side`. */
static void cb_net_queue_remote(int remote, int side, int sender, const unsigned char *data, int size) {
    cb_net_event *e = cb_net_queue_slot();
    e->remote = remote;
    e->side = side;
    e->player = sender;
    e->size = size;
    e->data = (unsigned char *)malloc((size_t)size + 1);
    if (!e->data) { fputs("out of memory\n", stderr); exit(3); }
    memcpy(e->data, data, (size_t)size);
}

static void cb_net_add_player(int number, const char *name, bool me) {
    cb_player_rec *r;
    if (cb_player_n == cb_player_cap) {
        cb_player_cap = cb_player_cap ? cb_player_cap * 2 : 8;
        cb_player_recs = (cb_player_rec *)realloc((void *)cb_player_recs, sizeof(cb_player_rec) * (size_t)cb_player_cap);
        if (!cb_player_recs) { fputs("out of memory\n", stderr); exit(3); }
    }
    r = &cb_player_recs[cb_player_n++];
    memset(r, 0, sizeof *r);
    r->number = number;
    sprintf(r->name, "%.46s", name);
    if (me)
        cb_net_me_num = number;
    cb_net_queue(true, number);
}

/* Player Left runs first (it can still read the player's name), then it goes. */
static void cb_net_remove_player(int number) {
    cb_player_rec *r = cb_player_rec_of(number);
    if (!r || r->leaving)
        return;
    r->leaving = true;
    if (number == cb_net_me_num)
        cb_net_me_num = 0;
    cb_net_queue(false, number);
}

static void cb_net_remove_all(void) {
    int i;
    for (i = 0; i < cb_player_n; i++)
        if (!cb_player_recs[i].leaving)
            cb_net_remove_player(cb_player_recs[i].number);
}

void cb_net_on_player(bool joined, int side, void (*fn)(int player)) {
    if (cb_net_handler_n == cb_net_handler_cap) {
        cb_net_handler_cap = cb_net_handler_cap ? cb_net_handler_cap * 2 : 8;
        cb_net_handlers = (cb_net_handler *)realloc((void *)cb_net_handlers, sizeof(cb_net_handler) * (size_t)cb_net_handler_cap);
        if (!cb_net_handlers) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_net_handlers[cb_net_handler_n].joined = joined;
    cb_net_handlers[cb_net_handler_n].side = side;
    cb_net_handlers[cb_net_handler_n].fn = fn;
    cb_net_handler_n++;
}

/* Runs the queued Player Joined / Left (once the program is ready: its world made). */
static void cb_net_deliver(void) {
    int i, h;
    if (!cb_net_is_ready || cb_net_delivering)
        return;
    cb_net_delivering = true;
    for (i = 0; i < cb_net_event_n; i++) {  /* (a handler may add more: they're on the end) */
        cb_net_event e = cb_net_events[i];
        if (e.remote >= 0 && e.side == 4) {  /* a question (Invoke Server): its handlers, then the answer */
            cb_ask_run(e.remote, e.player, e.request, e.data, e.size, false);
            free((void *)e.data);
            continue;
        }
        if (e.remote >= 0) {
            for (h = 0; h < cb_remote_handler_n; h++) {
                if (cb_remote_handlers[h].remote != e.remote || cb_remote_handlers[h].side != e.side)
                    continue;
                cb_msg_in.d = e.data; cb_msg_in.n = e.size; cb_msg_in.at = 0; cb_msg_in.bad = false;
                cb_remote_handlers[h].fn(e.player);
            }
            free((void *)e.data);
            continue;
        }
        if (e.key >= 0) {  /* Player Key: where the rules run */
            for (h = 0; h < cb_key_handler_n; h++)
                if (cb_key_handlers[h].key == e.key && cb_key_handlers[h].pressed == e.joined && cb_side_runs(1) && cb_player_rec_of(e.player))
                    cb_key_handlers[h].fn(e.player);
            continue;
        }
        for (h = 0; h < cb_net_handler_n; h++)
            if (cb_net_handlers[h].joined == e.joined && cb_side_runs(cb_net_handlers[h].side) && cb_player_rec_of(e.player))
                cb_net_handlers[h].fn(e.player);
        if (!e.joined)
            cb_player_drop(e.player);
    }
    cb_net_event_n = 0;
    cb_net_delivering = false;
}

/* ---- links ---- */
static void cb_peer_free(cb_peer *p) {
    int i;
    free((void *)p->out);
    for (i = 0; i < CB_NET_WINDOW; i++)
        free((void *)p->early[i]);
    memset(p, 0, sizeof *p);
}

static cb_peer *cb_peer_new(const cb_addr *addr) {
    int i;
    for (i = 0; i < CB_NET_PEERS; i++) {
        if (!cb_peers[i].used) {
            memset(&cb_peers[i], 0, sizeof cb_peers[i]);
            cb_peers[i].used = true;
            cb_peers[i].addr = *addr;
            cb_peers[i].heard = cb_peers[i].said = cb_udp_now();
            return &cb_peers[i];
        }
    }
    return NULL;
}

static void cb_raw(cb_peer *p, const cb_pack *k) {
    cb_udp_send(&p->addr, k->d, k->n);
    p->said = cb_udp_now();
}

static void cb_signal(cb_peer *p, int kind) {
    cb_pack k;
    cb_head(&k, kind);
    cb_raw(p, &k);
}

/* A message (msg: its bytes) sent until acknowledged. */
static void cb_send(cb_peer *p, const cb_pack *msg) {
    cb_waiting *w;
    cb_pack k;
    if (p->out_n == p->out_cap) {
        p->out_cap = p->out_cap ? p->out_cap * 2 : 16;
        p->out = (cb_waiting *)realloc((void *)p->out, sizeof(cb_waiting) * (size_t)p->out_cap);
        if (!p->out) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_head(&k, CB_K_DATA);
    cb_put32(&k, p->send_seq);
    memcpy(k.d + k.n, msg->d, (size_t)(msg->n < CB_NET_MTU - k.n ? msg->n : CB_NET_MTU - k.n));
    k.n += msg->n < CB_NET_MTU - k.n ? msg->n : CB_NET_MTU - k.n;
    w = &p->out[p->out_n++];
    w->seq = p->send_seq++;
    w->size = k.n;
    memcpy(w->data, k.d, (size_t)k.n);
    w->sent = cb_udp_now();
    cb_raw(p, &k);
}

static void cb_bye_all(void) {
    int i, times;
    for (times = 0; times < 3; times++)
        for (i = 0; i < CB_NET_PEERS; i++)
            if (cb_peers[i].used)
                cb_signal(&cb_peers[i], CB_K_BYE);
}

static void cb_net_close(void) {
    int i;
    for (i = 0; i < CB_NET_PEERS; i++)
        if (cb_peers[i].used)
            cb_peer_free(&cb_peers[i]);
    cb_udp_close();
}

static void cb_side_set(int role) {
    cb_net_role = role;
    cb_side_bits = role == CB_ROLE_SERVER ? 1 : role == CB_ROLE_CLIENT ? 2 : 3;
    cb_online = role != CB_ROLE_OFFLINE;  /* (Pause and time scale only change the world offline) */
}

/* Back to single-player: you are player 1 again (a client keeps the world it had, as its own). */
static void cb_net_go_offline(void) {
    if (cb_net_role == CB_ROLE_CLIENT)
        cb_copies_release();
    else
        cb_rep_clear();
    cb_net_close();
    cb_net_remove_all();
    cb_side_set(CB_ROLE_OFFLINE);
    cb_net_add_player(1, cb_net_name, true);
}

/* ---- the server's side ---- */
static const char *cb_unique_name(const char *want) {
    static char name[64];
    int n = 1;
    sprintf(name, "%.40s", want[0] ? want : "Player");
    while (1) {
        int i;
        bool taken = false;
        for (i = 0; i < cb_player_n; i++)
            if (!cb_player_recs[i].leaving && strcmp(cb_player_recs[i].name, name) == 0)
                taken = true;
        if (!taken)
            return name;
        sprintf(name, "%.40s_%d", want[0] ? want : "Player", ++n);
    }
}

static void cb_tell_others(const cb_peer *except, const cb_pack *msg) {
    int i;
    for (i = 0; i < CB_NET_PEERS; i++)
        if (cb_peers[i].used && cb_peers[i].welcomed && &cb_peers[i] != except)
            cb_send(&cb_peers[i], msg);
}

static void cb_server_drop(cb_peer *p, const char *why) {
    cb_pack m;
    if (p->welcomed) {
        char line[160];
        sprintf(line, "player %d left (%.100s)", p->number, why);
        if (cb_verbose) cb_net_note(line);
        m.n = 0;
        cb_put8(&m, CB_M_LEFT);
        cb_put16(&m, p->number);
        p->welcomed = false;
        cb_tell_others(p, &m);
        cb_net_remove_player(p->number);
    }
    cb_peer_free(p);
}

static void cb_server_message(cb_peer *p, cb_unpack *u) {
    int type = cb_get8(u);
    if (type == CB_M_REMOTE && p->welcomed) {
        cb_remote_arrived(u, p);
        return;
    }
    if (type == CB_M_ASK && p->welcomed) {
        cb_ask_arrived(u, p);
        return;
    }
    if (type == CB_M_KEYS && p->welcomed) {
        unsigned long hi = cb_get32u(u), lo = cb_get32u(u);
        if (!u->bad)
            cb_keys_set(p->number, hi, lo);
        return;
    }
    if (type == CB_M_HELLO && !p->welcomed) {
        char build[64], name[48];
        cb_pack m;
        int i;
        const char *unique;
        cb_get_text(u, build, sizeof build);
        cb_get_text(u, name, sizeof name);
        if (u->bad || strcmp(build, cb_net_build) != 0) {
            m.n = 0;
            cb_put8(&m, CB_M_REFUSE);
            cb_put_text(&m, "the server runs a different build of the game");
            cb_send(p, &m);
            cb_send(p, &m);  /* (a copy or two: the link is closed right after) */
            cb_send(p, &m);
            cb_peer_free(p);
            return;
        }
        unique = cb_unique_name(name);
        p->number = cb_net_next_number++;
        p->welcomed = true;
        cb_net_add_player(p->number, unique, false);
        m.n = 0;
        cb_put8(&m, CB_M_WELCOME);
        cb_put16(&m, p->number);
        {
            int count = 0;
            for (i = 0; i < cb_player_n; i++)
                if (!cb_player_recs[i].leaving)
                    count++;
            cb_put16(&m, count);
            for (i = 0; i < cb_player_n; i++) {
                if (cb_player_recs[i].leaving)
                    continue;
                cb_put16(&m, cb_player_recs[i].number);
                cb_put_text(&m, cb_player_recs[i].name);
            }
        }
        cb_send(p, &m);
        m.n = 0;
        cb_put8(&m, CB_M_JOINED);
        cb_put16(&m, p->number);
        cb_put_text(&m, unique);
        cb_tell_others(p, &m);
    }
}

/* ---- the client's side ---- */
static void cb_client_message(cb_unpack *u) {
    int type = cb_get8(u);
    char name[64];
    if (type == CB_M_WELCOME) {
        int you = cb_get16(u), count = cb_get16(u), i;
        cb_net_remove_all();  /* single-player's you leaves: the server's players arrive */
        for (i = 0; i < count && !u->bad; i++) {
            int number = cb_get16(u);
            cb_get_text(u, name, sizeof name);
            cb_net_add_player(number, name, number == you);
        }
        cb_peers[0].welcomed = true;
    } else if (type == CB_M_REFUSE) {
        cb_get_text(u, cb_net_refused, sizeof cb_net_refused);
        if (!cb_net_refused[0]) strcpy(cb_net_refused, "refused");
    } else if (type == CB_M_JOINED) {
        int number = cb_get16(u);
        cb_get_text(u, name, sizeof name);
        if (!u->bad && !cb_net_in_game(number))
            cb_net_add_player(number, name, false);
    } else if (type == CB_M_LEFT) {
        int number = cb_get16(u);
        if (!u->bad)
            cb_net_remove_player(number);
    } else if (type == CB_M_WORLD) {
        cb_world_message(u);
    } else if (type == CB_M_REMOTE) {
        cb_remote_arrived(u, NULL);
    } else if (type == CB_M_ANSWER) {
        cb_answer_arrived(u);
    }
}

/* ---- replication (stage 3b): the world, from the server to its clients ----
   The server keeps a record per object of the world it has told about (cb_rep: its
   number, parent, name, its Synced fields as last sent). 30 times a second it walks
   the world and sends what changed, to every client that has the whole world:
   made (class, parent, name, scene key), re-parented, renamed, destroyed, Synced
   fields. A client that has just joined gets the whole world first, then
   SNAPSHOT_END. Not sent: objects in the group "local" or of a Client class, and
   what's under them (a HUD, a camera of one's own: every machine makes its own).
   A client's copies (cb_object.net_id = the server's number) run no Every frame,
   When touched, When created or physics: the server does. Vector fields glide to new
   values (Synced name with "!": they jump), big jumps snap. All of it travels on the
   reliable channel, in order. */
#define CB_TICK (1.0 / 30.0)
#define CB_WORLD_ID 0xFFFFFFFFUL  /* an object reference to the world's root (each machine's own) */
#define CB_SNAP_DISTANCE 4.0
/* A rotation (a field named rotation, or ending in it: degrees) glides the short way
   round and snaps only at a turn this big (all axes together). Distances in world units
   don't fit angles: a gem spinning 120 degrees a second turns 4 between updates, right
   at CB_SNAP_DISTANCE, so it glided one update and jumped the next (it span jittery). */
#define CB_SNAP_ANGLE 90.0

static bool cb_is_angle(const char *name) {
    size_t n = strlen(name);
    return n >= 8 && strcmp(name + n - 8, "rotation") == 0;
}

/* a - b in degrees, the short way round (-180 to 180). */
static double cb_angle_diff(double a, double b) {
    double d = fmod(a - b, 360.0);
    if (d > 180.0) d -= 360.0;
    if (d < -180.0) d += 360.0;
    return d;
}
enum { CB_OP_CREATE = 1, CB_OP_PARENT, CB_OP_NAME, CB_OP_DESTROY, CB_OP_FIELDS, CB_OP_SNAPSHOT_END, CB_OP_OWNER, CB_OP_SCALE };
static double cb_scale_sent = 1.0;  /* the time scale the clients have (SCALE: the world's speed) */
enum { CB_V_NONE, CB_V_INT, CB_V_FLOAT, CB_V_BOOL, CB_V_TEXT, CB_V_V3, CB_V_V2, CB_V_OBJECT };

/* ---- a map from numbers to pointers (open addressing; -1: a removed key) ---- */
typedef struct { int *keys; void **vals; int cap, used; } cb_imap;

static void cb_imap_put(cb_imap *m, int key, void *val);

static void cb_imap_grow(cb_imap *m) {
    cb_imap old = *m;
    int i;
    m->cap = old.cap ? old.cap * 2 : 64;
    m->keys = (int *)calloc((size_t)m->cap, sizeof(int));
    m->vals = (void **)calloc((size_t)m->cap, sizeof(void *));
    if (!m->keys || !m->vals) { fputs("out of memory\n", stderr); exit(3); }
    m->used = 0;
    for (i = 0; i < old.cap; i++)
        if (old.keys[i] > 0)
            cb_imap_put(m, old.keys[i], old.vals[i]);
    free((void *)old.keys);
    free((void *)old.vals);
}

static int cb_imap_slot(const cb_imap *m, int key) {
    unsigned int h = (unsigned int)key * 2654435761u;
    return (int)(h & (unsigned int)(m->cap - 1));
}

static void *cb_imap_get(const cb_imap *m, int key) {
    int i, n;
    if (!m->cap)
        return NULL;
    for (i = cb_imap_slot(m, key), n = 0; n < m->cap; i = (i + 1) & (m->cap - 1), n++) {
        if (m->keys[i] == key)
            return m->vals[i];
        if (m->keys[i] == 0)
            return NULL;
    }
    return NULL;
}

static void cb_imap_put(cb_imap *m, int key, void *val) {
    int i, n, free_at = -1;
    if ((m->used + 1) * 2 > m->cap)
        cb_imap_grow(m);
    for (i = cb_imap_slot(m, key), n = 0; n < m->cap; i = (i + 1) & (m->cap - 1), n++) {
        if (m->keys[i] == key) { m->vals[i] = val; return; }
        if (m->keys[i] == -1 && free_at < 0) free_at = i;
        if (m->keys[i] == 0) { if (free_at < 0) free_at = i; break; }
    }
    if (m->keys[free_at] == 0)
        m->used++;
    m->keys[free_at] = key;
    m->vals[free_at] = val;
}

static void cb_imap_remove(cb_imap *m, int key) {
    int i, n;
    if (!m->cap)
        return;
    for (i = cb_imap_slot(m, key), n = 0; n < m->cap; i = (i + 1) & (m->cap - 1), n++) {
        if (m->keys[i] == key) { m->keys[i] = -1; m->vals[i] = NULL; return; }
        if (m->keys[i] == 0) return;
    }
}

static void cb_imap_clear(cb_imap *m) {
    free((void *)m->keys);
    free((void *)m->vals);
    memset(m, 0, sizeof *m);
}

/* ---- classes and their Synced fields (base class first) ---- */
typedef struct { const cb_field *f; int kind; const cb_class *of; } cb_sync_field;
typedef struct { cb_sync_field *list; int n; } cb_sync_list;
static cb_sync_list *cb_sync_lists = NULL;

static const cb_class *cb_class_named(const char *name) {
    int i;
    for (i = 0; i < cb_net_class_count; i++)
        if (strcmp(cb_net_classes[i]->name, name) == 0)
            return cb_net_classes[i];
    return NULL;
}

static int cb_class_index(const cb_class *cls) {
    int i;
    for (i = 0; i < cb_net_class_count; i++)
        if (cb_net_classes[i] == cls)
            return i;
    return -1;
}

static int cb_value_kind(const char *type, const cb_class **of) {
    *of = NULL;
    if (strcmp(type, "int") == 0) return CB_V_INT;
    if (strcmp(type, "float") == 0) return CB_V_FLOAT;
    if (strcmp(type, "bool") == 0) return CB_V_BOOL;
    if (strcmp(type, "string") == 0) return CB_V_TEXT;
    if (strcmp(type, "vector3") == 0) return CB_V_V3;
    if (strcmp(type, "vector2") == 0) return CB_V_V2;
    *of = cb_class_named(type);
    return *of ? CB_V_OBJECT : CB_V_NONE;
}

static void cb_sync_collect(const cb_class *cls, cb_sync_list *out) {
    int i;
    if (cls->parent)
        cb_sync_collect(cls->parent, out);
    for (i = 0; i < cls->field_count; i++) {
        cb_sync_field *sf;
        const cb_class *of;
        int kind;
        if (!cls->fields[i].synced)
            continue;
        kind = cb_value_kind(cls->fields[i].type, &of);
        if (kind == CB_V_NONE)
            continue;
        out->list = (cb_sync_field *)realloc((void *)out->list, sizeof(cb_sync_field) * (size_t)(out->n + 1));
        if (!out->list) { fputs("out of memory\n", stderr); exit(3); }
        sf = &out->list[out->n++];
        sf->f = &cls->fields[i];
        sf->kind = kind;
        sf->of = of;
    }
}

static const cb_sync_list *cb_synced_of(int class_index) {
    if (!cb_sync_lists) {
        int i;
        cb_sync_lists = (cb_sync_list *)calloc((size_t)cb_net_class_count, sizeof(cb_sync_list));
        if (!cb_sync_lists) { fputs("out of memory\n", stderr); exit(3); }
        for (i = 0; i < cb_net_class_count; i++)
            cb_sync_collect(cb_net_classes[i], &cb_sync_lists[i]);
    }
    return &cb_sync_lists[class_index];
}

/* ---- values on the wire (big-endian; floats as their IEEE bits) ---- */
static void cb_put_float32(cb_pack *p, float v) {
    unsigned long bits = 0;
    unsigned int u;
    memcpy(&u, &v, 4);
    bits = (unsigned long)u;
    cb_put32(p, bits);
}

static void cb_put_value(cb_pack *p, const cb_sync_field *sf, const void *at) {
    switch (sf->kind) {
    case CB_V_INT: cb_put32(p, (unsigned long)(unsigned int)*(const int *)at); break;
    case CB_V_FLOAT: {
        double d = *(const double *)at;
        unsigned char b[8];
        int i;
        memcpy(b, &d, 8);
        {   /* big-endian on the wire, whatever this machine is */
            unsigned int one = 1;
            bool little = *(unsigned char *)&one == 1;
            for (i = 0; i < 8; i++)
                cb_put8(p, b[little ? 7 - i : i]);
        }
        break;
    }
    case CB_V_BOOL: cb_put8(p, *(const bool *)at ? 1 : 0); break;
    case CB_V_TEXT: {
        const char *s = *(const char *const *)at;
        int n = s ? (int)strlen(s) : 0, i;
        if (n > 600) n = 600;
        cb_put16(p, n);
        for (i = 0; i < n; i++) cb_put8(p, (unsigned char)s[i]);
        break;
    }
    case CB_V_V3: { const Vector3 *v = (const Vector3 *)at; cb_put_float32(p, v->x); cb_put_float32(p, v->y); cb_put_float32(p, v->z); break; }
    case CB_V_V2: { const Vector2 *v = (const Vector2 *)at; cb_put_float32(p, v->x); cb_put_float32(p, v->y); break; }
    case CB_V_OBJECT: {
        const cb_object *o = *(const cb_object *const *)at;
        /* (the world's root isn't sent: every machine has its own, from the Main scene) */
        cb_put32(p, (o && cb_alive(o)) ? (o == (const cb_object *)cb_world() ? CB_WORLD_ID : (unsigned long)o->id) : 0UL);
        break;
    }
    default: break;
    }
}

static unsigned long cb_get32u(cb_unpack *u) { unsigned long a = (unsigned long)cb_get16(u); return (a << 16) | (unsigned long)cb_get16(u); }

static float cb_get_float32(cb_unpack *u) {
    unsigned int bits = (unsigned int)cb_get32u(u);
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

/* ---- the server's side ---- */
typedef struct {
    int id, parent, class_index, owner;
    bool root;             /* the world's root: only its Synced fields travel (as CB_WORLD_ID) */
    void *obj;
    char *name;
    unsigned char **enc;   /* each Synced field as last sent */
    int *len;
    unsigned long tick;
} cb_rep;

static cb_imap cb_reps;              /* object number -> cb_rep * */
static cb_rep **cb_rep_list = NULL;  /* every record, to find the gone ones */
static int cb_rep_n = 0, cb_rep_cap = 0;
static unsigned long cb_tick_no = 0;
static double cb_last_tick = -1;

/* A batch of operations: flushed as one WORLD message when it's nearly full. */
typedef struct { cb_pack m; cb_peer *to; } cb_batch;  /* to: one client, or NULL: every synced one */

static void cb_batch_start(cb_batch *b, cb_peer *to) {
    b->to = to;
    b->m.n = 0;
    cb_put8(&b->m, CB_M_WORLD);
}

static void cb_batch_flush(cb_batch *b) {
    int i;
    if (b->m.n <= 1)
        return;
    if (b->to) {
        cb_send(b->to, &b->m);
    } else {
        for (i = 0; i < CB_NET_PEERS; i++)
            if (cb_peers[i].used && cb_peers[i].welcomed && cb_peers[i].synced)
                cb_send(&cb_peers[i], &b->m);
    }
    cb_batch_start(b, b->to);
}

/* Room for `need` more bytes (flushing first if not). */
static void cb_batch_room(cb_batch *b, int need) {
    if (b->m.n + need > CB_NET_MTU - 16)
        cb_batch_flush(b);
}

/* A UI node (a Control or one of its classes): each machine builds its own UI. */
static bool cb_is_ui(const cb_object *o) {
    const cb_class *c;
    for (c = o->cls; c; c = c->parent)
        if (strcmp(c->name, "Control") == 0)
            return true;
    return false;
}

static bool cb_is_local(const cb_object *o) {
    const cb_object *w = (const cb_object *)cb_world();
    for (; o && o != w; o = o->parent)
        if (cb_group_index(o, "local") >= 0 || o->cls->side == 2 || cb_is_ui(o))
            return true;
    return false;
}

static int cb_parent_number(const cb_object *o) {
    return (!o->parent || o->parent == (cb_object *)cb_world()) ? 0 : o->parent->id;
}

static void cb_op_owner(cb_batch *b, const cb_rep *r) {
    cb_batch_room(b, 7);
    cb_put8(&b->m, CB_OP_OWNER);
    cb_put32(&b->m, (unsigned long)r->id);
    cb_put16(&b->m, r->owner);
}

static void cb_op_create(cb_batch *b, const cb_rep *r, const cb_object *o) {
    cb_batch_room(b, 16 + 260);
    cb_put8(&b->m, CB_OP_CREATE);
    cb_put32(&b->m, (unsigned long)r->id);
    cb_put16(&b->m, r->class_index);
    cb_put32(&b->m, (unsigned long)r->parent);
    cb_put_text(&b->m, r->name);
    cb_put32(&b->m, o->scene_key);
    cb_put16(&b->m, o->scene_of);  /* (an instance's root: its scene's Client scripts run on its owner's machine) */
    if (r->owner)
        cb_op_owner(b, r);
}

/* A FIELDS operation: id, a byte count, then (field index, value) pairs. Fields
   whose bytes are in `enc` (all: every field) are sent; split when it's long. */
static void cb_op_fields(cb_batch *b, const cb_rep *r, const bool *which) {
    const cb_sync_list *sl = cb_synced_of(r->class_index);
    int i, start = -1, count_at = 0;
    for (i = 0; i < sl->n; i++) {
        if (which && !which[i])
            continue;
        if (start >= 0 && b->m.n + 1 + r->len[i] > CB_NET_MTU - 16) {
            int size = b->m.n - start;
            b->m.d[count_at] = (unsigned char)(size >> 8);
            b->m.d[count_at + 1] = (unsigned char)(size & 255);
            start = -1;
        }
        if (start < 0) {
            cb_batch_room(b, 8 + 1 + r->len[i]);
            cb_put8(&b->m, CB_OP_FIELDS);
            cb_put32(&b->m, r->root ? CB_WORLD_ID : (unsigned long)r->id);
            count_at = b->m.n;
            cb_put16(&b->m, 0);
            start = b->m.n;
        }
        cb_put8(&b->m, i);
        memcpy(b->m.d + b->m.n, r->enc[i], (size_t)r->len[i]);
        b->m.n += r->len[i];
    }
    if (start >= 0) {
        int size = b->m.n - start;
        b->m.d[count_at] = (unsigned char)(size >> 8);
        b->m.d[count_at + 1] = (unsigned char)(size & 255);
    }
}

static void cb_rep_free(cb_rep *r) {
    int i;
    const cb_sync_list *sl = cb_synced_of(r->class_index);
    for (i = 0; i < sl->n; i++)
        free((void *)r->enc[i]);
    free((void *)r->enc);
    free((void *)r->len);
    free((void *)r->name);
    free((void *)r);
}

static char *cb_strdup(const char *s) {
    char *t = (char *)malloc(strlen(s) + 1);
    if (!t) { fputs("out of memory\n", stderr); exit(3); }
    strcpy(t, s);
    return t;
}

/* A field's bytes now; true when they differ from what was last sent (kept then). */
static bool cb_rep_encode(cb_rep *r, int i, const cb_object *o) {
    const cb_sync_list *sl = cb_synced_of(r->class_index);
    cb_pack v;
    v.n = 0;
    cb_put_value(&v, &sl->list[i], (const char *)o + sl->list[i].f->offset);
    if (r->enc[i] && r->len[i] == v.n && memcmp(r->enc[i], v.d, (size_t)v.n) == 0)
        return false;
    free((void *)r->enc[i]);
    r->enc[i] = (unsigned char *)malloc((size_t)v.n + 1);
    if (!r->enc[i]) { fputs("out of memory\n", stderr); exit(3); }
    memcpy(r->enc[i], v.d, (size_t)v.n);
    r->len[i] = v.n;
    return true;
}

static bool cb_any_synced_peer(void) {
    int i;
    for (i = 0; i < CB_NET_PEERS; i++)
        if (cb_peers[i].used && cb_peers[i].welcomed)
            return true;
    return false;
}

/* The whole world as it was last sent, to one client that has just joined. */
static void cb_send_snapshot(cb_peer *p) {
    void **all;
    int i, n = cb_world_objects(&all);
    cb_batch b;
    cb_batch_start(&b, p);
    for (i = 0; i < n; i++) {
        cb_rep *r = (cb_rep *)cb_imap_get(&cb_reps, ((cb_object *)all[i])->id);
        if (r && r->obj == all[i] && !r->root)
            cb_op_create(&b, r, (const cb_object *)all[i]);
    }
    for (i = 0; i < n; i++) {
        cb_rep *r = (cb_rep *)cb_imap_get(&cb_reps, ((cb_object *)all[i])->id);
        if (r && r->obj == all[i])
            cb_op_fields(&b, r, NULL);
    }
    cb_batch_room(&b, 5);
    cb_put8(&b.m, CB_OP_SCALE);  /* the world's speed */
    cb_put_float32(&b.m, (float)cb_world_scale);
    cb_batch_room(&b, 1);
    cb_put8(&b.m, CB_OP_SNAPSHOT_END);
    cb_batch_flush(&b);
    p->synced = true;
}

/* The server's tick: what changed in the world, to every client (now_: at once, before a Fire Clients). */
static void cb_rep_tick(bool now_) {
    void **all;
    int i, j, n, kept = 0;
    double now = cb_udp_now();
    cb_batch b;
    bool *changed = NULL;
    int changed_cap = 0;
    if (!now_ && now - cb_last_tick < CB_TICK)
        return;
    cb_last_tick = now;
    if (!cb_any_synced_peer() && cb_rep_n == 0)
        return;  /* nobody to tell, nothing told yet: the records start with the first client */
    cb_tick_no++;
    n = cb_world_objects(&all);
    {   /* (the world list is reused by cb_world_objects: keep a copy) */
        void **copy = (void **)malloc(sizeof(void *) * (size_t)(n ? n : 1));
        if (!copy) { fputs("out of memory\n", stderr); exit(3); }
        memcpy((void *)copy, (void *)all, sizeof(void *) * (size_t)n);
        all = copy;
    }
    cb_batch_start(&b, NULL);
    if (cb_world_scale != cb_scale_sent) {  /* the world's speed changed: everyone's */
        cb_batch_room(&b, 5);
        cb_put8(&b.m, CB_OP_SCALE);
        cb_put_float32(&b.m, (float)cb_world_scale);
        cb_scale_sent = cb_world_scale;
    }
    /* made, re-parented, renamed (parents before children: the world's order) */
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)all[i];
        cb_rep *r;
        if (o != (cb_object *)cb_world() && cb_is_local(o)) {
            all[i] = NULL;
            continue;
        }
        r = (cb_rep *)cb_imap_get(&cb_reps, o->id);
        if (!r || r->obj != (void *)o) {
            int ci = cb_class_index(o->cls);
            const cb_sync_list *sl;
            if (ci < 0) { all[i] = NULL; continue; }
            sl = cb_synced_of(ci);
            r = (cb_rep *)calloc(1, sizeof(cb_rep));
            if (!r) { fputs("out of memory\n", stderr); exit(3); }
            r->id = o->id;
            r->obj = o;
            r->class_index = ci;
            r->parent = cb_parent_number(o);
            r->name = cb_strdup(o->name);
            r->owner = o->owner;
            r->enc = (unsigned char **)calloc((size_t)(sl->n ? sl->n : 1), sizeof(unsigned char *));
            r->len = (int *)calloc((size_t)(sl->n ? sl->n : 1), sizeof(int));
            if (!r->enc || !r->len) { fputs("out of memory\n", stderr); exit(3); }
            cb_imap_put(&cb_reps, r->id, r);
            r->root = o == (cb_object *)cb_world();  /* (every machine makes its own root: only its fields go) */
            if (cb_rep_n == cb_rep_cap) {
                cb_rep_cap = cb_rep_cap ? cb_rep_cap * 2 : 64;
                cb_rep_list = (cb_rep **)realloc((void *)cb_rep_list, sizeof(cb_rep *) * (size_t)cb_rep_cap);
                if (!cb_rep_list) { fputs("out of memory\n", stderr); exit(3); }
            }
            cb_rep_list[cb_rep_n++] = r;
            if (!r->root)
                cb_op_create(&b, r, o);
        } else if (!r->root) {
            int parent = cb_parent_number(o);
            if (parent != r->parent) {
                r->parent = parent;
                cb_batch_room(&b, 9);
                cb_put8(&b.m, CB_OP_PARENT);
                cb_put32(&b.m, (unsigned long)r->id);
                cb_put32(&b.m, (unsigned long)parent);
            }
            if (o->owner != r->owner) {
                r->owner = o->owner;
                cb_op_owner(&b, r);
            }
            if (strcmp(o->name, r->name) != 0) {
                free((void *)r->name);
                r->name = cb_strdup(o->name);
                cb_batch_room(&b, 6 + 256);
                cb_put8(&b.m, CB_OP_NAME);
                cb_put32(&b.m, (unsigned long)r->id);
                cb_put_text(&b.m, r->name);
            }
        }
        r->tick = cb_tick_no;
    }
    /* Synced fields that changed (after every new object: a field may name one) */
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)all[i];
        cb_rep *r;
        const cb_sync_list *sl;
        bool any = false;
        if (!o)
            continue;
        r = (cb_rep *)cb_imap_get(&cb_reps, o->id);
        sl = cb_synced_of(r->class_index);
        if (sl->n > changed_cap) {
            changed_cap = sl->n;
            changed = (bool *)realloc((void *)changed, sizeof(bool) * (size_t)changed_cap);
            if (!changed) { fputs("out of memory\n", stderr); exit(3); }
        }
        for (j = 0; j < sl->n; j++) {
            changed[j] = cb_rep_encode(r, j, o);
            any = any || changed[j];
        }
        if (any)
            cb_op_fields(&b, r, changed);
    }
    free((void *)changed);
    free((void *)all);
    /* gone: destroyed, or out of the world */
    for (i = 0; i < cb_rep_n; i++) {
        cb_rep *r = cb_rep_list[i];
        if (r->tick == cb_tick_no) {
            cb_rep_list[kept++] = r;
            continue;
        }
        if (!r->root) {
            cb_batch_room(&b, 5);
            cb_put8(&b.m, CB_OP_DESTROY);
            cb_put32(&b.m, (unsigned long)r->id);
        }
        cb_imap_remove(&cb_reps, r->id);
        cb_rep_free(r);
    }
    cb_rep_n = kept;
    cb_batch_flush(&b);
    /* clients that have just joined: the whole world, as it is now */
    for (i = 0; i < CB_NET_PEERS; i++)
        if (cb_peers[i].used && cb_peers[i].welcomed && !cb_peers[i].synced)
            cb_send_snapshot(&cb_peers[i]);
}

static void cb_rep_clear(void) {
    int i;
    for (i = 0; i < cb_rep_n; i++)
        cb_rep_free(cb_rep_list[i]);
    cb_rep_n = 0;
    cb_imap_clear(&cb_reps);
}

/* ---- the client's side ---- */
static cb_imap cb_copies;              /* the server's object number -> this machine's copy */
static bool cb_net_has_world = false;  /* the whole world arrived (SNAPSHOT_END) */
typedef struct { cb_object *obj; int id; size_t offset; Vector3 target; bool two; } cb_glide;
static cb_glide *cb_glides = NULL;
static int cb_glide_n = 0, cb_glide_cap = 0;
static double cb_last_glide = -1;

/* The world's root on a client: its own (from the Main scene), now the server's copy. */
static cb_object *cb_root_copy(void) {
    cb_object *r = (cb_object *)cb_world();
    r->net_id = -1;  /* (its events are the server's: they don't run here) */
    return r;
}

/* The root's FIELDS (raw), kept in order to apply again once the client's scene exists. */
static unsigned char *cb_root_fields = NULL;
static int cb_root_fields_n = 0;

static void cb_root_stash(const unsigned char *data, int size) {
    cb_root_fields = (unsigned char *)realloc((void *)cb_root_fields, (size_t)(cb_root_fields_n + size + 2));
    if (!cb_root_fields) { fputs("out of memory\n", stderr); exit(3); }
    cb_root_fields[cb_root_fields_n] = (unsigned char)(size >> 8);
    cb_root_fields[cb_root_fields_n + 1] = (unsigned char)(size & 255);
    memcpy(cb_root_fields + cb_root_fields_n + 2, data, (size_t)size);
    cb_root_fields_n += size + 2;
}

static cb_object *cb_copy_of(int id) {
    cb_object *o = (cb_object *)cb_imap_get(&cb_copies, id);
    return (o && cb_alive(o) && o->net_id == id) ? o : NULL;
}

static void cb_glide_to(cb_object *o, size_t offset, Vector3 target, bool two) {
    int i;
    for (i = 0; i < cb_glide_n; i++) {
        if (cb_glides[i].obj == o && cb_glides[i].offset == offset) {
            cb_glides[i].target = target;
            return;
        }
    }
    if (cb_glide_n == cb_glide_cap) {
        cb_glide_cap = cb_glide_cap ? cb_glide_cap * 2 : 32;
        cb_glides = (cb_glide *)realloc((void *)cb_glides, sizeof(cb_glide) * (size_t)cb_glide_cap);
        if (!cb_glides) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_glides[cb_glide_n].obj = o;
    cb_glides[cb_glide_n].id = o->id;
    cb_glides[cb_glide_n].offset = offset;
    cb_glides[cb_glide_n].target = target;
    cb_glides[cb_glide_n].two = two;
    cb_glide_n++;
}

/* Copies' vector fields move toward their last values from the server. */
static void cb_glide_step(void) {
    double now = cb_udp_now(), dt = cb_last_glide < 0 ? 0 : now - cb_last_glide, k;
    int i, kept = 0;
    cb_last_glide = now;
    k = dt * 15.0;
    if (k > 1) k = 1;
    for (i = 0; i < cb_glide_n; i++) {
        cb_glide *g = &cb_glides[i];
        float *v;
        double dx, dy, dz;
        if (!cb_alive(g->obj) || g->obj->id != g->id || !g->obj->net_id)
            continue;
        v = (float *)(void *)((char *)g->obj + g->offset);
        dx = g->target.x - v[0];
        dy = g->target.y - v[1];
        dz = g->two ? 0 : g->target.z - v[2];
        if (fabs(dx) + fabs(dy) + fabs(dz) < 0.001) {
            v[0] = g->target.x; v[1] = g->target.y;
            if (!g->two) v[2] = g->target.z;
            continue;
        }
        v[0] += (float)(dx * k); v[1] += (float)(dy * k);
        if (!g->two) v[2] += (float)(dz * k);
        cb_glides[kept++] = *g;
    }
    cb_glide_n = kept;
}

static void cb_apply_value(cb_unpack *u, cb_object *o, const cb_sync_field *sf, bool first) {
    char *at = (char *)o + sf->f->offset;
    switch (sf->kind) {
    case CB_V_INT: *(int *)(void *)at = (int)(unsigned int)cb_get32u(u); break;
    case CB_V_FLOAT: {
        unsigned char b[8];
        unsigned int one = 1;
        bool little = *(unsigned char *)&one == 1;
        int i;
        double d;
        for (i = 0; i < 8; i++)
            b[little ? 7 - i : i] = (unsigned char)cb_get8(u);
        memcpy(&d, b, 8);
        *(double *)(void *)at = d;
        break;
    }
    case CB_V_BOOL: *(bool *)(void *)at = cb_get8(u) != 0; break;
    case CB_V_TEXT: {
        int n = cb_get16(u), i;
        char *s = (char *)cb_alloc((size_t)n + 1);
        for (i = 0; i < n; i++) s[i] = (char)cb_get8(u);
        s[n] = 0;
        if (strcmp(*(const char **)(void *)at, s) != 0)
            *(const char **)(void *)at = s;  /* (text is kept until the program ends) */
        break;
    }
    case CB_V_V3: case CB_V_V2: {
        Vector3 t;
        bool two = sf->kind == CB_V_V2;
        float *v = (float *)(void *)at;
        t.x = cb_get_float32(u); t.y = cb_get_float32(u); t.z = two ? 0 : cb_get_float32(u);
        if (!first && sf->f->synced == 1 && cb_is_angle(sf->f->name)) {
            /* an angle: aim at the nearest equal angle to where it is, so it turns the short way */
            Vector3 near;
            near.x = (float)(v[0] + cb_angle_diff(t.x, v[0]));
            near.y = (float)(v[1] + cb_angle_diff(t.y, v[1]));
            near.z = two ? 0 : (float)(v[2] + cb_angle_diff(t.z, v[2]));
            if (fabs(near.x - v[0]) + fabs(near.y - v[1]) + (two ? 0 : fabs(near.z - v[2])) < CB_SNAP_ANGLE) {
                cb_glide_to(o, sf->f->offset, near, two);
            } else {
                v[0] = t.x; v[1] = t.y;
                if (!two) v[2] = t.z;
            }
        } else if (!first && sf->f->synced == 1
            && fabs(t.x - v[0]) + fabs(t.y - v[1]) + (two ? 0 : fabs(t.z - v[2])) < CB_SNAP_DISTANCE) {
            cb_glide_to(o, sf->f->offset, t, two);  /* glides there */
        } else {
            v[0] = t.x; v[1] = t.y;
            if (!two) v[2] = t.z;
        }
        break;
    }
    case CB_V_OBJECT: {
        unsigned long raw = cb_get32u(u);
        cb_object *ref = raw == CB_WORLD_ID ? (cb_object *)cb_world() : cb_copy_of((int)raw);
        *(void **)(void *)at = (ref && cb_is_a(ref, sf->of)) ? ref : NULL;
        break;
    }
    default: break;
    }
}

/* The server's object number -> a copy here: the Main scene's own one (same place
   in it, same class) when there's one, else a new copy. */
static void cb_owned_scripts_add(cb_object *root, int scene);

static void cb_world_create(int id, int class_index, int parent, const char *name, unsigned long key, int scene_of) {
    const cb_class *cls;
    cb_object *o = NULL, *under;
    if (cb_copy_of(id) || class_index < 0 || class_index >= cb_net_class_count)
        return;
    cls = cb_net_classes[class_index];
    if (key) {
        void **all;
        int i, n = cb_world_objects(&all);
        for (i = 0; i < n; i++) {
            cb_object *c = (cb_object *)all[i];
            if (c->scene_key == key && c->cls == cls && !c->net_id) { o = c; break; }
        }
    }
    if (!o)
        o = (cb_object *)cb_new_replica(cls);
    o->net_id = id;
    o->scene_key = key;
    o->name = cb_net_copy(name);
    cb_imap_put(&cb_copies, id, o);
    under = parent ? cb_copy_of(parent) : NULL;
    cb_set_parent(o, under ? (void *)under : cb_world(), 0, 0);
    if (scene_of > 0) {
        o->scene_of = scene_of;
        cb_owned_scripts_add(o, scene_of - 1);  /* its scene's Client scripts: here if it's (or becomes) ours */
    }
}

/* ---- Client Script objects of instances made while a game runs: on their owner's machine ----
   (user, 2026-11-07, instead of StarterPlayer: a Client script inside something a player
   owns runs on that player's machine.) Each instance waits here until it's this machine's
   player's (a client: its owner is us; offline / a host: ours, or no one's), then its
   scene's Client scripts start with `parent` = the instance's root. */
typedef struct { cb_object *root; int id, scene; } cb_owned_wait;
static cb_owned_wait *cb_owned_waits = NULL;
static int cb_owned_n = 0, cb_owned_cap = 0;

static void cb_owned_scripts_add(cb_object *root, int scene) {
    if (cb_owned_n == cb_owned_cap) {
        cb_owned_cap = cb_owned_cap ? cb_owned_cap * 2 : 16;
        cb_owned_waits = (cb_owned_wait *)realloc((void *)cb_owned_waits, sizeof(cb_owned_wait) * (size_t)cb_owned_cap);
        if (!cb_owned_waits) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_owned_waits[cb_owned_n].root = root;
    cb_owned_waits[cb_owned_n].id = root->id;
    cb_owned_waits[cb_owned_n].scene = scene;
    cb_owned_n++;
}

static void cb_scene_client_wait(void *root, int scene) {
    cb_owned_scripts_add((cb_object *)root, scene);
}

/* After the network's turn: instances that are ours now run their Client scripts. */
static void cb_owned_scripts_check(void) {
    int i, kept = 0;
    for (i = 0; i < cb_owned_n; i++) {
        cb_owned_wait w = cb_owned_waits[i];
        int owner;
        if (!cb_alive(w.root) || w.root->id != w.id || !cb_side_runs(2))
            continue;  /* gone, or no players here (a dedicated server) */
        owner = cb_owner_number(w.root);
        if ((owner != 0 && owner == cb_net_me_num) || (owner == 0 && cb_net_role != CB_ROLE_CLIENT)) {
            if (cb_scene_clients_run)
                cb_scene_clients_run(w.scene, w.root);
            continue;
        }
        if (owner != 0 && cb_net_role != CB_ROLE_CLIENT)
            continue;  /* another player's: their machine runs them */
        cb_owned_waits[kept++] = w;  /* (a client: not ours yet; it may be given to us) */
    }
    cb_owned_n = kept;
}

/* Objects of this machine's that the server doesn't have: gone once the world has
   arrived (joining replaces single-player's world); keyed_only: just the Main scene's
   (made after joining, while the scene loads). Local ones stay. */
static void cb_world_prune(bool keyed_only) {
    void **all;
    int i, n = cb_world_objects(&all);
    void **copy = (void **)malloc(sizeof(void *) * (size_t)(n ? n : 1));
    if (!copy) { fputs("out of memory\n", stderr); exit(3); }
    memcpy((void *)copy, (void *)all, sizeof(void *) * (size_t)n);
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)copy[i];
        if (cb_alive(o) && o != (cb_object *)cb_world() && !o->net_id && (!keyed_only || o->scene_key) && !cb_is_local(o))
            cb_destroy(o, 0, 0);
    }
    free((void *)copy);
}

static void cb_world_message(cb_unpack *u) {
    char name[260];
    while (!u->bad && u->at < u->n) {
        int op = cb_get8(u);
        if (op == CB_OP_CREATE) {
            int id = (int)cb_get32u(u), ci = cb_get16(u), parent = (int)cb_get32u(u), scene_of;
            unsigned long key;
            cb_get_text(u, name, sizeof name);
            key = cb_get32u(u);
            scene_of = cb_get16(u);
            if (!u->bad)
                cb_world_create(id, ci, parent, name, key, scene_of);
        } else if (op == CB_OP_PARENT) {
            cb_object *o = cb_copy_of((int)cb_get32u(u));
            int parent = (int)cb_get32u(u);
            cb_object *under = parent ? cb_copy_of(parent) : NULL;
            if (o && !u->bad)
                cb_set_parent(o, under ? (void *)under : cb_world(), 0, 0);
        } else if (op == CB_OP_NAME) {
            cb_object *o = cb_copy_of((int)cb_get32u(u));
            cb_get_text(u, name, sizeof name);
            if (o && !u->bad)
                o->name = cb_net_copy(name);
        } else if (op == CB_OP_DESTROY) {
            int id = (int)cb_get32u(u);
            cb_object *o = cb_copy_of(id);
            cb_imap_remove(&cb_copies, id);
            if (o)
                cb_destroy(o, 0, 0);
        } else if (op == CB_OP_FIELDS) {
            unsigned long raw = cb_get32u(u);
            cb_object *o = raw == CB_WORLD_ID ? cb_root_copy() : cb_copy_of((int)raw);
            int size = cb_get16(u), end = u->at + size;
            if (raw == CB_WORLD_ID && size > 0 && end <= u->n && !cb_net_is_ready)
                cb_root_stash(u->d + u->at, size);  /* (kept: a client that joined before making its scene gets them then) */
            if (o) {
                int ci = cb_class_index(o->cls);
                const cb_sync_list *sl = ci >= 0 ? cb_synced_of(ci) : NULL;
                bool first = !cb_net_has_world;
                while (sl && !u->bad && u->at < end) {
                    int fi = cb_get8(u);
                    if (fi >= sl->n) break;  /* (not this object's fields: e.g. the root before the scene exists; the op is skipped) */
                    cb_apply_value(u, o, &sl->list[fi], first);
                }
            }
            u->at = end;  /* (an object this machine doesn't have: skipped) */
        } else if (op == CB_OP_OWNER) {
            cb_object *o = cb_copy_of((int)cb_get32u(u));
            int owner = cb_get16(u);
            if (o && !u->bad)
                o->owner = owner;
        } else if (op == CB_OP_SCALE) {
            float v = cb_get_float32(u);
            if (!u->bad)
                cb_world_scale = v;
        } else if (op == CB_OP_SNAPSHOT_END) {
            cb_net_has_world = true;
            cb_world_prune(false);
        } else {
            break;  /* unknown: the rest of the message can't be read */
        }
    }
}

/* A client that joined before making its scene (--join): the root's fields, again, now
   that its root (the Main scene's) is the world. */
static void cb_root_reapply(void) {
    int at = 0;
    cb_object *o = cb_root_copy();
    int ci = cb_class_index(o->cls);
    const cb_sync_list *sl = ci >= 0 ? cb_synced_of(ci) : NULL;
    while (sl && at + 2 <= cb_root_fields_n) {
        int size = (cb_root_fields[at] << 8) | cb_root_fields[at + 1];
        cb_unpack u;
        u.d = cb_root_fields + at + 2; u.n = size; u.at = 0; u.bad = false;
        while (!u.bad && u.at < u.n) {
            int fi = cb_get8(&u);
            if (fi >= sl->n) break;
            cb_apply_value(&u, o, &sl->list[fi], true);
        }
        at += size + 2;
    }
    free((void *)cb_root_fields);
    cb_root_fields = NULL;
    cb_root_fields_n = 0;
}

/* Back to this machine's own world: the copies become its own objects. */
static void cb_copies_release(void) {
    void **all;
    int i, n = cb_world_objects(&all);
    for (i = 0; i < n; i++)
        ((cb_object *)all[i])->net_id = 0;
    cb_imap_clear(&cb_copies);
    cb_glide_n = 0;
    cb_net_has_world = false;
}

/* The Main scene's objects, made while it loads on a client that has joined: its copy of the server's. */
static void *cb_scene_match(unsigned long key, const cb_class *cls) {
    void **all;
    int i, n;
    if (!cb_net_has_world)
        return NULL;
    n = cb_world_objects(&all);
    for (i = 0; i < n; i++) {
        cb_object *o = (cb_object *)all[i];
        if (o->net_id && o->scene_key == key && o->cls == cls)
            return o;
    }
    return NULL;
}

/* ---- remotes (stage 3c): Define Remote's messages ----
   Fire Server / Fire Clients write the remote's values (cb_msg_put_*, in order), then
   send them: REMOTE = the remote's number + its values. Where it arrives (or here,
   when this machine is the target: offline, a host) it's queued like Player Joined,
   so it runs after the world's changes that came before it, and each handler reads
   the values in order (cb_msg_*). Objects travel as the server's object numbers
   (players as their player numbers); one that isn't there arrives as none. */
static cb_pack cb_msg_out;
static bool cb_msg_long = false;

void cb_net_on_remote(int remote, int side, void (*fn)(int sender)) {
    if (cb_remote_handler_n == cb_remote_handler_cap) {
        cb_remote_handler_cap = cb_remote_handler_cap ? cb_remote_handler_cap * 2 : 8;
        cb_remote_handlers = (cb_remote_handler *)realloc((void *)cb_remote_handlers, sizeof(cb_remote_handler) * (size_t)cb_remote_handler_cap);
        if (!cb_remote_handlers) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_remote_handlers[cb_remote_handler_n].remote = remote;
    cb_remote_handlers[cb_remote_handler_n].side = side;
    cb_remote_handlers[cb_remote_handler_n].fn = fn;
    cb_remote_handler_n++;
}

static void cb_msg_room(int need) {
    if (cb_msg_out.n + need > CB_NET_MTU - 16)
        cb_msg_long = true;
}

void cb_msg_begin(int remote) {
    cb_msg_out.n = 0;
    cb_msg_long = false;
    cb_put8(&cb_msg_out, CB_M_REMOTE);
    cb_put16(&cb_msg_out, remote);
}

void cb_msg_put_int(int v) { cb_msg_room(4); cb_put32(&cb_msg_out, (unsigned long)(unsigned int)v); }

void cb_msg_put_float(double v) {
    cb_sync_field sf;
    memset(&sf, 0, sizeof sf);
    sf.kind = CB_V_FLOAT;
    cb_msg_room(8);
    cb_put_value(&cb_msg_out, &sf, &v);
}

void cb_msg_put_bool(bool v) { cb_msg_room(1); cb_put8(&cb_msg_out, v ? 1 : 0); }

void cb_msg_put_text(const char *v) {
    int n = v ? (int)strlen(v) : 0, i;
    cb_msg_room(2 + n);
    if (cb_msg_long) return;
    cb_put16(&cb_msg_out, n);
    for (i = 0; i < n; i++) cb_put8(&cb_msg_out, (unsigned char)v[i]);
}

void cb_msg_put_v3(Vector3 v) { cb_msg_room(12); cb_put_float32(&cb_msg_out, v.x); cb_put_float32(&cb_msg_out, v.y); cb_put_float32(&cb_msg_out, v.z); }

void cb_msg_put_v2(Vector2 v) { cb_msg_room(8); cb_put_float32(&cb_msg_out, v.x); cb_put_float32(&cb_msg_out, v.y); }

/* An object: 0 none, 1 + the server's number for it, 3 the world's root. */
void cb_msg_put_object(const void *v) {
    const cb_object *o = (const cb_object *)v;
    cb_msg_room(5);
    if (!o || !cb_alive(o)) {
        cb_put8(&cb_msg_out, 0);
        cb_put32(&cb_msg_out, 0);
    } else if (o == (const cb_object *)cb_world()) {
        cb_put8(&cb_msg_out, 3);  /* the world's root: each machine's own */
        cb_put32(&cb_msg_out, 0);
    } else {
        cb_put8(&cb_msg_out, 1);
        cb_put32(&cb_msg_out, (unsigned long)(cb_net_role == CB_ROLE_CLIENT ? o->net_id : o->id));
    }
}

int cb_msg_int(void) { return (int)(unsigned int)cb_get32u(&cb_msg_in); }

double cb_msg_float(void) {
    unsigned char b[8];
    unsigned int one = 1;
    bool little = *(unsigned char *)&one == 1;
    int i;
    double d;
    for (i = 0; i < 8; i++)
        b[little ? 7 - i : i] = (unsigned char)cb_get8(&cb_msg_in);
    memcpy(&d, b, 8);
    return cb_msg_in.bad ? 0.0 : d;
}

bool cb_msg_bool(void) { return cb_get8(&cb_msg_in) != 0; }

const char *cb_msg_text(void) {
    int n = cb_get16(&cb_msg_in), i;
    char *s;
    if (cb_msg_in.bad || n > cb_msg_in.n - cb_msg_in.at) { cb_msg_in.bad = true; return ""; }
    s = (char *)cb_alloc((size_t)n + 1);
    for (i = 0; i < n; i++) s[i] = (char)cb_get8(&cb_msg_in);
    s[n] = 0;
    return s;  /* (kept until the program ends) */
}

Vector3 cb_msg_v3(void) {
    Vector3 v;
    v.x = cb_get_float32(&cb_msg_in); v.y = cb_get_float32(&cb_msg_in); v.z = cb_get_float32(&cb_msg_in);
    if (cb_msg_in.bad) v.x = v.y = v.z = 0;
    return v;
}

Vector2 cb_msg_v2(void) {
    Vector2 v;
    v.x = cb_get_float32(&cb_msg_in); v.y = cb_get_float32(&cb_msg_in);
    if (cb_msg_in.bad) v.x = v.y = 0;
    return v;
}

/* The object a number names here (the world's on a server, a copy on a client), as cls. */
void *cb_msg_object(const cb_class *cls) {
    int kind = cb_get8(&cb_msg_in), id = (int)cb_get32u(&cb_msg_in);
    cb_object *o = NULL;
    if (cb_msg_in.bad || kind == 0)
        return NULL;
    if (kind == 3) {
        o = (cb_object *)cb_world();
    } else if (cb_net_role == CB_ROLE_CLIENT) {
        o = cb_copy_of(id);
    } else {
        void **all;
        int i, n = cb_world_objects(&all);
        for (i = 0; i < n && !o; i++)
            if (((cb_object *)all[i])->id == id)
                o = (cb_object *)all[i];
    }
    return (o && cb_is_a(o, cls)) ? o : NULL;
}

static bool cb_msg_check(const char *what, int file, int brick) {
    if (!cb_msg_long)
        return true;
    fprintf(stderr, "[warning] %s brick %d: %s: its values are too long for one message (over 1100 bytes): not sent\n", cb_files[file], brick, what);
    return false;
}

static int cb_remote_of(const cb_pack *m) {
    return (m->d[1] << 8) | m->d[2];
}

/* Fire Server: to the server (here, when this machine is the server: offline, a host). */
void cb_net_fire_server(int file, int brick) {
    if (!cb_msg_check("Fire Server", file, brick))
        return;
    if (cb_net_role == CB_ROLE_CLIENT) {
        if (cb_peers[0].used)
            cb_send(&cb_peers[0], &cb_msg_out);
        return;
    }
    cb_net_queue_remote(cb_remote_of(&cb_msg_out), 1, cb_net_me_num, cb_msg_out.d + 3, cb_msg_out.n - 3);
    cb_net_deliver();
}

/* Fire Clients: to every player's machine (all), or one player's; a host's own too. */
void cb_net_fire_clients(int player, bool all, int file, int brick) {
    int i;
    if (!cb_msg_check("Fire Clients", file, brick))
        return;
    if (cb_net_role == CB_ROLE_CLIENT)
        return;  /* (a Shared script on a player's machine: only the server tells clients) */
    if (cb_net_role != CB_ROLE_OFFLINE)
        cb_rep_tick(true);  /* the world's changes first, so they've arrived when this runs */
    if (!all && !cb_net_in_game(player))
        return;
    for (i = 0; i < CB_NET_PEERS; i++) {
        cb_peer *p = &cb_peers[i];
        if (p->used && p->welcomed && p->synced && (all || p->number == player))
            cb_send(p, &cb_msg_out);
    }
    if (cb_side_runs(2) && (all || (player == cb_net_me_num && player != 0))) {
        cb_net_queue_remote(cb_remote_of(&cb_msg_out), 2, 0, cb_msg_out.d + 3, cb_msg_out.n - 3);
        cb_net_deliver();
    }
}

/* A REMOTE that arrived: checked against its ways, then queued for this machine's handlers. */
static void cb_remote_arrived(cb_unpack *u, cb_peer *from) {
    int remote = cb_get16(u);
    int side = from ? 1 : 2;  /* from a client: On Client Fired; from the server: On Server Fired */
    if (u->bad || remote < 0 || remote >= cb_net_remote_count || !(cb_net_remote_ways[remote] & side))
        return;  /* (not a remote of this build's, or the wrong way: a client can't fire To clients) */
    cb_net_queue_remote(remote, side, from ? from->number : 0, u->d + u->at, u->n - u->at);
}

/* ---- Invoke (2026-11-07): a question to the server and its typed answer ----
   Roblox's RemoteFunction, Brickscript's Invoke Server / On Client Invoked / Answer.
   Invoke Server writes the remote's values like Fire Server (cb_msg_put_*), then
   cb_net_invoke() sends ASK = remote + a request number + the values, and waits (the
   world and the network keep running, as in a Wait) for ANSWER = the request number +
   answered? + the answer's value, at most Timeout seconds. Where the rules run, the
   question is queued like a remote; its On Client Invoked handlers run with the
   question as "the current ask" (cb_ask), the first Answer brick sends the answer
   (cb_answer_begin + cb_msg_put_* + cb_net_answer), and if none did by the end, an
   empty answer goes back (the asker gets its zero value at once, not a timeout).
   Offline / hosting the game is its own server: the handlers run at once. */
typedef struct { long request; int player; bool local, answered, active; } cb_ask_state;
static cb_ask_state cb_ask = { 0, 0, false, false, false };
typedef struct { long request; bool ok; int size; unsigned char *data; } cb_answer_rec;
static cb_answer_rec *cb_answers = NULL;
static int cb_answer_n = 0, cb_answer_cap = 0;
static long cb_ask_next = 0;
static unsigned char *cb_answer_kept = NULL;  /* the answer being read (cb_msg_in points into it) */

static void cb_answer_store(long request, bool ok, const unsigned char *data, int size) {
    cb_answer_rec *a;
    if (cb_answer_n == cb_answer_cap) {
        cb_answer_cap = cb_answer_cap ? cb_answer_cap * 2 : 4;
        cb_answers = (cb_answer_rec *)realloc((void *)cb_answers, sizeof(cb_answer_rec) * (size_t)cb_answer_cap);
        if (!cb_answers) { fputs("out of memory\n", stderr); exit(3); }
    }
    a = &cb_answers[cb_answer_n++];
    a->request = request;
    a->ok = ok;
    a->size = size > 0 ? size : 0;
    a->data = (unsigned char *)malloc((size_t)a->size + 1);
    if (!a->data) { fputs("out of memory\n", stderr); exit(3); }
    if (a->size > 0)
        memcpy(a->data, data, (size_t)a->size);
}

/* An answer's packet: ANSWER, the request, answered?, then the value (cb_msg_out). */
static void cb_answer_header(cb_pack *m, long request, bool ok) {
    m->n = 0;
    cb_put8(m, CB_M_ANSWER);
    cb_put32(m, (unsigned long)request);
    cb_put8(m, ok ? 1 : 0);
}

/* Sends (or keeps, for a question asked here) an answer packet. */
static void cb_answer_deliver(const cb_ask_state *a, const cb_pack *m) {
    int i;
    if (a->local) {
        cb_answer_store(a->request, m->d[5] != 0, m->d + 6, m->n - 6);
        return;
    }
    if (cb_net_role != CB_ROLE_OFFLINE)
        cb_rep_tick(true);  /* the world's changes first: an object in the answer is there */
    for (i = 0; i < CB_NET_PEERS; i++)
        if (cb_peers[i].used && cb_peers[i].welcomed && cb_peers[i].number == a->player)
            cb_send(&cb_peers[i], m);
}

/* Runs a question's On Client Invoked handlers; answers empty if none of them did. */
static void cb_ask_run(int remote, int sender, long request, const unsigned char *data, int size, bool local) {
    cb_ask_state was = cb_ask;
    cb_unpack in_was = cb_msg_in;
    int h;
    cb_ask.request = request;
    cb_ask.player = sender;
    cb_ask.local = local;
    cb_ask.answered = false;
    cb_ask.active = true;
    for (h = 0; h < cb_remote_handler_n; h++) {
        if (cb_remote_handlers[h].remote != remote || cb_remote_handlers[h].side != 4)
            continue;
        cb_msg_in.d = (unsigned char *)data; cb_msg_in.n = size; cb_msg_in.at = 0; cb_msg_in.bad = false;
        cb_remote_handlers[h].fn(sender);
    }
    if (!cb_ask.answered) {
        cb_pack m;
        cb_answer_header(&m, request, false);
        cb_answer_deliver(&cb_ask, &m);
    }
    cb_ask = was;
    cb_msg_in = in_was;
}

/* Answer: the value was written after cb_answer_begin(); only the first Answer counts. */
void cb_answer_begin(void) {
    cb_answer_header(&cb_msg_out, cb_ask.request, true);
    cb_msg_long = false;
}

void cb_net_answer(int file, int brick) {
    if (!cb_ask.active || cb_ask.answered)
        return;  /* (a second Answer to the same question) */
    if (cb_msg_long) {
        fprintf(stderr, "[warning] %s brick %d: Answer: the value is too long for one message (over 1100 bytes): an empty answer is sent\n", cb_files[file], brick);
        return;
    }
    cb_ask.answered = true;
    cb_answer_deliver(&cb_ask, &cb_msg_out);
}

static void cb_ask_arrived(cb_unpack *u, cb_peer *from) {
    int remote = cb_get16(u);
    long request = (long)cb_get32u(u);
    cb_net_event *e;
    if (u->bad || remote < 0 || remote >= cb_net_remote_count || !(cb_net_remote_ways[remote] & 4))
        return;  /* (not a question of this build's) */
    cb_net_queue_remote(remote, 4, from->number, u->d + u->at, u->n - u->at);
    e = &cb_net_events[cb_net_event_n - 1];
    e->request = request;
}

static void cb_answer_arrived(cb_unpack *u) {
    long request = (long)cb_get32u(u);
    int ok = cb_get8(u);
    if (!u->bad)
        cb_answer_store(request, ok != 0, u->d + u->at, u->n - u->at);
}

/* Invoke Server: asks, waits; true with the answer ready to read (cb_msg_*), false when
   nobody answered in time (or the server's handlers gave no answer). */
bool cb_net_invoke(double timeout, int file, int brick) {
    long request = ++cb_ask_next;
    double start = cb_now();
    int i;
    if (!cb_msg_check("Invoke Server", file, brick))
        return false;
    if (cb_net_role == CB_ROLE_CLIENT) {
        cb_pack m;
        if (!cb_peers[0].used)
            return false;
        m.n = 0;
        cb_put8(&m, CB_M_ASK);
        cb_put16(&m, cb_remote_of(&cb_msg_out));
        cb_put32(&m, (unsigned long)request);
        for (i = 3; i < cb_msg_out.n; i++)
            cb_put8(&m, cb_msg_out.d[i]);
        cb_send(&cb_peers[0], &m);
    } else {  /* this machine is the server: its handlers answer now */
        cb_ask_run(cb_remote_of(&cb_msg_out), cb_net_me_num, request, cb_msg_out.d + 3, cb_msg_out.n - 3, true);
    }
    for (;;) {
        for (i = 0; i < cb_answer_n; i++) {
            if (cb_answers[i].request == request) {
                bool ok = cb_answers[i].ok;
                int size = cb_answers[i].size;
                free((void *)cb_answer_kept);
                cb_answer_kept = cb_answers[i].data;
                cb_answers[i] = cb_answers[--cb_answer_n];
                cb_msg_in.d = cb_answer_kept; cb_msg_in.n = ok ? size : 0;
                cb_msg_in.at = 0; cb_msg_in.bad = false;
                return ok;
            }
        }
        if (cb_net_role != CB_ROLE_CLIENT || !cb_peers[0].used || cb_now() - start >= timeout)
            break;
        if (cb_poll_hook)
            cb_poll_hook();
        cb_wait(0.01);  /* (the window and the world keep running, as in a Wait) */
    }
    fprintf(stderr, "[warning] %s brick %d: Invoke Server: no answer%s\n", cb_files[file], brick, cb_net_role == CB_ROLE_CLIENT && cb_peers[0].used ? " in time" : " (not in a game with a server)");
    return false;
}

/* ---- players' keys (stage 3d: Player Key, Player Input) ----
   Each player's machine reads the keys the project's Player bricks name (cb_net_keys,
   through cb_key_hook: the window's) every frame and sends them when they change; the
   server keeps each player's, and turns changes into Player Key events. Offline and
   hosting, this machine's keys are its own player's. */
typedef struct { int number; unsigned long hi, lo; } cb_key_state;
static cb_key_state *cb_key_states = NULL;
static int cb_key_state_n = 0, cb_key_state_cap = 0;
static unsigned long cb_keys_sent_hi = 0, cb_keys_sent_lo = 0;
static bool cb_keys_sent_any = false;

void cb_net_on_key(int key, bool pressed, void (*fn)(int player)) {
    if (cb_key_handler_n == cb_key_handler_cap) {
        cb_key_handler_cap = cb_key_handler_cap ? cb_key_handler_cap * 2 : 8;
        cb_key_handlers = (cb_key_handler *)realloc((void *)cb_key_handlers, sizeof(cb_key_handler) * (size_t)cb_key_handler_cap);
        if (!cb_key_handlers) { fputs("out of memory\n", stderr); exit(3); }
    }
    cb_key_handlers[cb_key_handler_n].key = key;
    cb_key_handlers[cb_key_handler_n].pressed = pressed;
    cb_key_handlers[cb_key_handler_n].fn = fn;
    cb_key_handler_n++;
}

static cb_key_state *cb_key_state_of(int number, bool make) {
    int i;
    for (i = 0; i < cb_key_state_n; i++)
        if (cb_key_states[i].number == number)
            return &cb_key_states[i];
    if (!make)
        return NULL;
    if (cb_key_state_n == cb_key_state_cap) {
        cb_key_state_cap = cb_key_state_cap ? cb_key_state_cap * 2 : 8;
        cb_key_states = (cb_key_state *)realloc((void *)cb_key_states, sizeof(cb_key_state) * (size_t)cb_key_state_cap);
        if (!cb_key_states) { fputs("out of memory\n", stderr); exit(3); }
    }
    memset(&cb_key_states[cb_key_state_n], 0, sizeof(cb_key_state));
    cb_key_states[cb_key_state_n].number = number;
    return &cb_key_states[cb_key_state_n++];
}

static bool cb_bit(unsigned long hi, unsigned long lo, int i) {
    return i < 32 ? ((lo >> i) & 1UL) != 0 : ((hi >> (i - 32)) & 1UL) != 0;
}

/* A player's keys now: what changed becomes Player Key events. */
static void cb_keys_set(int number, unsigned long hi, unsigned long lo) {
    cb_key_state *k = cb_key_state_of(number, true);
    bool player = cb_net_in_game(number);
    int i;
    for (i = 0; i < cb_net_key_count && player; i++) {
        bool was = cb_bit(k->hi, k->lo, i), now = cb_bit(hi, lo, i);
        if (was != now) {
            cb_net_event *e = cb_net_queue_slot();
            e->key = i;
            e->joined = now;  /* (pressed) */
            e->player = number;
        }
    }
    k->hi = hi;
    k->lo = lo;
}

/* This machine's keys: to the server (a client), or its own player's (offline, a host). */
static void cb_keys_sample(void) {
    unsigned long hi = 0, lo = 0;
    int i;
    if (!cb_key_hook || cb_net_key_count == 0)
        return;
    for (i = 0; i < cb_net_key_count; i++) {
        if (cb_key_hook(cb_net_keys[i])) {
            if (i < 32) lo |= 1UL << i;
            else hi |= 1UL << (i - 32);
        }
    }
    if (cb_net_role == CB_ROLE_CLIENT) {
        if (cb_peers[0].used && cb_net_has_world && (!cb_keys_sent_any || hi != cb_keys_sent_hi || lo != cb_keys_sent_lo)) {
            cb_pack m;
            m.n = 0;
            cb_put8(&m, CB_M_KEYS);
            cb_put32(&m, hi);
            cb_put32(&m, lo);
            cb_send(&cb_peers[0], &m);
            cb_keys_sent_hi = hi;
            cb_keys_sent_lo = lo;
            cb_keys_sent_any = true;
        }
    } else if (cb_net_me_num) {
        cb_keys_set(cb_net_me_num, hi, lo);
    }
}

/* --press KEY:FROM:TO (several with commas): keys held from FROM to TO seconds after
   the start, instead of the window's (tests: players' keys without anyone at them). A
   client's clock starts when it has joined (a slow join would otherwise miss the keys). */
typedef struct { int code; double from, to; } cb_press;
static cb_press cb_presses[16];
static int cb_press_n = 0;
static double cb_press_start = 0;

static int cb_pressed_key(int code) {
    double t;
    int i;
    if (cb_net_role == CB_ROLE_CLIENT && !cb_net_me_num) {
        cb_press_start = cb_udp_now();  /* not in the game yet */
        return 0;
    }
    t = cb_udp_now() - cb_press_start;
    for (i = 0; i < cb_press_n; i++)
        if (cb_presses[i].code == code && t >= cb_presses[i].from && t < cb_presses[i].to)
            return 1;
    return 0;
}

static void cb_press_option(const char *spec) {
    char name[32];
    double from, to;
    while (*spec && cb_press_n < 16) {
        int i, used = 0;
        if (sscanf(spec, "%31[^:]:%lf:%lf%n", name, &from, &to, &used) == 3) {
            for (i = 0; i < cb_net_key_count; i++)
                if (strcmp(cb_net_key_names[i], name) == 0) {
                    cb_presses[cb_press_n].code = cb_net_keys[i];
                    cb_presses[cb_press_n].from = from;
                    cb_presses[cb_press_n].to = to;
                    cb_press_n++;
                }
            spec += used;
        } else {
            fprintf(stderr, "[net] --press: KEY:FROM:TO (e.g. D:0.5:1.5), not '%s'\n", spec);
            exit(2);
        }
        if (*spec == ',') spec++;
        else break;
    }
    cb_press_start = cb_udp_now();
    cb_key_hook = cb_pressed_key;
}

bool cb_net_key_held(int player, int key, int file, int brick) {
    cb_key_state *k;
    (void)file; (void)brick;
    if (!cb_net_in_game(player))
        return false;  /* no player (a left one's, a server's own things): no keys */
    k = cb_key_state_of(player, false);
    return k ? cb_bit(k->hi, k->lo, key) : false;
}

/* ---- ownership (Give to / Owner / Mine?): a player's number on an object, inherited
   by what's under it; sent to clients with the world. */
void cb_net_give(void *object, int player, int file, int brick) {
    cb_object *o = (cb_object *)cb_obj(object, file, brick);
    o->owner = player > 0 ? player : 0;
}

static int cb_owner_number(cb_object *o) {
    for (; o && cb_alive(o); o = o->parent)
        if (o->owner)
            return o->owner;
    return 0;
}

/* Owner: the player it belongs to (its own or its nearest parent's); 0: no one's, or they left. */
int cb_net_owner(void *object, int file, int brick) {
    int n = cb_owner_number((cb_object *)cb_obj(object, file, brick));
    return cb_net_in_game(n) ? n : 0;
}

/* Owned by: the world's nodes given to a player (their own owner, not a parent's). */
cb_list *cb_net_owned_by(int player) {
    cb_list *out = cb_list_new(sizeof(cb_object *));
    void **all;
    int i, n = cb_world_objects(&all);
    for (i = 0; i < n && player > 0; i++)
        if (((cb_object *)all[i])->owner == player)
            *(cb_object **)cb_list_add(out) = (cb_object *)all[i];
    return out;
}

/* Mine?: this machine's player's; offline and on a host, no one's things are yours too. */
bool cb_net_mine(void *object, int file, int brick) {
    int n = cb_owner_number((cb_object *)cb_obj(object, file, brick));
    if (n == 0)
        return cb_net_role == CB_ROLE_OFFLINE || cb_net_role == CB_ROLE_HOST;
    return cb_net_me_num != 0 && n == cb_net_me_num && cb_net_in_game(n);
}

/* ---- receiving ---- */
static void cb_handle_data(cb_peer *p, unsigned long seq, const unsigned char *msg, int size) {
    cb_pack ack;
    cb_head(&ack, CB_K_ACK);
    cb_put32(&ack, seq);
    cb_raw(p, &ack);
    if (seq < p->recv_seq || seq >= p->recv_seq + CB_NET_WINDOW)
        return;  /* had it already (our ACK was lost), or too far ahead: it comes again */
    if (seq > p->recv_seq) {
        int slot = (int)(seq % CB_NET_WINDOW);
        if (!p->early[slot]) {
            p->early[slot] = (unsigned char *)malloc((size_t)size + 1);
            if (!p->early[slot]) return;
            memcpy(p->early[slot], msg, (size_t)size);
            p->early_size[slot] = size;
        }
        return;
    }
    /* This one, then the kept ones that follow it. */
    {
        unsigned char *owned = NULL;  /* a kept message taken out of `early` */
        for (;;) {
            cb_unpack u;
            int slot;
            u.d = msg; u.n = size; u.at = 0; u.bad = false;
            p->recv_seq++;
            if (cb_net_role == CB_ROLE_CLIENT)
                cb_client_message(&u);
            else
                cb_server_message(p, &u);
            free((void *)owned);
            if (!p->used || cb_net_role == CB_ROLE_OFFLINE)
                return;  /* (a refused hello closes the link) */
            slot = (int)(p->recv_seq % CB_NET_WINDOW);
            if (!p->early[slot])
                return;
            owned = p->early[slot];
            p->early[slot] = NULL;
            msg = owned;
            size = p->early_size[slot];
        }
    }
}

static void cb_handle_ack(cb_peer *p, unsigned long seq) {
    int i;
    for (i = 0; i < p->out_n; i++) {
        if (p->out[i].seq == seq) {
            p->out[i] = p->out[--p->out_n];
            return;
        }
    }
}

static cb_peer *cb_peer_at(const cb_addr *a) {
    int i;
    for (i = 0; i < CB_NET_PEERS; i++)
        if (cb_peers[i].used && cb_same_addr(&cb_peers[i].addr, a))
            return &cb_peers[i];
    return NULL;
}

static void cb_net_receive(void) {
    unsigned char buf[CB_NET_MTU];
    cb_addr from;
    int size;
    while ((size = cb_udp_recv(&from, buf, sizeof buf)) >= 0) {
        cb_peer *p;
        int kind;
        if (size < 4 || buf[0] != 'C' || buf[1] != 'N' || buf[2] != CB_NET_VERSION)
            continue;
        kind = buf[3];
        p = cb_peer_at(&from);
        if (!p) {
            /* A server takes a new link from a first hello (DATA number 0, HELLO). */
            if (cb_net_role == CB_ROLE_CLIENT || kind != CB_K_DATA || size < 9 || buf[4] || buf[5] || buf[6] || buf[7] || buf[8] != CB_M_HELLO)
                continue;
            p = cb_peer_new(&from);
            if (!p)
                continue;  /* full */
        }
        p->heard = cb_udp_now();
        if (kind == CB_K_DATA && size >= 8) {
            unsigned long seq = ((unsigned long)buf[4] << 24) | ((unsigned long)buf[5] << 16) | ((unsigned long)buf[6] << 8) | (unsigned long)buf[7];
            cb_handle_data(p, seq, buf + 8, size - 8);
        } else if (kind == CB_K_ACK && size >= 8) {
            cb_handle_ack(p, ((unsigned long)buf[4] << 24) | ((unsigned long)buf[5] << 16) | ((unsigned long)buf[6] << 8) | (unsigned long)buf[7]);
        } else if (kind == CB_K_BYE) {
            if (cb_net_role == CB_ROLE_CLIENT) {
                cb_net_note("the server closed the game");
                cb_net_go_offline();
                return;
            }
            cb_server_drop(p, "left");
        }
    }
}

/* Resends, keep-alives, timeouts. */
static void cb_net_upkeep(void) {
    double now = cb_udp_now();
    int i, j;
    for (i = 0; i < CB_NET_PEERS; i++) {
        cb_peer *p = &cb_peers[i];
        if (!p->used)
            continue;
        if (now - p->heard > CB_NET_TIMEOUT) {
            if (cb_net_role == CB_ROLE_CLIENT) {
                cb_net_note("lost the server (it stopped answering)");
                cb_net_go_offline();
                return;
            }
            cb_server_drop(p, "stopped answering");
            continue;
        }
        for (j = 0; j < p->out_n; j++) {
            if (now - p->out[j].sent > CB_NET_RESEND) {
                cb_udp_send(&p->addr, p->out[j].data, p->out[j].size);
                p->out[j].sent = now;
                p->said = now;
            }
        }
        if (now - p->said > CB_NET_KEEPALIVE)
            cb_signal(p, CB_K_PING);
    }
}

/* The network's turn: from Wait, every frame, after Host / Join (cb_poll_hook). */
void cb_net_poll(void) {
    if (cb_net_role != CB_ROLE_OFFLINE) {
        cb_net_receive();
        if (cb_net_role != CB_ROLE_OFFLINE)
            cb_net_upkeep();
    }
    cb_keys_sample();
    if (cb_net_role == CB_ROLE_HOST || cb_net_role == CB_ROLE_SERVER)
        cb_rep_tick(false);
    else if (cb_net_role == CB_ROLE_CLIENT)
        cb_glide_step();
    cb_net_deliver();
    if (cb_net_is_ready)
        cb_owned_scripts_check();
}

/* ---- the bricks' side ---- */
static bool cb_net_open_server(int port, bool play) {
    char line[200];
    if (!cb_udp_open(port)) {
        sprintf(line, "can't host on port %d: %.150s", port, cb_udp_error());
        cb_net_note(line);
        return false;
    }
    cb_side_set(play ? CB_ROLE_HOST : CB_ROLE_SERVER);
    if (!play)
        cb_net_remove_all();
    if (cb_verbose) {
        sprintf(line, "%s on port %d", play ? "hosting" : "serving", cb_udp_port());
        cb_net_note(line);
    }
    return true;
}

/* Host: a server with this machine's player as player 1. False: already in a game, or the port is taken. */
bool cb_net_host(int port) {
    if (cb_net_role != CB_ROLE_OFFLINE)
        return false;
    return cb_net_open_server(port, true);
}

/* Join: waits (up to timeout seconds) for the server's welcome. False: no answer, refused, or already in a game. */
bool cb_net_join(const char *address, int port, double timeout) {
    cb_addr to;
    cb_pack m;
    cb_peer *p;
    double until;
    char line[260];
    if (cb_net_role != CB_ROLE_OFFLINE)
        return false;
    if (!cb_udp_resolve(address, port, &to) || !cb_udp_open(0)) {
        sprintf(line, "can't join %.100s:%d: %.100s", address, port, cb_udp_error());
        cb_net_note(line);
        cb_udp_close();
        return false;
    }
    cb_side_set(CB_ROLE_CLIENT);
    cb_net_refused[0] = 0;
    cb_keys_sent_any = false;
    p = cb_peer_new(&to);
    m.n = 0;
    cb_put8(&m, CB_M_HELLO);
    cb_put_text(&m, cb_net_build);
    cb_put_text(&m, cb_net_name);
    cb_send(p, &m);
    until = cb_udp_now() + timeout;
    cb_net_has_world = false;
    while (!cb_net_has_world && !cb_net_refused[0] && cb_udp_now() < until && cb_net_role == CB_ROLE_CLIENT) {
        cb_net_receive();
        if (cb_net_role == CB_ROLE_CLIENT)
            cb_net_upkeep();
        if (!cb_net_has_world && !cb_net_refused[0])
            cb_sleep_ms(5);
    }
    if (cb_net_role == CB_ROLE_CLIENT && cb_net_has_world) {  /* welcomed, and the world arrived */
        cb_net_deliver();
        return true;
    }
    sprintf(line, "can't join %.100s:%d: %.100s", address, port, cb_net_refused[0] ? cb_net_refused : "no answer");
    cb_net_note(line);
    cb_net_close();
    cb_side_set(CB_ROLE_OFFLINE);
    return false;
}

/* Leave: back to single-player (a host's clients see the game close). */
void cb_net_leave(void) {
    if (cb_net_role == CB_ROLE_OFFLINE)
        return;
    cb_bye_all();
    cb_net_go_offline();
    cb_net_deliver();
}

const char *cb_net_role_name(void) {
    static const char *names[] = { "offline", "host", "server", "client" };
    return names[cb_net_role];
}

bool cb_net_is_server(void) { return cb_net_role != CB_ROLE_CLIENT; }

int cb_net_me(void) { return cb_net_me_num; }

/* Every player in the game (numbers, in the order they joined... the table's order). */
cb_list *cb_net_players(void) {
    cb_list *out = cb_list_new(sizeof(int));
    int i;
    for (i = 0; i < cb_player_n; i++)
        if (!cb_player_recs[i].leaving)
            *(int *)cb_list_add(out) = cb_player_recs[i].number;
    return out;
}

/* The player above `start`: the owner of the object the script is in (or its nearest
   owned parent: 0 when they've left); `found` says whether there was one, else it's
   this machine's player's turn. */
static int cb_player_above(void *start, bool *found) {
    cb_object *o = (cb_object *)start;
    *found = true;
    while (o && cb_alive(o)) {
        if (o->owner)
            return cb_net_in_game(o->owner) ? o->owner : 0;
        o = o->parent;
    }
    *found = false;
    return cb_net_me_num;
}

/* Player Input's blank Player: like cb_net_player_here, but none is no keys, not an error. */
int cb_net_player_soft(void *start) {
    bool found;
    return cb_player_above(start, &found);
}

/* A blank Player input: the owner of what the script is in, else this machine's player;
   a dedicated server has none: an error naming the brick. */
int cb_net_player_here(void *parent, int file, int brick) {
    bool found;
    int p = cb_player_above(parent, &found);
    if (found)
        return p;
    if (!cb_net_me_num) {
        fprintf(stderr, "[error] %s brick %d: no player here (a dedicated server has none): give the brick a player\n", cb_files[file], brick);
        exit(1);
    }
    return cb_net_me_num;
}

/* --server PORT, --host PORT, --join ADDRESS[:PORT], --name NAME (cb_start). */
void cb_net_option(const char *flag, const char *value) {
    if (strcmp(flag, "press") == 0) {
        cb_press_option(value);
        return;
    }
    if (strcmp(flag, "name") == 0) {
        sprintf(cb_net_name, "%.40s", value);
        return;
    }
    if (strcmp(flag, "join") == 0) {
        const char *colon = strrchr(value, ':');
        cb_net_want = CB_ROLE_CLIENT;
        if (colon) {
            size_t n = (size_t)(colon - value);
            if (n >= sizeof cb_net_want_address) n = sizeof cb_net_want_address - 1;
            memcpy(cb_net_want_address, value, n);
            cb_net_want_address[n] = 0;
            cb_net_want_port = atoi(colon + 1);
        } else {
            sprintf(cb_net_want_address, "%.120s", value);
        }
        return;
    }
    cb_net_want = strcmp(flag, "server") == 0 ? CB_ROLE_SERVER : CB_ROLE_HOST;
    cb_net_want_port = atoi(value);
}

static void cb_net_ready(void) {
    cb_net_is_ready = true;
    if (cb_net_role == CB_ROLE_CLIENT) {
        cb_world_prune(true);  /* the Main scene's objects the server no longer has */
        cb_root_reapply();     /* the root's Synced fields that came before the scene was made */
    }
    cb_net_deliver();
}

static void cb_net_at_exit(void) {
    if (cb_net_role != CB_ROLE_OFFLINE)
        cb_bye_all();
    cb_net_close();
}

/* From cb_register (inside cb_start, after the flags): the role the flags ask for. */
void cb_net_init(const char *build) {
    sprintf(cb_net_build, "%.60s", build);
    if (!cb_net_name[0]) {
        const char *user = getenv("USER");
        if (!user || !user[0]) user = getenv("USERNAME");
        sprintf(cb_net_name, "%.40s", user && user[0] ? user : "Player");
    }
    cb_poll_hook = cb_net_poll;
    cb_ready_hook = cb_net_ready;
    cb_clock_hook = cb_udp_now;
    cb_scene_match_hook = cb_scene_match;
    cb_scene_client_hook = cb_scene_client_wait;
    if (cb_net_want == CB_ROLE_SERVER)
        cb_headless = true;  /* a dedicated server: no window */
    atexit(cb_net_at_exit);
    if (cb_net_want == CB_ROLE_OFFLINE || cb_net_want == CB_ROLE_HOST)
        cb_net_add_player(1, cb_net_name, true);  /* single-player (and a host): you are player 1 (--join: the server's players come) */
    if (cb_net_want == CB_ROLE_SERVER || cb_net_want == CB_ROLE_HOST) {
        if (!cb_net_open_server(cb_net_want_port, cb_net_want == CB_ROLE_HOST))
            exit(1);
    } else if (cb_net_want == CB_ROLE_CLIENT) {
        if (!cb_net_join(cb_net_want_address, cb_net_want_port, CB_NET_TIMEOUT))
            exit(1);
    }
}
