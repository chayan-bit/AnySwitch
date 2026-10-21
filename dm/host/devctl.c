// Dev input channel sequence parser (docs/dev-control.md). Steps are separated by commas, semicolons or white space outside parentheses; each step is
//   [fN:]KEYS[~h][*n/every]   tap: KEYS down for h frames (default DEVCTL_HOLD), then up for DEVCTL_GAP frames; *n/every repeats it n times, every `every` frames
//   [fN:]hold(KEYS)           KEYS down until released
//   [fN:]release(KEYS) | release() | release   KEYS up (a stick name centres that stick); empty = everything up
//   [fN:]wait(N)              N frames pass
// KEYS joins key names with +: DM_KEYS's names (A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down, LLeft LUp LRight LDown, RLeft RUp RRight RDown,
// Shake, T<x>x<y> a touch at normalized picture coordinates) plus stick vectors L(x,y) and R(x,y) with x, y in [-1, 1] (up is +y).
// fN: puts the step at absolute frame N (it may not go back in time). Seconds stamps of DM_KEYS ("8:A") are refused: the channel counts frames only.
#include "devctl.h"
#include "dm_input.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef struct { uint64_t mask; int l, r, t; int32_t lx, ly, rx, ry; float tx, ty; } keyset;
typedef struct { devctl_ev *out; int n, max; char *err; size_t errlen; } sink;

static int fail(sink *k, const char *fmt, const char *arg) { snprintf(k->err, k->errlen, fmt, arg); return -1; }
static int emit(sink *k, devctl_ev e) {
    if (k->n >= k->max) { snprintf(k->err, k->errlen, "sequence too long (more than %d events)", k->max); return -1; }
    k->out[k->n++] = e; return 0;
}
// Unsigned decimal filling the whole string, at most `lim`
static int num(const char *s, uint64_t lim, uint64_t *v) {
    char *e; if (!*s || *s < '0' || *s > '9') return 0;
    unsigned long long x = strtoull(s, &e, 10); if (*e || x > lim) return 0;
    *v = x; return 1;
}
static int axis(const char *s, int32_t *v) {
    char *e; float f = strtof(s, &e); if (e == s || *e || !(f >= -1.0f && f <= 1.0f)) return 0;
    *v = (int32_t)(f * DM_STICK_MAX + (f < 0 ? -0.5f : 0.5f)); return 1;
}
// "x,y" inside L( ) / R( )
static int vec(char *s, int32_t *x, int32_t *y) { char *c = strchr(s, ','); if (!c) return 0; *c = 0; return axis(s, x) && axis(c + 1, y); }

static int parse_keys(sink *k, char *s, keyset *ks) {
    static const char *names[16] = {"A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "Plus", "Minus", "Left", "Up", "Right", "Down"};
    static const char *dirs[4] = {"Left", "Up", "Right", "Down"}; static const int dx[4] = {-DM_STICK_MAX, 0, DM_STICK_MAX, 0}, dy[4] = {0, DM_STICK_MAX, 0, -DM_STICK_MAX};
    memset(ks, 0, sizeof *ks);
    if (!*s) return fail(k, "empty key list%s", "");
    for (char *p = s; p;) {
        char *q = p; int depth = 0; while (*q && !(*q == '+' && !depth)) { depth += *q == '(' ? 1 : *q == ')' ? -1 : 0; q++; }
        char *next = *q ? q + 1 : NULL; *q = 0;
        int found = 0; size_t n = strlen(p);
        for (int b = 0; b < 16; b++) if (!strcasecmp(p, names[b])) { ks->mask |= 1ull << b; found = 1; }
        if (!strcasecmp(p, "Shake")) { ks->mask |= DM_BTN_SHAKE; found = 1; }
        for (int d = 0; d < 4 && !found; d++) {
            if ((p[0] == 'L' || p[0] == 'l') && !strcasecmp(p + 1, dirs[d])) { ks->l = 1; if (dx[d]) ks->lx = dx[d]; if (dy[d]) ks->ly = dy[d]; found = 1; }
            if ((p[0] == 'R' || p[0] == 'r') && !strcasecmp(p + 1, dirs[d])) { ks->r = 1; if (dx[d]) ks->rx = dx[d]; if (dy[d]) ks->ry = dy[d]; found = 1; }
        }
        if (!found && n > 3 && (p[0] == 'L' || p[0] == 'l' || p[0] == 'R' || p[0] == 'r') && p[1] == '(' && p[n - 1] == ')') {
            p[n - 1] = 0; int left = p[0] == 'L' || p[0] == 'l';
            if (!vec(p + 2, left ? &ks->lx : &ks->rx, left ? &ks->ly : &ks->ry)) return fail(k, "stick vector wants two numbers in [-1, 1]: %s", p);
            if (left) ks->l = 1; else ks->r = 1;
            found = 1;
        }
        if (!found && (p[0] == 'T' || p[0] == 't')) {
            char *x = strchr(p + 1, 'x'); char *e1, *e2;
            if (x) { *x = 0; ks->tx = strtof(p + 1, &e1); ks->ty = strtof(x + 1, &e2);
                if (e1 != p + 1 && !*e1 && e2 != x + 1 && !*e2 && ks->tx >= 0 && ks->tx <= 1 && ks->ty >= 0 && ks->ty <= 1) { ks->t = 1; found = 1; } else *x = 'x'; }
        }
        if (!found) return fail(k, "unknown key: %s", p);
        p = next;
    }
    return 0;
}
static int keys_down(sink *k, uint64_t f, const keyset *ks) {
    if (ks->mask && emit(k, (devctl_ev){f, DEVCTL_DOWN, ks->mask})) return -1;
    if (ks->l && emit(k, (devctl_ev){f, DEVCTL_LSTICK, 0, ks->lx, ks->ly})) return -1;
    if (ks->r && emit(k, (devctl_ev){f, DEVCTL_RSTICK, 0, ks->rx, ks->ry})) return -1;
    if (ks->t && emit(k, (devctl_ev){f, DEVCTL_TOUCH, 0, 0, 0, ks->tx, ks->ty})) return -1;
    return 0;
}
static int keys_up(sink *k, uint64_t f, const keyset *ks) {
    if (ks->mask && emit(k, (devctl_ev){f, DEVCTL_UP, ks->mask})) return -1;
    if (ks->l && emit(k, (devctl_ev){f, DEVCTL_LSTICK})) return -1;
    if (ks->r && emit(k, (devctl_ev){f, DEVCTL_RSTICK})) return -1;
    if (ks->t && emit(k, (devctl_ev){f, DEVCTL_UNTOUCH})) return -1;
    return 0;
}
// "verb(arg)" → arg (the closing parenthesis cut off), or NULL
static char *call(char *s, const char *verb) {
    size_t v = strlen(verb), n = strlen(s);
    if (n < v + 2 || strncasecmp(s, verb, v) || s[v] != '(' || s[n - 1] != ')') return NULL;
    s[n - 1] = 0; return s + v + 1;
}
#define FRAME_LIM 100000000ull   // about 38 days at 30 fps: anything larger is a typo

static int step(sink *k, char *s, uint64_t *cur) {
    char *c = strchr(s, ':'), *par = strchr(s, '(');
    if (c && (!par || c < par)) {   // a stamp: "fN:" (frames); DM_KEYS's seconds form is refused
        *c = 0; uint64_t f;
        if ((s[0] != 'f' && s[0] != 'F') || !num(s + 1, FRAME_LIM, &f)) return fail(k, "bad stamp '%s': use fN: (an absolute frame) or wait(N); the channel counts frames, not seconds", s);
        if (f < *cur) { char m[96]; snprintf(m, sizeof m, "frame %llu is behind the sequence (at frame %llu)", (unsigned long long)f, (unsigned long long)*cur); return fail(k, "%s", m); }
        *cur = f; s = c + 1;
    }
    char *a; keyset ks; uint64_t v;
    if ((a = call(s, "wait"))) { if (!num(a, FRAME_LIM, &v)) return fail(k, "wait wants a frame count: %s", a); *cur += v; return 0; }
    if ((a = call(s, "hold"))) return parse_keys(k, a, &ks) || keys_down(k, *cur, &ks) ? -1 : 0;
    if (!strcasecmp(s, "release") || !strcasecmp(s, "release()")) return emit(k, (devctl_ev){*cur, DEVCTL_RELEASE_ALL});
    if ((a = call(s, "release"))) return parse_keys(k, a, &ks) || keys_up(k, *cur, &ks) ? -1 : 0;
    // tap: KEYS[~h][*n/every]; ~ and * are looked for outside the parentheses of stick vectors
    uint64_t h = DEVCTL_HOLD, rep = 1, every = 0; int depth = 0; char *tilde = NULL, *star = NULL;
    for (char *p = s; *p; p++) { depth += *p == '(' ? 1 : *p == ')' ? -1 : 0; if (!depth && *p == '~' && !tilde) tilde = p; if (!depth && *p == '*' && !star) star = p; }
    if (star) { *star = 0; char *sl = strchr(star + 1, '/'); if (sl) *sl = 0;
        if (!num(star + 1, 10000, &rep) || !rep) return fail(k, "repeat count wants 1 to 10000: %s", star + 1);
        if (sl && !num(sl + 1, FRAME_LIM, &every)) return fail(k, "repeat interval wants a frame count: %s", sl + 1); }
    if (tilde) { *tilde = 0; if (!num(tilde + 1, FRAME_LIM, &h) || !h) return fail(k, "hold wants a frame count of at least 1: %s", tilde + 1); }
    if (!every) every = h + DEVCTL_GAP;
    if (every <= h) return fail(k, "repeat interval must be longer than the hold%s", "");
    if (parse_keys(k, s, &ks)) return -1;
    for (uint64_t i = 0; i < rep; i++) if (keys_down(k, *cur + i * every, &ks) || keys_up(k, *cur + i * every + h, &ks)) return -1;
    *cur += (rep - 1) * every + h + DEVCTL_GAP;
    return 0;
}

int devctl_parse(const char *src, uint64_t start, devctl_ev *out, int max, uint64_t *end, char *err, size_t errlen) {
    sink k = {out, 0, max, err, errlen}; uint64_t cur = start;
    size_t n = strlen(src); char *buf = malloc(n + 1); if (!buf) return fail(&k, "out of memory%s", "");
    memcpy(buf, src, n + 1);
    int depth = 0, rc = 0;
    for (char *p = buf, *tok = buf;; p++) {
        int sep = !*p || (!depth && (*p == ',' || *p == ';' || *p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'));
        if (*p == '(') depth++; else if (*p == ')') depth--;
        if (depth < 0) { rc = fail(&k, "unbalanced ')'%s", ""); break; }
        if (!*p && depth) { rc = fail(&k, "unbalanced '('%s", ""); break; }
        if (sep) { int last = !*p; *p = 0; if (*tok && (rc = step(&k, tok, &cur))) break; if (last) break; tok = p + 1; }
    }
    free(buf);
    if (rc) return -1;
    for (int i = 1; i < k.n; i++) { devctl_ev e = out[i]; int j = i; while (j > 0 && out[j - 1].frame > e.frame) { out[j] = out[j - 1]; j--; } out[j] = e; }   // stable: steps at one frame keep their order
    *end = cur;
    return k.n;
}

void devctl_apply(devctl_state *s, const devctl_ev *e) {
    switch (e->kind) {
    case DEVCTL_DOWN: s->btn |= e->mask; break;
    case DEVCTL_UP: s->btn &= ~e->mask; break;
    case DEVCTL_LSTICK: s->lx = e->x; s->ly = e->y; break;
    case DEVCTL_RSTICK: s->rx = e->x; s->ry = e->y; break;
    case DEVCTL_TOUCH: s->touch = 1; s->tx = e->tx; s->ty = e->ty; break;
    case DEVCTL_UNTOUCH: s->touch = 0; break;
    case DEVCTL_RELEASE_ALL: memset(s, 0, sizeof *s); break;
    }
}
