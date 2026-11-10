#!/usr/bin/env python3
"""Taking Turns: the scene table. `python3 build.py` writes index.html, cues.txt and the voice's
timings into compositions/*.html (see ../kit/build_lib.py). Edit the pauses and the sound here."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "kit"))
from build_lib import build  # noqa: E402

SEED = 11
FLOOD = 0.45  # seconds the end card's mint ground takes to open from the amber dot
NOTE = "Mac defaults on a fresh install. Speeds measured on an M4 Max with 48 GB."
SCENES = [
    # The whole film is one world; each line is placed after the one before it, plus its pause.
    # The two longer pauses are where the clock's tape jumps ahead (to 11:40, then to 15:10).
    {"id": "world", "lead": 0.4, "tail": 0.5, "overlap": 0.6,
     "lines": [("c01", SEED, 0.0),
               ("c02", SEED, 0.25),
               ("c03", SEED, 0.25),
               ("c04", SEED, 0.25),
               ("c05", SEED, 0.25),
               ("c06", SEED, 0.35),
               ("c07", SEED, 0.35),
               ("c08", SEED, 0.25)],
     # (name, file, when in the world's time, volume): the picture each sound belongs to.
     # The times repeat the scene's own arithmetic (compositions/world.html): change both together.
     "effects": [
         # the tower comes apart and the files fly to the shelf
         ("tower", "whoosh-short", lambda c: c.W("c02", "the") + 0.35, 0.28),
         # the files' weight lands as one number
         ("weight", "pop", lambda c: c.W("c02", "ten"), 0.22),
         # a copy reaches the desk: Qwen3-ASR, Qwen3.5 4B, Gemma 4 E2B, Qwen3.5 4B again
         ("dock-speech", "pop", lambda c: c.W("c04", "load") + 0.3, 0.22),
         ("dock-think", "click-soft", lambda c: c.W("c05", "language") + 0.45, 0.3),
         ("dock-gemma", "pop", lambda c: c.W("c06", "autocomplete") + 0.45, 0.22),
         ("dock-answer", "click-soft", lambda c: c.W("c07", "goes") + 0.85, 0.3),
         # the tape whips ahead: 10:40 to 11:40, then to 15:10
         ("whip-1", "whoosh-short", lambda c: c.W("c05", "leaves") + 0.45, 0.16),
         ("whip-2", "whoosh-short", lambda c: c.E("c06") + 0.28, 0.16),
         # the last key of the typed sentence
         ("last-key", "key-press", lambda c: c.W("c06", "keystroke") + 0.75, 0.3),
     ],
     # (name, when, seconds, volume): typing under the keys of c06
     # (typing.mp3 gives 1.05 s after its silent start, so the two seconds of keys take two runs)
     "loops": [("keys-1", lambda c: c.W("c06", "because"), 1.05, 0.3),
               ("keys-2", lambda c: c.W("c06", "because") + 1.05, 1.05, 0.3)]},
    # The shared end card (../kit/endcard.html, copied in on every build).
    {"id": "endcard", "kit": True, "lead": FLOOD + 0.62, "tail": 2.4, "lines": [("end", SEED, 0.0)],
     "variables": {"note": NOTE, "flood": FLOOD},
     "effects": [("lockup", "impact-bass-1", FLOOD + 0.68, 0.3)]},
]

if __name__ == "__main__":
    build(HERE, ground="#143a35", scenes=SCENES)
