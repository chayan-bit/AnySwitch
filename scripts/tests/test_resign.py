"""resign.py: which container files a backup holds, the after-install comparison, the profile renewal's move-aside and restore, and the Xcode hints.
Everything runs on fakes in temporary folders; nothing touches a device, Xcode's profile cache or the keychain.
Run: python3 -I scripts/tests/test_resign.py"""
import datetime as dt, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import resign as r

NOW = dt.datetime.now(dt.timezone.utc)
ITEMS = [('Documents', True, 224), ('Documents/Logs/x/log.txt', False, 900), ('Documents/romfs.dmstore', False, 5949505620), ('Documents/settings.json', False, 60),
         ('Documents/Users/u1/saves/t/save', True, 96), ('Documents/Users/u1/saves/t/save/main', False, 1000), ('Documents/Users/users.json', False, 321),
         ('Documents/save', False, 50), ('Documents/temp/scratch', False, 5), ('Library/Application Support/Hearth/State/users.tsv', False, 177),
         ('Library/Application Support/Hearth/Games/t/code/ios.dylib', False, 75 << 20), ('Library/Caches/x', False, 4)]


def prof(uuid, days, created=0):
    return {'uuid': uuid, 'appid': 'T.b', 'expires': NOW + dt.timedelta(days=days), 'created': NOW + dt.timedelta(days=created), 'path': None}


class Files(unittest.TestCase):
    def test_backup_holds_saves_users_settings_and_state_only(self):
        self.assertEqual(r.save_files(ITEMS), ['Documents/Users/u1/saves/t/save/main', 'Documents/Users/users.json', 'Documents/save', 'Documents/settings.json',
                                               'Library/Application Support/Hearth/State/users.tsv'])

    def test_shape_keeps_user_data_by_size_and_skips_logs_scratch_caches(self):
        s = dict((p, size) for p, _, size in r.shape(ITEMS))
        self.assertEqual(s['Documents/romfs.dmstore'], 5949505620); self.assertIn('Library/Application Support/Hearth/Games/t/code/ios.dylib', s)
        self.assertEqual(s['Documents/Users/u1/saves/t/save'], 0, 'a directory counts by name only')
        for p in ('Documents/Logs/x/log.txt', 'Documents/temp/scratch', 'Library/Caches/x'): self.assertNotIn(p, s)

    def test_a_changed_save_or_a_missing_store_fails_the_install_check(self):
        log = lambda *a: None
        before = {'Documents/save': 'a'}
        for f in ('listing', 'pull'): self.addCleanup(setattr, r, f, getattr(r, f))
        for after_sums, items in (({'Documents/save': 'b'}, ITEMS), (before, [i for i in ITEMS if i[0] != 'Documents/romfs.dmstore'])):
            r.listing = lambda u, b, items=items: items
            r.pull = lambda u, b, files, dest, s=after_sums: s
            with tempfile.TemporaryDirectory() as t, self.assertRaises(r.Fail) as e:
                r.check_after('U', 'B', before, r.shape(ITEMS), f'{t}/resign-x.post-1', log)
            self.assertIn('restore from resign-x', str(e.exception))

    def test_a_backup_never_reuses_a_folder_or_writes_outside_its_own(self):
        with tempfile.TemporaryDirectory() as t:
            for bad in (f'{t}/USER-SAVE-keep', t):
                with self.assertRaises(r.Fail): r.backup('U', 'B', bad, print)


class Renewal(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.addCleanup(self._t.cleanup); self.t = Path(self._t.name)
        self.cache = self.t / 'cache'; self.cache.mkdir(); self.real = r.local_profiles; self.addCleanup(setattr, r, 'local_profiles', self.real)
        self.profiles = {}
        r.local_profiles = lambda appid, folder: [p for u, p in self.profiles.items() if (self.cache / f'{u}.mobileprovision').exists()]

    def put(self, p):
        p['path'] = str(self.cache / f'{p["uuid"]}.mobileprovision'); Path(p['path']).write_text(p['uuid']); self.profiles[p['uuid']] = p; return p

    def test_a_profile_with_more_than_six_and_a_half_days_is_reused(self):
        cur = self.put(prof('cur', 6.9)); built = []
        self.assertIs(r.fresh_profile('T.b', cur, lambda: built.append(1), self.t / 'moved', print, self.cache), cur); self.assertEqual(built, [])

    def test_renewal_moves_the_cached_ones_aside_and_puts_back_the_valid_ones(self):
        cur, dead = self.put(prof('cur', 1.5)), self.put(prof('dead', -1))
        def build():
            self.assertEqual(sorted(f.name for f in self.cache.iterdir()), [], 'Xcode sees no cached profile while it builds')
            self.put(prof('new', 7, created=0.01))
        new = r.fresh_profile('T.b', cur, build, self.t / 'moved', print, self.cache)
        self.assertEqual(new['uuid'], 'new')
        self.assertEqual(sorted(f.name for f in self.cache.iterdir()), ['cur.mobileprovision', 'new.mobileprovision'])
        self.assertEqual([f.name for f in (self.t / 'moved').iterdir()], ['dead.mobileprovision'], 'an expired one stays moved aside (kept, not deleted)')

    def test_a_failed_build_restores_the_cache_and_no_new_profile_fails(self):
        cur = self.put(prof('cur', 1))
        def boom(): raise r.Fail('xcodebuild failed: sign in to Xcode (Settings > Accounts)')
        with self.assertRaises(r.Fail): r.fresh_profile('T.b', cur, boom, self.t / 'moved', print, self.cache)
        self.assertTrue(Path(cur['path']).exists())
        with self.assertRaises(r.Fail) as e: r.fresh_profile('T.b', cur, lambda: None, self.t / 'moved2', print, self.cache)
        self.assertIn('no new profile', str(e.exception))


class Hints(unittest.TestCase):
    def test_xcode_errors_name_what_the_user_does(self):
        self.assertIn('sign in', r.xcode_hint('error: No Accounts: Add a new account in Accounts settings.'))
        self.assertIn('internet', r.xcode_hint('The network connection was lost / offline'))
        self.assertEqual(r.xcode_hint('something else'), 'see the log')


if __name__ == '__main__': unittest.main()
