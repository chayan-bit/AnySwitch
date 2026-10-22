// Hearth's game library (HearthLibrary.h): scan, pack check with a cache, NACP names, save and log paths, next.json
#import "HearthLibrary.h"
#include <stdlib.h>
#include "boot.h"

@implementation HearthGame
@end

// Name and publisher from meta/control.nacp: 16 language entries of 0x300 bytes (name 0x200, publisher 0x100); American English first, else the first one that is set
static void nacp_read(NSString *path, HearthGame *g) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d.length < 16 * 0x300) return;
    const char *b = d.bytes;
    for (int i = 0; i < 16; i++) {
        const char *e = b + i * 0x300;
        if (!e[0]) continue;
        g.name = [[NSString alloc] initWithBytes:e length:strnlen(e, 0x200) encoding:NSUTF8StringEncoding];
        g.publisher = [[NSString alloc] initWithBytes:e + 0x200 length:strnlen(e + 0x200, 0x100) encoding:NSUTF8StringEncoding];
        return;
    }
}

@implementation HearthLibrary {
    NSMutableDictionary<NSString *, NSArray *> *_checked;   // root -> @[key, reason, why]
}
- (instancetype)initWithHome:(NSString *)home bundle:(NSString *)bundleRoot {
    if (!(self = [super init])) return nil;
    _home = home.copy; _bundleRoot = bundleRoot.copy; _checked = [NSMutableDictionary dictionary];
    _supportDir = [home stringByAppendingPathComponent:@"Library/Application Support/Hearth"];
    _documentsDir = [home stringByAppendingPathComponent:@"Documents"];
    [NSFileManager.defaultManager createDirectoryAtPath:[_supportDir stringByAppendingPathComponent:@"Games"] withIntermediateDirectories:YES attributes:nil error:nil];
    return self;
}

- (HearthGame *)gameAt:(NSString *)root bundled:(BOOL)bundled {
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]] ?: NSData.data options:0 error:nil];
    HearthGame *g = [HearthGame new];
    g.root = root; g.bundled = bundled;
    g.titleId = [m isKindOfClass:NSDictionary.class] && [m[@"title_id"] isKindOfClass:NSString.class] ? m[@"title_id"] : root.lastPathComponent;
    g.name = g.titleId;
    nacp_read([root stringByAppendingPathComponent:@"meta/control.nacp"], g);
    NSString *icon = [root stringByAppendingPathComponent:@"meta/icon.jpg"];
    if ([NSFileManager.defaultManager fileExistsAtPath:icon]) g.iconPath = icon;
    NSString *code = [_bundleRoot stringByAppendingFormat:@"/Frameworks/%@.dylib", g.titleId];
    if ([NSFileManager.defaultManager fileExistsAtPath:code]) g.codePath = code;
    if (bundled) {   // the single-game app's game files stay where they were installed
        for (NSString *rel in @[@"romfs.dmstore", @"romfs"]) {
            NSString *p = [_documentsDir stringByAppendingPathComponent:rel];
            if ([NSFileManager.defaultManager fileExistsAtPath:p]) { g.romfsPath = p; break; }
        }
    }
    [self check:g];
    return g;
}

// dm_pack_check reads DM_CODE and DM_ROMFS from the environment: set them for this game, then put back what was there (a running game's own values)
static void env_swap(const char *k, NSString *v, char **old) {
    const char *o = getenv(k); *old = o ? strdup(o) : NULL;
    if (v) setenv(k, v.fileSystemRepresentation, 1); else unsetenv(k);
}
static void env_back(const char *k, char *old) { if (old) { setenv(k, old, 1); free(old); } else unsetenv(k); }
static NSString *stamp(NSString *p) {
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
    return a ? [NSString stringWithFormat:@"%@:%.6f", a[NSFileSize], [a[NSFileModificationDate] timeIntervalSince1970]] : @"-";
}
- (void)check:(HearthGame *)g {
    NSString *key = [@[stamp([g.root stringByAppendingPathComponent:@"manifest.json"]), stamp([g.root stringByAppendingPathComponent:@"profile/game.json"]),
                       g.codePath ? stamp(g.codePath) : @"embedded", g.romfsPath ?: @"-"] componentsJoinedByString:@" "];
    NSArray *c = _checked[g.root];
    if (![c[0] isEqual:key]) {
        char why[1024] = "", *oc, *orf;
        env_swap("DM_CODE", g.codePath, &oc); env_swap("DM_ROMFS", g.romfsPath, &orf);
        int r = dm_pack_check(g.root.fileSystemRepresentation, why, sizeof why);
        env_back("DM_CODE", oc); env_back("DM_ROMFS", orf);
        c = @[key, @(r), @(why)]; _checked[g.root] = c;
    }
    g.reason = [c[1] intValue]; g.why = g.reason ? c[2] : nil;
}

- (NSArray<HearthGame *> *)scan {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *bp = [_bundleRoot stringByAppendingPathComponent:@"pack"];
    if ([fm fileExistsAtPath:[bp stringByAppendingPathComponent:@"manifest.json"]]) [out addObject:[self gameAt:bp bundled:YES]];
    NSString *gd = [_supportDir stringByAppendingPathComponent:@"Games"];
    for (NSString *d in [[fm contentsOfDirectoryAtPath:gd error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *r = [gd stringByAppendingPathComponent:d];
        if ([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"manifest.json"]]) [out addObject:[self gameAt:r bundled:NO]];
    }
    return out;
}
- (HearthGame *)gameWithId:(NSString *)titleId {
    for (HearthGame *g in [self scan]) if ([g.titleId caseInsensitiveCompare:titleId] == NSOrderedSame) return g;
    return nil;
}

- (NSString *)saveDirFor:(HearthGame *)g {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [_documentsDir stringByAppendingFormat:@"/Users/%@/saves/%@", HEARTH_UID, g.titleId], *save = [dir stringByAppendingPathComponent:@"save"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *legacy = [_documentsDir stringByAppendingPathComponent:@"save"];
    // The single-game app kept its one game's save in Documents/save: cloned (APFS copy) for the bundled game the first time, never moved, so the old file stays until the user removes it
    if (g.bundled && ![fm fileExistsAtPath:save] && [fm fileExistsAtPath:legacy]) {
        NSError *e = nil;
        if (![fm copyItemAtPath:legacy toPath:save error:&e]) NSLog(@"hearth: [RED] could not copy %@ to %@: %@", legacy, save, e.localizedDescription);
        else NSLog(@"hearth: copied the save from %@ to %@ (the original is kept)", legacy, save);
    }
    return save;
}
- (NSString *)logDirFor:(HearthGame *)g {
    NSString *d = [_documentsDir stringByAppendingFormat:@"/Logs/%@", g.titleId];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

- (NSString *)nextPath { return [_supportDir stringByAppendingPathComponent:@"next.json"]; }
- (void)writeNext:(NSDictionary *)next {
    [[NSJSONSerialization dataWithJSONObject:next options:0 error:nil] writeToFile:self.nextPath atomically:YES];
}
- (NSDictionary *)takeNext {
    NSData *d = [NSData dataWithContentsOfFile:self.nextPath];
    [NSFileManager.defaultManager removeItemAtPath:self.nextPath error:nil];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:NSDictionary.class] ? j : @{@"action": @"home"};
}
@end
