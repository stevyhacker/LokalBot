#!/usr/bin/env python3
"""Encode one rig take into a constant 30 fps MP4 for the edit.

    encode.py <take-dir> <out.mp4>

ScreenCaptureKit delivers a frame only when the window changes; take.json
lists when each PNG arrived. Each frame is held until the next one, so the
video keeps the take's real timing, and its events (keystrokes, the moment the
suggestion appeared, each accept) line up with video time. Near-lossless
H.264 (CRF 12), 4:4:4 so thin text keeps its colour edges; the edit scales it.
"""
import json
import subprocess
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    take, out = Path(sys.argv[1]), Path(sys.argv[2])
    meta = json.loads((take / "take.json").read_text())
    frames = meta["frames"]
    if not frames:
        raise SystemExit(f"{take}: no frames")
    listing = take / "frames.ffconcat"
    lines = ["ffconcat version 1.0"]
    for i, (index, at) in enumerate(frames):
        until = frames[i + 1][1] if i + 1 < len(frames) else max(meta["end"], at + 1 / 30)
        lines.append(f"file 'frames/{int(index):05d}.png'")
        lines.append(f"duration {max(until - at, 0.001):.4f}")
    # The concat demuxer needs the last file twice for its duration to count.
    lines.append(f"file 'frames/{int(frames[-1][0]):05d}.png'")
    listing.write_text("\n".join(lines) + "\n")
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
        "-vf", "fps=30,pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-preset", "slow", "-crf", "12",
        "-pix_fmt", "yuv444p", "-movflags", "+faststart", str(out),
    ], check=True)
    events = out.with_suffix(".json")
    events.write_text(json.dumps({k: meta[k] for k in ("rect", "scale", "background", "end", "events")}, indent=2))
    print(f"{out} ({len(frames)} frames, {meta['end']:.1f}s)")


if __name__ == "__main__":
    main()
