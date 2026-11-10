#!/usr/bin/env python3
"""One Sentence: the scene table. `python3 build.py` writes index.html, cues.txt and the voice's
timings into compositions/*.html (see ../kit/build_lib.py). Edit the pauses and the sound here."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "kit"))
from build_lib import build  # noqa: E402

SEED = 11
FLOOD = 0  # the film is already on mint when the end card starts, so its ground just takes over
NOTE = "Mac defaults on a fresh install. Speeds measured on an M4 Max with 48 GB."
SCENES = [
    # The whole film is one world; each line is placed after the one before it, plus its pause.
    {"id": "world", "lead": 0.4, "tail": 0.8, "overlap": 0.6,
     "lines": [("a01", SEED, 0.0),
               ("a02", SEED, 0.35),
               ("a03", SEED, 0.35),
               ("a04", SEED, 0.35),
               ("a05", SEED, 0.35),
               ("a06", SEED, 0.35),
               ("a07", SEED, 0.35),
               ("a08", SEED, 0.35),
               ("a09", SEED, 0.35)],
     # (name, file, when in the world's time, volume): the picture each sound belongs to.
     "effects": [("tab", "key-press", lambda c: c.W("a07", "sentence"), 0.35),
                 ("switch", "click-soft", lambda c: c.W("a08", "allow"), 0.5),
                 ("pull-back", "whoosh", lambda c: c.L("a09") + 0.25, 0.28),
                 ("total", "pop", lambda c: c.W("a09", "ten"), 0.25)],
     # (name, when, seconds, volume): key ticks while text is typed on screen.
     "loops": [("type-caption", lambda c: c.W("a01", "says") + 0.04, 1.05, 0.2),
               ("type-document", lambda c: c.W("a07", "typing") - 0.4, 0.85, 0.35),
               ("type-agent", lambda c: c.W("a08", "agent") - 0.35, 0.8, 0.3)]},
    # The shared end card (../kit/endcard.html, copied in on every build).
    {"id": "endcard", "kit": True, "lead": FLOOD + 0.62, "tail": 2.4, "lines": [("end", SEED, 0.0)],
     "variables": {"note": NOTE, "flood": FLOOD},
     "effects": [("lockup", "impact-bass-1", FLOOD + 0.68, 0.3)]},
]

if __name__ == "__main__":
    build(HERE, ground="#0e151d", scenes=SCENES)
