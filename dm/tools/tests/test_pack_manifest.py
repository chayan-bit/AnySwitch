# pack_manifest.py on a scratch pack: write records the engine's numbers, the platforms present, the module build ids and every file (files.tsv, named by the small manifest.json);
# verify passes on the untouched pack and names each kind of difference (a changed, missing or extra file, an edited inventory, a stale number).
import json, re, subprocess, sys, tempfile
from pathlib import Path
TOOL = Path(__file__).resolve().parents[1] / 'pack_manifest.py'
ABI = {k: int(re.search(rf'^#define {k} (\d+)', (TOOL.parents[1] / 'host/dm_abi.h').read_text(), re.M).group(1)) for k in ('DM_PACK_FORMAT', 'DM_PROFILE_SCHEMA', 'DM_CODE_ABI', 'DM_SHADER_ABI')}


def run(*a):
    return subprocess.run([sys.executable, '-I', str(TOOL), *a], capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as t:
        r = Path(t) / 'pack'
        for f, data in (('profile/game.json', '{}'), ('profile/main.fixups.tsv', '# PATCH_OFF\t0x8000\n# BUILD_ID\tabcd\n'), ('code/macos.dylib', 'x' * 100),
                        ('msl/macos/b-1/a_b.metallib', 'lib'), ('romfs.dmstore', 'store')):
            (r / f).parent.mkdir(parents=True, exist_ok=True); (r / f).write_text(data)
        w = run('write', str(r), '--title', '0100abf008968000', '--chain', '1', '--display-version', '1.0')
        assert w.returncode == 0, w.stderr
        m = json.loads((r / 'manifest.json').read_text())
        assert m['format'] == ABI['DM_PACK_FORMAT'] and m['title_id'] == '0100ABF008968000', m
        assert m['abi'] == {'profile_schema': ABI['DM_PROFILE_SCHEMA'], 'code': ABI['DM_CODE_ABI'], 'shader': ABI['DM_SHADER_ABI']}, m['abi']
        assert m['platforms'] == ['macos'] and m['modules'] == {'main': 'abcd'}, m
        inv = {l.split('\t')[0]: l.split('\t')[1:] for l in (r / 'files.tsv').read_text().splitlines() if not l.startswith('#')}
        assert sorted(inv) == ['code/macos.dylib', 'msl/macos/b-1/a_b.metallib', 'profile/game.json', 'profile/main.fixups.tsv', 'romfs.dmstore'], inv
        assert inv['romfs.dmstore'][0] == '5' and m['inventory']['files'] == 5 and m['inventory']['file'] == 'files.tsv', (inv, m['inventory'])
        assert 'files' not in m and len((r / 'manifest.json').read_bytes()) < 2048   # the engine parses the manifest at every boot: it stays small
        assert run('verify', str(r)).returncode == 0

        def bad(change, want):
            raw = (r / 'manifest.json').read_text()
            undo = change()
            v = run('verify', str(r))
            assert v.returncode == 1 and want in v.stdout, (want, v.stdout)
            undo(); (r / 'manifest.json').write_text(raw)
            assert run('verify', str(r)).returncode == 0
        bad(lambda: ((r / 'romfs.dmstore').write_text('stoRe'), lambda: (r / 'romfs.dmstore').write_text('store'))[1], 'changed: romfs.dmstore')
        bad(lambda: ((r / 'msl/macos/b-1/a_b.metallib').rename(r / 'x'), lambda: (r / 'x').rename(r / 'msl/macos/b-1/a_b.metallib'))[1], 'missing: msl/macos/b-1/a_b.metallib')
        bad(lambda: ((r / 'extra.bin').write_text('?'), lambda: (r / 'extra.bin').unlink())[1], 'not in the manifest: extra.bin')
        inv_raw = (r / 'files.tsv').read_text()
        bad(lambda: ((r / 'files.tsv').write_text(inv_raw.replace('romfs.dmstore\t5', 'romfs.dmstore\t6')), lambda: (r / 'files.tsv').write_text(inv_raw))[1], 'changed: files.tsv')

        def stale():
            m2 = dict(m, abi=dict(m['abi'], code=m['abi']['code'] + 1)); (r / 'manifest.json').write_text(json.dumps(m2)); return lambda: None
        bad(stale, f'code {ABI["DM_CODE_ABI"] + 1}, this engine {ABI["DM_CODE_ABI"]}')
        assert run('write', str(r), '--title', 'nope').returncode != 0
        # bundled in the IPA: no inventory, the code embedded (platforms ios), the numbers still checked
        (r / 'files.tsv').unlink()
        assert run('write', str(r), '--title', '0100abf008968000', '--bundled').returncode == 0
        mb = json.loads((r / 'manifest.json').read_text())
        assert mb['inventory'] is None and mb['platforms'] == ['ios'] and not (r / 'files.tsv').exists(), mb
        assert run('verify', str(r)).returncode == 0
        bad(stale, f'code {ABI["DM_CODE_ABI"] + 1}, this engine {ABI["DM_CODE_ABI"]}')
    subset_case()
    print('test_pack_manifest: ok')


def subset_case():   # subset: the iOS part of a two-platform pack, verified on its own; a source that no longer matches its inventory is refused
    with tempfile.TemporaryDirectory() as t:
        r, s = Path(t) / 'pack', Path(t) / 'ios'
        for f in ('profile/game.json', 'code/ios.dylib', 'code/macos.dylib', 'msl/ios/b-1/a.metallib', 'msl/macos/b-1/a.metallib', 'pso/macos/x.bin', 'romfs.dmstore'):
            (r / f).parent.mkdir(parents=True, exist_ok=True); (r / f).write_text(f)
        assert run('write', str(r), '--title', '0100abf008968000').returncode == 0
        u = run('subset', str(r), str(s), '--platform', 'ios')
        assert u.returncode == 0, u.stderr
        have = sorted(p.relative_to(s).as_posix() for p in s.rglob('*') if p.is_file())
        assert have == ['code/ios.dylib', 'files.tsv', 'manifest.json', 'msl/ios/b-1/a.metallib', 'profile/game.json', 'romfs.dmstore'], have
        assert json.loads((s / 'manifest.json').read_text())['platforms'] == ['ios'] and not (s / 'pso').exists()
        assert run('verify', str(s)).returncode == 0 and run('verify', str(r)).returncode == 0   # the source is untouched
        (r / 'romfs.dmstore').write_text('changed')
        u = run('subset', str(r), str(Path(t) / 'ios2'), '--platform', 'ios')
        assert u.returncode != 0 and 'changed: romfs.dmstore' in u.stderr and not (Path(t) / 'ios2').exists(), u.stderr


if __name__ == '__main__':
    main()
