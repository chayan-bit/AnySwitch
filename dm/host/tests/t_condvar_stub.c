// Stubs for t_condvar: host facilities of hle_thread.c that the unit test does not use
#include "../dm.h"
#include <stdatomic.h>
struct dm_flags g_flag;
uint64_t g_t0_ns;
void crash_thread_init(void) {}
void guest_thread_init(void) {}
void dm_thread_enter(uint64_t entry, uint64_t arg, uint64_t sp) { (void)sp; ((void (*)(uint64_t))entry)(arg); abort(); }   // t_sync: a C entry on the host stack, which must end in ExitThread
void *guest_sym(const char *name) { (void)name; return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
#include <mach/mach_time.h>
uint64_t now_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom; }
_Atomic int g_test_det; _Atomic uint64_t g_test_guest_ns;   // t_sync drives the deterministic guest clock through these
uint64_t guest_ns(void) { return g_test_det ? g_test_guest_ns : now_ns(); }
int dm_detclock_enabled(void) { return g_test_det; }
__thread _Atomic int dm_host_work;   // referenced by hle_thread.c; in the host it is defined in hle_nvn.c
pthread_key_t g_key18, g_keytls, g_keytlr, g_keygate;   // dm.h declares them; the host defines them in loader.c
