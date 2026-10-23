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

// kicked: started ahead of the draw (flexpso_kick); warm: a base made for a warm-up stand-in that no draw has asked for (released when the stand-in is done, base_get)
@interface FlexEntry : NSObject { @public id<MTLRenderPipelineState> ps; int done, kicked, warm; } @end
@implementation FlexEntry @end

static id<MTLDevice> g_dev;
static id<MTL4Compiler> g_comp;
static id<MTL4Archive> g_arch;
static MTL4CompilerTaskOptions *g_opt;
static dispatch_group_t g_open;   // the archive opens on a worker (about 3 ms per MB): workers wait for it, the caller of flexpso_open does not
static int g_on;
static nvn_hmap g_req, g_base;   // values: retained FlexEntry
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static _Atomic uint64_t g_whit, g_wmiss;   // archive lookups of warm-up stand-ins (flexpso_warm), apart from the draws' g_hit / g_miss
static _Atomic uint64_t g_wrel, g_wtaken;   // stand-in bases released once their stand-in was made / taken by a draw that asked for the same key while it was in the table
static _Atomic uint64_t g_asked, g_kicked, g_ready, g_kick_late, g_hit, g_miss, g_compiled, g_spec, g_failed, g_spec_ns, g_spec_worst_ns;   // kicked: started ahead of the draw; ready: render asks that found it made
static _Atomic uint64_t g_waited, g_wait_ns, g_wait_worst_ns, g_wait_hist[FLEXPSO_WAIT_BUCKETS];   // draws that waited for their pipeline: count, total and worst time, histogram

static uint64_t now_ns_(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

void flexpso_open(id<MTLDevice> dev, NSString *archive, size_t klen, size_t ulen) {
    const char *on = getenv("DM_PSO_FLEX");
    g_on = on && atoi(on) > 0;
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
    FLOG("on: pipelines are made on workers, a draw whose pipeline is not ready yet waits for it (no draw is ever skipped)");
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

// The unspecialized pipeline for ukey: the first caller makes it (archive, else compile) while later callers for the same key wait for it. A failure is remembered (nil).
// warm: the lookup is a warm-up stand-in's, counted in g_whit / g_wmiss; a base it makes is marked warm until a draw (or a tool) asks for the same key, see base_release_warm
static FlexEntry *base_get(const void *ukey, MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, int warm, NSError **err) {
    pthread_mutex_lock(&g_mu);
    FlexEntry *b = (__bridge FlexEntry *)nvn_hm_get(&g_base, ukey); int mine = !b;
    if (mine) { b = [FlexEntry new]; b->warm = warm; nvn_hm_put(&g_base, ukey, (void *)CFBridgingRetain(b)); }
    else {
        if (!warm && b->warm) { b->warm = 0; atomic_fetch_add(&g_wtaken, 1); }   // a draw's key: the base stays for good, as every draw's base does
        while (!b->done) pthread_cond_wait(&g_cv, &g_mu);
    }
    pthread_mutex_unlock(&g_mu);
    if (!mine) return b;
    dispatch_group_wait(g_open, DISPATCH_TIME_FOREVER);
    id<MTLRenderPipelineState> ps = nil;
    MTL4RenderPipelineDescriptor *m = flexpso_desc(d, vlib, flib, 1);
    if (m && g_arch) ps = [g_arch newRenderPipelineStateWithDescriptor:m error:nil];
    if (ps) atomic_fetch_add(warm ? &g_whit : &g_hit, 1);
    else if (m) {
        uint64_t n = g_arch ? atomic_fetch_add(warm ? &g_wmiss : &g_miss, 1) + 1 : 0;
        if (n && (n <= MISS_LOG_ALL || n % 100 == 0)) FLOG("archive miss #%llu%s: %s compiled on a worker", (unsigned long long)n, warm ? " (warm-up stand-in)" : "", label ? label : "-");
        ps = [g_comp newRenderPipelineStateWithDescriptor:m compilerTaskOptions:g_opt error:err];
        if (ps) atomic_fetch_add(&g_compiled, 1);
    }
    pthread_mutex_lock(&g_mu); b->ps = ps; b->done = 1; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
    return b;
}
// A warm-up stand-in is made only to leave its functions compiled (nvn_mtl.m, program warm-up); its vertex layout and sample count rarely match a draw's, so its base is almost never
// asked for again. Keeping every one cost hundreds of MB (14,625 bases kept against about 460 drawn in Odyssey), so the base leaves the table once the stand-in is made, unless a draw
// asked for the same key meanwhile. A later ask makes it again from the same descriptor (archive, else compile): the same pipeline
static void base_release_warm(const void *ukey, FlexEntry *b) {
    pthread_mutex_lock(&g_mu);
    int drop = b->warm && (__bridge FlexEntry *)nvn_hm_get(&g_base, ukey) == b;
    if (drop) CFBridgingRelease(nvn_hm_del(&g_base, ukey));
    pthread_mutex_unlock(&g_mu);
    if (drop) atomic_fetch_add(&g_wrel, 1);
}

static id<MTLRenderPipelineState> make(const void *ukey, MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, int warm, NSError **err) {
    FlexEntry *e = base_get(ukey, d, vlib, flib, label, warm, err); id<MTLRenderPipelineState> b = e->ps, ps = nil;
    if (b) {
        MTL4RenderPipelineDescriptor *s = (MTL4RenderPipelineDescriptor *)[b newRenderPipelineDescriptorForSpecialization];
        flexpso_specialize(s, d);
        uint64_t t0 = now_ns_(); ps = [g_comp newRenderPipelineStateBySpecializationWithDescriptor:s pipeline:b error:err]; uint64_t t = now_ns_() - t0;
        atomic_fetch_add(&g_spec, 1); atomic_fetch_add(&g_spec_ns, t);
        for (uint64_t w = atomic_load(&g_spec_worst_ns); t > w && !atomic_compare_exchange_weak(&g_spec_worst_ns, &w, t);) {}
    }
    if (warm) base_release_warm(ukey, e);
    if (!ps) { atomic_fetch_add(&g_failed, 1); FLOG("[RED] %s: no flexible pipeline (%s): made as before", label ? label : "-", err && *err ? (*err).localizedDescription.UTF8String : "no unspecialized pipeline"); }
    return ps;
}
id<MTLRenderPipelineState> flexpso_make(const void *ukey, MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, NSError **err) { return make(ukey, d, vlib, flib, label, 0, err); }
id<MTLRenderPipelineState> flexpso_warm(const void *ukey, MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, NSError **err) { return make(ukey, d, vlib, flib, label, 1, err); }

// The request for key, taken out of the table when done (the caller now owns the result). Under g_mu
static id<MTLRenderPipelineState> take_done(const void *key, FlexEntry *r) {
    id<MTLRenderPipelineState> ps = r->ps;
    CFBridgingRelease(nvn_hm_del(&g_req, key));
    return ps;
}

// draw 0: a kick (no wait, a finished pipeline stays for the draw), its work at qos
// slot: a far kick's claim on g_far, given back when its work ends
static _Atomic int g_far; static int g_far_max = -1; static _Atomic uint64_t g_far_dropped;
static void wait_note(uint64_t ns) {
    atomic_fetch_add(&g_waited, 1); atomic_fetch_add(&g_wait_ns, ns);
    for (uint64_t w = atomic_load(&g_wait_worst_ns); ns > w && !atomic_compare_exchange_weak(&g_wait_worst_ns, &w, ns);) {}
    int b = 0; for (uint64_t lim = 1000000; b < FLEXPSO_WAIT_BUCKETS - 1 && ns >= lim; lim *= 4) b++;   // 1, 4, 16, 64, 256 ms
    atomic_fetch_add(&g_wait_hist[b], 1);
}
// draw 1: the render thread's ask, which waits until the pipeline is done (a failure is done too, with no pipeline); the time in *wait_ns
static id<MTLRenderPipelineState> ask(const void *key, const void *ukey, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, MTLRenderPipelineDescriptor *(^mk)(void), int draw, qos_class_t qos, _Atomic int *slot, uint64_t *wait_ns) {
    pthread_mutex_lock(&g_mu);
    FlexEntry *r = (__bridge FlexEntry *)nvn_hm_get(&g_req, key);
    if (!draw && r) { pthread_mutex_unlock(&g_mu); if (slot) atomic_fetch_sub(slot, 1); return nil; }   // kick: already asked for
    if (r && r->done) { int k = r->kicked; id ps = take_done(key, r); pthread_mutex_unlock(&g_mu); if (k) atomic_fetch_add(&g_ready, 1); return ps; }
    if (r && r->kicked == 1) { r->kicked = 2; atomic_fetch_add(&g_kick_late, 1); }   // kicked, the draw came first
    if (!r) {
        r = [FlexEntry new]; r->kicked = !draw; nvn_hm_put(&g_req, key, (void *)CFBridgingRetain(r));
        pthread_mutex_unlock(&g_mu);
        atomic_fetch_add(draw ? &g_asked : &g_kicked, 1);
        MTLRenderPipelineDescriptor *d = mk();
        NSData *uk = [NSData dataWithBytes:ukey length:g_base.klen]; NSString *lb = @(label ? label : "-"); FlexEntry *req = r;
        dispatch_async(dispatch_get_global_queue(qos, 0), ^{
            NSError *e = nil; id<MTLRenderPipelineState> ps = flexpso_make(uk.bytes, d, vlib, flib, lb.UTF8String, &e);
            pthread_mutex_lock(&g_mu); req->ps = ps; req->done = 1; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
            if (slot) atomic_fetch_sub(slot, 1);
        });
        if (!draw) return nil;
        pthread_mutex_lock(&g_mu);
    }
    uint64_t t0 = now_ns_();
    while (!r->done) pthread_cond_wait(&g_cv, &g_mu);
    id ps = take_done(key, r); pthread_mutex_unlock(&g_mu);
    uint64_t t = now_ns_() - t0; wait_note(t); if (wait_ns) *wait_ns = t;
    return ps;
}

id<MTLRenderPipelineState> flexpso_get(const void *key, const void *ukey, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, MTLRenderPipelineDescriptor *(^mk)(void), uint64_t *wait_ns) {
    if (wait_ns) *wait_ns = 0;
    return ask(key, ukey, vlib, flib, label, mk, 1, QOS_CLASS_USER_INITIATED, NULL, wait_ns);
}
void flexpso_kick(const void *key, const void *ukey, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, MTLRenderPipelineDescriptor *(^mk)(void), int soon) {
    if (soon) { ask(key, ukey, vlib, flib, label, mk, 0, QOS_CLASS_USER_INITIATED, NULL, NULL); return; }
    // A far guess yields to what a draw waits for: utility QoS, and at most DM_PSO_KICK_MAX (default 1) in flight, the rest dropped, since Metal's compiler serves
    // every compile in turn and a backlog of guesses delays the draws' own
    if (g_far_max < 0) { const char *m = getenv("DM_PSO_KICK_MAX"); g_far_max = m ? atoi(m) : 1; }
    if (atomic_fetch_add(&g_far, 1) >= g_far_max) { atomic_fetch_sub(&g_far, 1); atomic_fetch_add(&g_far_dropped, 1); return; }
    ask(key, ukey, vlib, flib, label, mk, 0, QOS_CLASS_UTILITY, &g_far, NULL);
}

unsigned flexpso_bases(void) { pthread_mutex_lock(&g_mu); unsigned n = g_base.n; pthread_mutex_unlock(&g_mu); return n; }
flexpso_counts flexpso_stats(void) {
    flexpso_counts c = {g_asked, g_kicked, g_ready, g_hit, g_miss, g_whit, g_wmiss, g_wrel, g_wtaken, g_compiled, g_spec, g_failed, g_waited, {0}, g_spec_ns / 1e6, g_spec_worst_ns / 1e6, g_wait_ns / 1e6, g_wait_worst_ns / 1e6};
    for (int i = 0; i < FLEXPSO_WAIT_BUCKETS; i++) c.wait_hist[i] = g_wait_hist[i];
    return c;
}

void flexpso_log(void) {
    if (!g_on) return;
    flexpso_counts c = flexpso_stats();
    static uint64_t said = ~0ull; if (c.asked + c.kicked + c.specialized + c.waited == said) return; said = c.asked + c.kicked + c.specialized + c.waited;
    uint64_t looked = c.archive_hit + c.archive_miss;
    FLOG("asked at the draw %llu, kicked ahead %llu (ready at their first draw %llu, still in progress %llu; guesses dropped %llu), archive %llu hits / %llu misses (coverage of the draws' pipelines %.1f%%; warm-up stand-ins apart: %llu hits / %llu misses, bases released %llu, taken by a draw %llu, kept %u), compiled %llu, specialized %llu (%.3f ms each, worst %.1f ms), failed %llu, draws waited %llu (%.2f ms each, worst %.1f ms; under 1 / 4 / 16 / 64 / 256 ms / longer: %llu / %llu / %llu / %llu / %llu / %llu)",
         (unsigned long long)c.asked, (unsigned long long)c.kicked, (unsigned long long)c.ready, (unsigned long long)g_kick_late, (unsigned long long)g_far_dropped, (unsigned long long)c.archive_hit, (unsigned long long)c.archive_miss, looked ? 100.0 * c.archive_hit / looked : 0.0, (unsigned long long)c.warm_hit, (unsigned long long)c.warm_miss, (unsigned long long)c.warm_released, (unsigned long long)c.warm_taken, flexpso_bases(), (unsigned long long)c.compiled,
         (unsigned long long)c.specialized, c.specialized ? c.spec_ms / c.specialized : 0.0, c.spec_worst_ms, (unsigned long long)c.failed,
         (unsigned long long)c.waited, c.waited ? c.wait_ms / c.waited : 0.0, c.wait_worst_ms, (unsigned long long)c.wait_hist[0], (unsigned long long)c.wait_hist[1], (unsigned long long)c.wait_hist[2],
         (unsigned long long)c.wait_hist[3], (unsigned long long)c.wait_hist[4], (unsigned long long)c.wait_hist[5]);
}
