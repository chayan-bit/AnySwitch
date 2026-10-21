#!/usr/bin/env python3
"""Checkpoint saves: copy a title's save data out of a Mac run or the iOS app into data/checkpoints/<title id>/<name>/, and install one before a launch.
Usage and examples: docs/dev-control.md. A checkpoint is the game's own save (user data derived from the game): it lives only under data/, never in git.

  checkpoint.py export <title> <name> --mac <DM_SAVE dir>                     the committed save of a Mac run (not <dir>.work)
  checkpoint.py export <title> <name> --device <udid> --bundle <bundle id>    Documents/save of the app (quit the app first)
  checkpoint.py import <title> <name> --mac <DM_SAVE dir>                     replaces the directory; launch the host with DM_SAVE=<dir>
  checkpoint.py import <title> <name> --device <udid> --bundle <bundle id> [--launch]
  checkpoint.py list [<title>] | verify <title> <name>

The Mac host and the iOS app keep a save the same way (dm/host/hle_fs.c): DM_SAVE is the committed directory, swapped in whole on every Commit, and a
mount clears the leftover <dir>.work / <dir>.new. The app's DM_SAVE is Documents/save (dm/ios/Sources/main.m). So a checkpoint is that directory, byte for byte.
One caveat: a guest name that collides on the case-insensitive host file system is kept in an extended attribute (org.d2rmobile.guest-name), and devicectl
does not carry extended attributes; such a checkpoint is refused for the device rather than installed wrong."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(os.environ.get('DM_CHECKPOINTS') or Path(__file__).resolve().parents[1] / 'data' / 'checkpoints')
GUEST_NAME_XATTR = 'org.d2rmobile.guest-name'
DEVICE_SAVE = 'Documents/save'
TITLE_RE = re.compile(r'^[0-9A-Fa-f]{16}$')
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')


class Fail(Exception):
    pass


def ckpt_dir(title, name, root=None):
    if not TITLE_RE.match(title): raise Fail(f'title id must be 16 hex digits: {title}')
    if not NAME_RE.match(name): raise Fail(f'checkpoint name must be letters, digits, . _ - (at most 64): {name}')
    return Path(root or ROOT) / title.upper() / name


def manifest(save):
    """{relative path: {size, sha256}} of every regular file; anything else (links, devices) is refused."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(save):
        dirnames.sort()
        for d in dirnames:
            if os.path.islink(os.path.join(dirpath, d)): raise Fail(f'symbolic link in the save: {os.path.join(dirpath, d)}')
        for f in sorted(filenames):
            p = Path(dirpath) / f
            if p.is_symlink() or not p.is_file(): raise Fail(f'not a regular file: {p}')
            files[p.relative_to(save).as_posix()] = {'size': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
    return files


def guest_name_xattrs(save):
    """Paths under save that carry the guest-name attribute (macOS xattr tool; none elsewhere)."""
    if not shutil.which('xattr'): return []
    out = subprocess.run(['xattr', '-r', str(save)], capture_output=True, text=True).stdout
    return sorted({Path(l.split(': ')[0]).relative_to(save).as_posix() for l in out.splitlines() if l.endswith(': ' + GUEST_NAME_XATTR)})


def copy_tree(src, dst):
    """Copy with extended attributes kept (ditto on macOS)."""
    if shutil.which('ditto'): subprocess.run(['ditto', str(src), str(dst)], check=True)
    else: shutil.copytree(src, dst)


def store(src_save, dest, source, note, force):
    if dest.exists():
        if not force: raise Fail(f'checkpoint exists: {dest} (pass --force to replace it)')
        shutil.rmtree(dest)
    files = manifest(src_save)
    if not files: raise Fail(f'the save is empty: {src_save} (has the game saved yet?)')
    tmp = dest.with_name(dest.name + '.tmp')
    if tmp.exists(): shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    copy_tree(src_save, tmp / 'save')
    meta = {'title': dest.parent.name, 'name': dest.name, 'source': source, 'note': note,
            'created': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
            'files': files, 'guest_name_xattrs': guest_name_xattrs(tmp / 'save')}
    if manifest(tmp / 'save') != files: raise Fail('the copy differs from the source (was the game saving meanwhile?)')
    (tmp / 'checkpoint.json').write_text(json.dumps(meta, indent=1) + '\n')
    tmp.rename(dest)
    return meta


def load(dest):
    if not (dest / 'checkpoint.json').is_file(): raise Fail(f'no checkpoint at {dest}')
    meta = json.loads((dest / 'checkpoint.json').read_text())
    if manifest(dest / 'save') != meta['files']: raise Fail(f'checkpoint {dest} does not match its manifest (edited or damaged)')
    return meta


def check_mac_save(d):
    d = Path(d)
    if d.name.endswith(('.work', '.new')): raise Fail(f'{d} is the host\'s scratch copy; pass the DM_SAVE directory itself')
    return d


def export_mac(title, name, save, note='', force=False, root=None):
    save = check_mac_save(save)
    if not save.is_dir(): raise Fail(f'no save directory {save}')
    return store(save, ckpt_dir(title, name, root), f'mac:{save.resolve()}', note, force)


def import_mac(title, name, save, root=None):
    save = check_mac_save(save); meta = load(ckpt_dir(title, name, root))
    for d in (save, Path(str(save) + '.work'), Path(str(save) + '.new')):
        if d.exists(): shutil.rmtree(d)
    save.parent.mkdir(parents=True, exist_ok=True)
    copy_tree(ckpt_dir(title, name, root) / 'save', save)
    return meta


def devicectl(*args, run=subprocess.run):
    cmd = ['xcrun', 'devicectl', *args]
    r = run(cmd, capture_output=True, text=True)
    if r.returncode: raise Fail(f'{" ".join(cmd)} failed:\n{r.stdout}{r.stderr}')
    return r


def device_args(udid, bundle):
    return ['--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bundle]


def export_device(title, name, udid, bundle, note='', force=False, root=None, run=subprocess.run):
    with tempfile.TemporaryDirectory() as t:
        got = Path(t) / 'save'
        devicectl('device', 'copy', 'from', *device_args(udid, bundle), '--source', DEVICE_SAVE, '--destination', str(got), run=run)
        if not got.is_dir(): raise Fail(f'devicectl gave no {DEVICE_SAVE} directory (has the app saved yet?)')
        return store(got, ckpt_dir(title, name, root), f'device:{udid}:{bundle}', note, force)


def app_pids(udid, bundle, run=subprocess.run):
    """PIDs of the app's running processes: its executable lives inside the installed bundle."""
    with tempfile.TemporaryDirectory() as t:
        devicectl('device', 'info', 'apps', '--device', udid, '--bundle-id', bundle, '--json-output', f'{t}/a.json', run=run)
        apps = json.loads(Path(f'{t}/a.json').read_text())['result']['apps']
        if not apps: raise Fail(f'{bundle} is not installed on {udid}')
        url = apps[0]['url'].rstrip('/') + '/'
        devicectl('device', 'info', 'processes', '--device', udid, '--json-output', f'{t}/p.json', run=run)
        procs = json.loads(Path(f'{t}/p.json').read_text())['result']['runningProcesses']
    return [p['processIdentifier'] for p in procs if p.get('executable', '').startswith(url)]


def import_device(title, name, udid, bundle, launch=False, root=None, run=subprocess.run):
    d = ckpt_dir(title, name, root); meta = load(d)
    if meta.get('guest_name_xattrs'): raise Fail(f'checkpoint has case-collision names kept in extended attributes, which devicectl drops: {meta["guest_name_xattrs"]}')
    for pid in app_pids(udid, bundle, run=run):   # a running app would commit its own save over the checkpoint
        devicectl('device', 'process', 'terminate', '--device', udid, '--pid', str(pid), run=run)
    devicectl('device', 'copy', 'to', *device_args(udid, bundle), '--source', str(d / 'save'), '--destination', DEVICE_SAVE,
              '--remove-existing-content', 'true', run=run)
    if launch: devicectl('device', 'process', 'launch', '--device', udid, '--terminate-existing', bundle, run=run)
    return meta


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('export', 'import'):
        p = sub.add_parser(c); p.add_argument('title'); p.add_argument('name')
        w = p.add_mutually_exclusive_group(required=True); w.add_argument('--mac', metavar='DIR'); w.add_argument('--device', metavar='UDID')
        p.add_argument('--bundle')
        if c == 'export': p.add_argument('--note', default=''); p.add_argument('--force', action='store_true')
        else: p.add_argument('--launch', action='store_true')
    p = sub.add_parser('list'); p.add_argument('title', nargs='?')
    p = sub.add_parser('verify'); p.add_argument('title'); p.add_argument('name')
    a = ap.parse_args(argv)
    try:
        if a.cmd in ('export', 'import') and a.device and not a.bundle: raise Fail('--device needs --bundle')
        if a.cmd == 'export':
            m = export_mac(a.title, a.name, a.mac, a.note, a.force) if a.mac else export_device(a.title, a.name, a.device, a.bundle, a.note, a.force)
            print(f'exported {a.title.upper()}/{a.name}: {len(m["files"])} files, {sum(f["size"] for f in m["files"].values())} bytes')
        elif a.cmd == 'import':
            m = import_mac(a.title, a.name, a.mac) if a.mac else import_device(a.title, a.name, a.device, a.bundle, a.launch)
            print(f'installed {a.title.upper()}/{a.name} ({len(m["files"])} files) into {a.mac or a.device + ":" + DEVICE_SAVE}')
        elif a.cmd == 'verify':
            m = load(ckpt_dir(a.title, a.name)); print(f'ok: {len(m["files"])} files match')
        else:
            titles = [ROOT / a.title.upper()] if a.title else sorted(p for p in ROOT.glob('*') if p.is_dir())
            for t in titles:
                for c in sorted(t.glob('*/checkpoint.json')):
                    m = json.loads(c.read_text()); print(f'{m["title"]}\t{m["name"]}\t{m["created"]}\t{m["source"]}\t{m["note"]}')
    except Fail as e:
        print(f'checkpoint: {e}', file=sys.stderr); return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
