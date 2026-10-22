// Haptics for the game's HD rumble (see DmHaptics.h). Everything that touches an engine runs on one serial queue (q); the main thread only builds the list of voices and sets two atomics.
#import "DmHaptics.h"
#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#include <stdatomic.h>
#include "dm.h"
#include "dm_input.h"
#import "DmHapticMap.h"

static const uint64_t k_stop_after_ns = 150000000ull;   // silence for this long stops the player (the engine idles, the actuator rests)
static const double k_event_seconds = 30;               // the longest continuous event Core Haptics allows; it loops

// One actuator: an engine and, while something plays, a looping continuous event whose intensity and sharpness are moved with dynamic parameters
@interface DmVoice : NSObject
@property (nonatomic, readonly) int actuator;   // 0 left, 1 right, -1 both (the device's engine, or a controller that has one engine)
- (instancetype)initWithName:(NSString *)name actuator:(int)actuator queue:(dispatch_queue_t)q make:(CHHapticEngine *(^)(NSError **))make;
- (void)intensity:(float)i sharpness:(float)s at:(uint64_t)now;
- (void)shutdown;   // stop playing and let the engine go
@end

@implementation DmVoice {
    NSString *_name; int _actuator; dispatch_queue_t _q; CHHapticEngine *(^_make)(NSError **);
    CHHapticEngine *_engine; id<CHHapticAdvancedPatternPlayer> _player; BOOL _running, _playing; float _i, _s; uint64_t _zeroSince, _retryAt; int _logged;
}
- (int)actuator { return _actuator; }
- (instancetype)initWithName:(NSString *)name actuator:(int)actuator queue:(dispatch_queue_t)q make:(CHHapticEngine *(^)(NSError **))make {
    if ((self = [super init])) { _name = [name copy]; _actuator = actuator; _q = q; _make = [make copy]; }
    return self;
}
- (void)fail:(NSError *)e {
    if (_logged++ < 3) LOG("haptics: %s: %s", _name.UTF8String, e.localizedDescription.UTF8String ?: "no engine");
    _engine = nil; _player = nil; _running = NO; _playing = NO; _retryAt = now_ns() + 2000000000ull;   // try again in two seconds
}
- (BOOL)ensureEngine {
    if (_engine && _running) return YES;
    if (now_ns() < _retryAt) return NO;
    NSError *e = nil;
    if (!_engine) {
        _engine = _make(&e); if (!_engine) { [self fail:e]; return NO; }
        _engine.playsHapticsOnly = YES;
        __weak DmVoice *w = self; dispatch_queue_t q = _q;   // the engine stops by itself when idle, in the background and on an interruption: the next value starts it again
        _engine.stoppedHandler = ^(CHHapticEngineStoppedReason r) { (void)r; dispatch_async(q, ^{ DmVoice *s = w; if (s) { s->_running = NO; s->_playing = NO; s->_player = nil; } }); };
        _engine.resetHandler = ^{ dispatch_async(q, ^{ DmVoice *s = w; if (s) { s->_running = NO; s->_playing = NO; s->_player = nil; } }); };
    }
    if (![_engine startAndReturnError:&e]) { [self fail:e]; return NO; }
    _running = YES; return YES;
}
// A fresh player per start: the pattern's own initial dynamic values carry the first intensity and sharpness, so nothing plays at the wrong level before the first update
- (BOOL)startPlayerAt:(float)i sharpness:(float)s {
    NSError *e = nil;
    CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
        parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1], [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f]]
        relativeTime:0 duration:k_event_seconds];
    CHHapticPattern *p = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:[self dynamicI:i s:s] error:&e];
    _player = p ? [_engine createAdvancedPlayerWithPattern:p error:&e] : nil;
    if (!_player) { [self fail:e]; return NO; }
    _player.loopEnabled = YES;
    if (![_player startAtTime:CHHapticTimeImmediate error:&e]) { [self fail:e]; return NO; }
    _playing = YES; _i = i; _s = s; return YES;
}
- (NSArray<CHHapticDynamicParameter *> *)dynamicI:(float)i s:(float)s {   // intensity control multiplies the event's 1.0; sharpness control adds to its 0.5
    return @[[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:i relativeTime:0],
             [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:s - 0.5f relativeTime:0]];
}
- (void)shutdown {
    if (_playing) [self stopPlayer];
    if (_engine) { [_engine stopWithCompletionHandler:nil]; _engine = nil; _running = NO; }
}
- (void)stopPlayer { NSError *e = nil; [_player stopAtTime:CHHapticTimeImmediate error:&e]; _player = nil; _playing = NO; _i = 0; }
- (void)intensity:(float)i sharpness:(float)s at:(uint64_t)now {
    if (i <= 0) {
        if (!_playing) return;
        if (!_zeroSince) _zeroSince = now;
        if (_i != 0) { NSError *e = nil; [_player sendParameters:[self dynamicI:0 s:_s] atTime:CHHapticTimeImmediate error:&e]; _i = 0; }
        if (now - _zeroSince > k_stop_after_ns) [self stopPlayer];
        return;
    }
    _zeroSince = 0;
    if (!_playing) { if ([self ensureEngine]) [self startPlayerAt:i sharpness:s]; return; }
    if (fabsf(i - _i) < 0.02f && fabsf(s - _s) < 0.04f) return;   // not worth a parameter update
    NSError *e = nil;
    if (![_player sendParameters:[self dynamicI:i s:s] atTime:CHHapticTimeImmediate error:&e]) { [self fail:e]; return; }
    _i = i; _s = s;
}
@end

#pragma mark - The poll loop

static dispatch_queue_t g_q; static dispatch_source_t g_timer;
static NSArray<DmVoice *> *g_phone, *g_pads;   // g_q only: the device's voice (or none), the attached controller's voices (or none)
static _Atomic int g_on = 1; static _Atomic float g_strength = 1;
static BOOL g_phone_ok;                          // the device has a haptic engine (decided once, main thread)

// The controller's haptics: left and right handles when it has them, else one voice for the whole controller
static NSArray<DmVoice *> *pad_voices(void) {
    for (GCController *c in GCController.controllers) {
        GCDeviceHaptics *h = c.haptics; if (!h) continue;
        NSSet *loc = h.supportedLocalities; NSString *name = c.vendorName ?: @"controller";
        CHHapticEngine *(^left)(NSError **) = ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityLeftHandle]; };
        CHHapticEngine *(^right)(NSError **) = ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityRightHandle]; };
        if ([loc containsObject:GCHapticsLocalityLeftHandle] && [loc containsObject:GCHapticsLocalityRightHandle])
            return @[[[DmVoice alloc] initWithName:[name stringByAppendingString:@" left"] actuator:0 queue:g_q make:left], [[DmVoice alloc] initWithName:[name stringByAppendingString:@" right"] actuator:1 queue:g_q make:right]];
        NSString *all = [loc containsObject:GCHapticsLocalityAll] ? GCHapticsLocalityAll : GCHapticsLocalityDefault;
        if ([loc containsObject:all]) return @[[[DmVoice alloc] initWithName:name actuator:-1 queue:g_q make:^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:all]; }]];
    }
    return @[];
}
BOOL dm_haptics_available(void) {
    if (g_phone_ok || (!g_q && CHHapticEngine.capabilitiesForHardware.supportsHaptics)) return YES;
    for (GCController *c in GCController.controllers) if (c.haptics) return YES;
    return NO;
}

static void rebuild(void) {   // main thread: the controllers changed
    NSArray *pads = pad_voices(); BOOL avail = g_phone_ok || pads.count > 0;
    dm_vib_set_available(avail);
    dispatch_async(g_q, ^{
        for (DmVoice *v in g_pads) [v shutdown];   // the old voices rest
        g_pads = pads;
        LOG("haptics: %s", pads.count ? "the controller's actuators play the game's rumble" : g_phone_ok ? "the device's haptic engine plays the game's rumble" : "no haptic hardware: the game sees no vibration devices");
    });
}

// What one voice should play now: its game device's value while it is fresh and the setting is on, else silence
static void play(DmVoice *voice, BOOL active, BOOL on, float strength, int devs, const dm_vib *v, const uint64_t *age, uint64_t now) {
    static const dm_vib silent = {0, 160, 0, 320};
    const dm_vib *val = &silent;
    if (active && on) {
        if (voice.actuator >= 0) { int d = dm_haptic_source(voice.actuator, devs); if (dm_haptic_fresh(age[d])) val = &v[d]; }
        else for (int d = 0; d < devs && d < 2; d++) if (dm_haptic_fresh(age[d]) && dm_haptic_intensity(&v[d], 1) > dm_haptic_intensity(val, 1)) val = &v[d];   // one engine for both: the stronger device
    }
    [voice intensity:dm_haptic_intensity(val, strength) sharpness:dm_haptic_sharpness(val) at:now];
}
static void tick(void) {   // g_q: 60 Hz
    int devs = dm_vib_devices(); if (!devs) return;   // the game has not asked for a vibration device: nothing to play
    dm_vib v[2]; uint64_t age[2] = {dm_vib_get(0, &v[0]), dm_vib_get(1, &v[1])}, now = now_ns();
    BOOL on = atomic_load_explicit(&g_on, memory_order_relaxed) != 0; float strength = atomic_load_explicit(&g_strength, memory_order_relaxed);
    BOOL pads = g_pads.count > 0;
    for (DmVoice *voice in g_pads) play(voice, YES, on, strength, devs, v, age, now);
    for (DmVoice *voice in g_phone) play(voice, !pads, on, strength, devs, v, age, now);   // an attached controller takes over from the device
}

void dm_haptics_enable(BOOL on) { atomic_store_explicit(&g_on, on ? 1 : 0, memory_order_relaxed); }
void dm_haptics_strength(float s) { atomic_store_explicit(&g_strength, dm_haptic_clamp01(s), memory_order_relaxed); }

void dm_haptics_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_q = dispatch_queue_create("anyswitch.haptics", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        g_phone_ok = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
        NSArray<DmVoice *> *phone = g_phone_ok ? @[[[DmVoice alloc] initWithName:@"device" actuator:-1 queue:g_q make:^CHHapticEngine *(NSError **e) { return [[CHHapticEngine alloc] initAndReturnError:e]; }]] : @[];
        dispatch_sync(g_q, ^{ g_phone = phone; g_pads = @[]; });
        for (NSNotificationName n in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *x) { (void)x; rebuild(); }];
        rebuild();
        g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
        dispatch_source_set_timer(g_timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 60, NSEC_PER_SEC / 240);
        dispatch_source_set_event_handler(g_timer, ^{ tick(); });
        dispatch_resume(g_timer);
    });
}
