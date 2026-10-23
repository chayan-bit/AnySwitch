// Hearth's Home screen (plan-hearth-p2.md section 4): the row of games and the system buttons. As the root it is the Home a cold start shows; with overlay set it is drawn
// over the paused game (hearth_home), with that game first and marked Playing
#import <UIKit/UIKit.h>

@interface HearthHomeVC : UIViewController
@property (nonatomic) BOOL overlay;   // set before the view loads
- (void)openQuick;    // Quick Settings over Home (long HOME, or Home's own button)
- (BOOL)closeQuick;   // closes Quick Settings when it is open (HOME does that first)
@end
