#!/bin/bash
# dev_sign.sh <build dir>: sign the unsigned <build dir>/app.ipa for a device install, then keep one copy of the app, not two.
# The IPA is unpacked into <build dir>/sign/Payload, signed (every framework dylib, then the app with the entitlements) and verified; only then the unsigned app.ipa,
# which holds the same bytes, goes to ~/.Trash (diskhygiene.py retire-ipa; KEEP_IPA=1 keeps it). Install the result with diskhygiene.py install, which also drops CoreDevice's delta copy.
# Environment (no defaults, they are this Mac's own): IDENTITY = the signing identity (SHA-1 or name), PROFILE = the .mobileprovision to embed, ENT = the entitlements plist.
# No device access.
set -eu
B=${1:?usage: dev_sign.sh <build dir holding app.ipa>}; S=$B/sign; A=$S/Payload/DmIOS.app; H=$(cd "$(dirname "$0")" && pwd)
die() { echo "dev_sign.sh: $*" >&2; exit 1; }
: "${IDENTITY:?set IDENTITY}" "${PROFILE:?set PROFILE}" "${ENT:?set ENT}"
[ -f "$B/app.ipa" ] || die "no $B/app.ipa"
[ ! -e "$S" ] || die "$S exists: move it to the Trash first"
mkdir -p "$S" && ditto -x -k "$B/app.ipa" "$S"
cp "$PROFILE" "$A/embedded.mobileprovision"
if [ -d "$A/Frameworks" ]; then find "$A/Frameworks" -name '*.dylib' -print0 | xargs -0 -n1 codesign --force --sign "$IDENTITY" --timestamp=none; fi
codesign --force --sign "$IDENTITY" --entitlements "$ENT" --generate-entitlement-der --timestamp=none "$A"
codesign --verify --deep --strict "$A" || die "codesign verify"
[ -f "$A/pack/manifest.json" ] && [ -f "$A/pack/profile/game.json" ] || die "no bundled pack"
codesign -d --entitlements - --xml "$A" 2> /dev/null | plutil -extract application-identifier raw -
du -sh "$A"; echo "signed: $A"
if [ "${KEEP_IPA:-0}" = 1 ]; then echo "KEEP_IPA=1: $B/app.ipa kept (a second copy of the same bytes)"; else python3 "$H/diskhygiene.py" retire-ipa "$B"; fi
