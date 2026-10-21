// Precompiled pipeline archive round trip (nvn_psoarch.m), no game files: descriptor -> harvest archive -> lookup hit; a pipeline not in the archive misses and still compiles; no archive = plain compiles.
// Usage: t_psoarch <lib.metallib> <work dir> [<archive built by dmsh_psoarch.py>] (test_psoarch.py builds the library from its own MSL and runs both steps)
#import <Metal/Metal.h>
#include <assert.h>
#include "../nvn/nvn_psoarch.h"

static id<MTLDevice> g_dev;
static id<MTLLibrary> g_lib;

static MTLRenderPipelineDescriptor *rdesc(NSString *fs, MTLPixelFormat cf) {   // fspec: a fragment specialized by a function constant, as the readable-tile versions are (bf_fn)
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; NSError *e = nil;
    d.vertexFunction = [g_lib newFunctionWithName:@"vmain"];
    if ([fs isEqual:@"fspec"]) { MTLFunctionConstantValues *v = [MTLFunctionConstantValues new]; int one = 1; [v setConstantValue:&one type:MTLDataTypeInt atIndex:0];
        d.fragmentFunction = [g_lib newFunctionWithName:fs constantValues:v error:&e]; }
    else d.fragmentFunction = [g_lib newFunctionWithName:fs];
    assert(d.vertexFunction && d.fragmentFunction);
    d.colorAttachments[0].pixelFormat = cf; d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatHalf4; vd.attributes[0].offset = 8; vd.attributes[0].bufferIndex = 1; vd.layouts[1].stride = 16;
    d.vertexDescriptor = vd; d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    return d;
}

static void create_all(void) {   // the three pipelines of the harvest: two render (one specialized) and one compute
    NSError *e = nil;
    assert(psoarch_render(rdesc(@"fmain", MTLPixelFormatBGRA8Unorm), "vmain/fmain", &e));
    assert(psoarch_render(rdesc(@"fspec", MTLPixelFormatRGBA16Float), "vmain/fspec", &e));
    assert(psoarch_compute([g_lib newFunctionWithName:@"kmain"], "kmain", &e));
}

static void expect(uint64_t hit, uint64_t miss, uint64_t harvested, const char *what) {
    uint64_t h, m, n; psoarch_stats(&h, &m, &n);
    if (h != hit || m != miss || n != harvested) { fprintf(stderr, "FAIL %s: hit %llu miss %llu harvested %llu, want %llu / %llu / %llu\n", what,
        (unsigned long long)h, (unsigned long long)m, (unsigned long long)n, (unsigned long long)hit, (unsigned long long)miss, (unsigned long long)harvested); exit(1); }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: t_psoarch <lib.metallib> <work dir> [<offline archive>]\n"); return 2; }
    @autoreleasepool {
        g_dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])]; assert(bytes);
        g_lib = [g_dev newLibraryWithData:dispatch_data_create(bytes.bytes, bytes.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&e];   // from memory, as the host loads (lib_from_file)
        assert(g_lib);
        NSString *work = @(argv[2]), *harv = [work stringByAppendingPathComponent:@"harvest.metallib"];
        [NSFileManager.defaultManager removeItemAtPath:harv error:nil];

        psoarch_open(g_dev, nil, harv); create_all(); psoarch_flush(1);   // harvest
        expect(0, 0, 3, "harvest");
        assert([NSFileManager.defaultManager fileExistsAtPath:harv]);

        psoarch_open(g_dev, harv, nil); create_all();   // lookup: every harvested pipeline is found
        expect(3, 0, 0, "lookup");
        assert(psoarch_render(rdesc(@"fmain", MTLPixelFormatRGBA8Unorm), "vmain/fmain other format", &e));   // a descriptor not harvested misses, and is compiled anyway
        expect(3, 1, 0, "miss");

        psoarch_open(g_dev, harv, harv); create_all(); psoarch_flush(1);   // extending an earlier harvest keeps what it had
        expect(3, 0, 3, "extend");

        psoarch_open(g_dev, [work stringByAppendingPathComponent:@"none.metallib"], nil); create_all();   // no archive: plain compiles, nothing counted
        expect(0, 0, 0, "no archive");

        // dmsh_psoarch.py output (metal-tt), same lookups: the plain pipelines hit; the specialized one misses (compiled as usual): a harvested pipeline script leaves out pipelines of
        // functions specialized at run time, and with them stored there (MTLFunctionOptionStoreFunctionInMetalPipelinesScript) metal-tt's binary still has another key (Xcode 27, macOS 27)
        if (argc > 3) { psoarch_open(g_dev, @(argv[3]), nil); create_all(); expect(2, 1, 0, "offline archive"); }
    }
    printf("PSOARCH OK harvest 3 -> lookup 3 hits, unharvested descriptor 1 miss (compiled), extend keeps entries, no archive = plain compile%s\n", argc > 3 ? ", offline archive 2 hits + specialized 1 miss" : "");
    return 0;
}
