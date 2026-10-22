#!/bin/bash
# Create the issue labels the issue forms and triage use. Run once by a maintainer: scripts/setup-labels.sh [owner/repo]
# Needs the GitHub CLI (gh) logged in with write access. Existing labels are updated, not duplicated (--force).
set -euo pipefail
REPO=${1:-chayan-bit/AnySwitch}

label() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force; }

label bug             d73a4a "Something is broken"
label enhancement     a2eeef "New feature or improvement"
label compatibility   0e8a16 "How a specific game runs"
label game-profile    5319e7 "Adding or changing a game profile in dm/games"
label graphics        1d76db "NVN, Vulkan or Metal layer, shaders"
label host            fbca04 "Horizon stand-in: kernel, services, loader"
label ios             006b75 "iOS app, settings screen, controls"
label build-script    c5def5 "scripts/build_ipa_from_nsp.py, build_ipa.sh, extraction"
label performance     f9d0c4 "Frame rate, stutter, memory, battery"
label documentation   0075ca "Docs and README"
label needs-info      ffffff "Waiting for details from the reporter"
label legal           b60205 "Game files, keys or derived data posted; handle per the legal note"
label "good first issue" 7057ff "Good for newcomers"
label "help wanted"     008672 "Extra attention is needed"
