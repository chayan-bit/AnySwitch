#!/usr/bin/env python3
# Shader packs (dm/gfx/README.md, "Shader packs"): the chain writes one library per shader (<key>_b.metallib), and opening tens of thousands of small files costs the host
# a library open per new shader at every scene change. This tool links the chain's shaders into a few large libraries the host opens once and keeps resident:
#   <out>/<n>.metallib  driver-linked libraries (xcrun metal *.air -o, which metal-tt reads as is, so a pipeline archive compiles against the packs without a relink);
#                       every entry point is renamed k<key>_<entry> (k0a0a4f086f237776_b_main0, _main0_z), unique across the packs, so the host's lookup is a name lookup
#   <out>/refl.bin      every shader's reflection json, concatenated (one mapped file instead of one open per shader)
#   <out>/index.tsv     key, pack number, json offset, json length, layer flag (the library writes render_target_array_index, which the host otherwise reads from the library bytes)
# The source is the chain's MSL (<key>_b.metal in the Mac b-<V>/), compiled again with the target folder's recorded convention (chain_metal in each json), so the code is the chain's own;
# only the entry names differ. Shaders are grouped by the container they come from (shader map column 5) so a pack holds related shaders, and cut every --per-pack shaders: by count, so the Mac and iOS packs of one chain version hold the same keys under the same
# numbers (dmsh_psoarch.py compiles a Mac harvest against the iOS pack of the same name, and checks the two indexes agree).
# --hot: pso_user.tsv / pso_manifest.tsv files (harvest runs); their shaders (S lines, in first-use order) fill the first packs, apart from the rest.
# A pipeline archive (metal-tt) embeds every library its pipelines name whole, so harvested shaders spread over many packs would put most of the title's code into the archive;
# grouped, the archive embeds only the hot packs, and the shaders a launch needs first share the first pack the background pass opens. Give the Mac and iOS runs the same lists.
# The compiled AIR is cached per key in <out>/.air (the chain version is in the folder name, so a key's MSL never changes there); a rerun only links.
# Usage: dmsh_pack.py --msl <Mac b-V dir> --target <b-V dir to pack> [-o <out dir>, default <target>/pack] [--map shader_map.tsv] [--per-pack 200] [--hot pso_user.tsv ...] [--keys file] [-j N] [--check]
#   --check: only verify an existing pack folder (every indexed shader's entry points are in its pack, names unique, refl.bin slices are the shaders' json)
# The output is game-derived (compiled game shaders): it lives only in the gitignored build output, beside the chain's libraries.
import os, re, sys, json, glob, shlex, argparse, subprocess, concurrent.futures as cf

ENTRY_KEYS = ('entry', 'entry_z', 'entry_tf')
BATCH = 48   # MSL files per compiler process (one process per file spends most of its time starting up)


def fn_name(key, entry):
    return f'k{key}_{entry}'


def entries(j):
    return [j[k] for k in ENTRY_KEYS if j.get(k)]


def convention(rec):
    """(compile argv, link argv) from a json's chain_metal record: the same front end, linked by the metal driver instead of metallib"""
    cc = shlex.split(rec.split(';')[0])
    if cc[:4] != ['xcrun', '-sdk', cc[2], 'metal'] or '-c' not in cc: sys.exit(f'[RED] unexpected compile convention "{rec}"')
    return cc, [x for x in cc if x != '-c']


def rename(src, key, names):
    """The MSL with each entry point renamed (whole identifiers only: main0 never touches main0_out / main0_in)"""
    pat = re.compile(r'\b(' + '|'.join(map(re.escape, sorted(names, key=len, reverse=True))) + r')\b')
    return pat.sub(lambda m: fn_name(key, m.group(1)), src)


def compile_batch(cc, items, air_dir):
    """items: [(key, renamed msl path)] -> compiled into air_dir/<key>.air, one compiler process"""
    subprocess.run([*cc, *(p for _, p in items)], cwd=air_dir, check=True, capture_output=True)


def groups(keys, map_path):
    """keys ordered by source container (shader map column 5 up to the first '#'), then key: shaders of one archive land in the same pack"""
    src = {}
    if map_path:
        for ln in open(map_path, encoding='utf-8'):
            c = ln.rstrip('\n').split('\t')
            if len(c) > 4 and not ln.startswith(('#', 'package')): src.setdefault(c[3] + '_b', c[4].split('#')[0])
    return sorted(keys, key=lambda k: (src.get(k, '~'), k))


def hot_keys(paths):
    """Shader keys in first-use order from pso_user.tsv / pso_manifest.tsv files and dmsh_psoexpand.py manifests: S lines name a key, R lines carry their
    shaders' keys as text inside the hex of the pipeline key (nvn_pso_skey.h)"""
    seen = {}
    for p in paths:
        for ln in open(p, encoding='utf-8'):
            c = ln.rstrip('\n').split('\t')
            if c[0] == 'S' and len(c) > 1: seen.setdefault(c[1], None)
            elif c[0] == 'R' and len(c) > 1:
                for k in re.findall(rb'[0-9a-f]{16}_b', bytes.fromhex(c[1])): seen.setdefault(k.decode(), None)
    return list(seen)


def chunks(keys, n):
    return [keys[i:i + n] for i in range(0, len(keys), n)]


def nm(lib):
    out = subprocess.run(['xcrun', 'metal-nm', lib], capture_output=True, text=True, check=True).stdout
    return [ln.split()[-1] for ln in out.splitlines() if ln.strip()]


def check(out_dir, target):
    """Every indexed shader's entry points are in its pack, names unique across packs, refl.bin slices are the target's json. Returns the number of shaders checked"""
    rows = [ln.rstrip('\n').split('\t') for ln in open(os.path.join(out_dir, 'index.tsv')) if not ln.startswith('#')]
    refl = open(os.path.join(out_dir, 'refl.bin'), 'rb').read()
    seen, have = {}, {}
    for p in sorted(glob.glob(os.path.join(out_dir, '*.metallib'))):
        n = int(os.path.basename(p).split('.')[0])
        for f in nm(p):
            if f in seen: sys.exit(f'[RED] function {f} in packs {seen[f]} and {n}')
            seen[f] = n
        have[n] = True
    for key, pack, off, ln, _ in rows:
        blob = refl[int(off):int(off) + int(ln)]
        if blob != open(os.path.join(target, key + '.json'), 'rb').read(): sys.exit(f'[RED] {key}: refl.bin slice differs from {key}.json')
        for e in entries(json.loads(blob)):
            if seen.get(fn_name(key, e)) != int(pack): sys.exit(f'[RED] {key}: {fn_name(key, e)} not in pack {pack}')
    return len(rows)


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('--msl', required=True); a.add_argument('--target', required=True); a.add_argument('-o'); a.add_argument('--map')
    a.add_argument('--per-pack', type=int, default=200); a.add_argument('--hot', nargs='*', default=[]); a.add_argument('--keys'); a.add_argument('-j', type=int, default=os.cpu_count()); a.add_argument('--check', action='store_true')
    o = a.parse_args()
    out = o.o or os.path.join(o.target, 'pack')
    if o.check:
        print(f'PACK CHECK OK {check(out, o.target)} shaders in {len(glob.glob(os.path.join(out, "*.metallib")))} packs ({out})'); return
    keys = [os.path.basename(p)[:-5] for p in glob.glob(os.path.join(o.target, '*_b.json'))]
    if o.keys: want = set(open(o.keys).read().split()); keys = [k for k in keys if k in want]
    keys = [k for k in keys if os.path.exists(os.path.join(o.target, k + '.metallib')) and os.path.exists(os.path.join(o.msl, k + '.metal'))]
    if not keys: sys.exit(f'[RED] no shaders with a library in {o.target} and MSL in {o.msl}')
    js = {k: open(os.path.join(o.target, k + '.json'), 'rb').read() for k in keys}
    jd = {k: json.loads(b) for k, b in js.items()}
    recs = {j['chain_metal'] for j in jd.values()}
    if len(recs) != 1: sys.exit(f'[RED] {len(recs)} compile conventions in {o.target}: {recs}')
    cc, link = convention(recs.pop())
    work = os.path.join(out, '.air'); src_dir = os.path.join(work, 'src'); os.makedirs(src_dir, exist_ok=True)
    todo = [k for k in keys if not os.path.exists(os.path.join(work, k + '.air'))]
    for k in todo:
        with open(os.path.join(src_dir, k + '.metal'), 'w') as f: f.write(rename(open(os.path.join(o.msl, k + '.metal')).read(), k, entries(jd[k])))
    print(f'{len(keys)} shaders, {len(todo)} to compile ({" ".join(cc[2:3] + cc[4:])})', flush=True)
    batches = [[(k, os.path.join(src_dir, k + '.metal')) for k in todo[i:i + BATCH]] for i in range(0, len(todo), BATCH)]
    with cf.ThreadPoolExecutor(o.j) as ex:
        for n, _ in enumerate(ex.map(lambda b: compile_batch(cc, b, work), batches), 1):
            if n % 50 == 0: print(f'compiled {n * BATCH} / {len(todo)}', flush=True)
    for k in todo: os.unlink(os.path.join(src_dir, k + '.metal'))
    have = set(keys)
    hot = [k for k in hot_keys(o.hot) if k in have]; hs = set(hot)
    packs = chunks(hot, o.per_pack) + chunks([k for k in groups(keys, o.map) if k not in hs], o.per_pack)   # hot packs never mix with cold ones
    if o.hot: print(f'{len(hot)} hot shaders (first use in {len(o.hot)} lists) in the first {len(chunks(hot, o.per_pack))} packs')
    for p in glob.glob(os.path.join(out, '*.metallib')): os.unlink(p)
    def link_pack(n):
        subprocess.run([*link, *(k + '.air' for k in packs[n]), '-o', os.path.join(out, f'{n}.metallib')], cwd=work, check=True, capture_output=True)
    with cf.ThreadPoolExecutor(o.j) as ex: list(ex.map(link_pack, range(len(packs))))
    rows, off = [], 0
    with open(os.path.join(out, 'refl.bin'), 'wb') as rb:
        for n, ks in enumerate(packs):
            for k in ks:
                layer = int(b'render_target_array_index' in open(os.path.join(o.target, k + '.metallib'), 'rb').read())   # the host's own test (lib_from_file), on the chain's library
                rb.write(js[k]); rows.append(f'{k}\t{n}\t{off}\t{len(js[k])}\t{layer}\n'); off += len(js[k])
    with open(os.path.join(out, 'index.tsv.tmp'), 'w') as f:
        f.write(f'# chain b-{jd[keys[0]]["chain"]} packs {len(packs)} shaders {len(keys)}: key, pack, json offset, json length, layer\n'); f.writelines(rows)
    os.replace(os.path.join(out, 'index.tsv.tmp'), os.path.join(out, 'index.tsv'))
    mb = sum(os.path.getsize(os.path.join(out, f'{n}.metallib')) for n in range(len(packs))) / 1048576
    print(f'wrote {len(packs)} packs ({mb:.1f} MB) + refl.bin ({off / 1048576:.1f} MB) for {len(keys)} shaders into {out}')
    print(f'PACK CHECK OK {check(out, o.target)} shaders')


if __name__ == '__main__':
    main()
