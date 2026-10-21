// Unit test of the host gate counts (hle_thread.c dm_gate_stats): SVCs by number, cntpct reads and blocked waits per frame since the previous call.
#include "../dm.h"
#include <string.h>
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void thr_tick_note(void);
void dm_gate_stats(char *out, size_t n, double frames);
static int g_fail;
static void expect(const char *out, const char *want) { if (!strstr(out, want)) { printf("✗ \"%s\" not in: %s\n", want, out); g_fail++; } else printf("✓ %s\n", want); }
int main(void) {
    uint32_t h = svc_thread_main_init(); char o[800];
    dm_gate_stats(o, sizeof o, 1);   // baseline
    for (int i = 0; i < 8; i++) { uint64_t r[8] = {0, h}; svc_thread(0x0C, r); }   // GetThreadPriority
    for (int i = 0; i < 4; i++) thr_tick_note();
    dm_gate_stats(o, sizeof o, 2);
    expect(o, "SVCs 4 per frame (0xc 4)"); expect(o, "tick reads 2 per frame (cntpct gate 2, GetSystemTick 0)"); expect(o, "waits that blocked 0 per frame");
    dm_gate_stats(o, sizeof o, 1);   // nothing happened since
    expect(o, "SVCs 0 per frame ()");
    printf(g_fail ? "FAILED: %d\n" : "all passed: 4/4\n", g_fail); return g_fail != 0;
}
