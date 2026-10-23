// hle_audio.c unit test (silent sink): 3 buffers of 100 ms each -> released in order at about 100/200/300 ms, each release triggering the event.
// Expected values are computed directly from the sample rate and block length: 4800 frames / 48 kHz = 100 ms.
#include "../hle_audio.c"
#include <time.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static struct { const void *k; void *v; } om[8];
void *objmap_get(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) return om[i].v; return NULL; }
void objmap_put(const void *k, void *v) { for (int i = 0; i < 8; i++) if (!om[i].k) { om[i].k = k; om[i].v = v; return; } }
void *objmap_del(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) { om[i].k = 0; return om[i].v; } return NULL; }
static _Atomic int g_sig;
void hle_signal_system_event(void *g) { (void)g; atomic_fetch_add_explicit(&g_sig, 1, memory_order_seq_cst); }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }   // the real implementation needs a guest thread + SDK kernel event; the unit test only counts triggers
module_t *module_of(const void *p) { (void)p; return NULL; }   // call sites in the log: no guest modules in the unit test
void dm_host_helper_qos(qos_class_t q) { (void)q; }   // hle_thread.c: the helper threads keep the default class in the unit test
// Master volume: the gain curve, the ramp and the clamping of apply_gain (hle_audio.c). Pure arithmetic: no device.
static int gain_selftest(void) {
    int bad = 0;
#define EXPECT(c, ...) do { if (!(c)) { bad++; printf("FAIL volume line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
    EXPECT(gain_of(1) == GAIN_UNITY && gain_of(7) == GAIN_UNITY && gain_of(0) == 0 && gain_of(-1) == 0 && gain_of(NAN) == 0, "clamps");
    EXPECT(gain_of(0.5) == GAIN_UNITY / 4 && gain_of(0.25) == GAIN_UNITY / 16, "the curve is the square: %d %d", gain_of(0.5), gain_of(0.25));
    int16_t a[8] = {1000, -1000, 32767, -32768, 5, -5, 0, 12345}, keep[8]; memcpy(keep, a, sizeof a);
    apply_gain(a, 4, 2, GAIN_UNITY, GAIN_UNITY); EXPECT(!memcmp(a, keep, sizeof a), "unity leaves the samples bit-exact");
    apply_gain(a, 4, 2, GAIN_UNITY / 2, GAIN_UNITY / 2); EXPECT(a[0] == 500 && a[1] == -500 && a[2] == 16383 && a[3] == -16384 && a[7] == 6172, "half: %d %d %d %d %d", a[0], a[1], a[2], a[3], a[7]);
    memcpy(a, keep, sizeof a); apply_gain(a, 4, 2, 0, 0); for (int i = 0; i < 8; i++) EXPECT(a[i] == 0, "silence");
    int16_t r[64]; for (int i = 0; i < 64; i++) r[i] = 20000;   // 32 stereo frames, ramping from silence to unity: monotonic, ends at the full level, the channels move together
    apply_gain(r, 32, 2, 0, GAIN_UNITY); for (int i = 1; i < 32; i++) EXPECT(r[2 * i] >= r[2 * (i - 1)] && r[2 * i] == r[2 * i + 1], "ramp up at %d", i);
    EXPECT(r[0] < 1000 && r[62] == 20000, "ramp ends: %d ... %d", r[0], r[62]);
    for (int i = 0; i < 64; i++) r[i] = -20000;
    apply_gain(r, 32, 2, GAIN_UNITY, 0); for (int i = 1; i < 32; i++) EXPECT(r[2 * i] >= r[2 * (i - 1)], "ramp down at %d", i);
    EXPECT(r[62] == 0, "ramp down ends silent");
    apply_gain(a, 0, 2, 0, GAIN_UNITY);   // an empty block does nothing and does not divide by zero
    dm_audio_volume(0.5); EXPECT(atomic_load(&g_gain) == GAIN_UNITY / 4, "the setter stores the gain"); dm_audio_volume(1);
    {   // through the sound card callback itself: the first block after a change ramps, the next is steady; a fresh output starts at the current gain (no fade-in from silence)
        char out[64], ev[64]; uint8_t prm[16]; gbuf b; static int16_t pcm[480 * 2]; h_au_InitParam(prm);
        for (int i = 0; i < 480 * 2; i++) pcm[i] = 20000;
        if (h_au_Open(out, ev, NULL, prm)) return 0;
        h_au_SetBuf(&b, pcm, sizeof pcm, sizeof pcm); h_au_Append(out, &b);
        aout *a = ao(out); atomic_store(&a->state, STATE_STARTED);   // no backend: the callback is called by hand
        static int16_t dst[480 * 2]; AudioBufferList bl = {.mNumberBuffers = 1, .mBuffers[0] = {.mNumberChannels = 2, .mDataByteSize = sizeof dst, .mData = dst}};
        dm_audio_volume(0.5); au_render(a, NULL, NULL, 0, 480, &bl);
        EXPECT(dst[0] == 5000 && dst[2 * 479 + 1] == 5000, "the first block is at the current gain: %d %d", dst[0], dst[2 * 479 + 1]);
        h_au_Append(out, &b); a->pos = 0; dm_audio_volume(1); au_render(a, NULL, NULL, 0, 480, &bl);
        EXPECT(dst[0] > 5000 && dst[0] < 20000 && dst[2 * 479] == 20000, "the next block ramps up to unity: %d ... %d", dst[0], dst[2 * 479]);
        usleep(50000); h_au_Close(out); usleep(50000); atomic_store(&g_sig, 0);   // the releases above signaled the event: the scenarios below count their own
    }
    printf("volume: gain curve, ramp and clamping %s\n", bad ? "FAILED" : "ok");
    return !bad;
}
int main(void) {
    if (!gain_selftest()) return 1;
    char out[64], ev[64]; uint8_t prm[16]; gbuf b[3]; static int16_t pcm[3][4800 * 2];
    h_au_InitParam(prm);
    if (h_au_Open(out, ev, NULL, prm)) return 1;
    if (h_au_Ch(out) != 2 || h_au_Rate(out) != 48000 || h_au_State(out) != STATE_STOPPED) { puts("FAIL parameters"); return 1; }
    for (int i = 0; i < 3; i++) { h_au_SetBuf(&b[i], pcm[i], sizeof pcm[i], sizeof pcm[i]); if (!h_au_Append(out, &b[i])) return 1; }
    if (h_au_Released(out)) { puts("FAIL buffers released before start"); return 1; }
    uint64_t t0 = now_ns(); h_au_Start(out);
    int got = 0, fail = 0;
    while (got < 3 && now_ns() - t0 < 10000000000ull) {
        gbuf *r = h_au_Released(out);
        if (!r) { usleep(1000); continue; }
        int ok = r == &b[got];
        printf("release #%d: expected block %d in order → got block %ld %s\n", got, got, (long)(r - b), ok ? "✓" : "✗");
        fail |= !ok; got++;
    }
    h_au_Close(out);
    int sig1 = atomic_load_explicit(&g_sig, memory_order_acquire);
    printf("released %d/3, event signaled %d times (expected 3)\n", got, sig1);
    if (fail || got != 3 || sig1 != 3) return 1;

    // Scenario 2: the real audio output sink (PCM all 0, inaudible) plays 6 blocks of 100 ms each, pausing at 150 ms (app to background / incoming call) and resuming at 350 ms.
    // Expected: during the pause the silent sink takes over and consumes in real time, all 6 blocks are released in order with 6 events; total duration ~ 600 ms (real time, neither stalled by the pause nor sped up).
    setenv("DM_AUDIO", "1", 1);
    char out2[64]; gbuf b2[6]; static int16_t pcm2[6][4800 * 2]; g_sig = 0;
    if (h_au_Open(out2, ev, NULL, prm)) return 1;
    for (int i = 0; i < 6; i++) { h_au_SetBuf(&b2[i], pcm2[i], sizeof pcm2[i], sizeof pcm2[i]); h_au_Append(out2, &b2[i]); }
    t0 = now_ns(); h_au_Start(out2);
    int got2 = 0, order_ok = 1, susp = 0, resumed = 0;
    while (got2 < 6 && now_ns() - t0 < 10000000000ull) {
        uint64_t ms = (now_ns() - t0) / 1000000;
        if (!susp && ms >= 150) { dm_audio_suspend(1); susp = 1; }
        if (susp && !resumed && ms >= 350) { dm_audio_suspend(0); resumed = 1; }
        gbuf *r = h_au_Released(out2);
        if (!r) { usleep(1000); continue; }
        order_ok &= r == &b2[got2]; got2++;
    }
    double total = (now_ns() - t0) / 1e6;
    h_au_Close(out2);
    int sig2 = atomic_load_explicit(&g_sig, memory_order_acquire);
    int ok2 = got2 == 6 && order_ok && sig2 == 6 && total > 520;
    printf("suspend / resume: released %d/6 in order=%d events %d (expected 6), total duration lower bound 520 ms, got %.0f ms %s\n", got2, order_ok, sig2, total, ok2 ? "✓" : "✗");
    if (!ok2) return 1;

    // Scenario 3: the device stops calling back while the output plays (iOS does this when another audio session takes over, without telling the AudioUnit). 20 blocks of 100 ms; at 150 ms the AudioUnit is stopped behind the host's back.
    // Expected: the watchdog sees no callback for 200 ms, the silent sink takes over (all 20 blocks still released in order, about 2 s plus the 200-250 ms gap), and the AudioUnit is restarted 1 s later and calls back again
    char out3[64]; gbuf b3[20]; static int16_t pcm3[20][4800 * 2]; g_sig = 0;
    if (h_au_Open(out3, ev, NULL, prm)) return 1;
    for (int i = 0; i < 20; i++) h_au_SetBuf(&b3[i], pcm3[i], sizeof pcm3[i], sizeof pcm3[i]);
    int app3 = 0; for (; app3 < 20 && h_au_Append(out3, &b3[app3]); app3++) ;
    aout *a3 = ao(out3); t0 = now_ns(); h_au_Start(out3);
    int got3 = 0, order3 = 1, cut = 0; uint64_t cb_restart = 0;
    while (got3 < 20 && now_ns() - t0 < 10000000000ull) {
        uint64_t ms = (now_ns() - t0) / 1000000;
        if (!cut && ms >= 150) { AudioOutputUnitStop(a3->au); cut = 1; }
        pthread_mutex_lock(&g_aos_lock); if (cut && !cb_restart && a3->backend == BK_AU && ms > 400) cb_restart = atomic_load(&a3->cb_n); pthread_mutex_unlock(&g_aos_lock);
        gbuf *r = h_au_Released(out3);
        if (!r) { usleep(1000); continue; }
        order3 &= r == &b3[got3]; got3++;
        if (app3 < 20) h_au_Append(out3, &b3[app3++]);
    }
    double total3 = (now_ns() - t0) / 1e6; usleep(100000);
    pthread_mutex_lock(&g_aos_lock); int back = a3->backend == BK_AU && !a3->stalled; uint64_t cb_end = atomic_load(&a3->cb_n); pthread_mutex_unlock(&g_aos_lock);
    h_au_Close(out3);
    int ok3 = got3 == 20 && order3 && total3 > 1900 && total3 < 2600 && back && cb_restart && cb_end > cb_restart;
    printf("device stall: released %d/20 in order=%d in %.0f ms (expected 2000-2600), AudioUnit restarted and calling back again=%d %s\n", got3, order3, total3, back && cb_restart && cb_end > cb_restart, ok3 ? "✓" : "✗");
    if (!ok3) return 1;

    // Scenario 4: a suspended game queues nothing (its clock is frozen), and the silent sink's pulls on the empty queue are not underruns: nothing is played, nothing is missing.
    // They used to be counted, so the first statistics line after a resume reported the whole suspended span as zero padding (a 20 s Home: 4126 underruns, 20.6 s).
    // Then the two suspend reasons (the front end's background, Hearth's Home) compose: the output plays again only when both are lifted
    char out4[64]; gbuf b4; static int16_t pcm4[2400 * 2];
    if (h_au_Open(out4, ev, NULL, prm)) return 1;
    h_au_SetBuf(&b4, pcm4, sizeof pcm4, sizeof pcm4); h_au_Append(out4, &b4);
    aout *a4 = ao(out4); h_au_Start(out4); usleep(150000);   // the 50 ms block is played and released: the queue is empty from here on
    dm_audio_suspend(1); uint64_t u0 = atomic_load(&a4->under_n), b0 = atomic_load(&a4->under_b); usleep(300000);
    uint64_t du = atomic_load(&a4->under_n) - u0, db = atomic_load(&a4->under_b) - b0;
    dm_audio_suspend_for(DM_SUSPEND_HOME, 1); dm_audio_suspend(0);
    pthread_mutex_lock(&g_aos_lock); int held = a4->backend == BK_NULL; pthread_mutex_unlock(&g_aos_lock);
    dm_audio_suspend_for(DM_SUSPEND_HOME, 0);
    pthread_mutex_lock(&g_aos_lock); int plays = a4->backend == BK_AU; pthread_mutex_unlock(&g_aos_lock);
    // A resume restarts the AudioUnit under g_aos_lock and stamps the watchdog with the time (au_go). The watchdog used to read its clock before taking the lock: waking during a
    // resume, it held an older time than the stamp, the difference wrapped around, and a playing output was declared stalled for 18446744073710 ms (the silent sink for 1 s after a HOME)
    int false_stall = 0;
    for (int i = 0; i < 4; i++) {
        pthread_mutex_lock(&g_aos_lock); usleep(80000);   // the watchdog's tick falls inside this: it waits for the lock
        a4->wd_n = atomic_load(&a4->cb_n); a4->wd_t = now_ns();   // what au_go does on a resume
        pthread_mutex_unlock(&g_aos_lock); usleep(30000);
        pthread_mutex_lock(&g_aos_lock); false_stall |= a4->stalled || a4->backend != BK_AU; pthread_mutex_unlock(&g_aos_lock);
    }
    plays &= !false_stall;
    h_au_Close(out4);
    int ok4 = du == 0 && db == 0 && held && plays;
    printf("suspended and empty: %llu underruns, %llu bytes zero-padded while suspended (expected 0, 0); Home still holds it after the background resume=%d, plays after both=%d %s\n",
           (unsigned long long)du, (unsigned long long)db, held, plays, ok4 ? "✓" : "✗");
    return !ok4;
}
