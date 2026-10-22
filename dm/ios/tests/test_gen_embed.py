# gen_embed.py --dylib on a synthetic module: the code dylib has one executable segment (__TEXT) holding both code blocks, the module's W segment is rw, every block is 16 KB aligned with the expected size,
# __dminfo says what the image is, and the dylib loads with dlopen and exports _dm_code_info (what loader.c code_image looks up). macOS only (xcrun, otool).
import ctypes, os, re, subprocess, sys, tempfile
from pathlib import Path
GEN = Path(__file__).resolve().parents[1] / 'tools/gen_embed.py'
PG = 0x4000
ABI = re.search(r'^#define DM_CODE_ABI (\d+)', (GEN.parents[2] / 'host/dm_abi.h').read_text(), re.M).group(1)

def fake_module(d, n):   # text ends at 0x100 (x0 = one page), key page at 0x4000, patch area at 0x8000 (x1 = one page)
    (d / f'{n}.fixups.tsv').write_text(''.join(f'# {k}\t{v}\n' for k, v in
        (('PATCH_OFF', '0x8000'), ('KEY_PAGE_OFF', '0x4000'), ('KEY_PAGE_SIZE', '0x4000'), ('TEXT_END', '0x100'), ('BUILD_ID', '00112233445566778899aabbccddeeff'))))
    (d / f'{n}.patched.bin').write_bytes(bytes([0xC0, 0x03, 0x5F, 0xD6]) * 0x40 + bytes(0x8000 - 0x100) + bytes(0x100))

def segments(dylib):   # {segment: (initprot, [(section, addr, size)])}
    segs, cur = {}, None
    for l in subprocess.run(['otool', '-l', dylib], capture_output=True, text=True, check=True).stdout.splitlines():
        l = l.split()
        if l[:2] == ['cmd', 'LC_SEGMENT_64']: cur = None
        elif l[:1] == ['segname'] and cur is None: cur = l[1]; segs[cur] = [0, []]
        elif l[:1] == ['initprot'] and cur: segs[cur][0] = int(l[1], 16)
        elif l[:1] == ['sectname']: sect = l[1]
        elif l[:1] == ['addr'] and cur: addr = int(l[1], 16)
        elif l[:1] == ['size'] and cur: segs[cur][1].append((sect, addr, int(l[1], 16)))
    return segs

def main():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t); fake_module(d, 'main')
        dylib = d / 'code/macos.dylib'; dylib.parent.mkdir()
        r = subprocess.run([sys.executable, '-I', str(GEN), str(d), str(d / 'embed.S'), 'main', '--title', '0100000000000000', '--dylib', str(dylib), '--target', 'macos'], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        assert r.stdout.split() == ['-Wl,-segprot,__DMmainW,rw,rw'], r.stdout
        segs = segments(str(dylib))
        execs = [s for s, (p, _) in segs.items() if p & 4]
        assert execs == ['__TEXT'], segs
        assert segs['__DMmainW'][0] == 3, segs['__DMmainW']
        sects = {s: (a, z) for seg in segs.values() for s, a, z in seg[1]}
        for s, want in (('__dmmainx0', PG), ('__img', PG), ('__dmmainx1', PG)):
            a, z = sects[s]
            assert z == want and a % PG == 0, (s, hex(a), hex(z))
        assert '__dminfo' in {s for s, _, _ in segs['__DATA'][1]}, segs['__DATA']
        lib = ctypes.CDLL(str(dylib), mode=os.RTLD_LOCAL)   # dlopen, then the symbol loader.c code_image looks up: the __dminfo text
        info = ctypes.string_at(ctypes.addressof(ctypes.c_char.in_dll(lib, 'dm_code_info'))).decode()
        assert info == f'code_abi {ABI}\ntitle 0100000000000000\nmodule main 00112233445566778899aabbccddeeff\n', info
        bad = subprocess.run([sys.executable, '-I', str(GEN), str(d), str(d / 'x.S'), 'main', '--title', 'nope'], capture_output=True, text=True)
        assert bad.returncode != 0 and '--title' in bad.stderr, bad.stderr
    print('test_gen_embed: ok')

if __name__ == '__main__':
    main()
