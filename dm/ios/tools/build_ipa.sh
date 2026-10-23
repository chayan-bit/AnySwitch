#!/bin/bash
# Build one unsigned all-in-one IPA: the rewritten modules compiled into the executable, and everything else as a game pack at DmIOS.app/pack (docs/development.md "Game packs": profile/,
# msl/ios/, pso/ios/, font/, aoc/, meta/ and manifest.json, without code/, which the executable embeds, and without the RomFS store, which goes to Documents; IPA_ROMFS=1 puts loose files at DmIOS.app/romfs).
# Xcode builds only the app; tools/pack_ipa.py then packs it with the shader libraries, the add-on content and the RomFS straight from where they are (no Payload/ copy, nothing through the home disk). At install time a signing tool (AltStore / Sideloadly etc.) swaps in your own certificate and bundle ID.
# Prerequisites: the rewriter (patched directory) and the iOS shader build (IOSOUT) have been run as in the README; Xcode and xcodegen are installed.
# Usage: dm/ios/tools/build_ipa.sh [output.ipa]; environment: GAME=game profile (dm/games/<base game title ID>, or one in DM_GAMES_DIR; required), W=the game's work folder (required: <NSP folder>/<title ID>-work, never the home folder), PATCHED / ROMFS / MSL_IOS can each be overridden
#   AOC=add-on content directory (default $W/data/aoc; when it exists it goes to DmIOS.app/pack/aoc/<index>/; an empty string = none), GFXAPI=nvn / vulkan (default: by the shader libraries in MSL_IOS)
#   IPA_ROMFS=store (the default) leaves the RomFS out of the IPA and builds a chunk store of it (dm/tools/romstore/romstore.py: deduplicated, compressed, random access, about 46% of the loose size) at ROMSTORE (default $W/build/romfs.dmstore;
#   an existing one is reused, ROMSTORE_REBUILD=1 rebuilds it, ROMSTORE_TRACE = DM_FSLOG files separated by ':' order it by first read); install it with
#   romstore.py install, and the app reads Documents/romfs.dmstore before Documents/romfs
#   IPA_ROMFS=1 packs the loose RomFS files into the IPA (DmIOS.app/romfs): one self-contained IPA that needs no extra copy, the way builds worked before the store became the default
#   IPA_ROMFS=0 leaves the RomFS out and builds no store (it is still read for the control data and the icon): the app then needs it at Documents/romfs (main.m looks there first, then at DmIOS.app/romfs), for a build that updates an install which already has the game files
#   The app name is the game name in the base NSP's control data ($W/data/v0/control.nacp, else the one next to the RomFS), the app version is the display version in the packed game's control data (the one next to the RomFS:
#   nx_extract saves the update's there when an update is packed, else the base game's), the bundle ID is org.anyswitch.<base game title ID in lowercase> (DM_DISPLAY_NAME / DM_APP_VERSION / DM_BUNDLE_ID override them);
#   DM_SHOW_FPS=1 turns the frame-rate counter on (DMShowFPS in Info.plist; DM_SHOW_FPS in the app's Documents/env.txt overrides it on the phone);
#   the IPA name, code modules, RomFS marker and shader tables come from the game profile
#   PACK=<new folder> writes a game pack there instead of an IPA (docs/development.md "Game packs"): the same tables, pipeline archives and fonts, the code dylibs for iOS and the Mac
#   (gen_embed.py --dylib), the iOS shader libraries and the Mac ones (MSL_MAC), the add-on content, the RomFS chunk store, icon and control data, then manifest.json
#   (dm/tools/pack_manifest.py); big files enter as APFS clones (cp -c: no extra disk on the same volume), and nothing is built with Xcode
#   CODE_DYLIB=1 links the rewritten modules into DmIOS.app/Frameworks/<title id>.dylib (gen_embed.py --dylib --target ios) instead of the executable; Hearth (HearthLibrary.m) points DM_CODE at it,
#   so the app maps its code the way a pack's code/ios.dylib is mapped (the install tool signs the dylib with the app)
set -u
cd "$(dirname "$0")/.." || exit 1
DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
cpc() { cp -c "$@" 2> /dev/null || cp "$@"; }   # copy as an APFS clone (no extra disk on the same volume), a plain copy where cloning is refused
# Metal's pipeline compiler (metal-tt) leaves temp entries in the per-user gpuarchiver cache (13 GB once): when this build ends, remove the ones it made, never the others (scripts/diskhygiene.py)
HYG=$DM/../scripts/diskhygiene.py; GPU_SNAP=$(mktemp -t dm_gpusnap) && python3 "$HYG" gpu-snapshot "$GPU_SNAP" && trap 'python3 "$HYG" gpu-clean "$GPU_SNAP"; rm -f "$GPU_SNAP"' EXIT
ROMFS_MODE=${IPA_ROMFS:-store}   # store (default): a chunk store beside the IPA; 1: loose files in the IPA; 0: none
case $ROMFS_MODE in store|1|0) ;; *) die "IPA_ROMFS must be store, 1 or 0, not $ROMFS_MODE" ;; esac
[ -n "${GAME:-}" ] || die "GAME is not set: GAME=<base game title ID> $0; profiles: $(python3 "$DM/games/game.py" list | awk -F'\t' '{printf "%s (%s)  ", $1, $3}')"
export GAME; GD=$(python3 "$DM/games/game.py" dir "$GAME") || die "no game profile $GAME"   # dm/games/<id>, or a profile in DM_GAMES_DIR (the NSP script's provisional one); the make that gen_build.py runs uses the same GAME
gp() { python3 "$DM/games/game.py" "$GAME" "$1" || die "game profile $GD: $1"; }   # read a key of the game profile
[ -f "$GD/game.tsv" ] || die "no game profile $GD/game.tsv"
[ -n "${W:-}" ] || die "W is not set: W=<NSP folder>/$GAME-work (the game's work folder) $0"
PKG=$(gp package)
PATCHED=${PATCHED:-$W/build/patched_$PKG}; ROMFS=${ROMFS:-$W/data/$PKG/RomFS}; MSL_IOS=${MSL_IOS:-$W/build/ios/dmsh_b}; AOC=${AOC-$W/data/aoc}
OUT_IPA=${1:-$(dirname "$W")/$(gp ipa)}; O=$W/build/ios/pkg; DD=$O/dd
MODS=$(gp modules); MARKER=$(gp romfs_marker)
NACP=$W/data/v0/control.nacp; [ -f "$NACP" ] || NACP=$(dirname "$ROMFS")/control.nacp
[ -n "${DM_DISPLAY_NAME:-}" ] || DM_DISPLAY_NAME=$(python3 "$DM/tools/nacp.py" "$NACP") || die "no game name in $NACP (re-extract with nx_extract, or set DM_DISPLAY_NAME)"
VNACP=$(dirname "$ROMFS")/control.nacp; [ -f "$VNACP" ] || VNACP=$W/data/v0/control.nacp
[ -n "${DM_APP_VERSION:-}" ] || DM_APP_VERSION=$(python3 "$DM/tools/nacp.py" --version "$VNACP") || { t "no display version in $VNACP: the app version is 1.0"; DM_APP_VERSION=1.0; }
DM_APP_CATEGORY=$(gp app_category) || exit 1
export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.anyswitch.$(echo "$GAME" | tr 'A-Z' 'a-z')} DM_DISPLAY_NAME DM_APP_VERSION DM_APP_CATEGORY DM_TEAM_ID=${DM_TEAM_ID:-0000000000}   # placeholder identity: unsigned, the install tool replaces it
if [ "${DM_SHOW_FPS:-0}" = 1 ]; then export DM_SHOW_FPS=YES; else export DM_SHOW_FPS=NO; fi
export DM_LETTERBOX=${DM_LETTERBOX:-ambient} DM_CONTROLS_LAYOUT=${DM_CONTROLS_LAYOUT:-auto} DM_CONTROLS_SCALE=${DM_CONTROLS_SCALE:-1}   # Info.plist DMLetterbox / DMControlsLayout / DMControlsScale (front_ios.m); the app's Documents/env.txt overrides them
for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f (run dm/tools/patch_nso.py first)"; done
[ -e "$ROMFS/$MARKER" ] || die "no RomFS at $ROMFS (missing $MARKER)"
V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$GD/dmsh_chain.h")
# A Vulkan game (Hades): the shaders are the game's SPIR-V, translated by dm/gfx/tools/vk_shaders.py into $MSL_IOS/vk; there are no NVN chain libraries. GFXAPI=nvn / vulkan says which
# (the NSP script passes what main imports); without it, the shader libraries in $MSL_IOS tell: the chain's b-$V, else vk
if [ -z "${GFXAPI:-}" ]; then if compgen -G "$MSL_IOS/b-$V/*_b.metallib" > /dev/null; then GFXAPI=nvn; elif [ -f "$MSL_IOS/vk/vk_shaders.metallib" ]; then GFXAPI=vulkan; else GFXAPI=nvn; fi; fi
if [ "$GFXAPI" = vulkan ]; then [ -f "$MSL_IOS/vk/vk_shaders.metallib" ] || die "no iOS Vulkan shader library $MSL_IOS/vk (dm/gfx/tools/vk_shaders.py \"$ROMFS\" <Mac dir> --ios \"$MSL_IOS\")"
else [ -n "$V" ] && compgen -G "$MSL_IOS/b-$V/*_b.metallib" > /dev/null || die "no iOS shader libraries $MSL_IOS/b-$V (IOSOUT=$MSL_IOS dmsh_build.py ...)"; fi
# Shader packs (dm/gfx/README.md, "Shader packs"): once dm/gfx/tools/dmsh_pack.py has packed the iOS libraries into $MSL_IOS/b-$V/pack, the app ships the packs instead of the loose
# <key>_b.metallib / .json they hold; SHADER_PACKS=0 ships the loose libraries. Pipelines replayed on this Mac for the archive must use the Mac packs then ($MSL_MAC/b-$V/pack, same --per-pack)
PACKS=0; if [ "$GFXAPI" = nvn ] && [ "${SHADER_PACKS:-1}" != 0 ] && [ -f "$MSL_IOS/b-$V/pack/index.tsv" ]; then PACKS=1; fi

# Destinations: the pack's profile/, pso/ios/ and font/, in Gen/pack (IPA: the app's DmIOS.app/pack) or in the pack folder (PACK)
if [ -n "${PACK:-}" ]; then
  [ ! -e "$PACK" ] || [ -f "$PACK/manifest.json" ] || die "PACK=$PACK exists and is not a game pack: give a new folder"
  PW=$PACK.partial; t "game pack: $PACK (built in $PW, moved in place when complete)"
  rm -rf "$PW" && mkdir -p "$PW/profile" "$PW/pso/ios" "$PW/font" "$PW/code" "$PW/meta" || die "mkdir $PW"
  DMO=$PW/profile; PSO_O=$PW/pso/ios; FONT_O=$PW/font
else
  t "app: $DM_DISPLAY_NAME $DM_APP_VERSION ($DM_BUNDLE_ID)$([ $DM_SHOW_FPS = YES ] && echo ', frame-rate counter on')"
  t "generate Gen/ (host sources, embedded modules, tables)"
  rm -rf Gen && mkdir -p Gen/pack/profile Gen/pack/pso/ios Gen/pack/meta || die "mkdir Gen"
  python3 tools/gen_build.py ../host Gen > Gen/dm.xcconfig || die "gen_build"
  F=; rm -rf "$O/fw"
  if [ "${CODE_DYLIB:-0}" = 1 ]; then
    mkdir -p "$O/fw" && python3 tools/gen_embed.py "$PATCHED" "$O/fw/embed.S" $MODS --title "$GAME" --dylib "$O/fw/$GAME.dylib" --target ios > /dev/null || die "code dylib"
    rm -f "$O/fw/embed.S"; echo '// CODE_DYLIB=1: the rewritten modules are in Frameworks/<title id>.dylib' > Gen/embed.S; t "code: Frameworks/<title id>.dylib (CODE_DYLIB=1)"
  else F=$(python3 tools/gen_embed.py "$PATCHED" Gen/embed.S $MODS --title "$GAME") || die "gen_embed"; fi
  echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig
  DMO=Gen/pack/profile; PSO_O=Gen/pack/pso/ios; FONT_O=Gen/pack/font
fi
cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv "$DMO"/ || die "copy rewriter tables"
if [ "$GFXAPI" = vulkan ]; then cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$DMO"/ || die "copy shader tables"   # empty NVN tables: the NVN layer is never used
else cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" "$DMO"/ || die "copy shader tables"
  if [ -f "$GD/cb_extent.tsv" ]; then cp "$GD/cb_extent.tsv" "$DMO"/ || die "copy cb_extent.tsv"; fi; fi   # optional: without it the host copies whole uniform bindings
# The game profile the host reads at boot (profile/game.json)
python3 "$DM/games/game.py" json "$GAME" "$DMO" || die "game.json"
# The game's own sections of the in-app settings screen (docs/settings.md): dm/games/<id>/settings.json becomes profile/settings.json
if [ -f "$GD/settings.json" ]; then cp "$GD/settings.json" "$DMO"/settings.json || die "copy settings.json"; t "settings: $GD/settings.json"; fi
# GPU architectures both pipeline archives below are built for (each holds one copy of every pipeline per architecture): PSO_ARCHS (names as the app's log line "this GPU: ..." prints
# them), else the connected devices' own, read from their chip IDs by tools/device_gpu.py (read-only: lists devices, installs nothing), else every iOS GPU family with Metal 4
if [ -n "${PSO_ARCHS:-}" ]; then t "GPU architectures: $PSO_ARCHS (PSO_ARCHS)"; else PSO_ARCHS=$(python3 tools/device_gpu.py) || PSO_ARCHS=; fi
# Precompiled pipelines (docs/stageB-pipeline-archives.md) as dm/pso_archive.metallib, where the host looks each pipeline up before compiling it: PSO_ARCHIVE=a finished archive, taken as is;
# else the harvests (DM_PSO_HARVEST runs on the Mac or the device) are compiled together by dmsh_psoarch.py with metal-tt for the iOS GPUs (the architectures above)
# against this chain's iOS libraries; MSL_MAC = the Mac libraries (their MSL is rebuilt with the driver link metal-tt reads).
# PSO_HARVEST = harvest files separated by ':', default every $W/build/pso_harvest*.metallib: copy a device harvest (Documents/pso_harvest.metallib) there under its own name, for example
# pso_harvest_ipad.metallib, and it is merged with the Mac one. No archive is no error: pipelines then compile on first use, as before
MSL_MAC=${MSL_MAC:-$W/build/cache/metal_shader_cache}
# Program pairs (dm/gfx/README.md, pipeline coverage): dmsh_pairs.py recovers the vertex / pixel shader pairs the title can draw with from its RomFS and main, without playing, into
# $W/build/program_pairs.tsv (kept while newer than the tool), and prints how many of the title's shaders are in a pair: the harvest-free coverage check of a new title.
# PAIRS=0 skips it, PAIRS=force rescans. Needs lz4 in python3, else it runs under nix-shell
PAIRS_TSV=$W/build/program_pairs.tsv
if [ "$GFXAPI" = nvn ] && [ "${PAIRS:-1}" != 0 ]; then
  t "program pairs (dmsh_pairs.py)"; [ "${PAIRS:-1}" = force ] && rm -f "$PAIRS_TSV"
  PC=(python3 "$DM/gfx/tools/dmsh_pairs.py" "$ROMFS" "$(dirname "$ROMFS")/ExeFS/main" "$PAIRS_TSV" --table "$GD/shader_pairs.tsv" --coverage "$GD/shader_map.tsv" --reuse)
  if python3 -c 'import lz4' 2> /dev/null; then DM_GAME=$GAME "${PC[@]}"; else DM_GAME=$GAME nix-shell -p 'python3.withPackages(ps:[ps.lz4])' --run "$(printf '%q ' "${PC[@]}")"; fi \
    || { rm -f "$PAIRS_TSV"; t "[RED] dmsh_pairs.py failed above: no program pairs"; }
fi
# Pipeline expansion (docs/stageB-pipeline-expansion.md): PSO_EXPAND = pso_user.tsv files of harvest runs separated by ':'; dmsh_psoexpand.py adds the pipelines their learned states give
# other shader pairs and replays them through the host's warm-up on this Mac into $W/build/pso_harvest_expand.metallib, merged below like any harvest. PSO_EXPAND_ARGS = more flags (--max-bytes ...)
if [ -n "${PSO_EXPAND:-}" ] && [ "$GFXAPI" = nvn ] && [ -z "${PSO_ARCHIVE:-}" ]; then
  IFS=: read -ra PE <<< "$PSO_EXPAND"; t "pipeline expansion of ${PE[*]}"
  DM_SHADER_PACKS=$([ $PACKS = 1 ] && echo on || echo off) DM_NVN_SHMAP="$GD/shader_map.tsv" DM_MSL_DIR="$MSL_MAC" python3 "$DM/gfx/tools/dmsh_psoexpand.py" "${PE[@]}" --map "$GD/shader_map.tsv" --refl "$MSL_MAC/b-$V" \
    ${PSO_EXPAND_ARGS:-} --build "$W/build/pso_harvest_expand.metallib" || t "[RED] pipeline expansion failed above: the archive holds the harvests only"
fi
HV=(); if [ -n "${PSO_HARVEST:-}" ]; then IFS=: read -ra HV <<< "$PSO_HARVEST"; else for h in "$W"/build/pso_harvest*.metallib; do [ -f "$h" ] && HV+=("$h"); done; fi
for h in ${HV[@]+"${HV[@]}"}; do [ -f "$h" ] || die "no pipeline harvest $h (PSO_HARVEST)"; done
if [ -n "${PSO_ARCHIVE:-}" ]; then cpc "$PSO_ARCHIVE" "$PSO_O"/pso_archive.metallib || die "copy PSO_ARCHIVE"; t "pipeline archive: $PSO_ARCHIVE (as is)"
elif [ "$GFXAPI" = nvn ] && [ ${#HV[@]} -gt 0 ]; then
  t "pipeline archive: compile ${HV[*]} for the iOS GPUs (metal-tt)"
  mkdir -p "$O" && python3 "$DM/gfx/tools/dmsh_psoarch.py" "${HV[@]}" --libs "$MSL_MAC/b-$V" "$MSL_IOS/b-$V" --target-libs "$MSL_IOS/b-$V" --msl "$MSL_MAC/b-$V" \
    ${PSO_ARCHS:+--arch $PSO_ARCHS} -o "$O/pso_archive.metallib" && cpc "$O/pso_archive.metallib" "$PSO_O"/ || t "[RED] no pipeline archive (dmsh_psoarch.py failed above): pipelines compile on first use"
else t "no pipeline harvest ($W/build/pso_harvest*.metallib, PSO_HARVEST): no pipeline archive, pipelines compile on first use"; fi
# Flexible pipeline archive (dm/gfx/README.md, pipeline coverage) as dm/pso_flex.metallib, for nvn_flexpso.m (DM_PSO_FLEX=1). Tiers filled in order until PSO_FLEX_MB (default 300, 0 = no cap):
# the pipeline logs of earlier runs ($W/build/pso_user*.tsv; a reachable device's log is pulled there first by pull_pso_user.py, PSO_PULL=0 skips that), then the program pairs of the
# accelerator rules and the same-variation table, then the interface pairs. Built by default (the app's Flexible pipelines setting is on by default and uses it); PSO_FLEX=0 skips it, PSO_FLEX_ARCHIVE=a finished archive taken as is. The archive names the libraries the
# app ships, so it is built from the packed libraries once those are packed. The cap holds for all the architectures above (measured on a one-architecture build), so every
# architecture fewer fits that many more pipelines
if [ "$GFXAPI" = nvn ] && [ "${PSO_FLEX:-1}" != 0 ]; then
  if [ -n "${PSO_FLEX_ARCHIVE:-}" ]; then cpc "$PSO_FLEX_ARCHIVE" "$PSO_O"/pso_flex.metallib || die "copy PSO_FLEX_ARCHIVE"; t "flexible pipeline archive: $PSO_FLEX_ARCHIVE (as is)"
  else
    [ "${PSO_PULL:-1}" = 0 ] || python3 tools/pull_pso_user.py "$DM_BUNDLE_ID" "$W/build" "$GAME" || t "[RED] pull_pso_user.py failed above: no device pipeline log"
    UL=(); for u in "$W"/build/pso_user*.tsv; do [ -f "$u" ] && UL+=("$u"); done
    PL=(); for p in "$PAIRS_TSV" "$GD/shader_pairs.tsv"; do [ -f "$p" ] && PL+=("$p"); done
    t "flexible pipeline archive (dmsh_flexarch.py, cap ${PSO_FLEX_MB:-300} MB): ${#UL[@]} pipeline logs, ${#PL[@]} pair lists"
    make -s -C "$DM/gfx/tests" GAME="$GAME" pso_flexbench > /dev/null && mkdir -p "$O" && DM_SHADER_PACKS=$([ $PACKS = 1 ] && echo on || echo off) DM_NVN_SHMAP="$GD/shader_map.tsv" DM_MSL_DIR="$MSL_MAC" python3 "$DM/gfx/tools/dmsh_flexarch.py" \
      ${UL[@]+--records "${UL[@]}"} ${PL[@]+--pairs "${PL[@]}"} --max-mb "${PSO_FLEX_MB:-300}" --msl "$MSL_MAC/b-$V" --target-libs "$MSL_IOS/b-$V" -o "$O/pso_flex.metallib" \
      ${PSO_ARCHS:+--arch $PSO_ARCHS} && cpc "$O/pso_flex.metallib" "$PSO_O"/ || t "[RED] no flexible pipeline archive (dmsh_flexarch.py failed above): flexible pipelines compile on workers"
  fi
fi
# Diagnostic build: DM_ENV_FILE=file → profile/env.txt in the bundled pack (main.m sets one environment variable per line at boot)
if [ -n "${DM_ENV_FILE:-}" ]; then cp "$DM_ENV_FILE" "$DMO"/env.txt || die "copy DM_ENV_FILE"; t "env: $(grep -v '^#' "$DM_ENV_FILE" | tr '\n' ' ')"; fi
# The shader libraries go into the archive as DmIOS.app/pack/msl/ios/<folder> (dm_boot_env sets DM_MSL_DIR to the pack's msl/ios)
if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; else MSLDIR=b-$V; fi
# Guard: an app without its shader libraries boots to a blank clear colour (0 draws), so a missing or nearly empty library folder is an error, never a warning:
# it needs at least one shader and, when the Mac libraries of the same chain are present, 90% of their count. A shader counts once whether it ships in a shader pack
# (dmsh_pack.py's index, every pack it names present) or as its own <key>_b.metallib
lib_keys() { find "$1" -maxdepth 1 -name '*_b.metallib' 2> /dev/null | sed 's|.*/||; s|\.metallib$||'; }
if [ "$GFXAPI" = vulkan ]; then NLIB=$(find "$MSL_IOS/$MSLDIR" -name '*.metallib' 2> /dev/null | wc -l | tr -d ' ')
elif [ $PACKS = 1 ]; then PI=$MSL_IOS/$MSLDIR/pack/index.tsv
  for n in $(grep -v '^#' "$PI" | cut -f2 | sort -u); do [ -f "$MSL_IOS/$MSLDIR/pack/$n.metallib" ] || die "shader pack $n named in $PI is missing"; done
  [ -f "$MSL_IOS/$MSLDIR/pack/refl.bin" ] || die "no $MSL_IOS/$MSLDIR/pack/refl.bin"
  NLIB=$( { grep -v '^#' "$PI" | cut -f1; lib_keys "$MSL_IOS/$MSLDIR"; } | sort -u | wc -l | tr -d ' ')
else NLIB=$(lib_keys "$MSL_IOS/$MSLDIR" | wc -l | tr -d ' '); fi
[ "$NLIB" -ge 1 ] || die "no iOS shader libraries in $MSL_IOS/$MSLDIR (chain $V: build them with dm/gfx/tools/dmsh_build.py); the app would show a blank picture"
if [ "$GFXAPI" = nvn ] && [ -d "$MSL_MAC/$MSLDIR" ]; then
  NMAC=$(lib_keys "$MSL_MAC/$MSLDIR" | wc -l | tr -d ' ')
  [ $((NLIB * 10)) -ge $((NMAC * 9)) ] || die "only $NLIB iOS shaders in $MSL_IOS/$MSLDIR against $NMAC Mac ones in $MSL_MAC/$MSLDIR (chain $V): rebuild the iOS set"
fi
# Shared-font stand-ins: standard = macOS's Arial Unicode (absent on iOS), Nintendo extension = button icons generated by make_ext_font.py (needs fontTools; FONT_PY names a python that has it)
mkdir -p "$FONT_O" && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" "$FONT_O"/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
"${FONT_PY:-python3}" "$DM/tools/make_ext_font.py" "$FONT_O"/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# The RomFS chunk store at ROMSTORE (default $W/build/romfs.dmstore): reused when it exists (ROMSTORE_REBUILD=1 rebuilds it)
romstore_ready() {
  ROMSTORE=${ROMSTORE:-$W/build/romfs.dmstore}
  if [ -f "$ROMSTORE" ] && [ "${ROMSTORE_REBUILD:-0}" != 1 ]; then t "chunk store: reusing $ROMSTORE (ROMSTORE_REBUILD=1 rebuilds it)"
  else
    TR=(); if [ -n "${ROMSTORE_TRACE:-}" ]; then IFS=: read -ra TRS <<< "$ROMSTORE_TRACE"; for f in "${TRS[@]}"; do TR+=(--trace "$f"); done; fi
    RC=(python3 "$DM/tools/romstore/romstore.py" build "$ROMFS" "$ROMSTORE" ${TR[@]+"${TR[@]}"})
    t "chunk store: building $ROMSTORE from $ROMFS (romstore.py, 2 threads)"
    if python3 -c 'import zstandard' 2> /dev/null; then "${RC[@]}"; else nix-shell -p 'python3.withPackages(ps:[ps.zstandard])' --run "$(printf '%q ' "${RC[@]}")"; fi || die "romstore.py build"
  fi
}
# Pack mode ends here: the parts an IPA would take from Gen/, DerivedData and the work folder are cloned into the pack, the code dylibs are linked, then the manifest
clone() {   # APFS clone of a file or folder (no extra disk on the same volume); on another volume a real copy, said so
  mkdir -p "$(dirname "$2")" || die "mkdir $(dirname "$2")"
  cp -c -R "$1" "$2" 2> /dev/null || { t "[RED] cannot clone $1 into the pack (another volume?): copying"; rm -rf "$2"; cp -R "$1" "$2" || die "copy $1"; }
}
if [ -n "${PACK:-}" ]; then
  if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; else MSLDIR=b-$V; fi
  t "code dylibs (gen_embed.py --dylib)"
  for P in ios macos; do python3 tools/gen_embed.py "$PATCHED" "$PW/code/embed.S" $MODS --title "$GAME" --dylib "$PW/code/$P.dylib" --target $P > /dev/null || die "code dylib $P"; done
  rm -f "$PW/code/embed.S"
  clone "$MSL_IOS/$MSLDIR" "$PW/msl/ios/$MSLDIR"
  if [ -d "$MSL_MAC/$MSLDIR" ]; then clone "$MSL_MAC/$MSLDIR" "$PW/msl/macos/$MSLDIR"; else t "[RED] no Mac shader libraries $MSL_MAC/$MSLDIR (MSL_MAC): the pack boots on iOS only"; fi
  if [ -n "$AOC" ] && [ -d "$AOC" ]; then clone "$AOC" "$PW/aoc"; t "add-on content: $(ls "$AOC" | tr '\n' ' ')"; fi
  [ "$ROMFS_MODE" = store ] || t "IPA_ROMFS=$ROMFS_MODE ignored: a pack holds the RomFS as a chunk store"
  romstore_ready; clone "$ROMSTORE" "$PW/romfs.dmstore"
  ICON=${DM_ICON:-$(dirname "$ROMFS")/icon.jpg}; if [ -f "$ICON" ]; then clone "$ICON" "$PW/meta/icon.jpg"; else t "no icon ($ICON)"; fi
  [ -f "$VNACP" ] && clone "$VNACP" "$PW/meta/control.nacp"
  python3 "$DM/tools/pack_manifest.py" write "$PW" --title "$GAME" --chain "$V" --display-version "$DM_APP_VERSION" || die "pack_manifest.py"
  rm -rf "$PACK" && mv "$PW" "$PACK" || die "move $PW to $PACK"
  t "done: $PACK ($(du -sh "$PACK" | cut -f1) as du counts it; clones share their blocks with the sources)"
  exit 0
fi
# App icon: Hearth's own mark, drawn by Hearth/Assets/hearth_icon.c as a 1024x1024 PNG in the asset catalog Gen/Assets.xcassets (a single-size app icon; actool generates the other sizes).
# The game's icon (icon.jpg saved from the control data by nx_extract, the English 256x256 one; DM_ICON can point at another image) is the game's tile on Home, in the pack's meta/
ICON=${DM_ICON:-$(dirname "$ROMFS")/icon.jpg}
mkdir -p Gen/Assets.xcassets && printf '{"info":{"author":"xcode","version":1}}\n' > Gen/Assets.xcassets/Contents.json || die "asset catalog"
AI=Gen/Assets.xcassets/AppIcon.appiconset; mkdir -p "$AI" || die "mkdir $AI"
clang -O1 -o Gen/hearth_icon Hearth/Assets/hearth_icon.c -framework CoreGraphics -framework ImageIO -framework CoreFoundation || die "build the app icon renderer"
Gen/hearth_icon "$AI/icon.png" 1024 || die "draw the app icon"
printf '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n' > "$AI/Contents.json"
echo "DM_APPICON = AppIcon" >> Gen/dm.xcconfig
t "app icon: Hearth's mark (Hearth/Assets/hearth_icon.c)"
python3 tools/gen_licenses.py "$DM/.." Gen/licenses.txt || die "gen_licenses.py"   # About > Licences: every shipped component's licence
[ -f "$ICON" ] || t "no game icon ($ICON not found): the game's tile on Home shows a placeholder"
# The bundled pack's own parts: icon and control data, then manifest.json (pack_manifest.py --bundled: the code is the executable's own and the app's signature seals the files, so no inventory)
if [ -f "$ICON" ]; then cp "$ICON" Gen/pack/meta/icon.jpg || die "copy $ICON"; fi
if [ -f "$VNACP" ]; then cp "$VNACP" Gen/pack/meta/control.nacp || die "copy $VNACP"; fi
python3 "$DM/tools/pack_manifest.py" write Gen/pack --title "$GAME" --chain "$V" --display-version "$DM_APP_VERSION" --bundled > /dev/null || die "pack_manifest.py"
xcodegen generate -q > /dev/null || die "xcodegen"

t "xcodebuild (Release, unsigned, iPhone + iPad)"
mkdir -p "$O"
# XCODE_JOBS = how many compile jobs xcodebuild runs at once (default: its own choice, one per core)
xcodebuild -project DmIOS.xcodeproj -scheme DmIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" ${XCODE_JOBS:+-jobs "$XCODE_JOBS"} \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$O/build.log" 2>&1 \
  || { grep -E 'error:' "$O/build.log" | head -20; die "xcodebuild, log $O/build.log"; }
# When Xcode's Locations setting is a custom location, products ignore -derivedDataPath: take the actual path from this build's log
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app; [ -d "$APP" ] || APP=$(grep -o '/[^ ]*/Release-iphoneos/DmIOS\.app' "$O/build.log" | tail -1)
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"

# Straight from the sources: the app without its signature, and without the folders an app built before pack_ipa.py still has (DerivedData keeps resources that left the project;
# msl/ is also deleted there, it took 1.5 GB of the home disk; dm/ and the top-level msl/ and aoc/ are the layout before the bundled pack), then the shader libraries, the add-on content (the RomFS extracted from the player's DLC NSPs, one folder per index:
# the app sets DM_AOC_DIR at launch, the host reports them as owned and mounts them from it) and the RomFS
rm -rf "$APP/msl" "$APP/aoc" "$APP/dm" "$APP/pack/msl" "$APP/pack/aoc" "$O/Payload" "$O/out.ipa"   # (the last two: what the copy-and-zip packing left behind)
P=Payload/DmIOS.app; PM=$P/pack/msl/ios/$MSLDIR; MAPS=("$P=$APP" "$PM=$MSL_IOS/$MSLDIR")
SKIPS=$O/pack_skip.txt; : > "$SKIPS" || die "write $SKIPS"
if [ $PACKS = 1 ]; then   # the packer's AIR cache and every loose library a pack holds stay out
  echo "$PM/pack/.air" > "$SKIPS"; awk -F'\t' -v d="$PM/" '!/^#/ { print d $1 ".metallib"; print d $1 ".json" }' "$MSL_IOS/$MSLDIR/pack/index.tsv" >> "$SKIPS"
  t "shader packs: $(ls "$MSL_IOS/$MSLDIR/pack/"*.metallib | wc -l | tr -d ' ') packs for $(grep -vc '^#' "$MSL_IOS/$MSLDIR/pack/index.tsv") shaders replace their loose libraries"
  [ -f "$MSL_MAC/$MSLDIR/pack/index.tsv" ] || t "[RED] no Mac shader packs ($MSL_MAC/$MSLDIR/pack): pipelines harvested on this Mac miss on the device"
else t "no shader packs ($MSL_IOS/$MSLDIR/pack, SHADER_PACKS): one library per shader"; fi
if [ "${CODE_DYLIB:-0}" = 1 ]; then MAPS+=("$P/Frameworks=$O/fw"); fi
if [ -n "$AOC" ] && [ -d "$AOC" ]; then MAPS+=("$P/pack/aoc=$AOC"); t "add-on content: $(ls "$AOC" | tr '\n' ' ')"; fi
if [ "$ROMFS_MODE" = store ]; then
  romstore_ready
  t "RomFS not packed (IPA_ROMFS=store): after installing the app, copy the store with: python3 $DM/tools/romstore/romstore.py install $ROMSTORE --device <udid> --bundle $DM_BUNDLE_ID"
elif [ "$ROMFS_MODE" = 0 ]; then t "RomFS not packed (IPA_ROMFS=0): the app reads Documents/romfs"; else MAPS+=("$P/romfs=$ROMFS"); fi
t "pack IPA (already-compressed game files stored, everything else deflated)"
python3 tools/pack_ipa.py "$OUT_IPA" --store "$(gp zip_store)" --skip $P/_CodeSignature --skip $P/embedded.mobileprovision --skip $P/pack/msl --skip $P/pack/aoc --skip $P/romfs --skip-list "$SKIPS" "${MAPS[@]}" || die "pack_ipa"
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"
