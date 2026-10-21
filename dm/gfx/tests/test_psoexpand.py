#!/usr/bin/env python3
"""Pipeline expansion (tools/dmsh_psoexpand.py) on synthetic records, no game files: the record layout matches the C struct, state parts move between shaders only where
pso_key_fill would produce them, the candidate tiers and caps behave, and the varying / colour-type filters keep illegal pairs out."""
import os, sys, json, struct, tempfile, subprocess, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../tools'))
import dmsh_psoexpand as X

LAYOUT_C = r'''
#include <stdio.h>
#include <stddef.h>
typedef struct { int stage; char key[24]; } NvShader;
#include "nvn_pso_skey.h"
int main(void) {
    printf("%zu %zu %zu %zu %zu %zu %zu\n", sizeof(pso_skey), offsetof(pso_skey, k), offsetof(pso_key, cfmt), offsetof(pso_key, attr), offsetof(pso_key, stream), offsetof(pso_key, lmap), offsetof(pso_key, fsfn));
    return 0;
}
'''


def rt(cfmt0, blend0=0, dfmt=260, sfmt=260, chmask=0xffffffff):
    """A render-target part as X.rt_part lays it out: merged / fz / fz_desc + pad (38 bytes), cfmt .. blend[8] (120), lmap (8)"""
    k = struct.pack('<8I6I8Q', cfmt0, *[0] * 7, dfmt, sfmt, 1, 1 if blend0 else 0, chmask, 0, blend0, *[0] * 7)
    return bytes(38) + k + bytes(8)


def vx(attrs, streams):
    """attrs {index: (fmt, offset, stream)}, streams {index: (stride, divisor)}"""
    a = [0] * 16; s = [0] * 32
    for i, (f, o, st) in attrs.items(): a[i] = f | o << 8 | st << 27
    for i, (stride, div) in streams.items(): s[2 * i], s[2 * i + 1] = stride, div
    return struct.pack('<16I32I', *a, *s)


class Expand(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); d = self.d = self.tmp.name
        # four vertex shaders, four pixel shaders; v3 reads only attribute 0; f3 writes an integer colour; f4 reads a varying no vertex shader writes
        sh = {'v1': ([0, 1], 'vs', [0]), 'v2': ([0, 1], 'vs', [0]), 'v3': ([0], 'vs', [0]), 'v9': ([0, 1], 'vs', [0]),
              'f1': ([], 'ps', [0]), 'f2': ([], 'ps', [0]), 'f3': ([], 'ps', [0]), 'f4': ([], 'ps', [0, 5])}
        for k, (ins, st, locs) in sh.items():
            json.dump({'stage': st, 'vertex_inputs': [{'location': l, 'msl_type': 'float4'} for l in ins], 'raster': {'colors': [0]} if st == 'ps' else {}},
                      open(os.path.join(d, k + 'xxxxxxxxxxxxxx_b.json'), 'w'))
            u = ''.join(f'    float4 m_{l} [[user(locn{l})]];\n' for l in locs)
            col = '    uint4 m_c [[color(0)]];\n' if k == 'f3' else '    float4 m_c [[color(0)]];\n'
            body = (f'struct main0_out\n{{\n{u}    float4 gl_Position [[position]];\n}};\n' if st == 'vs' else f'struct main0_out\n{{\n{col}}};\n\nstruct main0_in\n{{\n{u}}};\n')
            open(os.path.join(d, k + 'xxxxxxxxxxxxxx_b.metal'), 'w').write(body)
        self.k = {k: k + 'xxxxxxxxxxxxxx_b' for k in sh}
        rows = ['package\tindex\tstage\tdm_ctl_sha16\tsource']
        for k in sh:
            grp = '/a.pak#vfile' if k[0] == 'v' and k != 'v9' else '/a.pak#pfile' if k[0] == 'f' else '/b.pak#other'
            rows.append(f'p\t0\t{"vertex" if k[0] == "v" else "pixel"}\t{k}xxxxxxxxxxxxxx\t{grp}#BNSH@0x0#var{k[1]}')
        self.map = os.path.join(d, 'shader_map.tsv'); open(self.map, 'w').write('\n'.join(rows) + '\n')
        self.A, self.B = rt(92), rt(115, blend0=0x481040410)
        self.X = vx({0: (0x19, 0, 0), 1: (0x13, 12, 0)}, {0: (20, 0)})
        rec = lambda v, f, r, x: X.compose(self.k[v], 0, self.k[f], 1, r, x)
        self.harvest = [rec('v1', 'f1', self.A, self.X), rec('v1', 'f2', self.B, self.X)]
        self.tsv = os.path.join(d, 'pso_user.tsv')
        open(self.tsv, 'w').write(''.join(f'S\t{self.k[s]}\t{i}\n' for s, i in (('v1', 0), ('f1', 1))) + ''.join('R\t' + b.hex() + '\n' for b in self.harvest))

    def tearDown(self): self.tmp.cleanup()

    def run_expand(self, table=()):
        recs, stage = X.read_records([self.tsv])
        facts = X.Facts(self.d); voc = X.Vocab(recs, facts)
        return X.expand(voc, X.candidates(voc, X.read_map(self.map), list(table), stage), stage, 2, 1000)

    def test_layout_matches_the_c_structs(self):
        src = os.path.join(self.d, 'layout.c'); exe = os.path.join(self.d, 'layout')
        hdr = os.path.join(HERE, '../nvn')
        open(src, 'w').write(LAYOUT_C)
        r = subprocess.run(['clang', '-x', 'c', '-I', hdr, '-I', os.path.join(hdr, 'include'), src, '-o', exe], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        size, k, cfmt, attr, stream, lmap, fsfn = map(int, subprocess.run([exe], capture_output=True, text=True).stdout.split())
        self.assertEqual((size, k), (X.SKEY, X.KOFF))
        self.assertEqual((X.KOFF + cfmt, X.KOFF + attr, X.KOFF + stream, X.KOFF + lmap, X.KOFF + fsfn), (X.RT[1][0], X.VX[0], X.VX[0] + 64, X.RT[2][0], X.PTRS[1][0]))

    def test_compose_round_trips_the_parts(self):
        b = self.harvest[0]
        self.assertEqual(len(b), X.SKEY)
        self.assertEqual(X.keys(b), (self.k['v1'], self.k['f1'], 0, 1))
        self.assertEqual((X.rt_part(b), X.vx_part(b)), (self.A, self.X))
        vs, fs, vst, fst = X.keys(b)
        self.assertEqual(X.compose(vs, vst, fs, fst, X.rt_part(b), X.vx_part(b)), b)

    def test_restrict_drops_unread_attributes_and_their_streams(self):
        x = vx({0: (0x19, 0, 0), 1: (0x13, 0, 1)}, {0: (12, 0), 1: (8, 1)})
        self.assertEqual(X.restrict(x, {0}), vx({0: (0x19, 0, 0)}, {0: (12, 0)}))
        self.assertEqual(X.restrict(x, {0, 1}), x)

    def test_group_variations_get_the_learned_states(self):
        out, tiers = self.run_expand()
        got = {(X.keys(b)[0], X.keys(b)[1], X.rt_part(b), X.vx_part(b)) for b in out}
        self.assertEqual(out[:2], self.harvest)   # harvest records first, unchanged
        self.assertIn((self.k['v2'], self.k['f1'], self.A, self.X), got)   # same file group, same inputs: the vertex part moves as is
        self.assertIn((self.k['v3'], self.k['f1'], self.A, X.restrict(self.X, {0})), got)   # fewer inputs: the wider layout restricted, as pso_key_fill would fill it
        self.assertIn((self.k['v1'], self.k['f1'], self.B, self.X), got)   # a harvested pair gets the other state its vertex shader drew
        self.assertFalse(any(k[1] == self.k['f3'] for k in got))   # integer colour output: no float render-target state fits it, so no pipeline
        self.assertFalse(any(k[1] == self.k['f4'] for k in got))   # reads varying 5, which no vertex shader writes
        self.assertFalse(any(k[0] == self.k['v9'] for k in got))   # another container group, not paired by the harvest
        self.assertEqual(len(got), len(out))

    def test_table_tier_and_caps(self):
        out, tiers = self.run_expand(table=[('v9xxxxxxxxxxxxxx', 'f2xxxxxxxxxxxxxx')])
        self.assertTrue(any(X.keys(b)[:2] == (self.k['v9'], self.k['f2']) for b in out))
        self.assertGreater(tiers['table'], 0)
        recs, stage = X.read_records([self.tsv]); voc = X.Vocab(recs, X.Facts(self.d))
        capped, _ = X.expand(voc, X.candidates(voc, X.read_map(self.map), [], stage), stage, 2, 3)
        self.assertEqual(len(capped), 3); self.assertEqual(capped[:2], self.harvest)

    def test_cli_writes_a_pso_user_manifest(self):
        man = os.path.join(self.d, 'm.tsv')
        r = subprocess.run([sys.executable, os.path.join(HERE, '../tools/dmsh_psoexpand.py'), self.tsv, '--map', self.map, '--refl', self.d, '-o', man, '--max-pipelines', '4'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = [l for l in open(man) if not l.startswith('#')]
        self.assertEqual(len(lines), 4)
        self.assertTrue(all(l.startswith('R\t') and len(l.strip()) == 2 + 2 * X.SKEY for l in lines))


if __name__ == '__main__':
    unittest.main()
