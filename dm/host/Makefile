# One host for every game: the game profile is read at boot from game.json (profile.m; dm/games/game.py json writes it), so nothing here depends on a game
CFLAGS=-O1 -g -Wall -Wno-unused-function
# Service-layer takeover hle_*.c files are included by wildcard: adding a file does not touch this line (avoids merge conflicts)
SRC=main.c loader.c hle.c crash.c probe.c thread.c memstat.m romstore.c profile.m boot.m $(sort $(wildcard hle_*.c)) front_mac.m entry.S
# Dev input channel (docs/dev-control.md): only with make DEVCTL=1 (also read from the environment, so build_ipa.sh / gen_build.py carry it into the iOS app); product builds have none of it
ifneq ($(strip $(DEVCTL)),)
CFLAGS += -DDM_DEVCTL
SRC += devctl.c
endif
# NVN null device + nn::vi + the Vulkan layer (dm/gfx/)
# Sources under dm/gfx, dm/gfx/nvn, dm/gfx/tex and dm/gfx/vk are included by wildcard (tests/ and metal/ do not go into the host): adding a file does not touch this line
GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S ../gfx/tex/*.c ../gfx/tex/*.m ../gfx/vk/*.m))
GFX_H=$(sort $(wildcard ../gfx/nvn/*.h ../gfx/nvn/include/*.h ../gfx/tex/*.h))
# Third party: libvpx ships only the VP9 decoder's sources (movie decoding, hle_movie.c), with its configuration headers in config/ (arm64, shared by Mac and iOS). Built separately into a static library, file by file, so host changes do not recompile it
VPX=../third_party/libvpx
VPX_SRC=$(sort $(shell find $(VPX) -name '*.c'))
VPX_OBJ=$(patsubst $(VPX)/%.c,gen/vpx/%.o,$(VPX_SRC))
VPX_LIB=gen/vpx/libvpx.a
gen/vpx/%.o: $(VPX)/%.c $(wildcard $(VPX)/config/*.h)
	@mkdir -p $(dir $@)
	clang -O2 -g -I$(VPX) -I$(VPX)/config -c $< -o $@
$(VPX_LIB): $(VPX_OBJ)
	rm -f $@; ar rcs $@ $^
# Third party: zstd's decompressor only (lib/common + lib/decompress), for the chunk store reader romstore.c; a static library like libvpx, and the iOS build compiles the same files
ZSTD=../third_party/zstd/lib
ZSTD_SRC=$(sort $(wildcard $(ZSTD)/common/*.c $(ZSTD)/decompress/*.c))
ZSTD_OBJ=$(patsubst $(ZSTD)/%.c,gen/zstd/%.o,$(ZSTD_SRC))
ZSTD_LIB=gen/zstd/libzstd.a
gen/zstd/%.o: $(ZSTD)/%.c $(wildcard $(ZSTD)/*.h $(ZSTD)/common/*.h $(ZSTD)/decompress/*.h)
	@mkdir -p $(dir $@)
	clang -O2 -g -DZSTD_DISABLE_ASM -I$(ZSTD) -c $< -o $@
$(ZSTD_LIB): $(ZSTD_OBJ)
	rm -f $@; ar rcs $@ $^
.DEFAULT_GOAL := dmhost   # the library rules come first, so the default goal is stated explicitly
# Records whether the host is a dev build (DEVCTL), so switching between dev and product builds always relinks: a product build never keeps a dev host
STAMP = gen/build.stamp
STAMP_ID = host$(if $(strip $(DEVCTL)),-devctl)
$(STAMP): FORCE
	@mkdir -p gen; echo $(STAMP_ID) | cmp -s - $@ || echo $(STAMP_ID) > $@
ifneq ($(shell cat $(STAMP) 2>/dev/null),$(STAMP_ID))
dmhost: FORCE
endif
.PHONY: FORCE
FORCE:
dmhost: $(SRC) $(GFX) dm.h hle.h dm_input.h front.h devctl.h profile.h dm_abi.h boot.h $(GFX_H) $(STAMP) $(VPX_LIB) $(ZSTD_LIB) romstore.h
	clang $(CFLAGS) -I../gfx/nvn/include -I../third_party/vulkan-headers/include -I$(VPX) -I$(ZSTD) -I../third_party/stb_vorbis -fobjc-arc -o $@ $(SRC) $(GFX) $(VPX_LIB) $(ZSTD_LIB) -framework Cocoa -framework QuartzCore -framework Metal -framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers
