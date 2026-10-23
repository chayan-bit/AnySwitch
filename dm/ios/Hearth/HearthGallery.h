// Hearth's Gallery on disk (plan-hearth-p3.md 4.2), Foundation only so dm/ios/tests/t_gallery.m runs it on the Mac.
// Documents/Gallery/<title id>/<yyyyMMdd-HHmmss-SSS>.jpg; Documents/Gallery/<title id>/.name holds the game's name, so a deleted game's pictures keep a title. Not per user, as on the console.
#import <Foundation/Foundation.h>

// The game's folder, created, with .name written when a name is given and it changed. nil when it cannot be created
NSString *hearth_gallery_dir(NSString *documents, NSString *titleId, NSString *name);
// A new picture's path in dir, named by the time (a second picture in the same millisecond gets -1, -2, ...)
NSString *hearth_gallery_new_path(NSString *dir, NSDate *now, NSString *ext);
// Every picture, newest first: @{@"path", @"titleId", @"title" (the .name, else the title id), @"date" (NSDate from the file name)}
NSArray<NSDictionary *> *hearth_gallery_items(NSString *documents);
// Removes one picture; only files inside Documents/Gallery
BOOL hearth_gallery_delete(NSString *documents, NSString *path, NSString **why);
