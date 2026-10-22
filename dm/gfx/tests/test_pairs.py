#!/usr/bin/env python3
# dmsh_pairs.py rule split, no game files: entries in container order as shader_split.py lists them (where, stage, key)
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../tools'))
import dmsh_pairs as P

f = lambda b, v, st, k: (f'/a.gfpak#{b}#BNSH@0x0#var{v}', st, k)
found = [
    f('m0fsh', 0, 'ps', 'P0'), f('m0vsh', 0, 'vs', 'V0'),                                   # one material: fsh then vsh, one variation each
    f('m1fsh', 0, 'ps', 'P1'), f('m1fsh', 1, 'ps', 'P2'), f('m1vsh', 0, 'vs', 'V1'),        # 2 pixel variations, 1 vertex: every combination
    f('both', 0, 'vs', 'V9'), f('both', 0, 'ps', 'P9'),                                     # both stages in one variation: shader_pairs.tsv's job, not this rule
    f('m2vsh', 0, 'vs', 'V2'), f('m2fsh', 0, 'ps', 'P3'),                                   # vertex file first: not a split program
    f('m3fsh', 0, 'ps', 'P4'), f('m3fsh', 1, 'ps', 'P5'), f('m3vsh', 0, 'vs', 'V3'), f('m3vsh', 1, 'vs', 'V4'),   # equal counts: by index
]
got = P.split_pairs(found)
want = {('V0', 'P0'), ('V1', 'P1'), ('V1', 'P2'), ('V3', 'P4'), ('V4', 'P5')}
assert got == want, (sorted(got), sorted(want))
assert P.tfx_pairs(b'not a tinyeffect object') == set()
# --coverage: shaders of the map in some pair, per stage (compute shaders do not count)
import tempfile
with tempfile.NamedTemporaryFile('w', suffix='.tsv', delete=False) as m:
    m.write('package\tindex\tstage\tdm_ctl_sha16\tsource\n' + ''.join(f'p\t0\t{st}\t{k}\tx\n' for st, k in
            [('vertex', 'V0'), ('vertex', 'V8'), ('pixel', 'P0'), ('pixel', 'P1'), ('pixel', 'P7'), ('compute', 'C0')]))
assert P.coverage(got, m.name) == (1, 2, 2, 3), P.coverage(got, m.name)
os.unlink(m.name)
# rule iface: shader program headers (sph_io) and the attribute-level subset within WINDOW shader files
import struct
def sph(st, attrs):   # a 0x80-byte code blob whose header writes (vs) or reads (ps, component x only) the given generic attributes
    h = bytearray(0x50); struct.pack_into('<I', h, 0, 1 if st == 'vs' else 2)
    for a in attrs:
        if st == 'vs': n = int.from_bytes(h, 'little') | 0xf << (432 + 4 * a); h = bytearray(n.to_bytes(0x50, 'little'))
        else: h[24 + a] |= 2   # word 6 onwards, one byte per attribute, 2 bits per component: x perspective
    return bytes(0x30) + bytes(h)
assert P.sph_io(sph('vs', [0, 2]), 'vs') == 0xf | 0xf << 8 and P.sph_io(sph('ps', [2]), 'ps') == 1 << 8
assert P.sph_io(sph('ps', [1]), 'vs') is None   # a pixel header read as a vertex shader's
g = lambda b, st, k, attrs: (f'/a.gfpak#{b}#BNSH@0x0#var0', st, k, P.sph_io(sph(st, attrs), st))
found = [g('f0', 'vs', 'VA', [0, 1, 2]), g('f1', 'ps', 'PA', [1, 2]), g('f2', 'ps', 'PB', [3]), g('f3', 'vs', 'VB', [3]), g('f9', 'ps', 'PC', [0])]
got = P.iface_pairs(found)
assert got == {('VA', 'PA'), ('VB', 'PB')}, sorted(got)   # PB: VA lacks attribute 3; PC: VA 4 files away
print('PAIRS OK split rule', len(want), 'pairs, iface rule', len(got), 'pairs, coverage')
