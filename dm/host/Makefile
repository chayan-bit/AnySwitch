# One host for every game (AnySwitch): the game profile is read at boot from game.json (profile.m; dm/games/game.py json writes it), so nothing here depends on a game.
# profile.h maps upstream's DM_GAME_* names onto that run-time profile, so GAME is not needed here
include ../mac/min_os.mk
# -O2 as the other native code here (libvpx, dav1d, the launcher; the iOS host builds at Xcode Release's -Os). Not -O3 (no measured gain over -O2) and not -flto, which moves
# hle_bigstack.c's inline-assembly entry apart from its return path (SIGBUS in dm_bigstack_enter on Breath of the Wild, PR #556)
CFLAGS=-O2 -g -Wall -Wno-unused-function -mmacosx-version-min=$(MACOS_MIN)
# Service-layer takeover hle_*.c files are included by wildcard: adding a file does not touch this line (avoids merge conflicts)
SRC=main.c loader.c hle.c crash.c probe.c thread.c save_sync.c memstat.m romstore.c profile.m boot.m haptics_apple.m pad_switch2_apple.m $(sort $(wildcard hle_*.c)) keymap.c front_mac.m web_apple.m entry.S
# Dev input channel (docs/dev-control.md): only with make DEVCTL=1 (also read from the environment, so build_ipa.sh / gen_build.py carry it into the iOS app); product builds have none of it
ifneq ($(strip $(DEVCTL)),)
CFLAGS += -DDM_DEVCTL
SRC += devctl.c
else
# A product build (no DEVCTL: the shipped app): the profiling counters start off; DM_PERF=1 in env.txt turns them on
CFLAGS += -DDM_PERF_DEFAULT=0
endif
# NVN null device + nn::vi + the Vulkan layer (dm/gfx/)
# Sources under dm/gfx, dm/gfx/nvn, dm/gfx/tex, dm/gfx/vk and dm/gfx/gl are included by wildcard (tests/ and metal/ do not go into the host): adding a file does not touch this line
GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S ../gfx/tex/*.c ../gfx/tex/*.m ../gfx/vk/*.m ../gfx/gl/*.m))
GFX_H=$(sort $(wildcard ../gfx/nvn/*.h ../gfx/nvn/*.inc ../gfx/nvn/include/*.h ../gfx/tex/*.h))   # *.inc: nvn_mtl.m includes them (nvn_geometry.inc); an edit there alone used not to rebuild the host
# Third party: libvpx ships the VP8 and VP9 decoder sources (movie decoding, hle_movie.c), with its configuration headers in config/ (arm64, shared by Mac and iOS). Built separately into a static library, file by file, so host changes do not recompile it
VPX=../third_party/libvpx
VPX_SRC=$(sort $(shell find $(VPX) -name '*.c'))
VPX_OBJ=$(patsubst $(VPX)/%.c,gen/vpx/%.o,$(VPX_SRC))
VPX_LIB=gen/vpx/libvpx.a
gen/vpx/%.o: $(VPX)/%.c $(wildcard $(VPX)/config/*.h) ../mac/min_os.mk
	@mkdir -p $(dir $@)
	clang -O2 -g -mmacosx-version-min=$(MACOS_MIN) -I$(VPX) -I$(VPX)/config -c $< -o $@
$(VPX_LIB): $(VPX_OBJ)
	rm -f $@; ar rcs $@ $^
# Third party: dav1d, the AV1 decoder where VideoToolbox has none (hle_movie_av1.c), with its arm64 NEON assembly and its configuration in config/. Its *_tmpl.c files are built
# through the per-bit-depth wrappers in config/tmpl, and the assembly files other assembly files include (*_tmpl.S, util.S) are not built on their own: the list meson builds
DAV1D=../third_party/dav1d
DAV1D_SRC=$(sort $(filter-out %_tmpl.c,$(wildcard $(DAV1D)/src/*.c)) $(DAV1D)/src/arm/cpu.c $(wildcard $(DAV1D)/config/tmpl/*.c) \
          $(filter-out %_tmpl.S %/util.S,$(wildcard $(DAV1D)/src/arm/64/*.S)))
DAV1D_OBJ=$(patsubst $(DAV1D)/%,gen/dav1d/%.o,$(DAV1D_SRC))
DAV1D_LIB=gen/dav1d/libdav1d.a
DAV1D_H=$(wildcard $(DAV1D)/config/*.h $(DAV1D)/src/*.h $(DAV1D)/src/*_tmpl.c $(DAV1D)/src/arm/*.h $(DAV1D)/src/arm/asm.S $(DAV1D)/src/arm/64/*_tmpl.S $(DAV1D)/src/arm/64/util.S $(DAV1D)/include/*/*.h)
gen/dav1d/%.o: $(DAV1D)/% $(DAV1D_H) ../mac/min_os.mk
	@mkdir -p $(dir $@)
	clang -O2 -g -mmacosx-version-min=$(MACOS_MIN) -fvisibility=hidden -fomit-frame-pointer -fno-align-functions -I$(DAV1D) -I$(DAV1D)/include -I$(DAV1D)/config -c $< -o $@
$(DAV1D_LIB): $(DAV1D_OBJ)
	rm -f $@; ar rcs $@ $^
# Third party: zstd's decompressor only (lib/common + lib/decompress), for the chunk store reader romstore.c; a static library like libvpx, and the iOS build compiles the same files
ZSTD=../third_party/zstd/lib
ZSTD_SRC=$(sort $(wildcard $(ZSTD)/common/*.c $(ZSTD)/decompress/*.c))
ZSTD_OBJ=$(patsubst $(ZSTD)/%.c,gen/zstd/%.o,$(ZSTD_SRC))
ZSTD_LIB=gen/zstd/libzstd.a
gen/zstd/%.o: $(ZSTD)/%.c $(wildcard $(ZSTD)/*.h $(ZSTD)/common/*.h $(ZSTD)/decompress/*.h) ../mac/min_os.mk
	@mkdir -p $(dir $@)
	clang -O2 -g -mmacosx-version-min=$(MACOS_MIN) -DZSTD_DISABLE_ASM -I$(ZSTD) -c $< -o $@
$(ZSTD_LIB): $(ZSTD_OBJ)
	rm -f $@; ar rcs $@ $^
# The host's own Metal shaders (dm/gfx/msl/*.metal) compiled for MSL_SDK into gen/msl-<sdk>/host_msl_gen.h (dm/gfx/tools/host_msl.py; dm/gfx/nvn/host_msl.m loads them), so the host
# compiles no MSL at run time. The iOS build (dm/ios/tools/gen_build.py) makes it with MSL_SDK=iphoneos, for the app's deployment target (MSL_MIN_iphoneos, as project.yml)
MSL_SDK ?= macosx
MSL_MIN_macosx = $(MACOS_MIN)
MSL_MIN_iphoneos = 26.0
MSL_SRC = $(sort $(wildcard ../gfx/msl/*.metal))
MSL_H = gen/msl-$(MSL_SDK)/host_msl_gen.h
# Recheck the toolchain and target on every build; the generator keeps the header unchanged when its inputs match.
$(MSL_H): $(MSL_SRC) ../gfx/tools/host_msl.py FORCE
	python3 ../gfx/tools/host_msl.py --sdk $(MSL_SDK) $(if $(MSL_MIN_$(MSL_SDK)),--min $(MSL_MIN_$(MSL_SDK))) $@ $(MSL_SRC)
.PHONY: host_msl game_profile
host_msl: $(MSL_H)
game_profile:   # nothing to generate here (game.json is read at boot); kept so upstream's callers (compile_check.py, lint_c.py, regress.py) still run
.DEFAULT_GOAL := dmhost   # The header generation rules are written first below, so the default goal must be stated explicitly (otherwise make only generates the headers and does not build the host)
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
# Makefile: a change to CFLAGS (or the compile line) rebuilds the host
dmhost: Makefile $(SRC) $(GFX) ../third_party/stb_vorbis/stb_vorbis.c dm.h hle.h romfs_image.h save_sync.h dm_input.h pad_slots.h hle_haptics.h haptics_apple.h pad_switch2_apple.h switch2_proto.h motion_fusion.h motion_apple.h motion_pro.h motion_pro_mac.h keymap.h pad_apple.h pad_hid.h pad_hid_mac.h home_quit.h home_quit_mac.h ctrl_prompt.h front.h $(GFX_H) profile.h dm_abi.h boot.h romstore.h devctl.h $(MSL_H) $(STAMP) $(VPX_LIB) $(DAV1D_LIB) $(ZSTD_LIB) $(MSL_H)
	clang $(CFLAGS) -I. -I../gfx/nvn/include -I$(dir $(MSL_H)) -I../third_party/vulkan-headers/include -I$(VPX) -I$(DAV1D)/include -I$(ZSTD) -I../third_party/stb_vorbis -fobjc-arc -o $@ $(SRC) $(GFX) $(VPX_LIB) $(DAV1D_LIB) $(ZSTD_LIB) -framework Cocoa -framework WebKit -framework UserNotifications -framework QuartzCore -framework Metal -framework MetalFX -framework GameController -framework CoreBluetooth -framework IOBluetooth -framework CoreHaptics -framework IOKit -framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers
clean:   # the host and everything make generates for it (gen/: the build stamp and the libvpx, dav1d and zstd builds; dmhost_* and *.dSYM beside them, as in .gitignore)
	rm -rf gen dmhost dmhost_* *.dSYM
.PHONY: clean
