// Hearth's Home screen (HearthHomeVC.h): the player and the time at the top, one row of game tiles (last played first), the system buttons under it, the button hints at the bottom right.
// Focus (HearthFocus.h): zone 0 the tiles, zone 1 the buttons. A controller (captured while Home is up), a hardware keyboard and touch all drive it; a touch hides the ring until the next key or button.
#import "HearthHomeVC.h"
#import "HearthHomeViews.h"
#import "HearthFocus.h"
#import "HearthLaunch.h"
#import "HearthTheme.h"
#import "HearthSound.h"
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
    HearthTopBar *_bar; UIScrollView *_row; UILabel *_empty; NSMutableArray<HearthTile *> *_tiles; NSArray<HearthRoundButton *> *_buttons;
    DmFocusView *_tileRing, *_buttonRing; DmHintBar *_hints; NSArray *_shownHints;
    HearthFocus *_focus; DmRepeat *_repeat; uint64_t _prev; BOOL _baselined, _launching;
    DmSettingsVC *_settings;
}

#pragma mark - Build

- (void)viewDidLoad {
    [super viewDidLoad];
    __weak HearthHomeVC *w = self;
    dm_on_style(self.view, ^{ w.view.backgroundColor = DmUI.bg; });   // opaque over the game too: a see-through Home showed the game's touch controls and, back from the background, its paused frame
    _focus = [[HearthFocus alloc] initWithZones:ZoneCount]; _repeat = [DmRepeat new]; _tiles = [NSMutableArray array];
    _bar = [HearthTopBar new];
    _row = [UIScrollView new]; _row.showsHorizontalScrollIndicator = NO; _row.showsVerticalScrollIndicator = NO; _row.alwaysBounceVertical = NO; _row.clipsToBounds = NO; _row.delegate = self;
    _row.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _tileRing = [DmFocusView new]; _tileRing.radius = HEARTH_TILE_RADIUS + 6; [_row addSubview:_tileRing];
    _empty = [UILabel new]; _empty.text = @"No games yet"; _empty.font = [DmUI font:22 weight:UIFontWeightSemibold]; _empty.textColor = DmUI.sub; _empty.textAlignment = NSTextAlignmentCenter;
    HearthRoundButton *settings = [[HearthRoundButton alloc] initWithSymbol:@"gearshape.fill" label:@"Settings"];
    _buttons = @[settings];
    if (_overlay) _buttons = [_buttons arrayByAddingObject:[[HearthRoundButton alloc] initWithSymbol:@"xmark" label:@"Close the game"]];   // touch's way to close the paused game
    for (HearthRoundButton *b in _buttons) [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    _buttonRing = [DmFocusView new]; _buttonRing.radius = HEARTH_BUTTON_SIZE / 2 + 6;
    _hints = [DmHintBar new];
    for (UIView *v in @[_bar, _row, _empty, _buttonRing, _hints]) [self.view addSubview:v];
    for (UIView *v in _buttons) [self.view insertSubview:v belowSubview:_buttonRing];
    [_focus setCount:(NSInteger)_buttons.count forZone:ZoneButtons];
    dm_gamepad_watch();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:UIApplicationDidBecomeActiveNotification object:nil];
}
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
    for (HearthGame *g in games) {
        HearthTile *t = [[HearthTile alloc] initWithGame:g]; t.playing = g == run;
        [t addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_row insertSubview:t belowSubview:_tileRing]; [_tiles addObject:t];
    }
    _empty.hidden = _tiles.count > 0;
    [_focus setCount:(NSInteger)_tiles.count forZone:ZoneTiles];
    for (NSUInteger i = 0; i < _tiles.count; i++) if ([_tiles[i].game.titleId isEqual:was]) [_focus focusZone:ZoneTiles index:(NSInteger)i];
    [_bar setPlayer:[DmSettings.systemStore valueForKey:@"DM_NICK"]];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    [self showFocus:NO];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; UIEdgeInsets si = self.view.safeAreaInsets;
    CGFloat left = MAX(si.left, 0) + HEARTH_MARGIN, right = b.size.width - MAX(si.right, 0) - HEARTH_MARGIN, top = MAX(si.top, 0) + 24;
    CGFloat hh = [_hints heightWithCompact:NO], bottom = b.size.height - MAX(si.bottom, 16) - hh;
    _bar.frame = CGRectMake(left, top, right - left, 48);
    _hints.frame = CGRectMake(left, bottom, right - left, hh);
    CGFloat by = bottom - 36 - HEARTH_BUTTON_SIZE, bw = _buttons.count * HEARTH_BUTTON_SIZE + (_buttons.count - 1) * 28.0, bx = (b.size.width - bw) / 2;
    for (NSUInteger i = 0; i < _buttons.count; i++) _buttons[i].frame = CGRectMake(bx + i * (HEARTH_BUTTON_SIZE + 28), by, HEARTH_BUTTON_SIZE, HEARTH_BUTTON_SIZE);
    CGFloat th = _tiles.count ? _tiles[0].bounds.size.height : 300, rowTop = CGRectGetMaxY(_bar.frame) + 12;
    CGFloat ry = rowTop + MAX(0, (by - 24 - rowTop - th) / 2);   // the row sits in the middle of the space between the bar and the buttons
    _row.frame = CGRectMake(0, ry, b.size.width, th);
    CGFloat total = _tiles.count * HEARTH_TILE_SIZE + (_tiles.count ? _tiles.count - 1 : 0) * HEARTH_TILE_SPACING;
    CGFloat x0 = total < right - left ? (b.size.width - total) / 2 : left;   // a short row is centred, a long one starts at the margin and scrolls
    for (NSUInteger i = 0; i < _tiles.count; i++) {
        HearthTile *t = _tiles[i]; CGAffineTransform keep = t.art.transform; t.art.transform = CGAffineTransformIdentity;
        t.frame = CGRectMake(x0 + i * (HEARTH_TILE_SIZE + HEARTH_TILE_SPACING), 0, HEARTH_TILE_SIZE, th);
        t.art.transform = keep;
    }
    _row.contentSize = CGSizeMake(MAX(x0 * 2 + total, b.size.width), th);
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
            CGRect a = CGRectOffset(CGRectMake(0, 0, HEARTH_TILE_SIZE, HEARTH_TILE_SIZE), t.frame.origin.x, t.frame.origin.y + t.art.center.y - HEARTH_TILE_SIZE / 2);
            CGFloat grow = HEARTH_TILE_SIZE * (HEARTH_TILE_FOCUS_SCALE - 1) / 2;
            self->_tileRing.frame = CGRectInset(a, -grow - 6, -grow - 6);
        }
        if (self->_focus.zone == ZoneButtons) self->_buttonRing.frame = CGRectInset(self->_buttons[(NSUInteger)[self->_focus indexInZone:ZoneButtons]].frame, -6, -6);
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled())
        [UIView animateWithDuration:HEARTH_FOCUS_SECONDS delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:place completion:nil];
    else place();
    _tileRing.active = onTiles && _focus.ringVisible;
    _buttonRing.active = _focus.zone == ZoneButtons && _focus.ringVisible;
    if (onTiles) [_row scrollRectToVisible:CGRectInset(_tiles[(NSUInteger)_focus.index].frame, -HEARTH_TILE_SPACING, 0) animated:animated];
    HearthTile *ft = onTiles ? _tiles[(NSUInteger)_focus.index] : nil;
    DmFocusKind k = _focus.zone == ZoneButtons ? DmFocusHomeButton : ft.playing ? DmFocusHomeRunning : ft.game.reason ? DmFocusHomeBlocked : DmFocusHomeGame;
    NSArray *h = onTiles || _focus.zone == ZoneButtons ? dm_hints_for_focus(k, NO, NO) : @[];
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
    UIAlertController *a = [UIAlertController alertControllerWithTitle:hearth_state_line(g) message:[NSString stringWithFormat:@"%@\n\n%@", what, g.why ?: @""] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)pressButton:(NSInteger)i {
    if (i == 0) [self openSettings];
    else hearth_confirm_close(self);   // overlay only: Close the game
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
- (void)openSettings {
    if (_settings) return;
    hearth_sound(HearthSoundOpen); [_repeat stop];
    DmSettingsVC *vc = [[DmSettingsVC alloc] initWithSettings:DmSettings.systemStore size:self.view.bounds.size];
    __weak HearthHomeVC *w = self;
    vc.onClose = ^{ [w closeSettings]; };
    vc.onRestart = ^{ [w closeSettings]; };   // no game runs: the next launch reads the new values anyway
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
    uint64_t want = m & (1ull << DMB_A | 1ull << DMB_B | 1ull << DMB_X);
    if (!_baselined) { _baselined = YES; _prev = want; if (d) [_repeat hold:d step:nil]; return; }   // what is held when Home takes the controller does nothing until released
    uint64_t up = want & ~_prev; _prev = want;
    if (self.presentedViewController) {   // a dialog is up: A answers it (Close, Close and Start, or OK), B cancels
        if (up & (1ull << DMB_A | 1ull << DMB_B)) hearth_dialog_answer(self, (up & 1ull << DMB_A) != 0);
        return;
    }
    if (d != (HearthDir)_repeat.held) {
        [_repeat stop];
        if (d) { [self go:d]; __weak HearthHomeVC *w = self; [_repeat hold:d step:^NSTimeInterval { [w go:d]; return DM_REPEAT_NEXT; }]; }
    }
    if (up & 1ull << DMB_A) [self activate];
    if (up & 1ull << DMB_X && _focus.zone == ZoneTiles && _focus.index >= 0 && _tiles[(NSUInteger)_focus.index].playing) { [_focus showRing]; hearth_confirm_close(self); }
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    if (_settings || _launching) return @[];
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
