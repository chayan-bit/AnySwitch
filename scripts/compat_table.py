#!/usr/bin/env python3
"""Print the README compatibility table from the game profiles in dm/games/ (names and builds from game.tsv).

Usage: python3 scripts/compat_table.py     (paste the output into README.md)
A profile is listed as Playable unless its title ID is in EXPERIMENTAL; add the ID there while a title is in bring-up.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dm' / 'games'))
import game

EXPERIMENTAL = {'0100ABF008968000'}   # profile exists, the game is not yet verified end to end


def table():
    rows = ['| Game | Title ID | Supported builds | Status |', '|---|---|---|---|']
    for g in sorted(game.all_games(), key=lambda g: g.get('name').lower()):
        builds = ', '.join(b['display'] for b in g.builds().values())
        status = 'Experimental' if g.id in EXPERIMENTAL else 'Playable'
        rows.append(f"| {g.get('name')} | `{g.id}` | {builds} | {status} |")
    return '\n'.join(rows)


if __name__ == '__main__':
    print(table())
