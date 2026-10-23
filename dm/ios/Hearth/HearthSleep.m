// Sleep (HearthSleep.h): a black window above everything, which takes touches, keys and the controller until the first new press
#import "HearthSleep.h"
#import <UIKit/UIKit.h>

void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly));

static UIWindow *g_win, *g_back;   // the black window, and the window that was key before it
static void (^g_woke)(void);
static double g_since; static BOOL g_idle;   // when Sleep began; the idle timer setting to put back
static id g_active;

static double now_s(void) { return CACurrentMediaTime(); }
BOOL hearth_asleep(void) { return g_win != nil; }

static void wake(const char *by) {
    if (!g_win) return;
    fprintf(stderr, "hearth: woken by %s after %.1f s\n", by, now_s() - g_since);
    g_win.hidden = YES; g_win = nil;
    [NSNotificationCenter.defaultCenter removeObserver:g_active]; g_active = nil;
    UIApplication.sharedApplication.idleTimerDisabled = g_idle;
    dm_gamepad_set_capture(nil);
    [g_back makeKeyWindow]; g_back = nil;
    void (^w)(void) = g_woke; g_woke = nil;
    if (w) w();
}

@interface HearthSleepVC : UIViewController
@end
@implementation HearthSleepVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.view.isAccessibilityElement = YES; self.view.accessibilityLabel = @"Asleep. Touch the screen to wake.";
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self becomeFirstResponder]; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { (void)t; (void)e; wake("touch"); }
- (void)pressesBegan:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { (void)p; (void)e; wake("key"); }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

void hearth_sleep(void (^woke)(void)) {
    if (g_win) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
    if (!scene) return;
    for (UIWindow *w in scene.windows) if (w.isKeyWindow) g_back = w;
    g_woke = [woke copy]; g_since = now_s(); g_idle = UIApplication.sharedApplication.idleTimerDisabled;
    g_win = [[UIWindow alloc] initWithWindowScene:scene];
    g_win.windowLevel = UIWindowLevelAlert + 1; g_win.backgroundColor = UIColor.blackColor;
    g_win.overrideUserInterfaceStyle = g_back.overrideUserInterfaceStyle;
    g_win.rootViewController = [HearthSleepVC new];
    [g_win makeKeyAndVisible];
    UIApplication.sharedApplication.idleTimerDisabled = NO;   // iPadOS may lock now, after its own auto-lock time
    // Unlocking makes the app active again, and the game's front end then turns the idle timer off (front_ios_focus_event): turn it back on while asleep
    g_active = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; dispatch_async(dispatch_get_main_queue(), ^{ if (g_win) UIApplication.sharedApplication.idleTimerDisabled = NO; });
    }];
    __block BOOL based = NO; __block uint64_t prev = 0;
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) {   // what is held at sleep time does nothing; the next press wakes
        (void)lx; (void)ly;
        if (!based) { based = YES; prev = m; return; }
        uint64_t down = m & ~prev; prev = m;
        if (down) wake("controller");
    });
    fprintf(stderr, "hearth: asleep\n");
}
