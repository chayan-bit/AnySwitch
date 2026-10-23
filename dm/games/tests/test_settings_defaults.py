"""Per-game settings files (dm/games/<id>/settings.json, copied into the app by dm/ios/tools/build_ipa.sh): the file is valid JSON of the documented form, its defaults name registered keys,
and the frame cap default matches the profile's fps_target, so the in-app screen shows what the host really does. No game data.
Run: python3 -I dm/games/tests/test_settings_defaults.py"""
import json
import re
from pathlib import Path
import unittest
GAMES = Path(__file__).resolve().parents[1]
REGISTRY = GAMES.parent / 'ios' / 'Sources' / 'DmSettings.m'
KEYS = set(re.findall(r'@"key": @"(DM_[A-Z0-9_]+)"', REGISTRY.read_text(encoding='utf-8')))
FILES = sorted(GAMES.glob('*/settings.json'))


def profile_value(game_dir, key):
    for line in (game_dir / 'game.tsv').read_text(encoding='utf-8').splitlines():
        f = line.split('\t')
        if len(f) >= 2 and f[0] == key: return f[1]
    return None


class SettingsFiles(unittest.TestCase):
    def test_registry_keys_were_found(self): self.assertIn('DM_FPS_TARGET', KEYS); self.assertIn('DM_SHAKE_G', KEYS)

    def test_files_are_objects_with_known_keys(self):
        for f in FILES:
            with self.subTest(f=f.parent.name):
                j = json.loads(f.read_text(encoding='utf-8'))
                self.assertIsInstance(j, dict)
                self.assertLessEqual(set(j), {'sections', 'defaults'})
                self.assertIsInstance(j.get('defaults', {}), dict)
                self.assertLessEqual(set(j.get('defaults', {})), KEYS | {k for s in j.get('sections', []) for e in s.get('settings', []) for k in [e.get('key')]})

    def test_frame_cap_default_follows_the_profile(self):
        for g in sorted(GAMES.glob('*/game.tsv')):
            target = profile_value(g.parent, 'fps_target')
            f = g.parent / 'settings.json'
            with self.subTest(game=g.parent.name):
                got = json.loads(f.read_text(encoding='utf-8')).get('defaults', {}).get('DM_FPS_TARGET') if f.exists() else None
                self.assertEqual(got, target)   # a profile without fps_target keeps the registry default (0, "Game decides")

    def test_console_mode_default_follows_the_profile(self):
        for g in sorted(GAMES.glob('*/game.tsv')):
            handheld = profile_value(g.parent, 'op_mode') == 'handheld'
            f = g.parent / 'settings.json'
            with self.subTest(game=g.parent.name):
                got = json.loads(f.read_text(encoding='utf-8')).get('defaults', {}).get('DM_OPMODE') if f.exists() else None
                self.assertEqual(got, '0' if handheld else None)   # Docked (the registry default) unless the profile runs the game handheld


if __name__ == '__main__': unittest.main()
