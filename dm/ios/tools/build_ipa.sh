#!/bin/bash
# Build one unsigned all-in-one IPA: the rewritten modules compiled into the executable, and everything else as a game pack at DmIOS.app/pack (docs/development.md "Game packs": profile/,
# msl/ios/, pso/ios/, font/, aoc/, meta/ and manifest.json, without code/, which the executable embeds, and without the RomFS store, which goes to Documents; IPA_ROMFS=1 puts the RomFS at DmIOS.app/romfs).
# Xcode builds only the app (Hearth, dm/ios/Hearth); tools/pack_ipa.py then packs it with the shader libraries, the pipeline archive, the add-on content and the RomFS straight from where they are (no Payload/ copy,
# nothing through the home disk). At install time a signing tool (AltStore / Sideloadly etc.) swaps in your own certificate and bundle ID.
# Prerequisites: the rewriter (patched directory) and the iOS shader build (IOSOUT) have been run as in the README; Xcode and xcodegen are installed.
# Usage: dm/ios/tools/build_ipa.sh [output.ipa]; environment: GAME=game profile (dm/games/<base game title ID>, or one in DM_GAMES_DIR; required), W=the game's work folder (required: <NSP folder>/<title ID>-work, never the home folder), PATCHED / ROMFS / MSL_IOS can each be overridden
#   ROMFS is the extraction's RomFS.img (the NSP script's default) or a RomFS folder
#   AOC=add-on content directory (default $W/data/aoc; when it exists it goes to DmIOS.app/pack/aoc/<index>/; an empty string = none), GFXAPI=nvn / vulkan / gl (default: by the shader libraries in MSL_IOS)
#   IPA_ROMFS=store (the default) leaves the RomFS out of the IPA and builds a chunk store of it (dm/tools/romstore/romstore.py: deduplicated, compressed, random access, about 46% of the loose size) at ROMSTORE (default $W/build/romfs.dmstore;
#   an existing one is reused, ROMSTORE_REBUILD=1 rebuilds it, ROMSTORE_TRACE = DM_FSLOG files separated by ':' order it by first read); install it with
#   romstore.py install, and the app reads Documents/romfs.dmstore before Documents/romfs
#   IPA_ROMFS=1 packs the RomFS into the IPA (DmIOS.app/romfs): one self-contained IPA that needs no extra copy, the way builds worked before the store became the default
#   IPA_ROMFS=0 leaves the RomFS out and builds no store (it is still read for the control data and the icon): the app then needs it at Documents/romfs, for a build that updates an install which already has the game files
#   The app name is the game name in the base NSP's control data ($W/data/v0/control.nacp, else the one next to the RomFS), the app version is the display version in the packed game's control data (the one next to the RomFS:
#   nx_extract saves the update's there when an update is packed, else the base game's), the bundle ID is org.anyswitch.<base game title ID in lowercase> (DM_DISPLAY_NAME / DM_APP_VERSION / DM_BUNDLE_ID override them);
#   DM_SHOW_FPS=1 turns the frame-rate counter on (DM_SHOW_FPS in the app's Documents/env.txt overrides it on the phone);
#   DM_METAL_CAPTURE=1 makes a development build that can write GPU frame captures (MetalCaptureEnabled in Info.plist, for the host's DM_GPU_CAPTURE switch);
#   DM_ENTITLEMENTS=<plist> is signed ad-hoc into the executable, for an install tool that keeps the entitlements of the signature it replaces (default: none; free Apple ID signing grants only its own);
#   DM_SHADER_FILES=1 packs an NVN game's shader library as its separate files, not as the one file b-<chain>.img, for install tools that cannot copy a large file (pack_ipa.py --shader-files);
#   DM_PSO_GPUS=<comma-separated GPU architectures> or none: the offline pipeline archive (dm/gfx/tools/pso_offline.py), by default as the profile's pso_mtl4 / pso_gpu say;
#   the IPA name, code modules, RomFS marker and shader tables come from the game profile
#   PACK=<new folder> writes a game pack there instead of an IPA (docs/development.md "Game packs"): the same tables, pipeline archive and fonts, the code dylibs for iOS and the Mac
#   (gen_embed.py --dylib), the iOS shader libraries and the Mac ones (MSL_MAC), the add-on content, the RomFS chunk store, icon and control data, then manifest.json
#   (dm/tools/pack_manifest.py); big files enter as APFS clones (cp -c: no extra disk on the same volume), and nothing is built with Xcode
#   CODE_DYLIB=1 links the rewritten modules into DmIOS.app/Frameworks/<title id>.dylib (gen_embed.py --dylib --target ios) instead of the executable; Hearth (HearthLibrary.m) points DM_CODE at it,
#   so the app maps its code the way a pack's code/ios.dylib is mapped (the install tool signs the dylib with the app)
# Not supported by Hearth (upstream's single-game app has them; docs/sync-upstream-2026-11.md): --prepare-xcode, DM_COPY_ROMFS=NO and PROGRAMS_TSV (a game of several programs)
set -u
cd "$(dirname "$0")/.." || exit 1
DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
[ "${1:-}" != --prepare-xcode ] || die "--prepare-xcode: AnySwitch builds Hearth, one app for every game; a per-game Xcode project is not supported"
[ "${DM_COPY_ROMFS:-YES}" != NO ] || die "DM_COPY_ROMFS=NO: use IPA_ROMFS=store (the default) or IPA_ROMFS=0, which leave the game files out of the IPA"
[ -z "${PROGRAMS_TSV:-}" ] || die "PROGRAMS_TSV: a game of several programs is not supported by Hearth's packs yet"
# Metal's pipeline compiler (metal-tt) leaves temp entries in the per-user gpuarchiver cache (13 GB once): when this build ends, remove the ones it made, never the others (scripts/diskhygiene.py)
HYG=$DM/../scripts/diskhygiene.py; GPU_SNAP=$(mktemp -t dm_gpusnap.XXXXXX) && python3 "$HYG" gpu-snapshot "$GPU_SNAP" && trap 'python3 "$HYG" gpu-clean "$GPU_SNAP"; rm -f "$GPU_SNAP"' EXIT
ROMFS_MODE=${IPA_ROMFS:-store}   # store (default): a chunk store beside the IPA; 1: the RomFS in the IPA; 0: none
case $ROMFS_MODE in store|1|0) ;; *) die "IPA_ROMFS must be store, 1 or 0, not $ROMFS_MODE" ;; esac
[ -n "${GAME:-}" ] || die "GAME is not set: GAME=<base game title ID> $0; profiles: $(python3 "$DM/games/game.py" list | awk -F'\t' '{printf "%s (%s)  ", $1, $3}')"
export GAME; GD=$(python3 "$DM/games/game.py" dir "$GAME") || die "no game profile $GAME"   # dm/games/<id>, or a profile in DM_GAMES_DIR (the NSP script's provisional one)
gp() { python3 "$DM/games/game.py" "$GAME" "$1" || die "game profile $GD: $1"; }   # read a key of the game profile
[ -f "$GD/game.tsv" ] || die "no game profile $GD/game.tsv"
[ -n "${W:-}" ] || die "W is not set: W=<NSP folder>/$GAME-work (the game's work folder) $0"
PKG=$(gp package)
if [ -z "${ROMFS:-}" ] && [ -f "$W/data/$PKG/RomFS.img" ]; then ROMFS=$W/data/$PKG/RomFS.img; fi
PATCHED=${PATCHED:-$W/build/patched_$PKG}; ROMFS=${ROMFS:-$W/data/$PKG/RomFS}; MSL_IOS=${MSL_IOS:-$W/build/ios/dmsh_b}; AOC=${AOC-$W/data/aoc}
OUT_IPA=${1:-$(dirname "$W")/$(gp ipa)}; O=$W/build/ios/pkg; DD=$O/dd
MARKER=$(gp romfs_marker)
NACP=$W/data/v0/control.nacp; [ -f "$NACP" ] || NACP=$(dirname "$ROMFS")/control.nacp
[ -n "${DM_DISPLAY_NAME:-}" ] || DM_DISPLAY_NAME=$(python3 "$DM/tools/nacp.py" "$NACP") || die "no game name in $NACP (re-extract with nx_extract, or set DM_DISPLAY_NAME)"
VNACP=$(dirname "$ROMFS")/control.nacp; [ -f "$VNACP" ] || VNACP=$W/data/v0/control.nacp
[ -n "${DM_APP_VERSION:-}" ] || DM_APP_VERSION=$(python3 "$DM/tools/nacp.py" --version "$VNACP") || { t "no display version in $VNACP: the app version is 1.0"; DM_APP_VERSION=1.0; }
VNACP=${CONTROL:-$VNACP}   # from here on, the file that lists the game's languages (the NSP script's languages_control); the pack's meta/control.nacp
DM_APP_CATEGORY=$(gp app_category) || exit 1
export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.anyswitch.$(echo "$GAME" | tr 'A-Z' 'a-z')} DM_DISPLAY_NAME DM_APP_VERSION DM_APP_CATEGORY DM_TEAM_ID=${DM_TEAM_ID:-0000000000}   # placeholder identity: unsigned, the install tool replaces it
if [ "${DM_SHOW_FPS:-0}" = 1 ]; then export DM_SHOW_FPS=YES; else export DM_SHOW_FPS=NO; fi
export DM_LETTERBOX=${DM_LETTERBOX:-ambient} DM_CONTROLS_LAYOUT=${DM_CONTROLS_LAYOUT:-auto} DM_CONTROLS_SCALE=${DM_CONTROLS_SCALE:-1}   # the pack's settings defaults (DmSettings.m); the app's Documents/env.txt overrides them
# An NVN game's libraries are the folder b-$V or the one file b-$V.img beside its name (dm/tools/shader_lib.py), read in place: whether they hold a shader, one of their files, the path to what is there
lib_has() { python3 "$DM/tools/shader_lib.py" has "$1" 2> /dev/null; }
lib_cat() { python3 "$DM/tools/shader_lib.py" cat "$1" "$2" 2> /dev/null; }
lib_path() { python3 "$DM/tools/shader_lib.py" path "$1"; }
[ -f "$PATCHED/main.fixups.tsv" ] || die "no rewritten main in $PATCHED (run dm/tools/patch_nso.py first)"
MODS=$(python3 "$DM/games/game.py" modules "$GAME" "$PATCHED") || die "game profile $GD: modules"   # main's build row, as the host picks them: a version may lack a module another has
for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f (run dm/tools/patch_nso.py first)"; done
python3 "$DM/tools/romfs.py" "$ROMFS" "$MARKER" || die "no RomFS at $ROMFS (missing $MARKER)"
V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM/gfx/nvn/dmsh_chain.h")   # the chain version the host is compiled with, one for every game
# A Vulkan game (Hades): the shaders are the game's SPIR-V, translated by dm/gfx/tools/vk_shaders.py into $MSL_IOS/vk; an OpenGL game: its GLSL, translated by dm/gfx/tools/gl_shaders.py into
# $MSL_IOS/gl; neither has NVN chain libraries. GFXAPI=nvn / vulkan / gl says which (the NSP script passes what main imports); without it, the shader libraries in $MSL_IOS tell
if [ -z "${GFXAPI:-}" ]; then if lib_has "$MSL_IOS/b-$V"; then GFXAPI=nvn; elif [ -f "$MSL_IOS/vk/vk_shaders.metallib" ]; then GFXAPI=vulkan;
  elif [ -f "$MSL_IOS/gl/gl_shaders.metallib" ]; then GFXAPI=gl; else GFXAPI=nvn; fi; fi
if [ "$GFXAPI" = vulkan ]; then [ -f "$MSL_IOS/vk/vk_shaders.metallib" ] || die "no iOS Vulkan shader library $MSL_IOS/vk (dm/gfx/tools/vk_shaders.py \"$ROMFS\" <Mac dir> --ios \"$MSL_IOS\")"
elif [ "$GFXAPI" = gl ]; then [ -f "$MSL_IOS/gl/gl_shaders.metallib" ] || die "no iOS GL shader library $MSL_IOS/gl (dm/gfx/tools/gl_shaders.py \"$ROMFS\" <main> <Mac dir> --ios \"$MSL_IOS\")"
else [ -n "$V" ] && lib_has "$MSL_IOS/b-$V" || die "no iOS shader libraries $MSL_IOS/b-$V (IOSOUT=$MSL_IOS dmsh_build.py ...)"
  # One chain version serves every game: the libraries' stamp (b-$V/inputs.tsv, written by a full dmsh_build.py run) must name this game and the digest of its profile's current inputs,
  # and c1_full.tsv (made by the same build) must name that digest, or the host ignores it
  IN=$(DM_GAME="$GAME" python3 "$DM/gfx/tools/dmsh_chain.py" --inputs) || die "dmsh_chain.py --inputs (game profile $GD)"
  STAMP=$(lib_cat "$MSL_IOS/b-$V" inputs.tsv)
  printf '%s\n' "$STAMP" | grep -qxF "$(printf 'game\t%s' "$GAME")" && printf '%s\n' "$STAMP" | grep -qxF "$(printf 'inputs\t%s' "$IN")" ||
    die "the iOS shader libraries $MSL_IOS/b-$V are not a full build from this profile's current tables (inputs $IN; their stamp: $([ -n "$STAMP" ] && printf '%s\n' "$STAMP" | grep -v '^#' | tr '\n\t' '  ' || echo none)): build them again (IOSOUT=$MSL_IOS dmsh_build.py ...)"
  head -1 "$GD/c1_full.tsv" 2> /dev/null | grep -q "^# chain b-$V inputs $IN " || die "$GD/c1_full.tsv is missing or not made from these libraries (chain $V, inputs $IN): a full dmsh_build.py run makes it and cb_extent.tsv"; fi
if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; elif [ "$GFXAPI" = gl ]; then MSLDIR=gl; else MSLDIR=b-$V; fi
JIT=$(dirname "$ROMFS")/jit/jit.img; J=(); [ ! -f "$JIT" ] || J=(--jit "$JIT")   # the nn::jit image (dm/tools/jit_capture.py), beside the RomFS: embedded with the code
[ ! -d "$(dirname "$ROMFS")/html" ] || t "[RED] offline HTML pages $(dirname "$ROMFS")/html are not carried by Hearth's packs yet: the game's web pages will not open"

# Destinations: the pack's profile/ and font/, in Gen/pack (IPA: the app's DmIOS.app/pack) or in the pack folder (PACK)
if [ -n "${PACK:-}" ]; then
  [ ! -e "$PACK" ] || [ -f "$PACK/manifest.json" ] || die "PACK=$PACK exists and is not a game pack: give a new folder"
  PW=$PACK.partial; t "game pack: $PACK (built in $PW, moved in place when complete)"
  rm -rf "$PW" && mkdir -p "$PW/profile" "$PW/font" "$PW/code" "$PW/meta" || die "mkdir $PW"
  DMO=$PW/profile; FONT_O=$PW/font
else
  t "app: $DM_DISPLAY_NAME $DM_APP_VERSION ($DM_BUNDLE_ID)$([ $DM_SHOW_FPS = YES ] && echo ', frame-rate counter on')"
  t "generate Gen/ (host sources, embedded modules, tables)"
  rm -rf Gen && mkdir -p Gen/pack/profile Gen/pack/meta || die "mkdir Gen"
  python3 tools/gen_build.py ../host Gen > Gen/dm.xcconfig || die "gen_build"
  F=; rm -rf "$O/fw"
  if [ "${CODE_DYLIB:-0}" = 1 ]; then
    [ ${#J[@]} = 0 ] || die "CODE_DYLIB=1: the nn::jit image goes into the executable; build without CODE_DYLIB"
    mkdir -p "$O/fw" && python3 tools/gen_embed.py "$PATCHED" "$O/fw/embed.S" $MODS --title "$GAME" --dylib "$O/fw/$GAME.dylib" --target ios > /dev/null || die "code dylib"
    rm -f "$O/fw/embed.S"; echo '// CODE_DYLIB=1: the rewritten modules are in Frameworks/<title id>.dylib' > Gen/embed.S; t "code: Frameworks/<title id>.dylib (CODE_DYLIB=1)"
  else F=$(python3 tools/gen_embed.py "$PATCHED" Gen/embed.S $MODS --title "$GAME" ${J[@]+"${J[@]}"}) || die "gen_embed"; fi
  echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig
  DMO=Gen/pack/profile; FONT_O=Gen/pack/font
fi
cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv "$DMO"/ || die "copy rewriter tables"
if [ -f "$PATCHED/nro.tsv" ]; then cp "$PATCHED/nro.tsv" "$DMO"/ || die "copy the NRO table"; fi   # the NRO modules the game loads with nn::ro (hle_ro.c), embedded by gen_embed.py
if [ "$GFXAPI" = vulkan ] || [ "$GFXAPI" = gl ]; then cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$DMO"/ || die "copy shader tables"   # empty NVN tables: the NVN layer draws nothing
else cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" "$DMO"/ || die "copy shader tables"
  if [ -f "$GD/cb_extent.tsv" ]; then cp "$GD/cb_extent.tsv" "$DMO"/ || die "copy cb_extent.tsv"; else t "no $GD/cb_extent.tsv: the host copies whole uniform bindings"; fi
  # the shader pairs, beside the shader map where the pipeline prebuild reads them (nvn_mtl.m pso_prebuild): without them the app makes no pulling bases, and a hybrid draw has no stand-in
  for f in shader_pairs.tsv pso_pairs.tsv; do if [ -f "$GD/$f" ]; then cp "$GD/$f" "$DMO"/ || die "copy $f"; fi; done; fi   # optional
# The game profile the host reads at boot (profile/game.json)
python3 "$DM/games/game.py" json "$GAME" "$DMO" || die "game.json"
# The game's own sections of the in-app settings screen (docs/settings.md): dm/games/<id>/settings.json becomes profile/settings.json
if [ -f "$GD/settings.json" ]; then cp "$GD/settings.json" "$DMO"/settings.json || die "copy settings.json"; t "settings: $GD/settings.json"; fi
# The pipeline archive made offline (dm/gfx/tools/pso_offline.py): the base of every shader pair and a pipeline per compute shader of the shader map, compiled here by metal-tt for each GPU
# architecture in DM_PSO_GPUS (comma-separated; none = no archive), so the device does not build them on its first start. Only the Metal 4 path reads it, which iOS turns on for a game whose
# profile sets pso_mtl4 on: the default is what the profile's pso_gpu key names, else g18p, and none for the games that do not set pso_mtl4 on. It goes into the pack as pso/ios
# (boot.m hands it to the host as DM_PSO_BUNDLE); made again only when its inputs change
PSO=; P4=$(python3 "$DM/games/game.py" "$GAME" pso_mtl4 off) || die "game profile $GD: pso_mtl4"; PG=$(python3 "$DM/games/game.py" "$GAME" pso_gpu '') || die "game profile $GD: pso_gpu"
PGK=g18p; N=0; for w in $PG; do case $w in none) N=9; break ;; esac; case ${w#applegpu_} in '' | *[!A-Za-z0-9]*) N=9; break ;; esac; N=$((N+1)); done
if [ "$P4" = on ] && [ "$PG" ]; then case $N in 1 | 2 | 3 | 4) PGK=$(echo "$PG" | tr -s ' \t' ',') ;; *) t "profile $GD: pso_gpu '$PG' is not 1-4 whitespace-separated GPU architectures - taking g18p" ;; esac; fi
if [ -n "${DM_PSO_GPUS+set}" ]; then GPUS=$DM_PSO_GPUS; elif [ "$P4" = on ]; then GPUS=$PGK; else GPUS=none; fi
if [ "$GFXAPI" = nvn ] && [ -n "$GPUS" ] && [ "$GPUS" != none ] && [ -f "$GD/shader_pairs.tsv" ]; then
  PSO=$W/build/ios/pso/bundle
  t "pipeline archive for $GPUS (metal-tt; minutes when its inputs changed)"
  python3 "$DM/gfx/tools/pso_offline.py" --game "$GAME" --msl "$MSL_IOS/b-$V" --out "$PSO" --work "$W/build/ios/pso/work" --gpu "$GPUS" ${DM_PSO_IOS_MIN:+--os-min "$DM_PSO_IOS_MIN"} \
    | while IFS= read -r ln; do t "$ln"; done
  if [ "${PIPESTATUS[0]}" != 0 ]; then   # an optimization: the device builds the bases on its first start without it
    t "[RED] pipeline archive: pso_offline.py failed (its output is above); the app is built without one and the device builds its pipeline bases on its first start (DM_PSO_GPUS=none skips this step)"
    rm -rf "$PSO"; PSO=
  fi
else [ "$GFXAPI" != nvn ] || t "no pipeline archive ($([ -n "${DM_PSO_GPUS+set}" ] && echo "DM_PSO_GPUS=${GPUS:-empty}" || echo "the profile does not set pso_mtl4 on; DM_PSO_GPUS=g18p builds one")$([ -f "$GD/shader_pairs.tsv" ] || echo ', no shader_pairs.tsv'))"; fi
# Diagnostic build: DM_ENV_FILE=file → profile/env.txt in the bundled pack (main.m sets one environment variable per line at boot)
if [ -n "${DM_ENV_FILE:-}" ]; then cp "$DM_ENV_FILE" "$DMO"/env.txt || die "copy DM_ENV_FILE"; t "env: $(grep -v '^#' "$DM_ENV_FILE" | tr '\n' ' ')"; fi
# Shared-font stand-ins: standard = macOS's Arial Unicode (absent on iOS), Nintendo extension = button icons generated by make_ext_font.py (needs fontTools; FONT_PY names a python that has it)
mkdir -p "$FONT_O" && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" "$FONT_O"/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
"${FONT_PY:-python3}" "$DM/tools/make_ext_font.py" "$FONT_O"/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# The RomFS chunk store at ROMSTORE (default $W/build/romfs.dmstore), from the RomFS image or folder: reused when it exists (ROMSTORE_REBUILD=1 rebuilds it)
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
  [ ${#J[@]} = 0 ] || die "PACK: the nn::jit image is not carried by code dylibs yet"
  MSL_MAC=${MSL_MAC:-$W/build/cache}
  t "code dylibs (gen_embed.py --dylib)"
  for P in ios macos; do python3 tools/gen_embed.py "$PATCHED" "$PW/code/embed.S" $MODS --title "$GAME" --dylib "$PW/code/$P.dylib" --target $P > /dev/null || die "code dylib $P"; done
  rm -f "$PW/code/embed.S"
  LI=$(lib_path "$MSL_IOS/$MSLDIR") || die "shader libraries $MSL_IOS/$MSLDIR"; clone "$LI" "$PW/msl/ios/$(basename "$LI")"
  if lib_has "$MSL_MAC/$MSLDIR" || [ -d "$MSL_MAC/$MSLDIR" ]; then LM=$(lib_path "$MSL_MAC/$MSLDIR"); clone "$LM" "$PW/msl/macos/$(basename "$LM")"
  else t "[RED] no Mac shader libraries $MSL_MAC/$MSLDIR (MSL_MAC): the pack boots on iOS only"; fi
  if [ -n "$PSO" ]; then clone "$PSO" "$PW/pso/ios"; fi
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
# DMCommit / DMChain: the checkout that built the app (+dirty with uncommitted changes to tracked files) and the shader chain it carries, which the host logs at start (main.c)
COMMIT=$(git -C "$DM" rev-parse --short=12 HEAD 2> /dev/null) && { [ -z "$(git -C "$DM" status --porcelain --untracked-files=no 2> /dev/null)" ] || COMMIT=$COMMIT+dirty
  /usr/libexec/PlistBuddy -c "Add :DMCommit string $COMMIT" Gen/Info.plist > /dev/null || die "DMCommit"; t "source: $COMMIT"; }
case "$MSLDIR" in b-*) /usr/libexec/PlistBuddy -c "Add :DMChain string ${MSLDIR#b-}" Gen/Info.plist > /dev/null || die "DMChain";; esac
# DM_METAL_CAPTURE=1: a development build that may write GPU frame captures (MetalCaptureEnabled; the host's DM_GPU_CAPTURE switch writes them to Documents/gpu_captures)
if [ "${DM_METAL_CAPTURE:-0}" = 1 ]; then /usr/libexec/PlistBuddy -c "Add :MetalCaptureEnabled bool true" Gen/Info.plist > /dev/null || die "MetalCaptureEnabled"; t "Metal frame capture: enabled (DM_METAL_CAPTURE=1)"; fi

t "xcodebuild (Release, unsigned, iPhone + iPad)"
mkdir -p "$O"
# XCODE_JOBS = how many compile jobs xcodebuild runs at once (default: its own choice, one per core)
xcodebuild -project DmIOS.xcodeproj -scheme DmIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" ${XCODE_JOBS:+-jobs "$XCODE_JOBS"} \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$O/build.log" 2>&1 \
  || { grep -E 'error:' "$O/build.log" | head -20; die "xcodebuild, log $O/build.log"; }
# When Xcode's Locations setting is a custom location, products ignore -derivedDataPath: take the actual path from this build's log
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app; [ -d "$APP" ] || APP=$(grep -o '/[^ ]*/Release-iphoneos/DmIOS\.app' "$O/build.log" | tail -1)
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"
# DM_ENTITLEMENTS: the executable's ad-hoc signature carries them, for an install tool that keeps the entitlements of the signature it replaces (upstream's default is the Increased Memory
# Limit; AnySwitch's default is none, as the free Apple ID's profile decides what the re-signed app may have)
if [ -n "${DM_ENTITLEMENTS:-}" ]; then
  EXE=$APP/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist") || die "CFBundleExecutable of $APP"
  xattr -cr "$EXE" 2> /dev/null   # codesign refuses a file with a resource fork, Finder information or quarantine attributes
  codesign --force --sign - --entitlements "$DM_ENTITLEMENTS" "$EXE" || die "ad-hoc signature with the entitlements"
  t "entitlements in the executable's ad-hoc signature: $DM_ENTITLEMENTS"
fi

# Straight from the sources: the app without its signature, and without the folders an app built before pack_ipa.py still has (DerivedData keeps resources that left the project;
# dm/ and the top-level msl/ and aoc/ are the layout before the bundled pack), then the shader libraries, the pipeline archive, the add-on content (the RomFS extracted from the player's DLC NSPs,
# one folder per index: the host reports them as owned and mounts them from it) and the RomFS
rm -rf "$APP/msl" "$APP/aoc" "$APP/dm" "$APP/pack/msl" "$APP/pack/aoc" "$APP/pack/pso" "$O/Payload" "$O/out.ipa"   # (the last two: what the copy-and-zip packing left behind)
P=Payload/DmIOS.app; MAPS=("$P=$APP" "$P/pack/msl/ios/$MSLDIR=$MSL_IOS/$MSLDIR")   # pack_ipa.py maps an NVN library image as b-<chain>.img
if [ "${CODE_DYLIB:-0}" = 1 ]; then MAPS+=("$P/Frameworks=$O/fw"); fi
if [ -n "$PSO" ]; then MAPS+=("$P/pack/pso/ios=$PSO"); fi
if [ -n "$AOC" ] && [ -d "$AOC" ]; then MAPS+=("$P/pack/aoc=$AOC"); t "add-on content: $(ls "$AOC" | tr '\n' ' ')"; fi
if [ "$ROMFS_MODE" = store ]; then
  romstore_ready
  t "RomFS not packed (IPA_ROMFS=store): after installing the app, copy the store with: python3 $DM/tools/romstore/romstore.py install $ROMSTORE --device <udid> --bundle $DM_BUNDLE_ID"
elif [ "$ROMFS_MODE" = 0 ]; then t "RomFS not packed (IPA_ROMFS=0): the app reads Documents/romfs"; else MAPS+=("$P/romfs=$ROMFS"); fi
t "pack IPA (already-compressed game files stored, everything else deflated)"
# Without an offline archive the device's prebuild needs the pulling vertex libraries (_bp.metallib); IOS_PULL=0 omits them then, an IPA with an archive always carries them
PACK_OPTS=(--store "$(gp zip_store)"); [ -n "$PSO" ] || [ "${IOS_PULL:-1}" = 1 ] || PACK_OPTS+=(--skip-suffix _bp.metallib)
[ "${DM_SHADER_FILES:-0}" != 1 ] || PACK_OPTS+=(--shader-files)
python3 tools/pack_ipa.py "$OUT_IPA" "${PACK_OPTS[@]}" --skip $P/_CodeSignature --skip $P/embedded.mobileprovision --skip $P/pack/msl --skip $P/pack/pso --skip $P/pack/aoc --skip $P/romfs "${MAPS[@]}" || die "pack_ipa"
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"
