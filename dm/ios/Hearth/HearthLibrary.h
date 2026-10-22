// Hearth's game library and process-model files (Foundation only, so dm/ios/tests/t_library.m runs it on the Mac).
// Layout (notes: plan-hearth-p2.md 3.2): <home>/Library/Application Support/Hearth/{Games/<id>/, State/, next.json}; <home>/Documents/{Users/<uid>/saves/<id>/save, Logs/<id>/log.txt, Logs/hearth.txt}.
// Every game's code is a dylib inside the app bundle (Frameworks/<title id>.dylib), never in the data container: iPadOS refuses development-signed code there (spike H3).
#import <Foundation/Foundation.h>

#define HEARTH_UID @"78626c000000000153574e4154495645"   // the fixed local user of dm/host/hle_account.c, so P3's users never move a save

@interface HearthGame : NSObject
@property (nonatomic, copy) NSString *titleId, *name, *publisher, *root, *iconPath;
@property (nonatomic, copy) NSString *codePath;     // Frameworks/<id>.dylib when the bundle has it, else nil (the pack's own dylib or this executable's embedded code)
@property (nonatomic, copy) NSString *romfsPath;    // caller-provided game files (the bundled pack keeps them in Documents), else nil (the pack's romfs.dmstore)
@property (nonatomic) BOOL bundled;                 // the pack that ships inside the app
@property (nonatomic) int reason;                   // boot.h DM_PACK_*: 0 = bootable
@property (nonatomic, copy) NSString *why;          // dm_pack_check's sentence when reason != 0
@end

@interface HearthLibrary : NSObject
- (instancetype)initWithHome:(NSString *)home bundle:(NSString *)bundleRoot;   // the app: NSHomeDirectory() and NSBundle.mainBundle.bundlePath
@property (nonatomic, readonly) NSString *home, *bundleRoot, *supportDir, *documentsDir;
- (NSArray<HearthGame *> *)scan;   // bundled pack first, then Games/<id>/ by title id; each checked (cached while the pack's key files keep their size and time)
- (HearthGame *)gameWithId:(NSString *)titleId;
- (NSString *)saveDirFor:(HearthGame *)g;   // Documents/Users/<uid>/saves/<id>/save; the first time, the single-game app's Documents/save is cloned there (the original is kept)
- (NSString *)logDirFor:(HearthGame *)g;
// next.json: what the next process does, {"action": "home"} or {"action": "launch", "id": "<title id>"}. take = read and remove (a crash never loops)
- (void)writeNext:(NSDictionary *)next;
- (NSDictionary *)takeNext;
@end
