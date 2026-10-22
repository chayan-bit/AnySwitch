#!/usr/bin/env python3
# Game profiles: dm/games/<base game title ID>/game.tsv (key <TAB> values..., lines starting with # are comments) + the shader tables and dmsh_chain.h in the same folder. The shader tools, iOS packaging and the NSP script take each game's constants from here; the host reads them at boot from game.json (game.py json).
# Usage: game.py list (list all profiles); game.py <id> <key> (print that key's value, for shell); game.py json <id> <out> (the resolved profile the host reads at boot: <out> or <out>/game.json);
#   game.py dir <id> (print the profile folder); game.py link <id> <link> (point a symlink at the profile folder: make cannot take paths with spaces)
#   From Python: import game; g = game.load() (takes DM_GAME; there is no default game: unset is an error that lists the profiles); game.by_title(title ID); g.get / g.words / g.int / g.builds() / g.table(file name)
# DM_GAMES_DIR (folders separated by ':') adds profile folders outside the repository, searched after dm/games: the NSP script writes a provisional profile for a game without one into
#   <NSP folder>/<id>_build/profile/<id>/ and points DM_GAMES_DIR at <id>_build/profile, so the shader tools, game.py json and build_ipa.sh all find it.
#   DM_GAMES_FIRST=1 searches DM_GAMES_DIR before dm/games (the NSP script's --provisional: a provisional profile for a game that has one in dm/games, to test the guesses)
import json, os, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
AUTO_MODES = {'off': 0, 'on': 1, 'auto': 2}   # values of the keys that take auto (nvn_autostat.h NVN_AUTO_*)
PROFILE_SCHEMA = 1   # the keys and value types of game.json; equals DM_PROFILE_SCHEMA in dm/host/dm_abi.h (dm/host/profile.m refuses any other)


class Game:
    def __init__(self, d):
        self.dir = Path(d).resolve(); self.id = self.dir.name; self.rows = []
        for line in (self.dir / 'game.tsv').read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.lstrip().startswith('#'): continue
            c = line.split('\t'); self.rows.append((c[0].strip(), [v.strip() for v in c[1:]]))

    def values(self, key):   # every row of this key (keys such as build repeat)
        return [v for k, v in self.rows if k == key]

    def get(self, key, default=None):
        r = self.values(key)
        if r: return '\t'.join(r[0])
        if default is None: raise KeyError(f'{self.dir / "game.tsv"} has no key {key}')
        return default

    def words(self, key, default=None): return self.get(key, default).split()
    def int(self, key): return int(self.get(key), 0)
    def table(self, name): return self.dir / name

    @property
    def title_id(self): return int(self.get('title_id'), 16)

    def builds(self):
        """{version: {'display': display version, module name: build ID, ...}}"""
        out = {}
        for ver, disp, *mods in self.values('build'):
            out[ver] = dict([('display', disp)] + [tuple(m.split('=', 1)) for m in mods])
        return out

    def pairs(self, key):   # "a=b c=d" → [(a, b), (c, d)]
        return [tuple(w.split('=', 1)) for w in self.words(key)]


def extra_dirs():   # profile folders outside the repository (DM_GAMES_DIR), searched after dm/games
    return [Path(p) for p in os.environ.get('DM_GAMES_DIR', '').split(':') if p]


def search_dirs():   # dm/games, then DM_GAMES_DIR; DM_GAMES_FIRST=1 the other way round
    return extra_dirs() + [HERE] if os.environ.get('DM_GAMES_FIRST') else [HERE] + extra_dirs()


def find_dir(name):   # the profile folder of a title ID (the first of search_dirs that has it); a path is taken as is
    if os.sep in str(name): return Path(name)
    return next((d / name for d in search_dirs() if (d / name / 'game.tsv').exists()), HERE / name)


def load(name=None):
    name = name or os.environ.get('DM_GAME')
    if not name:   # there is no default game
        have = ', '.join(f'{g.id} ({g.get("name", "")})' for g in all_games())
        raise SystemExit(f'[RED] DM_GAME is not set: pick a game profile by base game title ID: {have}')
    d = find_dir(name)
    if not (d / 'game.tsv').exists():   # profile folders are named after the base game's title ID (the old names smbw / fe_engage are gone)
        have = ', '.join(f'{g.id} ({g.get("name", "")})' for g in all_games())
        raise SystemExit(f'[RED] no game profile {d / "game.tsv"} (DM_GAME / GAME take the base game title ID: {have})')
    return Game(d)


def all_games():
    out, seen = [], set()
    for root in search_dirs():
        if not root.is_dir(): continue
        for d in sorted(root.iterdir()):
            if (d / 'game.tsv').exists() and d.name not in seen: seen.add(d.name); out.append(Game(d))
    return out


def by_title(tid):
    return next((g for g in all_games() if g.title_id == tid), None)


def resolve(g):
    """the profile values the host uses, validated and resolved (on / off → bool, auto → 0 off / 1 on / 2 auto, hex → int): the content of game.json (json_text), which dm/host/profile.m reads at boot"""
    mods = g.words('modules')
    if not 1 <= len(mods) <= 8 or any(not re.fullmatch(r'\w{1,15}', m) for m in mods): sys.exit(f'{g.id}: modules takes 1 to 8 names of at most 15 characters: {mods}')
    pick = lambda key, default, allowed: v if (v := g.get(key, default)) in allowed else sys.exit(f'{g.id}: {key} must be one of {", ".join(allowed)}: {v}')
    keys = lambda key: [k for k in g.words(key, '') if re.fullmatch(r'[0-9a-f]{8,16}', k) or sys.exit(f'{g.id}: {key} takes fragment shader keys (8-16 lowercase hex digits): {k}')]
    tfu, tdu = pick('tex_flush_upload', 'off', AUTO_MODES), pick('tex_dirty_upload', 'off', AUTO_MODES)
    if (tdu == 'on' and tfu != 'on') or (tdu == 'auto' and tfu == 'off'): sys.exit(f'{g.id}: tex_dirty_upload on needs tex_flush_upload on, and auto needs it on or auto: {tdu}')
    api = g.get('device_api', '')
    if api and not re.fullmatch(r'\d+\.\d+', api): sys.exit(f'{g.id}: device_api must be major.minor: {api}')
    ch = g.table('dmsh_chain.h')   # the shader translation chain version (dm/gfx/tools/dmsh_chain.py --header); the host loads only <library dir>/b-<chain>/
    ch = re.search(r'#define DMSH_CHAIN "(\w+)"', ch.read_text()) if ch.is_file() else None
    r = {'schema': PROFILE_SCHEMA, 'id': g.id, 'name': g.get('name'), 'program_id': f'{int(g.get("program_id"), 16):016X}', 'modules': mods, 'romfs_marker': g.get('romfs_marker'),
         'mem_reserve': g.int('mem_reserve'), 'mem_alias': g.int('mem_alias'), 'mem_stack': g.int('mem_stack'), 'app_pool': g.int('app_pool'), 'mem_used': int(g.get('mem_used', '0x4000000'), 0),
         'game_args': g.get('game_args', ''), 'game_env': g.get('game_env', ''), 'mem_map_limit': pick('mem_map_limit', 'off', ('on', 'off')) == 'on',
         'display_versions': [[b['main'], b['display']] for b in g.builds().values() if 'main' in b],
         'present_display': pick('present_interval', 'game', ('game', 'display')) == 'display', 'core_preempt': pick('core_preempt', 'off', ('on', 'off')) == 'on',
         'alloc_big_align': pick('alloc_big_align', 'off', ('on', 'off')) == 'on', 'fps_target': int(pick('fps_target', '0', ('0', '30', '60'))),
         'fps_hold': pick('fps_hold', 'on', ('on', 'off')) == 'on', 'pad_full': pick('pad_layout', 'simple', ('simple', 'full')) == 'full',
         'opmode_console': pick('op_mode', 'console', ('console', 'handheld')) == 'console', 'perf_boost': pick('perf_mode', 'follow', ('follow', 'boost')) == 'boost',
         'feedback_snap': ' '.join(keys('feedback_snap')), 'alpha_from_red': ' '.join(keys('alpha_from_red')),
         'tex_flush_upload': AUTO_MODES[tfu], 'render_cond': AUTO_MODES[pick('render_cond', 'off', AUTO_MODES)], 'tex_dirty_upload': AUTO_MODES[tdu],
         'tex_dyn_slots': pick('tex_dyn_slots', 'off', ('on', 'off')) == 'on', 'gpu_ts_segment': pick('gpu_timestamps', 'segment', ('submission', 'segment')) == 'segment',
         'vconv_range': pick('vconv_range', 'off', ('on', 'off')) == 'on', 'chain': ch.group(1) if ch else ''}
    if g.get('shared_font', ''): r['shared_font_ttf'] = pick('shared_font', 'bfttf', ('bfttf', 'ttf')) == 'ttf'   # optional: without the key the host decides by the SDK version (hle_sdk16.c)
    if api: r['nvn_api'] = [int(x) for x in api.split('.')]   # optional: without the key the host decides by the SDK version (hle_nvn.c nvn_api)
    return r


def json_text(g):   # game.json: the resolved profile, one key per line so a diff reads well
    return json.dumps(resolve(g), indent=1, ensure_ascii=False) + '\n'


def write_if_changed(out, text):   # written only when it changes: make runs these rules every time, and an unchanged file must not rebuild anything
    out = Path(out); out.parent.mkdir(parents=True, exist_ok=True)
    if not (out.exists() and out.read_text(encoding='utf-8') == text):
        tmp = out.with_name(out.name + '.tmp'); tmp.write_text(text, encoding='utf-8'); tmp.replace(out)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['list']:
        for g in all_games(): print(f'{g.id}\t{g.title_id:016X}\t{g.get("name", "")}')
    elif len(a) == 3 and a[0] == 'json':   # <out> ending in .json is the file, anything else a folder that gets <out>/game.json
        write_if_changed(a[2] if a[2].endswith('.json') else Path(a[2]) / 'game.json', json_text(load(a[1])))
    elif len(a) == 2 and a[0] == 'dir':
        print(load(a[1]).dir)
    elif len(a) == 3 and a[0] == 'link':   # link → the profile folder (replaced when it points elsewhere)
        d, ln = load(a[1]).dir, Path(a[2]); ln.parent.mkdir(parents=True, exist_ok=True)
        if not (ln.is_symlink() and Path(os.readlink(ln)) == d):
            if ln.is_symlink() or ln.exists(): ln.unlink()
            ln.symlink_to(d)
    elif len(a) == 2:
        print(load(a[0]).get(a[1]))
    else:
        sys.exit(__doc__ or 'usage: game.py list | game.py <id> <key> | game.py json <id> <out> | game.py dir <id> | game.py link <id> <link>')
