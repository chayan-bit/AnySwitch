// nn::hid vibration (HD rumble). The game asks for vibration devices, then sends VibrationValues to them: SendVibrationValue directly, or through the SDK's vibration graph, which flushes
// batches through detail::SendVibrationValues. The host keeps the latest value of each device in a lock-free mailbox and the front end polls it on its own thread (dm_vib_get), so a game
// thread that sends hundreds of values a second never waits for the haptics engine and a burst is coalesced to what the engine can play. The front end says whether there is any haptic
// hardware (dm_vib_set_available); without it the game sees no devices, as before. A VibrationValue is two bands: amplitude 0...1 and frequency in Hz for a low band (160 Hz idle) and a high band (320 Hz idle).
#include "hle.h"
#include "dm_input.h"
#include <stdatomic.h>
#include <math.h>

// nn::hid::NpadStyleTag bits of the set the game passes, as hle_hid.c reports them
enum { STYLE_FULLKEY = 1u << 0, STYLE_HANDHELD = 1u << 1, STYLE_JOYDUAL = 1u << 2 };
enum { VIB_DEVS = 2, VIB_TYPE_LRA = 1, VIB_POS_LEFT = 1, VIB_POS_RIGHT = 2 };   // VibrationDeviceType::LinearResonantActuator, VibrationDevicePosition::Left / Right
#define FREQ_MIN 40.f     // the band an HD rumble actuator plays (the SDK documents 40 to 1252 Hz)
#define FREQ_MAX 1252.f
#define FREQ_LOW_IDLE 160.f
#define FREQ_HIGH_IDLE 320.f

// One device's value in 48 bits: amplitudes in 1/255, frequencies in 1/8 Hz (1252 Hz needs 14 bits)
static _Atomic uint64_t g_vib[VIB_DEVS];      // the latest value sent
static _Atomic uint64_t g_vib_t[VIB_DEVS];    // when (now_ns); 0 = never
static _Atomic uint64_t g_vib_serial;         // values received, all devices
static _Atomic int g_vib_avail, g_vib_devs;   // haptic hardware present; the most devices the game has asked for

static uint64_t pack_amp(float a) { return !isfinite(a) || a <= 0 ? 0 : a >= 1 ? 255 : (uint64_t)lroundf(a * 255.f); }
static uint64_t pack_freq(float f, float idle) { if (!isfinite(f)) f = idle; f = fminf(fmaxf(f, FREQ_MIN), FREQ_MAX); return (uint64_t)lroundf(f * 8.f); }
static void store(int dev, const float *v) {   // v: amplitude low, frequency low, amplitude high, frequency high
    uint64_t p = pack_amp(v[0]) | pack_amp(v[2]) << 8 | pack_freq(v[1], FREQ_LOW_IDLE) << 16 | pack_freq(v[3], FREQ_HIGH_IDLE) << 32;
    dev = dev < 0 ? 0 : dev >= VIB_DEVS ? VIB_DEVS - 1 : dev;
    atomic_store_explicit(&g_vib[dev], p, memory_order_relaxed); atomic_store_explicit(&g_vib_t[dev], now_ns() | 1, memory_order_release);   // |1: never 0
    atomic_fetch_add_explicit(&g_vib_serial, 1, memory_order_relaxed);
}
static int device_of(const void *handle) { return handle ? (int)((*(const uint32_t *)handle >> 16) & 0xff) : 0; }

void dm_vib_set_available(int on) { atomic_store(&g_vib_avail, on != 0); }
int dm_vib_devices(void) { return atomic_load(&g_vib_devs); }
uint64_t dm_vib_serial(void) { return atomic_load_explicit(&g_vib_serial, memory_order_relaxed); }
uint64_t dm_vib_get(int dev, dm_vib *out) {
    dev = dev < 0 ? 0 : dev >= VIB_DEVS ? VIB_DEVS - 1 : dev;
    uint64_t t = atomic_load_explicit(&g_vib_t[dev], memory_order_acquire), p = atomic_load_explicit(&g_vib[dev], memory_order_relaxed);
    if (!t) p = 0;
    out->amp_low = (p & 0xff) / 255.f; out->amp_high = (p >> 8 & 0xff) / 255.f;
    out->freq_low = t ? (p >> 16 & 0xffff) / 8.f : FREQ_LOW_IDLE; out->freq_high = t ? (p >> 32 & 0xffff) / 8.f : FREQ_HIGH_IDLE;
    return t ? now_ns() - (t & ~1ull) : UINT64_MAX;   // the stamp's low bit marks "sent"; a nanosecond of error does not matter
}

HLE_FORCE("_ZN2nn3hid20IsVibrationPermittedEv", "vibration permission; granted when the front end has haptic hardware", unsigned, h_hid_VibPermit, void) { return (unsigned)atomic_load(&g_vib_avail); }
// Handheld and dual Joy-Con have a left and a right actuator, anything else one (as the six-axis sensors are counted in hle_hid.c). The handle carries the style bit, the npad id and the device index
HLE_FORCE("_ZN2nn3hid25GetVibrationDeviceHandlesEPNS0_21VibrationDeviceHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", "vibration devices: left and right for handheld / dual Joy-Con, else one; none without haptic hardware",
          int, h_hid_VibHandles, uint32_t *h, int n, const uint32_t *id, uint32_t style) {
    if (!atomic_load(&g_vib_avail) || !h || n <= 0 || !id) return 0;
    int k = style & (STYLE_HANDHELD | STYLE_JOYDUAL) ? 2 : 1; if (k > n) k = n;
    for (int i = 0; i < k; i++) h[i] = (uint32_t)(style ? __builtin_ctz(style) : 0) | (*id & 0xff) << 8 | (uint32_t)i << 16;
    int seen = atomic_load(&g_vib_devs); while (k > seen && !atomic_compare_exchange_weak(&g_vib_devs, &seen, k)) ;
    return k;
}
HLE_FORCE("_ZN2nn3hid25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", "vibration device initialization; nothing to set up on the host", void, h_hid_InitVib, const void *h) { (void)h; }
HLE_FORCE("_ZN2nn3hid18SendVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", "vibration value: kept for the front end's haptics (never waits)", void, h_hid_SendVib, const void *h, const void *v) {
    if (v) store(device_of(h), (const float *)v);
}
// The SDK's vibration graph (VibrationNode::Update) flushes its queued values through this internal call, from the sdk's FlushEnqueuedVibrationValues through the PLT into the hid service proxy (sm abort without a hook).
// Metroid Dread sets handles on its VibrationTargets even when the host reports 0 devices, so values get queued; returns success as the real call does
HLE_FORCE("_ZN2nn3hid6detail19SendVibrationValuesEPKNS0_21VibrationDeviceHandleEPKNS0_14VibrationValueEi", "vibration batch (the vibration graph's flush): each value to the device its handle names", Result, h_hid_SendVibs, const uint32_t *h, const float *v, int n) {
    if (h && v) for (int i = 0; i < n; i++) store(device_of(&h[i]), v + 4 * i);
    return 0;
}
HLE_FORCE("_ZN2nn3hid22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", "vibration device info: a linear resonant actuator, left then right", void, h_hid_VibInfo, uint32_t *info, const void *h) {
    info[0] = VIB_TYPE_LRA; info[1] = device_of(h) ? VIB_POS_RIGHT : VIB_POS_LEFT;
}
HLE_FORCE("_ZN2nn3hid23GetActualVibrationValueEPNS0_14VibrationValueERKNS0_21VibrationDeviceHandleE", "actual vibration value: the latest value sent to the device", void, h_hid_VibActual, float *v, const void *h) {
    dm_vib g; dm_vib_get(device_of(h), &g); v[0] = g.amp_low; v[1] = g.freq_low; v[2] = g.amp_high; v[3] = g.freq_high;
}
