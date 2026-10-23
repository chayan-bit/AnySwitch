// Boot API: a game pack (dm_abi.h, docs/development.md "Game packs") is checked, then booted, by the shell app or dmhost
#pragma once
#include <stddef.h>
#include <sysexits.h>
#define DM_EXIT_PACK EX_CONFIG   // 78: the exit code of a pack this engine refuses
// 0 = bootable. Otherwise a reason code (below) and why holds one line naming the mismatch and what to rebuild. No side effects: the menu may call it for every pack before launching one
enum { DM_PACK_NOT_PACK = 1, DM_PACK_REBUILD = 2, DM_PACK_MISSING = 3 };   // no readable manifest / built for another engine version or another title / a part this platform needs is absent
int dm_pack_check(const char *root, char *why, size_t n);
// dm_pack_check, and on refusal log "[RED] <why>" and exit with DM_EXIT_PACK
void dm_pack_require(const char *root);
// Default the environment for booting the pack at root, only where the caller has not set a variable (docs/development.md "Game packs"); returns how many optional parts are absent (each is logged)
int dm_boot_env(const char *root);
// Boot the pack at root, once per process: dm_pack_check (refusal: logged, returns 1), dm_boot_env, the profile, then host loading in the background (dm_host_preload_start with
// {"dmhost", root}, so the later dm_main must get the same two arguments). The caller owns DM_SAVE, DM_SAVE_ROOT, DM_TEMP, DM_USER_UID, DM_NICK, DM_USERS and DM_OPMODE
int dm_boot_game(const char *root);
// A folder holding manifest.json is booted as a pack (dmhost <pack root>); any other folder is a rewriter output folder with the tables (dmhost <code dir>)
int dm_is_pack(const char *dir);
