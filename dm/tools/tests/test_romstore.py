"""romstore.py build + romstore_tool verify on a synthetic RomFS (no game data): every file reads back through the host's reader byte for byte, duplicate
content is stored once, a traced read puts its chunks first in the pack, and damage to the pack or the index is caught.
Needs python-zstandard (nix-shell -p 'python3.withPackages(ps:[ps.zstandard])') and clang. Run: python3 -I dm/tools/tests/test_romstore.py"""
import hashlib
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import tempfile

TOOL = Path(__file__).resolve().parents[1] / 'romstore' / 'romstore.py'
HEADER = struct.Struct('<8sIIQQIIIIII32s40s')


def make_tree(root):
    rng = random.Random(7)
    blob = bytes(rng.getrandbits(8) for _ in range(300_000))
    text = b''.join(b'entry %d value %d name item_%03d\n' % (i, rng.randrange(1000), i % 97) for i in range(40_000))
    files = {
        'a/b/c/deep.bin': blob[:150_000],
        'a/b/copy.bin': blob[:150_000],                                  # identical to deep.bin: stored once
        'a/shifted.bin': b'xyz' + blob[1000:200_000],                     # same content at another offset: content-defined cuts still find it
        'a/text.txt': text,
        'empty.dat': b'',
        'top.bin': blob,
        'name with space/ünïcödé.dat': text[:5000],
    }
    for i in range(50): files[f'many/f{i:03d}.bin'] = blob[i * 100:i * 100 + 700 + i * 37]
    for p, b in files.items():
        q = root / p; q.parent.mkdir(parents=True, exist_ok=True); q.write_bytes(b)
    (root / 'emptydir').mkdir()
    return files


def run(*args, ok=True):
    r = subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True, text=True)
    if (r.returncode == 0) != ok: sys.exit(f'FAIL: romstore.py {" ".join(map(str, args))} exited {r.returncode}\n{r.stdout}\n{r.stderr}')
    return r.stdout + r.stderr


def index(store):
    b = Path(store).read_bytes(); h = HEADER.unpack_from(b, 0)
    _, _, _, ioff, isize, nd, nf, nr, nc, dsz, _, _, _ = h
    p = ioff + (-(nd * 24) % 8) + nd * 24
    files = [struct.unpack_from('<IIIIQ', b, p + 24 * i) for i in range(nf)]
    p += nf * 24 + (-(nf * 24) % 8)
    p += nr * 8
    ref_chunk = struct.unpack_from(f'<{nr}I', b, p)
    return dict(n_files=nf, n_refs=nr, n_chunks=nc, dict_size=dsz, files=files, ref_chunk=ref_chunk)


def main():
    with tempfile.TemporaryDirectory() as t:
        t = Path(t); root = t / 'romfs'; make_tree(root)
        trace = t / 'fslog.tsv'
        trace.write_text('0.5\tdata:/a/text.txt\t70000\t100\t0x0\n0.6\tsave0:/not/here\t0\t10\t0x0\n')
        store = t / 'game.dmstore'
        out = run('build', root, store, '--avg', 1024, '--dict-size', 4096, '--trace', trace)
        print(' ', [l for l in out.splitlines() if l.startswith('done:')][0])
        ix = index(store)
        assert ix['dict_size'] > 0, 'a dictionary was trained'
        assert ix['n_chunks'] < ix['n_refs'], 'duplicate chunks are stored once'
        # the traced read of a/text.txt at 70000 comes first in the pack: the file's chunk covering offset 70000 is chunk 0
        files = sorted(p for p in root.rglob('*') if p.is_file())
        print('  verify:', [l for l in run('verify', store, root).splitlines() if l.startswith('files ')][0])
        assert any(c == 0 for c in ix['ref_chunk']), 'chunk 0 is referenced'
        # find a/text.txt's references through the walk order: breadth-first, sorted by name
        order = []; q = [root]
        while q:
            d = q.pop(0); subs = sorted((p for p in d.iterdir() if p.is_dir()), key=lambda p: os.fsencode(p.name))
            order += sorted((p for p in d.iterdir() if p.is_file()), key=lambda p: os.fsencode(p.name)); q += subs
        fi = order.index(root / 'a' / 'text.txt'); _, _, first, cnt, size = ix['files'][fi]
        assert size == (root / 'a' / 'text.txt').stat().st_size
        assert 0 in ix['ref_chunk'][first:first + cnt], 'the traced chunk is first in the pack'
        assert len(files) == ix['n_files']
        # damage: one byte in the pack, then one byte in the index
        b = bytearray(store.read_bytes()); bad = t / 'bad.dmstore'
        b[HEADER.size + 40] ^= 0x55; bad.write_bytes(b)
        assert 'MISMATCH' in run('verify', bad, root, ok=False), 'a damaged chunk is reported'
        b = bytearray(store.read_bytes()); h = HEADER.unpack_from(b, 0); b[h[3] + 5] ^= 1; bad.write_bytes(b)
        assert 'checksum mismatch' in run('verify', bad, root, ok=False), 'a damaged index is refused at open'
        # a store without a dictionary (too little data to train one) reads back too
        small = t / 'small'; small.mkdir(); (small / 'one.bin').write_bytes(b'hello' * 10)
        run('build', small, t / 'small.dmstore', '--avg', 1024); assert index(t / 'small.dmstore')['dict_size'] == 0
        run('verify', t / 'small.dmstore', small)
        # a store does not hold a file the directory lacks
        extra = t / 'extra'; shutil.copytree(small, extra); (extra / 'two.bin').write_bytes(b'x')
        run('verify', t / 'small.dmstore', extra, ok=False)
    print('test_romstore: ok')


if __name__ == '__main__':
    main()
