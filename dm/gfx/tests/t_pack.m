// Shader packs through the host's own loader (nvn_mtl.m shader_get): every key given loads with its pack's renamed entry points, and gives the same shader as its own library would
// (entry point, near=0 entry, layer flag, argument buffer length). Driven by test_pack.py, which builds the folder: t_pack <library root> <key>:<stage>...
// Environment as the host: DM_MSL_DIR, DM_NVN_SHMAP; DM_SHADER_PACKS=off loads one library per shader
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

int main(int argc, char **argv) {
    @autoreleasepool {
        mtl_init();
        shmap_load();
        printf("packs %s\n", g_pack_idx ? "on" : "off");
        for (int i = 1; i < argc; i++) {
            char key[32]; int stage = 0;
            if (sscanf(argv[i], "%23[^:]:%d", key, &stage) != 2) { fprintf(stderr, "bad argument %s\n", argv[i]); return 2; }
            for (int z = 0; z < 2; z++) {   // both depth conventions: main0, then main0_z for vertex shaders that have it
                if (stage != 0 && z) break;
                mtl_set_depth_zero(z);
                [g_shcache removeAllObjects]; [g_sh_shared removeAllObjects];   // both shader tables: the depth convention picks the entry at load
                NvShader *o = shader_get(@(key), stage);
                if (!o || !o->fn) { printf("FAIL %s: not loaded\n", key); return 1; }
                NSUInteger rl = o->arg_len ? [o->fn newArgumentEncoderWithBufferIndex:0].encodedLength : 0;   // the layout the encoder is built from (8 bytes an entry) is the function's own
                if (rl != o->arg_len) { printf("FAIL %s: argument buffer %lu bytes, the function reflects %lu\n", key, (unsigned long)o->arg_len, (unsigned long)rl); return 1; }
                printf("%s z%d fn=%s arg_len=%lu layer=%d\n", key, z, o->fn.name.UTF8String, (unsigned long)o->arg_len, o->layer_out);
            }
        }
    }
    return 0;
}
