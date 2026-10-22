// pso_flexbench: measures what a render pipeline costs to create, per record of a pipeline manifest (pso_user.tsv format), with the runtime's own descriptors (nvn_mtl.m pso_desc).
// Modes (BENCH_MODE), each run in its own process so the system shader cache of one mode cannot serve another (the bundle id below gives this tool its own cache folder,
// $(getconf DARWIN_USER_CACHE_DIR)/com.anyswitch.psoflexbench, which BENCH_CLEAR=1 empties first):
//   classic  MTLDevice newRenderPipelineStateWithDescriptor: (what the runtime does today without an archive hit)
//   mtl4     MTL4Compiler with the same, fully specified descriptor (no depth / stencil formats: a Metal 4 descriptor has none)
//   flex     MTL4Compiler with colour formats, write masks and blending unspecialized, compiled once per distinct unspecialized key, then
//            newRenderPipelineStateBySpecializationWithDescriptor: for each record (the cost a pipeline keyed by its shader pair would add per new colour state)
// BENCH_SCRIPT=<out.mtlp-json>: also serialize the Metal 4 descriptors compiled (flex / mtl4) as a pipelines script, for metal-tt.
// BENCH_ARCHIVE=<archive>: classic looks each record up in this MTLBinaryArchive first (FailOnBinaryArchiveMiss); flex / mtl4 look the unspecialized (or full) pipelines up in this MTL4Archive first (MTL4Archive newRenderPipelineStateWithDescriptor:, nil = miss) and report hits.
// BENCH_SYNTH_VTX=1: replace each record's vertex layout by one built from the vertex shader's inputs (records made from bare shader pairs).
// Environment as pso_replay: BENCH_MANIFEST=<tsv>, DM_NVN_SHMAP, DM_MSL_DIR; BENCH_MAX=<records> (default all). Output: one BENCH line with counts and milliseconds.
// Built by make -C dm/gfx/tests GAME=<id> pso_flexbench (dm/gfx/README.md, pipeline coverage)
#include "../nvn/nvn_mtl.m"
#include <mach/mach.h>
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

// The runtime's own conversions (nvn_flexpso.m), so what is measured and serialized is what the runtime looks up
static MTL4RenderPipelineDescriptor *to4(MTLRenderPipelineDescriptor *d, NvShader *vs, NvShader *fs, int unspec) { return flexpso_desc(d, vs->lib, fs ? fs->lib : nil, unspec); }
static void specialize(MTL4RenderPipelineDescriptor *s, MTLRenderPipelineDescriptor *d) { flexpso_specialize(s, d); }
static double footprint_mb(void) {   // what iOS's memory limit counts (phys_footprint), not the file size
    task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? vi.phys_footprint / 1048576.0 : -1;
}
static double ms(uint64_t a, uint64_t b) { return (double)(b - a) / 1e6; }

int main(void) {
    const char *man = getenv("BENCH_MANIFEST"), *mode = getenv("BENCH_MODE") ?: "classic", *script = getenv("BENCH_SCRIPT"), *arch = getenv("BENCH_ARCHIVE");
    long max = getenv("BENCH_MAX") ? atol(getenv("BENCH_MAX")) : LONG_MAX;
    if (!man) { fprintf(stderr, "pso_flexbench: set BENCH_MANIFEST=<manifest.tsv> and BENCH_MODE=classic|mtl4|flex\n"); return 2; }
    int classic = !strcmp(mode, "classic"), flex = !strcmp(mode, "flex"), synth = getenv("BENCH_SYNTH_VTX") && atoi(getenv("BENCH_SYNTH_VTX"));
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_ARCHIVE", "off", 1);
    @autoreleasepool {
        if (getenv("BENCH_CLEAR") && atoi(getenv("BENCH_CLEAR"))) {
            char p[1024]; size_t n = confstr(_CS_DARWIN_USER_CACHE_DIR, p, sizeof p);
            NSString *c = [@(n ? p : "/nonexistent/") stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"none"];
            if (NSBundle.mainBundle.bundleIdentifier) [NSFileManager.defaultManager removeItemAtPath:c error:nil];
            fprintf(stderr, "cleared %s\n", c.UTF8String);
        }
        mtl_init(); shmap_load();
        NSError *e = nil;
        MTL4CompilerDescriptor *cd = [MTL4CompilerDescriptor new];
        id<MTL4PipelineDataSetSerializer> ser = nil;
        if (script) { MTL4PipelineDataSetSerializerDescriptor *sd = [MTL4PipelineDataSetSerializerDescriptor new]; sd.configuration = MTL4PipelineDataSetSerializerConfigurationCaptureDescriptors;
            ser = [g_dev newPipelineDataSetSerializerWithDescriptor:sd]; cd.pipelineDataSetSerializer = ser; }
        id<MTL4Compiler> comp = classic ? nil : [g_dev newCompilerWithDescriptor:cd error:&e];
        if (!classic && !comp) { fprintf(stderr, "[RED] no MTL4Compiler: %s\n", e.localizedDescription.UTF8String); return 1; }
        id<MTLBinaryArchive> ba = nil;   // classic: a MTLBinaryArchive (dmsh_psoarch.py output), looked up with FailOnBinaryArchiveMiss as nvn_psoarch.m does
        if (arch && classic) { MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new]; ad.url = [NSURL fileURLWithPath:@(arch)]; ba = [g_dev newBinaryArchiveWithDescriptor:ad error:&e];
            if (!ba) { fprintf(stderr, "[RED] cannot open binary archive %s: %s\n", arch, e.localizedDescription.UTF8String); return 1; } }
        double fp0 = footprint_mb(); uint64_t ta = bp_now();
        id<MTL4Archive> ar = arch && !classic ? [g_dev newArchiveWithURL:[NSURL fileURLWithPath:@(arch)] error:&e] : nil;
        double t_open = ms(ta, bp_now()), fp1 = footprint_mb();
        if (arch && !classic && !ar) { fprintf(stderr, "[RED] cannot open MTL4 archive %s: %s\n", arch, e.localizedDescription.UTF8String); return 1; }
        MTL4CompilerTaskOptions *opt = [MTL4CompilerTaskOptions new]; if (ar) opt.lookupArchives = @[ar];
        NSMutableDictionary<NSString *, NvShader *> *dict = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSData *, id<MTLRenderPipelineState>> *base = [NSMutableDictionary dictionary];
        long recs = 0, fail = 0, nbase = 0, hits = 0; double t_full = 0, t_base = 0, t_spec = 0, t_hit = 0, worst_spec = 0; long slow_spec = 0;
        NSString *txt = [NSString stringWithContentsOfFile:@(man) encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
            if (recs >= max) break;
            if (![line hasPrefix:@"R\t"]) continue;
            pso_skey sk; if (pso_skey_parse([line substringFromIndex:2].UTF8String, &sk) || sk.fz || sk.merged) continue;
            NSString *vk = warm_key(sk.vs, sizeof sk.vs), *fk = warm_key(sk.fs, sizeof sk.fs);
            NvShader *vs = vk.length ? warm_shader(dict, vk, sk.vs_stage) : nil, *fs = fk.length ? warm_shader(dict, fk, sk.fs_stage) : nil;
            if (!vs || (fk.length && !fs)) continue;
            pso_key k = sk.k; k.vs = (__bridge void *)vs; k.fs = (__bridge void *)fs; k.fsfn = NULL;
            if (vs->layer_out) {}   // pso_desc sets the input class
            MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, fs, nil, 0);
            if (synth) {   // BENCH_SYNTH_VTX=1: records with no vertex state (shader pairs from dmsh_pairs.py): every input a 4-component attribute of one interleaved stream, for sizing an archive
                MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor]; const nvn_refl *rf = &vs->rf;
                for (int v = 0; v < rf->nv; v++) { MTLVertexAttributeDescriptor *at = vd.attributes[rf->v[v].loc];
                    at.format = rf->v[v].ct == NVN_CT_UINT ? MTLVertexFormatUInt4 : rf->v[v].ct == NVN_CT_INT ? MTLVertexFormatInt4 : MTLVertexFormatFloat4; at.offset = 16 * v; at.bufferIndex = VB_SLOT(0); }
                if (rf->nv) vd.layouts[VB_SLOT(0)].stride = 16 * rf->nv;
                d.vertexDescriptor = vd;
            }
            recs++;
            @autoreleasepool {
                if (classic) {
                    uint64_t t0 = bp_now(); id ps = nil;
                    if (ba) { d.binaryArchives = @[ba]; ps = [g_dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
                        if (ps) { hits++; t_hit += ms(t0, bp_now()); continue; }
                        d.binaryArchives = nil; t0 = bp_now(); }
                    ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&e]; t_full += ms(t0, bp_now());
                    if (!ps) { fail++; if (fail < 5) fprintf(stderr, "[RED] classic %s: %s\n", pso_label(vs, fs).UTF8String, e.localizedDescription.UTF8String); }
                    continue;
                }
                MTL4RenderPipelineDescriptor *m = to4(d, vs, fs, flex);
                if (!m) { fail++; continue; }
                if (!flex) {
                    uint64_t t0 = bp_now(); id ps = ar ? [ar newRenderPipelineStateWithDescriptor:m error:nil] : nil;
                    if (ps) { hits++; t_hit += ms(t0, bp_now()); continue; }
                    t0 = bp_now(); ps = [comp newRenderPipelineStateWithDescriptor:m compilerTaskOptions:opt error:&e]; t_full += ms(t0, bp_now());
                    if (!ps) { fail++; if (fail < 5) fprintf(stderr, "[RED] mtl4 %s: %s\n", pso_label(vs, fs).UTF8String, e.localizedDescription.UTF8String); }
                    continue;
                }
                // flex: the unspecialized pipeline is keyed by the record without its colour state (formats, masks, blending) and without depth / stencil formats
                pso_skey u = sk; memset(u.k.cfmt, 0, sizeof u.k.cfmt); u.k.dfmt = u.k.sfmt = 0; u.k.blend_en = u.k.chmask = 0; memset(u.k.blend, 0, sizeof u.k.blend);
                NSData *uk = [NSData dataWithBytes:&u length:sizeof u];
                id<MTLRenderPipelineState> b = base[uk];
                if (!b) {
                    uint64_t t0 = bp_now(); b = ar ? [ar newRenderPipelineStateWithDescriptor:m error:nil] : nil;
                    if (b) { hits++; t_hit += ms(t0, bp_now()); }
                    else { if (ar && getenv("BENCH_MISSES")) fprintf(stderr, "BENCH miss %s\n", pso_label(vs, fs).UTF8String);
                        t0 = bp_now(); b = [comp newRenderPipelineStateWithDescriptor:m compilerTaskOptions:opt error:&e]; t_base += ms(t0, bp_now()); }
                    if (!b) { fail++; if (fail < 5) fprintf(stderr, "[RED] flex base %s: %s\n", pso_label(vs, fs).UTF8String, e.localizedDescription.UTF8String); continue; }
                    base[uk] = b; nbase++;
                }
                MTL4RenderPipelineDescriptor *s = (MTL4RenderPipelineDescriptor *)[b newRenderPipelineDescriptorForSpecialization];
                specialize(s, d);
                uint64_t t0 = bp_now(); id ps = [comp newRenderPipelineStateBySpecializationWithDescriptor:s pipeline:b error:&e]; double t = ms(t0, bp_now());
                t_spec += t; if (t > worst_spec) worst_spec = t; slow_spec += t > 2;
                if (!ps) { fail++; if (fail < 5) fprintf(stderr, "[RED] flex specialize %s: %s\n", pso_label(vs, fs).UTF8String, e.localizedDescription.UTF8String); }
            }
        }
        if (ser) { NSData *j = [ser serializeAsPipelinesScriptWithError:&e];
            if (!j || ![j writeToFile:@(script) atomically:YES]) fprintf(stderr, "[RED] pipelines script not written: %s\n", e.localizedDescription.UTF8String); }
        printf("BENCH mode %s records %ld failed %ld | full compile %.1f ms (%.2f ms each) | unspecialized %ld compiled %.1f ms (%.2f ms each) | specialize %.1f ms (%.3f ms each, worst %.2f, %ld over 2 ms) | archive hits %ld, %.1f ms\n",
               mode, recs, fail, t_full, recs ? t_full / recs : 0, flex ? nbase - hits : 0, t_base, flex && nbase - hits > 0 ? t_base / (nbase - hits) : 0, t_spec, recs ? t_spec / recs : 0, worst_spec, slow_spec, hits, t_hit);
        if (ar) printf("BENCH archive open %.1f ms; footprint %.1f MB before, %.1f MB after open, %.1f MB after the lookups\n", t_open, fp0, fp1, footprint_mb());
    }
    return 0;
}
