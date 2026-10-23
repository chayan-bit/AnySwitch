// Hearth's users (plan-hearth-p3.md 3.1), Foundation only so dm/ios/tests/t_users.m runs it on the Mac.
// Documents/Users/users.json holds names, order, avatar choices and the last user per game; Documents/Users/<uid>/ holds avatar.jpg and saves/<title id>/save.
// The folders are the truth: a user folder missing from users.json comes back as "Player N", an entry without a folder gets an empty one, so editing the index in Files never loses a save.
// The first start keeps HEARTH_UID (the save the single-user Hearth made) and names it after the old Player name setting.
#import <Foundation/Foundation.h>

#define HEARTH_MAX_USERS 8
#define HEARTH_NAME_BYTES 32   // DM_NICK's limit (hle_account.c copies at most 32 bytes)

@interface HearthUser : NSObject
@property (nonatomic, copy) NSString *uid, *name;   // uid: 32 lowercase hex digits
@property (nonatomic, copy) NSDictionary *avatar;   // {"kind": "art", "symbol", "colour"} or {"kind": "photo"}; the picture itself is avatar.jpg
@end

@interface HearthUsers : NSObject
- (instancetype)initWithDocuments:(NSString *)documentsDir firstName:(NSString *)firstName;   // loads (and on the first start creates) the users
@property (nonatomic, readonly) NSArray<HearthUser *> *users;   // display order
- (HearthUser *)userWithUid:(NSString *)uid;
+ (NSString *)problemWithName:(NSString *)name;   // nil when the name is usable, else why not
- (HearthUser *)addUser:(NSString *)name avatar:(NSDictionary *)avatar error:(NSString **)why;
- (BOOL)rename:(HearthUser *)u to:(NSString *)name error:(NSString **)why;
- (void)setAvatar:(NSDictionary *)avatar of:(HearthUser *)u;
- (void)move:(HearthUser *)u by:(NSInteger)delta;   // -1 up, +1 down
- (NSArray<NSString *> *)gamesWithSavesOf:(HearthUser *)u;   // title ids under Users/<uid>/saves that hold something
- (BOOL)deleteUser:(HearthUser *)u error:(NSString **)why;   // the user's folder with its saves; the last user cannot go
- (HearthUser *)lastUserOf:(NSString *)titleId;   // who played it last, else the first user
- (void)setLastUser:(HearthUser *)u of:(NSString *)titleId;
- (NSString *)folderOf:(HearthUser *)u;
- (NSString *)avatarPathOf:(HearthUser *)u;     // Users/<uid>/avatar.jpg (may not exist)
- (NSString *)saveDirOf:(HearthUser *)u game:(NSString *)titleId;   // Users/<uid>/saves/<title id>/save (its parent created)
- (BOOL)writeHostList:(NSString *)path;          // DM_USERS for the host: uid<TAB>name<TAB>avatar path per line
@end
