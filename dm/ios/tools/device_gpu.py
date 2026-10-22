#!/usr/bin/env python3
# GPU architectures of the connected devices, for the pipeline archives build_ipa.sh builds (PSO_ARCHS): an archive holds one copy of every pipeline per GPU architecture, so building
# only the devices' own fits many more pipelines under the same size cap. Read-only: it lists devices with xcrun devicectl and never installs or copies anything.
# A device's chip ID is the first field of its UDID (0000XXXX-...), mapped to a Metal GPU architecture by CHIP_ARCH. Prints the architectures on stdout, space separated, and nothing
# when no device is connected, devicectl fails or a chip is not in the table: the archives are then built for every iOS GPU family. Why goes to stderr.
# Usage: device_gpu.py [devices.json]   (the JSON of `xcrun devicectl list devices --json-output`; default: run it)
import json, re, subprocess, sys, tempfile

TIMEOUT = 30
# Chip ID -> GPU architecture, every iOS chip with Metal 4: A-series GPUs are the "p" slices, M-series the "g" slices, one GPU generation each
# ponytail: hand table, a newer chip falls back to every family until its row is added (xcrun metal-arch prints a Mac's architecture, the app logs "this GPU: ...")
CHIP_ARCH = {0x8101: 'applegpu_g13p', 0x8103: 'applegpu_g13g', 0x8110: 'applegpu_g14p', 0x8112: 'applegpu_g14g', 0x8120: 'applegpu_g15p', 0x8122: 'applegpu_g15g',
             0x8130: 'applegpu_g16p', 0x8132: 'applegpu_g16g', 0x8140: 'applegpu_g17p', 0x8142: 'applegpu_g17g', 0x8150: 'applegpu_g18p'}


def pick(devices):
    """(architectures, why) for the connected physical iOS devices; no architectures means build for every family"""
    up = [d for d in devices if d.get('connectionProperties', {}).get('tunnelState') == 'connected'
          and d.get('hardwareProperties', {}).get('platform') == 'iOS' and d.get('hardwareProperties', {}).get('reality') == 'physical']
    if not up: return [], 'no connected device'
    archs, seen = [], []
    for d in up:
        h = d['hardwareProperties']; name = d.get('deviceProperties', {}).get('name', '?')
        m = re.fullmatch(r'0000([0-9A-Fa-f]{4})-[0-9A-Fa-f]{16}', h.get('udid', ''))
        arch = m and CHIP_ARCH.get(int(m.group(1), 16))
        if not arch: return [], f'{name}: chip {m.group(1) if m else "unknown"} is not in the table (device_gpu.py CHIP_ARCH)'
        seen.append(f'{name}: chip {m.group(1)} -> {arch}')
        if arch not in archs: archs.append(arch)
    return archs, 'connected ' + ', '.join(seen)


def devices(path=None):
    if path: return json.load(open(path))['result']['devices']
    with tempfile.NamedTemporaryFile(suffix='.json') as j:
        r = subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', j.name], capture_output=True, text=True, timeout=TIMEOUT)
        if r.returncode: raise RuntimeError(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'devicectl list devices failed')
        return json.load(open(j.name))['result']['devices']


def main():
    try: archs, why = pick(devices(sys.argv[1] if len(sys.argv) > 1 else None))
    except Exception as e: archs, why = [], f'no device list ({e})'
    print(f'GPU architectures: {" ".join(archs)} ({why})' if archs else f'GPU architectures: every iOS GPU family ({why})', file=sys.stderr)
    print(' '.join(archs))


if __name__ == '__main__':
    main()
