"""Extracts the footage frames the UGC cut uses into footage/ (gitignored).

- footage/hero/NNNN.jpg: the README hero loop from 43d72b9 (Scripts/readme-gif,
  recorded from the real app with the fictional launch-pricing library), at its
  own 20 fps, cropped to the window. NNNN is the loop's frame number (1-based).
  Only the Ask and meeting takes are kept.
- footage/tab/NNNN.jpg: the live autocomplete take light-memory from
  pr-assets/392-autocomplete-demo (TextEdit at 44 pt on a hosted Mac), at 30 fps.
  NNNN is the clip's frame number (1-based). footage/tab/events.json is the
  take's event log (typing, the suggestion appearing, each Tab).

Window pixels are only cropped; nothing is redrawn.
Usage: python3 prepare_footage.py   (run inside the LokalBot checkout)
"""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / 'footage'
HERO = ('43d72b9', 'Assets/hero/lokalbot-demo-light.gif')
TAB = ('origin/pr-assets/392-autocomplete-demo', 'clips/light-memory')
# The hero loop's window sits on a flat #E9EEF3 field under its caption band
# and above its footer; this crop keeps the window and a margin of that field.
HERO_CROP = (40, 128, 1760, 1162)  # x, y, w, h
HERO_FRAMES = [(61, 150), (151, 216)]  # meeting, Ask


def git_blob(rev, path, dest):
    if rev.startswith('origin/'):
        subprocess.run(['git', 'fetch', '-q', 'origin', rev.removeprefix('origin/')], cwd=HERE, check=True)
    with open(dest, 'wb') as f:
        subprocess.run(['git', 'show', f'{rev}:{path}'], cwd=HERE, check=True, stdout=f)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    (OUT / 'hero').mkdir(parents=True)
    (OUT / 'tab').mkdir(parents=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        git_blob(*HERO, tmp / 'hero.gif')
        x, y, w, h = HERO_CROP
        subprocess.run(['ffmpeg', '-v', 'error', '-i', tmp / 'hero.gif', '-vf', f'fps=20,crop={w}:{h}:{x}:{y}',
                        '-q:v', '2', tmp / 'h%04d.jpg'], check=True)
        for a, b in HERO_FRAMES:
            for n in range(a, b + 1):
                shutil.copy(tmp / f'h{n:04d}.jpg', OUT / 'hero' / f'{n:04d}.jpg')
        git_blob(TAB[0], TAB[1] + '.mp4', tmp / 'tab.mp4')
        git_blob(TAB[0], TAB[1] + '.json', OUT / 'tab' / 'events.json')
        events = json.loads((OUT / 'tab' / 'events.json').read_text())['events']
        typed = next(e['t'] for e in events if e.get('name') == 'typed')
        ghost = next(e['t'] for e in events if e['kind'] == 'ghost')
        accepted = next(e['t'] for e in events if e['kind'] == 'accepted')
        # The typing just before "$15" is done, and the suggestion through its accepts.
        spans = [(typed - 5.0, typed + 0.3), (ghost - 0.4, accepted + 2.0)]
        subprocess.run(['ffmpeg', '-v', 'error', '-i', tmp / 'tab.mp4', '-q:v', '2', tmp / 't%04d.jpg'], check=True)
        for a, b in spans:
            for n in range(int(a * 30) + 1, int(b * 30) + 2):
                if (tmp / f't{n:04d}.jpg').exists():
                    shutil.copy(tmp / f't{n:04d}.jpg', OUT / 'tab' / f'{n:04d}.jpg')
    print(len(list((OUT / 'hero').iterdir())), 'hero frames,', len(list((OUT / 'tab').glob('*.jpg'))), 'tab frames')


if __name__ == '__main__':
    main()
