#!/usr/bin/env python3
# A game pack's manifest.json and file inventory (docs/development.md "Game packs"): what the pack is, and every file in it, so an import (or a copy to another machine) can be checked.
#   write <root> --title <id> [--chain V] [--display-version X]: files.tsv (path, size, sha256 of every file under the root), then manifest.json with the four version numbers from
#     dm/host/dm_abi.h, the platforms whose code dylib is present, each module's build id (profile/<module>.fixups.tsv) and the inventory's own count, size and digest
#   write <root> ... --bundled: a pack inside the per-game IPA (DmIOS.app/pack): the code is embedded in the app's executable (platforms: ios) and there is no inventory, since the app's
#     code signature seals every file it holds
#   verify <root>: the numbers still match this tree's dm_abi.h, the inventory is the one the manifest names, and every file is there with its size and digest, nothing missing or extra;
#     exit 1 naming each difference
# manifest.json stays small on purpose: the engine parses it before every boot (dm/host/boot.m dm_pack_check), while a pack holds hundreds of thousands of shader files.
import argparse, hashlib, json, os, re, sys
from pathlib import Path
ABI_H = Path(__file__).resolve().parents[1] / 'host/dm_abi.h'
ABI_KEYS = {'DM_PACK_FORMAT': None, 'DM_PROFILE_SCHEMA': 'profile_schema', 'DM_CODE_ABI': 'code', 'DM_SHADER_ABI': 'shader'}
PLATFORMS = ('ios', 'macos')
INVENTORY = 'files.tsv'


def engine_numbers():
    t = ABI_H.read_text()
    n = {k: re.search(rf'^#define {k} (\d+)', t, re.M) for k in ABI_KEYS}
    missing = [k for k, m in n.items() if not m]
    if missing: sys.exit(f'pack_manifest: {", ".join(missing)} missing from {ABI_H}')
    return {k: int(m.group(1)) for k, m in n.items()}


def digest(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    return h.hexdigest()


def files_under(root):   # relative path → (size, sha256) of every file except the manifest and the inventory; symlinks are followed (a pack holds files, clones or not)
    out = {}
    for d, dirs, names in os.walk(root, followlinks=True):
        dirs.sort()
        for n in sorted(names):
            p = Path(d) / n; rel = p.relative_to(root).as_posix()
            if rel not in ('manifest.json', INVENTORY): out[rel] = (p.stat().st_size, digest(p))
    return out


def inventory_text(files):
    return '# path\tsize\tsha256\n' + ''.join(f'{r}\t{s}\t{h}\n' for r, (s, h) in sorted(files.items()))


def read_inventory(text):
    rows = (l.split('\t') for l in text.splitlines() if l and not l.startswith('#'))
    return {r: (int(s), h) for r, s, h in rows}


def build_ids(root):
    ids = {}
    for f in sorted((root / 'profile').glob('*.fixups.tsv')):
        hdr = dict(l[2:].split(None, 1) for l in f.read_text().splitlines() if l.startswith('# ') and len(l.split()) >= 3)
        ids[f.name[:-len('.fixups.tsv')]] = hdr.get('BUILD_ID', '').strip()
    return ids


def write(root, title, chain='', display_version='', bundled=False):
    if not re.fullmatch(r'[0-9A-Fa-f]{16}', title): sys.exit(f'pack_manifest: --title must be a 16-digit hex title id, not {title}')
    e = engine_numbers()
    m = {'format': e['DM_PACK_FORMAT'], 'title_id': title.upper(), 'display_version': display_version, 'chain': chain,
         'abi': {v: e[k] for k, v in ABI_KEYS.items() if v}, 'platforms': ['ios'] if bundled else [p for p in PLATFORMS if (root / f'code/{p}.dylib').is_file()],
         'modules': build_ids(root), 'inventory': None}
    if not bundled:
        files = files_under(root); inv = inventory_text(files).encode()
        (root / INVENTORY).write_bytes(inv)
        m['inventory'] = {'file': INVENTORY, 'files': len(files), 'bytes': sum(s for s, _ in files.values()), 'sha256': hashlib.sha256(inv).hexdigest()}
    (root / 'manifest.json').write_text(json.dumps(m, indent=1) + '\n')
    return m


def problems(root):   # every difference between the pack and its manifest, and between the manifest and this engine
    try: m = json.loads((root / 'manifest.json').read_text())
    except (OSError, ValueError) as x: return [f'manifest.json unreadable: {x}']
    e, out = engine_numbers(), []
    if m.get('format') != e['DM_PACK_FORMAT']: out.append(f'pack format {m.get("format")}, this engine {e["DM_PACK_FORMAT"]}')
    for k, v in ABI_KEYS.items():
        if v and m.get('abi', {}).get(v) != e[k]: out.append(f'{v} {m.get("abi", {}).get(v)}, this engine {e[k]}')
    inv = m.get('inventory', {})
    if inv is None: return out   # bundled in an app: its code signature covers the files
    try: raw = (root / inv.get('file', INVENTORY)).read_bytes()
    except OSError as x: return out + [f'inventory unreadable: {x}']
    if hashlib.sha256(raw).hexdigest() != inv.get('sha256'): out.append(f'changed: {inv.get("file", INVENTORY)} (not the inventory manifest.json names)')
    want, have = read_inventory(raw.decode()), files_under(root)
    out += [f'missing: {f}' for f in sorted(set(want) - set(have))]
    out += [f'not in the manifest: {f}' for f in sorted(set(have) - set(want))]
    out += [f'changed: {f}' for f in sorted(set(want) & set(have)) if want[f] != have[f]]
    return out


def main():
    ap = argparse.ArgumentParser(description='write or verify a game pack\'s manifest.json and file inventory')
    sub = ap.add_subparsers(dest='cmd', required=True)
    w = sub.add_parser('write'); w.add_argument('root'); w.add_argument('--title', required=True); w.add_argument('--chain', default=''); w.add_argument('--display-version', default=''); w.add_argument('--bundled', action='store_true')
    v = sub.add_parser('verify'); v.add_argument('root')
    a = ap.parse_args(); root = Path(a.root)
    if not root.is_dir(): sys.exit(f'pack_manifest: no pack folder {root}')
    if a.cmd == 'write':
        m = write(root, a.title, a.chain, a.display_version, a.bundled)
        i = m['inventory']
        print(f'manifest: {root / "manifest.json"}: ' + (f'{i["files"]} files, {i["bytes"] / 2**30:.2f} GB' if i else 'bundled, no inventory') + f', platforms {" ".join(m["platforms"]) or "none"}')
        return
    bad = problems(root)
    for b in bad: print(f'[RED] pack {root}: {b}')
    if bad: sys.exit(1)
    print(f'pack {root}: manifest verified')


if __name__ == '__main__':
    main()
