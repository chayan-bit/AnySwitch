// Hearth's game library (HearthLibrary.h): scan, pack check with a cache, NACP names, save and log paths, next.json
#import "HearthLibrary.h"
#include <stdlib.h>
#include "boot.h"
#include <TargetConditionals.h>

#define HEARTH_PLATFORM (TARGET_OS_IPHONE ? "ios" : "macos")   // the code a pack carries for this platform, as boot.m names it

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
    NSString *inApp = [_bundleRoot stringByAppendingFormat:@"/Frameworks/%@.dylib", g.titleId];
    if ([NSFileManager.defaultManager fileExistsAtPath:inApp]) g.codePath = inApp;   // the bundled game's code; an imported game's fallback (check: decides)
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
// An imported game's own code is used when it is signed for this app; otherwise the in-app copy, when the build has one; otherwise the game needs signing
- (void)check:(HearthGame *)g {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *own = g.bundled ? nil : [g.root stringByAppendingFormat:@"/code/%s.dylib", HEARTH_PLATFORM];
    if (own && ![fm fileExistsAtPath:own]) own = nil;
    NSString *key = [@[stamp([g.root stringByAppendingPathComponent:@"manifest.json"]), stamp([g.root stringByAppendingPathComponent:@"profile/game.json"]),
                       g.codePath ? stamp(g.codePath) : @"embedded", own ? stamp(own) : @"-", g.romfsPath ?: @"-"] componentsJoinedByString:@" "];
    NSArray *c = _checked[g.root];
    if (![c[0] isEqual:key]) {
        NSString *bad = own && _bundleId ? hearth_code_mismatch(_appSigner, _bundleId, [HearthSigner signerOf:own]) : nil;
        BOOL useOwn = own && (!bad || !g.codePath);
        NSString *code = useOwn ? nil : g.codePath;   // nil: dm_pack_check looks at the pack's own code (or this executable's)
        char why[1024] = "", *oc, *orf;
        env_swap("DM_CODE", code, &oc); env_swap("DM_ROMFS", g.romfsPath, &orf);
        int r = dm_pack_check(g.root.fileSystemRepresentation, why, sizeof why);
        env_back("DM_CODE", oc); env_back("DM_ROMFS", orf);
        NSString *text = @(why);
        if (!r && useOwn && bad) { r = HEARTH_NEEDS_SIGNING; text = [NSString stringWithFormat:@"%@: %@. To sign it for this app, import the game again from the Mac.", g.titleId, bad]; }   // also after Hearth's certificate or bundle ID changed
        c = @[key, @(r), text, code ?: @""]; _checked[g.root] = c;
    }
    g.reason = [c[1] intValue]; g.why = g.reason ? c[2] : nil; g.codePath = [c[3] length] ? c[3] : nil;
}

- (NSString *)statePath:(HearthGame *)g { return [_supportDir stringByAppendingFormat:@"/State/%@.json", g.titleId]; }
- (NSDictionary *)stateOf:(HearthGame *)g {
    id st = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self statePath:g]] ?: NSData.data options:0 error:nil];
    return [st isKindOfClass:NSDictionary.class] ? st : @{};
}
- (void)updateState:(HearthGame *)g with:(void (^)(NSMutableDictionary *st))change {
    NSString *p = [self statePath:g]; NSMutableDictionary *st = [[self stateOf:g] mutableCopy];
    change(st);
    [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:st options:0 error:nil] writeToFile:p atomically:YES];
}
- (void)markPlayed:(HearthGame *)g {
    double now = NSDate.date.timeIntervalSince1970; g.lastPlayed = now;
    [self updateState:g with:^(NSMutableDictionary *st) { st[@"lastPlayed"] = @(now); }];
}
- (void)addPlayTime:(double)s to:(HearthGame *)g {
    if (!(s > 0)) return;
    [self updateState:g with:^(NSMutableDictionary *st) { st[@"playSeconds"] = @([st[@"playSeconds"] doubleValue] + s); }];
}
- (double)playTimeOf:(HearthGame *)g { id v = [self stateOf:g][@"playSeconds"]; return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 0; }
- (void)rememberCaps:(NSDictionary<NSString *, NSNumber *> *)caps of:(HearthGame *)g { [self updateState:g with:^(NSMutableDictionary *st) { st[@"caps"] = caps; }]; }
- (NSDictionary<NSString *, NSNumber *> *)capsOf:(HearthGame *)g { id c = [self stateOf:g][@"caps"]; return [c isKindOfClass:NSDictionary.class] ? c : nil; }

static unsigned long long tree_size(NSString *path) {   // a file's size, or the sum of the files under a folder
    NSFileManager *fm = NSFileManager.defaultManager; BOOL dir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&dir]) return 0;
    if (!dir) return [[fm attributesOfItemAtPath:path error:nil] fileSize];
    unsigned long long n = 0;
    for (NSURL *u in [fm enumeratorAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsRegularFileKey] options:0 errorHandler:nil]) {
        NSNumber *reg = nil, *sz = nil; [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil]; [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        if (reg.boolValue) n += sz.unsignedLongLongValue;
    }
    return n;
}
- (NSDictionary<NSString *, NSNumber *> *)sizesOf:(HearthGame *)g {
    NSString *r = g.root;
    unsigned long long code = tree_size([r stringByAppendingPathComponent:@"code"]) + (g.codePath ? tree_size(g.codePath) : 0);
    unsigned long long files = g.romfsPath ? tree_size(g.romfsPath) : tree_size([r stringByAppendingPathComponent:@"romfs.dmstore"]) + tree_size([r stringByAppendingPathComponent:@"romfs"]);
    unsigned long long known = 0, all = tree_size(r);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSArray *k in @[@[@"shaders", @"msl"], @[@"pipelines", @"pso"], @[@"addons", @"aoc"]]) { unsigned long long n = tree_size([r stringByAppendingPathComponent:k[1]]); out[k[0]] = @(n); known += n; }
    known += tree_size([r stringByAppendingPathComponent:@"code"]) + (g.romfsPath ? 0 : files);
    out[@"code"] = @(code); out[@"files"] = @(files); out[@"other"] = @(all > known ? all - known : 0);
    out[@"save"] = @(tree_size([[self saveDirFor:g] stringByDeletingLastPathComponent]));
    return out;
}
- (BOOL)deleteGame:(HearthGame *)g error:(NSString **)why {
    if (g.bundled || ![g.root hasPrefix:[_supportDir stringByAppendingPathComponent:@"Games/"]]) { if (why) *why = @"This game is built into the app and goes only when Hearth is deleted."; return NO; }
    NSError *e = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:g.root error:&e]) { if (why) *why = e.localizedDescription; return NO; }
    [NSFileManager.defaultManager removeItemAtPath:[self statePath:g] error:nil];
    [_checked removeObjectForKey:g.root];
    NSLog(@"hearth: deleted the game %@ (its saves are kept)", g.titleId);
    return YES;
}
- (BOOL)deleteSavesOf:(HearthGame *)g error:(NSString **)why {
    NSString *save = [self saveDirFor:g]; NSError *e = nil; NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *suffix in @[@"", @".work", @".new"]) {   // the committed save and the host's working and pending copies beside it (hle_fs.c)
        NSString *p = [save stringByAppendingString:suffix];
        if ([fm fileExistsAtPath:p] && ![fm removeItemAtPath:p error:&e]) { if (why) *why = e.localizedDescription; return NO; }
    }
    [fm createDirectoryAtPath:save withIntermediateDirectories:YES attributes:nil error:nil];   // present and empty: saveDirFor does not copy the old single-game save again
    NSLog(@"hearth: deleted the saves of %@", g.titleId);
    return YES;
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
    for (HearthGame *g in out) {
        NSDictionary *st = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self statePath:g]] ?: NSData.data options:0 error:nil];
        g.lastPlayed = [st isKindOfClass:NSDictionary.class] && [st[@"lastPlayed"] isKindOfClass:NSNumber.class] ? [st[@"lastPlayed"] doubleValue] : 0;
    }
    [out sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(HearthGame *a, HearthGame *b) {   // last played first; the never played keep the scan order
        return a.lastPlayed == b.lastPlayed ? NSOrderedSame : a.lastPlayed > b.lastPlayed ? NSOrderedAscending : NSOrderedDescending; }];
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
