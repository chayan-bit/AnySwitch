// Sharp upscale at present (nvn_upscale.h, FSR 1 EASU + RCAS): real Metal rendering of synthetic frames, no game artwork.
// Checks: the picture covers exactly its viewport; flat colours come out exact (a NaN or an overflow would not); the result is measurably sharper than bilinear on a detail pattern and keeps its mean;
// noise never turns black; a same-size or smaller picture stays bilinear; crop and the bottom-up window origin keep the orientation; the screenshot path matches the live present;
// the target is reused at one size and reallocated at another; and the GPU cost per frame at 2752x2064 stays under the budget (the interleaved-minimum method of t_present_ambient).
// DM_SCALE_OUT=<dir> also writes bilinear / sharp PNGs of the detail pattern at 2752x2064; with DM_SCALE_IN=<png> (a captured frame) also that frame presented both ways at DM_SCALE_SIZE (default 2360x1640).
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }   // Tests use host-thread stacks.
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int o_ = (ok); checks++; if (!o_) { fprintf(stderr, "FAIL %s\n", name); failed++; } else printf("ok   %s\n", name); } while (0)

static id<MTLTexture> make_src(int w, int h, void (*fill)(uint8_t *, int, int)) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint8_t *px = malloc((size_t)w * h * 4);
    fill(px, w, h); [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4]; free(px);
    res_add(t); res_commit(); return t;
}
static uint8_t g_flat[4];
static void fill_flat(uint8_t *px, int w, int h) { for (size_t i = 0; i < (size_t)w * h; i++) memcpy(px + 4 * i, g_flat, 4); }
static void fill_quads(uint8_t *px, int w, int h) {   // red | green over blue | yellow
    static const uint8_t c[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}};
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) memcpy(px + 4 * ((size_t)y * w + x), c[(x >= w / 2) + 2 * (y >= h / 2)], 4);
}
static void fill_noise(uint8_t *px, int w, int h) {   // every channel in 16..239: a black output pixel can only be a broken one
    uint32_t s = 12345; for (size_t i = 0; i < (size_t)w * h * 4; i++) { s = s * 1664525u + 1013904223u; px[i] = (i & 3) == 3 ? 255 : (uint8_t)(16 + (s >> 24) % 224); }
}
static void fill_detail(uint8_t *px, int w, int h) {   // fine detail: 1-4 px bars, a slanted edge, rings, small glyph-like blocks on grey
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float u = (float)x / w, v = (float)y / h; int g = 128;
        if (u < 0.25f) g = ((x / (1 + (y * 4 / h))) & 1) ? 230 : 25;   // vertical bars, 1 to 4 px wide by band
        else if (u < 0.5f) g = (x - 0.25f * w) * 0.2f + y * 0.98f < 0.5f * h ? 30 : 220;   // slanted edge, about 11 degrees off vertical
        else if (u < 0.75f) { float dx = x - 0.625f * w, dy = y - 0.5f * h; g = ((int)(sqrtf(dx * dx + dy * dy) / 3) & 1) ? 210 : 40; }   // rings, 3 px period
        else if (((x / 6) + (y / 9)) % 3 == 0 && (x % 6) < 4 && (y % 9) < 7) g = 20;   // a page of small dark glyphs
        else g = 200;
        (void)v; uint8_t *p = px + 4 * ((size_t)y * w + x); p[0] = p[1] = p[2] = (uint8_t)g; p[3] = 255;
    }
}
static id<MTLTexture> make_dst(int w, int h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); res_commit(); return t;
}
// The live present (Metal 4 command buffer, ring slot `slot`); returns the command buffer's GPU time in ms
static double render_m4(id<MTLTexture> src, id<MTLTexture> dst, int slot, const int crop[4]) {
    [g_present_alloc4[slot] reset];
    id<MTL4CommandBuffer> cb = g_present_cb[slot];
    [cb beginCommandBufferWithAllocator:g_present_alloc4[slot]];
    int ok = present_encode_m4(cb, src, dst, crop, slot); (void)ok;
    [cb endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block double ms = 0;
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { if (f.error) fprintf(stderr, "GPU error %s\n", f.error.description.UTF8String); ms = (f.GPUEndTime - f.GPUStartTime) * 1e3; dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> bufs[] = {cb}; [g_q4 commit:bufs count:1 options:o];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return ms;
}
static void render_legacy(id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; present_encode(cb, src, dst, NULL); [cb commit]; [cb waitUntilCompleted];
}
static uint8_t *read_back(id<MTLTexture> t) {
    size_t w = t.width, h = t.height; uint8_t *o = malloc(w * h * 4);
    [t getBytes:o bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0]; return o;
}
static uint8_t *present(id<MTLTexture> src, int dw, int dh, int sharp, const int crop[4]) {
    id<MTLTexture> dst = make_dst(dw, dh); mtl_upscale_set(sharp, UP_SHARP_DEFAULT); render_m4(src, dst, 0, crop); return read_back(dst);
}
static const uint8_t *px_at(const uint8_t *img, int w, int x, int y) { return img + 4 * ((size_t)y * w + x); }   // BGRA
static double grad_energy(const uint8_t *img, int w, int x0, int y0, int x1, int y1) {   // mean squared luma gradient (both axes): a softer edge spreads the same step over more pixels and scores lower
    double s = 0; long n = 0;
    for (int y = y0; y < y1 - 1; y++) for (int x = x0; x < x1 - 1; x++) {
        const uint8_t *p = px_at(img, w, x, y), *r = px_at(img, w, x + 1, y), *d = px_at(img, w, x, y + 1);
        double gx = r[1] - p[1], gy = d[1] - p[1]; s += gx * gx + gy * gy; n++;
    }
    return s / n;
}
static double mean_g(const uint8_t *img, int w, int x0, int y0, int x1, int y1) { double s = 0; for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) s += px_at(img, w, x, y)[1]; return s / ((double)(x1 - x0) * (y1 - y0)); }
static void save_png(const uint8_t *bgra, int w, int h, const char *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cx = CGBitmapContextCreate((void *)bgra, w, h, 8, (size_t)w * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef im = CGBitmapContextCreateImage(cx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, im, NULL); CGImageDestinationFinalize(dst);
    CFRelease(dst); CFRelease(url); CGImageRelease(im); CGContextRelease(cx); CGColorSpaceRelease(cs);
}

static void frame_ab(const char *in, const char *out) {   // a real captured frame through the real present, bilinear and sharp, ambient bars on
    CGImageSourceRef is = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(in)], NULL); CGImageRef im = is ? CGImageSourceCreateImageAtIndex(is, 0, NULL) : NULL;
    if (!im) { fprintf(stderr, "FAIL cannot read %s\n", in); failed++; if (is) CFRelease(is); return; }
    int w = (int)CGImageGetWidth(im), h = (int)CGImageGetHeight(im), dw = 2360, dh = 1640; const char *sz = getenv("DM_SCALE_SIZE"); if (sz) sscanf(sz, "%dx%d", &dw, &dh);
    uint8_t *px = calloc((size_t)w * h, 4); CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cx = CGBitmapContextCreate(px, w, h, 8, (size_t)w * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big); CGContextDrawImage(cx, CGRectMake(0, 0, w, h), im);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO]; d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [g_dev newTextureWithDescriptor:d]; [src replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4]; res_add(src); res_commit();
    for (int m = 0; m < 2; m++) { uint8_t *a = present(src, dw, dh, m, NULL); char p[1024]; snprintf(p, sizeof p, "%s/frame_%s.png", out, m ? "sharp" : "bilinear"); save_png(a, dw, dh, p); printf("wrote %s\n", p); free(a); }
    CGContextRelease(cx); CGColorSpaceRelease(cs); CGImageRelease(im); CFRelease(is); free(px);
}
enum { DW = 2752, DH = 2064, PH = 1548, Y0 = (DH - PH) / 2 };   // a 13-inch iPad's panel; 1920x1080 lands in 2752x1548, 258 rows of bars above and below
static void check_viewport_and_flat(void) {
    static const uint8_t cols[][4] = {{255, 255, 255, 255}, {0, 0, 0, 255}, {128, 128, 128, 255}, {255, 0, 0, 255}, {7, 200, 90, 255}};
    mtl_letterbox_set(0); char n[200];
    for (int c = 0; c < 5; c++) {
        memcpy(g_flat, cols[c], 4); id<MTLTexture> src = make_src(1920, 1080, fill_flat); uint8_t *a = present(src, DW, DH, 1, NULL);
        long bad = 0, bar = 0; int fx = -1, fy = -1, fv[3] = {0};
        for (int y = 0; y < DH; y++) for (int x = 0; x < DW; x++) {
            const uint8_t *p = px_at(a, DW, x, y);
            if (y < Y0 || y >= Y0 + PH) bar += p[0] | p[1] | p[2]; else if (p[2] != cols[c][0] || p[1] != cols[c][1] || p[0] != cols[c][2]) { if (!bad++) { fx = x; fy = y; fv[0] = p[2]; fv[1] = p[1]; fv[2] = p[0]; } }
        }
        snprintf(n, sizeof n, "flat %d,%d,%d: every picture pixel exact (%ld off, first at %d,%d: %d,%d,%d) and the bars exact black (%ld)", cols[c][0], cols[c][1], cols[c][2], bad, fx, fy, fv[0], fv[1], fv[2], bar); CHECK(n, bad == 0 && bar == 0);
        free(a);
    }
    { memcpy(g_flat, cols[0], 4); id<MTLTexture> src = make_src(1920, 1080, fill_flat); uint8_t *a = present(src, DW, DH, 0, NULL); long off = 0;   // 1920 * 2752 / 1920 lands a hair over 2752: the viewport once started at x = -1
      for (int y = Y0; y < Y0 + PH; y++) off += px_at(a, DW, DW - 1, y)[1] != 255 || px_at(a, DW, 0, y)[1] != 255;
      snprintf(n, sizeof n, "bilinear too covers the first and the last column of the picture (%ld off)", off); CHECK(n, off == 0); free(a); }
    snprintf(n, sizeof n, "the sharp target is the picture's viewport (%lux%lu)", (unsigned long)g_up_tmp.width, (unsigned long)g_up_tmp.height); CHECK(n, g_up_tmp.width == DW && g_up_tmp.height == PH);
    mtl_letterbox_set(1);
}
static void check_sharper(const char *out) {
    id<MTLTexture> src = make_src(1920, 1080, fill_detail); uint8_t *b = present(src, DW, DH, 0, NULL), *s = present(src, DW, DH, 1, NULL); char n[200];
    double eb = grad_energy(b, DW, 0, Y0, DW, Y0 + PH), es = grad_energy(s, DW, 0, Y0, DW, Y0 + PH), mb = mean_g(b, DW, 0, Y0, DW, Y0 + PH), ms = mean_g(s, DW, 0, Y0, DW, Y0 + PH);
    snprintf(n, sizeof n, "detail pattern: sharp has %.2fx the edge energy of bilinear (%.0f vs %.0f)", es / eb, es, eb); CHECK(n, es > 1.3 * eb);
    for (int q = 0; q < 4; q++) {   // each kind of detail on its own
        int x0 = q * DW / 4 + 8, x1 = (q + 1) * DW / 4 - 8; double r = grad_energy(s, DW, x0, Y0 + 8, x1, Y0 + PH - 8) / grad_energy(b, DW, x0, Y0 + 8, x1, Y0 + PH - 8);
        snprintf(n, sizeof n, "detail pattern, quarter %d: sharper than bilinear (%.2fx)", q, r); CHECK(n, r > 1.1);
    }
    snprintf(n, sizeof n, "detail pattern: the picture keeps its mean (%.2f vs %.2f)", ms, mb); CHECK(n, fabs(ms - mb) < 1.5);
    if (out && *out) { char p[1024]; snprintf(p, sizeof p, "%s/scale_bilinear.png", out); save_png(b, DW, DH, p); snprintf(p, sizeof p, "%s/scale_sharp.png", out); save_png(s, DW, DH, p); printf("wrote %s/scale_{bilinear,sharp}.png\n", out); }
    free(b); free(s);
}
static void check_noise(void) {
    id<MTLTexture> src = make_src(1920, 1080, fill_noise); uint8_t *b = present(src, DW, DH, 0, NULL), *s = present(src, DW, DH, 1, NULL); long black = 0; char n[200];
    for (int y = Y0; y < Y0 + PH; y++) for (int x = 0; x < DW; x++) { const uint8_t *p = px_at(s, DW, x, y); black += !(p[0] | p[1] | p[2]); }
    double mb = mean_g(b, DW, 0, Y0, DW, Y0 + PH), ms = mean_g(s, DW, 0, Y0, DW, Y0 + PH);
    snprintf(n, sizeof n, "noise: no black pixel in the sharp picture (%ld) and the mean holds (%.2f vs %.2f)", black, ms, mb); CHECK(n, black == 0 && fabs(ms - mb) < 1.5);
    free(b); free(s);
}
static void check_fallback(void) {   // nothing to enlarge: bit-identical to bilinear
    id<MTLTexture> src = make_src(1280, 720, fill_detail); char n[200];
    static const int sz[][2] = {{1280, 720}, {800, 600}};
    for (int i = 0; i < 2; i++) {
        uint8_t *b = present(src, sz[i][0], sz[i][1], 0, NULL), *s = present(src, sz[i][0], sz[i][1], 1, NULL);
        snprintf(n, sizeof n, "%dx%d from 1280x720: sharp mode stays bilinear", sz[i][0], sz[i][1]); CHECK(n, !memcmp(b, s, (size_t)sz[i][0] * sz[i][1] * 4));
        free(b); free(s);
    }
}
static void check_orientation(void) {   // quadrant centres (flat areas) agree with bilinear under a crop and under the bottom-up origin
    id<MTLTexture> src = make_src(1280, 720, fill_quads); char n[200];
    static const int crops[][4] = {{0, 0, 0, 0}, {100, 60, 1000, 600}};
    for (int f = 0; f < 2; f++) for (int c = 0; c < 2; c++) {
        mtl_set_origin_lower_left(f); mtl_letterbox_set(0);
        uint8_t *b = present(src, DW, DH, 0, crops[c]), *s = present(src, DW, DH, 1, crops[c]); int bad = 0;
        for (int q = 0; q < 4; q++) { int x = DW / 4 + (q & 1) * DW / 2, y = Y0 + PH / 4 + (q >> 1) * PH / 2; bad += memcmp(px_at(b, DW, x, y), px_at(s, DW, x, y), 4) != 0; }
        snprintf(n, sizeof n, "orientation, %s origin, %s: all four quadrants where bilinear puts them", f ? "lower-left" : "upper-left", c ? "crop 100,60 1000x600" : "whole frame"); CHECK(n, bad == 0);
        free(b); free(s);
    }
    mtl_set_origin_lower_left(0); mtl_letterbox_set(1);
}
static void check_screenshot_path(void) {   // ambient bars on: the old command buffer path (whole-window screenshot, DM_NVN_SHOT_OUT) draws what the screen shows
    id<MTLTexture> src = make_src(1920, 1080, fill_detail), d1 = make_dst(DW, DH), d2 = make_dst(DW, DH); char n[200];
    mtl_upscale_set(1, UP_SHARP_DEFAULT); render_m4(src, d1, 1, NULL); render_legacy(src, d2);
    uint8_t *a = read_back(d1), *l = read_back(d2); int md = 0; for (size_t i = 0; i < (size_t)DW * DH * 4; i++) md = MAX(md, abs((int)a[i] - (int)l[i]));
    snprintf(n, sizeof n, "the screenshot path matches the live sharp present (max channel difference %d)", md); CHECK(n, md <= 2);
    free(a); free(l);
}
static void check_resize(void) {
    id<MTLTexture> src = make_src(640, 360, fill_quads); mtl_upscale_set(1, UP_SHARP_DEFAULT);
    render_m4(src, make_dst(1376, 1032), 0, NULL); id<MTLTexture> t0 = g_up_tmp;
    render_m4(src, make_dst(1376, 1032), 1, NULL); int reuse = g_up_tmp == t0;
    render_m4(src, make_dst(1032, 1376), 2, NULL); int re = g_up_tmp != t0 && g_up_tmp.width == 1032 && g_up_tmp.height == 581;
    CHECK("resize: the same size reuses the target, rotation reallocates it at the new viewport", reuse && re);
}
// Same method as t_present_ambient's timing: bilinear and sharp presents interleaved one frame at a time in many short batches, order flipped every round, each keeping its minimum
// (a shared Mac: other jobs' GPU slices spoil the batches they land in, the minimum is the cost of the passes themselves). The cost is the difference of the whole present command buffers' GPU times.
// Budget: EASU is ALU-bound on Apple GPUs (a threadgroup-tiled compute version that reads each texel once measured only 6% faster); on an Apple silicon Mac (10-core GPU) the sharp path costs 1.1 to 1.5 ms
// at this size (more from a 720p source than from 1080p), the same as the MetalFX spatial scaler (1.0 to 2.1 ms for 1920x1080 to 2752x1548 alone). 2.0 ms (12% of a 60 Hz frame) leaves headroom over the 1.55 ms seen, so a shared GPU does not flake it; a 2360x1640 panel has 26% fewer pixels.
#define UP_BUDGET_MS 2.0
static void timing(int dw, int dh, int sw, int sh) {
    enum { ROUNDS = 300, BATCH = 2 };
    id<MTLTexture> src = make_src(sw, sh, fill_detail), dst = make_dst(dw, dh);
    double best[2], cost = 1e9; int timed = 0;
    for (int attempt = 0; attempt < 3 && cost >= UP_BUDGET_MS; attempt++) {   // up to 3 attempts to catch a quiet GPU
        timed = 0;
        for (int mode = 0; mode < 2; mode++) { mtl_upscale_set(mode, UP_SHARP_DEFAULT); for (int i = 0; i < 30; i++) render_m4(src, dst, i % 3, NULL); best[mode] = 1e9; }   // warm up both
        for (int r = 0; r < ROUNDS; r++) for (int j = 0; j < 2; j++) {
            int mode = (j + r) & 1; mtl_upscale_set(mode, UP_SHARP_DEFAULT);
            for (int i = 0; i < BATCH; i++) { double ms = render_m4(src, dst, i % 3, NULL); if (ms > 0) { timed += mode; if (ms < best[mode]) best[mode] = ms; } }
        }
        cost = best[1] - best[0];
    }
    printf("GPU time %dx%d drawable, %dx%d source (best of %d interleaved batches each): present %.3f ms sharp versus %.3f ms bilinear: sharp costs %.3f ms per frame\n", dw, dh, sw, sh, ROUNDS, best[1], best[0], cost);
    char nm[200]; snprintf(nm, sizeof nm, "GPU cost of the sharp upscale at %dx%d from %dx%d is under %.1f ms (%.3f ms)", dw, dh, sw, sh, UP_BUDGET_MS, cost);
    CHECK(nm, timed == ROUNDS * BATCH && cost < UP_BUDGET_MS);
}
int main(void) { @autoreleasepool {
    mtl_init();
    check_viewport_and_flat();
    check_sharper(getenv("DM_SCALE_OUT"));
    check_noise();
    check_fallback();
    check_orientation();
    check_screenshot_path();
    check_resize();
    timing(DW, DH, 1920, 1080);
    timing(DW, DH, 1280, 720);
    const char *fin = getenv("DM_SCALE_IN"), *fout = getenv("DM_SCALE_OUT"); if (fin && *fin && fout && *fout) frame_ab(fin, fout);
    printf("t_present_scale: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
