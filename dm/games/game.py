#!/usr/bin/env python3
# Game profiles: dm/games/<base game title ID>/game.tsv (key <TAB> values..., lines starting with # are comments) + the shader tables and dmsh_chain.h in the same folder. The shader tools, the host build, iOS packaging and the NSP script take each game's constants from here.
# Usage: game.py list (list all profiles); game.py <id> <key> (print that key's value, for shell); game.py header <id> <out.h> (generate the host's game_profile.h); game.py json <id> <out> (the resolved profile the host reads at boot: <out> or <out>/game.json);
#   game.py dir <id> (print the profile folder); game.py link <id> <link> (point a symlink at the profile folder: make cannot take paths with spaces)
#   From Python: import game; g = game.load() (takes DM_GAME; there is no default game: unset is an error that lists the profiles); game.by_title(title ID); g.get / g.words / g.int / g.builds() / g.table(file name)
# DM_GAMES_DIR (folders separated by ':') adds profile folders outside the repository, searched after dm/games: the NSP script writes a provisional profile for a game without one into
#   <NSP folder>/<id>_build/profile/<id>/ and points DM_GAMES_DIR at <id>_build/profile, so the shader tools, the host build and build_ipa.sh all find it.
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


def header(g):
    """the host's game_profile.h: the profile constants the host uses, as macros"""
    q = lambda s: '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    mods = g.words('modules')
    vers = ', '.join('{' + q(b['main']) + ', ' + q(b['display']) + '}' for b in g.builds().values() if 'main' in b)
    pi = g.get('present_interval', 'game')   # present interval: game = as the game sets it (as on the Switch), display = one frame per display tick
    if pi not in ('game', 'display'): sys.exit(f'{g.id}: present_interval must be game or display: {pi}')
    ft = g.get('fps_target', '0')   # frame rate cap of the rewriter's frame step (patch_nso.py FRAME_STEP: Tears of the Kingdom 1.4.3, Breath of the Wild 1.9.0) or of the engine's own frame limit (hle_fpslock.c): 0 = the game's own step, 30 / 60
    if ft not in ('0', '30', '60'): sys.exit(f'{g.id}: fps_target must be 0, 30 or 60: {ft}')
    fh = g.get('fps_hold', 'on')   # whether the frame step may hold a frame longer than the cap's vsyncs when frames come late (hle_nvn.c fstep_tick): on / off
    if fh not in ('on', 'off'): sys.exit(f'{g.id}: fps_hold must be on or off: {fh}')
    cp = g.get('core_preempt', 'off')   # same-core preemption approximation (hle_thread.c): on / off
    if cp not in ('on', 'off'): sys.exit(f'{g.id}: core_preempt must be on or off: {cp}')
    aba = g.get('alloc_big_align', 'off')   # nn::mem::StandardAllocator::Allocate aligns blocks of 64 KB or more to 64 KB (hle_os.c; Vanillaware's memory pool storage): on / off
    if aba not in ('on', 'off'): sys.exit(f'{g.id}: alloc_big_align must be on or off: {aba}')
    sf = g.get('shared_font', 'bfttf')   # what the shared-font address points at (hle_sdk16.c): bfttf = 8-byte header + TTF, ttf = the TTF alone
    if sf not in ('bfttf', 'ttf'): sys.exit(f'{g.id}: shared_font must be bfttf or ttf: {sf}')
    pl = g.get('pad_layout', 'simple')   # the virtual gamepad's first layout (DmGamepad.m; afterwards whatever the player switched to in game is kept): simple = 2D, full = 3D (D-pad, right stick, L3 / R3)
    if pl not in ('simple', 'full'): sys.exit(f'{g.id}: pad_layout must be simple or full: {pl}')
    fbs = g.words('feedback_snap', '')   # fragment shader key prefixes whose same-pass feedback sampling gets a snapshot first (nvn_mtl.m fb_prepare); none by default
    if any(not re.fullmatch(r'[0-9a-f]{8,16}', k) for k in fbs): sys.exit(f'{g.id}: feedback_snap takes fragment shader keys (8-16 lowercase hex digits): {fbs}')
    afr = g.words('alpha_from_red', '')   # fragment shader key prefixes that read single-channel textures mapped (R, 0, 0, 1) with alpha = red (nvn_mtl.m tex_alpha_red); none by default
    if any(not re.fullmatch(r'[0-9a-f]{8,16}', k) for k in afr): sys.exit(f'{g.id}: alpha_from_red takes fragment shader keys (8-16 lowercase hex digits): {afr}')
    # Keys on their way to detection at run time take auto as well (nvn_autostat.h): macro 0 off / 1 on / 2 auto; auto resolves to off until the key's detector lands, and the host's
    # environment switches (DM_NVN_RENDER_COND, DM_NVN_TEX_GUEST for both texture keys) override the profile either way
    rcd = g.get('render_cond', 'off')   # NVN conditional rendering evaluated at replay, timestamp reports with counter 0 (nvn_mtl.m OP_RENDER_COND): on / off / auto
    if rcd not in AUTO_MODES: sys.exit(f'{g.id}: render_cond must be on, off or auto: {rcd}')
    tfu = g.get('tex_flush_upload', 'off')   # textures written by the CPU into a pool and published with nvnMemoryPoolFlushMappedRange are uploaded like packaged ones (hle_nvn.c): on / off / auto
    if tfu not in AUTO_MODES: sys.exit(f'{g.id}: tex_flush_upload must be on, off or auto: {tfu}')
    tdu = g.get('tex_dirty_upload', 'off')   # with tex_flush_upload: a registered texture the CPU writes after init without any flush is uploaded too (dirty pages, hle_nvn.c nvn_ft_written): on / off / auto
    if tdu not in AUTO_MODES or (tdu == 'on' and tfu != 'on') or (tdu == 'auto' and tfu == 'off'):
        sys.exit(f'{g.id}: tex_dirty_upload must be on, off or auto, on needs tex_flush_upload on and auto needs it on or auto: {tdu}')
    tds = g.get('tex_dyn_slots', 'off')   # shaders whose texture handle the translator could not trace to one slot: slot indices in c2, the bound slots in the fallback arrays (nvn_mtl.m): on / off
    if tds not in ('on', 'off'): sys.exit(f'{g.id}: tex_dyn_slots must be on or off: {tds}')
    vcr = g.get('vconv_range', 'off')   # vertex attributes converted on the CPU only over the vertices each draw reads (nvn_mtl.m vc_draw_range): on / off
    if vcr not in ('on', 'off'): sys.exit(f'{g.id}: vconv_range must be on or off: {vcr}')
    mml = g.get('mem_map_limit', 'off')   # MapPhysicalMemory refused beyond the application pool, as on Horizon (hle_svc.c): on / off
    if mml not in ('on', 'off'): sys.exit(f'{g.id}: mem_map_limit must be on or off: {mml}')
    gts = g.get('gpu_timestamps', 'segment')   # counter timestamps (nvn_mtl.m rep_ticks): segment (default) = the GPU start / end of the segment holding the report, submission = one time per submission
    if gts not in ('submission', 'segment'): sys.exit(f'{g.id}: gpu_timestamps must be submission or segment: {gts}')
    om = g.get('op_mode', 'console')   # the operation mode reported at start (hle_oe.c dm_opmode; DM_OPMODE overrides): console = docked, handheld = touch screen in use (Super Mario Galaxy's pointer)
    if om not in ('console', 'handheld'): sys.exit(f'{g.id}: op_mode must be console or handheld: {om}')
    pm = g.get('perf_mode', 'follow')   # the performance mode reported (hle_oe.c): follow = the operation mode's (Boost docked, Normal handheld), boost = Boost always
    if pm not in ('follow', 'boost'): sys.exit(f'{g.id}: perf_mode must be follow or boost: {pm}')
    api = g.get('device_api', '55.15')   # the NVN API major.minor version nvnDeviceGetInteger reports (hle_nvn.c)
    if not re.fullmatch(r'\d+\.\d+', api): sys.exit(f'{g.id}: device_api must be major.minor: {api}')
    src = f'dm/games/{g.id}' if g.dir.parent == HERE else str(g.dir)
    L = [f'// Generated by dm/games/game.py from {src}/game.tsv; do not edit',
         '#pragma once',
         f'#define DM_GAME_ID {q(g.id)}',
         f'#define DM_GAME_NAME {q(g.get("name"))}',
         f'#define DM_GAME_PROGRAM_ID 0x{int(g.get("program_id"), 16):016X}ull',
         f'#define DM_GAME_MODULES {{{", ".join(map(q, mods))}}}',
         f'#define DM_GAME_NMOD {len(mods)}',
         f'#define DM_GAME_ROMFS_MARKER {q(g.get("romfs_marker"))}',
         f'#define DM_GAME_MEM_RESERVE {g.int("mem_reserve"):#x}ull',
         f'#define DM_GAME_MEM_ALIAS {g.int("mem_alias"):#x}ull',
         f'#define DM_GAME_MEM_STACK {g.int("mem_stack"):#x}ull',
         f'#define DM_GAME_APP_POOL {g.int("app_pool"):#x}ull',
         f'#define DM_GAME_MEM_USED {int(g.get("mem_used", "0x4000000"), 0):#x}ull',   # used memory reported beside the heap (hle_svc.c GetInfo UsedMemorySize)
         f'#define DM_GAME_ARGS {q(g.get("game_args", ""))}',   # game arguments when the command line gives none (main.c; Octopath Traveler 0: Unreal's -SwitchVirtualAddressSpaceSize=)
         f'#define DM_GAME_ENV {q(g.get("game_env", ""))}',   # KEY=VALUE pairs getenv answers (hle_os.c; Absolum: .NET's DOTNET_GCRegionRange)
         f'#define DM_GAME_MEM_MAP_LIMIT {int(mml == "on")}',
         f'#define DM_GAME_DISPLAY_VERSIONS {vers}',
         f'#define DM_GAME_PRESENT_DISPLAY {int(pi == "display")}',
         f'#define DM_GAME_CORE_PREEMPT {int(cp == "on")}',
         f'#define DM_GAME_ALLOC_BIG_ALIGN {int(aba == "on")}',
         f'#define DM_GAME_FPS_TARGET {int(ft)}',
         f'#define DM_GAME_FPS_HOLD {int(fh == "on")}',
         *([f'#define DM_GAME_SHARED_FONT_TTF {int(sf == "ttf")}'] if g.get('shared_font', '') else []),   # without the key the host decides by the SDK version (hle_sdk16.c)
         f'#define DM_GAME_PAD_FULL {int(pl == "full")}',
         f'#define DM_GAME_OPMODE {int(om == "console")}',
         f'#define DM_GAME_PERF_BOOST {int(pm == "boost")}',
         f'#define DM_GAME_FEEDBACK_SNAP {q(" ".join(fbs))}',
         f'#define DM_GAME_ALPHA_FROM_RED {q(" ".join(afr))}',
         f'#define DM_GAME_TEX_FLUSH_UPLOAD {AUTO_MODES[tfu]}',
         f'#define DM_GAME_RENDER_COND {AUTO_MODES[rcd]}',
         f'#define DM_GAME_TEX_DIRTY_UPLOAD {AUTO_MODES[tdu]}',
         f'#define DM_GAME_TEX_DYN_SLOTS {int(tds == "on")}',
         f'#define DM_GAME_GPU_TS_SEGMENT {int(gts == "segment")}',
         f'#define DM_GAME_VCONV_RANGE {int(vcr == "on")}',
         *([f'#define DM_GAME_NVN_API_MAJOR {api.split(".")[0]}', f'#define DM_GAME_NVN_API_MINOR {api.split(".")[1]}'] if g.get('device_api', '') else []),   # without the key: by the SDK version (hle_nvn.c nvn_api)
         '']
    return '\n'.join(L)


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
    elif len(a) == 3 and a[0] == 'header':
        write_if_changed(a[2], header(load(a[1])))
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
        sys.exit(__doc__ or 'usage: game.py list | game.py <id> <key> | game.py header <id> <out.h> | game.py json <id> <out> | game.py dir <id> | game.py link <id> <link>')
