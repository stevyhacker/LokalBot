#!/usr/bin/env python3
"""Turn the workflow's footage into takes compose.py can cut.

    unpack.py <footage-dir> <takes-dir> [take...]

The workflow keeps each take as a near-lossless 30 fps MP4 with its events
(clips/<appearance>-<take>.mp4 and .json). This decodes it back to one PNG per
distinct picture with the time it appeared, as the rig first wrote it. A long
take is mostly one picture, so only the frames that change reach the disk.
"""
import json
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from PIL import Image


def unpack(clip, out):
    meta = json.loads(clip.with_suffix(".json").read_text())
    frames = out / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    for old in frames.glob("*.png"):
        old.unlink()
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height",
                            "-of", "csv=p=0", str(clip)], check=True, capture_output=True, text=True)
    width, height = map(int, probe.stdout.strip().split(",")[:2])
    decoder = subprocess.Popen(["ffmpeg", "-v", "error", "-i", str(clip), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                               stdout=subprocess.PIPE)
    size = width * height * 3
    kept, previous, index = [], None, 0
    while True:
        frame = decoder.stdout.read(size)
        if len(frame) < size:
            break
        if frame != previous:
            Image.frombuffer("RGB", (width, height), frame, "raw", "RGB", 0, 1).save(frames / f"{index:05d}.png", compress_level=1)
            kept.append([index, index / 30])
            previous = frame
        index += 1
    if decoder.wait() != 0:
        raise SystemExit(f"could not decode {clip}")
    # Footage from before encode.py kept exact time drifts over a long take.
    if abs(index / 30 - meta["end"]) > 1:
        stretch = meta["end"] / (index / 30)
        kept = [[frame, at * stretch] for frame, at in kept]
    meta["frames"] = kept
    (out / "take.json").write_text(json.dumps(meta))
    return f"{clip.stem}: {len(kept)} distinct frames"


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    footage, takes = Path(sys.argv[1]), Path(sys.argv[2])
    wanted = set(sys.argv[3:])
    jobs = []
    with ProcessPoolExecutor() as pool:
        for clip in sorted((footage / "clips").glob("*.mp4")):
            appearance, _, take = clip.stem.partition("-")
            if not wanted or take in wanted:
                jobs.append(pool.submit(unpack, clip, takes / appearance / take))
        for job in jobs:
            print(job.result())


if __name__ == "__main__":
    main()
