#!/usr/bin/env python3
"""Record LokalBot's main window while the film runs.

    record.py <film-dir>

Waits for the `window.json` FilmDirector keeps current, then captures that
window with screencapture twice a second into `<film-dir>/frames`, listing
each frame and when it was taken (seconds since 1970) in `frames.jsonl`,
until FilmDirector's `done` or film.sh's `stop` appears there. The session
must be allowed to record the screen, as hosted runners are. The first frame
is also taken as a plain screen rectangle (`rect-probe.png`) to check the
window capture against.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

INTERVAL = 0.5


def capture(window, path):
    subprocess.run(["screencapture", "-x", "-o", f"-l{window['id']}", str(path)], capture_output=True)
    if not path.exists():
        rect = f"{window['x']},{window['y']},{window['w']},{window['h']}"
        subprocess.run(["screencapture", "-x", f"-R{rect}", str(path)], capture_output=True)
    return path.exists()


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    film = Path(sys.argv[1])
    frames = film / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    number = 0
    with open(film / "frames.jsonl", "a") as listing:
        while not (film / "done").exists() and not (film / "stop").exists():
            began = time.time()
            try:
                window = json.loads((film / "window.json").read_text())
            except (OSError, ValueError):
                time.sleep(INTERVAL)
                continue
            if number == 0:
                rect = f"{window['x']},{window['y']},{window['w']},{window['h']}"
                subprocess.run(["screencapture", "-x", f"-R{rect}", str(film / "rect-probe.png")],
                               capture_output=True)
            name = f"{number + 1:05d}.png"
            if capture(window, frames / name):
                number += 1
                listing.write(json.dumps({"frame": name, "at": round(began, 2)}) + "\n")
                listing.flush()
            time.sleep(max(0.0, INTERVAL - (time.time() - began)))
    print(f"recorded {number} frames")


if __name__ == "__main__":
    main()
