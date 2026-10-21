// Building blocks of the settings screen (see DmSettingsViews.h). Colours are dynamic (light / dark follows the system); layers take theirs through colorsUpdate, which runs again when the style changes.
#import "DmSettingsViews.h"

static UIColor *dyn(uint32_t light, uint32_t dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        uint32_t c = t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        return [UIColor colorWithRed:((c >> 16) & 255) / 255.0 green:((c >> 8) & 255) / 255.0 blue:(c & 255) / 255.0 alpha:1];
    }];
}
static CGColorRef cg(UIView *v, UIColor *c) { return [c resolvedColorWithTraitCollection:v.traitCollection].CGColor; }

@implementation DmUI
+ (UIColor *)bg { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0xEBEBEB, 0x2B2B2B); }); return c; }
+ (UIColor *)panel { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0xFFFFFF, 0x363636); }); return c; }
+ (UIColor *)row { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0xF3F3F3, 0x424242); }); return c; }
+ (UIColor *)text { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0x2D2D2D, 0xF2F2F2); }); return c; }
+ (UIColor *)sub { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0x777777, 0xA6A6A6); }); return c; }
+ (UIColor *)sep { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0xD6D6D6, 0x575757); }); return c; }
+ (UIColor *)accent { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0x00B9E6, 0x20D5FF); }); return c; }
+ (UIColor *)selected { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0xD2EEF7, 0x3E5059); }); return c; }
+ (UIColor *)warn { static UIColor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = dyn(0xE2502A, 0xFF7B54); }); return c; }
+ (UIFont *)font:(CGFloat)size weight:(UIFontWeight)w {
    UIFont *f = [UIFont systemFontOfSize:size weight:w];
    UIFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return d ? [UIFont fontWithDescriptor:d size:size] : f;
}
@end

// Runs a block when the light / dark style changes, and once now
static void on_style(UIView *v, void (^apply)(void)) {
    apply();
    [v registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withHandler:^(__kindof id<UITraitEnvironment> e, UITraitCollection *p) { (void)e; (void)p; apply(); }];
}

#pragma mark - Focus border

@implementation DmFocusView
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.userInteractionEnabled = NO; self.hidden = YES; _radius = 14;
        CALayer *l = self.layer; l.borderWidth = 3.5; l.cornerRadius = _radius; l.shadowOpacity = 0.85; l.shadowRadius = 7; l.shadowOffset = CGSizeZero;
        __weak DmFocusView *w = self;
        on_style(self, ^{ DmFocusView *s = w; s.layer.borderColor = cg(s, DmUI.accent); s.layer.shadowColor = cg(s, DmUI.accent); });
    }
    return self;
}
- (void)setRadius:(CGFloat)r { _radius = r; self.layer.cornerRadius = r; }
- (void)setActive:(BOOL)a {
    _active = a; self.hidden = !a;
    [self.layer removeAnimationForKey:@"pulse"];
    if (!a || UIAccessibilityIsReduceMotionEnabled()) return;
    CABasicAnimation *p = [CABasicAnimation animationWithKeyPath:@"opacity"];
    p.fromValue = @1; p.toValue = @0.5; p.duration = 0.7; p.autoreverses = YES; p.repeatCount = HUGE_VALF; p.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:p forKey:@"pulse"];
}
@end

#pragma mark - Toggle

@implementation DmToggleView { CALayer *_track, *_knob; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 54, 30)])) {
        _track = [CALayer layer]; _track.cornerRadius = 15; [self.layer addSublayer:_track];
        _knob = [CALayer layer]; _knob.backgroundColor = UIColor.whiteColor.CGColor; _knob.cornerRadius = 12; _knob.bounds = CGRectMake(0, 0, 24, 24);
        _knob.shadowColor = UIColor.blackColor.CGColor; _knob.shadowOpacity = 0.25; _knob.shadowRadius = 2; _knob.shadowOffset = CGSizeMake(0, 1);
        [self.layer addSublayer:_knob];
        self.userInteractionEnabled = NO;
        __weak DmToggleView *w = self; on_style(self, ^{ [w place:NO]; });
    }
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(54, 30); }
- (void)layoutSubviews { [super layoutSubviews]; _track.frame = self.bounds; [self place:NO]; }
- (void)place:(BOOL)animated {
    [CATransaction begin]; [CATransaction setDisableActions:!animated]; if (animated) [CATransaction setAnimationDuration:0.14];
    _track.backgroundColor = cg(self, _on ? DmUI.accent : DmUI.sep);
    _knob.position = CGPointMake(_on ? CGRectGetWidth(self.bounds) - 15 : 15, CGRectGetHeight(self.bounds) / 2);
    [CATransaction commit];
}
- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }
- (void)setOn:(BOOL)on animated:(BOOL)animated { if (on == _on && self.bounds.size.width > 0) return; _on = on; [self place:animated && self.window != nil]; }
@end

#pragma mark - Slider

@implementation DmSliderView { CALayer *_track, *_fill, *_knob; }
static const CGFloat kKnob = 26;
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _track = [CALayer layer]; _track.cornerRadius = 3; [self.layer addSublayer:_track];
        _fill = [CALayer layer]; _fill.cornerRadius = 3; [self.layer addSublayer:_fill];
        _knob = [CALayer layer]; _knob.backgroundColor = UIColor.whiteColor.CGColor; _knob.cornerRadius = kKnob / 2; _knob.bounds = CGRectMake(0, 0, kKnob, kKnob);
        _knob.shadowColor = UIColor.blackColor.CGColor; _knob.shadowOpacity = 0.3; _knob.shadowRadius = 3; _knob.shadowOffset = CGSizeMake(0, 1);
        _knob.borderWidth = 0.5; _knob.borderColor = [UIColor colorWithWhite:0 alpha:0.15].CGColor;
        [self.layer addSublayer:_knob];
        __weak DmSliderView *w = self; on_style(self, ^{ DmSliderView *s = w; s->_track.backgroundColor = cg(s, DmUI.sep); s->_fill.backgroundColor = cg(s, DmUI.accent); });
    }
    return self;
}
- (void)setValue:(CGFloat)v { _value = fmin(fmax(v, 0), 1); [self setNeedsLayout]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, x = kKnob / 2 + (w - kKnob) * _value;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _track.frame = CGRectMake(kKnob / 2, h / 2 - 3, w - kKnob, 6);
    _fill.frame = CGRectMake(kKnob / 2, h / 2 - 3, x - kKnob / 2, 6);
    _knob.position = CGPointMake(x, h / 2);
    [CATransaction commit];
}
- (void)pick:(UITouch *)t {
    CGFloat w = self.bounds.size.width - kKnob; if (w <= 0) return;
    CGFloat v = fmin(fmax(([t locationInView:self].x - kKnob / 2) / w, 0), 1);
    if (v != _value) { self.value = v; [self sendActionsForControlEvents:UIControlEventValueChanged]; }
}
- (BOOL)beginTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self pick:t]; return YES; }
- (BOOL)continueTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self pick:t]; return YES; }
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 34); }
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return CGRectContainsPoint(CGRectInset(self.bounds, -8, -10), p); }
@end

#pragma mark - Category cell

@implementation DmCategoryView { UIImageView *_icon; UILabel *_title; BOOL _compact; }
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)symbol compact:(BOOL)compact {
    if ((self = [super initWithFrame:CGRectZero])) {
        _compact = compact;
        self.layer.cornerRadius = compact ? 12 : 16;
        UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:compact ? 17 : 22 weight:UIImageSymbolWeightSemibold];
        _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:c] ?: [UIImage systemImageNamed:@"gearshape" withConfiguration:c]];
        _icon.contentMode = UIViewContentModeCenter; _icon.userInteractionEnabled = NO;
        _title = [UILabel new]; _title.text = title; _title.font = [DmUI font:compact ? 15 : 19 weight:UIFontWeightSemibold]; _title.userInteractionEnabled = NO;
        _title.adjustsFontSizeToFitWidth = YES; _title.minimumScaleFactor = 0.8;
        [self addSubview:_icon]; [self addSubview:_title];
        __weak DmCategoryView *w = self; on_style(self, ^{ [w paint]; });
    }
    return self;
}
- (void)paint {
    BOOL fill = _chosen;   // the ring marks the choice while the focus is on the list; once it is in the pane the choice keeps a soft fill
    self.layer.backgroundColor = fill ? cg(self, _paneFocused ? DmUI.selected : DmUI.panel) : UIColor.clearColor.CGColor;
    UIColor *t = _chosen ? DmUI.text : DmUI.sub; _title.textColor = t; _icon.tintColor = _chosen ? DmUI.accent : DmUI.sub;
}
- (void)setChosen:(BOOL)c { _chosen = c; [self paint]; }
- (void)setPaneFocused:(BOOL)p { _paneFocused = p; [self paint]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat pad = _compact ? 10 : 18, iw = _compact ? 24 : 32, h = self.bounds.size.height;
    _icon.frame = CGRectMake(pad, 0, iw, h);
    _title.frame = CGRectMake(pad + iw + (_compact ? 6 : 10), 0, self.bounds.size.width - pad * 2 - iw - 10, h);
}
@end

#pragma mark - Row

@implementation DmRowView {
    BOOL _compact; DmItemKind _kind; DmSetting *_setting;
    UILabel *_title, *_detail, *_value, *_note; UIImageView *_chev[2];
    DmToggleView *_toggle; DmSliderView *_slider;
    NSString *_noteText; BOOL _locked;
}
- (DmSetting *)setting { return _setting; }
- (DmItemKind)kind { return _kind; }
- (DmSliderView *)slider { return _slider; }
- (BOOL)locked { return _locked; }
- (instancetype)initWithSetting:(DmSetting *)s kind:(DmItemKind)kind compact:(BOOL)compact {
    if ((self = [super initWithFrame:CGRectZero])) {
        _setting = s; _kind = kind; _compact = compact;
        self.layer.cornerRadius = compact ? 12 : 16;
        _title = [UILabel new]; _title.font = [DmUI font:compact ? 16 : 19 weight:UIFontWeightSemibold];
        _detail = [UILabel new]; _detail.font = [DmUI font:compact ? 12 : 14 weight:UIFontWeightRegular]; _detail.numberOfLines = 0;
        _value = [UILabel new]; _value.font = [DmUI font:compact ? 15 : 18 weight:UIFontWeightSemibold]; _value.textAlignment = NSTextAlignmentRight;
        _note = [UILabel new]; _note.font = [DmUI font:compact ? 11 : 13 weight:UIFontWeightSemibold]; _note.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[_title, _detail, _value, _note]) { v.userInteractionEnabled = NO; [self addSubview:v]; }
        if (kind == DmItemSetting) {
            _title.text = s.label; _detail.text = s.detail;
            if (s.type == DmSettingToggle) { _toggle = [DmToggleView new]; [self addSubview:_toggle]; }
            if (s.type == DmSettingSlider) { _slider = [DmSliderView new]; [self addSubview:_slider]; }
            if (s.type == DmSettingChoice) {
                UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:compact ? 12 : 14 weight:UIImageSymbolWeightBold];
                for (int i = 0; i < 2; i++) { _chev[i] = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:i ? @"chevron.right" : @"chevron.left" withConfiguration:c]]; _chev[i].contentMode = UIViewContentModeCenter; [self addSubview:_chev[i]]; }
            }
            _noteText = s.restart ? @"Applies after a restart" : nil;
        } else {
            _title.textAlignment = NSTextAlignmentCenter; _detail.textAlignment = NSTextAlignmentCenter;
            _title.text = kind == DmItemReset ? @"Restore defaults" : @"Restart now";
            _detail.text = kind == DmItemReset ? @"Puts every setting on this page back to its default." : @"Closes the game so the changed settings apply on the next start. Progress that was not saved in the game is lost.";
        }
        __weak DmRowView *w = self; on_style(self, ^{ [w paint]; });
    }
    return self;
}
- (void)paint {
    self.layer.backgroundColor = cg(self, DmUI.row);
    _title.textColor = _kind == DmItemSetting ? DmUI.text : (_kind == DmItemReset ? DmUI.accent : DmUI.warn);
    _detail.textColor = DmUI.sub; _value.textColor = _locked ? DmUI.sub : DmUI.accent;
    _note.textColor = DmUI.warn;
    for (int i = 0; i < 2; i++) _chev[i].tintColor = DmUI.sub;
    self.alpha = _locked ? 0.62 : 1;
}
- (void)showValue:(NSString *)v source:(DmSettingSource)src {
    _locked = src == DmSourceEnv;
    _note.text = _locked ? @"Set in env.txt" : _noteText;
    if (_setting.type == DmSettingToggle) { _toggle.on = [v isEqualToString:@"1"]; _value.text = nil; }
    else if (_setting) _value.text = [_setting displayValue:v];
    if (_slider) _slider.value = (v.doubleValue - _setting.min) / (_setting.max - _setting.min);
    [self paint]; [self setNeedsLayout];
}
- (void)shake {
    CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    k.values = @[@0, @-7, @7, @-4, @4, @0]; k.duration = 0.25; [self.layer addAnimation:k forKey:@"shake"];
}
// Frames of the parts for a width; the height is the sum
typedef struct { CGRect title, detail, value, note, toggle, slider, chevL, chevR; CGFloat height; } RowLayout;
- (RowLayout)layoutForWidth:(CGFloat)w {
    RowLayout L = {0}; CGFloat padX = _compact ? 14 : 22, padY = _compact ? 11 : 16, gap = 4, x1 = w - padX, cw = w - padX * 2;
    BOOL plain = _kind != DmItemSetting;
    CGFloat right = 0;   // width of what sits right of the title: the value, the toggle, the chevrons
    if (_toggle) right = 54;
    else if (_setting.type == DmSettingChoice) right = ceil([_value.text sizeWithAttributes:@{NSFontAttributeName: _value.font}].width) + (_compact ? 44 : 52);
    else if (_slider) right = ceil([@"100%" sizeWithAttributes:@{NSFontAttributeName: _value.font}].width) + 8;
    CGFloat tw = cw - (right ? right + 12 : 0), th = ceil(_title.font.lineHeight), y = padY;
    L.title = CGRectMake(padX, y, plain ? cw : tw, th);
    CGFloat noteW = 0; if (_note.text.length) { noteW = ceil([_note.text sizeWithAttributes:@{NSFontAttributeName: _note.font}].width); }
    if (_toggle) L.toggle = CGRectMake(x1 - 54, y + (th - 30) / 2 + (_compact ? 0 : 0), 54, 30);
    else if (_setting.type == DmSettingChoice) {
        CGFloat cs = _compact ? 16 : 20; L.chevR = CGRectMake(x1 - cs, y + (th - cs) / 2, cs, cs); L.chevL = CGRectMake(x1 - right + 4, y + (th - cs) / 2, cs, cs);
        L.value = CGRectMake(L.chevL.origin.x + cs, y, L.chevR.origin.x - L.chevL.origin.x - cs, th);
    } else if (_slider) L.value = CGRectMake(x1 - right + 8, y, right - 8, th);
    y += th;
    if (noteW && !plain) { L.note = CGRectMake(padX, y + 1, cw, ceil(_note.font.lineHeight)); y += ceil(_note.font.lineHeight) + 1; }
    if (_detail.text.length) {
        CGFloat dw = plain ? cw : (_slider ? cw : cw - (right ? right + 12 : 0));
        CGSize ds = [_detail sizeThatFits:CGSizeMake(dw, CGFLOAT_MAX)];
        L.detail = CGRectMake(padX, y + gap, dw, ceil(ds.height)); y += gap + ceil(ds.height);
    }
    if (_slider) { y += _compact ? 6 : 10; L.slider = CGRectMake(padX, y, cw, 34); y += 34; }
    L.height = y + padY;
    CGFloat minH = _compact ? 50 : 64; if (L.height < minH) { CGFloat d = (minH - L.height) / 2; if (!_slider) { for (CGRect *r = &L.title; r <= &L.chevR; r++) if (!CGRectIsEmpty(*r)) r->origin.y += d; } L.height = minH; }
    return L;
}
- (CGFloat)heightForWidth:(CGFloat)w { return [self layoutForWidth:w].height; }
- (void)layoutSubviews {
    [super layoutSubviews];
    RowLayout L = [self layoutForWidth:self.bounds.size.width];
    _title.frame = L.title; _detail.frame = L.detail; _value.frame = L.value; _note.frame = L.note; _note.textAlignment = NSTextAlignmentLeft;
    _toggle.frame = L.toggle; _slider.frame = L.slider; _chev[0].frame = L.chevL; _chev[1].frame = L.chevR;
    _detail.hidden = _detail.text.length == 0; _note.hidden = _kind != DmItemSetting || !_note.text.length; _value.hidden = _toggle != nil || !_setting;
    if (_note.hidden == NO && !_locked) _note.frame = L.note;
}
@end

#pragma mark - Hint bar

@implementation DmHintBar { NSArray<NSArray<NSString *> *> *_hints; NSMutableArray<UIView *> *_parts; BOOL _compact; }
- (instancetype)initWithFrame:(CGRect)f { if ((self = [super initWithFrame:f])) { _parts = [NSMutableArray array]; self.userInteractionEnabled = NO; } return self; }
- (CGFloat)heightWithCompact:(BOOL)c { _compact = c; return c ? 30 : 40; }
- (void)setHints:(NSArray<NSArray<NSString *> *> *)h {
    _hints = h; for (UIView *v in _parts) [v removeFromSuperview]; [_parts removeAllObjects];
    for (NSArray<NSString *> *p in h) {
        UILabel *g = [UILabel new]; g.text = p[0]; g.textAlignment = NSTextAlignmentCenter; g.layer.masksToBounds = YES; g.tag = 1;
        UILabel *t = [UILabel new]; t.text = p[1]; t.tag = 2;
        [self addSubview:g]; [self addSubview:t]; [_parts addObject:g]; [_parts addObject:t];
        __weak UILabel *wg = g, *wt = t; on_style(self, ^{ wg.textColor = DmUI.bg; wg.backgroundColor = DmUI.text; wt.textColor = DmUI.text; });
    }
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, fs = _compact ? 12 : 15, gs = _compact ? 22 : 28, x = self.bounds.size.width;
    for (NSInteger i = (NSInteger)_parts.count - 2; i >= 0; i -= 2) {   // from the right edge inward
        UILabel *g = (UILabel *)_parts[i], *t = (UILabel *)_parts[i + 1];
        g.font = [DmUI font:fs weight:UIFontWeightBold]; t.font = [DmUI font:fs + 1 weight:UIFontWeightSemibold];
        CGFloat tw = ceil([t.text sizeWithAttributes:@{NSFontAttributeName: t.font}].width), gw = fmax(gs, ceil([g.text sizeWithAttributes:@{NSFontAttributeName: g.font}].width) + 12);
        x -= tw; t.frame = CGRectMake(x, 0, tw, h);
        x -= 8 + gw; g.frame = CGRectMake(x, (h - gs) / 2, gw, gs); g.layer.cornerRadius = gs / 2;
        x -= _compact ? 14 : 22;
    }
}
@end
