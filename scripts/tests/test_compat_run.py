"""compat_run.py: the detectors, the status ladder, suggestions, the resume key, results.tsv and route files, on made-up host logs (no game, no host).
Run: python3 -I scripts/tests/test_compat_run.py"""
import json
from pathlib import Path
import signal
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compat_run as cr

M = '[dm] [nvn-mtl] '


def shot(frame, t, nonblack=0.9, hash_=None, mag=0):
    return f'{M}[shot] frame={frame} t={t:.2f} w=1280 h=720 luma=100.00 nonblack={nonblack:.4f} magenta_px={mag * 256} magenta_blocks16={mag} hash={hash_ or f"{frame:016x}"}'


def auto(frame, **kw):
    v = dict(render_cond='off', tex_flush='off', tex_dirty='off', fb_snap_keys=0, cpu_tex=0, rc_conds=0, snw=0, fb_c=0)
    v.update(kw)
    return f'{M}[auto] frame={frame} t={frame / 30:.1f} ' + ' '.join(f'{k}={x}' for k, x in v.items())


def log(*lines, boot=True, first=1.0):
    head = ['[dm] >>> nnMain'] if boot else []
    if first is not None: head.append(f'{M}[auto] event=first_present t={first:.3f}')
    return '\n'.join(head + list(lines)) + '\n'


def playing(n=12, every=10.0):   # shots that change every time, over n * every seconds
    return [shot(300 * (i + 1), 1.0 + every * (i + 1)) for i in range(n)]


class Parse(unittest.TestCase):
    def test_reads_shots_auto_and_first_present(self):
        s = cr.parse_log(log(shot(300, 11.0, 0.5, 'ab' * 8, 2), auto(300, snw=3, render_cond='on')))
        self.assertEqual(s['first_present'], 1.0)
        self.assertEqual(s['shots'][0]['magenta_blocks16'], 2)
        self.assertEqual(s['shots'][0]['nonblack'], 0.5)
        self.assertEqual(s['auto']['snw'], 3)
        self.assertEqual(s['auto']['render_cond'], 'on')

    def test_tolerates_another_threads_output_inside_a_line(self):
        s = cr.parse_log(f'{M}[auto] event=first_present t=0.929[dm] [nvn] init 0: 192 functions\n')
        self.assertAlmostEqual(s['first_present'], 0.929)

    def test_groups_red_lines_by_template_and_counts_stubs(self):
        s = cr.parse_log(log('[dm] [RED] texture 0x1234 of 64x64 unsupported', '[dm] [RED] texture 0x99 of 128x128 unsupported',
                             '[dm] UNIMPL nnFooBar (x0=0x1 x1=0x2 x2=0x3)', '[dm] UNIMPL nnFooBar (x0=0x1 x1=0x2 x2=0x3)'))
        self.assertEqual(list(s['red'].values()), [2])
        self.assertEqual(s['unimpl'], {'nnFooBar': 2})

    def test_reads_fout_rows_and_shader_failures(self):
        s = cr.parse_log(log(f'{M}[RED] failed to create render pipeline vs/fs: add to shader_facts_manual.tsv: abcd1234\tfout 0=uint',
                             f'{M}[RED] shader 1234abcd is not in the shader map'))
        self.assertEqual(s['fout_rows'], ['abcd1234\tfout 0=uint'])
        self.assertEqual((s['pso_fail'], s['shmap_miss']), (1, 1))

    def test_reads_class_c_keys_once(self):
        c = f'{M}[auto] feedback class C: fragment shader 0123456789abcdef samples colour attachment 0 while writing it (frame 9)'
        self.assertEqual(cr.parse_log(log(c, c))['fb_c_keys'], ['0123456789abcdef'])


class Status(unittest.TestCase):
    def status(self, text, rc=None, full=True, sent=True, hang=False):
        return cr.detect(cr.parse_log(text), rc, full, sent, hang)

    def test_no_nnmain_is_no_boot(self):
        self.assertEqual(self.status(log(boot=False, first=None), rc=1, full=False)[0], 'no-boot')

    def test_boot_without_a_lit_shot_is_boots(self):
        st, labels = self.status(log(*[shot(300 * i, 10.0 * i, 0.0) for i in range(1, 8)]))
        self.assertEqual(st, 'boots')
        self.assertIn('black', labels)

    def test_changing_picture_for_the_whole_budget_is_ingame(self):
        self.assertEqual(self.status(log(*playing())), ('ingame', []))

    def test_crash_caps_at_renders(self):
        st, labels = self.status(log(*playing(4), '[dm] CRASH sig=11'), rc=-signal.SIGSEGV, full=False)
        self.assertEqual(st, 'renders')
        self.assertIn('crash', labels)

    def test_watchdog_exit_is_a_hang_not_a_crash(self):
        st, labels = self.status(log(*playing(4), '[dm] [RED] watchdog: no progress since second 9, stuck at tick 3 / stage x'), rc=142, full=False)
        self.assertEqual((st, labels), ('renders', ['hang']))

    def test_frozen_picture_under_input(self):
        same = [shot(300 * i, 10.0 * i, 0.9, 'cd' * 8) for i in range(1, 9)]
        st, labels = self.status(log(*playing(3), *same))
        self.assertEqual(st, 'renders')
        self.assertIn('frozen', labels)

    def test_frozen_needs_input(self):
        same = [shot(300 * i, 10.0 * i, 0.9, 'cd' * 8) for i in range(1, 9)]
        self.assertNotIn('frozen', self.status(log(*same), sent=False)[1])

    def test_magenta_blocks_and_snw_are_missing_textures(self):
        self.assertIn('missing-textures', self.status(log(*playing(), shot(9999, 200.0, 0.9, None, 4)))[1])
        self.assertIn('missing-textures', self.status(log(*playing(), auto(3600, snw=2)))[1])

    def test_a_stopped_host_is_not_ingame(self):
        self.assertEqual(self.status(log(*playing()), rc=0, full=False)[0], 'renders')

    def test_slow_frames(self):
        t = '[dm] [nvn] timing up to frame 300: frame time p50 66.70 / p95 70.00 / max 90.00 ms (299 frames)'
        self.assertIn('slow', self.status(log(*playing(), t))[1])


class Suggestions(unittest.TestCase):
    def kinds(self, text, heap=None):
        return {(x['kind'], x.get('key', x.get('item', x.get('row')))) for x in cr.suggest(cr.parse_log(text), heap)}

    def test_each_signal_gives_its_key(self):
        k = self.kinds(log(auto(300, snw=5), f'{M}[RED] SetRenderEnableConditional: the host draws anyway for now',
                           f'{M}[auto] feedback class C: fragment shader 0123456789abcdef samples colour attachment 1 while writing it (frame 3)',
                           '[dm] UNIMPL nnBaz (x0=0 x1=0 x2=0)'), {'heap_size': ('0x80000000', 'SetHeapSize OOM')})
        self.assertEqual(k, {('key', 'tex_flush_upload tex_dirty_upload'), ('key', 'render_cond'), ('key', 'feedback_snap'), ('host', 'UNIMPL nnBaz'), ('key', 'heap_size')})

    def test_no_key_suggested_when_it_is_already_on(self):
        self.assertEqual(self.kinds(log(auto(300, snw=5, tex_flush='on'))), set())

    def test_flaky_repeats(self):
        self.assertTrue(cr.flaky([('ingame', []), ('renders', ['crash'])]))
        self.assertFalse(cr.flaky([('ingame', []), ('ingame', [])]))
        self.assertFalse(cr.flaky([('renders', ['crash']), ('renders', ['crash'])]))


class Bookkeeping(unittest.TestCase):
    def test_key_changes_with_files_repo_route_and_options(self):
        base = (['a.nsp:10'], 'abc', (None, None, ''), {'secs': 300})
        k = cr.run_key(*base)
        self.assertEqual(k, cr.run_key(*base))
        for i, v in enumerate((['a.nsp:11'], 'abd', ('x', None, ''), {'secs': 60})):
            self.assertNotEqual(k, cr.run_key(*[v if j == i else b for j, b in enumerate(base)]))

    def test_results_keep_the_latest_row_per_title(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'results.tsv'
            cr.merge_results(p, [{'title_id': 'A', 'status': 'boots'}, {'title_id': 'B', 'status': 'renders'}])
            have = cr.merge_results(p, [{'title_id': 'A', 'status': 'ingame', 'labels': 'slow'}])
            self.assertEqual((have['A']['status'], have['A']['labels'], have['B']['status']), ('ingame', 'slow', 'renders'))
            self.assertEqual(len(p.read_text().splitlines()), 3)

    def test_compat_table_reads_results(self):
        import compat_table
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'results.tsv'
            cr.merge_results(p, [{'title_id': '0100AAAAAAAAA000', 'name': 'Made Up', 'status': 'renders', 'labels': 'black', 'stamp': 's1'}])
            self.assertIn('| Made Up | `0100AAAAAAAAA000` | renders | black | s1 |', compat_table.results(p))

    def test_env_switches_keep_paths_and_lists(self):
        self.assertEqual(cr.env_pairs(['DM_MSL_DIR=/a/b-c/d', 'X=1,2 Y=on']), {'DM_MSL_DIR': '/a/b-c/d', 'X': '1,2', 'Y': 'on'})
        with self.assertRaises(SystemExit): cr.env_pairs(['nope'])

    def test_host_launch_from_a_pack_or_a_patched_folder(self):
        info = {'host': '/h/dmhost', 'patched': '/w/patched', 'romfs': '/w/romfs.dmstore', 'msl_dir': '/w/msl', 'shader_map': '/g/shader_map.tsv', 'aoc': '/w/aoc', 'profile_json': '/w/profile'}
        argv, env = cr.host_launch(info, {'DM_SAVE': '/s', 'DM_KEYS': 'x'}, {'DM_NICK': 'n'})
        self.assertEqual(argv, ['/h/dmhost', '/w/patched'])
        self.assertEqual((env['DM_ROMFS'], env['DM_MSL_DIR'], env['DM_AOC_DIR'], env['DM_PROFILE_DIR'], env['DM_SAVE'], env['DM_NICK']), ('/w/romfs.dmstore', '/w/msl', '/w/aoc', '/w/profile', '/s', 'n'))
        self.assertNotIn('DM_KEYS', env)
        argv, env = cr.host_launch(dict(info, pack='/p/pack'), {'DM_SAVE': '/s', 'DM_ROMFS': '/stale', 'DM_CODE': '/stale.dylib'}, {'DM_MSL_DIR': '/test'})
        self.assertEqual(argv, ['/h/dmhost', '/p/pack'])
        self.assertEqual(env['DM_SAVE'], '/s')                  # the caller's own values stay
        self.assertNotIn('DM_ROMFS', env); self.assertNotIn('DM_CODE', env); self.assertNotIn('DM_PROFILE_DIR', env)   # the pack defaults them
        self.assertEqual(env['DM_MSL_DIR'], '/test')            # --env still wins

    def test_route_file(self):
        ck, secs, seq = cr.read_route('# a route\ncheckpoint start\nsecs 120\nf700:A*12/90\nwait(30) LLeft~40  # walk\n')
        self.assertEqual((ck, secs, seq), ('start', 120.0, 'f700:A*12/90 wait(30) LLeft~40'))

    def test_compare_two_boots(self):
        mk = lambda st, h: {'status': st, 'labels': [], 'signals': cr.parse_log(log(shot(300, 11.0, 0.5, h), auto(300, snw=1 if st == 'renders' else 0)))}
        d = cr.compare(mk('ingame', 'aa' * 8), mk('renders', 'bb' * 8))
        self.assertEqual((d['status'], d['shots_same_hash'], d['auto']['snw']), (['ingame', 'renders'], '0/1', [0, 1]))

    def test_game_dirs(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root / 'g1').mkdir(); (root / 'g1/x.nsp').write_bytes(b''); (root / 'empty').mkdir()
            self.assertEqual(cr.game_dirs(root), [root / 'g1'])
            self.assertEqual(cr.game_dirs(root / 'g1'), [root / 'g1'])

    def test_summary_lists_each_game(self):
        with tempfile.TemporaryDirectory() as d:
            sd = Path(d) / 's1'; sd.mkdir()
            cr.summary(sd, [{'title_id': '0100AAAAAAAAA000', 'status': 'build-failed', 'labels': []}], None)
            self.assertIn('0100AAAAAAAAA000', (sd / 'summary.md').read_text())


class Artifacts(unittest.TestCase):
    """What the host could not write (the screenshots, the save mount) is a label of its own, and such a run is not ingame"""
    FAIL = f'{M}screenshot 1280x720 format 80 \u2192 shots/300.png failed'
    SAVE = f'{M}[RED] save transaction: cloning the work directory failed (save.work, errno=2) -- mounting the committed directory save read-only instead: saves cannot be written this session'

    def status(self, text, **kw):
        s = cr.parse_log(text); s.update(kw)
        return cr.detect(s, None, True, True, False)

    def test_failed_screenshot_write_is_shots_missing_and_not_ingame(self):
        st, labels = self.status(log(*playing(), self.FAIL))
        self.assertIn('shots-missing', labels)
        self.assertEqual(st, 'renders')

    def test_fewer_files_than_shots_taken_is_shots_missing(self):
        st, labels = self.status(log(*playing(12)), shot_files=7)
        self.assertEqual((st, 'shots-missing' in labels), ('renders', True))
        self.assertEqual(self.status(log(*playing(12)), shot_files=12), ('ingame', []))

    def test_save_mount_failure_is_labelled_and_not_ingame(self):
        st, labels = self.status(log(*playing(), self.SAVE))
        self.assertIn('save-mount-failed', labels)
        self.assertEqual(st, 'renders')

    def test_a_checkpoint_that_did_not_import_is_save_mount_failed(self):
        self.assertIn('save-mount-failed', self.status(log(*playing()), save_failed=True)[1])

    def test_report_counts_the_files_the_run_wrote(self):
        with tempfile.TemporaryDirectory() as d:
            rd = Path(d); (rd / 'shots').mkdir()
            (rd / 'host.log').write_text(log(*playing(4)))
            for i in (1, 2): (rd / 'shots' / f'{i}.png').write_bytes(b'x')
            r = cr.report_boot(rd, None, True, True, False)
            self.assertIn('shots-missing', r['labels'])
            self.assertEqual(r['status'], 'renders')
            self.assertEqual(cr.report_boot(rd, None, True, True, False, save_failed=True)['labels'].count('save-mount-failed'), 1)


class Paths(unittest.TestCase):
    """The host runs with cwd = the run directory: a relative path handed to it would resolve there, so every path option is absolute from the start"""
    def test_relative_paths_become_absolute(self):
        a = cr.parse_args(['games', '-k', 'prod.keys', '--out', 'runs/here', '--routes', 'routes'])
        for p in (a.root, a.keys, a.out, Path(a.routes)): self.assertTrue(Path(p).is_absolute(), p)
        self.assertEqual(a.out, Path.cwd() / 'runs/here')

    def test_default_out_is_absolute(self):
        self.assertTrue(cr.parse_args(['g', '-k', 'k']).out.is_absolute())


if __name__ == '__main__':
    unittest.main()
