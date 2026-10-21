// Precompiled pipelines (Metal binary archives), see nvn_psoarch.h. Pipelines are built with the classic MTLDevice calls (nvn_mtl.m pso_desc), which take MTLBinaryArchive;
// Metal 4's MTL4Archive only serves pipelines built through an MTL4Compiler, which nxnative does not use. Lookups go through MTLPipelineOptionFailOnBinaryArchiveMiss so a miss is seen
// (and logged) instead of silently compiling; the fallback is the ordinary compile, so a stale archive (iPadOS / driver update, other chain version) costs only the lookup.
#import "nvn_psoarch.h"
#include <os/lock.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define PLOG(...) do { fprintf(stderr, "[dm] [pso-archive] " __VA_ARGS__); fputc('\n', stderr); } while (0)
enum { MISS_LOG_ALL = 32 };   // misses logged one by one; after that every 100th (a wholesale invalidation would otherwise log every pipeline of the game)

static id<MTLDevice> g_dev;
static id<MTLBinaryArchive> g_load, g_harv;
static NSArray<id<MTLBinaryArchive>> *g_archs;   // passed to every descriptor: the loaded archive only, so the harvest archive is touched under g_harv_lock alone (harvest_write may replace it)
static NSString *g_harv_path;
static os_unfair_lock g_harv_lock = OS_UNFAIR_LOCK_INIT;   // adds and the serialize write share the harvest archive across the warm-up, prediction and submit threads
static NSMutableArray<NSArray *> *g_pend;   // {descriptor, label} of the pipelines added since the last good write (harvest_write puts them back when a write fails)
static _Atomic uint64_t g_hit, g_miss, g_harvested, g_harv_written;

static id<MTLBinaryArchive> arch_new(NSString *path, NSError **e) {
    MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
    if (path) ad.url = [NSURL fileURLWithPath:path];
    return [g_dev newBinaryArchiveWithDescriptor:ad error:e];
}

void psoarch_open(id<MTLDevice> dev, NSString *load, NSString *harvest) {
    g_dev = dev; g_load = g_harv = nil; g_harv_path = harvest; g_hit = g_miss = g_harvested = g_harv_written = 0;
    NSError *e = nil;
    if (load && [NSFileManager.defaultManager fileExistsAtPath:load]) {
        g_load = arch_new(load, &e);
        if (g_load) PLOG("loaded %s: pipelines found there are not compiled (this GPU: %s, the slice the archive needs; xcrun metal-lipo -archs lists an archive's)", load.UTF8String, dev.architecture.name.UTF8String);
        else PLOG("[RED] cannot load %s (%s): every pipeline compiles as without an archive", load.UTF8String, e.localizedDescription.UTF8String);
    } else if (load) PLOG("no archive at %s: every pipeline compiles on first use (build one: docs/stageB-pipeline-archives.md)", load.UTF8String);
    if (harvest) {
        e = nil; int had = [NSFileManager.defaultManager fileExistsAtPath:harvest];
        g_harv = had ? arch_new(harvest, &e) : nil;   // extend an earlier harvest; one Metal no longer reads (other OS) is started over
        if (had && !g_harv) PLOG("[RED] cannot extend %s (%s): starting a new harvest", harvest.UTF8String, e.localizedDescription.UTF8String);
        if (!g_harv) g_harv = arch_new(nil, &e);
        if (g_harv) PLOG("harvest on: every pipeline created is added to %s", harvest.UTF8String);
        else PLOG("[RED] cannot create a harvest archive (%s): harvest off", e.localizedDescription.UTF8String);
    }
    g_archs = g_load ? @[g_load] : @[];
    g_pend = [NSMutableArray array];
}

static void miss_log(const char *what, const char *label) {
    uint64_t n = atomic_fetch_add(&g_miss, 1) + 1;
    if (n <= MISS_LOG_ALL || n % 100 == 0) PLOG("miss #%llu: %s pipeline %s compiled on the spot (not in the archive)%s", (unsigned long long)n, what, label ? label : "-",
                                               n == MISS_LOG_ALL ? "; further misses are logged every 100th" : "");
}

static BOOL arch_add(id<MTLBinaryArchive> a, id d, NSError **e) {
    return [d isKindOfClass:MTLRenderPipelineDescriptor.class] ? [a addRenderPipelineFunctionsWithDescriptor:d error:e] : [a addComputePipelineFunctionsWithDescriptor:d error:e];
}

static void harvest_add(MTLRenderPipelineDescriptor *rd, MTLComputePipelineDescriptor *cd, const char *label) {
    if (!g_harv) return;
    NSError *e = nil; BOOL ok;
    id d = rd ? [rd copy] : [cd copy];   // kept for harvest_write; a copy, as callers build each descriptor once but nothing promises they leave it alone
    [d setBinaryArchives:nil];
    os_unfair_lock_lock(&g_harv_lock);
    ok = arch_add(g_harv, d, &e);
    if (ok) [g_pend addObject:@[d, @(label ? label : "-")]];
    os_unfair_lock_unlock(&g_harv_lock);
    if (ok) atomic_fetch_add(&g_harvested, 1);
    else PLOG("[RED] harvest: pipeline %s not added: %s", label ? label : "-", e.localizedDescription.UTF8String);
}

id<MTLRenderPipelineState> psoarch_render(MTLRenderPipelineDescriptor *d, const char *label, NSError **err) {
    id<MTLDevice> dev = d.vertexFunction.device ?: MTLCreateSystemDefaultDevice();   // the function's own device, so this also works before psoarch_open; a missing function gets Metal's own error
    if (!g_load && !g_harv) return [dev newRenderPipelineStateWithDescriptor:d error:err];
    if (g_load) d.binaryArchives = g_archs;
    id<MTLRenderPipelineState> ps = g_load ? [dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil] : nil;
    if (ps) atomic_fetch_add(&g_hit, 1);
    else { if (g_load) miss_log("render", label); ps = [dev newRenderPipelineStateWithDescriptor:d error:err]; }
    if (ps) harvest_add(d, nil, label);   // only pipelines Metal accepted (a refused one is retried by the caller with another descriptor)
    return ps;
}

id<MTLComputePipelineState> psoarch_compute(id<MTLFunction> fn, const char *label, NSError **err) {
    id<MTLDevice> dev = fn.device ?: MTLCreateSystemDefaultDevice();
    if (!g_load && !g_harv) return [dev newComputePipelineStateWithFunction:fn error:err];
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];   // the descriptor equivalent of newComputePipelineStateWithFunction (only a descriptor can name archives)
    d.computeFunction = fn;
    if (g_load) d.binaryArchives = g_archs;
    id<MTLComputePipelineState> ps = g_load ? [dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil] : nil;
    if (ps) atomic_fetch_add(&g_hit, 1);
    else { if (g_load) miss_log("compute", label); ps = [dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:nil error:err]; }
    if (ps) harvest_add(nil, d, label);
    return ps;
}

// The pipelines of items that Metal writes to an archive: a scratch archive of them is written to the probe file, its halves are tried when that fails, and a single pipeline that fails is left out
static NSArray<NSArray *> *harvest_writable(NSArray<NSArray *> *items, NSString *probe) {
    if (!items.count) return items;
    id<MTLBinaryArchive> a = arch_new(nil, nil); NSError *e = nil;
    for (NSArray *it in items) arch_add(a, it[0], nil);
    if ([a serializeToURL:[NSURL fileURLWithPath:probe] error:&e]) return items;
    if (items.count == 1) { PLOG("[RED] harvest: pipeline %s left out, Metal cannot write it to an archive: %s", [items[0][1] UTF8String], e.localizedDescription.UTF8String); return @[]; }
    NSUInteger h = items.count / 2;
    return [harvest_writable([items subarrayWithRange:NSMakeRange(0, h)], probe) arrayByAddingObjectsFromArray:harvest_writable([items subarrayWithRange:NSMakeRange(h, items.count - h)], probe)];
}

static void harvest_write_(int repair) {
    os_unfair_lock_lock(&g_harv_lock);
    uint64_t n = atomic_load(&g_harvested);
    if (!g_harv || n == g_harv_written) { os_unfair_lock_unlock(&g_harv_lock); return; }
    // to a temporary file, then renamed over the archive: a kill mid-write (iOS, the 1.5 s exit fallback) leaves the previous archive intact
    NSString *tmp = [g_harv_path stringByAppendingString:@".tmp"]; NSError *e = nil;
    BOOL ok = [g_harv serializeToURL:[NSURL fileURLWithPath:tmp] error:&e] && !rename(tmp.fileSystemRepresentation, g_harv_path.fileSystemRepresentation);
    NSArray *lost = g_pend;
    if (ok) g_harv_written = n;
    if (ok || repair) g_pend = [NSMutableArray array];
    os_unfair_lock_unlock(&g_harv_lock);
    if (ok) { PLOG("harvest: %llu pipelines written to %s", (unsigned long long)n, g_harv_path.UTF8String); return; }
    PLOG("[RED] harvest: writing %s failed: %s", g_harv_path.UTF8String, e ? e.localizedDescription.UTF8String : strerror(errno));
    if (!repair) return;
    // A failed write also drops from the archive the pipelines added since the last good write (iPadOS 26: Metal's GPU binary packer refuses one of them, "expecting 'fragment' stage in pipeline
    // no. N", and the next write finds "Nothing to serialize"). So the archive is reopened from the last good file and those pipelines are added back, less the ones a probe write refuses
    NSString *probe = [g_harv_path stringByAppendingString:@".probe"];
    NSArray *keep = harvest_writable(lost, probe);
    unlink(probe.fileSystemRepresentation);
    NSError *le = nil; id<MTLBinaryArchive> a = arch_new([NSFileManager.defaultManager fileExistsAtPath:g_harv_path] ? g_harv_path : nil, &le);
    if (!a) { PLOG("[RED] harvest: cannot reopen %s (%s): the pipelines since the last write are lost", g_harv_path.UTF8String, le.localizedDescription.UTF8String); return; }
    os_unfair_lock_lock(&g_harv_lock);
    for (NSArray *it in [keep arrayByAddingObjectsFromArray:g_pend]) arch_add(a, it[0], nil);   // g_pend: added while the probes ran
    [g_pend insertObjects:keep atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, keep.count)]];
    g_harv = a; g_harv_written = n - 1;   // anything but n: the write below goes ahead
    os_unfair_lock_unlock(&g_harv_lock);
    PLOG("harvest: %lu of the %lu pipelines since the last write put back", (unsigned long)keep.count, (unsigned long)lost.count);
    harvest_write_(0);
}
static void harvest_write(void) { harvest_write_(1); }

void psoarch_flush(int wait) {
    if (wait && g_load) PLOG("%llu hits / %llu misses so far", (unsigned long long)g_hit, (unsigned long long)g_miss);   // suspend and exit (mtl_drain): how many pipelines still compiled at run time
    if (!g_harv || atomic_load(&g_harvested) == atomic_load(&g_harv_written)) return;
    if (wait) { harvest_write(); return; }
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("dm.nvn.pso-harvest", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    dispatch_async(q, ^{ harvest_write(); });
}

void psoarch_stats(uint64_t *hit, uint64_t *miss, uint64_t *harvested) { *hit = g_hit; *miss = g_miss; *harvested = g_harvested; }
