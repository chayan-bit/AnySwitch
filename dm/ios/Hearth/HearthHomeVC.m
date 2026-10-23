// Hearth's Home screen (HearthHomeVC.h): the player and the time at the top, one row of game tiles (last played first), the system buttons under it, the button hints at the bottom right.
// Focus (HearthFocus.h): zone 0 the tiles, zone 1 the buttons. A controller (captured while Home is up), a hardware keyboard and touch all drive it; a touch hides the ring until the next key or button.
#import "HearthHomeVC.h"
#import "HearthAvatar.h"
#import "HearthHomeViews.h"
#import "HearthFocus.h"
#import "HearthLaunch.h"
#import "HearthTheme.h"
#import "HearthSound.h"
#import "HearthQuickVC.h"
#import "HearthSleep.h"
#import "HearthDialog.h"
#import "HearthSettingsPages.h"
#import "DmSettings.h"
#import "DmSettingsVC.h"
#import "DmSettingsViews.h"
#import "DmPadBits.h"
#import "DmRepeat.h"
#include "boot.h"

void dm_gamepad_watch(void);
void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly));

enum { ZoneTiles = 0, ZoneButtons = 1, ZoneCount };

@interface HearthHomeVC () <UIScrollViewDelegate>
@end

@implementation HearthHomeVC {
    HearthTopBar *_bar; UIScrollView *_row; UILabel *_empty; UIView *_divider; UILabel *_buttonName; CGFloat _tileSize; NSMutableArray<HearthTile *> *_tiles; NSArray<HearthRoundButton *> *_buttons;
    DmFocusView *_tileRing, *_buttonRing; DmHintBar *_hints; NSArray *_shownHints;
    HearthFocus *_focus; DmRepeat *_repeat; uint64_t _prev; BOOL _baselined, _launching;
    DmSettingsVC *_settings; HearthQuickVC *_quick; NSArray<NSString *> *_buttonActions;
}

#pragma mark - Build

- (void)viewDidLoad {
    [super viewDidLoad];
    __weak HearthHomeVC *w = self;
    dm_on_style(self.view, ^{ w.view.backgroundColor = DmUI.bg; });   // opaque over the game too: a see-through Home showed the game's touch controls and, back from the background, its paused frame
    _focus = [[HearthFocus alloc] initWithZones:ZoneCount]; _repeat = [DmRepeat new]; _tiles = [NSMutableArray array];
    _bar = [HearthTopBar new];
    _bar.onUser = ^(NSInteger i) { HearthHomeVC *s = w; NSArray *us = hearth_users().users; if (s && i < (NSInteger)us.count) [s openUser:us[(NSUInteger)i]]; };
    _row = [UIScrollView new]; _row.showsHorizontalScrollIndicator = NO; _row.showsVerticalScrollIndicator = NO; _row.alwaysBounceVertical = NO; _row.clipsToBounds = NO; _row.delegate = self;
    _row.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _tileRing = [DmFocusView new]; _tileRing.radius = HEARTH_TILE_RADIUS + 6; [_row addSubview:_tileRing];
    _empty = [UILabel new]; _empty.text = @"No games yet"; _empty.font = [DmUI font:22 weight:UIFontWeightSemibold]; _empty.textColor = DmUI.sub; _empty.textAlignment = NSTextAlignmentCenter;
    NSMutableArray *bs = [NSMutableArray array], *acts = [NSMutableArray array];
    NSArray *defs = @[@[@"gearshape.fill", @"Settings", @"openSettings"], @[@"switch.2", @"Quick Settings", @"openQuick"], @[@"moon.fill", @"Sleep", @"sleep"]];
    if (_overlay) defs = [defs arrayByAddingObject:@[@"xmark", @"Close the game", @"closeGame"]];   // touch's way to close the paused game
    for (NSArray *d in defs) { [bs addObject:[[HearthRoundButton alloc] initWithSymbol:d[0] label:d[1]]]; [acts addObject:d[2]]; }
    _buttons = bs; _buttonActions = acts;
    for (HearthRoundButton *b in _buttons) [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    _buttonRing = [DmFocusView new]; _buttonRing.radius = HEARTH_BUTTON_SIZE / 2 + 6;
    _hints = [DmHintBar new];
    _buttonName = [UILabel new]; _buttonName.font = [DmUI font:18 weight:UIFontWeightSemibold]; _buttonName.textColor = DmUI.text; _buttonName.textAlignment = NSTextAlignmentCenter; _buttonName.alpha = 0;   // names the focused round button, as the focused tile shows its game's name
    _divider = [UIView new]; _divider.userInteractionEnabled = NO;   // the bottom bar's top edge; the hints sit in the bar on its right, its left end is free for the controllers' status
    __weak UIView *line = _divider; dm_on_style(_divider, ^{ line.backgroundColor = [DmUI.sub colorWithAlphaComponent:0.35]; });
    for (UIView *v in @[_bar, _row, _empty, _buttonRing, _buttonName, _divider, _hints]) [self.view addSubview:v];
    for (UIView *v in _buttons) [self.view insertSubview:v belowSubview:_buttonRing];
    [_focus setCount:(NSInteger)_buttons.count forZone:ZoneButtons];
    dm_gamepad_watch();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scanInbox) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self scanInbox];
}
- (CGFloat)screenHeight { CGFloat h = self.view.bounds.size.height; return h > 0 ? h : self.view.window.windowScene.screen.bounds.size.height; }   // 0 before the first layout: the first layout rebuilds the tiles
- (void)scanInbox { __weak HearthHomeVC *w = self; hearth_import_scan(^{ [w reload]; }); }   // a game pushed from the Mac appears when its import is done
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_repeat stop]; }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self reload]; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self takeController]; [self becomeFirstResponder]; }
- (BOOL)canBecomeFirstResponder { return YES; }

- (void)reload {
    if (_launching) return;
    NSString *was = _focus.zone == ZoneTiles && _focus.index >= 0 && _focus.index < (NSInteger)_tiles.count ? _tiles[(NSUInteger)_focus.index].game.titleId : nil;
    NSArray<HearthGame *> *games = [hearth_library() scan];
    HearthGame *run = _overlay ? hearth_running_game() : nil;
    if (run) {   // the paused game comes first, as the one a player most likely returns to
        NSMutableArray *m = [NSMutableArray arrayWithObject:run];
        for (HearthGame *g in games) if (![g.titleId isEqual:run.titleId]) [m addObject:g];
        games = m;
    }
    fprintf(stderr, "home: %lu games\n", (unsigned long)games.count);
    for (HearthTile *t in _tiles) [t removeFromSuperview];
    [_tiles removeAllObjects];
    _tileSize = hearth_tile_size(self.screenHeight);
    for (HearthGame *g in games) {
        HearthTile *t = [[HearthTile alloc] initWithGame:g size:_tileSize]; t.playing = g == run;
        [t addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [t addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(tileHeld:)]];   // the game's Options
        [_row insertSubview:t belowSubview:_tileRing]; [_tiles addObject:t];
    }
    _empty.hidden = _tiles.count > 0;
    [_focus setCount:(NSInteger)_tiles.count forZone:ZoneTiles];
    for (NSUInteger i = 0; i < _tiles.count; i++) if ([_tiles[i].game.titleId isEqual:was]) [_focus focusZone:ZoneTiles index:(NSInteger)i];
    NSMutableArray *pics = [NSMutableArray array], *names = [NSMutableArray array];
    for (HearthUser *u in hearth_users().users) { [pics addObject:hearth_avatar_image(u)]; [names addObject:u.name]; }
    [_bar setUsers:pics names:names];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    [self showFocus:NO];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; UIEdgeInsets si = self.view.safeAreaInsets;
    if (_tiles.count && fabs(hearth_tile_size(b.size.height) - _tileSize) > 0.5) { __weak HearthHomeVC *w = self; dispatch_async(dispatch_get_main_queue(), ^{ [w reload]; }); }   // the view's real height arrived after the first build
    CGFloat left = MAX(si.left, 0) + HEARTH_MARGIN, right = b.size.width - MAX(si.right, 0) - HEARTH_MARGIN, top = MAX(si.top, 0) + 24;
    _bar.frame = CGRectMake(left, top, right - left, 48);
    // the bottom bar: a hairline between the margins, the hints centred in the bar under it and kept to the right
    CGFloat hh = [_hints heightWithCompact:NO], barTop = b.size.height - MAX(si.bottom, 0) - HEARTH_BAR_HEIGHT;
    _divider.frame = CGRectMake(left, barTop, right - left, 1);
    _hints.frame = CGRectMake(left, barTop + 1 + (HEARTH_BAR_HEIGHT - 1 - hh) / 2, right - left, hh);
    // the row: the art's centre at 40% of the height, the round buttons 60 pt under the row's last line (the state line)
    CGFloat size = _tileSize ?: hearth_tile_size(b.size.height), th = [HearthTile nameHeight] + size + [HearthTile stateHeight];
    CGFloat ry = b.size.height * HEARTH_ROW_CENTRE - [HearthTile nameHeight] - size / 2;
    CGFloat by = MIN(ry + th + HEARTH_BUTTONS_GAP, barTop - 24 - HEARTH_BUTTON_SIZE), bw = _buttons.count * HEARTH_BUTTON_SIZE + (_buttons.count - 1) * 28.0, bx = (b.size.width - bw) / 2;
    for (NSUInteger i = 0; i < _buttons.count; i++) _buttons[i].frame = CGRectMake(bx + i * (HEARTH_BUTTON_SIZE + 28), by, HEARTH_BUTTON_SIZE, HEARTH_BUTTON_SIZE);
    _row.frame = CGRectMake(0, ry, b.size.width, th);
    CGFloat x0 = left + (hearth_tile_focus_scale(size) - 1) * size / 2, total = _tiles.count * size + (_tiles.count ? _tiles.count - 1 : 0) * HEARTH_TILE_SPACING;   // the row starts at the left margin (the focused tile, which grows, reaches it), as on a console, and scrolls when it is longer than the screen
    for (NSUInteger i = 0; i < _tiles.count; i++) {
        HearthTile *t = _tiles[i]; CGAffineTransform keep = t.art.transform; t.art.transform = CGAffineTransformIdentity;
        t.frame = CGRectMake(x0 + i * (size + HEARTH_TILE_SPACING), 0, size, th);
        t.art.transform = keep;
    }
    _row.contentSize = CGSizeMake(MAX(x0 + total + (b.size.width - right), b.size.width), th);
    _empty.frame = CGRectMake(left, ry, right - left, th);
    [self showFocus:NO];
}

#pragma mark - Focus

- (void)showFocus:(BOOL)animated {
    BOOL onTiles = _focus.zone == ZoneTiles && _focus.index >= 0;
    for (NSUInteger i = 0; i < _tiles.count; i++) {
        BOOL f = onTiles && (NSInteger)i == _focus.index;
        if (f != _tiles[i].chosen) [_tiles[i] setChosen:f animated:animated];
    }
    void (^place)(void) = ^{
        if (onTiles) {
            HearthTile *t = self->_tiles[(NSUInteger)self->_focus.index];
            CGRect a = CGRectOffset(CGRectMake(0, 0, t.size, t.size), t.frame.origin.x, t.frame.origin.y + t.art.center.y - t.size / 2);
            CGFloat grow = t.size * (hearth_tile_focus_scale(t.size) - 1) / 2;
            self->_tileRing.frame = CGRectInset(a, -grow - 6, -grow - 6);
        }
        if (self->_focus.zone == ZoneButtons) {
            HearthRoundButton *b = self->_buttons[(NSUInteger)[self->_focus indexInZone:ZoneButtons]];
            self->_buttonRing.frame = CGRectInset(b.frame, -6, -6);
            self->_buttonName.text = b.accessibilityLabel; self->_buttonName.frame = CGRectMake(CGRectGetMidX(b.frame) - 120, CGRectGetMaxY(b.frame) + 14, 240, 26);
        }
        self->_buttonName.alpha = self->_focus.zone == ZoneButtons && self->_focus.ringVisible ? 1 : 0;
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled())
        [UIView animateWithDuration:HEARTH_FOCUS_SECONDS delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:place completion:nil];
    else place();
    _tileRing.active = onTiles && _focus.ringVisible;
    _buttonRing.active = _focus.zone == ZoneButtons && _focus.ringVisible;
    if (onTiles) [_row scrollRectToVisible:CGRectInset(_tiles[(NSUInteger)_focus.index].frame, -HEARTH_TILE_SPACING, 0) animated:animated];
    HearthTile *ft = onTiles ? _tiles[(NSUInteger)_focus.index] : nil;
    DmFocusKind k = _focus.zone == ZoneButtons ? DmFocusHomeButton : ft.playing ? DmFocusHomeRunning : ft.game.reason ? DmFocusHomeBlocked : DmFocusHomeGame;
    NSArray *h = _focus.hintsVisible ? dm_hints_for_focus(k, NO, NO) : @[];   // no ring (after a touch), no hints
    if (![h isEqual:_shownHints]) { _shownHints = h; [_hints setHints:h]; }
}
- (void)go:(HearthDir)d {
    if ([_focus move:d]) hearth_sound(HearthSoundMove);
    [self showFocus:YES];
}

#pragma mark - Actions

- (void)activate {
    [_focus showRing];
    if (_focus.zone == ZoneButtons) { [self pressButton:[_focus indexInZone:ZoneButtons]]; return; }
    if (_focus.index < 0) return;
    HearthTile *t = _tiles[(NSUInteger)_focus.index];
    if (t.game.reason) [self explain:t.game]; else [self launch:t];
    [self showFocus:YES];
}
- (void)explain:(HearthGame *)g {
    hearth_sound(HearthSoundBack);
    NSString *what = g.reason == DM_PACK_REBUILD ? @"This game was converted for a different version of Hearth. Convert it again on your Mac (build_ipa_from_nsp.py --pack)."
        : g.reason == HEARTH_NEEDS_SIGNING ? @"This game's code is not signed for this copy of Hearth, so iPadOS will not run it. Import the game again from your Mac, which signs it for this Hearth."
        : g.reason == DM_PACK_MISSING ? @"Part of this game is missing. Import it again from your Mac."
        : @"This folder is not a game Hearth can open.";
    hearth_dialog_info(self, hearth_state_line(g), [NSString stringWithFormat:@"%@\n\n%@", what, g.why ?: @""]);
}
- (void)pressButton:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_buttonActions.count) return;
    SEL a = NSSelectorFromString(_buttonActions[(NSUInteger)i]);
    ((void (*)(id, SEL))[self methodForSelector:a])(self, a);
}
- (void)closeGame { hearth_confirm_close(self); }
// Sleep: a paused game wakes straight back into play, as a console does; without one the player is back on Home
- (void)sleep {
    if (hearth_asleep()) return;
    [_repeat stop]; [self showFocus:NO];
    __weak HearthHomeVC *w = self;
    hearth_sleep(^{ HearthHomeVC *s = w; if (hearth_home_up()) hearth_resume(); else if (s) { [s takeController]; [s becomeFirstResponder]; } });
}
- (void)openQuick {
    if (_quick || _settings) return;
    hearth_sound(HearthSoundOpen); [_repeat stop];
    HearthQuickVC *q = [HearthQuickVC new]; _quick = q;
    __weak HearthHomeVC *w = self;
    q.onClose = ^{ [w quickGone]; };
    q.onSleep = ^{ [w sleep]; };
    [self addChildViewController:q];
    q.view.frame = self.view.bounds; q.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:q.view]; [q didMoveToParentViewController:self];
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { [q padState:m lx:lx ly:ly]; });
}
- (BOOL)closeQuick { if (!_quick) return NO; [_quick close]; return YES; }   // HOME with the panel open closes only the panel
- (void)quickGone {
    HearthQuickVC *q = _quick; if (!q) return;
    _quick = nil;
    [q willMoveToParentViewController:nil]; [q.view removeFromSuperview]; [q removeFromParentViewController];
    if (!hearth_asleep()) { [self takeController]; [self becomeFirstResponder]; }
}
- (void)launch:(HearthTile *)t {
    if (_launching) return;
    HearthGame *run = hearth_running_game();
    if (run) {   // the paused game's tile goes back to it; another tile asks to close it first (the controller stays with Home meanwhile)
        if (t.playing) hearth_resume(); else hearth_launch(t.game, self.view.window, nil);
        return;
    }
    _launching = YES; hearth_sound(HearthSoundOpen);
    [_repeat stop]; dm_gamepad_set_capture(nil);   // the game takes the controller
    __block BOOL zoomed = NO;
    hearth_launch(t.game, self.view.window, ^(void (^done)(void)) { zoomed = YES; [self zoomFrom:t done:done]; });
    if (!zoomed) { _launching = NO; [self takeController]; }   // refused: Home stays
}
// The tile grows towards the middle of the screen while the screen goes dark; the game's first frame follows (Reduce Motion: only the fade)
- (void)zoomFrom:(HearthTile *)t done:(void (^)(void))done {
    UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds]; cover.backgroundColor = UIColor.blackColor; cover.alpha = 0;
    UIView *snap = [t.art snapshotViewAfterScreenUpdates:NO]; snap.frame = [t convertRect:t.art.frame toView:self.view];
    [self.view addSubview:cover]; [self.view addSubview:snap]; t.art.hidden = YES;   // the snapshot leaves its place: no second copy stays behind under it
    BOOL calm = UIAccessibilityIsReduceMotionEnabled(); CGPoint mid = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    [UIView animateWithDuration:HEARTH_LAUNCH_SECONDS delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        cover.alpha = 1; snap.alpha = 0;
        if (!calm) { snap.center = mid; snap.transform = CGAffineTransformMakeScale(2.2, 2.2); }
    } completion:^(BOOL f) { (void)f; t.art.hidden = NO; done(); }];
}
- (void)openSettings { [self showSheet:hearth_system_settings(self.view.bounds.size)]; }
- (void)openUser:(HearthUser *)u {   // a picture in the top bar: that user on the Users page
    if (_settings || _quick) return;
    DmSettingsVC *v = hearth_system_settings(self.view.bounds.size); [self showSheet:v]; hearth_settings_show_user(v, u.uid);
}
- (void)openOptions:(HearthGame *)g {
    __weak HearthHomeVC *w = self;
    fprintf(stderr, "hearth: Options of %s\n", g.titleId.UTF8String);
    [self showSheet:hearth_options(g, self.view.bounds.size, ^{ [w closeSettings]; })];   // a deleted game: back to Home, which lists the games again
}
// System Settings or a game's Options, over Home; it has the controller until it closes
- (void)showSheet:(DmSettingsVC *)vc {
    if (_settings || _quick) return;
    hearth_sound(HearthSoundOpen); [_repeat stop];
    __weak HearthHomeVC *w = self;
    vc.onClose = ^{ [w closeSettings]; };
    vc.onRestart = ^{ if (hearth_running_game()) hearth_restart_game(); else [w closeSettings]; };   // with no game running the next launch reads the new values anyway
    _settings = vc; [self addChildViewController:vc];
    vc.view.frame = self.view.bounds; vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    vc.view.alpha = 0; vc.view.transform = CGAffineTransformMakeScale(0.97, 0.97);
    [self.view addSubview:vc.view]; [vc didMoveToParentViewController:self];
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { [vc padState:m lx:lx ly:ly]; });
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ vc.view.alpha = 1; vc.view.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)closeSettings {
    DmSettingsVC *vc = _settings; if (!vc) return;
    _settings = nil; hearth_sound(HearthSoundBack);
    [vc willMoveToParentViewController:nil];
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{ vc.view.alpha = 0; vc.view.transform = CGAffineTransformMakeScale(0.98, 0.98); }
                     completion:^(BOOL f) { (void)f; [vc.view removeFromSuperview]; [vc removeFromParentViewController]; }];
    [self takeController]; [self becomeFirstResponder]; [self reload];   // the player's name may have changed
}

#pragma mark - Touch

- (void)tileTapped:(HearthTile *)t {
    NSUInteger i = [_tiles indexOfObject:t]; if (i == NSNotFound) return;
    [_focus touched]; [_focus focusZone:ZoneTiles index:(NSInteger)i]; [self showFocus:YES];
    if (t.game.reason) [self explain:t.game]; else [self launch:t];
}
- (void)tileHeld:(UILongPressGestureRecognizer *)g {
    HearthTile *t = (HearthTile *)g.view; NSUInteger i = [_tiles indexOfObject:t];
    if (g.state != UIGestureRecognizerStateBegan || i == NSNotFound) return;
    [_focus touched]; [_focus focusZone:ZoneTiles index:(NSInteger)i]; [self showFocus:YES];
    [self openOptions:t.game];
}
- (void)buttonTapped:(HearthRoundButton *)b {
    NSUInteger i = [_buttons indexOfObject:b]; if (i == NSNotFound) return;
    [_focus touched]; [_focus focusZone:ZoneButtons index:(NSInteger)i]; [self showFocus:YES];
    [self pressButton:(NSInteger)i];
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)s { (void)s; [_focus touched]; [self showFocus:NO]; }

#pragma mark - Controller and keyboard

static HearthDir dir_of(uint64_t m, int32_t lx, int32_t ly) {
    if (m & 1ull << DMB_UP || ly > 20000) return HearthDirUp;
    if (m & 1ull << DMB_DOWN || ly < -20000) return HearthDirDown;
    if (m & 1ull << DMB_LEFT || lx < -20000) return HearthDirLeft;
    if (m & 1ull << DMB_RIGHT || lx > 20000) return HearthDirRight;
    return HearthDirNone;
}
- (void)takeController {
    _baselined = NO;
    __weak HearthHomeVC *w = self;
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { [w padState:m lx:lx ly:ly]; });
}
- (void)padState:(uint64_t)m lx:(int32_t)lx ly:(int32_t)ly {
    HearthDir d = dir_of(m, lx, ly);
    uint64_t want = m & (1ull << DMB_A | 1ull << DMB_B | 1ull << DMB_X | 1ull << DMB_PLUS | 1ull << DMB_MINUS);
    if (!_baselined) { _baselined = YES; _prev = want; if (d) [_repeat hold:d step:nil]; return; }   // what is held when Home takes the controller does nothing until released
    uint64_t up = want & ~_prev; _prev = want;
    if (d != (HearthDir)_repeat.held) {
        [_repeat stop];
        if (d) { [self go:d]; __weak HearthHomeVC *w = self; [_repeat hold:d step:^NSTimeInterval { [w go:d]; return DM_REPEAT_NEXT; }]; }
    }
    if (up & 1ull << DMB_A) [self activate];
    if (up & (1ull << DMB_PLUS | 1ull << DMB_MINUS) && _focus.zone == ZoneTiles && _focus.index >= 0) { [_focus showRing]; [self openOptions:_tiles[(NSUInteger)_focus.index].game]; return; }
    if (up & 1ull << DMB_X && _focus.zone == ZoneTiles && _focus.index >= 0 && _tiles[(NSUInteger)_focus.index].playing) { [_focus showRing]; hearth_confirm_close(self); }
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    if (_settings || _quick || _launching) return @[];
    NSMutableArray *r = [NSMutableArray array];
    for (NSArray *p in @[@[UIKeyInputUpArrow, @"keyUp"], @[UIKeyInputDownArrow, @"keyDown"], @[UIKeyInputLeftArrow, @"keyLeft"], @[UIKeyInputRightArrow, @"keyRight"], @[@"\r", @"activate"]]) {
        UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:p[0] modifierFlags:0 action:NSSelectorFromString(p[1])]; c.wantsPriorityOverSystemBehavior = YES; [r addObject:c];
    }
    [r addObject:[UIKeyCommand keyCommandWithInput:@"," modifierFlags:UIKeyModifierCommand action:@selector(openSettings)]];
    if (_overlay) [r addObject:[UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:UIKeyModifierCommand action:@selector(keyHome)]];   // HOME: back to the game
    return r;
}
- (void)keyHome { hearth_home(); }
- (void)keyUp { [self go:HearthDirUp]; }
- (void)keyDown { [self go:HearthDirDown]; }
- (void)keyLeft { [self go:HearthDirLeft]; }
- (void)keyRight { [self go:HearthDirRight]; }

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
