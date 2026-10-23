// err: the error display applet. A game hands it a Result, an ErrorCode or its own error; the host formats the code the way players know it (2xxx-yyyy) and asks the
// front end to show it (front_error, front.h: Hearth's dialog on iOS, a log line on the Mac). The call blocks until the player dismisses it, as the applet does on the console.
// Tests: dm/host/tests/t_err.c. Diagnostics: DM_OE_SCRIPT="err=<Result as a decimal number>@<seconds>" (hle_oe.c) shows one on demand.
#include "hle.h"
#include "dm.h"
#include "front.h"
#include <stdio.h>
#include <string.h>

// The front end's default (no window): the line in the log is all there is. code is "" when the game gave none
__attribute__((weak)) void front_error(const char *code, int network) { LOG("front_error %s%s: no front end attached (default weak implementation)", code, network ? " (online)" : ""); }

// Result: module in bits 0-8, description in bits 9-21; shown as (2000 + module)-description
void dm_err_code_result(Result r, char out[16]) { snprintf(out, 16, "%04u-%04u", 2000 + (r & 0x1ff), (r >> 9) & 0x1fff); }
// ErrorCode {category, number}: shown as is
void dm_err_code_pair(uint32_t category, uint32_t number, char out[16]) { snprintf(out, 16, "%04u-%04u", category % 10000, number % 10000); }
// Online errors get their own sentence: 2110 is the network connection service (nifm, from memory), 2162-0001 is RES_FAIL, what every cut online feature of this host returns
int dm_err_is_network(const char *code) { return !strncmp(code, "2110-", 5) || !strcmp(code, "2162-0001"); }

static void show(const char *code, const char *what) {
    int net = dm_err_is_network(code);
    LOG("game asks to show an error: %s (%s%s)", code, what, net ? ", online" : "");
    front_error(code, net);
}
void dm_err_show_result(Result r) { char c[16]; dm_err_code_result(r, c); show(c, "Result"); }

HLE_FORCE_BIG("_ZN2nn3err9ShowErrorENS_6ResultE", "error display applet; Hearth's dialog (front_error)", void, h_err_ShowError, Result r) { dm_err_show_result(r); }
HLE_FORCE_BIG("_ZN2nn3err9ShowErrorENS0_9ErrorCodeE", "error display applet; Hearth's dialog (front_error)", void, h_err_ShowCode, uint64_t code) {
    char c[16]; dm_err_code_pair((uint32_t)code, (uint32_t)(code >> 32), c); show(c, "ErrorCode");
}
// ErrorResultVariant: a state (1 Result, 2 ErrorCode, from memory, unverified) then the value; the raw bytes are logged so the layout can be checked on the first real call
HLE_FORCE_BIG("_ZN2nn3err9ShowErrorERKNS0_18ErrorResultVariantE", "error display applet; Hearth's dialog (front_error)", void, h_err_ShowVar, const uint32_t *v) {
    LOG("err: ErrorResultVariant %08x %08x %08x %08x", v[0], v[1], v[2], v[3]);
    char c[16];
    if ((v[0] & 0xff) == 1) dm_err_code_result(v[1], c);
    else if ((v[0] & 0xff) == 2) dm_err_code_pair(v[1], v[2], c);
    else c[0] = 0;   // no code: the generic dialog
    show(c, "ErrorResultVariant");
}
HLE_FORCE_BIG("_ZN2nn3err40ShowUnacceptableAddOnContentVersionErrorEv", "add-on content version mismatch; Hearth's dialog (front_error)", void, h_err_AocVer, void) { show("", "add-on content version mismatch"); }
HLE_FORCE_BIG("_ZN2nn3err39ShowUnacceptableApplicationVersionErrorEv", "game version mismatch; Hearth's dialog (front_error)", void, h_err_AppVer, void) { show("", "game version mismatch"); }
// Pokémon Legends: Z-A (SDK 19): the application's own error screen (a number and two messages; the layout is not known, so only the generic dialog)
HLE_FORCE_BIG("_ZN2nn3err20ShowApplicationErrorERKNS0_19ApplicationErrorArgE", "application error applet; Hearth's dialog (front_error)", void, h_err_ShowApp, const void *arg) { (void)arg; show("", "ApplicationErrorArg"); }
