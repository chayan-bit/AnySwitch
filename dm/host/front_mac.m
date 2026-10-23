// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// Keys (keymap.h, the same table as Hearth's keyboard play; DM_MAP_KEY_* changes a key): WASD left stick, P ; L ' right stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR,
// F=press left stick G=press right stick, Return=+ Tab=−. Space shakes the controller while no row of the map uses it.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include "keymap.h"
#include <signal.h>

static CAMetalLayer *g_layer;
static uint64_t g_down[4], g_shake;   // the keys held (HID usages, keymap.h)
static uint8_t g_map[DM_KEYMAP_ROWS];

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static _Atomic int g_screen_fps;   // the window's screen's maximumFramesPerSecond, kept up to date when the window moves to another screen
int front_screen_max_fps(void) { return g_screen_fps; }
static void push(void) {
    uint64_t b; int32_t lx, ly, rx, ry;
    dm_keymap_state(g_map, g_down, &b, &lx, &ly, &rx, &ry);
    dm_input_set(b | g_shake, lx, ly, rx, ry);
}
// macOS virtual key codes to HID usages, for the keys keymap.c offers (and Space); 0: not a key the map knows
static int hid_of(unsigned short c) {
    static const uint8_t t[128] = {
        [0] = 4, [11] = 5, [8] = 6, [2] = 7, [14] = 8, [3] = 9, [5] = 10, [4] = 11, [34] = 12, [38] = 13, [40] = 14, [37] = 15, [46] = 16, [45] = 17, [31] = 18, [35] = 19,
        [12] = 20, [15] = 21, [1] = 22, [17] = 23, [32] = 24, [9] = 25, [13] = 26, [7] = 27, [16] = 28, [6] = 29,
        [18] = 30, [19] = 31, [20] = 32, [21] = 33, [23] = 34, [22] = 35, [26] = 36, [28] = 37, [25] = 38, [29] = 39,
        [36] = 40, [48] = 43, [49] = 44, [51] = 42, [126] = 82, [125] = 81, [123] = 80, [124] = 79,
        [56] = 225, [60] = 229, [59] = 224, [58] = 226, [61] = 230,
        [41] = 51, [39] = 52, [43] = 54, [47] = 55, [44] = 56, [33] = 47, [30] = 48, [27] = 45, [24] = 46, [42] = 49, [50] = 53,
    };
    return c < 128 ? t[c] : 0;
}
static int space_mapped(void) { for (int r = 0; r < DM_KEYMAP_ROWS; r++) if (g_map[r] == 44) return 1; return 0; }
static void on_key(unsigned short code, int down) {
    int u = hid_of(code); if (!u) return;
    if (down) g_down[u >> 6] |= 1ull << (u & 63); else g_down[u >> 6] &= ~(1ull << (u & 63));
    if (u == 44 && !space_mapped()) g_shake = down ? DM_BTN_SHAKE : 0;   // Space: shaken while held
    push();
}
// Shift, Control and Option send flagsChanged, not key down and up: the flag of the key's own side says whether it is held
static void on_flags(NSEvent *e) {
    NSEventModifierFlags f = e.modifierFlags; unsigned short c = e.keyCode;
    int down = c == 56 || c == 60 ? (f & NSEventModifierFlagShift) != 0 : c == 59 ? (f & NSEventModifierFlagControl) != 0 : c == 58 || c == 61 ? (f & NSEventModifierFlagOption) != 0 : -1;
    if (down >= 0) on_key(c, down);
}

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

void front_run(void (*guest)(void)) {
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = [@(g_profile.name) stringByAppendingString:@" - AnySwitch"];   // the game profile's name (game name label); %s would read its UTF-8 as Mac Roman
        NSView *v = win.contentView;
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        v.layer = g_layer;
        [win center];
        [win makeKeyAndOrderFront:nil];
        g_screen_fps = (int)(win.screen ?: NSScreen.mainScreen).maximumFramesPerSecond;
        [NSApp activateIgnoringOtherApps:YES];
        int bad = dm_keymap_load(g_map); if (bad) LOG("[RED] front end: %d DM_MAP_KEY_* entries are not keys the map offers; those keys keep their defaults", bad);
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.type == NSEventTypeFlagsChanged) { on_flags(e); return e; }
            if (!e.isARepeat) on_key(e.keyCode, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        // Mouse as a single-point touchscreen (for testing touch on the local machine, front.h dm_touch_set): left button down / drag = finger 0 at the normalized coordinates, release = lifted
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;
            if (e.type == NSEventTypeLeftMouseUp) { dm_touch_set(NULL, 0); return nil; }
            NSPoint p = [v convertPoint:e.locationInWindow fromView:nil]; NSSize sz = v.bounds.size;
            if (sz.width <= 0 || sz.height <= 0) return e;
            dm_touch t = {0, (float)(p.x / sz.width), (float)(1.0 - p.y / sz.height)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
            dm_touch_set(&t, 1); return nil;
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidChangeScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (win.screen) g_screen_fps = (int)win.screen.maximumFramesPerSecond; }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (!win.miniaturized) dm_focus_set(2); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = title && *title ? @(title) : @"Input";
        NSString *info = [[@[@(sub ? sub : ""), @(guide ? guide : "")] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@"\n"];
        a.informativeText = info;
        [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
        f.stringValue = initial ? @(initial) : @"";
        if (guide && *guide) f.placeholderString = @(guide);
        a.accessoryView = f; a.window.initialFirstResponder = f;
        r = [a runModal] == NSAlertFirstButtonReturn;
        text = f.stringValue;
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
