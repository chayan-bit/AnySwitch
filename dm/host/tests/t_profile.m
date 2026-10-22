// Parity of the run-time game profile with the compile-time header it replaces: built once per profile against that profile's game_profile.h (dm/games/game.py header, -include),
// it loads the same profile's game.json (game.py json) through profile.m and compares every field with its macro, the two optional keys' presence included.
// Run: make -C dm/host/tests profile-parity (every profile in dm/games)
#import <Foundation/Foundation.h>
#include "dm.h"

static int n, bad;
#define I(macro, field) do { n++; if ((long long)(macro) != (long long)(field)) { bad++; printf("  %s: header %lld, game.json %lld\n", #field, (long long)(macro), (long long)(field)); } } while (0)
#define S(macro, field) do { n++; if (strcmp((macro), (field))) { bad++; printf("  %s: header \"%s\", game.json \"%s\"\n", #field, (macro), (field)); } } while (0)

// Fail-fast checks: each change to the valid game.json must be refused with a reason naming the key, and must leave the output untouched
static int refusals(const char *dir) {
    NSMutableDictionary *ok = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[@(dir) stringByAppendingPathComponent:@"game.json"]] options:NSJSONReadingMutableContainers error:nil];
    NSDictionary *cases = @{@"schema": @{@"schema": @999}, @"missing key mem_alias": @{@"mem_alias": NSNull.null}, @"mem_used": @{@"mem_used": @"0x10"},
                            @"fps_hold": @{@"fps_hold": @1}, @"fps_target": @{@"fps_target": @45}, @"render_cond": @{@"render_cond": @3}, @"unknown key": @{@"typo_key": @1},
                            @"modules": @{@"modules": @[]}, @"program_id": @{@"program_id": @"12"}, @"feedback_snap": @{@"feedback_snap": @"XYZ"}, @"nvn_api": @{@"nvn_api": @[@55]}};
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_profile.%d", getpid()]];
    [NSFileManager.defaultManager createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    int fails = 0;
    for (NSString *want in cases) {
        NSMutableDictionary *j = [ok mutableCopy];
        [cases[want] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { if (v == NSNull.null) [j removeObjectForKey:k]; else j[k] = v; }];
        [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:[tmp stringByAppendingPathComponent:@"game.json"] atomically:YES];
        struct dm_profile q = {.id = "untouched"}; char why[512] = "";
        int rc = dm_profile_parse(tmp.fileSystemRepresentation, &q, why, sizeof why);
        if (!rc || !strstr(why, want.UTF8String) || strcmp(q.id, "untouched")) { fails++; printf("  refusal %s: rc %d, reason \"%s\"\n", want.UTF8String, rc, why); }
    }
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    if (fails) printf("%d of %lu bad profiles not refused as expected\n", fails, (unsigned long)cases.count);
    return fails;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: t_profile <folder with game.json>\n"); return 2; }
    dm_profile_load(argv[1]);
    const struct dm_profile *p = &g_profile;
    S(DM_GAME_ID, p->id); S(DM_GAME_NAME, p->name); I(DM_GAME_PROGRAM_ID, p->program_id); S(DM_GAME_ROMFS_MARKER, p->romfs_marker);
    static const char *mods[] = DM_GAME_MODULES;
    I(DM_GAME_NMOD, p->nmod);
    for (int i = 0; i < DM_GAME_NMOD && i < p->nmod; i++) S(mods[i], p->modules[i]);
    I(DM_GAME_MEM_RESERVE, p->mem_reserve); I(DM_GAME_MEM_ALIAS, p->mem_alias); I(DM_GAME_MEM_STACK, p->mem_stack); I(DM_GAME_APP_POOL, p->app_pool); I(DM_GAME_MEM_USED, p->mem_used);
    S(DM_GAME_ARGS, p->game_args); S(DM_GAME_ENV, p->game_env); I(DM_GAME_MEM_MAP_LIMIT, p->mem_map_limit);
    static const struct { const char *build, *ver; } vers[] = {DM_GAME_DISPLAY_VERSIONS};
    I(sizeof vers / sizeof *vers, p->nversions);
    for (int i = 0; i < (int)(sizeof vers / sizeof *vers) && i < p->nversions; i++) { S(vers[i].build, p->versions[i].build); S(vers[i].ver, p->versions[i].ver); }
    I(DM_GAME_PRESENT_DISPLAY, p->present_display); I(DM_GAME_CORE_PREEMPT, p->core_preempt); I(DM_GAME_ALLOC_BIG_ALIGN, p->alloc_big_align);
    I(DM_GAME_FPS_TARGET, p->fps_target); I(DM_GAME_FPS_HOLD, p->fps_hold); I(DM_GAME_PAD_FULL, p->pad_full); I(DM_GAME_OPMODE, p->opmode_console); I(DM_GAME_PERF_BOOST, p->perf_boost);
    S(DM_GAME_FEEDBACK_SNAP, p->feedback_snap); S(DM_GAME_ALPHA_FROM_RED, p->alpha_from_red);
    I(DM_GAME_TEX_FLUSH_UPLOAD, p->tex_flush_upload); I(DM_GAME_RENDER_COND, p->render_cond); I(DM_GAME_TEX_DIRTY_UPLOAD, p->tex_dirty_upload);
    I(DM_GAME_TEX_DYN_SLOTS, p->tex_dyn_slots); I(DM_GAME_GPU_TS_SEGMENT, p->gpu_ts_segment); I(DM_GAME_VCONV_RANGE, p->vconv_range);
#ifdef DM_GAME_SHARED_FONT_TTF
    I(DM_GAME_SHARED_FONT_TTF, p->shared_font_ttf);
#else
    I(-1, p->shared_font_ttf);   // no key: the host decides by the SDK version
#endif
#ifdef DM_GAME_NVN_API_MAJOR
    I(DM_GAME_NVN_API_MAJOR, p->nvn_api_major); I(DM_GAME_NVN_API_MINOR, p->nvn_api_minor);
#else
    I(0, p->nvn_api_major); I(0, p->nvn_api_minor);
#endif
    S(DMSH_CHAIN, p->chain);
    printf("%s: %d fields, %d differ\n", p->id, n, bad);
    return bad != 0 || refusals(argv[1]);
}
