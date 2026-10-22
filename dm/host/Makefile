# Game profile (dm/games/<id>/): the host is built for it (make GAME=base game title ID, required: there is no default game). game_profile.h is generated from game.tsv into gen/<id>/, dmsh_chain.h lives in the profile folder
# without GAME only clean and a bare make (whose default goal only builds libvpx) pass; anything else stops and lists the profiles
ifeq ($(strip $(GAME)),)
ifneq ($(filter-out clean,$(MAKECMDGOALS)),)
$(error GAME is not set: make GAME=<base game title ID>: $(shell python3 ../games/game.py list | awk -F'\t' '{printf "%s (%s)  ", $$1, $$3}'))
endif
endif
# A profile outside the repository (DM_GAMES_DIR, e.g. the NSP script's provisional profile) is reached through the symlink gen/<id>/profile: make cannot take paths with spaces.
# DM_GAMES_FIRST=1 (the NSP script's --provisional) takes it even when dm/games has the game
ifneq ($(strip $(GAME)),)
GAME_DIR := $(if $(and $(wildcard ../games/$(GAME)/game.tsv),$(if $(DM_GAMES_FIRST),,1)),../games/$(GAME),$(shell python3 ../games/game.py link $(GAME) gen/$(GAME)/profile >&2 && echo gen/$(GAME)/profile))
ifeq ($(GAME_DIR),)
$(error no game profile $(GAME) (neither in dm/games nor in DM_GAMES_DIR))
endif
endif
GAME_H = gen/$(GAME)/game_profile.h
CFLAGS=-O1 -g -Wall -Wno-unused-function
# Service-layer takeover hle_*.c files are included by wildcard: adding a file does not touch this line (avoids merge conflicts)
SRC=main.c loader.c hle.c crash.c probe.c thread.c memstat.m romstore.c $(sort $(wildcard hle_*.c)) front_mac.m entry.S
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
.DEFAULT_GOAL := dmhost   # The header generation rules are written first below, so the default goal must be stated explicitly (otherwise make only generates the headers and does not build the host)
.PHONY: game_profile
game_profile: $(GAME_H)
# Regenerated on every make (FORCE): the same GAME can come from another profile folder (DM_GAMES_FIRST), whose game.tsv may be older than the header; game.py writes it only when it changes
$(GAME_H): $(GAME_DIR)/game.tsv ../games/game.py FORCE
	@python3 ../games/game.py header $(GAME) $@
# Records which game the host was built for: changing GAME changes the stamp's content and rebuilds the host (otherwise make sees dmhost as newer than both headers and keeps the other game's host).
# The game of the last build is also read when the Makefile is parsed, and a different one forces the link: make compares whole seconds, and a stamp written in the same second as
# another game's dmhost (two builds in a row) did not count as newer, so that game's host was kept
# The stamp also records a dev build (DEVCTL), so switching between dev and product builds always relinks: a product build never keeps a dev host
GAME_STAMP = gen/game.stamp
STAMP_ID = $(GAME)$(if $(strip $(DEVCTL)),-devctl)
$(GAME_STAMP): FORCE
	@mkdir -p gen; echo $(STAMP_ID) | cmp -s - $@ || echo $(STAMP_ID) > $@
ifneq ($(strip $(GAME)),)
ifneq ($(shell cat $(GAME_STAMP) 2>/dev/null),$(STAMP_ID))
dmhost: FORCE
endif
endif
.PHONY: FORCE
FORCE:
dmhost: $(SRC) $(GFX) dm.h hle.h dm_input.h front.h devctl.h $(GFX_H) $(GAME_H) $(GAME_DIR)/dmsh_chain.h $(GAME_STAMP) $(VPX_LIB) $(ZSTD_LIB) romstore.h
	clang $(CFLAGS) -I../gfx/nvn/include -I../third_party/vulkan-headers/include -I$(dir $(GAME_H)) -I$(GAME_DIR) -I$(VPX) -I$(ZSTD) -I../third_party/stb_vorbis -fobjc-arc -o $@ $(SRC) $(GFX) $(VPX_LIB) $(ZSTD_LIB) -framework Cocoa -framework QuartzCore -framework Metal -framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers
