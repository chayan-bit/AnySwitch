// The Gallery screen (plan-hearth-p3.md 4.3): every screenshot in Documents/Gallery, newest first, with a row of game filters above the grid, and a viewer for one picture.
// Over Home as Quick Settings is, so over a paused game too; it has the controller while it is up. Grid: A opens, B or Escape closes. Viewer: left and right move,
// A shows or hides the info bar, X deletes (a second X confirms), Y shares, + saves to Photos (iPadOS asks once), B goes back to the grid. Touch has a button for each.
#import <UIKit/UIKit.h>

@interface HearthGalleryVC : UIViewController
@property (nonatomic, copy) void (^onClose)(void);   // after the screen has gone
- (void)close;
- (void)padState:(uint64_t)buttons lx:(int32_t)lx ly:(int32_t)ly;   // the controller, as Home hands it over
@end
