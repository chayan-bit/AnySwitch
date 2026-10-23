// The errors games asked Hearth to show (hle_err.c through front_error, front.h): the dialog's wording and the history in About (Foundation only, so t_library runs it on the Mac).
// History: Documents/Logs/errors.txt, one line per error, tab-separated: time (ISO 8601), title id, game name, code ("" when the game gave none), "online" or "".
#import <Foundation/Foundation.h>

// The dialog's sentence: our own words, with the online one for network errors (Hearth has no online play)
NSString *hearth_error_message(NSString *code, BOOL network);
// Append one error to the history in documentsDir (tabs and newlines in the fields become spaces)
void hearth_error_record(NSString *documentsDir, NSString *titleId, NSString *name, NSString *code, BOOL network, NSDate *when);
// The history, newest first, at most limit entries, each {when, titleId, name, code, network}
NSArray<NSDictionary *> *hearth_error_history(NSString *documentsDir, NSUInteger limit);
