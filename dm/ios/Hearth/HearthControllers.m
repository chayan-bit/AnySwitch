// Hearth's Controllers page (HearthControllers.h)
#import "HearthControllers.h"
#import "HearthInputTestVC.h"
#import "HearthHomeViews.h"
#import <GameController/GameController.h>

void dm_gamepad_reload_maps(void);
int dm_gamepad_player_of(GCController *c);   // DmGamepad.m: 0 = player 1, -1 = not a player (yet)
int dm_gamepad_player_mode(void);            // 0 each its own player, 1 all player 1, 2 press a button to join
void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly));

static DmPageItem *info(NSString *t, NSString *d) { return [DmPageItem info:t detail:d]; }

static NSArray<DmPageItem *> *connected_items(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (GCController *c in GCController.controllers) {
        if (!c.extendedGamepad) continue;
        GCDeviceBattery *b = c.battery; BOOL charging = b.batteryState == GCDeviceBatteryStateCharging;
        NSString *bat = b && b.batteryLevel > 0 ? [NSString stringWithFormat:@" Battery %.0f%%%@.", b.batteryLevel * 100, charging ? @", charging" : @""] : @"";
        int p = dm_gamepad_player_of(c);
        NSString *who = p >= 0 ? [NSString stringWithFormat:@"Plays as player %d.", p + 1] : dm_gamepad_player_mode() == 2 ? @"Press one of its buttons to join." : @"Not playing: every player is taken.";
        [out addObject:info(c.vendorName.length ? c.vendorName : @"Controller", [who stringByAppendingString:bat])];
    }
    BOOL pads = out.count > 0;
    if (GCKeyboard.coalescedKeyboard) [out addObject:info(@"Keyboard", @"Plays as player 1. Its keys are on the Keyboard keys page.")];
    [out addObject:info(@"Touch controls", pads ? @"Hidden during a game while a controller is connected." : @"Shown during a game while no controller is connected.")];
    if (!pads) [out addObject:info(@"No controller connected", @"The Pairing page says how to connect one.")];
    int mode = dm_gamepad_player_mode();
    [out addObject:info(@"Player order", mode == 1 ? @"Every controller and the keyboard play as player 1." : mode == 2 ? @"Each controller becomes a player when one of its buttons is pressed. The keyboard and the touch controls play as player 1."
                                                    : @"Each controller is a player in the order it connected. The keyboard and the touch controls play as player 1.")];
    return out;
}
static NSArray<DmPageItem *> *pairing_items(void) {
    return @[info(@"Connect a controller", @"Hold the controller's pairing button until its light flashes. Then open the Settings app, choose Bluetooth, and choose the controller under Other Devices."),
             info(@"Which controllers work", @"Any controller iPadOS supports. Once it shows as connected in the Settings app, it plays here."),
             info(@"Forget a controller", @"In the Settings app under Bluetooth, choose the info button beside the controller, then Forget This Device."),
             info(@"Connect a keyboard", @"By Bluetooth or a cable. W A S D move, J is A and K is B; every key is on the Keyboard keys page.")];
}
static DmPage *section_page(NSString *ident) {
    for (DmSection *s in DmSettings.systemStore.sections) if ([s.ident isEqual:ident]) return [DmPage section:s];
    return nil;
}

// Test input over the page: it takes the controller and gives it back to the page when it closes
static void open_test(DmSettingsVC *vc) {
    if (!vc) return;
    HearthInputTestVC *t = [HearthInputTestVC new]; __weak DmSettingsVC *wv = vc; __weak HearthInputTestVC *wt = t;
    t.onClose = ^{
        HearthInputTestVC *x = wt; DmSettingsVC *v = wv; if (!x) return;
        [x willMoveToParentViewController:nil]; hearth_ax_cover(x.view, NO); [x.view removeFromSuperview]; [x removeFromParentViewController];
        if (v) { dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { [v padState:m lx:lx ly:ly]; }); [v resumeController]; [v becomeFirstResponder]; }
    };
    [vc addChildViewController:t];
    t.view.frame = vc.view.bounds; t.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:t.view]; [t didMoveToParentViewController:vc]; hearth_ax_cover(t.view, YES);
}

DmSettingsVC *hearth_controllers(CGSize size) {
    DmSettingsVC *v = [[DmSettingsVC alloc] initWithSettings:DmSettings.systemStore size:size];
    __weak DmSettingsVC *w = v;
    NSMutableArray *p = [NSMutableArray arrayWithObjects:
        [DmPage page:@"Connected" icon:@"dot.radiowaves.left.and.right" items:^{ return connected_items(); }],
        [DmPage page:@"Pairing" icon:@"link" items:^{ return pairing_items(); }], nil];
    for (NSString *ident in @[@"players", @"map_pad", @"map_keys"]) { DmPage *s = section_page(ident); if (s) [p addObject:s]; }
    [p addObject:[DmPage page:@"Test input" icon:@"scope" items:^{
        return @[[DmPageItem action:@"Test input" detail:@"Shows each button and stick of a controller or a keyboard as it is pressed, after the maps above." run:^{ open_test(w); }]];
    }]];
    DmPage *touch = section_page(@"controls"); if (touch) [p addObject:touch];   // the touch controls' own rows, as in System Settings
    v.pages = p; v.heading = @"Controllers"; v.pageRestoreOnly = YES;   // Restore all here would also reset Display, Audio and the rest
    v.onChange = ^{ dm_gamepad_reload_maps(); };   // the system store announces nothing: the maps are read again at once
    return v;
}
