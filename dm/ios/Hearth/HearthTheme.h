// Hearth's own measures (plan-hearth-p2.md section 7): sizes, radii and timings chosen for Hearth, not taken from any console. Colours live in dm/ios/Sources/DmPalette.h
#pragma once

// Focus: a solid ring with a soft glow around it that breathes slowly (Reduce Motion: a steady glow)
#define HEARTH_RING_WIDTH       2.0
#define HEARTH_GLOW_RADIUS      10.0
#define HEARTH_GLOW_MIN         0.35    // glow opacity at the low point of a breath
#define HEARTH_GLOW_MAX         0.9
#define HEARTH_BREATH_SECONDS   1.6     // one full breath (in and out)

// Home tiles: sized from the screen's height, so a tile is as big on an iPad as a game's icon should be on a console's Home (300 pt, 340 pt focused, on a 1024 pt screen)
#define HEARTH_TILE_HEIGHT_FRACTION 0.293   // the unfocused tile's edge over the screen's height
#define HEARTH_TILE_MIN         160.0
#define HEARTH_TILE_MAX         340.0
#define HEARTH_TILE_GROW        40.0    // how much longer the focused tile's edge is than the others'
#define HEARTH_TILE_RADIUS      26.0
#define HEARTH_TILE_SPACING     40.0
#define HEARTH_FOCUS_SECONDS    0.12    // focus moves and the tile's growth
#define HEARTH_LAUNCH_SECONDS   0.3     // the launch zoom (Reduce Motion: a plain fade)
#define HEARTH_BUTTON_SIZE      64.0    // the round system buttons under the tiles
#define HEARTH_MARGIN           40.0    // the screen's side margins
// Home's vertical layout, as fractions and gaps of the screen's height: the tile art's centre sits at 40% of it, the round buttons 60 pt under the row (name above, state line below included),
// and the bottom bar (a divider with the button hints on its right) is 72 pt high
#define HEARTH_ROW_CENTRE       0.40
#define HEARTH_BUTTONS_GAP      60.0
#define HEARTH_BAR_HEIGHT       72.0

static inline double hearth_tile_size(double screenHeight) {   // whole points, so the art's edges stay crisp
    double s = screenHeight * HEARTH_TILE_HEIGHT_FRACTION;
    s = s < HEARTH_TILE_MIN ? HEARTH_TILE_MIN : s > HEARTH_TILE_MAX ? HEARTH_TILE_MAX : s;
    return (double)(long)(s + 0.5);
}
static inline double hearth_tile_focus_scale(double tile) { return (tile + HEARTH_TILE_GROW) / tile; }
