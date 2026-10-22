// Game profile at run time: <profile dir>/game.json, the resolved dm/games/<id>/game.tsv written by dm/games/game.py json, read once at boot (profile.m).
// One host binary runs any game: nothing game-specific is compiled in. Keys and meanings: dm/games/README.md; the schema version is DM_PROFILE_SCHEMA (dm_abi.h)
#pragma once
#include <stddef.h>
#include <stdint.h>

#define DM_PROFILE_MAX_MOD 8   // = MAX_MOD (dm.h)
struct dm_profile_version { const char *build, *ver; };   // main's build ID → the display version GetDisplayVersion reports (hle_sdk16.c)
struct dm_profile {
    const char *id, *name, *romfs_marker, *game_args, *game_env, *feedback_snap, *alpha_from_red, *chain;
    uint64_t program_id, mem_reserve, mem_alias, mem_stack, app_pool, mem_used;
    const char *modules[DM_PROFILE_MAX_MOD]; int nmod;
    const struct dm_profile_version *versions; int nversions;
    int mem_map_limit, present_display, core_preempt, alloc_big_align, fps_target, fps_hold, pad_full, opmode_console, perf_boost;
    int tex_flush_upload, render_cond, tex_dirty_upload;   // 0 off / 1 on / 2 auto (nvn_autostat.h)
    int tex_dyn_slots, gpu_ts_segment, vconv_range;
    int shared_font_ttf;               // -1 = not in the profile (the host decides by the SDK version)
    int nvn_api_major, nvn_api_minor;  // 0 = not in the profile (by the SDK version)
};
extern struct dm_profile g_profile;   // filled by dm_profile_load before the host loads anything

// Parse and check <dir>/game.json into *p: 0 = valid; otherwise why says what is wrong and *p is untouched. No other side effects (the shell can call it on any folder)
int dm_profile_parse(const char *dir, struct dm_profile *p, char *why, size_t n);
// g_profile from <dir>/game.json; a missing or invalid profile stops the host with the reason
void dm_profile_load(const char *dir);
