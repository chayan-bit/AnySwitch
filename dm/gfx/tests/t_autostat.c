// Unit tests for nvn_autostat.h: the run-time switch parser of the GPU workaround keys, the screenshot statistics the compatibility runner reads, and the same-pass feedback classes
#include "../nvn/nvn_autostat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail, checks;
static void check(int ok, const char *what) { checks++; fail += !ok; printf("%-78s %s\n", what, ok ? "ok" : "FAIL"); }

static void px(uint8_t *p, size_t w, size_t x, size_t y, int bgra, uint8_t r, uint8_t g, uint8_t b) {
    uint8_t *q = p + 4 * (y * w + x);
    q[0] = bgra ? b : r; q[1] = g; q[2] = bgra ? r : b; q[3] = 255;
}

int main(void) {
    // switches: env wins when it names a mode, the profile value otherwise; auto stays off until its detector exists
    check(nvn_auto_mode(NULL, NVN_AUTO_ON) == NVN_AUTO_ON, "no env: the profile value");
    check(nvn_auto_mode("", NVN_AUTO_ON) == NVN_AUTO_ON, "empty env: the profile value");
    check(nvn_auto_mode("off", NVN_AUTO_ON) == NVN_AUTO_OFF && nvn_auto_mode("0", NVN_AUTO_ON) == NVN_AUTO_OFF, "env off / 0 beats a profile on");
    check(nvn_auto_mode("on", NVN_AUTO_OFF) == NVN_AUTO_ON && nvn_auto_mode("1", NVN_AUTO_OFF) == NVN_AUTO_ON, "env on / 1 beats a profile off");
    check(nvn_auto_mode("auto", NVN_AUTO_ON) == NVN_AUTO_AUTO, "env auto");
    check(nvn_auto_mode("bogus", NVN_AUTO_ON) == NVN_AUTO_ON, "an unknown env value keeps the profile value");
    check(!nvn_auto_on(NVN_AUTO_OFF) && nvn_auto_on(NVN_AUTO_ON) && !nvn_auto_on(NVN_AUTO_AUTO), "only on is on (auto has no detector yet)");
    check(!strcmp(nvn_auto_name(NVN_AUTO_AUTO), "auto") && !strcmp(nvn_auto_name(NVN_AUTO_ON), "on") && !strcmp(nvn_auto_name(NVN_AUTO_OFF), "off"), "mode names");

    // screenshot statistics on a 32x32 image: all black, then one magenta 16x16 block, one stray magenta pixel and a grey pixel
    for (int bgra = 0; bgra < 2; bgra++) {
        enum { W = 32, H = 32 }; uint8_t *p = calloc(W * H, 4); nvn_shot_stat s;
        nvn_shot_stats(p, W, H, W * 4, bgra, &s);
        check(s.nonblack == 0 && s.luma == 0 && s.magenta_px == 0 && s.magenta_blocks16 == 0, bgra ? "BGRA black: nothing" : "RGBA black: nothing");
        uint64_t black_hash = s.hash;
        for (int y = 16; y < 32; y++) for (int x = 0; x < 16; x++) px(p, W, x, y, bgra, 255, 0, 255);
        px(p, W, 20, 2, bgra, 250, 10, 240);
        px(p, W, 30, 30, bgra, 100, 100, 100);
        nvn_shot_stats(p, W, H, W * 4, bgra, &s);
        check(s.magenta_px == 257 && s.magenta_blocks16 == 1, bgra ? "BGRA: 257 magenta pixels, one full block" : "RGBA: 257 magenta pixels, one full block");
        check(s.nonblack > 258.0 / 1024 - 1e-9 && s.nonblack < 258.0 / 1024 + 1e-9, "nonblack is the share of pixels with a channel at 16 or more");
        check(s.hash != black_hash, "the hash follows the content");
        nvn_shot_stat t; nvn_shot_stats(p, W, H, W * 4, bgra, &t);
        check(t.hash == s.hash, "the hash is stable");
        px(p, W, 16, 16, bgra, 255, 0, 255);
        nvn_shot_stats(p, W, H, W * 4, bgra, &t);
        check(t.magenta_blocks16 == 1 && t.magenta_px == 258, "a partly magenta block is not a block");
        free(p);
    }
    {   // the same picture in RGBA and BGRA hashes the same (the hash is over R, G, B)
        uint8_t a[16], b[16];
        for (int i = 0; i < 4; i++) { px(a, 2, i % 2, i / 2, 0, (uint8_t)(10 * i), 7, 200); px(b, 2, i % 2, i / 2, 1, (uint8_t)(10 * i), 7, 200); }
        nvn_shot_stat x, y; nvn_shot_stats(a, 2, 2, 8, 0, &x); nvn_shot_stats(b, 2, 2, 8, 1, &y);
        check(x.hash == y.hash && x.luma == y.luma, "RGBA and BGRA of one picture: same hash and luma");
    }
    {   // row padding is skipped
        uint8_t p[2 * 12] = {0}; px(p, 3, 2, 0, 0, 255, 255, 255); px(p, 3, 0, 1, 0, 255, 255, 255);   // 2 pixels a row in a 12-byte row (3 pixels' room): the padding of row 0 white, pixel (0, 1) white
        nvn_shot_stat s; nvn_shot_stats(p, 2, 2, 12, 0, &s);
        check(s.nonblack == 0.25, "the row stride is honoured");
    }

    // feedback classes: C when this draw writes the attachment, B when an earlier draw of the pass did, A otherwise
    check(nvn_fb_class(1, 0) == 'C' && nvn_fb_class(1, 1) == 'C', "this draw writes the attachment: C");
    check(nvn_fb_class(0, 1) == 'B', "written earlier in the pass only: B");
    check(nvn_fb_class(0, 0) == 'A', "not written in the pass: A");

    printf("%d checks, %d failed\n", checks, fail);
    return fail != 0;
}
