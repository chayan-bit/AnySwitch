// Dev input channel parser (devctl.c): every expected event is written out by hand. Build and run: make -C dm/host/tests GAME=<id> run (or clang -I.. t_devctl.c ../devctl.c)
#include "../devctl.h"
#include "../dm_input.h"
#include <stdio.h>
#include <string.h>

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  x "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static devctl_ev ev[DEVCTL_MAX_EV]; static uint64_t end; static char err[160];
static int P(const char *s, uint64_t start) { err[0] = 0; return devctl_parse(s, start, ev, DEVCTL_MAX_EV, &end, err, sizeof err); }
static int is(int i, uint64_t f, int kind, uint64_t mask, int32_t x, int32_t y) { return ev[i].frame == f && ev[i].kind == kind && ev[i].mask == mask && ev[i].x == x && ev[i].y == y; }
static devctl_state run_to(int n, uint64_t frame) { devctl_state s = {0}; for (int i = 0; i < n && ev[i].frame <= frame; i++) devctl_apply(&s, &ev[i]); return s; }

int main(void) {
    int n;
    printf("1 tap: default hold, then the gap\n");
    n = P("A", 100);
    CHECK(n == 2 && is(0, 100, DEVCTL_DOWN, DM_BTN_A, 0, 0) && is(1, 105, DEVCTL_UP, DM_BTN_A, 0, 0) && end == 110, "n=%d end=%llu err=%s", n, (unsigned long long)end, err);
    printf("2 combo, hold length, two taps in a row\n");
    n = P("a+b~3, Plus", 0);
    CHECK(n == 4 && is(0, 0, DEVCTL_DOWN, DM_BTN_A | DM_BTN_B, 0, 0) && is(1, 3, DEVCTL_UP, DM_BTN_A | DM_BTN_B, 0, 0) && is(2, 8, DEVCTL_DOWN, DM_BTN_PLUS, 0, 0) && end == 18, "n=%d end=%llu err=%s", n, (unsigned long long)end, err);
    printf("3 repeat *n/every interleaves by frame\n");
    n = P("A*3/10", 0);
    CHECK(n == 6 && is(0, 0, DEVCTL_DOWN, DM_BTN_A, 0, 0) && is(1, 5, DEVCTL_UP, DM_BTN_A, 0, 0) && is(4, 20, DEVCTL_DOWN, DM_BTN_A, 0, 0) && end == 30, "n=%d end=%llu", n, (unsigned long long)end);
    n = P("A~2*2", 0);   // default interval = hold + gap
    CHECK(n == 4 && is(2, 7, DEVCTL_DOWN, DM_BTN_A, 0, 0) && end == 14, "default interval: n=%d end=%llu", n, (unsigned long long)end);
    printf("4 absolute frame stamps and wait\n");
    n = P("f500:A wait(20) B", 400);
    CHECK(n == 4 && is(0, 500, DEVCTL_DOWN, DM_BTN_A, 0, 0) && is(2, 530, DEVCTL_DOWN, DM_BTN_B, 0, 0) && end == 540, "n=%d end=%llu err=%s", n, (unsigned long long)end, err);
    CHECK(P("f300:A", 400) < 0 && strstr(err, "behind"), "a stamp in the past is refused: %s", err);
    CHECK(P("f500:A f502:B", 400) < 0, "a stamp inside the last tap goes back in time");
    CHECK(P("8:A", 0) < 0 && strstr(err, "frames"), "seconds stamps are refused: %s", err);
    printf("5 hold and release, sticks and vectors\n");
    n = P("hold(ZL+LUp) wait(30) release(LUp) wait(1) release", 10);
    CHECK(n == 4 && is(0, 10, DEVCTL_DOWN, DM_BTN_ZL, 0, 0) && is(1, 10, DEVCTL_LSTICK, 0, 0, DM_STICK_MAX) && is(2, 40, DEVCTL_LSTICK, 0, 0, 0) && is(3, 41, DEVCTL_RELEASE_ALL, 0, 0, 0) && end == 41, "n=%d end=%llu err=%s", n, (unsigned long long)end, err);
    devctl_state s = run_to(n, 39); CHECK(s.btn == DM_BTN_ZL && s.ly == DM_STICK_MAX, "held state at frame 39");
    s = run_to(n, 40); CHECK(s.btn == DM_BTN_ZL && s.ly == 0, "stick centred at frame 40, ZL still held");
    s = run_to(n, 41); CHECK(!s.btn && !s.lx && !s.ly, "everything up at frame 41");
    n = P("L(0.5,-1)~60 R(-1,+0.25)", 0);
    CHECK(n == 4 && is(0, 0, DEVCTL_LSTICK, 0, 16384, -DM_STICK_MAX) && is(1, 60, DEVCTL_LSTICK, 0, 0, 0) && is(2, 65, DEVCTL_RSTICK, 0, -DM_STICK_MAX, 8192) && end == 75, "n=%d err=%s x=%d", n, err, ev[0].x);
    n = P("LLeft+RDown", 0); CHECK(n == 4 && is(0, 0, DEVCTL_LSTICK, 0, -DM_STICK_MAX, 0) && is(1, 0, DEVCTL_RSTICK, 0, 0, -DM_STICK_MAX), "direction names: n=%d", n);
    n = P("Left+Right+L+R+LS+RS", 0); CHECK(n == 2 && ev[0].mask == (DM_BTN_LEFT | DM_BTN_RIGHT | DM_BTN_L | DM_BTN_R | DM_BTN_LS | DM_BTN_RS), "d-pad and shoulder names are buttons");
    CHECK(P("L(2,0)", 0) < 0, "vector out of range refused");
    CHECK(P("L(0.5)", 0) < 0, "vector with one number refused");
    printf("6 touch and shake\n");
    n = P("T0.25x0.75~2 Shake", 0);
    CHECK(n == 4 && ev[0].kind == DEVCTL_TOUCH && ev[0].tx == 0.25f && ev[0].ty == 0.75f && ev[1].kind == DEVCTL_UNTOUCH && ev[1].frame == 2 && ev[2].mask == DM_BTN_SHAKE, "n=%d err=%s", n, err);
    CHECK(P("T1.5x0", 0) < 0, "touch outside the picture refused");
    printf("7 errors name the problem\n");
    CHECK(P("Q", 0) < 0 && strstr(err, "unknown key: Q"), "unknown key: %s", err);
    CHECK(P("hold(A", 0) < 0 && strstr(err, "unbalanced"), "unbalanced: %s", err);
    CHECK(P("A~0", 0) < 0, "zero hold refused");
    CHECK(P("A*2/3~5", 0) < 0, "interval not longer than the hold refused");
    CHECK(P("wait(x)", 0) < 0, "wait wants a number");
    CHECK(P("frame", 0) < 0, "a command word is not a key");
    n = P("", 7); CHECK(n == 0 && end == 7, "an empty sequence is a no-op");
    devctl_ev small[3]; CHECK(devctl_parse("A A", 0, small, 3, &end, err, sizeof err) < 0 && strstr(err, "too long"), "event limit: %s", err);
    printf("%s: %d/%d checks\n", fails ? "FAIL" : "PASS", checks - fails, checks);
    return fails != 0;
}
