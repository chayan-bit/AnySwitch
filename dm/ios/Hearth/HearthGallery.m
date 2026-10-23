// Hearth's Gallery on disk (HearthGallery.h)
#import "HearthGallery.h"

static NSString *root_of(NSString *documents) { return [documents stringByAppendingPathComponent:@"Gallery"]; }
static NSDateFormatter *stamp(void) {
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    return f;
}

NSString *hearth_gallery_dir(NSString *documents, NSString *titleId, NSString *name) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [root_of(documents) stringByAppendingPathComponent:titleId], *np = [dir stringByAppendingPathComponent:@".name"];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    if (name.length && ![[NSString stringWithContentsOfFile:np encoding:NSUTF8StringEncoding error:nil] isEqualToString:name])
        [name writeToFile:np atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return dir;
}

NSString *hearth_gallery_new_path(NSString *dir, NSDate *now, NSString *ext) {
    NSString *base = [stamp() stringFromDate:now], *p = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:ext]];
    for (int i = 1; [NSFileManager.defaultManager fileExistsAtPath:p]; i++) p = [dir stringByAppendingPathComponent:[[base stringByAppendingFormat:@"-%d", i] stringByAppendingPathExtension:ext]];
    return p;
}

NSArray<NSDictionary *> *hearth_gallery_items(NSString *documents) {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *root = root_of(documents); NSDateFormatter *f = stamp();
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *tid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir = [root stringByAppendingPathComponent:tid];
        NSString *title = [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@".name"] encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![@[@"jpg", @"mp4"] containsObject:file.pathExtension.lowercaseString]) continue;
            NSDate *d = [f dateFromString:[file.stringByDeletingPathExtension substringToIndex:MIN((NSUInteger)19, file.stringByDeletingPathExtension.length)]];
            if (!d) continue;   // not one of ours
            [out addObject:@{@"path": [dir stringByAppendingPathComponent:file], @"titleId": tid, @"title": title.length ? title : tid, @"date": d}];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [b[@"date"] compare:a[@"date"]];
        NSString *sa = [a[@"path"] lastPathComponent].stringByDeletingPathExtension, *sb = [b[@"path"] lastPathComponent].stringByDeletingPathExtension;   // "<stamp>-1" after "<stamp>"
        return r != NSOrderedSame ? r : [sb compare:sa options:NSNumericSearch];
    }];
    return out;
}

BOOL hearth_gallery_delete(NSString *documents, NSString *path, NSString **why) {
    NSString *root = [root_of(documents).stringByStandardizingPath stringByAppendingString:@"/"], *p = path.stringByStandardizingPath;
    if (![p hasPrefix:root] || [p.lastPathComponent hasPrefix:@"."]) { if (why) *why = @"That file is not in the Gallery."; return NO; }
    NSError *e = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:p error:&e]) { if (why) *why = e.localizedDescription; return NO; }
    return YES;
}
