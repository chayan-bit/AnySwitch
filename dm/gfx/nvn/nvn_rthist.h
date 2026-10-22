// Render-target history for skip-draw (DM_PSO_FLEX, dm/gfx/README.md): which render passes may drop a draw whose pipeline is not ready yet.
// A skipped draw is lost for one frame only when its target is drawn again the next frame. A target rendered once and then sampled for many frames (text or an icon baked into a
// texture, a map built on demand) keeps the hole for as long as it is used, so a draw into it waits for its pipeline instead. The rule: a pass may skip when every target it attaches
// was also rendered in the previous frame; a target new this frame, idle last frame, or a pass with no target at all waits.
// One table entry per target serial, its value two frame stamps packed in the pointer (no allocation): the last frame it was rendered and the frame before that one.
// Written once per pass begin on the replay thread (the caller's lock); the draws only read the pass's result. Entries idle for more than a frame are pruned every RTH_PRUNE_EVERY frames:
// an absent entry means the same as an idle one. Unit test: tests/t_flexpso.m.
#pragma once
#include <stdint.h>
#include "nvn_hmap.h"

enum { RTH_PRUNE_EVERY = 600 };
typedef struct { nvn_hmap m; uint64_t next_prune; } nvn_rthist;

static inline void rth_init(nvn_rthist *h) { nvn_hm_init(&h->m, 8); h->next_prune = RTH_PRUNE_EVERY; }
static inline void rth_free(nvn_rthist *h) { free(h->m.keys); free(h->m.vals); rth_init(h); }

// Stamps are frame + 1 (0 = never) in 32 bits each: last in the high half (never 0, so the value is never NULL), the previous frame of use in the low half
static inline void rth_prune(nvn_rthist *h, uint64_t frame) {
    nvn_hmap o = h->m; nvn_hm_init(&h->m, 8);
    for (uint32_t i = 0; i < o.cap; i++) {
        uint64_t v = (uint64_t)(uintptr_t)o.vals[i];
        if (v && (v >> 32) >= frame) nvn_hm_put(&h->m, o.keys + (size_t)i * 8, o.vals[i]);   // last use at frame - 1 or later (its stamp frame or more): kept
    }
    free(o.keys); free(o.vals);
}

// Stamps the n target serials of a pass beginning in frame; returns 1 when the pass may skip a draw: n > 0 and every target was rendered in frame - 1
static inline int rth_pass(nvn_rthist *h, const uint64_t *ser, int n, uint64_t frame) {
    if (frame >= h->next_prune) { rth_prune(h, frame); h->next_prune = frame + RTH_PRUNE_EVERY; }
    uint32_t f1 = (uint32_t)(frame + 1); int steady = n > 0;
    for (int i = 0; i < n; i++) {
        uint64_t v = (uint64_t)(uintptr_t)nvn_hm_get(&h->m, &ser[i]); uint32_t last = (uint32_t)(v >> 32), prev = (uint32_t)v;
        if (last != f1) { prev = last; last = f1; nvn_hm_put(&h->m, &ser[i], (void *)(uintptr_t)((uint64_t)last << 32 | prev)); }
        steady &= prev && prev == (uint32_t)frame;   // previous use stamped (frame - 1) + 1
    }
    return steady;
}
