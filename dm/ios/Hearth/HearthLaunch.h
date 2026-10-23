// Hearth's process model (notes: plan-hearth-p2.md 3.3): one process holds Home and at most one game, launched in process; closing a game restarts the app,
// because a game's address space, Metal device and host globals live for the whole process (dm_boot_game runs once per process)
#import <UIKit/UIKit.h>
#import "HearthLibrary.h"

HearthLibrary *hearth_library(void);
HearthGame *hearth_running_game(void);   // nil while no game was launched in this process
// Launch g in this process (Home's tile action). A refused pack shows its reason; with another game running, a dialog offers to close it and restart straight into g.
// The game boots at once (the host loads in the background); zoom, when given, plays Home's launch animation meanwhile and calls done when the game's screen may replace Home
void hearth_launch(HearthGame *g, UIWindow *window, void (^zoom)(void (^done)(void)));
// End the running game: next.json says Home, the app asks iOS to open it again, then exits (spike H2: back in about 0.2 s)
void hearth_close(void);
// The settings screens' Restart now: the running game closes and starts again in a new process, with the changed settings
void hearth_restart_game(void);
// "Close <game>?": Close ends the running game (hearth_close), Cancel keeps it
void hearth_confirm_close(UIViewController *over);
// HOME (the touch Home button, Cmd+Return): Home over the paused game, or back to the game when Home is up. While the game blocks HOME the press waits (dm_home_press)
void hearth_home(void);
void hearth_home_long(void);   // long HOME (a long press on the touch Home button): Home with Quick Settings open over the paused game
void hearth_resume(void);    // leave Home: the game runs again
BOOL hearth_home_up(void);   // Home is over a paused game
// A controller's answer to the dialog over over (UIAlertController takes no controller input): it is dismissed; yes (A) also runs the confirming action of a dialog
// hearth_confirm_close or the switch dialog showed, no (B) is Cancel
void hearth_dialog_answer(UIViewController *over, BOOL yes);
