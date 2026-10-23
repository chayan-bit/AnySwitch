// Test input (plan-hearth-p3.md 5.1), from the Controllers page: every game button lights while it is held and both sticks show where they point, as the game would get them
// (after the controller and keyboard maps, from any controller, the keyboard or touch: dm_gamepad_set_monitor). It holds the controller while it is up; holding B for a second,
// Escape or the Done button closes it.
#import <UIKit/UIKit.h>

@interface HearthInputTestVC : UIViewController
@property (nonatomic, copy) void (^onClose)(void);   // the screen asks to be removed; the monitor is already stopped
@end
