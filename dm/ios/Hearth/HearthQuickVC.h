// Quick Settings (plan-hearth-p2.md 4.6): a panel from the right over Home (and so over a paused game): volume, screen brightness, console mode, audio output, Sleep, the battery.
// Volume and console mode are system settings (DmSettings.systemStore), so a paused game takes the volume at once (linkSystemLayer:) and the console mode at its next start.
// Brightness changes only when the player moves it. B, Escape, HOME or a tap beside the panel closes it
#import <UIKit/UIKit.h>

@interface HearthQuickVC : UIViewController
@property (nonatomic, copy) void (^onClose)(void);   // after the panel has gone
@property (nonatomic, copy) void (^onSleep)(void);   // Sleep was chosen (the panel is gone already)
- (void)close;
- (void)padState:(uint64_t)buttons lx:(int32_t)lx ly:(int32_t)ly;   // the controller, as Home hands it over
@end
