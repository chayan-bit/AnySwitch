# Generate the embedded assembly: compile the rewritten module image into the executable, with code going into the single executable segment __TEXT only (Apple ITMS-90999: only one segment with execute permission is allowed).
#   __TEXT,__dm<name>x0   original text: [0, round16K(TEXT_END)) (includes part of the first ro page, read-only)
#   __DM<name>W,__img     RW segment: [round16K(TEXT_END), PATCH_OFF), rest of ro + data + bss (relocations land only here)
#   __TEXT,__dm<name>x1   patch area: [PATCH_OFF, round16K(end of file))
#   __TEXT,__dm<name>x2   only with a back patch area (patch_nso.py TWO, a text longer than a B reaches): the last BACK_LEN bytes of the file, mapped at BACK_OFF
#   __DATA,__dminfo       what the image is (symbol _dm_code_info): "code_abi <DM_CODE_ABI>", "title <title id>", then "module <name> <build id>" per module, one per line
#   Modules with the patch area before the base (negative PATCH_OFF, see patch_nso.py FAR): W is [round16K(TEXT_END), FILE_IMAGE_LEN), x1 is the patch area after FILE_IMAGE_LEN in the file; bss and the key page are not in the executable
# The three pieces are not adjacent in the executable; at run time the loader (loader.c map_image) reserves one contiguous address range and vm_remaps them back at their original relative positions (code pages share the signed pages, W is copy-on-write),
# so the run-time layout is byte-identical to the original image: PC-relative addressing between original code and data, relative jumps in the patch area, and the host's "base + original offset" references all need no change.
# The NRO modules the game loads at run time (nro.tsv beside the modules, dm/tools/nro_collect.py; Super Smash Bros. Ultimate: 98) are packed instead of getting sections of their own: a Mach-O
# file has at most 255 sections, and three per module would pass it. Their pieces follow each other, each 16K aligned, in __TEXT,__dm_nro_x0 / __DM_NRO_W,__img / __TEXT,__dm_nro_x1, and
# __DATA,__dm_nro_tab lists them: per module 32 bytes of name, then the offset and length of its x0, W and x1 pieces in their sections (u64 each); the loader maps each from there at start
# (loader.c nro_pieces). Rows named 'refused' (an online SDK the host never loads) have no module.
# --tag (an app holding several programs of a multi-program application, build_ipa.sh PROGRAMS_TSV): the program's sections are __dm<tag><name>x0 / __DM<tag><name>W / __dm<tag><name>x1 and
# __dm<tag>_nro_*, which the loader takes from DM_EMBED_TAG (main.m). --jit <jit.img> (a game whose code comes through nn::jit: dm/tools/jit_capture.py's image, beside the RomFS) puts that image in
# __TEXT,__dm<tag>_jit, which the host remaps as the code memory's start (hle_jit.c jit_map_image).
# The same assembly links either into the app executable (the per-game IPA) or, with --dylib, into a code dylib of its own (a pack's code/<platform>.dylib, which the host dlopens: DM_CODE).
# Usage: gen_embed.py <build output dir> <output .S> <module name...> --title <title id> [--tag <tag>] [--jit <jit.img>] [--dylib <out.dylib> --target ios|macos];
# link flags are printed to stdout (-segprot for the W segments)
import argparse, os, re, subprocess, sys
PG = 0x4000
HERE = os.path.dirname(os.path.abspath(__file__))
def r16(x): return (x + PG - 1) & ~(PG - 1)

def code_abi():
    m = re.search(r'^#define DM_CODE_ABI (\d+)', open(os.path.join(HERE, '../../host/dm_abi.h')).read(), re.M)
    if not m: sys.exit('gen_embed: no DM_CODE_ABI in dm/host/dm_abi.h')
    return int(m.group(1))

def header(out, n):
    return dict(l[2:].split() for l in open(f'{out}/{n}.fixups.tsv') if l.startswith('# '))

def pieces(out, n, hdr):   # the module's (x0, W, x1[, x2]) as (file start, end)
    te, po = int(hdr['TEXT_END'], 16), int(hdr['PATCH_OFF'], 16)
    ko, ks = int(hdr['KEY_PAGE_OFF'], 16), int(hdr['KEY_PAGE_SIZE'], 16)
    bin_ = os.path.abspath(f'{out}/{n}.patched.bin'); sz = os.path.getsize(bin_)
    a, end = r16(te), r16(sz)
    if po < 0:   # patch area before the base (patch_nso.py FAR): W ends at the end of data, the loader supplies zero pages for bss and the key page; in the file the patch area follows at FILE_IMAGE_LEN
        fl, bl = int(hdr['FILE_IMAGE_LEN'], 16), int(hdr.get('BACK_LEN', '0'), 16)
        assert fl % PG == 0 and a <= fl and ko % PG == 0 and ks == PG and ko >= fl and bl % PG == 0 and (not bl or sz % PG == 0)
        return bin_, sz, ((0, a), (a, fl), (fl, end - bl)) + (((end - bl, end),) if bl else ())
    assert po % PG == 0 and a <= ko and ko + ks <= po and ko % PG == 0 and ks == PG
    return bin_, sz, ((0, a), (a, po), (po, end))

def place(asm, bin_, sz, lo, hi):   # one piece, 16K aligned at both ends (vm_remap takes whole pages)
    fill = min(hi, sz) - lo
    asm += ['    .p2align 14', f'    .incbin "{bin_}", {lo:#x}, {fill:#x}']
    if hi - lo > fill: asm.append(f'    .space {hi - lo - fill:#x}')
    asm.append('    .p2align 14')

def nro_sections(out, tag, asm, flags):
    tab = os.path.join(out, 'nro.tsv')
    nros = [ln.split('\t')[0] for ln in open(tab) if ln.strip() and not ln.startswith('#') and not ln.startswith('refused\t')] if os.path.exists(tab) else []
    if not nros: return
    at, rows = [0, 0, 0], []
    for i, sect in enumerate((f'__TEXT,__dm{tag}_nro_x0', f'__DM{tag}_NRO_W,__img', f'__TEXT,__dm{tag}_nro_x1')):
        asm.append(f'    .section {sect}')
        for k, n in enumerate(nros):
            bin_, sz, parts = pieces(out, n, header(out, n)); lo, hi = parts[i]
            assert len(parts) == 3, f'NRO {n} has a back patch area, which the packed NRO sections do not hold'
            if i == 0: rows.append([n])
            rows[k] += [at[i], hi - lo]; at[i] += hi - lo
            place(asm, bin_, sz, lo, hi)
    asm += [f'    .section __DATA,__dm{tag}_nro_tab', '    .p2align 3']
    for r in rows:
        assert len(r[0]) < 32
        asm.append(f'    .ascii "{r[0]}"'); asm.append(f'    .space {32 - len(r[0])}')
        asm.append('    .quad ' + ', '.join(f'{v:#x}' for v in r[1:]))
    flags.append(f'-Wl,-segprot,__DM{tag}_NRO_W,rw,rw')

def assembly(out, names, title, tag='', jit=None):
    asm, flags, info = ['// Generated by dm/ios/tools/gen_embed.py; do not edit'], [], [f'code_abi {code_abi()}', f'title {title}']
    for n in names:
        hdr = header(out, n)
        bin_, sz, parts = pieces(out, n, hdr)
        for sect, (lo, hi) in zip((f'__TEXT,__dm{tag}{n}x0', f'__DM{tag}{n}W,__img', f'__TEXT,__dm{tag}{n}x1', f'__TEXT,__dm{tag}{n}x2'), parts):
            assert all(len(x) <= 16 for x in sect.split(','))
            asm.append(f'    .section {sect}'); place(asm, bin_, sz, lo, hi)
        flags.append(f'-Wl,-segprot,__DM{tag}{n}W,rw,rw')
        info.append(f'module {n} {hdr.get("BUILD_ID", "-")}')
    nro_sections(out, tag, asm, flags)
    if jit: asm.append(f'    .section __TEXT,__dm{tag}_jit'); place(asm, jit, os.path.getsize(jit), 0, r16(os.path.getsize(jit)))
    if not tag:   # the info block names one image (a code dylib reads it, loader.c code_image); a tagged program of a multi-program app shares the executable's, so it has none
        asm += ['    .section __DATA,__dminfo', '    .globl _dm_code_info', '_dm_code_info:', '    .asciz "' + ''.join(l + '\\n' for l in info) + '"']
    return '\n'.join(asm) + '\n', flags

def link(src, dst, target, title, flags):
    sdk, triple = {'ios': ('iphoneos', 'arm64-apple-ios26.0'), 'macos': ('macosx', 'arm64-apple-macos')}[target]
    cmd = ['xcrun', '--sdk', sdk, 'clang', '-target', triple, '-dynamiclib', '-install_name', f'@rpath/org.anyswitch.code.{title.lower()}.dylib', src, '-o', dst, '-Wl,-adhoc_codesign', *flags]   # linker-signed on both platforms (ld signs only macOS by default); the install tool re-signs for the device
    if subprocess.call(cmd): sys.exit(f'gen_embed: link of {dst} failed')

def main():
    ap = argparse.ArgumentParser(description='embed rewritten modules as signed code sections')
    ap.add_argument('out', help='build output dir (the rewriter\'s patched folder)')
    ap.add_argument('dst', help='output .S')
    ap.add_argument('names', nargs='+', help='module names')
    ap.add_argument('--title', required=True, help='title id, recorded in __dminfo and the dylib install name')
    ap.add_argument('--tag', default='', help='section tag of one program in a multi-program app (DM_EMBED_TAG)')
    ap.add_argument('--jit', help='nn::jit code image to embed (dm/tools/jit_capture.py)')
    ap.add_argument('--dylib', help='also link the assembly into this code dylib')
    ap.add_argument('--target', choices=('ios', 'macos'), help='platform of --dylib')
    a = ap.parse_args()
    if bool(a.dylib) != bool(a.target): ap.error('--dylib and --target go together')
    if a.dylib and a.tag: ap.error('--tag is for an app holding several programs, not a code dylib')
    if not re.fullmatch(r'[0-9A-Fa-f]{16}', a.title): ap.error(f'--title must be a 16-digit hex title id, not {a.title}')
    asm, flags = assembly(a.out, a.names, a.title.upper(), a.tag, a.jit and os.path.abspath(a.jit))
    open(a.dst, 'w').write(asm)
    if a.dylib: link(a.dst, a.dylib, a.target, a.title, flags)
    print(' '.join(flags))

if __name__ == '__main__':
    main()
