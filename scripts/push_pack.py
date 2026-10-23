#!/usr/bin/env python3
"""Import a game pack into Hearth on an iPad or iPhone, from the Mac (plan-hearth-p2.md 6.1; the device side is dm/ios/Hearth/HearthImport.m).

  push_pack.py <pack> --app <the installed Hearth's DmIOS.app> [--device <udid>] [--work <dir>]

1. The iOS part of the pack (pack_manifest.py subset: verified against its inventory first), cloned into the work folder.
2. Its code signed the way Hearth loads code from its data folder (notes/hearth-p2.md, E1): the identity that signed the installed app, the identifier set to
   the app's bundle ID, no entitlements. Both are read from the app given with --app (the same build that is installed); --identity and --bundle-id override them.
3. A new inventory, then one Apple Archive (.aar) of the whole tree: a device copy is one file per call, and a pack holds about 100 000 shader files.
4. With --device: the archive, then a small <name>.ready that names its size, each copied with one devicectl call into the app's Documents/Import/.
   Hearth imports it when it starts or comes back to the front: it extracts, checks every file against the inventory and moves the game into its library.
Every push uses a new name, because devicectl keeps an existing file of the same size. Take a verified backup of the device's saves first (the device rules).
Run: python3 -I scripts/push_pack.py ... (tests: scripts/tests/test_push_pack.py)"""
import argparse, hashlib, json, plistlib, subprocess, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dm/tools'))
import pack_manifest   # noqa: E402

PLATFORM = 'ios'


def die(msg):
    sys.exit(f'push_pack: {msg}')


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode: die(f'{" ".join(map(str, cmd[:3]))}... failed: {(r.stderr or r.stdout).strip()[-400:]}')
    return r.stdout


def app_identity(app):
    """(signing identity SHA-1, bundle ID) of a signed app: the leaf certificate of its signature, and its application-identifier without the team prefix"""
    ent = run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)])
    aid = plistlib.loads(ent.encode()).get('application-identifier', '') if ent.strip() else ''
    if '.' not in aid: die(f'{app} has no application-identifier entitlement: is it the signed build?')
    with tempfile.TemporaryDirectory() as t:
        run(['codesign', '-d', f'--extract-certificates={t}/cert', str(app)])
        leaf = Path(f'{t}/cert0')
        if not leaf.exists(): die(f'{app} has no signing certificate (ad hoc?)')
        sha1 = hashlib.sha1(leaf.read_bytes()).hexdigest().upper()
    return sha1, aid.split('.', 1)[1]


def sign(dylib, identity, bundle_id):
    run(['codesign', '--force', '--sign', identity, '--timestamp=none', '--identifier', bundle_id, str(dylib)])
    got = subprocess.run(['codesign', '-dv', str(dylib)], capture_output=True, text=True).stderr
    if f'Identifier={bundle_id}\n' not in got: die(f'{dylib}: signed, but the identifier is not {bundle_id}:\n{got}')


def build(pack, work, identity, bundle_id):
    """The archive and its ready note for pack, in work: (archive path, ready path)"""
    title = json.loads((pack / 'manifest.json').read_text()).get('title_id', '')
    if len(title) != 16: die(f'{pack}/manifest.json names no title id')
    name = f'{title}-{time.strftime("%Y%m%d-%H%M%S")}'
    stage = work / name
    pack_manifest.subset(pack, stage, PLATFORM)
    code = stage / f'code/{PLATFORM}.dylib'
    if code.exists(): sign(code, identity, bundle_id)
    else: print(f'push_pack: [RED] no code/{PLATFORM}.dylib: the game will need the code inside the app')
    m = pack_manifest.reinventory(stage, PLATFORM)
    aar = work / f'{name}.aar'
    run(['aa', 'archive', '-d', str(stage), '-o', str(aar), '-exclude-field', 'uid,gid,flg,btm,ctm'])
    ready = work / f'{name}.ready'
    ready.write_text(json.dumps({'title_id': title, 'archive': aar.name, 'archive_bytes': aar.stat().st_size,
                                 'files': m['inventory']['files'], 'bytes': m['inventory']['bytes']}, indent=1) + '\n')
    print(f'push_pack: {aar} ({aar.stat().st_size / 2**20:.0f} MB, {m["inventory"]["files"]} files, {m["inventory"]["bytes"] / 2**30:.2f} GB unpacked)')
    return aar, ready


def device_files(udid, bundle_id, sub):
    with tempfile.TemporaryDirectory() as t:
        run(['xcrun', 'devicectl', 'device', 'info', 'files', '--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bundle_id,
             '--subdirectory', sub, '--json-output', f'{t}/f.json'])
        return {f['relativePath']: f.get('metadata', {}).get('size') for f in json.loads(Path(f'{t}/f.json').read_text())['result']['files']}


def push(udid, bundle_id, files):   # one devicectl copy per file, never a folder copy and never a removal; then each size read back
    for f in files:
        t0 = time.time()
        run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bundle_id,
             '--source', str(f), '--destination', f'Documents/Import/{f.name}'])
        print(f'push_pack: copied {f.name} in {time.time() - t0:.0f} s')
    have = device_files(udid, bundle_id, 'Documents/Import')
    for f in files:
        if have.get(f.name) != f.stat().st_size: die(f'{f.name} on the device has {have.get(f.name)} bytes, not {f.stat().st_size}')
    print('push_pack: sizes on the device match; Hearth imports the game when it next starts or comes to the front')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('pack'); ap.add_argument('--app'); ap.add_argument('--device'); ap.add_argument('--work')
    ap.add_argument('--identity'); ap.add_argument('--bundle-id')
    a = ap.parse_args()
    pack = Path(a.pack).resolve()
    if not (pack / 'manifest.json').is_file(): die(f'{pack} is not a pack (no manifest.json)')
    identity, bundle_id = a.identity, a.bundle_id
    if not (identity and bundle_id):
        if not a.app: die('--app <the installed DmIOS.app> is needed to know how to sign (or --identity and --bundle-id)')
        i, b = app_identity(Path(a.app)); identity = identity or i; bundle_id = bundle_id or b
    work = Path(a.work).resolve() if a.work else pack.parent / f'{pack.name}.push'
    work.mkdir(parents=True, exist_ok=True)
    aar, ready = build(pack, work, identity, bundle_id)
    if a.device: push(a.device, bundle_id, [aar, ready])   # the ready note last: Hearth takes an archive only once its note says the copy is complete


if __name__ == '__main__':
    main()
