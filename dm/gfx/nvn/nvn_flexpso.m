// Flexible pipelines, see nvn_flexpso.h. Two tables under one mutex: requests (full key -> the pipeline a worker is making for the render thread) and bases (unspecialized key -> the
// unspecialized pipeline, made once and specialized for every colour state). Neither is on the per-draw path: the caller's own cache answers every draw after the first.
#import "nvn_flexpso.h"
#include "nvn_hmap.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define FLOG(...) do { fprintf(stderr, "[dm] [pso-flex] " __VA_ARGS__); fputc('\n', stderr); } while (0)
enum { MISS_LOG_ALL = 32 };   // archive misses logged one by one, then every 100th

@interface FlexEntry : NSObject { @public id<MTLRenderPipelineState> ps; int done; } @end
@implementation FlexEntry @end

static id<MTLDevice> g_dev;
static id<MTL4Compiler> g_comp;
static id<MTL4Archive> g_arch;
static MTL4CompilerTaskOptions *g_opt;
static dispatch_group_t g_open;   // the archive opens on a worker (about 3 ms per MB): workers wait for it, the caller of flexpso_open does not
static int g_on; static long g_wait_us;
static nvn_hmap g_req, g_base;   // values: retained FlexEntry
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static _Atomic uint64_t g_asked, g_hit, g_miss, g_compiled, g_spec, g_failed, g_skipped, g_spec_ns, g_spec_worst_ns;

static uint64_t now_ns_(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

void flexpso_open(id<MTLDevice> dev, NSString *archive, size_t klen, size_t ulen) {
    const char *on = getenv("DM_PSO_FLEX"), *w = getenv("DM_PSO_FLEX_WAIT_US");
    g_on = on && atoi(on) > 0; g_wait_us = w ? atol(w) : 0;
    if (!g_on) return;
    g_dev = dev; nvn_hm_init(&g_req, (uint32_t)klen); nvn_hm_init(&g_base, (uint32_t)ulen);
    NSError *e = nil;
    g_comp = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
    if (!g_comp) { FLOG("[RED] no Metal 4 compiler (%s): flexible pipelines off", e.localizedDescription.UTF8String); g_on = 0; return; }
    g_opt = [MTL4CompilerTaskOptions new];
    g_open = dispatch_group_create();
    if (archive && [NSFileManager.defaultManager fileExistsAtPath:archive]) dispatch_group_async(g_open, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *ae = nil; uint64_t t0 = now_ns_();
        g_arch = [dev newArchiveWithURL:[NSURL fileURLWithPath:archive] error:&ae];
        if (g_arch) { g_opt.lookupArchives = @[g_arch]; FLOG("archive %s loaded in %.0f ms (this GPU: %s)", archive.UTF8String, (now_ns_() - t0) / 1e6, dev.architecture.name.UTF8String); }
        else FLOG("[RED] cannot load %s (%s): every flexible pipeline compiles", archive.UTF8String, ae.localizedDescription.UTF8String);
    });
    else FLOG("no archive%s%s: every flexible pipeline compiles on a worker", archive ? " at " : "", archive ? archive.UTF8String : "");
    FLOG("on: pipelines are made on workers, a draw whose pipeline is not ready yet is skipped (render thread waits at most %ld us%s)", g_wait_us, g_wait_us < 0 ? ", -1 = until ready" : "");
}

int flexpso_on(void) { return g_on; }

static MTL4FunctionDescriptor *fdesc(id<MTLLibrary> lib, id<MTLFunction> fn) {
    if (!lib || !fn || ![lib.functionNames containsObject:fn.name]) return nil;   // a function from another library (DM_NVN_HILITE): no Metal 4 descriptor, made as before
    MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = lib; f.name = fn.name;
    if (!fn.functionConstantsDictionary.count) return f;
    // The runtime specializes functions that declare constants with an empty set of values (nvn_mtl.m shader_load); the same here
    MTL4SpecializedFunctionDescriptor *s = [MTL4SpecializedFunctionDescriptor new]; s.functionDescriptor = f; s.constantValues = [MTLFunctionConstantValues new];
    return s;
}

static void colour(MTL4RenderPipelineColorAttachmentDescriptor *o, MTLRenderPipelineColorAttachmentDescriptor *c) {
    o.pixelFormat = c.pixelFormat; o.writeMask = c.pixelFormat ? c.writeMask : MTLColorWriteMaskNone; o.blendingState = c.blendingEnabled ? MTL4BlendStateEnabled : MTL4BlendStateDisabled;
    o.sourceRGBBlendFactor = c.sourceRGBBlendFactor; o.destinationRGBBlendFactor = c.destinationRGBBlendFactor; o.rgbBlendOperation = c.rgbBlendOperation;
    o.sourceAlphaBlendFactor = c.sourceAlphaBlendFactor; o.destinationAlphaBlendFactor = c.destinationAlphaBlendFactor; o.alphaBlendOperation = c.alphaBlendOperation;
}

MTL4RenderPipelineDescriptor *flexpso_desc(MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, int unspec) {
    MTL4RenderPipelineDescriptor *m = [MTL4RenderPipelineDescriptor new];
    m.vertexFunctionDescriptor = fdesc(vlib, d.vertexFunction);
    if (d.fragmentFunction) m.fragmentFunctionDescriptor = fdesc(flib, d.fragmentFunction);
    if (!m.vertexFunctionDescriptor || (d.fragmentFunction && !m.fragmentFunctionDescriptor)) return nil;
    m.vertexDescriptor = d.vertexDescriptor; m.rasterSampleCount = d.rasterSampleCount; m.rasterizationEnabled = d.rasterizationEnabled;
    m.inputPrimitiveTopology = d.inputPrimitiveTopology;
    m.alphaToCoverageState = d.alphaToCoverageEnabled ? MTL4AlphaToCoverageStateEnabled : MTL4AlphaToCoverageStateDisabled;
    for (int i = 0; i < 8; i++) {
        MTL4RenderPipelineColorAttachmentDescriptor *o = m.colorAttachments[i];
        if (unspec) { o.pixelFormat = MTLPixelFormatUnspecialized; o.writeMask = MTLColorWriteMaskUnspecialized; o.blendingState = MTL4BlendStateUnspecialized; }
        else colour(o, d.colorAttachments[i]);
    }
    return m;
}

void flexpso_specialize(MTL4RenderPipelineDescriptor *s, MTLRenderPipelineDescriptor *d) { for (int i = 0; i < 8; i++) colour(s.colorAttachments[i], d.colorAttachments[i]); }

// The unspecialized pipeline for ukey: the first caller makes it (archive, else compile) while later callers for the same key wait for it. A failure is remembered (nil)
static id<MTLRenderPipelineState> base_get(const void *ukey, MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, NSError **err) {
    pthread_mutex_lock(&g_mu);
    FlexEntry *b = (__bridge FlexEntry *)nvn_hm_get(&g_base, ukey); int mine = !b;
    if (mine) { b = [FlexEntry new]; nvn_hm_put(&g_base, ukey, (void *)CFBridgingRetain(b)); }
    else while (!b->done) pthread_cond_wait(&g_cv, &g_mu);
    pthread_mutex_unlock(&g_mu);
    if (!mine) return b->ps;
    dispatch_group_wait(g_open, DISPATCH_TIME_FOREVER);
    id<MTLRenderPipelineState> ps = nil;
    MTL4RenderPipelineDescriptor *m = flexpso_desc(d, vlib, flib, 1);
    if (m && g_arch) ps = [g_arch newRenderPipelineStateWithDescriptor:m error:nil];
    if (ps) atomic_fetch_add(&g_hit, 1);
    else if (m) {
        uint64_t n = g_arch ? atomic_fetch_add(&g_miss, 1) + 1 : 0;
        if (n && (n <= MISS_LOG_ALL || n % 100 == 0)) FLOG("archive miss #%llu: %s compiled on a worker", (unsigned long long)n, label ? label : "-");
        ps = [g_comp newRenderPipelineStateWithDescriptor:m compilerTaskOptions:g_opt error:err];
        if (ps) atomic_fetch_add(&g_compiled, 1);
    }
    pthread_mutex_lock(&g_mu); b->ps = ps; b->done = 1; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
    return ps;
}

id<MTLRenderPipelineState> flexpso_make(const void *ukey, MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, NSError **err) {
    id<MTLRenderPipelineState> b = base_get(ukey, d, vlib, flib, label, err), ps = nil;
    if (b) {
        MTL4RenderPipelineDescriptor *s = (MTL4RenderPipelineDescriptor *)[b newRenderPipelineDescriptorForSpecialization];
        flexpso_specialize(s, d);
        uint64_t t0 = now_ns_(); ps = [g_comp newRenderPipelineStateBySpecializationWithDescriptor:s pipeline:b error:err]; uint64_t t = now_ns_() - t0;
        atomic_fetch_add(&g_spec, 1); atomic_fetch_add(&g_spec_ns, t);
        for (uint64_t w = atomic_load(&g_spec_worst_ns); t > w && !atomic_compare_exchange_weak(&g_spec_worst_ns, &w, t);) {}
    }
    if (!ps) { atomic_fetch_add(&g_failed, 1); FLOG("[RED] %s: no flexible pipeline (%s): made as before", label ? label : "-", err && *err ? (*err).localizedDescription.UTF8String : "no unspecialized pipeline"); }
    return ps;
}

// The request for key, taken out of the table when done (the caller now owns the result). Under g_mu
static id<MTLRenderPipelineState> take_done(const void *key, FlexEntry *r, int *pending) {
    id<MTLRenderPipelineState> ps = r->ps;
    CFBridgingRelease(nvn_hm_del(&g_req, key));
    *pending = 0; return ps;
}

id<MTLRenderPipelineState> flexpso_get(const void *key, const void *ukey, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, MTLRenderPipelineDescriptor *(^mk)(void), int *pending) {
    pthread_mutex_lock(&g_mu);
    FlexEntry *r = (__bridge FlexEntry *)nvn_hm_get(&g_req, key);
    if (r && r->done) { id ps = take_done(key, r, pending); pthread_mutex_unlock(&g_mu); return ps; }
    if (!r) {
        r = [FlexEntry new]; nvn_hm_put(&g_req, key, (void *)CFBridgingRetain(r));
        pthread_mutex_unlock(&g_mu);
        atomic_fetch_add(&g_asked, 1);
        MTLRenderPipelineDescriptor *d = mk();
        NSData *uk = [NSData dataWithBytes:ukey length:g_base.klen]; NSString *lb = @(label ? label : "-"); FlexEntry *req = r;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *e = nil; id<MTLRenderPipelineState> ps = flexpso_make(uk.bytes, d, vlib, flib, lb.UTF8String, &e);
            pthread_mutex_lock(&g_mu); req->ps = ps; req->done = 1; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
        });
        pthread_mutex_lock(&g_mu);
    }
    if (g_wait_us) {   // DM_PSO_FLEX_WAIT_US: bounded wait (or, -1, until ready)
        struct timespec until; clock_gettime(CLOCK_REALTIME, &until);
        long ns = until.tv_nsec + (g_wait_us > 0 ? g_wait_us : 0) * 1000; until.tv_sec += ns / 1000000000; until.tv_nsec = ns % 1000000000;
        while (!r->done && (g_wait_us < 0 ? !pthread_cond_wait(&g_cv, &g_mu) : !pthread_cond_timedwait(&g_cv, &g_mu, &until))) {}
        if (r->done) { id ps = take_done(key, r, pending); pthread_mutex_unlock(&g_mu); return ps; }
    }
    pthread_mutex_unlock(&g_mu);
    atomic_fetch_add(&g_skipped, 1);
    *pending = 1; return nil;
}

flexpso_counts flexpso_stats(void) {
    return (flexpso_counts){g_asked, g_hit, g_miss, g_compiled, g_spec, g_failed, g_skipped, g_spec_ns / 1e6, g_spec_worst_ns / 1e6};
}

void flexpso_log(void) {
    if (!g_on) return;
    flexpso_counts c = flexpso_stats();
    static uint64_t said = ~0ull; if (c.asked + c.specialized == said) return; said = c.asked + c.specialized;
    uint64_t looked = c.archive_hit + c.archive_miss;
    FLOG("asked %llu, archive %llu hits / %llu misses (coverage %.1f%%), compiled %llu, specialized %llu (%.3f ms each, worst %.1f ms), failed %llu, draws skipped %llu",
         (unsigned long long)c.asked, (unsigned long long)c.archive_hit, (unsigned long long)c.archive_miss, looked ? 100.0 * c.archive_hit / looked : 0.0, (unsigned long long)c.compiled,
         (unsigned long long)c.specialized, c.specialized ? c.spec_ms / c.specialized : 0.0, c.spec_worst_ms, (unsigned long long)c.failed, (unsigned long long)c.skipped);
}
