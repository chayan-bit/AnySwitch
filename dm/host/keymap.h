// Keyboard play (plan-hearth-p3.md 5.1): which key plays which game button or stick direction. One table for the Mac host (front_mac.m) and Hearth's keyboard input (DmGamepad.m).
// Keys are USB HID keyboard usages, the numbers GCKeyCode uses (J = 13, Return = 40). DM_MAP_KEY_<row> in the environment (a usage, 0 = not used) replaces a row's default;
// Hearth's settings export the player's choice under the same names.
#pragma once
#include <stdint.h>

// Rows 0-15: the game buttons in dm_input_set's bit order (A B X Y, left and right stick press, L R ZL ZR, + −, D-pad left up right down); 16-23: the left stick up down left right, then the right stick's
enum { DM_KEYMAP_BUTTONS = 16, DM_KEYMAP_ROWS = 24 };
extern const char *const dm_keymap_row[DM_KEYMAP_ROWS];         // the environment name's suffix: "A", "LS", "PLUS", "LS_UP"
extern const char *const dm_keymap_row_label[DM_KEYMAP_ROWS];   // what the settings row says: "A", "Left stick press", "Left stick up"
extern const uint8_t dm_keymap_default[DM_KEYMAP_ROWS];          // the Mac host's own keys: WASD, J K U I, F G, Q E Z C, Return Tab, the arrows; the right stick on P ; L '

int dm_keymap_key_count(void);             // the keys a row can take, in menu order
int dm_keymap_key_at(int i);               // the usage of the i-th
const char *dm_keymap_key_name(int usage); // "J", "Return", "Left arrow"; NULL for a key the map does not offer (0 too)
// The defaults with DM_MAP_KEY_* applied; returns how many entries were refused (not a number, or a key the map does not offer: that row keeps its default)
int dm_keymap_load(uint8_t map[DM_KEYMAP_ROWS]);
int dm_keymap_load_from(uint8_t map[DM_KEYMAP_ROWS], const char *(*get)(const char *name));   // the same with another source than the environment (Hearth's settings store)
// The game input for the keys held (down: one bit per usage, 256 bits). A stick direction pressed with its opposite cancels out
void dm_keymap_state(const uint8_t map[DM_KEYMAP_ROWS], const uint64_t down[4], uint64_t *buttons, int32_t *lx, int32_t *ly, int32_t *rx, int32_t *ry);
