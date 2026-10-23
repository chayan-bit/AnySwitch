// HearthImport on the Mac: a scratch pack archived as push_pack.py does (pack_manifest.py write, then aa archive) goes from Documents/Import into the library;
// a copy still in progress waits; a missing or changed file, a stale contract and an unsafe archive are refused with a note; an interrupted import starts again;
// a second import replaces the installed game and leaves its save alone; the game running in this process is not replaced under it.
// Run: make -C dm/ios/tests run (argv: a folder with a valid game.json, and its title id)
#import "HearthImport.h"
#include "dm_abi.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
void dm_host_preload_start(int argc, char **argv) { (void)argc; (void)argv; }   // boot.m's dm_boot_game hook; never reached here

static NSString *g_t, *g_prof, *g_id, *g_tool;   // g_tool: pack_manifest.py
static int sh(NSString *cmd) { return system([NSString stringWithFormat:@"( %@ ) > /dev/null 2>&1", cmd].UTF8String); }
// A bootable scratch pack for this Mac (code/macos.dylib with the code stamp the pack check reads), its inventory written; change runs before the archive is made
static NSString *pack(NSString *tag, NSString *change) {
    NSString *r = [g_t stringByAppendingFormat:@"/src-%@", tag];
    NSString *cmd = [NSString stringWithFormat:@"mkdir -p '%@/profile' '%@/code' '%@/msl/macos/b-1' && cp '%@/game.json' '%@/profile/' && printf store > '%@/romfs.dmstore' && printf lib > '%@/msl/macos/b-1/a.metallib' && "
        "printf '.section __DATA,__dminfo\\n.globl _dm_code_info\\n_dm_code_info:\\n.asciz \"code_abi %d\\\\ntitle %@\\\\nmodule main 00\\\\n\"\\n' > '%@/info-%@.S' && "
        "xcrun clang -dynamiclib -arch arm64 -o '%@/code/macos.dylib' '%@/info-%@.S' && python3 -I '%@' write '%@' --title %@",
        r, r, r, g_prof, r, r, r, DM_CODE_ABI, g_id, g_t, tag, r, g_t, tag, g_tool, r, g_id];
    CHECK(sh(cmd) == 0, "scratch pack %s", tag.UTF8String);
    if (change) CHECK(sh([NSString stringWithFormat:@"cd '%@' && %@", r, change]) == 0, "change %s", change.UTF8String);
    return r;
}
// The archive and its ready note in Documents/Import, as push_pack.py leaves them; bytes: the note's archive size (another value = a copy in progress)
static void inbox(HearthImport *imp, NSString *src, NSString *name, long long bytes) {
    NSString *aar = [imp.inbox stringByAppendingFormat:@"/%@.aar", name];
    [NSFileManager.defaultManager createDirectoryAtPath:imp.inbox withIntermediateDirectories:YES attributes:nil error:nil];
    CHECK(sh([NSString stringWithFormat:@"aa archive -d '%@' -o '%@' -exclude-field uid,gid,flg,btm,ctm", src, aar]) == 0, "archive %s", name.UTF8String);
    long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:aar error:nil][NSFileSize] longLongValue];
    NSDictionary *note = @{@"title_id": g_id, @"archive": aar.lastPathComponent, @"archive_bytes": @(bytes ? bytes : size), @"files": @4, @"bytes": @100000};
    [[NSJSONSerialization dataWithJSONObject:note options:0 error:nil] writeToFile:[imp.inbox stringByAppendingFormat:@"/%@.ready", name] atomically:YES];
}
static NSString *note(HearthImport *imp, NSString *name) { return [NSString stringWithContentsOfFile:[imp.inbox stringByAppendingFormat:@"/%@.hearth-error.txt", name] encoding:NSUTF8StringEncoding error:nil]; }
static BOOL exists(NSString *p) { return [NSFileManager.defaultManager fileExistsAtPath:p]; }

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) { fprintf(stderr, "usage: t_import <folder with game.json> <title id>\n"); return 2; }
    g_prof = @(argv[1]); g_id = @(argv[2]);
    g_tool = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"../../tools/pack_manifest.py"].stringByStandardizingPath;   // run from dm/ios/tests
    g_t = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_import.%d", getpid()]];
    HearthLibrary *lib = [[HearthLibrary alloc] initWithHome:[g_t stringByAppendingPathComponent:@"home"] bundle:[g_t stringByAppendingPathComponent:@"Hearth.app"]];
    HearthImport *imp = [[HearthImport alloc] initWithLibrary:lib];
    NSString *dest = [lib.supportDir stringByAppendingFormat:@"/Games/%@", g_id];

    // 1. a copy in progress (the archive is shorter than the note says) waits, without a note
    inbox(imp, pack(@"good", nil), @"a", 1 << 30);
    CHECK(imp.ready.count == 0 && [imp importAll] == 0 && !note(imp, @"a") && exists([imp.inbox stringByAppendingPathComponent:@"a.aar"]), "incomplete copy waits");

    // 2. an interrupted earlier run left a half-made folder: the import starts again and succeeds; the game appears and is kept out of the backup
    inbox(imp, [g_t stringByAppendingPathComponent:@"src-good"], @"a", 0);
    sh([NSString stringWithFormat:@"mkdir -p '%@/a.import/code' && printf junk > '%@/a.import/code/junk'", imp.inbox, imp.inbox]);
    CHECK([imp.ready isEqual:@[@"a"]], "ready: %s", imp.ready.description.UTF8String);
    CHECK([imp importAll] == 1, "imported (%s)", note(imp, @"a").UTF8String);
    CHECK(exists([dest stringByAppendingPathComponent:@"romfs.dmstore"]) && !exists([dest stringByAppendingPathComponent:@"code/junk"]), "the game's files, not the interrupted run's");
    CHECK(!exists([imp.inbox stringByAppendingPathComponent:@"a.aar"]) && !exists([imp.inbox stringByAppendingPathComponent:@"a.ready"]) && !exists([imp.inbox stringByAppendingPathComponent:@"a.import"]), "the Inbox is empty again");
    NSNumber *ex = nil; [[NSURL fileURLWithPath:dest] getResourceValue:&ex forKey:NSURLIsExcludedFromBackupKey error:nil];
    CHECK(ex.boolValue, "kept out of the device backup");
    HearthGame *g = [lib gameWithId:g_id];
    CHECK(g && g.reason == 0, "the library opens it (%d %s)", g.reason, g.why.UTF8String);

    // 3. refused, each with a note beside the ready file, the archive dropped and the installed game untouched
    NSString *save = [[lib saveDirFor:g] stringByAppendingPathComponent:@"main"];
    [NSFileManager.defaultManager createDirectoryAtPath:save.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"progress" writeToFile:save atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSArray *bad = @[@[@"missing", @"rm msl/macos/b-1/a.metallib", @"missing: msl/macos/b-1/a.metallib"],
                     @[@"digest", @"printf STORE > romfs.dmstore", @"changed: romfs.dmstore"],
                     @[@"extra", @"printf x > extra.bin", @"not in the manifest: extra.bin"],
                     @[@"stale", [NSString stringWithFormat:@"sed -i '' 's/\"code\": %d/\"code\": %d/' manifest.json", DM_CODE_ABI, DM_CODE_ABI + 1], @"code"],
                     @[@"link", @"ln -s /tmp msl/out", @"cannot be extracted safely: msl/out"]];
    for (NSArray *b in bad) {
        inbox(imp, pack(b[0], b[1]), b[0], 0);
        NSString *why = [imp importName:b[0]];
        CHECK(why && [why containsString:b[2]] && [note(imp, b[0]) isEqual:why], "%s refused: %s", [b[0] UTF8String], why.UTF8String);
        CHECK(!exists([imp.inbox stringByAppendingFormat:@"/%@.aar", b[0]]) && !exists([imp.inbox stringByAppendingFormat:@"/%@.import", b[0]]), "%s: archive and folder gone", [b[0] UTF8String]);
        CHECK(![imp.ready containsObject:b[0]], "%s is not offered again", [b[0] UTF8String]);
    }
    CHECK(exists([dest stringByAppendingPathComponent:@"romfs.dmstore"]) && !exists([dest stringByAppendingPathComponent:@"extra.bin"]), "the installed game is untouched");

    // 4. the running game is not replaced under it; once it is closed, a new import replaces it and the save stays
    inbox(imp, pack(@"new", [NSString stringWithFormat:@"printf store2 > romfs.dmstore && python3 -I '%@' write . --title %@", g_tool, g_id]), @"b", 0);
    imp.runningId = g_id;
    CHECK([[imp importName:@"b"] containsString:@"waits"] && !note(imp, @"b") && [imp.ready isEqual:@[@"b"]], "waits for the running game");
    imp.runningId = nil;
    CHECK([imp importName:@"b"] == nil, "replaced (%s)", note(imp, @"b").UTF8String);
    CHECK([[NSString stringWithContentsOfFile:[dest stringByAppendingPathComponent:@"romfs.dmstore"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"store2"], "the new files");
    CHECK([[NSString stringWithContentsOfFile:save encoding:NSUTF8StringEncoding error:nil] isEqual:@"progress"], "the save is untouched");
    NSArray *left = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:[lib.supportDir stringByAppendingPathComponent:@"Games"] error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.replaced'"]];
    CHECK(left.count == 0, "no replaced copy left");

    [NSFileManager.defaultManager removeItemAtPath:g_t error:nil];
    printf("t_import: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
