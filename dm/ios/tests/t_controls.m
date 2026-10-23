// DmControlMap.m: the controller map's defaults are the positional map read_pad always had, a remap and "Not used" round-trip through a settings store, and the registry rows match keymap.h
#import <Foundation/Foundation.h>
#import "DmControlMap.h"
#import "DmSettings.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) { @autoreleasepool {
    int8_t src[DM_KEYMAP_BUTTONS];
    dm_pad_map_load(src, ^NSString *(NSString *k) { (void)k; return nil; });
    BOOL identity = YES; for (int b = 0; b < DM_KEYMAP_BUTTONS; b++) if (src[b] != b) identity = NO;
    CHECK(identity, "defaults: each game button from the input in its own position");
    // read_pad's old fixed map, by position: right face A, bottom B, top X, left Y, shoulders L R, triggers ZL ZR, menu +, options −, stick presses, the D-pad
    NSArray *old = @[@"east", @"south", @"north", @"west", @"lstick", @"rstick", @"lshoulder", @"rshoulder", @"ltrigger", @"rtrigger", @"menu", @"options", @"dleft", @"dup", @"dright", @"ddown"];
    for (int b = 0; b < DM_KEYMAP_BUTTONS; b++) CHECK([dm_pad_input_ids[src[b]] isEqual:old[(NSUInteger)b]], "row %s plays from %s", dm_keymap_row[b], [old[(NSUInteger)b] UTF8String]);
    CHECK(dm_pad_map_apply(src, 1u << 1) == 1ull << 1 && dm_pad_map_apply(src, 1u << 0 | 1u << 15) == (1ull << 0 | 1ull << 15), "default: bottom face plays B; right face and D-pad down");

    // a store with the built-in registry: swap A and B, B's old input not used, then restore
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    DmSettings *st = [[DmSettings alloc] initWithSections:[DmSettings builtinSections] storePath:path env:^NSString *(NSString *k) { return env[k]; }
                                                   setEnv:^(NSString *k, NSString *v) { if (v) env[k] = v; else [env removeObjectForKey:k]; } plist:^id(NSString *k) { (void)k; return nil; }];
    CHECK([st setValue:@"south" forKey:@"DM_MAP_PAD_A"] && [st setValue:@"none" forKey:@"DM_MAP_PAD_B"] && ![st setValue:@"thumb" forKey:@"DM_MAP_PAD_X"], "remap taken, an unknown input refused");
    NSString *(^get)(NSString *) = ^NSString *(NSString *k) { return [st valueForKey:k]; };
    dm_pad_map_load(src, get);
    CHECK(src[0] == 1 && src[1] == -1 && src[2] == 2, "A from the bottom face, B not used, X unchanged: %d %d %d", src[0], src[1], src[2]);
    CHECK(dm_pad_map_apply(src, 1u << 1) == 1ull << 0 && dm_pad_map_apply(src, 1u << 0) == 0, "bottom face now plays A; the right face plays nothing");
    DmSettings *again = [[DmSettings alloc] initWithSections:[DmSettings builtinSections] storePath:path env:^NSString *(NSString *k) { (void)k; return nil; } setEnv:^(NSString *k, NSString *v) { (void)k; (void)v; } plist:^id(NSString *k) { (void)k; return nil; }];
    CHECK([[again valueForKey:@"DM_MAP_PAD_A"] isEqual:@"south"] && [[again valueForKey:@"DM_MAP_PAD_B"] isEqual:@"none"], "the map survives a new store over the same file");
    [st resetSection:[[st.sections filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"ident == 'map_pad'"]] firstObject]];
    dm_pad_map_load(src, get);
    CHECK(src[0] == 0 && src[1] == 1, "Restore defaults: positional again");

    // keyboard rows: one per keymap row, its default the keymap's, every offered key and Not used as options, a value exported as the usage number
    DmSection *keys = [[st.sections filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"ident == 'map_keys'"]] firstObject];
    DmSection *pad = [[st.sections filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"ident == 'map_pad'"]] firstObject];
    CHECK(keys.settings.count == DM_KEYMAP_ROWS && pad.settings.count == DM_KEYMAP_BUTTONS && !keys.listed && !pad.listed, "24 key rows, 16 controller rows, neither listed among the categories");
    for (int r = 0; r < DM_KEYMAP_ROWS; r++) {
        DmSetting *s = keys.settings[(NSUInteger)r];
        CHECK([s.def isEqual:@(dm_keymap_default[r]).stringValue] && s.options.count == (NSUInteger)dm_keymap_key_count() + 1, "%s: default %d, every key", s.key.UTF8String, dm_keymap_default[r]);
    }
    CHECK([st setValue:@"44" forKey:@"DM_MAP_KEY_A"] && [env[@"DM_MAP_KEY_A"] isEqual:@"44"] && [[keys.settings[0] displayValue:@"44"] isEqual:@"Space"], "Space for A: exported as 44, shown as Space");
    CHECK(![st setValue:@"41" forKey:@"DM_MAP_KEY_A"], "Escape is not offered");
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    printf("t_controls: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
