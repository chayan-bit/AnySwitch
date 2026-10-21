// Dev input channel (dev builds only, make DEVCTL=1): sequence parser and controller state, free of host dependencies so the unit test links it alone.
// Grammar and protocol: docs/dev-control.md. Everything is counted in presented frames (dm_guest_frame), never seconds, so a sequence replays the same way on a busy machine.
#pragma once
#include <stddef.h>
#include <stdint.h>

enum { DEVCTL_DOWN, DEVCTL_UP, DEVCTL_LSTICK, DEVCTL_RSTICK, DEVCTL_TOUCH, DEVCTL_UNTOUCH, DEVCTL_RELEASE_ALL };
typedef struct { uint64_t frame; int kind; uint64_t mask; int32_t x, y; float tx, ty; } devctl_ev;   // mask: DM_BTN_* bits (DOWN / UP); x, y: stick; tx, ty: touch
typedef struct { uint64_t btn; int32_t lx, ly, rx, ry; int touch; float tx, ty; } devctl_state;

#define DEVCTL_MAX_EV 4096
#define DEVCTL_HOLD 5   // frames a tap holds by default (DM_KEYS's 0.15 s at 30 fps)
#define DEVCTL_GAP 5    // frames released after a tap before the next step starts, so two taps of one button read as two presses

// Parses a sequence starting at frame `start` (the first frame the game has not begun yet). Writes events sorted by frame (stable) and the frame after the last step to *end.
// Returns the event count, or -1 with a message in err.
int devctl_parse(const char *src, uint64_t start, devctl_ev *out, int max, uint64_t *end, char *err, size_t errlen);
void devctl_apply(devctl_state *s, const devctl_ev *e);
