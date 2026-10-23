// The settings screen (see DmSettingsVC.h). Two focus levels: the category list and the rows of the chosen category; one amber focus ring per level, moved with a short animation.
// All data comes from DmSettings (the registry): the screen knows no setting by name.
#import "DmSettingsVC.h"
#import "DmSettingsViews.h"
#import "DmSettingsEditor.h"
#import "DmPadBits.h"
#import "DmRepeat.h"

static void on_trait(UIView *v, void (^apply)(void));
typedef NS_ENUM(NSInteger, Dir) { DirNone = 0, DirUp, DirDown, DirLeft, DirRight };

@implementation DmPageItem
+ (instancetype)info:(NSString *)t detail:(NSString *)d { DmPageItem *i = [self new]; i.title = t; i.detail = d; return i; }
+ (instancetype)action:(NSString *)t detail:(NSString *)d run:(void (^)(void))r { DmPageItem *i = [self info:t detail:d]; i.run = r; return i; }
+ (instancetype)unavailable:(NSString *)t detail:(NSString *)d { DmPageItem *i = [self info:t detail:d]; i.unavailable = YES; return i; }
@end
@implementation DmPage
+ (instancetype)section:(DmSection *)s { DmPage *p = [self new]; p->_section = s; p->_title = s.title; p->_icon = s.icon; return p; }
+ (instancetype)page:(NSString *)title icon:(NSString *)symbol items:(NSArray<DmPageItem *> *(^)(void))items { DmPage *p = [self new]; p->_title = title; p->_icon = symbol; p->_items = [items copy]; return p; }
+ (NSArray<DmPage *> *)pagesOf:(DmSettings *)st gameRowsOnly:(BOOL)gameOnly {
    NSMutableArray *out = [NSMutableArray array];
    for (DmSection *s in st.visibleSections) {
        BOOL any = !gameOnly; for (DmSetting *x in [st visibleSettingsInSection:s]) if (x.scope != DmScopeSystem) any = YES;
        if (!any) continue;
        DmPage *p = [self section:s]; p->_gameRowsOnly = gameOnly; [out addObject:p];
    }
    return out;
}
@end

@implementation DmSettingsVC {
    DmSettings *_settings; BOOL _compact; NSArray<DmPage *> *_shown; BOOL _editing, _armed;   // _shown: the categories; _editing: the text editor is up; _armed: restore-all or an action waits for a second press
    NSArray<DmPageItem *> *_items; DmRowView *_armedRow;   // an item page's items (row i is item i); the action row waiting for its second press
    DmEditorView *_editor; BOOL _editB;   // _editB: the controller's B is held (it cancels the editor once released)
    NSInteger _section, _row; BOOL _inPane;
    NSMutableArray<DmCategoryView *> *_cats; NSMutableArray<DmRowView *> *_rows; BOOL _hasRestartRow;
    UILabel *_head, *_paneTitle; UIButton *_close; UIView *_catBox, *_panel, *_clip; UIScrollView *_scroll; DmHintBar *_hints;
    DmFocusView *_catRing, *_rowRing;
    uint64_t _prev; BOOL _baselined; DmRepeat *_repeat; NSArray *_shownHints;
}
- (instancetype)initWithSettings:(DmSettings *)s size:(CGSize)size {
    if ((self = [super initWithNibName:nil bundle:nil])) { _settings = s; _compact = MIN(size.width, size.height) < 500; _rows = [NSMutableArray array]; _cats = [NSMutableArray array]; _repeat = [DmRepeat new]; }
    return self;
}
- (NSInteger)section { return _section; }
- (BOOL)canBecomeFirstResponder { return YES; }

#pragma mark - Build

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *v = self.view; v.backgroundColor = DmUI.bg; v.accessibilityViewIsModal = YES;   // over Home: VoiceOver stays on this screen
    _shown = self.pages ?: [DmPage pagesOf:_settings gameRowsOnly:NO];
    _head = [UILabel new]; _head.text = self.heading ?: @"Settings"; _head.font = [DmUI font:_compact ? 22 : 34 weight:UIFontWeightBold]; _head.textColor = DmUI.text;
    _close = [UIButton buttonWithType:UIButtonTypeSystem];
    [_close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:_compact ? 14 : 17 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    _close.tintColor = DmUI.sub; _close.layer.cornerRadius = 22; _close.accessibilityLabel = @"Close settings";
    [_close addTarget:self action:@selector(requestClose) forControlEvents:UIControlEventTouchUpInside];
    _catBox = [UIView new]; _panel = [UIView new]; _panel.layer.cornerRadius = _compact ? 18 : 26;
    _paneTitle = [UILabel new]; _paneTitle.font = [DmUI font:_compact ? 18 : 26 weight:UIFontWeightBold]; _paneTitle.textColor = DmUI.text;
    _clip = [UIView new]; _scroll = [UIScrollView new]; _scroll.showsVerticalScrollIndicator = NO; _scroll.showsHorizontalScrollIndicator = NO; _scroll.alwaysBounceVertical = NO; _scroll.alwaysBounceHorizontal = NO; _scroll.directionalLockEnabled = YES; _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever; _scroll.delaysContentTouches = NO;   // vertical only
    _hints = [DmHintBar new];
    _catRing = [DmFocusView new]; _catRing.radius = _compact ? 14 : 19;
    _rowRing = [DmFocusView new]; _rowRing.radius = _compact ? 14 : 19;
    for (UIView *s in @[_head, _close, _catBox, _panel, _hints]) [v addSubview:s];
    [_panel addSubview:_paneTitle]; [_panel addSubview:_clip]; [_clip addSubview:_scroll];
    [_scroll addSubview:_rowRing];
    [self buildCategories];
    __weak DmSettingsVC *w = self;
    on_trait(self.view, ^{ DmSettingsVC *s = w; s->_panel.layer.backgroundColor = [DmUI.panel resolvedColorWithTraitCollection:s.view.traitCollection].CGColor; s->_close.backgroundColor = DmUI.row; });
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshRows) name:DmSettingDidChangeNotification object:nil];
    [self rebuildRows];
    [self updateFocus:NO];
}
- (void)buildCategories {
    for (NSUInteger i = 0; i < _shown.count; i++) {
        DmPage *p = _shown[i];
        DmCategoryView *c = [[DmCategoryView alloc] initWithTitle:p.title icon:p.icon compact:_compact]; c.tag = (NSInteger)i;
        [c addTarget:self action:@selector(categoryTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_catBox addSubview:c]; [_cats addObject:c];
    }
    [_catBox addSubview:_catRing];
}
- (void)resumeController { _baselined = NO; [_repeat stop]; }
- (void)reloadPages {
    if (!self.isViewLoaded) return;
    NSString *was = _section < (NSInteger)_shown.count ? _shown[(NSUInteger)_section].title : nil;
    for (DmCategoryView *c in _cats) [c removeFromSuperview];
    [_cats removeAllObjects];
    _shown = self.pages ?: [DmPage pagesOf:_settings gameRowsOnly:NO];
    [self buildCategories];
    for (NSUInteger i = 0; i < _shown.count; i++) if ([_shown[i].title isEqualToString:was]) _section = (NSInteger)i;   // the same page where it still exists
    _section = MIN(MAX(_section, 0), (NSInteger)_shown.count - 1);
    [self rebuildRows]; [self.view setNeedsLayout]; [self.view layoutIfNeeded]; [self updateFocus:NO];
}
// a block run now and when the light / dark style changes
static void on_trait(UIView *v, void (^apply)(void)) {
    apply();
    [v registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withHandler:^(__kindof id<UITraitEnvironment> e, UITraitCollection *p) { (void)e; (void)p; apply(); }];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_repeat stop]; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self becomeFirstResponder]; }

- (DmPage *)currentPage { return _shown[(NSUInteger)_section]; }
- (DmSection *)currentSection { return self.currentPage.section; }
- (void)rebuildRows {
    for (DmRowView *r in _rows) [r removeFromSuperview];
    [_rows removeAllObjects];
    _hasRestartRow = _settings.restartPending;
    void (^add)(DmRowView *) = ^(DmRowView *r) {
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rowTapped:)]; [r addGestureRecognizer:t];
        if (self->_settings.gameId && r.setting.scope == DmScopeBoth) [r addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(rowHeld:)]];
        [self->_scroll insertSubview:r belowSubview:self->_rowRing]; [self->_rows addObject:r];
    };
    DmPage *pg = self.currentPage; _items = nil; _armedRow = nil;
    if (pg.section) {
        if (_hasRestartRow) add([[DmRowView alloc] initWithSetting:nil kind:DmItemRestart compact:_compact]);
        for (DmSetting *s in [_settings visibleSettingsInSection:pg.section]) {
            if (pg.gameRowsOnly && s.scope == DmScopeSystem) continue;   // a game's Options: only what can differ per game
            DmRowView *r = [[DmRowView alloc] initWithSetting:s kind:DmItemSetting compact:_compact]; add(r);
            if (r.slider) [r.slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        }
        add([[DmRowView alloc] initWithSetting:nil kind:DmItemReset compact:_compact]);
        if (!pg.gameRowsOnly) add([[DmRowView alloc] initWithSetting:nil kind:DmItemResetAll compact:_compact]);   // in a game's Options it would reach the system settings too
    } else {
        _items = pg.items ? pg.items() : @[];
        if (!_items.count) _items = @[[DmPageItem info:@"Nothing here yet" detail:nil]];
        for (DmPageItem *it in _items) { DmRowView *r = [[DmRowView alloc] initWithAction:it.title detail:it.detail compact:_compact]; r.info = !it.run; r.destructive = it.destructive; r.unavailable = it.unavailable; add(r); }
    }
    _armed = NO;
    _paneTitle.text = pg.title;
    _row = MIN(MAX(_row, 0), (NSInteger)_rows.count - 1);
    [self refreshRows]; [self layoutPane];
}
- (void)refreshRows {
    for (DmRowView *r in _rows) if (r.setting) r.scopeNote = !_settings.gameId || r.setting.scope != DmScopeBoth ? nil
        : [_settings followsSystem:r.setting] ? @"System setting" : @"This game only, hold to use the system setting";
    for (DmRowView *r in _rows) if (r.setting) [r showValue:[_settings valueForKey:r.setting.key] source:[_settings sourceForKey:r.setting.key] disabledNote:[_settings disabledNote:r.setting]];
    if (_settings.restartPending != _hasRestartRow) {   // a restart-only setting changed: the restart row appears (keep the focus on the same setting)
        NSString *key = _row < (NSInteger)_rows.count ? _rows[(NSUInteger)_row].setting.key : nil;
        [self rebuildRows];
        if (key) for (NSUInteger i = 0; i < _rows.count; i++) if ([_rows[i].setting.key isEqualToString:key]) _row = (NSInteger)i;
        [self updateFocus:NO];
    }
    [self layoutPane]; [self updateHints];   // a row may have become locked, unlocked, disabled or enabled
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
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, y - gap + iy);   // exactly the pane's width: nothing to scroll sideways
}

#pragma mark - Focus

- (void)updateFocus:(BOOL)animated {
    if (_cats.count == 0 || _rows.count == 0) return;
    if (_armed && (!_inPane || (_rows[(NSUInteger)_row].kind != DmItemResetAll && _rows[(NSUInteger)_row] != _armedRow))) [self disarm];   // moving away takes the confirmation back
    for (DmCategoryView *c in _cats) { c.chosen = c.tag == _section; c.paneFocused = _inPane; }
    void (^place)(void) = ^{
        self->_catRing.frame = CGRectInset(self->_cats[(NSUInteger)self->_section].frame, -3, -3);
        self->_rowRing.frame = CGRectInset(self->_rows[(NSUInteger)self->_row].frame, -3, -3);
    };
    if (animated) [UIView animateWithDuration:0.13 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:place completion:nil]; else place();
    _catRing.active = !_inPane; _rowRing.active = _inPane;
    if (_inPane) [_scroll scrollRectToVisible:CGRectInset(_rows[(NSUInteger)_row].frame, 0, -10) animated:animated];
    [self updateHints];
}
// The footer says what the focused spot can do (dm_hints_for_focus)
- (void)updateHints {
    DmFocusKind k = DmFocusCategory; BOOL locked = NO;
    if (_editing) k = DmFocusEditor;
    else if (_inPane && _row < (NSInteger)_rows.count) {
        DmRowView *r = _rows[(NSUInteger)_row]; locked = r.inert;   // a disabled row changes as little as a locked one
        switch (r.kind) {
            case DmItemReset: k = DmFocusRestore; break;
            case DmItemResetAll: k = DmFocusRestoreAll; break;
            case DmItemRestart: k = DmFocusRestart; break;
            case DmItemAction: k = r.info ? DmFocusInfo : DmFocusAction; break;
            case DmItemSetting:
                switch (r.setting.type) { case DmSettingToggle: k = DmFocusToggle; break; case DmSettingChoice: k = DmFocusChoice; break; case DmSettingSlider: k = DmFocusSlider; break; case DmSettingText: k = DmFocusText; break; }
                break;
        }
    }
    NSArray *h = dm_hints_for_focus(k, locked, _armed);
    if (![h isEqual:_shownHints]) { _shownHints = h; [_hints setHints:h]; }
    _hints.hidden = h.count == 0;   // the editor has its own buttons, above the keyboard
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
    if (r.disabled || ![_settings setValue:v forKey:r.setting.key]) { [r shake]; return; }
    [self refreshRows]; [self changed];
}
- (void)changed { if (self.onChange) self.onChange(); }
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
        case DmSettingText: break;   // edited in the editor (A / tap)
    }
}
- (void)disarm {
    if (!_armed) return;
    _armed = NO; for (DmRowView *r in _rows) if (r.kind == DmItemResetAll) r.confirming = NO;
    NSUInteger i = _armedRow ? [_rows indexOfObject:_armedRow] : NSNotFound;
    if (i < _items.count) { [_armedRow setActionTitle:_items[i].title detail:_items[i].detail]; _armedRow.confirming = NO; }
    _armedRow = nil; [self layoutPane]; [self updateHints];
}
- (void)runItem:(DmRowView *)r {   // an item page's row: information does nothing; an action may ask for a second press first
    NSUInteger i = [_rows indexOfObject:r]; DmPageItem *it = i < _items.count ? _items[i] : nil;
    if (!it.run) return;
    if (it.confirmTitle && r != _armedRow) {
        [self disarm]; _armed = YES; _armedRow = r; [r setActionTitle:it.confirmTitle detail:it.detail]; r.confirming = YES; [self layoutPane]; [self updateHints]; return;
    }
    [self disarm];
    void (^run)(void) = it.run; run();
    if (self.view.window && _section < (NSInteger)_shown.count && !self.currentPage.section) {   // the page shows what changed (the action may have reloaded the pages already)
        NSInteger keep = _row; [self rebuildRows]; _row = MIN(keep, (NSInteger)_rows.count - 1); [self updateFocus:NO];
    }
}
- (void)activate:(DmRowView *)r {   // A / tap
    if (r.kind != DmItemResetAll && r != _armedRow) [self disarm];
    switch (r.kind) {
        case DmItemReset:
            if (self.currentPage.gameRowsOnly) { for (DmRowView *x in _rows) if (x.setting) [_settings useSystemForKey:x.setting.key]; }   // a game's Options: drops this game's own choices on the page, touches nothing of the system's
            else [_settings resetSection:self.currentSection];
            [self refreshRows]; [self changed]; break;
        case DmItemResetAll:
            if (!_armed) { _armed = YES; r.confirming = YES; [self layoutPane]; [self updateHints]; break; }   // a second A or tap restores everything
            [_settings resetAll]; _armed = NO; r.confirming = NO; [self refreshRows]; [self updateHints]; [self changed]; break;
        case DmItemAction: [self runItem:r]; break;
        case DmItemRestart: [self restart]; break;
        case DmItemSetting:
            if (r.setting.type == DmSettingToggle) [self setRow:r value:[[_settings valueForKey:r.setting.key] isEqualToString:@"1"] ? @"0" : @"1"];
            else if (r.setting.type == DmSettingChoice) [self adjust:r by:1];
            else if (r.setting.type == DmSettingText) [self editText:r];
            break;
    }
}

#pragma mark - Text editing

// A text row opens the editor panel (DmSettingsEditor.m): the system keyboard for touch, a hardware keyboard works as usual (Return saves, Escape cancels).
// The controller and the key commands are paused while it is up, except B, which cancels
- (void)editText:(DmRowView *)r {
    DmSetting *s = r.setting; if (r.inert) { [r shake]; return; }
    __weak DmSettingsVC *w = self; __weak DmRowView *wr = r;
    [self editSetting:s text:[_settings valueForKey:s.key] save:^BOOL(NSString *text) {
        DmSettingsVC *me = w; if (!me) return NO;
        if (![me->_settings setValue:text forKey:s.key]) { [wr shake]; return NO; }
        [me refreshRows]; [me changed]; return YES;
    }];
}
- (void)editText:(NSString *)title value:(NSString *)value maxBytes:(NSUInteger)maxBytes save:(BOOL (^)(NSString *text))save {
    NSString *why = nil;   // the default only has to parse (an empty text does not): the editor starts from value
    DmSetting *s = [DmSetting settingFromDictionary:@{@"key": @"page.text", @"label": title, @"type": @"text", @"default": value.length ? value : title, @"maxLength": @(maxBytes), @"maxBytes": @(maxBytes)} error:&why];
    if (!s) { NSLog(@"settings: [RED] no text editor for %@: %@", title, why); return; }
    [self editSetting:s text:value save:save];
}
- (void)editSetting:(DmSetting *)s text:(NSString *)text save:(BOOL (^)(NSString *text))save {
    DmEditorView *e = [[DmEditorView alloc] initWithSetting:s text:text compact:_compact];
    __weak DmSettingsVC *w = self;
    e.onSave = ^(NSString *t) { save(t); [w textEditorClosed]; };
    e.onCancel = ^{ [w textEditorClosed]; };
    e.frame = self.view.bounds; e.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _editor = e; _editing = YES; _editB = (_prev & 1ull << DMB_B) != 0;
    [self.view addSubview:e]; [self updateHints]; [e open];   // the footer goes while the editor is up: the soft keyboard would cover it, and the panel has its own Cancel and Save
}
- (void)textEditorClosed { _editing = NO; _editor = nil; _baselined = NO; [self updateHints]; [self becomeFirstResponder]; }   // what the controller holds now does nothing until it is released
- (void)cancelEditor { [_editor cancel]; }
- (void)step:(Dir)d {
    if (!_inPane) {
        if (d == DirUp || d == DirDown) { [self selectSection:_section + (d == DirDown ? 1 : -1) focusPane:NO row:0]; }
        else if (d == DirRight) [self selectSection:_section focusPane:YES row:0];
        return;
    }
    DmRowView *r = _rows[(NSUInteger)_row];
    if (d == DirUp || d == DirDown) { _row = MIN(MAX(_row + (d == DirDown ? 1 : -1), 0), (NSInteger)_rows.count - 1); [self updateFocus:YES]; }
    else if (r.kind != DmItemSetting || r.inert || r.setting.type == DmSettingText) { if (d == DirLeft) [self selectSection:_section focusPane:NO row:_row]; }   // no left / right on this row: left goes back to the list
    else [self adjust:r by:d == DirRight ? 1 : -1];
}
- (void)accept { if (!_inPane) [self selectSection:_section focusPane:YES row:0]; else [self activate:_rows[(NSUInteger)_row]]; }
- (void)back { if (_inPane) [self selectSection:_section focusPane:NO row:_row]; else [self requestClose]; }
- (void)page:(int)d { [self selectSection:_section + d focusPane:_inPane row:0]; }

#pragma mark - Touch

- (void)categoryTapped:(DmCategoryView *)c { [self selectSection:c.tag focusPane:NO row:0]; }
- (void)rowHeld:(UILongPressGestureRecognizer *)g {   // Use system setting: drops this game's own choice of the row
    DmRowView *r = (DmRowView *)g.view;
    if (g.state != UIGestureRecognizerStateBegan || !r.setting || [_settings followsSystem:r.setting] || [_settings sourceForKey:r.setting.key] == DmSourceEnv) return;
    [_settings useSystemForKey:r.setting.key]; [self refreshRows]; [self changed];
}
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
- (void)startRepeat:(Dir)d {   // sliders and choices change faster than the focus moves
    __weak DmSettingsVC *w = self;
    [_repeat hold:d step:^NSTimeInterval { DmSettingsVC *s = w; [s step:d]; return s && s->_inPane && (d == DirLeft || d == DirRight) ? 0.07 : DM_REPEAT_NEXT; }];
}
- (void)padState:(uint64_t)m lx:(int32_t)lx ly:(int32_t)ly {
    if (_editing) {   // the text editor is up: the controller does nothing but B, which cancels it once released
        BOOL b = (m & 1ull << DMB_B) != 0; if (_editB && !b) [_editor cancel]; _editB = b; return;
    }
    Dir d = dir_of(m, lx, ly);
    uint64_t want = m & (1ull << DMB_A | 1ull << DMB_B | 1ull << DMB_L | 1ull << DMB_R | 1ull << DMB_ZL | 1ull << DMB_ZR);
    if (!_baselined) { _baselined = YES; _prev = want; if (d != DirNone) [_repeat hold:d step:nil]; return; }   // what is held when the screen opens (the chord's buttons, a direction) does nothing until it is released
    uint64_t up = want & ~_prev; _prev = want;
    if (d != (Dir)_repeat.held) { [_repeat stop]; if (d != DirNone) { [self step:d]; [self startRepeat:d]; } }
    if (up & 1ull << DMB_A) [self accept];
    if (up & 1ull << DMB_B) [self back];
    if (up & (1ull << DMB_L | 1ull << DMB_ZL)) [self page:-1];
    if (up & (1ull << DMB_R | 1ull << DMB_ZR)) [self page:1];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    if (_editing) {   // the editor's text field takes the arrows and Return itself; only Escape is ours
        UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancelEditor)]; c.wantsPriorityOverSystemBehavior = YES; return @[c];
    }
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
