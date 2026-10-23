// Which input plays which game button (plan-hearth-p3.md 5.2): the registry entries Hearth's Controllers page edits, and the controller table DmGamepad.m plays from.
// Controller: one row per game button naming the physical input that plays it, by position (DM_MAP_PAD_<row>), so one map fits every controller; the default is the positional map
// read_pad always had (the right face button plays A). Keyboard: keymap.h (DM_MAP_KEY_<row>). Both are system settings, live. Foundation only (dm/ios/tests/t_controls.m).
#import <Foundation/Foundation.h>
#include "keymap.h"

enum { DM_PAD_INPUTS = 16 };   // the physical inputs, in the order of the game buttons they play by default (so the default table is i -> i)
extern NSString *const dm_pad_input_ids[DM_PAD_INPUTS];   // the stored values: "east", "south", ..., "ddown" ("none": not used)
NSArray<NSDictionary *> *dm_control_map_sections(void);   // "map_pad" (Controller buttons) and "map_keys" (Keyboard keys), listed only where a page names them
// The physical input (index into dm_pad_input_ids, -1: not used) that plays each game button; get returns a row's value (nil, or a value that is not an input: the default)
void dm_pad_map_load(int8_t src[DM_KEYMAP_BUTTONS], NSString *(^get)(NSString *key));
uint64_t dm_pad_map_apply(const int8_t src[DM_KEYMAP_BUTTONS], uint32_t pressed);   // the game buttons for the physical inputs held (bit i: dm_pad_input_ids[i])
