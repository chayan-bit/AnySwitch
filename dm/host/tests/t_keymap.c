// keymap.c: the defaults are the Mac host's own keys, DM_MAP_KEY_* replaces them (0 = not used, an unknown key is refused), held keys become buttons and stick directions
#include "../keymap.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void press(uint64_t d[4], int u) { d[u >> 6] |= 1ull << (u & 63); }

int main(void) {
    // the keys front_mac.m played before the map (J K U I, F G, Q E Z C, Return Tab, arrows; WASD), as HID usages
    static const uint8_t mac[DM_KEYMAP_ROWS] = {13, 14, 24, 12, 9, 10, 20, 8, 29, 6, 40, 43, 80, 82, 79, 81, 26, 22, 4, 7};
    CHECK(!memcmp(dm_keymap_default, mac, 20), "defaults: the Mac host's keys");
    int seen[256] = {0}, dup = 0;
    for (int r = 0; r < DM_KEYMAP_ROWS; r++) { if (seen[dm_keymap_default[r]]++) dup++; CHECK(dm_keymap_key_name(dm_keymap_default[r]), "row %s: its default key is offered", dm_keymap_row[r]); }
    CHECK(!dup, "no key plays two rows by default");
    CHECK(!dm_keymap_key_name(41) && !dm_keymap_key_name(227) && !dm_keymap_key_name(0), "Escape, Command and 0 are not offered");
    CHECK(dm_keymap_key_count() > 50 && dm_keymap_key_at(0) == 4 && !strcmp(dm_keymap_key_name(40), "Return"), "the offered keys");

    uint8_t map[DM_KEYMAP_ROWS];
    CHECK(dm_keymap_load(map) == 0 && !memcmp(map, dm_keymap_default, DM_KEYMAP_ROWS), "no environment: the defaults");
    setenv("DM_MAP_KEY_A", "44", 1); setenv("DM_MAP_KEY_B", "0", 1); setenv("DM_MAP_KEY_X", "41", 1); setenv("DM_MAP_KEY_Y", "J", 1); setenv("DM_MAP_KEY_RS_UP", "82", 1);
    CHECK(dm_keymap_load(map) == 2, "Escape and a letter name refused");
    CHECK(map[0] == 44 && map[1] == 0 && map[2] == 24 && map[3] == 12 && map[20] == 82, "Space plays A, B is not used, refused rows keep their defaults");

    uint64_t d[4] = {0}, b; int32_t lx, ly, rx, ry;
    press(d, 44); press(d, 26); press(d, 82);
    dm_keymap_state(map, d, &b, &lx, &ly, &rx, &ry);
    CHECK(b == (1ull << 0 | 1ull << 13), "Space: A; Up arrow: D-pad up (and the right stick up it now also plays): %llx", (unsigned long long)b);
    CHECK(ly == 32767 && lx == 0 && ry == 32767 && rx == 0, "W: left stick up; Up arrow: right stick up: %d %d %d %d", lx, ly, rx, ry);
    press(d, 22); press(d, 7);
    dm_keymap_state(map, d, &b, &lx, &ly, &rx, &ry);
    CHECK(ly == 0 && lx == 32767, "W with S cancels out; D: right: %d %d", lx, ly);
    memset(d, 0, sizeof d); press(d, 14);
    dm_keymap_state(map, d, &b, &lx, &ly, &rx, &ry);
    CHECK(b == 0, "K no longer plays B (not used)");
    printf("t_keymap: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
}
