// Run-time switches and observation helpers for the GPU workaround keys that are moving to detection at run time (render_cond, tex_flush_upload / tex_dirty_upload, feedback_snap).
// A key's profile value is off, on or auto (game.py: macro 0 / 1 / 2); an environment variable of the same three words (or 0 / 1) overrides it, so a compatibility run can A/B a key
// without rebuilding the host. auto has no detector yet and resolves to off, which keeps today's default behaviour; the detectors replace that rule one key at a time.
// The screenshot statistics give the compatibility runner (scripts/compat_run.py) what it needs from a frame without decoding PNGs: the [shot] log line.
// Unit test: tests/t_autostat.c
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { NVN_AUTO_OFF = 0, NVN_AUTO_ON = 1, NVN_AUTO_AUTO = 2 };

// The mode from an environment value, or the profile's when the value is unset or names no mode
static inline int nvn_auto_mode(const char *env, int profile) {
    if (!env || !*env) return profile;
    if (!strcmp(env, "on") || !strcmp(env, "1")) return NVN_AUTO_ON;
    if (!strcmp(env, "off") || !strcmp(env, "0")) return NVN_AUTO_OFF;
    if (!strcmp(env, "auto")) return NVN_AUTO_AUTO;
    return profile;
}
static inline int nvn_auto_on(int mode) { return mode == NVN_AUTO_ON; }   // auto: off until its detector lands
static inline const char *nvn_auto_name(int mode) { return mode == NVN_AUTO_ON ? "on" : mode == NVN_AUTO_AUTO ? "auto" : "off"; }
// The resolved mode of each key (hle_nvn.c: the profile macro, overridden by DM_NVN_RENDER_COND / DM_NVN_TEX_GUEST); read once, so a switch from the iOS app's env.txt counts too
enum { NVN_KEY_RENDER_COND, NVN_KEY_TEX_FLUSH, NVN_KEY_TEX_DIRTY };
int nvn_key_mode(int key);
static inline int nvn_key_on(int key) { return nvn_auto_on(nvn_key_mode(key)); }

// Screenshot statistics over an 8-bit RGBA or BGRA image (row bytes per row): mean luma (0-255), the share of pixels with any channel at 16 or more, pixels of the error colour
// magenta (ASTC decodes zeros to it, the host's missing-texture fallbacks use it), aligned 16x16 blocks that are magenta throughout, and an FNV-1a hash over R, G, B
typedef struct { double luma, nonblack; uint64_t magenta_px, magenta_blocks16, hash; } nvn_shot_stat;
static inline int nvn_magenta(uint8_t r, uint8_t g, uint8_t b) { return r >= 224 && b >= 224 && g <= 32; }
static inline void nvn_shot_stats(const uint8_t *p, size_t w, size_t h, size_t row, int bgra, nvn_shot_stat *s) {
    uint64_t luma = 0, lit = 0, mag = 0, hash = 0xcbf29ce484222325ull;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        const uint8_t *q = p + y * row + 4 * x; uint8_t r = bgra ? q[2] : q[0], g = q[1], b = bgra ? q[0] : q[2];
        luma += 77u * r + 150u * g + 29u * b;
        lit += r >= 16 || g >= 16 || b >= 16;
        mag += nvn_magenta(r, g, b);
        hash = (hash ^ r) * 0x100000001b3ull; hash = (hash ^ g) * 0x100000001b3ull; hash = (hash ^ b) * 0x100000001b3ull;
    }
    uint64_t blocks = 0;
    for (size_t by = 0; by + 16 <= h; by += 16) for (size_t bx = 0; bx + 16 <= w; bx += 16) {
        int all = 1;
        for (size_t y = by; y < by + 16 && all; y++) for (size_t x = bx; x < bx + 16; x++) {
            const uint8_t *q = p + y * row + 4 * x;
            if (!nvn_magenta(bgra ? q[2] : q[0], q[1], bgra ? q[0] : q[2])) { all = 0; break; }
        }
        blocks += all;
    }
    double n = w && h ? (double)w * (double)h : 1;
    *s = (nvn_shot_stat){luma / 256.0 / n, lit / n, mag, blocks, hash};
}

// Same-pass feedback (a fragment shader samples a colour attachment of its own pass): C = this draw writes that attachment (the read races the write: a snapshot is needed),
// B = an earlier draw of the pass wrote it (ending the pass would do), A = nothing in the pass wrote it yet (the memory holds the loaded content)
static inline char nvn_fb_class(int this_draw_writes, int written_in_pass) { return this_draw_writes ? 'C' : written_in_pass ? 'B' : 'A'; }
