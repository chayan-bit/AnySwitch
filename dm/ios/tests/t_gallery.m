// Hearth's Gallery on disk (dm/ios/Hearth/HearthGallery.m) on a scratch Documents: folders and .name, picture names by time, newest first across games, titles kept after a game goes, delete only inside the Gallery.
// Foundation only, runs on the Mac: make -C dm/ios/tests run
#import <Foundation/Foundation.h>
#import "HearthGallery.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *why = nil;
    NSString *docs = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    CHECK(hearth_gallery_items(docs).count == 0, "no Gallery yet: nothing");
    NSString *a = hearth_gallery_dir(docs, @"0100ABF008968000", @"Sword"), *b = hearth_gallery_dir(docs, @"0100000000010000", nil);
    CHECK([a hasSuffix:@"/Gallery/0100ABF008968000"] && [[NSString stringWithContentsOfFile:[a stringByAppendingPathComponent:@".name"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"Sword"], "folder and name: %s", a.UTF8String);
    CHECK(b && ![fm fileExistsAtPath:[b stringByAppendingPathComponent:@".name"]], "no name given: no .name");
    NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1761200000.25];
    NSString *p1 = hearth_gallery_new_path(a, t0, @"jpg"); [@"1" writeToFile:p1 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *p2 = hearth_gallery_new_path(a, t0, @"jpg"); [@"2" writeToFile:p2 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *p3 = hearth_gallery_new_path(b, [t0 dateByAddingTimeInterval:60], @"jpg"); [@"3" writeToFile:p3 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *p4 = hearth_gallery_new_path(a, [t0 dateByAddingTimeInterval:-60], @"mp4"); [@"4" writeToFile:p4 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"x" writeToFile:[a stringByAppendingPathComponent:@"notes.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];   // not one of ours
    CHECK(p1.lastPathComponent.length == 23 && [p2 hasSuffix:@"-1.jpg"] && ![p1 isEqual:p2], "names by time, a second one in the same millisecond numbered: %s %s", p1.lastPathComponent.UTF8String, p2.lastPathComponent.UTF8String);
    NSArray<NSDictionary *> *it = hearth_gallery_items(docs);
    CHECK(it.count == 4, "four pictures, the foreign file skipped: %lu", (unsigned long)it.count);
    CHECK(it.count == 4 && [it[0][@"path"] isEqual:p3] && [it[1][@"path"] isEqual:p2] && [it[2][@"path"] isEqual:p1] && [it[3][@"path"] isEqual:p4], "newest first across games: %s", [[it valueForKey:@"path"] description].UTF8String);
    CHECK(it.count == 4 && [it[0][@"title"] isEqual:@"0100000000010000"] && [it[1][@"title"] isEqual:@"Sword"] && [it[1][@"titleId"] isEqual:@"0100ABF008968000"], "titles: the name, else the title id");
    hearth_gallery_dir(docs, @"0100ABF008968000", @"Pokémon Sword");
    CHECK([hearth_gallery_items(docs)[1][@"title"] isEqual:@"Pokémon Sword"], "a changed name is written again");
    CHECK(!hearth_gallery_delete(docs, [docs stringByAppendingPathComponent:@"Gallery/../settings.json"], &why) && why, "outside the Gallery: refused");
    CHECK(!hearth_gallery_delete(docs, [a stringByAppendingPathComponent:@".name"], &why), "the name file: refused");
    CHECK(hearth_gallery_delete(docs, p1, &why) && ![fm fileExistsAtPath:p1] && hearth_gallery_items(docs).count == 3, "one picture deleted");
    [fm removeItemAtPath:docs error:nil];
    printf("t_gallery: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
