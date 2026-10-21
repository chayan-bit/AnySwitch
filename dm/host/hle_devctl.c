// Dev input channel server (docs/dev-control.md). Compiled only into dev builds (make DEVCTL=1 defines DM_DEVCTL; the iOS project takes the flag from the same compile command);
// a product build carries none of this. A TCP socket on one local address, never a wildcard: DM_DEVCTL_ADDR names it, "tunnel" means the device side of the
// CoreDevice tunnel (the default on iOS: devicectl and Xcode reach the device through it, and a connection through it arrives on that address, not on loopback),
// otherwise the default is the loopback address. Port DM_DEVCTL_PORT (default 47800).
// A random token, printed in the log at start, must be the first line of every connection. One client at a time; line protocol:
//   auth <token>   → "ok frame <N>"            (anything else first → "err auth", connection closed)
//   frame          → "frame <N>"               (presented frames so far, dm_guest_frame)
//   run <sequence> → "done start <S> end <E> frame <N>" once the game has reached frame E, or "err <why>" (devctl.c grammar)
//   quit
// No other command exists: the channel only presses controller inputs and reads the frame number.
// Input goes through dm_pad_set, the path DM_KEYS uses: ORed with the keyboard / touch / physical controller path, edges latched until the game's next read.
// Events are applied when the game reads the controller (hle_hid.c calls devctl_poll), against the frame counter at that read, so a frame-stamped sequence lands on the same frames every run.
#ifdef DM_DEVCTL
#include "hle.h"
#include "dm_input.h"
#include "front.h"
#include "devctl.h"
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <TargetConditionals.h>

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static devctl_ev g_q[DEVCTL_MAX_EV]; static int g_qn, g_qi;   // pending events g_q[g_qi .. g_qn), sorted by frame
static devctl_state g_st;
static _Atomic uint64_t g_due = UINT64_MAX;                  // frame of the first pending event (a lock-free check on every controller read)

static void publish(const devctl_state *o) {
    dm_pad_set(g_st.btn, g_st.lx, g_st.ly, g_st.rx, g_st.ry);
    if (g_st.touch != o->touch || (g_st.touch && (g_st.tx != o->tx || g_st.ty != o->ty))) {
        dm_touch t = {0, g_st.tx, g_st.ty}; dm_touch_set(g_st.touch ? &t : NULL, g_st.touch);
    }
}
void devctl_poll(void) {
    uint64_t f = dm_guest_frame();
    if (f < atomic_load(&g_due)) return;
    pthread_mutex_lock(&g_mu);
    while (g_qi < g_qn && g_q[g_qi].frame <= f) { devctl_state o = g_st; devctl_apply(&g_st, &g_q[g_qi++]); publish(&o); }   // one publish per event: a press and release due together still latch the press
    atomic_store(&g_due, g_qi < g_qn ? g_q[g_qi].frame : UINT64_MAX);
    pthread_mutex_unlock(&g_mu);
}
// Queue a parsed sequence. Leftovers of the last one (due, but the game has not read the controller since) stay in front: they are all earlier than the new start
static void enqueue(const devctl_ev *ev, int n) {
    pthread_mutex_lock(&g_mu);
    memmove(g_q, g_q + g_qi, (size_t)(g_qn - g_qi) * sizeof *g_q); g_qn -= g_qi; g_qi = 0;
    int room = DEVCTL_MAX_EV - g_qn; if (n > room) { LOG("[RED] devctl: queue full, %d events dropped", n - room); n = room; }
    memcpy(g_q + g_qn, ev, (size_t)n * sizeof *ev); g_qn += n;
    atomic_store(&g_due, g_qn ? g_q[0].frame : UINT64_MAX);
    pthread_mutex_unlock(&g_mu);
}

static int send_line(int fd, const char *s) {
    size_t n = strlen(s);
    while (n) { ssize_t w = send(fd, s, n, 0); if (w < 0 && errno == EINTR) continue; if (w <= 0) return -1; s += w; n -= (size_t)w; }
    return 0;
}
static int recv_line(int fd, char *buf, size_t n) {   // 1 = a line (newline stripped), 0 = closed / error / over-long
    size_t i = 0;
    for (;;) { char c; ssize_t r = recv(fd, &c, 1, 0); if (r < 0 && errno == EINTR) continue; if (r <= 0) return 0;
        if (c == '\n') { if (i && buf[i - 1] == '\r') i--; buf[i] = 0; return 1; }
        if (i + 1 >= n) return 0; buf[i++] = c; }
}
static int token_eq(const char *a, const char *b) {   // constant time over the token (its length is no secret)
    size_t n = strlen(b); if (strlen(a) != n) return 0;
    unsigned d = 0; for (size_t i = 0; i < n; i++) d |= (unsigned char)(a[i] ^ b[i]);
    return !d;
}

static char g_token[33];
#define LINE_MAX_DEVCTL 65536
static void serve(int fd) {
    static char line[LINE_MAX_DEVCTL]; static devctl_ev ev[DEVCTL_MAX_EV]; char out[160], err[160];
    struct timeval tv = {10, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);   // the token must come within 10 s
    if (!recv_line(fd, line, sizeof line) || strncmp(line, "auth ", 5) || !token_eq(line + 5, g_token)) {
        LOG("[RED] devctl: connection refused (no or wrong token)"); send_line(fd, "err auth\n"); sleep(1); return;
    }
    tv.tv_sec = 0; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    snprintf(out, sizeof out, "ok frame %llu\n", (unsigned long long)dm_guest_frame()); if (send_line(fd, out)) return;
    LOG("devctl: client connected");
    while (recv_line(fd, line, sizeof line)) {
        if (!strcmp(line, "quit")) break;
        if (!strcmp(line, "frame")) snprintf(out, sizeof out, "frame %llu\n", (unsigned long long)dm_guest_frame());
        else if (!strncmp(line, "run ", 4)) {
            uint64_t start = dm_guest_frame() + 1, end;
            int n = devctl_parse(line + 4, start, ev, DEVCTL_MAX_EV, &end, err, sizeof err);
            if (n < 0) snprintf(out, sizeof out, "err %s\n", err);
            else {
                LOG("devctl: run frames %llu..%llu, %d events: %.200s", (unsigned long long)start, (unsigned long long)end, n, line + 4);
                enqueue(ev, n);
                while (dm_guest_frame() < end) usleep(2000);
                snprintf(out, sizeof out, "done start %llu end %llu frame %llu\n", (unsigned long long)start, (unsigned long long)end, (unsigned long long)dm_guest_frame());
            }
        } else snprintf(out, sizeof out, "err unknown command (auth, frame, run, quit)\n");
        if (send_line(fd, out)) break;
    }
    LOG("devctl: client gone");
}
static void *server_main(void *arg) {
    int ls = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) { if (errno == EINTR || errno == ECONNABORTED) continue; LOG("[RED] devctl: accept failed errno=%d, channel closed", errno); return NULL; }
        int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one); setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        serve(fd); close(fd);
    }
}
// The device side of the CoreDevice tunnel, which devicectl prints as "Tunnel IP Address" (`devicectl device info details`): a unique local
// IPv6 address (fd00::/8) with a /64 prefix on a utun interface whose MTU is 16000. VPNs also use utun interfaces with unique local addresses
// (Tailscale: fd7a:115c:a1e0::/48, MTU 1280), so all three must hold, and more than one match (a device paired to two Macs) is refused.
static int tunnel_addr(char *out, size_t n) {
    struct ifaddrs *ifs, *i; int found = 0, s = socket(AF_INET6, SOCK_DGRAM, 0);
    if (s < 0) return 0;
    if (getifaddrs(&ifs)) { close(s); return 0; }
    for (i = ifs; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET6 || !i->ifa_netmask || strncmp(i->ifa_name, "utun", 4) || !(i->ifa_flags & IFF_UP)) continue;
        const struct in6_addr *a = &((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, *m = &((struct sockaddr_in6 *)i->ifa_netmask)->sin6_addr;
        int bits = 0; for (int k = 0; k < 16; k++) bits += __builtin_popcount(m->s6_addr[k]);
        struct ifreq r = {0}; strlcpy(r.ifr_name, i->ifa_name, sizeof r.ifr_name);
        if (a->s6_addr[0] != 0xfd || bits != 64 || ioctl(s, SIOCGIFMTU, &r) || r.ifr_mtu != 16000) continue;
        char t[INET6_ADDRSTRLEN]; inet_ntop(AF_INET6, a, t, sizeof t);
        LOG("devctl: CoreDevice tunnel candidate %s on %s", t, i->ifa_name);
        if (!found++) strlcpy(out, t, n);
    }
    freeifaddrs(ifs); close(s);
    if (found > 1) LOG("[RED] devctl: %d CoreDevice tunnel interfaces, set DM_DEVCTL_ADDR to the right one", found);
    return found == 1;
}
void devctl_start(void) {
    const char *addr = getenv("DM_DEVCTL_ADDR"), *port_s = getenv("DM_DEVCTL_PORT");
    if (!addr || !*addr) addr = TARGET_OS_IPHONE ? "tunnel" : "127.0.0.1";
    char tun[INET6_ADDRSTRLEN];
    if (!strcmp(addr, "tunnel")) {
        if (!tunnel_addr(tun, sizeof tun)) { LOG("[RED] devctl: no single CoreDevice tunnel interface (launch from devicectl or Xcode, or set DM_DEVCTL_ADDR), channel off"); return; }
        addr = tun;
    }
    int port = port_s && *port_s ? atoi(port_s) : 47800;
    if (port <= 0 || port > 65535) { LOG("[RED] devctl: bad DM_DEVCTL_PORT %s, channel off", port_s); return; }
    struct sockaddr_storage ss = {0}; socklen_t sl; int fam;
    struct sockaddr_in *a4 = (struct sockaddr_in *)&ss; struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&ss;
    if (inet_pton(AF_INET, addr, &a4->sin_addr) == 1) { fam = AF_INET; a4->sin_family = AF_INET; a4->sin_port = htons((uint16_t)port); sl = sizeof *a4;
        if (a4->sin_addr.s_addr == htonl(INADDR_ANY)) { LOG("[RED] devctl: refusing the wildcard address, channel off"); return; } }
    else if (inet_pton(AF_INET6, addr, &a6->sin6_addr) == 1) { fam = AF_INET6; a6->sin6_family = AF_INET6; a6->sin6_port = htons((uint16_t)port); sl = sizeof *a6;
        if (IN6_IS_ADDR_UNSPECIFIED(&a6->sin6_addr)) { LOG("[RED] devctl: refusing the wildcard address, channel off"); return; } }
    else { LOG("[RED] devctl: DM_DEVCTL_ADDR %s is not a numeric address, channel off", addr); return; }
    ss.ss_len = (uint8_t)sl;
    int ls = socket(fam, SOCK_STREAM, 0), one = 1;
    if (ls < 0) { LOG("[RED] devctl: socket failed errno=%d, channel off", errno); return; }
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(ls, (struct sockaddr *)&ss, sl) || listen(ls, 1)) { LOG("[RED] devctl: cannot listen on %s port %d errno=%d, channel off", addr, port, errno); close(ls); return; }
    uint8_t r[16]; arc4random_buf(r, sizeof r);
    for (int i = 0; i < 16; i++) snprintf(g_token + 2 * i, 3, "%02x", r[i]);
    pthread_t th; if (pthread_create(&th, NULL, server_main, (void *)(intptr_t)ls)) { LOG("[RED] devctl: no thread, channel off"); close(ls); return; }
    pthread_detach(th);
    LOG("devctl: dev input channel listening on %s port %d, token %s", addr, port, g_token);
}
#endif
