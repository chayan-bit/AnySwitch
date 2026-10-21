// The settings screen: a category list on the left, the chosen category's rows on the right, a cyan pulsing focus border, button hints at the bottom (see DmSettingsVC.m).
// Controller: D-pad or left stick moves, A selects / changes, B goes back (closes from the category list), L / R (and ZL / ZR) switch category. Touch: tap, drag a slider. Hardware keyboard: arrows, return, escape, [ and ].
#import <UIKit/UIKit.h>
#import "DmSettings.h"

@interface DmSettingsVC : UIViewController
- (instancetype)initWithSettings:(DmSettings *)settings size:(CGSize)size;   // size: the screen the view will fill; a short side under 500 pt (a phone in landscape) gets the compact sizes
@property (nonatomic, copy) void (^onClose)(void);     // the screen asks to be closed (B on the category list, the close button, escape)
@property (nonatomic, copy) void (^onRestart)(void);   // the restart row was chosen; the default exits the process
@property (nonatomic, readonly) NSInteger section;
// The physical controller's state (DmPadBits.h buttons, left stick) as handed over by dm_gamepad_set_capture; the first call only records what is already held
- (void)padState:(uint64_t)buttons lx:(int32_t)lx ly:(int32_t)ly;
// Jump to a state (tests and screenshots): the category, whether the focus is in the pane, and the row there
- (void)selectSection:(NSInteger)section focusPane:(BOOL)pane row:(NSInteger)row;
@end
