// Hearth's users (HearthUsers.h)
#import "HearthUsers.h"
#import "HearthLibrary.h"
#include <stdlib.h>

@implementation HearthUser
@end

static NSDictionary *default_art(NSUInteger i) {   // the art a recovered or migrated user gets: the colours go round
    NSArray *colours = @[@"amber", @"teal", @"rose", @"violet", @"lime", @"sky", @"coral", @"slate"];
    return @{@"kind": @"art", @"symbol": @"person.fill", @"colour": colours[i % colours.count]};
}
static BOOL is_uid(NSString *s) {
    if (s.length != 32) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [s rangeOfCharacterFromSet:bad].location == NSNotFound && ![s isEqual:[@"" stringByPaddingToLength:32 withString:@"0" startingAtIndex:0]];
}
static NSString *new_uid(void) {
    uint8_t b[16]; NSMutableString *s = [NSMutableString string];
    do { arc4random_buf(b, sizeof b); [s setString:@""]; for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", b[i]]; } while (!is_uid(s));
    return s;
}

@implementation HearthUsers {
    NSString *_root; NSMutableArray<HearthUser *> *_list; NSMutableDictionary<NSString *, NSString *> *_last;
}

- (instancetype)initWithDocuments:(NSString *)documentsDir firstName:(NSString *)firstName {
    if (!(self = [super init])) return nil;
    _root = [documentsDir stringByAppendingPathComponent:@"Users"]; _list = [NSMutableArray array]; _last = [NSMutableDictionary dictionary];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:_root withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSData dataWithContentsOfFile:self.indexPath];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    BOOL first = ![j isKindOfClass:NSDictionary.class];
    if (!first) {
        for (id e in [j[@"users"] isKindOfClass:NSArray.class] ? j[@"users"] : @[]) {
            if (![e isKindOfClass:NSDictionary.class] || !is_uid(e[@"uid"]) || [self userWithUid:e[@"uid"]] || _list.count == HEARTH_MAX_USERS) continue;
            HearthUser *u = [HearthUser new]; u.uid = e[@"uid"];
            u.name = [e[@"name"] isKindOfClass:NSString.class] && ![HearthUsers problemWithName:e[@"name"]] ? e[@"name"] : [NSString stringWithFormat:@"Player %lu", (unsigned long)_list.count + 1];
            u.avatar = [e[@"avatar"] isKindOfClass:NSDictionary.class] ? e[@"avatar"] : default_art(_list.count);
            [_list addObject:u];
        }
        if ([j[@"lastByGame"] isKindOfClass:NSDictionary.class]) for (id k in j[@"lastByGame"]) if ([k isKindOfClass:NSString.class] && is_uid(j[@"lastByGame"][k])) _last[k] = j[@"lastByGame"][k];
    }
    // The first start: the single-user Hearth's user, so its save keeps its owner, named as the old Player name setting said
    if (first && !_list.count) {
        HearthUser *u = [HearthUser new]; u.uid = HEARTH_UID; u.name = [HearthUsers problemWithName:firstName] ? @"Player" : firstName; u.avatar = default_art(0);
        [_list addObject:u];
    }
    // The folders are the truth: a folder the index does not list comes back, in name order
    for (NSString *f in [[fm contentsOfDirectoryAtPath:_root error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        BOOL dir = NO;
        if (!is_uid(f) || [self userWithUid:f] || ![fm fileExistsAtPath:[_root stringByAppendingPathComponent:f] isDirectory:&dir] || !dir) continue;
        if (_list.count == HEARTH_MAX_USERS) { NSLog(@"hearth: [RED] users: %@ is not listed, there are already %d users", f, HEARTH_MAX_USERS); continue; }
        HearthUser *u = [HearthUser new]; u.uid = f; u.name = [NSString stringWithFormat:@"Player %lu", (unsigned long)_list.count + 1]; u.avatar = default_art(_list.count);
        [_list addObject:u]; NSLog(@"hearth: users: the folder %@ came back as %@", f, u.name);
    }
    if (!_list.count) { HearthUser *u = [HearthUser new]; u.uid = HEARTH_UID; u.name = @"Player"; u.avatar = default_art(0); [_list addObject:u]; }   // an index with nobody usable and no folders: never zero users
    for (HearthUser *u in _list) [fm createDirectoryAtPath:[self folderOf:u] withIntermediateDirectories:YES attributes:nil error:nil];   // an entry without a folder gets an empty one
    [self save];
    return self;
}

- (NSString *)indexPath { return [_root stringByAppendingPathComponent:@"users.json"]; }
- (void)save {
    NSMutableArray *a = [NSMutableArray array];
    for (HearthUser *u in _list) [a addObject:@{@"uid": u.uid, @"name": u.name, @"avatar": u.avatar ?: default_art(0)}];
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"users": a, @"lastByGame": _last} options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (![d writeToFile:self.indexPath atomically:YES]) NSLog(@"hearth: [RED] users: %@ could not be written", self.indexPath);
}
- (NSArray<HearthUser *> *)users { return [_list copy]; }
- (HearthUser *)userWithUid:(NSString *)uid {
    for (HearthUser *u in _list) if ([u.uid isEqualToString:uid.lowercaseString]) return u;
    return nil;
}

+ (NSString *)problemWithName:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || ![name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) return @"A name cannot be empty.";
    if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > HEARTH_NAME_BYTES) return @"That name is too long.";
    if ([name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return @"A name cannot hold tabs or line breaks.";   // users.tsv is tab-separated
    return nil;
}
static NSString *trimmed(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; }

- (HearthUser *)addUser:(NSString *)name avatar:(NSDictionary *)avatar error:(NSString **)why {
    NSString *p = [HearthUsers problemWithName:name];
    if (!p && _list.count >= HEARTH_MAX_USERS) p = [NSString stringWithFormat:@"Hearth holds up to %d users.", HEARTH_MAX_USERS];
    if (p) { if (why) *why = p; return nil; }
    HearthUser *u = [HearthUser new]; u.uid = new_uid(); u.name = trimmed(name); u.avatar = avatar ?: default_art(_list.count);
    [_list addObject:u];
    [NSFileManager.defaultManager createDirectoryAtPath:[self folderOf:u] withIntermediateDirectories:YES attributes:nil error:nil];
    [self save];
    return u;
}
- (BOOL)rename:(HearthUser *)u to:(NSString *)name error:(NSString **)why {
    NSString *p = [HearthUsers problemWithName:name];
    if (p) { if (why) *why = p; return NO; }
    u.name = trimmed(name); [self save]; return YES;
}
- (void)setAvatar:(NSDictionary *)avatar of:(HearthUser *)u { u.avatar = avatar; [self save]; }
- (void)move:(HearthUser *)u by:(NSInteger)delta {
    NSInteger i = (NSInteger)[_list indexOfObject:u], j = i + delta;
    if (i == NSNotFound || j < 0 || j >= (NSInteger)_list.count) return;
    [_list exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:(NSUInteger)j]; [self save];
}

- (NSString *)folderOf:(HearthUser *)u { return [_root stringByAppendingPathComponent:u.uid]; }
- (NSString *)avatarPathOf:(HearthUser *)u { return [[self folderOf:u] stringByAppendingPathComponent:@"avatar.jpg"]; }
- (NSString *)saveDirOf:(HearthUser *)u game:(NSString *)titleId {
    NSString *dir = [[self folderOf:u] stringByAppendingFormat:@"/saves/%@", titleId];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"save"];
}
- (NSArray<NSString *> *)gamesWithSavesOf:(HearthUser *)u {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *saves = [[self folderOf:u] stringByAppendingPathComponent:@"saves"]; NSMutableArray *out = [NSMutableArray array];
    for (NSString *t in [[fm contentsOfDirectoryAtPath:saves error:nil] sortedArrayUsingSelector:@selector(compare:)])
        if ([[fm contentsOfDirectoryAtPath:[saves stringByAppendingFormat:@"/%@/save", t] error:nil] count]) [out addObject:t];
    return out;
}
- (BOOL)deleteUser:(HearthUser *)u error:(NSString **)why {
    if (![_list containsObject:u]) { if (why) *why = @"This user is not on this iPad."; return NO; }
    if (_list.count == 1) { if (why) *why = @"The last user cannot be deleted."; return NO; }
    NSError *e = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:[self folderOf:u]] && ![NSFileManager.defaultManager removeItemAtPath:[self folderOf:u] error:&e]) { if (why) *why = e.localizedDescription; return NO; }
    [_list removeObject:u];
    for (NSString *k in _last.allKeys) if ([_last[k] isEqual:u.uid]) [_last removeObjectForKey:k];
    [self save];
    NSLog(@"hearth: deleted the user %@ and their saves", u.uid);
    return YES;
}

- (HearthUser *)lastUserOf:(NSString *)titleId { return [self userWithUid:_last[titleId]] ?: _list.firstObject; }
- (void)setLastUser:(HearthUser *)u of:(NSString *)titleId { if (!u || [_last[titleId] isEqual:u.uid]) return; _last[titleId] = u.uid; [self save]; }

- (BOOL)writeHostList:(NSString *)path {
    NSMutableString *s = [NSMutableString string]; NSFileManager *fm = NSFileManager.defaultManager;
    for (HearthUser *u in _list) { NSString *a = [self avatarPathOf:u]; [s appendFormat:@"%@\t%@\t%@\n", u.uid, u.name, [fm fileExistsAtPath:a] ? a : @""]; }
    [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    return [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
@end
