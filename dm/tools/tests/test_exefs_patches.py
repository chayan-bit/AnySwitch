"""ExeFS patch loader: IPS / IPS32 / .pchtxt parsing and conflict rules (pure Python), and patch_nso.py end to end on a synthetic NSO (needs lz4 and capstone).
No game data: every NSO and patch file here is built in memory. Run: python3 -I dm/tools/tests/test_exefs_patches.py"""
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import exefs_patches as ep

BID = 'a1b2c3d4e5f60718293a4b5c6d7e8f91'   # 16 bytes; the NSO header's module ID is this plus 16 zero bytes
NOP, MOV_X1_X18, SVC_1, RET = 0xD503201F, 0xAA1203E1, 0xD4000021, 0xD65F03C0
FN = 0x200   # the synthetic function: nop, nop, nop, ret
H = ep.NSO_HEADER


def ips(recs, wide=False):
    out = b'IPS32' if wide else b'PATCH'
    for off, data in recs:
        out += off.to_bytes(4 if wide else 3, 'big')
        if isinstance(data, tuple): out += b'\0\0' + data[0].to_bytes(2, 'big') + bytes([data[1]])   # RLE: (count, byte)
        else: out += len(data).to_bytes(2, 'big') + data
    return out + (b'EEOF' if wide else b'EOF')


def word(w): return struct.pack('<I', w)


def synthetic_nso():
    """text 0x1000 (one function at FN with its FDE, MOD0 at 0x100), ro 0x1000 (eh_frame_hdr, eh_frame), data 0x1000; uncompressed"""
    text, ro, data = bytearray(0x1000), bytearray(0x1000), bytearray(0x1000)
    text[0:4] = word(0x14000000 | 0x40)   # b +0x100
    text[4:8] = word(0x100)               # MOD0 offset
    for i, w in enumerate((NOP, NOP, NOP, RET)): text[FN + 4 * i:FN + 4 * i + 4] = word(w)
    mod0, hdr, eh = 0x100, 0x1000, 0x1040
    text[mod0:mod0 + 4] = b'MOD0'
    struct.pack_into('<iiiiii', text, mod0 + 4, 0, 0, 0, hdr - mod0, hdr + 0x40 - mod0, 0)   # eh_frame_hdr start, end
    # CIE at eh: length, id 0, version 1, "zR", code align 4, data align -8, return register 30, aug length 1, FDE encoding pcrel sdata4
    cie = struct.pack('<IIB', 0x14, 0, 1) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + b'\0' * 7
    ro[eh - 0x1000:eh - 0x1000 + len(cie)] = cie
    fde_at = eh + len(cie)
    fde = struct.pack('<II', 0x14, fde_at + 4 - eh) + struct.pack('<ii', FN - (fde_at + 8), 16) + b'\0' * 8
    ro[fde_at - 0x1000:fde_at - 0x1000 + len(fde)] = fde
    # eh_frame_hdr: version 1, eh_frame_ptr pcrel sdata4, count udata4, table datarel sdata4; one (function, FDE) pair
    struct.pack_into('<BBBBiIii', ro, hdr - 0x1000, 1, 0x1B, 0x03, 0x3B, eh - (hdr + 4), 1, FN - hdr, fde_at - hdr)
    nso = bytearray(H)
    nso[0:4] = b'NSO0'
    for i, (fo, mo, sz) in enumerate(((H, 0, 0x1000), (H + 0x1000, 0x1000, 0x1000), (H + 0x2000, 0x2000, 0x1000))):
        struct.pack_into('<III', nso, 0x10 + 0x10 * i, fo, mo, sz)
        struct.pack_into('<I', nso, 0x60 + 4 * i, sz)
    nso[0x40:0x40 + 16] = bytes.fromhex(BID)
    return bytes(nso + text + ro + data)


class Parse(unittest.TestCase):
    def test_ips_copy_and_rle(self):
        self.assertEqual(ep.parse_ips(ips([(0x300, b'\x01\x02'), (0x400, (3, 0xAA))])), [(0x300, b'\x01\x02'), (0x400, b'\xAA\xAA\xAA')])

    def test_ips32_wide_offsets(self):
        self.assertEqual(ep.parse_ips(ips([(0x01000300, b'\x07')], wide=True)), [(0x01000300, b'\x07')])

    def test_ips_truncated_or_headerless_is_an_error(self):
        with self.assertRaises(ep.PatchError): ep.parse_ips(ips([(0x300, b'\x01\x02')])[:-2])
        with self.assertRaises(ep.PatchError): ep.parse_ips(b'NOTIPS')

    def test_pchtxt_shift_comments_strings_and_sections(self):
        text = (f'@nsobid-{BID.upper()}000000\n\n// title\n@flag offset_shift 0x100\n\n'
                '@enabled\n00000200 1F2003D5 // nop\n00000300 "hi"\n\n'            # a blank line ends the section
                '@disabled\n00000400 AA\n\n'
                '@enabled\n00000500 AA BB\n\n'
                '@disabled\n00000600 CC\n@stop\n@enabled\n00000700 DD\n')
        self.assertEqual(ep.pchtxt_bid(text), BID)
        self.assertEqual(ep.parse_pchtxt(text), [(0x300, word(NOP)), (0x400, b'hi\0'), (0x600, b'\xaa\xbb')])

    def test_pchtxt_bad_line_is_an_error(self):
        with self.assertRaises(ep.PatchError): ep.parse_pchtxt('@nsobid-AA\n@enabled\n0010 XYZ\n')
        with self.assertRaises(ep.PatchError): ep.parse_pchtxt('@nsobid-AA\n@enabled\nZZ 00\n')


class Load(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
    def tearDown(self): self.tmp.cleanup()
    def put(self, rel, data):
        p = self.root / rel; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data if isinstance(data, bytes) else data.encode())
    def load(self, reserved=()): return ep.load(str(self.root), BID + '0' * 32, 0x3000, reserved)

    def test_applies_by_build_id_and_subtracts_the_header(self):
        self.put(f'60fps/{BID.upper()}{"0" * 32}.ips', ips([(H + FN, word(NOP))]))
        self.put(f'60fps/{BID}.ips', ips([(H + 0x2000, b'\x01')]))                    # same ID, short name: also matches
        self.put('60fps/0123456789abcdef0123456789abcdef.ips', ips([(H + 0x10, b'\x09')]))   # another build
        self.put('mod/x.pchtxt', f'@nsobid-{BID}\n@flag offset_shift 0x100\n@enabled\n00000010 AA\n')
        self.put('mod/other.pchtxt', '@nsobid-0123456789abcdef\n@enabled\n00000010 BB\n')
        summary, writes = self.load()
        self.assertEqual([w[:2] for w in writes], [(0x10, b'\xaa'), (FN, word(NOP)), (0x2000, b'\x01')])
        self.assertEqual(sorted(s[0] for s in summary), sorted(['60fps/' + BID.upper() + '0' * 32 + '.ips', f'60fps/{BID}.ips', 'mod/x.pchtxt']))

    def test_errors(self):
        for name, recs, reserved, msg in (
                ('header', [(0xF0, b'\0')], (), 'NSO header'),
                ('end', [(H + 0x2FFF, b'\0\0')], (), 'beyond the image'),
                ('cut', [(H + 0x202, b'\0\0')], [(0x200, 4, 'registered cut')], 'registered cut'),
                ('gate', [(H + 0x1FF, b'\0\0')], [(0x200, 4, 'observation gate')], 'observation gate')):
            with self.subTest(name):
                for f in self.root.glob('*'): f.unlink()
                self.put(f'{BID}.ips', ips(recs))
                with self.assertRaisesRegex(ep.PatchError, msg): self.load(reserved)

    def test_overlap_conflicts_only_when_bytes_differ(self):
        self.put(f'a/{BID}.ips', ips([(H + 0x300, b'\x01\x02\x03')]))
        self.put(f'b/{BID}.ips', ips([(H + 0x301, b'\x02\x03\x04')]))   # agrees on 0x301-0x302
        self.assertEqual(len(self.load()[1]), 2)
        self.put(f'c/{BID}.ips', ips([(H + 0x302, b'\x99')]))
        with self.assertRaisesRegex(ep.PatchError, 'different bytes'): self.load()


@unittest.skipUnless(all(importlib.util.find_spec(m) for m in ('lz4', 'capstone')), 'needs lz4 and capstone')
class Rewriter(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        (self.root / 'patches').mkdir(); (self.root / 'out').mkdir()
        (self.root / 'main.nso').write_bytes(synthetic_nso())
    def tearDown(self): self.tmp.cleanup()

    def run_rewriter(self, patches=True):
        env = {k: v for k, v in os.environ.items() if k != 'DM_EXEFS_PATCHES'}
        if patches: env['DM_EXEFS_PATCHES'] = str(self.root / 'patches')
        return subprocess.run([sys.executable, '-I', str(TOOLS / 'patch_nso.py'), str(self.root / 'main.nso'), str(self.root / 'out'), 'main'], capture_output=True, text=True, env=env)

    def put_ips(self, recs): (self.root / 'patches' / f'{BID}.ips').write_bytes(ips(recs))
    def sites(self):
        rows = [l.split('\t') for l in (self.root / 'out/main.sites.tsv').read_text().splitlines()]
        return {int(r[0], 16): r[1] for r in rows}
    def image_word(self, off): return struct.unpack_from('<I', (self.root / 'out/main.patched.bin').read_bytes(), off)[0]

    def test_no_patches_leaves_the_output_unchanged(self):
        p = self.run_rewriter(patches=False)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        base = (self.root / 'out/main.patched.bin').read_bytes()
        self.assertEqual(self.sites(), {})
        self.assertEqual(self.run_rewriter().returncode, 0)   # an empty folder: nothing matches
        self.assertEqual((self.root / 'out/main.patched.bin').read_bytes(), base)

    def test_patched_x18_and_svc_words_are_rewritten_after_patching(self):
        self.put_ips([(H + FN + 4, word(MOV_X1_X18)), (H + FN + 8, word(SVC_1))])
        p = self.run_rewriter()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('exefs patch', p.stdout)
        self.assertEqual(self.sites(), {FN + 4: 'x18', FN + 8: 'svc'})
        for off in (FN + 4, FN + 8): self.assertEqual(self.image_word(off) >> 26, 0x05, 'the site must now be a B into the patch area')
        self.assertEqual(self.image_word(FN), NOP)
        self.assertIn(BID, (self.root / 'out/main.exefs_patches.tsv').read_text())
        # the same bytes baked into the NSO give the same output: patching and then rewriting is not a different path
        nso = bytearray(synthetic_nso()); nso[H + FN + 4:H + FN + 12] = word(MOV_X1_X18) + word(SVC_1)
        (self.root / 'main.nso').write_bytes(bytes(nso)); patched = (self.root / 'out/main.patched.bin').read_bytes()
        self.assertEqual(self.run_rewriter(patches=False).returncode, 0)
        self.assertEqual((self.root / 'out/main.patched.bin').read_bytes(), patched)

    def test_patch_putting_an_x18_word_outside_swept_code_aborts(self):
        self.put_ips([(H + 0x1100, word(MOV_X1_X18))])   # in the ro segment
        p = self.run_rewriter()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('would not be rewritten', p.stderr)

    def test_a_patch_below_the_image_aborts(self):
        self.put_ips([(0x20, b'\0\0\0\0')])
        p = self.run_rewriter()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('NSO header', p.stderr)


if __name__ == '__main__':
    unittest.main()
