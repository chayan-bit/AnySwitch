#!/usr/bin/env python3
# Program pairs (vertex shader, pixel shader) a game can draw with, recovered from its files without playing, for precompiling pipelines (dm/gfx/README.md, pipeline coverage).
# shader_split.py's pair table (shader_pairs.tsv) pairs the stages of one BNSH variation (and Unity programs, MSHD, SDF, single-stage covers); that misses programs whose stages live in separate files:
#   rule split: a BNSH holding only pixel stages directly followed, in container order, by a BNSH holding only vertex stages is one program kept as two files (<name>.bnsh_fsh then <name>.bnsh_vsh
#     in Game Freak's GFLXPACK, where the pack lists a material's two shader files next to each other); variations pair by index when both files have as many, else every combination.
#     A container is one .gfpak (files in pack order) or one folder of loose files (in name order).
#   rule tfx: a TinyEffect object (Silicon Studio's YEBIS, kept zlib-compressed in main, see shader_split.zlib_streams) names every technique's vertex and pixel program in its text header
#     ("tech_<name>,<vertex program>,<n>,<pixel program>,<n>"); a table of 256-byte name records lists the programs in the order their GLSLC outputs follow.
#   rule iface (generic, no packer convention): a vertex shader and a pixel shader pair when every generic attribute the pixel shader reads is one the vertex shader writes, both read
#     from the Maxwell shader program header (sph_io), and their shader files are at most one apart in container order (WINDOW). Needs no names; it over-pairs (any linkable
#     neighbours), so its pairs rank after the other rules' in the archive. A container is a .gfpak, a folder of loose files, main or one zlib object in main.
#     Attribute level, not component level: a pixel shader may read a component the vertex shader leaves unwritten.
# split and tfx are accelerators for formats they know; iface is the generic rule. Every rule is keyed by container format, never by title.
# Game-agnostic: the rules read container formats, never a title's names. Output (gitignored build output, keys of game shaders): <vertex key> <TAB> <pixel key> <TAB> <rule> per line.
# Usage: DM_GAME=<id> dmsh_pairs.py <RomFS> <ExeFS main> <out.tsv> [--table shader_pairs.tsv] [--coverage shader_map.tsv] [--reuse] [--check pso_user.tsv ...]   (needs lz4: nix-shell -p 'python3.withPackages(ps:[ps.lz4])')
#   --check: how many of the shader pairs and records of real runs (pso_user*.tsv R records) the pairs cover, per rule
#   --coverage shader_map.tsv: the harvest-free self-check build_ipa.sh prints: how many of the title's vertex and pixel shaders are in some pair. A shader in no pair can never be precompiled
#     (a title whose packer the rules do not know shows up here as low coverage, before anyone plays it)
import os, re, sys, struct, argparse, collections, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shader_split as SS

GFLX = b'GFLXPACK'


def sph_io(code, st):
    """Generic attribute components a shader passes on, from the Maxwell shader program header (0x50 bytes at code +0x30, NVIDIA's documented SPH): a vertex shader's outputs
    (OmapGenericVector, header bits 432-559, 4 component bits per attribute), a pixel shader's inputs (ImapGenericVector, words 6-13, 2 interpolation bits per component, non-zero = read;
    Ryujinx ShaderHeader.ImapTypes). As an int: attribute i component c = bit 4i+c. None: no header (compute, other stages, a header of another type)"""
    if st not in ('vs', 'ps') or len(code) < 0x80: return None
    w = struct.unpack_from('<20I', code, 0x30)
    if (w[0] & 0x1f) != (1 if st == 'vs' else 2): return None   # SPH type 1 = vertex / tessellation / geometry, 2 = pixel
    if st == 'vs': return int.from_bytes(code[0x30:0x80], 'little') >> 432 & (1 << 128) - 1
    m = 0
    for i in range(32):
        b = (w[6 + i // 4] >> (8 * (i % 4))) & 0xff
        for c in range(4):
            if b >> (2 * c) & 3: m |= 1 << (4 * i + c)
    return m


WINDOW = 1   # shader files apart in container order: the whole container gives orders of magnitude more candidates for few more real pairs


def iface_pairs(found):
    """rule iface (see the header). A shader file is a BNSH (its variations together) or a loose file"""
    att = lambda x: sum(1 << i for i in range(32) if x >> (4 * i) & 0xf)   # attributes with any component
    order, at = {}, collections.defaultdict(lambda: ([], []))
    for w, st, k, io in found:
        if st not in ('vs', 'ps') or io is None: continue
        i = order.setdefault(w.rpartition('#var')[0] or w, len(order))
        at[i][st == 'ps'].append((k, att(io)))
    return {(v, p) for j, (_, ps) in list(at.items()) for p, pi in ps for d in range(-WINDOW, WINDOW + 1) for v, vo in at.get(j + d, ([], []))[0] if not pi & ~vo}


def bnsh_list(found):
    """[(BNSH label, {variation: {stage: key}})] in container order, from (where, stage, key, ...) entries"""
    out, at = [], {}
    for where, st, key, *_ in found:
        if '#BNSH@' not in where or '#var' not in where: continue
        b, _, v = where.rpartition('#var')
        if b not in at: at[b] = len(out); out.append((b, {}))
        out[at[b]][1].setdefault(int(v), {})[st] = key
    return out


def split_pairs(found):
    """rule split (see the header)"""
    out, bl = set(), bnsh_list(found)
    stages = lambda vs: {s for v in vs.values() for s in v}
    for (_, ps), (_, vs) in zip(bl, bl[1:]):
        if stages(ps) != {'ps'} or stages(vs) != {'vs'}: continue
        if len(ps) == len(vs): out |= {(vs[i]['vs'], ps[i]['ps']) for i in ps if i in vs}
        else: out |= {(v['vs'], p['ps']) for v in vs.values() for p in ps.values()}
    return out


def tfx_pairs(d):
    """rule tfx (see the header); an object that does not check out gives nothing"""
    if not d.startswith(b'.tfxo file'): return set()
    outs = sorted(SS.glslc_shaders(d, 'tfx', need=False), key=lambda o: int(o[0].rsplit('@', 1)[1], 16))
    if not outs: return set()
    first = int(outs[0][0].rsplit('@', 1)[1], 16)
    names = [n.decode() for n in re.findall(rb'\\([A-Za-z0-9_]+)\.[vp]so\0', d[:first])]
    if len(names) != len(outs) or any((n[:3] == 'vs_') != (o[1] == 'vs') for n, o in zip(names, outs)):
        print(f'[RED] TinyEffect object: {len(names)} program names for {len(outs)} GLSLC outputs (or stages disagree): no pairs from it', file=sys.stderr); return set()
    key = {n: SS.skey(o[2], o[3]) for n, o in zip(names, outs)}
    head = d[:d.find(b'GlobalParameter:')].decode('latin1')
    techs = [l.split(',') for l in head.split('\n') if l.startswith('tech_') and l.count(',') >= 4]
    return {(key[t[1]], key[t[3]]) for t in techs if t[1] in key and t[3] in key}


def scan(job):
    """one file → (container, [(where, stage, key, sph_io)] in order)"""
    path, rel = job
    found = []
    with open(path, 'rb') as f: head = f.read(8)
    if head == GFLX: SS.gfpak_shaders(path, rel, found); cont = rel
    else:
        d = open(path, 'rb').read()
        if b'BNSH\0\0\0\0' not in d and d[:4] != b'Yaz0' and not (d[:4] == b'SARC' and b'Yaz0' in d): return rel, []   # as shader_split.scan_file
        SS.scan_blob(d, '/' + rel, found); cont = os.path.dirname(rel)
    return cont, [(w, st, SS.skey(c, k), sph_io(k, st)) for w, st, c, k in found]


def find_pairs(romfs, main, jobs):
    files = sorted((os.path.join(dp, f), os.path.relpath(os.path.join(dp, f), romfs)) for dp, _, fs in os.walk(romfs) for f in fs)
    by = collections.defaultdict(list)
    with cf.ProcessPoolExecutor(jobs) as ex:
        for cont, found in ex.map(scan, files, chunksize=16): by[cont] += found   # files of one folder arrive in name order
    img = SS.nso_image(main)
    glslc = lambda d, label: [(w, st, SS.skey(c, k), sph_io(k, st)) for w, st, c, k in SS.glslc_shaders(d, label, need=False)]
    by['main'] += glslc(img, 'main')
    pairs = collections.defaultdict(set)
    for i, (_, z) in enumerate(SS.zlib_streams(img)):
        for p in tfx_pairs(z): pairs[p].add('tfx')
        by[f'main#zlib{i}'] += glslc(z, f'main#zlib{i}')
    for found in by.values():
        for r, f in RULES:
            for p in f(found): pairs[p].add(r)
    return pairs


RULES = [('split', split_pairs), ('iface', iface_pairs)]   # container rules; tfx reads main's TinyEffect objects (find_pairs)


def read_records(paths):
    recs = set()
    for p in paths:
        for line in open(p):
            c = line.rstrip('\n').split('\t')
            if c[0] == 'R' and len(c) > 1 and len(c[1]) == 864: recs.add(bytes.fromhex(c[1]))
    key = lambda b, o: b[o:o + 24].rstrip(b'\0').decode()[:16]
    return [(key(b, 0), key(b, 24)) for b in recs]


def check(pairs, table, lists):
    recs = read_records(lists)
    real = {p for p in recs if p[1]}; vonly = {p[0] for p in recs if not p[1]}
    rules = collections.defaultdict(set)
    for p, rs in pairs.items():
        for r in rs: rules[r].add(p)
    rules['table'] = table
    every = set().union(*rules.values())
    for r, s in sorted(rules.items()): print(f'rule {r}: {len(s)} pairs, {len(real & s)} of the {len(real)} real pairs')
    vs_all = {v for v, _ in every}
    print(f'all rules: {len(every)} pairs, {len(real & every)} of {len(real)} real pairs ({100 * len(real & every) / max(1, len(real)):.1f}%); '
          f'vertex-only: {len(vonly & vs_all)} of {len(vonly)} real vertex-only shaders are vertex shaders of a pair ({len(vs_all)} such shaders)')
    hit = sum(1 for p in recs if (p in every if p[1] else p[0] in vs_all))
    print(f'records keyed by their pair: {hit} of {len(recs)} ({100 * hit / max(1, len(recs)):.1f}%)')


def coverage(pairs, shmap):
    """(vertex shaders in a pair, vertex shaders, pixel shaders in a pair, pixel shaders) of the shader map"""
    st = {}
    for l in open(shmap):
        c = l.rstrip('\n').split('\t')
        if len(c) > 3 and c[2] in ('vertex', 'pixel'): st[c[3]] = c[2]
    vs, fs = {v for v, _ in pairs}, {f for _, f in pairs}
    nv = sum(1 for k, s in st.items() if s == 'vertex'); nf = len(st) - nv
    return sum(1 for k, s in st.items() if s == 'vertex' and k in vs), nv, sum(1 for k, s in st.items() if s == 'pixel' and k in fs), nf


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('romfs'); a.add_argument('main'); a.add_argument('out')
    a.add_argument('--table', help="shader_split.py's shader_pairs.tsv (for --check)"); a.add_argument('--check', nargs='*', default=[])
    a.add_argument('--coverage', help='shader_map.tsv: print how many of its vertex / pixel shaders are in a pair')
    a.add_argument('-j', type=int, default=int(os.environ.get('J', '8')))
    a.add_argument('--reuse', action='store_true', help='keep <out.tsv> when it is newer than this tool and shader_split.py (the pairs depend only on the game files and the rules)')
    o = a.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    fresh = o.reuse and os.path.exists(o.out) and os.path.getmtime(o.out) > max(os.path.getmtime(os.path.join(here, f)) for f in ('dmsh_pairs.py', 'shader_split.py'))
    if fresh:
        pairs = {}
        for l in open(o.out):
            if not l.startswith('#'): v, p, rs = l.rstrip('\n').split('\t'); pairs[(v, p)] = set(rs.split(','))
    else:
        pairs = find_pairs(o.romfs, o.main, o.j)
        with open(o.out + '.tmp', 'w') as f:
            f.write('# program pairs from container rules (dm/gfx/tools/dmsh_pairs.py): vertex key <TAB> pixel key <TAB> rules\n')
            for (v, p), rs in sorted(pairs.items()): f.write(f'{v}\t{p}\t{",".join(sorted(rs))}\n')
        os.replace(o.out + '.tmp', o.out)
    print(f'{"kept" if fresh else "wrote"} {o.out}: {len(pairs)} pairs (' + ', '.join(f'{r} {n}' for r, n in collections.Counter(r for rs in pairs.values() for r in rs).most_common()) + ')')
    table = {tuple(l.split()[:2]) for l in open(o.table) if l.strip() and not l.startswith('#')} if o.table and os.path.exists(o.table) else set()
    if o.coverage:
        pairs_all = set(pairs) | table
        accel = {p for p, rs in pairs.items() if rs - {'iface'}} | table
        for what, ps in (('all pairs', pairs_all), ('accelerators (split, tfx, same-variation table)', accel), ('generic rule alone (iface)', {p for p, rs in pairs.items() if 'iface' in rs})):
            cv, nv, cf, nf = coverage(ps, o.coverage)
            print(f'coverage, {what}: {cv} of {nv} vertex shaders ({100 * cv / max(1, nv):.1f}%) and {cf} of {nf} pixel shaders ({100 * cf / max(1, nf):.1f}%) are in a pair'
                  + ('' if ps is not pairs_all or cv + cf >= 0.9 * (nv + nf) else ' [RED] low: shaders in no pair compile on first use'))
        print('coverage: a shader in a pair is necessary, not sufficient (the pairing of one BNSH variation is often not the one drawn); the device log (pso-flex hits / misses) measures the real coverage')
    if o.check: check(pairs, table, o.check)


if __name__ == '__main__':
    main()
