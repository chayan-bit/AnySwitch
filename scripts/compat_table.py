#!/usr/bin/env python3
"""Print the README compatibility table from the game profiles in dm/games/ (names and builds from game.tsv).

Usage: python3 scripts/compat_table.py     (paste the output into README.md)
       python3 scripts/compat_table.py --results [data/compat/results.tsv]     (the latest compatibility run per title, scripts/compat_run.py; not for README.md)
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


def results(path):   # compat_run.py's results.tsv as a table; names from the profiles where one exists, else from the run
    names = {g.id: g.get('name') for g in game.all_games()}
    lines = Path(path).read_text().splitlines()
    rows = [dict(zip(lines[0].split('\t'), l.split('\t'))) for l in lines[1:] if l]
    out = ['| Game | Title ID | Status | Labels | Run |', '|---|---|---|---|---|']
    for r in sorted(rows, key=lambda r: (names.get(r['title_id']) or r.get('name') or r['title_id']).lower()):
        out.append(f"| {names.get(r['title_id']) or r.get('name', '')} | `{r['title_id']}` | {r['status']} | {r.get('labels', '')} | {r.get('stamp', '')} |")
    return '\n'.join(out)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--results']:
        print(results(sys.argv[2] if len(sys.argv) > 2 else Path(__file__).resolve().parents[1] / 'data/compat/results.tsv'))
    else:
        print(table())
