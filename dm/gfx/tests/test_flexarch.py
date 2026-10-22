#!/usr/bin/env python3
# dmsh_flexarch.py archive policy, no game files: tiers filled in order (harvested and learned, accelerator pairs, interface pairs) until the size cap
import os, sys, types, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../tools'))
import dmsh_flexarch as F

d = tempfile.mkdtemp()
def w(name, text): p = os.path.join(d, name); open(p, 'w').write(text); return p
rec = F.pair_record   # a harvested record with no state: the same record as that pair
user = w('pso_user.tsv', 'S\tx\t0\n' + rec('h1', 'h2') + '\n' + rec('h1', 'h2') + '\n')        # one harvested record (twice), a shader line
pairs = w('program_pairs.tsv', '# header\nv1\tp1\tsplit\nv2\tp2\tiface\nv3\tp3\tiface,split\nh1\th2\tsplit\n')
table = w('shader_pairs.tsv', 'v4\tp4\n')
o = types.SimpleNamespace(records=[user], pairs=[pairs, table], platform='ios', max_mb=0)
t = F.tiers(o)
assert [len(x) for x in t] == [1, 3, 1], [len(x) for x in t]   # h1/h2 only once (harvested wins), v1 v3 v4 accelerator, v2 interface-only
o.max_mb = 1; F.KB_EACH['ios'] = 1024 // 3                      # room for 3 records: the harvested one and 2 accelerator pairs
recs, nh = F.records(o)
assert (len(recs), nh) == (3, 1) and recs[0] == t[0][0] and recs[1:] == t[1][:2], (len(recs), nh)
print('FLEXARCH OK tiers', [len(x) for x in t], 'cap keeps', len(recs))
