// Unit tests for nvn_rscale.h: the DM_INTERNAL_RES parser
#include "../nvn/nvn_rscale.h"
#include <stdio.h>

static int fail, checks;
static void check(int ok, const char *what) { checks++; fail += !ok; printf("%-60s %s\n", what, ok ? "ok" : "FAIL"); }

int main(void) {
    check(nvn_rs_parse(NULL) == 1.0f && nvn_rs_parse("") == 1.0f, "unset or empty: 1x");
    check(nvn_rs_parse("1") == 1.0f && nvn_rs_parse("1.0") == 1.0f, "1 and 1.0: 1x");
    check(nvn_rs_parse("1.5") == 1.5f && nvn_rs_parse("1.50") == 1.5f, "1.5: 1.5x");
    check(nvn_rs_parse("2") == 2.0f && nvn_rs_parse("2.0") == 2.0f, "2 and 2.0: 2x");
    check(nvn_rs_parse("3") == 0 && nvn_rs_parse("1.25") == 0 && nvn_rs_parse("0.5") == 0, "other numbers: invalid");
    check(nvn_rs_parse("2x") == 0 && nvn_rs_parse("high") == 0 && nvn_rs_parse(" 2") == 2.0f, "trailing text invalid, leading space as strtof");
    printf("== %d checks, %d failed ==\n", checks, fail);
    return fail != 0;
}
