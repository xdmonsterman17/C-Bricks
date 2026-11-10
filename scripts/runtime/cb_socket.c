/* ---- C-Bricks networking, part 1: one UDP socket and a clock ----------------------
   Its own file (cbricks_socket.c): the operating system's socket headers stay out of
   cbricks.h, so they never meet raylib.h (windows.h's Rectangle, CloseWindow...).
   Winsock on Windows, BSD sockets everywhere else; the Web and WASI have none here
   (a WebSocket bridge comes later): opening fails and says so. IPv4 for now.
   cbricks_net.c (the protocol) declares these same functions and cb_addr. */
#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#  define WIN32_LEAN_AND_MEAN
#  endif
#  include <winsock2.h>
#  include <ws2tcpip.h>
#  if defined(_MSC_VER)
#  pragma comment(lib, "ws2_32.lib")
#  endif
typedef SOCKET cb_sock_t;
#  define CB_NO_SOCK INVALID_SOCKET
#elif defined(__DJGPP__)
/* MS-DOS: Watt-32's BSD sockets (thirdparty/watt32, over a packet driver). DJGPP's headers hide
   their DOS parts under -std=c99, as in cb_be_dos.c. */
#  ifdef __STRICT_ANSI__
#  undef __STRICT_ANSI__
#  define CB_DOS_STRICT 1
#  endif
#  include <sys/types.h>
#  include <sys/socket.h>
#  include <netinet/in.h>
#  include <arpa/inet.h>
#  include <netdb.h>
#  include <sys/ioctl.h>
#  include <tcp.h>
#  include <time.h>
#  ifdef CB_DOS_STRICT
#  define __STRICT_ANSI__ 1
#  endif
typedef int cb_sock_t;
#  define CB_NO_SOCK (-1)
#elif defined(__EMSCRIPTEN__) || defined(__wasi__)
#  define CB_NO_SOCKETS 1
#  include <time.h>
#else
#  if defined(__linux__) && !defined(_POSIX_C_SOURCE)
#  define _POSIX_C_SOURCE 200112L  /* getaddrinfo, clock_gettime under -std=c99 */
#  endif
#  include <sys/types.h>
#  include <sys/socket.h>
#  include <netinet/in.h>
#  include <arpa/inet.h>
#  include <netdb.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <time.h>
#  if defined(__APPLE__)
#  include <mach/mach_time.h>
#  endif
typedef int cb_sock_t;
#  define CB_NO_SOCK (-1)
#endif
#include <stdio.h>
#include <string.h>
#include <stdbool.h>

typedef struct cb_addr { unsigned char ip[4]; unsigned short port; } cb_addr;

bool cb_udp_open(int port);
void cb_udp_close(void);
bool cb_udp_resolve(const char *host, int port, cb_addr *out);
bool cb_udp_send(const cb_addr *to, const void *data, int size);
int cb_udp_recv(cb_addr *from, void *buffer, int capacity);
int cb_udp_port(void);
const char *cb_udp_error(void);
double cb_udp_now(void);

static char cb_udp_why[160] = "";

#if defined(CB_NO_SOCKETS)
bool cb_udp_open(int port) { (void)port; strcpy(cb_udp_why, "networking isn't in this build (the Web / WASI have no UDP sockets yet)"); return false; }
void cb_udp_close(void) {}
bool cb_udp_resolve(const char *host, int port, cb_addr *out) { (void)host; (void)port; (void)out; return false; }
bool cb_udp_send(const cb_addr *to, const void *data, int size) { (void)to; (void)data; (void)size; return false; }
int cb_udp_recv(cb_addr *from, void *buffer, int capacity) { (void)from; (void)buffer; (void)capacity; return -1; }
int cb_udp_port(void) { return 0; }
const char *cb_udp_error(void) { return cb_udp_why; }
double cb_udp_now(void) { return (double)time(NULL); }  /* (no sockets here: only Join's timeout uses it) */
#else

static cb_sock_t cb_udp = CB_NO_SOCK;
static int cb_udp_bound = 0;

static void cb_udp_fail(const char *what) {
#if defined(_WIN32)
    sprintf(cb_udp_why, "%s (Winsock error %d)", what, WSAGetLastError());
#else
    sprintf(cb_udp_why, "%s", what);
#endif
}

bool cb_udp_open(int port) {
    struct sockaddr_in at;
    socklen_t size = (socklen_t)sizeof at;
#if defined(__DJGPP__)
    static bool started = false;
    long on = 1;
    if (!started) {  /* Watt-32 reads WATTCP.CFG (my_ip = dhcp ...) and talks to the packet driver */
        if (sock_init() != 0) { sprintf(cb_udp_why, "no network: is a packet driver loaded (NE2000.COM) and is WATTCP.CFG right?"); return false; }
        started = true;
    }
#elif defined(_WIN32)
    static bool started = false;
    u_long on = 1;
    if (!started) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { cb_udp_fail("can't start Winsock"); return false; }
        started = true;
    }
#endif
    cb_udp_close();
    cb_udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (cb_udp == CB_NO_SOCK) { cb_udp_fail("can't make a UDP socket"); return false; }
    memset(&at, 0, sizeof at);
    at.sin_family = AF_INET;
    at.sin_addr.s_addr = htonl(INADDR_ANY);
    at.sin_port = htons((unsigned short)port);
    if (bind(cb_udp, (struct sockaddr *)&at, (socklen_t)sizeof at) != 0) {
        sprintf(cb_udp_why, "port %d is taken (or not allowed)", port);
        cb_udp_close();
        return false;
    }
#if defined(__DJGPP__)
    ioctlsocket(cb_udp, FIONBIO, &on);
#elif defined(_WIN32)
    ioctlsocket(cb_udp, FIONBIO, &on);
#else
    fcntl(cb_udp, F_SETFL, fcntl(cb_udp, F_GETFL, 0) | O_NONBLOCK);
#endif
    cb_udp_bound = port;
    if (getsockname(cb_udp, (struct sockaddr *)&at, &size) == 0)
        cb_udp_bound = ntohs(at.sin_port);
    return true;
}

void cb_udp_close(void) {
    if (cb_udp == CB_NO_SOCK)
        return;
#if defined(_WIN32)
    closesocket(cb_udp);
#elif defined(__DJGPP__)
    close_s(cb_udp);
#else
    close(cb_udp);
#endif
    cb_udp = CB_NO_SOCK;
    cb_udp_bound = 0;
}

int cb_udp_port(void) { return cb_udp_bound; }

const char *cb_udp_error(void) { return cb_udp_why; }

bool cb_udp_resolve(const char *host, int port, cb_addr *out) {
    struct addrinfo hints, *found = NULL;
    const struct sockaddr_in *in;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (strcmp(host, "localhost") == 0 || host[0] == 0)
        host = "127.0.0.1";
#if defined(__DJGPP__)
    {   /* a dotted address needs no DNS (a DOS PC often has none set up) */
        unsigned long a = inet_addr(host);
        if (a != 0xFFFFFFFFul) {
            memcpy(out->ip, &a, 4);
            out->port = (unsigned short)port;
            return true;
        }
    }
#endif
    if (getaddrinfo(host, NULL, &hints, &found) != 0 || !found) {
        sprintf(cb_udp_why, "can't find the address '%.100s'", host);
        return false;
    }
    in = (const struct sockaddr_in *)(const void *)found->ai_addr;
    memcpy(out->ip, &in->sin_addr.s_addr, 4);
    out->port = (unsigned short)port;
    freeaddrinfo(found);
    return true;
}

bool cb_udp_send(const cb_addr *to, const void *data, int size) {
    struct sockaddr_in at;
    if (cb_udp == CB_NO_SOCK)
        return false;
    memset(&at, 0, sizeof at);
    at.sin_family = AF_INET;
    memcpy(&at.sin_addr.s_addr, to->ip, 4);
    at.sin_port = htons(to->port);
    return sendto(cb_udp, (const char *)data, size, 0, (const struct sockaddr *)&at, (socklen_t)sizeof at) == size;
}

/* One waiting packet into buffer: its size, or -1 when none is waiting. */
int cb_udp_recv(cb_addr *from, void *buffer, int capacity) {
    struct sockaddr_in at;
    socklen_t size = (socklen_t)sizeof at;
    int got;
    if (cb_udp == CB_NO_SOCK)
        return -1;
    for (;;) {
        got = (int)recvfrom(cb_udp, (char *)buffer, capacity, 0, (struct sockaddr *)&at, &size);
        if (got >= 0)
            break;
#if defined(_WIN32)
        if (WSAGetLastError() == WSAECONNRESET)  /* an earlier send was refused: skip it */
            continue;
#endif
        return -1;
    }
    memcpy(from->ip, &at.sin_addr.s_addr, 4);
    from->port = ntohs(at.sin_port);
    return got;
}

/* Seconds from some fixed point, steady (not the time of day, not CPU time). */
double cb_udp_now(void) {
#if defined(_WIN32)
    return (double)GetTickCount64() / 1000.0;
#elif defined(__DJGPP__)
    return (double)uclock() / (double)UCLOCKS_PER_SEC;
#elif defined(__APPLE__)
    static mach_timebase_info_data_t base;
    if (base.denom == 0)
        mach_timebase_info(&base);
    return (double)mach_absolute_time() * base.numer / base.denom / 1e9;
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
#endif
}
#endif
