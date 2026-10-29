"""Extracts the footage the UGC cut uses into footage/ (gitignored).

The takes come from the UGC demo footage workflow (.github/workflows/ugc-demo.yml,
Video/lokalbot-ugc/film): the real app filmed at 2x on a hosted Mac, without the
system pointer, with the pointer's path logged. They are on the orphan branch
pr-assets/ugc-demo-footage, or in a local copy of it (--from <dir>).

- footage/<take>/NNNN.jpg: the take at 30 fps; frame NNNN (1-based) shows take
  time (NNNN - 1) / 30.
- footage/<take>/take.json: the clip's log (window rect and scale, events,
  pointer path in window points), its size in pixels and frame count, and
  `changes`: every frame where the window's pixels changed from the frame
  before, with how many and where, so the edit knows when the app is busy and
  when it sits still, and the camera can follow text as it is typed.

Window pixels are only scaled and moved; nothing in them is redrawn.
Usage: python3 prepare_footage.py [--from <dir>]   (inside the LokalBot checkout)
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / 'footage'
BRANCH = 'pr-assets/ugc-demo-footage'
TAKES = ['flow', 'follow-up']


class Source:
    def __init__(self, local):
        self.local = Path(local) if local else None
        if not self.local:
            subprocess.run(['git', 'fetch', '-q', 'origin', BRANCH], cwd=HERE, check=True)

    def has(self, path):
        if self.local:
            return (self.local / path).exists()
        return subprocess.run(['git', 'cat-file', '-e', f'origin/{BRANCH}:{path}'], cwd=HERE,
                              capture_output=True).returncode == 0

    def copy(self, path, dest):
        if self.local:
            shutil.copy(self.local / path, dest)
            return
        with open(dest, 'wb') as f:
            subprocess.run(['git', 'show', f'origin/{BRANCH}:{path}'], cwd=HERE, check=True, stdout=f)


def frames(video, dest):
    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(video), '-q:v', '2', str(dest / '%04d.jpg')], check=True)
    return sorted(dest.glob('*.jpg'))


def changes(video, size, step=4):
    """[[t, n, x, y, x0, y0, x1, y1]] for each frame that differs from the one
    before: t in take seconds, n the changed pixels at 1/step scale, then the
    middle (median) and the box of the change in footage pixels."""
    w, h = size[0] // step, size[1] // step
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(video), '-vf', f'scale={w}:{h}', '-f', 'rawvideo',
                          '-pix_fmt', 'gray', '-'], check=True, capture_output=True).stdout
    video = np.frombuffer(raw, np.uint8).reshape(-1, h, w).astype(np.int16)
    out = []
    for i in range(1, len(video)):
        ys, xs = np.nonzero(np.abs(video[i] - video[i - 1]) > 12)
        if len(xs):
            out.append([round(i / 30, 3), int(len(xs))] + [float(v * step) for v in (
                np.median(xs), np.median(ys), xs.min(), ys.min(), xs.max(), ys.max())])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='local', default='')
    args = ap.parse_args()
    src = Source(args.local)
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for take in TAKES:
            if not src.has(f'clips/{take}.mp4'):
                print(f'{take}: not filmed')
                continue
            dest = OUT / take
            dest.mkdir()
            src.copy(f'clips/{take}.mp4', tmp / f'{take}.mp4')
            src.copy(f'clips/{take}.json', tmp / f'{take}.json')
            meta = json.loads((tmp / f'{take}.json').read_text())
            paths = frames(tmp / f'{take}.mp4', dest)
            probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                    'stream=width,height', '-of', 'csv=p=0', str(tmp / f'{take}.mp4')],
                                   check=True, capture_output=True, text=True).stdout.strip().split(',')
            meta['size'] = [int(probe[0]), int(probe[1])]
            meta['count'] = len(paths)
            meta['changes'] = changes(tmp / f'{take}.mp4', meta['size'])
            (dest / 'take.json').write_text(json.dumps(meta, indent=1))
            print(f"{take}: {len(paths)} frames, {meta['size'][0]}x{meta['size'][1]}, scale {meta.get('scale')}")


if __name__ == '__main__':
    main()
