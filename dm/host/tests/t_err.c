// Error applet unit test (hle_err.c): the 2xxx-yyyy form of a Result and an ErrorCode, which codes count as online errors, and that a game's call reaches the front end once with both.
// Expected codes are worked out by hand. Run: make -C dm/host/tests run
#include "../hle.h"
#include <stdio.h>
#include <string.h>

void dm_err_code_result(Result r, char out[16]);
void dm_err_code_pair(uint32_t category, uint32_t number, char out[16]);
int dm_err_is_network(const char *code);
void dm_err_show_result(Result r);

static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  ✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static char g_code[16]; static int g_net, g_calls;
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }   // hle_bigstack.c asks it; no guest here
void front_error(const char *code, int network) { snprintf(g_code, sizeof g_code, "%s", code); g_net = network; g_calls++; }   // the front end: record what it was asked to show

int main(void) {
    char c[16];
    dm_err_code_result(0x26e, c); CHECK(!strcmp(c, "2110-0001"), "nifm module 110, description 1: %s", c);   // 0x26e = 110 | 1 << 9
    dm_err_code_result(RES_FAIL, c); CHECK(!strcmp(c, "2162-0001"), "the host's RES_FAIL 0x2a2: %s", c);
    dm_err_code_result(0x3fffff, c); CHECK(!strcmp(c, "2511-8191"), "all bits set: module 511, description 8191: %s", c);
    dm_err_code_result(2, c); CHECK(!strcmp(c, "2002-0000"), "fs module 2, description 0: %s", c);
    dm_err_code_pair(2306, 520, c); CHECK(!strcmp(c, "2306-0520"), "ErrorCode as given: %s", c);
    dm_err_code_pair(123456, 7, c); CHECK(!strcmp(c, "3456-0007"), "out-of-range category keeps four digits: %s", c);
    CHECK(dm_err_is_network("2110-0001") && dm_err_is_network("2110-3127"), "2110 is online");
    CHECK(dm_err_is_network("2162-0001"), "RES_FAIL (cut online features) is online");
    CHECK(!dm_err_is_network("2162-0002") && !dm_err_is_network("2002-0000") && !dm_err_is_network(""), "anything else is not");
    dm_err_show_result(0x26e);
    CHECK(g_calls == 1 && !strcmp(g_code, "2110-0001") && g_net == 1, "a game's Result reaches the front end once, as online: %d %s %d", g_calls, g_code, g_net);
    dm_err_show_result(2);
    CHECK(g_calls == 2 && !strcmp(g_code, "2002-0000") && g_net == 0, "an fs error is not online: %s %d", g_code, g_net);
    printf("t_err: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
