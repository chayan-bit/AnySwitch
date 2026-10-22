// iOS front end (the iOS implementation of front.h): the Metal view + a full-screen virtual gamepad layer (DmGamepad.m).
// The picture is the game's 16:9 frame fitted into the screen. With letterbox=ambient (default) the Metal view is the whole screen and the present stage fills the bars with the blurred live frame (dm/gfx/nvn/nvn_ambient.h);
// with letterbox=black the view is just the 16:9 rectangle on a black screen, as before. Controls sit in the bars when they are tall enough (controls layout auto), else over the picture (DmGamepad.m).
// Settings (DmSettings.m, the in-app settings screen DmSettingsVC.m; gear button at the top, the + and - buttons held together, or Cmd-,); the registry in DmSettings.m lists every setting and whether it applies live or on the next start.
// Precedence: Documents/env.txt, then the player's choice in Documents/settings.json, then the Info.plist keys (project.yml), then the game profile's defaults (dm/settings.json), then the registry defaults. Changes in the screen apply at once (settingChanged:).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#import "DmSettings.h"
#import "DmSettingsVC.h"
#include <errno.h>
#include "front.h"
#include "hle.h"
#include "dm.h"

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
BOOL dm_gamepad_layout(CGRect content, BOOL allowBars);
void dm_gamepad_scale(float s);
void dm_gamepad_opacity(float o);
void dm_gamepad_shake_g(double g);
void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly));
void dm_gamepad_set_chord(void (^handler)(void));
void mtl_letterbox_set(int ambient);
void mtl_ambient_level_set(float v);
CGRect dm_gamepad_hud_frame(void);
void front_ios_boot(void);
int front_ios_boot_ok(void);

static CAMetalLayer *g_layer;
static BOOL g_ambient = YES, g_controls_auto = YES;
static float g_controls_scale = 1, g_controls_opacity = 1;
static int g_settings_open;   // the settings screen is up: the game stays out of focus (front_ios_focus_event)
// The start-up values come from the settings store (environment, the player's file, Info.plist, defaults: DmSettings.m); the graphics layer is told here, the same way a change in the screen tells it
static void front_ios_settings(void) {
    DmSettings *s = DmSettings.shared;
    g_ambient = [[s valueForKey:@"DM_LETTERBOX"] isEqualToString:@"ambient"];
    g_controls_auto = [[s valueForKey:@"DM_CONTROLS_LAYOUT"] isEqualToString:@"auto"];
    g_controls_scale = (float)[s doubleForKey:@"DM_CONTROLS_SCALE"]; g_controls_opacity = (float)[s doubleForKey:@"DM_CONTROLS_OPACITY"];   // clamped again in DmGamepad.m
    mtl_letterbox_set(g_ambient); mtl_ambient_level_set((float)[s doubleForKey:@"DM_AMBIENT_LEVEL"]);
    dm_gamepad_shake_g([s doubleForKey:@"DM_SHAKE_G"]);
    s.capabilities = ^BOOL(NSString *c) { return dm_capability(c.UTF8String) != 0; };   // the loaded game decides which rows exist (frame cap, render scale)
    LOG("front end: letterbox %s, controls layout %s, controls scale %.2f, opacity %.2f", g_ambient ? "ambient" : "black", g_controls_auto ? "auto (in the bars when they fit)" : "overlay", g_controls_scale, g_controls_opacity);
}
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.drawableSize = CGSizeMake(self.bounds.size.width * l.contentsScale, self.bounds.size.height * l.contentsScale);
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UILabel *fps;
@property (nonatomic, strong) UIButton *gear;
@property (nonatomic, strong) DmSettingsVC *settings;
@end
@implementation DmRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    front_ios_power_watch();
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.text = @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart.";
        [self.view addSubview:lb]; return;
    }
    front_ios_audio_watch();
    front_ios_settings();
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    self.pad = dm_gamepad_view(self.view.bounds);
    dm_gamepad_scale(g_controls_scale); dm_gamepad_opacity(g_controls_opacity);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    if ([DmSettings.shared boolForKey:@"DM_SHOW_FPS"]) { self.fps = front_ios_fps_label(); [self.view addSubview:self.fps]; }   // above the pad, which hides while a controller is connected
    self.gear = [self makeGear]; [self.view addSubview:self.gear];
    [self addKeyCommand:[UIKeyCommand keyCommandWithInput:@"," modifierFlags:UIKeyModifierCommand action:@selector(toggleSettings)]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingChanged:) name:DmSettingDidChangeNotification object:nil];
    __weak DmRootVC *w = self; dm_gamepad_set_chord(^{ [w toggleSettings]; });   // + and - held together on a controller
}
- (UIButton *)makeGear {   // right of the frame-rate counter: a 44 pt target with a 32 pt translucent disc
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    UIButtonConfiguration *c = [UIButtonConfiguration plainButtonConfiguration];
    c.image = [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    c.baseForegroundColor = [UIColor colorWithWhite:1 alpha:0.9];
    c.background.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42]; c.background.cornerRadius = 16; c.background.backgroundInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 6);
    c.background.strokeColor = [UIColor colorWithWhite:1 alpha:0.28]; c.background.strokeWidth = 1;
    b.configuration = c; b.accessibilityLabel = @"Settings";
    [b addTarget:self action:@selector(toggleSettings) forControlEvents:UIControlEventTouchUpInside];
    return b;
}
// The settings screen sits over everything as a child view; while it is up the game is out of focus (the pause hook) and the physical controller belongs to it
- (void)toggleSettings { if (self.settings) [self closeSettings]; else [self openSettings]; }
- (void)openSettings {
    if (self.settings || !self.game) return;
    DmSettingsVC *vc = [[DmSettingsVC alloc] initWithSettings:DmSettings.shared size:self.view.bounds.size];
    __weak DmRootVC *w = self; vc.onClose = ^{ [w closeSettings]; };
    self.settings = vc; [self addChildViewController:vc];
    vc.view.frame = self.view.bounds; vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    vc.view.alpha = 0; vc.view.transform = CGAffineTransformMakeScale(0.97, 0.97);
    [self.view addSubview:vc.view]; [vc didMoveToParentViewController:self];
    g_settings_open = 1; dm_focus_set(2);
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { [vc padState:m lx:lx ly:ly]; });
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ vc.view.alpha = 1; vc.view.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)closeSettings {
    DmSettingsVC *vc = self.settings; if (!vc) return;
    self.settings = nil;
    dm_gamepad_set_capture(nil); g_settings_open = 0; dm_focus_set(1);
    [vc willMoveToParentViewController:nil];
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{ vc.view.alpha = 0; vc.view.transform = CGAffineTransformMakeScale(0.98, 0.98); }
                     completion:^(BOOL f) { (void)f; [vc.view removeFromSuperview]; [vc removeFromParentViewController]; }];
}
// A setting changed in the screen: apply it at once
- (void)settingChanged:(NSNotification *)n {
    NSString *k = n.object, *v = n.userInfo[@"value"];
    if ([k isEqualToString:@"DM_LETTERBOX"]) { g_ambient = [v isEqualToString:@"ambient"]; mtl_letterbox_set(g_ambient); [self.view setNeedsLayout]; }
    else if ([k isEqualToString:@"DM_CONTROLS_LAYOUT"]) { g_controls_auto = [v isEqualToString:@"auto"]; [self.view setNeedsLayout]; }
    else if ([k isEqualToString:@"DM_CONTROLS_SCALE"]) dm_gamepad_scale(v.floatValue);
    else if ([k isEqualToString:@"DM_CONTROLS_OPACITY"]) dm_gamepad_opacity(v.floatValue);
    else if ([k isEqualToString:@"DM_AMBIENT_LEVEL"]) mtl_ambient_level_set(v.floatValue);
    else if ([k isEqualToString:@"DM_SHAKE_G"]) dm_gamepad_shake_g(v.doubleValue);
    else if ([k isEqualToString:@"DM_SHOW_FPS"]) {
        BOOL want = [v isEqualToString:@"1"];
        if (want && !self.fps) { self.fps = front_ios_fps_label(); [self.view insertSubview:self.fps belowSubview:self.gear]; [self.view setNeedsLayout]; }
        else if (!want && self.fps) { [self.fps removeFromSuperview]; self.fps = nil; }
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; if (!self.game) return;
    CGFloat w = b.size.width, h = b.size.height;   // Fit 16:9 into the whole screen
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    CGRect content = CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
    self.game.frame = g_ambient ? b : content;   // ambient: the drawable is the whole screen and the present stage letterboxes the picture inside it (the same fit, so the rectangles agree)
    self.pad.frame = b;
    BOOL bars = dm_gamepad_layout(content, g_controls_auto);
    CGRect hud = bars ? dm_gamepad_hud_frame() : CGRectNull;   // the counter joins the top bar
    if (CGRectIsNull(hud)) {   // the top row's free stretch: right of DmGamepad.m's L3 key (102 + 17 of its units from the safe edge), level with − / + (22 units down); u is its unit
        CGRect s = UIEdgeInsetsInsetRect(b, self.view.safeAreaInsets); CGFloat u = MIN(b.size.height / 430.0, 1.3);
        hud = CGRectMake(floor(CGRectGetMinX(s) + 130 * u), floor(CGRectGetMinY(s) + 22 * u - 11), 64, 22);
    }
    if (self.fps) self.fps.frame = hud;
    self.gear.frame = CGRectMake(CGRectGetMaxX(hud) + 4, CGRectGetMidY(hud) - 22, 44, 44);   // the counter's place stays reserved while it is off, so nothing moves when it is switched
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; UIApplication.sharedApplication.idleTimerDisabled = YES; front_ios_boot(); }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

// Thermal state and screen brightness for the power and present rows every 300 frames (hle_nvn.c; its weak defaults return -1 on the Mac). thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
// Brightness is read on the main thread at start and on each change; every change of the thermal state and of Low Power Mode (which lowers the CPU clock) is logged with the time since launch
static _Atomic double g_brightness = -1;
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }   // the frame step does not probe in it (hle_nvn.c fstep_cpu_slowed)
double dm_brightness_now(void) { return g_brightness; }
static void front_ios_power_watch(void) {
    g_brightness = UIScreen.mainScreen.brightness;
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; g_brightness = UIScreen.mainScreen.brightness; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9); }];
    LOG("front end: thermal state %d, brightness %.2f, Low Power Mode %s", dm_thermal_now(), g_brightness, dm_low_power_now() ? "on" : "off");
}

// Frame-rate counter: the frames put on screen in the last second (nvn_mtl.m counts them for NVN and for the Vulkan layer alike; frames the display link merged away are not counted).
// Shown when the DM_SHOW_FPS setting is on (the NSP script's SHOW_FPS / --show-fps → DMShowFPS in Info.plist is its default; env.txt and the settings screen override that without a rebuild)
uint64_t mtl_present_count(void);
static UILabel *front_ios_fps_label(void) {
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold]; l.textColor = UIColor.whiteColor; l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; l.layer.cornerRadius = 6; l.layer.masksToBounds = YES; l.userInteractionEnabled = NO;
    l.text = @"-- fps";
    __block uint64_t n0 = mtl_present_count(); __block double t0 = CACurrentMediaTime(); __weak UILabel *wl = l;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {   // ends with the label (the screen can switch the counter off and on)
        UILabel *l = wl; if (!l) { [t invalidate]; return; }
        uint64_t n = mtl_present_count(); double now = CACurrentMediaTime();
        if (now - t0 < 1.5) l.text = [NSString stringWithFormat:@"%.0f fps", (n - n0) / (now - t0)];   // a longer span is the time in the background: no reading
        n0 = n; t0 = now;
    }];
    LOG("front end: frame-rate counter on");
    return l;
}

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    // The guest clock keeps running meanwhile, as on the Switch (hle_swkbd.c): a freeze here as well stopped Octopath Traveler 0's frame loop for as long as the box was up and made its sound stutter
    // (4,977 ms and 2,577 ms frames, 5,181 wakeups a second). The inline keyboard freezes around its own call (hle_swkbd.c)
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game. hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("front end: save data write failed errno=%d, telling the player", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("[RED] front end: no window for the save-failure alert errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"Storage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"Saving failed (errno %d); progress was not saved.", err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category stays the default SoloAmbient (silent switch and interrupting other apps' audio behave as before). Set once at boot and again on return to the foreground (the system may reset it after an interruption)
static int g_session_off;   // the last activation failed (another app or a call still held the session): tried again when the app becomes active
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategorySoloAmbient error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    LOG("audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for 5 ms)", s.sampleRate, s.IOBufferDuration * 1000);
}

// Real audio output is suspended (the silent sink paces the game) while the app is in the background or another audio session has interrupted ours (Siri, an alarm, a call).
// Without the interruption observer the AudioUnits stayed "started" while iOS no longer called them, and a game waiting for its buffers back lost its sound until restart.
// All of this runs on the main queue, like the scene callbacks
static int g_audio_bg, g_audio_intr;
static void front_ios_audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
static void front_ios_audio_watch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue], reason = [n.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) { LOG("audio session: interrupted (reason %lu)", (unsigned long)reason); g_audio_intr = 1; }
        else {
            LOG("audio session: interruption ended"); g_audio_intr = 0;
            if (!g_audio_bg) front_ios_audio_session();
        }
        front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; LOG("audio session: the media services were reset; setting the session and the outputs up again");
        front_ios_audio_session(); dm_audio_reset();
    }];
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed).
// The screen stays on while the game is active: only touches reset the idle timer, so with a controller (or during a cutscene) the screen dimmed and locked mid-game
void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); break;
        case 3:   // Becoming active again also ends an interruption whose "ended" never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); dm_focus_set(g_settings_open ? 2 : 1); break;   // the settings screen keeps the game out of focus
    }
}
