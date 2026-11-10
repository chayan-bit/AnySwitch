// Hearth's Vibration settings on top of the host's rumble output (dm/host/haptics_apple.m: the game's HD rumble on a controller's haptics, else the phone's own engine; an iPad has none).
#import <Foundation/Foundation.h>

void dm_haptics_start(void);             // main thread, once, when the game starts: starts the rumble output and routes player 1 to the connected controller (or the device)
void dm_haptics_enable(BOOL on);         // the Vibration setting (live)
void dm_haptics_strength(float strength);   // the Vibration strength setting, 0...1 (live)
BOOL dm_haptics_can_vibrate(void);       // the device or an attached controller can vibrate (the settings screen's "haptics" capability)
