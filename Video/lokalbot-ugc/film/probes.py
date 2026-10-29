#!/usr/bin/env python3
"""Writes the probe shots for one take: the take's setup followed by its actions
up to each `mark`, with no actions of its own. `rig probe` runs one on a fresh
launch and saves the window's accessibility tree and a frame at that point, so
a target that misses can be fixed from what the window really held.

    probes.py <shot.json> <out-dir>      prints one probe shot path per line
"""
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    shot_path, out = Path(sys.argv[1]), Path(sys.argv[2])
    shot = json.loads(shot_path.read_text())
    out.mkdir(parents=True, exist_ok=True)
    steps = [('start', 0)] + [(a['mark'], i + 1) for i, a in enumerate(shot['actions']) if 'mark' in a]
    for n, (name, upto) in enumerate(steps):
        probe = dict(shot, setup=shot.get('setup', []) + shot['actions'][:upto], actions=[])
        path = out / f'{shot_path.stem}-{n}-{name}.json'
        path.write_text(json.dumps(probe, indent=2))
        print(path)


if __name__ == '__main__':
    main()
