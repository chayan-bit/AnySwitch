// Quick Settings (HearthQuickVC.h). The rows are the settings screen's own (DmRowView): two from the registry (Volume, Console mode), a brightness slider of our own, and two actions
#import "HearthQuickVC.h"
#import "HearthSound.h"
#import "DmSettings.h"
#import "DmSettingsViews.h"
#import "DmPadBits.h"
#import "DmRepeat.h"
#import <AVKit/AVKit.h>

#define QUICK_INSET 20.0   // the panel keeps this distance from the top, bottom and right edge of the screen

enum { RowVolume, RowBrightness, RowMode, RowOutput, RowSleep, RowCount };

@implementation HearthQuickVC {
    UIView *_dim, *_panel; UIScrollView *_scroll; UILabel *_head, *_battery; NSArray<DmRowView *> *_rows; DmFocusView *_ring; AVRoutePickerView *_route;
    DmSetting *_bright; NSInteger _row; BOOL _closing, _baselined, _ringShown; uint64_t _prev; DmRepeat *_repeat;
}

static UIScreen *screen_of(UIView *v) { return v.window.windowScene.screen; }

- (void)viewDidLoad {
    [super viewDidLoad];
    DmSettings *st = DmSettings.systemStore;
    _repeat = [DmRepeat new]; self.view.accessibilityViewIsModal = YES;
    _dim = [UIView new]; _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    _panel = [UIView new]; _panel.layer.cornerRadius = 26; _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.layer.shadowOpacity = 0.28; _panel.layer.shadowRadius = 26; _panel.layer.shadowOffset = CGSizeMake(-4, 8);   // a card floating at an even distance from the screen's edges, its four corners rounded
    _head = [UILabel new]; _head.text = @"Quick Settings"; _head.font = [DmUI font:_compact ? 22 : 28 weight:UIFontWeightBold]; _head.textColor = DmUI.text;
    _battery = [UILabel new]; _battery.font = [DmUI font:_compact ? 13 : 16 weight:UIFontWeightMedium]; _battery.textColor = DmUI.sub;
    _bright = [DmSetting settingFromDictionary:@{@"key": @"HEARTH_BRIGHTNESS", @"label": @"Brightness", @"detail": @"The screen's brightness.", @"type": @"slider",
                                                 @"min": @0, @"max": @1, @"step": @0.05, @"scale": @100, @"suffix": @"%", @"default": @"0.5"} error:nil];
    DmRowView *vol = [[DmRowView alloc] initWithSetting:[st settingForKey:@"DM_VOLUME"] kind:DmItemSetting compact:_compact];
    DmRowView *bri = [[DmRowView alloc] initWithSetting:_bright kind:DmItemSetting compact:_compact];
    DmRowView *mode = [[DmRowView alloc] initWithSetting:[st settingForKey:@"DM_OPMODE"] kind:DmItemSetting compact:_compact];
    DmRowView *out = [[DmRowView alloc] initWithAction:@"Audio output" detail:@"Speaker, headphones or AirPlay." compact:_compact];
    DmRowView *slp = [[DmRowView alloc] initWithAction:@"Sleep" detail:@"Turns the screen black. A touch, a key or a button wakes it." compact:_compact];
    _rows = @[vol, bri, mode, out, slp];
    _route = [AVRoutePickerView new]; _route.activeTintColor = DmUI.accentText; _route.tintColor = DmUI.sub; _route.prioritizesVideoDevices = NO;
    [out addSubview:_route];
    _ring = [DmFocusView new]; _ring.radius = _compact ? 14 : 19;
    _scroll = [UIScrollView new]; _scroll.showsVerticalScrollIndicator = NO; _scroll.alwaysBounceVertical = NO; _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;   // the rows scroll where a short screen cannot hold them all
    [self.view addSubview:_dim]; [self.view addSubview:_panel];
    for (UIView *v in @[_head, _battery, _scroll]) [_panel addSubview:v];
    for (DmRowView *r in _rows) {
        [r addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rowTapped:)]];
        if (r.slider) [r.slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_scroll addSubview:r];
    }
    [_scroll addSubview:_ring];
    __weak HearthQuickVC *w = self; dm_on_style(_panel, ^{ HearthQuickVC *s = w; if (s) s->_panel.backgroundColor = DmUI.panel; });
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:UIScreenBrightnessDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_repeat stop]; }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self refresh]; }
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a]; [self becomeFirstResponder]; [self refresh];
    CGFloat w = _panel.bounds.size.width + QUICK_INSET * 2; _panel.transform = CGAffineTransformMakeTranslation(w, 0); _dim.alpha = 0;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ self->_panel.transform = CGAffineTransformIdentity; self->_dim.alpha = 1; } completion:nil];
    fprintf(stderr, "hearth: Quick Settings open\n");
}
- (BOOL)canBecomeFirstResponder { return YES; }

- (void)refresh {
    DmSettings *st = DmSettings.systemStore;
    for (NSInteger i = 0; i < RowCount; i++) {
        DmRowView *r = _rows[(NSUInteger)i];
        if (i == RowBrightness) [r showValue:[NSString stringWithFormat:@"%g", round(screen_of(self.view).brightness * 20) / 20] source:DmSourceUser disabledNote:nil];
        else if (r.setting) [r showValue:[st valueForKey:r.setting.key] source:[st sourceForKey:r.setting.key] disabledNote:nil];
    }
    UIDevice *d = UIDevice.currentDevice; float lv = d.batteryLevel;
    BOOL charging = d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull;
    _battery.text = lv < 0 ? nil : [NSString stringWithFormat:@"Battery %.0f%%%@", lv * 100, charging ? @", charging" : @""];
    [self.view setNeedsLayout];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; UIEdgeInsets si = self.view.safeAreaInsets;
    CGFloat pw = _compact ? MIN(340, b.size.width * 0.45) : MIN(480, MAX(380, b.size.width * 0.38)), pad = _compact ? 16 : 28, m = _compact ? 12 : QUICK_INSET, rowGap = _compact ? 8 : 12, glow = 8;
    _dim.frame = b;
    CGAffineTransform t = _panel.transform; _panel.transform = CGAffineTransformIdentity;
    _panel.frame = CGRectMake(b.size.width - MAX(si.right, 0) - m - pw, MAX(si.top, 0) + m, pw, b.size.height - MAX(si.top, 0) - MAX(si.bottom, 0) - 2 * m);   // the same gap above, below and at the right
    _panel.layer.cornerRadius = _compact ? 20 : 26;
    _panel.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_panel.bounds cornerRadius:_panel.layer.cornerRadius].CGPath;
    _panel.transform = t;
    CGFloat w = pw - pad * 2, y = _compact ? pad - 4 : pad, hh = _compact ? 30 : 40, bh = _compact ? 18 : 22;
    _head.frame = CGRectMake(pad, y, w, hh); y += hh + 2;
    _battery.frame = CGRectMake(pad, y, w, bh); y += bh + (_compact ? 8 : 12);
    _scroll.frame = CGRectMake(0, y - glow, pw, _panel.bounds.size.height - y + glow);   // starts a glow's width above the first row, which the focus ring needs
    CGFloat ry = glow;
    for (DmRowView *r in _rows) { CGFloat rh = [r heightForWidth:w]; r.frame = CGRectMake(pad, ry, w, rh); ry += rh + rowGap; }
    _scroll.contentSize = CGSizeMake(pw, ry - rowGap + glow + pad);
    DmRowView *out = _rows[RowOutput]; _route.frame = CGRectMake(out.bounds.size.width - 64, (out.bounds.size.height - 44) / 2, 44, 44);
    [self placeRing:NO];
}
- (void)placeRing:(BOOL)animated {
    static const CGFloat glow_ = 8;
    CGRect f = CGRectInset(_rows[(NSUInteger)_row].frame, -3, -3);
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) [UIView animateWithDuration:0.13 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{ self->_ring.frame = f; } completion:nil];
    else _ring.frame = f;
    _ring.active = _ringShown;
    [_scroll scrollRectToVisible:CGRectInset(f, 0, -glow_) animated:animated];   // the focused row stays on screen
}

#pragma mark - Changes

- (void)setBrightness:(double)v {   // the only place Hearth changes the screen's brightness: the player moved it
    v = MIN(MAX(v, 0), 1); screen_of(self.view).brightness = v;
    fprintf(stderr, "hearth: brightness %.2f\n", v); [self refresh];
}
- (void)adjust:(NSInteger)i by:(int)dir {
    DmRowView *r = _rows[(NSUInteger)i]; DmSettings *st = DmSettings.systemStore;
    if (i == RowBrightness) { [self setBrightness:screen_of(self.view).brightness + dir * _bright.step]; return; }
    DmSetting *s = r.setting; if (!s) return;
    NSString *cur = [st valueForKey:s.key], *v = nil;
    if (s.type == DmSettingSlider) v = [NSString stringWithFormat:@"%g", cur.doubleValue + dir * s.step];
    else if (s.type == DmSettingChoice) {
        NSInteger n = (NSInteger)s.options.count, k = 0;
        for (NSInteger j = 0; j < n; j++) if ([s.options[(NSUInteger)j][@"value"] isEqualToString:cur]) k = j;
        v = s.options[(NSUInteger)((k + dir + n) % n)][@"value"];
    }
    if (!v || ![st setValue:v forKey:s.key]) [r shake];
    [self refresh];
}
- (void)activate:(NSInteger)i {
    switch (i) {
        case RowMode: [self adjust:i by:1]; break;
        case RowOutput:   // AVRoutePickerView has no call that opens it: press its own button
            for (UIView *v in _route.subviews) if ([v isKindOfClass:UIButton.class]) [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            break;
        case RowSleep: { void (^s)(void) = self.onSleep; [self dismissThen:^{ if (s) s(); }]; break; }
        default: break;
    }
}
- (void)focus:(NSInteger)i { if (i != _row) hearth_sound(HearthSoundMove); _row = MIN(MAX(i, 0), RowCount - 1); [self placeRing:YES]; }

#pragma mark - Close

- (void)close { [self dismissThen:nil]; }
- (void)dismissThen:(void (^)(void))then {
    if (_closing) return;
    _closing = YES; [_repeat stop]; hearth_sound(HearthSoundBack);
    fprintf(stderr, "hearth: Quick Settings closed\n");
    void (^done)(void) = self.onClose;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ self->_panel.transform = CGAffineTransformMakeTranslation(self->_panel.bounds.size.width + QUICK_INSET * 2, 0); self->_dim.alpha = 0; }
                     completion:^(BOOL f) { (void)f; if (done) done(); if (then) then(); }];
}

#pragma mark - Touch

- (void)rowTapped:(UITapGestureRecognizer *)g {
    DmRowView *r = (DmRowView *)g.view; NSUInteger i = [_rows indexOfObject:r]; if (i == NSNotFound) return;
    if (r.slider && CGRectContainsPoint(CGRectInset(r.slider.frame, 0, -10), [g locationInView:r])) return;
    _ringShown = NO; _row = (NSInteger)i; [self placeRing:NO];
    [self activate:(NSInteger)i];
}
- (void)sliderChanged:(DmSliderView *)s {
    NSUInteger i = [_rows indexOfObject:(DmRowView *)s.superview]; if (i == NSNotFound) return;
    _ringShown = NO; _row = (NSInteger)i; [self placeRing:NO];
    if (i == RowBrightness) { [self setBrightness:s.value]; return; }
    DmSetting *st = _rows[i].setting;
    [DmSettings.systemStore setValue:[NSString stringWithFormat:@"%g", st.min + s.value * (st.max - st.min)] forKey:st.key];
    [self refresh];
}

#pragma mark - Controller and keyboard

- (void)step:(int)d {   // 1 up, 2 down, 3 left, 4 right
    _ringShown = YES;
    if (d <= 2) [self focus:_row + (d == 2 ? 1 : -1)];
    else if (_row == RowVolume || _row == RowBrightness || _row == RowMode) [self adjust:_row by:d == 4 ? 1 : -1];
    [self placeRing:YES];
}
- (void)padState:(uint64_t)m lx:(int32_t)lx ly:(int32_t)ly {
    int d = m & 1ull << DMB_UP || ly > 20000 ? 1 : m & 1ull << DMB_DOWN || ly < -20000 ? 2 : m & 1ull << DMB_LEFT || lx < -20000 ? 3 : m & 1ull << DMB_RIGHT || lx > 20000 ? 4 : 0;
    uint64_t want = m & (1ull << DMB_A | 1ull << DMB_B);
    if (!_baselined) { _baselined = YES; _prev = want; if (d) [_repeat hold:d step:nil]; return; }
    uint64_t up = want & ~_prev; _prev = want;
    if (d != _repeat.held) {
        [_repeat stop];
        if (d) { [self step:d]; __weak HearthQuickVC *w = self; [_repeat hold:d step:^NSTimeInterval { [w step:d]; return d >= 3 ? 0.07 : DM_REPEAT_NEXT; }]; }
    }
    if (up & 1ull << DMB_A) { _ringShown = YES; [self placeRing:NO]; [self activate:_row]; }
    if (up & 1ull << DMB_B) [self close];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray *r = [NSMutableArray array];
    for (NSArray *p in @[@[UIKeyInputUpArrow, @"keyUp"], @[UIKeyInputDownArrow, @"keyDown"], @[UIKeyInputLeftArrow, @"keyLeft"], @[UIKeyInputRightArrow, @"keyRight"], @[@"\r", @"keyReturn"], @[UIKeyInputEscape, @"close"]]) {
        UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:p[0] modifierFlags:0 action:NSSelectorFromString(p[1])]; c.wantsPriorityOverSystemBehavior = YES; [r addObject:c];
    }
    return r;
}
- (void)keyUp { [self step:1]; }
- (void)keyDown { [self step:2]; }
- (void)keyLeft { [self step:3]; }
- (void)keyRight { [self step:4]; }
- (void)keyReturn { _ringShown = YES; [self placeRing:NO]; [self activate:_row]; }
@end
