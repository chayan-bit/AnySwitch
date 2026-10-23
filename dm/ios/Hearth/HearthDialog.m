// Hearth's dialog (HearthDialog.h)
#import "HearthDialog.h"
#import "HearthFocus.h"
#import "HearthSound.h"
#import "HearthTheme.h"
#import "DmSettingsViews.h"
#import "DmPadBits.h"
#import "DmRepeat.h"

typedef void (^HearthPadHandler)(uint64_t buttons, int32_t lx, int32_t ly);
void dm_gamepad_set_capture(HearthPadHandler handler);
HearthPadHandler dm_gamepad_capture(void);   // DmGamepad.m: the handler that holds the controller now (nil: the game)

#define BTN_H 56.0
#define LABEL_TAG 100   // a button's own tag is its index
#define IMAGE_TAG 101
#define TILE_MAX 116.0   // a picture tile's edge (hearth_dialog_tiles), smaller when many do not fit
#define TILE_LABEL 34.0

@interface HearthDialogVC : UIViewController
@end

@implementation HearthDialogVC {
    NSString *_title, *_message; NSArray<NSString *> *_names; NSArray *_images; NSInteger _destructive, _cancel; void (^_answer)(NSInteger);   // _images: a picture per button (NSNull: none), nil for a plain dialog
    UIView *_dim, *_panel; UILabel *_titleLabel, *_messageLabel; NSMutableArray<UIControl *> *_buttons; DmFocusView *_ring; DmHintBar *_hints;
    HearthFocus *_focus; DmRepeat *_repeat; uint64_t _prev; BOOL _baselined, _done; __weak UIViewController *_over;
    HearthPadHandler _pad, _before; BOOL _took;   // our controller handler; the one that held the controller before us
}

+ (void)show:(UIViewController *)over title:(NSString *)title message:(NSString *)message buttons:(NSArray<NSString *> *)names images:(NSArray *)images destructive:(NSInteger)destructive focus:(NSInteger)focus cancel:(NSInteger)cancel answer:(void (^)(NSInteger))answer {
    while (over.presentedViewController) over = over.presentedViewController;
    HearthDialogVC *d = [self new]; d->_images = images;
    d->_title = title; d->_message = message; d->_names = names; d->_destructive = destructive; d->_cancel = cancel; d->_answer = answer; d->_over = over;
    d->_focus = [[HearthFocus alloc] initWithZones:1]; [d->_focus setCount:(NSInteger)names.count forZone:0]; [d->_focus focusZone:0 index:MIN(MAX(focus, 0), (NSInteger)names.count - 1)];
    d.modalPresentationStyle = UIModalPresentationOverFullScreen; d.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    fprintf(stderr, "hearth: dialog shown: %s\n", title.UTF8String);
    [over presentViewController:d animated:YES completion:nil];
    __weak HearthDialogVC *w = d;
    d->_before = dm_gamepad_capture(); d->_took = YES;
    d->_pad = [^(uint64_t m, int32_t lx, int32_t ly) { [w padState:m lx:lx ly:ly]; } copy];
    dm_gamepad_set_capture(d->_pad);
}

- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

#pragma mark - Build

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor; self.view.accessibilityViewIsModal = YES;
    _repeat = [DmRepeat new]; _buttons = [NSMutableArray array];
    _dim = [UIView new]; _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outside)]];
    _panel = [UIView new]; _panel.layer.cornerRadius = 30; _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.layer.shadowOpacity = 0.3; _panel.layer.shadowRadius = 30; _panel.layer.shadowOffset = CGSizeMake(0, 12);
    _titleLabel = [UILabel new]; _titleLabel.text = _title; _titleLabel.font = [DmUI font:26 weight:UIFontWeightBold]; _titleLabel.textColor = DmUI.text; _titleLabel.numberOfLines = 0;
    _messageLabel = [UILabel new]; _messageLabel.text = _message; _messageLabel.font = [DmUI font:18 weight:UIFontWeightRegular]; _messageLabel.textColor = DmUI.sub; _messageLabel.numberOfLines = 0;
    _hints = [DmHintBar new];
    _ring = [DmFocusView new]; _ring.radius = 22;
    [self.view addSubview:_dim]; [self.view addSubview:_panel];
    for (UIView *v in @[_titleLabel, _messageLabel, _hints]) [_panel addSubview:v];
    for (NSUInteger i = 0; i < _names.count; i++) {
        UIControl *b = [UIControl new]; b.layer.cornerRadius = 18; b.layer.cornerCurve = kCACornerCurveContinuous; b.tag = (NSInteger)i;
        UILabel *l = [UILabel new]; l.text = _names[i]; l.font = [DmUI font:20 weight:UIFontWeightSemibold]; l.textAlignment = NSTextAlignmentCenter; l.userInteractionEnabled = NO; l.tag = LABEL_TAG;
        l.textColor = (NSInteger)i == _destructive ? DmUI.warn : DmUI.text;
        if (i < _images.count && [_images[i] isKindOfClass:UIImage.class]) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:_images[i]]; iv.tag = IMAGE_TAG; iv.contentMode = UIViewContentModeScaleAspectFill; iv.clipsToBounds = YES; iv.userInteractionEnabled = NO;
            [b addSubview:iv]; l.font = [DmUI font:17 weight:UIFontWeightSemibold]; l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.7;
        }
        [b addSubview:l]; [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
        b.isAccessibilityElement = YES; b.accessibilityLabel = _names[i]; b.accessibilityTraits = UIAccessibilityTraitButton;
        [_panel addSubview:b]; [_buttons addObject:b];
    }
    [_panel addSubview:_ring];
    __weak HearthDialogVC *w = self;
    dm_on_style(_panel, ^{ HearthDialogVC *s = w; if (!s) return; s->_panel.backgroundColor = DmUI.panel; s->_panel.layer.shadowColor = UIColor.blackColor.CGColor; for (UIControl *b in s->_buttons) b.backgroundColor = DmUI.row; });
    [self showFocus:NO];
}
- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    _panel.transform = CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ self->_panel.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self becomeFirstResponder]; hearth_sound(HearthSoundOpen); }
- (void)viewDidDisappear:(BOOL)a {
    [super viewDidDisappear:a];
    if (!_done) { _done = YES; [_repeat stop]; if (_took && dm_gamepad_capture() == _pad) dm_gamepad_set_capture(_before); }   // taken away from outside (HOME resumed the game): the controller goes to whoever has it now
}
- (void)dealloc { [_repeat stop]; }

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; _dim.frame = b;
    CGFloat pad = 32, n = (CGFloat)_buttons.count, gap = 14, tile = _images ? MIN(TILE_MAX, floor((b.size.width - 80 - pad * 2 - gap * (n - 1)) / n)) : 0;
    CGFloat w = _images ? MIN(b.size.width - 80, MAX(580, n * tile + gap * (n - 1) + pad * 2)) : MIN(580, b.size.width - 80), iw = w - pad * 2, y = pad;
    CGAffineTransform t = _panel.transform; _panel.transform = CGAffineTransformIdentity;
    CGFloat th = ceil([_titleLabel sizeThatFits:CGSizeMake(iw, CGFLOAT_MAX)].height), mh = _message.length ? ceil([_messageLabel sizeThatFits:CGSizeMake(iw, CGFLOAT_MAX)].height) : 0;
    _titleLabel.frame = CGRectMake(pad, y, iw, th); y += th + (mh ? 10 : 0);
    _messageLabel.frame = CGRectMake(pad, y, iw, mh); y += mh + 28;
    CGFloat bw = _images ? tile : n > 1 ? (iw - gap * (n - 1)) / n : iw, bh = _images ? tile + TILE_LABEL : BTN_H, x0 = _images ? pad + (iw - (n * tile + gap * (n - 1))) / 2 : pad;
    for (NSUInteger i = 0; i < _buttons.count; i++) {
        UIControl *c = _buttons[i]; c.frame = CGRectMake(x0 + i * (bw + gap), y, bw, bh);
        UIView *iv = [c viewWithTag:IMAGE_TAG], *l = [c viewWithTag:LABEL_TAG];
        if (!_images) { l.frame = c.bounds; continue; }
        if (iv) { CGFloat e = tile - 20; iv.frame = CGRectMake(10, 10, e, e); iv.layer.cornerRadius = e / 2; l.frame = CGRectMake(6, tile - 2, tile - 12, TILE_LABEL - 4); }
        else l.frame = c.bounds;   // a tile without a picture (Cancel): its name in the middle
    }
    y += bh + 16;
    CGFloat hh = [_hints heightWithCompact:NO]; _hints.frame = CGRectMake(pad, y, iw, hh); y += hh + 22;
    _panel.frame = CGRectMake(0, 0, w, y); _panel.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)); _panel.transform = t;
    _panel.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_panel.bounds cornerRadius:30].CGPath;
    [self placeRing:NO];
}

#pragma mark - Focus

- (void)placeRing:(BOOL)animated {
    NSInteger i = _focus.index; if (i < 0 || i >= (NSInteger)_buttons.count) return;
    CGRect f = CGRectInset(_buttons[(NSUInteger)i].frame, -4, -4);
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) [UIView animateWithDuration:HEARTH_FOCUS_SECONDS delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{ self->_ring.frame = f; } completion:nil];
    else _ring.frame = f;
}
- (void)showFocus:(BOOL)animated {
    [self placeRing:animated];
    _ring.active = _focus.ringVisible;
    NSString *yes = _focus.index >= 0 ? _names[(NSUInteger)_focus.index] : @"OK";
    BOOL cancelHint = _cancel >= 0 && _cancel != _focus.index;   // B is worth a hint only when it does something other than A
    NSArray *h = !_focus.hintsVisible ? @[] : cancelHint ? @[@[@"A", yes], @[@"B", _names[(NSUInteger)_cancel]]] : @[@[@"A", yes]];
    [_hints setHints:h];
}
- (void)go:(HearthDir)d {
    if ([_focus move:d]) hearth_sound(HearthSoundMove);
    [self showFocus:YES];
}

#pragma mark - Answers

- (void)finish:(NSInteger)i {
    if (_done || i < 0 || i >= (NSInteger)_names.count) return;
    _done = YES; [_repeat stop];
    fprintf(stderr, "hearth: dialog: %s\n", _names[(NSUInteger)i].UTF8String);
    hearth_sound(i == _cancel ? HearthSoundBack : i == _destructive ? HearthSoundClose : HearthSoundOpen);
    [self handBack];
    void (^answer)(NSInteger) = _answer; UIViewController *over = _over;
    [self dismissViewControllerAnimated:YES completion:^{ [over becomeFirstResponder]; if (answer) answer(i); }];
}
// Whoever had the controller gets it back once every button is up, so the press that answered the dialog does nothing there
- (void)handBack {
    if (!_took) return;
    _took = NO;
    HearthPadHandler before = _before;
    __block HearthPadHandler wait = nil;
    wait = [^(uint64_t m, int32_t lx, int32_t ly) {
        if (m || lx > 20000 || lx < -20000 || ly > 20000 || ly < -20000) return;
        HearthPadHandler me = wait; wait = nil;   // the block's own place in the cycle: dropped here
        dispatch_async(dispatch_get_main_queue(), ^{ if (dm_gamepad_capture() == me) dm_gamepad_set_capture(before); });   // not from inside the handler that is being replaced
    } copy];
    if (dm_gamepad_capture() == _pad) dm_gamepad_set_capture(wait);
}
- (void)buttonTapped:(UIControl *)b { [_focus touched]; [_focus focusZone:0 index:b.tag]; [self showFocus:YES]; [self finish:b.tag]; }
- (void)outside { if (_cancel >= 0) { [_focus touched]; [self finish:_cancel]; } }
- (void)cancel { if (_cancel >= 0) [self finish:_cancel]; }
- (void)choose { [_focus showRing]; [self finish:_focus.index]; }

#pragma mark - Controller and keyboard

- (void)padState:(uint64_t)m lx:(int32_t)lx ly:(int32_t)ly {
    HearthDir d = m & 1ull << DMB_LEFT || lx < -20000 ? HearthDirLeft : m & 1ull << DMB_RIGHT || lx > 20000 ? HearthDirRight : HearthDirNone;
    uint64_t want = m & (1ull << DMB_A | 1ull << DMB_B);
    if (!_baselined) { _baselined = YES; _prev = want; if (d) [_repeat hold:d step:nil]; return; }   // what is held when the dialog opens does nothing until it is released
    uint64_t up = want & ~_prev; _prev = want;
    if (d != (HearthDir)_repeat.held) {
        [_repeat stop];
        if (d) { [self go:d]; __weak HearthDialogVC *w = self; [_repeat hold:d step:^NSTimeInterval { [w go:d]; return DM_REPEAT_NEXT; }]; }
    }
    if (up & 1ull << DMB_A) [self choose]; else if (up & 1ull << DMB_B) [self cancel];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray *r = [NSMutableArray array];
    for (NSArray *p in @[@[UIKeyInputLeftArrow, @"keyLeft"], @[UIKeyInputRightArrow, @"keyRight"], @[@"\r", @"choose"], @[UIKeyInputEscape, @"cancel"]]) {
        UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:p[0] modifierFlags:0 action:NSSelectorFromString(p[1])]; c.wantsPriorityOverSystemBehavior = YES; [r addObject:c];
    }
    return r;
}
- (void)keyLeft { [self go:HearthDirLeft]; }
- (void)keyRight { [self go:HearthDirRight]; }
@end

void hearth_dialog(UIViewController *over, NSString *title, NSString *message, NSArray<NSString *> *buttons, NSInteger destructive, NSInteger focus, NSInteger cancel, void (^answer)(NSInteger index)) {
    [HearthDialogVC show:over title:title message:message buttons:buttons images:nil destructive:destructive focus:focus cancel:cancel answer:answer];
}
void hearth_dialog_tiles(UIViewController *over, NSString *title, NSString *message, NSArray<NSString *> *names, NSArray *images, NSInteger focus, NSInteger cancel, void (^answer)(NSInteger index)) {
    [HearthDialogVC show:over title:title message:message buttons:names images:images ?: @[] destructive:-1 focus:focus cancel:cancel answer:answer];
}
void hearth_dialog_info(UIViewController *over, NSString *title, NSString *message) {
    hearth_dialog(over, title, message, @[@"OK"], -1, 0, 0, nil);
}
