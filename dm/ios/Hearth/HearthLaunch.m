// Hearth's process model (HearthLaunch.h)
#import "HearthLaunch.h"
#import "HearthHomeVC.h"
#import "HearthSound.h"
#import <objc/message.h>
#include "hle.h"

void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly));

int hearth_boot_game(HearthGame *g);       // main.m: the game's environment, log and dm_boot_game; 1 = booting
UIViewController *front_ios_root(void);    // front_ios.m: the game's view controller
void dm_host_shutdown(const char *why);    // hle_lifecycle.c: audio and graphics stopped, then _exit(0)

static HearthGame *g_running;
HearthLibrary *hearth_library(void) {
    static HearthLibrary *lib; static dispatch_once_t once;
    dispatch_once(&once, ^{
        lib = [[HearthLibrary alloc] initWithHome:NSHomeDirectory() bundle:NSBundle.mainBundle.bundlePath];
        lib.bundleId = NSBundle.mainBundle.bundleIdentifier; lib.appSigner = [HearthSigner signerOf:NSBundle.mainBundle.executablePath];   // what imported code must be signed with
        if (!lib.appSigner) fprintf(stderr, "hearth: [RED] this app's own signature could not be read: imported games will say Needs signing\n");
    });
    return lib;
}
HearthGame *hearth_running_game(void) { return g_running; }

static void quit(void) { if (g_running) dm_host_shutdown("close"); else exit(0); }
// Ask LaunchServices to open this app, then end the process; the open is served after the exit. Two requests and the first completion as the exit point is the pattern spike H2
// measured (66 of 66 back in the foreground); our own code, after LiveContainer's idea. If no completion comes in 3 s the process ends anyway and the user opens Hearth by hand
static void relaunch(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    id ws = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"LSApplicationWorkspace"), NSSelectorFromString(@"defaultWorkspace"));
    SEL s = NSSelectorFromString(@"openApplicationWithBundleIdentifier:configuration:completionHandler:");
    if (!ws || ![ws respondsToSelector:s]) { NSLog(@"hearth: [RED] no LaunchServices open call: closing without a restart"); quit(); return; }
    id cfg = [NSClassFromString(@"_LSOpenConfiguration") new];
    for (int i = 0; i < 2; i++)
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(ws, s, bid, cfg, ^(BOOL ok, NSError *e) {
            fprintf(stderr, "hearth: restart requested (%s%s)\n", ok ? "ok" : "failed: ", ok ? "" : e.localizedDescription.UTF8String);
            quit();
        });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ fprintf(stderr, "hearth: [RED] no answer to the restart in 3 s\n"); quit(); });
}

void hearth_close(void) {
    fprintf(stderr, "hearth: closing %s\n", g_running.titleId.UTF8String ?: "(no game)");
    [hearth_library() writeNext:@{@"action": @"home"}];
    relaunch();
}

// The confirming action of the dialog on screen, for a controller's A; cleared by either button
static void (^g_confirm)(void);
void hearth_dialog_answer(UIViewController *over, BOOL yes) {
    void (^f)(void) = yes ? g_confirm : nil; g_confirm = nil;
    if (!f && over.presentedViewController) fprintf(stderr, "hearth: dialog dismissed (controller)\n");
    [over dismissViewControllerAnimated:YES completion:f];
}
// A two-button dialog: the confirming button is destructive and preferred (Return on a keyboard, A on a controller), Cancel keeps things as they are
static void confirm(UIViewController *over, NSString *title, NSString *yes, NSString *what, void (^run)(void)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:@"Progress that was not saved will be lost." preferredStyle:UIAlertControllerStyleAlert];
    fprintf(stderr, "hearth: %s dialog shown\n", what.UTF8String);   // with DM_TOUCH_LOG=1 the touches around it are logged too (main.m)
    void (^go)(void) = ^{ fprintf(stderr, "hearth: %s dialog: %s\n", what.UTF8String, yes.UTF8String); run(); };
    UIAlertAction *y = [UIAlertAction actionWithTitle:yes style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { (void)x; g_confirm = nil; go(); }];
    [a addAction:y];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; g_confirm = nil; fprintf(stderr, "hearth: %s dialog: Cancel\n", what.UTF8String); }]];
    a.preferredAction = y;
    g_confirm = ^{ fprintf(stderr, "hearth: (controller A)\n"); go(); };
    [over presentViewController:a animated:YES completion:nil];
}

static void alert(UIViewController *over, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [over presentViewController:a animated:YES completion:nil];
}

void hearth_launch(HearthGame *g, UIWindow *window, void (^zoom)(void (^done)(void))) {
    if (g.reason) { alert(window.rootViewController, g.reason == 2 ? @"Rebuild needed" : @"This game cannot start", g.why); return; }
    if (g_running) {   // one game per process: close the running one, then the restart boots g
        if ([g_running.titleId isEqual:g.titleId]) { hearth_resume(); return; }
        UIViewController *over = window.rootViewController; while (over.presentedViewController) over = over.presentedViewController;
        confirm(over, [NSString stringWithFormat:@"Close %@ and start %@?", g_running.name, g.name], @"Close and Start", @"switch", ^{
            [hearth_library() writeNext:@{@"action": @"launch", @"id": g.titleId}];
            relaunch();
        });
        return;
    }
    if (!hearth_boot_game(g)) { alert(window.rootViewController, @"This game cannot start", @"Its log has the reason (Documents/Logs)."); return; }
    g_running = g;
    void (^show)(void) = ^{ window.rootViewController = front_ios_root(); };
    if (zoom) zoom(show); else show();
}

void hearth_confirm_close(UIViewController *over) {
    confirm(over, [NSString stringWithFormat:@"Close %@?", g_running.name ?: @"the game"], @"Close", @"close", ^{ hearth_close(); });
}

// HOME: Home is a child of the game's view controller, over its view; the game is suspended first (dm_home_suspend: focus 2, audio, guest clock, graphics), so its last frame stays
// under Home. Leaving resumes the game at once and fades Home out over it
static HearthHomeVC *g_overlay;
BOOL hearth_home_up(void) { return g_overlay != nil; }
static UIViewController *game_vc(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w.rootViewController;
    return nil;
}
static void home_show(void) {
    UIViewController *root = game_vc(); if (!root || g_overlay || !g_running) return;
    if (root.presentedViewController) { fprintf(stderr, "hearth: HOME ignored: a dialog is up\n"); return; }   // the software keyboard's guest thread waits for its answer
    dm_home_suspend(1);
    HearthHomeVC *h = [HearthHomeVC new]; h.overlay = YES; g_overlay = h;
    [root addChildViewController:h];
    h.view.frame = root.view.bounds; h.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; h.view.alpha = 0;
    [root.view addSubview:h.view]; [h didMoveToParentViewController:root];
    hearth_sound(HearthSoundOpen);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ h.view.alpha = 1; } completion:nil];
    fprintf(stderr, "hearth: Home over %s\n", g_running.titleId.UTF8String);
}
void hearth_resume(void) {
    HearthHomeVC *h = g_overlay; if (!h) return;
    g_overlay = nil; g_confirm = nil;
    UIViewController *root = game_vc(); if (root.presentedViewController) [root dismissViewControllerAnimated:NO completion:nil];   // Home's own dialog (no game dialog can be up: Home does not open over one)
    dm_gamepad_set_capture(nil);   // the controller goes back to the game
    dm_home_suspend(0);
    hearth_sound(HearthSoundBack);
    [h willMoveToParentViewController:nil];
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{ h.view.alpha = 0; }
                     completion:^(BOOL f) { (void)f; [h.view removeFromSuperview]; [h removeFromParentViewController]; }];
    fprintf(stderr, "hearth: back to %s\n", g_running.titleId.UTF8String);
}
static void home_deliver(void) { dispatch_async(dispatch_get_main_queue(), ^{ if (g_overlay) hearth_resume(); else home_show(); }); }
void hearth_home(void) { if (g_running) dm_home_press(home_deliver); }

// Called by main.m for a launch intent from next.json, before UIApplicationMain: the game boots early, as the single-game app did
void hearth_mark_running(HearthGame *g) { g_running = g; }
