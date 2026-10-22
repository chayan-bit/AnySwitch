// Hearth's own measures (plan-hearth-p2.md section 7): sizes, radii and timings chosen for Hearth, not taken from any console. Colours live in dm/ios/Sources/DmPalette.h
#pragma once

// Focus: a solid ring with a soft glow around it that breathes slowly (Reduce Motion: a steady glow)
#define HEARTH_RING_WIDTH       2.0
#define HEARTH_GLOW_RADIUS      10.0
#define HEARTH_GLOW_MIN         0.35    // glow opacity at the low point of a breath
#define HEARTH_GLOW_MAX         0.9
#define HEARTH_BREATH_SECONDS   1.6     // one full breath (in and out)

// Home tiles
#define HEARTH_TILE_SIZE        220.0
#define HEARTH_TILE_RADIUS      22.0
#define HEARTH_TILE_SPACING     32.0
