// Render-target heaps (nvn_mtl.m, rh_*; usage: t_rtheap <scale>, run at 1 and 2): GPU-owned textures whose storage overlaps in one pool share a Metal placement heap, laid out like the
// guest pool: textures whose guest ranges overlap share host bytes, textures whose guest ranges are disjoint never do (checked on the host ranges and on the GPU: two targets cleared one
// after the other keep their own colours), a texture created on bytes another one used is not zeroed over them, a texture with no overlapping neighbour stays standalone, and the
// heaps go with their pool. Odyssey's layout: 1600x900 targets 0.4 MB apart in a virtual compressible pool, and one storage used as R11G11B10F and as R32F
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft hle_g_ft
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { uint64_t w = (want), g = (got); count++; printf("%-78s expected %llu → got %llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w == g ? "✓" : "✗"); fail += w != g; } while (0)
enum { W = 1600, H = 900 };
static pool_t t_virt = {.flags = NVN_MEMORY_POOL_FLAGS_VIRTUAL | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS};   // Odyssey's G-buffer pool (0x2a1)
static uint64_t g_ser = 90000;
static tex_t tex_in(pool_t *pool, int64_t off, int format, uint32_t w, uint32_t h, int flags) {
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = g_ser++, .pool = pool, .off = off};
    t.d.width = w; t.d.height = h; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = format; t.d.flags = flags;
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t);
    return t;
}
static tex_t tex(int64_t off, int format) { return tex_in(&t_virt, off, format, W, H, NVN_TEXTURE_FLAGS_COMPRESSIBLE); }
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c = {0}; if (posix_memalign((void **)&c.p, getpagesize(), 65536)) abort(); memset(c.p, 0, 65536); mtl_pool_add(c.p, 65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)z}; memcpy(c->p + c->n, &h, 8); if (n) memcpy(c->p + c->n + 8, a, n); c->n += z; }
static void clear_rt(chain *c, const tex_t *t, float r, float g, float b) {
    p_set_rt s = {.n = 1}; s.color[0] = t; emit(c, OP_SET_RT, &s, sizeof s);
    p_viewports v = {.n = 1}; v.v[0][2] = W; v.v[0][3] = H; v.v[0][5] = 1; emit(c, OP_VIEWPORTS, &v, sizeof v);
    p_scissor sc = {0, 0, W, H}; emit(c, OP_SCISSOR, &sc, sizeof sc);
    p_clear_color x = {.index = 0, .mask = 15, .rgba = {r, g, b, 1}}; emit(c, OP_CLEAR_COLOR, &x, sizeof x);
}
static void run(chain *c) {
    emit(c, OP_END, NULL, 0); state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin(); uint64_t h = (uint64_t)c->p; mtl_sub_index(&h, 1); mtl_exec(c->p);
    EXPECT("submission done", 1, mtl_wait(mtl_sub_commit(), 5000000000ull));
}
static uint32_t texel(const tex_t *t, int x, int y) { uint32_t o = 0; NVNcopyRegion r = {x, y, 0, 1, 1, 1}; mtl_read_texels(t, 0, 0, &r, (uint8_t *)&o, 4, 4); return o; }
static int overlap(id<MTLTexture> a, id<MTLTexture> b) { return a.heapOffset < b.heapOffset + b.allocatedSize && b.heapOffset < a.heapOffset + a.allocatedSize; }
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_INTERNAL_RES", argc > 1 ? argv[1] : "1", 1); mtl_init(); printf("== internal resolution %gx ==\n", g_rs);
    // A, B (0.4 MB after A), C (0.4 MB after B: disjoint from A), E (A's storage as R32F); D far away, overlapping nothing
    int64_t L = 0; { tex_t probe = {0}; probe.d.width = W; probe.d.height = H; probe.d.depth = probe.d.levels = 1; probe.d.target = NVN_TEXTURE_TARGET_2D; probe.d.format = NVN_FORMAT_RGBA8; nvn_tex_layout(&probe.d, &probe.L); L = (int64_t)probe.L.size; }
    int64_t step = L - 0x61600 > L / 2 ? L / 2 + 0x1000 : L - 0x61600;   // B overlaps A and C, C does not overlap A
    tex_t A = tex(0, NVN_FORMAT_R11G11B10F), B = tex(step, NVN_FORMAT_RGBA8), C = tex(2 * step, NVN_FORMAT_R11G11B10F), E = tex(0, NVN_FORMAT_R32F), D = tex(0x4000000, NVN_FORMAT_RGBA8);
    EXPECT("C's guest range is disjoint from A's", 1, C.off >= A.off + (int64_t)A.L.size);
    chain c1 = chain_new(); clear_rt(&c1, &A, 1, 0, 0); clear_rt(&c1, &C, 0, 0, 1); clear_rt(&c1, &D, 0, 1, 0); run(&c1);
    id<MTLTexture> a = tex_get(A.serial), cc = tex_get(C.serial), d = tex_get(D.serial);
    EXPECT("A is placed in a render-target heap", 1, a.heap != nil);
    EXPECT("C shares A's heap", 1, a.heap && cc.heap == a.heap);
    EXPECT("D (no overlapping neighbour) stays standalone", 1, d && !d.heap);
    EXPECT("A and C (guest-disjoint) do not share host bytes", 0, a.heap && overlap(a, cc));
    uint64_t sep = 0; for (int i = 0; i < 4; i++) { tex_t *t = (tex_t *[]){&A, &B, &C, &E}[i]; alias_key ak; memset(&ak, 0, sizeof ak); ak.d = t->d; tex_t q = {0}; q.d = t->d; MTLTextureDescriptor *td = tex_desc(&q, 0);
        if (g_rs != 1.0f) { td.width = nvn_rs_host(W, g_rs); td.height = nvn_rs_host(H, g_rs); } sep += [g_dev heapTextureSizeAndAlignWithDescriptor:td].size; }
    EXPECT("the heap is smaller than the four textures apart", 1, a.heap && a.heap.size < sep);
    // B on A's and C's bytes, E on A's: placed over used bytes, so neither is zeroed (A keeps red, C keeps blue)
    mtl_sub_begin(); id<MTLTexture> b = tex_mtl(&B), e = tex_mtl(&E); EXPECT("B and E created", 1, mtl_wait(mtl_sub_commit(), 5000000000ull) && b && e);
    EXPECT("B shares the heap and overlaps A and C", 1, b.heap == a.heap && overlap(a, b) && overlap(b, cc));
    EXPECT("E (A's storage as R32F) sits on A's bytes", 1, e.heap == a.heap && e.heapOffset == a.heapOffset);
    uint32_t red = texel(&A, W / 2, H / 2), blue = texel(&C, W / 2, H / 2);
    EXPECT("A still red after B and E were created (not zeroed)", 0x3c0, red);   // R11G11B10F 1, 0, 0
    EXPECT("C still blue after B and E were created", 0x1e0u << 22, blue);
    // Disjoint guest ranges keep their content through writes to each other: clear C green, A stays red
    chain c2 = chain_new(); clear_rt(&c2, &C, 0, 1, 0); run(&c2);
    EXPECT("A unchanged by a clear of C", red, texel(&A, W / 2, H / 2));
    uint32_t hn; uint64_t hb, hp, hs; rh_stats(&hn, &hb, &hp, &hs);
    EXPECT("one heap, four textures placed, two on used bytes", 1, hn == 1 && hp == 4 && hs == 2);
    mtl_alias_drop_pool(&t_virt); rh_stats(&hn, &hb, &hp, &hs);
    EXPECT("the heap goes with its pool", 0, hn);
    // A pool of render targets (as Odyssey's G-buffer pool): one heap for the whole pool, laid out like it, so a description the game initializes later anywhere in the pool (another
    // resolution, a target without the compressible flag) is placed in it too instead of getting its own memory
    {
        pool_t rt = t_virt; rt.size = (uint64_t)(2 * step) + (uint64_t)L;
        tex_t F0 = tex_in(&rt, 0, NVN_FORMAT_R11G11B10F, W, H, NVN_TEXTURE_FLAGS_COMPRESSIBLE), F1 = tex_in(&rt, step, NVN_FORMAT_RGBA8, W, H, NVN_TEXTURE_FLAGS_COMPRESSIBLE),
              F2 = tex_in(&rt, 2 * step, NVN_FORMAT_R11G11B10F, W, H, NVN_TEXTURE_FLAGS_COMPRESSIBLE), F3 = tex_in(&rt, 0, NVN_FORMAT_R32F, W, H, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
        chain c3 = chain_new(); clear_rt(&c3, &F0, 1, 0, 0); clear_rt(&c3, &F2, 0, 0, 1); run(&c3);
        id<MTLTexture> f0 = tex_get(F0.serial), f2 = tex_get(F2.serial);
        EXPECT("the pool's first target is in a heap", 1, f0.heap != nil);
        NvRtHeap *ph = nil; for (NvRtHeap *x in g_rh_heaps) if (x->heap == f0.heap) ph = x;
        EXPECT("one heap for the whole pool, smaller than its four textures apart", 1, ph && ph->lo == 0 && ph->hi == (int64_t)rt.size && f2.heap == f0.heap && f0.heap.size < sep);
        EXPECT("guest-disjoint F0 and F2 do not share host bytes", 0, f0.heap && overlap(f0, f2));
        // Initialized after the heap was made: the same storage at another resolution, and a target without the compressible flag
        tex_t G = tex_in(&rt, step / 2, NVN_FORMAT_RGBA8, W * 3 / 4, H * 3 / 4, NVN_TEXTURE_FLAGS_COMPRESSIBLE), N = tex_in(&rt, step + step / 2, NVN_FORMAT_RGBA8, W / 2, H / 2, 0);
        mtl_sub_begin(); id<MTLTexture> gt = tex_mtl(&G), nn = tex_mtl(&N), f1 = tex_mtl(&F1), f3 = tex_mtl(&F3);
        EXPECT("later textures created", 1, mtl_wait(mtl_sub_commit(), 5000000000ull) && gt && nn && f1 && f3);
        EXPECT("a later description at another resolution is placed in the pool heap", 1, f0.heap && gt.heap == f0.heap);
        EXPECT("a later non-compressible target is placed in the pool heap", 1, f0.heap && nn.heap == f0.heap);
        EXPECT("F3 (F0's storage as R32F) sits on F0's bytes", 1, f0.heap && f3.heap == f0.heap && f3.heapOffset == f0.heapOffset);
        EXPECT("F0 still red after the later ones were created", 0x3c0, texel(&F0, W / 2, H / 2));
        EXPECT("F2 still blue after the later ones were created", 0x1e0u << 22, texel(&F2, W / 2, H / 2));
        mtl_alias_drop_pool(&rt); rh_stats(&hn, &hb, &hp, &hs);
        EXPECT("the pool heap goes with its pool", 0, hn);
    }
    printf("%d / %d checks failed\n", fail, count);
    printf(fail ? "RTHEAP FAIL\n" : "RTHEAP OK: overlapping targets share a placement heap laid out like the pool, disjoint ones never share bytes, no zeroing over used bytes, isolated targets standalone, a pool of render targets in one heap that also takes descriptions initialized later, heaps freed with the pool\n");
    return fail != 0;
} }
