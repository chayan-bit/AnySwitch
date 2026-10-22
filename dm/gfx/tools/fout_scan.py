#!/usr/bin/env python3
# fout_scan.py <dmsh_b version dir> > rows.tsv: integer fragment outputs in a game with no PC reflection, from the translated MSL (the Mac cache).
# The translator declares every colour output float4; a Maxwell pixel shader that writes an integer target stores the integer bits into the output register.
# An output whose every written component is `as_type<float>(_N)` with `_N = uint(...)` / `int(...)` (an F2I conversion) holds integer values: no float target is written that way.
# Prints shader_facts_manual.tsv rows (`<key>\t{"fout":{"<slot>":"uint"|"sint"}}`); after adding them, the shader split merges them and the shader build retranslates those shaders.
# Only conversions count: plain bit moves stay out (register reuse keeps float bits in integer variables, see docs/internals/04-graphics.md "Integer fragment outputs").
import glob, os, re, sys

OUT = re.compile(r'float4 (m_\d+) \[\[color\((\d)\)\]\]')
CONV = re.compile(r'\b(?:uint|int) (_\d+) = (u?int)\(')
CAST = re.compile(r'as_type<float>\((_\d+)\)')

def int_outputs(msl):
    """{slot: 'uint' | 'sint'} for each colour output written only from F2I conversions."""
    if 'fragment main0_out' not in msl: return {}
    conv, found = dict(CONV.findall(msl)), {}
    for name, slot in OUT.findall(msl):
        kinds = set()
        for rhs in re.findall(r'out\.%s(?:\.[xyzw])? = (.*);' % name, msl):
            m = CAST.fullmatch(rhs.strip())
            kinds.add(conv.get(m.group(1)) if m else None)
        if kinds in ({'uint'}, {'int'}): found[slot] = 'uint' if kinds == {'uint'} else 'sint'
    return found

def demo():
    msl = ('struct main0_out { float4 m_1 [[color(0)]]; float4 m_2 [[color(1)]]; };\nfragment main0_out main0()\n'
           'uint _5 = uint(_4);\nuint _6 = as_type<uint>(_3);\nout.m_1.x = as_type<float>(_6);\nout.m_2.x = as_type<float>(_5);\nout.m_2.y = as_type<float>(_5);\n')
    assert int_outputs(msl) == {'1': 'uint'}, int_outputs(msl)   # colour 0 only moves bits: not counted

if __name__ == '__main__':
    demo()
    if len(sys.argv) != 2: sys.exit(__doc__ or 'usage: fout_scan.py <dmsh_b version dir>')
    rows = {}
    for f in sorted(glob.glob(os.path.join(sys.argv[1], '*_b.metal'))):
        found = int_outputs(open(f).read())
        if found: rows[os.path.basename(f)[:16]] = found
    for k, found in rows.items():
        print('%s\t{"fout":{%s}}' % (k, ','.join('"%s":"%s"' % s for s in sorted(found.items()))))
    print(f'{len(rows)} shaders with integer outputs', file=sys.stderr)
