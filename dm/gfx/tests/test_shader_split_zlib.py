#!/usr/bin/env python3
# shader_split.py zlib_streams, no game files: a GLSLC output compressed inside a module image is found and split, and bytes that only start like a zlib header are skipped
import os, struct, sys, zlib
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../tools')); import shader_split as s

ctl = bytearray(0x850); ctl[:4] = s.CTL_MAGIC; struct.pack_into('<I', ctl, 0x20, 0x850)
code = bytearray(0x100); code[:4] = s.GFX_MAGIC; struct.pack_into('<I', code, 0x30, 5 << 10)   # SPH stage 5: pixel
struct.pack_into('<I', ctl, 0x704, len(code))
out = bytearray(0x48) + ctl + code; out[:4] = bytes.fromhex('91688619'); struct.pack_into('<I', out, 0x44, len(out))
img = b'\x78\x9c' + bytes(64) + b'x\xdaJUNK' + zlib.compress(b'.tfxo file\0' + bytes(out)) + b'\x78\x01tail'

zs = s.zlib_streams(img)
assert [o for o, _ in zs] == [img.index(b'x\x9c', 2)], [hex(o) for o, _ in zs]
found = s.glslc_shaders(zs[0][1], 'main#zlib', need=False)
assert [(st, bytes(c), bytes(k)) for _, st, c, k in found] == [('ps', bytes(ctl), bytes(code))], found
print('ok: one stream, one pixel shader', s.skey(ctl, code))
