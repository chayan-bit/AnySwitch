// nvn_flexpso.m: a flexible pipeline (Metal 4 compiler, colour state specialized later) draws the same pixels as the classic pipeline of the same descriptor, in a Metal 4 render
// encoder as the runtime uses, with blending, a partial write mask, a second colour target and depth; the render thread never waits; one unspecialized pipeline serves every
// colour state; a pipeline the flexible path cannot make reports failure instead of pending forever
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "../nvn/nvn_flexpso.h"

#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); exit(1); } } while (0)
static const char *SRC =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float4 c; };\n"
    "struct I { float2 p [[attribute(0)]]; float4 c [[attribute(1)]]; };\n"
    "struct O { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; };\n"
    "vertex V vs(I i [[stage_in]]) { V o; o.p = float4(i.p, 0.5, 1); o.c = i.c; return o; }\n"
    "fragment O fs(V i [[stage_in]]) { return {i.c, i.c.bgra}; }\n";
enum { N = 32 };
static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static id<MTLDevice> dev; static id<MTLLibrary> lib; static id<MTL4CommandQueue> q; static id<MTLBuffer> vb;
static MTLRenderPipelineDescriptor *desc(int blend, MTLPixelFormat f1, const char *frag) {
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].bufferIndex = 0; vd.attributes[1].format = MTLVertexFormatUChar4Normalized; vd.attributes[1].offset = 8; vd.layouts[0].stride = 12;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@(frag)]; d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; d.colorAttachments[0].writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskAlpha;
    d.colorAttachments[0].blendingEnabled = blend; d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[1].pixelFormat = f1; d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    return d;
}
// Draws one triangle with ps into fresh targets (colour 0 RGBA8, colour 1 of format f1, depth), returns colour 0 and 1 as bytes
static NSData *draw(id<MTLRenderPipelineState> ps, MTLPixelFormat f1) {
    id<MTLTexture> t[2]; NSMutableData *out = [NSMutableData data];
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    for (int i = 0; i < 2; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:i ? f1 : MTLPixelFormatRGBA8Unorm width:N height:N mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        t[i] = [dev newTextureWithDescriptor:td];
        rp.colorAttachments[i].texture = t[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear; rp.colorAttachments[i].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 1); rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:N height:N mipmapped:NO]; dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
    rp.depthAttachment.texture = [dev newTextureWithDescriptor:dd]; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    id<MTL4CommandAllocator> al = [dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:al];
    id<MTL4ArgumentTable> at = [dev newArgumentTableWithDescriptor:({ MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 1; ad; }) error:nil];
    [at setAddress:vb.gpuAddress atIndex:0];
    id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:ps]; [en setArgumentTable:at atStages:MTLRenderStageVertex]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb endCommandBuffer];
    id<MTLSharedEvent> ev = [dev newSharedEvent]; id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
    [rs addAllocation:vb]; [rs commit]; [q addResidencySet:rs];
    const id<MTL4CommandBuffer> cbs[1] = {cb}; [q commit:cbs count:1]; [q signalEvent:ev value:1];
    CHECK([ev waitUntilSignaledValue:1 timeoutMS:5000], "GPU timeout");
    [q removeResidencySet:rs];
    for (int i = 0; i < 2; i++) { size_t bpr = N * (i && f1 == MTLPixelFormatRGBA16Float ? 8 : 4); NSMutableData *b = [NSMutableData dataWithLength:bpr * N];
        [t[i] getBytes:b.mutableBytes bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0]; [out appendData:b]; }
    return out;
}
// Asks until the pipeline exists; checks that no single ask waited
static id<MTLRenderPipelineState> get(int key, int ukey, MTLRenderPipelineDescriptor *d, int *asks, double *worst) {
    long k = key, u = ukey; int pending = 0; id<MTLRenderPipelineState> ps = nil;
    for (*asks = 0; !ps; (*asks)++) {
        double t0 = now_ms(); ps = flexpso_get(&k, &u, lib, lib, "test", ^{ return d; }, &pending); double t = now_ms() - t0; if (t > *worst) *worst = t;
        if (!ps && !pending) return nil;
        if (!ps) usleep(500);
        CHECK(*asks < 20000, "pipeline %d never became ready", key);
    }
    return ps;
}

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e]; CHECK(lib, "%s", e.localizedDescription.UTF8String);
    q = [dev newMTL4CommandQueue];
    struct { float x, y; uint8_t c[4]; } v[3] = {{-1, -1, {255, 0, 0, 128}}, {3, -1, {0, 255, 0, 128}}, {-1, 3, {0, 0, 255, 128}}};
    vb = [dev newBufferWithBytes:v length:sizeof v options:MTLResourceStorageModeShared];
    setenv("DM_PSO_FLEX", "1", 1); flexpso_open(dev, nil, sizeof(long), sizeof(long));
    CHECK(flexpso_on(), "DM_PSO_FLEX=1 did not turn it on");
    // Two colour states of one unspecialized pipeline: pixel-identical to the classic pipeline of each
    const struct { int blend; MTLPixelFormat f1; } cs[2] = {{1, MTLPixelFormatRGBA8Unorm}, {0, MTLPixelFormatRGBA16Float}};
    double worst = 0; int asks;
    for (int i = 0; i < 2; i++) {
        MTLRenderPipelineDescriptor *d = desc(cs[i].blend, cs[i].f1, "fs");
        id<MTLRenderPipelineState> classic = [dev newRenderPipelineStateWithDescriptor:d error:&e]; CHECK(classic, "classic: %s", e.localizedDescription.UTF8String);
        id<MTLRenderPipelineState> flex = get(i + 1, 7, d, &asks, &worst); CHECK(flex, "flexible pipeline %d failed", i);
        CHECK(i || asks > 1, "the first ask returned a pipeline: it was made on the render thread");
        CHECK([draw(classic, cs[i].f1) isEqualToData:draw(flex, cs[i].f1)], "colour state %d: flexible and classic pipelines draw different pixels", i);
    }
    flexpso_counts c = flexpso_stats();
    CHECK(c.compiled == 1 && c.specialized == 2, "one unspecialized pipeline for both colour states: compiled %llu, specialized %llu", c.compiled, c.specialized);
    CHECK(c.skipped >= 1, "no ask was answered pending");
    CHECK(worst < 5, "an ask took %.2f ms: the render thread waited", worst);
    // A function the descriptor names is not in the library: failure, not pending forever
    id<MTLLibrary> other = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 lone() { return 1; }\n" options:nil error:&e];
    MTLRenderPipelineDescriptor *bad = desc(0, MTLPixelFormatRGBA8Unorm, "fs"); bad.fragmentFunction = [other newFunctionWithName:@"lone"];
    CHECK(!get(9, 9, bad, &asks, &worst), "a pipeline with a function outside its library was made");
    flexpso_log();
    printf("FLEXPSO OK: pixel-identical to classic for 2 colour states of 1 unspecialized pipeline, worst ask %.3f ms, failure reported\n", worst);
    return 0;
}}
