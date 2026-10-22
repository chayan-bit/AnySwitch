#!/usr/bin/env python3
"""Compatibility runner: build each game for the Mac, boot it in the Mac dev host, drive it, and report what happened.

  compat_run.py <root> -k <prod.keys> [--secs 300] [--only <id>,...] [--repeat N] [--ab KEY=VALUE] [--baseline <stamp>] [--stamp <name>]

<root> holds one folder per game (the NSP script's rule: one game's NSPs in a folder), or is one such folder itself. For each game, in order:
  build    scripts/build_ipa_from_nsp.py --mac-only, unless --no-build (every stage's cache as for an IPA build; a game without a profile gets the survey and a provisional profile)
  boot     the dev host from <id>_build/mac_run.json, headless and silent, a fresh save (or the route's checkpoint), screenshots every --shot-every frames, the watchdog on
  input    the route's devctl sequence (--routes <dir>/<id>.txt, else the profile's compat_route.txt), then A every 2 s with an occasional Plus / B until the budget ends
           (--secs after the first present); a route file holds devctl steps, '# comments', and the directives 'checkpoint <name>' and 'secs <n>'
  report   data/compat/<stamp>/<id>/: report.json (status, labels, signals, suggestions, the [auto] counters), host.log, shots/;
           data/compat/<stamp>/summary.md, and data/compat/results.tsv with the latest row per title (scripts/compat_table.py --results)
Status ladder: build-failed, no-boot, boots (nnMain, no picture), renders (a picture), ingame (a picture that keeps changing under input for the whole budget, no crash or hang);
playable is never set here. A run whose host could not write its screenshots (`shots-missing`) or mount its save (`save-mount-failed`) is not graded ingame. Suggestions (profile keys, shader facts rows, host work items) go into the report only; profiles are never changed.
A game whose report in the same --stamp has the same key (NSP files, repository state, route, options) is skipped, so an interrupted batch resumes with the same --stamp.
Everything a run writes is game-derived and stays under data/ (gitignored). Detectors are pure functions of the log text: scripts/tests/test_compat_run.py."""
import argparse, hashlib, importlib.util, json, os, re, shutil, signal, socket, subprocess, sys, time, traceback
from importlib.machinery import SourceFileLoader
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(REPO / 'dm/games')); sys.path.insert(0, str(SCRIPTS))
NONBLACK = 0.005          # a shot with at least this share of lit pixels shows a picture
BLACK_AFTER = 30          # seconds after the first present from which an all-black run counts as black
FROZEN_SHOTS, FROZEN_SECS = 5, 30
STATUSES = ('build-failed', 'no-boot', 'boots', 'renders', 'ingame')
GENERIC = ['A wait(55) ' * 5, 'A wait(55) ' * 5, 'A wait(55) ' * 5, 'Plus wait(55) B wait(55) B wait(55) A wait(55) B wait(55)']   # about 10 s each at 30 fps


def _load(name, path):
    spec = importlib.util.spec_from_loader(name, SourceFileLoader(name, str(path)))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


# ---- Log parsing and detectors (pure) ----
def kv(line):   # key=value tokens of an [auto] / [shot] line
    return {k: v for k, v in re.findall(r'(\w+)=([\w.-]+)', line)}   # values stop at any other character: another thread's output can land mid-line


def env_pairs(args):   # --env / --ab values: 'KEY=VALUE KEY=VALUE' words (values are paths, lists, anything without spaces)
    out = {}
    for w in ' '.join(args).split():
        k, eq, v = w.partition('=')
        if not eq or not re.fullmatch(r'[A-Za-z_]\w*', k): raise SystemExit(f'not KEY=VALUE: {w}')
        out[k] = v
    return out


def num(v):
    try: return int(v, 16) if re.fullmatch(r'[0-9a-f]{16}', v) else float(v) if '.' in v else int(v)
    except ValueError: return v


def red_template(line):   # a [RED] line with numbers, addresses and keys stripped, to group repeats
    t = line.split('[RED]', 1)[1].strip()
    return re.sub(r'(0x)?[0-9a-fA-F]*\d[0-9a-fA-F]*', 'N', t)[:200]


def parse_log(text):
    """Signals from a host log: boot, first present, [shot] and [auto] lines, crash / watchdog lines, red lines, stubs, shader and pipeline failures, timings"""
    s = {'boot': '>>> nnMain' in text, 'first_present': None, 'shots': [], 'auto': {}, 'crash': [], 'watchdog': [], 'unimpl': {}, 'red': {}, 'fout_rows': [],
         'shader_fail': 0, 'shmap_miss': 0, 'pso_fail': 0, 'zb': 0, 'longframes': 0, 'frame_p50': [], 'cpu_pct': [], 'fb_c_keys': [], 'snw_lines': 0,
         'rc_draws_anyway': False, 'heap_oom': 'SetHeapSize OOM' in text or '> app pool' in text, 'devctl': False,
         'shot_fail': 0, 'shot_files': None, 'save_failed': False}   # the last three: what the host could not write (shot_files: PNGs on disk, set by report_boot from the run directory)
    for line in text.splitlines():
        if '[auto] event=first_present' in line: s['first_present'] = float(kv(line.split('[auto]', 1)[1])['t'])
        elif '[auto] frame=' in line: s['auto'] = {k: num(v) for k, v in kv(line.split('[auto]', 1)[1]).items()}
        elif '[shot] frame=' in line: s['shots'].append({k: num(v) for k, v in kv(line.split('[shot]', 1)[1]).items()})
        elif '[auto] feedback class C' in line:
            m = re.search(r'fragment shader (\w+)', line)
            if m and m.group(1) not in s['fb_c_keys']: s['fb_c_keys'].append(m.group(1))
        elif '[auto] sampled but never written' in line: s['snw_lines'] += 1
        elif 'CRASH sig=' in line: s['crash'].append(line.strip())
        elif '[RED] watchdog: no progress' in line: s['watchdog'].append(line.strip())
        elif line.lstrip('[dm] ').startswith('UNIMPL ') or ' UNIMPL ' in line:
            m = re.search(r'UNIMPL (\S+)', line); n = m.group(1) if m else '?'; s['unimpl'][n] = s['unimpl'].get(n, 0) + 1
        elif '[zb]' in line: s['zb'] += 1
        elif re.search(r'screenshot .* \u2192 \S+ failed$', line.strip()): s['shot_fail'] += 1
        elif 'save transaction:' in line and 'read-only instead' in line: s['save_failed'] = True   # hle_fs.c mount_ex: the save could not be cloned, the game plays on a read-only save
        elif '[longframe]' in line: s['longframes'] += 1
        elif 'devctl: dev input channel listening' in line: s['devctl'] = True
        if '[RED]' in line:
            t = red_template(line); s['red'][t] = s['red'].get(t, 0) + 1
            if 'failed to create render pipeline' in line: s['pso_fail'] += 1
            if 'failed to load' in line and 'shader' in line: s['shader_fail'] += 1
            if 'is not in the shader map' in line: s['shmap_miss'] += 1
            if 'SetRenderEnableConditional' in line: s['rc_draws_anyway'] = True
        m = re.search(r'add to shader_facts_manual\.tsv: (\S+)\t(.*)$', line)
        if m: s['fout_rows'].append(f'{m.group(1)}\t{m.group(2)}')
        m = re.search(r'\[nvn\] timing up to frame \d+: frame time p50 ([\d.]+)', line)
        if m: s['frame_p50'].append(float(m.group(1)))
        m = re.search(r'\[nvn\] power up to frame \d+: .*?CPU (\d+)% \(100 = one core\)', line)
        if m: s['cpu_pct'].append(int(m.group(1)))
    return s


def frozen_runs(shots):   # runs of identical consecutive shot hashes: [(first index, length, seconds)]
    out, i = [], 0
    while i < len(shots):
        j = i
        while j + 1 < len(shots) and shots[j + 1].get('hash') == shots[i].get('hash'): j += 1
        if j > i: out.append((i, j - i + 1, shots[j].get('t', 0) - shots[i].get('t', 0)))
        i = j + 1
    return out


def detect(s, rc, ran_full, input_sent, liveness_hang=False):
    """(status, labels) from parse_log's signals, the host's exit (None = still running when stopped, negative = a signal), whether the budget ran out
    (rather than the host stopping or no first present), whether input was sent, and whether devctl saw the frame counter stand still for 60 s.
    Missing screenshots and a failed save mount are labels of their own and keep the status below ingame"""
    labels = []
    crashed = bool(s['crash']) or (rc is not None and rc not in (0, -signal.SIGTERM, 128 + signal.SIGTERM, 128 + signal.SIGALRM) and not s['watchdog'])
    hung = bool(s['watchdog']) or rc == 128 + signal.SIGALRM or liveness_hang
    if crashed: labels.append('crash')
    if hung: labels.append('hang')
    t0 = s['first_present']; shots = s['shots']
    late = [x for x in shots if t0 is not None and x.get('t', 0) >= t0 + BLACK_AFTER]
    lit = any(x.get('nonblack', 0) >= NONBLACK for x in shots)
    if late and all(x.get('nonblack', 0) < NONBLACK for x in late): labels.append('black')
    runs = [r for r in frozen_runs(shots) if r[1] >= FROZEN_SHOTS and r[2] >= FROZEN_SECS]
    if runs and input_sent: labels.append('frozen')
    if any(x.get('magenta_blocks16', 0) for x in shots) or s['zb'] or s['auto'].get('snw', 0): labels.append('missing-textures')
    if s['pso_fail'] or s['shader_fail'] or s['shmap_miss'] or s['fout_rows']: labels.append('pipelines')
    if s['unimpl']: labels.append('unimplemented')
    shots_lost = bool(s['shot_fail']) or (s['shot_files'] is not None and s['shot_files'] < len(shots))   # fewer images than the host's [shot] lines: its writes failed
    if shots_lost: labels.append('shots-missing')
    if s['save_failed']: labels.append('save-mount-failed')
    if s['frame_p50'] and sorted(s['frame_p50'])[len(s['frame_p50']) // 2] > 50: labels.append('slow')
    if not s['boot']: return 'no-boot', labels
    if not lit: return 'boots', labels
    end_frozen = bool(runs) and runs[-1][0] + runs[-1][1] == len(shots)
    if ran_full and input_sent and not crashed and not hung and 'black' not in labels and not end_frozen and not shots_lost and not s['save_failed']: return 'ingame', labels   # a run that lost its evidence or its save is not a clean ingame
    return 'renders', labels


def suggest(s, heap=None):
    """Suggestions for the report: profile keys (written into provisional profiles by hand, never into dm/games), shader facts rows, host work items. heap: profile_guess.heap_signals' result"""
    out, a = [], s['auto']
    for k, (v, why) in (heap or {}).items(): out.append({'kind': 'key', 'key': k, 'value': v, 'why': why})
    for row in dict.fromkeys(s['fout_rows']): out.append({'kind': 'shader_facts_manual', 'row': row, 'why': 'a pipeline failed on integer outputs (pso_fout_hint)'})
    if s['rc_draws_anyway'] and a.get('render_cond', 'off') == 'off':
        out.append({'kind': 'key', 'key': 'render_cond', 'value': 'on', 'why': 'the game uses conditional rendering, which the host draws through (A/B with DM_NVN_RENDER_COND=on)'})
    if a.get('snw', 0) and a.get('tex_flush', 'off') == 'off':
        out.append({'kind': 'key', 'key': 'tex_flush_upload tex_dirty_upload', 'value': 'on', 'why': f'{a["snw"]} textures sampled but never written (A/B with DM_NVN_TEX_GUEST=on)'})
    if s['fb_c_keys'] and a.get('fb_snap_keys', 0) == 0:
        out.append({'kind': 'key', 'key': 'feedback_snap', 'value': ' '.join(s['fb_c_keys']), 'why': 'fragment shaders sample an attachment they write in the same pass (class C)'})
    for n, c in sorted(s['unimpl'].items()): out.append({'kind': 'host', 'item': f'UNIMPL {n}', 'why': f'{c} calls'})
    return out


def flaky(statuses):   # repeats that disagree, or a crash / hang in some of them
    return len(set(st for st, _ in statuses)) > 1 or any(('crash' in l or 'hang' in l) for _, l in statuses) and not all(('crash' in l or 'hang' in l) for _, l in statuses)


def compare(a, b):   # two boots' reports (--ab, --baseline): what differs
    d = {}
    if a['status'] != b['status']: d['status'] = [a['status'], b['status']]
    if set(a['labels']) != set(b['labels']): d['labels'] = [sorted(a['labels']), sorted(b['labels'])]
    sa = {x['frame']: x for x in a['signals']['shots']}; sb = {x['frame']: x for x in b['signals']['shots']}
    common = sorted(set(sa) & set(sb))
    if common:
        d['shots_same_hash'] = f'{sum(sa[f]["hash"] == sb[f]["hash"] for f in common)}/{len(common)}'
        d['nonblack_max_diff'] = round(max(abs(sa[f]['nonblack'] - sb[f]['nonblack']) for f in common), 4)
        d['magenta_blocks16'] = [sum(sa[f]['magenta_blocks16'] for f in common), sum(sb[f]['magenta_blocks16'] for f in common)]
    ka, kb = a['signals']['auto'], b['signals']['auto']
    d['auto'] = {k: [ka.get(k), kb.get(k)] for k in sorted(set(ka) | set(kb)) if ka.get(k) != kb.get(k) and k not in ('frame', 't')}
    return d


def run_key(nsp_files, repo_state, route, opts):   # what a report stands for: the game files, the repository, the route and the options
    h = hashlib.sha256(json.dumps([sorted(nsp_files), repo_state, route, opts], sort_keys=True).encode())
    return h.hexdigest()[:16]


RESULT_COLS = ('title_id', 'name', 'status', 'labels', 'stamp', 'build', 'repo')


def merge_results(path, rows):   # results.tsv keeps the latest row per title
    path = Path(path); have = {}
    if path.exists():
        for line in path.read_text().splitlines()[1:]:
            c = line.split('\t')
            if len(c) == len(RESULT_COLS): have[c[0]] = dict(zip(RESULT_COLS, c))
    for r in rows: have[r['title_id']] = {k: str(r.get(k, '')) for k in RESULT_COLS}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\t'.join(RESULT_COLS) + '\n' + ''.join('\t'.join(have[t][k] for k in RESULT_COLS) + '\n' for t in sorted(have)))
    return have


def read_route(text):   # (checkpoint, secs, devctl sequence) from a route file
    ck, secs, seq = None, None, []
    for line in text.splitlines():
        line = line.split('#', 1)[0].strip()
        if not line: continue
        w = line.split()
        if w[0] == 'checkpoint' and len(w) == 2: ck = w[1]
        elif w[0] == 'secs' and len(w) == 2: secs = float(w[1])
        else: seq.append(line)
    return ck, secs, ' '.join(seq)


# ---- Building and booting ----
def game_dirs(root):   # one folder per game; root itself when it holds NSPs
    has = lambda d: any(d.glob('*.nsp')) or any(d.glob('*.xci'))
    return [root] if has(root) else [d for d in sorted(root.iterdir()) if d.is_dir() and has(d)]


def repo_state():   # HEAD plus a hash of uncommitted changes
    git = lambda *a: subprocess.run(['git', '-C', str(REPO), *a], capture_output=True, text=True).stdout
    return git('rev-parse', '--short=12', 'HEAD').strip() + ('+' + hashlib.sha256(git('diff', 'HEAD').encode()).hexdigest()[:8] if git('status', '--porcelain', '--untracked-files=no').strip() else '')


def build(nsp_dir, keys, out, timeout, env):
    """build_ipa_from_nsp.py --mac-only; returns (mac_run.json path or None, failed stage, last lines)"""
    cmd = [sys.executable, str(SCRIPTS / 'build_ipa_from_nsp.py'), str(nsp_dir), '-k', str(keys), '--mac-only', '--progress', 'lines']
    try:
        with open(out, 'w') as f: p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env, timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired: rc = 'timeout'
    text = Path(out).read_text(errors='replace')
    m = re.findall(r'mac run: (.+mac_run\.json)', text)
    if rc == 0 and m: return Path(m[-1].strip()), None, None
    stages = re.findall(r'\[\d+/\d+\] ([^·\n]+)', text)
    return None, (stages[-1].strip(' …') if stages else '?') + (' (timed out)' if rc == 'timeout' else ''), text.splitlines()[-30:]


def wait_for(pred, secs, proc, step=0.5):
    t = time.time()
    while time.time() - t < secs:
        if pred(): return True
        if proc.poll() is not None: return False
        time.sleep(step)
    return pred()


def boot(info, rd, secs, route, extra_env, boot_timeout, shot_every, log=print):
    """One boot in rd (host.log, shots/, save/): returns (exit code or None, ran the full budget, input sent, devctl liveness hang, the route's checkpoint failed to import)"""
    dmctl = _load('dmctl', SCRIPTS / 'dmctl')
    ck, rsecs, seq = route
    secs = secs or rsecs or 300   # --secs, else the route's, else 300
    old = [rd / n for n in ('host.log', 'shots', 'save', 'temp', 'stall_sample.txt') if (rd / n).exists()]
    if old:   # an earlier boot here (a resumed run whose key changed): kept aside, never deleted
        prev = rd / f'prev-{time.strftime("%Y%m%d-%H%M%S")}'; prev.mkdir()
        for p in old: p.rename(prev / p.name)
    (rd / 'shots').mkdir(parents=True); (rd / 'temp').mkdir()
    ck_failed = False
    if ck:
        import checkpoint
        try: checkpoint.import_mac(info['title_id'], ck, rd / 'save')
        except (Exception, SystemExit) as e: log(f'  [RED] checkpoint {ck}: {e}; a fresh save instead'); ck_failed = True; (rd / 'save').mkdir(exist_ok=True)
    else: (rd / 'save').mkdir()
    frames = ','.join(str(f) for f in range(shot_every, int((secs + boot_timeout) * 60) + shot_every, shot_every))   # enough for the budget at up to 60 fps
    env = dict(os.environ, DM_ROMFS=info['romfs'], DM_SAVE=str(rd / 'save'), DM_TEMP=str(rd / 'temp'), DM_MSL_DIR=info['msl_dir'], DM_NVN_SHMAP=info['shader_map'],
               DM_WATCH_STALL='60', DM_WATCH_SAMPLE=str(rd / 'stall_sample.txt'), DM_NVN_ZBLOCK='1', DM_NVN_SHOT=f'{frames}:{rd}/shots/%d.png')
    for k in ('DM_WINDOW', 'DM_AUDIO', 'DM_KEYS'): env.pop(k, None)   # headless and silent; input only through devctl
    if info.get('aoc'): env['DM_AOC_DIR'] = info['aoc']
    if info.get('games_dir'): env['DM_GAMES_DIR'] = info['games_dir']
    if info.get('games_first'): env['DM_GAMES_FIRST'] = info['games_first']
    env.update(extra_env)   # --env / --ab switches win over the runner's own
    hl = rd / 'host.log'; f = open(hl, 'w')
    p = subprocess.Popen([info['host'], info['patched']], env=env, cwd=rd, stdout=f, stderr=subprocess.STDOUT)
    txt = lambda: hl.read_text(errors='replace')
    sent, full, hang = False, False, False
    try:
        if not wait_for(lambda: '[auto] event=first_present' in txt(), boot_timeout, p): return p.poll(), False, False, False, ck_failed
        t0 = time.time(); deadline = t0 + secs
        tok = dmctl.token_from_log(hl)
        if not tok: log('  [RED] no devctl token in the log: is the host a dev build?')
        def channel(timeout): return dmctl.Channel('127.0.0.1', int(env.get('DM_DEVCTL_PORT', 47800)), tok, timeout)
        chunks = ([seq] if seq else []) + [GENERIC[i % len(GENERIC)] for i in range(100000)]
        last_frame, last_move = -1, time.time()
        for c in chunks:
            if time.time() >= deadline or p.poll() is not None or not tok: break
            try:
                ch = channel(max(5.0, min(deadline - time.time(), 600 if c is seq else 60)))
                r = ch.ask('run ' + ' '.join(c.split())); ch.close(); sent = True
                m = re.search(r'frame (\d+)', r)
                if m and int(m.group(1)) != last_frame: last_frame, last_move = int(m.group(1)), time.time()
            except (OSError, ConnectionError):   # a run that did not finish in time: is the game still presenting?
                try:
                    ch = channel(10); fr = int(re.search(r'(\d+)', ch.ask('frame')).group(1)); ch.close()
                except (OSError, ConnectionError, AttributeError): fr = last_frame
                if fr != last_frame: last_frame, last_move = fr, time.time()
                elif time.time() - last_move >= 60: hang = True; break
        while time.time() < deadline and p.poll() is None: time.sleep(1)
        full = p.poll() is None and not hang
        return p.poll(), full, sent, hang, ck_failed
    finally:
        if p.poll() is None:
            p.terminate()
            try: p.wait(10)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
        f.close()


def report_boot(rd, rc, full, sent, hang, save_failed=False):   # save_failed: the route's checkpoint did not import (boot's last value)
    s = parse_log((rd / 'host.log').read_text(errors='replace'))
    s['shot_files'] = len(list((rd / 'shots').glob('*.png')))
    s['save_failed'] = s['save_failed'] or save_failed
    status, labels = detect(s, rc, full, sent, hang)
    tail = (rd / 'host.log').read_text(errors='replace').splitlines()[-40:] if ('crash' in labels or 'hang' in labels or status == 'no-boot') else []
    return {'status': status, 'labels': labels, 'rc': rc, 'ran_full': full, 'input_sent': sent, 'signals': s, 'tail': tail}


# ---- One game, the batch ----
def run_game(d, a, stamp_dir, state, log):
    bm = _load('build_ipa_from_nsp', SCRIPTS / 'build_ipa_from_nsp.py')
    bm.PROG.mode = 'off'
    app, _ = bm.scan_nsps(d)
    tid = f'{app:016X}'
    if a.only and tid not in a.only: return None
    gd = stamp_dir / tid; gd.mkdir(parents=True, exist_ok=True)
    rpath = gd / 'report.json'
    route_file = next((p for p in ([Path(a.routes) / f'{tid}.txt'] if a.routes else []) + [REPO / f'dm/games/{tid}/compat_route.txt'] if p.is_file()), None)
    route = read_route(route_file.read_text()) if route_file else (None, None, '')
    nsps = [f'{p.name}:{p.stat().st_size}' for p in [*d.glob('*.nsp'), *d.glob('*.xci')]]
    key = run_key(nsps, state, route, {k: getattr(a, k) for k in ('secs', 'repeat', 'ab', 'shot_every', 'env', 'no_build')})
    if rpath.exists():
        try:
            old = json.loads(rpath.read_text())
            if old.get('key') == key: log(f'{tid}: reusing {rpath} ({old["status"]})'); return old
        except ValueError: pass
    if bm.free_gb(d) < a.min_free_gb:
        rep = {'title_id': tid, 'key': key, 'status': 'build-failed', 'labels': ['disk'], 'why': f'less than {a.min_free_gb} GB free'}
        rpath.write_text(json.dumps(rep, indent=1)); return rep
    t0 = time.time()
    if a.no_build:
        info_path, stage, last = d / f'{tid}_build' / 'mac_run.json', 'no mac_run.json (--no-build)', []
        if not info_path.is_file(): info_path = None
    else:
        log(f'{tid}: building ({d})')
        info_path, stage, last = build(d, a.keys, gd / 'build.log', a.build_timeout, dict(os.environ, J=str(a.jobs)))
    rep = {'title_id': tid, 'key': key, 'stamp': stamp_dir.name, 'repo': state, 'route': str(route_file or ''), 'times': {'build_s': round(time.time() - t0)}}
    if not info_path:
        rep.update(status='build-failed', labels=[], stage=stage, tail=last); rpath.write_text(json.dumps(rep, indent=1)); return rep
    info = json.loads(info_path.read_text())
    rep.update(name=info['name'], build=info['fingerprint'], provisional=info['provisional'])
    extra = env_pairs(a.env)
    boots = []
    for i in range(a.repeat):
        rd = gd if i == 0 else gd / 'extra' / f'repeat{i + 1}'
        log(f'{tid}: boot {i + 1}/{a.repeat}'); t1 = time.time()
        b = report_boot(rd, *boot(info, rd, a.secs, route, extra, a.boot_timeout, a.shot_every, log)); b['secs'] = round(time.time() - t1); boots.append(b)
    first = boots[0]
    rep.update(status=first['status'], labels=first['labels'], rc=first['rc'], signals=first['signals'], tail=first['tail'], auto=first['signals']['auto'])
    heap = {}
    if first['signals']['heap_oom']:
        import game, profile_guess
        try: heap = profile_guess.heap_signals((gd / 'host.log').read_text(errors='replace'), game.Game(info['profile_dir']))
        except Exception as e: log(f'  heap signals: {e}')
    rep['suggestions'] = suggest(first['signals'], heap)
    if a.repeat > 1:
        rep['repeats'] = [[b['status'], b['labels']] for b in boots]
        if flaky(rep['repeats']): rep['labels'] = sorted(set(rep['labels']) | {'flaky'}); rep['suggestions'].append({'kind': 'ab', 'key': 'core_preempt', 'value': 'on', 'why': 'repeats disagree or crash / hang in some'})
    for ab in a.ab:
        rd = gd / 'extra' / ('ab-' + re.sub(r'[^\w.=-]', '_', ab)); log(f'{tid}: A/B boot {ab}')
        b = report_boot(rd, *boot(info, rd, a.secs, route, dict(extra, **env_pairs([ab])), a.boot_timeout, a.shot_every, log))
        rep.setdefault('ab', {})[ab] = {'status': b['status'], 'labels': b['labels'], 'diff': compare(first, b)}
    rep['times']['total_s'] = round(time.time() - t0)
    rpath.write_text(json.dumps(rep, indent=1) + '\n')
    log(f'{tid}: {rep["status"]} {" ".join(rep["labels"])} ({rep["times"]["total_s"]} s)')
    return rep


def summary(stamp_dir, reps, baseline):
    L = [f'# Compatibility run {stamp_dir.name}', '', '| Title ID | Name | Status | Labels | First present | Suggestions |', '|---|---|---|---|---|---|']
    for r in reps:
        fp = r.get('signals', {}).get('first_present')
        L.append(f"| `{r['title_id']}` | {r.get('name', '')} | {r['status']} | {' '.join(r.get('labels', []))} | {'' if fp is None else f'{fp:.1f} s'} | {len(r.get('suggestions', []))} |")
    for r in reps:
        for ab, x in r.get('ab', {}).items(): L += ['', f"A/B `{r['title_id']}` {ab}: {x['status']} {' '.join(x['labels'])}; differences: `{json.dumps(x['diff'])}`"]
    if baseline:
        L += ['', f'## Against {baseline.name}', '']
        for r in reps:
            p = baseline / r['title_id'] / 'report.json'
            if not p.exists() or 'signals' not in r: L.append(f"- `{r['title_id']}`: no baseline"); continue
            old = json.loads(p.read_text())
            if 'signals' not in old: L.append(f"- `{r['title_id']}`: baseline {old['status']}, now {r['status']}"); continue
            L.append(f"- `{r['title_id']}`: {old['status']} -> {r['status']}; `{json.dumps(compare(old, r))}`")
    (stamp_dir / 'summary.md').write_text('\n'.join(L) + '\n')


def absolute(s): return Path(s).resolve()   # the host runs with cwd = the run directory: a relative path given to it would resolve there (writes into a directory that does not exist)


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], epilog=__doc__.split('\n\n', 1)[1], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('root', type=absolute, help='a folder of game folders, or one game folder')
    ap.add_argument('-k', '--keys', type=absolute, required=True, help='prod.keys (passed to the NSP script, never read here)')
    ap.add_argument('--out', type=absolute, default=REPO / 'data/compat', help='where runs go (default data/compat)')
    ap.add_argument('--stamp', default=time.strftime('%Y%m%d-%H%M%S'), help='run name; the same name resumes a run')
    ap.add_argument('--only', type=lambda s: {x.upper() for x in s.split(',')}, help='title IDs to run')
    ap.add_argument('--secs', type=float, help='seconds of play after the first present (default: the route\'s secs, else 300)')
    ap.add_argument('--boot-timeout', type=float, default=240, help='seconds to the first present before a run counts as not rendering (default 240)')
    ap.add_argument('--build-timeout', type=float, default=7200)
    ap.add_argument('--shot-every', type=int, default=300, help='frames between screenshots (default 300)')
    ap.add_argument('--repeat', type=int, default=1, help='boots per game; disagreeing boots are labelled flaky')
    ap.add_argument('--ab', action='append', default=[], help='KEY=VALUE[ KEY=VALUE]: one more boot with these environment switches, compared with the first')
    ap.add_argument('--env', action='append', default=[], help='KEY=VALUE switches for every boot')
    ap.add_argument('--routes', type=absolute, help='folder of <title id>.txt routes, ahead of the profiles\' compat_route.txt')
    ap.add_argument('--baseline', help='an earlier stamp to compare with in summary.md')
    ap.add_argument('--jobs', type=int, default=1, help='workers of the build stages (J, default 1: a batch runs for hours, keep the machine usable)')
    ap.add_argument('--no-build', action='store_true', help='boot each game from its existing <id>_build/mac_run.json instead of building (a re-run, or a build made elsewhere)')
    ap.add_argument('--min-free-gb', type=float, default=20)
    ap.add_argument('--no-keep-extracted', action='store_true', help='delete <id>_build/extract after each game (bounds disk use; the next build extracts again)')
    return ap.parse_args(argv)


def main(argv=None):
    a = parse_args(argv)
    if not a.keys.is_file(): sys.exit(f'no such file: {a.keys}')
    stamp_dir = a.out / a.stamp; stamp_dir.mkdir(parents=True, exist_ok=True)
    logf = open(stamp_dir / 'runner.log', 'a')
    def log(m): line = f'[{time.strftime("%H:%M:%S")}] {m}'; print(line, flush=True); logf.write(line + '\n'); logf.flush()
    if shutil.which('caffeinate'): subprocess.Popen(['caffeinate', '-i', '-w', str(os.getpid())])
    state, reps = repo_state(), []
    for d in game_dirs(a.root.resolve()):
        try: r = run_game(d, a, stamp_dir, state, log)
        except Exception as e:   # one game never stops the batch
            r = {'title_id': d.name, 'status': 'build-failed', 'labels': ['runner-error'], 'error': ''.join(traceback.format_exception(e))[-3000:]}; log(f'{d.name}: runner error {e}')
        if r is None: continue
        reps.append(r)
        if a.no_keep_extracted and r.get('title_id'):
            ex = d / f'{r["title_id"]}_build' / 'extract'
            if ex.is_dir(): shutil.rmtree(ex)
    merge_results(a.out / 'results.tsv', [dict(r, labels=' '.join(r.get('labels', []))) for r in reps if re.fullmatch(r'[0-9A-F]{16}', r['title_id'])])
    summary(stamp_dir, reps, a.out / a.baseline if a.baseline else None)
    log(f'done: {stamp_dir / "summary.md"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
