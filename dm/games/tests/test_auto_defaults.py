"""Keys on their way to detection at run time (render_cond, tex_flush_upload, tex_dirty_upload): the profile takes off / on / auto (game.json 0 / 1 / 2), the default stays off,
bad values and impossible texture pairs are refused, and the host reads its environment override ahead of the profile value (hle_nvn.c nvn_key_mode).
No game data: the profiles here are built in a temp folder. Run: python3 -I dm/games/tests/test_auto_defaults.py"""
from pathlib import Path
import re
import sys
import tempfile
import unittest
GAMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GAMES))
import game

BASE = 'title_id\t0100000000000000\nprogram_id\t0100000000000000\nname\tSynthetic\nbuild\tv0\t1.0\tmain=00\nmodules\tmain\nromfs_marker\tdata\n' \
       'mem_reserve\t0x1000\nmem_alias\t0x1000\nmem_stack\t0x1000\napp_pool\t0x1000\n'


def macros(extra=''):   # the three keys as game.json has them
    with tempfile.TemporaryDirectory() as t:
        d = Path(t) / '0100000000000000'; d.mkdir(); (d / 'game.tsv').write_text(BASE + extra)
        r = game.resolve(game.Game(d))
        return {k: r[k.lower()] for k in ('RENDER_COND', 'TEX_FLUSH_UPLOAD', 'TEX_DIRTY_UPLOAD')}


class AutoKeys(unittest.TestCase):
    def test_unset_keys_stay_off(self): self.assertEqual(macros(), {'RENDER_COND': 0, 'TEX_FLUSH_UPLOAD': 0, 'TEX_DIRTY_UPLOAD': 0})

    def test_each_key_takes_off_on_and_auto(self):
        for word, v in (('off', 0), ('on', 1), ('auto', 2)):
            self.assertEqual(macros(f'render_cond\t{word}\n')['RENDER_COND'], v)
            self.assertEqual(macros(f'tex_flush_upload\t{word}\n')['TEX_FLUSH_UPLOAD'], v)

    def test_dirty_follows_its_flush_key(self):
        self.assertEqual(macros('tex_flush_upload\ton\ntex_dirty_upload\ton\n')['TEX_DIRTY_UPLOAD'], 1)
        self.assertEqual(macros('tex_flush_upload\tauto\ntex_dirty_upload\tauto\n')['TEX_DIRTY_UPLOAD'], 2)
        self.assertEqual(macros('tex_flush_upload\ton\ntex_dirty_upload\tauto\n')['TEX_DIRTY_UPLOAD'], 2)
        for bad in ('tex_dirty_upload\ton\n', 'tex_flush_upload\tauto\ntex_dirty_upload\ton\n', 'tex_dirty_upload\tauto\n'):
            with self.assertRaises(SystemExit): macros(bad)

    def test_bad_values_are_refused(self):
        for bad in ('render_cond\tyes\n', 'tex_flush_upload\t1\n'):
            with self.assertRaises(SystemExit): macros(bad)

    def test_env_override_sits_ahead_of_the_profile_value(self):   # hle_nvn.c resolves every mode once, nvn_mtl.m asks it
        src = (GAMES.parent / 'gfx' / 'nvn' / 'hle_nvn.c').read_text(encoding='utf-8')
        self.assertRegex(src, r'nvn_auto_mode\(getenv\("DM_NVN_RENDER_COND"\), g_profile\.render_cond\)')
        self.assertRegex(src, r'nvn_auto_mode\(tg, g_profile\.tex_flush_upload\)')
        self.assertRegex(src, r'nvn_auto_mode\(tg, g_profile\.tex_dirty_upload\)')
        self.assertRegex(src, r'tg = getenv\("DM_NVN_TEX_GUEST"\)')
        rest = src + (GAMES.parent / 'gfx' / 'nvn' / 'nvn_mtl.m').read_text(encoding='utf-8')
        direct = [l for l in rest.splitlines() if re.search(r'g_profile\.(render_cond|tex_flush_upload|tex_dirty_upload)\b', l) and 'nvn_auto_mode(' not in l]
        self.assertEqual(direct, [])   # no direct use of the values left: a truth test would read auto (2) as on


if __name__ == '__main__': unittest.main()
