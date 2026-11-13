#!/usr/bin/env python3
"""Cuts the root README's media from the home page's clips in Website/public/assets/demos.

A README can't autoplay video, so these are the same footage as GIFs: one hero that
walks through the six hero clips under a caption band, a loop for each feature with a
section of its own, and two stills. Each comes in light and dark.

    LANDING_FONT=<a copy of SF, off macOS> \
        python3 Video/lokalbot-landing-demos/readme_gifs.py <demos dir> <out dir> [name ...]

Needs ffmpeg, gifsicle and Pillow. Copy lokalbot-demo-*.gif over Assets/hero/ and the
rest over Assets/readme/, then update the tables in Assets/hero/README.md.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

APPEARANCES = {
    "light": {"band": "#f4f8f7", "text": "#10201c", "dot": "#c4d2ce", "accent": "#0f8a72"},
    "dark": {"band": "#141618", "text": "#f2f5f4", "dot": "#3c4245", "accent": "#35d0ae"},
}

# Each segment is (start, end, speed) in the clip's seconds. Nothing inside a frame changes.
DICTATION = [(0.3, 6.6, 2), (6.6, 8.4, 1)]
ASK = [(0.3, 9.6, 1)]
AGENTS = [(2.8, 10.2, 1)]
HERO = [
    ("meetings", "Notes from every call, with no bot", [(1.2, 14.0, 1)]),
    ("search", "One search for everything you saw and heard", [(0.4, 6.4, 1)]),
    ("autocomplete", "Autocomplete that knows what your meetings decided", [(0.0, 6.4, 1.6), (6.4, 10.6, 1)]),
    ("dictation", "Say what you need, and it writes at your cursor", DICTATION),
    ("ask", "Ask your own work, then check the source", ASK),
    ("agents", "Your AI agents can search it too", AGENTS),
]
HERO_WIDTH, HERO_BAND, HERO_FPS, HERO_LOSSY = 1120, 84, 12, 60

FEATURES = {
    "today": [(0.0, 11.5, 1)],
    "files": [(0.0, 12.9, 1)],
    "timeline": [(0.0, 10.8, 1)],
    "people": [(0.0, 10.8, 1)],
    "projects": [(0.0, 10.0, 1)],
    "ask": ASK,
    "dictation": DICTATION,
    "agents": AGENTS,
}
FEATURE_WIDTH, FEATURE_FPS, FEATURE_LOSSY = 960, 12, 60

# For the sections whose clip already opens the README: the second of a frame, and how
# much of its height to keep (the meeting frame ends on a half-cut row under the pointer).
STILLS = {"meetings": (10.5, 0.94), "search": (6.2, 1.0)}

CLEAN = "hqdn3d=1.5:1.5:4:4"


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def ffmpeg(*args):
    run("ffmpeg", "-nostdin", "-v", "error", "-y", *args)


def font(size, weight):
    f = ImageFont.truetype(os.environ.get("LANDING_FONT", "/System/Library/Fonts/SFNS.ttf"), size)
    try:
        f.set_variation_by_name(weight)
    except (OSError, ValueError):
        pass  # A static font has no named weights.
    return f


def band(path, caption, step, steps, colors):
    """The strip above a scene: what this scene shows, and how far through the loop it is."""
    scale = 4
    w, h = HERO_WIDTH * scale, HERO_BAND * scale
    img = Image.new("RGB", (w, h), colors["band"])
    draw = ImageDraw.Draw(img)
    draw.text((40 * scale, h / 2), caption, font=font(34 * scale, "Semibold"), fill=colors["text"], anchor="lm")
    r, gap = 7 * scale, 26 * scale
    for i in range(steps):
        x = w - 40 * scale - (steps - 1 - i) * gap
        draw.ellipse((x - r, h / 2 - r, x + r, h / 2 + r), fill=colors["accent"] if i == step else colors["dot"])
    img.resize((HERO_WIDTH, HERO_BAND), Image.LANCZOS).save(path)


def timed(segments, width, fps):
    """A filter graph that plays the segments of [0:v] in order, scaled, at a constant rate."""
    parts, labels = [], []
    for i, (start, end, speed) in enumerate(segments):
        parts.append(f"[0:v]trim={start}:{end},setpts=(PTS-STARTPTS)/{speed}[s{i}]")
        labels.append(f"[s{i}]")
    parts.append(f"{''.join(labels)}concat=n={len(labels)}:v=1,fps={fps},scale={width}:-2:flags=lanczos,{CLEAN}[v]")
    return ";".join(parts)


def to_gif(source, out, lossy):
    # Every frame stays. Dropping duplicates would shorten the last hold, because a GIF
    # has no later frame to carry the time, and the loop would restart mid-read.
    with tempfile.TemporaryDirectory() as tmp:
        palette = pathlib.Path(tmp) / "palette.png"
        raw = pathlib.Path(tmp) / "raw.gif"
        ffmpeg("-i", source, "-vf", "palettegen=max_colors=256:stats_mode=full", palette)
        ffmpeg("-i", source, "-i", palette, "-lavfi", "paletteuse=dither=none:diff_mode=rectangle", "-loop", "0", raw)
        run("gifsicle", "-O3", f"--lossy={lossy}", "--no-comments", "--no-names", raw, "-o", out)


def hero(demos, out, appearance):
    colors = APPEARANCES[appearance]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        scenes = []
        for step, (clip, caption, segments) in enumerate(HERO):
            strip, scene = tmp / f"band{step}.png", tmp / f"scene{step}.mkv"
            band(strip, caption, step, len(HERO), colors)
            graph = (
                timed(segments, HERO_WIDTH, HERO_FPS)
                + f";[v]pad={HERO_WIDTH}:ih+{HERO_BAND}:0:{HERO_BAND}[p];[p][1:v]overlay=0:0,format=yuv444p[o]"
            )
            ffmpeg("-i", demos / f"{clip}-wide-{appearance}.mp4", "-i", strip,
                   "-filter_complex", graph, "-map", "[o]", "-c:v", "ffv1", scene)
            scenes.append(scene)
        listing = tmp / "scenes.txt"
        listing.write_text("".join(f"file '{s}'\n" for s in scenes))
        joined = tmp / "hero.mkv"
        ffmpeg("-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", joined)
        to_gif(joined, out / f"lokalbot-demo-{appearance}.gif", HERO_LOSSY)


def feature(demos, out, clip, appearance):
    with tempfile.TemporaryDirectory() as tmp:
        cut = pathlib.Path(tmp) / "cut.mkv"
        ffmpeg("-i", demos / f"{clip}-wide-{appearance}.mp4", "-filter_complex",
               timed(FEATURES[clip], FEATURE_WIDTH, FEATURE_FPS), "-map", "[v]", "-c:v", "ffv1", cut)
        to_gif(cut, out / f"{clip}-{appearance}.gif", FEATURE_LOSSY)


def still(demos, out, clip, appearance):
    second, keep = STILLS[clip]
    ffmpeg("-ss", second, "-i", demos / f"{clip}-wide-{appearance}.mp4", "-frames:v", "1",
           "-vf", f"crop=iw:trunc(ih*{keep}/2)*2:0:0,scale=1600:-2:flags=lanczos", out / f"{clip}-{appearance}.png")


def main():
    demos, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    names = sys.argv[3:] or ["hero", *FEATURES, *STILLS]
    out.mkdir(parents=True, exist_ok=True)
    for name in names:
        for appearance in APPEARANCES:
            if name == "hero":
                hero(demos, out, appearance)
            elif name in STILLS:
                still(demos, out, name, appearance)
            else:
                feature(demos, out, name, appearance)


if __name__ == "__main__":
    main()
