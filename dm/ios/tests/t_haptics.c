// How a Switch HD rumble value maps to Core Haptics intensity and sharpness (dm/ios/Sources/DmHapticMap.h): a plain C check, runs on the Mac: make -C dm/ios/tests run
#include <stdio.h>
#include <math.h>
#include "DmHapticMap.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define NEAR(a, b, e) CHECK(fabsf((a) - (b)) <= (e), "%g vs %g", (double)(a), (double)(b))

int main(void) {
    dm_vib idle = {0, 160, 0, 320}, low = {1, 160, 0, 320}, high = {0, 160, 1, 320}, both = {0.5f, 160, 0.5f, 320}, quiet = {0.01f, 160, 0, 320};
    // intensity: the two bands add as energy (a full band is 1, two half bands about 0.71), capped at 1, then scaled by the player's strength
    NEAR(dm_haptic_intensity(&idle, 1), 0, 0); NEAR(dm_haptic_intensity(&low, 1), 1, 1e-6f); NEAR(dm_haptic_intensity(&high, 1), 1, 1e-6f); NEAR(dm_haptic_intensity(&both, 1), 0.7071f, 1e-3f);
    dm_vib loud = {1, 160, 1, 320}; NEAR(dm_haptic_intensity(&loud, 1), 1, 0);
    NEAR(dm_haptic_intensity(&low, 0.5f), 0.5f, 1e-6f); NEAR(dm_haptic_intensity(&low, 0), 0, 0); NEAR(dm_haptic_intensity(&low, 2), 1, 0); NEAR(dm_haptic_intensity(&low, -1), 0, 0); NEAR(dm_haptic_intensity(&low, NAN), 0, 0);
    NEAR(dm_haptic_intensity(&quiet, 1), 0, 0);   // under the floor: the actuator would not be felt, so the engine is left stopped
    NEAR(dm_haptic_intensity(&low, 0.005f), 0, 0);   // the same after the strength is applied
    // sharpness: the amplitude-weighted mean of the two bands' frequencies on a log scale, 40 Hz = 0 and 1252 Hz = 1; no amplitude is neutral
    NEAR(dm_haptic_sharpness(&idle), 0.5f, 0); NEAR(dm_haptic_sharpness(&low), 0.4026f, 1e-3f); NEAR(dm_haptic_sharpness(&high), 0.6038f, 1e-3f); NEAR(dm_haptic_sharpness(&both), 0.5032f, 1e-3f);
    dm_vib lo = {1, 40, 0, 320}, hi = {0, 160, 1, 1252}, over = {1, 5, 0, 320}, nan = {1, NAN, 0, 320};
    NEAR(dm_haptic_sharpness(&lo), 0, 1e-6f); NEAR(dm_haptic_sharpness(&hi), 1, 1e-6f); NEAR(dm_haptic_sharpness(&over), 0, 1e-6f); NEAR(dm_haptic_sharpness(&nan), 0.5f, 0);
    dm_vib mix = {1, 160, 0.25f, 640}; CHECK(dm_haptic_sharpness(&mix) > dm_haptic_sharpness(&low) && dm_haptic_sharpness(&mix) < dm_haptic_sharpness(&high) + 0.2f, "the louder band leads");
    // a value the game stopped sending does not buzz for ever
    CHECK(dm_haptic_fresh(0) && dm_haptic_fresh(400000000ull) && !dm_haptic_fresh(600000000ull) && !dm_haptic_fresh(UINT64_MAX), "freshness");
    // which game device drives which actuator: with one game device (a pro controller style) both sides follow it; with two, each side its own
    CHECK(dm_haptic_source(0, 1) == 0 && dm_haptic_source(1, 1) == 0 && dm_haptic_source(0, 2) == 0 && dm_haptic_source(1, 2) == 1 && dm_haptic_source(1, 0) == 0, "device routing");
    printf("t_haptics: %d checks, %d failed\n", g_n, g_fail);
    return g_fail ? 1 : 0;
}
