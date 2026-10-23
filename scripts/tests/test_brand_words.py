"""Hearth's legal check (plan-hearth-p2.md section 7): no console brand words in what the app shows or names, and every file in a built app is ours, the system's, or from the player's own game.
Tree (CI, no game data): the Objective-C string literals of the iOS front end and Hearth, the rows of the games' settings files, the Info.plist values in project.yml and the names of Hearth's assets.
A built app (optional, local): python3 -I scripts/tests/test_brand_words.py --app <path to DmIOS.app> checks its file inventory and the names and Info.plist values outside the game's pack.
Run: python3 -I scripts/tests/test_brand_words.py"""
import json
from pathlib import Path
import plistlib
import re
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Brand names in the form a reader would see them; the generic words ("switch" as a verb, "home") stay allowed
BANNED = re.compile(r'\b(Switch|HOME Menu|Joy-?Con|Mii|My Page)\b|(?i:\b(nintendo|amiibo|eshop)\b)')
# A built app's files: ours or the system's (anywhere but pack/), and the game's (the player's own dump, converted) under pack/ and Frameworks/
APP_FILES = [
    (r'_CodeSignature/.+|embedded\.mobileprovision|Info\.plist|PkgInfo|Assets\.car|AppIcon[\w@~.-]*\.png|DmIOS', 'ours or the system\'s (signature, plist, asset catalog with Hearth\'s icon, the executable)'),
    (r'licenses\.txt', 'ours: the licences of the shipped components (dm/ios/tools/gen_licenses.py)'),
    (r'Frameworks/[0-9A-F]{16}\.dylib', 'the game\'s code, rewritten from the player\'s dump'),
    (r'pack/(manifest\.json|profile/.+)', 'ours: the pack index and the tables the converter wrote'),
    (r'pack/font/(standard|nintendo_ext)\.ttf', 'ours or the system\'s: stand-ins for the shared fonts (the file name is the font the game asks for, never shown)'),
    (r'pack/(meta|msl|pso|aoc)/.+', 'the game\'s: its icon and control data, translated shaders, pipelines and add-on content'),
]


def objc_strings(text):
    return re.findall(r'@"((?:[^"\\]|\\.)*)"', text)


def settings_strings(j):   # what a games' settings file shows: section titles, row labels, details and option labels
    out = []
    for sec in j.get('sections', []) if isinstance(j, dict) else []:
        out.append(str(sec.get('title', '')))
        for e in sec.get('settings', []):
            out += [str(e.get('label', '')), str(e.get('detail', ''))] + [str(o.get('label', '')) for o in e.get('options', [])]
    return out


def plist_values(yml_text):   # the values of the info: properties: block of project.yml (comments dropped)
    block = re.search(r'\n      properties:\n((?:        .*\n|\s*\n)+)', yml_text)
    return [re.sub(r'\s+#.*$', '', ln).split(':', 1)[1].strip() for ln in (block.group(1).splitlines() if block else []) if ':' in ln]


def scan_tree(root):
    """Every brand word in what the app shows or names: [(file, text)]"""
    root = Path(root); hits = []
    for d in ('dm/ios/Sources', 'dm/ios/Hearth'):
        for f in sorted((root / d).rglob('*.m')):
            hits += [(f, s) for s in objc_strings(f.read_text(encoding='utf-8')) if BANNED.search(s)]
    for f in sorted((root / 'dm/games').glob('*/settings.json')):
        hits += [(f, s) for s in settings_strings(json.loads(f.read_text(encoding='utf-8'))) if BANNED.search(s)]
    yml = root / 'dm/ios/project.yml'
    hits += [(yml, v) for v in plist_values(yml.read_text(encoding='utf-8')) if BANNED.search(v)]
    hits += [(f, f.name) for f in sorted((root / 'dm/ios/Hearth/Assets').rglob('*')) if BANNED.search(f.name)]
    return hits


def scan_app(app):
    """A built app: ([(file, why)] for files of no known kind, [(where, text)] for brand words in names and Info.plist values outside the game's pack)"""
    app = Path(app); unknown, words = [], []
    for f in sorted(p for p in app.rglob('*') if p.is_file()):
        rel = f.relative_to(app).as_posix()
        if not any(re.fullmatch(rx, rel) for rx, _ in APP_FILES): unknown.append((rel, 'not a known kind of file'))
        if not rel.startswith('pack/') and BANNED.search(rel): words.append((rel, rel))
    info = plistlib.loads((app / 'Info.plist').read_bytes()) if (app / 'Info.plist').exists() else {}
    def walk(v, at):
        if isinstance(v, str) and BANNED.search(v): words.append(('Info.plist ' + at, v))
        elif isinstance(v, dict): [walk(x, f'{at}.{k}') for k, x in v.items()]
        elif isinstance(v, list): [walk(x, f'{at}[{i}]') for i, x in enumerate(v)]
    walk(info, '')
    return unknown, words


class BrandWords(unittest.TestCase):
    def test_the_tree_has_none(self):
        self.assertEqual(scan_tree(ROOT), [])

    def test_the_scan_sees_what_it_should(self):   # the scan reads real strings: the registry's labels are there
        text = (ROOT / 'dm/ios/Sources/DmSettings.m').read_text(encoding='utf-8')
        self.assertIn('Bars around the picture', objc_strings(text))
        self.assertIn('Hearth', ' '.join(plist_values((ROOT / 'dm/ios/project.yml').read_text(encoding='utf-8'))))

    def test_a_planted_word_fails(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            for d in ('dm/ios/Sources', 'dm/ios/Hearth/Assets', 'dm/games/0000000000000001'): (t / d).mkdir(parents=True)
            shutil.copy(ROOT / 'dm/ios/project.yml', t / 'dm/ios/project.yml')
            self.assertEqual(scan_tree(t), [])
            (t / 'dm/ios/Sources/X.m').write_text('l.text = @"1x (Switch)"; NSLog(@"switch layouts");\n', encoding='utf-8')
            (t / 'dm/games/0000000000000001/settings.json').write_text(json.dumps({'sections': [{'id': 'g', 'title': 'Amiibo', 'settings': []}]}), encoding='utf-8')
            (t / 'dm/ios/Hearth/Assets/joycon.png').write_bytes(b'')
            (t / 'dm/ios/Hearth/Assets/Joy-Con.png').write_bytes(b'')
            got = sorted(s for _, s in scan_tree(t))
            self.assertEqual(got, ['1x (Switch)', 'Amiibo', 'Joy-Con.png'])   # "switch" as a verb is fine

    def test_the_shipped_licences_have_none(self):   # About > Licences shows this text (dm/ios/tools/gen_licenses.py); every licence it names must still be there
        sys.path.insert(0, str(ROOT / 'dm/ios/tools'))
        from gen_licenses import render
        text = render(ROOT)
        self.assertEqual(BANNED.findall(text), [])
        for part in ('libvpx', 'Zstandard', 'stb_vorbis', 'h1k421', 'Advanced Micro Devices', 'deko3d', 'Permission is hereby granted'): self.assertIn(part, text)

    def test_a_built_app_inventory(self):
        with tempfile.TemporaryDirectory() as t:
            app = Path(t) / 'DmIOS.app'
            for rel in ('DmIOS', 'Assets.car', 'PkgInfo', '_CodeSignature/CodeResources', 'Frameworks/0100000000010000.dylib', 'pack/manifest.json', 'pack/meta/icon.jpg', 'pack/font/nintendo_ext.ttf', 'licenses.txt'):
                (app / rel).parent.mkdir(parents=True, exist_ok=True); (app / rel).write_bytes(b'')
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleDisplayName': 'Hearth'}))
            self.assertEqual(scan_app(app), ([], []))
            (app / 'Nintendo.png').write_bytes(b''); (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleDisplayName': 'Switch Home'}))
            unknown, words = scan_app(app)
            self.assertEqual([u for u, _ in unknown], ['Nintendo.png']); self.assertEqual(sorted(w for _, w in words), ['Nintendo.png', 'Switch Home'])


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--app':
        unknown, words = scan_app(sys.argv[2])
        for rel, why in unknown: print(f'UNKNOWN {rel}: {why}')
        for at, text in words: print(f'BRAND {at}: {text}')
        files = [p for p in Path(sys.argv[2]).rglob('*') if p.is_file()]
        print(f'{len(files)} files: {len(unknown)} of no known kind, {len(words)} brand words outside the game\'s pack')
        sys.exit(1 if unknown or words else 0)
    unittest.main()
