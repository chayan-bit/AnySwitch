// Building blocks of the settings screen (DmSettingsVC.m), modelled on the Switch's System Settings: colours that follow the system theme, an amber focus ring whose glow breathes slowly,
// category cells, rows with a toggle / selector / slider, and the button hints at the bottom.
#import <UIKit/UIKit.h>
#import "DmSettings.h"

void dm_on_style(UIView *v, void (^apply)(void));   // runs the block now and again whenever the light / dark style of the view changes
CGColorRef dm_cg(UIView *v, UIColor *c);             // a dynamic colour resolved for the view's current style (for layers)

@interface DmUI : NSObject
+ (UIColor *)bg;       // screen background
+ (UIColor *)panel;    // the right pane
+ (UIColor *)row;      // a row on the pane
+ (UIColor *)text;
+ (UIColor *)sub;      // secondary text
+ (UIColor *)sep;      // hairlines
+ (UIColor *)accent;   // focus amber (DmPalette.h)
+ (UIColor *)accentText;   // amber for text and icons on a row: the same hue, deeper in the light style so it reads at 4.5:1
+ (UIColor *)track;    // the empty part of a toggle or slider: at least 3:1 against a row in both styles
+ (UIColor *)selected; // the chosen category while the focus is in the pane
+ (UIColor *)warn;     // restart tags, locked rows
+ (UIFont *)font:(CGFloat)size weight:(UIFontWeight)w;
@end

@interface DmFocusView : UIView   // rounded amber ring with a soft glow that breathes while active (HearthTheme.h)
@property (nonatomic) CGFloat radius;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL warn;   // the border takes the warning colour (a refused entry)
@end

@interface DmToggleView : UIView
@property (nonatomic) BOOL on;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@interface DmSliderView : UIControl   // value 0...1; a drag or a tap sends UIControlEventValueChanged
@property (nonatomic) CGFloat value;
@end

@interface DmCategoryView : UIControl
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)symbol compact:(BOOL)compact;
@property (nonatomic) BOOL chosen, paneFocused;
@end

typedef NS_ENUM(NSInteger, DmItemKind) { DmItemSetting, DmItemReset, DmItemResetAll, DmItemRestart, DmItemAction };   // Action: a titled row that is not a setting (Hearth's Quick Settings and System Settings pages)
@interface DmRowView : UIView
- (instancetype)initWithSetting:(DmSetting *)s kind:(DmItemKind)kind compact:(BOOL)compact;   // setting is nil for the reset and restart rows
- (instancetype)initWithAction:(NSString *)title detail:(NSString *)detail compact:(BOOL)compact;   // an action row; info = YES makes it plain text that does nothing
- (void)setActionTitle:(NSString *)title detail:(NSString *)detail;
@property (nonatomic) BOOL info, destructive;   // an action row: plain information (no accent), or an action that removes something (warning colour)
@property (nonatomic) BOOL unavailable;          // an action row for something that cannot be done now: its title is dimmed as a setting with no effect is, its detail (the reason) stays legible
@property (nonatomic, readonly) DmSetting *setting;
@property (nonatomic, readonly) DmItemKind kind;
@property (nonatomic, readonly) DmSliderView *slider;
@property (nonatomic, copy) NSString *scopeNote;   // a game's settings: whether the row follows the system setting or is this game's own (shown before the restart note); set before showValue
- (void)showValue:(NSString *)value source:(DmSettingSource)src disabledNote:(NSString *)disabledNote;   // refresh from the store (env: the row is locked; a disabledNote: the setting has no effect now, the row is dimmed and shows the note)
@property (nonatomic, readonly) BOOL locked;
@property (nonatomic, readonly) BOOL disabled;
@property (nonatomic, readonly) BOOL inert;   // locked, disabled or unavailable: the row does not change
- (void)shake;   // a refused change
@property (nonatomic) BOOL confirming;   // the restore-all row asks for a second tap
- (CGFloat)heightForWidth:(CGFloat)w;
@end

@interface DmHintBar : UIView
- (void)setHints:(NSArray<NSArray<NSString *> *> *)hints;   // {glyph, text} pairs, laid out left to right and kept at the right edge; a letter is drawn as text, the arrows ↔ and ↵ as SF Symbols at the same size
- (CGFloat)heightWithCompact:(BOOL)compact;
@end
