#!/usr/bin/env python3
"""Keep the free Apple ID's 7-day signatures of Hearth and WebDriverAgent alive on the devices, from this Mac (a launchd agent runs `run` daily).

  resign.py check [--device NAME]          days left per app per device, read back from the profiles installed on each device; changes nothing
  resign.py run [--device NAME] [--force]  re-sign and reinstall each app whose profile ends within the threshold (48 h); --force does it now
  resign.py adopt NAME APP                 record APP as the Hearth build installed on device NAME now (installs through diskhygiene.py record this themselves)

Hearth: the build the device has now (the install record, see diskhygiene.py) is cloned, given a fresh profile and signed again with the same identity and
entitlements; a verified save backup comes first and the saves are compared after the install. The engine is never rebuilt; devicectl never gets
--remove-existing-content; an open Hearth is never stopped (the run waits for it to be closed).
WebDriverAgent: rebuilt for testing with a fresh profile, its runner installed, and restarted through ios-up.sh when it was running.
A fresh free-team profile comes from xcodebuild -allowProvisioningUpdates (scripts/resign_stub for Hearth) with the cached profile moved aside first.
Per-machine settings (devices, team, identity, paths): ~/.config/anyswitch/resign.json, never in the repo. Logs: <data>/resign/log/.
On a failure a macOS notification (a banner, no window) says what failed and what to do. Tests: scripts/tests/test_resign.py
"""
import argparse, datetime as dt, fcntl, hashlib, json, os, plistlib, shlex, shutil, subprocess, sys, tempfile, time, traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import diskhygiene

HERE = Path(__file__).resolve().parent
CONF = Path(os.environ.get('ANYSWITCH_CONF') or Path.home() / '.config/anyswitch')
PROFILES = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
FRESH_HOURS = 156   # a cached profile with more than 6.5 days left is reused (one renewal serves both devices)
# What a backup holds (the saves, users, settings) and what the after-install check compares by size (the rest of the data the user keeps)
SAVE_DIRS = ('Documents/Users/', 'Documents/save/', 'Documents/save.work/', 'Library/Application Support/Hearth/State/')
SAVE_FILES = {'Documents/settings.json', 'Documents/env.txt', 'Documents/save', 'Documents/save.work'}
SHAPE_DIRS = ('Documents/', 'Library/Application Support/')
SHAPE_SKIP = ('Documents/Logs', 'Documents/temp')


class Fail(Exception):
    """A failure the user can fix: str() is the notification text (what failed and what to do)"""


def now():
    return dt.datetime.now(dt.timezone.utc)


def hours_left(p, at=None):
    return (p['expires'] - (at or now())).total_seconds() / 3600


class Log:
    def __init__(self, path):
        self.path = Path(path); self.path.parent.mkdir(parents=True, exist_ok=True); self.f = open(self.path, 'a')

    def __call__(self, *a):
        line = ' '.join(str(x) for x in a); print(line, flush=True); self.f.write(f'{time.strftime("%H:%M:%S")} {line}\n'); self.f.flush()


def sh(cmd, log=None, check=False, **kw):
    """Run a command, capture its output (into the log when given); check=True raises Fail with the output's last lines"""
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if log: log(f'$ {shlex.join(map(str, cmd))} -> {r.returncode}'); (r.stdout or r.stderr) and log.f.write(r.stdout + r.stderr)
    if check and r.returncode: raise Fail(f'{Path(str(cmd[0])).name} failed: {(r.stderr or r.stdout).strip()[-300:]}')
    return r


def tool(name, nixpkg):
    """argv prefix for a tool: from PATH (the launchd agent puts it there), else through nix-shell for a one-off run"""
    if shutil.which(name): return lambda *a: [name, *map(str, a)]
    return lambda *a: ['nix-shell', '-p', nixpkg, '--run', shlex.join([name, *map(str, a)])]


def heavy(cmd):
    return (['mac-heavy'] if shutil.which('mac-heavy') else []) + cmd


def notify(msg, title='AnySwitch re-sign'):
    """A Notification Center banner: no window, no focus change"""
    q = lambda s: json.dumps(s, ensure_ascii=False)   # an AppleScript string literal
    subprocess.run(['osascript', '-e', f'display notification {q(msg)} with title {q(title)}'], capture_output=True)


# ---------- profiles

def read_profile(path):
    r = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
    if r.returncode: return None
    p = plistlib.loads(r.stdout)
    return {'uuid': p['UUID'], 'name': p.get('Name'), 'appid': p.get('Entitlements', {}).get('application-identifier'), 'path': str(path),
            'created': p['CreationDate'].replace(tzinfo=dt.timezone.utc), 'expires': p['ExpirationDate'].replace(tzinfo=dt.timezone.utc),
            'certs': [hashlib.sha1(c).hexdigest().upper() for c in p.get('DeveloperCertificates', [])], 'devices': p.get('ProvisionedDevices', [])}


def local_profiles(appid, folder=PROFILES):
    return [p for p in (read_profile(f) for f in sorted(Path(folder).glob('*.mobileprovision'))) if p and p['appid'] == appid]


# ---------- device

def device_profiles(udid):
    """The provisioning profiles installed on the device, read back through devicectl (works from launchd, unlike a direct lockdown connection)"""
    ps = devicectl('device', 'profile', 'list', '--device', udid, '--type', 'provisioning')['provisioningProfiles']
    t = lambda s: dt.datetime.fromisoformat(s.replace('Z', '+00:00'))
    return [{'uuid': p['uuid'].lower(), 'name': p['name'], 'bundle': p['name'].split(': ', 1)[-1], 'expires': t(p['expirationDate'])} for p in ps]



def devicectl(*args, timeout=120):
    """xcrun devicectl ... --json-output -: the parsed result, or Fail with devicectl's message"""
    r = subprocess.run(['xcrun', 'devicectl', *map(str, args), '--timeout', str(timeout), '--json-output', '-'], capture_output=True, text=True)
    try: d = json.loads(r.stdout)
    except ValueError: d = {}
    if r.returncode or d.get('info', {}).get('outcome') == 'failed':
        err = d.get('error', {}).get('userInfo', {}).get('NSLocalizedDescription', {}).get('string') or (r.stderr.strip().splitlines() or ['?'])[-1]
        raise Fail(err)
    return d.get('result', {})


def installed_app(udid, bundle):
    apps = devicectl('device', 'info', 'apps', '--device', udid, '--bundle-id', bundle)['apps']
    return apps[0] if apps else None


def app_running(udid, url):
    path = url.replace('file://', '').rstrip('/') + '/'
    procs = devicectl('device', 'info', 'processes', '--device', udid)['runningProcesses']
    return [p['processIdentifier'] for p in procs if p.get('executable', '').replace('file://', '').startswith(path)]


def listing(udid, bundle):
    """(path, is dir, size) of every item in the app's data container"""
    fs = devicectl('device', 'info', 'files', '--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, timeout=300)['files']
    return [(f['relativePath'], bool(f.get('resources', {}).get('isDirectory')), f.get('metadata', {}).get('size', 0)) for f in fs]


def save_files(items):
    return sorted(p for p, d, _ in items if not d and (p in SAVE_FILES or p.startswith(SAVE_DIRS)))


def shape(items):
    """What must not change across an install, by name and size: the user's data outside the logs and scratch folder (a directory's size is its entry count, left out)"""
    return sorted((p, d, 0 if d else s) for p, d, s in items if p.startswith(SHAPE_DIRS) and not p.startswith(SHAPE_SKIP))


def pull(udid, bundle, files, dest):
    """Copy each file off the device into dest; returns {path: sha256}"""
    sums = {}; Path(dest).mkdir(parents=True, exist_ok=True)
    for f in files:
        out = Path(dest) / f; out.parent.mkdir(parents=True, exist_ok=True)
        devicectl('device', 'copy', 'from', '--device', udid, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', f, '--destination', out)
        sums[f] = hashlib.sha256(out.read_bytes()).hexdigest()
    return sums


def sums_text(sums):
    return ''.join(f'{h}  {p}\n' for p, h in sorted(sums.items()))


def backup(udid, bundle, dest, log):
    """Two pulls of the saves with identical SHA-256, as data/p1/device/backup.sh; returns (sums, shape). The app must not be running."""
    if not Path(dest).name.startswith('resign-') or Path(dest).exists(): raise Fail(f'refusing backup folder {dest}')   # only new folders of our own, never USER-SAVE-keep
    items = listing(udid, bundle); files = save_files(items)
    a = pull(udid, bundle, files, dest); b = pull(udid, bundle, files, f'{dest}.pull2')
    if a != b: raise Fail(f'the two backup pulls differ ({dest}): nothing installed')
    (Path(dest) / 'SHA256SUMS').write_text(sums_text(a))
    Path(f'{dest}.verify').write_text(f'verified {time.ctime()}\nbackup: {dest} (app not running; taken by resign.py before a re-sign install)\n'
                                      f'method: pulled twice via devicectl ({Path(dest).name}.pull2), SHA256 identical\n{sums_text(a)}')
    log(f'backup {dest}: {len(a)} files, two pulls identical')
    return a, shape(items)


def check_after(udid, bundle, before, before_shape, dest, log):
    """Pull the saves again after the install and require the same SHA-256 and the same container shape; Fail names the backup to restore from"""
    items = listing(udid, bundle)
    after = pull(udid, bundle, save_files(items), dest); Path(dest).mkdir(parents=True, exist_ok=True); (Path(dest) / 'SHA256SUMS').write_text(sums_text(after))
    if after != before or shape(items) != before_shape:
        diff = sorted(set(before.items()) ^ set(after.items()))[:5] or sorted(set(before_shape) ^ set(shape(items)))[:5]
        log(f'MISMATCH after install: {diff}')
        raise Fail(f'saves changed by the install: restore from {Path(dest).name.rsplit(".post", 1)[0]} (see the log)')
    log(f'saves unchanged by the install ({len(after)} files, container shape equal)')


# ---------- signing

def leaf_sha1(path):
    """SHA-1 of the certificate that signed this code"""
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(['codesign', '-d', f'--extract-certificates={d}/c', str(path)], capture_output=True)
        c = Path(f'{d}/c0')
        return hashlib.sha1(c.read_bytes()).hexdigest().upper() if c.is_file() else None


def entitlements(app):
    r = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)], capture_output=True)
    return plistlib.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {}


def resign_app(src, dst, profile, identity, udid, log):
    """Clone src to dst, embed the profile, sign the bundle again with src's own entitlements; checks that nothing but the profile changes"""
    ent = entitlements(src)
    if ent.get('application-identifier') != profile['appid']: raise Fail(f'{src} is signed for {ent.get("application-identifier")}, the profile for {profile["appid"]}')
    if leaf_sha1(src) != identity.upper(): raise Fail(f'{src} was signed by another certificate than {identity[:8]}: sign it once by hand')
    if identity.upper() not in profile['certs']: raise Fail(f'the new profile does not hold certificate {identity[:8]}: check Xcode > Settings > Accounts')
    if udid not in profile['devices']: raise Fail(f'the new profile does not list device {udid}: register it once in Xcode')
    diskhygiene.clone(src, dst)
    shutil.copyfile(profile['path'], Path(dst) / 'embedded.mobileprovision')
    with tempfile.NamedTemporaryFile(suffix='.plist') as e:
        e.write(plistlib.dumps(ent)); e.flush()
        sh(['codesign', '--force', '--sign', identity, '--entitlements', e.name, '--generate-entitlement-der', '--timestamp=none', dst], log, check=True)
    sh(['codesign', '--verify', '--deep', '--strict', dst], log, check=True)
    log(f'signed {dst} with profile {profile["uuid"]} (ends {profile["expires"]:%Y-%m-%d %H:%M} UTC)')


def xcode_hint(out):
    o = out.lower()
    if any(k in o for k in ('sign in', 'no account', 'not signed in', 'session has expired', 'authenticat', 'password')): return 'sign in to Xcode (Settings > Accounts)'
    if any(k in o for k in ('network', 'offline', 'could not connect', 'timed out')): return 'check the Mac\'s internet connection'
    return 'see the log'


def fresh_profile(appid, current, build, stash, log, folder=PROFILES):
    """current when it has more than FRESH_HOURS left; else the cached profiles for appid are moved aside, build() runs (Xcode then fetches a new one),
    and the ones still valid go back (other scripts may name them). Returns the new profile."""
    if current and hours_left(current) > FRESH_HOURS: return current
    old = local_profiles(appid, folder); Path(stash).mkdir(parents=True, exist_ok=True)
    for p in old: shutil.move(p['path'], Path(stash) / Path(p['path']).name)
    try: build()
    finally:
        for p in old:
            if hours_left(p) > 0: shutil.move(str(Path(stash) / Path(p['path']).name), p['path'])
    new = [p for p in local_profiles(appid, folder) if p['uuid'] not in {o['uuid'] for o in old}]
    if not new: raise Fail(f'Xcode gave no new profile for {appid}: {xcode_hint("")}')
    p = max(new, key=lambda p: p['created']); log(f'new profile {p["uuid"]} for {appid}, ends {p["expires"]:%Y-%m-%d %H:%M} UTC')
    return p


def xcodebuild(cmd, log):
    r = sh(heavy(['xcodebuild', *cmd, '-allowProvisioningUpdates']), log)
    if r.returncode: raise Fail(f'xcodebuild failed: {xcode_hint(r.stdout + r.stderr)}')


# ---------- the run

class Run:
    def __init__(self, cfg, log, stamp):
        self.cfg, self.log, self.stamp = cfg, log, stamp
        self.data = Path(cfg['data']).expanduser(); self.team = cfg['team']; self.identity = cfg['identity']
        self.hearth = cfg['hearth_bundle']; w = cfg['wda']
        self.wda_bundle = w['bundle'] + '.xctrunner'; self.wda_dd = Path(w['derived']).expanduser()
        self.wda_app = self.wda_dd / 'Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app'
        self.xcodegen = tool('xcodegen', 'xcodegen')
        self.ledger = json.loads(diskhygiene.LEDGER.read_text()) if diskhygiene.LEDGER.is_file() else {}
        self._fresh = {}

    def status(self, name, udid):
        """[(app, installed?, expected profile, profile on the device or None, note)] for Hearth and WDA on one device (Fail when unreachable)"""
        on_dev = {p['uuid']: p for p in device_profiles(udid)}
        out = []
        for app, bundle in (('hearth', self.hearth), ('wda', self.wda_bundle)):
            inst = installed_app(udid, bundle)
            if not inst: out.append((app, None, None, None, 'not installed')); continue
            newest = max((p for p in on_dev.values() if p['bundle'] == bundle), key=lambda p: p['expires'], default=None)
            if app == 'hearth':
                rec = self.ledger.get(f'{udid}/{bundle}'); why = None
                if not rec: why = f'no install record: run resign.py adopt {name} <the installed .app>'
                elif rec.get('url') and rec['url'] != inst['url']: why = 'installed outside diskhygiene.py install: which build is unknown'
                if why: out.append((app, inst, None, newest, why)); continue   # cannot re-sign; the newest profile says how urgent that is
                want = rec.get('profile'); mine = on_dev.get((want or '').lower())
                out.append((app, inst, want, mine, '' if mine else f'profile {want} not on the device'))
            else:
                # ios-up.sh installs the runner from the build on every start, so a device whose runner predates the build counts by its newest WDA profile
                want = diskhygiene.profile_uuid(self.wda_app); mine = on_dev.get((want or '').lower())
                out.append((app, inst, want, mine or newest, '' if mine else 'runner older than the current build (ios-up.sh installs it)'))
        return out

    def known_hours_left(self, udid):
        """Soonest end of what this Mac last installed on the device (Hearth's recorded profile, the WDA build's), or None when unknown"""
        rec = self.ledger.get(f'{udid}/{self.hearth}') or {}
        hearth = {p['uuid']: p for p in local_profiles(f'{self.team}.{self.hearth}')}.get(rec.get('profile'))
        if not hearth: return None
        wda = read_profile(self.wda_app / 'embedded.mobileprovision') if self.wda_app.is_dir() else None
        return min(hours_left(p) for p in (hearth, wda) if p)

    def needs(self, mine, force):
        return force or mine is None or hours_left(mine) < self.cfg.get('threshold_hours', 48)

    def hearth_profile(self, udid):
        if 'hearth' not in self._fresh:
            appid = f'{self.team}.{self.hearth}'
            cur = max(local_profiles(appid), key=lambda p: p['expires'], default=None)
            self._fresh['hearth'] = fresh_profile(appid, cur, self.build_stub, self.data / f'resign/profile-cache-moved/{self.stamp}', self.log)
        return self._fresh['hearth']

    def build_stub(self):
        d = self.data / 'resign/stub'; d.mkdir(parents=True, exist_ok=True)
        for f in ('project.yml', 'main.c'): shutil.copyfile(HERE / 'resign_stub' / f, d / f)
        sh(self.xcodegen('generate', '--spec', d / 'project.yml'), self.log, check=True)
        xcodebuild(['build', '-project', d / 'ResignStub.xcodeproj', '-scheme', 'ResignStub', '-destination', 'generic/platform=iOS', '-derivedDataPath', d / 'dd',
                    f'DEVELOPMENT_TEAM={self.team}', f'PRODUCT_BUNDLE_IDENTIFIER={self.hearth}'], self.log)

    def build_wda(self):
        w = self.cfg['wda']
        xcodebuild(['build-for-testing', '-project', Path(w['project']).expanduser(), '-scheme', 'WebDriverAgentRunner', '-destination', 'generic/platform=iOS',
                    '-derivedDataPath', self.wda_dd, f'DEVELOPMENT_TEAM={self.team}', 'CODE_SIGN_STYLE=Automatic', f'PRODUCT_BUNDLE_IDENTIFIER={w["bundle"]}'], self.log)

    def resign_hearth(self, name, udid, inst):
        rec = self.ledger[f'{udid}/{self.hearth}']; src = Path(rec['app'])
        if not (src / 'Info.plist').is_file(): raise Fail(f'the installed Hearth build is gone from the Mac ({src}): install a build with diskhygiene.py install')
        if app_running(udid, inst['url']): raise Fail(f'Hearth is open on the {name}: close it (swipe it away) so it can be re-signed')
        prof = self.hearth_profile(udid)
        dst = self.data / f'resign/apps/{name}-{self.stamp}' / src.name
        resign_app(src, dst, prof, self.identity, udid, self.log)
        k = self.data / f'backups/resign-{name}-{self.stamp}'
        before, before_shape = backup(udid, self.hearth, k, self.log)
        if app_running(udid, inst['url']): raise Fail(f'Hearth was opened on the {name} during the backup: nothing installed, it retries later')
        if diskhygiene.install_app(udid, dst, self.hearth, out=self.log, ledger=diskhygiene.LEDGER): raise Fail(f'install on the {name} failed: unlock the {name} and keep it awake')
        check_after(udid, self.hearth, before, before_shape, f'{k}.post-{time.strftime("%H%M%S")}', self.log)
        self.read_back(name, udid, prof)
        for old in sorted((self.data / 'resign/apps').glob(f'{name}-*'))[:-2]: diskhygiene.to_trash(old, f'resign-{old.name}')   # keep the newest two

    def resign_wda(self, name, udid):
        appid = f'{self.team}.{self.wda_bundle}'
        if 'wda' not in self._fresh:
            cur = read_profile(self.wda_app / 'embedded.mobileprovision') if self.wda_app.is_dir() else None
            self._fresh['wda'] = fresh_profile(appid, cur, self.build_wda, self.data / f'resign/profile-cache-moved/{self.stamp}', self.log)
            if diskhygiene.profile_uuid(self.wda_app) != self._fresh['wda']['uuid']: self.build_wda()   # the product still had an older one
        if diskhygiene.profile_uuid(self.wda_app) != self._fresh['wda']['uuid']: raise Fail('the WebDriverAgent build did not take the new profile: see the log')
        running = subprocess.run(['pgrep', '-f', f'test-without-building.*id={udid}'], capture_output=True).returncode == 0
        primary = subprocess.run(['pgrep', '-f', f'forward --udid {udid} 8100 '], capture_output=True).returncode == 0
        if diskhygiene.install_app(udid, self.wda_app, self.wda_bundle, out=self.log): raise Fail(f'WebDriverAgent install on the {name} failed: unlock the {name}')
        self.read_back(name, udid, self._fresh['wda'])
        if running:
            other = next((n for n in self.cfg['devices'] if n != name), name)
            sh([str(Path(self.cfg['wda']['ios_up']).expanduser()), name if primary else other], self.log, env={**os.environ, 'ONLY': name})

    def read_back(self, name, udid, prof):
        got = {p['uuid']: p for p in device_profiles(udid)}.get(prof['uuid'].lower())
        if not got: raise Fail(f'the new profile is not on the {name} after the install')
        self.log(f'{name}: device has profile {got["uuid"]} ({got["name"]}), ends {got["expires"]:%Y-%m-%d %H:%M} UTC, {hours_left(got) / 24:.1f} days left')


def table_row(name, app, inst, want, mine, note, act):
    left = f'{hours_left(mine) / 24:5.1f}' if mine else '    -'
    ends = f'{mine["expires"]:%Y-%m-%d %H:%M}Z' if mine else '-'
    return f'{name:7} {app:7} {"yes" if inst else "no":4} {left} {ends:18} {act:10} {note}'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0]); sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('check', 'run'):
        s = sub.add_parser(c); s.add_argument('--device', action='append')
        if c == 'run': s.add_argument('--force', action='store_true'); s.add_argument('--apps', default='hearth,wda')
    s = sub.add_parser('adopt'); s.add_argument('device'); s.add_argument('app')
    a = ap.parse_args(argv)
    cfg = json.loads((CONF / 'resign.json').read_text())
    cfg['data'] = cfg.get('data') or str(HERE.parent / 'data')
    stamp = time.strftime('%Y%m%d-%H%M%S')
    log = Log(Path(cfg['data']) / f'resign/log/{stamp}-{a.cmd}.log')
    if a.cmd == 'adopt':
        udid = cfg['devices'][a.device]; inst = installed_app(udid, cfg['hearth_bundle'])
        if not inst: sys.exit(f'resign: no {cfg["hearth_bundle"]} on the {a.device}')
        log(f'adopted: {diskhygiene.record_install(udid, cfg["hearth_bundle"], a.app, inst["url"], diskhygiene.LEDGER)}'); return 0
    lock = open(Path(cfg['data']) / 'resign/.lock', 'w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: log('another resign.py run holds the lock; nothing done'); return 0
    r = Run(cfg, log, stamp); fails = []
    log(f'resign.py {a.cmd} at {now():%Y-%m-%d %H:%M} UTC, threshold {cfg.get("threshold_hours", 48)} h; log {log.path}')
    log(f'{"device":7} {"app":7} {"inst":4} {"days":5} {"ends":18} {"action":10} note')
    for name, udid in cfg['devices'].items():
        if a.device and name not in a.device: continue
        force = a.cmd == 'run' and a.force
        try: rows = r.status(name, udid)
        except Fail as e:
            left = r.known_hours_left(udid)   # from this Mac's own records: an unreachable device only matters when something is due
            log(f'{name:7} -       unreachable: {e}; by this Mac\'s records the soonest profile ends in {"?" if left is None else f"{left / 24:.1f} days"}')
            if force or left is None or left < cfg.get('threshold_hours', 48): fails.append(f'{name} unreachable: wake it, unlock it and put it on the Mac\'s Wi-Fi')
            continue
        for app, inst, want, mine, note in rows:
            due = r.needs(mine, force)
            act = 'skip' if not inst else 'CANNOT' if app == 'hearth' and not want and due else 'skip' if app == 'hearth' and not want else 'RE-SIGN' if due else 'ok'
            log(table_row(name, app, inst, want, mine, note, act))
            if act == 'CANNOT': fails.append(f'{name} Hearth is due but {note}')
            if a.cmd != 'run' or act != 'RE-SIGN' or app not in a.apps.split(','): continue
            try: r.resign_hearth(name, udid, inst) if app == 'hearth' else r.resign_wda(name, udid)
            except Fail as e: log(f'FAIL {name} {app}: {e}'); fails.append(f'{name} {app}: {e}')
            except Exception: log(traceback.format_exc()); fails.append(f'{name} {app}: crashed, see {log.path.name}')
    if fails and a.cmd == 'run':
        notify('; '.join(fails)[:400] + f' (log: data/resign/log/{log.path.name})')
    log('FAILED: ' + '; '.join(fails) if fails else 'done')
    return 1 if fails else 0


if __name__ == '__main__': sys.exit(main())
