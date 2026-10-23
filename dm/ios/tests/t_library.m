// Hearth's library (dm/ios/Hearth/HearthLibrary.m) on a scratch home: scan order, names from the NACP, reason codes of broken packs, the check cache, next.json, the one-time save copy.
// Foundation only, runs on the Mac: make -C dm/ios/tests run
#import <Foundation/Foundation.h>
#import "HearthLibrary.h"
#import "HearthErrors.h"
#import "HearthSound.h"
#import "HearthSaves.h"
#include "boot.h"
#include "dm_abi.h"
#include <sys/stat.h>

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
    if (lang == 0) memcpy((char *)d.mutableBytes + 0x3060, "1.3.2", 5);   // the display version (the pack with the American English entry has one)
    if (lang == 0) ((char *)d.mutableBytes)[0x3025] = 1;   // StartupUserAccount: required (the pack with the American English entry)
    if (lang == 1) ((char *)d.mutableBytes)[0x3034] = 1;   // Screenshot: Deny (the pack with the second language entry)
    memcpy((char *)d.mutableBytes + lang * 0x300, name.UTF8String, strlen(name.UTF8String));
    memcpy((char *)d.mutableBytes + lang * 0x300 + 0x200, pub.UTF8String, strlen(pub.UTF8String));
    [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"meta"] withIntermediateDirectories:YES attributes:nil error:nil];
    [d writeToFile:[root stringByAppendingPathComponent:@"meta/control.nacp"] atomically:YES];
}

int main(int argc, char **argv) { @autoreleasepool {   // argv: a folder with a valid game.json and its title id (section 9)
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
    CHECK([all[0].version isEqual:@"1.3.2"] && all[1].version == nil, "NACP display version: %s / %s", all[0].version.UTF8String, all[1].version.UTF8String);
    CHECK([all[1].name isEqual:@"Second Language Name"], "NACP first set language: %s", all[1].name.UTF8String);
    CHECK(all[0].startupUser == 1 && all[1].startupUser == 0 && all[2].startupUser == 0, "NACP StartupUserAccount: %d %d %d", all[0].startupUser, all[1].startupUser, all[2].startupUser);
    CHECK(!all[0].screenshotDenied && all[1].screenshotDenied && !all[2].screenshotDenied, "NACP Screenshot: %d %d %d", all[0].screenshotDenied, all[1].screenshotDenied, all[2].screenshotDenied);
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

    // 7. last played first: markPlayed writes State/<id>.json; the never played keep the scan order
    [lib markPlayed:[lib gameWithId:@"0100000000020000"]];
    NSArray<HearthGame *> *lp = [lib scan];
    CHECK([lp[0].titleId isEqual:@"0100000000020000"] && lp[0].lastPlayed > 0 && [lp[1].titleId isEqual:@"0100000000030000"], "last played first: %s %s", lp[0].titleId.UTF8String, lp[1].titleId.UTF8String);
    CHECK([fm fileExistsAtPath:[lib.supportDir stringByAppendingPathComponent:@"State/0100000000020000.json"]], "state file");

    // 8. code signatures (HearthSign.m): Apple's own tools carry an identifier and a certificate set, the same set for both; the comparison rules
    { HearthSigner *ls = [HearthSigner signerOf:@"/bin/ls"], *cat = [HearthSigner signerOf:@"/bin/cat"];
      CHECK([ls.identifier isEqual:@"com.apple.ls"] && ls.team == nil && ls.certs.length == 64, "ls: %s %s %s", ls.identifier.UTF8String, ls.team.UTF8String, ls.certs.UTF8String);
      CHECK([cat.certs isEqual:ls.certs] && ![cat.identifier isEqual:ls.identifier], "same signer, other identifier");
      CHECK([HearthSigner signerOf:@"/etc/hosts"] == nil && [HearthSigner signerOf:@"/no/such/file"] == nil, "not Mach-O: nil");
      HearthSigner *app = [HearthSigner new]; app.identifier = @"org.example.hearth"; app.team = @"TEAM1"; app.certs = @"c1";
      HearthSigner *ok = [HearthSigner new]; ok.identifier = @"org.example.hearth"; ok.team = @"TEAM1"; ok.certs = @"c1";
      CHECK(hearth_code_mismatch(app, @"org.example.hearth", ok) == nil, "identifier, team and certificates match: loads");
      ok.identifier = @"code"; CHECK([hearth_code_mismatch(app, @"org.example.hearth", ok) containsString:@"signed as code"], "another identifier (E1's control)");
      ok.identifier = @"org.example.hearth"; ok.team = @"TEAM2"; CHECK([hearth_code_mismatch(app, @"org.example.hearth", ok) containsString:@"team TEAM2"], "another team");
      ok.team = nil; CHECK(hearth_code_mismatch(app, @"org.example.hearth", ok) != nil, "ad hoc code never matches");
      ok.team = @"TEAM1"; ok.certs = @"c2"; CHECK([hearth_code_mismatch(app, @"org.example.hearth", ok) containsString:@"another certificate"], "a renewed certificate: re-import needed");
      CHECK(hearth_code_mismatch(app, @"org.example.hearth", nil) != nil && hearth_code_mismatch(nil, @"org.example.hearth", ok) != nil, "unsigned code, unreadable app: refused"); }

    // 9. an imported game's code (needs a valid profile: make passes one from dm/games): its own when signed for this app, else the in-app copy, else Needs signing
    if (argc == 3) {
        NSString *gid = @(argv[2]), *r = [games stringByAppendingPathComponent:gid], *own = [r stringByAppendingPathComponent:@"code/macos.dylib"];
        [fm removeItemAtPath:[bundle stringByAppendingFormat:@"/Frameworks/%@.dylib", gid] error:nil];   // section 5's stand-in, when the profile has the same id
        NSString *cmd = [NSString stringWithFormat:@"mkdir -p '%@/profile' '%@/code' '%@/msl/macos' && cp '%s/game.json' '%@/profile/' && : > '%@/romfs.dmstore' && "
            "printf '.section __DATA,__dminfo\\n.globl _dm_code_info\\n_dm_code_info:\\n.asciz \"code_abi %d\\\\ntitle %@\\\\nmodule main 00\\\\n\"\\n' > '%@/info.S' && "
            "xcrun clang -dynamiclib -arch arm64 -o '%@' '%@/info.S' && codesign -f -s - -i org.example.other '%@' 2>/dev/null",
            r, r, r, argv[1], r, r, DM_CODE_ABI, gid, t, own, t, own];
        CHECK(system(cmd.UTF8String) == 0, "scratch pack");
        put([r stringByAppendingPathComponent:@"manifest.json"], [NSString stringWithFormat:@"{\"title_id\": \"%@\", \"format\": %d, \"platforms\": [\"macos\"], \"abi\": {\"profile_schema\": %d, \"code\": %d, \"shader\": %d}}",
            gid, DM_PACK_FORMAT, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI]);
        HearthGame *g = [lib gameWithId:gid];
        CHECK(g.reason == 0 && g.codePath == nil, "no signing rule set (the Mac): the pack's own code, bootable (%d %s)", g.reason, g.why.UTF8String);
        lib.bundleId = @"org.example.hearth"; lib.appSigner = [HearthSigner signerOf:own];
        system([NSString stringWithFormat:@"touch '%@'", own].UTF8String);   // the check is cached by file stamps: the rule changed, so touch the code
        g = [lib gameWithId:gid];
        CHECK(g.reason == HEARTH_NEEDS_SIGNING && [g.why containsString:@"signed as org.example.other"] && [g.why containsString:@"import the game again"], "own code signed for another identifier: Needs signing (%d %s)", g.reason, g.why.UTF8String);
        NSString *inApp = [bundle stringByAppendingFormat:@"/Frameworks/%@.dylib", gid];
        [fm copyItemAtPath:own toPath:inApp error:nil];
        g = [lib gameWithId:gid];
        CHECK(g.reason == 0 && [g.codePath isEqual:inApp], "the in-app copy is the fallback (%d %s)", g.reason, g.codePath.UTF8String);
        [fm removeItemAtPath:inApp error:nil];
        lib.bundleId = nil; lib.appSigner = nil;
    } else printf("t_library: section 9 skipped (run through make: it passes a profile)\n");

    // 10. Data Management and Options: sizes by kind, delete game keeps the saves, delete saves sticks (the old single-game save is not copied back), cached capabilities, play time
    { HearthGame *g = [HearthGame new]; g.titleId = @"0100000000050000"; g.root = [games stringByAppendingPathComponent:g.titleId];
      NSDictionary *files = @{@"code/ios.dylib": @1000, @"msl/a/b.metallib": @200, @"msl/c.json": @30, @"pso/ios/x.bin": @400, @"romfs.dmstore": @5000, @"aoc/1/romfs.dmstore": @700,
                              @"profile/game.json": @10, @"meta/icon.jpg": @20, @"manifest.json": @5};
      for (NSString *rel in files) put([g.root stringByAppendingPathComponent:rel], [@"" stringByPaddingToLength:[files[rel] unsignedIntegerValue] withString:@"x" startingAtIndex:0]);
      NSString *save = [lib saveDirFor:g]; put([save stringByAppendingPathComponent:@"main"], [@"" stringByPaddingToLength:64 withString:@"s" startingAtIndex:0]);
      NSDictionary *sz = [lib sizesOf:g];
      CHECK([sz[@"code"] isEqual:@1000] && [sz[@"shaders"] isEqual:@230] && [sz[@"pipelines"] isEqual:@400] && [sz[@"files"] isEqual:@5000] && [sz[@"addons"] isEqual:@700]
            && [sz[@"other"] isEqual:@35] && [sz[@"save"] isEqual:@64], "sizes by kind %s", sz.description.UTF8String);
      CHECK([lib capsOf:g] == nil, "no capabilities before the first start");
      [lib rememberCaps:@{@"fstep": @YES, @"nvn": @NO} of:g]; [lib addPlayTime:90 to:g user:@"0123456789abcdef0123456789abcdef"]; [lib addPlayTime:30.5 to:g user:nil]; [lib markPlayed:g];
      CHECK([[lib capsOf:g][@"fstep"] boolValue] && ![[lib capsOf:g][@"nvn"] boolValue], "capabilities kept %s", [lib capsOf:g].description.UTF8String);
      CHECK([lib playTimeOf:g] == 120.5 && g.lastPlayed > 0, "play time %.1f, and markPlayed keeps it", [lib playTimeOf:g]);
      CHECK([lib playTimeOf:g user:@"0123456789abcdef0123456789abcdef"] == 90 && [lib playTimeOf:g user:HEARTH_UID] == 30.5, "per user: %.1f, and time that is no one's (before users existed) is the first user's", [lib playTimeOf:g user:@"0123456789abcdef0123456789abcdef"]);
      NSString *other = [lib saveDirFor:g user:@"0123456789abcdef0123456789abcdef"];
      CHECK(([other hasSuffix:[NSString stringWithFormat:@"Documents/Users/0123456789abcdef0123456789abcdef/saves/%@/save", g.titleId]] && [fm fileExistsAtPath:other.stringByDeletingLastPathComponent] && ![other isEqual:save]), "another user's save path %s", other.UTF8String);
      CHECK([[lib saveDirFor:g user:HEARTH_UID] isEqual:save], "the first user's is the old path");
      NSString *why = nil;
      HearthGame *b = [HearthGame new]; b.titleId = @"0100000000030000"; b.root = [bundle stringByAppendingPathComponent:@"pack"]; b.bundled = YES;
      CHECK(![lib deleteGame:b error:&why] && why.length && [fm fileExistsAtPath:b.root], "the game built into the app is not deleted (%s)", why.UTF8String);
      CHECK([lib deleteGame:g error:&why] && ![fm fileExistsAtPath:g.root] && [fm fileExistsAtPath:[save stringByAppendingPathComponent:@"main"]], "deleted, its save kept (%s)", why.UTF8String);
      CHECK([lib capsOf:g] == nil && [lib playTimeOf:g] == 0, "its state goes with it");
      put([home stringByAppendingPathComponent:@"Documents/save/main"], @"old single-game save");
      CHECK(![fm fileExistsAtPath:[[lib saveDirFor:b user:@"0123456789abcdef0123456789abcdef"] stringByAppendingPathComponent:@"main"]], "the old single-game save is never copied to another user");
      NSString *bs = [lib saveDirFor:b]; CHECK([fm fileExistsAtPath:[bs stringByAppendingPathComponent:@"main"]], "bundled game: the old save copied once");
      put([bs stringByAppendingString:@".work/main"], @"working copy");
      CHECK([lib deleteSavesOf:b error:&why] && ![fm fileExistsAtPath:[bs stringByAppendingString:@".work"]], "delete saves, the working copy too (%s)", why.UTF8String);
      bs = [lib saveDirFor:b];
      CHECK(![fm fileExistsAtPath:[bs stringByAppendingPathComponent:@"main"]] && [fm fileExistsAtPath:[home stringByAppendingPathComponent:@"Documents/save/main"]],
            "deleted saves stay deleted, and the old single-game save is left alone");
      CHECK([[lib sizesOf:b][@"save"] isEqual:@0], "save size 0 after the delete"); }

    [fm removeItemAtPath:t error:nil];
    // menu sounds: short, within full scale, no click at the start or the end, the open chime rises and the close chime falls
    { double rate = 48000;
      double (^pitch)(const float *, size_t) = ^double(const float *s, size_t n) { size_t z = 0; for (size_t i = 1; i < n; i++) if ((s[i - 1] < 0) != (s[i] < 0)) z++; return z * rate / 2 / n; };   // zero crossings
      for (int k = HearthSoundMove; k <= HearthSoundClose; k++) {
          NSData *d = hearth_sound_samples((HearthSoundKind)k, rate); const float *s = d.bytes; size_t n = d.length / sizeof(float);
          float peak = 0; for (size_t i = 0; i < n; i++) peak = fmaxf(peak, fabsf(s[i]));
          CHECK(n > rate * 0.03 && n < rate * 0.6, "sound %d: %zu frames", k, n);
          CHECK(peak > 0.05 && peak <= 1, "sound %d peak %.2f", k, peak);
          CHECK(fabsf(s[0]) < 0.01 && fabsf(s[n - 1]) < 0.01, "sound %d starts and ends quietly (%.3f, %.3f)", k, s[0], s[n - 1]);
      }
      NSData *o = hearth_sound_samples(HearthSoundOpen, rate), *c = hearth_sound_samples(HearthSoundClose, rate); size_t w = (size_t)(0.06 * rate);
      const float *os = o.bytes, *cs = c.bytes; size_t on = o.length / sizeof(float), cn = c.length / sizeof(float);
      double o1 = pitch(os, w), o2 = pitch(os + on - w * 3, w), c1 = pitch(cs, w), c2 = pitch(cs + cn - w * 3, w);
      CHECK(o2 > o1 * 1.3 && c2 < c1 / 1.3, "open %.0f -> %.0f Hz, close %.0f -> %.0f Hz", o1, o2, c1, c2); }

    // a save through Files (HearthSaves.m): export copies it, import keeps the old save first, refuses while the game runs, and a failed copy changes nothing
    { NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString], *why = nil, *kept = nil;
      NSString *save = [d stringByAppendingPathComponent:@"Users/u/saves/0100ABF008968000/save"], *pick = [d stringByAppendingPathComponent:@"picked"];
      NSString *(^text)(NSString *) = ^NSString *(NSString *p) { return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil]; };
      CHECK(!hearth_save_export(save, [d stringByAppendingPathComponent:@"tmp"], @"x", &why) && why, "no save: nothing to export");
      put([save stringByAppendingPathComponent:@"main"], @"old");
      NSString *out = hearth_save_export(save, [d stringByAppendingPathComponent:@"tmp"], @"Sword/Player", nil);
      CHECK([out.lastPathComponent isEqual:@"Sword-Player"] && [text([out stringByAppendingPathComponent:@"main"]) isEqual:@"old"], "export: %s", out.UTF8String);
      put([pick stringByAppendingPathComponent:@"main"], @"new");
      CHECK(!hearth_save_import(pick, save, @"0100ABF008968000", @"0100abf008968000", NSDate.date, &kept, &why) && [text([save stringByAppendingPathComponent:@"main"]) isEqual:@"old"], "refused while the game runs");
      put([pick stringByAppendingPathComponent:@"locked"], @"x"); chmod([pick stringByAppendingPathComponent:@"locked"].fileSystemRepresentation, 0);
      CHECK(!hearth_save_import(pick, save, @"0100ABF008968000", nil, NSDate.date, &kept, &why) && [text([save stringByAppendingPathComponent:@"main"]) isEqual:@"old"]
            && ![fm fileExistsAtPath:[save stringByAppendingString:@".importing"]] && !kept, "a failed copy leaves the old save: %s", why.UTF8String);
      [fm removeItemAtPath:[pick stringByAppendingPathComponent:@"locked"] error:nil];
      put([save stringByAppendingString:@".work/main"], @"stale");
      CHECK(hearth_save_import(pick, save, @"0100ABF008968000", @"0100000000010000", [NSDate dateWithTimeIntervalSince1970:0], &kept, &why), "import: %s", why.UTF8String);
      CHECK([text([save stringByAppendingPathComponent:@"main"]) isEqual:@"new"] && [text([kept stringByAppendingPathComponent:@"main"]) isEqual:@"old"]
            && [kept hasPrefix:[save stringByAppendingString:@".before-import-1970"]], "the old save kept: %s", kept.UTF8String);
      CHECK(![fm fileExistsAtPath:[save stringByAppendingString:@".work"]] && ![fm fileExistsAtPath:[save stringByAppendingString:@".replaced"]], "the old working copies are gone");
      CHECK(!hearth_save_import([d stringByAppendingPathComponent:@"none"], save, @"0100ABF008968000", nil, NSDate.date, &kept, &why), "an empty pick is refused");
      CHECK(!hearth_save_import(d, save, @"0100ABF008968000", nil, NSDate.date, &kept, &why) && [text([save stringByAppendingPathComponent:@"main"]) isEqual:@"new"], "a folder holding the save (Documents) is refused: %s", why.UTF8String);
      put([save stringByAppendingString:@"/sub/x"], @"x");
      CHECK(!hearth_save_import([save stringByAppendingPathComponent:@"sub"], save, @"0100ABF008968000", nil, NSDate.date, &kept, &why), "a folder inside the save is refused");
      [fm removeItemAtPath:d error:nil]; }

    // error history (HearthErrors.m): our sentences, a line per error, newest first, damaged lines skipped, tabs and line breaks in a name cannot split a line
    { NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
      CHECK([hearth_error_message(@"2110-0001", YES) containsString:@"Online features are not available"] && [hearth_error_message(@"2110-0001", YES) hasSuffix:@"Error code 2110-0001"], "online sentence with its code");
      CHECK(![hearth_error_message(@"", NO) containsString:@"Error code"] && [hearth_error_message(@"", NO) containsString:@"reported a problem"], "no code: the generic sentence alone");
      CHECK(hearth_error_history(d, 10).count == 0, "no history yet");
      hearth_error_record(d, @"0100000000030000", @"Old\tGame\nName", @"2002-0000", NO, [NSDate dateWithTimeIntervalSince1970:1000]);
      put([d stringByAppendingPathComponent:@"Logs/errors.txt"], [[NSString stringWithContentsOfFile:[d stringByAppendingPathComponent:@"Logs/errors.txt"] encoding:NSUTF8StringEncoding error:nil] stringByAppendingString:@"garbage line\n"]);
      hearth_error_record(d, @"0100000000030000", @"New", @"2110-0001", YES, [NSDate dateWithTimeIntervalSince1970:2000]);
      NSArray<NSDictionary *> *h = hearth_error_history(d, 10);
      CHECK(h.count == 2 && [h[0][@"code"] isEqual:@"2110-0001"] && [h[0][@"network"] boolValue] && [h[0][@"when"] timeIntervalSince1970] == 2000, "newest first: %s", h.description.UTF8String);
      CHECK(h.count == 2 && [h[1][@"name"] isEqual:@"Old Game Name"] && ![h[1][@"network"] boolValue], "the name kept on one line: %s", h.count > 1 ? [h[1][@"name"] UTF8String] : "-");
      CHECK(hearth_error_history(d, 1).count == 1, "limit");
      [fm removeItemAtPath:d error:nil]; }

    printf("t_library: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
