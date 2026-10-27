#!/usr/bin/env python3
"""Compose the 30 s README hero reel into PNG frames.

    python3 compose.py <takes dir> <legacy frames dir> <out dir>

<takes dir> holds the FilmDirector takes (t-*.mov + t-*.events.json).
<legacy frames dir> holds the previous hero GIF (Assets/hero/lokalbot-demo-light.gif
at 43d72b9, built by Scripts/readme-gif) decoded at 20 fps; its live autocomplete
and dictation scenes are reused, cropped below their old caption and scaled to
this canvas. build.sh prepares both and encodes the result.

Each beat is a hard cut: a caption band over the footage, with a cursor, click
ripple and keycaps drawn at the times and points the recorder logged. Window
pixels are only cropped, scaled, or retimed by whole frames.
"""
import json, os, shutil, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

TAKES, LEGACY, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
FPS = 15
TAKE_FPS = 30
LEGACY_FPS = 20
SCALE = 1.5                      # recorder pixels per window point
W, BAND, BODY = 1410, 88, 930    # canvas width, caption band, footage area
H = BAND + BODY
TOTAL_SECONDS = 30.0
TEAL = (12, 130, 117)
INK = (31, 35, 40)
MUTED = (89, 99, 110)
LINE = (216, 222, 228)
BAND_BG = (246, 248, 250)
BACKDROP = (233, 238, 243)       # the legacy scenes' backdrop
ICON = os.path.join(REPO, "LinuxWindows/packaging/icons/lokalbot-512.png")
LEGACY_CROP = (0, 130, 1840, 1264)   # below the old caption, above the old footer

# segments: (source start s, source end s, speed); output length = sum((end - start) / speed)
BEATS = [
    dict(take="t-recall", layout="panel", segments=[(0.45, 2.45, 2.5), (2.45, 4.85, 1.0)],
         caption=[("Search what you ", False), ("saw and heard", True)]),
    dict(take="t-meeting", layout="window", segments=[(0.5, 4.5, 1.0)],
         caption=[("Meeting notes that ", False), ("cite the moment", True)]),
    dict(take="t-ask", layout="window", segments=[(0.5, 4.3, 1.0)],
         caption=[("Ask your memory, ", False), ("check the source", True)]),
    dict(legacy=True, segments=[(12.0, 13.2, 1.0), (14.6, 17.7, 1.0)],
         keys=[(15.10, "tab"), (15.50, "tab"), (15.95, "tab"), (16.40, "tab")],
         caption=[("Autocomplete that ", False), ("knows what was agreed", True)]),
    dict(legacy=True, segments=[(20.2, 22.9, 1.0), (22.9, 25.7, 2.0), (25.7, 27.2, 1.0)],
         holds=[(20.2, 22.3, "hold ⌥ space")],
         caption=[("Say what you need, ", False), ("dictation writes it", True)]),
    dict(take="t-timeline", layout="window", segments=[(0.5, 3.9, 1.0)],
         caption=[("Retrace your day", True), (", session by session", False)]),
    dict(take="t-people", layout="window", segments=[(0.6, 3.6, 1.0)],
         caption=[("What's open ", False), ("with each person", True)]),
]


def font(size, weight="Regular"):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


CAPTION = font(36, "Semibold")
LABEL = font(20, "Regular")
KEY = font(26, "Semibold")


def ease(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def length(segments):
    return sum((e - s) / v for s, e, v in segments)


def source_time(segments, t):
    for s, e, v in segments:
        span = (e - s) / v
        if t < span:
            return s + t * v
        t -= span
    return segments[-1][1]


def output_time(segments, src):
    """Output time at which a source moment plays, or None if it was cut."""
    base = 0.0
    for s, e, v in segments:
        if s <= src <= e:
            return base + (src - s) / v
        base += (e - s) / v
    return None


def take_frames(take, work):
    folder = os.path.join(work, take)
    if not os.path.isdir(folder):
        os.makedirs(folder)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", os.path.join(TAKES, f"{take}.mov"),
                        "-vf", f"fps={TAKE_FPS}", "-start_number", "0",
                        os.path.join(folder, "%04d.png")], check=True)
    return [os.path.join(folder, n) for n in sorted(os.listdir(folder))]


def pick(frames, fps, t):
    return frames[min(len(frames) - 1, max(0, round(t * fps)))]


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return mask


def place_panel(canvas, frame):
    # Quick Recall hides its titlebar; drop that empty strip above the field.
    frame = frame.crop((0, 42, frame.size[0], frame.size[1]))
    fw, fh = frame.size
    ox, oy = (W - fw) // 2, BAND + (BODY - fh) // 2
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    for i, a in enumerate((10, 8, 6, 4)):
        g = 4 + i * 5
        sd.rounded_rectangle((ox - g, oy - g + 8, ox + fw + g, oy + fh + g + 8), 21 + g, fill=(0, 0, 0, a))
    canvas.alpha_composite(shadow)
    canvas.paste(frame, (ox, oy), rounded_mask(frame.size, 21))
    ImageDraw.Draw(canvas).rounded_rectangle((ox, oy, ox + fw - 1, oy + fh - 1), 21, outline=(201, 209, 217), width=1)
    return ox, oy - 42


def footage(beat, path):
    canvas = Image.new("RGBA", (W, H), BACKDROP)
    frame = Image.open(path).convert("RGBA")
    if beat.get("legacy"):
        frame = frame.crop(LEGACY_CROP)
        frame = frame.resize((W, round(frame.size[1] * W / frame.size[0])), Image.LANCZOS)
        canvas.paste(frame, (0, BAND + (BODY - frame.size[1]) // 2))
        return canvas, (0, 0)
    if beat["layout"] == "panel":
        return canvas, place_panel(canvas, frame)
    canvas.paste(frame.crop((0, 0, W, BODY)), (0, BAND))
    return canvas, (0, BAND)


def draw_band(canvas, index, caption):
    d = ImageDraw.Draw(canvas)
    d.rectangle((0, 0, W, BAND - 1), fill=BAND_BG)
    d.line((0, BAND - 1, W, BAND - 1), fill=LINE, width=1)
    x = 40
    for text, accent in caption:
        d.text((x, BAND / 2), text, font=CAPTION, fill=TEAL if accent else INK, anchor="lm")
        x += d.textlength(text, font=CAPTION)
    n, gap, r = len(BEATS), 22, 6
    right = W - 40
    for i in range(n):
        cx = right - (n - 1 - i) * gap
        d.ellipse((cx - r, BAND / 2 - r, cx + r, BAND / 2 + r), fill=TEAL if i == index else LINE)
    d.text((right - (n - 1) * gap - 26, BAND / 2), "Real app · fictional demo data",
           font=LABEL, fill=MUTED, anchor="rm")


def draw_cursor(canvas, x, y):
    pts = [(0, 0), (0, 17.5), (4.2, 13.6), (6.9, 20), (9.6, 18.9), (6.9, 12.7), (12.4, 12.7)]
    shape = [(x + px * SCALE, y + py * SCALE) for px, py in pts]
    d = ImageDraw.Draw(canvas)
    d.polygon(shape, fill=(255, 255, 255), outline=(255, 255, 255), width=5)
    d.polygon(shape, fill=(0, 0, 0))


def draw_ripple(canvas, x, y, age):
    if not 0 <= age <= 0.42:
        return
    k = age / 0.42
    radius = 10 + 30 * ease(k)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse((x - radius, y - radius, x + radius, y + radius),
                                  outline=TEAL + (int(255 * (1 - k) * 0.85),), width=5)
    canvas.alpha_composite(layer)


def draw_keycap(canvas, text, cx, cy):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w = max(64, d.textlength(text, font=KEY) + 40)
    d.rounded_rectangle((cx - w / 2, cy - 26, cx + w / 2, cy + 26), 12, fill=INK + (235,))
    d.text((cx, cy), text, font=KEY, fill=(255, 255, 255), anchor="mm")
    canvas.alpha_composite(layer)


def end_card():
    canvas = Image.new("RGBA", (W, H), BAND_BG)
    d = ImageDraw.Draw(canvas)
    icon = Image.open(ICON).convert("RGBA")
    icon = icon.crop(icon.getchannel("A").getbbox()).resize((168, 168), Image.LANCZOS)
    canvas.alpha_composite(icon, ((W - 168) // 2, 168))
    d.text((W / 2, 412), "LokalBot", font=font(84, "Bold"), fill=INK, anchor="mm")
    d.text((W / 2, 500), "Your personal context engine.", font=font(38, "Regular"), fill=MUTED, anchor="mm")
    chips = ["Runs on your computer", "Free and open source", "No bot joins your calls"]
    cf = font(28, "Semibold")
    widths = [d.textlength(c, font=cf) + 48 for c in chips]
    x = (W - (sum(widths) + 16 * (len(chips) - 1))) / 2
    for c, w in zip(chips, widths):
        d.rounded_rectangle((x, 572, x + w, 628), 28, fill=(226, 241, 238))
        d.text((x + w / 2, 600), c, font=cf, fill=TEAL, anchor="mm")
        x += w + 16
    d.text((W / 2, 702), "Also: rewrite selected text, and give your AI agents read-only access over MCP.",
           font=font(28, "Regular"), fill=MUTED, anchor="mm")
    d.text((W / 2, H - 52), "Real app · fictional demo data", font=LABEL, fill=MUTED, anchor="mm")
    return canvas


def main():
    work = os.path.join(os.path.dirname(os.path.abspath(OUT)), "take-frames")
    os.makedirs(work, exist_ok=True)
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    legacy = [os.path.join(LEGACY, n) for n in sorted(os.listdir(LEGACY))]
    n = 0
    for index, beat in enumerate(BEATS):
        segs = beat["segments"]
        if beat.get("legacy"):
            frames, fps, ev = legacy, LEGACY_FPS, []
        else:
            frames, fps = take_frames(beat["take"], work), TAKE_FPS
            with open(os.path.join(TAKES, f"{beat['take']}.events.json")) as f:
                ev = json.load(f)
        clicks = [(output_time(segs, e["t"]), e) for e in ev if e["kind"] == "click"]
        keys = [(output_time(segs, e["t"]), {"down": "↓", "tab": "tab"}.get(e["key"], e["key"]))
                for e in ev if e["kind"] == "press"]
        keys += [(output_time(segs, t), label) for t, label in beat.get("keys", [])]
        holds = [(output_time(segs, a), output_time(segs, b), label) for a, b, label in beat.get("holds", [])]
        for i in range(round(length(segs) * FPS)):
            t = i / FPS
            canvas, (ox, oy) = footage(beat, pick(frames, fps, source_time(segs, t)))
            for at, c in clicks:
                if at is None:
                    continue
                tx, ty = ox + c["x"] * SCALE, oy + c["y"] * SCALE
                sx, sy = tx + 170, ty + 120
                travel = ease((t - 0.1) / max(0.2, at - 0.22))
                draw_ripple(canvas, tx, ty, t - at)
                draw_cursor(canvas, sx + (tx - sx) * travel, sy + (ty - sy) * travel)
            for at, label in keys:
                if at is not None and 0 <= t - at < 0.36:
                    draw_keycap(canvas, label, W / 2, BAND + BODY - 70)
            for a, b, label in holds:
                if a is not None and b is not None and a <= t < b:
                    draw_keycap(canvas, label, W / 2, BAND + BODY - 70)
            draw_band(canvas, index, beat["caption"])
            canvas.convert("RGB").save(os.path.join(OUT, f"{n:04d}.png"))
            n += 1
    card = end_card().convert("RGB")
    # The end card absorbs the remainder so the loop is exactly TOTAL_SECONDS.
    for _ in range(round(TOTAL_SECONDS * FPS) - n):
        card.save(os.path.join(OUT, f"{n:04d}.png"))
        n += 1
    print(f"{n} frames, {n / FPS:.2f} s")


main()
