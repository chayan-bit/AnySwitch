// Haptics for the game's HD rumble (hle_vibration.c keeps the latest values; DmHapticMap.h maps one to Core Haptics intensity and sharpness).
// A controller that has haptics (GCController) plays them, left and right actuators from the game's left and right devices; without one the device's own haptic engine plays (a phone;
// an iPad has none). One poll thread at 60 Hz reads the host's mailbox, so the game thread never waits and a burst of values collapses to what the engine can play.
#import <Foundation/Foundation.h>

void dm_haptics_start(void);             // main thread, once, when the game starts: finds the hardware, tells the host, starts polling
void dm_haptics_enable(BOOL on);         // the Vibration setting (live)
void dm_haptics_strength(float strength);   // the Vibration strength setting, 0...1 (live)
BOOL dm_haptics_available(void);         // the device or an attached controller can vibrate (the settings screen's "haptics" capability)
