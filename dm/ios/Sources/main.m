// iOS App entry (Hearth): Home lists the games (dm/ios/Hearth); a game is booted in this process the way dmhost boots a pack on the Mac (dm_boot_game: environment, profile,
// host loading in the background), then dm_main runs on a big-stack thread. Closing a game restarts the app (HearthLaunch.m), and next.json tells the new process to show
// Home or to boot the next game before UIApplicationMain, as the single-game app always did. Logs: Documents/Logs/hearth.txt, then Documents/Logs/<title id>/log.txt once a game starts.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include "boot.h"
#import "DmSettings.h"
#import "HearthLaunch.h"
#import "HearthHomeVC.h"

int dm_main(int argc, char **argv);   // dm/host/main.c compiled in with -Dmain=dm_main
UIViewController *front_ios_root(void);
void front_ios_focus_event(int ev);
void hearth_mark_running(HearthGame *g);

static char *g_argv[4]; static int g_argc; static int g_boot_ok;
static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static double g_t0;   // process start on the clock the host's [bootprof] lines use (its t= counts from process start, so a launch from Home subtracts this line's t)
__attribute__((constructor)) static void hearth_t0(void) { g_t0 = now_s(); }
static void apply_appearance(UIWindow *w);

static void log_to(NSString *dir, NSString *name) {   // stderr (the host's log) into dir/name.txt; the previous one is kept as name.prev.txt
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *log = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".txt"]], *prev = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".prev.txt"]];
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
}

// Boot prerequisites of one game (HearthLaunch.m calls it from Home; main() for a launch intent, before UIApplicationMain): log, environment, settings, then dm_boot_game
// (the host's early load runs in the background from here). 1 = booting
int hearth_boot_game(HearthGame *g) {
    HearthLibrary *lib = hearth_library();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = lib.documentsDir, *pack = g.root;
    log_to([lib logDirFor:g], @"log");
    fprintf(stderr, "hearth: launching %s at t=%.3f s\n", g.titleId.UTF8String, now_s() - g_t0);
    [fm createDirectoryAtPath:[doc stringByAppendingPathComponent:@"temp"] withIntermediateDirectories:YES attributes:nil error:nil];
    // Keep game files and scratch data out of device backups (Documents is backed up by default; a RomFS placed there is many GB). Saves, logs and the pipeline list stay in the backup
    for (NSString *d in @[@"romfs", @"romfs.dmstore", @"temp"]) {
        NSURL *u = [NSURL fileURLWithPath:[doc stringByAppendingPathComponent:d]]; NSError *e = nil;
        if ([fm fileExistsAtPath:u.path] && ![u setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&e]) fprintf(stderr, "boot: %s could not be excluded from backup: %s\n", d.UTF8String, e.localizedDescription.UTF8String);
    }
    // Environment switch files (on-device diagnostics: a sideloaded app cannot be given environment variables from outside): one KEY=VALUE per line, # starts a comment;
    // Documents/env.txt takes precedence over the pack's profile/env.txt (put there by build_ipa.sh's DM_ENV_FILE)
    for (NSString *ef in @[[doc stringByAppendingPathComponent:@"env.txt"], [pack stringByAppendingPathComponent:@"profile/env.txt"]]) {
        NSString *txt = [NSString stringWithContentsOfFile:ef encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); fprintf(stderr, "boot: env %s=%s (%s)\n", k.UTF8String, v.UTF8String, ef.lastPathComponent.UTF8String); }
        }
    }
    dm_settings_set_game(g.titleId, pack);
    dm_settings_boot();   // Documents/settings.json (the in-app settings screen: this game's choices, then the system ones) and the pack's defaults, for every key env.txt did not set: DmSettings.m
    // Console mode Auto: Docked while an external display is connected, else Handheld (the host reads DM_OPMODE once, as 0 or 1)
    if ([[DmSettings.shared valueForKey:@"DM_OPMODE"] isEqualToString:@"auto"]) {
        BOOL ext = UIScreen.screens.count > 1;
        setenv("DM_OPMODE", ext ? "1" : "0", 1); fprintf(stderr, "hearth: console mode Auto: %s\n", ext ? "Docked (external display)" : "Handheld");
    }
    // DM_CLEAR_SHADER_CACHE=1: start with the empty Metal shader cache of a fresh install (Library/Caches/<bundle id>/com.apple.metal and its siblings), to measure first-launch pipeline compiles
    // without reinstalling (a reinstall also drops Documents: game files, saves). Pair it with a fresh DM_PSO_USER file so no learned warm-up list hides the compiles either
    if (getenv("DM_CLEAR_SHADER_CACHE") && atoi(getenv("DM_CLEAR_SHADER_CACHE"))) {
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier];
        for (NSString *d in @[@"com.apple.metal", @"com.apple.gpuarchiver", @"com.apple.metalfe"]) {
            NSString *p = [caches stringByAppendingPathComponent:d]; NSError *e = nil;
            if (![fm fileExistsAtPath:p]) continue;
            if (![fm removeItemAtPath:p error:&e]) fprintf(stderr, "boot: [RED] could not clear the shader cache %s: %s\n", p.fileSystemRepresentation, e.localizedDescription.UTF8String);
            else fprintf(stderr, "boot: shader cache %s cleared (DM_CLEAR_SHADER_CACHE)\n", d.UTF8String);
        }
    }
    // The caller's part of the environment contract (boot.h): game files the bundled pack keeps in Documents, the code inside the app bundle, the user's save, scratch space, the user
    if (g.romfsPath) setenv("DM_ROMFS", g.romfsPath.fileSystemRepresentation, 0);
    if (g.codePath) setenv("DM_CODE", g.codePath.fileSystemRepresentation, 0);
    setenv("DM_SAVE", [lib saveDirFor:g].fileSystemRepresentation, 0);
    setenv("DM_TEMP", [doc stringByAppendingPathComponent:@"temp"].fileSystemRepresentation, 0);
    setenv("DM_USER_UID", HEARTH_UID.UTF8String, 0);
    chdir(doc.fileSystemRepresentation);
    if (dm_boot_game(pack.fileSystemRepresentation)) return 0;   // a refused pack: the reason is in the game's log, and Home stays
    g_argv[0] = strdup("dmhost"); g_argv[1] = strdup(pack.fileSystemRepresentation); g_argc = 2;   // the same two arguments dm_boot_game gave the early start
    g_boot_ok = 1;
    if (NSThread.isMainThread && UIApplication.sharedApplication)   // launched from Home: the window exists already (a launch intent has none yet; the scene applies it)
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)sc).windows) apply_appearance(w);
    return 1;
}

// DM_APPEARANCE=light|dark (env.txt diagnostics): Hearth in that style whatever the system's; the Appearance setting of the System Settings will set the same override
static void apply_appearance(UIWindow *w) {
    const char *ap = getenv("DM_APPEARANCE"); if (!ap) return;
    w.overrideUserInterfaceStyle = !strcmp(ap, "light") ? UIUserInterfaceStyleLight : !strcmp(ap, "dark") ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
}
static void *boot_thread(void *p) {
    (void)p;
    static char alt[65536]; stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);   // crash printing must work on the host thread too
    int rc = dm_main(g_argc, g_argv);
    fprintf(stderr, "boot: dm_main returned %d\n", rc);
    return NULL;
}
void front_ios_boot(void) {   // Called by front_ios.m once the window and Metal view exist
    static int once; if (once++ || !g_boot_ok) return;
    void front_ios_audio_session(void); front_ios_audio_session();   // set a short I/O buffer before the game opens audio output (front_ios.m)
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);   // the Switch main thread stack is set by npdm; the host gives plenty
    pthread_t t; pthread_create(&t, &a, boot_thread, NULL); pthread_detach(t);
}
int front_ios_boot_ok(void) { return g_boot_ok; }

@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
@end

// Scene lifecycle: create the window + hand focus events to front_ios.m
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    fprintf(stderr, "hearth: scene connects at t=%.3f s, %s\n", now_s() - g_t0, hearth_running_game() ? "game" : "Home");
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    apply_appearance(self.window);
    self.window.rootViewController = hearth_running_game() ? front_ios_root() : [HearthHomeVC new];   // a launch intent booted its game before UIApplicationMain
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)s { front_ios_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { front_ios_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { front_ios_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { fprintf(stderr, "hearth: active at t=%.3f s\n", now_s() - g_t0); front_ios_focus_event(3); }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        HearthLibrary *lib = hearth_library();
        log_to([lib.documentsDir stringByAppendingPathComponent:@"Logs"], @"hearth");
        NSDictionary *next = [lib takeNext];   // what the previous process asked for when it closed a game: Home, or straight into another game
        fprintf(stderr, "hearth: start, next %s %s\n", [next[@"action"] description].UTF8String, [next[@"id"] description].UTF8String ?: "");
        HearthGame *g = [next[@"action"] isEqual:@"launch"] && [next[@"id"] isKindOfClass:NSString.class] ? [lib gameWithId:next[@"id"]] : nil;
        if (g && !g.reason && hearth_boot_game(g)) hearth_mark_running(g);   // the host's early load overlaps UIKit start-up, as in the single-game app
    }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
