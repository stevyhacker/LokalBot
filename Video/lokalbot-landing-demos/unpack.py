#!/usr/bin/env python3
"""Turn the workflow's footage into takes compose.py can cut.

    unpack.py <footage-dir> <takes-dir> [take...]

The workflow keeps each take as a near-lossless 30 fps MP4 with its events
(clips/<appearance>-<take>.mp4 and .json). This decodes it back to one PNG per
distinct picture with the time it appeared, as the rig first wrote it.
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def unpack(clip, out):
    meta = json.loads(clip.with_suffix(".json").read_text())
    frames = out / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    for old in frames.glob("*.png"):
        old.unlink()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(clip), "-start_number", "0", str(frames / "%05d.png")], check=True)
    kept, previous = [], None
    for index, path in enumerate(sorted(frames.glob("*.png"))):
        digest = hashlib.md5(path.read_bytes()).hexdigest()
        if digest == previous:
            path.unlink()
            continue
        previous = digest
        kept.append([index, index / 30])
    meta["frames"] = kept
    (out / "take.json").write_text(json.dumps(meta))
    return len(kept)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    footage, takes = Path(sys.argv[1]), Path(sys.argv[2])
    wanted = set(sys.argv[3:])
    for clip in sorted((footage / "clips").glob("*.mp4")):
        appearance, _, take = clip.stem.partition("-")
        if wanted and take not in wanted:
            continue
        count = unpack(clip, takes / appearance / take)
        print(f"{appearance}/{take}: {count} distinct frames")


if __name__ == "__main__":
    main()
