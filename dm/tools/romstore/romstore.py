#!/usr/bin/env python3
"""Chunk store for a game's RomFS: build one, check one, and copy one to a device. Format: dm/host/romstore.h; the host reads a store when DM_ROMFS names it.

  romstore.py build <RomFS dir> <out.dmstore> [--trace FSLOG ...] [--avg 16384] [--level 19] [--dict-size 262144] [--jobs 2]
  romstore.py verify <store> <RomFS dir> [--jobs 2]
  romstore.py install <store> --device <udid> --bundle <bundle id>     copies it to the app's Documents/romfs.dmstore (the app prefers it to Documents/romfs)

build: every file is cut with FastCDC (romstore_tool scan), identical chunks are kept once (SHA-256), one zstd dictionary is trained on a sample of the chunks,
and each chunk is compressed on its own (zstd frame with a content checksum). Chunks are written in the order a boot first read them (--trace: DM_FSLOG files of
runs on this RomFS, any mount name), then in path order, so a boot reads the pack mostly forward. Needs python-zstandard:
nix-shell -p 'python3.withPackages(ps:[ps.zstandard])'. --jobs bounds the compression threads (zstd itself runs single-threaded).
verify: romstore_tool verify, which reads every file back through the host's own reader and compares it with the directory."""
import argparse
import bisect
import concurrent.futures
import hashlib
import os
import random
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
HEADER = struct.Struct('<8sIIQQIIIIII32s40s')   # romstore_header
DIR = struct.Struct('<IIIIII')
FILE = struct.Struct('<IIIIQ')
CHUNK = struct.Struct('<QII')
MAGIC, VERSION, PAGE = b'DMRSTORE', 1, 16384
GUEST_NAME_XATTR = 'org.d2rmobile.guest-name'   # case-collision aliases (dm/host/hle_fs.c)


def say(*a):
    print(*a, flush=True)


def tool():
    subprocess.run(['make', '-s', '-C', str(HERE)], check=True)
    return str(HERE / 'build' / 'romstore_tool')


def guest(parent, name):
    if name.startswith(b'.dm-case-'):
        try: return os.getxattr(os.path.join(parent, name), GUEST_NAME_XATTR, follow_symlinks=False)
        except OSError: pass
    return name


def walk(root):
    """Directories in breadth-first order, each one's subdirectories and files contiguous and sorted by guest name (bytes)."""
    dirs = [dict(name=b'', parent=0, phys=os.fsencode(root))]
    files = []
    for i, d in enumerate(dirs):   # dirs grows while it is walked
        subs, fs = [], []
        with os.scandir(d['phys']) as it:
            for e in it:
                g = guest(d['phys'], e.name)
                if e.is_dir(follow_symlinks=False): subs.append((g, e.path))
                elif e.is_file(follow_symlinks=False): fs.append((g, e.path))
                else: sys.exit(f'not a file or directory: {os.fsdecode(e.path)}')
        subs.sort(); fs.sort()
        d['dir_first'], d['dir_count'] = len(dirs), len(subs)
        d['file_first'], d['file_count'] = len(files), len(fs)
        dirs += [dict(name=g, parent=i, phys=p) for g, p in subs]
        files += [dict(name=g, parent=i, phys=p) for g, p in fs]
    return dirs, files


def guest_path(dirs, f):
    parts, d = [f['name']], f['parent']
    while d: parts.append(dirs[d]['name']); d = dirs[d]['parent']
    return b'/' + b'/'.join(reversed(parts))


def scan(files, avg):
    """Per file, its chunk list [(sha, length)] from romstore_tool scan."""
    p = subprocess.Popen([tool(), 'scan', str(avg)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    feeder = threading.Thread(target=lambda: (p.stdin.write(b'\0'.join(f['phys'] for f in files) + b'\0'), p.stdin.close()))
    feeder.start()
    data = p.stdout.read(); feeder.join()
    if p.wait(): sys.exit('romstore_tool scan failed')
    out = [[] for _ in files]
    for fi, ln, sha in struct.iter_unpack('<II32s', data): out[fi].append((sha, ln))
    return out


def read_trace(paths, by_path):
    """(file number, offset, length) of every read in DM_FSLOG files, in time order; reads of paths outside this RomFS are skipped."""
    reads = []
    for p in paths:
        with open(p, 'rb') as f:
            for line in f:
                c = line.rstrip(b'\n').split(b'\t')
                if len(c) < 4 or b':' not in c[1]: continue
                fi = by_path.get(b'/' + c[1].split(b':', 1)[1].lstrip(b'/'))
                if fi is not None: reads.append((float(c[0]), fi, int(c[2]), int(c[3])))
    reads.sort(key=lambda r: r[0])
    return [r[1:] for r in reads]


def train(chunks, src, size, level, jobs):
    """One dictionary from up to 1500 slices of 8 KiB of randomly chosen chunks (the sampling the space study measured); None when there is too little data."""
    import zstandard
    rng = random.Random(1)
    pick = rng.sample(range(len(chunks)), min(1500, len(chunks)))
    samples = []
    for c in pick:
        b = src.read(c); o = rng.randrange(max(1, len(b) - 8192)); samples.append(b[o:o + 8192])
    if not size or sum(map(len, samples)) < 8 * size: return None
    return zstandard.train_dictionary(size, samples, level=level, threads=jobs)


class Source:
    """Reads a chunk's bytes from its first occurrence; one small cache of open files per thread."""
    def __init__(self, files, where):
        self.files, self.where, self.tls = files, where, threading.local()

    def read(self, c):
        fi, off, ln = self.where[c]
        fds = self.tls.__dict__.setdefault('fds', {})
        fd = fds.get(fi)
        if fd is None:
            if len(fds) >= 32:
                for k in list(fds)[:16]: os.close(fds.pop(k))
            fd = fds[fi] = os.open(self.files[fi]['phys'], os.O_RDONLY)
        b = os.pread(fd, ln, off)
        if len(b) != ln: sys.exit(f'short read: {os.fsdecode(self.files[fi]["phys"])}')
        return b


def pad8(b):
    return b + b'\0' * (-len(b) % 8)


def build(a):
    import zstandard
    t0 = time.time()
    dirs, files = walk(a.romfs)
    total = sum(os.stat(f['phys']).st_size for f in files)
    say(f'walk: {len(dirs)} directories, {len(files)} files, {total / 1e9:.3f} GB')
    lists = scan(files, a.avg)
    ids, where, refs = {}, [], []   # unique chunk number per SHA-256, (file, offset, length) of its first occurrence, per file [(end, chunk)]
    for fi, lst in enumerate(lists):
        off, r = 0, []
        for sha, ln in lst:
            c = ids.get(sha)
            if c is None: c = ids[sha] = len(where); where.append((fi, off, ln))
            off += ln; r.append((off, c))
        if off != os.stat(files[fi]['phys']).st_size: sys.exit(f'scan does not cover {os.fsdecode(files[fi]["phys"])}')
        refs.append(r)
    del lists
    unique = sum(w[2] for w in where)
    say(f'scan: {sum(map(len, refs))} chunk references, {len(where)} unique chunks, {unique / 1e9:.3f} GB unique ({100 * (1 - unique / max(total, 1)):.1f}% duplicate) [{time.time() - t0:.0f} s]')
    # pack order: first read in the traces, then path order
    order, seen = [], bytearray(len(where))
    def take(c):
        if not seen[c]: seen[c] = 1; order.append(c)
    if a.trace:
        by_path = {guest_path(dirs, f): i for i, f in enumerate(files)}
        reads = read_trace(a.trace, by_path)
        for fi, off, ln in reads:
            ends = [e for e, _ in refs[fi]]
            k = bisect.bisect_right(ends, off)
            while k < len(ends) and (k == 0 or ends[k - 1] < off + ln):
                take(refs[fi][k][1]); k += 1
        say(f'trace: {len(reads)} reads place {len(order)} chunks first')
    for r in refs:
        for _, c in r: take(c)
    src = Source(files, where)
    t1 = time.time()
    d = train(where, src, a.dict_size, a.level, a.jobs)
    dict_bytes = d.as_bytes() if d else b''
    say(f'dictionary: {len(dict_bytes)} bytes [{time.time() - t1:.0f} s]')
    if d: d.precompute_compress(level=a.level)
    tls = threading.local()
    def compress(batch):
        z = getattr(tls, 'z', None)
        if z is None: z = tls.z = zstandard.ZstdCompressor(level=a.level, dict_data=d, write_checksum=True, write_content_size=False, write_dict_id=False)
        return [z.compress(src.read(c)) for c in batch]
    tmp = a.out + '.tmp'
    pack_off, csize = [0] * len(where), [0] * len(where)
    with open(tmp, 'wb') as out, concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        out.write(b'\0' * HEADER.size)
        pos, done, t2 = HEADER.size, 0, time.time()
        batches = [order[i:i + 64] for i in range(0, len(order), 64)]
        pending = []
        for i in range(len(batches) + 4 * a.jobs):   # a bounded window of batches in flight, written in order
            if i < len(batches): pending.append((batches[i], ex.submit(compress, batches[i])))
            if pending and (i >= 4 * a.jobs or i >= len(batches)):
                batch, fut = pending.pop(0)
                for c, fr in zip(batch, fut.result()):
                    pack_off[c], csize[c] = pos, len(fr); out.write(fr); pos += len(fr)
                done += len(batch)
                if done % 8192 < 64 or done == len(order):
                    say(f'compress {done}/{len(order)} chunks, {pos / 1e9:.3f} GB written [{time.time() - t2:.0f} s]')
        out.write(b'\0' * (-pos % PAGE)); index_off = pos + (-pos % PAGE)
        # renumber chunks in pack order, so the chunk table runs forward through the file
        new = [0] * len(where)
        for i, c in enumerate(order): new[c] = i
        names, name_off = bytearray(), {}
        def name(b):
            if b not in name_off: name_off[b] = len(names); names.extend(b + b'\0')
            return name_off[b]
        dir_tab = b''.join(DIR.pack(name(x['name']), x['parent'], x['dir_first'], x['dir_count'], x['file_first'], x['file_count']) for x in dirs)
        file_tab, ref_end, ref_chunk = [], [], []
        for f, r in zip(files, refs):
            file_tab.append(FILE.pack(name(f['name']), f['parent'], len(ref_end), len(r), r[-1][0] if r else 0))
            ref_end += [e for e, _ in r]; ref_chunk += [new[c] for _, c in r]
        chunk_tab = b''.join(CHUNK.pack(pack_off[c], csize[c], where[c][2]) for c in order)
        index = (pad8(dir_tab) + pad8(b''.join(file_tab)) + struct.pack(f'<{len(ref_end)}Q', *ref_end) + pad8(struct.pack(f'<{len(ref_chunk)}I', *ref_chunk))
                 + chunk_tab + pad8(dict_bytes) + bytes(names))
        max_chunk = max((w[2] for w in where), default=0)
        head = HEADER.pack(MAGIC, VERSION, HEADER.size, index_off, len(index), len(dirs), len(files), len(ref_end), len(where), len(dict_bytes), max_chunk, b'\0' * 32, b'\0' * 40)
        sha = hashlib.sha256(head[:56] + index).digest()
        out.write(index); out.seek(0)
        out.write(HEADER.pack(MAGIC, VERSION, HEADER.size, index_off, len(index), len(dirs), len(files), len(ref_end), len(where), len(dict_bytes), max_chunk, sha, b'\0' * 40))
        out.flush(); os.fsync(out.fileno())
    os.replace(tmp, a.out)
    size = os.path.getsize(a.out)
    say(f'done: {a.out}: {size / 1e9:.3f} GB from {total / 1e9:.3f} GB ({100 * size / max(total, 1):.1f}%), pack {(index_off - HEADER.size) / 1e9:.3f} GB, index {len(index) / 1e6:.1f} MB, '
        f'largest chunk {max_chunk} bytes [{time.time() - t0:.0f} s]')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build'); b.add_argument('romfs'); b.add_argument('out')
    b.add_argument('--trace', action='append', default=[]); b.add_argument('--avg', type=int, default=16384)
    b.add_argument('--level', type=int, default=19); b.add_argument('--dict-size', type=int, default=262144); b.add_argument('--jobs', type=int, default=2)
    v = sub.add_parser('verify'); v.add_argument('store'); v.add_argument('romfs'); v.add_argument('--jobs', type=int, default=2)
    i = sub.add_parser('install'); i.add_argument('store'); i.add_argument('--device', required=True); i.add_argument('--bundle', required=True)
    a = ap.parse_args()
    if a.cmd == 'build': build(a)
    elif a.cmd == 'verify': sys.exit(subprocess.run([tool(), 'verify', a.store, a.romfs, str(a.jobs)]).returncode)
    else:
        sys.exit(subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', a.device, '--domain-type', 'appDataContainer', '--domain-identifier', a.bundle,
                                 '--source', a.store, '--destination', 'Documents/romfs.dmstore']).returncode)


if __name__ == '__main__':
    main()
