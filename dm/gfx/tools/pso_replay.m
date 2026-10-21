// pso_replay: creates every pipeline of a manifest (pso_user.tsv format) through the host's own warm-up (nvn_mtl.m warm_worker -> pso_desc -> psoarch_render), with no game running.
// With DM_PSO_HARVEST it is a harvest run: the pipeline script it writes holds exactly the descriptors the runtime builds for those records, ready for dmsh_psoarch.py.
// With DM_PSO_ARCHIVE it checks an archive: every record must hit (a miss means the archive's key differs from what the runtime looks up).
// Environment: DM_PSO_MANIFEST=<tsv> (required), DM_NVN_SHMAP=<shader_map.tsv>, DM_MSL_DIR=<library folder holding b-<V>/>, DM_PSO_HARVEST=<out.metallib>, DM_PSO_ARCHIVE=<archive>|off
// Built by make -C dm/gfx/tests GAME=<id> pso_replay; driven by dmsh_psoexpand.py --build (docs/stageB-pipeline-expansion.md)
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }   // hle_nvn.c symbols nvn_mtl.m links against; no program is ever drawn here
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

int main(void) {
    const char *m = getenv("DM_PSO_MANIFEST");
    if (!m || !*m || !strcmp(m, "off")) { fprintf(stderr, "pso_replay: set DM_PSO_MANIFEST=<manifest.tsv> (and DM_PSO_HARVEST and / or DM_PSO_ARCHIVE)\n"); return 2; }
    @autoreleasepool {
        mtl_init();
        shmap_load();   // loads the shader map and starts the warm-up on the manifest (warm_start)
        mtl_warm_wait(INT_MAX);
        psoarch_flush(1);
        uint64_t hit, miss, harv; psoarch_stats(&hit, &miss, &harv);
        printf("PSO_REPLAY render %llu compute %llu specialized skipped %llu; archive %llu hits / %llu misses; %llu harvested\n",
               g_warm_rps, g_warm_cps, g_warm_skip_fz, hit, miss, harv);
    }
    return 0;
}
