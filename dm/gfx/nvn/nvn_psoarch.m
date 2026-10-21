// Precompiled pipelines (Metal binary archives), see nvn_psoarch.h. Pipelines are built with the classic MTLDevice calls (nvn_mtl.m pso_desc), which take MTLBinaryArchive;
// Metal 4's MTL4Archive only serves pipelines built through an MTL4Compiler, which nxnative does not use. Lookups go through MTLPipelineOptionFailOnBinaryArchiveMiss so a miss is seen
// (and logged) instead of silently compiling; the fallback is the ordinary compile, so a stale archive (iPadOS / driver update, other chain version) costs only the lookup.
#import "nvn_psoarch.h"
#include <os/lock.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define PLOG(...) do { fprintf(stderr, "[dm] [pso-archive] " __VA_ARGS__); fputc('\n', stderr); } while (0)
enum { MISS_LOG_ALL = 32 };   // misses logged one by one; after that every 100th (a wholesale invalidation would otherwise log every pipeline of the game)

static id<MTLDevice> g_dev;
static id<MTLBinaryArchive> g_load;
static NSArray<id<MTLBinaryArchive>> *g_archs;   // passed to every descriptor: the loaded archive
static NSString *g_harv_path;   // harvest on: every pipeline created is written to this archive
static os_unfair_lock g_harv_lock = OS_UNFAIR_LOCK_INIT;   // g_all is appended from the warm-up, prediction and submit threads
static NSMutableArray<NSArray *> *g_all;   // {descriptor, label} of every pipeline created this run
static _Atomic uint64_t g_hit, g_miss, g_harvested, g_harv_written;

static id<MTLBinaryArchive> arch_new(NSString *path, NSError **e) {
    MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
    if (path) ad.url = [NSURL fileURLWithPath:path];
    return [g_dev newBinaryArchiveWithDescriptor:ad error:e];
}

void psoarch_open(id<MTLDevice> dev, NSString *load, NSString *harvest) {
    g_dev = dev; g_load = nil; g_harv_path = harvest; g_hit = g_miss = g_harvested = g_harv_written = 0;
    NSError *e = nil;
    if (load && [NSFileManager.defaultManager fileExistsAtPath:load]) {
        g_load = arch_new(load, &e);
        if (g_load) PLOG("loaded %s: pipelines found there are not compiled (this GPU: %s, the slice the archive needs; xcrun metal-lipo -archs lists an archive's)", load.UTF8String, dev.architecture.name.UTF8String);
        else PLOG("[RED] cannot load %s (%s): every pipeline compiles as without an archive", load.UTF8String, e.localizedDescription.UTF8String);
    } else if (load) PLOG("no archive at %s: every pipeline compiles on first use (build one: docs/stageB-pipeline-archives.md)", load.UTF8String);
    // The harvest is rewritten whole by this run: pipelines of earlier runs come back through the warm-up replay of the pipeline list (DM_PSO_USER), so run with the same list
    if (harvest) PLOG("harvest on: every pipeline created is written to %s (replaces an earlier harvest there)", harvest.UTF8String);
    g_archs = g_load ? @[g_load] : @[];
    g_all = [NSMutableArray array];
}

static void miss_log(const char *what, const char *label) {
    uint64_t n = atomic_fetch_add(&g_miss, 1) + 1;
    if (n <= MISS_LOG_ALL || n % 100 == 0) PLOG("miss #%llu: %s pipeline %s compiled on the spot (not in the archive)%s", (unsigned long long)n, what, label ? label : "-",
                                               n == MISS_LOG_ALL ? "; further misses are logged every 100th" : "");
}

static void harvest_add(MTLRenderPipelineDescriptor *rd, MTLComputePipelineDescriptor *cd, const char *label) {
    if (!g_harv_path) return;
    id d = rd ? [rd copy] : [cd copy];   // a copy, as callers build each descriptor once but nothing promises they leave it alone
    [d setBinaryArchives:nil];
    os_unfair_lock_lock(&g_harv_lock);
    [g_all addObject:@[d, @(label ? label : "-")]];
    os_unfair_lock_unlock(&g_harv_lock);
    atomic_fetch_add(&g_harvested, 1);
}

id<MTLRenderPipelineState> psoarch_render(MTLRenderPipelineDescriptor *d, const char *label, NSError **err) {
    id<MTLDevice> dev = d.vertexFunction.device ?: MTLCreateSystemDefaultDevice();   // the function's own device, so this also works before psoarch_open; a missing function gets Metal's own error
    if (!g_load && !g_harv_path) return [dev newRenderPipelineStateWithDescriptor:d error:err];
    if (g_load) d.binaryArchives = g_archs;
    id<MTLRenderPipelineState> ps = g_load ? [dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil] : nil;
    if (ps) atomic_fetch_add(&g_hit, 1);
    else { if (g_load) miss_log("render", label); ps = [dev newRenderPipelineStateWithDescriptor:d error:err]; }
    if (ps) harvest_add(d, nil, label);   // only pipelines Metal accepted (a refused one is retried by the caller with another descriptor)
    return ps;
}

id<MTLComputePipelineState> psoarch_compute(id<MTLFunction> fn, const char *label, NSError **err) {
    id<MTLDevice> dev = fn.device ?: MTLCreateSystemDefaultDevice();
    if (!g_load && !g_harv_path) return [dev newComputePipelineStateWithFunction:fn error:err];
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];   // the descriptor equivalent of newComputePipelineStateWithFunction (only a descriptor can name archives)
    d.computeFunction = fn;
    if (g_load) d.binaryArchives = g_archs;
    id<MTLComputePipelineState> ps = g_load ? [dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil] : nil;
    if (ps) atomic_fetch_add(&g_hit, 1);
    else { if (g_load) miss_log("compute", label); ps = [dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:nil error:err]; }
    if (ps) harvest_add(nil, d, label);
    return ps;
}

// Each write is a fresh archive of every pipeline so far. iPadOS 26 serializes an archive once: a second serialize of the same archive (or of one opened from a file) fails in the GPU
// binary packer ("expecting 'fragment' stage in pipeline no. N", N a pipeline of the earlier write) and leaves the archive empty ("Nothing to serialize")
static void harvest_write(void) {
    os_unfair_lock_lock(&g_harv_lock);
    uint64_t n = atomic_load(&g_harvested); NSArray *all = n == g_harv_written ? nil : [g_all copy];
    os_unfair_lock_unlock(&g_harv_lock);
    if (!all.count) return;
    NSError *e = nil; id<MTLBinaryArchive> a = arch_new(nil, &e); NSUInteger left = 0;
    if (!a) { PLOG("[RED] harvest: cannot create an archive (%s)", e.localizedDescription.UTF8String); return; }
    for (NSArray *it in all) {
        id d = it[0]; e = nil;
        BOOL ok = [d isKindOfClass:MTLRenderPipelineDescriptor.class] ? [a addRenderPipelineFunctionsWithDescriptor:d error:&e] : [a addComputePipelineFunctionsWithDescriptor:d error:&e];
        if (!ok && !left++) PLOG("[RED] harvest: pipeline %s not added: %s", [it[1] UTF8String], e.localizedDescription.UTF8String);
    }
    // to a temporary file, then renamed over the archive: a kill mid-write (iOS, the 1.5 s exit fallback) leaves the previous archive intact
    NSString *tmp = [g_harv_path stringByAppendingString:@".tmp"]; e = nil;
    if (![a serializeToURL:[NSURL fileURLWithPath:tmp] error:&e] || rename(tmp.fileSystemRepresentation, g_harv_path.fileSystemRepresentation)) {
        PLOG("[RED] harvest: writing %s failed: %s", g_harv_path.UTF8String, e ? e.localizedDescription.UTF8String : strerror(errno)); return; }
    g_harv_written = n;
    PLOG("harvest: %lu pipelines written to %s%s", (unsigned long)(all.count - left), g_harv_path.UTF8String, left ? " (some left out, see above)" : "");
}

void psoarch_flush(int wait) {
    static uint64_t said = ~0ull;   // how many pipelines still compile at run time: at suspend / exit (mtl_drain) and every 600 presents when it changed
    if (g_load && (wait || g_hit + g_miss != said)) { said = g_hit + g_miss; PLOG("%llu hits / %llu misses so far", (unsigned long long)g_hit, (unsigned long long)g_miss); }
    if (!g_harv_path || atomic_load(&g_harvested) == atomic_load(&g_harv_written)) return;
    static dispatch_queue_t q; static dispatch_once_t once;   // one writer at a time
    dispatch_once(&once, ^{ q = dispatch_queue_create("dm.nvn.pso-harvest", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    if (wait) dispatch_sync(q, ^{ harvest_write(); }); else dispatch_async(q, ^{ harvest_write(); });
}

void psoarch_stats(uint64_t *hit, uint64_t *miss, uint64_t *harvested) { *hit = g_hit; *miss = g_miss; *harvested = g_harvested; }
