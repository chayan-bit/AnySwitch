"""checkpoint.py: export / import round trips on the Mac side, validation, and the devicectl commands for the device side (a fake runner, no device).
No game data: every save here is made up. Run: python3 -I scripts/tests/test_checkpoint.py"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkpoint as cp

T = '0100ABF008968000'


def save_dir(root, files):
    root.mkdir(parents=True, exist_ok=True)
    for rel, data in files.items():
        p = root / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
    return root


class Mac(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.t = Path(self.tmp.name); self.root = self.t / 'ck'

    def tearDown(self): self.tmp.cleanup()

    def test_export_then_import_round_trips_every_byte(self):
        src = save_dir(self.t / 'run' / 'save', {'main': b'\x01' * 1000, 'sub/backup': b'xyz'})
        meta = cp.export_mac(T, 'bedroom', src, note='n', root=self.root)
        self.assertEqual(set(meta['files']), {'main', 'sub/backup'})
        self.assertEqual(meta['guest_name_xattrs'], [])
        dst = save_dir(self.t / 'run2' / 'save', {'stale': b'old'})
        save_dir(Path(str(dst) + '.work'), {'main': b'scratch'})
        cp.import_mac(T, 'bedroom', dst, root=self.root)
        self.assertEqual(cp.manifest(dst), meta['files'])
        self.assertFalse((dst / 'stale').exists(), 'files not in the checkpoint are removed')
        self.assertFalse(Path(str(dst) + '.work').exists(), 'the host scratch copy is cleared')

    def test_the_scratch_copy_is_refused_as_a_source(self):
        src = save_dir(self.t / 'save.work', {'main': b'a'})
        with self.assertRaises(cp.Fail): cp.export_mac(T, 'x', src, root=self.root)

    def test_an_empty_save_is_refused(self):
        with self.assertRaises(cp.Fail): cp.export_mac(T, 'x', save_dir(self.t / 'save', {}), root=self.root)

    def test_existing_checkpoint_needs_force(self):
        src = save_dir(self.t / 'save', {'main': b'a'})
        cp.export_mac(T, 'x', src, root=self.root)
        with self.assertRaises(cp.Fail): cp.export_mac(T, 'x', src, root=self.root)
        (src / 'main').write_bytes(b'b')
        self.assertEqual(cp.export_mac(T, 'x', src, force=True, root=self.root)['files']['main']['size'], 1)

    def test_a_damaged_checkpoint_is_refused(self):
        src = save_dir(self.t / 'save', {'main': b'abc'})
        cp.export_mac(T, 'x', src, root=self.root)
        (cp.ckpt_dir(T, 'x', self.root) / 'save' / 'main').write_bytes(b'abd')
        with self.assertRaises(cp.Fail): cp.import_mac(T, 'x', self.t / 'out', root=self.root)

    def test_names_are_validated(self):
        for title, name in (('0100', 'x'), (T, '../x'), (T, '.hidden'), (T, 'a/b'), (T, '')):
            with self.assertRaises(cp.Fail, msg=(title, name)): cp.ckpt_dir(title, name, self.root)
        self.assertEqual(cp.ckpt_dir(T.lower(), 'route-1.v2', self.root), self.root / T / 'route-1.v2')

    @unittest.skipUnless(sys.platform == 'darwin', 'extended attributes through the macOS xattr tool')
    def test_guest_name_attributes_are_recorded_and_block_the_device(self):
        src = save_dir(self.t / 'save', {'main': b'a', 'Main_1': b'b'})
        subprocess.run(['xattr', '-w', cp.GUEST_NAME_XATTR, 'MAIN', str(src / 'Main_1')], check=True)
        meta = cp.export_mac(T, 'x', src, root=self.root)
        self.assertEqual(meta['guest_name_xattrs'], ['Main_1'])
        out = subprocess.run(['xattr', '-p', cp.GUEST_NAME_XATTR, str(cp.ckpt_dir(T, 'x', self.root) / 'save' / 'Main_1')], capture_output=True, text=True)
        self.assertEqual(out.stdout.strip(), 'MAIN', 'the copy keeps the attribute')
        with self.assertRaises(cp.Fail): cp.import_device(T, 'x', 'UDID', 'b.id', root=self.root, run=FakeDevice(self.t).run)


class FakeDevice:
    """Answers devicectl like the real tool would, records every command."""
    def __init__(self, t, save=None, pids=(), app_url='file:///private/var/containers/Bundle/Application/X/DmIOS.app/', drop=()):
        self.t, self.save, self.pids, self.url, self.cmds, self.drop = t, dict(save or {}), pids, app_url, [], drop

    def run(self, cmd, capture_output=True, text=True):
        self.cmds.append(cmd); a = cmd[2:]
        def opt(k): return a[a.index(k) + 1]
        if a[:3] == ['device', 'copy', 'from']: save_dir(Path(opt('--destination')), self.save)
        elif a[:3] == ['device', 'copy', 'to']:
            rel = opt('--destination').removeprefix(cp.DEVICE_SAVE + '/')
            if rel not in self.drop: self.save[rel] = Path(opt('--source')).read_bytes()
        elif a[:3] == ['device', 'info', 'files']:
            if not self.save: return subprocess.CompletedProcess(cmd, 1, '', 'not found')
            files = [{'relativePath': k, 'metadata': {'size': len(v)}, 'resources': {'isDirectory': False}} for k, v in self.save.items()]
            Path(opt('--json-output')).write_text(json.dumps({'result': {'files': files}}))
        elif a[:3] == ['device', 'info', 'apps']: Path(opt('--json-output')).write_text(json.dumps({'result': {'apps': [{'url': self.url}]}}))
        elif a[:3] == ['device', 'info', 'processes']:
            procs = [{'processIdentifier': p, 'executable': self.url + 'DmIOS'} for p in self.pids] + [{'processIdentifier': 1, 'executable': 'file:///sbin/launchd'}]
            Path(opt('--json-output')).write_text(json.dumps({'result': {'runningProcesses': procs}}))
        return subprocess.CompletedProcess(cmd, 0, '', '')


class Device(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.t = Path(self.tmp.name); self.root = self.t / 'ck'

    def tearDown(self): self.tmp.cleanup()

    def test_export_copies_documents_save(self):
        dev = FakeDevice(self.t, save={'main': b'\x02' * 64})
        meta = cp.export_device(T, 'ipad', 'UDID', 'com.x.y', root=self.root, run=dev.run)
        self.assertEqual(meta['source'], 'device:UDID:com.x.y')
        c = dev.cmds[0]
        self.assertEqual(c[:5], ['xcrun', 'devicectl', 'device', 'copy', 'from'])
        self.assertIn('appDataContainer', c); self.assertEqual(c[c.index('--source') + 1], 'Documents/save')

    def test_import_stops_the_app_then_copies_each_file_and_checks_them(self):
        cp.export_mac(T, 'x', save_dir(self.t / 'save', {'main': b'a', 'backup': b'bb'}), root=self.root)
        dev = FakeDevice(self.t, save={'main': b'old', 'backup': b'old'}, pids=(812,))
        cp.import_device(T, 'x', 'UDID', 'com.x.y', launch=True, root=self.root, run=dev.run)
        verbs = [' '.join(c[2:5]) for c in dev.cmds]
        self.assertEqual(verbs, ['device info files', 'device info apps', 'device info processes', 'device process terminate',
                                 'device copy to', 'device copy to', 'device info files', 'device process launch'])
        term = dev.cmds[3]; self.assertEqual(term[term.index('--pid') + 1], '812')
        dests = sorted(c[c.index('--destination') + 1] for c in dev.cmds if c[2:5] == ['device', 'copy', 'to'])
        self.assertEqual(dests, ['Documents/save/backup', 'Documents/save/main'])
        self.assertFalse(any('--remove-existing-content' in c for c in dev.cmds), 'that flag empties the whole destination container directory')
        self.assertEqual(dev.save, {'main': b'a', 'backup': b'bb'})

    def test_import_refuses_a_device_save_with_extra_files_unless_kept(self):
        cp.export_mac(T, 'x', save_dir(self.t / 'save', {'main': b'a'}), root=self.root)
        dev = FakeDevice(self.t, save={'main': b'old', 'extra': b'e'})
        with self.assertRaises(cp.Fail): cp.import_device(T, 'x', 'UDID', 'com.x.y', root=self.root, run=dev.run)
        self.assertNotIn('copy', [c[3] for c in dev.cmds], 'nothing is copied before the refusal')
        cp.import_device(T, 'x', 'UDID', 'com.x.y', keep_extra=True, root=self.root, run=dev.run)
        self.assertEqual(dev.save, {'main': b'a', 'extra': b'e'})

    def test_import_fails_when_a_copied_file_is_missing_on_the_device(self):
        cp.export_mac(T, 'x', save_dir(self.t / 'save', {'main': b'a', 'backup': b'b'}), root=self.root)
        dev = FakeDevice(self.t, drop=('backup',))
        with self.assertRaises(cp.Fail): cp.import_device(T, 'x', 'UDID', 'com.x.y', launch=True, root=self.root, run=dev.run)
        self.assertNotIn('launch', [c[4] for c in dev.cmds])

    def test_import_without_a_running_app_terminates_nothing(self):
        cp.export_mac(T, 'x', save_dir(self.t / 'save', {'main': b'a'}), root=self.root)
        dev = FakeDevice(self.t)
        cp.import_device(T, 'x', 'UDID', 'com.x.y', root=self.root, run=dev.run)
        self.assertNotIn('terminate', [c[4] for c in dev.cmds])


if __name__ == '__main__':
    unittest.main()
