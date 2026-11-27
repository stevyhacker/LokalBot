#!/usr/bin/env python3
"""Taking Turns: the scene table. Writes index.html, cues.txt and voice timings into compositions/*.html.

    python3 build.py
    python3 build.py --format 4:5
    python3 build.py --format 9:16
"""
import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEED = 11
FLOOD = 0.45
NOTE = "v0.14.0 Mac defaults (Apache-2.0 fine-tunes). Speeds measured on an M4 Max with 48 GB."
SCENES = [
    {
        "id": "world",
        "lead": 0.4,
        "tail": 0.5,
        "overlap": 0.6,
        "lines": [
            ("c01", SEED, 0.0),
            ("c02", SEED, 0.25),
            ("c03", SEED, 0.25),
            ("c04", SEED, 0.25),
            ("c05", SEED, 0.25),
            ("c06", SEED, 0.35),
            ("c07", SEED, 0.35),
            ("c08", SEED, 0.25),
        ],
        "effects": [
            ("tower", "whoosh-short", lambda c: c.W("c02", "the") + 0.35, 0.28),
            ("weight", "pop", lambda c: c.W("c02", "ten"), 0.22),
            ("dock-speech", "pop", lambda c: c.W("c04", "load") + 0.3, 0.22),
            ("dock-think", "click-soft", lambda c: c.W("c05", "language") + 0.45, 0.3),
            ("dock-gemma", "pop", lambda c: c.W("c06", "autocomplete") + 0.45, 0.22),
            ("dock-answer", "click-soft", lambda c: c.W("c07", "goes") + 0.85, 0.3),
            ("whip-1", "whoosh-short", lambda c: c.W("c05", "leaves") + 0.45, 0.16),
            ("whip-2", "whoosh-short", lambda c: c.E("c06") + 0.28, 0.16),
            ("last-key", "key-press", lambda c: c.W("c06", "keystroke") + 0.75, 0.3),
        ],
        "loops": [
            ("keys-1", lambda c: c.W("c06", "because"), 1.05, 0.3),
            ("keys-2", lambda c: c.W("c06", "because") + 1.05, 1.05, 0.3),
        ],
    },
    {
        "id": "endcard",
        "kit": True,
        "lead": FLOOD + 0.62,
        "tail": 2.4,
        "lines": [("end", SEED, 0.0)],
        "variables": {"note": NOTE, "flood": FLOOD},
        "effects": [("lockup", "impact-bass-1", FLOOD + 0.68, 0.3)],
    },
]


def main():
    parser = argparse.ArgumentParser(description="Build Taking Turns HyperFrames composition.")
    parser.add_argument("--format", choices=["16:9", "4:5", "9:16"], default="16:9")
    parser.add_argument("--captions", dest="captions", action="store_true", default=None)
    parser.add_argument("--no-captions", dest="captions", action="store_false")
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    sys.path.insert(0, str(HERE.parent / "kit"))
    from build_lib import build

    build(
        HERE,
        ground="#143a35",
        scenes=SCENES,
        fmt=args.format,
        with_captions=args.captions,
        social_badge="5 LOCAL MODELS · UNDER 10 GB",
        social_headline="Five local AI models, <b>taking turns</b> on one Mac",
        out_path=args.out,
    )


if __name__ == "__main__":
    main()
