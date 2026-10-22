// Hearth's process model (HearthLaunch.h)
#import "HearthLaunch.h"
#import <objc/message.h>

int hearth_boot_game(HearthGame *g);       // main.m: the game's environment, log and dm_boot_game; 1 = booting
UIViewController *front_ios_root(void);    // front_ios.m: the game's view controller
void dm_host_shutdown(const char *why);    // hle_lifecycle.c: audio and graphics stopped, then _exit(0)

static HearthGame *g_running;
HearthLibrary *hearth_library(void) {
    static HearthLibrary *lib; static dispatch_once_t once;
    dispatch_once(&once, ^{ lib = [[HearthLibrary alloc] initWithHome:NSHomeDirectory() bundle:NSBundle.mainBundle.bundlePath]; });
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

static void alert(UIViewController *over, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [over presentViewController:a animated:YES completion:nil];
}

void hearth_launch(HearthGame *g, UIWindow *window) {
    if (g.reason) { alert(window.rootViewController, g.reason == 2 ? @"Rebuild needed" : @"This game cannot start", g.why); return; }
    if (g_running) {   // one game per process: restart straight into the new one (the close dialog arrives with the Home overlay in step 6)
        if ([g_running.titleId isEqual:g.titleId]) return;
        [hearth_library() writeNext:@{@"action": @"launch", @"id": g.titleId}];
        relaunch(); return;
    }
    if (!hearth_boot_game(g)) { alert(window.rootViewController, @"This game cannot start", @"Its log has the reason (Documents/Logs)."); return; }
    g_running = g;
    window.rootViewController = front_ios_root();
}

void hearth_confirm_close(UIViewController *over) {
    NSString *name = g_running.name ?: @"the game";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Close %@?", name] message:@"Progress that was not saved will be lost."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { (void)x; hearth_close(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [over presentViewController:a animated:YES completion:nil];
}

// Called by main.m for a launch intent from next.json, before UIApplicationMain: the game boots early, as the single-game app did
void hearth_mark_running(HearthGame *g) { g_running = g; }
