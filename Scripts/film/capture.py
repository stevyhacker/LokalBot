"""Films the main display for the hackathon film: a full-size JPEG about four
times a second, from when the test drops `.start` in the folder until `.stop`,
then frames.txt for ffmpeg's concat demuxer. It runs beside the test, so taking
3200x2000 screenshots never holds up the app or the test's queries.

Usage: capture.py <frames folder>
"""
import subprocess
import sys
import time
from pathlib import Path

INTERVAL = 0.25
folder = Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)
while not (folder / '.start').exists() and not (folder / '.stop').exists():
    time.sleep(0.1)
frames = []
while not (folder / '.stop').exists():
    started = time.time()
    name = f'{len(frames):05d}.jpg'
    if subprocess.run(['/usr/sbin/screencapture', '-x', '-t', 'jpg', str(folder / name)]).returncode == 0:
        frames.append((name, started))
    time.sleep(max(0, INTERVAL - (time.time() - started)))
lines = []
for (name, at), (_, following) in zip(frames, frames[1:]):
    lines += [f"file '{name}'", f'duration {following - at:.3f}']
if frames:
    lines += [f"file '{frames[-1][0]}'", 'duration 1.000', f"file '{frames[-1][0]}'"]
(folder / 'frames.txt').write_text('\n'.join(lines) + '\n')
print(f'{len(frames)} frames, {frames[-1][1] - frames[0][1]:.1f} s' if frames else 'no frames')
