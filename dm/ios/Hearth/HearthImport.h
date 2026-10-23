// Game import on the device (plan-hearth-p2.md 6.1; the Mac side is scripts/push_pack.py). Foundation, AppleArchive and CommonCrypto only, so dm/ios/tests/t_import.m runs it on the Mac.
// Documents/Import/<name>.aar is one Apple Archive of a pack; <name>.ready (written after it) gives its size, so a copy still in progress is left alone.
// An import, in order: free space, extraction into Import/<name>.import/ (only plain files and folders inside it), every file checked against the pack's inventory
// (size, then SHA-256), dm_pack_check, then a rename into Library/Application Support/Hearth/Games/<title id>/ (the same volume: instant), kept out of the device backup.
// An installed game of the same title is replaced only after the new one passed every check; saves are never touched.
// Interrupted (the app was closed or killed), it starts again from the archive next time. A failure leaves Import/<name>.hearth-error.txt with the reason and drops the archive
#import <Foundation/Foundation.h>
#import "HearthLibrary.h"

@interface HearthImport : NSObject
- (instancetype)initWithLibrary:(HearthLibrary *)lib;
@property (nonatomic, readonly) NSString *inbox;
@property (nonatomic, copy) NSString *runningId;    // the title of the game running in this process: it is not replaced under it (the import waits)
- (NSArray<NSString *> *)ready;                     // names of complete archives waiting, without an error note, oldest first
- (NSString *)importName:(NSString *)name;          // nil: imported; else the reason (written beside it unless the import only has to wait)
- (NSUInteger)importAll;                            // every ready archive; the number imported
@end
