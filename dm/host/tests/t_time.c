// Time service snapshot comparisons (hle_time.c): CalculateStandardUserSystemClockDifferenceByUser and CalculateSpanBetween, expected values written by hand from the service's rules.
#include "../hle_time.c"
uint64_t guest_ns(void) { return 5000000000ull; }
static int checks, fails;
#define CHECK(c, s) do { checks++; int ok = !!(c); fails += !ok; printf("%s %s\n", ok ? "✓" : "✗", s); } while (0)
static void put64(uint8_t *p, int64_t v) { memcpy(p, &v, 8); }
static void src(uint8_t *tp, const char *id) { memcpy(tp + 8, id, 16); }   // a steady time point's clock source ID
int main(void) {
    uint8_t a[0xd0], b[0xd0]; int64_t span = 0;
    h_time_Snapshot(a); h_time_Snapshot(b);
    CHECK(!memcmp(a, b, 0x20), "two snapshots in a row share the user clock context");
    CHECK(h_time_UserClockDiff(a, b) == 0, "no clock change → difference 0");
    put64(b, *(int64_t *)a + 3600);
    CHECK(h_time_UserClockDiff(a, b) == 3600000000000ll, "user clock set 1 h forward → +3600 s in ns");
    src(b + 0x08, "other-steady-src");
    CHECK(h_time_UserClockDiff(a, b) == 0, "steady clock restarted (other source) → 0");
    memcpy(b, a, 0xd0); put64(b, *(int64_t *)a + 60); a[0xcc] = b[0xcc] = 1;
    src(a + 0x28, "other-steady-src");   // network contexts follow another clock: the change was the user's
    CHECK(h_time_UserClockDiff(a, b) == 60000000000ll, "automatic correction, network on another clock → difference kept");
    memcpy(a + 0x28, a + 0x90, 0x18);
    CHECK(h_time_UserClockDiff(a, b) == 0, "automatic correction, network context on the steady clock → 0");
    memcpy(b, a, 0xd0); put64(b + 0x90, *(int64_t *)(a + 0x90) + 42);
    CHECK(h_time_SpanBetween(&span, a, b) == RES_OK && span == 42000000000ll, "span by steady time points");
    src(b + 0x90, "other-steady-src");
    CHECK(h_time_SpanBetween(&span, a, b) == RES_TIME_NOT_FOUND, "other steady source, no network time → time not found");
    put64(a + 0x48, 1000); put64(b + 0x48, 1010);
    CHECK(h_time_SpanBetween(&span, a, b) == RES_OK && span == 10000000000ll, "other steady source → span by network times");
    printf("t_time: %d/%d\n", checks - fails, checks);
    return fails != 0;
}
