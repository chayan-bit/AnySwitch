// Keyboard play (keymap.h)
#include "keymap.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *const dm_keymap_row[DM_KEYMAP_ROWS] = {"A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "PLUS", "MINUS", "LEFT", "UP", "RIGHT", "DOWN",
                                                   "LS_UP", "LS_DOWN", "LS_LEFT", "LS_RIGHT", "RS_UP", "RS_DOWN", "RS_LEFT", "RS_RIGHT"};
const char *const dm_keymap_row_label[DM_KEYMAP_ROWS] = {"A", "B", "X", "Y", "Left stick press", "Right stick press", "L", "R", "ZL", "ZR", "+", "−",
    "D-pad left", "D-pad up", "D-pad right", "D-pad down", "Left stick up", "Left stick down", "Left stick left", "Left stick right",
    "Right stick up", "Right stick down", "Right stick left", "Right stick right"};
const uint8_t dm_keymap_default[DM_KEYMAP_ROWS] = {13, 14, 24, 12, 9, 10, 20, 8, 29, 6, 40, 43, 80, 82, 79, 81,   // J K U I, F G, Q E Z C, Return Tab, arrows
                                                   26, 22, 4, 7, 19, 51, 15, 52};                                  // W S A D; P ; L '

// Escape stays with the menus and Command with the key commands (Cmd+Return is HOME), so neither is offered
static const struct { uint8_t usage; const char *name; } k_keys[] = {
    {4, "A"}, {5, "B"}, {6, "C"}, {7, "D"}, {8, "E"}, {9, "F"}, {10, "G"}, {11, "H"}, {12, "I"}, {13, "J"}, {14, "K"}, {15, "L"}, {16, "M"}, {17, "N"}, {18, "O"}, {19, "P"},
    {20, "Q"}, {21, "R"}, {22, "S"}, {23, "T"}, {24, "U"}, {25, "V"}, {26, "W"}, {27, "X"}, {28, "Y"}, {29, "Z"},
    {30, "1"}, {31, "2"}, {32, "3"}, {33, "4"}, {34, "5"}, {35, "6"}, {36, "7"}, {37, "8"}, {38, "9"}, {39, "0"},
    {40, "Return"}, {43, "Tab"}, {44, "Space"}, {42, "Delete"},
    {82, "Up arrow"}, {81, "Down arrow"}, {80, "Left arrow"}, {79, "Right arrow"},
    {225, "Left Shift"}, {229, "Right Shift"}, {224, "Control"}, {226, "Left Option"}, {230, "Right Option"},
    {51, ";"}, {52, "'"}, {54, ","}, {55, "."}, {56, "/"}, {47, "["}, {48, "]"}, {45, "-"}, {46, "="}, {49, "\\"}, {53, "`"},
};
enum { K_N = sizeof k_keys / sizeof k_keys[0] };

int dm_keymap_key_count(void) { return K_N; }
int dm_keymap_key_at(int i) { return i >= 0 && i < K_N ? k_keys[i].usage : 0; }
const char *dm_keymap_key_name(int usage) {
    for (int i = 0; i < K_N; i++) if (k_keys[i].usage == usage) return k_keys[i].name;
    return NULL;
}

static const char *env_value(const char *name) { return getenv(name); }
int dm_keymap_load(uint8_t map[DM_KEYMAP_ROWS]) { return dm_keymap_load_from(map, env_value); }
int dm_keymap_load_from(uint8_t map[DM_KEYMAP_ROWS], const char *(*get)(const char *name)) {
    int refused = 0;
    for (int r = 0; r < DM_KEYMAP_ROWS; r++) {
        map[r] = dm_keymap_default[r];
        char name[32]; snprintf(name, sizeof name, "DM_MAP_KEY_%s", dm_keymap_row[r]);
        const char *v = get(name); if (!v || !*v) continue;
        char *end; long u = strtol(v, &end, 10);
        if (*end || u < 0 || (u && !dm_keymap_key_name((int)u))) { refused++; continue; }
        map[r] = (uint8_t)u;
    }
    return refused;
}

static int held(const uint64_t down[4], uint8_t usage) { return usage && (down[usage >> 6] >> (usage & 63) & 1); }
static int32_t axis(const uint64_t down[4], uint8_t plus, uint8_t minus) { return (held(down, plus) - held(down, minus)) * 32767; }

void dm_keymap_state(const uint8_t map[DM_KEYMAP_ROWS], const uint64_t down[4], uint64_t *buttons, int32_t *lx, int32_t *ly, int32_t *rx, int32_t *ry) {
    uint64_t m = 0;
    for (int b = 0; b < DM_KEYMAP_BUTTONS; b++) if (held(down, map[b])) m |= 1ull << b;
    *buttons = m;
    *ly = axis(down, map[16], map[17]); *lx = axis(down, map[19], map[18]);
    *ry = axis(down, map[20], map[21]); *rx = axis(down, map[23], map[22]);
}
