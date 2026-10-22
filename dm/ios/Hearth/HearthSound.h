// Hearth's menu sounds, synthesized at run time (no sample files): short sine tones with a soft attack and an exponential fade.
// They follow the silent switch and the Volume setting, and stay quiet while a game runs (hearth_running_game).
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, HearthSoundKind) {
    HearthSoundMove,     // a soft short tick: the focus moves
    HearthSoundOpen,     // two notes rising: open, launch
    HearthSoundBack,     // a low muted tap: back
    HearthSoundClose,    // two notes falling: close
};

void hearth_sound(HearthSoundKind kind);
// The samples of a sound at a sample rate (mono float, -1...1), for the Mac test; the player uses the same
NSData *hearth_sound_samples(HearthSoundKind kind, double rate);
