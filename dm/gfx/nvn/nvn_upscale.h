// Sharp upscale for the present stage (included once by nvn_mtl.m next to nvn_ambient.h: it uses that file's statics).
// DM_UPSCALE=sharp replaces the plain bilinear stretch of the game picture with AMD FidelityFX Super Resolution 1:
//   pass 1  EASU (edge-adaptive 12-tap upscale) from the valid source rectangle into an RGBA8 target the size of the picture's viewport
//   final   inside the drawable's own pass, after the letterbox bars: RCAS (contrast-adaptive sharpening, 5 taps) from that target into the viewport
// DM_UPSCALE_SHARPNESS=0..1 is RCAS's strength (exp2(-stops) of ffx_fsr1.h: 1 = AMD's maximum, 0 = EASU alone). Only an enlargement uses it; a same-size or smaller picture stays bilinear.
// The live present keeps one target and reuses it every frame (presents run in order on one queue, each pass behind a full queue barrier); the old command buffer path (screenshots, DM_NVN_SHOT_OUT) makes one per call.
// MSL port of EASU (FsrEasuH, half precision) and RCAS (FsrRcasF) from ffx_fsr1.h v1.20210629, AMD FidelityFX Super Resolution 1, as vendored by Ryujinx (MIT); see THIRD_PARTY.md. Its notice:
//   Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction,
//   including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and / or sell copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// Differences from the reference: taps are integer reads clamped to the valid rectangle (the bilinear path's edge clamp) instead of gathers; RCAS's limiter reciprocals are guarded against a black or white ring (no inf * 0)
// and its resolve divides exactly (the medium-precision reciprocal turned a flat 255 into 254).
#define UP_SHARP_DEFAULT 0.8f

static int g_up_mode = -1;   // 1 sharp, 0 bilinear (default)
static float g_up_sharp = UP_SHARP_DEFAULT;
static int up_on(void) {
    if (g_up_mode < 0) {
        const char *e = getenv("DM_UPSCALE"), *s = getenv("DM_UPSCALE_SHARPNESS");
        g_up_mode = e && !strcmp(e, "sharp");
        if (s && *s) g_up_sharp = fminf(fmaxf(strtof(s, NULL), 0.f), 1.f);
        MLOG("upscale: %s (sharpness %.2f)%s", g_up_mode ? "sharp (FSR 1)" : "bilinear", g_up_sharp, e ? " (DM_UPSCALE)" : " (default)");
    }
    return g_up_mode;
}
void mtl_upscale_set(int sharp, float amount) { g_up_mode = sharp ? 1 : 0; g_up_sharp = fminf(fmaxf(amount, 0.f), 1.f); }   // tests and the front end; takes effect on the next present

static NSString *const k_up_msl = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V uvs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); return o; }\n"
    // EASU in half precision, as ffx_fsr1.h's FsrEasuH (the same algorithm; on an M-series GPU it takes about 20% less time than the FP32 path), positions in float
    "static half rcp_lo(half a) { return as_type<half>(ushort(0x7784u - as_type<ushort>(a))); }\n"   // APrxLoRcpH1
    "static half rsq_lo(half a) { return as_type<half>(ushort(0x59a3u - (as_type<ushort>(a) >> 1))); }\n"   // APrxLoRsqH1
    "static void easu_tap(thread half3 &ac, thread half &aw, half2 off, half2 dir, half2 len, half lob, half clp, half3 c) {\n"
    "  half2 v = half2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len;\n"
    "  half d2 = min(v.x * v.x + v.y * v.y, clp);\n"
    "  half wb = 0.4h * d2 - 1.0h, wa = lob * d2 - 1.0h; wb *= wb; wa *= wa; wb = half(25.0 / 16.0) * wb - half(25.0 / 16.0 - 1.0);\n"
    "  half w = wb * wa; ac += c * w; aw += w; }\n"
    "static void easu_set(thread half2 &dir, thread half &len, half w, half la, half lb, half lc, half ld, half le) {\n"
    "  half lx = rcp_lo(max(abs(ld - lc), abs(lc - lb))), dx = ld - lb; dir.x += dx * w; lx = saturate(abs(dx) * lx); len += lx * lx * w;\n"
    "  half ly = rcp_lo(max(abs(le - lc), abs(lc - la))), dy = le - la; dir.y += dy * w; ly = saturate(abs(dy) * ly); len += ly * ly * w; }\n"
    // map: xy = source pixels per output pixel, zw = 0.5 * xy - 0.5 + valid origin; lim: the valid rectangle's first and last texel; flip: x = 1 for a bottom-up window image, y = output height
    "struct EasuU { float4 map; float4 lim; float4 flip; };\n"
    "fragment half4 fs_easu(V in [[stage_in]], texture2d<half> t [[texture(0)]], constant EasuU& u [[buffer(0)]]) {\n"
    "  float2 ip = floor(in.p.xy); if (u.flip.x > 0.5) ip.y = u.flip.y - 1.0 - ip.y;\n"
    "  float2 pf = ip * u.map.xy + u.map.zw, fp = floor(pf); half2 pp = half2(pf - fp);\n"
    "  #define TAP(x, y) t.read(uint2(clamp(fp + float2(x, y), u.lim.xy, u.lim.zw))).rgb\n"
    "  half3 b = TAP(0, -1), c = TAP(1, -1), e = TAP(-1, 0), f = TAP(0, 0), g = TAP(1, 0), h = TAP(2, 0), i = TAP(-1, 1), j = TAP(0, 1), k = TAP(1, 1), l = TAP(2, 1), n = TAP(0, 2), o = TAP(1, 2);\n"
    "  #define LUMA(q) (q.b * 0.5h + (q.r * 0.5h + q.g))\n"
    "  half bL = LUMA(b), cL = LUMA(c), eL = LUMA(e), fL = LUMA(f), gL = LUMA(g), hL = LUMA(h), iL = LUMA(i), jL = LUMA(j), kL = LUMA(k), lL = LUMA(l), nL = LUMA(n), oL = LUMA(o);\n"
    "  half2 dir = 0; half len = 0;\n"
    "  easu_set(dir, len, (1.0h - pp.x) * (1.0h - pp.y), bL, eL, fL, gL, jL);\n"
    "  easu_set(dir, len, pp.x * (1.0h - pp.y), cL, fL, gL, hL, kL);\n"
    "  easu_set(dir, len, (1.0h - pp.x) * pp.y, fL, iL, jL, kL, nL);\n"
    "  easu_set(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);\n"
    "  half2 dir2 = dir * dir; half dirr = dir2.x + dir2.y; bool zro = dirr < half(1.0 / 32768.0);\n"
    "  dirr = zro ? 1.0h : rsq_lo(dirr); dir.x = zro ? 1.0h : dir.x; dir *= dirr;\n"
    "  len = len * 0.5h; len *= len;\n"
    "  half stretch = (dir.x * dir.x + dir.y * dir.y) * rcp_lo(max(abs(dir.x), abs(dir.y)));\n"
    "  half2 len2 = half2(1.0h + (stretch - 1.0h) * len, 1.0h - 0.5h * len);\n"
    "  half lob = 0.5h + half((1.0 / 4.0 - 0.04) - 0.5) * len, clp = rcp_lo(lob);\n"
    "  half3 mn = min(min(f, g), min(j, k)), mx = max(max(f, g), max(j, k)), ac = 0; half aw = 0;\n"
    "  easu_tap(ac, aw, half2(0, -1) - pp, dir, len2, lob, clp, b); easu_tap(ac, aw, half2(1, -1) - pp, dir, len2, lob, clp, c);\n"
    "  easu_tap(ac, aw, half2(-1, 1) - pp, dir, len2, lob, clp, i); easu_tap(ac, aw, half2(0, 1) - pp, dir, len2, lob, clp, j);\n"
    "  easu_tap(ac, aw, half2(0, 0) - pp, dir, len2, lob, clp, f); easu_tap(ac, aw, half2(-1, 0) - pp, dir, len2, lob, clp, e);\n"
    "  easu_tap(ac, aw, half2(1, 1) - pp, dir, len2, lob, clp, k); easu_tap(ac, aw, half2(2, 1) - pp, dir, len2, lob, clp, l);\n"
    "  easu_tap(ac, aw, half2(2, 0) - pp, dir, len2, lob, clp, h); easu_tap(ac, aw, half2(1, 0) - pp, dir, len2, lob, clp, g);\n"
    "  easu_tap(ac, aw, half2(1, 2) - pp, dir, len2, lob, clp, o); easu_tap(ac, aw, half2(0, 2) - pp, dir, len2, lob, clp, n);\n"
    "  return half4(min(mx, max(mn, ac / aw)), 1); }\n"
    // org: xy = the viewport's origin in the drawable, z = strength (exp2(-stops))
    "struct RcasU { float4 org; };\n"
    "fragment float4 fs_rcas(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant RcasU& u [[buffer(0)]]) {\n"
    "  int2 p = int2(floor(in.p.xy - u.org.xy)), hi = int2(t.get_width() - 1, t.get_height() - 1);\n"
    "  #define LD(x, y) t.read(uint2(clamp(p + int2(x, y), int2(0), hi))).rgb\n"
    "  float3 b = LD(0, -1), d = LD(-1, 0), e = LD(0, 0), f = LD(1, 0), h = LD(0, 1);\n"
    "  float3 mn4 = min(min(b, d), min(f, h)), mx4 = max(max(b, d), max(f, h));\n"
    "  float3 hitmin = min(mn4, e) / max(4.0 * mx4, float3(1e-5)), hitmax = (1.0 - max(mx4, e)) / min(4.0 * mn4 - 4.0, float3(-1e-5)), lobe3 = max(-hitmin, hitmax);\n"
    "  float lobe = max(-(0.25 - 1.0 / 16.0), min(max(max(lobe3.r, lobe3.g), lobe3.b), 0.0)) * u.org.z;\n"
    "  return float4((lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0), 1); }\n";

static id<MTLLibrary> g_up_lib; static id<MTLRenderPipelineState> g_up_easu, g_up_rcas; static MTLPixelFormat g_up_fmt;
static int up_pipelines(MTLPixelFormat format) {   // on the first sharp present; RCAS again for another target format. A failure logs once and falls back to bilinear
    if (g_up_rcas && g_up_fmt == format) return 1;
    NSError *e = nil;
    if (!g_up_lib) g_up_lib = [g_dev newLibraryWithSource:k_up_msl options:nil error:&e];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [g_up_lib newFunctionWithName:@"uvs"]; pd.fragmentFunction = [g_up_lib newFunctionWithName:@"fs_easu"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    if (g_up_lib && !g_up_easu) g_up_easu = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.fragmentFunction = [g_up_lib newFunctionWithName:@"fs_rcas"]; pd.colorAttachments[0].pixelFormat = format;
    id<MTLRenderPipelineState> rcas = g_up_easu ? [g_dev newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
    if (!rcas) { MLOG("[RED] sharp upscale unavailable, presenting bilinear: %s", e.localizedDescription.UTF8String); g_up_mode = 0; return 0; }
    g_up_rcas = rcas; g_up_fmt = format;
    return 1;
}

// Uniforms of both passes for one frame: EASU at 0, RCAS at 64 (the live present's buffer holds 128 bytes per ring slot)
typedef struct { float easu[12], pad[4], rcas[4]; } up_u;
static int up_fill(up_u *u, NSUInteger cx, NSUInteger cy, NSUInteger cw, NSUInteger ch, MTLViewport vp, MTLPixelFormat format) {   // 0 = stay bilinear
    if (!up_on() || vp.width < cw || vp.height < ch || (vp.width == cw && vp.height == ch) || !up_pipelines(format)) return 0;
    memset(u, 0, sizeof *u);
    float sx = (float)(cw / vp.width), sy = (float)(ch / vp.height);
    float *e = u->easu; e[0] = sx; e[1] = sy; e[2] = 0.5f * sx - 0.5f + cx; e[3] = 0.5f * sy - 0.5f + cy;
    e[4] = cx; e[5] = cy; e[6] = cx + cw - 1; e[7] = cy + ch - 1;
    e[8] = atomic_load_explicit(&g_origin_ll, memory_order_relaxed) ? 1 : 0; e[9] = (float)vp.height;   // lower-left origin: the window image is stored bottom-up
    u->rcas[0] = (float)vp.originX; u->rcas[1] = (float)vp.originY; u->rcas[2] = g_up_sharp;
    return 1;
}
static id<MTLTexture> up_target(NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    return [g_dev newTextureWithDescriptor:td];
}

// ---- Metal 4 (the live present) ----
static id<MTLTexture> g_up_tmp; static id<MTLBuffer> g_up_ub[3];
static int up_target_ready(NSUInteger w, NSUInteger h) {
    if (g_up_tmp && g_up_tmp.width == w && g_up_tmp.height == h) return 1;
    pthread_mutex_lock(&g_pq_mu); while (g_pq_inflight) pthread_cond_wait(&g_pq_cv, &g_pq_mu); pthread_mutex_unlock(&g_pq_mu);   // a new size (rotation, resized window): no queued present may still read the old one
    res_remove(g_up_tmp); g_up_tmp = up_target(w, h);
    if (!g_up_tmp) { static int once; if (!once++) MLOG("[RED] sharp upscale: cannot allocate the %lux%lu target; presenting bilinear", (unsigned long)w, (unsigned long)h); return 0; }
    res_add(g_up_tmp); res_commit();
    MLOG("sharp upscale: target %lux%lu", (unsigned long)w, (unsigned long)h);
    return 1;
}
// EASU into the shared target; returns 0 (nothing encoded) when it cannot, and the caller draws bilinear
static int up_prepare_m4(id<MTL4CommandBuffer> cb, id<MTLTexture> raw, NSUInteger cx, NSUInteger cy, NSUInteger cw, NSUInteger ch, MTLViewport vp, MTLPixelFormat format, int slot) {
    up_u u; if (!up_fill(&u, cx, cy, cw, ch, vp, format) || !up_target_ready((NSUInteger)vp.width, (NSUInteger)vp.height)) return 0;
    if (!g_up_ub[slot]) { g_up_ub[slot] = [g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared]; if (!g_up_ub[slot]) return 0; res_add(g_up_ub[slot]); res_commit(); }
    memcpy(g_up_ub[slot].contents, u.easu, sizeof u.easu); memcpy((uint8_t *)g_up_ub[slot].contents + 64, u.rcas, sizeof u.rcas);
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = g_up_tmp; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    if (!en) return 0;
    [en barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [en setArgumentTable:g_present_args atStages:MTLRenderStageFragment];
    amb_ts(en, slot, 3, 0);   // GPU time of this pass: the ambient letterbox's timing line (nvn_ambient.h amb_feedback)
    [g_present_args setTexture:raw.gpuResourceID atIndex:0]; [g_present_args setAddress:g_up_ub[slot].gpuAddress atIndex:0];
    [en setRenderPipelineState:g_up_easu]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    amb_ts(en, slot, 3, 1); m4_end(en);
    return 1;
}
static void up_bind_m4(int slot) { [g_present_args setTexture:g_up_tmp.gpuResourceID atIndex:0]; [g_present_args setAddress:g_up_ub[slot].gpuAddress + 64 atIndex:0]; }   // RCAS: the caller sets the viewport and g_up_rcas

// ---- Legacy command buffer (screenshots, DM_NVN_SHOT_OUT, tests): the same shaders, a target per call kept alive by the command buffer ----
static id<MTLTexture> up_prepare_legacy(id<MTLCommandBuffer> cb, id<MTLTexture> raw, NSUInteger cx, NSUInteger cy, NSUInteger cw, NSUInteger ch, MTLViewport vp, MTLPixelFormat format, up_u *u) {
    if (!up_fill(u, cx, cy, cw, ch, vp, format)) return nil;
    id<MTLTexture> t = up_target((NSUInteger)vp.width, (NSUInteger)vp.height); if (!t) return nil;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:g_up_easu]; [en setFragmentTexture:raw atIndex:0]; [en setFragmentBytes:u->easu length:sizeof u->easu atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    return t;
}
