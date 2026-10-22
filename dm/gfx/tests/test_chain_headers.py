"""Every committed dm/games/<title id>/dmsh_chain.h holds the translation chain version the tools in this tree compute (dmsh_chain.py --header would write the same).
A stale header makes the shader build refuse to start ("dmsh_chain.h does not hold the current translation chain version"). Reads the profiles' tracked tables only, no game files.
Run: python3 -I dm/gfx/tests/test_chain_headers.py"""
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
CHAIN = ROOT / 'dm/gfx/tools/dmsh_chain.py'


def chain_version(title):   # what dmsh_chain.py --header would write for the title, without writing it
    env = {k: v for k, v in os.environ.items() if k not in ('DM_GAMES_DIR', 'DM_GAMES_FIRST', 'XLATE_DEBUG', 'XLATE_REDUCED')}
    env['DM_GAME'] = title
    return subprocess.run([sys.executable, '-I', str(CHAIN)], env=env, capture_output=True, text=True, check=True).stdout.strip()


class ChainHeaders(unittest.TestCase):
    def test_committed_headers_hold_the_current_chain_version(self):
        stale = []
        for h in sorted((ROOT / 'dm/games').glob('*/dmsh_chain.h')):
            title = h.parent.name; want = chain_version(title)
            have = re.search(r'#define DMSH_CHAIN "(.*)"', h.read_text()).group(1)
            if have != want: stale.append(f'  {title}: header {have}, current {want}   fix: DM_GAME={title} python3 dm/gfx/tools/dmsh_chain.py --header')
        self.assertFalse(stale, 'stale dmsh_chain.h (a file the chain version covers changed); regenerate and commit each:\n' + '\n'.join(stale)
                         + '\nall at once: for d in dm/games/*/dmsh_chain.h; do DM_GAME=$(basename $(dirname $d)) python3 dm/gfx/tools/dmsh_chain.py --header; done')


if __name__ == '__main__': unittest.main()
