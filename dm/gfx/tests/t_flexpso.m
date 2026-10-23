// nvn_flexpso.m: a flexible pipeline (Metal 4 compiler, colour state specialized later) draws the same pixels as the classic pipeline of the same descriptor, in a Metal 4 render
// encoder as the runtime uses, with blending, a partial write mask, a second colour target and depth; one unspecialized pipeline serves every colour state; a draw is never skipped:
// the first ask for a pipeline not made yet waits for the worker and returns it, counted as waited; a pipeline the flexible path cannot make reports failure instead of waiting forever.
// Background slots (nvn_bgq.h): hundreds of queued warm-up jobs keep their slot limit and leave the process's GCD workers free, so a pipeline job on a global queue starts at once
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "../nvn/nvn_flexpso.h"
#include "../nvn/nvn_bgq.h"

#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); exit(1); } } while (0)
static const char *SRC =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float4 c; };\n"
    "struct I { float2 p [[attribute(0)]]; float4 c [[attribute(1)]]; };\n"
    "struct O { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; };\n"
    "vertex V vs(I i [[stage_in]]) { V o; o.p = float4(i.p, 0.5, 1); o.c = i.c; return o; }\n"
    "fragment O fs(V i [[stage_in]]) { return {i.c, i.c.bgra}; }\n"
    "fragment O fs2(V i [[stage_in]]) { return {i.c.gbra, i.c}; }\n";
enum { N = 32 };
static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static _Atomic int g_live, g_peak;
// Background slots: 300 jobs of 2 ms on 2 slots (600 ms of work) while a job on the user-initiated global queue (where nvn_flexpso.m makes a draw's pipeline) starts within 50 ms
static void bgq_check(void) {
    nvn_bgq b; bgq_init(&b, 2, QOS_CLASS_UTILITY, "t_flexpso.bgq"); dispatch_group_t g = dispatch_group_create();
    for (int i = 0; i < 300; i++) {
        dispatch_group_enter(g);
        bgq_async(&b, ^{
            int l = atomic_fetch_add(&g_live, 1) + 1;
            for (int p = atomic_load(&g_peak); l > p && !atomic_compare_exchange_weak(&g_peak, &p, l);) {}
            usleep(2000); atomic_fetch_sub(&g_live, 1); dispatch_group_leave(g);
        });
    }
    usleep(20000);   // the slots are busy and the queues full
    double t0 = now_ms(); __block double t1 = 0; dispatch_semaphore_t s = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ t1 = now_ms(); dispatch_semaphore_signal(s); });
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    CHECK(t1 - t0 < 50, "a global-queue job waited %.1f ms behind the background slots: worker pool exhausted", t1 - t0);
    CHECK(!dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), "background jobs did not finish");
    CHECK(atomic_load(&g_peak) >= 1 && atomic_load(&g_peak) <= 2, "%d background jobs ran at once on 2 slots", atomic_load(&g_peak));
}

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
// One ask, as a draw makes it: the pipeline (waited for when not made yet) or nil when the flexible path cannot make it
static id<MTLRenderPipelineState> get(int key, int ukey, MTLRenderPipelineDescriptor *d) {
    long k = key, u = ukey;
    return flexpso_get(&k, &u, lib, lib, "test", ^{ return d; }, NULL);
}

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e]; CHECK(lib, "%s", e.localizedDescription.UTF8String);
    q = [dev newMTL4CommandQueue];
    struct { float x, y; uint8_t c[4]; } v[3] = {{-1, -1, {255, 0, 0, 128}}, {3, -1, {0, 255, 0, 128}}, {-1, 3, {0, 0, 255, 128}}};
    vb = [dev newBufferWithBytes:v length:sizeof v options:MTLResourceStorageModeShared];
    // An archive holding one unspecialized pipeline (fragment fs2), written the way an MTL4Archive can be at run time: a compiler that captures binaries
    NSString *arch = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_flexpso_%d.metallib", getpid()]];
    {
        MTL4PipelineDataSetSerializerDescriptor *sd = [MTL4PipelineDataSetSerializerDescriptor new]; sd.configuration = MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
        id<MTL4PipelineDataSetSerializer> ser = [dev newPipelineDataSetSerializerWithDescriptor:sd];
        MTL4CompilerDescriptor *cd = [MTL4CompilerDescriptor new]; cd.pipelineDataSetSerializer = ser;
        id<MTL4Compiler> comp = [dev newCompilerWithDescriptor:cd error:&e]; CHECK(comp, "compiler: %s", e.localizedDescription.UTF8String);
        CHECK([comp newRenderPipelineStateWithDescriptor:flexpso_desc(desc(0, MTLPixelFormatRGBA8Unorm, "fs2"), lib, lib, 1) compilerTaskOptions:nil error:&e], "archive pipeline: %s", e.localizedDescription.UTF8String);
        CHECK([ser serializeAsArchiveAndFlushToURL:[NSURL fileURLWithPath:arch] error:&e], "archive: %s", e.localizedDescription.UTF8String);
    }
    setenv("DM_PSO_FLEX", "1", 1); flexpso_open(dev, arch, sizeof(long), sizeof(long));
    CHECK(flexpso_on(), "DM_PSO_FLEX=1 did not turn it on");
    // Two colour states of one unspecialized pipeline: pixel-identical to the classic pipeline of each
    const struct { int blend; MTLPixelFormat f1; } cs[2] = {{1, MTLPixelFormatRGBA8Unorm}, {0, MTLPixelFormatRGBA16Float}};
    for (int i = 0; i < 2; i++) {
        MTLRenderPipelineDescriptor *d = desc(cs[i].blend, cs[i].f1, "fs");
        id<MTLRenderPipelineState> classic = [dev newRenderPipelineStateWithDescriptor:d error:&e]; CHECK(classic, "classic: %s", e.localizedDescription.UTF8String);
        uint64_t w0 = flexpso_stats().waited;
        id<MTLRenderPipelineState> flex = get(i + 1, 7, d); CHECK(flex, "colour state %d: the first ask did not return the pipeline (a draw would have been skipped)", i);
        CHECK(flexpso_stats().waited == w0 + 1, "colour state %d: the first ask for a new pipeline was not counted as waited", i);
        CHECK([draw(classic, cs[i].f1) isEqualToData:draw(flex, cs[i].f1)], "colour state %d: flexible and classic pipelines draw different pixels", i);
    }
    flexpso_counts c = flexpso_stats();
    CHECK(c.compiled == 1 && c.specialized == 2, "one unspecialized pipeline for both colour states: compiled %llu, specialized %llu", c.compiled, c.specialized);
    // A kick ahead of the draw: once its worker is done, the draw's first ask takes it without waiting
    {
        MTLRenderPipelineDescriptor *d = desc(1, MTLPixelFormatRGBA8Unorm, "fs"); long k = 3, u = 8;
        flexpso_kick(&k, &u, lib, lib, "kick", ^{ return d; }, 0);
        for (int i = 0; flexpso_stats().specialized < c.specialized + 1; i++) { CHECK(i < 20000, "the kicked pipeline never became ready"); usleep(500); }
        id<MTLRenderPipelineState> ps = flexpso_get(&k, &u, lib, lib, "kick", ^{ return d; }, NULL);
        flexpso_counts c2 = flexpso_stats();
        CHECK(ps && c2.kicked == 1 && c2.ready == 1 && c2.waited == c.waited, "kicked pipeline: got %p, kicked %llu, ready %llu, waited %llu -> %llu", (__bridge void *)ps, c2.kicked, c2.ready, c.waited, c2.waited);
    }
    // Many draws asking for pipelines while other compiles are in flight (kicks queued ahead): every ask returns its pipeline, none is skipped
    {
        for (long i = 0; i < 16; i++) { long k = 100 + i, u = 200 + i % 4; MTLRenderPipelineDescriptor *d = desc((int)(i & 1), i & 2 ? MTLPixelFormatRGBA16Float : MTLPixelFormatRGBA8Unorm, "fs");
            flexpso_kick(&k, &u, lib, lib, "busy", ^{ return d; }, 1); }
        for (long i = 0; i < 16; i++) { long k = 300 + i, u = 200 + i % 4; MTLRenderPipelineDescriptor *d = desc((int)(i & 1), i & 2 ? MTLPixelFormatRGBA16Float : MTLPixelFormatRGBA8Unorm, "fs");
            CHECK(flexpso_get(&k, &u, lib, lib, "busy draw", ^{ return d; }, NULL), "draw %ld: no pipeline while others compiled (skipped)", i); }
    }
    // A function the descriptor names is not in the library: failure, not pending forever
    id<MTLLibrary> other = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 lone() { return 1; }\n" options:nil error:&e];
    MTLRenderPipelineDescriptor *bad = desc(0, MTLPixelFormatRGBA8Unorm, "fs"); bad.fragmentFunction = [other newFunctionWithName:@"lone"];
    CHECK(!get(9, 9, bad), "a pipeline with a function outside its library was made");
    // A draw waits for its pipeline: made on the first ask, counted as waited with its time; a failure under wait is reported, not waited for forever
    {
        flexpso_counts c0 = flexpso_stats(); MTLRenderPipelineDescriptor *d = desc(0, MTLPixelFormatRGBA8Unorm, "fs"); long k = 4, u = 10; uint64_t wns = 0;
        id<MTLRenderPipelineState> ps = flexpso_get(&k, &u, lib, lib, "wait", ^{ return d; }, &wns);
        flexpso_counts c1 = flexpso_stats();
        CHECK(ps, "a draw did not get its pipeline on the first ask");
        CHECK(c1.waited == c0.waited + 1, "waited %llu -> %llu", c0.waited, c1.waited);
        CHECK(wns > 0 && c1.wait_ms > c0.wait_ms, "the wait time was not recorded (%llu ns)", wns);
        uint64_t hs = 0; for (int i = 0; i < FLEXPSO_WAIT_BUCKETS; i++) hs += c1.wait_hist[i];
        CHECK(hs == c1.waited, "wait histogram holds %llu of %llu waits", hs, c1.waited);
        MTLRenderPipelineDescriptor *bad2 = desc(0, MTLPixelFormatRGBA8Unorm, "fs"); bad2.fragmentFunction = [other newFunctionWithName:@"lone"]; long k3 = 11, u3 = 11;
        ps = flexpso_get(&k3, &u3, lib, lib, "badwait", ^{ return bad2; }, NULL);
        CHECK(!ps, "a failing pipeline under wait: got %p", (__bridge void *)ps);
    }
    // Archive coverage counts the lookups made for draws; the program warm-up's stand-ins (flexpso_warm) are counted apart, so that their misses do not read as lower coverage
    {
        flexpso_counts c0 = flexpso_stats(); long u1 = 20, u2 = 21, u3 = 22;
        CHECK(flexpso_warm(&u1, desc(0, MTLPixelFormatRGBA8Unorm, "fs2"), lib, lib, "warm hit", &e), "warm-up stand-in from the archive failed");
        CHECK(flexpso_warm(&u2, desc(0, MTLPixelFormatRGBA8Unorm, "fs"), lib, lib, "warm miss", &e), "compiled warm-up stand-in failed");
        flexpso_counts c1 = flexpso_stats();
        CHECK(c1.warm_hit == c0.warm_hit + 1 && c1.warm_miss == c0.warm_miss + 1, "warm-up lookups: hits %llu -> %llu, misses %llu -> %llu", c0.warm_hit, c1.warm_hit, c0.warm_miss, c1.warm_miss);
        CHECK(c1.archive_hit == c0.archive_hit && c1.archive_miss == c0.archive_miss, "warm-up lookups counted as draw lookups: hits %llu -> %llu, misses %llu -> %llu", c0.archive_hit, c1.archive_hit, c0.archive_miss, c1.archive_miss);
        CHECK(flexpso_make(&u3, desc(1, MTLPixelFormatRGBA8Unorm, "fs2"), lib, lib, "draw hit", &e), "draw pipeline from the archive failed");
        flexpso_counts c2 = flexpso_stats();
        CHECK(c2.archive_hit == c1.archive_hit + 1 && c2.warm_hit == c1.warm_hit, "a draw's archive hit was not counted as one: hits %llu -> %llu", c1.archive_hit, c2.archive_hit);
        CHECK(c0.archive_hit == 0 && c0.archive_miss >= 1, "the draws before used fs (not in the archive): hits %llu, misses %llu", c0.archive_hit, c0.archive_miss);
    }
    [NSFileManager.defaultManager removeItemAtPath:arch error:nil];
    bgq_check();
    flexpso_log();
    printf("FLEXPSO OK: pixel-identical to classic for 2 colour states of 1 unspecialized pipeline, every draw gets its pipeline (none skipped), kicked pipeline ready at its first draw, failure reported, waits counted, background slots bounded without starving the worker pool, warm-up archive lookups counted apart\n");
    return 0;
}}
