// nn::account: the real device manages users via the acc:u0 service. The host knows the users the front end lists in DM_USERS (Hearth writes it before every boot), else one fixed local user.
// Online accounts (network service account / Nintendo Account authorization / tokens) are out of scope and uniformly return RES_FAIL; the async context's completion event fires immediately.
// Environment switches: DM_NICK=nickname (default Player), DM_USER_UID=the user's 32-hex-digit Uid (default a fixed one), the user the game starts with (preselected);
// DM_USERS=path of a tab-separated file, one user per line: uid<TAB>nickname<TAB>profile image path (a JPEG, may be empty), at most 8. Tests: dm/host/tests/t_account.c
#include "hle.h"
#include "front.h"
#include <stdatomic.h>
#include <stdio.h>

typedef struct { uint64_t v[2]; } Uid;                 // nn::account::Uid, 16 bytes
typedef struct { uint64_t v[3]; } UserHandle;          // nn::account::UserHandle, 24 bytes
_Static_assert(sizeof(Uid) == 16, "Uid");
static Uid k_uid = {{0x78626c0000000001ull, 0x53574e4154495645ull}};   // Non-zero means valid; the fixed local user, so saves made before DM_USER_UID keep their owner
static int parse_uid(const char *e, Uid *u) {   // 32 hex digits, not all zero
    char hi[17] = ""; u->v[0] = u->v[1] = 0;
    if (!e || strlen(e) != 32 || strspn(e, "0123456789abcdefABCDEF") != 32) return 0;
    memcpy(hi, e, 16); u->v[0] = strtoull(hi, NULL, 16); u->v[1] = strtoull(e + 16, NULL, 16);
    return (u->v[0] | u->v[1]) != 0;
}
// The local user: DM_USER_UID (32 hex digits, the caller's per-user value, boot.h environment contract) else the fixed one. Read on first use: the iOS app sets the environment after process start
static _Atomic int g_uid_done;
static Uid user_uid(void) {
    if (atomic_load(&g_uid_done)) return k_uid;
    const char *e = getenv("DM_USER_UID"); Uid u; parse_uid(e, &u);
    if (u.v[0] | u.v[1]) { k_uid = u; LOG("account: user %s (DM_USER_UID)", e); }
    else if (e) LOG("[RED] account: DM_USER_UID must be 32 hex digits, not all zero (got \"%s\"): the fixed local user", e);
    atomic_store(&g_uid_done, 1);
    return k_uid;
}
static int same_uid(const Uid *a, Uid b) { return a->v[0] == b.v[0] && a->v[1] == b.v[1]; }
int dm_account_is_preselected(const void *uid) { return !uid || same_uid(uid, user_uid()); }   // hle_fs.c: whose save a mount is (no uid: the preselected user's)

// DM_USERS: read once, on first use; without it the one local user stands for everyone (Mac runs, tools, tests)
#define MAX_USERS 8
typedef struct { Uid uid; char nick[33]; char image[1024]; } user_t;
static user_t g_users[MAX_USERS]; static int g_nusers = -1; static pthread_mutex_t g_users_lock = PTHREAD_MUTEX_INITIALIZER;
static void reset_users(void) { pthread_mutex_lock(&g_users_lock); g_nusers = -1; pthread_mutex_unlock(&g_users_lock); }   // t_account.c
static int users(void) {
    pthread_mutex_lock(&g_users_lock);
    if (g_nusers < 0) {
        g_nusers = 0; const char *p = getenv("DM_USERS"); FILE *f = p && *p ? fopen(p, "r") : NULL; char line[2048];
        if (p && *p && !f) LOG("[RED] account: DM_USERS %s cannot be read: one local user", p);
        while (f && fgets(line, sizeof line, f)) {
            line[strcspn(line, "\r\n")] = 0; if (!*line) continue;
            char *t1 = strchr(line, '\t'), *t2 = t1 ? strchr(t1 + 1, '\t') : NULL; user_t u = {0};
            if (t1) *t1 = 0; if (t2) *t2 = 0;
            if (!t2 || !parse_uid(line, &u.uid)) { LOG("[RED] account: DM_USERS line skipped (want uid<TAB>name<TAB>image): %s", line); continue; }
            if (g_nusers == MAX_USERS) { LOG("[RED] account: DM_USERS lists more than %d users; the rest are skipped", MAX_USERS); break; }
            strlcpy(u.nick, t1 + 1, sizeof u.nick); strlcpy(u.image, t2 + 1, sizeof u.image); g_users[g_nusers++] = u;
        }
        if (f) { fclose(f); LOG("account: %d users from DM_USERS", g_nusers); }
    }
    int n = g_nusers; pthread_mutex_unlock(&g_users_lock); return n;
}
static const user_t *find_user(const Uid *uid) { int n = users(); for (int i = 0; i < n; i++) if (same_uid(uid, g_users[i].uid)) return &g_users[i]; return NULL; }
static int list_users(int *n, Uid *out, int max) {   // every user (DM_USERS), else the one local user
    int k = 0, all = users();
    if (!all) { if (max > 0 && out) { out[0] = user_uid(); k = 1; } }
    else for (int i = 0; i < all && i < max && out; i++) out[k++] = g_users[i].uid;
    *n = k; return RES_OK;
}
// The user selector's cancel: account module 124, description 0 (from memory, unverified; to be read from an SDK image when a title cancels)
#define RES_ACC_CANCELLED 0x7Cu
#ifndef T_ACCOUNT
__attribute__((weak)) int front_user_select(char out[33]) { (void)out; return -1; }   // no front end picker: the preselected user
#endif
#define HANDLE_MAGIC 0x55534552484e444cull                                    // "USERHNDL"

HLE_FORCE("_ZN2nn7account10InitializeEv", "connects to the acc:u0 account service; the host has one fixed local user", void, h_acc_Init, void) {}

HLE_FORCE("_ZN2nn7account13ListOpenUsersEPiPNS0_3UidEi", "list of open users; always the one local user", Result, h_acc_ListOpen, int *n, Uid *out, int max) {
    *n = 0;
    if (max > 0) { out[0] = user_uid(); *n = 1; }
    return RES_OK;
}
HLE_FORCE("_ZN2nn7account12ListAllUsersEPiPNS0_3UidEi", "list of all users: DM_USERS, else the one local user (Super Mario 3D World + Bowser's Fury)", Result, h_acc_ListAll, int *n, Uid *out, int max) {
    return list_users(n, out, max);
}
// The game's own "who is playing" (decision 5): the front end's picker (Hearth's, blocking this thread like the software keyboard), else the preselected user
HLE_FORCE("_ZN2nn7account16ShowUserSelectorEPNS0_3UidERKNS0_21UserSelectionSettingsE", "user selection applet; the front end's picker (front_user_select), else the preselected user", Result, h_acc_ShowSel, Uid *out, const void *settings) {
    (void)settings; char hex[33] = ""; Uid u;
    int r = users() > 1 ? front_user_select(hex) : -1;
    if (r == 0) { LOG("account: user selector cancelled"); return RES_ACC_CANCELLED; }
    *out = r > 0 && parse_uid(hex, &u) && find_user(&u) ? u : user_uid();
    LOG("account: user selector: %016llx%016llx%s", (unsigned long long)out->v[0], (unsigned long long)out->v[1], r > 0 ? "" : " (preselected)");
    return RES_OK;
}
// Take the users the system opened on the application's behalf (Mario 1.2.1 asks this first and falls back to TryOpenPreselectedUser on 0; the game only reads the count, not the return value):
// the host has no such users and returns 0, so the game opens the preselected user itself, as in v0
HLE_FORCE("_ZN2nn7account12PopOpenUsersEPiPNS0_10UserHandleEi", "users opened by the system: none (the game falls back to the preselected user)", void, h_acc_PopOpen, int *n, UserHandle *out, int max) { (void)out; (void)max; *n = 0; }
// Hand the open users to the next program of a multi-program application (Octopath Traveler 0 imports it with oe::ExecuteProgram): the host runs one program, so there is nothing to hand over
HLE_FORCE("_ZN2nn7account13PushOpenUsersEv", "hand the open users to the next program: the host runs only this one", void, h_acc_PushOpen, void) {}
HLE_FORCE("_ZN2nn7account22TryOpenPreselectedUserEPNS0_10UserHandleE", "user preselected at launch; always the local user (returns bool)", unsigned, h_acc_TryOpenPre, UserHandle *h) {
    h->v[0] = user_uid().v[0]; h->v[1] = user_uid().v[1]; h->v[2] = HANDLE_MAGIC; return 1;
}
// The aborting form (Super Mario Odyssey, SDK 7): without the hook the SDK's IPC call fails and aborts with no message. In SDK 6 the same symbol returns a Result, and Fire Emblem: Three Houses
// skips its save mount when it is non-zero (main+0x53b7e0); returning void left the handle pointer in w0, so the game never mounted "save" and its loading screen waited forever for save:/system.
// It returns 0 now, which SDK 7+ callers ignore
HLE_FORCE("_ZN2nn7account19OpenPreselectedUserEPNS0_10UserHandleE", "user preselected at launch (returns a Result in SDK 6, later versions abort on failure); always the local user", Result, h_acc_OpenPre, UserHandle *h) {
    h->v[0] = user_uid().v[0]; h->v[1] = user_uid().v[1]; h->v[2] = HANDLE_MAGIC; return RES_OK;
}
HLE_FORCE("_ZN2nn7account17GetLastOpenedUserEPNS0_3UidE", "last opened user; always the local user (Super Mario Odyssey)", Result, h_acc_LastOpened, Uid *out) { *out = user_uid(); return RES_OK; }
HLE_FORCE("_ZN2nn7account8OpenUserEPNS0_10UserHandleERKNS0_3UidE", "open user; the handle holds the Uid itself", Result, h_acc_OpenUser, UserHandle *h, const Uid *uid) {
    h->v[0] = uid->v[0]; h->v[1] = uid->v[1]; h->v[2] = HANDLE_MAGIC; return RES_OK;
}
HLE_FORCE("_ZN2nn7account9GetUserIdEPNS0_3UidERKNS0_10UserHandleE", "gets the Uid from the handle", Result, h_acc_GetUserId, Uid *out, const UserHandle *h) {
    if (h->v[2] != HANDLE_MAGIC) die("account::GetUserId: the handle was not issued by the host (%#llx)", h->v[2]);
    out->v[0] = h->v[0]; out->v[1] = h->v[1]; return RES_OK;
}
// nn::account::Nickname = struct { char name[33]; }, UTF-8
HLE_FORCE("_ZN2nn7account11GetNicknameEPNS0_8NicknameERKNS0_3UidE", "user nickname: DM_USERS per Uid, else DM_NICK", Result, h_acc_GetNick, char *nick, const Uid *uid) {
    const user_t *u = find_user(uid);
    const char *e = u ? u->nick : getenv("DM_NICK");
    memset(nick, 0, 33); strncpy(nick, e ? e : "Player", 32);
    return RES_OK;
}

// ---------- Online accounts: cut ----------
HLE_FORCE("_ZN2nn7account36EnsureNetworkServiceAccountAvailableERKNS0_10UserHandleE", "network service account, out of scope; cut: always unavailable", Result, h_acc_EnsureNsa, const UserHandle *h) { (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn7account26GetNetworkServiceAccountIdEPNS0_23NetworkServiceAccountIdERKNS0_10UserHandleE", "network service account, out of scope; cut", Result, h_acc_GetNsaId, void *id, const UserHandle *h) { (void)id; (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn7account37LoadNetworkServiceAccountIdTokenCacheEPmPcmRKNS0_10UserHandleE", "network service account token, out of scope; cut", Result, h_acc_LoadTok, uint64_t *n, char *buf, uint64_t sz, const UserHandle *h) {
    (void)buf; (void)sz; (void)h; if (n) *n = 0; return RES_FAIL;
}
HLE_FORCE("_ZN2nn7account40ShowLicenseRequirementsForNetworkServiceERKNS0_10UserHandleE", "online membership notice applet, out of scope; cut", Result, h_acc_ShowLic, const UserHandle *h) { (void)h; return RES_FAIL; }

// AsyncContext / NintendoAccountAuthorizationRequestContext: object contents are read and written only by the interfaces below; construction writes no memory, the completion event fires immediately, and the result is always failure
HLE_FORCE("_ZN2nn7account12AsyncContextC1Ev", "async context constructor; the host creates no IPC object", void, h_acc_AcCtor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn7account44EnsureNetworkServiceAccountIdTokenCacheAsyncEPNS0_12AsyncContextERKNS0_10UserHandleE", "network service account token, out of scope; cut", Result, h_acc_EnsureTokAsync, void *ctx, const UserHandle *h) { (void)ctx; (void)h; return RES_FAIL; }
HLE_FORCE("_ZN2nn7account12AsyncContext14GetSystemEventEPNS_2os11SystemEventE", "async completion event; fires immediately", Result, h_acc_AcGetEv, void *self, void *ev) { (void)self; hle_signal_system_event(ev); return RES_OK; }
HLE_FORCE("_ZN2nn7account12AsyncContext9GetResultEv", "async result; networking is cut, always fails", Result, h_acc_AcGetRes, void *self) { (void)self; return RES_FAIL; }
HLE_FORCE("_ZN2nn7account42NintendoAccountAuthorizationRequestContextC1Ev", "Nintendo Account authorization, out of scope; the constructor writes no memory", void, h_acc_NaCtor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn7account42NintendoAccountAuthorizationRequestContextD1Ev", "Nintendo Account authorization, out of scope", void, h_acc_NaDtor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn7account41CreateNintendoAccountAuthorizationRequestEPNS0_42NintendoAccountAuthorizationRequestContextERKNS0_10UserHandleERKNS0_45NintendoAccountAuthorizationRequestParametersEPvm",
          "Nintendo Account authorization, out of scope; cut", Result, h_acc_NaCreate, void *ctx, const UserHandle *h, const void *prm, void *buf, uint64_t sz) {
    (void)ctx; (void)h; (void)prm; (void)buf; (void)sz; return RES_FAIL;
}
HLE_FORCE("_ZN2nn7account42NintendoAccountAuthorizationRequestContext14GetSystemEventEPNS_2os11SystemEventE", "authorization completion event; fires immediately", Result, h_acc_NaGetEv, void *self, void *ev) { (void)self; hle_signal_system_event(ev); return RES_OK; }
HLE_FORCE("_ZN2nn7account42NintendoAccountAuthorizationRequestContext34GetResultWithInteractionIfRequiredEv", "authorization result; always fails", Result, h_acc_NaGetRes, void *self) { (void)self; return RES_FAIL; }
HLE_FORCE("_ZN2nn7account42NintendoAccountAuthorizationRequestContext10GetIdTokenEPmPcm", "authorization token; always fails", Result, h_acc_NaGetTok, void *self, uint64_t *n, char *buf, uint64_t sz) {
    (void)self; (void)buf; (void)sz; if (n) *n = 0; return RES_FAIL;
}

// ---------- Account interfaces used by newer SDKs: user enumeration / existence / profile image, the remaining AsyncContext members ----------
HLE_FORCE("_ZN2nn7account12GetUserCountEPi", "user count: DM_USERS, else the one local user", Result, h_acc_UserCount, int *n) { int k = users(); *n = k ? k : 1; return RES_OK; }
HLE_FORCE("_ZN2nn7account18ListQualifiedUsersEPiPNS0_3UidEi", "list of qualified users: every user", Result, h_acc_ListQual, int *n, Uid *out, int max) { return list_users(n, out, max); }
HLE_FORCE("_ZN2nn7account16GetUserExistenceEPbRKNS0_3UidE", "whether a user exists: listed in DM_USERS, or the local user", Result, h_acc_Exists, uint8_t *out, const Uid *uid) {
    *out = same_uid(uid, user_uid()) || find_user(uid); return RES_OK;
}
HLE_FORCE("_ZN2nn7account15ShowUserCreatorEv", "user creation applet; the host already has its local user", Result, h_acc_ShowCreator, void) { return RES_OK; }
// The user's picture (Hearth's avatar.jpg, a 256x256 JPEG): no buffer asks for the size; a buffer too small fails, as nothing would be usable
HLE_FORCE("_ZN2nn7account16LoadProfileImageEPmPvmRKNS0_3UidE", "user profile image: the JPEG DM_USERS names for the Uid, else none (fails)", Result, h_acc_LoadImage, uint64_t *n, void *buf, uint64_t sz, const Uid *uid) {
    const user_t *u = find_user(uid); FILE *f = u && u->image[0] ? fopen(u->image, "rb") : NULL;
    if (n) *n = 0;
    if (!f) return RES_FAIL;
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    Result r = RES_OK;
    if (len <= 0) r = RES_FAIL;
    else if (buf && (uint64_t)len > sz) { LOG("[RED] account: profile image is %ld bytes, the game's buffer %llu", len, (unsigned long long)sz); r = RES_FAIL; }
    else if (buf && fread(buf, 1, (size_t)len, f) != (size_t)len) r = RES_FAIL;
    fclose(f);
    if (n && r == RES_OK) *n = (uint64_t)len;
    return r;
}
// The save-data thumbnail is what the system's data management screen shows next to a save (The Great Ace Attorney Chronicles, SDK 10); the host has no such screen and keeps none
HLE_FORCE("_ZN2nn7account27StoreSaveDataThumbnailImageERKNS0_3UidEPKvm", "save-data thumbnail for the system's data management screen; the host keeps none", Result, h_acc_StoreThumb, const Uid *uid, const void *img, uint64_t n) {
    (void)uid; (void)img; (void)n; return RES_OK;
}
HLE_FORCE("_ZN2nn7account28DeleteSaveDataThumbnailImageERKNS0_3UidE", "save-data thumbnail; the host keeps none", Result, h_acc_DeleteThumb, const Uid *uid) { (void)uid; return RES_OK; }
HLE_FORCE("_ZN2nn7account32IsNetworkServiceAccountAvailableEPbRKNS0_10UserHandleE", "network service account, out of scope; always unavailable", Result, h_acc_NsaAvail, uint8_t *out, const UserHandle *h) { (void)h; *out = 0; return RES_OK; }
HLE_FORCE("_ZN2nn7account9CloseUserERKNS0_10UserHandleE", "close user; the handle holds no session", void, h_acc_CloseUser, const UserHandle *h) { (void)h; }
HLE_FORCE("_ZN2nn7account12AsyncContext6CancelEv", "async context cancel; no request", Result, h_acc_AcCancel, void *self) { (void)self; return RES_OK; }
HLE_FORCE("_ZN2nn7account12AsyncContext7HasDoneEPb", "async context: always done", Result, h_acc_AcHasDone, void *self, uint8_t *done) { (void)self; *done = 1; return RES_OK; }
HLE_FORCE("_ZN2nn7account12AsyncContextD1Ev", "async context destructor; no session to close", void, h_acc_AcDtor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn7account12AsyncContextaSEOS1_", "async context move assignment; the object holds no host state", void *, h_acc_AcMove, void *self, void *other) { (void)other; return self; }
