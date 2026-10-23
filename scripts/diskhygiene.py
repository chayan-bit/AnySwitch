#!/usr/bin/env python3
"""Keep AnySwitch builds and device installs from filling the Mac's disk (docs/development.md "Disk hygiene").

  diskhygiene.py install --device <udid> <app> [--bundle <id>]   devicectl install, then drop that bundle's CoreDevice delta cache (only after a success),
                                                                 and record which .app the device has now (~/.config/anyswitch/installed.json, read by resign.py)
  diskhygiene.py clean-delta <bundle id>                         drop one bundle's CoreDevice delta cache (com.chayan.* only; a rebuildable cache)
  diskhygiene.py prune <parent> [--keep 2] [--sub build] [-n]    keep the newest N per-step build folders under <parent>, the rest go to ~/.Trash
  diskhygiene.py retire-ipa <build dir>                          after sign/ is signed and verifies, the unsigned app.ipa (same bytes) goes to ~/.Trash
  diskhygiene.py clone <src> <dst>                               APFS clone (cp -c) of a file or folder, a plain copy on another volume
  diskhygiene.py gpu-snapshot <file> / gpu-clean <file>          Metal's gpuarchiver temp: remove only the entries made since the snapshot
Tests: scripts/tests/test_diskhygiene.py"""
import argparse, json, os, plistlib, shutil, subprocess, sys, tempfile, time
from pathlib import Path

DELTA_ROOT = Path.home() / 'Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas'
TRASH = Path(os.environ.get('DM_TRASH') or Path.home() / '.Trash')   # DM_TRASH: another trash folder (tests, demos)
OWN_BUNDLE_PREFIX = 'com.chayan.'
PROTECTED = {'backups', 'dump', 'extracted'}   # never pruned, whatever the caller passes
LEDGER = Path(os.environ.get('ANYSWITCH_CONF') or Path.home() / '.config/anyswitch') / 'installed.json'   # per machine, never in the repo
GPU_QUIET_SECS = 30   # a new gpuarchiver entry touched more recently than this may belong to a build still running


def die(msg):
    sys.exit(f'diskhygiene: {msg}')


def tree_bytes(p):
    p = Path(p)
    if p.is_file(): return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob('*') if f.is_file() and not f.is_symlink())


def clone(src, dst):
    """APFS clone of a file or folder (no extra disk on the same volume); a plain copy where cloning is refused. Returns 'clone' or 'copy'."""
    src, dst = Path(src), Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(['cp', '-c', '-R', str(src), str(dst)], capture_output=True).returncode == 0: return 'clone'
    shutil.rmtree(dst, ignore_errors=True) if dst.is_dir() else dst.unlink(missing_ok=True)   # drop a half-made clone
    if subprocess.run(['cp', '-R', str(src), str(dst)]).returncode: die(f'cannot copy {src} to {dst}')
    return 'copy'


def to_trash(path, name, trash=TRASH):
    """Move path into the trash folder as <name> (a time stamp is added when the name is taken); returns the new path"""
    trash.mkdir(parents=True, exist_ok=True)
    dst = trash / name
    if dst.exists(): dst = trash / f'{name}-{time.strftime("%H%M%S")}-{os.getpid()}'
    shutil.move(str(path), str(dst))
    return dst


def prune_steps(parent, keep=2, sub=None, trash=TRASH, dry_run=False):
    """Per-step build folders under parent: the newest `keep` stay, the older go to the trash. With sub, a step's build is parent/<step>/<sub> (steps without it are skipped,
    the rest of the step folder stays); without, each folder under parent is a build. Returns the moved paths, oldest first."""
    parent = Path(parent).resolve()
    if not parent.is_dir(): die(f'no folder {parent}')
    if PROTECTED & set(parent.parts): die(f'{parent} is under a protected folder ({", ".join(sorted(PROTECTED))}): never pruned')
    if keep < 0: die('--keep must be 0 or more')
    builds = [(c / sub if sub else c) for c in parent.iterdir() if c.is_dir() and not c.is_symlink() and not c.name.startswith('.')]
    builds = sorted((b for b in builds if b.is_dir() and not b.is_symlink()), key=lambda b: b.stat().st_mtime, reverse=True)
    old = builds[keep:][::-1]
    for b in old:
        if not dry_run: to_trash(b, '-'.join(b.relative_to(parent.parent).parts), trash)
    return old


def clean_delta(bundle_id, root=DELTA_ROOT):
    """Delete one bundle's CoreDevice delta cache (a full copy of the app after every install, rebuilt by the next one). Only our own bundle IDs; returns the bytes freed."""
    if not bundle_id.startswith(OWN_BUNDLE_PREFIX) or '/' in bundle_id or '..' in bundle_id: die(f'{bundle_id}: not one of our bundle IDs ({OWN_BUNDLE_PREFIX}*)')
    d = Path(root) / bundle_id
    if d.is_symlink() or not d.is_dir(): return 0
    n = tree_bytes(d)
    shutil.rmtree(d)
    return n


def app_bundle_id(app):
    with open(Path(app) / 'Info.plist', 'rb') as f: return plistlib.load(f)['CFBundleIdentifier']


def install_app(device, app, bundle_id=None, run=subprocess.run, delta_root=DELTA_ROOT, out=print, ledger=None):
    """devicectl install of the .app, then the bundle's delta cache is deleted. A failed install keeps the cache and returns devicectl's exit code.
    With a ledger file, a success also records which .app the device has now (resign.py re-signs that same build)."""
    bundle_id = bundle_id or app_bundle_id(app)
    with tempfile.TemporaryDirectory() as t:
        js = Path(t) / 'install.json'
        r = run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, str(app), '--json-output', str(js)])
        if r.returncode: return r.returncode
        url = installed_url(js, bundle_id)
    out(f'diskhygiene: installed {bundle_id}; CoreDevice delta cache freed {clean_delta(bundle_id, delta_root) / 2**20:.0f} MB')
    if ledger: record_install(device, bundle_id, app, url, ledger)
    return 0


def installed_url(js, bundle_id):
    """The bundle path devicectl reports for the installed app (a new one with every install), or None"""
    try: apps = json.loads(Path(js).read_text())['result']['installedApplications']
    except (OSError, ValueError, KeyError, TypeError): return None
    return next((a.get('installationURL') for a in apps if a.get('bundleID') == bundle_id), None)


def profile_uuid(app):
    """UUID of the .app's embedded provisioning profile, or None"""
    r = subprocess.run(['security', 'cms', '-D', '-i', str(Path(app) / 'embedded.mobileprovision')], capture_output=True)
    try: return plistlib.loads(r.stdout).get('UUID') if r.returncode == 0 else None
    except plistlib.InvalidFileException: return None


def record_install(device, bundle_id, app, url, ledger=LEDGER):
    """<device>/<bundle id> -> the installed .app, its bundle path on the device and its profile UUID (written atomically); returns the record"""
    ledger = Path(ledger); ledger.parent.mkdir(parents=True, exist_ok=True)
    old = json.loads(ledger.read_text()) if ledger.is_file() else {}
    rec = {'app': str(Path(app).resolve()), 'url': url, 'profile': profile_uuid(app), 'time': time.strftime('%Y-%m-%dT%H:%M:%S%z')}
    tmp = ledger.with_suffix('.tmp')
    tmp.write_text(json.dumps({**old, f'{device}/{bundle_id}': rec}, indent=1, sort_keys=True) + '\n'); os.replace(tmp, ledger)
    return rec


def retire_ipa(build, run=subprocess.run, trash=TRASH):
    """The signed app in <build>/sign/Payload/*.app must verify; only then the unsigned <build>/app.ipa (the same bytes, unpacked and signed) goes to the trash. Returns its new path."""
    build = Path(build)
    ipa, apps = build / 'app.ipa', list((build / 'sign/Payload').glob('*.app'))
    if len(apps) != 1: die(f'{build}/sign/Payload holds {len(apps)} apps, not 1: not signed yet')
    if run(['codesign', '--verify', '--deep', '--strict', str(apps[0])], capture_output=True).returncode: die(f'{apps[0]} does not verify: app.ipa kept')
    if not ipa.is_file(): die(f'no {ipa}')
    return to_trash(ipa, f'{build.parent.name}-app.ipa', trash)


def gpu_root():
    d = subprocess.run(['getconf', 'DARWIN_USER_CACHE_DIR'], capture_output=True, text=True).stdout.strip()
    return Path(d) / 'com.apple.gpuarchiver'


def gpu_snapshot(root=None):
    root = root or gpu_root()
    return sorted(p.name for p in root.iterdir()) if root.is_dir() else []


def _busy(p, quiet, now):   # an open file inside (lsof), or anything in it touched within the quiet window
    newest = max([p.stat().st_mtime] + [Path(d, f).stat().st_mtime for d, _, fs in os.walk(p) for f in fs if Path(d, f).exists()])
    if now - newest < quiet: return True
    return bool(shutil.which('lsof')) and subprocess.run(['lsof', '-t', '+D', str(p)], capture_output=True, text=True, timeout=30).stdout.strip() != ''


def gpu_clean(before, root=None, quiet=GPU_QUIET_SECS, now=None):
    """Remove the gpuarchiver entries that are not in `before` (the snapshot taken when the build started); entries that look in use are left. Returns (bytes freed, names left)."""
    # ponytail: two builds at once can still race on a dir that is between metal-tt runs for longer than the quiet window; the build scripts only run this at their end
    root, now = root or gpu_root(), now or time.time()
    if not root.is_dir(): return 0, []
    freed, left = 0, []
    for p in sorted(root.iterdir()):
        if p.name in set(before): continue
        try:   # a cache cleanup never fails a build: whatever cannot be judged or removed stays
            if p.is_dir() and not p.is_symlink():
                if _busy(p, quiet, now): left.append(p.name); continue
                n = tree_bytes(p); shutil.rmtree(p); freed += n
            else: p.unlink(missing_ok=True)
        except (OSError, subprocess.SubprocessError): left.append(p.name)
    return freed, left


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0]); sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('install'); s.add_argument('app'); s.add_argument('--device', required=True); s.add_argument('--bundle')
    s = sub.add_parser('clean-delta'); s.add_argument('bundle')
    s = sub.add_parser('prune'); s.add_argument('parent'); s.add_argument('--keep', type=int, default=2); s.add_argument('--sub'); s.add_argument('-n', '--dry-run', action='store_true')
    s = sub.add_parser('retire-ipa'); s.add_argument('build')
    s = sub.add_parser('clone'); s.add_argument('src'); s.add_argument('dst')
    s = sub.add_parser('gpu-snapshot'); s.add_argument('file')
    s = sub.add_parser('gpu-clean'); s.add_argument('file'); s.add_argument('--quiet-secs', type=int, default=GPU_QUIET_SECS)
    a = ap.parse_args(argv)
    if a.cmd == 'install': return install_app(a.device, a.app, a.bundle, ledger=LEDGER)
    if a.cmd == 'clean-delta': print(f'diskhygiene: freed {clean_delta(a.bundle) / 2**20:.0f} MB')
    elif a.cmd == 'prune':
        for p in prune_steps(a.parent, a.keep, a.sub, dry_run=a.dry_run): print(f'diskhygiene: {"would move" if a.dry_run else "to ~/.Trash:"} {p}')
    elif a.cmd == 'retire-ipa': print(f'diskhygiene: unsigned IPA to {retire_ipa(a.build)}')
    elif a.cmd == 'clone': print(f'diskhygiene: {clone(a.src, a.dst)}: {a.dst}')
    elif a.cmd == 'gpu-snapshot': Path(a.file).write_text('\n'.join(gpu_snapshot()) + '\n')
    elif a.cmd == 'gpu-clean':
        if not Path(a.file).is_file(): die(f'no snapshot {a.file}')
        freed, left = gpu_clean(Path(a.file).read_text().split(), quiet=a.quiet_secs)
        print(f'diskhygiene: gpuarchiver temp: freed {freed / 2**20:.0f} MB' + (f', {len(left)} entries in use left' if left else ''))
    return 0


if __name__ == '__main__': sys.exit(main())
