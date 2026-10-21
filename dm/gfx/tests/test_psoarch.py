#!/usr/bin/env python3
# Precompiled pipeline archive end to end, no game files: a small MSL library built as the chain builds b-<V>/ (Mac and iOS folders with <key>_b.metallib / .json / .metal, compiled by
# dmsh_build.py's and ios_metal.py's conventions) -> t_psoarch harvests and looks up -> tools/dmsh_psoarch.py compiles the harvest with metal-tt for macOS (looked up again by t_psoarch:
# hits) and for iOS against the iOS library (an archive with Apple GPU slices). PSOARCH_WORK=dir keeps the files for a look
import os, sys, json, shlex, subprocess, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../ios/tools')); import ios_metal
MAC_RECORD = 'xcrun -sdk macosx metal -c -fpreserve-invariance; xcrun -sdk macosx metallib'   # = dmsh_build.py MAC_RECORD (that script builds on import)
MSL = '''#include <metal_stdlib>
using namespace metal;
struct V { half4 p [[attribute(0)]]; };
struct O { float4 p [[position]]; };
vertex O vmain(V v [[stage_in]]) { O o; o.p = float4(v.p); return o; }
fragment float4 fmain() { return float4(1, 0, 0, 1); }
constant int k [[function_constant(0)]];
fragment float4 fspec() { return float4(k, 0, 0, 1); }
kernel void kmain(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] *= 2; }
'''


def chain_lib(d, rec):   # <d>/k0_b.metallib the way the chain builds it: compile to AIR, link with metallib, the convention recorded in the json
    os.makedirs(d, exist_ok=True); src = os.path.join(d, 'k0_b.metal'); open(src, 'w').write(MSL)
    cc, ln = (shlex.split(x) for x in rec.split(';'))
    subprocess.run([*cc, src, '-o', src + '.air'], check=True); subprocess.run([*ln, src + '.air', '-o', os.path.join(d, 'k0_b.metallib')], check=True)
    json.dump({'chain_metal': rec}, open(os.path.join(d, 'k0_b.json'), 'w'))
    return os.path.join(d, 'k0_b.metallib')


def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode: sys.exit(f'FAIL {" ".join(a)}\n{r.stdout}{r.stderr}')
    return r.stdout


with tempfile.TemporaryDirectory() as w:
    w = os.environ.get('PSOARCH_WORK') or w
    mac, ios = os.path.join(w, 'mac'), os.path.join(w, 'ios')
    maclib = chain_lib(mac, MAC_RECORD); chain_lib(ios, ios_metal.RECORD)
    t = os.path.join(HERE, 't_psoarch'); tool = os.path.join(HERE, '../tools/dmsh_psoarch.py'); harv = os.path.join(w, 'harvest.metallib')
    run(t, maclib, w)
    arch = subprocess.run(['xcrun', 'metal-arch'], capture_output=True, text=True).stdout.split()[0]   # this Mac's GPU, so the macOS build stays one slice
    run(sys.executable, tool, harv, '--libs', mac, '--target-libs', mac, '--msl', mac, '--platform', 'macos', '--arch', arch, '-o', os.path.join(w, 'mac_tt.metallib'))
    run(t, maclib, w, os.path.join(w, 'mac_tt.metallib'))
    out = run(sys.executable, tool, harv, '--libs', mac, '--target-libs', ios, '--msl', mac, '--platform', 'ios', '-o', os.path.join(w, 'ios_tt.metallib'))
    assert 'applegpu_' in out.splitlines()[-1], 'the iOS archive has no Apple GPU slice'
print('PSOARCH TOOL OK harvest -> metal-tt macOS archive hits; iOS archive built against the iOS library')
