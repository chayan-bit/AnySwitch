"""push_pack.py without a device: a scratch two-platform pack becomes one archive whose tree is the iOS part, verified by its own inventory, with the code signed
for the given bundle ID; a pack that no longer matches its inventory is refused. Needs Xcode's clang and codesign, and aa (macOS).
Run: python3 -I scripts/tests/test_push_pack.py"""
import json, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'scripts/push_pack.py'
sys.path.insert(0, str(ROOT / 'dm/tools'))
import pack_manifest   # noqa: E402


def push(pack, work):
    return subprocess.run([sys.executable, '-I', str(TOOL), str(pack), '--identity', '-', '--bundle-id', 'org.example.hearth', '--work', str(work)], capture_output=True, text=True)


class PushPack(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); t = Path(self.t.name)
        self.pack, self.work = t / 'pack', t / 'work'
        for f in ('profile/game.json', 'code/macos.dylib', 'msl/ios/b-1/a.metallib', 'msl/macos/b-1/a.metallib', 'romfs.dmstore'):
            (self.pack / f).parent.mkdir(parents=True, exist_ok=True); (self.pack / f).write_text(f)
        src = t / 'c.c'; src.write_text('int dm_probe(void) { return 1; }\n')
        subprocess.run(['xcrun', '-sdk', 'iphoneos', 'clang', '-dynamiclib', '-arch', 'arm64', '-miphoneos-version-min=17.0', '-o', str(self.pack / 'code/ios.dylib'), str(src)], check=True)
        pack_manifest.write(self.pack, '0100000000010000')

    def tearDown(self): self.t.cleanup()

    def test_the_archive_holds_the_ios_part_signed_for_the_app(self):
        r = push(self.pack, self.work)
        self.assertEqual(r.returncode, 0, r.stderr)
        aar = sorted(self.work.glob('*.aar')); ready = sorted(self.work.glob('*.ready'))
        self.assertEqual(len(aar), 1); self.assertEqual(len(ready), 1)
        note = json.loads(ready[0].read_text())
        self.assertEqual((note['title_id'], note['archive'], note['archive_bytes'], note['files']), ('0100000000010000', aar[0].name, aar[0].stat().st_size, 4))   # files.tsv and manifest.json are not in the inventory
        out = Path(self.t.name) / 'out'; out.mkdir()
        subprocess.run(['aa', 'extract', '-i', str(aar[0]), '-d', str(out)], check=True)
        have = sorted(p.relative_to(out).as_posix() for p in out.rglob('*') if p.is_file())
        self.assertEqual(have, ['code/ios.dylib', 'files.tsv', 'manifest.json', 'msl/ios/b-1/a.metallib', 'profile/game.json', 'romfs.dmstore'])
        self.assertEqual(pack_manifest.problems(out), [])
        sig = subprocess.run(['codesign', '-dv', str(out / 'code/ios.dylib')], capture_output=True, text=True).stderr
        self.assertIn('Identifier=org.example.hearth\n', sig)
        self.assertEqual(pack_manifest.problems(self.pack), [])   # the source pack is untouched (its own code stays unsigned)

    def test_a_pack_that_changed_since_its_inventory_is_refused(self):
        (self.pack / 'romfs.dmstore').write_text('changed')
        r = push(self.pack, self.work)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('changed: romfs.dmstore', r.stderr)
        self.assertEqual(list(self.work.glob('*.aar')), [])


if __name__ == '__main__':
    unittest.main()
