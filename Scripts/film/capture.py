"""Films the main display for the hackathon film: a full-size JPEG about three
times a second, from when the test drops `.start` in the folder until `.stop`,
then frames.txt for ffmpeg's concat demuxer. It runs beside the test, so taking
3200x2000 screenshots never holds up the app or the test's queries.

On the hosted Mac a screencapture now and then hangs for about ten seconds, so
shots overlap and a stuck one is killed: it costs that shot, not the seconds
after it.

Usage: capture.py <frames folder>
"""
import subprocess
import sys
import time
from pathlib import Path

INTERVAL = 0.33
AT_ONCE = 3
GIVE_UP_AFTER = 3.0
folder = Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)
while not (folder / '.start').exists() and not (folder / '.stop').exists():
    time.sleep(0.1)
frames, running, taken, killed = [], [], 0, 0


def reap():
    global running, killed
    still = []
    for name, at, shot in running:
        if shot.poll() is None and time.time() - at > GIVE_UP_AFTER:
            shot.kill()
            shot.wait()
            killed += 1
        elif shot.poll() is None:
            still.append((name, at, shot))
        elif shot.returncode == 0:
            frames.append((name, at))
    running = still


while not (folder / '.stop').exists():
    started = time.time()
    reap()
    if len(running) < AT_ONCE:
        name = f'{taken:05d}.jpg'
        taken += 1
        running.append((name, started, subprocess.Popen(['/usr/sbin/screencapture', '-x', '-t', 'jpg', str(folder / name)])))
    time.sleep(max(0, INTERVAL - (time.time() - started)))
while running:
    reap()
    time.sleep(0.05)
frames.sort(key=lambda frame: frame[1])
lines = []
for (name, at), (_, following) in zip(frames, frames[1:]):
    lines += [f"file '{name}'", f'duration {following - at:.3f}']
if frames:
    lines += [f"file '{frames[-1][0]}'", 'duration 1.000', f"file '{frames[-1][0]}'"]
(folder / 'frames.txt').write_text('\n'.join(lines) + '\n')
print(f'{len(frames)} frames, {frames[-1][1] - frames[0][1]:.1f} s, {killed} stuck shots killed' if frames else 'no frames')
