"""build_ipa_from_nsp.pack_shaders: the NSP build packs the Mac and iOS shader libraries (dmsh_pack.py) and reuses the packs while the shader stage's key, the tools and the profile are unchanged.
Two stand-in shaders in a stand-in shader folder (no game files); needs xcrun metal. Run: python3 -I scripts/tests/test_pack_shaders.py"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_ipa_from_nsp as b

V = 'abc123abc123'
RECORD = 'xcrun -sdk macosx metal -c -fpreserve-invariance; xcrun -sdk macosx metallib'   # dmsh_build.py's Mac record: the compile line dmsh_pack.py repeats
KEYS = ('00000000000000a1_b', '00000000000000b2_b')


def libs(d):   # a chain folder as dmsh_build.py leaves it: <key>_b.metal / .metallib / .json
    d.mkdir(parents=True)
    cc, ln = (shlex.split(x) for x in RECORD.split(';'))
    for k in KEYS:
        src = d / f'{k}.metal'; src.write_text('#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1, 0, 0, 1); }\n')
        subprocess.run([*cc, src, '-o', f'{src}.air'], check=True, capture_output=True)
        subprocess.run([*ln, f'{src}.air', '-o', d / f'{k}.metallib'], check=True, capture_output=True)
        os.unlink(f'{src}.air')
        (d / f'{k}.json').write_text(json.dumps({'key': k, 'chain': V, 'stage': 'ps', 'entry': 'main0', 'bindings': [], 'chain_metal': RECORD}))


class PackShaders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = Path(__file__).resolve().parents[2]
        cls.tmp = tempfile.TemporaryDirectory(); cls.root = Path(cls.tmp.name)
        cls.sh, cls.gd = cls.root / 'shader', cls.root / 'profile'
        libs(cls.sh / 'cache' / f'b-{V}'); libs(cls.sh / 'ios' / f'b-{V}')
        cls.gd.mkdir()
        (cls.gd / 'dmsh_chain.h').write_text(f'#define DMSH_CHAIN "{V}"\n')
        (cls.gd / 'shader_map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\tsource\n' + ''.join(f'x.bin\t0\tpixel\t{k[:16]}\t/x.pak#0\n' for k in KEYS))
        (cls.gd / 'pso_manifest.tsv').write_text('# empty seed list\n')
        cls.g = types.SimpleNamespace(dir=cls.gd, table=lambda n: cls.gd / n)

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def setUp(self):
        for d in (self.sh / 'cache', self.sh / 'ios'):
            for p in (d / f'b-{V}' / 'pack', d / f'b-{V}.pack.key'): b.rmtree(p)
        self.calls = []
        real = b.run
        def run(cmd, log, **kw): self.calls.append(Path(str(cmd[1])).name); real(cmd, log, **kw)
        b.run = run; self.addCleanup(setattr, b, 'run', real)

    def pack(self, ios_key='K1'):
        kf = self.sh / 'ios' / f'b-{V}.key'
        if ios_key: kf.write_text(f'{ios_key}\nnote\n')
        else: b.rmtree(kf)
        b.pack_shaders(sys.executable, self.repo, self.sh, dict(os.environ, J='1'), self.root / 'logs', self.g)

    def index(self, side): return [l.split('\t')[0] for l in (self.sh / side / f'b-{V}' / 'pack' / 'index.tsv').read_text().splitlines() if not l.startswith('#')]

    def test_packs_the_mac_and_the_ios_libraries(self):
        self.pack()
        self.assertEqual(self.calls, ['dmsh_pack.py'] * 2)
        for side in ('cache', 'ios'): self.assertEqual(sorted(self.index(side)), list(KEYS))

    def test_reuses_the_packs_while_the_inputs_are_unchanged(self):
        self.pack(); self.calls.clear()
        self.pack()
        self.assertEqual(self.calls, [])

    def test_repacks_when_the_shader_stage_key_changes(self):
        self.pack(); self.calls.clear()
        self.pack('K2')
        self.assertEqual(self.calls, ['dmsh_pack.py'] * 2)

    def test_repacks_when_a_pack_is_missing(self):
        self.pack(); self.calls.clear()
        os.unlink(self.sh / 'ios' / f'b-{V}' / 'pack' / 'index.tsv')
        self.pack()
        self.assertEqual(self.calls, ['dmsh_pack.py'] * 2)

    def test_never_reuses_without_a_shader_stage_key(self):   # a provisional profile or damaged files: the iOS stage keeps no key either
        self.pack(None); self.calls.clear()
        self.pack(None)
        self.assertEqual(self.calls, ['dmsh_pack.py'] * 2)


if __name__ == '__main__': unittest.main()
