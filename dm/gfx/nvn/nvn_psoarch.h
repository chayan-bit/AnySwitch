// Precompiled pipelines (Metal binary archives): pipeline creation looks each pipeline up in a shipped archive of GPU binaries before compiling it, and a harvest run records every pipeline it creates.
// Game-agnostic: an archive entry is keyed by Metal itself (the functions' hashes + the whole descriptor nxnative builds: vertex layout, attachment formats, blending), never by game.
// Flow (docs/stageB-pipeline-archives.md): harvest (DM_PSO_HARVEST) -> tools/dmsh_psoarch.py compiles the harvested pipelines for the iOS GPUs with metal-tt -> build_ipa.sh packs dm/pso_archive.metallib.
#pragma once
#import <Metal/Metal.h>

// load: archive to look pipelines up in (nil or missing file = none); harvest: archive file to add every created pipeline to (nil = off; an existing file is extended).
// Callable again (tests): replaces both archives and zeroes the counters
void psoarch_open(id<MTLDevice> dev, NSString *load, NSString *harvest);
// Create a pipeline: hit in the loaded archive = no driver compile; a miss compiles as before and is logged with label (the shader keys). Never fails because of the archive
id<MTLRenderPipelineState> psoarch_render(MTLRenderPipelineDescriptor *d, const char *label, NSError **err);
id<MTLComputePipelineState> psoarch_compute(id<MTLFunction> fn, const char *label, NSError **err);
// Harvest: write the archive if it gained pipelines since the last write (wait = 0 writes on a background queue). No-op when harvest is off
void psoarch_flush(int wait);
// Cumulative: lookups that hit / missed the loaded archive, pipelines added to the harvest archive
void psoarch_stats(uint64_t *hit, uint64_t *miss, uint64_t *harvested);
