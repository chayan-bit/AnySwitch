// Album unit test (hle_album.c): a game's own 1280x720 picture reaches the front end once with its pixels, a short buffer, another size or a pointer outside the guest is refused,
// and the front end's answer decides the Result. Run: make -C dm/host/tests run
#include "../hle.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Result dm_album_save(const void *p, size_t n, int size);

static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  ✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static uint8_t *g_guest; static size_t g_guest_n;   // the stand-in guest memory
static int g_calls, g_w, g_h, g_answer; static uint8_t g_first;
int dm_guest_as_contains(uintptr_t a) { return g_guest && a >= (uintptr_t)g_guest && a < (uintptr_t)g_guest + g_guest_n; }
int front_album_save(const void *rgba, int w, int h) { g_calls++; g_w = w; g_h = h; g_first = *(const uint8_t *)rgba; return g_answer; }
int front_capture(void) { return 0; }

int main(void) {
    const size_t px = 1280 * 720 * 4;
    g_guest_n = px + 64; g_guest = calloc(1, g_guest_n); g_guest[16] = 0xab;
    CHECK(dm_album_save(g_guest + 16, px, 0) == 0 && g_calls == 1 && g_w == 1280 && g_h == 720 && g_first == 0xab, "a 1280x720 picture is saved: calls %d, %dx%d, first byte %02x", g_calls, g_w, g_h, g_first);
    CHECK(dm_album_save(g_guest, px - 1, 0) == RES_FAIL && g_calls == 1, "a buffer one byte short is refused before the front end");
    CHECK(dm_album_save(g_guest, px, 1) == RES_FAIL && g_calls == 1, "another image size is refused");
    CHECK(dm_album_save(g_guest + 128, px, 0) == RES_FAIL && g_calls == 1, "a picture running past the guest's memory is refused");
    CHECK(dm_album_save(NULL, px, 0) == RES_FAIL && g_calls == 1, "no buffer is refused");
    g_answer = -1;
    CHECK(dm_album_save(g_guest, px, 0) == RES_FAIL && g_calls == 2, "the front end has no album: the game is told it failed");
    printf("t_album: %d checks, %d failed\n", checks, fails);
    free(g_guest);
    return fails != 0;
}
