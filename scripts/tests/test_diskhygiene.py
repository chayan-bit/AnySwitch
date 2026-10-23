"""diskhygiene.py: clone, keep-last-N prune to a (fake) trash, the CoreDevice delta cleanup after an install (a fake devicectl, a fake delta folder), retiring the unsigned IPA,
and the gpuarchiver snapshot/clean. Everything runs in temporary folders; nothing touches a device, the real trash or the real caches.
Run: python3 -I scripts/tests/test_diskhygiene.py"""
import os, plistlib, subprocess, sys, tempfile, time, unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diskhygiene as h


class Tmp(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.addCleanup(self._t.cleanup); self.t = Path(self._t.name)

    def make(self, rel, size=10, age=0):   # a file of `size` bytes whose folders and file are `age` seconds old
        p = self.t / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'x' * size)
        when = time.time() - age
        for q in (p, *p.parents):
            if q == self.t: break
            os.utime(q, (when, when))
        return p


class Clone(Tmp):
    def test_clones_a_folder_with_the_same_content(self):
        self.make('src/a/f.bin', 100)
        self.assertIn(h.clone(self.t / 'src', self.t / 'out/dst'), ('clone', 'copy'))
        self.assertEqual((self.t / 'out/dst/a/f.bin').read_bytes(), b'x' * 100)

    def test_falls_back_to_a_plain_copy_when_cloning_is_refused(self):
        self.make('src/f.bin', 5)
        real = subprocess.run
        def no_clone(cmd, *a, **k):
            if cmd[:2] == ['cp', '-c']: return SimpleNamespace(returncode=1)
            return real(cmd, *a, **k)
        h.subprocess.run = no_clone
        self.addCleanup(setattr, h.subprocess, 'run', real)
        self.assertEqual(h.clone(self.t / 'src', self.t / 'dst'), 'copy')
        self.assertEqual((self.t / 'dst/f.bin').read_bytes(), b'x' * 5)

    @unittest.skipUnless(sys.platform == 'darwin', 'APFS clones')
    def test_a_clone_shares_blocks(self):   # same volume: the clone adds (almost) no allocated blocks
        self.make('src/big.bin', 8 * 2**20)
        used = lambda p: sum(f.stat().st_blocks * 512 for f in Path(p).rglob('*') if f.is_file())
        free = lambda: (lambda s: s.f_bavail * s.f_frsize)(os.statvfs(self.t))
        before = free(); how = h.clone(self.t / 'src', self.t / 'dst'); after = free()
        if how == 'copy': self.skipTest('this volume does not clone')
        self.assertEqual(used(self.t / 'dst'), used(self.t / 'src'))   # the logical size is all there
        self.assertLess(before - after, 2 * 2**20)                      # the free space barely moved


class Prune(Tmp):
    def steps(self, n, sub='build'):   # step1 oldest ... stepN newest
        for i in range(1, n + 1): self.make(f'p2/step{i}/{sub}/app.ipa', 10, age=1000 - i * 10); self.make(f'p2/step{i}/notes.txt', 1, age=1000 - i * 10)
        return self.t / 'p2'

    def test_keeps_the_newest_two_and_moves_the_rest_to_the_trash(self):
        p, trash = self.steps(5), self.t / 'trash'
        moved = h.prune_steps(p, 2, 'build', trash)
        self.assertEqual([m.parent.name for m in moved], ['step1', 'step2', 'step3'])
        self.assertTrue((p / 'step4/build').is_dir() and (p / 'step5/build').is_dir())
        self.assertFalse(any((p / f'step{i}/build').exists() for i in (1, 2, 3)))
        self.assertTrue((p / 'step1/notes.txt').exists())   # only the build folder moves, not the step's notes
        self.assertEqual(sorted(x.name for x in trash.iterdir()), ['p2-step1-build', 'p2-step2-build', 'p2-step3-build'])
        self.assertEqual((trash / 'p2-step1-build/app.ipa').read_bytes(), b'x' * 10)   # moved, not deleted

    def test_dry_run_moves_nothing_and_fewer_than_n_is_a_no_op(self):
        p = self.steps(3)
        self.assertEqual(len(h.prune_steps(p, 2, 'build', self.t / 'trash', dry_run=True)), 1)
        self.assertTrue((p / 'step1/build').exists())
        self.assertEqual(h.prune_steps(p, 5, 'build', self.t / 'trash'), [])

    def test_a_name_taken_in_the_trash_is_not_overwritten(self):
        p, trash = self.steps(3), self.t / 'trash'
        self.make('trash/p2-step1-build/keep.txt')
        h.prune_steps(p, 2, 'build', trash)
        self.assertTrue((trash / 'p2-step1-build/keep.txt').exists()); self.assertEqual(len(list(trash.iterdir())), 2)

    def test_without_sub_each_folder_is_a_build(self):
        for i in (1, 2, 3): self.make(f'device/v{i}/sign/x', 1, age=100 - i)
        moved = h.prune_steps(self.t / 'device', 1, None, self.t / 'trash')
        self.assertEqual(sorted(m.name for m in moved), ['v1', 'v2'])

    def test_protected_folders_are_refused(self):
        self.make('backups/20261023/x')
        with self.assertRaises(SystemExit): h.prune_steps(self.t / 'backups', 0, None, self.t / 'trash')
        self.make('data/extracted/g1/x')
        with self.assertRaises(SystemExit): h.prune_steps(self.t / 'data/extracted', 0, None, self.t / 'trash')
        self.assertTrue((self.t / 'backups/20261023/x').exists())


class Delta(Tmp):
    def delta(self, bundle, size=1000):
        root = self.t / 'AppInstallationBinaryDeltas'; self.make(f'AppInstallationBinaryDeltas/{bundle}/blob', size); return root

    def test_removes_our_bundle_and_only_that_one(self):
        root = self.delta('com.chayan.anyswitch.sword', 1234); self.make('AppInstallationBinaryDeltas/com.other.app/blob')
        self.assertEqual(h.clean_delta('com.chayan.anyswitch.sword', root), 1234)
        self.assertFalse((root / 'com.chayan.anyswitch.sword').exists()); self.assertTrue((root / 'com.other.app/blob').exists())

    def test_refuses_bundle_ids_that_are_not_ours_or_climb_out(self):
        root = self.delta('com.other.app')
        for bad in ('com.other.app', 'com.chayan./../com.other.app', 'com.chayan.a/b', ''):
            with self.assertRaises(SystemExit): h.clean_delta(bad, root)
        self.assertTrue((root / 'com.other.app/blob').exists())

    def test_no_cache_is_not_an_error(self):
        self.assertEqual(h.clean_delta('com.chayan.nothing', self.t), 0)

    def app(self):
        a = self.t / 'DmIOS.app'; a.mkdir(); (a / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.chayan.anyswitch.sword'})); return a

    def test_cleanup_runs_after_a_successful_install(self):
        root, cmds, said = self.delta('com.chayan.anyswitch.sword', 2**20), [], []
        rc = h.install_app('UDID', self.app(), run=lambda c: cmds.append(c) or SimpleNamespace(returncode=0), delta_root=root, out=said.append)
        self.assertEqual(rc, 0)
        self.assertEqual(cmds[0][:6], ['xcrun', 'devicectl', 'device', 'install', 'app', '--device'])
        self.assertFalse((root / 'com.chayan.anyswitch.sword').exists()); self.assertIn('freed 1 MB', said[0])

    def test_a_failed_install_keeps_the_cache(self):
        root = self.delta('com.chayan.anyswitch.sword')
        self.assertEqual(h.install_app('UDID', self.app(), run=lambda c: SimpleNamespace(returncode=3), delta_root=root, out=print), 3)
        self.assertTrue((root / 'com.chayan.anyswitch.sword/blob').exists())


class RetireIpa(Tmp):
    def build(self, signed=True):
        self.make('step2/build/app.ipa', 50)
        if signed: (self.t / 'step2/build/sign/Payload/DmIOS.app').mkdir(parents=True)
        return self.t / 'step2/build'

    def test_the_ipa_goes_to_the_trash_once_the_signed_app_verifies(self):
        b, trash = self.build(), self.t / 'trash'
        new = h.retire_ipa(b, run=lambda c, **k: SimpleNamespace(returncode=0), trash=trash)
        self.assertFalse((b / 'app.ipa').exists()); self.assertEqual(new.read_bytes(), b'x' * 50)

    def test_the_ipa_stays_when_nothing_is_signed_or_it_does_not_verify(self):
        with self.assertRaises(SystemExit): h.retire_ipa(self.build(signed=False), run=lambda c, **k: SimpleNamespace(returncode=0), trash=self.t / 'trash')
        b = self.t / 'step3/build'; self.make('step3/build/app.ipa'); (b / 'sign/Payload/DmIOS.app').mkdir(parents=True)
        with self.assertRaises(SystemExit): h.retire_ipa(b, run=lambda c, **k: SimpleNamespace(returncode=1), trash=self.t / 'trash')
        self.assertTrue((b / 'app.ipa').exists())


class Gpu(Tmp):
    def test_removes_only_entries_made_since_the_snapshot(self):
        root = self.t / 'com.apple.gpuarchiver'
        self.make('com.apple.gpuarchiver/gpuarchiver-old/f', 100, age=500)
        before = h.gpu_snapshot(root); self.assertEqual(before, ['gpuarchiver-old'])
        self.make('com.apple.gpuarchiver/gpuarchiver-new/f', 300, age=100)
        freed, left = h.gpu_clean(before, root, quiet=30)
        self.assertEqual((freed, left), (300, []))
        self.assertEqual(h.gpu_snapshot(root), ['gpuarchiver-old'])

    def test_an_entry_touched_inside_the_quiet_window_is_left(self):
        root = self.t / 'com.apple.gpuarchiver'; root.mkdir()
        self.make('com.apple.gpuarchiver/gpuarchiver-live/f', 10, age=1)
        self.assertEqual(h.gpu_clean([], root, quiet=30), (0, ['gpuarchiver-live']))
        self.assertTrue((root / 'gpuarchiver-live/f').exists())

    def test_a_missing_cache_folder_is_fine(self):
        self.assertEqual(h.gpu_snapshot(self.t / 'none'), []); self.assertEqual(h.gpu_clean([], self.t / 'none'), (0, []))


if __name__ == '__main__': unittest.main()
