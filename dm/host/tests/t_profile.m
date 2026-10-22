// Schema test of every game profile: game.py json writes each profile's game.json, and profile.m (what the host runs at boot) must accept it, with the profile's own id and
// the chain version its dmsh_chain.h names; then each kind of bad game.json must be refused with a reason naming the key.
// Run: make -C dm/host/tests profile-schema (every profile in dm/games)
#import <Foundation/Foundation.h>
#include "dm.h"

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
    if (argc != 4) { fprintf(stderr, "usage: t_profile <folder with game.json> <profile id> <chain version>\n"); return 2; }
    struct dm_profile p = {0}; char why[512] = "";
    if (dm_profile_parse(argv[1], &p, why, sizeof why)) { printf("%s: refused: %s\n", argv[2], why); return 1; }
    int bad = 0;
    if (strcmp(p.id, argv[2])) { bad++; printf("  id %s, profile folder %s\n", p.id, argv[2]); }
    if (strcmp(p.chain, argv[3])) { bad++; printf("  chain %s, dmsh_chain.h %s\n", p.chain, argv[3]); }
    if (!p.program_id || !p.nmod || !p.mem_reserve || !p.app_pool) { bad++; printf("  program_id, modules, mem_reserve and app_pool must be set\n"); }
    printf("%s: %s, %d modules, %d display versions, %s\n", p.id, p.name, p.nmod, p.nversions, bad ? "BAD" : "ok");
    return bad != 0 || refusals(argv[1]);
}
