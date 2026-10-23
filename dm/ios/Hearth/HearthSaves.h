// A user's save of one game through Files (plan-hearth-p3.md 3.4), Foundation only so dm/ios/tests/t_library.m runs it on the Mac.
// Export copies the committed save folder (Users/<uid>/saves/<title id>/save) under a readable name for the document picker to place.
// Import replaces it with a picked folder: refused while that game runs; the current save is first cloned to save.before-import-<stamp> beside it,
// the picked folder is copied next to the save and only then swapped in, so an interrupted or failed copy leaves the old save as it was.
#import <Foundation/Foundation.h>

// The folder to hand to the document picker: <tmp>/<label>/ holding the save's files. nil and why on failure (no save yet, copy failed)
NSString *hearth_save_export(NSString *save, NSString *tmpDir, NSString *label, NSString **why);
// running: the title id of the game running now (nil: none). backup: the path of the kept copy (nil when there was no save to keep). YES when the picked folder is the save now
BOOL hearth_save_import(NSString *picked, NSString *save, NSString *titleId, NSString *running, NSDate *now, NSString **backup, NSString **why);
