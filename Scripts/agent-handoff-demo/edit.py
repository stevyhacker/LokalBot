#!/usr/bin/env python3
"""Cut the agent handoff film into an MP4 and a GIF.

    edit.py <film-dir> <out-dir>

Reads the window frames record.py took (`frames/*.png`, `frames.jsonl`) and
the scenes FilmDirector logged (`scenes.jsonl`), and plays each scene for a
set length: the agents' work is sped up, the rest plays in real time. Each
frame sits on a light backdrop with the scene's caption under it. Needs
ffmpeg and Pillow.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FPS = 10
MAX_WIDTH = 1280
PAD = 24
BAR = 72
BACKDROP = "#ececef"
INK = "#1d1d1f"
# Seconds on screen per scene; None keeps the scene's real length.
SCENES = [
    ("meeting", None, "The call ends. LokalBot transcribes it and writes the notes."),
    ("handed-off", None, "Each action you took on becomes its own agent task."),
    ("agents", 36, "The agents start on their own and work side by side."),
    ("done", None, "Each task ends with a report and the files it wrote, ready for review."),
]
FONTS = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def by_scene(frames, scenes):
    """Each frame under the scene that had begun when it was taken."""
    grouped = {}
    for row in frames:
        begun = [scene["scene"] for scene in scenes if scene["at"] <= row["at"]]
        if begun:
            grouped.setdefault(begun[-1], []).append(row)
    return grouped


def sample(frames, seconds):
    """Frame names at FPS covering the scene in `seconds`, or in its real length."""
    start, end = frames[0]["at"], frames[-1]["at"]
    length = max(end - start, 1 / FPS)
    count = max(1, round((seconds or length) * FPS))
    picked, index = [], 0
    for n in range(count):
        t = start + length * n / count
        while index + 1 < len(frames) and frames[index + 1]["at"] <= t:
            index += 1
        picked.append(frames[index]["frame"])
    return picked


def caption_font(size):
    for path in FONTS:
        try:
            face = ImageFont.truetype(path, size)
        except OSError:
            continue
        try:
            face.set_variation_by_name("Semibold")
        except Exception:  # not a variable font, or no such instance
            pass
        return face
    return ImageFont.load_default(size)


def compose(source, size, caption, face, dest):
    width, height = size
    canvas = Image.new("RGB", (width + 2 * PAD, height + PAD + BAR), BACKDROP)
    with Image.open(source) as frame:
        frame = frame.convert("RGBA")
        if frame.size != size:
            frame.thumbnail(size, Image.LANCZOS)
        canvas.paste(frame, (PAD + (width - frame.width) // 2, PAD + (height - frame.height) // 2), frame)
    ImageDraw.Draw(canvas).text((canvas.width / 2, PAD + height + BAR / 2), caption,
                                font=face, fill=INK, anchor="mm")
    canvas.save(dest)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    film, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    grouped = by_scene(read_rows(film / "frames.jsonl"), read_rows(film / "scenes.jsonl"))
    timeline, stills = [], {}
    for scene, seconds, caption in SCENES:
        if scene in grouped:
            picked = sample(grouped[scene], seconds)
            timeline += [(name, caption) for name in picked]
            stills[scene] = picked[-1]
    if not timeline:
        raise SystemExit("no frames to cut")

    # Every frame at the size most of them have, no wider than MAX_WIDTH,
    # with even sides for H.264.
    sizes = [Image.open(film / "frames" / name).size for name, _ in timeline[::10]]
    width, height = max(set(sizes), key=sizes.count)
    scale = min(1.0, MAX_WIDTH / width)
    size = (round(width * scale) // 2 * 2, round(height * scale) // 2 * 2)
    face = caption_font(26)
    cut = out / "cut"
    shutil.rmtree(cut, ignore_errors=True)
    (cut / "sequence").mkdir(parents=True)
    composed = {}
    for number, (name, caption) in enumerate(timeline):
        key = (name, caption)
        if key not in composed:
            composed[key] = cut / f"{len(composed):05d}.png"
            compose(film / "frames" / name, size, caption, face, composed[key])
        os.link(composed[key], cut / "sequence" / f"{number:05d}.png")

    mp4 = out / "agent-handoff.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS),
                    "-i", str(cut / "sequence" / "%05d.png"), "-c:v", "libx264", "-crf", "20",
                    "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4)], check=True)
    gif = out / "agent-handoff.gif"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(mp4), "-vf",
                    "fps=8,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];"
                    "[b][p]paletteuse=dither=bayer:bayer_scale=4", str(gif)], check=True)
    for scene, name in stills.items():
        shutil.copy(film / "frames" / name, out / f"{scene}.png")
    shutil.rmtree(cut)
    print(f"{mp4} ({len(timeline) / FPS:.0f} s), {gif}")


if __name__ == "__main__":
    main()
