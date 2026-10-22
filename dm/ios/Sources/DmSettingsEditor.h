// The text editor of the settings screen: a panel in the screen's own style (same fonts, colours and cyan focus border) over a dimmed scrim, with a live n/limit counter,
// a visible refusal when the limit is hit or the text is empty, and Cancel / Save buttons. The system keyboard (or a hardware one: Return saves, Escape cancels) types into it.
#import <UIKit/UIKit.h>
#import "DmSettings.h"

@interface DmEditorView : UIView
- (instancetype)initWithSetting:(DmSetting *)s text:(NSString *)text compact:(BOOL)compact;
@property (nonatomic, copy) void (^onSave)(NSString *text);   // a text the setting accepts (trimmed); called once, the editor goes away after it
@property (nonatomic, copy) void (^onCancel)(void);           // Cancel, Escape, the controller's B, a tap outside the panel
@property (nonatomic, readonly) UITextField *field;
- (void)open;     // fades in and puts the cursor in the field (the view must already be in a window)
- (void)save;     // Return / Save: an empty text is refused with feedback
- (void)cancel;
@end
