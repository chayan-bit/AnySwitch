"""gpu_timestamps profile key: the default is segment (audit rank 10), a per-title `gpu_timestamps submission` wins, a bad value is refused, and the run-time env override still sits ahead of the profile macro in nvn_mtl.m.
No game data: the profiles here are built in a temp folder. Run: python3 -I dm/games/tests/test_gpu_timestamps_default.py"""
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


def macro(extra=''):
    with tempfile.TemporaryDirectory() as t:
        d = Path(t) / '0100000000000000'; d.mkdir(); (d / 'game.tsv').write_text(BASE + extra)
        return re.search(r'DM_GAME_GPU_TS_SEGMENT (\d)', game.header(game.Game(d))).group(1)


class GpuTimestampsDefault(unittest.TestCase):
    def test_unset_key_resolves_to_segment(self): self.assertEqual(macro(), '1')
    def test_profile_can_opt_out_with_submission(self): self.assertEqual(macro('gpu_timestamps\tsubmission\n'), '0')
    def test_profile_can_ask_for_segment(self): self.assertEqual(macro('gpu_timestamps\tsegment\n'), '1')

    def test_bad_value_is_refused(self):
        with self.assertRaises(SystemExit): macro('gpu_timestamps\tfoo\n')

    def test_env_override_still_wins_over_the_profile_macro(self):   # the only reader of the macro is seg_ts() in dm/gfx/nvn/nvn_mtl.m
        src = (GAMES.parent / 'gfx' / 'nvn' / 'nvn_mtl.m').read_text(encoding='utf-8')
        m = re.search(r'static int seg_ts\(void\) \{.*?\n', src)
        self.assertIsNotNone(m)
        self.assertRegex(m.group(0), r'getenv\("DM_NVN_GPU_TS"\).*e && \*e \? !strcmp\(e, "segment"\) : DM_GAME_GPU_TS_SEGMENT')


if __name__ == '__main__': unittest.main()
