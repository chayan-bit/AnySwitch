#!/usr/bin/env python3
# Passive learning (dm/gfx/README.md, pipeline coverage): copy the pipeline log (Documents/pso_user.tsv, always written by the app) from every reachable device that has this app installed to
# <out dir>/pso_user_<device>.tsv, where build_ipa.sh folds its R records into the first tier of the flexible pipeline archive. The install tool may have changed the bundle ID
# (AltStore / Sideloadly append the team), so an installed app matches when its ID starts with the build's.
# Usage: pull_pso_user.py <bundle ID> <out dir>. Exit 0 with a note when no device is reachable: that is not an error. Uses xcrun devicectl (Xcode 15+), with timeouts
import json, os, subprocess, sys, tempfile

TIMEOUT = 30


def devicectl(*args):
    with tempfile.NamedTemporaryFile(suffix='.json') as j:
        r = subprocess.run(['xcrun', 'devicectl', *args, '--json-output', j.name], capture_output=True, text=True, timeout=TIMEOUT)
        if r.returncode: raise RuntimeError(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else f'devicectl {args[0]} failed')
        return json.load(open(j.name)).get('result', {})


def main():
    bid, out = sys.argv[1], sys.argv[2]
    try: devs = devicectl('list', 'devices').get('devices', [])
    except Exception as e: print(f'pipeline log: no device list ({e}): nothing pulled'); return
    up = [d for d in devs if d.get('connectionProperties', {}).get('tunnelState') == 'connected']
    if not up: print('pipeline log: no reachable device: nothing pulled'); return
    for d in up:
        did, name = d['identifier'], d.get('deviceProperties', {}).get('name', d['identifier'])
        try:
            apps = devicectl('device', 'info', 'apps', '--device', did).get('apps', [])
            app = next((a['bundleIdentifier'] for a in apps if a.get('bundleIdentifier', '').startswith(bid)), None)
            if not app: print(f'pipeline log: {name} has no {bid}*'); continue
            dst = os.path.join(out, f'pso_user_{did[:8]}.tsv')
            devicectl('device', 'copy', 'from', '--device', did, '--domain-type', 'appDataContainer', '--domain-identifier', app, '--source', 'Documents/pso_user.tsv', '--destination', dst)
            print(f'pipeline log: {name} ({app}) -> {dst}, {sum(1 for l in open(dst) if l.startswith("R"))} pipeline records')
        except Exception as e: print(f'pipeline log: {name}: {e}')


if __name__ == '__main__':
    main()
