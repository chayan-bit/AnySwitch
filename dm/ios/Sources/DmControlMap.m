// Which input plays which game button (DmControlMap.h)
#import "DmControlMap.h"

NSString *const dm_pad_input_ids[DM_PAD_INPUTS] = {@"east", @"south", @"north", @"west", @"lstick", @"rstick", @"lshoulder", @"rshoulder", @"ltrigger", @"rtrigger",
                                                   @"menu", @"options", @"dleft", @"dup", @"dright", @"ddown"};
// By position and shape, never by a maker's letters: a controller's own A may sit at the bottom
static NSString *const k_pad_labels[DM_PAD_INPUTS] = {@"Right face button", @"Bottom face button", @"Top face button", @"Left face button", @"Left stick press", @"Right stick press",
    @"Left shoulder", @"Right shoulder", @"Left trigger", @"Right trigger", @"Menu button", @"Options button", @"D-pad left", @"D-pad up", @"D-pad right", @"D-pad down"};

static NSString *pad_key(int row) { return [NSString stringWithFormat:@"DM_MAP_PAD_%s", dm_keymap_row[row]]; }

NSArray<NSDictionary *> *dm_control_map_sections(void) {
    NSMutableArray *padOpts = [NSMutableArray array], *keyOpts = [NSMutableArray arrayWithObject:@{@"value": @"0", @"label": @"Not used"}];
    for (int i = 0; i < DM_PAD_INPUTS; i++) [padOpts addObject:@{@"value": dm_pad_input_ids[i], @"label": k_pad_labels[i]}];
    [padOpts addObject:@{@"value": @"none", @"label": @"Not used"}];
    for (int i = 0; i < dm_keymap_key_count(); i++) { int u = dm_keymap_key_at(i); [keyOpts addObject:@{@"value": @(u).stringValue, @"label": @(dm_keymap_key_name(u))}]; }
    NSMutableArray *pad = [NSMutableArray array], *keys = [NSMutableArray array];
    for (int r = 0; r < DM_KEYMAP_ROWS; r++) {
        NSString *label = @(dm_keymap_row_label[r]);
        if (r < DM_KEYMAP_BUTTONS) [pad addObject:@{@"key": pad_key(r), @"label": label, @"type": @"choice", @"default": dm_pad_input_ids[r], @"options": padOpts,
                                                    @"detail": @"The controller input that plays this in games."}];
        [keys addObject:@{@"key": [NSString stringWithFormat:@"DM_MAP_KEY_%s", dm_keymap_row[r]], @"label": label, @"type": @"choice", @"default": @(dm_keymap_default[r]).stringValue, @"options": keyOpts,
                          @"detail": @"The key that plays this in games."}];
    }
    return @[@{@"id": @"map_pad", @"title": @"Controller buttons", @"icon": @"gamecontroller.fill", @"listed": @NO, @"settings": pad},
             @{@"id": @"map_keys", @"title": @"Keyboard keys", @"icon": @"keyboard", @"listed": @NO, @"settings": keys}];
}

void dm_pad_map_load(int8_t src[DM_KEYMAP_BUTTONS], NSString *(^get)(NSString *key)) {
    for (int r = 0; r < DM_KEYMAP_BUTTONS; r++) {
        NSString *v = get(pad_key(r)); src[r] = (int8_t)r;
        if ([v isEqualToString:@"none"]) { src[r] = -1; continue; }
        for (int i = 0; i < DM_PAD_INPUTS; i++) if ([v isEqualToString:dm_pad_input_ids[i]]) src[r] = (int8_t)i;
    }
}

uint64_t dm_pad_map_apply(const int8_t src[DM_KEYMAP_BUTTONS], uint32_t pressed) {
    uint64_t m = 0;
    for (int b = 0; b < DM_KEYMAP_BUTTONS; b++) if (src[b] >= 0 && pressed >> src[b] & 1) m |= 1ull << b;
    return m;
}
