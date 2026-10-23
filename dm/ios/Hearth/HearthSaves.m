// A user's save through Files (HearthSaves.h)
#import "HearthSaves.h"
#include <stdio.h>

static BOOL has_files(NSString *dir) {
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return NO;
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) if (![f hasPrefix:@"."]) return YES;
    return NO;
}
static NSString *safe(NSString *s) {   // a file name: no path separators or leading dots
    NSString *t = [[s componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]] componentsJoinedByString:@"-"];
    while ([t hasPrefix:@"."]) t = [t substringFromIndex:1];
    return t.length ? t : @"save";
}

NSString *hearth_save_export(NSString *save, NSString *tmpDir, NSString *label, NSString **why) {
    NSFileManager *fm = NSFileManager.defaultManager; NSError *e = nil;
    if (!has_files(save)) { if (why) *why = @"There is no save to export yet."; return nil; }
    NSString *out = [tmpDir stringByAppendingPathComponent:safe(label)];
    [fm removeItemAtPath:out error:nil];
    [fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm copyItemAtPath:save toPath:out error:&e]) { if (why) *why = e.localizedDescription; [fm removeItemAtPath:out error:nil]; return nil; }
    return out;
}

BOOL hearth_save_import(NSString *picked, NSString *save, NSString *titleId, NSString *running, NSDate *now, NSString **backup, NSString **why) {
    NSFileManager *fm = NSFileManager.defaultManager; NSError *e = nil;
    if (backup) *backup = nil;
    if (running && [running caseInsensitiveCompare:titleId] == NSOrderedSame) { if (why) *why = @"Close the game first."; return NO; }
    if (!has_files(picked)) { if (why) *why = @"That folder holds no save files."; return NO; }
    NSString *p = [picked.stringByResolvingSymlinksInPath.stringByStandardizingPath stringByAppendingString:@"/"], *s = [save.stringByResolvingSymlinksInPath.stringByStandardizingPath stringByAppendingString:@"/"];
    if ([p isEqualToString:s]) { if (why) *why = @"That folder is this save already."; return NO; }
    // a folder picker's Open picks the folder being browsed: Hearth's own Documents (or any folder holding the save) would be copied into the save, and the save's own subfolders are not a save
    if ([s hasPrefix:p] || [p hasPrefix:s]) { if (why) *why = @"That folder holds Hearth's own files, not an exported save. Open the exported save folder itself."; return NO; }
    // 1. the picked folder next to the save: a failure here leaves everything as it was
    NSString *incoming = [save stringByAppendingString:@".importing"];
    [fm removeItemAtPath:incoming error:nil];
    [fm createDirectoryAtPath:save.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm copyItemAtPath:picked toPath:incoming error:&e]) { [fm removeItemAtPath:incoming error:nil]; if (why) *why = e.localizedDescription; return NO; }
    // 2. the current save kept beside it
    NSString *kept = nil;
    if (has_files(save)) {
        NSDateFormatter *df = [NSDateFormatter new]; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; df.dateFormat = @"yyyyMMdd-HHmmss";
        kept = [save stringByAppendingFormat:@".before-import-%@", [df stringFromDate:now]];
        if (![fm copyItemAtPath:save toPath:kept error:&e]) { [fm removeItemAtPath:incoming error:nil]; if (why) *why = [NSString stringWithFormat:@"The current save could not be kept: %@", e.localizedDescription]; return NO; }
    }
    // 3. swap it in (one rename each way; the old folder goes only after the new one is in place), and drop the host's working copies of the old save (hle_fs.c)
    NSString *old = [save stringByAppendingString:@".replaced"];
    [fm removeItemAtPath:old error:nil];
    if ([fm fileExistsAtPath:save] && ![fm moveItemAtPath:save toPath:old error:&e]) { [fm removeItemAtPath:incoming error:nil]; if (why) *why = e.localizedDescription; return NO; }
    if (![fm moveItemAtPath:incoming toPath:save error:&e]) {
        [fm moveItemAtPath:old toPath:save error:nil];   // put the old one back
        [fm removeItemAtPath:incoming error:nil]; if (why) *why = e.localizedDescription; return NO;
    }
    for (NSString *s in @[@".replaced", @".work", @".new"]) [fm removeItemAtPath:[save stringByAppendingString:s] error:nil];
    if (backup) *backup = kept;
    return YES;
}
