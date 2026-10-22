// Virtual gamepad (Nintendo button positions) + physical controllers (GameController). Both are merged and handed to the host through dm_input_set (hle_hid.c, bit layout in dm_input.h).
//   Two layouts; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D") switches them, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_FULL).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller).
//   Controls in the letterbox bars: when the picture is letterboxed top and bottom (a 16:9 game on a 4:3 iPad) and both bars are tall enough for 44 pt targets, the controls move out of the picture into the bars (front_ios.m's
//     DM_CONTROLS_LAYOUT=auto, dm_gamepad_layout): top bar ZL, L (L3 in 3D), then - / layout button / + and the frame-rate counter, then R3 (3D), R, ZR; bottom bar the left stick, (3D: the D-pad,) and the diamond.
//     The keys get a frosted look (a lighter fill, a bright rim and a soft top-lit gloss over the blurred ambient bars). Touches on the bars that no control takes are not sent to the game's touch screen.
//     With DM_CONTROLS_LAYOUT=overlay, or bars too small (a 16:10 screen), everything stays as described above, over the picture.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include <stdatomic.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#import "DmPadBits.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_capturing;   // the settings screen holds the controller (dm_gamepad_set_capture): the game sees nothing
static uint64_t g_touch_btn, g_pad_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry, g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static int tilted(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y > (int64_t)4000 * 4000; }
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    if (g_capturing) { dm_input_set(0, 0, 0, 0, 0); pthread_mutex_unlock(&g_mu); return; }   // the settings screen is open
    int32_t lx = g_touch_lx, ly = g_touch_ly, rx = g_touch_rx, ry = g_touch_ry;
    if (tilted(g_pad_lx, g_pad_ly)) { lx = g_pad_lx; ly = g_pad_ly; }   // a tilted physical stick wins
    if (tilted(g_pad_rx, g_pad_ry)) { rx = g_pad_rx; ry = g_pad_ry; }
    dm_input_set(g_touch_btn | g_pad_btn | g_shake_btn, lx, ly, rx, ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds the threshold
// (DM_SHAKE_G, 1.5 G by default: the "Shake sensitivity" setting, dm_gamepad_shake_g; every sample reads the current value, so a change applies at once) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static _Atomic double g_shake_g = 1.5;   // read by the accelerometer queue on every sample, written on the main thread
void dm_gamepad_shake_g(double g) { atomic_store_explicit(&g_shake_g, g >= 0.1 && g <= 10 ? g : 1.5, memory_order_relaxed); }   // main thread: the threshold in G (a lower number reacts to a gentler shake); out of range falls back to 1.5
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", atomic_load_explicit(&g_shake_g, memory_order_relaxed));
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > atomic_load_explicit(&g_shake_g, memory_order_relaxed)) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const CGFloat
    K_BAR_EDGE = 20,                                // bars mode: the bottom controls keep this far from the screen edge (the rounded corners; over the picture they hug it)
    K_SCALE_MIN = 0.75, K_SCALE_MAX = 2.5,          // DM_CONTROLS_SCALE range: the bottom controls (stick, diamond, D-pad) grow past the bar over the picture; at 0.75 the face keys' touch circles are still 44 pt (1.25 x radius, 22 pt floor)
    K_BAR_REF_H = 1024, K_BAR_UNIT = 7.0 / 6,       // bars mode: the unit bu of the bottom controls = K_BAR_UNIT x (screen height / K_BAR_REF_H) x scale: at scale 1 on a 13-inch iPad the stick is 180 pt across, the A / B / X / Y keys 75 pt, the D-pad 112 pt
    K_BAR_FACE_U = 32,                              // bars mode: face key radius in bu (overlay: K_FACE_R); the diamond keeps K_FACE_GAP, so neighbouring keys stay 8 pt apart at scale 1
    K_BAR_LOW_X = 220,                              // bars mode: D-pad centre from the outer edge in bu: right of the stick (3D layout)
    K_FACE_HIT = 1.25, K_HIT_MIN = 22,              // touch circle: times the key radius, never under 22 pt (44 pt across)
    K_BAR_MIN_BOTTOM = 108, K_BAR_MIN_TOP = 60,     // bars mode needs bars at least this tall (points): the diamond at 0.65 u gives 44 pt hit circles, the top row needs 44 pt plus margins
    K_BAR_L_DX = 64,                                // bars mode: L / R centre from ZL / ZR (in u, along the bar)
    K_BAR_CLICK_X = 165,                            // bars mode: L3 / R3 centre from the outer edge (in u): inward of L / R
    K_HUD_W = 64, K_HUD_H = 22,                     // the frame-rate counter's size (front_ios.m)
    K_OVERLAY_SCALE_MAX = 1.35,                     // over the picture (overlay layout) DM_CONTROLS_SCALE stops here: the bottom controls must not reach the top row
    K_CHORD_S = 0.8;                                // + and - held together this long open the settings screen (dm_gamepad_set_chord)
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static CGFloat g_scale = 1, g_opacity = 1;   // dm_gamepad_scale: size of the bottom controls, 1 = the default; dm_gamepad_opacity: how solid every control is
static void (^g_capture)(uint64_t, int32_t, int32_t);   // main thread: the physical controller's buttons (DMB_* bits) and left stick while captured
static void (^g_chord)(void);                            // main thread: + and - held together
static uint64_t g_chord_gen;
_Static_assert(B_A == DMB_A && B_B == DMB_B && B_X == DMB_X && B_Y == DMB_Y && B_LS == DMB_LS && B_RS == DMB_RS && B_L == DMB_L && B_R == DMB_R && B_ZL == DMB_ZL && B_ZR == DMB_ZR
    && B_PLUS == DMB_PLUS && B_MINUS == DMB_MINUS && B_LEFT == DMB_LEFT && B_UP == DMB_UP && B_RIGHT == DMB_RIGHT && B_DOWN == DMB_DOWN, "DmPadBits.h and the B_* enum must agree");
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 1 = 3D, 0 = 2D

@interface DmGamepad : UIView
@end
static __weak DmGamepad *g_view;

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full;                                    // the 3D layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    BOOL _bars;                                    // controls live in the letterbox bars (dm_gamepad_layout)
    CGRect _content, _top, _bot;                   // the picture, and the usable parts of the bars above and below it
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn, *k_idleBar, *k_lineBar, *k_ringBar, *k_textBar;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
            k_idleBar = [UIColor colorWithWhite:1 alpha:0.18]; k_lineBar = [UIColor colorWithWhite:1 alpha:0.50]; k_ringBar = [UIColor colorWithWhite:1 alpha:0.10]; k_textBar = [UIColor colorWithWhite:1 alpha:0.9];   // frosted: the bars behind are already blurred
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        _full = saved ? saved.boolValue : DM_GAME_PAD_FULL;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [self padsChanged];
        motion_start();
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = fullOnly(b) && !_full;
    _swapLabel.string = _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)setFull:(BOOL)full {   // switch layouts: release every touch first (no key stays held), save, lay out again
    if (full == _full) return;
    [self reset];
    _full = full;
    [NSUserDefaults.standardUserDefaults setObject:@(full) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
- (CGFloat)bu {   // the bottom controls' unit (stick, diamond, D-pad): over the picture the overlay unit times the scale; in the bars from the screen height, so a 13-inch iPad gets thumb-sized controls whatever the bars' height
    return _bars ? K_BAR_UNIT * fmax(0.55, fmin(self.bounds.size.height / K_BAR_REF_H, 1.25)) * g_scale : self.u * fmin(g_scale, K_OVERLAY_SCALE_MAX);
}
- (CGFloat)padY:(CGFloat)overlayFromBottom { CGRect s = self.corner;   // the bottom controls' centre line; bars mode: the diamond's lowest key and the stick's ring (aligned, via the D-pad's offset) sit K_BAR_EDGE above the screen's bottom, extending up from the bar over the picture
    if (!_bars) return CGRectGetMaxY(s) - overlayFromBottom * self.bu;
    CGFloat bu = self.bu, y = CGRectGetMaxY(self.bounds) - K_BAR_EDGE - (K_FACE_GAP + K_BAR_FACE_U) * bu;
    return overlayFromBottom == K_LOW_Y ? y + (K_STICK_X - K_DPAD_R) * bu : y; }
- (CGFloat)topY:(CGFloat)overlayFromTop { return _bars ? CGRectGetMidY(_top) : CGRectGetMinY(self.safe) + overlayFromTop * self.u; }   // the top controls' centre line
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { CGRect s = self.corner; return side(s, 1, _bars ? K_BAR_EDGE + (K_FACE_GAP + K_BAR_FACE_U) * self.bu : K_FACE_X * self.bu, [self padY:K_PAD_Y]); }
- (CGFloat)faceGap { return K_FACE_GAP * self.bu; }
- (CGFloat)faceR { return (_bars ? K_BAR_FACE_U : K_FACE_R) * self.bu; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome { CGRect s = self.corner; return side(s, 0, K_STICK_X * self.bu + (_bars ? K_BAR_EDGE : 0), [self padY:K_PAD_Y]); }   // the left stick's ring centre
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return i ? K_RSTICK_R * self.u : K_STICK_R * self.bu; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter { CGRect s = self.corner; return side(s, 0, _bars ? K_BAR_EDGE + K_BAR_LOW_X * self.bu : K_LOW_X * self.bu, [self padY:K_LOW_Y]); }
- (CGFloat)dpadR { return K_DPAD_R * self.bu; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    CGFloat dx = _bars ? (z ? K_ZL_X : K_ZL_X + K_BAR_L_DX) : (z ? K_ZL_X : K_L_X);   // bars: ZL and L side by side along the bar; overlay: one column
    return side(s, b == B_ZR || b == B_R, dx * u, [self topY:z ? K_ZL_Y : K_L_Y]); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, (_bars ? K_BAR_CLICK_X : K_CLICK_X) * u, [self topY:K_ZL_Y]); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, [self topY:K_PILL_Y]);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), [self topY:K_PILL_Y]); }
- (BOOL)inBars { return _bars; }
- (CGRect)hudFrame { CGFloat u = self.u; CGPoint c = CGPointMake(CGRectGetMidX(self.safe) + (K_PILL_DX + K_PILL_W / 2 + 16) * u, [self topY:K_PILL_Y]);   // right of the + key (bars mode)
    return CGRectMake(floor(c.x), floor(c.y - K_HUD_H / 2), K_HUD_W, K_HUD_H); }
// The picture's rectangle in this view, and whether the controls go in the bars around it (returns that). The bars must span the width (letterbox, not pillarbox) and both be tall enough
- (BOOL)setContent:(CGRect)c allowBars:(BOOL)allow {
    CGRect b = self.bounds, cr = self.corner; UIEdgeInsets in = self.safeAreaInsets;
    CGFloat top = CGRectGetMinY(c) - in.top / 2, bot = CGRectGetHeight(b) - CGRectGetMaxY(c) - in.bottom / 2;   // half the safe-area inset: that is the home indicator / the notch, the controls may sit close to it
    BOOL bars = allow && fabs(CGRectGetWidth(c) - CGRectGetWidth(b)) < 2 && top >= K_BAR_MIN_TOP && bot >= K_BAR_MIN_BOTTOM;
    CGRect t = CGRectMake(CGRectGetMinX(cr), in.top / 2, CGRectGetWidth(cr), top), bt = CGRectMake(CGRectGetMinX(cr), CGRectGetMaxY(c), CGRectGetWidth(cr), bot);
    if (bars == _bars && CGRectEqualToRect(c, _content) && CGRectEqualToRect(t, _top) && CGRectEqualToRect(bt, _bot)) return bars;
    if (bars != _bars) [self reset];   // controls move: release every touch so no key stays held under a finger that is now somewhere else
    _bars = bars; _content = c; _top = t; _bot = bt;
    [self setNeedsLayout];
    return bars;
}

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = MAX(self.faceR * K_FACE_HIT, K_HIT_MIN);
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    CGFloat x0 = (b.size.width - w) / 2, y0 = (b.size.height - h) / 2;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        BOOL onBars = _bars && !CGRectContainsPoint(_content, p);   // a touch on the bars that no control takes is not the game's (it would clamp to the picture's edge)
        if (_padOff) { if (!onBars) game |= [self gameBegin:t]; continue; }
        int hit = [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else if (!onBars) game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO, game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self setFull:!_full];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void gloss(CAShapeLayer *l, BOOL on) {   // frosted look in the bars: a soft top-lit gradient inside the key's own outline, below its label
    CAGradientLayer *g = nil; for (CALayer *x in l.sublayers) if ([x.name isEqualToString:@"gloss"]) g = (CAGradientLayer *)x;
    if (!on || !l.path) { g.hidden = YES; return; }
    if (!g) {
        g = [CAGradientLayer layer]; g.name = @"gloss"; g.mask = [CAShapeLayer layer];
        g.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.30].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.02].CGColor];
        [l insertSublayer:g atIndex:0];
    }
    CGRect bb = CGPathGetBoundingBox(l.path); CGAffineTransform t = CGAffineTransformMakeTranslation(-bb.origin.x, -bb.origin.y);
    CGPathRef lp = CGPathCreateCopyByTransformingPath(l.path, &t);
    g.hidden = NO; g.frame = bb; ((CAShapeLayer *)g.mask).path = lp; CGPathRelease(lp);
}
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat u = self.u, bu = self.bu;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 0.74 * self.faceR); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * bu, K_ARM_IN * bu, arms[i].angle, 6 * bu));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * bu; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    for (int b = 0; b < B_N; b++) gloss(_key[b], _bars);
    gloss(_swap, _bars); gloss(_ring, _bars);
    _ring.strokeColor = (_bars ? k_lineBar : k_line).CGColor; _ring.fillColor = (_bars ? k_ringBar : k_ringFill).CGColor;
    [CATransaction commit];
    [self applyOpacity];
    [self refresh];
}
- (void)applyOpacity {   // per layer, so a full opacity needs no extra compositing pass
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].opacity = g_opacity;
    _swap.opacity = _ring.opacity = _knob.opacity = g_opacity;
    [CATransaction commit];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    UIColor *idle = _bars ? k_idleBar : k_idle, *line = _bars ? k_lineBar : k_line, *text = _bars ? k_textBar : k_text;
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : idle).CGColor; _key[b].strokeColor = line.CGColor; _label[b].foregroundColor = (on ? k_textOn : text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : idle).CGColor; _swap.strokeColor = line.CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : text).CGColor;
    CGPoint h = self.stickHome, o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : idle).CGColor; _knob.strokeColor = line.CGColor;
    [CATransaction commit];
}

// ---- Physical controllers ----
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.buttonB, B_A); K(g.buttonA, B_B); K(g.buttonY, B_X); K(g.buttonX, B_Y);   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    pthread_mutex_lock(&g_mu);
    g_pad_btn = m; g_pad_lx = axis(g.leftThumbstick.xAxis.value); g_pad_ly = axis(g.leftThumbstick.yAxis.value);
    g_pad_rx = axis(g.rightThumbstick.xAxis.value); g_pad_ry = axis(g.rightThumbstick.yAxis.value);
    int32_t lx = g_pad_lx, ly = g_pad_ly;
    pthread_mutex_unlock(&g_mu);
    publish();
    uint64_t both = 1ull << B_PLUS | 1ull << B_MINUS;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_capture) g_capture(m, lx, ly);
        if ((m & both) != both) { g_chord_gen++; return; }
        uint64_t gen = ++g_chord_gen;   // held together: the chord fires K_CHORD_S after the last change, unless a key came up meanwhile
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(K_CHORD_S * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen != g_chord_gen) return;
            g_chord_gen++; if (g_chord) g_chord();
        });
    });
}
- (void)padsChanged {
    BOOL any = NO;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) {
        any = YES; c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        read_pad(c.extendedGamepad);
    }
    if (!any) { pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish(); }
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = any; self->_controls.hidden = any; [self reset]; });
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
BOOL dm_gamepad_layout(CGRect content, BOOL allowBars) { return [g_view setContent:content allowBars:allowBars]; }   // main thread: the picture's rectangle; YES when the controls moved into the bars around it
void dm_gamepad_scale(float s) {   // main thread: the bottom controls' size (stick, A / B / X / Y, D-pad), clamped to K_SCALE_MIN...K_SCALE_MAX
    g_scale = fminf(fmaxf(s, K_SCALE_MIN), K_SCALE_MAX); [g_view setNeedsLayout]; }
CGRect dm_gamepad_hud_frame(void) { return g_view && [g_view inBars] ? [g_view hudFrame] : CGRectNull; }   // the frame-rate counter's place in the bars (CGRectNull: keep the overlay place)
void dm_gamepad_opacity(float o) { g_opacity = fminf(fmaxf(o, 0.3f), 1.f); [g_view applyOpacity]; }   // main thread: every control's opacity, 0.3...1
// The settings screen takes the physical controller: while a handler is set the game gets no input (touches are covered by the screen itself), and the handler is called on the main thread with the
// buttons (DmPadBits.h) and the left stick at once and on every change. NULL gives the controller back
void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly)) {
    g_capture = [handler copy]; g_capturing = handler != nil;
    [g_view reset];
    publish();
    if (handler) { pthread_mutex_lock(&g_mu); uint64_t m = g_pad_btn; int32_t lx = g_pad_lx, ly = g_pad_ly; pthread_mutex_unlock(&g_mu); handler(m, lx, ly); }
}
void dm_gamepad_set_chord(void (^handler)(void)) { g_chord = [handler copy]; }   // main thread: called once when + and - have been held together for 0.8 s
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_shake_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish();
}
