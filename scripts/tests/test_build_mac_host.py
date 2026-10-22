"""build_ipa_from_nsp.build_mac_host: every library on the host's link line is built before the dry-run line is handed to clang.
A stand-in dm/host/Makefile with libraries and a link rule (no game, no clang). Run: python3 -I scripts/tests/test_build_mac_host.py"""
import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_ipa_from_nsp as b

MAKEFILE = '''LIBS=%s
gen/%%.a:
\t@mkdir -p $(dir $@); touch $@
dmhost: $(LIBS)
\tclang -o $@ main.c $(LIBS) -framework Cocoa
'''


class MacHost(unittest.TestCase):
    def build(self, libs):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name) / 'repo'; host = repo / 'dm/host'; host.mkdir(parents=True)
        (host / 'Makefile').write_text(MAKEFILE % ' '.join(libs))
        links = []
        real_run = b.run

        def run(cmd, log, **kw):   # make runs for real; the link line is only recorded, with the state of its libraries at that moment
            if str(cmd[0]) != 'make':
                links.append([(l, (host / l).is_file()) for l in cmd if str(l).endswith('.a')]); return
            real_run(cmd, log, **kw)
        b.run, orig = run, b.run
        self.addCleanup(setattr, b, 'run', orig)
        b.build_mac_host(repo, Path(tmp.name) / 'out/dmhost', dict(os.environ), Path(tmp.name) / 'logs')
        return links

    def test_builds_every_library_the_link_line_names(self):
        self.assertEqual(self.build(['gen/vpx/libvpx.a', 'gen/zstd/libzstd.a', 'gen/next/libnext.a']),
                         [[('gen/vpx/libvpx.a', True), ('gen/zstd/libzstd.a', True), ('gen/next/libnext.a', True)]])


if __name__ == '__main__': unittest.main()
