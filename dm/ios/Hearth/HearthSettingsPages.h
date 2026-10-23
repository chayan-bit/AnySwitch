// Hearth's own pages for the settings screen (DmSettingsVC with DmPage, plan-hearth-p2.md 5.3 and 5.4).
// System Settings: the registry's pages (Appearance among them), then Data Management, Signing, About, and Developer once About's version line was pressed 7 times.
// A game's Options: Overview, the rows this game may set for itself (scope game or both, filtered by what the game provides, learned when it runs), Manage.
#import <UIKit/UIKit.h>
#import "DmSettingsVC.h"
#import "HearthLibrary.h"

DmSettingsVC *hearth_system_settings(CGSize size);   // the caller sets onClose and onRestart and shows it
void hearth_settings_show_user(DmSettingsVC *v, NSString *uid);   // after it is shown: the Users page at that user (Home's avatars)
// A game's Options; gone runs after the game was deleted (the caller closes the sheet and reloads Home). The running game's rows use the live store, so a change reaches it at once
DmSettingsVC *hearth_options(HearthGame *g, CGSize size, void (^gone)(void));
// DM_APPEARANCE (the system store's value; env.txt still wins) on every window of the app: at scene start, and after a change in either settings screen
void hearth_apply_appearance(void);
