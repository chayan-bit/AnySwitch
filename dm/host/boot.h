// Boot API: a game pack (dm_abi.h, docs/development.md "Game packs") is checked, then booted, by the shell app or dmhost
#pragma once
#include <stddef.h>
#include <sysexits.h>
#define DM_EXIT_PACK EX_CONFIG   // 78: the exit code of a pack this engine refuses
// 0 = bootable. Otherwise 1 and why holds one line naming the mismatch and what to rebuild. No side effects: the menu may call it for every pack before launching one
int dm_pack_check(const char *root, char *why, size_t n);
// dm_pack_check, and on refusal log "[RED] <why>" and exit with DM_EXIT_PACK
void dm_pack_require(const char *root);
