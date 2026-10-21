// Ambient letterbox fill for the present stage (included once by nvn_mtl.m, right before present_pipeline: it uses that file's statics).
// When the game picture does not fill the drawable (16:9 on a 4:3 iPad, a taller game pillarboxed, a resized Mac window) the bars show the live frame instead of black:
//   pass 1  game frame (cover-scaled to the drawable's aspect) -> A, drawable / 8, 4 bilinear taps = a box filter over the source footprint
//   pass 2  A -> B, A / 8 (drawable / 64), 16 bilinear taps = an exact 8x8 box
//   final   inside the drawable's own pass: the bars (scissored triangle) sample B with a cubic B-spline (4 bilinear taps, smooth, no blocky texels), darken, desaturate, dither, and soften toward the picture edge; the sharp frame is drawn on top
// Targets are RGBA16F (no banding before the darkening), allocated once per ring slot and size (a new size = rotation or a resized window), never per frame.
// DM_LETTERBOX=black switches it off (the old black bars); the iOS front end maps its Info.plist key DMLetterbox onto the same variable.
// Per-pass GPU time comes from the same MTL4 counter-heap timestamps as DM_NVN_PASSGPU (pg_on): mtl_amb_stats_take, and a log line every 300 presents.
#define AMB_DIV_A 8             // A = drawable / 8
#define AMB_DIV_B 8             // B = A / 8 (drawable / 64)
#define AMB_DARK 0.50f          // multiplier on the blurred colour (darkened by 50%)
#define AMB_SAT 0.85f           // 1 = unchanged, 0 = grey
#define AMB_SHADOW 0.35f        // extra darkening right at the picture edge
#define AMB_TS 8                // timestamp slots per ring slot: A start/end, B start/end, final start/end

static id<MTLTexture> present_raw_src(id<MTLTexture> src);
static int g_amb_mode = -1;     // 1 ambient (default), 0 black
static int amb_on(void) {
    if (g_amb_mode < 0) {
        const char *e = getenv("DM_LETTERBOX");
        g_amb_mode = !(e && (!strcmp(e, "black") || !strcmp(e, "0")));
        MLOG("letterbox: %s%s", g_amb_mode ? "ambient" : "black", e ? " (DM_LETTERBOX)" : " (default)");
    }
    return g_amb_mode;
}
void mtl_letterbox_set(int ambient) { g_amb_mode = ambient ? 1 : 0; }   // for tests and the front end; takes effect on the next present
static float g_amb_dark = AMB_DARK;   // brightness of the bars' blurred colour (1 = the picture's own)
void mtl_ambient_level_set(float v) { g_amb_dark = fminf(fmaxf(v, 0.f), 1.f); }   // the iOS settings screen; takes effect on the next present

static NSString *const k_amb_msl = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V avs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct DownU { float4 rect; float4 edge; float4 tap; };\n"   // uv = in.uv * rect.zw + rect.xy, clamped to edge; taps at +-tap
    "fragment float4 afs_down(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant DownU& u [[buffer(0)]]) {\n"
    "  float2 uv = in.uv * u.rect.zw + u.rect.xy, d = u.tap.xy, lo = u.edge.xy, hi = u.edge.zw;\n"
    "  float3 c = t.sample(s, clamp(uv + float2(-d.x, -d.y), lo, hi)).rgb + t.sample(s, clamp(uv + float2(d.x, -d.y), lo, hi)).rgb\n"
    "           + t.sample(s, clamp(uv + float2(-d.x, d.y), lo, hi)).rgb + t.sample(s, clamp(uv + float2(d.x, d.y), lo, hi)).rgb;\n"
    "  return float4(c * 0.25, 1); }\n"
    "fragment float4 afs_down16(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant DownU& u [[buffer(0)]]) {\n"   // tap.xy = one source texel; taps at -3 -1 1 3 texels
    "  float2 uv = in.uv * u.rect.zw + u.rect.xy, d = u.tap.xy; float3 c = 0;\n"
    "  for (int j = -3; j <= 3; j += 2) for (int i = -3; i <= 3; i += 2) c += t.sample(s, clamp(uv + float2(i, j) * d, u.edge.xy, u.edge.zw)).rgb;\n"
    "  return float4(c * (1.0 / 16.0), 1); }\n"
    "struct BarU { float4 frame; float4 size; float4 grade; float4 tap; };\n"   // frame x0 y0 x1 y1 in drawable pixels; size w h 1/w 1/h; grade dark sat shadow shadow-radius-px; tap = B size w h 1/w 1/h
    "fragment float4 afs_bar(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant BarU& u [[buffer(0)]]) {\n"
    "  float2 sz = u.tap.xy, p = (in.p.xy * u.size.zw) * sz - 0.5, i = floor(p), f = p - i;\n"   // cubic B-spline through four bilinear fetches (GPU Gems 2, ch. 20)
    "  float2 w0 = (1 - f) * (1 - f) * (1 - f) / 6, w1 = (3 * f * f * f - 6 * f * f + 4) / 6, w2 = (-3 * f * f * f + 3 * f * f + 3 * f + 1) / 6, w3 = f * f * f / 6;\n"
    "  float2 g0 = w0 + w1, g1 = w2 + w3, h0 = (i - 1 + w1 / g0 + 0.5) * u.tap.zw, h1 = (i + 1 + w3 / g1 + 0.5) * u.tap.zw;\n"
    "  float3 c = g0.y * (g0.x * t.sample(s, float2(h0.x, h0.y)).rgb + g1.x * t.sample(s, float2(h1.x, h0.y)).rgb) + g1.y * (g0.x * t.sample(s, float2(h0.x, h1.y)).rgb + g1.x * t.sample(s, float2(h1.x, h1.y)).rgb);\n"
    "  c = mix(float3(dot(c, float3(0.299, 0.587, 0.114))), c, u.grade.y) * u.grade.x;\n"
    "  float2 e = max(max(u.frame.xy - in.p.xy, in.p.xy - u.frame.zw), 0.0);\n"
    "  float fe = 1.0 - smoothstep(0.0, u.grade.w, length(e));\n"
    "  c *= 1.0 - u.grade.z * fe * fe;\n"
    "  c += (fract(52.9829189 * fract(dot(in.p.xy, float2(0.06711056, 0.00583715)))) - 0.5) / 255.0;\n"   // dither: the dark gradient would band in 8 bits
    "  return float4(c, 1); }\n";

static id<MTLRenderPipelineState> g_amb_down, g_amb_down16, g_amb_bar; static MTLPixelFormat g_amb_fmt;
static void amb_pipelines(MTLPixelFormat format) {   // present_pipeline calls this on the first present, before the drawable is taken
    if (g_amb_down && g_amb_fmt == format) return;
    NSError *e = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:k_amb_msl options:nil error:&e];
    if (!lib) MDIE("ambient letterbox shader compile failed %s", e.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"avs"]; pd.fragmentFunction = [lib newFunctionWithName:@"afs_down"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    g_amb_down = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!g_amb_down) MDIE("ambient downsample pipeline failed %s", e.localizedDescription.UTF8String);
    pd.fragmentFunction = [lib newFunctionWithName:@"afs_down16"];
    g_amb_down16 = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!g_amb_down16) MDIE("ambient second downsample pipeline failed %s", e.localizedDescription.UTF8String);
    pd.fragmentFunction = [lib newFunctionWithName:@"afs_bar"]; pd.colorAttachments[0].pixelFormat = format;
    g_amb_bar = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!g_amb_bar) MDIE("ambient bar pipeline failed %s", e.localizedDescription.UTF8String);
    g_amb_fmt = format;
}

// Everything one frame needs, computed on the CPU from the source rectangle, the drawable and the picture viewport
typedef struct { float down1[12], down2[12], bar[16]; MTLScissorRect sc[4]; int nsc; NSUInteger aw, ah, bw, bh; } amb_u;
static void amb_sizes(NSUInteger dw, NSUInteger dh, NSUInteger *aw, NSUInteger *ah, NSUInteger *bw, NSUInteger *bh) {
    *aw = MAX((NSUInteger)8, (dw + AMB_DIV_A / 2) / AMB_DIV_A); *ah = MAX((NSUInteger)8, (dh + AMB_DIV_A / 2) / AMB_DIV_A);
    *bw = MAX((NSUInteger)4, *aw / AMB_DIV_B); *bh = MAX((NSUInteger)4, *ah / AMB_DIV_B);
}
static void amb_fill(amb_u *u, NSUInteger srcW, NSUInteger srcH, NSUInteger cx, NSUInteger cy, NSUInteger cw, NSUInteger ch, int origin_ll, NSUInteger dw, NSUInteger dh, MTLViewport vp) {
    memset(u, 0, sizeof *u);
    amb_sizes(dw, dh, &u->aw, &u->ah, &u->bw, &u->bh);
    // cover: the source rectangle scaled until it fills the drawable, the overhang cropped equally on both sides
    double sc = fmax((double)dw / cw, (double)dh / ch), vw = dw / sc, vh = dh / sc, ox = cx + (cw - vw) / 2, oy = cy + (ch - vh) / 2;
    float *d = u->down1;
    d[0] = (float)(ox / srcW); d[1] = (float)(oy / srcH); d[2] = (float)(vw / srcW); d[3] = (float)(vh / srcH);
    if (origin_ll) { d[1] += d[3]; d[3] = -d[3]; }   // lower-left origin: the window image is stored bottom-up
    d[4] = (cx + 0.5f) / srcW; d[5] = (cy + 0.5f) / srcH; d[6] = (cx + cw - 0.5f) / srcW; d[7] = (cy + ch - 0.5f) / srcH;
    d[8] = (float)(vw / u->aw / 4 / srcW); d[9] = (float)(vh / u->ah / 4 / srcH);   // a quarter of one A texel's footprint in the source: four bilinear taps tile it
    d = u->down2;
    d[0] = 0; d[1] = 0; d[2] = 1; d[3] = 1; d[4] = 0.5f / u->aw; d[5] = 0.5f / u->ah; d[6] = 1 - 0.5f / u->aw; d[7] = 1 - 0.5f / u->ah; d[8] = 1.f / u->aw; d[9] = 1.f / u->ah;   // taps at -3 -1 1 3 A texels, each averaging two: an 8x8 box
    d = u->bar;
    d[0] = (float)vp.originX; d[1] = (float)vp.originY; d[2] = (float)(vp.originX + vp.width); d[3] = (float)(vp.originY + vp.height);
    d[4] = (float)dw; d[5] = (float)dh; d[6] = 1.f / dw; d[7] = 1.f / dh;
    d[8] = g_amb_dark; d[9] = AMB_SAT; d[10] = AMB_SHADOW; d[11] = (float)fmax(12.0, 0.012 * fmin((double)dw, (double)dh));
    d[12] = (float)u->bw; d[13] = (float)u->bh; d[14] = 1.f / u->bw; d[15] = 1.f / u->bh;
    // the bars: top and bottom full width, left and right between them (together they tile everything outside the picture)
    NSUInteger x0 = (NSUInteger)vp.originX, y0 = (NSUInteger)vp.originY, x1 = MIN(dw, (NSUInteger)(vp.originX + vp.width)), y1 = MIN(dh, (NSUInteger)(vp.originY + vp.height));
    if (y0 > 0) u->sc[u->nsc++] = (MTLScissorRect){0, 0, dw, y0};
    if (y1 < dh) u->sc[u->nsc++] = (MTLScissorRect){0, y1, dw, dh - y1};
    if (x0 > 0) u->sc[u->nsc++] = (MTLScissorRect){0, y0, x0, y1 - y0};
    if (x1 < dw) u->sc[u->nsc++] = (MTLScissorRect){x1, y0, dw - x1, y1 - y0};
}

// ---- Metal 4 (the live present): per ring slot targets and uniforms, resident for the queue ----
static id<MTLTexture> g_amb_a[3], g_amb_b[3]; static NSUInteger g_amb_dw[3], g_amb_dh[3];
static id<MTLBuffer> g_amb_ub[3];
static id<MTL4CounterHeap> g_amb_heap;
static id<MTLTexture> amb_target(NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    return [g_dev newTextureWithDescriptor:td];
}
static int amb_slot_ready(int slot, NSUInteger dw, NSUInteger dh) {   // the caller has waited for this slot's previous present (g_present_alloc_fence), so nothing in flight uses the old targets
    if (g_amb_a[slot] && g_amb_dw[slot] == dw && g_amb_dh[slot] == dh) return 1;
    NSUInteger aw, ah, bw, bh; amb_sizes(dw, dh, &aw, &ah, &bw, &bh);
    res_remove(g_amb_a[slot]); res_remove(g_amb_b[slot]);
    g_amb_a[slot] = amb_target(aw, ah); g_amb_b[slot] = amb_target(bw, bh);
    if (!g_amb_ub[slot]) g_amb_ub[slot] = [g_dev newBufferWithLength:768 options:MTLResourceStorageModeShared];
    if (!g_amb_a[slot] || !g_amb_b[slot] || !g_amb_ub[slot]) { static int once; if (!once++) MLOG("[RED] ambient letterbox: cannot allocate the blur targets (%lux%lu); drawing black bars", (unsigned long)aw, (unsigned long)ah); g_amb_a[slot] = g_amb_b[slot] = nil; return 0; }
    res_add(g_amb_a[slot]); res_add(g_amb_b[slot]); res_add(g_amb_ub[slot]); res_commit();
    g_amb_dw[slot] = dw; g_amb_dh[slot] = dh;
    MLOG("ambient letterbox: blur targets for slot %d: %lux%lu then %lux%lu (drawable %lux%lu)", slot, (unsigned long)aw, (unsigned long)ah, (unsigned long)bw, (unsigned long)bh, (unsigned long)dw, (unsigned long)dh);
    return 1;
}
static id<MTL4CounterHeap> amb_heap(void) {
    if (g_amb_heap || !pg_on()) return g_amb_heap;
    MTL4CounterHeapDescriptor *d = [MTL4CounterHeapDescriptor new]; d.type = MTL4CounterHeapTypeTimestamp; d.count = 3 * AMB_TS;
    NSError *er = nil; g_amb_heap = [g_dev newCounterHeapWithDescriptor:d error:&er];
    if (!g_amb_heap) MLOG("[RED] ambient letterbox GPU timing off: cannot create the counter heap: %s", er.localizedDescription.UTF8String);
    return g_amb_heap;
}
static void amb_ts(id<MTL4RenderCommandEncoder> en, int slot, int idx, int end) {   // idx 0 = A, 1 = B, 2 = final pass
    id<MTL4CounterHeap> h = amb_heap(); if (!h) return;
    [en writeTimestampWithGranularity:MTL4TimestampGranularityRelaxed afterStage:end ? MTLRenderStageFragment : MTLRenderStageVertex intoHeap:h atIndex:(NSUInteger)(slot * AMB_TS + idx * 2 + end)];
}
static id<MTL4RenderCommandEncoder> amb_pass_m4(id<MTL4CommandBuffer> cb, id<MTLTexture> dst, int slot, int idx) {
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    if (!en) return nil;
    [en barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [en setArgumentTable:g_present_args atStages:MTLRenderStageFragment];
    amb_ts(en, slot, idx, 0);
    return en;
}
// Runs the two blur passes into the slot's targets; returns 0 (and draws nothing) when it cannot, and the caller then clears to black as before. u stays valid for amb_bars_m4
static int amb_prepare_m4(id<MTL4CommandBuffer> cb, id<MTLTexture> raw, NSUInteger cx, NSUInteger cy, NSUInteger cw, NSUInteger ch, id<MTLTexture> dst, MTLViewport vp, int slot, amb_u *u) {
    if (!g_amb_down || !amb_slot_ready(slot, dst.width, dst.height)) return 0;
    amb_fill(u, raw.width, raw.height, cx, cy, cw, ch, atomic_load_explicit(&g_origin_ll, memory_order_relaxed), dst.width, dst.height, vp);
    uint8_t *ub = g_amb_ub[slot].contents; memcpy(ub, u->down1, sizeof u->down1); memcpy(ub + 256, u->down2, sizeof u->down2); memcpy(ub + 512, u->bar, sizeof u->bar);
    id<MTL4RenderCommandEncoder> en = amb_pass_m4(cb, g_amb_a[slot], slot, 0);
    if (!en) return 0;   // nothing encoded yet: the caller's black clear stays correct
    [g_present_args setTexture:raw.gpuResourceID atIndex:0]; [g_present_args setSamplerState:g_blit_samp.gpuResourceID atIndex:0]; [g_present_args setAddress:g_amb_ub[slot].gpuAddress atIndex:0];
    [en setRenderPipelineState:g_amb_down]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    amb_ts(en, slot, 0, 1); m4_end(en);
    en = amb_pass_m4(cb, g_amb_b[slot], slot, 1);
    if (!en) return 0;
    [g_present_args setTexture:g_amb_a[slot].gpuResourceID atIndex:0]; [g_present_args setSamplerState:g_blit_samp.gpuResourceID atIndex:0]; [g_present_args setAddress:g_amb_ub[slot].gpuAddress + 256 atIndex:0];
    [en setRenderPipelineState:g_amb_down16]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    amb_ts(en, slot, 1, 1); m4_end(en);
    return 1;
}
// Inside the drawable's pass, before the picture: the bars. Leaves the scissor and the argument table for the caller's picture draw to set up again
static void amb_bars_m4(id<MTL4RenderCommandEncoder> en, int slot, const amb_u *u, NSUInteger dw, NSUInteger dh) {
    [en setViewport:(MTLViewport){0, 0, (double)dw, (double)dh, 0, 1}]; [en setRenderPipelineState:g_amb_bar];
    [g_present_args setTexture:g_amb_b[slot].gpuResourceID atIndex:0]; [g_present_args setSamplerState:g_blit_samp.gpuResourceID atIndex:0]; [g_present_args setAddress:g_amb_ub[slot].gpuAddress + 512 atIndex:0];
    for (int i = 0; i < u->nsc; i++) { [en setScissorRect:u->sc[i]]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    [en setScissorRect:(MTLScissorRect){0, 0, dw, dh}];
}

// ---- Legacy command buffer (whole-window screenshots, DM_NVN_SHOT_OUT, tests): same shaders, targets made per call, kept alive by the command buffer ----
static int amb_prepare_legacy(id<MTLCommandBuffer> cb, id<MTLTexture> raw, NSUInteger cx, NSUInteger cy, NSUInteger cw, NSUInteger ch, id<MTLTexture> dst, MTLViewport vp, amb_u *u, id<MTLTexture> __strong *bOut) {
    if (!g_amb_down || g_amb_fmt != dst.pixelFormat) return 0;
    amb_fill(u, raw.width, raw.height, cx, cy, cw, ch, atomic_load_explicit(&g_origin_ll, memory_order_relaxed), dst.width, dst.height, vp);
    id<MTLTexture> a = amb_target(u->aw, u->ah), b = amb_target(u->bw, u->bh);
    if (!a || !b) return 0;
    for (int p = 0; p < 2; p++) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = p ? b : a; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:p ? g_amb_down16 : g_amb_down]; [en setFragmentTexture:p ? a : raw atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0];
        [en setFragmentBytes:p ? u->down2 : u->down1 length:sizeof u->down1 atIndex:0];
        [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    }
    *bOut = b;
    return 1;
}
static void amb_bars_legacy(id<MTLRenderCommandEncoder> en, id<MTLTexture> b, const amb_u *u, NSUInteger dw, NSUInteger dh) {
    [en setViewport:(MTLViewport){0, 0, (double)dw, (double)dh, 0, 1}]; [en setRenderPipelineState:g_amb_bar];
    [en setFragmentTexture:b atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0]; [en setFragmentBytes:u->bar length:sizeof u->bar atIndex:0];
    for (int i = 0; i < u->nsc; i++) { [en setScissorRect:u->sc[i]]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    [en setScissorRect:(MTLScissorRect){0, 0, dw, dh}];
}

// ---- GPU time: the present command buffer's pass spans, read when it completes (present_now's feedback handler) ----
static pthread_mutex_t g_amb_mu = PTHREAD_MUTEX_INITIALIZER;
static double g_amb_sum[3], g_amb_lsum[3]; static uint64_t g_amb_n[3], g_amb_ln[3];   // per pass index: A, B, final; the l* ones are the log window, g_amb_* what mtl_amb_stats_take hands out
static void amb_feedback(int slot) {
    if (!g_amb_heap) return;
    NSRange r = NSMakeRange((NSUInteger)slot * AMB_TS, 6);
    NSData *d = [g_amb_heap resolveCounterRange:r];
    const MTL4TimestampHeapEntry *ts = d.length >= 6 * sizeof *ts ? d.bytes : NULL;
    if (!ts) return;
    double ms[3] = {0, 0, 0};
    for (int i = 0; i < 3; i++) { uint64_t a = ts[2 * i].timestamp, b = ts[2 * i + 1].timestamp; if (a && b && b >= a) ms[i] = (b - a) * g_pg_ns / 1e6; }
    [g_amb_heap invalidateCounterRange:r];
    pthread_mutex_lock(&g_amb_mu);
    for (int i = 0; i < 3; i++) if (ms[i] > 0) { g_amb_sum[i] += ms[i]; g_amb_n[i]++; g_amb_lsum[i] += ms[i]; g_amb_ln[i]++; }
    if (g_amb_ln[2] >= 300) {
        MLOG("[ambient] per present over %llu frames: blur passes %.3f + %.3f ms (%llu frames with them), final pass %.3f ms", (unsigned long long)g_amb_ln[2],
             g_amb_ln[0] ? g_amb_lsum[0] / g_amb_ln[0] : 0.0, g_amb_ln[1] ? g_amb_lsum[1] / g_amb_ln[1] : 0.0, (unsigned long long)g_amb_ln[0], g_amb_lsum[2] / g_amb_ln[2]);
        memset(g_amb_lsum, 0, sizeof g_amb_lsum); memset(g_amb_ln, 0, sizeof g_amb_ln);
    }
    pthread_mutex_unlock(&g_amb_mu);
}
// Mean per-present pass spans in ms since the last call (0 for a pass that did not run): ms[0] = first blur pass, ms[1] = second, ms[2] = the drawable's pass; n = how many frames each was timed in
void mtl_amb_stats_take(double ms[3], uint64_t n[3]) {
    pthread_mutex_lock(&g_amb_mu);
    for (int i = 0; i < 3; i++) { ms[i] = g_amb_n[i] ? g_amb_sum[i] / g_amb_n[i] : 0; n[i] = g_amb_n[i]; }
    memset(g_amb_sum, 0, sizeof g_amb_sum); memset(g_amb_n, 0, sizeof g_amb_n);
    pthread_mutex_unlock(&g_amb_mu);
}
