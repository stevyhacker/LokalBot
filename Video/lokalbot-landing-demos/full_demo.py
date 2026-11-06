#!/usr/bin/env python3
"""Cuts the home page's one full demo from the hero clips in web/assets/demos.

The hero plays a single film of under 45 seconds, and its tabs are chapters in it. This
joins the six hero clips with short fades, trims each, and speeds up typing and waits.
Nothing inside a frame changes. Each scene runs the same length in every cut, so the
chapter times it prints apply to all four files; copy them to `data-start` on the demo
tabs in web/index.html.

    python3 Video/lokalbot-landing-demos/full_demo.py web/assets/demos

Writes full-<cut>-<appearance>.mp4 next to the clips. Needs ffmpeg and ffprobe.
"""
import pathlib
import subprocess
import sys

FADE = 0.3
FPS = 60

# Each scene is a list of (start, end, seconds on screen), in the clip's seconds. A
# negative time counts back from the clip's end, since the same moment falls a little
# earlier or later in each cut.
SCENES = [
    ("meetings", [(1.0, 4.4, 1.8), (4.4, -0.3, 9.6)]),
    ("search", [(0.8, -0.8, 5.6)]),
    ("autocomplete", [(0.0, -4.6, 3.8), (-4.6, -0.2, 4.4)]),
    ("dictation", [(0.3, -2.0, 3.0), (-2.0, 0.0, 2.0)]),
    ("ask", [(0.3, -1.9, 8.3)]),
    ("agents", [(3.2, -0.8, 6.2)]),
]


def seconds(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True,
    )
    return float(out.stdout)


def scene_lengths():
    return [sum(part[2] for part in parts) for _, parts in SCENES]


def chapters():
    """When each scene has fully faded in, which is also where a tab seeks to."""
    times, offset = [0.0], 0.0
    for length in scene_lengths()[:-1]:
        offset += length - FADE
        times.append(round(offset + FADE, 2))
    return times


def graph(demos, cut, appearance):
    parts, inputs = [], []
    for index, (clip, segments) in enumerate(SCENES):
        path = demos / f"{clip}-{cut}-{appearance}.mp4"
        inputs += ["-i", str(path)]
        total = seconds(path)
        labels = []
        for number, (start, end, shown) in enumerate(segments):
            start = start if start >= 0 else total + start
            end = end if end > 0 else total + end
            label = f"s{index}p{number}"
            parts.append(
                f"[{index}:v]trim={start:.3f}:{end:.3f},setpts=(PTS-STARTPTS)*{shown / (end - start):.5f}[{label}]"
            )
            labels.append(f"[{label}]")
        length = sum(segment[2] for segment in segments)
        parts.append(
            f"{''.join(labels)}concat=n={len(labels)}:v=1,fps={FPS},format=yuv420p,"
            f"tpad=stop_mode=clone:stop_duration=1,trim=duration={length:.3f},setpts=PTS-STARTPTS,settb=1/{FPS * 100}[v{index}]"
        )
    joined, offset = "[v0]", 0.0
    for index, length in enumerate(scene_lengths()[:-1], start=1):
        offset += length - FADE
        parts.append(f"{joined}[v{index}]xfade=transition=fade:duration={FADE}:offset={offset:.3f}[x{index}]")
        joined = f"[x{index}]"
    return inputs, ";".join(parts), joined


def main():
    demos = pathlib.Path(sys.argv[1])
    keyframes = ",".join(str(t) for t in chapters())
    for cut in ("wide", "tall"):
        for appearance in ("light", "dark"):
            inputs, filters, last = graph(demos, cut, appearance)
            out = demos / f"full-{cut}-{appearance}.mp4"
            subprocess.run(
                ["ffmpeg", "-nostdin", "-v", "error", "-y", *inputs, "-filter_complex", filters, "-map", last, "-an",
                 "-c:v", "libx264", "-preset", "slow", "-crf", "22", "-pix_fmt", "yuv420p", "-threads", "4",
                 "-force_key_frames", keyframes, "-movflags", "+faststart", str(out)],
                check=True,
            )
            print(f"{out.name}: {seconds(out):.2f}s, {out.stat().st_size / 1e6:.1f} MB")
    print("chapters:", keyframes, "total:", round(sum(scene_lengths()) - FADE * (len(SCENES) - 1), 2))


if __name__ == "__main__":
    main()
