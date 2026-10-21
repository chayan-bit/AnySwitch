// Cost of the host gate (entry.S dm_gate + hle.c gate_dispatch) per call, for a cntpct read and for a short SVC (GetCurrentProcessorNumber, 0x10), next to the C work alone.
// Also checks what the gate must keep: a cntpct read returns the guest tick in its target register, and every register and the flags survive (FPCR included).
// Timing is printed, not asserted (docs/perf-sync-cntpct.md records it).
#include "../dm.h"
#include <stdatomic.h>
#include <mach/mach_time.h>
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void gate_register(uint64_t ret_abs, const char *kind, int arg, uint64_t orig);
uint64_t call_tick(void), call_svc(void); void call_check(void);
extern uint64_t call_tick_ret, call_svc_ret, call_check_ret; extern uint8_t check_dump[784];
// what hle.c needs besides hle_thread.c and the shared stub
void *hlecount_wrap(const char *k, const char *n, void *fn) { (void)k; (void)n; return fn; }
void guest_clock_read_wait(void) {}
uint64_t svc_dispatch(int num, uint64_t *regs, uint64_t orig) { (void)orig; svc_thread(num, regs); return regs[0]; }   // hle_svc.c starts the same way for thread SVCs

module_t g_mod[MAX_MOD];
static double ns_per(uint64_t t0, uint64_t t1, int n) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return (double)(t1 - t0) * tb.numer / tb.denom / n; }
static void thr_tick_work(void) { void thr_tick_note(void); thr_tick_note(); guest_clock_read_wait(); }
int main(void) {
    int fail = 0;
    svc_thread_main_init();
    gate_register(call_tick_ret, "cntpct", 0, 0);
    gate_register(call_svc_ret, "svc", 0x10, 0);
    gate_register(call_check_ret, "svc", 0x10, 0);
    // every register, the flags and FPCR come back as they went in
    call_check(); int bad = 0;
    for (int i = 1; i <= 28; i++) { uint64_t v; memcpy(&v, check_dump + 8 * i, 8); if (i != 18 && v != 0x1000u + (unsigned)i) { printf("  x%d = %#llx\n", i, v); bad++; } }
    for (int i = 0; i < 32; i++) for (int k = 0; k < 16; k++) if (check_dump[256 + 16 * i + k] != i + 1) { printf("  v%d byte %d = %u\n", i, k, check_dump[256 + 16 * i + k]); bad++; break; }
    uint64_t nzcv, fpcr; memcpy(&nzcv, check_dump + 768, 8); memcpy(&fpcr, check_dump + 776, 8);
    if (nzcv != 0xA0000000u) { printf("  nzcv = %#llx\n", nzcv); bad++; }
    if (fpcr != 0xC00000u) { printf("  fpcr = %#llx\n", fpcr); bad++; }
    if (bad) { printf("✗ registers changed by the gate: %d\n", bad); fail++; } else printf("✓ SVC through the gate keeps x1-x17, x19-x28, v0-v31, NZCV and FPCR\n");
    // the cntpct gate writes the tick into its target (x0 here) and it advances at 19.2 MHz
    uint64_t a = call_tick(), t0 = now_ns(); while (now_ns() - t0 < 10000000) {} uint64_t b = call_tick();
    double mhz = (b - a) / ((now_ns() - t0) / 1e3);
    if (!(mhz > 18.5 && mhz < 19.3)) { printf("✗ tick rate %.2f MHz (expected 19.2)\n", mhz); fail++; } else printf("✓ cntpct gate: tick rate %.2f MHz\n", mhz);
    enum { N = 2000000 };
    uint64_t s = mach_absolute_time(); for (int i = 0; i < N; i++) (void)call_tick(); uint64_t e = mach_absolute_time();
    double gt = ns_per(s, e, N);
    s = mach_absolute_time(); for (int i = 0; i < N; i++) { thr_tick_work(); volatile uint64_t v = guest_ns() * 12 / 625; (void)v; } e = mach_absolute_time();
    double ct = ns_per(s, e, N);
    s = mach_absolute_time(); for (int i = 0; i < N; i++) (void)call_svc(); e = mach_absolute_time();
    double gs = ns_per(s, e, N);
    s = mach_absolute_time(); for (int i = 0; i < N; i++) { uint64_t r[8] = {0}; svc_thread(0x10, r); } e = mach_absolute_time();
    double cs = ns_per(s, e, N);
    printf("cntpct through the gate %.1f ns (C work alone %.1f ns, gate frame and dispatch %.1f ns)\n", gt, ct, gt - ct);
    printf("svc 0x10 through the gate %.1f ns (svc_thread alone %.1f ns, gate frame and dispatch %.1f ns)\n", gs, cs, gs - cs);
    printf(fail ? "FAILED: %d\n" : "all passed: 2/2\n", fail);
    return fail != 0;
}
