// Hearth's library (dm/ios/Hearth/HearthLibrary.m) on a scratch home: scan order, names from the NACP, reason codes of broken packs, the check cache, next.json, the one-time save copy.
// Foundation only, runs on the Mac: make -C dm/ios/tests run
#import <Foundation/Foundation.h>
#import "HearthLibrary.h"
#include "boot.h"
#include "dm_abi.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
void dm_host_preload_start(int argc, char **argv) { (void)argc; (void)argv; }   // boot.m's dm_boot_game hook; never reached here

static void put(NSString *path, NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void manifest(NSString *root, NSString *title, int format) {
    put([root stringByAppendingPathComponent:@"manifest.json"], [NSString stringWithFormat:@"{\"title_id\": \"%@\", \"format\": %d, \"abi\": {\"profile_schema\": %d, \"code\": %d, \"shader\": %d}}",
        title, format, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI]);
}
static void nacp(NSString *root, int lang, NSString *name, NSString *pub) {
    NSMutableData *d = [NSMutableData dataWithLength:0x4000];
    memcpy((char *)d.mutableBytes + lang * 0x300, name.UTF8String, strlen(name.UTF8String));
    memcpy((char *)d.mutableBytes + lang * 0x300 + 0x200, pub.UTF8String, strlen(pub.UTF8String));
    [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"meta"] withIntermediateDirectories:YES attributes:nil error:nil];
    [d writeToFile:[root stringByAppendingPathComponent:@"meta/control.nacp"] atomically:YES];
}

int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *t = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_library.%d", getpid()]];
    NSString *home = [t stringByAppendingPathComponent:@"home"], *bundle = [t stringByAppendingPathComponent:@"Hearth.app"];
    HearthLibrary *lib = [[HearthLibrary alloc] initWithHome:home bundle:bundle];
    NSString *games = [lib.supportDir stringByAppendingPathComponent:@"Games"];

    // 1. empty library; next.json defaults to Home and is consumed
    CHECK([lib scan].count == 0, "empty");
    CHECK([[lib takeNext][@"action"] isEqual:@"home"], "no next.json means home");
    [lib writeNext:@{@"action": @"launch", @"id": @"0100000000010000"}];
    NSDictionary *nx = [lib takeNext];
    CHECK([nx[@"action"] isEqual:@"launch"] && [nx[@"id"] isEqual:@"0100000000010000"], "round trip %s", nx.description.UTF8String);
    CHECK([[lib takeNext][@"action"] isEqual:@"home"], "taken once: a crash in the launched game does not loop");

    // 2. scan: bundled pack first, then Games/ sorted; folders without a manifest are not games
    manifest([bundle stringByAppendingPathComponent:@"pack"], @"0100000000030000", DM_PACK_FORMAT);
    manifest([games stringByAppendingPathComponent:@"0100000000020000"], @"0100000000020000", DM_PACK_FORMAT + 1);
    manifest([games stringByAppendingPathComponent:@"0100000000010000"], @"0100000000010000", DM_PACK_FORMAT);
    put([games stringByAppendingPathComponent:@"junk/readme.txt"], @"not a pack");
    nacp([games stringByAppendingPathComponent:@"0100000000010000"], 1, @"Second Language Name", @"Pub");
    nacp([bundle stringByAppendingPathComponent:@"pack"], 0, @"Bundled Game", @"Maker");
    NSArray<HearthGame *> *all = [lib scan];
    CHECK(all.count == 3, "count %lu", (unsigned long)all.count);
    CHECK(all[0].bundled && [all[0].titleId isEqual:@"0100000000030000"] && [all[1].titleId isEqual:@"0100000000010000"] && [all[2].titleId isEqual:@"0100000000020000"], "order");
    CHECK([all[0].name isEqual:@"Bundled Game"] && [all[0].publisher isEqual:@"Maker"], "NACP American English: %s", all[0].name.UTF8String);
    CHECK([all[1].name isEqual:@"Second Language Name"], "NACP first set language: %s", all[1].name.UTF8String);
    CHECK([all[2].name isEqual:@"0100000000020000"], "no NACP: the title id");

    // 3. reason codes: a newer pack format is a rebuild; a pack missing its profile and code is a missing part or a rebuild, never bootable
    CHECK(all[2].reason == DM_PACK_REBUILD && [all[2].why containsString:@"pack format"], "stale: %d %s", all[2].reason, all[2].why.UTF8String);
    CHECK(all[1].reason != 0 && all[1].why.length, "incomplete pack refused: %d", all[1].reason);
    CHECK([lib gameWithId:@"0100000000020000"].reason == DM_PACK_REBUILD, "gameWithId");
    CHECK([lib gameWithId:@"01000000000F0000"] == nil, "unknown id");

    // 4. the cache follows the files: a fixed manifest is checked again
    manifest([games stringByAppendingPathComponent:@"0100000000020000"], @"0100000000020000", DM_PACK_FORMAT);
    HearthGame *g2 = [lib gameWithId:@"0100000000020000"];
    CHECK(g2.reason != DM_PACK_REBUILD || ![g2.why containsString:@"pack format"], "re-checked after the manifest changed: %s", g2.why.UTF8String);

    // 5. code in the bundle: Frameworks/<id>.dylib is the game's code when present
    put([bundle stringByAppendingPathComponent:@"Frameworks/0100000000010000.dylib"], @"x");
    CHECK([[lib gameWithId:@"0100000000010000"].codePath hasSuffix:@"Frameworks/0100000000010000.dylib"], "bundle code path");
    CHECK([lib gameWithId:@"0100000000020000"].codePath == nil, "no bundle code: nil");
    CHECK(getenv("DM_CODE") == NULL && getenv("DM_ROMFS") == NULL, "the check leaves the environment as it found it");
    setenv("DM_CODE", "/running/game.dylib", 1); [lib scan];
    CHECK(!strcmp(getenv("DM_CODE"), "/running/game.dylib"), "a running game's DM_CODE survives a scan"); unsetenv("DM_CODE");

    // 6. saves: the bundled game's legacy Documents/save is copied once (the original kept); other games start empty; logs per game
    put([lib.documentsDir stringByAppendingPathComponent:@"save/main"], @"legacy-save");
    put([lib.documentsDir stringByAppendingPathComponent:@"romfs.dmstore"], @"store");
    HearthGame *b = [lib scan][0];
    CHECK([b.romfsPath hasSuffix:@"Documents/romfs.dmstore"], "bundled game files in Documents");
    NSString *sd = [lib saveDirFor:b];
    CHECK(([sd hasSuffix:[NSString stringWithFormat:@"Documents/Users/%@/saves/0100000000030000/save", HEARTH_UID]]), "save path %s", sd.UTF8String);
    CHECK([[NSString stringWithContentsOfFile:[sd stringByAppendingPathComponent:@"main"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"legacy-save"], "copied");
    CHECK([fm fileExistsAtPath:[lib.documentsDir stringByAppendingPathComponent:@"save/main"]], "original kept");
    put([sd stringByAppendingPathComponent:@"main"], @"newer");
    [lib saveDirFor:b];
    CHECK([[NSString stringWithContentsOfFile:[sd stringByAppendingPathComponent:@"main"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"newer"], "never copied over again");
    NSString *s1 = [lib saveDirFor:[lib gameWithId:@"0100000000010000"]];
    CHECK(![fm fileExistsAtPath:s1], "an imported game does not get the legacy save");
    CHECK([[lib logDirFor:b] hasSuffix:@"Documents/Logs/0100000000030000"] && [fm fileExistsAtPath:[lib logDirFor:b]], "log dir");

    [fm removeItemAtPath:t error:nil];
    printf("t_library: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
