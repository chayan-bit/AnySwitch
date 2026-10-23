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
#define HEARTH_TILE_FOCUS_SCALE 1.06    // the focused tile grows a little
#define HEARTH_FOCUS_SECONDS    0.12    // focus moves and the tile's growth
#define HEARTH_LAUNCH_SECONDS   0.3     // the launch zoom (Reduce Motion: a plain fade)
#define HEARTH_BUTTON_SIZE      64.0    // the round system buttons under the tiles
#define HEARTH_MARGIN           40.0    // the screen's side margins
