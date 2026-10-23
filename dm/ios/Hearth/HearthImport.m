// Game import on the device (HearthImport.h)
#import "HearthImport.h"
#import <AppleArchive/AppleArchive.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>

#define SPARE (512ull << 20)   // free space kept beyond the unpacked pack, so the import never fills the device

static NSString *hex(const unsigned char *d, size_t n) { NSMutableString *s = [NSMutableString string]; for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", d[i]]; return s; }
static NSString *sha256_file(NSString *path) {   // streamed: a pack holds files of several GB
    int fd = open(path.fileSystemRepresentation, O_RDONLY); if (fd < 0) return nil;
    CC_SHA256_CTX c; CC_SHA256_Init(&c);
    static const size_t N = 1 << 22; unsigned char *buf = malloc(N); ssize_t r;
    while ((r = read(fd, buf, N)) > 0) CC_SHA256_Update(&c, buf, (CC_LONG)r);
    free(buf); close(fd);
    if (r < 0) return nil;
    unsigned char d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(d, &c);
    return hex(d, sizeof d);
}

// An archive entry may only be a plain file or folder, at a relative path that stays inside the target (no "..", no links that a later entry could write through)
static BOOL safe_path(const char *p) {
    if (p[0] == '/') return NO;
    for (const char *s = p; *s; ) {
        const char *e = strchr(s, '/'); size_t n = e ? (size_t)(e - s) : strlen(s);
        if (n == 2 && s[0] == '.' && s[1] == '.') return NO;
        s += n; if (*s) s++;
    }
    return YES;
}
static int guard(void *arg, AAEntryMessage m, const char *path, void *data) {
    if (m == AA_ENTRY_MESSAGE_EXTRACT_FAIL) { *(char **)arg = strdup(path); return -1; }
    if (m != AA_ENTRY_MESSAGE_EXTRACT_BEGIN) return 0;
    uint64_t typ = 0; int i = AAHeaderGetKeyIndex((AAHeader)data, AA_FIELD_TYP);
    if (!safe_path(path) || i < 0 || AAHeaderGetFieldUInt((AAHeader)data, (uint32_t)i, &typ) < 0 || (typ != AA_ENTRY_TYPE_REG && typ != AA_ENTRY_TYPE_DIR)) {
        *(char **)arg = strdup(path); return -1;
    }
    return 0;
}
static NSString *extract(NSString *aar, NSString *dir) {   // nil, or what went wrong
    char *bad = NULL; ssize_t n = -1; int closed = -1;
    AAByteStream file = AAFileStreamOpenWithPath(aar.fileSystemRepresentation, O_RDONLY, 0);
    AAByteStream dec = file ? AADecompressionInputStreamOpen(file, 0, 0) : NULL;
    AAArchiveStream in = dec ? AADecodeArchiveInputStreamOpen(dec, NULL, NULL, 0, 0) : NULL;
    AAArchiveStream out = in ? AAExtractArchiveOutputStreamOpen(dir.fileSystemRepresentation, &bad, guard, 0, 0) : NULL;
    if (out) { n = AAArchiveStreamProcess(in, out, NULL, NULL, 0, 0); closed = AAArchiveStreamClose(out); }
    AAArchiveStreamClose(in); AAByteStreamClose(dec); AAByteStreamClose(file);
    NSString *why = bad ? [NSString stringWithFormat:@"the archive holds an entry that cannot be extracted safely: %s", bad]
        : !out ? @"the archive cannot be opened" : n < 0 || closed < 0 ? @"the archive is damaged or incomplete" : nil;
    free(bad);
    return why;
}

// Every file against the inventory the manifest names: nothing missing, changed or extra, and nothing but plain files and folders
static NSString *verify(NSString *root, NSString **title) {
    NSData *md = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]];
    NSDictionary *m = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:nil] : nil;
    if (![m isKindOfClass:NSDictionary.class]) return @"no readable manifest.json";
    *title = [m[@"title_id"] isKindOfClass:NSString.class] ? [m[@"title_id"] uppercaseString] : nil;
    if ((*title).length != 16 || [*title rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"].invertedSet].location != NSNotFound) return @"the manifest names no title id";
    NSDictionary *inv = [m[@"inventory"] isKindOfClass:NSDictionary.class] ? m[@"inventory"] : nil;
    if (!inv) return @"the manifest has no inventory";
    NSString *invName = [inv[@"file"] isKindOfClass:NSString.class] ? inv[@"file"] : @"files.tsv", *invPath = [root stringByAppendingPathComponent:invName];
    if (!safe_path(invName.fileSystemRepresentation) || ![sha256_file(invPath) isEqual:inv[@"sha256"]]) return [NSString stringWithFormat:@"%@ is not the inventory the manifest names", invName];
    NSMutableDictionary<NSString *, NSArray *> *want = [NSMutableDictionary dictionary];
    for (NSString *l in [[NSString stringWithContentsOfFile:invPath encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]) {
        if (!l.length || [l hasPrefix:@"#"]) continue;
        NSArray *f = [l componentsSeparatedByString:@"\t"];
        if (f.count != 3 || !safe_path([f[0] fileSystemRepresentation])) return [NSString stringWithFormat:@"%@ has a bad line: %@", invName, l];
        want[f[0]] = @[@([f[1] longLongValue]), f[2]];
    }
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString *rel in e) {
        NSString *type = e.fileAttributes[NSFileType];
        if ([type isEqual:NSFileTypeDirectory]) continue;
        if (![type isEqual:NSFileTypeRegular]) return [NSString stringWithFormat:@"%@ is not a plain file", rel];
        if ([rel isEqual:@"manifest.json"] || [rel isEqual:invName]) continue;
        NSArray *w = want[rel];
        if (!w) return [NSString stringWithFormat:@"not in the manifest: %@", rel];
        if ([e.fileAttributes[NSFileSize] longLongValue] != [w[0] longLongValue]) return [NSString stringWithFormat:@"changed: %@ (%lld bytes, the inventory says %lld)", rel, [e.fileAttributes[NSFileSize] longLongValue], [w[0] longLongValue]];
    }
    for (NSString *rel in want) {   // sizes first (cheap, above), then every digest
        NSString *p = [root stringByAppendingPathComponent:rel], *d = sha256_file(p);
        if (!d) return [NSString stringWithFormat:@"missing: %@", rel];
        if (![d isEqual:want[rel][1]]) return [NSString stringWithFormat:@"changed: %@", rel];
    }
    return nil;
}

@implementation HearthImport { HearthLibrary *_lib; }
- (instancetype)initWithLibrary:(HearthLibrary *)lib {
    if ((self = [super init])) { _lib = lib; _inbox = [lib.documentsDir stringByAppendingPathComponent:@"Import"]; }   // not Documents/Inbox: iOS keeps that one for documents opened in the app, and apps may not write there
    return self;
}
- (NSString *)p:(NSString *)name ext:(NSString *)ext { return [_inbox stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]]; }
- (NSDictionary *)note:(NSString *)name {
    NSData *d = [NSData dataWithContentsOfFile:[self p:name ext:@"ready"]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:NSDictionary.class] ? j : nil;
}
- (BOOL)complete:(NSString *)name {   // the note is there and the archive has the size it names (a copy in progress has not)
    NSDictionary *n = [self note:name];
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:[self p:name ext:@"aar"] error:nil];
    return n && a && [a[NSFileSize] longLongValue] == [n[@"archive_bytes"] longLongValue];
}
- (NSArray<NSString *> *)ready {
    NSMutableArray *out = [NSMutableArray array]; NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *f in [[fm contentsOfDirectoryAtPath:_inbox error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f.pathExtension isEqual:@"ready"]) continue;
        NSString *name = f.stringByDeletingPathExtension;
        if ([self complete:name] && ![fm fileExistsAtPath:[self p:name ext:@"hearth-error.txt"]]) [out addObject:name];
    }
    return out;
}
- (NSString *)fail:(NSString *)name why:(NSString *)why {   // the note stays with the reason beside it; the archive and the half-made folder go
    NSFileManager *fm = NSFileManager.defaultManager;
    [why writeToFile:[self p:name ext:@"hearth-error.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:[self p:name ext:@"import"] error:nil]; [fm removeItemAtPath:[self p:name ext:@"aar"] error:nil];
    NSLog(@"hearth: [RED] import %@ failed: %@", name, why);
    return why;
}
- (NSString *)importName:(NSString *)name {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!safe_path(name.fileSystemRepresentation) || [name containsString:@"/"] || ![self complete:name]) return @"not a complete archive in Documents/Import";
    NSDictionary *note = [self note:name];
    if (self.runningId && [[note[@"title_id"] description].uppercaseString isEqual:self.runningId]) return @"waits until the game is closed";
    NSString *work = [self p:name ext:@"import"];
    NSNumber *free = nil; [[NSURL fileURLWithPath:_inbox] getResourceValue:&free forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    unsigned long long need = [note[@"bytes"] unsignedLongLongValue] + SPARE;
    if (free && free.unsignedLongLongValue < need)
        return [self fail:name why:[NSString stringWithFormat:@"not enough free space: the game needs %@, %@ is free", [NSByteCountFormatter stringFromByteCount:(long long)need countStyle:NSByteCountFormatterCountStyleFile], [NSByteCountFormatter stringFromByteCount:free.longLongValue countStyle:NSByteCountFormatterCountStyleFile]]];
    double t0 = CFAbsoluteTimeGetCurrent();
    [fm removeItemAtPath:work error:nil];   // an earlier, interrupted run: start again
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    NSLog(@"hearth: import %@: extracting", name);
    NSString *why = extract([self p:name ext:@"aar"], work), *title = nil;
    if (why) return [self fail:name why:why];
    double t1 = CFAbsoluteTimeGetCurrent();
    if ((why = verify(work, &title))) return [self fail:name why:why];
    if ([_lib checkPackAt:work why:&why]) return [self fail:name why:why];
    if (self.runningId && [title isEqual:self.runningId]) { [fm removeItemAtPath:work error:nil]; return @"waits until the game is closed"; }
    NSString *games = [_lib.supportDir stringByAppendingPathComponent:@"Games"], *dest = [games stringByAppendingPathComponent:title];
    NSString *old = [games stringByAppendingFormat:@"/.replaced-%@", name];
    NSError *e = nil;
    [fm createDirectoryAtPath:games withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL had = [fm fileExistsAtPath:dest];
    if (had && ![fm moveItemAtPath:dest toPath:old error:&e]) return [self fail:name why:e.localizedDescription];
    if (![fm moveItemAtPath:work toPath:dest error:&e]) { if (had) [fm moveItemAtPath:old toPath:dest error:nil]; return [self fail:name why:e.localizedDescription]; }
    if (had) [fm removeItemAtPath:old error:nil];
    [[NSURL fileURLWithPath:dest] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];   // the user's own game, large, and can be imported again
    [fm removeItemAtPath:[self p:name ext:@"aar"] error:nil]; [fm removeItemAtPath:[self p:name ext:@"ready"] error:nil];
    NSLog(@"hearth: imported %@ as %@ (%@): extracted in %.1f s, checked in %.1f s", name, title, had ? @"replacing the installed one" : @"new", t1 - t0, CFAbsoluteTimeGetCurrent() - t1);
    return nil;
}
- (NSUInteger)importAll {
    NSUInteger n = 0;
    for (NSString *name in self.ready) if (![self importName:name]) n++;
    return n;
}
@end
