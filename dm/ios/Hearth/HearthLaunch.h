// Hearth's process model (notes: plan-hearth-p2.md 3.3): one process holds Home and at most one game, launched in process; closing a game restarts the app,
// because a game's address space, Metal device and host globals live for the whole process (dm_boot_game runs once per process)
#import <UIKit/UIKit.h>
#import "HearthLibrary.h"

HearthLibrary *hearth_library(void);
HearthGame *hearth_running_game(void);   // nil while no game was launched in this process
// Launch g in this process (Home's tile action). A refused pack shows its reason; with another game running the app restarts straight into g
void hearth_launch(HearthGame *g, UIWindow *window);
// End the running game: next.json says Home, the app asks iOS to open it again, then exits (spike H2: back in about 0.2 s)
void hearth_close(void);
// The confirmation the game's Home button shows until the Home overlay exists (step 6)
void hearth_confirm_close(UIViewController *over);
