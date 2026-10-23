// Home's focus model (dm/ios/Hearth/HearthFocus.m) and the held-direction repeat (dm/ios/Sources/DmRepeat.m): zone moves, the place each zone remembers, edges,
// empty zones, a touch hiding the ring, and the repeat timing. Foundation only, runs on the Mac: make -C dm/ios/tests run
#import <Foundation/Foundation.h>
#import "HearthFocus.h"
#import "HearthTheme.h"
#import "DmRepeat.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) { @autoreleasepool {
    // 1. moves inside a zone stop at its ends; up and down switch zones and come back to the remembered place
    { HearthFocus *f = [[HearthFocus alloc] initWithZones:2];
      [f setCount:4 forZone:0]; [f setCount:1 forZone:1];
      CHECK(f.zone == 0 && f.index == 0 && f.ringVisible, "starts on the first tile with the ring shown");
      CHECK(![f move:HearthDirLeft] && f.index == 0, "left at the first tile does nothing");
      CHECK([f move:HearthDirRight] && [f move:HearthDirRight] && f.index == 2, "right twice: tile 2");
      CHECK([f move:HearthDirRight] && ![f move:HearthDirRight] && f.index == 3, "the last tile is the end");
      CHECK([f move:HearthDirDown] && f.zone == 1 && f.index == 0, "down: the buttons");
      CHECK(![f move:HearthDirDown] && f.zone == 1, "down from the last zone does nothing");
      CHECK([f move:HearthDirUp] && f.zone == 0 && f.index == 3, "up: back to the tile it left (index %ld)", (long)f.index);
      CHECK(![f move:HearthDirUp], "up from the first zone does nothing");
      CHECK(![f move:HearthDirNone], "no direction, no move"); }
    // 2. a touch hides the ring; the next direction only shows it; a touch focus moves without showing it
    { HearthFocus *f = [[HearthFocus alloc] initWithZones:2];
      [f setCount:3 forZone:0]; [f setCount:1 forZone:1];
      [f touched]; CHECK(!f.ringVisible, "a touch hides the ring");
      [f focusZone:0 index:2]; CHECK(f.index == 2 && !f.ringVisible, "a tap focuses the tile it hit; the ring stays hidden");
      CHECK(![f move:HearthDirLeft] && f.index == 2 && f.ringVisible, "the first direction after a touch only brings the ring back");
      CHECK([f move:HearthDirLeft] && f.index == 1, "the next one moves");
      [f touched]; [f showRing]; CHECK(f.ringVisible, "A (or any other button) shows the ring");
      [f focusZone:0 index:9]; [f focusZone:5 index:0]; CHECK(f.zone == 0 && f.index == 1, "a focus outside the items is ignored"); }
    // 3. empty zones: skipped by up and down; the focus leaves a zone that empties; positions clamp to a shorter row
    { HearthFocus *f = [[HearthFocus alloc] initWithZones:3];
      [f setCount:0 forZone:0]; [f setCount:2 forZone:1]; [f setCount:1 forZone:2];
      CHECK(f.zone == 1, "no games: the focus starts on the first zone with items (zone %ld)", (long)f.zone);
      [f setCount:5 forZone:0]; [f focusZone:0 index:4]; [f setCount:0 forZone:1];
      CHECK([f move:HearthDirDown] && f.zone == 2, "down skips the empty zone");
      [f setCount:2 forZone:0]; CHECK([f indexInZone:0] == 1, "a shorter row clamps the remembered place (%ld)", (long)[f indexInZone:0]);
      [f move:HearthDirUp]; CHECK(f.zone == 0 && f.index == 1, "up skips the empty zone back to the row");
      [f setCount:0 forZone:0]; CHECK(f.zone == 2, "the row emptied while focused: the focus moves to a zone with items");
      HearthFocus *o = [[HearthFocus alloc] initWithZones:2];
      [o setCount:1 forZone:1]; [o setCount:3 forZone:0];
      CHECK(o.zone == 0 && o.index == 0, "the buttons counted before the games: the focus still starts on the first game (zone %ld)", (long)o.zone);
      [o move:HearthDirDown]; [o setCount:4 forZone:0]; CHECK(o.zone == 1, "a zone the player chose keeps the focus when the row changes");
      HearthFocus *e = [[HearthFocus alloc] initWithZones:2];
      CHECK(e.index == -1 && ![e move:HearthDirDown], "nothing anywhere: no focus, no move"); }
    // 4. the repeat: the first step after DM_REPEAT_FIRST, then at the steps' own delays; stop and a new hold end the old one
    { DmRepeat *r = [DmRepeat new]; NSMutableArray<NSNumber *> *at = [NSMutableArray array]; CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
      [r hold:1 step:^NSTimeInterval { [at addObject:@(CFAbsoluteTimeGetCurrent() - t0)]; return DM_REPEAT_NEXT; }];
      CHECK(r.held == 1, "held");
      [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
      CHECK(at.count >= 2 && at.count <= 4, "steps in 0.8 s: %lu", (unsigned long)at.count);
      CHECK(at.count && fabs(at[0].doubleValue - DM_REPEAT_FIRST) < 0.08, "first repeat at %.3f s", at.count ? at[0].doubleValue : -1);
      CHECK(at.count > 1 && fabs(at[1].doubleValue - at[0].doubleValue - DM_REPEAT_NEXT) < 0.06, "then every %.3f s", at.count > 1 ? at[1].doubleValue - at[0].doubleValue : -1);
      [r stop]; NSUInteger n = at.count;
      [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
      CHECK(at.count == n && r.held == 0, "stop: no more steps");
      __block int a = 0, b = 0;
      [r hold:2 step:^NSTimeInterval { a++; return 0.05; }]; [r hold:3 step:^NSTimeInterval { b++; return 0.05; }];
      [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
      CHECK(a == 0 && b >= 2 && r.held == 3, "a new hold replaces the old one (old %d, new %d)", a, b);
      [r hold:4 step:nil]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
      CHECK(r.held == 4 && b < 20, "held without steps (a key already down)"); [r stop]; }

    // 5. the button hints belong to the ring: gone after a touch, back with the ring, never shown when nothing is focused
    { HearthFocus *f = [[HearthFocus alloc] initWithZones:2];
      CHECK(!f.hintsVisible, "nothing focused: no hints");
      [f setCount:3 forZone:0]; [f setCount:1 forZone:1];
      CHECK(f.hintsVisible, "a fresh Home shows the ring and the hints");
      [f touched]; CHECK(!f.hintsVisible && !f.ringVisible, "a touch hides the ring and the hints with it");
      [f focusZone:0 index:2]; CHECK(!f.hintsVisible, "a tap focuses a tile and the hints stay away");
      CHECK(![f move:HearthDirLeft] && f.hintsVisible, "the first direction after a touch brings the ring and the hints back");
      [f touched]; [f showRing]; CHECK(f.hintsVisible, "A on a hidden ring shows both");
      [f touched]; [f setCount:0 forZone:0]; [f move:HearthDirDown]; CHECK(f.hintsVisible == f.ringVisible, "hints follow the ring on the button row too");
      HearthFocus *e = [[HearthFocus alloc] initWithZones:1]; [e setCount:0 forZone:0]; CHECK(!e.hintsVisible, "an emptied Home has no hints"); }
    // 6. the dialog's buttons are one zone: it starts on the focus it was given, left and right stop at the ends
    { HearthFocus *f = [[HearthFocus alloc] initWithZones:1]; [f setCount:2 forZone:0]; [f focusZone:0 index:1];
      CHECK(f.index == 1 && f.hintsVisible, "Cancel and Close: the focus starts on Close");
      CHECK(![f move:HearthDirRight] && f.index == 1, "right of the last button does nothing");
      CHECK([f move:HearthDirLeft] && f.index == 0 && ![f move:HearthDirLeft], "left reaches Cancel and stops");
      CHECK(![f move:HearthDirUp] && ![f move:HearthDirDown] && f.index == 0, "up and down do nothing in a row of buttons"); }
    // 7. Home's measures (HearthTheme.h): 300 pt tiles, 340 pt focused, on the 1024 pt iPad screen; smaller and larger screens scale and clamp
    { CHECK(hearth_tile_size(1024) == 300, "iPad Air landscape: %g", hearth_tile_size(1024));
      CHECK(fabs(hearth_tile_size(1024) * hearth_tile_focus_scale(hearth_tile_size(1024)) - 340) < 1e-9, "focused edge %g", hearth_tile_size(1024) * hearth_tile_focus_scale(300));
      CHECK(hearth_tile_size(744) == 218 && hearth_tile_size(1032) == 302, "other iPads: %g and %g", hearth_tile_size(744), hearth_tile_size(1032));
      CHECK(hearth_tile_size(300) == HEARTH_TILE_MIN && hearth_tile_size(4000) == HEARTH_TILE_MAX, "clamped: %g and %g", hearth_tile_size(300), hearth_tile_size(4000));
      double h = 1024, size = hearth_tile_size(h), centre = h * HEARTH_ROW_CENTRE;
      CHECK(fabs(centre - 409.6) < 1e-9 && centre - size / 2 > 100, "the art's centre sits at 40%% of the height, clear of the top bar (%g)", centre);
      double rowBottom = centre + size / 2 + 44, buttonsTop = rowBottom + HEARTH_BUTTONS_GAP, barTop = h - HEARTH_BAR_HEIGHT;
      CHECK(buttonsTop + HEARTH_BUTTON_SIZE + 24 < barTop, "the round buttons (%g to %g) fit above the bottom bar (%g)", buttonsTop, buttonsTop + HEARTH_BUTTON_SIZE, barTop); }
    // 8. the layout of HearthMetrics on five landscape screens (iPad Air 11 and 13, iPhone 15 Pro, 16 Pro, 16 Pro Max): nothing overlaps top to bottom, the regular values are today's constants
    { double sizes[5][4] = {{1180, 820, 0, 20}, {1366, 1024, 0, 20}, {852, 393, 0, 21}, {874, 402, 0, 21}, {956, 440, 0, 21}};   // width, height, safe top, safe bottom
      for (int i = 0; i < 5; i++) {
          double w = sizes[i][0], h = sizes[i][1], st = sizes[i][2], sb = sizes[i][3];
          HearthMetrics m = hearth_metrics(w, h, st, sb);
          double ry = m.rowTop >= 0 ? st + m.rowTop : h * HEARTH_ROW_CENTRE - m.nameH - m.tile / 2, th = m.nameH + m.tile + m.stateH;
          double barTop = h - sb - m.barH, by = fmin(ry + th + m.buttonsGap, barTop - m.barGap - m.button), g = m.grow / 2;
          double topBarBottom = st + m.topOffset + m.topH;
          CHECK(m.compact == (fmin(w, h) < 500), "%gx%g: compact %d", w, h, m.compact);
          CHECK(ry + m.nameH - m.grow / 2 - m.nameGap - m.nameLabelH >= topBarBottom, "%gx%g: the focused name (%g) clears the top bar (%g)", w, h, ry + m.nameH - g - m.nameGap - m.nameLabelH, topBarBottom);
          CHECK(ry + th + g <= by, "%gx%g: the grown art and state line (to %g) end above the round buttons (%g)", w, h, ry + th + g, by);
          CHECK(by + m.button + m.barGap <= barTop + 1e-9, "%gx%g: the round buttons (to %g) end above the bottom bar (%g)", w, h, by + m.button, barTop);
          CHECK(m.tile >= (m.compact ? 96 : HEARTH_TILE_MIN) && m.tile <= HEARTH_TILE_MAX, "%gx%g: tile %g", w, h, m.tile);
          CHECK(m.tile + m.grow <= h - st - sb, "%gx%g: the grown art fits the screen", w, h);
          if (!m.compact) CHECK(m.tile == hearth_tile_size(h) && m.button == HEARTH_BUTTON_SIZE && m.barH == HEARTH_BAR_HEIGHT && m.margin == HEARTH_MARGIN && m.nameH == 56 && m.stateH == 44 && m.rowTop < 0, "%gx%g: regular is today's layout", w, h);
      }
      HearthMetrics p = hearth_metrics(874, 402, 0, 21);
      CHECK(p.tile == 135 && p.button == 48 && p.barH == 44, "iPhone 16 Pro: tile %g, buttons %g, bar %g", p.tile, p.button, p.barH); }

    printf("t_home_focus: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
