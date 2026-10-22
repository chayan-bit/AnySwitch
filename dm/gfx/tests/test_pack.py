#!/usr/bin/env python3
# Shader packs end to end, no game files: three shaders built as the chain builds b-<V>/ (<key>_b.metal / .metallib / .json, Mac convention) -> tools/dmsh_pack.py links them into two
# packs -> its --check (every entry point present in its pack, names unique, refl.bin slices equal the json) -> t_pack loads every key through the host's loader with the packs and
# with DM_SHADER_PACKS=off, and both give the same entry point, argument buffer length and layer flag. Needs DM_GAME (the chain version the host expects). PACK_WORK=dir keeps the files
import os, re, sys, json, shlex, subprocess, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
MAC_RECORD = 'xcrun -sdk macosx metal -c -fpreserve-invariance; xcrun -sdk macosx metallib'   # = dmsh_build.py MAC_RECORD
GAME = os.environ.get('DM_GAME') or sys.exit('DM_GAME is not set')
V = re.search(r'#define DMSH_CHAIN "(\w+)"', open(os.path.join(HERE, '../../games', GAME, 'dmsh_chain.h')).read()).group(1)
ARGS = '''struct spvDescriptorSetBuffer0 { constant float4* fp_c3 [[id(0)]]; texture2d<float> fp_t [[id(1)]]; sampler fp_s [[id(2)]]; };
'''
SHADERS = {   # key: (stage, MSL, json extras) - SPIRV-Cross's naming: main0, main0_out, main0_in
    '00000000000000a1_b': (0, '''struct main0_out { float4 gl_Position [[position]]; uint gl_Layer [[render_target_array_index]]; };
struct main0_in { float4 p [[attribute(0)]]; };
struct spvDescriptorSetBuffer0 { constant float4* vp_c3 [[id(0)]]; };
vertex main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& d [[buffer(0)]]) { main0_out out = {}; out.gl_Position = in.p * d.vp_c3[0]; out.gl_Position.z = (out.gl_Position.z + out.gl_Position.w) * 0.5; out.gl_Layer = 1; return out; }
vertex main0_out main0_z(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& d [[buffer(0)]]) { main0_out out = {}; out.gl_Position = in.p * d.vp_c3[0]; out.gl_Layer = 1; return out; }
''', {'entry_z': 'main0_z', 'bindings': [{'msl_name': 'vp_c3', 'msl_type': 'constant float4*', 'arg_id': 0, 'kind': 'cbuf', 'reg': 0}],
      'vertex_inputs': [{'location': 0, 'msl_type': 'float4'}]}),
    '00000000000000b2_b': (1, ARGS + '''struct main0_out { float4 c [[color(0)]]; };
struct main0_in { float4 uv [[user(locn0)]]; };
fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& d [[buffer(0)]]) { main0_out out = {}; out.c = d.fp_t.sample(d.fp_s, in.uv.xy) * d.fp_c3[0]; return out; }
''', {'bindings': [{'msl_name': 'fp_c3', 'msl_type': 'constant float4*', 'arg_id': 0, 'kind': 'cbuf', 'reg': 0},
                   {'msl_name': 'fp_t', 'msl_type': 'texture2d<float>', 'arg_id': 1, 'kind': 'tex', 'reg': 0},
                   {'msl_name': 'fp_s', 'msl_type': 'sampler', 'arg_id': 2, 'kind': 'samp', 'reg': 0}]}),
    '00000000000000c3_b': (1, '''struct main0_out { float4 c [[color(0)]]; };
fragment main0_out main0() { main0_out out = {}; out.c = float4(1, 0, 0, 1); return out; }
''', {'bindings': []}),
}


def run(*a, env=None):
    r = subprocess.run(a, capture_output=True, text=True, env=env)
    if r.returncode: sys.exit(f'FAIL {" ".join(a)}\n{r.stdout}{r.stderr}')
    return r.stdout


with tempfile.TemporaryDirectory() as w:
    w = os.environ.get('PACK_WORK') or w
    d = os.path.join(w, 'b-' + V); os.makedirs(d, exist_ok=True)
    cc, ln = (shlex.split(x) for x in MAC_RECORD.split(';'))
    smap = ['package\tindex\tstage\tdm_ctl_sha16\tsource\n']
    for key, (stage, msl, extra) in SHADERS.items():
        src = os.path.join(d, key + '.metal'); open(src, 'w').write('#include <metal_stdlib>\nusing namespace metal;\n' + msl)
        run(*cc, src, '-o', src + '.air'); run(*ln, src + '.air', '-o', os.path.join(d, key + '.metallib')); os.unlink(src + '.air')
        j = {'key': key, 'route': 'B', 'chain': V, 'stage': ['vs', 'ps'][stage], 'entry': 'main0', 'c1': '', 'drv_reads': {}, 'drv_unfillable': [], 'vertex_inputs': [],
             'raster': {}, 'chain_metal': MAC_RECORD, **extra}
        json.dump(j, open(os.path.join(d, key + '.json'), 'w'))
        smap.append(f'x.bin\t0\t{["vertex", "pixel"][stage]}\t{key[:16]}\t/{key[-4]}.pak#0\n')
    open(os.path.join(w, 'shader_map.tsv'), 'w').writelines(smap)
    tool = os.path.join(HERE, '../tools/dmsh_pack.py')
    out = run(sys.executable, '-I', tool, '--msl', d, '--target', d, '--map', os.path.join(w, 'shader_map.tsv'), '--per-pack', '2')
    assert 'wrote 2 packs' in out and 'PACK CHECK OK 3 shaders' in out, out
    names = run('xcrun', 'metal-nm', os.path.join(d, 'pack', '0.metallib')) + run('xcrun', 'metal-nm', os.path.join(d, 'pack', '1.metallib'))
    for f in ('k00000000000000a1_b_main0', 'k00000000000000a1_b_main0_z', 'k00000000000000b2_b_main0', 'k00000000000000c3_b_main0'): assert f in names, f'{f} missing:\n{names}'
    assert run(sys.executable, '-I', tool, '--msl', d, '--target', d, '--check').startswith('PACK CHECK OK 3 shaders')
    env = dict(os.environ, DM_MSL_DIR=w, DM_NVN_SHMAP=os.path.join(w, 'shader_map.tsv'), DM_PSO_MANIFEST='off', DM_PSO_ARCHIVE='off')
    args = [f'{k}:{s}' for k, (s, _, _) in SHADERS.items()]
    on = run(os.path.join(HERE, 't_pack'), *args, env=env)
    off = run(os.path.join(HERE, 't_pack'), *args, env=dict(env, DM_SHADER_PACKS='off'))
    assert on.startswith('packs on') and off.startswith('packs off'), on + off
    on_n = re.sub(r'fn=k\w+?_b_', 'fn=', on.split('\n', 1)[1])   # the pack's names, k<key>_<entry>, against the library's own
    assert on_n == off.split('\n', 1)[1], f'packs and loose libraries differ:\n{on}\n{off}'
    for want in ('00000000000000a1_b z0 fn=main0 arg_len=8 layer=1', '00000000000000a1_b z1 fn=main0_z arg_len=8 layer=1', '00000000000000b2_b z0 fn=main0 arg_len=24 layer=0',
                 '00000000000000c3_b z0 fn=main0 arg_len=0 layer=0'):
        assert want in on_n, f'{want} not in\n{on_n}'
    # a folder without packs falls back to one library per shader, and says so at [RED] level (every boot program then opens its own file); packs deliberately off stay quiet
    os.rename(os.path.join(d, 'pack'), os.path.join(d, 'pack_moved'))
    miss = subprocess.run([os.path.join(HERE, 't_pack'), *args], capture_output=True, text=True, env=env)
    quiet = subprocess.run([os.path.join(HERE, 't_pack'), *args], capture_output=True, text=True, env=dict(env, DM_SHADER_PACKS='off'))
    os.rename(os.path.join(d, 'pack_moved'), os.path.join(d, 'pack'))
    assert miss.returncode == 0 and re.search(r'\[RED\] no shader packs in \S+/pack: one library per shader', miss.stderr), miss.stderr
    assert quiet.returncode == 0 and '[RED] no shader packs' not in quiet.stderr, quiet.stderr
    # --hot: the shaders of a harvest list (S lines, and the keys inside R records, first-use order; unknown keys ignored) fill the first pack, apart from the rest
    rec = (b'00000000000000b2_b' + bytes(6) + b'00000000000000c3_b' + bytes(70)).hex()
    hot = os.path.join(w, 'pso_user.tsv'); open(hot, 'w').write(f'S\t00000000000000c3_b\t0\nR\t{rec}\nS\tffffffffffffffff_b\t1\nS\t00000000000000a1_b\t2\n')
    out = run(sys.executable, '-I', tool, '--msl', d, '--target', d, '--map', os.path.join(w, 'shader_map.tsv'), '--per-pack', '2', '--hot', hot)
    assert '3 hot shaders' in out and 'PACK CHECK OK 3 shaders' in out, out
    rows = [ln.split('\t')[:2] for ln in open(os.path.join(d, 'pack', 'index.tsv')) if not ln.startswith('#')]
    assert rows == [['00000000000000c3_b', '0'], ['00000000000000b2_b', '0'], ['00000000000000a1_b', '1']], rows
print('PACK OK 3 shaders in 2 packs: entry points renamed and unique, refl.bin slices match, the host loads each key from its pack exactly as from its own library, hot shaders pack first')
