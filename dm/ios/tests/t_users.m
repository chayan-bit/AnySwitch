// Hearth's users (dm/ios/Hearth/HearthUsers.m) on a scratch Documents folder: the first start keeps HEARTH_UID and the old name, folders without entries and entries without folders,
// the 8-user cap, names refused, delete (its saves, never the last user), order, last user per game, users.tsv for the host. Foundation only: make -C dm/ios/tests run
#import <Foundation/Foundation.h>
#import "HearthUsers.h"
#import "HearthLibrary.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
static void put(NSString *path, NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static NSString *slurp(NSString *path) { return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]; }

int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_users.%d/Documents", getpid()]];
    NSString *save1 = [doc stringByAppendingFormat:@"/Users/%@/saves/0100ABF008968000/save/main", HEARTH_UID];
    put(save1, @"progress");   // the single-user Hearth's save, before P3

    // 1. first start: one user, HEARTH_UID, named as the old setting said; the save stays where it was
    HearthUsers *us = [[HearthUsers alloc] initWithDocuments:doc firstName:@"Chayan"];
    CHECK(us.users.count == 1 && [us.users[0].uid isEqual:HEARTH_UID] && [us.users[0].name isEqual:@"Chayan"], "first user %s", us.users[0].name.UTF8String);
    CHECK([slurp(save1) isEqual:@"progress"], "the save is untouched");
    CHECK([[us saveDirOf:us.users[0] game:@"0100ABF008968000"] isEqual:save1.stringByDeletingLastPathComponent], "the first user's save path is the old one");
    CHECK([[us gamesWithSavesOf:us.users[0]] isEqual:@[@"0100ABF008968000"]], "the first user's games with saves");
    CHECK([fm fileExistsAtPath:[doc stringByAppendingPathComponent:@"Users/users.json"]], "users.json written");
    HearthUsers *again = [[HearthUsers alloc] initWithDocuments:doc firstName:@"Other"];
    CHECK(again.users.count == 1 && [again.users[0].name isEqual:@"Chayan"], "a second start keeps the name, not the setting's");
    CHECK([[[HearthUsers alloc] initWithDocuments:[doc stringByAppendingString:@"2"] firstName:@"bad\tname"].users[0].name isEqual:@"Player"], "an unusable old name becomes Player");

    // 2. names
    CHECK([HearthUsers problemWithName:@""] && [HearthUsers problemWithName:@"   "], "empty refused");
    CHECK([HearthUsers problemWithName:@"a\tb"] && [HearthUsers problemWithName:@"a\nb"], "tab and newline refused");
    CHECK([HearthUsers problemWithName:[@"" stringByPaddingToLength:33 withString:@"x" startingAtIndex:0]], "33 bytes refused");
    CHECK(![HearthUsers problemWithName:[@"" stringByPaddingToLength:32 withString:@"x" startingAtIndex:0]], "32 bytes fine");
    CHECK([HearthUsers problemWithName:[@"" stringByPaddingToLength:11 withString:@"é" startingAtIndex:0]] == nil && [HearthUsers problemWithName:[@"" stringByPaddingToLength:17 withString:@"é" startingAtIndex:0]], "bytes, not characters");
    NSString *why = nil;
    CHECK(![us addUser:@"x\ty" avatar:nil error:&why] && why.length, "add refuses a bad name: %s", why.UTF8String);

    // 3. add, order, rename, cap
    HearthUser *b = [us addUser:@"  Guest " avatar:@{@"kind": @"art", @"symbol": @"star.fill", @"colour": @"teal"} error:&why];
    CHECK(b && b.uid.length == 32 && ![b.uid isEqual:HEARTH_UID] && [b.name isEqual:@"Guest"], "added %s", b.uid.UTF8String);
    CHECK([fm fileExistsAtPath:[us folderOf:b]], "its folder exists");
    HearthUser *c = [us addUser:@"Third" avatar:nil error:&why];
    [us move:c by:-1]; CHECK([us.users[1].uid isEqual:c.uid] && [us.users[2].uid isEqual:b.uid], "moved up");
    [us move:us.users[0] by:-1]; CHECK([us.users[0].uid isEqual:HEARTH_UID], "the first cannot move up");
    CHECK([us rename:b to:@"Misty" error:&why] && [b.name isEqual:@"Misty"], "renamed");
    CHECK(![us rename:b to:@"" error:&why] && [b.name isEqual:@"Misty"], "an empty rename refused");
    for (int i = 0; i < 5; i++) CHECK(([us addUser:[NSString stringWithFormat:@"P%d", i] avatar:nil error:nil] != nil), "add %d", i);
    CHECK(us.users.count == HEARTH_MAX_USERS && ![us addUser:@"Ninth" avatar:nil error:&why] && why.length, "the 8-user cap: %s", why.UTF8String);
    HearthUsers *reload = [[HearthUsers alloc] initWithDocuments:doc firstName:@"x"];
    CHECK(reload.users.count == 8 && [reload.users[1].name isEqual:@"Third"] && [reload.users[2].name isEqual:@"Misty"] && [reload.users[2].avatar[@"symbol"] isEqual:@"star.fill"], "order, names and avatars survive a restart");

    // 4. last user per game
    CHECK([[us lastUserOf:@"0100ABF008968000"].uid isEqual:HEARTH_UID], "nobody played it yet: the first user");
    [us setLastUser:b of:@"0100ABF008968000"];
    CHECK([[[[HearthUsers alloc] initWithDocuments:doc firstName:@"x"] lastUserOf:@"0100ABF008968000"].uid isEqual:b.uid], "remembered across a restart");

    // 5. delete: the user's folder and saves, the last user per game falls back, never the last user
    NSString *bsave = [[us saveDirOf:b game:@"0100ABF008968000"] stringByAppendingPathComponent:@"main"]; put(bsave, @"guest progress");
    CHECK([[us gamesWithSavesOf:b] isEqual:@[@"0100ABF008968000"]], "the guest's games with saves");
    CHECK([us deleteUser:b error:&why] && ![fm fileExistsAtPath:[us folderOf:b]], "deleted with its folder");
    CHECK([slurp(save1) isEqual:@"progress"], "the first user's save is untouched");
    CHECK([[us lastUserOf:@"0100ABF008968000"].uid isEqual:HEARTH_UID], "the last user of the game falls back to the first");
    while (us.users.count > 1) [us deleteUser:us.users.lastObject error:nil];
    CHECK(![us deleteUser:us.users[0] error:&why] && us.users.count == 1 && why.length, "the last user cannot go: %s", why.UTF8String);

    // 6. the folders are the truth
    NSString *lost = @"0123456789abcdef0123456789abcdef";
    put([doc stringByAppendingFormat:@"/Users/%@/saves/01007EF00011E000/save/x", lost], @"lost");
    put([doc stringByAppendingPathComponent:@"Users/not-a-user/x"], @"x");
    NSMutableDictionary *j = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[doc stringByAppendingPathComponent:@"Users/users.json"]] options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    [j[@"users"] addObject:@{@"uid": @"fedcba9876543210fedcba9876543210", @"name": @"No folder"}];
    [j[@"users"] addObject:@{@"uid": @"nope", @"name": @"Broken"}];
    [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:[doc stringByAppendingPathComponent:@"Users/users.json"] atomically:YES];
    HearthUsers *rec = [[HearthUsers alloc] initWithDocuments:doc firstName:@"x"];
    CHECK(rec.users.count == 3, "first, the entry without a folder, the folder without an entry: %lu", (unsigned long)rec.users.count);
    CHECK([rec userWithUid:@"fedcba9876543210fedcba9876543210"] && [fm fileExistsAtPath:[doc stringByAppendingPathComponent:@"Users/fedcba9876543210fedcba9876543210"]], "the entry got a folder");
    CHECK([[rec userWithUid:lost].name isEqual:@"Player 3"] && [slurp([doc stringByAppendingFormat:@"/Users/%@/saves/01007EF00011E000/save/x", lost]) isEqual:@"lost"], "the folder came back as Player 3, its save kept");
    CHECK(![rec userWithUid:@"nope"], "a bad uid in the index is dropped");
    put([doc stringByAppendingPathComponent:@"Users/users.json"], @"{ broken");
    CHECK([[HearthUsers alloc] initWithDocuments:doc firstName:@"Again"].users.count == 3, "a damaged index: rebuilt from the folders (first user named Again: %s)",
          [[[HearthUsers alloc] initWithDocuments:doc firstName:@"Again"] userWithUid:HEARTH_UID].name.UTF8String);

    // 7. users.tsv for the host: uid, name, avatar path when the picture exists
    put([rec avatarPathOf:[rec userWithUid:lost]], @"jpeg");
    NSString *tsv = [doc stringByAppendingPathComponent:@"../Library/users.tsv"];
    CHECK([rec writeHostList:tsv], "written");
    NSArray *lines = [[slurp(tsv) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\n"];
    CHECK(lines.count == 3, "three lines");
    NSArray *f0 = [lines[0] componentsSeparatedByString:@"\t"], *f2 = [lines[2] componentsSeparatedByString:@"\t"];
    CHECK(f0.count == 3 && [f0[0] isEqual:HEARTH_UID] && [f0[2] isEqual:@""], "first user: no picture yet");
    CHECK(f2.count == 3 && [f2[0] isEqual:lost] && [f2[1] isEqual:@"Player 3"] && [f2[2] hasSuffix:[lost stringByAppendingString:@"/avatar.jpg"]], "third: its picture");

    [fm removeItemAtPath:doc.stringByDeletingLastPathComponent error:nil]; [fm removeItemAtPath:[doc stringByAppendingString:@"2"] error:nil];
    printf("t_users: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
