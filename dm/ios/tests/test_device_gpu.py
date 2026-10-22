#!/usr/bin/env python3
# tools/device_gpu.py: connected devices' chip IDs -> GPU architectures, and the fallback to every family (empty output) on an unknown chip, no device or no device list
import json, os, subprocess, sys, tempfile
T = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../tools')
sys.path.insert(0, T)
import device_gpu as G


def dev(chip, state='connected', platform='iOS', reality='physical', udid=None):
    return {'connectionProperties': {'tunnelState': state}, 'deviceProperties': {'name': f'dev{chip}'},
            'hardwareProperties': {'udid': udid or f'0000{chip}-0001020304050607', 'platform': platform, 'reality': reality}}


assert G.pick([dev('8132')])[0] == ['applegpu_g16g']
assert G.pick([dev('8132'), dev('8140'), dev('8132')])[0] == ['applegpu_g16g', 'applegpu_g17p']        # one per architecture, in order
assert G.pick([dev('8132'), dev('8140', state='disconnected'), dev('8140', reality='virtual'), dev('8140', platform='macOS')])[0] == ['applegpu_g16g']   # connected iOS hardware only
assert G.pick([dev('8132'), dev('9999')]) == ([], 'dev9999: chip 9999 is not in the table (device_gpu.py CHIP_ARCH)')   # any unknown chip: every family
assert G.pick([dev('8132', udid='0123456789abcdef0123456789abcdef01234567')])[0] == []                # an older UDID with no chip ID
assert G.pick([]) == ([], 'no connected device') and G.pick([dev('8132', state='unavailable')])[0] == []
assert set(G.CHIP_ARCH.values()) == {f'applegpu_g{g}{k}' for g in range(13, 19) for k in 'pg'} - {'applegpu_g18g'}   # every iOS GPU family with Metal 4, once


def cli(*args):
    r = subprocess.run([sys.executable, '-I', os.path.join(T, 'device_gpu.py'), *args], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip(), r.stderr.strip()


with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f: json.dump({'result': {'devices': [dev('8132'), dev('8101')]}}, f)
assert cli(f.name) == ('applegpu_g16g applegpu_g13p', 'GPU architectures: applegpu_g16g applegpu_g13p (connected dev8132: chip 8132 -> applegpu_g16g, dev8101: chip 8101 -> applegpu_g13p)'), cli(f.name)
os.remove(f.name)
out, err = cli(f.name)   # no device list: every family, still exit 0
assert out == '' and err.startswith('GPU architectures: every iOS GPU family (no device list'), err
print('DEVICE_GPU OK chip IDs to GPU architectures, fallback to every family on an unknown chip, no device or no device list')
