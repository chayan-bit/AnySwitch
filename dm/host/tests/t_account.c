// Account unit test (hle_account.c): the users Hearth lists in DM_USERS (list, count, existence, nickname and profile image per Uid), malformed lines skipped,
// the 8-user cap, the user selector through the front end, and that without DM_USERS everything answers as the single fixed user did. Expected values are written by hand.
#include "../hle_account.c"
#include <stdio.h>
#include <unistd.h>

static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  ✗ line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
void hle_signal_system_event(void *ev) { (void)ev; }
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }   // no guest address space: big-stack hooks run on the host stack
static int g_sel_ret; static char g_sel_uid[33];
int front_user_select(char out[33]) { if (g_sel_ret > 0) memcpy(out, g_sel_uid, 33); return g_sel_ret; }   // the front end's picker: answer as configured

static Uid uid_of(const char *hex) { Uid u; char hi[17] = {0}; memcpy(hi, hex, 16); u.v[0] = strtoull(hi, NULL, 16); u.v[1] = strtoull(hex + 16, NULL, 16); return u; }
static int same(Uid a, Uid b) { return a.v[0] == b.v[0] && a.v[1] == b.v[1]; }
#define U1 "78626c000000000153574e4154495645"   // Hearth's first user
#define U2 "0123456789abcdef0123456789abcdef"
#define U3 "fedcba9876543210fedcba9876543210"

int main(void) {
    char dir[] = "/tmp/t_account.XXXXXX"; if (!mkdtemp(dir)) return 2;
    char users[256], img[256], line[4096]; snprintf(users, sizeof users, "%s/users.tsv", dir); snprintf(img, sizeof img, "%s/a.jpg", dir);
    FILE *f = fopen(img, "wb"); for (int i = 0; i < 1000; i++) fputc(i & 0xff, f); fclose(f);
    // 1. no DM_USERS: one user, the fixed Uid (or DM_USER_UID), DM_NICK, no image: as before P3
    unsetenv("DM_USERS"); unsetenv("DM_USER_UID"); setenv("DM_NICK", "Solo", 1);
    int n = -1; Uid out[8]; char nick[33]; uint64_t sz = 99; uint8_t buf[2048];
    CHECK(h_acc_UserCount(&n) == RES_OK && n == 1, "count %d", n);
    CHECK(h_acc_ListAll(&n, out, 8) == RES_OK && n == 1 && same(out[0], uid_of(U1)), "list: the fixed user");
    h_acc_GetNick(nick, &out[0]); CHECK(!strcmp(nick, "Solo"), "nickname %s", nick);
    CHECK(h_acc_LoadImage(&sz, buf, sizeof buf, &out[0]) != RES_OK && sz == 0, "no image");
    // 2. three users (one line malformed, one with a bad uid), the second preselected
    f = fopen(users, "w");
    fprintf(f, "%s\tChayan\t\n", U1);
    fprintf(f, "not a uid\tBroken\t\n");
    fprintf(f, "%s\tGuest\t%s\n", U2, img);
    fprintf(f, "%s only one field\n", U3);
    fprintf(f, "%s\tThird\tmissing.jpg\n", U3);
    fclose(f);
    reset_users(); setenv("DM_USERS", users, 1); setenv("DM_USER_UID", U2, 1); setenv("DM_NICK", "Guest", 1); atomic_store(&g_uid_done, 0);
    CHECK(h_acc_UserCount(&n) == RES_OK && n == 3, "count %d (malformed lines skipped)", n);
    CHECK(h_acc_ListAll(&n, out, 8) == RES_OK && n == 3 && same(out[0], uid_of(U1)) && same(out[1], uid_of(U2)) && same(out[2], uid_of(U3)), "all three in file order");
    CHECK(h_acc_ListAll(&n, out, 2) == RES_OK && n == 2, "capped at the caller's room: %d", n);
    CHECK(h_acc_ListQual(&n, out, 8) == RES_OK && n == 3, "qualified: all %d", n);
    CHECK(h_acc_ListOpen(&n, out, 8) == RES_OK && n == 1 && same(out[0], uid_of(U2)), "open: only the preselected user");
    UserHandle h; CHECK(h_acc_OpenPre(&h) == RES_OK && h.v[0] == uid_of(U2).v[0], "preselected = DM_USER_UID");
    uint8_t ex = 0; Uid u = uid_of(U3); h_acc_Exists(&ex, &u); CHECK(ex == 1, "a listed user exists");
    u = uid_of("00000000000000000000000000000001"); h_acc_Exists(&ex, &u); CHECK(ex == 0, "an unknown user does not");
    u = uid_of(U1); h_acc_GetNick(nick, &u); CHECK(!strcmp(nick, "Chayan"), "nickname per uid: %s", nick);
    u = uid_of(U3); h_acc_GetNick(nick, &u); CHECK(!strcmp(nick, "Third"), "nickname per uid: %s", nick);
    // 3. profile image: the size alone, a buffer that fits, one too small, a user without a file
    u = uid_of(U2);
    CHECK(h_acc_LoadImage(&sz, NULL, 0, &u) == RES_OK && sz == 1000, "size query %llu", (unsigned long long)sz);
    memset(buf, 0, sizeof buf);
    CHECK(h_acc_LoadImage(&sz, buf, sizeof buf, &u) == RES_OK && sz == 1000 && buf[999] == (999 & 0xff) && buf[1000] == 0, "copied");
    CHECK(h_acc_LoadImage(&sz, buf, 10, &u) != RES_OK, "too small a buffer fails");
    u = uid_of(U3); CHECK(h_acc_LoadImage(&sz, buf, sizeof buf, &u) != RES_OK && sz == 0, "a missing file: no image");
    // 4. the user selector: the front end's choice, its cancel, or the preselected user when there is no front end window
    g_sel_ret = 1; memcpy(g_sel_uid, U3, 33); Uid s;
    CHECK(h_acc_ShowSel(&s, NULL) == RES_OK && same(s, uid_of(U3)), "picked the third user");
    g_sel_ret = 0; CHECK(h_acc_ShowSel(&s, NULL) == RES_ACC_CANCELLED, "cancelled");
    g_sel_ret = -1; CHECK(h_acc_ShowSel(&s, NULL) == RES_OK && same(s, uid_of(U2)), "no window: the preselected user");
    g_sel_ret = 1; memcpy(g_sel_uid, "00000000000000000000000000000009", 33); CHECK(h_acc_ShowSel(&s, NULL) == RES_OK && same(s, uid_of(U2)), "an unknown answer: the preselected user");
    // 5. dm_account_is_preselected (hle_fs.c's save mount)
    u = uid_of(U2); CHECK(dm_account_is_preselected(&u), "preselected"); u = uid_of(U1); CHECK(!dm_account_is_preselected(&u), "another user");
    CHECK(dm_account_is_preselected(NULL), "no uid: the preselected user's save");
    // 6. more than 8 lines: the first 8 users
    f = fopen(users, "w"); for (int i = 0; i < 10; i++) fprintf(f, "%032x\tP%d\t\n", i + 1, i); fclose(f);
    reset_users(); CHECK(h_acc_UserCount(&n) == RES_OK && n == 8, "8-user cap: %d", n);
    snprintf(line, sizeof line, "rm -rf %s", dir); if (system(line)) {}
    printf("t_account: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
