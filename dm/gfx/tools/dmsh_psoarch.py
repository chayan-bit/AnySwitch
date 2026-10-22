#!/usr/bin/env python3
# Precompiled pipeline archive (dm/gfx/README.md#precompiled-pipeline-archives): compiles the pipelines a harvest run recorded (DM_PSO_HARVEST, nvn/nvn_psoarch.m) into GPU binaries for the target devices,
# so the app creates them without a driver compile. Apple's documented flow: metal-source extracts the pipeline script (.mtlp-json) a harvested archive carries, metal-tt compiles it.
# The script names each shader library by the sha256 of its bytes (the host loads libraries from memory, lib_from_file); this tool finds the library with that hash in --libs (the library folders of
# the harvesting machine: the Mac b-<V>/ for a Mac harvest, the iOS one for a device harvest) and compiles against the library of the same name in --target-libs (the libraries the app ships).
# So a pipeline harvested on the Mac compiles for the iOS libraries of the same chain version. Pipelines of libraries found in no folder (host built-ins compiled from source at run time,
# another chain version) are left out and counted: those compile on first use as before.
# metal-tt reads only libraries linked by the metal driver (`xcrun metal x.air -o x.metallib`); the chain links with `metallib`, which leaves out the platform metadata metal-tt needs
# ("cannot find private metadata"). So each needed library is rebuilt from its MSL (--msl: the Mac b-<V>/, which keeps <key>_b.metal) with the compile convention its json records
# (chain_metal) and linked by the driver: the same AIR, so for nearly every library the same function hashes the app looks up. The driver link folds the bitcode of shaders that only write
# constants (iOS SDK 26: a fragment shader returning a fixed color, a vertex shader writing a fixed position), which gives their functions another hash: pipelines of such a library could never be
# found, so they are left out and counted (they compile on first use as before). The rebuilt libraries stay in a temporary folder, the shipped ones are untouched.
# Shader packs (dmsh_pack.py, <dir>/pack/<n>.metallib) are found the same way and need no relink: the pack tool links them with the driver, so metal-tt reads the shipped pack itself.
# Usage: dmsh_psoarch.py <harvest.metallib>... --libs <dir>... --target-libs <dir> --msl <dir> -o <out.metallib> [--platform ios|macos] [--arch applegpu_g16g ...]
#   --platform: ios (default, the app) or macos (dmhost, tests); --arch: GPU architectures to build (default: every GPU of the platform; xcrun metal-arch prints this Mac's)
# The output is game-derived (compiled game shaders): write it only under the gitignored build output
import os, re, sys, glob, json, shlex, hashlib, argparse, tempfile, subprocess, concurrent.futures as cf

# iOS 26: the app's deployment target (project.yml, Metal 4; the iOS libraries are built for 18, ios_metal.py). macOS: the SDK's own version, as the Mac libraries are built with the
# SDK default and metal-tt refuses a library whose AIR is newer than the target's
TARGET = {'ios': ('iphoneos', lambda: 'air64-apple-ios26.0'),
          'macos': ('macosx', lambda: 'air64-apple-macos' + subprocess.run(['xcrun', '-sdk', 'macosx', '--show-sdk-version'], capture_output=True, text=True).stdout.strip())}
ALIAS = re.compile(r'alias:([^#"]+)#')   # a function reference: alias:<library label>#<name>
KINDS = ('render_pipelines', 'compute_pipelines', 'tile_pipelines', 'mesh_render_pipelines')


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
    return h.hexdigest().upper()


def scripts(harvest, work):
    """The pipeline scripts metal-source extracts from one harvested archive"""
    out = os.path.join(work, 'x%d' % len(os.listdir(work)))
    r = subprocess.run(['xcrun', 'metal-source', '-flatbuffers=json', harvest, '-o', out], capture_output=True, text=True)
    found = glob.glob(os.path.join(out, '**', '*.mtlp-json'), recursive=True)
    if r.returncode or not found: sys.exit(f'[RED] {harvest}: no pipeline script inside (not a harvested archive?) {r.stderr}')
    return [json.load(open(p)) for p in found]


def fn_hashes(path):
    """The function hashes a metallib lists (HASH tags: 2-byte size, 32-byte sha256): what a binary archive keys its pipelines by"""
    b = open(path, 'rb').read()
    return [b[m.start() + 6:m.start() + 38] for m in re.finditer(b'HASH', b)]


def pack_index(d):
    """{key: 'pack/<n>.metallib'} from a folder's pack/index.tsv (dmsh_pack.py), empty without one"""
    p = os.path.join(d, 'pack', 'index.tsv')
    if not os.path.exists(p): return {}
    return {c[0]: f'pack/{c[1]}.metallib' for c in (ln.split('\t') for ln in open(p) if not ln.startswith('#'))}


def merge(docs, names):
    """One script: pipelines deduplicated, those using a library not in names dropped. Returns (script, {label: library file name}, kept, dropped)"""
    libs, spec, funcs = {}, {}, {}
    for d in docs:
        lib = d.get('libraries', {})
        for p in lib.get('paths', []):
            n = names.get(p['label'].upper())
            if n: libs[p['label']] = n
        for f in lib.get('specialized_functions', []): spec[f['label']] = f   # a function specialized by constants (SpecializedLib_<hash>), over a library above
        funcs.update(d.get('functions') or {})
    spec = {l: f for l, f in spec.items() if all(x in libs for x in ALIAS.findall(json.dumps(f)))}
    known = set(libs) | set(spec)
    pipes, seen, dropped = {k: [] for k in KINDS}, set(), 0
    for d in docs:
        for kind in KINDS:
            for p in d.get('pipelines', {}).get(kind, []):
                t = json.dumps(p, sort_keys=True)
                if t in seen: continue
                seen.add(t)
                if all(x in known for x in ALIAS.findall(t)): pipes[kind].append(p)
                else: dropped += 1
    text = json.dumps(pipes)
    used = lambda l: f'alias:{l}#' in text or any(f'alias:{l}#' in json.dumps(f) for s, f in spec.items() if f'alias:{s}#' in text)
    base = dict(docs[0]); base['functions'] = funcs; base['pipelines'] = {k: v for k, v in pipes.items() if v}
    base['libraries'] = {'paths': [], 'specialized_functions': [f for l, f in spec.items() if f'alias:{l}#' in text]}
    return base, {l: n for l, n in libs.items() if used(l)}, sum(len(v) for v in pipes.values()), dropped


def relink(name, target_libs, msl_dir, out_dir):
    """<name> rebuilt from its MSL with the target folder's recorded compile convention, linked by the metal driver (keeping the convention's flags: -mios-version-min sets the platform)"""
    key = re.sub(r'_bf?\.metallib$', '', name)
    rec = json.load(open(os.path.join(target_libs, key + '_b.json')))['chain_metal']
    cc = shlex.split(rec.split(';')[0])
    if cc[:4] != ['xcrun', '-sdk', cc[2], 'metal'] or '-c' not in cc: sys.exit(f'[RED] {key}_b.json: unexpected compile convention "{rec}"')
    msl, air, lib = os.path.join(msl_dir, name[:-len('.metallib')] + '.metal'), os.path.join(out_dir, name + '.air'), os.path.join(out_dir, name)
    subprocess.run([*cc, msl, '-o', air], check=True, capture_output=True)
    subprocess.run([*(x for x in cc if x != '-c'), air, '-o', lib], check=True, capture_output=True)
    os.unlink(air)
    return lib


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('harvest', nargs='+'); a.add_argument('--libs', nargs='+', required=True); a.add_argument('--target-libs', required=True); a.add_argument('--msl', required=True)
    a.add_argument('-o', required=True); a.add_argument('--platform', choices=TARGET, default='ios'); a.add_argument('--arch', nargs='*', default=[])
    o = a.parse_args()
    names = {}   # sha256 of a library -> its file name (the shader key + _b / _bf)
    for d in o.libs:
        for p in glob.glob(os.path.join(d, '*.metallib')) + glob.glob(os.path.join(d, 'pack', '*.metallib')): names[sha(p)] = os.path.relpath(p, d)   # pack/<n>.metallib: dmsh_pack.py
    names = {h: n for h, n in names.items() if os.path.exists(os.path.join(o.target_libs, n))}
    covered = pack_index(o.target_libs)   # with packs the app does not ship the loose library of a packed key (build_ipa.sh), so pipelines harvested on it would never be looked up
    names = {h: n for h, n in names.items() if n.startswith('pack/') or n[:-len('.metallib')] not in covered}
    if any(n.startswith('pack/') for n in names.values()):   # a pack is compiled against the target pack of the same number: both must hold the same shaders
        tix = pack_index(o.target_libs)
        for d in o.libs:
            if pack_index(d) not in ({}, tix): sys.exit(f'[RED] the shader packs of {d} and {o.target_libs} differ: rebuild both with the same dmsh_pack.py --per-pack and key set')
    with tempfile.TemporaryDirectory() as work:
        docs = [s for h in o.harvest for s in scripts(h, work)]
        script, libs, kept, dropped = merge(docs, names)
        print(f'pipelines: {kept} to compile from {len(libs)} libraries, {dropped} left out (library not in --libs / --target-libs: host built-ins or another chain version)')
        if not kept: sys.exit('[RED] nothing to compile')
        rl = os.path.join(work, 'libs'); os.makedirs(rl)
        with cf.ThreadPoolExecutor(os.cpu_count()) as ex:
            paths = dict(zip(libs, ex.map(lambda n: os.path.join(o.target_libs, n) if n.startswith('pack/') else relink(n, o.target_libs, o.msl, rl), libs.values())))   # packs are driver-linked already
        moved = {l for l, p in paths.items() if fn_hashes(p) != fn_hashes(os.path.join(o.target_libs, libs[l]))}
        if moved:
            n0 = sum(len(v) for v in script['pipelines'].values())
            script['pipelines'] = {k: [p for p in v if not set(ALIAS.findall(json.dumps(p))) & moved] for k, v in script['pipelines'].items()}
            print(f'pipelines: {n0 - sum(len(v) for v in script["pipelines"].values())} left out, their library relinks to other function hashes than the shipped one ({len(moved)} libraries, '
                  f'shaders writing only constants): they compile on first use')
        script['libraries']['paths'] = [{'label': l, 'path': p} for l, p in sorted(paths.items()) if l not in moved]
        sp = os.path.join(work, 'pipelines.mtlp-json'); json.dump(script, open(sp, 'w'), indent=1)
        sdk, target = TARGET[o.platform]
        cmd = ['xcrun', '-sdk', sdk, 'metal-tt', '-target', target(), *[x for arch in o.arch for x in ('-arch', arch)], sp, '-o', o.o + '.tmp']
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode: sys.exit(f'[RED] metal-tt failed ({" ".join(cmd)}):\n{r.stderr}')
        os.replace(o.o + '.tmp', o.o)
    archs = subprocess.run(['xcrun', 'metal-lipo', o.o, '-archs'], capture_output=True, text=True).stdout.split()
    print(f'wrote {o.o} ({os.path.getsize(o.o) / 1048576:.1f} MB): {" ".join(archs)}')


if __name__ == '__main__':
    main()
