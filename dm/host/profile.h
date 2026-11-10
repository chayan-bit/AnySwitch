// Game profile at run time: <profile dir>/game.json, the resolved dm/games/<id>/game.tsv written by dm/games/game.py json, read once at boot (profile.m).
// One host binary runs any game: nothing game-specific is compiled in. Keys and meanings: dm/games/README.md; the schema version is DM_PROFILE_SCHEMA (dm_abi.h).
// The JSON keys are upstream's game_profile.h macros (game.py header_one) without their DM_GAME_ prefix, lower case, and the DM_GAME_* names below read this struct,
// so code shared with seedds/nxnative compiles unchanged (the DM_GAME_* names live in game_profile.h, which a test may shadow with a synthetic one). A list macro (DM_GAME_MODULES, DM_GAME_BUILD_MODULES, DM_GAME_DISPLAY_VERSIONS) has no macro here: its users read the arrays
#pragma once
#include <stddef.h>
#include <stdint.h>

#define DM_PROFILE_MAX_MOD 8   // = MAX_MOD (dm.h)
struct dm_profile_pair { const char *build, *val; };   // main's build ID -> its display version (versions) or its space-separated modules (build_modules)
struct dm_profile {
    const char *id, *name, *romfs_marker, *args, *env, *launch_param, *ue_fps_cvar, *upscaler_keys, *chain;
    uint64_t program_id, mem_reserve, mem_alias, mem_stack, app_pool, mem_used, sys_resource, stdalloc_cap;
    const char *modules[DM_PROFILE_MAX_MOD]; int nmod;
    const struct dm_profile_pair *versions; int nversions;
    const struct dm_profile_pair *build_modules; int nbuild_modules;
    int mem_map_limit, screen_aspect, present_display, core_preempt, alloc_big_align, fps_target, fps_max, fps_hold, ue_texture_pool, present_snap, pso_mtl4, enc_thread;
    int pad_layout, opmode, perf_boost, tex_flush_upload, render_cond, tex_dirty_upload, tex_dyn_slots, draw_barriers_game, upscaler_n, vconv_range;
    uint32_t shader_key_skip_off, shader_key_skip_len;
    int shared_font_ttf;               // -1 = not in the profile (the host decides by the SDK version)
    int nvn_api_major, nvn_api_minor;  // 0 = not in the profile (by the SDK version)
};
extern struct dm_profile g_profile;   // filled by dm_profile_load before the host loads anything

// Parse and check <dir>/game.json into *p: 0 = valid; otherwise why says what is wrong and *p is untouched. No other side effects (the shell can call it on any folder)
int dm_profile_parse(const char *dir, struct dm_profile *p, char *why, size_t n);
// g_profile from <dir>/game.json; a missing or invalid profile stops the host with the reason
void dm_profile_load(const char *dir);
