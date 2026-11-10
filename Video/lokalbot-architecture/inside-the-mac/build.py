#!/usr/bin/env python3
"""Inside the Mac: the scene table. `python3 build.py` writes index.html, cues.txt and the voice's
timings into compositions/*.html (see ../kit/build_lib.py). Edit the pauses and the sound here."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "kit"))
from build_lib import build  # noqa: E402

SEED = 11
FLOOD = 0.45  # seconds the end card's mint ground takes to open from the amber dot
# This film shows no speeds, so its small print says what the screen is instead.
NOTE = "Mac defaults on a fresh install. The app on the screen is real, on fictional data."
SCENES = [
    # The whole film is one world; each line is placed after the one before it, plus its pause.
    {"id": "world", "lead": 0.4, "tail": 1.0, "overlap": 0.6,
     "lines": [("b01", SEED, 0.0),
               ("b02", SEED, 0.2),
               ("b03", SEED, 0.25),
               ("b05", SEED, 0.2),
               ("b06", SEED, 0.2),
               ("b07", SEED, 0.2),
               ("b08", SEED, 0.2),
               ("b09", SEED, 0.2)],
     # (name, file, when in the world's time, volume): the picture each sound belongs to.
     "effects": [
         ("open", "whoosh-short", lambda c: c.W("b01", "open"), 0.25),
         # One soft landing for each model file as it seats.
         ("file-1", "pop", lambda c: c.W("b03", "speech"), 0.22),
         ("file-2", "click-soft", lambda c: c.W("b03", "speakers"), 0.25),
         ("file-3", "pop", lambda c: c.W("b03", "notes"), 0.22),
         ("file-4", "click-soft", lambda c: c.W("b03", "sentences"), 0.25),
         ("file-5", "pop", lambda c: c.W("b03", "meaning"), 0.22),
         ("total", "pop", lambda c: c.W("b05", "nine") + 0.02, 0.3),
         ("close", "whoosh", lambda c: c.W("b09", "close") + 0.1, 0.25),
     ],
     # (name, when, seconds, volume): keys under the folder tree as it is typed.
     "loops": [
         ("tree-1", lambda c: c.L("b07") + 0.2, 0.45, 0.3),
         ("tree-2", lambda c: c.W("b07", "lands") - 0.42, 0.4, 0.3),
         ("tree-3", lambda c: c.W("b07", "folder") + 0.08, 0.84, 0.3),
     ]},
    # The shared end card (../kit/endcard.html, copied in on every build).
    {"id": "endcard", "kit": True, "lead": FLOOD + 0.62, "tail": 2.4, "lines": [("end", SEED, 0.0)],
     "variables": {"note": NOTE, "flood": FLOOD},
     "effects": [("lockup", "impact-bass-1", FLOOD + 0.68, 0.3)]},
]

if __name__ == "__main__":
    build(HERE, ground="#f1faf7", scenes=SCENES)
