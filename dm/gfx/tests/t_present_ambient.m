// Ambient letterbox fill (nvn_ambient.h): real Metal rendering of synthetic frames (flat colour quadrants for closed-form checks, a generated scene for screenshots), no game artwork.
// Checks: the picture is exact and the bars carry the darkened, blurred colours of the nearest part of the frame; black mode leaves exact zeros; the Metal 4 present and the legacy screenshot path agree;
// pillarboxing; resize / rotation reallocates the slot's targets once and steady frames reuse them; and the GPU cost of the blur passes (DM_NVN_PASSGPU-style timestamps) stays under the budget.
// DM_AMB_OUT=<dir> also writes before / after PNGs (black bars versus ambient) of the generated scene at 2752x2064 (a 13-inch iPad) and 1376x1032.
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
static void fill_quads(uint8_t *px, int w, int h) {   // red | green over blue | yellow
    static const uint8_t c[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}};
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) memcpy(px + 4 * ((size_t)y * w + x), c[(x >= w / 2) + 2 * (y >= h / 2)], 4);
}
static float smooth(float a, float b, float x) { float t = fminf(fmaxf((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t); }
static void fill_scene(uint8_t *px, int w, int h) {   // generated: sky gradient, sun, hills, a red roof, a white HUD bar
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float u = (float)x / w, v = (float)y / h, r, g, b;
        r = 0.10f + 0.9f * smooth(0, 0.75f, v); g = 0.25f + 0.30f * smooth(0, 0.75f, v); b = 0.75f - 0.55f * smooth(0, 0.75f, v);
        float sd = hypotf((u - 0.72f) * 16 / 9, v - 0.28f); float sun = 1 - smooth(0.07f, 0.09f, sd); r += (1 - r) * sun; g += (0.95f - g) * sun; b += (0.6f - b) * sun;
        float hill = 0.62f + 0.06f * sinf(u * 9) + 0.04f * sinf(u * 21 + 1);
        if (v > hill) { float k = (v - hill) / (1 - hill); r = 0.10f + 0.1f * k; g = 0.55f - 0.30f * k; b = 0.15f; }
        if (u > 0.12f && u < 0.30f && v > 0.50f && v < 0.66f) { r = 0.75f; g = 0.15f; b = 0.12f; }
        if (u > 0.05f && u < 0.35f && v > 0.90f && v < 0.95f) { r = g = b = 0.95f; }
        uint8_t *p = px + 4 * ((size_t)y * w + x);
        p[0] = (uint8_t)(fminf(r, 1) * 255 + 0.5f); p[1] = (uint8_t)(fminf(g, 1) * 255 + 0.5f); p[2] = (uint8_t)(fminf(b, 1) * 255 + 0.5f); p[3] = 255;
    }
}
static id<MTLTexture> make_dst(int w, int h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); res_commit(); return t;
}
// The live present: Metal 4 command buffer, ring slot `slot`, the feedback handler the real present_now has (amb_feedback)
static void render_m4(id<MTLTexture> src, id<MTLTexture> dst, int slot) {
    [g_present_alloc4[slot] reset];
    id<MTL4CommandBuffer> cb = g_present_cb[slot];
    [cb beginCommandBufferWithAllocator:g_present_alloc4[slot]];
    int ok = present_encode_m4(cb, src, dst, NULL, slot); (void)ok;
    [cb endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { if (f.error) fprintf(stderr, "GPU error %s\n", f.error.description.UTF8String); amb_feedback(slot); dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> bufs[] = {cb}; [g_q4 commit:bufs count:1 options:o];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}
static void render_legacy(id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; present_encode(cb, src, dst, NULL); [cb commit]; [cb waitUntilCompleted];
}
static uint8_t *read_back(id<MTLTexture> t) {
    size_t w = t.width, h = t.height; uint8_t *o = malloc(w * h * 4);
    [t getBytes:o bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0]; return o;
}
// BGRA bytes: p[0] = B, p[1] = G, p[2] = R
static const uint8_t *px_at(const uint8_t *img, int w, int x, int y) { return img + 4 * ((size_t)y * w + x); }
static void save_png(const uint8_t *bgra, int w, int h, const char *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cx = CGBitmapContextCreate((void *)bgra, w, h, 8, (size_t)w * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef im = CGBitmapContextCreateImage(cx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, im, NULL); CGImageDestinationFinalize(dst);
    CFRelease(dst); CFRelease(url); CGImageRelease(im); CGContextRelease(cx); CGColorSpaceRelease(cs);
}

static void check_quads(int dw, int dh, const char *tag) {
    id<MTLTexture> src = make_src(1280, 720, fill_quads), dst = make_dst(dw, dh); char n[160];
    mtl_letterbox_set(1); render_m4(src, dst, 0); uint8_t *a = read_back(dst);
    int ph = (int)round(dw * 720.0 / 1280), y0 = (dh - ph) / 2;   // the 16:9 picture's rows
    const uint8_t *c = px_at(a, dw, dw / 4, y0 + ph / 4);
    snprintf(n, sizeof n, "%s: picture is exact (red quadrant)", tag); CHECK(n, c[2] == 255 && c[1] == 0 && c[0] == 0);
    c = px_at(a, dw, dw * 3 / 4, y0 + ph * 3 / 4);
    snprintf(n, sizeof n, "%s: picture is exact (yellow quadrant)", tag); CHECK(n, c[2] == 255 && c[1] == 255 && c[0] == 0);
    const uint8_t *tl = px_at(a, dw, dw * 15 / 100, y0 / 3), *tr = px_at(a, dw, dw * 85 / 100, y0 / 3), *bl = px_at(a, dw, dw * 15 / 100, dh - y0 / 3), *br = px_at(a, dw, dw * 85 / 100, dh - y0 / 3);
    snprintf(n, sizeof n, "%s: top bar left is red, darkened about 50%% and slightly desaturated (r %d g %d b %d)", tag, tl[2], tl[1], tl[0]); CHECK(n, tl[2] >= 100 && tl[2] <= 128 && tl[1] >= 4 && tl[1] <= 24 && tl[0] >= 4 && tl[0] <= 24);
    snprintf(n, sizeof n, "%s: top bar right is green (g %d)", tag, tr[1]); CHECK(n, tr[1] >= 100 && tr[1] <= 128 && tr[2] < 24 && tr[0] < 24);
    snprintf(n, sizeof n, "%s: bottom bar left is blue (b %d)", tag, bl[0]); CHECK(n, bl[0] >= 100 && bl[0] <= 128 && bl[2] < 24 && bl[1] < 24);
    snprintf(n, sizeof n, "%s: bottom bar right is yellow (r %d g %d b %d)", tag, br[2], br[1], br[0]); CHECK(n, br[2] >= 100 && br[1] >= 100 && br[0] < 24);
    long zero = 0; for (int y = 0; y < dh; y++) if (y < y0 || y >= y0 + ph) for (int x = 0; x < dw; x++) { const uint8_t *p = px_at(a, dw, x, y); zero += !(p[0] | p[1] | p[2]); }
    snprintf(n, sizeof n, "%s: no black pixel in either bar (%ld)", tag, zero); CHECK(n, zero == 0);
    // the edge shadow: the bar row touching the picture is darker than the same bar well away from it
    const uint8_t *edge = px_at(a, dw, dw * 15 / 100, y0 - 1), *far = px_at(a, dw, dw * 15 / 100, y0 / 3);
    snprintf(n, sizeof n, "%s: soft shadow at the picture edge (%d < %d)", tag, edge[2], far[2]); CHECK(n, edge[2] + 15 < far[2]);
    uint8_t *l = NULL; { id<MTLTexture> d2 = make_dst(dw, dh); render_legacy(src, d2); l = read_back(d2); }
    int md = 0; for (size_t i = 0; i < (size_t)dw * dh * 4; i++) md = MAX(md, abs((int)a[i] - (int)l[i]));
    snprintf(n, sizeof n, "%s: the screenshot path matches the live present (max channel difference %d)", tag, md); CHECK(n, md <= 2);
    mtl_letterbox_set(0); render_m4(src, dst, 1); uint8_t *k = read_back(dst);
    zero = 0; for (int y = 0; y < dh; y++) if (y < y0 || y >= y0 + ph) for (int x = 0; x < dw; x++) { const uint8_t *p = px_at(k, dw, x, y); zero += !!(p[0] | p[1] | p[2]); }
    snprintf(n, sizeof n, "%s: letterbox=black leaves exact black bars (%ld non-black)", tag, zero); CHECK(n, zero == 0);
    c = px_at(k, dw, dw / 4, y0 + ph / 4); snprintf(n, sizeof n, "%s: letterbox=black picture unchanged", tag); CHECK(n, c[2] == 255 && c[1] == 0 && c[0] == 0);
    free(a); free(l); free(k);
}
static void check_pillar(void) {   // a taller-than-screen game: 9:16 into 4:3 gives left and right bars
    int dw = 1376, dh = 1032, pw = (int)round(dh * 720.0 / 1280), x0 = (dw - pw) / 2;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:720 height:1280 mipmapped:NO]; d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [g_dev newTextureWithDescriptor:d]; uint8_t *px = malloc(720 * 1280 * 4); fill_quads(px, 720, 1280);
    [src replaceRegion:MTLRegionMake2D(0, 0, 720, 1280) mipmapLevel:0 withBytes:px bytesPerRow:720 * 4]; free(px); res_add(src); res_commit();
    id<MTLTexture> dst = make_dst(dw, dh); mtl_letterbox_set(1); render_m4(src, dst, 2); uint8_t *a = read_back(dst);
    const uint8_t *lt = px_at(a, dw, x0 / 3, dh / 4), *rb = px_at(a, dw, dw - x0 / 3, dh * 3 / 4), *c = px_at(a, dw, dw / 2 - 50, dh / 4);
    char n[160];
    snprintf(n, sizeof n, "pillarbox: left bar top is red (r %d g %d), right bar bottom is yellow (r %d g %d b %d)", lt[2], lt[1], rb[2], rb[1], rb[0]); CHECK(n, lt[2] >= 100 && lt[1] < 30 && rb[2] >= 100 && rb[1] >= 100 && rb[0] < 30);
    snprintf(n, sizeof n, "pillarbox: picture exact in the middle"); CHECK(n, c[2] == 255 && c[1] == 0 && c[0] == 0);
    long zero = 0; for (int y = 0; y < dh; y++) for (int x = 0; x < dw; x++) if (x < x0 || x >= x0 + pw) { const uint8_t *p = px_at(a, dw, x, y); zero += !(p[0] | p[1] | p[2]); }
    snprintf(n, sizeof n, "pillarbox: no black pixel in the side bars (%ld)", zero); CHECK(n, zero == 0);
    free(a);
}
static void check_resize(void) {
    id<MTLTexture> src = make_src(1280, 720, fill_quads);
    static const int sz[][2] = {{1376, 1032}, {1376, 1032}, {1032, 1376}, {800, 600}, {800, 600}};   // steady, rotate, resize
    id<MTLTexture> first = nil, a0 = nil; int reuse = 1, realloc_ = 0;
    for (int i = 0; i < 5; i++) {
        id<MTLTexture> dst = make_dst(sz[i][0], sz[i][1]); render_m4(src, dst, 0);
        if (i == 0) first = g_amb_a[0]; if (i == 1) reuse = g_amb_a[0] == first;
        if (i >= 2 && g_amb_a[0] != a0) realloc_++; a0 = g_amb_a[0];
        NSUInteger aw, ah, bw, bh; amb_sizes(sz[i][0], sz[i][1], &aw, &ah, &bw, &bh);
        if (g_amb_a[0].width != aw || g_amb_a[0].height != ah || g_amb_b[0].width != bw) reuse = 0;
    }
    CHECK("resize: the same size reuses the blur targets; every size has targets of its own proportions", reuse);
    CHECK("resize: rotation and a smaller window each reallocated once", realloc_ == 2);
}
// The Mac is shared with other jobs and the cost is the difference of two small timings, so one measurement of each is noise (the black-bar final pass alone swings 0.17 to 0.46 ms on a busy machine).
// The two variants are therefore timed interleaved, in many short batches (an ambient batch and a black batch next to each other, the order flipped every round, one frame at a time so nothing overlaps),
// and every pass keeps its minimum over all rounds: a slow patch of the machine or another job's GPU slice spoils the batches it falls in, and the minimum is the cost of the passes themselves.
static void timing(int dw, int dh, int sw, int sh) {
    enum { ROUNDS = 300, BATCH = 2 };
    id<MTLTexture> src = make_src(sw, sh, fill_scene), dst = make_dst(dw, dh);
    double best[2][3], ms[3], cost = 1e9; uint64_t n[3], timed = 0;
    for (int attempt = 0; attempt < 3 && cost >= 0.3; attempt++) {   // up to 3 attempts to catch a quiet GPU
        timed = 0;
        for (int mode = 0; mode < 2; mode++) { mtl_letterbox_set(mode); for (int i = 0; i < 30; i++) render_m4(src, dst, i % 3); for (int k = 0; k < 3; k++) best[mode][k] = 1e9; }   // warm up both (pipelines, targets, clocks)
        for (int r = 0; r < ROUNDS; r++)
            for (int j = 0; j < 2; j++) {
                int mode = (j + r) & 1;
                mtl_letterbox_set(mode); mtl_amb_stats_take(ms, n);
                for (int i = 0; i < BATCH; i++) render_m4(src, dst, i % 3);
                mtl_amb_stats_take(ms, n); if (mode) timed += n[0];
                for (int k = 0; k < 3; k++) if (ms[k] > 0 && ms[k] < best[mode][k]) best[mode][k] = ms[k];
            }
        cost = best[1][0] + best[1][1] + best[1][2] - best[0][2];
    }
    printf("GPU time %dx%d drawable, %dx%d source (best of %d interleaved batches each): blur passes %.3f + %.3f ms, final pass %.3f ms with ambient bars versus %.3f ms with black bars: ambient costs %.3f ms per frame\n", dw, dh, sw, sh, ROUNDS, best[1][0], best[1][1], best[1][2], best[0][2], cost);
    char nm[160]; snprintf(nm, sizeof nm, "GPU cost of the ambient fill at %dx%d is under 0.3 ms (%.3f ms)", dw, dh, cost); CHECK(nm, timed == ROUNDS * BATCH && cost < 0.3);
}
static void shots(const char *dir) {
    static const int sz[][2] = {{2752, 2064}, {1376, 1032}};
    id<MTLTexture> src = make_src(1920, 1080, fill_scene);
    for (int i = 0; i < 2; i++) {
        id<MTLTexture> dst = make_dst(sz[i][0], sz[i][1]); char p[1024];
        for (int m = 0; m < 2; m++) {
            mtl_letterbox_set(m); render_m4(src, dst, 0); uint8_t *a = read_back(dst);
            snprintf(p, sizeof p, "%s/present_%dx%d_%s.png", dir, sz[i][0], sz[i][1], m ? "ambient" : "black"); save_png(a, sz[i][0], sz[i][1], p); printf("wrote %s\n", p); free(a);
        }
    }
}
int main(void) { @autoreleasepool {
    mtl_init();
    CHECK("per-pass GPU timing is on", pg_on());
    check_quads(1376, 1032, "4:3 drawable, 16:9 frame");
    check_quads(1400, 875, "16:10 drawable, 16:9 frame");
    check_pillar();
    check_resize();
    timing(2752, 2064, 1920, 1080);
    timing(2752, 2064, 1280, 720);
    const char *out = getenv("DM_AMB_OUT"); if (out && *out) shots(out);
    printf("t_present_ambient: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
