"""Community ExeFS patches (Atmosphere layout exefs_patches/<name>/<build ID>.ips, .pchtxt) for patch_nso.py. Standard library only.
Parsers ported from Ryujinx (MIT, Copyright (c) Ryujinx Team and Contributors), src/Ryujinx.HLE/Loaders/Mods/IPSPatcher.cs, IPSwitchPatcher.cs and MemPatch.cs
(local clone ~/Code/vendor/ryujinx): same formats and semantics, except that malformed input, bad offsets and overlapping records are errors here (Ryujinx warns and goes on).
A patch directory is read from the user's disk only; nothing is fetched and no patch file belongs in the repository.

Offsets: IPS and .pchtxt offsets count the 0x100-byte NSO header; the image offset is the offset minus 0x100. A .pchtxt adds its `@flag offset_shift` to each offset first
(module-relative addresses become header-relative with `@flag offset_shift 0x100`).
Matching: an IPS file by its name (text before the first dot), a .pchtxt by its `@nsobid-` line; both compare the build ID with trailing zeros removed (the NSO header holds a 32-byte ID)."""
import os
from pathlib import Path

NSO_HEADER = 0x100


class PatchError(Exception):
    pass


def parse_ips(data, label='ips'):
    """IPS ('PATCH' ... 'EOF') and IPS32 ('IPS32' ... 'EEOF') -> [(offset, bytes)]; RLE records are expanded. Bytes after the trailer are ignored"""
    if data[:5] == b'IPS32': is32, tail, o = True, b'EEOF', 5
    elif data[:5] == b'PATCH': is32, tail, o = False, b'EOF', 5
    else: raise PatchError(f'{label}: not an IPS file (no PATCH / IPS32 header)')
    out, w = [], 4 if is32 else 3
    def take(n):
        nonlocal o
        if o + n > len(data): raise PatchError(f'{label}: truncated record at byte {o:#x}')
        o += n; return data[o - n:o]
    while True:
        field = take(len(tail))
        if field == tail: return out
        off = int.from_bytes(field[:w], 'big')
        size = int.from_bytes(take(2), 'big')
        if size: out.append((off, bytes(take(size))))
        else:   # RLE: 16-bit count, one fill byte
            n = int.from_bytes(take(2), 'big')
            out.append((off, bytes(take(1)) * n))


def _preprocess(line):
    """Comment removal ('//', and Ryujinx stops at any '/') and C escapes inside quoted strings; quotes are kept"""
    out, state = [], 'n'
    esc = {'a': '\a', 'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v', '\\': '\\'}
    for c in line:
        if state == 'n':
            if c == '/': break
            if c == '"': state = 's'
        elif state == 's':
            if c == '"': state = 'n'
            elif c == '\\': state = 'e'; continue
        else:
            state = 's'; c = esc.get(c, '?')
        out.append(c)
    return ''.join(out).strip()


def _hex(s):
    try: return bytes.fromhex(s) if len(s) % 2 == 0 else None
    except ValueError: return None


def pchtxt_bid(text):
    """The `@nsobid-` build ID of a .pchtxt (trailing zeros removed, lower case), None when the first line is not one"""
    for line in text.splitlines():
        if line.strip():
            return line.strip()[8:].strip().rstrip('0').lower() if line.strip().startswith('@nsobid-') else None
    return None


def parse_pchtxt(text, label='pchtxt'):
    """IPSwitch text -> [(offset, bytes)] of the enabled sections, offset_shift added. A blank line ends a section's @enabled, @stop ends the file"""
    out, enabled, shift = [], False, 0
    for n, raw in enumerate(text.splitlines(), 1):
        if not raw.strip(): enabled = False; continue
        line = _preprocess(raw)
        if not line or line.startswith('#'): continue
        if line.startswith('@stop'): break
        if line.startswith('@enabled'): enabled = True
        elif line.startswith('@disabled'): enabled = False
        elif line.startswith('@flag'):
            tok = line.split(None, 2)
            if len(tok) < 2: raise PatchError(f'{label}:{n}: bad @flag')
            if tok[1] == 'offset_shift':
                try: shift = int(tok[2], 0)
                except (IndexError, ValueError): raise PatchError(f'{label}:{n}: bad offset_shift') from None
        elif line.startswith('@'): pass
        elif enabled:
            tok = line.split(None, 1)
            if len(tok) < 2: raise PatchError(f'{label}:{n}: expected "<hex offset> <hex bytes | \\"string\\">"')
            try: off = int(tok[0], 16) + shift
            except ValueError: raise PatchError(f'{label}:{n}: bad offset {tok[0]!r}') from None
            if tok[1][0] == '"': data = tok[1].strip('"').encode('ascii') + b'\0'
            elif (data := _hex(tok[1].replace(' ', ''))) is None: raise PatchError(f'{label}:{n}: bad hex bytes {tok[1]!r}')
            out.append((off, data))
    return out


def _bid_match(a, b): return a.lower().rstrip('0') == b.lower().rstrip('0')


def discover(root, module_id):
    """[(label, [(offset, bytes)])] for every .ips / .pchtxt under root that targets this NSO module ID (32 bytes as hex), in path order; label = path relative to root"""
    if not os.path.isdir(root): raise PatchError(f'DM_EXEFS_PATCHES is not a folder: {root}')
    found = []
    for dp, dn, fn in os.walk(root):
        dn.sort()
        for f in sorted(fn):
            p, rel, ext = os.path.join(dp, f), os.path.relpath(os.path.join(dp, f), root), os.path.splitext(f)[1].lower()
            if ext == '.ips':
                if _bid_match(f.split('.')[0], module_id): found.append((rel, parse_ips(Path(p).read_bytes(), rel)))
            elif ext == '.pchtxt':
                text = Path(p).read_text(encoding='utf-8-sig', errors='replace')
                if (bid := pchtxt_bid(text)) is not None and _bid_match(bid, module_id): found.append((rel, parse_pchtxt(text, rel)))
    return found


def load(root, module_id, image_end, reserved=()):
    """Patches for a module -> (summary [(label, records, bytes)], writes [(image offset, bytes, label)] sorted by offset).
    image_end: end of the file-backed image (data segment end); reserved: [(image offset, length, what)] other rewrites that own those bytes.
    Errors (PatchError): an offset inside the NSO header or beyond the image, overlap with a reserved range, overlap of two records that write different bytes"""
    summary, writes = [], []
    for label, recs in discover(root, module_id):
        summary.append((label, len(recs), sum(len(b) for _, b in recs)))
        for off, data in recs:
            if not data: continue
            if off < NSO_HEADER: raise PatchError(f'{label}: offset {off:#x} is inside the NSO header (the first {NSO_HEADER:#x} bytes)')
            if off - NSO_HEADER + len(data) > image_end: raise PatchError(f'{label}: record at {off:#x} (+{len(data):#x}) ends beyond the image ({image_end + NSO_HEADER:#x})')
            writes.append((off - NSO_HEADER, data, label))
    writes.sort(key=lambda w: w[0])
    for off, data, label in writes:
        for ro, rl, what in reserved:
            if off < ro + rl and ro < off + len(data): raise PatchError(f'{label}: record at image offset {off:#x} (+{len(data):#x}) overlaps a {what} at {ro:#x}')
    owner = {}   # byte -> (value, label), only to compare overlaps; records are small next to the image
    for off, data, label in writes:
        for i, b in enumerate(data):
            if (prev := owner.get(off + i)) and prev[0] != b: raise PatchError(f'image offset {off + i:#x}: {prev[1]} and {label} write different bytes')
            owner[off + i] = (b, label)
    return summary, writes
