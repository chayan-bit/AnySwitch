// Stub for t_fs: strong implementation of the front end's save-failure notification (a separate compilation unit that replaces the weak implementation in hle_fs.c at link time, the same way the iOS front end does it)
int g_nfail, g_lasterr;
int dm_account_is_preselected(const void *uid) { return !uid || ((const unsigned long long *)uid)[0] == 1; }   // hle_account.c: Uid {1, x} or none is the preselected user
void front_save_failed(int err) { g_nfail++; g_lasterr = err; }

// the loader's module table (dm.h): the unit test has no modules, so the table is empty
#include "../dm.h"
module_t g_mod[MAX_MOD];
int g_nmod;
struct dm_profile g_profile;   // the game profile (profile.m): the unit test has none, every value is 0
// the guest address space (hle_svc.c): the unit test has none, so every stack is a host stack and the big-stack takeovers run on it directly (hle_bigstack.c)
#include <stdint.h>
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }
