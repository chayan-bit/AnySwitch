// Vibration unit test (hle_vibration.c): what the game's nn::hid calls report (devices, info, permission), how values are kept (latest wins, clamped, quantized), the batch call,
// and that sending never waits (a flood of values from the game thread while a consumer reads). The haptics engine itself is the front end's (dm/ios/Sources/DmHaptics.m).
#include "../hle_vibration.c"
#include <time.h>
#include <pthread.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define NEAR(a, b, e) CHECK(fabsf((a) - (b)) <= (e), "%g vs %g", (double)(a), (double)(b))

static _Atomic int g_stop; static _Atomic uint64_t g_reads;
static void *reader(void *arg) { (void)arg; dm_vib v; while (!atomic_load(&g_stop)) { dm_vib_get(0, &v); dm_vib_get(1, &v); atomic_fetch_add(&g_reads, 1); } return NULL; }

int main(void) {
    uint32_t id = 0x20, h[4]; float v[4], got[4]; dm_vib g;
    // 1. no haptic hardware: no devices, vibration not permitted (what a game saw before there was any), a value sent anyway is accepted and ignored by the front end
    CHECK(h_hid_VibPermit() == 0, "not permitted"); CHECK(h_hid_VibHandles(h, 4, &id, STYLE_HANDHELD) == 0, "no devices");
    // 2. with hardware: handheld and dual Joy-Con report left and right, anything else one; the count is capped at what the game asks for; handles carry the device index
    dm_vib_set_available(1); CHECK(h_hid_VibPermit() == 1, "permitted");
    CHECK(h_hid_VibHandles(h, 4, &id, STYLE_HANDHELD) == 2, "handheld: 2"); CHECK(((h[0] >> 16) & 0xff) == 0 && ((h[1] >> 16) & 0xff) == 1, "device indexes %x %x", h[0], h[1]);
    CHECK((h[0] & 0xff) == 1 && ((h[0] >> 8) & 0xff) == 0x20, "style and id in the handle: %x", h[0]);
    CHECK(h_hid_VibHandles(h, 1, &id, STYLE_HANDHELD) == 1, "capped at the request"); CHECK(h_hid_VibHandles(h, 4, &id, STYLE_JOYDUAL) == 2, "dual joy-con: 2");
    CHECK(h_hid_VibHandles(h, 4, &id, STYLE_FULLKEY) == 1, "full key: 1"); CHECK(h_hid_VibHandles(h, 0, &id, STYLE_FULLKEY) == 0, "no room");
    CHECK(dm_vib_devices() == 2, "the game has asked for two devices: %d", dm_vib_devices());
    h_hid_VibHandles(h, 4, &id, STYLE_HANDHELD);
    // 3. device info: a linear resonant actuator, left then right
    uint32_t info[2]; h_hid_VibInfo(info, &h[0]); CHECK(info[0] == 1 && info[1] == 1, "left LRA: %u %u", info[0], info[1]); h_hid_VibInfo(info, &h[1]); CHECK(info[0] == 1 && info[1] == 2, "right LRA: %u %u", info[0], info[1]);
    // 4. before anything is sent a device reads the SDK's idle value (no amplitude, 160 Hz and 320 Hz), with no age
    CHECK(dm_vib_get(0, &g) == UINT64_MAX, "never sent"); NEAR(g.amp_low, 0, 0); NEAR(g.freq_low, 160, 0); NEAR(g.amp_high, 0, 0); NEAR(g.freq_high, 320, 0);
    h_hid_VibActual(got, &h[0]); NEAR(got[1], 160, 0); NEAR(got[3], 320, 0);
    // 5. a value is kept (quantized to 1/255 and 1/8 Hz), the latest wins, each device is its own, the serial counts
    uint64_t s0 = dm_vib_serial(); v[0] = 0.5f; v[1] = 200.f; v[2] = 0.25f; v[3] = 400.f; h_hid_SendVib(&h[0], v);
    uint64_t age = dm_vib_get(0, &g); CHECK(age < 1000000000ull, "fresh"); NEAR(g.amp_low, 0.5f, 1.f / 255); NEAR(g.freq_low, 200.f, 0.125f); NEAR(g.amp_high, 0.25f, 1.f / 255); NEAR(g.freq_high, 400.f, 0.125f);
    CHECK(dm_vib_get(1, &g) == UINT64_MAX, "device 1 untouched"); CHECK(dm_vib_serial() == s0 + 1, "serial");
    v[0] = 1.f; v[1] = 160.f; v[2] = 0.f; v[3] = 320.f; h_hid_SendVib(&h[0], v); dm_vib_get(0, &g); NEAR(g.amp_low, 1.f, 0); CHECK(g.amp_high == 0, "latest wins");
    h_hid_VibActual(got, &h[0]); NEAR(got[0], 1.f, 0);
    // 6. out-of-range values are clamped, not-a-number is silence, frequencies stay inside the actuator's 40 to 1252 Hz band
    v[0] = 7.f; v[1] = 5.f; v[2] = -1.f; v[3] = 99999.f; h_hid_SendVib(&h[1], v); dm_vib_get(1, &g);
    NEAR(g.amp_low, 1.f, 0); NEAR(g.amp_high, 0.f, 0); NEAR(g.freq_low, 40.f, 0); NEAR(g.freq_high, 1252.f, 0.125f);
    v[0] = NAN; v[1] = NAN; v[2] = INFINITY; v[3] = NAN; h_hid_SendVib(&h[1], v); dm_vib_get(1, &g); NEAR(g.amp_low, 0, 0); NEAR(g.amp_high, 0, 0); NEAR(g.freq_low, 160, 0.125f); NEAR(g.freq_high, 320, 0.125f);
    // 7. the batch call (the SDK's vibration flush): each value goes to the device its handle names; success; a handle outside left / right lands on a valid device
    float batch[8] = {0.1f, 100.f, 0.f, 300.f, 0.9f, 500.f, 0.f, 300.f}; uint32_t bh[2] = {h[0], h[1]};
    CHECK(h_hid_SendVibs(bh, batch, 2) == 0, "success"); dm_vib_get(0, &g); NEAR(g.amp_low, 0.1f, 1.f / 255); dm_vib_get(1, &g); NEAR(g.amp_low, 0.9f, 1.f / 255); NEAR(g.freq_low, 500.f, 0.125f);
    uint32_t odd = 0x00090001; h_hid_SendVib(&odd, v); CHECK(h_hid_SendVibs(NULL, batch, 2) == 0 && h_hid_SendVibs(bh, NULL, 2) == 0 && h_hid_SendVibs(bh, batch, 0) == 0, "bad arguments are ignored");
    h_hid_InitVib(&h[0]);   // does nothing, must not crash
    // 8. sending never waits: a hundred thousand values from the game thread while two readers poll; the sender finishes in well under a second
    pthread_t t[2]; for (int i = 0; i < 2; i++) pthread_create(&t[i], NULL, reader, NULL);
    uint64_t t0 = now_ns(); for (int i = 0; i < 100000; i++) { v[0] = (i & 255) / 255.f; v[1] = 160.f + (i % 100); v[2] = 0.f; v[3] = 320.f; h_hid_SendVib(&h[i & 1], v); }
    double ms = (now_ns() - t0) / 1e6; atomic_store(&g_stop, 1); for (int i = 0; i < 2; i++) pthread_join(t[i], NULL);
    CHECK(ms < 500, "100000 sends took %.1f ms", ms); printf("100000 sends with two polling readers: %.1f ms, %llu reads\n", ms, (unsigned long long)atomic_load(&g_reads));
    // 9. a reader never sees a torn value: the amplitude and frequency pair that goes in (a, 160 + a) is the pair that comes out
    for (int i = 0; i < 1000; i++) { uint8_t a = (uint8_t)(i % 200); v[0] = a / 255.f; v[1] = 100.f + a; v[2] = v[0]; v[3] = 100.f + a; h_hid_SendVib(&h[0], v); dm_vib_get(0, &g); NEAR(g.freq_low - 100.f, a, 0.2f); NEAR(g.freq_high, g.freq_low, 0.01f); }
    dm_vib_set_available(0); CHECK(h_hid_VibPermit() == 0 && h_hid_VibHandles(h, 4, &id, STYLE_HANDHELD) == 0, "hardware gone: no devices again");
    printf("t_vib: %d checks, %d failed\n", g_n, g_fail);
    return g_fail ? 1 : 0;
}
