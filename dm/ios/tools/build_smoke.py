#!/usr/bin/env python3
"""CI build of the production iOS project with synthetic embedded modules.

Requires Xcode and XcodeGen; GAME (or DM_GAME) selects the host profile.
No game files, keys, shaders, signing or device are needed. The resulting app
is a compile/link fixture, not a runnable game. All Xcode output stays under
--output, which must name a new directory; keep it on a scratch drive locally.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/games'))
import game


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='new scratch directory for inputs and build products')
    args = parser.parse_args()
    profile = game.load(os.environ.get('GAME') or os.environ.get('DM_GAME'))
    root = args.output.resolve()
    root.mkdir(parents=True)  # Never overwrite an existing project or build.
    ios = REPO / 'dm/ios'
    project = root / 'project'
    gen = project / 'Gen'
    tables = gen / 'pack/profile'   # AnySwitch: Hearth's bundled pack (build_ipa.sh Gen/pack)
    tables.mkdir(parents=True)
    (gen / 'licenses.txt').write_text('CI build fixture\n')
    for name in ('Sources', 'tools', 'Hearth'):
        (project / name).symlink_to(ios / name, target_is_directory=True)
    shutil.copyfile(ios / 'project.yml', project / 'project.yml')
    assets = gen / 'Assets.xcassets'
    assets.mkdir()
    (assets / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}))

    # One original text page, two writable pages (including the key page),
    # and one patch page exercise the production Mach-O segment/link flags.
    patched = root / 'patched'
    patched.mkdir()
    modules = profile.words('modules')
    for name in modules:
        (patched / f'{name}.patched.bin').write_bytes(bytes(0x10000))
        fixups = patched / f'{name}.fixups.tsv'
        fixups.write_text('# TEXT_END 0x4000\n# PATCH_OFF 0xc000\n'
                          '# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n')
        shutil.copyfile(fixups, tables / fixups.name)

    env = dict(os.environ, GAME=profile.id, DM_GAME=profile.id,
               DM_BUNDLE_ID='org.anyswitch.ci', DM_DISPLAY_NAME='CI build fixture',
               DM_APP_VERSION='1.0', DM_APP_CATEGORY=profile.get('app_category'),
               DM_TEAM_ID='', DM_SCHEME_NAME='DmIOS', DM_APPICON='',
               DM_SHOW_FPS='NO', DM_LANG='en-US')

    def run(*command, capture=False):
        return subprocess.run([str(c) for c in command], cwd=project, env=env,
                              check=True, text=True, stdout=subprocess.PIPE if capture else None)

    config = run(sys.executable, ios / 'tools/gen_build.py', REPO / 'dm/host', gen, capture=True).stdout
    flags = run(sys.executable, ios / 'tools/gen_embed.py', patched, gen / 'embed.S', *modules, '--title', profile.id, capture=True).stdout.strip()
    (gen / 'dm.xcconfig').write_text(config + f'OTHER_LDFLAGS = $(inherited) $(DM_FRAMEWORKS) {flags}\n')
    run('xcodegen', 'generate')

    derived = root / 'derived'
    run('xcodebuild', '-project', project / 'DmIOS.xcodeproj', '-scheme', 'DmIOS',
        '-configuration', 'Release', '-destination', 'generic/platform=iOS',
        '-derivedDataPath', derived, '-jobs', '3',
        'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=',
        f'DM_XCODE_OUTPUT_ROOT={derived}', f'SYMROOT={derived}/Build/Products',
        f'OBJROOT={derived}/Build/Intermediates.noindex', 'build')

    app = derived / 'Build/Products/Release-iphoneos/DmIOS.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = app / info['CFBundleExecutable']
    if not executable.is_file():
        raise RuntimeError(f'No linked executable: {executable}')
    if not (app / 'pack/profile').is_dir():
        raise RuntimeError(f'No bundled pack in {app}')
    if (app / '_CodeSignature').exists() or (app / 'embedded.mobileprovision').exists():
        raise RuntimeError('The smoke-test app must be unsigned')
    print(f'iOS smoke build passed: {executable}', flush=True)


if __name__ == '__main__':
    main()
