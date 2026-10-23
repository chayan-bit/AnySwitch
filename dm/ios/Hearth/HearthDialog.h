// Hearth's dialog (plan-hearth-p2.md 4.5): a sheet drawn like the rest of Hearth (panel, rounded buttons, the amber focus ring with its breathing glow, the button hints), not a stock iOS alert.
// A controller (it takes the controller while the dialog is up and hands it back when the buttons are released), a hardware keyboard and touch all drive it: left and right move the focus,
// A or Return chooses, B or Escape (or a tap outside) answers the cancel button.
#import <UIKit/UIKit.h>

// buttons: titles, left to right. destructive: the index drawn in the warning colour (-1 none). focus: the button focused at first (the one a plain A or Return chooses). cancel: the index B, Escape and a tap
// outside choose (-1: only a button ends the dialog). answer runs with the chosen index once the dialog is gone. The dialog opens over the top-most dialog or sheet above over.
void hearth_dialog(UIViewController *over, NSString *title, NSString *message, NSArray<NSString *> *buttons, NSInteger destructive, NSInteger focus, NSInteger cancel, void (^answer)(NSInteger index));
// One OK button: information the player only has to dismiss
void hearth_dialog_info(UIViewController *over, NSString *title, NSString *message);
