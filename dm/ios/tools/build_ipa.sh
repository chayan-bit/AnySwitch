#!/bin/bash
# Build one unsigned all-in-one IPA: the rewritten modules compiled into the executable, iOS shader libraries at DmIOS.app/msl, and the game files (RomFS) at DmIOS.app/romfs.
# Xcode builds only the app; tools/pack_ipa.py then packs it with the shader libraries, the add-on content and the RomFS straight from where they are (no Payload/ copy, nothing through the home disk). At install time a signing tool (AltStore / Sideloadly etc.) swaps in your own certificate and bundle ID.
# Prerequisites: the rewriter (patched directory) and the iOS shader build (IOSOUT) have been run as in the README; Xcode and xcodegen are installed.
# Usage: dm/ios/tools/build_ipa.sh [output.ipa]; environment: GAME=game profile (dm/games/<base game title ID>, or one in DM_GAMES_DIR; required), W=the game's work folder (required: <NSP folder>/<title ID>-work, never the home folder), PATCHED / ROMFS / MSL_IOS can each be overridden
#   AOC=add-on content directory (default $W/data/aoc; when it exists it goes to DmIOS.app/aoc/<index>/; an empty string = none), GFXAPI=nvn / vulkan (default: by the shader libraries in MSL_IOS)
#   The app name is the game name in the base NSP's control data ($W/data/v0/control.nacp, else the one next to the RomFS), the app version is the display version in the packed game's control data (the one next to the RomFS:
#   nx_extract saves the update's there when an update is packed, else the base game's), the bundle ID is org.anyswitch.<base game title ID in lowercase> (DM_DISPLAY_NAME / DM_APP_VERSION / DM_BUNDLE_ID override them);
#   DM_SHOW_FPS=1 turns the frame-rate counter on (DMShowFPS in Info.plist; DM_SHOW_FPS in the app's Documents/env.txt overrides it on the phone);
#   the IPA name, code modules, RomFS marker and shader tables come from the game profile
set -u
cd "$(dirname "$0")/.." || exit 1
IOS=$PWD; DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
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
export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.anyswitch.$(echo "$GAME" | tr 'A-Z' 'a-z')} DM_DISPLAY_NAME DM_APP_VERSION DM_APP_CATEGORY=$(gp app_category) DM_TEAM_ID=${DM_TEAM_ID:-0000000000}   # placeholder identity: unsigned, the install tool replaces it
if [ "${DM_SHOW_FPS:-0}" = 1 ]; then export DM_SHOW_FPS=YES; else export DM_SHOW_FPS=NO; fi
export DM_LETTERBOX=${DM_LETTERBOX:-ambient} DM_CONTROLS_LAYOUT=${DM_CONTROLS_LAYOUT:-auto} DM_CONTROLS_SCALE=${DM_CONTROLS_SCALE:-1}   # Info.plist DMLetterbox / DMControlsLayout / DMControlsScale (front_ios.m); the app's Documents/env.txt overrides them
for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f (run dm/tools/patch_nso.py first)"; done
[ -e "$ROMFS/$MARKER" ] || die "no RomFS at $ROMFS (missing $MARKER)"
V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$GD/dmsh_chain.h")
# A Vulkan game (Hades): the shaders are the game's SPIR-V, translated by dm/gfx/tools/vk_shaders.py into $MSL_IOS/vk; there are no NVN chain libraries. GFXAPI=nvn / vulkan says which
# (the NSP script passes what main imports); without it, the shader libraries in $MSL_IOS tell: the chain's b-$V, else vk
if [ -z "${GFXAPI:-}" ]; then if ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$'; then GFXAPI=nvn; elif [ -f "$MSL_IOS/vk/vk_shaders.metallib" ]; then GFXAPI=vulkan; else GFXAPI=nvn; fi; fi
if [ "$GFXAPI" = vulkan ]; then [ -f "$MSL_IOS/vk/vk_shaders.metallib" ] || die "no iOS Vulkan shader library $MSL_IOS/vk (dm/gfx/tools/vk_shaders.py \"$ROMFS\" <Mac dir> --ios \"$MSL_IOS\")"
else [ -n "$V" ] && ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$' || die "no iOS shader libraries $MSL_IOS/b-$V (IOSOUT=$MSL_IOS dmsh_build.py ...)"; fi

t "app: $DM_DISPLAY_NAME $DM_APP_VERSION ($DM_BUNDLE_ID)$([ $DM_SHOW_FPS = YES ] && echo ', frame-rate counter on')"
t "generate Gen/ (host sources, embedded modules, tables)"
rm -rf Gen && mkdir -p Gen/dm || die "mkdir Gen"
python3 tools/gen_build.py ../host Gen > Gen/dm.xcconfig || die "gen_build"
F=$(python3 tools/gen_embed.py "$PATCHED" Gen/embed.S $MODS) || die "gen_embed"
echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig
cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv Gen/dm/ || die "copy rewriter tables"
if [ "$GFXAPI" = vulkan ]; then cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" Gen/dm/ || die "copy shader tables"   # empty NVN tables: the NVN layer is never used
else cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" Gen/dm/ || die "copy shader tables"
  if [ -f "$GD/cb_extent.tsv" ]; then cp "$GD/cb_extent.tsv" Gen/dm/ || die "copy cb_extent.tsv"; fi; fi   # optional: without it the host copies whole uniform bindings
# The game's own sections of the in-app settings screen (docs/settings.md): dm/games/<id>/settings.json becomes dm/settings.json in the app
if [ -f "$GD/settings.json" ]; then cp "$GD/settings.json" Gen/dm/settings.json || die "copy settings.json"; t "settings: $GD/settings.json"; fi
# Precompiled pipelines (docs/stageB-pipeline-archives.md) as dm/pso_archive.metallib, where the host looks each pipeline up before compiling it: PSO_ARCHIVE=a finished archive, taken as is;
# else the harvests (DM_PSO_HARVEST runs on the Mac or the device) are compiled together by dmsh_psoarch.py with metal-tt for the iOS GPUs (PSO_ARCHS=architectures to keep it small,
# default every iOS GPU) against this chain's iOS libraries; MSL_MAC = the Mac libraries (their MSL is rebuilt with the driver link metal-tt reads).
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
  DM_NVN_SHMAP="$GD/shader_map.tsv" DM_MSL_DIR="$MSL_MAC" python3 "$DM/gfx/tools/dmsh_psoexpand.py" "${PE[@]}" --map "$GD/shader_map.tsv" --refl "$MSL_MAC/b-$V" \
    ${PSO_EXPAND_ARGS:-} --build "$W/build/pso_harvest_expand.metallib" || t "[RED] pipeline expansion failed above: the archive holds the harvests only"
fi
HV=(); if [ -n "${PSO_HARVEST:-}" ]; then IFS=: read -ra HV <<< "$PSO_HARVEST"; else for h in "$W"/build/pso_harvest*.metallib; do [ -f "$h" ] && HV+=("$h"); done; fi
for h in ${HV[@]+"${HV[@]}"}; do [ -f "$h" ] || die "no pipeline harvest $h (PSO_HARVEST)"; done
if [ -n "${PSO_ARCHIVE:-}" ]; then cp "$PSO_ARCHIVE" Gen/dm/pso_archive.metallib || die "copy PSO_ARCHIVE"; t "pipeline archive: $PSO_ARCHIVE (as is)"
elif [ "$GFXAPI" = nvn ] && [ ${#HV[@]} -gt 0 ]; then
  t "pipeline archive: compile ${HV[*]} for the iOS GPUs (metal-tt)"
  mkdir -p "$O" && python3 "$DM/gfx/tools/dmsh_psoarch.py" "${HV[@]}" --libs "$MSL_MAC/b-$V" "$MSL_IOS/b-$V" --target-libs "$MSL_IOS/b-$V" --msl "$MSL_MAC/b-$V" \
    ${PSO_ARCHS:+--arch $PSO_ARCHS} -o "$O/pso_archive.metallib" && cp "$O/pso_archive.metallib" Gen/dm/ || t "[RED] no pipeline archive (dmsh_psoarch.py failed above): pipelines compile on first use"
else t "no pipeline harvest ($W/build/pso_harvest*.metallib, PSO_HARVEST): no pipeline archive, pipelines compile on first use"; fi
# Flexible pipeline archive (dm/gfx/README.md, pipeline coverage) as dm/pso_flex.metallib, for nvn_flexpso.m (DM_PSO_FLEX=1). Tiers filled in order until PSO_FLEX_MB (default 300, 0 = no cap):
# the pipeline logs of earlier runs ($W/build/pso_user*.tsv), then the program pairs of the
# accelerator rules and the same-variation table, then the interface pairs. PSO_FLEX=0 skips it, PSO_FLEX_ARCHIVE=a finished archive taken as is. The archive names the libraries the
# app ships, so it is built from the packed libraries once those are packed
if [ "$GFXAPI" = nvn ] && [ "${PSO_FLEX:-1}" != 0 ]; then
  if [ -n "${PSO_FLEX_ARCHIVE:-}" ]; then cp "$PSO_FLEX_ARCHIVE" Gen/dm/pso_flex.metallib || die "copy PSO_FLEX_ARCHIVE"; t "flexible pipeline archive: $PSO_FLEX_ARCHIVE (as is)"
  else
    UL=(); for u in "$W"/build/pso_user*.tsv; do [ -f "$u" ] && UL+=("$u"); done
    PL=(); for p in "$PAIRS_TSV" "$GD/shader_pairs.tsv"; do [ -f "$p" ] && PL+=("$p"); done
    t "flexible pipeline archive (dmsh_flexarch.py, cap ${PSO_FLEX_MB:-300} MB): ${#UL[@]} pipeline logs, ${#PL[@]} pair lists"
    make -s -C "$DM/gfx/tests" GAME="$GAME" pso_flexbench > /dev/null && mkdir -p "$O" && DM_NVN_SHMAP="$GD/shader_map.tsv" DM_MSL_DIR="$MSL_MAC" python3 "$DM/gfx/tools/dmsh_flexarch.py" \
      ${UL[@]+--records "${UL[@]}"} ${PL[@]+--pairs "${PL[@]}"} --max-mb "${PSO_FLEX_MB:-300}" --msl "$MSL_MAC/b-$V" --target-libs "$MSL_IOS/b-$V" -o "$O/pso_flex.metallib" \
      ${PSO_ARCHS:+--arch $PSO_ARCHS} && cp "$O/pso_flex.metallib" Gen/dm/ || t "[RED] no flexible pipeline archive (dmsh_flexarch.py failed above): flexible pipelines compile on workers"
  fi
fi
# Diagnostic build: DM_ENV_FILE=file → dm/env.txt in the bundle (main.m sets one environment variable per line at boot)
if [ -n "${DM_ENV_FILE:-}" ]; then cp "$DM_ENV_FILE" Gen/dm/env.txt || die "copy DM_ENV_FILE"; t "env: $(grep -v '^#' "$DM_ENV_FILE" | tr '\n' ' ')"; fi
# The shader libraries go into the archive as DmIOS.app/msl/<folder> (main.m sets DM_MSL_DIR to it)
if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; else MSLDIR=b-$V; fi
# Guard: an app without its shader libraries boots to a blank clear colour (0 draws), so a missing or nearly empty library folder is an error, never a warning:
# it needs at least one library and, when the Mac libraries of the same chain are present, 90% of their count
NLIB=$(find "$MSL_IOS/$MSLDIR" -name '*.metallib' 2>/dev/null | wc -l | tr -d ' ')
[ "$NLIB" -ge 1 ] || die "no iOS shader libraries in $MSL_IOS/$MSLDIR (chain $V: build them with dm/gfx/tools/dmsh_build.py); the app would show a blank picture"
if [ -d "$MSL_MAC/$MSLDIR" ]; then
  NMAC=$(find "$MSL_MAC/$MSLDIR" -name '*.metallib' | wc -l | tr -d ' ')
  [ $((NLIB * 10)) -ge $((NMAC * 9)) ] || die "only $NLIB iOS shader libraries in $MSL_IOS/$MSLDIR against $NMAC Mac ones in $MSL_MAC/$MSLDIR (chain $V): rebuild the iOS set"
fi
# Shared-font stand-ins: standard = macOS's Arial Unicode (absent on iOS), Nintendo extension = button icons generated by make_ext_font.py (needs fontTools; FONT_PY names a python that has it)
mkdir -p Gen/dm/font && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" Gen/dm/font/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
"${FONT_PY:-python3}" "$DM/tools/make_ext_font.py" Gen/dm/font/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# App icon: the game's own icon (icon.jpg saved from the control data by nx_extract, the English 256x256 one). DM_ICON can point at another image; by default the icon.jpg next to the RomFS is used.
# It is scaled to a 1024x1024 PNG in the asset catalog Gen/Assets.xcassets (a single-size app icon; actool generates the other sizes); with neither, no icon is set and the home-screen icon is blank.
# The catalog is always created (the project always lists it, see project.yml); without an icon it stays empty and DM_APPICON is not set
ICON=${DM_ICON:-$(dirname "$ROMFS")/icon.jpg}
mkdir -p Gen/Assets.xcassets && printf '{"info":{"author":"xcode","version":1}}\n' > Gen/Assets.xcassets/Contents.json || die "asset catalog"
if [ -f "$ICON" ]; then
  AI=Gen/Assets.xcassets/AppIcon.appiconset; mkdir -p "$AI" || die "mkdir $AI"
  sips -s format png -z 1024 1024 "$ICON" --out "$AI/icon.png" > /dev/null || die "sips: cannot convert the icon $ICON"
  printf '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n' > "$AI/Contents.json"
  echo "DM_APPICON = AppIcon" >> Gen/dm.xcconfig
  t "app icon: $ICON"
else t "no app icon ($ICON not found): the home-screen icon stays blank"; fi
xcodegen generate -q > /dev/null || die "xcodegen"

t "xcodebuild (Release, unsigned, iPhone + iPad)"
mkdir -p "$O"
xcodebuild -project DmIOS.xcodeproj -scheme DmIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$O/build.log" 2>&1 \
  || { grep -E 'error:' "$O/build.log" | head -20; die "xcodebuild, log $O/build.log"; }
# When Xcode's Locations setting is a custom location, products ignore -derivedDataPath: take the actual path from this build's log
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app; [ -d "$APP" ] || APP=$(grep -o '/[^ ]*/Release-iphoneos/DmIOS\.app' "$O/build.log" | tail -1)
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"

# Straight from the sources: the app without its signature, and without the folders an app built before pack_ipa.py still has (DerivedData keeps resources that left the project;
# msl/ is also deleted there, it took 1.5 GB of the home disk), then the shader libraries, the add-on content (the RomFS extracted from the player's DLC NSPs, one folder per index:
# the app sets DM_AOC_DIR at launch, the host reports them as owned and mounts them from it) and the RomFS
rm -rf "$APP/msl" "$O/Payload" "$O/out.ipa"   # (the last two: what the copy-and-zip packing left behind)
P=Payload/DmIOS.app; MAPS=("$P=$APP" "$P/msl/$MSLDIR=$MSL_IOS/$MSLDIR")
if [ -n "$AOC" ] && [ -d "$AOC" ]; then MAPS+=("$P/aoc=$AOC"); t "add-on content: $(ls "$AOC" | tr '\n' ' ')"; fi
MAPS+=("$P/romfs=$ROMFS")
t "pack IPA (already-compressed game files stored, everything else deflated)"
python3 tools/pack_ipa.py "$OUT_IPA" --store "$(gp zip_store)" --skip $P/_CodeSignature --skip $P/embedded.mobileprovision --skip $P/msl --skip $P/aoc --skip $P/romfs "${MAPS[@]}" || die "pack_ipa"
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"
