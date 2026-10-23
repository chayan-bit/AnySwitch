# Unit tests: make compiles and runs them (seconds)
# Source files are included by wildcard, same convention as GFX in the host Makefile (hle_nvn.c is #included directly by t_nvn.c, so it is excluded); adding new source files needs no change here
# Game profile (GAME=base game title ID, required: there is no default game): the tests and tools load its game.json at start (t_profile_boot.m), written to build/game.json by dm/games/game.py json
ifeq ($(strip $(GAME)),)
ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),t_nvn)),)
$(error GAME is not set: make GAME=<base game title ID>: $(shell python3 ../../games/game.py list | awk -F'\t' '{printf "%s (%s)  ", $$1, $$3}'))
endif
endif
GAME_DIR = ../../games/$(GAME)
PROFILE_J = build/game.json
# the profile's translation chain version (t_refl and t_rt_range_ro read the Mac libraries of it)
CHAIN = $(shell sed -n 's/^\#define DMSH_CHAIN "\(.*\)"/\1/p' $(GAME_DIR)/dmsh_chain.h)
CFLAGS=-O1 -g -Wall -Wno-unused-function -I../nvn/include -DT_PROFILE_DIR='"$(abspath build)"' -DDMSH_CHAIN='"$(CHAIN)"'
GFX=$(filter-out ../nvn/hle_nvn.c,$(sort $(wildcard ../nvn/*.c ../nvn/*.m ../nvn/*.S ../tex/*.c ../tex/*.m))) ../../host/profile.m t_profile_boot.m
GFX_H=$(wildcard ../nvn/*.h ../nvn/*.inc ../nvn/include/*.h ../tex/*.h) ../../host/profile.h $(PROFILE_J)
.DEFAULT_GOAL := t_nvn   # the profile rule comes first, so keep the default goal as before
# Regenerated on every make (FORCE): game.py writes it only when it changes, and another GAME changes it
$(PROFILE_J): FORCE
	@python3 ../../games/game.py json $(GAME) $@
.PHONY: FORCE
FORCE:
FW=-framework Metal -framework Foundation -framework QuartzCore -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers
# Host crash.c is linked in as well: the write-protect unit tests go through the same page-fault hook as production
t_nvn: t_nvn.c ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(FW)
t_dirty_slots: t_dirty_slots.c ../nvn/nvn_dirty.c ../../host/crash.c ../nvn/nvn_dirty.h ../../host/profile.h
	clang $(CFLAGS) -o $@ t_dirty_slots.c ../../host/crash.c ../nvn/nvn_dirty.c
t_dirty_race: t_dirty_race.c ../nvn/nvn_dirty.c ../../host/crash.c ../nvn/nvn_dirty.h ../../host/profile.h
	clang $(CFLAGS) -o $@ t_dirty_race.c ../../host/crash.c
t_builtin: t_builtin.m ../nvn/nvn_builtin.h
	clang -O1 -g -Wall -fobjc-arc -o $@ t_builtin.m -framework Metal -framework Foundation
t_deswz_gpu: t_deswz_gpu.m ../tex/nvn_deswizzle.c ../tex/nvn_deswizzle_gpu.m ../tex/nvn_deswizzle.h ../tex/nvn_deswizzle_gpu.h ../nvn/nvn_tex.c ../nvn/nvn_tex.h
	clang $(CFLAGS) -fobjc-arc -o $@ t_deswz_gpu.m ../tex/nvn_deswizzle.c ../tex/nvn_deswizzle_gpu.m ../nvn/nvn_tex.c -framework Metal -framework Foundation
t_refl: t_refl.m ../nvn/nvn_refl.m ../nvn/nvn_refl.h $(GAME_DIR)/dmsh_chain.h
	clang -O1 -g -Wall -DDMSH_CHAIN='"$(CHAIN)"' -fobjc-arc -o $@ t_refl.m ../nvn/nvn_refl.m -framework Metal -framework Foundation
t_hmap: t_hmap.c ../nvn/nvn_hmap.h
	clang -O1 -Wall -o $@ t_hmap.c
t_cover: t_cover.c ../nvn/nvn_cover.h
	clang -O1 -Wall -o $@ t_cover.c
t_pace: t_pace.c ../nvn/nvn_pace.h
	clang -O1 -Wall -o $@ t_pace.c
t_fstep: t_fstep.c ../nvn/nvn_fstep.h
	clang -O1 -Wall -o $@ t_fstep.c
t_autostat: t_autostat.c ../nvn/nvn_autostat.h
	clang -O1 -Wall -o $@ t_autostat.c
t_rscale: t_rscale.c ../nvn/nvn_rscale.h
	clang -O1 -Wall -o $@ t_rscale.c
t_fuse_check: t_fuse_check.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_fuse_check.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_present_crop: t_present_crop.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_present_crop.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_reorder_chain: t_reorder_chain.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_reorder_chain.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_defer_chain: t_defer_chain.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_defer_chain.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_zskip: t_zskip.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_zskip.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_xv: t_xv.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_xv.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_ub: t_ub.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_ub.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_vbuf: t_vbuf.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_vbuf.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_pool_release: t_pool_release.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_pool_release.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_passgpu: t_passgpu.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_passgpu.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_present_ambient: t_present_ambient.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_present_ambient.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_present_scale: t_present_scale.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_present_scale.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_mip_extent: t_mip_extent.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_mip_extent.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_rscale_gpu: t_rscale_gpu.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rscale_gpu.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_rtheap: t_rtheap.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rtheap.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_rt_range_shape: t_rt_range_shape.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_range_shape.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_rt_range_ro: t_rt_range_ro.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_range_ro.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_rt_range: t_rt_range.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_range.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_rt_depth_ro: t_rt_depth_ro.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_depth_ro.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_pso_skey: t_pso_skey.m ../nvn/nvn_pso_skey.h ../nvn/nvn_obj.h
	clang $(CFLAGS) -fobjc-arc -o $@ t_pso_skey.m -framework Foundation
t_pfv: t_pfv.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_pfv.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_psoarch: t_psoarch.m ../nvn/nvn_psoarch.m ../nvn/nvn_psoarch.h
	clang -O1 -g -Wall -fobjc-arc -o $@ t_psoarch.m ../nvn/nvn_psoarch.m -framework Metal -framework Foundation
t_flexpso: t_flexpso.m ../nvn/nvn_flexpso.m ../nvn/nvn_flexpso.h ../nvn/nvn_hmap.h ../nvn/nvn_bgq.h
	clang -O1 -g -Wall -fobjc-arc -o $@ t_flexpso.m ../nvn/nvn_flexpso.m -framework Metal -framework Foundation
# Build tool, not a test: replays a pipeline manifest through the host's warm-up (tools/pso_replay.m, driven by tools/dmsh_psoexpand.py)
pso_replay: ../tools/pso_replay.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ ../tools/pso_replay.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
# Measurement tool, not a test: pipeline creation cost per record, classic vs Metal 4 vs Metal 4 unspecialized + specialization (tools/pso_flexbench.m, dm/gfx/README.md, pipeline coverage).
# The embedded Info.plist gives it its own bundle id, so its system shader cache folder is its own and BENCH_CLEAR=1 can empty it
pso_flexbench: ../tools/pso_flexbench.m pso_flexbench.plist ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -Wl,-sectcreate,__TEXT,__info_plist,pso_flexbench.plist -o $@ ../tools/pso_flexbench.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_pack: t_pack.m ../../host/crash.c t_hle_stubs.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_pack.m ../../host/crash.c t_hle_stubs.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
run: t_nvn t_dirty_slots t_dirty_race t_builtin t_deswz_gpu t_pace t_fstep t_refl t_hmap t_cover t_fuse_check t_present_crop t_reorder_chain t_defer_chain t_zskip t_xv t_ub t_vbuf t_mip_extent t_rt_range_shape t_rt_range_ro t_rt_range t_rt_depth_ro t_pool_release t_pso_skey t_pfv t_psoarch t_passgpu t_present_ambient t_present_scale t_flexpso t_pack t_autostat t_rscale t_rscale_gpu t_rtheap
	./t_nvn
	./t_dirty_slots
	./t_dirty_race
	./t_builtin
	./t_deswz_gpu
	./t_pace
	./t_fstep
	./t_autostat
	./t_rscale
	MTL_DEBUG_LAYER=1 ./t_rscale_gpu 1   # internal resolution on the GPU: 1x (the test's own baseline), 1.5x, 2x
	MTL_DEBUG_LAYER=1 ./t_rscale_gpu 1.5
	MTL_DEBUG_LAYER=1 ./t_rscale_gpu 2
	MTL_DEBUG_LAYER=1 ./t_rtheap 1   # render-target heaps: overlapping targets share bytes, disjoint ones never do, at 1x and 2x
	MTL_DEBUG_LAYER=1 ./t_rtheap 2
	./t_refl
	./t_hmap
	./t_cover
	./t_fuse_check
	./t_present_crop
	MTL_DEBUG_LAYER=1 ./t_present_ambient
	MTL_DEBUG_LAYER=1 ./t_present_scale
	MTL_DEBUG_LAYER=1 ./t_reorder_chain
	MTL_DEBUG_LAYER=1 ./t_defer_chain
	./t_zskip
	./t_xv
	./t_ub
	MTL_DEBUG_LAYER=1 ./t_vbuf
	DM_NVN_VBUF_CACHE=0 MTL_DEBUG_LAYER=1 ./t_vbuf
	./t_pool_release   # freed pools are deallocated after retirement even when freed on a thread with no autorelease pool
	MTL_DEBUG_LAYER=1 ./t_mip_extent
	MTL_DEBUG_LAYER=1 ./t_mip_extent --stencil-only
	./t_rt_depth_ro
	./t_rt_range_shape
	./t_rt_range_ro
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range
	MTL_DEBUG_LAYER=1 ./t_rt_range   # DontCare on by default: attachment bytes use the closed-form expectation of "one depth-stencil store saved per pass"
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range --disabled
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range --small-depth
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range --sample-attachment --both-flags
	./t_pso_skey
	MTL_DEBUG_LAYER=1 ./t_pfv
	DM_GAME=$(GAME) python3 test_tbdr_budget.py   # tools/tbdr_budget.py names shaders from the game profile's shader_map.tsv
	DM_GAME=$(GAME) python3 test_shader_split_zlib.py   # tools/shader_split.py zlib_streams: shaders compressed inside a module image
	DM_GAME=$(GAME) python3 test_pack.py   # tools/dmsh_pack.py packs, loaded through t_pack (the host's shader loader) with and without them
	python3 test_psoarch.py   # runs t_psoarch: harvest -> lookup, then metal-tt archives (macOS looked up, iOS built)
	MTL_DEBUG_LAYER=1 ./t_passgpu
	MTL_DEBUG_LAYER=1 ./t_flexpso
	DM_GAME=$(GAME) python3 test_pairs.py   # tools/dmsh_pairs.py split and iface rules, coverage
	python3 test_flexarch.py   # tools/dmsh_flexarch.py archive tiers and size cap
	python3 test_rscale.py   # tools/dmsh_rscale.py internal-resolution facts and their MSL check
.PHONY: run
