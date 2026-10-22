#!/usr/bin/env python3
# Pipeline expansion for the precompiled pipeline archive (dm/gfx/README.md#precompiled-pipeline-archives): learns the fixed-function state vocabulary of a short harvest (the R records of pso_user.tsv)
# and writes R records for statically known shader pairs it did not see, so the archive covers pipelines the harvest run never drew. Game-agnostic: the inputs are any title's
# harvest, its shader map (column 5 = where each key first appeared: container#member#...#var) and pair table (shader_split.py), and the chain's reflection folder (b-<V>/).
# Output = a pso_user.tsv-format manifest; replaying it through the host's own warm-up (pso_replay, DM_PSO_HARVEST) gives a harvest that dmsh_psoarch.py compiles as usual,
# so every descriptor is the one the runtime builds (nvn_mtl.m pso_desc), never a copy of it.
# Record = pso_skey (nvn/nvn_pso_skey.h, arm64 layout, 432 bytes): the shader keys and stages, the merged / specialized flags, then pso_key:
#   render-target part (pass state, independent of the shaders): cfmt[8] dfmt sfmt samples blend_en chmask a2c blend[8] (+ lmap and the merged / specialized bytes)
#   vertex part (pso_key_fill: attr[a] only for the vertex shader's inputs a, stream[s] only for the streams those attributes read)
# Usage: dmsh_psoexpand.py <pso_user.tsv>... --map shader_map.tsv --refl <Mac b-V dir> [-o manifest.tsv] [--build harvest.metallib] [--check macos_archive.metallib]
#          [--per-pair K] [--max-pipelines N] [--max-bytes B] [--no-groups] [--table --pairs shader_pairs.tsv]
#        dmsh_psoexpand.py ... --holdout 0.5   (no output: trains on the first half of the records, reports how much of the second half the expansion predicts)
import os, re, sys, json, struct, argparse, subprocess, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

SKEY, KOFF = 432, 88                    # sizeof(pso_skey), offsetof(pso_skey, k)
RT = [(50, KOFF), (KOFF + 16, KOFF + 136), (KOFF + 328, KOFF + 336)]   # merged, fz, fz_desc + pad | cfmt .. blend[8] | lmap
VX = (KOFF + 136, KOFF + 328)           # attr[16] (u32: fmt 8, offset 19, stream 5), stream[16] {stride, divisor}
PTRS = [(KOFF, KOFF + 16), (KOFF + 336, KOFF + 344)]   # vs, fs, fsfn: zeroed by pso_skey_from
BYTES_PER_PIPELINE = 8_000              # per manifest record, applegpu_g16g slice: measured 7.8 KB on one title (11.1 KB per distinct compiled pipeline)


def text(path):
    with open(path) as f: return f.read()


def keys(b):
    return b[0:24].rstrip(b'\0').decode(), b[24:48].rstrip(b'\0').decode(), b[48], b[49]


def rt_part(b): return b''.join(b[x:y] for x, y in RT)
def vx_part(b): return b[VX[0]:VX[1]]
def special(b): return b[50] or b[51]   # merged pass or run-time specialized fragment: keyed by replay-time planning, not expandable


def compose(vs, vst, fs, fst, rt, vx):
    """A pso_skey from shader keys and the two state parts, laid out as pso_skey_from writes it"""
    b = bytearray(SKEY)
    b[0:24] = vs.encode().ljust(24, b'\0'); b[24:48] = fs.encode().ljust(24, b'\0'); b[48] = vst; b[49] = fst
    o = 0
    for x, y in RT: b[x:y] = rt[o:o + y - x]; o += y - x
    b[VX[0]:VX[1]] = vx
    return bytes(b)


def attrs(vx):
    a = struct.unpack_from('<16I', vx, 0); return {i: a[i] for i in range(16) if a[i]}


def restrict(vx, inputs):
    """The vertex part pso_key_fill would give a shader reading only `inputs`: other attributes and the streams only they read are zero"""
    a, s = list(struct.unpack_from('<16I', vx, 0)), list(struct.unpack_from('<32I', vx, 64))
    a = [a[i] if i in inputs else 0 for i in range(16)]
    used = {x >> 27 for x in a if x}
    s = [s[i] if i // 2 in used else 0 for i in range(32)]
    return struct.pack('<16I32I', *a, *s)


def read_records(paths):
    out, stage = [], {}
    for p in paths:
        for line in text(p).splitlines():
            c = line.rstrip('\n').split('\t')
            if c[0] == 'S' and len(c) >= 3: stage[c[1]] = int(c[2])
            if c[0] == 'R' and len(c) >= 2 and len(c[1]) == 2 * SKEY: out.append(bytes.fromhex(c[1]))
    return list(dict.fromkeys(out)), stage


OUT_STRUCT = re.compile(r'struct main0_(out|in)\n\{\n(.*?)\n\};', re.S)
USER = re.compile(r'(\w+) \w+ \[\[user\(locn(\d+)\)\]\]')
COLOR = re.compile(r'(\w+) \w+ \[\[color\((\d)\)\]\]')


class Facts:
    """Static facts per shader key from the chain's reflection folder: vertex inputs, written colours (+ their MSL types), varyings"""
    def __init__(self, d): self.d, self.c = d, {}

    def get(self, key):
        if key in self.c: return self.c[key]
        f = {'ok': False}
        try: j = json.loads(text(os.path.join(self.d, key + '.json')))
        except (OSError, ValueError): self.c[key] = f; return f
        ra = j.get('raster') if isinstance(j.get('raster'), dict) else {}
        f = {'ok': True, 'inputs': frozenset(v['location'] for v in j.get('vertex_inputs') or []),
             'colors': tuple(ra['colors']) if isinstance(ra.get('colors'), list) else None, 'vout': {}, 'pin': {}, 'ctypes': ()}
        try: msl = text(os.path.join(self.d, key + '.metal'))
        except OSError: msl = ''
        for kind, body in OUT_STRUCT.findall(msl):
            u = {int(n): t for t, n in USER.findall(body)}
            if kind == 'out': f['vout'] = u; f['ctypes'] = tuple(sorted((int(n), t) for t, n in COLOR.findall(body)))
            else: f['pin'] = u
        self.c[key] = f
        return f

    def fsig(self, key):
        """What a render-target state must agree with: the colours the fragment shader writes and their types"""
        if not key: return ('none',)
        f = self.get(key); return (f.get('colors'), f.get('ctypes')) if f['ok'] else None

    def linkable(self, vs, fs):
        """Every varying the pixel shader reads is written by the vertex shader with the same type"""
        v, p = self.get(vs), self.get(fs)
        return v['ok'] and p['ok'] and all(v['vout'].get(l) == t for l, t in p['pin'].items())


def read_map(path):
    """key -> (stage name, group, variation): group = the source without its variation (container#member), so the variations of one shader file share it"""
    m = {}
    for line in text(path).splitlines():
        if line.startswith('#') or line.startswith('package'): continue
        c = line.rstrip('\n').split('\t')
        if len(c) < 4 or c[3] in m: continue
        src = c[4] if len(c) > 4 else ''
        g, _, var = src.rpartition('#') if '#var' in src else (src, '', '')
        m[c[3]] = (c[2], g, var)
    return m


def read_pairs(path):
    return [tuple(l.split()[:2]) for l in text(path).splitlines() if l.strip() and not l.startswith('#')] if path else []


class Vocab:
    def __init__(self, recs, facts):
        self.facts = facts
        self.recs = list(dict.fromkeys(recs)); self.seen = set(self.recs)
        self.rt_by_fs, self.rt_by_sig = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
        self.vx_by_vs, self.vx_by_in = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
        self.pairs, self.rt_by_vs = collections.Counter(), collections.defaultdict(collections.Counter)
        for b in recs:
            if special(b): continue
            vs, fs, _, _ = keys(b)
            self.pairs[(vs, fs)] += 1
            self.rt_by_fs[fs][rt_part(b)] += 1; self.rt_by_vs[vs][rt_part(b)] += 1
            s = facts.fsig(fs)
            if s is not None: self.rt_by_sig[s][rt_part(b)] += 1
            self.vx_by_vs[vs][vx_part(b)] += 1
            vf = facts.get(vs)
            if vf['ok']: self.vx_by_in[vf['inputs']][vx_part(b)] += 1

    def rts(self, fs, vs=''):
        """Render-target parts for a fragment shader, best first: seen with it, then the passes its vertex shader drew in, then the most frequent among fragment shaders writing
        the same colours (the vertex shader's passes only when they also served such a fragment shader: a colour state is never given to a shader whose outputs it does not fit)"""
        out = [t for t, _ in self.rt_by_fs.get(fs, collections.Counter()).most_common()]
        s = self.facts.fsig(fs)
        fit = self.rt_by_sig.get(s, collections.Counter()) if s is not None else collections.Counter()
        out += [t for t, _ in self.rt_by_vs.get(vs, collections.Counter()).most_common() if t in fit and t not in out]
        return out + [t for t, _ in fit.most_common() if t not in out]

    def vxs(self, vs):
        """Vertex parts for a vertex shader: seen with it, then with shaders of the same inputs, then a wider shader's layout restricted to these inputs"""
        out = [t for t, _ in self.vx_by_vs.get(vs, collections.Counter()).most_common()]
        f = self.facts.get(vs)
        if not f['ok']: return out
        out += [t for t, _ in self.vx_by_in.get(f['inputs'], collections.Counter()).most_common() if t not in out]
        wider = collections.Counter()
        for i, c in self.vx_by_in.items():
            if f['inputs'] < i:
                for t, n in c.items(): wider[restrict(t, f['inputs'])] += n
        return out + [t for t, _ in wider.most_common() if t not in out]


def candidates(voc, smap, table, stage, groups_on=True):
    """Shader pairs to expand, most likely first: (1) pairs the harvest drew, (2) the other variations of shader files the harvest paired (same container#member groups),
    (3) the static pair table. Each tier keeps only linkable pairs (varyings agree); vertex-only pipelines follow the vertex shaders seen without a fragment shader"""
    out, seen = [], set()
    def add(p, tier):
        if p not in seen: seen.add(p); out.append((p, tier))
    for p, _ in voc.pairs.most_common(): add(p, 'harvest')
    groups = collections.defaultdict(list)   # group -> its keys, as stored in records (<key><suffix>)
    sfx = {k[16:] for p in voc.pairs for k in p if k}
    suffix = sfx.pop() if len(sfx) == 1 else '_b'
    for k, (st, g, var) in smap.items():
        if g: groups[g].append(k + suffix)
    gp = collections.Counter()
    for (vs, fs), n in voc.pairs.items():
        gv, gf = smap.get(vs[:16], (0, '', ''))[1], smap.get(fs[:16], (0, '', ''))[1] if fs else ''
        if gv and (gf or not fs): gp[(gv, gf)] += n
    for (gv, gf), _ in gp.most_common() if groups_on else ():
        for v in groups[gv]:
            if smap[v[:16]][0] != 'vertex': continue
            if not gf: add((v, ''), 'group'); continue
            for f in groups[gf]:
                if smap[f[:16]][0] == 'pixel' and voc.facts.linkable(v, f): add((v, f), 'group')
    for a, b in table:
        if voc.facts.linkable(a + suffix, b + suffix): add((a + suffix, b + suffix), 'table')
    return out


def expand(voc, cands, stage, per_pair, max_pipes):
    """R records for the candidates: per pair up to per_pair (vertex part x render-target part) combinations, the harvest's own records always kept"""
    out, tiers = list(voc.recs), collections.Counter({'harvest records': len(voc.recs)})
    have = set(out)
    for (vs, fs), tier in cands:
        if len(out) >= max_pipes: break
        vxs, rts = voc.vxs(vs)[:per_pair], voc.rts(fs, vs)[:per_pair]
        if not vxs or not rts: tiers[tier + ' (no state)'] += 1; continue
        vst, fst = stage.get(vs, 0), stage.get(fs, 1) if fs else 0
        n = 0
        for i, j in sorted(((i, j) for i in range(len(vxs)) for j in range(len(rts))), key=lambda x: (x[0] + x[1], x[0])):   # best ranks first
            b = compose(vs, vst, fs, fst, rts[j], vxs[i])
            if b in have: continue
            have.add(b); out.append(b); n += 1; tiers[tier] += 1
            if n >= per_pair: break
    return out[:max_pipes], tiers


def relinked_away(recs, lib_dir):
    """Shader keys whose library dmsh_psoarch.py leaves out (its relink gives other function hashes: shaders writing only constants), decided the way it decides,
    once per distinct library content (a script names libraries by content, so identical libraries share one relink)"""
    import hashlib, tempfile, concurrent.futures as cf
    import dmsh_psoarch as P
    by = collections.defaultdict(list)
    for k in {k for b in recs for k in keys(b)[:2] if k}:
        with open(os.path.join(lib_dir, k + '.metallib'), 'rb') as f: by[hashlib.sha256(f.read()).digest()].append(k)
    with tempfile.TemporaryDirectory() as w:
        def away(ks):
            p = P.relink(ks[0] + '.metallib', lib_dir, lib_dir, w)
            return P.fn_hashes(p) != P.fn_hashes(os.path.join(lib_dir, ks[0] + '.metallib'))
        with cf.ThreadPoolExecutor(os.cpu_count()) as ex:
            return {k for ks, a in zip(by.values(), ex.map(away, by.values())) if a for k in ks}


def replay(manifest, env):
    """Creates the manifest's pipelines through the host's warm-up (pso_replay, built for $GAME); returns its summary line"""
    tests = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../tests')
    if not os.environ.get('GAME'): sys.exit('[RED] GAME is not set (the game profile pso_replay is built for)')
    subprocess.run(['make', '-s', '-C', tests, 'GAME=' + os.environ['GAME'], 'pso_replay'], check=True, stdout=subprocess.DEVNULL)
    r = subprocess.run([os.path.join(tests, 'pso_replay')], env={**os.environ, 'DM_PSO_MANIFEST': manifest, **env}, capture_output=True, text=True)
    with open(manifest + '.log', 'w') as f: f.write(r.stderr)   # every miss / failure line, beside the manifest
    red = [l for l in r.stderr.splitlines() if '[RED]' in l]
    if red: print('\n'.join(red[:10]) + (f'\n... {len(red)} [RED] lines' if len(red) > 10 else ''), file=sys.stderr)
    line = next((l for l in r.stdout.splitlines() if l.startswith('PSO_REPLAY')), None)
    if r.returncode or not line: sys.exit(f'[RED] pso_replay failed ({r.returncode}):\n{r.stderr[-3000:]}')
    return line


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('harvest', nargs='+', help='pso_user.tsv files of harvest runs (their R records)')
    a.add_argument('--map', required=True); a.add_argument('--pairs', help='shader_pairs.tsv (used with --table)'); a.add_argument('--refl', required=True, help='the Mac b-<V> folder (json + MSL)')
    a.add_argument('--per-pair', type=int, default=2, help='state combinations per shader pair (default 2)')
    a.add_argument('--max-pipelines', type=int, default=1 << 30)
    a.add_argument('--max-bytes', type=float, default=256e6, help='archive byte cap at %d bytes per pipeline (default 256 MB)' % BYTES_PER_PIPELINE)
    a.add_argument('--no-groups', action='store_true', help='leave out the other variations of the shader files the harvest paired')
    a.add_argument('--table', action='store_true', help='add the static pair table (only worth it where the table holds the pairs the game draws, see the doc)')
    a.add_argument('--holdout', type=float, help='evaluate: train on this fraction of the records (in harvest order), report how much of the rest the expansion predicts')
    a.add_argument('-o', help='manifest to write'); a.add_argument('--build', metavar='HARVEST', help='also replay the manifest into this harvest archive (env DM_NVN_SHMAP, DM_MSL_DIR)')
    a.add_argument('--check', metavar='ARCHIVE', help='replay the manifest against a macOS archive: every record must hit')
    o = a.parse_args()
    recs, stage = read_records(o.harvest)
    if not recs: sys.exit('[RED] no R records in ' + ' '.join(o.harvest))
    facts, smap, table = Facts(o.refl), read_map(o.map), read_pairs(o.pairs) if o.table else []
    cap = int(min(o.max_pipelines, o.max_bytes / BYTES_PER_PIPELINE))
    if o.holdout:
        n = int(len(recs) * o.holdout); train, test = recs[:n], set(recs[n:]) - set(recs[:n])
        voc = Vocab(train, facts); out, tiers = expand(voc, candidates(voc, smap, table, stage, not o.no_groups), stage, o.per_pair, cap)
        got = test & set(out)
        old = {b for b in test if keys(b)[:2] in voc.pairs}
        tp = {keys(b)[:2] for b in test}; op = {keys(b)[:2] for b in out}
        print(f'holdout: train {len(train)} records, test {len(test)} new records; expansion {len(out)} pipelines ({dict(tiers)});'
              f' predicts {len(got)} of {len(test)} new records ({100 * len(got) / max(1, len(test)):.0f}%): {len(got & old)} of the {len(old)} whose pair the train drew,'
              f' {len(got - old)} of the {len(test - old)} with a new pair; pairs: {len(tp & op)} of {len(tp)} test pairs are candidates')
        return
    voc = Vocab(recs, facts)
    out, tiers = expand(voc, candidates(voc, smap, table, stage, not o.no_groups), stage, o.per_pair, cap)
    skipped = sum(1 for b in recs if special(b))
    print(f'harvest: {len(recs)} records, {len(voc.pairs)} pairs, {len({rt_part(b) for b in recs})} render-target parts, {len({vx_part(b) for b in recs})} vertex parts,'
          f' {skipped} merged / specialized kept as is; expansion: {len(out)} pipelines ({dict(tiers)}), about {len(out) * BYTES_PER_PIPELINE / 1e6:.0f} MB')
    man = o.o or (o.build + '.tsv' if o.build else o.check + '.tsv' if o.check else None)
    if not man: return
    with open(man, 'w') as f:
        f.write('# pipeline manifest (dm/gfx/tools/dmsh_psoexpand.py): harvest records + expansion, pso_user.tsv format\n')
        for b in out: f.write('R\t' + b.hex() + '\n')
    if o.build:
        if os.path.exists(o.build): os.unlink(o.build)   # a fresh harvest: an old one would keep pipelines this manifest no longer has
        print(replay(os.path.abspath(man), {'DM_PSO_HARVEST': os.path.abspath(o.build), 'DM_PSO_ARCHIVE': 'off'}))
    if o.check:
        line = replay(os.path.abspath(man), {'DM_PSO_ARCHIVE': os.path.abspath(o.check)})
        print(line)
        m = re.search(r'archive (\d+) hits / (\d+) misses', line)
        moved = relinked_away(out, o.refl)
        want = sum(1 for b in out if {k for k in keys(b)[:2] if k} & moved)
        logged = {tuple(x) for x in re.findall(r'miss #\d+: render pipeline vertex (\S+) fragment (\S+)', text(os.path.abspath(man) + '.log'))}
        odd = {p for p in logged if not set(p) & moved}
        print(f'archive check: {m and m.group(2)} misses, {want} expected (records using one of {len(moved)} libraries whose relink gives other function hashes,'
              f' left out by dmsh_psoarch.py); unexpected among the logged misses: {len(odd)}')
        if not m or int(m.group(2)) != want or odd: sys.exit('[RED] archive check: misses beyond the left-out libraries (a key differs from what the runtime looks up)')


if __name__ == '__main__':
    main()
