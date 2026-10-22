// Internal resolution (DM_INTERNAL_RES): render targets drawn at a multiple of the guest size. Pure helpers, unit-tested in tests/t_rscale.c.
// The translated shaders already carry Ryujinx's render-scale code (FragCoord divide, texel-fetch scale, texture-size unscale), all reading support_buffer.render_scale;
// the reflection says which binding uses which render_scale entry (nvn_refl.h sidx / sfl / frag_coord, written by tools/dmsh_rscale.py).
// So far the scale is parsed and logged only: every target stays at 1x.
#pragma once
#include <stdlib.h>

#define NVN_RS_SCALES { 1.0f, 1.5f, 2.0f }   // the scales the setting offers (Settings "Internal resolution", DmSettings.m)

// The scale a DM_INTERNAL_RES value asks for: unset or empty = 1; a number equal to one of NVN_RS_SCALES (1, 1.0, 1.5, 2, 2.0 ...); anything else = 0 (invalid: the caller logs it and uses 1)
static inline float nvn_rs_parse(const char *e) {
    if (!e || !*e) return 1.0f;
    char *end; float v = strtof(e, &end);
    if (end == e || *end) return 0.0f;
    static const float ok[] = NVN_RS_SCALES;
    for (unsigned i = 0; i < sizeof ok / sizeof *ok; i++) if (v == ok[i]) return v;
    return 0.0f;
}
