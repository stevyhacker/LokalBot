#!/usr/bin/env python3
"""Cut the agent handoff film into an MP4 and a GIF.

    edit.py <film-dir> <out-dir>

Reads the frames FilmDirector wrote (`frames/*.png`, `frames.jsonl`) and
plays each scene for a set length: waiting for transcription and the agents
is sped up, the moment the summary lands and the finished result play near
real time. A caption names what each scene shows. Needs ffmpeg.
"""
import json
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

FPS = 10
# Seconds on screen per scene; None keeps the scene's real length.
SCENES = [
    ("meeting", 14, "The call ends. LokalBot transcribes it and writes the notes."),
    ("handed-off", None, "Each action you took on becomes its own Agent Mode task."),
    ("agents", 30, "Agents start on their own, up to four at once."),
    ("done", None, "Finished work waits in each task for your review."),
]
FONTS = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
         "/System/Library/Fonts/Supplemental/Arial.ttf"]


def sample(frames, seconds):
    """Frames at FPS covering the scene's time span in `seconds`."""
    if not frames:
        return []
    start, end = frames[0]["t"], frames[-1]["t"]
    length = max(end - start, 0.5)
    count = max(1, round((seconds if seconds else length) * FPS))
    picked, index = [], 0
    for n in range(count):
        t = start + length * n / count
        while index + 1 < len(frames) and frames[index + 1]["t"] <= t:
            index += 1
        picked.append(frames[index]["frame"])
    return picked


def png_size(path):
    with open(path, "rb") as f:
        return struct.unpack(">II", f.read(24)[16:24])


def escape(text):
    return text.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’")


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    film, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(line) for line in (film / "frames.jsonl").read_text().splitlines() if line.strip()]
    timeline, captions, stills = [], [], {}
    for scene, seconds, caption in SCENES:
        picked = sample([row for row in rows if row["scene"] == scene], seconds)
        if not picked:
            continue
        begin = len(timeline) / FPS
        timeline += picked
        captions.append((begin, len(timeline) / FPS, caption))
        stills[scene] = picked[-1]
    if not timeline:
        raise SystemExit("no frames to cut")
    listing = out / "frames.txt"
    with open(listing, "w") as f:
        for name in timeline:
            f.write(f"file '{(film / 'frames' / name).resolve()}'\nduration {1 / FPS}\n")
        f.write(f"file '{(film / 'frames' / timeline[-1]).resolve()}'\n")

    # Every frame at the size most of them have, in case the window changed.
    sizes = [png_size(film / "frames" / name) for name in timeline[::10]]
    width, height = max(set(sizes), key=sizes.count)
    font = next((path for path in FONTS if os.path.exists(path)), None)
    filters = [f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
               f"pad={width}:{height + 64}:(ow-iw)/2:0:color=white"]
    if font:
        for begin, end, caption in captions:
            filters.append(
                f"drawtext=fontfile='{font}':text='{escape(caption)}':fontsize=26:fontcolor=0x1d1d1f:"
                f"x=(w-text_w)/2:y=h-46:enable='between(t,{begin:.2f},{end:.2f})'")
    filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p")
    mp4 = out / "agent-handoff.mp4"
    encode = ["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
              "-r", str(FPS), "-c:v", "libx264", "-crf", "22", "-preset", "slow", "-movflags", "+faststart"]
    try:
        subprocess.run(encode + ["-vf", ",".join(filters), str(mp4)], check=True)
    except subprocess.CalledProcessError:
        # A build without drawtext still gets the film, uncaptioned.
        subprocess.run(encode + ["-vf", ",".join([filters[0], filters[-1]]), str(mp4)], check=True)
    gif = out / "agent-handoff.gif"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(mp4), "-vf",
                    "fps=8,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];"
                    "[b][p]paletteuse=dither=bayer:bayer_scale=4", str(gif)], check=True)
    for scene, name in stills.items():
        shutil.copy(film / "frames" / name, out / f"{scene}.png")
    listing.unlink()
    print(f"{mp4} ({len(timeline) / FPS:.0f} s), {gif}")


if __name__ == "__main__":
    main()
