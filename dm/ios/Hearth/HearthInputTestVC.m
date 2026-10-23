// Test input (HearthInputTestVC.h)
#import "HearthInputTestVC.h"
#import "HearthSound.h"
#import "DmSettingsViews.h"
#import "DmPadBits.h"
#import "keymap.h"

void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly));
void dm_gamepad_set_monitor(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry));

static const NSTimeInterval HOLD_TO_LEAVE = 1.0;
enum { COLS = 4 };

@interface HearthStickView : UIView
@property (nonatomic) CGPoint at;   // -1...1 each way, y up
@end
@implementation HearthStickView { UIView *_dot; }
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.layer.borderWidth = 2; _dot = [UIView new]; [self addSubview:_dot];
    __weak HearthStickView *w = self; dm_on_style(self, ^{ HearthStickView *s = w; s.layer.borderColor = DmUI.sep.CGColor; s.backgroundColor = DmUI.row; s->_dot.backgroundColor = DmUI.accent; });
    return self;
}
- (void)setAt:(CGPoint)at { _at = at; [self setNeedsLayout]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = self.bounds.size.width / 2, d = r * 0.4; self.layer.cornerRadius = r; _dot.layer.cornerRadius = d / 2;
    _dot.frame = CGRectMake(r + _at.x * (r - d / 2) - d / 2, r - _at.y * (r - d / 2) - d / 2, d, d);
}
@end

@implementation HearthInputTestVC {
    UILabel *_head, *_line; UIButton *_done; NSArray<UILabel *> *_chips; NSArray<HearthStickView *> *_sticks; NSArray<UILabel *> *_stickNames;
    uint64_t _held; NSUInteger _holdGen; BOOL _closing;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    __weak HearthInputTestVC *w = self; dm_on_style(self.view, ^{ w.view.backgroundColor = DmUI.bg; });
    _head = [UILabel new]; _head.text = @"Test input"; _head.textColor = DmUI.text; _head.accessibilityTraits = UIAccessibilityTraitHeader;
    _line = [UILabel new]; _line.text = @"Press any button or key. Hold B or press Escape to go back."; _line.textColor = DmUI.sub; _line.numberOfLines = 0;
    UIButtonConfiguration *c = UIButtonConfiguration.filledButtonConfiguration; c.title = @"Done"; c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.baseBackgroundColor = DmUI.row; c.baseForegroundColor = DmUI.text;
    _done = [UIButton buttonWithConfiguration:c primaryAction:nil]; [_done addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    NSMutableArray *chips = [NSMutableArray array];
    for (int b = 0; b < DM_KEYMAP_BUTTONS; b++) {
        UILabel *l = [UILabel new]; l.text = @(dm_keymap_row_label[b]); l.textAlignment = NSTextAlignmentCenter; l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.6;
        l.layer.cornerRadius = 12; l.layer.cornerCurve = kCACornerCurveContinuous; l.clipsToBounds = YES; [chips addObject:l];
    }
    _chips = chips;
    _sticks = @[[HearthStickView new], [HearthStickView new]];
    UILabel *ln = [UILabel new], *rn = [UILabel new]; ln.text = @"Left stick"; rn.text = @"Right stick"; _stickNames = @[ln, rn];
    for (UILabel *l in _stickNames) { l.textColor = DmUI.sub; l.textAlignment = NSTextAlignmentCenter; }
    for (NSArray<UIView *> *group in @[@[_head, _line, _done], _chips, _sticks, _stickNames]) for (UIView *v in group) [self.view addSubview:v];
    [self show:0 lx:0 ly:0 rx:0 ry:0];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    __weak HearthInputTestVC *w = self;
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { (void)m; (void)lx; (void)ly; });   // the page under it stays still; the monitor below shows the input
    dm_gamepad_set_monitor(^(uint64_t m, int32_t lx, int32_t ly, int32_t rx, int32_t ry) { [w show:m lx:lx ly:ly rx:rx ry:ry]; });
    [self becomeFirstResponder];
    fprintf(stderr, "hearth: Test input opened\n");
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize s = self.view.bounds.size; UIEdgeInsets sa = self.view.safeAreaInsets; BOOL compact = MIN(s.width, s.height) < 500;
    CGFloat m = compact ? 20 : 48, gap = compact ? 8 : 12, chipH = compact ? 34 : 50, stick = compact ? 96 : 170, x = MAX(m, sa.left), right = s.width - MAX(m, sa.right), y = MAX(m * 0.6, sa.top + 12);
    _head.font = [DmUI font:compact ? 24 : 34 weight:UIFontWeightBold]; _line.font = [DmUI font:compact ? 15 : 18 weight:UIFontWeightMedium];
    CGSize ds = [_done sizeThatFits:CGSizeMake(200, 44)]; _done.frame = CGRectMake(right - ds.width - 8, y, ds.width + 8, MAX(ds.height, 44));
    _head.frame = CGRectMake(x, y, right - x - _done.frame.size.width - gap, compact ? 30 : 42); y = CGRectGetMaxY(_head.frame) + 4;
    CGFloat lh = [_line sizeThatFits:CGSizeMake(right - x, 200)].height; _line.frame = CGRectMake(x, y, right - x, lh); y += lh + (compact ? 12 : 24);
    CGFloat cw = (right - x - gap * (COLS - 1)) / COLS;
    for (NSUInteger i = 0; i < _chips.count; i++) {
        _chips[i].font = [DmUI font:compact ? 15 : 19 weight:UIFontWeightSemibold];
        _chips[i].frame = CGRectMake(x + (i % COLS) * (cw + gap), y + (i / COLS) * (chipH + gap), cw, chipH);
    }
    y += (_chips.count + COLS - 1) / COLS * (chipH + gap) + (compact ? 4 : 16);
    CGFloat nameH = compact ? 18 : 24, mid = (x + right) / 2, sp = compact ? 60 : 120;
    stick = MIN(stick, s.height - MAX(m * 0.6, sa.bottom + 8) - y - nameH - 4);
    for (NSUInteger i = 0; i < 2; i++) {
        CGFloat cx = i == 0 ? mid - sp / 2 - stick / 2 : mid + sp / 2 + stick / 2;
        _sticks[i].frame = CGRectMake(cx - stick / 2, y, stick, stick);
        _stickNames[i].font = [DmUI font:compact ? 14 : 17 weight:UIFontWeightMedium]; _stickNames[i].frame = CGRectMake(cx - 100, y + stick + 4, 200, nameH);
    }
}

- (void)show:(uint64_t)m lx:(int32_t)lx ly:(int32_t)ly rx:(int32_t)rx ry:(int32_t)ry {
    if (_closing) return;
    for (NSUInteger b = 0; b < _chips.count; b++) {
        BOOL on = m >> b & 1; UILabel *l = _chips[b];
        l.backgroundColor = on ? DmUI.accent : DmUI.row; l.textColor = on ? UIColor.blackColor : DmUI.text;
        l.accessibilityValue = on ? @"Held" : @"Not held";
    }
    _sticks[0].at = CGPointMake(lx / 32767.0, ly / 32767.0); _sticks[1].at = CGPointMake(rx / 32767.0, ry / 32767.0);
    BOOL b = m >> DMB_B & 1, was = _held >> DMB_B & 1; _held = m;
    if (b == was) return;
    NSUInteger gen = ++_holdGen;   // B held on for HOLD_TO_LEAVE with no release in between leaves
    if (!b) return;
    __weak HearthInputTestVC *w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(HOLD_TO_LEAVE * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HearthInputTestVC *s = w; if (s && gen == s->_holdGen) [s close];
    });
}
- (void)close {
    if (_closing) return;
    _closing = YES; dm_gamepad_set_monitor(nil); hearth_sound(HearthSoundBack);
    fprintf(stderr, "hearth: Test input closed\n");
    if (self.onClose) self.onClose();
}
- (BOOL)accessibilityPerformEscape { [self close]; return YES; }
- (BOOL)canBecomeFirstResponder { return YES; }
// Escape leaves; every other key the settings page under it would take does nothing here (the keyboard plays through GameController, which the monitor shows)
- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *k in @[UIKeyInputEscape, UIKeyInputUpArrow, UIKeyInputDownArrow, UIKeyInputLeftArrow, UIKeyInputRightArrow, @"\r", @"\t", @" ", @"[", @"]"]) {
        UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:k modifierFlags:0 action:[k isEqual:UIKeyInputEscape] ? @selector(close) : @selector(swallow)];
        c.wantsPriorityOverSystemBehavior = YES; [r addObject:c];
    }
    return r;
}
- (void)swallow {}
@end
