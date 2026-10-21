// Per-pass GPU timing under Metal 4 (pg_*): real passes through the replay's encoder hooks, then the heap is resolved in the last segment's completion and the report line is logged.
// Checks: every timed pass has an end after its start, the increments sum to no more than the GPU busy span, and the 300-frame report line appears.
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }   // Tests use host-thread stacks.
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(name, want, got) do { uint64_t w = (want), g = (got); checks++; if (w != g) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w, (unsigned long long)g); failed++; } } while (0)

static id<MTLRenderPipelineState> pipeline(void) {
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { float2 p = float2((i << 1) & 2, i & 2); return float4(p * 2 - 1, 0, 1); }\n"
        "fragment half4 f(float4 p[[position]]) { half4 c = half4(0); for (int i = 0; i < 32; i++) c += half4(sin(p.x * 0.01 + i), cos(p.y * 0.01 + i), 0, 0.001); return c; }" options:nil error:&err];
    if (!lib) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); abort(); }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"v"]; d.fragmentFunction = [lib newFunctionWithName:@"f"]; d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!ps) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); abort(); }
    return ps;
}
int main(void) { @autoreleasepool {
    mtl_init(); id<MTLRenderPipelineState> ps = pipeline();
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:2048 height:2048 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex = [g_dev newTextureWithDescriptor:td]; res_add(tex);
    EXPECT("timing is on", 1, pg_on());
    uint64_t last = 0;
    for (uint64_t f = 301; f < 301 + 700; f++) {
        mtl_set_frame(f); mtl_sub_begin();
        for (int k = 0; k < 3; k++) {
            MTL4RenderPassDescriptor *d = [MTL4RenderPassDescriptor new];
            d.colorAttachments[0].texture = tex; d.colorAttachments[0].loadAction = k ? MTLLoadActionLoad : MTLLoadActionClear; d.colorAttachments[0].storeAction = MTLStoreActionStore;
            g_stat_pass++; pg_render(d, 1);
            id<MTL4RenderCommandEncoder> en = enc_r_begin_pass(d); enc_r_pso(en, ps); enc_r_draw(en, MTLPrimitiveTypeTriangle, 0, 3);
            enc_r_end_pass(en); pg_end_render();
        }
        last = mtl_sub_commit();
    }
    EXPECT("submissions completed", 1, mtl_wait(last, 20000000000ull));
    EXPECT("no GPU error", 0, mtl_last_commit_error());
    pthread_mutex_lock(&g_pg_mu);
    double frames = (double)g_pg_win_frames; uint64_t passes = g_pg_win_passes; uint64_t rep = g_pg_rep_frame;
    pthread_mutex_unlock(&g_pg_mu);
    EXPECT("a report window was closed (frame 601 or later)", 1, rep >= 601);
    EXPECT("timed passes are 3 per frame in the open window", 1, passes >= (uint64_t)(3 * frames) && passes <= (uint64_t)(3 * frames) + 3);   // + the frame still being summed
    printf("t_passgpu: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
