"""Write a replay job for QwenLanguageSampleReplayTests.

  make_manifest.py --modes before --layouts word plain --sets fleurs switch
  make_manifest.py --modes after --ids ami-ES2004a

Tracks come from items.json (fetch_tracks.py). `--meetings` adds the owner's own meeting
tracks, read in place from the LokalBot library through `lokalbot-cli path` (read only);
they have no reference and are scored on agreement with the old path and on speed. The job is
written to QLS_OUT/manifest.json and results append to QLS_OUT/runs.jsonl.
"""
import argparse
import json
import os
import subprocess
from pathlib import Path

OUT = Path(os.environ.get('QLS_OUT', '/private/tmp/lokalbot-qwen-sample'))
SAMPLE_SIZES = [2, 3, 4, 5, 6, 8, 10, 12, 16, 24]


def meeting_tracks(meeting_ids):
    tracks = []
    for meeting_id in meeting_ids:
        folder = Path(subprocess.run(['lokalbot-cli', 'path', meeting_id], check=True, capture_output=True,
                                     text=True).stdout.strip())
        for track in ['mic', 'system']:
            source = folder / f'{track}.m4a'
            if source.exists():
                tracks.append({'id': f'meeting-{meeting_id}-{track}', 'set': 'meetings', 'wav': str(source)})
    return tracks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--modes', nargs='+', default=['before'], choices=['before', 'after'])
    parser.add_argument('--layouts', nargs='+', default=['word', 'plain'], choices=['word', 'plain'])
    parser.add_argument('--sets', nargs='*', default=[])
    parser.add_argument('--ids', nargs='*', default=[])
    parser.add_argument('--meetings', nargs='*', default=[])
    parser.add_argument('--output', default=str(OUT / 'runs.jsonl'))
    parser.add_argument('--alternate', action='store_true',
                        help='swap the order of the modes on every other track and layout (paired timing)')
    args = parser.parse_args()
    items = json.loads((OUT / 'items.json').read_text())
    tracks = [{'id': i['id'], 'set': i['set'], 'wav': i['wav']} for i in items
              if i['set'] in args.sets or i['id'] in args.ids]
    meetings = meeting_tracks(args.meetings)
    if meetings:
        known = {m['id']: m for m in json.loads((OUT / 'meetings.json').read_text())} \
            if (OUT / 'meetings.json').exists() else {}
        known.update({m['id']: m for m in meetings})
        (OUT / 'meetings.json').write_text(json.dumps(list(known.values()), indent=1))
    tracks += meetings
    job = {'output': args.output, 'modes': args.modes, 'alternate': args.alternate, 'layouts': args.layouts,
           'sampleSizes': SAMPLE_SIZES,
           'tracks': [{'id': t['id'], 'wav': t['wav']} for t in tracks]}
    (OUT / 'manifest.json').write_text(json.dumps(job, indent=1))
    print(f'{len(tracks)} tracks x {len(args.layouts)} layouts x {len(args.modes)} modes -> {OUT / "manifest.json"}')


if __name__ == '__main__':
    main()
