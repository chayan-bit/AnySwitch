// iOS App entry: write the host log to Documents/log.txt, find the game files, then boot the game pack the app bundles (<App>/pack, docs/development.md "Game packs") the way
// dmhost boots one on the Mac (dm_pack_require, dm_boot_game: environment, profile, host loading in the background), create the window (front_ios.m), then run dm_main on a big-stack thread.
// The pack's code is this executable's own (gen_embed.py links it in). The game files: a chunk store at Documents/romfs.dmstore (dm/tools/romstore/romstore.py) comes first, then
// Documents/romfs placed through the Files app (lets you swap them without reinstalling), then <App>/romfs (IPA_ROMFS=1).
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include "boot.h"
#include "profile.h"   // the game profile (the RomFS marker path)
#import "DmSettings.h"

int dm_main(int argc, char **argv);   // dm/host/main.c compiled in with -Dmain=dm_main
UIViewController *front_ios_root(void);
void front_ios_focus_event(int ev);

static char *g_argv[4]; static int g_argc;

static NSString *romfs_locate(const char *marker) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *store = [doc stringByAppendingPathComponent:@"romfs.dmstore"]; BOOL isdir = NO;   // the host checks the store itself when it mounts it (hle_fs.c)
    if ([fm fileExistsAtPath:store isDirectory:&isdir] && !isdir) return store;
    for (NSString *d in @[[doc stringByAppendingPathComponent:@"romfs"], [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs"]])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@(marker)]]) return d;   // only a directory containing the game profile's romfs_marker path counts (Mario: System/Resource, the resource size table)
    return nil;
}

// Boot prerequisites (done before UIApplicationMain): directories / environment variables / log -- the host's early load reads these
static int boot_env(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *res = NSBundle.mainBundle.resourcePath, *pack = [res stringByAppendingPathComponent:@"pack"];
    for (NSString *d in @[@"save", @"temp"]) [fm createDirectoryAtPath:[doc stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
    // Keep game files and scratch data out of device backups (Documents is backed up by default; a RomFS placed there is many GB). Saves, logs and the pipeline list stay in the backup
    for (NSString *d in @[@"romfs", @"romfs.dmstore", @"temp"]) {
        NSURL *u = [NSURL fileURLWithPath:[doc stringByAppendingPathComponent:d]]; NSError *e = nil;
        if ([fm fileExistsAtPath:u.path] && ![u setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&e]) fprintf(stderr, "boot: %s could not be excluded from backup: %s\n", d.UTF8String, e.localizedDescription.UTF8String);
    }
    // Log: the host only writes to stderr; redirect it to Documents/log.txt (the previous one is kept as log.prev.txt), retrieve it from the Files app when something goes wrong
    NSString *log = [doc stringByAppendingPathComponent:@"log.txt"], *prev = [doc stringByAppendingPathComponent:@"log.prev.txt"];
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    // Environment switch files (for on-device diagnostics: a sideloaded app cannot be given environment variables from outside): one KEY=VALUE per line, # starts a comment; Documents/env.txt takes precedence over the pack's profile/env.txt (put there by build_ipa.sh's DM_ENV_FILE)
    for (NSString *ef in @[[doc stringByAppendingPathComponent:@"env.txt"], [pack stringByAppendingPathComponent:@"profile/env.txt"]]) {
        NSString *txt = [NSString stringWithContentsOfFile:ef encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); fprintf(stderr, "boot: env %s=%s (%s)\n", k.UTF8String, v.UTF8String, ef.lastPathComponent.UTF8String); }
        }
    }
    dm_settings_boot();   // Documents/settings.json (the in-app settings screen) and the Info.plist defaults, for every key env.txt did not set: DmSettings.m
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
    // The game files before the pack check: the pack holds no RomFS, so DM_ROMFS (set here) is the part the check accepts in its place
    struct dm_profile prof = {0}; char why[512];
    if (dm_profile_parse([pack stringByAppendingPathComponent:@"profile"].fileSystemRepresentation, &prof, why, sizeof why)) dm_pack_require(pack.fileSystemRepresentation);   // logs the reason, exits 78
    NSString *romfs = romfs_locate(prof.romfs_marker);
    if (!romfs) { fprintf(stderr, "boot: game files not found (Documents/romfs.dmstore, Documents/romfs or <App>/romfs)\n"); return 0; }
    fprintf(stderr, "boot: game files %s\n", romfs.fileSystemRepresentation);
    setenv("DM_ROMFS", romfs.fileSystemRepresentation, 0);
    setenv("DM_SAVE", [doc stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 0);
    setenv("DM_TEMP", [doc stringByAppendingPathComponent:@"temp"].fileSystemRepresentation, 0);
    chdir(doc.fileSystemRepresentation);
    NSString *fwcode = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"code.dylib"];   // the code linked as a dylib (build_ipa.sh CODE_DYLIB=1), not into this executable
    if ([fm fileExistsAtPath:fwcode]) setenv("DM_CODE", fwcode.fileSystemRepresentation, 0);
    dm_pack_require(pack.fileSystemRepresentation);   // a pack this engine cannot boot: the reason in log.txt, exit 78 (as dmhost)
    if (dm_boot_game(pack.fileSystemRepresentation)) return 0;   // the rest of the environment from the pack, the profile, then module tables / relocation / takeover in the background, in parallel with UIKit startup
    g_argv[0] = strdup("dmhost"); g_argv[1] = strdup(pack.fileSystemRepresentation); g_argc = 2;   // the same two arguments dm_boot_game gave the early start
    return 1;
}
static int g_boot_ok;

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
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = front_ios_root();
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)s { front_ios_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { front_ios_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { front_ios_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { front_ios_focus_event(3); }
@end

int main(int argc, char **argv) {
    @autoreleasepool { g_boot_ok = boot_env(); }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
