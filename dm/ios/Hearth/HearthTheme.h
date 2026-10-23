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
static inline double hearth_tile_scale(double tile, double grow) { return (tile + grow) / tile; }

// Home's measures for one screen (the iPhone compact layout). Compact is the iPhone's (the screen's shorter side under 500 pt, the switch DmSettingsVC uses); regular equals the constants above,
// so an iPad keeps today's layout to the point. A pure function of the screen size and the vertical safe-area insets, so a test can check any screen on the Mac.
typedef struct {
    int compact;
    double tile, grow, radius, spacing;                 // art edge, how much longer the focused edge is, corner radius, gap between tiles
    double nameH, nameLabelH, nameGap, nameFont;        // band above the art, the focused game's name label in it, its gap to the art, its font
    double stateH, stateGap, stateLabelH, stateFont;    // band below the art and the state line in it
    double button, buttonSpacing, buttonsGap, buttonIcon, barGap;   // round buttons: size, gap between, gap under the row, symbol size, least gap above the bottom bar
    double barH, margin;                                // bottom bar height, side margins
    double topOffset, topH, avatar, playerFont, clockFont, batteryFont;   // top bar
    double rowTop;                                      // the row's top edge measured from the top safe edge; -1: the art's centre sits at HEARTH_ROW_CENTRE of the height
} HearthMetrics;

static inline HearthMetrics hearth_metrics(double width, double height, double safeTop, double safeBottom) {
    double shorter = width < height ? width : height;
    if (safeTop < 0) safeTop = 0;
    if (safeBottom < 0) safeBottom = 0;
    HearthMetrics m = {0, hearth_tile_size(height), HEARTH_TILE_GROW, HEARTH_TILE_RADIUS, HEARTH_TILE_SPACING, 56, 36, 12, 26, 44, 8, 36, 19,
                       HEARTH_BUTTON_SIZE, 28, HEARTH_BUTTONS_GAP, 26, 24, HEARTH_BAR_HEIGHT, HEARTH_MARGIN, 24, 48, 36, 20, 22, 17, -1};
    if (shorter >= 500) return m;
    m.compact = 1; m.grow = 28; m.radius = 20; m.spacing = 24;
    m.nameLabelH = 30; m.nameGap = 8; m.nameFont = 20; m.nameH = m.grow / 2 + m.nameGap + m.nameLabelH;   // the focused name stays clear of the top bar
    m.stateGap = 3; m.stateLabelH = 20; m.stateFont = 15; m.stateH = m.stateGap + m.stateLabelH + 1;
    m.button = 48; m.buttonSpacing = 20; m.buttonsGap = 22; m.buttonIcon = 20; m.barGap = 8;   // the gap holds the focused button's name above it
    m.barH = 44; m.margin = 16;
    m.topOffset = 8; m.topH = 36; m.avatar = 28; m.playerFont = 17; m.clockFont = 18; m.batteryFont = 15;
    m.rowTop = m.topOffset + m.topH + 4;
    double fixed = safeTop + m.rowTop + m.nameH + m.stateH + m.buttonsGap + m.button + m.barGap + m.barH + safeBottom;   // everything but the art, top to bottom
    double t = height - fixed, cap = height * 0.36;
    t = t > cap ? cap : t < 96 ? 96 : t;
    m.tile = (double)(long)t;
    return m;
}
