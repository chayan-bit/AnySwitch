// Hearth's Vibration settings mapped onto the host's rumble output (haptics_apple.m, upstream's): Vibration turns the game's rumble on or off (dm_haptics_set_enabled), Vibration strength
// is its gain (0...1 here; DM_RUMBLE_GAIN allows up to 3). Which hardware plays it, the controller in use or the phone, haptics_apple.m decides (DmGamepad.m routes the controller).
#import "DmHaptics.h"
#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#include "haptics_apple.h"

static BOOL g_on = YES;

void dm_haptics_start(void) {
    dm_haptics_apple_init();
    dm_haptics_set_enabled(g_on);
}
void dm_haptics_enable(BOOL on) { g_on = on; dm_haptics_set_enabled(on); }
void dm_haptics_strength(float strength) { dm_haptics_apple_set_gain(fmaxf(0, fminf(1, strength))); }
BOOL dm_haptics_can_vibrate(void) {
    if (CHHapticEngine.capabilitiesForHardware.supportsHaptics) return YES;
    for (GCController *c in GCController.controllers) if (c.haptics) return YES;
    return NO;
}
