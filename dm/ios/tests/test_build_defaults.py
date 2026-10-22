#!/usr/bin/env python3
# tools/build_ipa.sh defaults: the RomFS goes to a chunk store unless IPA_ROMFS says otherwise (1 = loose files in the IPA, 0 = left out),
# and the flexible pipeline archive is built unless PSO_FLEX=0. The script itself needs a game, so this reads its two decision lines and runs them in bash.
import re, subprocess, sys
from pathlib import Path

SH = (Path(__file__).resolve().parents[1] / 'tools' / 'build_ipa.sh').read_text(encoding='utf-8')
DOCS = (Path(__file__).resolve().parents[3] / 'docs' / 'development.md').read_text(encoding='utf-8')


def mode(env):
    """ROMFS_MODE as build_ipa.sh decides it, with `die` printing FAIL and exiting"""
    m = re.search(r'^ROMFS_MODE=.*\n(?:case .*\n)?', SH, re.M)
    assert m, 'build_ipa.sh has no ROMFS_MODE line'
    r = subprocess.run(['bash', '-c', 'die() { echo "FAIL: $*"; exit 1; }\n' + m.group(0) + 'echo "$ROMFS_MODE"'], env=env, capture_output=True, text=True)
    return r.stdout.strip()


assert mode({}) == 'store', 'the default is the chunk store'
assert mode({'IPA_ROMFS': 'store'}) == 'store' and mode({'IPA_ROMFS': '1'}) == '1' and mode({'IPA_ROMFS': '0'}) == '0', 'loose files and none stay available'
assert mode({'IPA_ROMFS': 'zip'}).startswith('FAIL'), 'an unknown value is refused'
assert re.findall(r'\$\{IPA_ROMFS[^}]*\}', SH) == ['${IPA_ROMFS:-store}'], 'one read of IPA_ROMFS, with the store as its default'
assert '"$ROMFS_MODE" = store' in SH and '"$ROMFS_MODE" = 0' in SH, 'the branches follow ROMFS_MODE'
assert '${PSO_FLEX:-1}' in SH and '${PSO_FLEX:-0}' not in SH, 'the flexible pipeline archive is on by default'
assert 'IPA_ROMFS=1' in SH.split('set -u')[0] and 'IPA_ROMFS=1' in DOCS, 'the loose-files option is documented in the script and in docs/development.md'
SRC = Path(__file__).resolve().parents[1] / 'Sources'
# The game's settings.json: build_ipa.sh copies it into the bundled pack's profile folder (DMO, Gen/pack/profile, which project.yml bundles as pack/), and DmSettings.m reads it from there
dmo = re.findall(r'^  DMO=(\S+); PSO_O=', SH, re.M)   # the PACK branch's, then the IPA's
yml = (Path(__file__).resolve().parents[1] / 'project.yml').read_text(encoding='utf-8')
assert dmo[-1:] == ['Gen/pack/profile'] and '"$GD/settings.json" "$DMO"/settings.json' in SH and '- path: Gen/pack ' in yml, 'the IPA bundles the game settings at pack/profile/settings.json'
assert '@"pack/profile/settings.json"' in (SRC / 'DmSettings.m').read_text(encoding='utf-8'), 'DmSettings.m reads the game settings where the IPA puts them'
print('BUILD_DEFAULTS OK chunk store by default, loose files and none by IPA_ROMFS, flexible pipeline archive on by default, game settings at pack/profile')
sys.exit(0)
