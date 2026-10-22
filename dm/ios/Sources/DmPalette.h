// The settings screen's surface colours as plain sRGB hex values, so the contrast of the toggle / slider track against the row it sits on can be computed in a Mac test (dm/ios/tests/t_settings.m).
// DmSettingsViews.m builds its dynamic colours from these.
#pragma once
#include <math.h>
#include <stdint.h>

#define DM_PANEL_LIGHT 0xFFFFFF
#define DM_PANEL_DARK  0x363636
#define DM_ROW_LIGHT   0xF0F0F0
#define DM_ROW_DARK    0x424242
// The empty part of a toggle or slider: at least 3:1 against a row (WCAG non-text contrast) with margin, because a device renders a colour a little darker than its value (about 10% measured)
#define DM_TRACK_LIGHT 0x767676
#define DM_TRACK_DARK  0xA6A6A6

static inline double dm_channel_linear(uint32_t c) { double v = c / 255.0; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
static inline double dm_luminance(uint32_t rgb) { return 0.2126 * dm_channel_linear((rgb >> 16) & 255) + 0.7152 * dm_channel_linear((rgb >> 8) & 255) + 0.0722 * dm_channel_linear(rgb & 255); }
static inline double dm_contrast(uint32_t a, uint32_t b) { double x = dm_luminance(a), y = dm_luminance(b); return (fmax(x, y) + 0.05) / (fmin(x, y) + 0.05); }   // WCAG contrast ratio, 1...21
