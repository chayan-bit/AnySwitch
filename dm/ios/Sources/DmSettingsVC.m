// The settings screen (see DmSettingsVC.h). Two focus levels: the category list and the rows of the chosen category; one cyan border per level, moved with a short animation.
// All data comes from DmSettings (the registry): the screen knows no setting by name.
#import "DmSettingsVC.h"
#import "DmSettingsViews.h"
#import "DmPadBits.h"
#import <objc/runtime.h>

@interface DmSettingsVC () <UITextFieldDelegate>
@end
static void on_trait(UIView *v, void (^apply)(void));
typedef NS_ENUM(NSInteger, Dir) { DirNone = 0, DirUp, DirDown, DirLeft, DirRight };

@implementation DmSettingsVC {
    DmSettings *_settings; BOOL _compact; NSArray<DmSection *> *_secs; BOOL _editing, _armed;   // _secs: the pages this build has; _editing: the text editor is up; _armed: restore-all waits for a second tap
    NSInteger _section, _row; BOOL _inPane;
    NSMutableArray<DmCategoryView *> *_cats; NSMutableArray<DmRowView *> *_rows; BOOL _hasRestartRow;
    UILabel *_head, *_paneTitle; UIButton *_close; UIView *_catBox, *_panel, *_clip; UIScrollView *_scroll; DmHintBar *_hints;
    DmFocusView *_catRing, *_rowRing;
    uint64_t _prev; BOOL _baselined; Dir _held; NSTimer *_repeat; NSInteger _hintMode;
}
- (instancetype)initWithSettings:(DmSettings *)s size:(CGSize)size {
    if ((self = [super initWithNibName:nil bundle:nil])) { _settings = s; _secs = s.visibleSections; _compact = MIN(size.width, size.height) < 500; _rows = [NSMutableArray array]; _cats = [NSMutableArray array]; _hintMode = -1; }
    return self;
}
- (NSInteger)section { return _section; }
- (BOOL)canBecomeFirstResponder { return YES; }

#pragma mark - Build

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *v = self.view; v.backgroundColor = DmUI.bg;
    _head = [UILabel new]; _head.text = @"Settings"; _head.font = [DmUI font:_compact ? 22 : 34 weight:UIFontWeightBold]; _head.textColor = DmUI.text;
    _close = [UIButton buttonWithType:UIButtonTypeSystem];
    [_close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:_compact ? 14 : 17 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    _close.tintColor = DmUI.sub; _close.layer.cornerRadius = 22; _close.accessibilityLabel = @"Close settings";
    [_close addTarget:self action:@selector(requestClose) forControlEvents:UIControlEventTouchUpInside];
    _catBox = [UIView new]; _panel = [UIView new]; _panel.layer.cornerRadius = _compact ? 18 : 26;
    _paneTitle = [UILabel new]; _paneTitle.font = [DmUI font:_compact ? 18 : 26 weight:UIFontWeightBold]; _paneTitle.textColor = DmUI.text;
    _clip = [UIView new]; _scroll = [UIScrollView new]; _scroll.showsVerticalScrollIndicator = NO; _scroll.alwaysBounceVertical = NO; _scroll.delaysContentTouches = NO;
    _hints = [DmHintBar new];
    _catRing = [DmFocusView new]; _catRing.radius = _compact ? 14 : 19;
    _rowRing = [DmFocusView new]; _rowRing.radius = _compact ? 14 : 19;
    for (UIView *s in @[_head, _close, _catBox, _panel, _hints]) [v addSubview:s];
    [_panel addSubview:_paneTitle]; [_panel addSubview:_clip]; [_clip addSubview:_scroll];
    [_scroll addSubview:_rowRing];
    for (NSUInteger i = 0; i < _secs.count; i++) {
        DmSection *s = _secs[i];
        DmCategoryView *c = [[DmCategoryView alloc] initWithTitle:s.title icon:s.icon compact:_compact]; c.tag = (NSInteger)i;
        [c addTarget:self action:@selector(categoryTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_catBox addSubview:c]; [_cats addObject:c];
    }
    [_catBox addSubview:_catRing];
    __weak DmSettingsVC *w = self;
    on_trait(self.view, ^{ DmSettingsVC *s = w; s->_panel.layer.backgroundColor = [DmUI.panel resolvedColorWithTraitCollection:s.view.traitCollection].CGColor; s->_close.backgroundColor = DmUI.row; });
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshRows) name:DmSettingDidChangeNotification object:nil];
    [self rebuildRows];
    [self updateFocus:NO];
}
// a block run now and when the light / dark style changes
static void on_trait(UIView *v, void (^apply)(void)) {
    apply();
    [v registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withHandler:^(__kindof id<UITraitEnvironment> e, UITraitCollection *p) { (void)e; (void)p; apply(); }];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_repeat invalidate]; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self becomeFirstResponder]; }

- (DmSection *)currentSection { return _secs[(NSUInteger)_section]; }
- (void)rebuildRows {
    for (DmRowView *r in _rows) [r removeFromSuperview];
    [_rows removeAllObjects];
    _hasRestartRow = _settings.restartPending;
    void (^add)(DmRowView *) = ^(DmRowView *r) {
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rowTapped:)]; [r addGestureRecognizer:t];
        [self->_scroll insertSubview:r belowSubview:self->_rowRing]; [self->_rows addObject:r];
    };
    if (_hasRestartRow) add([[DmRowView alloc] initWithSetting:nil kind:DmItemRestart compact:_compact]);
    for (DmSetting *s in [_settings visibleSettingsInSection:self.currentSection]) {
        DmRowView *r = [[DmRowView alloc] initWithSetting:s kind:DmItemSetting compact:_compact]; add(r);
        if (r.slider) [r.slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    }
    add([[DmRowView alloc] initWithSetting:nil kind:DmItemReset compact:_compact]);
    add([[DmRowView alloc] initWithSetting:nil kind:DmItemResetAll compact:_compact]);
    _armed = NO;
    _paneTitle.text = self.currentSection.title;
    _row = MIN(MAX(_row, 0), (NSInteger)_rows.count - 1);
    [self refreshRows]; [self layoutPane];
}
- (void)refreshRows {
    for (DmRowView *r in _rows) if (r.setting) [r showValue:[_settings valueForKey:r.setting.key] source:[_settings sourceForKey:r.setting.key]];
    if (_settings.restartPending != _hasRestartRow) {   // a restart-only setting changed: the restart row appears (keep the focus on the same setting)
        NSString *key = _row < (NSInteger)_rows.count ? _rows[(NSUInteger)_row].setting.key : nil;
        [self rebuildRows];
        if (key) for (NSUInteger i = 0; i < _rows.count; i++) if ([_rows[i].setting.key isEqualToString:key]) _row = (NSInteger)i;
        [self updateFocus:NO];
    }
    [self layoutPane];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets si = self.view.safeAreaInsets; CGRect b = self.view.bounds;
    CGFloat m = _compact ? 16 : 40, top = MAX(si.top, _compact ? 8 : 22), left = MAX(si.left, 0) + m, right = b.size.width - MAX(si.right, 0) - m;
    CGFloat hh = _compact ? 40 : 76, hb = [_hints heightWithCompact:_compact], bottom = b.size.height - MAX(si.bottom, _compact ? 6 : 16) - hb;
    _head.frame = CGRectMake(left, top, 300, hh); _close.frame = CGRectMake(right - 44, top + (hh - 44) / 2, 44, 44);
    _hints.frame = CGRectMake(left, bottom, right - left, hb);
    CGFloat y0 = top + hh + (_compact ? 4 : 6), y1 = bottom - (_compact ? 6 : 14);
    CGFloat lw = _compact ? 176 : MIN(360, MAX(280, b.size.width * 0.26)), ch = _compact ? 46 : 66, gap = _compact ? 6 : 10;
    _catBox.frame = CGRectMake(left, y0, lw, y1 - y0);
    for (NSUInteger i = 0; i < _cats.count; i++) _cats[i].frame = CGRectMake(0, i * (ch + gap), lw, ch);
    CGFloat px = left + lw + (_compact ? 14 : 28);
    _panel.frame = CGRectMake(px, y0, right - px, y1 - y0);
    CGFloat pad = _compact ? 14 : 26, tt = _compact ? 30 : 44;
    _paneTitle.frame = CGRectMake(pad + 6, pad - 2, _panel.bounds.size.width - pad * 2, tt);
    _clip.frame = CGRectMake(pad - 6, pad + tt + 2, _panel.bounds.size.width - pad * 2 + 12, _panel.bounds.size.height - pad - tt - 2 - (_compact ? 8 : 14));
    _scroll.frame = _clip.bounds; _scroll.clipsToBounds = YES;
    CAGradientLayer *fade = (CAGradientLayer *)_clip.layer.mask;   // rows fade out under the pane's title and above its bottom edge instead of ending in a hard line (the mask sits on the clip view: on the scroll view it would scroll with the content)
    if (!fade) { fade = [CAGradientLayer layer]; fade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:0].CGColor]; fade.startPoint = CGPointMake(0.5, 0); fade.endPoint = CGPointMake(0.5, 1); _clip.layer.mask = fade; }
    CGFloat fh = MAX(_clip.bounds.size.height, 1), f = MIN(0.5, (_compact ? 10 : 14) / fh);
    fade.frame = _clip.bounds; fade.locations = @[@0, @(f), @(1 - f), @1];
    [self layoutPane]; [self updateFocus:NO];
}
- (void)layoutPane {
    CGFloat ix = 12, iy = 10, w = _scroll.bounds.size.width - ix * 2, y = iy, gap = _compact ? 8 : 12;   // room around the rows for the focus border's glow (the scroll view clips)
    if (w <= 0) return;
    for (DmRowView *r in _rows) { CGFloat h = [r heightForWidth:w]; r.frame = CGRectMake(ix, y, w, h); y += h + gap; }
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, y - gap + iy);
}

#pragma mark - Focus

- (void)updateFocus:(BOOL)animated {
    if (_cats.count == 0 || _rows.count == 0) return;
    if (_armed && (!_inPane || _rows[(NSUInteger)_row].kind != DmItemResetAll)) [self disarm];   // moving away takes the restore-all confirmation back
    for (DmCategoryView *c in _cats) { c.chosen = c.tag == _section; c.paneFocused = _inPane; }
    void (^place)(void) = ^{
        self->_catRing.frame = CGRectInset(self->_cats[(NSUInteger)self->_section].frame, -3, -3);
        self->_rowRing.frame = CGRectInset(self->_rows[(NSUInteger)self->_row].frame, -3, -3);
    };
    if (animated) [UIView animateWithDuration:0.13 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:place completion:nil]; else place();
    _catRing.active = !_inPane; _rowRing.active = _inPane;
    if (_inPane) [_scroll scrollRectToVisible:CGRectInset(_rows[(NSUInteger)_row].frame, 0, -10) animated:animated];
    if (_hintMode != _inPane) [_hints setHints:_inPane ? @[@[@"↔", @"Change"], @[@"A", @"Select"], @[@"B", @"Back"], @[@"L R", @"Category"]] : @[@[@"A", @"Open"], @[@"B", @"Close"], @[@"L R", @"Category"]]];
    _hintMode = _inPane;
}
- (void)selectSection:(NSInteger)s focusPane:(BOOL)pane row:(NSInteger)row {
    s = MIN(MAX(s, 0), (NSInteger)_cats.count - 1);
    BOOL changed = s != _section; _section = s; _inPane = pane; _row = row;
    if (changed || _rows.count == 0) {
        [UIView transitionWithView:_panel duration:0.12 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{ [self rebuildRows]; } completion:nil];
    }
    _row = MIN(MAX(row, 0), (NSInteger)_rows.count - 1);
    [self.view layoutIfNeeded]; [self updateFocus:self.view.window != nil];
}

#pragma mark - Actions

- (void)requestClose { if (self.onClose) self.onClose(); }
- (void)restart { if (self.onRestart) self.onRestart(); else exit(0); }   // the choices are stored already; the player starts the app again
- (void)setRow:(DmRowView *)r value:(NSString *)v {
    if (![_settings setValue:v forKey:r.setting.key]) { [r shake]; return; }
    [self refreshRows];
}
- (void)adjust:(DmRowView *)r by:(int)dir {   // left / right on a row (dir -1 / +1)
    DmSetting *s = r.setting; NSString *cur = [_settings valueForKey:s.key];
    switch (s.type) {
        case DmSettingToggle: [self setRow:r value:dir > 0 ? @"1" : @"0"]; break;
        case DmSettingChoice: {
            NSInteger n = (NSInteger)s.options.count, i = 0;
            for (NSInteger k = 0; k < n; k++) if ([s.options[(NSUInteger)k][@"value"] isEqualToString:cur]) i = k;
            [self setRow:r value:s.options[(NSUInteger)((i + dir + n) % n)][@"value"]]; break;
        }
        case DmSettingSlider: [self setRow:r value:[NSString stringWithFormat:@"%g", cur.doubleValue + dir * s.step]]; break;
        case DmSettingText: break;   // edited in the alert (A / tap)
    }
}
- (void)disarm { if (_armed) { _armed = NO; for (DmRowView *r in _rows) if (r.kind == DmItemResetAll) r.confirming = NO; [self layoutPane]; } }
- (void)activate:(DmRowView *)r {   // A / tap
    if (r.kind != DmItemResetAll) [self disarm];
    switch (r.kind) {
        case DmItemReset: [_settings resetSection:self.currentSection]; [self refreshRows]; break;
        case DmItemResetAll:
            if (!_armed) { _armed = YES; r.confirming = YES; [self layoutPane]; break; }   // a second A or tap restores everything
            [_settings resetAll]; _armed = NO; r.confirming = NO; [self refreshRows]; break;
        case DmItemRestart: [self restart]; break;
        case DmItemSetting:
            if (r.setting.type == DmSettingToggle) [self setRow:r value:[[_settings valueForKey:r.setting.key] isEqualToString:@"1"] ? @"0" : @"1"];
            else if (r.setting.type == DmSettingChoice) [self adjust:r by:1];
            else if (r.setting.type == DmSettingText) [self editText:r];
            break;
    }
}

#pragma mark - Text editing

static const void *kSaveKey = &kSaveKey, *kSettingKey = &kSettingKey;   // on the alert's text field: the save block and the setting it edits
// A text row opens a small editor: the system keyboard for touch, the hardware keyboard works as usual (Return saves, Escape cancels). The controller and the key commands are paused while it is up
- (void)editText:(DmRowView *)r {
    DmSetting *s = r.setting; if (r.locked) { [r shake]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:s.label message:s.detail preferredStyle:UIAlertControllerStyleAlert];
    __weak DmSettingsVC *w = self; __weak DmRowView *wr = r; __weak UIAlertController *wa = a;
    void (^save)(void) = ^{
        DmSettingsVC *me = w; DmRowView *row = wr; UITextField *f = wa.textFields.firstObject; if (!me || !row || !f) return;
        if (![me->_settings setValue:f.text forKey:s.key]) { [row shake]; return; }
        [me refreshRows];
    };
    UIAlertAction *ok = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; save(); [w textEditorClosed]; }];
    __weak UIAlertAction *wok = ok;
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = [self->_settings valueForKey:s.key]; f.clearButtonMode = UITextFieldViewModeWhileEditing; f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeWords; f.returnKeyType = UIReturnKeyDone; f.accessibilityLabel = s.label; f.delegate = self;
        [f addAction:[UIAction actionWithHandler:^(__kindof UIAction *x) { (void)x; wok.enabled = [s normalized:f.text] != nil; }] forControlEvents:UIControlEventEditingChanged];
        objc_setAssociatedObject(f, kSaveKey, [save copy], OBJC_ASSOCIATION_COPY_NONATOMIC); objc_setAssociatedObject(f, kSettingKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; [w textEditorClosed]; }]];
    [a addAction:ok]; a.preferredAction = ok;
    _editing = YES; [self presentViewController:a animated:YES completion:nil];
}
- (void)textEditorClosed { _editing = NO; _baselined = NO; [self becomeFirstResponder]; }   // what the controller holds now does nothing until it is released
- (BOOL)textField:(UITextField *)f shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)t {
    DmSetting *s = objc_getAssociatedObject(f, kSettingKey); if (!s) return YES;
    return [s textFits:[f.text stringByReplacingCharactersInRange:r withString:t]];
}
- (BOOL)textFieldShouldReturn:(UITextField *)f {
    DmSetting *s = objc_getAssociatedObject(f, kSettingKey); void (^save)(void) = objc_getAssociatedObject(f, kSaveKey);
    if (!s || ![s normalized:f.text]) return NO;
    [self.presentedViewController dismissViewControllerAnimated:YES completion:nil]; if (save) save(); [self textEditorClosed];
    return NO;
}
- (void)step:(Dir)d {
    if (!_inPane) {
        if (d == DirUp || d == DirDown) { [self selectSection:_section + (d == DirDown ? 1 : -1) focusPane:NO row:0]; }
        else if (d == DirRight) [self selectSection:_section focusPane:YES row:0];
        return;
    }
    DmRowView *r = _rows[(NSUInteger)_row];
    if (d == DirUp || d == DirDown) { _row = MIN(MAX(_row + (d == DirDown ? 1 : -1), 0), (NSInteger)_rows.count - 1); [self updateFocus:YES]; }
    else if (r.kind != DmItemSetting) { if (d == DirLeft) [self selectSection:_section focusPane:NO row:_row]; }
    else [self adjust:r by:d == DirRight ? 1 : -1];
}
- (void)accept { if (!_inPane) [self selectSection:_section focusPane:YES row:0]; else [self activate:_rows[(NSUInteger)_row]]; }
- (void)back { if (_inPane) [self selectSection:_section focusPane:NO row:_row]; else [self requestClose]; }
- (void)page:(int)d { [self selectSection:_section + d focusPane:_inPane row:0]; }

#pragma mark - Touch

- (void)categoryTapped:(DmCategoryView *)c { [self selectSection:c.tag focusPane:NO row:0]; }
- (void)rowTapped:(UITapGestureRecognizer *)g {
    DmRowView *r = (DmRowView *)g.view; NSUInteger i = [_rows indexOfObject:r]; if (i == NSNotFound) return;
    if (r.slider && CGRectContainsPoint(CGRectInset(r.slider.frame, 0, -10), [g locationInView:r])) return;
    _inPane = YES; _row = (NSInteger)i; [self updateFocus:YES]; [self activate:r];
}
- (void)sliderChanged:(DmSliderView *)s {
    DmRowView *r = (DmRowView *)s.superview; NSUInteger i = [_rows indexOfObject:r]; if (i == NSNotFound) return;
    if (!_inPane || _row != (NSInteger)i) { _inPane = YES; _row = (NSInteger)i; [self updateFocus:YES]; }
    DmSetting *st = r.setting;
    [self setRow:r value:[NSString stringWithFormat:@"%g", st.min + s.value * (st.max - st.min)]];
}

#pragma mark - Controller and keyboard

static Dir dir_of(uint64_t m, int32_t lx, int32_t ly) {
    if (m & 1ull << DMB_UP || ly > 20000) return DirUp;
    if (m & 1ull << DMB_DOWN || ly < -20000) return DirDown;
    if (m & 1ull << DMB_LEFT || lx < -20000) return DirLeft;
    if (m & 1ull << DMB_RIGHT || lx > 20000) return DirRight;
    return DirNone;
}
- (void)stopRepeat { [_repeat invalidate]; _repeat = nil; _held = DirNone; }
- (void)startRepeat:(Dir)d {
    [self stopRepeat]; _held = d;
    __weak DmSettingsVC *w = self; __block void (^tick)(NSTimeInterval);
    tick = ^(NSTimeInterval after) {
        DmSettingsVC *s = w; if (!s) return;
        s->_repeat = [NSTimer scheduledTimerWithTimeInterval:after repeats:NO block:^(NSTimer *t) {
            DmSettingsVC *s2 = w; if (!s2 || s2->_held != d) { tick = nil; return; }
            [s2 step:d]; tick(s2->_inPane && (d == DirLeft || d == DirRight) ? 0.07 : 0.15);
        }];
    };
    tick(0.4);
}
- (void)padState:(uint64_t)m lx:(int32_t)lx ly:(int32_t)ly {
    if (_editing) return;   // the text editor is up: the controller does nothing
    Dir d = dir_of(m, lx, ly);
    uint64_t want = m & (1ull << DMB_A | 1ull << DMB_B | 1ull << DMB_L | 1ull << DMB_R | 1ull << DMB_ZL | 1ull << DMB_ZR);
    if (!_baselined) { _baselined = YES; _prev = want; _held = d; return; }   // what is held when the screen opens (the chord's buttons, a direction) does nothing until it is released
    uint64_t up = want & ~_prev; _prev = want;
    if (d != _held) { [self stopRepeat]; if (d != DirNone) { [self step:d]; [self startRepeat:d]; } }
    if (up & 1ull << DMB_A) [self accept];
    if (up & 1ull << DMB_B) [self back];
    if (up & (1ull << DMB_L | 1ull << DMB_ZL)) [self page:-1];
    if (up & (1ull << DMB_R | 1ull << DMB_ZR)) [self page:1];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    NSArray *k = @[@[UIKeyInputUpArrow, @"keyUp"], @[UIKeyInputDownArrow, @"keyDown"], @[UIKeyInputLeftArrow, @"keyLeft"], @[UIKeyInputRightArrow, @"keyRight"],
                   @[@"\r", @"accept"], @[UIKeyInputEscape, @"back"], @[@"[", @"keyPrev"], @[@"]", @"keyNext"]];
    NSMutableArray *r = [NSMutableArray array];
    for (NSArray *p in k) { UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:p[0] modifierFlags:0 action:NSSelectorFromString(p[1])]; c.wantsPriorityOverSystemBehavior = YES; [r addObject:c]; }
    return r;
}
- (void)keyUp { [self step:DirUp]; }
- (void)keyDown { [self step:DirDown]; }
- (void)keyLeft { [self step:DirLeft]; }
- (void)keyRight { [self step:DirRight]; }
- (void)keyPrev { [self page:-1]; }
- (void)keyNext { [self page:1]; }
@end
