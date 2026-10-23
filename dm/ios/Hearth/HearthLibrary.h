// Hearth's game library and process-model files (Foundation only, so dm/ios/tests/t_library.m runs it on the Mac).
// Layout (notes: plan-hearth-p2.md 3.2): <home>/Library/Application Support/Hearth/{Games/<id>/, State/, next.json}; <home>/Documents/{Users/<uid>/saves/<id>/save, Logs/<id>/log.txt, Logs/hearth.txt}.
// A game's code: an imported game's own code/ios.dylib in the data container when it is signed for this app (notes/hearth-p2.md, E1: identifier = Hearth's bundle ID, the same team and certificate),
// else the app bundle's Frameworks/<title id>.dylib when the build carries one (the fallback, and the bundled game's place), else the tile says "Needs signing".
// Paths are always built from the current home at run time: the data container moves when the app is reinstalled.
#import <Foundation/Foundation.h>
#import "HearthSign.h"

#define HEARTH_NEEDS_SIGNING 100   // HearthGame.reason beside boot.h's DM_PACK_*: the pack is fine, its code is not signed for this copy of Hearth
#define HEARTH_UID @"78626c000000000153574e4154495645"   // the fixed local user of dm/host/hle_account.c, so P3's users never move a save

@interface HearthGame : NSObject
@property (nonatomic, copy) NSString *titleId, *name, *publisher, *root, *iconPath;
@property (nonatomic, copy) NSString *version;      // the NACP's display version ("1.3.2"), nil when the pack has none
@property (nonatomic, copy) NSString *codePath;     // Frameworks/<id>.dylib when that is the code used, else nil (the pack's own code/ios.dylib, or this executable's embedded code)
@property (nonatomic, copy) NSString *romfsPath;    // caller-provided game files (the bundled pack keeps them in Documents), else nil (the pack's romfs.dmstore)
@property (nonatomic) BOOL bundled;                 // the pack that ships inside the app
@property (nonatomic) int reason;                   // boot.h DM_PACK_* or HEARTH_NEEDS_SIGNING: 0 = bootable
@property (nonatomic) double lastPlayed;            // seconds since 1970 of the last launch (State/<id>.json), 0 = never
@property (nonatomic, copy) NSString *why;          // dm_pack_check's sentence when reason != 0
@property (nonatomic) int startupUser;              // the NACP's StartupUserAccount (0x3025): 0 none, 1 required, 2 required with an online account; non-zero = the game starts as a chosen user
@end

@interface HearthLibrary : NSObject
- (instancetype)initWithHome:(NSString *)home bundle:(NSString *)bundleRoot;   // the app: NSHomeDirectory() and NSBundle.mainBundle.bundlePath
@property (nonatomic, readonly) NSString *home, *bundleRoot, *supportDir, *documentsDir;
@property (nonatomic, copy) NSString *bundleId;          // this app's bundle ID and signature: what imported code must be signed with (the app sets them; nil = no check)
@property (nonatomic, strong) HearthSigner *appSigner;
- (NSArray<HearthGame *> *)scan;   // the bundled pack and Games/<id>/, last played first, then by title id; each checked (cached while the pack's key files keep their size and time)
- (void)markPlayed:(HearthGame *)g;   // State/<id>.json: lastPlayed = now
- (void)addPlayTime:(double)seconds to:(HearthGame *)g user:(NSString *)uid;   // State/<id>.json playSeconds (the total) and users.<uid>.playSeconds; uid nil: the total only
- (double)playTimeOf:(HearthGame *)g;   // every user's
- (double)playTimeOf:(HearthGame *)g user:(NSString *)uid;
- (void)rememberCaps:(NSDictionary<NSString *, NSNumber *> *)caps of:(HearthGame *)g;   // what the game provides (dm_capability), learned when it runs (plan decision 12)
- (NSDictionary<NSString *, NSNumber *> *)capsOf:(HearthGame *)g;   // nil before its first start
// Bytes per kind: code, shaders (msl/), pipelines (pso/), files (the game's own files), addons (aoc/), other (profile, icon, manifest), save
- (NSDictionary<NSString *, NSNumber *> *)sizesOf:(HearthGame *)g;
- (BOOL)deleteGame:(HearthGame *)g error:(NSString **)why;      // an imported game's folder and state; its saves stay. Not the game built into the app. The caller makes sure it is not running
- (BOOL)deleteSavesOf:(HearthGame *)g error:(NSString **)why;   // every user's save of this game, each folder left empty so the old single-game save is not copied back
- (BOOL)deleteSavesOf:(HearthGame *)g user:(NSString *)uid error:(NSString **)why;   // one user's
- (unsigned long long)saveSizeOf:(HearthGame *)g user:(NSString *)uid;
- (HearthGame *)gameWithId:(NSString *)titleId;
- (int)checkPackAt:(NSString *)root why:(NSString **)why;   // dm_pack_check of a folder with its own code and game files (an import, before it replaces anything); 0 = fine
- (NSString *)saveDirFor:(HearthGame *)g;   // the first user's (HEARTH_UID) Documents/Users/<uid>/saves/<id>/save; the first time, the single-game app's Documents/save is cloned there (the original is kept)
- (NSString *)saveDirFor:(HearthGame *)g user:(NSString *)uid;   // that user's; the single-game copy only for HEARTH_UID
- (NSString *)logDirFor:(HearthGame *)g;
// next.json: what the next process does, {"action": "home"} or {"action": "launch", "id": "<title id>"}. take = read and remove (a crash never loops)
- (void)writeNext:(NSDictionary *)next;
- (NSDictionary *)takeNext;
@end
