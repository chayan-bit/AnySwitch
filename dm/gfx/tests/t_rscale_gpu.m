// Internal resolution on the GPU (usage: t_rscale_gpu <scale>, run at 1, 1.5 and 2): real command chains through the production replay, each case drawn twice, into a texture
// the session scales (a GPU-only pool) and into a reference kept at 1x (its storage listed in g_rs_never, as after a demotion), then both read back as the guest reads them (ReadTexels)
// and compared: exactly where the result is scale-independent, within 2/255 where the scaled one samples a smooth gradient at other points (ReadTexels takes the host texel nearest
// each guest texel's centre). The shaders do what Ryujinx's translated shaders do with support_buffer.render_scale: FragCoord / render_scale[0], TexelFetchScale, TextureSizeUnscale
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
#define EXPECT(name, want, got) do { uint64_t w = (want), g = (got); count++; printf("%-72s expected %llu → got %llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w == g ? "✓" : "✗"); fail += w != g; } while (0)
enum { W = 64, H = 48 };   // eligible at any scale: not square after 64-byte alignment, not 16:9 below 360 lines
static float t_s;
static pool_t t_gpu = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED}, t_cpu = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED},
              t_virt = {.flags = NVN_MEMORY_POOL_FLAGS_VIRTUAL | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS};   // Super Mario Odyssey's G-buffer pool (0x2a1)
// scaled: 1 a GPU-only pool, 2 a CPU-visible pool, 3 a virtual pool (all created at the session scale), 0 the 1x reference (CPU-visible pool, kept 1x through g_rs_never)
static tex_t tex(int scaled, int w, int h, int format, int flags) {
    static uint64_t ser = 70000; static int64_t off; tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = ser++, .pool = scaled == 1 ? &t_gpu : scaled == 3 ? &t_virt : &t_cpu, .off = off += 0x100000};
    t.d.width = w; t.d.height = h; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = format; t.d.flags = flags;
    if (!scaled) { alias_key ak; memset(&ak, 0, sizeof ak); ak.pool = (uint64_t)(uintptr_t)t.pool; ak.off = t.off; ak.d = t.d; nvn_hm_put(&g_rs_never, &ak, (void *)(uintptr_t)NVN_RS_CPU); }
    return t;
}
static int reg(const tex_t *t) { static int id = 1500; mtl_reg_tex(id, t, NULL); return id++; }
// Command chain helpers (as t_xv.m)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c = {0}; if (posix_memalign((void **)&c.p, getpagesize(), 65536)) abort(); memset(c.p, 0, 65536); mtl_pool_add(c.p, 65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)z}; memcpy(c->p + c->n, &h, 8); if (n) memcpy(c->p + c->n + 8, a, n); c->n += z; }
static void set_rt(chain *c, const tex_t *t) {
    p_set_rt r = {.n = t ? 1 : 0}; r.color[0] = t; emit(c, OP_SET_RT, &r, sizeof r);
    p_viewports v = {.n = 1}; v.v[0][2] = W; v.v[0][3] = H; v.v[0][5] = 1; emit(c, OP_VIEWPORTS, &v, sizeof v);
    p_scissor sc = {0, 0, W, H}; emit(c, OP_SCISSOR, &sc, sizeof sc);
    ds_st d = {0, 0, NVN_DEPTH_FUNC_ALWAYS, 0, NVN_STENCIL_FUNC_ALWAYS, NVN_STENCIL_FUNC_ALWAYS}; p_bind_state x = {.kind = 5}; memcpy(x.bytes, &d, sizeof d); emit(c, OP_BIND_STATE, &x, sizeof x);
}
static void scissor(chain *c, int x, int y, int w, int h) { p_scissor sc = {x, y, w, h}; emit(c, OP_SCISSOR, &sc, sizeof sc); }
static void clear(chain *c, float r, float g, float b) { p_clear_color x = {.index = 0, .mask = 15, .rgba = {r, g, b, 1}}; emit(c, OP_CLEAR_COLOR, &x, sizeof x); }
static void prog(chain *c, prog_t *p) { p_bind_program b = {p, 3}; emit(c, OP_BIND_PROGRAM, &b, sizeof b); }
static void bind(chain *c, unsigned op, int id) { p_bind_handles b = {.stage = 1, .first = 0, .n = 1}; b.h[0] = (uint64_t)id; emit(c, op, &b, sizeof b); }
static void tdraw(chain *c) { p_draw d = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; emit(c, OP_DRAW, &d, sizeof d); }
static void copy(chain *c, const tex_t *s, const tex_t *d, NVNcopyRegion sr, NVNcopyRegion dr) { p_copy_t2t x = {.src = s, .dst = d, .sr = sr, .dr = dr}; emit(c, OP_COPY_T2T, &x, sizeof x); }
static void run(chain *c) {
    emit(c, OP_END, NULL, 0); state_reset(); memset(&R, 0, sizeof R); vis_clear(); g_vis_on = g_vis_counting = 0;
    mtl_sub_begin(); uint64_t h = (uint64_t)c->p; mtl_sub_index(&h, 1); mtl_exec(c->p);
    EXPECT("submission done", 1, mtl_wait(mtl_sub_commit(), 5000000000ull));
}
// ReadTexels of a guest region; the largest channel difference between two textures over it (bpp bytes per texel compared as bytes)
static uint8_t *rd(const tex_t *t, int x, int y, int w, int h, int bpp) { uint8_t *o = calloc((size_t)w * h, bpp); NVNcopyRegion r = {x, y, 0, w, h, 1}; mtl_read_texels(t, 0, 0, &r, o, (size_t)w * bpp, (size_t)w * h * bpp); return o; }
static int maxdiff(const tex_t *a, const tex_t *b, int x, int y, int w, int h) {
    uint8_t *p = rd(a, x, y, w, h, 4), *q = rd(b, x, y, w, h, 4); int m = 0;
    for (int i = 0; i < w * h * 4; i++) m = MAX(m, abs(p[i] - q[i]));
    free(p); free(q); return m;
}
// Programs: 0 gradient (FragCoord), 1 texel fetch (TexelFetchScale), 2 texture size (TextureSizeUnscale), 3 image store, 4 integer gradient, 5 host-pixel stripes (detail finer than a guest texel)
static prog_t t_pg[6]; static NvProg *t_keep[6];
static NSString *const k_msl = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint n [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; V o; o.p = float4(p[n], 0, 1); return o; }\n"
    "struct SB { float4 pad[12]; float4 rs[73]; };\n"   // render_scale at byte 192
    "struct A0 { constant SB *sb [[id(0)]]; };\n"
    "struct A1 { constant SB *sb [[id(0)]]; texture2d<float> t [[id(1)]]; };\n"
    "struct A3 { constant SB *sb [[id(0)]]; texture2d<float, access::write> img [[id(1)]]; };\n"
    "fragment float4 grad(V in [[stage_in]], constant A0 &a [[buffer(0)]]) { float2 g = in.p.xy / a.sb->rs[0].x; return float4(g.x / 64, g.y / 48, 0.5, 1); }\n"
    "fragment float4 fetch(V in [[stage_in]], constant A1 &a [[buffer(0)]]) { float s = a.sb->rs[1].x; int2 c = int2(in.p.xy / a.sb->rs[0].x);\n"
    "  if (s < 0) c = int2(float2(c) * -s + fmod(in.p.xy, -s)); else if (s != 1) c = int2(float2(c) * s); return a.t.read(uint2(c)); }\n"
    "fragment float4 tsize(V in [[stage_in]], constant A1 &a [[buffer(0)]]) { float s = a.sb->rs[1].x; float2 z = float2(a.t.get_width(), a.t.get_height());\n"
    "  if (s != 1) z /= abs(s); return float4(z.x / 255, z.y / 255, 0, 1); }\n"
    "fragment void istore(V in [[stage_in]], constant A3 &a [[buffer(0)]]) { float2 g = in.p.xy / a.sb->rs[0].x; a.img.write(float4(g.x / 64, g.y / 48, 0.5, 1), uint2(g)); }\n"
    "fragment uint4 igrad(V in [[stage_in]], constant A0 &a [[buffer(0)]]) { uint2 g = uint2(in.p.xy / a.sb->rs[0].x); return uint4(g.x + g.y * 64, 0, 0, 0); }\n"
    "fragment float4 hstripe(V in [[stage_in]], constant A0 &a [[buffer(0)]]) { return float4(fmod(floor(in.p.x), 4) / 3, 0, 0, a.sb->rs[0].x > 0); }\n";
static void programs(void) {
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:k_msl options:nil error:&e]; if (!l) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); abort(); }
    static NSString *const fs[6] = {@"grad", @"fetch", @"tsize", @"istore", @"igrad", @"hstripe"};
    for (int i = 0; i < 6; i++) {
        NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"vs"];
        NvShader *f = p->sh[1] = [NvShader new]; f->stage = 1; f->fn = [l newFunctionWithName:fs[i]]; f->rf.frag_coord = i != 2;
        f->rf.b[f->rf.nb++] = (nvn_rbind){.kind = NVN_RB_SUPPORT, .aid = 0, .sidx = NVN_RS_NONE};
        if (i == 1 || i == 2) f->rf.b[f->rf.nb++] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 1, .dtt = MTLTextureType2D, .sidx = 0, .sfl = NVN_RSF_NEEDS_SCALE};
        if (i == 3) f->rf.b[f->rf.nb++] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .aid = 1, .dtt = MTLTextureType2D, .sidx = 0, .sfl = NVN_RSF_IMAGE_STORE};
        f->ae = [f->fn newArgumentEncoderWithBufferIndex:0];
        t_pg[i].serial = 71000 + i; t_keep[i] = p; serial_put(t_pg[i].serial, p);
    }
}
// One chain per side: build(c, target, source) records the case into a chain for the scaled side and for the reference side
typedef void (*build_fn)(chain *, const tex_t *, int);
static void both(build_fn f, const tex_t *a, int ia, const tex_t *r, int ir) { chain c = chain_new(); f(&c, a, ia); run(&c); chain d = chain_new(); f(&d, r, ir); run(&d); }
static void b_grad(chain *c, const tex_t *t, int id) { (void)id; set_rt(c, t); clear(c, 0, 0, 0); prog(c, &t_pg[0]); tdraw(c); }
static void b_fetch(chain *c, const tex_t *t, int id) { set_rt(c, t); clear(c, 0, 0, 0); prog(c, &t_pg[1]); bind(c, OP_BIND_TEX, id); tdraw(c); }
static void b_size(chain *c, const tex_t *t, int id) { set_rt(c, t); prog(c, &t_pg[2]); bind(c, OP_BIND_TEX, id); tdraw(c); }
static void b_clears(chain *c, const tex_t *t, int id) { (void)id; set_rt(c, t); scissor(c, 3, 5, 11, 7); clear(c, 1, 0, 0);   // scissored clear opening the pass
    scissor(c, 0, 0, W, H); prog(c, &t_pg[0]); tdraw(c); scissor(c, 20, 9, 13, 21); clear(c, 0, 1, 0); }                          // a draw, then a scissored clear inside the open pass
static uint64_t t_qaddr;   // where b_occ reports its counter
static void b_occ(chain *c, const tex_t *t, int id) { (void)id; set_rt(c, t); scissor(c, 8, 8, 32, 24); uint64_t ty = NVN_COUNTER_TYPE_SAMPLES_PASSED; emit(c, OP_RESET_COUNTER, &ty, 8);
    prog(c, &t_pg[0]); tdraw(c); uint64_t rep[2] = {ty, t_qaddr}; emit(c, OP_REPORT_COUNTER, rep, 16); }
static void b_istore(chain *c, const tex_t *t, int id) { (void)t; set_rt(c, NULL); prog(c, &t_pg[3]); bind(c, OP_BIND_IMG, id); tdraw(c); }
static void b_igrad(chain *c, const tex_t *t, int id) { (void)id; set_rt(c, t); prog(c, &t_pg[4]); tdraw(c); }
static void b_stripe(chain *c, const tex_t *t, int id) { (void)id; set_rt(c, t); prog(c, &t_pg[5]); tdraw(c); }
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_INTERNAL_RES", argc > 1 ? argv[1] : "2", 1); mtl_init(); t_s = g_rs; printf("== internal resolution %gx ==\n", t_s); programs();
    char nm[160];
    // Gradient (FragCoord / render_scale[0]): the scaled target's host size and its ReadTexels against the 1x render
    tex_t a = tex(1, W, H, NVN_FORMAT_RGBA8, 0), r = tex(0, W, H, NVN_FORMAT_RGBA8, 0);
    both(b_grad, &a, 0, &r, 0);
    EXPECT("scaled target: host width ceil(64 S)", nvn_rs_host(W, t_s), tex_mtl(&a).width); EXPECT("scaled target: host height ceil(48 S)", nvn_rs_host(H, t_s), tex_mtl(&a).height);
    EXPECT("reference kept at 1x", W, tex_mtl(&r).width);
    EXPECT("FragCoord gradient: ReadTexels within 2/255 of 1x", 1, maxdiff(&a, &r, 0, 0, W, H) <= 2);
    // A render target in a pool the CPU can access (Super Mario Odyssey's window textures) or in a virtual pool (its G-buffer): the CPU reaches its texels only through ReadTexels,
    // copies and the CPU-write tracking, all scale-aware, so it is scaled like one in a GPU-only pool. Guest bytes copied in from a buffer (copy_b2t) then demote it to 1x, exactly
    { tex_t vt = tex(3, W, H, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); chain c = chain_new(); b_grad(&c, &vt, 0); run(&c);
      EXPECT("virtual pool target: host width ceil(64 S)", nvn_rs_host(W, t_s), tex_mtl(&vt).width);
      EXPECT("virtual pool target: ReadTexels within 2/255 of 1x", 1, maxdiff(&vt, &r, 0, 0, W, H) <= 2); }
    { tex_t cv = tex(2, W, H, NVN_FORMAT_RGBA8, 0); chain c = chain_new(); b_grad(&c, &cv, 0); run(&c);
      EXPECT("CPU-visible pool target: host width ceil(64 S)", nvn_rs_host(W, t_s), tex_mtl(&cv).width);
      EXPECT("CPU-visible pool target: ReadTexels within 2/255 of 1x", 1, maxdiff(&cv, &r, 0, 0, W, H) <= 2);
      uint32_t *src = NULL; if (posix_memalign((void **)&src, getpagesize(), (size_t)W * H * 4)) abort(); for (int i = 0; i < W * H; i++) src[i] = 0xff000000u | (uint32_t)i * 2654435761u >> 8;
      mtl_pool_add(src, (size_t)W * H * 4);
      chain d = chain_new(); p_copy_b2t x = {.src = (uint64_t)(uintptr_t)src, .tex = &cv, .r = {0, 0, 0, W, H, 1}}; emit(&d, OP_COPY_B2T, &x, sizeof x); run(&d);
      uint32_t *p = (uint32_t *)rd(&cv, 0, 0, W, H, 4); int bad = 0; for (int i = 0; i < W * H; i++) bad += p[i] != src[i]; free(p);
      EXPECT("CPU-visible pool target, guest bytes copied in: 1x after the copy", 1, rs_of(tex_mtl(&cv)) == 1.0f);
      EXPECT("CPU-visible pool target, guest bytes copied in: texels off", 0, bad); }
    // Full-screen texel fetch of a same-size target (the -t_s path): one host texel per host pixel, so the copy equals its source
    tex_t b = tex(1, W, H, NVN_FORMAT_RGBA8, 0), rb = tex(0, W, H, NVN_FORMAT_RGBA8, 0);
    both(b_fetch, &b, reg(&a), &rb, reg(&r));
    EXPECT("texel fetch (-S): equals its source texel for texel", 0, maxdiff(&b, &a, 0, 0, W, H));
    EXPECT("texel fetch (-S): ReadTexels within 2/255 of 1x", 1, maxdiff(&b, &rb, 0, 0, W, H) <= 2);
    // textureSize of a scaled texture reads the guest size
    tex_t z = tex(1, W, H, NVN_FORMAT_RGBA8, 0), rz = tex(0, W, H, NVN_FORMAT_RGBA8, 0);
    both(b_size, &z, reg(&a), &rz, reg(&r));
    { uint8_t *p = rd(&z, 5, 5, 1, 1, 4); EXPECT("textureSize: guest width", W, p[0]); EXPECT("textureSize: guest height", H, p[1]); free(p); }
    // Scissored clear opening the pass and a scissored clear in the open pass
    tex_t k = tex(1, W, H, NVN_FORMAT_RGBA8, 0), rk = tex(0, W, H, NVN_FORMAT_RGBA8, 0);
    both(b_clears, &k, 0, &rk, 0);
    { uint8_t *p = rd(&k, 0, 0, W, H, 4), *q = rd(&rk, 0, 0, W, H, 4); int bad = 0;   // cleared texels exact, the rest (gradient) within 2/255
        for (int i = 0; i < W * H; i++) { int in = q[4 * i] == 255 || q[4 * i + 1] == 255; for (int ch = 0; ch < 4; ch++) bad += in ? p[4 * i + ch] != q[4 * i + ch] : abs(p[4 * i + ch] - q[4 * i + ch]) > 2; }
        EXPECT("scissored clears (pass start and mid-pass): texels off", 0, bad); free(p); free(q); }
    // Copies: equal scale (whole host texels: blit; odd guest edges at 1.5x: resampling draw) and mismatched scale (scaled → 1x), against the same copies of the 1x render
    tex_t ce = tex(1, W, H, NVN_FORMAT_RGBA8, 0), cm = tex(0, W, H, NVN_FORMAT_RGBA8, 0), rce = tex(0, W, H, NVN_FORMAT_RGBA8, 0), rcm = tex(0, W, H, NVN_FORMAT_RGBA8, 0);
    { chain c = chain_new(); copy(&c, &a, &ce, (NVNcopyRegion){8, 8, 0, 16, 16, 1}, (NVNcopyRegion){0, 0, 0, 16, 16, 1}); copy(&c, &a, &ce, (NVNcopyRegion){7, 5, 0, 9, 9, 1}, (NVNcopyRegion){21, 1, 0, 9, 9, 1});
      copy(&c, &a, &cm, (NVNcopyRegion){4, 4, 0, 40, 30, 1}, (NVNcopyRegion){2, 3, 0, 40, 30, 1}); run(&c);
      chain d = chain_new(); copy(&d, &r, &rce, (NVNcopyRegion){8, 8, 0, 16, 16, 1}, (NVNcopyRegion){0, 0, 0, 16, 16, 1}); copy(&d, &r, &rce, (NVNcopyRegion){7, 5, 0, 9, 9, 1}, (NVNcopyRegion){21, 1, 0, 9, 9, 1});
      copy(&d, &r, &rcm, (NVNcopyRegion){4, 4, 0, 40, 30, 1}, (NVNcopyRegion){2, 3, 0, 40, 30, 1}); run(&d); }
    EXPECT("copy at equal scale, whole texels: within 2/255 of 1x", 1, maxdiff(&ce, &rce, 0, 0, 16, 16) <= 2);
    EXPECT("copy at equal scale, odd guest edges: within 2/255 of 1x", 1, maxdiff(&ce, &rce, 21, 1, 9, 9) <= 2);
    EXPECT("copy scaled → 1x: within 2/255 of 1x", 1, maxdiff(&cm, &rcm, 2, 3, 40, 30) <= 2);
    EXPECT("copy destinations keep their scale", 1, rs_of(tex_mtl(&ce)) == t_s && rs_of(tex_mtl(&cm)) == 1.0f);
    // Integer copy scaled → 1x (nearest texel read): exact
    tex_t ia = tex(1, W, H, NVN_FORMAT_R32UI, 0), ic = tex(0, W, H, NVN_FORMAT_R32UI, 0);
    { chain c = chain_new(); b_igrad(&c, &ia, 0); copy(&c, &ia, &ic, (NVNcopyRegion){0, 0, 0, W, H, 1}, (NVNcopyRegion){0, 0, 0, W, H, 1}); run(&c);
      uint32_t *p = (uint32_t *)rd(&ic, 0, 0, W, H, 4); int bad = 0; for (int i = 0; i < W * H; i++) bad += p[i] != (uint32_t)(i % W + i / W * 64); free(p);
      EXPECT("integer copy scaled → 1x: texels off", 0, bad); EXPECT("integer source stays scaled", 1, rs_of(tex_mtl(&ia)) == t_s); }
    // ReadTexels of an integer scaled target: exact (nearest)
    { uint32_t *p = (uint32_t *)rd(&ia, 3, 2, 20, 10, 4); int bad = 0; for (int y = 0; y < 10; y++) for (int x = 0; x < 20; x++) bad += p[y * 20 + x] != (uint32_t)(3 + x + (2 + y) * 64); free(p);
      EXPECT("ReadTexels of a scaled integer target: texels off", 0, bad); }
    // Occlusion query: samples passed counted in guest pixels
    { uint64_t *q = NULL; if (posix_memalign((void **)&q, getpagesize(), getpagesize())) abort(); memset(q, 0, getpagesize()); mtl_pool_add(q, getpagesize());
      tex_t o = tex(1, W, H, NVN_FORMAT_RGBA8, 0), ro = tex(0, W, H, NVN_FORMAT_RGBA8, 0);
      t_qaddr = (uint64_t)(uintptr_t)q; chain c = chain_new(); b_occ(&c, &o, 0); run(&c); mtl_finish_gpu(); uint64_t n1 = q[0];
      t_qaddr = (uint64_t)(uintptr_t)(q + 4); chain d = chain_new(); b_occ(&d, &ro, 0); run(&d); mtl_finish_gpu(); uint64_t n0 = q[4];
      EXPECT("occlusion query, 1x reference: 32 x 24 samples", 32 * 24, n0); EXPECT("occlusion query, scaled pass: equal to 1x", n0, n1); }
    // Attachment-less pass storing to an image: stays 1x (render_scale[0] = 1), and the image (IMAGE flag, scaled at creation) is demoted when bound
    tex_t im = tex(1, W, H, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_IMAGE), rim = tex(0, W, H, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_IMAGE);
    if (t_s != 1.0f) EXPECT("IMAGE-flagged target: created scaled", 1, rs_of(tex_mtl(&im)) == t_s);
    both(b_istore, &im, reg(&im), &rim, reg(&rim));
    EXPECT("image bound for store: 1x after the pass", 1, rs_of(tex_mtl(&im)) == 1.0f);
    EXPECT("attachment-less image-store pass: equal to 1x", 0, maxdiff(&im, &rim, 0, 0, W, H));
    // A 1x pass sampling a scaled texture (a bloom chain's first downsample, its kernel sized in guest texels) reads the texture's 1x copy, so it sees what a 1x render
    // would give it: the same as copying the texture to 1x first (both a bilinear resample), not the host texels that happen to sit under its guest-sized taps
    { tex_t hs = tex(1, W, H, NVN_FORMAT_RGBA8, 0), h1 = tex(0, W, H, NVN_FORMAT_RGBA8, 0), o = tex(0, W, H, NVN_FORMAT_RGBA8, 0), ro = tex(0, W, H, NVN_FORMAT_RGBA8, 0);
      int ihs = reg(&hs), ih1 = reg(&h1); uint64_t n0 = g_lo_count;
      chain c = chain_new(); b_stripe(&c, &hs, 0); copy(&c, &hs, &h1, (NVNcopyRegion){0, 0, 0, W, H, 1}, (NVNcopyRegion){0, 0, 0, W, H, 1}); b_fetch(&c, &o, ihs); b_fetch(&c, &ro, ih1); run(&c);
      EXPECT("scaled texture sampled in a 1x pass: equal to its copy to 1x", 0, maxdiff(&o, &ro, 0, 0, W, H));
      EXPECT("scaled texture sampled in a 1x pass: 1x copies made", t_s != 1.0f, g_lo_count - n0); }
    snprintf(nm, sizeof nm, "== %gx: %d checks, %d failed ==", t_s, count, fail); puts(nm); return fail != 0;
}}
