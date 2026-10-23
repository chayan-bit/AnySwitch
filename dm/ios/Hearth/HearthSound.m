// Hearth's menu sounds (HearthSound.h): each one is a list of notes, rendered once into a buffer and played on an AVAudioEngine under the Ambient session category.
#import "HearthSound.h"
#include <math.h>
#if TARGET_OS_IOS
#import <AVFoundation/AVFoundation.h>
#import "DmSettings.h"
#import "HearthLaunch.h"
#endif

typedef struct { double start, hz, length, gain; } Note;   // seconds, Hz, seconds (to about -60 dB), 0...1

static int notes_of(HearthSoundKind k, const Note **out) {
    static const Note move[] = {{0, 1320, 0.05, 0.18}};
    static const Note open[] = {{0, 660, 0.22, 0.30}, {0.09, 990, 0.30, 0.30}};    // a fifth up
    static const Note back[] = {{0, 330, 0.08, 0.30}};
    static const Note close[] = {{0, 880, 0.22, 0.28}, {0.10, 587, 0.34, 0.28}};  // a fifth down
    switch (k) {
        case HearthSoundMove: *out = move; return 1;
        case HearthSoundOpen: *out = open; return 2;
        case HearthSoundBack: *out = back; return 1;
        case HearthSoundClose: *out = close; return 2;
    }
    *out = NULL; return 0;
}

NSData *hearth_sound_samples(HearthSoundKind kind, double rate) {
    const Note *n; int count = notes_of(kind, &n);
    double end = 0; for (int i = 0; i < count; i++) end = fmax(end, n[i].start + n[i].length);
    size_t frames = (size_t)ceil(end * rate);
    NSMutableData *d = [NSMutableData dataWithLength:frames * sizeof(float)]; float *s = d.mutableBytes;
    for (int i = 0; i < count; i++) {
        size_t from = (size_t)(n[i].start * rate), len = (size_t)(n[i].length * rate);
        double attack = 0.004 * rate, decay = len / 6.9;   // 4 ms ramp in (no click), then e^-6.9 = -60 dB at the end
        for (size_t f = 0; f < len && from + f < frames; f++) {
            double env = fmin(1.0, f / attack) * exp(-(double)f / decay);
            s[from + f] += (float)(n[i].gain * env * sin(2 * M_PI * n[i].hz * f / rate));
        }
    }
    for (size_t f = 0; f < frames; f++) s[f] = fmaxf(-1, fminf(1, s[f]));
    return d;
}

#if TARGET_OS_IOS
void hearth_sound(HearthSoundKind kind) {
    if (hearth_running_game()) return;   // the game owns the sound while it runs
    static AVAudioEngine *engine; static AVAudioPlayerNode *player; static AVAudioFormat *fmt; static NSMutableDictionary<NSNumber *, AVAudioPCMBuffer *> *cache;
    if (!engine) {
        NSError *e = nil;
        if (![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient error:&e]) fprintf(stderr, "hearth: sound session: %s\n", e.localizedDescription.UTF8String);   // follows the silent switch, mixes with other audio
        engine = [AVAudioEngine new]; player = [AVAudioPlayerNode new]; cache = [NSMutableDictionary dictionary];
        fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
        [engine attachNode:player]; [engine connect:player to:engine.mainMixerNode format:fmt];
    }
    if (!engine.running) { NSError *e = nil; if (![engine startAndReturnError:&e]) { fprintf(stderr, "hearth: sound engine: %s\n", e.localizedDescription.UTF8String); return; } }
    AVAudioPCMBuffer *b = cache[@(kind)];
    if (!b) {
        NSData *d = hearth_sound_samples(kind, fmt.sampleRate); AVAudioFrameCount n = (AVAudioFrameCount)(d.length / sizeof(float));
        b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:n]; b.frameLength = n; memcpy(b.floatChannelData[0], d.bytes, d.length);
        cache[@(kind)] = b;
    }
    player.volume = (float)[DmSettings.systemStore doubleForKey:@"DM_VOLUME"];
    [player scheduleBuffer:b atTime:nil options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
    if (!player.playing) [player play];
}
#endif
