// Building blocks of the settings screen (DmSettingsVC.m), modelled on the Switch's System Settings: colours that follow the system theme, a cyan focus border with a soft pulse,
// category cells, rows with a toggle / selector / slider, and the button hints at the bottom.
#import <UIKit/UIKit.h>
#import "DmSettings.h"

@interface DmUI : NSObject
+ (UIColor *)bg;       // screen background
+ (UIColor *)panel;    // the right pane
+ (UIColor *)row;      // a row on the pane
+ (UIColor *)text;
+ (UIColor *)sub;      // secondary text
+ (UIColor *)sep;      // hairlines
+ (UIColor *)accent;   // focus cyan
+ (UIColor *)selected; // the chosen category while the focus is in the pane
+ (UIColor *)warn;     // restart tags, locked rows
+ (UIFont *)font:(CGFloat)size weight:(UIFontWeight)w;
@end

@interface DmFocusView : UIView   // rounded cyan border with a soft glow that pulses while active
@property (nonatomic) CGFloat radius;
@property (nonatomic) BOOL active;
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

typedef NS_ENUM(NSInteger, DmItemKind) { DmItemSetting, DmItemReset, DmItemRestart };
@interface DmRowView : UIView
- (instancetype)initWithSetting:(DmSetting *)s kind:(DmItemKind)kind compact:(BOOL)compact;   // setting is nil for the reset and restart rows
@property (nonatomic, readonly) DmSetting *setting;
@property (nonatomic, readonly) DmItemKind kind;
@property (nonatomic, readonly) DmSliderView *slider;
- (void)showValue:(NSString *)value source:(DmSettingSource)src;   // refresh from the store (env: the row is locked)
@property (nonatomic, readonly) BOOL locked;
- (void)shake;   // a refused change
- (CGFloat)heightForWidth:(CGFloat)w;
@end

@interface DmHintBar : UIView
- (void)setHints:(NSArray<NSArray<NSString *> *> *)hints;   // {glyph, text} pairs, laid out left to right and kept at the right edge
- (CGFloat)heightWithCompact:(BOOL)compact;
@end
