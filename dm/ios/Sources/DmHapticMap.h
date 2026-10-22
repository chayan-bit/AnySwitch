// How a Switch HD rumble value (dm_vib: two bands, each an amplitude 0...1 and a frequency in Hz) becomes a Core Haptics continuous event, in plain C so it runs in a Mac test (dm/ios/tests/t_haptics.c).
//   intensity  = sqrt(low^2 + high^2), capped at 1 (the two bands add as energy: one full band is 1, two half bands 0.71), times the player's strength; under 2% of the game's amplitude is not felt: 0
//   sharpness  = where the value sits between 40 Hz (0) and 1252 Hz (1) on a log scale, the two bands' frequencies weighted by their amplitudes; with no amplitude 0.5 (160 Hz alone is 0.40, 320 Hz alone 0.60)
// A value the game stopped sending for half a second is treated as silence, so a game that never sends a closing zero does not leave the device buzzing.
#pragma once
#include <math.h>
#include <stdint.h>
#include "dm_input.h"

enum { DM_HAPTIC_STALE_MS = 500 };
#define DM_HAPTIC_FLOOR 0.02f   // the game's amplitude below which nothing is played

static inline float dm_haptic_clamp01(float x) { return !(x > 0) ? 0 : x > 1 ? 1 : x; }   // NaN is 0
static inline float dm_haptic_intensity(const dm_vib *v, float strength) {
    float a = dm_haptic_clamp01(v->amp_low), b = dm_haptic_clamp01(v->amp_high), i = fminf(sqrtf(a * a + b * b), 1.f);
    if (i < DM_HAPTIC_FLOOR) return 0;
    i *= dm_haptic_clamp01(strength);
    return i < 0.01f ? 0 : i;
}
static inline float dm_haptic_sharpness(const dm_vib *v) {
    float a = dm_haptic_clamp01(v->amp_low), b = dm_haptic_clamp01(v->amp_high), fl = isfinite(v->freq_low) ? v->freq_low : 160.f, fh = isfinite(v->freq_high) ? v->freq_high : 320.f;
    if (a + b < 1e-4f || !isfinite(v->freq_low) || !isfinite(v->freq_high)) return 0.5f;
    fl = fminf(fmaxf(fl, 40.f), 1252.f); fh = fminf(fmaxf(fh, 40.f), 1252.f);
    float mean = (a * log2f(fl) + b * log2f(fh)) / (a + b);
    return dm_haptic_clamp01((mean - log2f(40.f)) / (log2f(1252.f) - log2f(40.f)));
}
static inline int dm_haptic_fresh(uint64_t age_ns) { return age_ns != UINT64_MAX && age_ns < (uint64_t)DM_HAPTIC_STALE_MS * 1000000ull; }
// Which game device drives an actuator (0 left, 1 right): a game that asked for one device drives both sides from it
static inline int dm_haptic_source(int actuator, int game_devices) { return game_devices >= 2 && actuator == 1 ? 1 : 0; }
