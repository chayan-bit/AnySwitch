// Screenshots of the game's own picture (plan-hearth-p3.md 4.1, spike C1): the game view's 16:9 content only, without the touch controls (a separate view) and without the ambient bars
// (cropped away), written as a JPEG into the Gallery. The grab runs on the main thread from the render server's copy of the screen, so dm/gfx is not involved; the encode runs on a background queue.
#import <UIKit/UIKit.h>

// Grab content (in view's coordinates) of view now and write it as a JPEG into dir (created when missing). done runs on the main thread with the file (nil on failure) and the times in ms
void hearth_capture(UIView *view, CGRect content, NSString *dir, void (^done)(NSString *path, double grabMs, double encodeMs));
