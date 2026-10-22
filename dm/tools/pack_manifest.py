#!/usr/bin/env python3
# A game pack's manifest.json (docs/development.md "Game packs"): what the pack is and every file in it, so an import (or a copy to another machine) can be checked before boot.
#   write <root> --title <id> [--chain V] [--display-version X]: the four version numbers from dm/host/dm_abi.h, the platforms whose code dylib is present, each module's build id
#     (profile/<module>.fixups.tsv), and the size and sha256 of every file under the root
#   verify <root>: the numbers still match this tree's dm_abi.h, and every file is there with its size and digest, nothing missing or extra; exit 1 naming each difference
# The engine checks the numbers itself before boot (dm/host/boot.m dm_pack_check); verify is the slow, complete check (it reads every byte).
import argparse, hashlib, json, os, re, sys
from pathlib import Path
ABI_H = Path(__file__).resolve().parents[1] / 'host/dm_abi.h'
ABI_KEYS = {'DM_PACK_FORMAT': None, 'DM_PROFILE_SCHEMA': 'profile_schema', 'DM_CODE_ABI': 'code', 'DM_SHADER_ABI': 'shader'}
PLATFORMS = ('ios', 'macos')


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


def files_under(root):   # relative path → (size, sha256) of every file, manifest.json itself excluded; symlinks are followed (a pack holds files, clones or not)
    out = {}
    for d, dirs, names in os.walk(root, followlinks=True):
        dirs.sort()
        for n in sorted(names):
            p = Path(d) / n; rel = p.relative_to(root).as_posix()
            if rel != 'manifest.json': out[rel] = {'size': p.stat().st_size, 'sha256': digest(p)}
    return out


def build_ids(root):
    ids = {}
    for f in sorted((root / 'profile').glob('*.fixups.tsv')):
        hdr = dict(l[2:].split(None, 1) for l in f.read_text().splitlines() if l.startswith('# ') and len(l.split()) >= 3)
        ids[f.name[:-len('.fixups.tsv')]] = hdr.get('BUILD_ID', '').strip()
    return ids


def manifest(root, title, chain='', display_version=''):
    if not re.fullmatch(r'[0-9A-Fa-f]{16}', title): sys.exit(f'pack_manifest: --title must be a 16-digit hex title id, not {title}')
    e = engine_numbers()
    return {'format': e['DM_PACK_FORMAT'], 'title_id': title.upper(), 'display_version': display_version, 'chain': chain,
            'abi': {v: e[k] for k, v in ABI_KEYS.items() if v}, 'platforms': [p for p in PLATFORMS if (root / f'code/{p}.dylib').is_file()],
            'modules': build_ids(root), 'files': files_under(root)}


def problems(root):   # every difference between the pack and its manifest, and between the manifest and this engine
    try: m = json.loads((root / 'manifest.json').read_text())
    except (OSError, ValueError) as x: return [f'manifest.json unreadable: {x}']
    e, out = engine_numbers(), []
    if m.get('format') != e['DM_PACK_FORMAT']: out.append(f'pack format {m.get("format")}, this engine {e["DM_PACK_FORMAT"]}')
    for k, v in ABI_KEYS.items():
        if v and m.get('abi', {}).get(v) != e[k]: out.append(f'{v} {m.get("abi", {}).get(v)}, this engine {e[k]}')
    want, have = m.get('files', {}), files_under(root)
    out += [f'missing: {f}' for f in sorted(set(want) - set(have))]
    out += [f'not in the manifest: {f}' for f in sorted(set(have) - set(want))]
    out += [f'changed: {f}' for f in sorted(set(want) & set(have)) if want[f] != have[f]]
    return out


def main():
    ap = argparse.ArgumentParser(description='write or verify a game pack\'s manifest.json')
    sub = ap.add_subparsers(dest='cmd', required=True)
    w = sub.add_parser('write'); w.add_argument('root'); w.add_argument('--title', required=True); w.add_argument('--chain', default=''); w.add_argument('--display-version', default='')
    v = sub.add_parser('verify'); v.add_argument('root')
    a = ap.parse_args(); root = Path(a.root)
    if not root.is_dir(): sys.exit(f'pack_manifest: no pack folder {root}')
    if a.cmd == 'write':
        m = manifest(root, a.title, a.chain, a.display_version)
        (root / 'manifest.json').write_text(json.dumps(m, indent=1) + '\n')
        print(f'manifest: {root / "manifest.json"}: {len(m["files"])} files, {sum(f["size"] for f in m["files"].values()) / 2**30:.2f} GB, platforms {" ".join(m["platforms"]) or "none"}')
        return
    bad = problems(root)
    for b in bad: print(f'[RED] pack {root}: {b}')
    if bad: sys.exit(1)
    print(f'pack {root}: manifest verified')


if __name__ == '__main__':
    main()
