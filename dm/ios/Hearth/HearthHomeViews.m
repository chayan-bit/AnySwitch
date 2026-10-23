// Home's pieces (HearthHomeViews.h). Colours come from DmUI (light and dark follow the system), sizes from HearthTheme.h
#import "HearthHomeViews.h"
#import "HearthTheme.h"
#import "DmSettingsViews.h"
#import <CoreText/CoreText.h>
#include "boot.h"

NSString *hearth_state_line(HearthGame *g) {
    switch (g.reason) {
        case 0: return nil;
        case DM_PACK_REBUILD: return @"Rebuild needed";
        case DM_PACK_MISSING: return @"Incomplete";
        case HEARTH_NEEDS_SIGNING: return @"Needs signing";
        default: return @"Not a game";
    }
}

static UIFont *tabular(UIFont *f) {   // digits of equal width, so the clock and the percentage do not jitter
    UIFontDescriptor *d = [f.fontDescriptor fontDescriptorByAddingAttributes:@{UIFontDescriptorFeatureSettingsAttribute:
        @[@{UIFontFeatureTypeIdentifierKey: @(kNumberSpacingType), UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)}]}];
    return [UIFont fontWithDescriptor:d size:f.pointSize];
}

#define NAME_H 56.0    // room above the art for the focused game's name
#define STATE_H 44.0   // room below it for the state line

@implementation HearthTile {
    UIImageView *_image; UILabel *_name, *_state;
}
+ (CGFloat)nameHeight { return NAME_H; }
+ (CGFloat)stateHeight { return STATE_H; }
- (instancetype)initWithGame:(HearthGame *)g size:(CGFloat)size {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, size, NAME_H + size + STATE_H)])) return nil;
    _game = g; _size = size;
    _art = [[UIView alloc] initWithFrame:CGRectMake(0, NAME_H, size, size)];
    _art.userInteractionEnabled = NO; _art.layer.shadowOpacity = 0.28; _art.layer.shadowRadius = 18; _art.layer.shadowOffset = CGSizeMake(0, 8);
    _art.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_art.bounds cornerRadius:HEARTH_TILE_RADIUS].CGPath;
    _image = [[UIImageView alloc] initWithFrame:_art.bounds];
    _image.layer.cornerRadius = HEARTH_TILE_RADIUS; _image.layer.cornerCurve = kCACornerCurveContinuous; _image.clipsToBounds = YES; _image.contentMode = UIViewContentModeScaleAspectFill;
    UIImage *icon = g.iconPath ? [UIImage imageWithContentsOfFile:g.iconPath] : nil;
    if (icon) _image.image = icon;
    else {   // no icon: the game controller symbol on a quiet card
        _image.image = [UIImage systemImageNamed:@"gamecontroller.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size * 0.3 weight:UIImageSymbolWeightRegular]];
        _image.contentMode = UIViewContentModeCenter; _image.tintColor = DmUI.sub; _image.backgroundColor = DmUI.row;
    }
    [_art addSubview:_image];
    _name = [[UILabel alloc] initWithFrame:CGRectMake(-40, 8, size + 80, 36)];
    _name.text = g.name; _name.font = [DmUI font:26 weight:UIFontWeightSemibold]; _name.textColor = DmUI.text; _name.textAlignment = NSTextAlignmentCenter; _name.alpha = 0;
    _name.adjustsFontSizeToFitWidth = YES; _name.minimumScaleFactor = 0.75; _name.lineBreakMode = NSLineBreakByTruncatingTail;
    _state = [[UILabel alloc] initWithFrame:CGRectMake(0, NAME_H + size + 8, size, STATE_H - 8)];
    _state.text = hearth_state_line(g); _state.font = [DmUI font:19 weight:UIFontWeightSemibold]; _state.textColor = DmUI.warn; _state.textAlignment = NSTextAlignmentCenter;
    for (UIView *v in @[_art, _name, _state]) [self addSubview:v];
    if (g.reason) _image.alpha = 0.45;   // a game that cannot start stays in the row, dimmed, and says why
    self.isAccessibilityElement = YES; self.accessibilityLabel = g.name; self.accessibilityValue = hearth_state_line(g); self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}
- (void)setPlaying:(BOOL)p {
    _playing = p;
    _state.text = p ? @"Playing" : hearth_state_line(_game); _state.textColor = p ? DmUI.accentText : DmUI.warn;
    self.accessibilityValue = _state.text;
}
- (void)setChosen:(BOOL)f { [self setChosen:f animated:NO]; }
- (void)setChosen:(BOOL)f animated:(BOOL)animated {
    _chosen = f;
    void (^apply)(void) = ^{
        CGFloat s = f ? hearth_tile_focus_scale(self->_size) : 1, grow = (s - 1) * self->_size / 2;
        self->_art.transform = CGAffineTransformMakeScale(s, s);
        self->_name.alpha = f; self->_name.transform = CGAffineTransformMakeTranslation(0, f ? -grow : 0);   // both lines stay clear of the grown art
        self->_state.transform = CGAffineTransformMakeTranslation(0, f ? grow : 0);
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) [UIView animateWithDuration:HEARTH_FOCUS_SECONDS delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
    else apply();
}
@end

@implementation HearthRoundButton {
    UIImageView *_icon;
}
- (instancetype)initWithSymbol:(NSString *)symbol label:(NSString *)label {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, HEARTH_BUTTON_SIZE, HEARTH_BUTTON_SIZE)])) return nil;
    self.layer.cornerRadius = HEARTH_BUTTON_SIZE / 2;
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium]]];
    _icon.tintColor = DmUI.text; _icon.center = CGPointMake(HEARTH_BUTTON_SIZE / 2, HEARTH_BUTTON_SIZE / 2); _icon.userInteractionEnabled = NO;
    [self addSubview:_icon];
    __weak HearthRoundButton *w = self; dm_on_style(self, ^{ w.backgroundColor = DmUI.row; });
    self.accessibilityLabel = label; self.isAccessibilityElement = YES; self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}
@end

@implementation HearthTopBar {
    UILabel *_player, *_clock, *_battery; UIImageView *_cell; NSMutableArray<UIButton *> *_avatars; NSDateFormatter *_fmt; NSTimer *_tick;
}
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _avatars = [NSMutableArray array];
    _player = [UILabel new]; _player.font = [DmUI font:20 weight:UIFontWeightSemibold]; _player.textColor = DmUI.text;
    _clock = [UILabel new]; _clock.font = tabular([DmUI font:22 weight:UIFontWeightSemibold]); _clock.textColor = DmUI.text; _clock.textAlignment = NSTextAlignmentRight;
    _battery = [UILabel new]; _battery.font = tabular([DmUI font:17 weight:UIFontWeightMedium]); _battery.textColor = DmUI.sub; _battery.textAlignment = NSTextAlignmentRight;
    _cell = [UIImageView new]; _cell.tintColor = DmUI.sub;
    for (UIView *v in @[_player, _clock, _battery, _cell]) [self addSubview:v];
    _fmt = [NSDateFormatter new]; _fmt.locale = NSLocale.currentLocale; [_fmt setLocalizedDateFormatFromTemplate:@"jmm"];
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    for (NSNotificationName n in @[UIDeviceBatteryLevelDidChangeNotification, UIDeviceBatteryStateDidChangeNotification])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:n object:nil];
    __weak HearthTopBar *w = self;
    _tick = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) { HearthTopBar *s = w; if (!s) [t invalidate]; else [s refresh]; }];
    [self refresh];
    return self;
}
- (void)dealloc { [_tick invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)setUsers:(NSArray<UIImage *> *)pictures names:(NSArray<NSString *> *)names {
    for (UIButton *b in _avatars) [b removeFromSuperview];
    [_avatars removeAllObjects];
    for (NSUInteger i = 0; i < pictures.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; [b setImage:pictures[i] forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFill; b.clipsToBounds = YES; b.layer.cornerRadius = 18; b.tag = (NSInteger)i;
        b.accessibilityLabel = i < names.count ? names[i] : nil;
        [b addTarget:self action:@selector(avatarTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b]; [_avatars addObject:b];
    }
    _player.text = names.count == 1 ? names[0] : nil;   // several users: their pictures say who is here
    [self setNeedsLayout];
}
- (void)avatarTapped:(UIButton *)b { if (self.onUser) self.onUser(b.tag); }
- (void)refresh {
    _clock.text = [_fmt stringFromDate:NSDate.date];
    float level = UIDevice.currentDevice.batteryLevel; UIDeviceBatteryState st = UIDevice.currentDevice.batteryState;
    BOOL known = level >= 0;
    _battery.text = known ? [NSString stringWithFormat:@"%.0f%%", level * 100] : nil;
    NSString *sym = st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull ? @"battery.100percent.bolt"
        : level > 0.87 ? @"battery.100percent" : level > 0.62 ? @"battery.75percent" : level > 0.37 ? @"battery.50percent" : level > 0.12 ? @"battery.25percent" : @"battery.0percent";
    _cell.image = known ? [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular]] : nil;
    _cell.hidden = !known;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    CGFloat ax = 0; for (UIButton *b in _avatars) { b.frame = CGRectMake(ax, (h - 36) / 2, 36, 36); ax += 44; }
    _player.frame = CGRectMake(ax + 4, 0, MAX(0, w / 2 - ax - 4), h);
    [_battery sizeToFit]; [_clock sizeToFit];
    CGFloat x = w;
    if (!_cell.hidden) { x -= 34; _cell.frame = CGRectMake(x, (h - 22) / 2, 34, 22); _cell.contentMode = UIViewContentModeScaleAspectFit; }
    if (_battery.text) { x -= _battery.bounds.size.width + 6; _battery.frame = CGRectMake(x, 0, _battery.bounds.size.width, h); }
    x -= _clock.bounds.size.width + 22; _clock.frame = CGRectMake(x, 0, _clock.bounds.size.width, h);
}
@end
