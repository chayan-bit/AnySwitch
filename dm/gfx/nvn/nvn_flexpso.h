// Flexible pipelines (dm/gfx/README.md, pipeline coverage): render pipelines made through Metal 4's MTL4Compiler with colour formats, write masks and blending left unspecialized, so one
// precompiled pipeline per shader pair (and vertex layout) serves every colour state. The unspecialized pipeline comes from a shipped MTL4Archive (dm/pso_flex.metallib, built by
// tools/dmsh_flexarch.py) or is compiled, then specialized for the draw's colour state. All of it runs on worker threads: the render thread only asks, and skips the draw until the pipeline exists.
// Game-agnostic: keys are the caller's pipeline keys as bytes; the archive is keyed by Metal (function hashes + descriptor).
// Switches: DM_PSO_FLEX=1 turns it on (default off: pipelines are made as before, nvn_psoarch.m); DM_PSO_FLEX_ARCHIVE=path|off (default pso_flex.metallib beside the shader map);
// DM_PSO_FLEX_WAIT_US=n: the render thread waits at most n microseconds for a pipeline it just asked for (default 0: never waits; -1: waits until it exists, for pixel comparisons only).
#pragma once
#import <Metal/Metal.h>

// klen / ulen: byte length of the full key (every state the pipeline depends on) and of the unspecialized key (the same without colour formats, write masks, blending and depth / stencil formats)
void flexpso_open(id<MTLDevice> dev, NSString *archive, size_t klen, size_t ulen);
int flexpso_on(void);
// The Metal 4 descriptor of a classic one. Functions are named by vlib / flib (the libraries of d's vertex and fragment functions). unspec: colour formats, write masks and blending left for
// specialization. Shared with tools/pso_flexbench.m, so the archive build serializes exactly the descriptors the runtime looks up
MTL4RenderPipelineDescriptor *flexpso_desc(MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, int unspec);
// The colour state of d written into s (a descriptor from newRenderPipelineDescriptorForSpecialization)
void flexpso_specialize(MTL4RenderPipelineDescriptor *s, MTLRenderPipelineDescriptor *d);
// Render thread, never blocks (beyond DM_PSO_FLEX_WAIT_US). Returns the pipeline once a worker made it (once: the caller caches it). Otherwise starts it the first time it is asked for
// (mk builds the classic descriptor, only then) and returns nil with *pending = 1: skip the draw. nil with *pending = 0: the flexible path could not make it, make it as before
id<MTLRenderPipelineState> flexpso_get(const void *key, const void *ukey, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, MTLRenderPipelineDescriptor *(^mk)(void), int *pending);
// Ahead of the draw, any thread: starts the pipeline if it is new and returns at once; the finished pipeline waits for the draw's flexpso_get. soon: the draw is in the submission
// being replayed (user-initiated work), else a guess made at record time (utility)
void flexpso_kick(const void *key, const void *ukey, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, MTLRenderPipelineDescriptor *(^mk)(void), int soon);
// Blocking: unspecialized pipeline (archive, else compiled; cached by ukey) then specialized. For the warm-up thread and tools, never the render thread
id<MTLRenderPipelineState> flexpso_make(const void *ukey, MTLRenderPipelineDescriptor *d, id<MTLLibrary> vlib, id<MTLLibrary> flib, const char *label, NSError **err);
// Cumulative counts and a log line ("flexible pipelines: ...") with the archive coverage of the pipelines asked for so far
typedef struct { uint64_t asked, kicked, ready, archive_hit, archive_miss, compiled, specialized, failed, skipped; double spec_ms, spec_worst_ms; } flexpso_counts;
flexpso_counts flexpso_stats(void);
void flexpso_log(void);
