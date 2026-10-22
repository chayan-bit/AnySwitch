#!/usr/bin/env python3
# Flexible pipeline archive (dm/gfx/README.md, pipeline coverage, runtime nvn/nvn_flexpso.m): one unspecialized Metal 4 pipeline (colour formats, write masks and blending left open) per pipeline
# the runtime can ask for, compiled for the target GPUs with metal-tt into an MTL4Archive (dm/pso_flex.metallib in the app).
# The descriptors come from the runtime's own code: tools/pso_flexbench.m replays the records through nvn_mtl.m pso_desc + nvn_flexpso.m flexpso_desc on this Mac and serializes them
# (MTL4PipelineDataSetSerializer); the libraries are relinked by the metal driver as dmsh_psoarch.py does, and those whose function hashes move (constant-only shaders) are left out.
# Records (what to put in), in tiers filled in this order until the size cap (--max-mb, default 300; 0 = no cap):
#   1. harvested and learned: --records pso_user*.tsv (R records of harvest runs and of devices, whose pipeline log is always on);
#   2. accelerator pairs: --pairs lines whose rules are not iface alone (split, tfx) and the same-variation table (shader_pairs.tsv);
#   3. interface pairs: --pairs lines found by the generic iface rule alone.
#   A pair becomes a record with no vertex or colour state: the unspecialized pipeline of that pair with no vertex layout, exact for draws whose layout is empty.
#   The cap counts records at the measured archive size per pipeline (KB_EACH); the size written is printed, a [RED] line when it is over.
# --check: replays the records against the archive written (a macOS archive, --platform macos) and prints the hit rate, the archive's open time and memory footprint; --check-only skips the build.
# Usage: dmsh_flexarch.py --records <tsv>... [--pairs <tsv>...] [--max-mb 300] --msl <Mac b-V dir> --target-libs <dir> -o <out.metallib> [--platform ios|macos] [--arch applegpu_g16g ...] [--check]
#   Environment: DM_NVN_SHMAP (shader map), DM_MSL_DIR (the Mac library root holding b-<V>), as for pso_flexbench. The output is game-derived: write it only under the gitignored build output
import os, re, sys, json, glob, argparse, tempfile, subprocess, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dmsh_psoarch as A

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(HERE, '../tests/pso_flexbench')
SKEY = 432   # sizeof(pso_skey) on arm64 (nvn_pso_skey.h; tests/t_pso_skey checks the layout)
KB_EACH = {'ios': 34, 'macos': 21}   # archive KB per record, measured for applegpu_g16g; library sharing between records makes it an upper bound
TIERS = ('harvested and learned', 'accelerator pairs', 'interface pairs')


def pair_record(v, p):
    """R record of a bare shader pair: vertex key, fragment key, stages 0 / 1, no state (nvn_pso_skey.h layout)"""
    b = bytearray(SKEY)
    b[0:len(v) + 2] = (v + '_b').encode(); b[24:24 + len(p) + 2] = (p + '_b').encode()
    b[48], b[49] = 0, 1
    return 'R\t' + bytes(b).hex()


def tiers(o):
    """[[record]] per TIERS entry, deduplicated across tiers"""
    t, seen = ([], [], []), set()
    def add(i, r):
        if r[2:] not in seen: seen.add(r[2:]); t[i].append(r)
    for path in o.records:
        for l in open(path):
            c = l.rstrip('\n').split('\t')
            if c[0] == 'R' and len(c) > 1 and len(c[1]) == 2 * SKEY: add(0, 'R\t' + c[1])
    for path in o.pairs:
        for l in open(path):
            if l.startswith('#') or not l.strip(): continue
            c = l.split()
            add(2 if len(c) > 2 and c[2] == 'iface' else 1, pair_record(c[0], c[1]))
    return t


def records(o):
    """(records in tier order up to the cap, how many are harvested), printing what each tier gives"""
    cap = o.max_mb * 1024 // KB_EACH[o.platform] if o.max_mb else float('inf')
    out, nh = [], None
    for name, rs in zip(TIERS, tiers(o)):
        take = rs[:max(0, int(min(len(rs), cap - len(out))))]
        print(f'tier {name}: {len(take)} of {len(rs)} records' + ('' if len(take) == len(rs) else f' (cap {o.max_mb} MB reached)'))
        out += take; nh = len(take) if nh is None else nh
    return out, nh


def bench(manifest, env):
    r = subprocess.run([BENCH], env={**os.environ, 'BENCH_MODE': 'flex', 'BENCH_MANIFEST': manifest, **env}, capture_output=True, text=True)
    line = '\n'.join(l for l in r.stdout.splitlines() if l.startswith('BENCH'))   # the totals, and with an archive its open time and memory footprint
    if r.returncode or not line: sys.exit(f'[RED] pso_flexbench failed ({r.returncode}): {r.stderr[-2000:]}')
    for l in r.stderr.splitlines():
        if '[RED]' in l: print(l)
    return line


def build(script, msl, target_libs, out, platform, archs):
    """metal-tt over a Metal 4 pipelines script, libraries relinked (dmsh_psoarch.relink); returns (pipelines kept, left out)"""
    d = json.load(open(script))
    shas = {}
    with cf.ThreadPoolExecutor(8) as ex:
        fs = glob.glob(os.path.join(msl, '*.metallib'))
        for p, h in zip(fs, ex.map(A.sha, fs)): shas[h] = os.path.basename(p)
    names = {l['label']: shas[l['label'].upper()] for l in d['libraries'] if l['label'].upper() in shas}
    with tempfile.TemporaryDirectory() as w:
        with cf.ThreadPoolExecutor(os.cpu_count()) as ex:
            paths = dict(zip(names, ex.map(lambda n: A.relink(n, target_libs, msl, w), names.values())))
        moved = {l for l, p in paths.items() if A.fn_hashes(p) != A.fn_hashes(os.path.join(target_libs, names[l]))} | {l['label'] for l in d['libraries'] if l['label'] not in names}
        gone = {'fnd:' + f['label'] for f in d['function_descriptors']['library_function_descriptors'] if f['library'] in moved}
        rp = d['pipeline_descriptors']['render_pipeline_descriptors']
        keep = [x for x in rp if not gone & {x.get('vertex_function_descriptor'), x.get('fragment_function_descriptor')}]
        d['pipeline_descriptors']['render_pipeline_descriptors'] = keep
        fds = d['function_descriptors']['library_function_descriptors']
        d['function_descriptors']['library_function_descriptors'] = [f for f in fds if 'fnd:' + f['label'] not in gone]
        d['libraries'] = [{'label': l, 'path': p} for l, p in sorted(paths.items()) if l not in moved]
        sp = os.path.join(w, 'pipelines.mtl4-json'); json.dump(d, open(sp, 'w'))   # metal-tt takes a Metal 4 script by this extension only
        sdk, target = A.TARGET[platform]
        cmd = ['xcrun', '-sdk', sdk, 'metal-tt', '-target', target(), *[x for a in archs for x in ('-arch', a)], sp, '-o', out + '.tmp']
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode: sys.exit(f'[RED] metal-tt failed ({" ".join(cmd)}):\n{r.stderr[-3000:]}')
        os.replace(out + '.tmp', out)
    return len(keep), len(rp) - len(keep)


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('--records', nargs='*', default=[]); a.add_argument('--pairs', nargs='*', default=[])
    a.add_argument('--msl', required=True); a.add_argument('--target-libs', required=True); a.add_argument('-o', required=True)
    a.add_argument('--platform', choices=A.TARGET, default='ios'); a.add_argument('--arch', nargs='*', default=[]); a.add_argument('--check', action='store_true')
    a.add_argument('--max-mb', type=int, default=300, help='archive size cap in MB, filled tier by tier (0 = no cap)')
    a.add_argument('--check-only', action='store_true', help='only replay the records against the existing -o archive')
    o = a.parse_args()
    if not os.access(BENCH, os.X_OK): sys.exit(f'[RED] build {BENCH} first: make -C dm/gfx/tests GAME=<id> pso_flexbench')
    recs, nh = records(o)
    if not recs: sys.exit('[RED] no records (--records / --pairs)')
    with tempfile.TemporaryDirectory() as w:
        man, script = os.path.join(w, 'records.tsv'), os.path.join(w, 'pipelines.mtlp-json')
        open(man, 'w').write('\n'.join(recs) + '\n')
        if o.check_only: print('check:', bench(man, {'BENCH_ARCHIVE': o.o})); return
        print(f'records: {nh} harvested, {len(recs) - nh} shader pairs; serializing their unspecialized pipelines (pso_flexbench)')
        print(bench(man, {'BENCH_SCRIPT': script}))
        kept, left = build(script, o.msl, o.target_libs, o.o, o.platform, o.arch)
        archs = subprocess.run(['xcrun', 'metal-lipo', o.o, '-archs'], capture_output=True, text=True).stdout.split()
        mb = os.path.getsize(o.o) / 1048576
        print(f'wrote {o.o} ({mb:.1f} MB, {" ".join(archs)}): {kept} pipelines, {left} left out (constant-only libraries: compiled on a worker at run time)'
              + (f' [RED] over the {o.max_mb} MB cap: lower KB_EACH' if o.max_mb and mb > o.max_mb else ''))
        if o.check: print('check:', bench(man, {'BENCH_ARCHIVE': o.o}))


if __name__ == '__main__':
    main()
