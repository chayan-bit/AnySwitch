// Upstream (seedds/nxnative) includes a generated per-game header here; AnySwitch reads the profile at boot (profile.h), and these DM_GAME_* names read it.
// A test may pin compile-time values instead: tests/memory_profile/game_profile.h, force-included (-include) before this header, defines names this one then leaves alone.
#pragma once
#include "profile.h"

#ifndef DM_GAME_ID
#define DM_GAME_ID (g_profile.id)
#endif
#ifndef DM_GAME_NAME
#define DM_GAME_NAME (g_profile.name)
#endif
#ifndef DM_GAME_PROGRAM_ID
#define DM_GAME_PROGRAM_ID (g_profile.program_id)
#endif
#ifndef DM_GAME_NMOD
#define DM_GAME_NMOD (g_profile.nmod)
#endif
#ifndef DM_GAME_ROMFS_MARKER
#define DM_GAME_ROMFS_MARKER (g_profile.romfs_marker)
#endif
#ifndef DM_GAME_MEM_RESERVE
#define DM_GAME_MEM_RESERVE (g_profile.mem_reserve)
#endif
#ifndef DM_GAME_MEM_ALIAS
#define DM_GAME_MEM_ALIAS (g_profile.mem_alias)
#endif
#ifndef DM_GAME_MEM_STACK
#define DM_GAME_MEM_STACK (g_profile.mem_stack)
#endif
#ifndef DM_GAME_APP_POOL
#define DM_GAME_APP_POOL (g_profile.app_pool)
#endif
#ifndef DM_GAME_MEM_USED
#define DM_GAME_MEM_USED (g_profile.mem_used)
#endif
#ifndef DM_GAME_SYS_RESOURCE
#define DM_GAME_SYS_RESOURCE (g_profile.sys_resource)
#endif
#ifndef DM_GAME_ARGS
#define DM_GAME_ARGS (g_profile.args)
#endif
#ifndef DM_GAME_ENV
#define DM_GAME_ENV (g_profile.env)
#endif
#ifndef DM_GAME_LAUNCH_PARAM
#define DM_GAME_LAUNCH_PARAM (g_profile.launch_param)
#endif
#ifndef DM_GAME_MEM_MAP_LIMIT
#define DM_GAME_MEM_MAP_LIMIT (g_profile.mem_map_limit)
#endif
#ifndef DM_GAME_STDALLOC_CAP
#define DM_GAME_STDALLOC_CAP (g_profile.stdalloc_cap)
#endif
#ifndef DM_GAME_SCREEN_ASPECT
#define DM_GAME_SCREEN_ASPECT (g_profile.screen_aspect)
#endif
#ifndef DM_GAME_PRESENT_DISPLAY
#define DM_GAME_PRESENT_DISPLAY (g_profile.present_display)
#endif
#ifndef DM_GAME_CORE_PREEMPT
#define DM_GAME_CORE_PREEMPT (g_profile.core_preempt)
#endif
#ifndef DM_GAME_ALLOC_BIG_ALIGN
#define DM_GAME_ALLOC_BIG_ALIGN (g_profile.alloc_big_align)
#endif
#ifndef DM_GAME_FPS_TARGET
#define DM_GAME_FPS_TARGET (g_profile.fps_target)
#endif
#ifndef DM_GAME_FPS_MAX
#define DM_GAME_FPS_MAX (g_profile.fps_max)
#endif
#ifndef DM_GAME_FPS_HOLD
#define DM_GAME_FPS_HOLD (g_profile.fps_hold)
#endif
#ifndef DM_GAME_UE_TEXTURE_POOL
#define DM_GAME_UE_TEXTURE_POOL (g_profile.ue_texture_pool)
#endif
#ifndef DM_GAME_UE_FPS_CVAR
#define DM_GAME_UE_FPS_CVAR (g_profile.ue_fps_cvar)
#endif
#ifndef DM_GAME_PRESENT_SNAP
#define DM_GAME_PRESENT_SNAP (g_profile.present_snap)
#endif
#ifndef DM_GAME_PSO_MTL4
#define DM_GAME_PSO_MTL4 (g_profile.pso_mtl4)
#endif
#ifndef DM_GAME_ENC_THREAD
#define DM_GAME_ENC_THREAD (g_profile.enc_thread)
#endif
#ifndef DM_GAME_PAD_LAYOUT
#define DM_GAME_PAD_LAYOUT (g_profile.pad_layout)
#endif
#ifndef DM_GAME_OPMODE
#define DM_GAME_OPMODE (g_profile.opmode)
#endif
#ifndef DM_GAME_PERF_BOOST
#define DM_GAME_PERF_BOOST (g_profile.perf_boost)
#endif
#ifndef DM_GAME_TEX_FLUSH_UPLOAD
#define DM_GAME_TEX_FLUSH_UPLOAD (g_profile.tex_flush_upload)
#endif
#ifndef DM_GAME_SHADER_KEY_SKIP_OFF
#define DM_GAME_SHADER_KEY_SKIP_OFF (g_profile.shader_key_skip_off)
#endif
#ifndef DM_GAME_SHADER_KEY_SKIP_LEN
#define DM_GAME_SHADER_KEY_SKIP_LEN (g_profile.shader_key_skip_len)
#endif
#ifndef DM_GAME_RENDER_COND
#define DM_GAME_RENDER_COND (g_profile.render_cond)
#endif
#ifndef DM_GAME_TEX_DIRTY_UPLOAD
#define DM_GAME_TEX_DIRTY_UPLOAD (g_profile.tex_dirty_upload)
#endif
#ifndef DM_GAME_TEX_DYN_SLOTS
#define DM_GAME_TEX_DYN_SLOTS (g_profile.tex_dyn_slots)
#endif
#ifndef DM_GAME_DRAW_BARRIERS_GAME
#define DM_GAME_DRAW_BARRIERS_GAME (g_profile.draw_barriers_game)
#endif
#ifndef DM_GAME_UPSCALER_KEYS
#define DM_GAME_UPSCALER_KEYS (g_profile.upscaler_keys)
#endif
#ifndef DM_GAME_UPSCALER_N
#define DM_GAME_UPSCALER_N (g_profile.upscaler_n)
#endif
#ifndef DM_GAME_VCONV_RANGE
#define DM_GAME_VCONV_RANGE (g_profile.vconv_range)
#endif
// Optional keys: 0 / -1 when the profile has none (upstream tests these with #ifdef)
#ifndef DM_GAME_NVN_API_MAJOR
#define DM_GAME_NVN_API_MAJOR (g_profile.nvn_api_major)
#endif
#ifndef DM_GAME_NVN_API_MINOR
#define DM_GAME_NVN_API_MINOR (g_profile.nvn_api_minor)
#endif
#ifndef DM_GAME_SHARED_FONT_TTF
#define DM_GAME_SHARED_FONT_TTF (g_profile.shared_font_ttf)
#endif
