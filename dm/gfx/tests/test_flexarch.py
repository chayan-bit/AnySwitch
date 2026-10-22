#!/usr/bin/env python3
# dmsh_flexarch.py archive policy, no game files: tiers filled in order (harvested and learned, accelerator pairs, interface pairs) until the size cap, which counts every GPU
# architecture the archive is built for (each one holds its own copy of every pipeline)
import os, sys, types, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../tools'))
import dmsh_flexarch as F

d = tempfile.mkdtemp()
def w(name, text): p = os.path.join(d, name); open(p, 'w').write(text); return p
rec = F.pair_record   # a harvested record with no state: the same record as that pair
user = w('pso_user.tsv', 'S\tx\t0\n' + rec('h1', 'h2') + '\n' + rec('h1', 'h2') + '\n')        # one harvested record (twice), a shader line
pairs = w('program_pairs.tsv', '# header\nv1\tp1\tsplit\nv2\tp2\tiface\nv3\tp3\tiface,split\nh1\th2\tsplit\n')
table = w('shader_pairs.tsv', 'v4\tp4\n')
o = types.SimpleNamespace(records=[user], pairs=[pairs, table], max_mb=0, archs=['g1'])
t = F.tiers(o)
assert [len(x) for x in t] == [1, 3, 1], [len(x) for x in t]   # h1/h2 only once (harvested wins), v1 v3 v4 accelerator, v2 interface-only
o.max_mb = 1; F.KB_EACH = 1024 // 3                              # room for 3 records on one GPU architecture: the harvested one and 2 accelerator pairs
recs, nh = F.records(o)
assert (len(recs), nh) == (3, 1) and recs[0] == t[0][0] and recs[1:] == t[1][:2], (len(recs), nh)
o.archs = ['g1', 'g2', 'g3']; F.KB_EACH = 1024 // 6               # room for 6 records on one architecture, so 2 across three
recs, nh = F.records(o)
assert (len(recs), nh) == (2, 1), (len(recs), nh)
o.max_mb = 0; assert len(F.records(o)[0]) == 5                   # no cap: every record, whatever the architectures
# Measured cut: one architecture weighed 100 MB, three are built under a 150 MB cap: half the records, less the margin; a fit or no cap keeps all; never all when over
assert F.trim(1000, 100, 3, 150) == int(1000 * 150 / 300 * F.TRIM_MARGIN), F.trim(1000, 100, 3, 150)
assert F.trim(1000, 40, 3, 150) == 1000 and F.trim(1000, 400, 3, 0) == 1000
assert F.trim(10, 101, 1, 100) == 8 and F.trim(10, 100.5, 1, 100) < 10 and F.trim(1, 500, 2, 100) == 0
print('FLEXARCH OK tiers', [len(x) for x in t], 'cap keeps 3 on one GPU architecture, 2 on three; measured cut in proportion')
