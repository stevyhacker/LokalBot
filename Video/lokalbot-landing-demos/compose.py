#!/usr/bin/env python3
"""Cut one landing page demo clip from a rig take.

    compose.py <takes-dir> <clip> <wide|tall> <light|dark> <out.mp4> [--poster out.png]

A take (Scripts/readme-gif/rig.swift) is the app's window as PNG frames with
their arrival times, the events the rig performed, and the pointer's path. This
puts the window on a backdrop, moves a camera over it, and draws the pointer,
click ripples, keycaps and badges at the times and points the rig logged.
edit.json says which parts of which takes play at what speed and where the
camera looks.

Times in edit.json are take seconds, or anchors that hold in every appearance's
take: a mark ("typed"), the nth event of a kind ("click:0", "key:2", "hold:0"),
"end", or a clip's own "anchors" per appearance, each with an optional offset
("typed+0.4"). A segment is [start, end, speed]; a speed "=3" plays the segment
in exactly 3 seconds. A clip plays one "take" and its "segments", or "parts", a
list of those, dissolving between them over "fade" seconds. A cut can override
any of a clip's settings, such as a portrait cut with its own take.

Window pixels are only moved and scaled, and retimed by whole source frames;
nothing inside the window is redrawn. Everything drawn on top is listed above.
"""
import argparse
import json
import math
import os
import re
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
CANVAS = {"wide": (1920, 1200), "tall": (1080, 1350)}
FPS = 60
BACKDROP = {
    "light": ((222, 243, 238), (233, 237, 245), (8, 60, 60)),
    "dark": ((13, 25, 33), (10, 15, 23), (0, 0, 0)),
}
SHADOW_ALPHA = {"light": 70, "dark": 170}
RIPPLE = {"light": (12, 130, 117), "dark": (110, 242, 220)}
KEYCAP = {
    "light": {"fill": (255, 255, 255, 245), "line": (20, 40, 50, 40), "text": (31, 35, 40, 255), "down": (222, 243, 238, 250)},
    "dark": {"fill": (30, 42, 54, 245), "line": (255, 255, 255, 46), "text": (236, 243, 247, 255), "down": (20, 72, 70, 250)},
}


def ease(x):
    x = min(1.0, max(0.0, x))
    return x * x * x * (x * (6 * x - 15) + 10)  # smootherstep, so the camera starts and lands softly


def font(size, weight="Semibold"):
    f = ImageFont.truetype(os.environ.get("LANDING_FONT", "/System/Library/Fonts/SFNS.ttf"), size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


class Take:
    def __init__(self, folder):
        self.folder = Path(folder)
        meta = json.loads((self.folder / "take.json").read_text())
        self.meta = meta
        self.frames = meta["frames"]
        self.times = [f[1] for f in self.frames]
        self.scale = meta["scale"]
        self.rect = meta["rect"]
        self.events = meta["events"]
        self.pointer = meta.get("pointer") or []
        self.end = meta["end"]
        self.anchors = {"start": 0.0, "end": self.end}
        counts = {}
        for event in self.events:
            kind = event.get("kind")
            if kind == "mark":
                self.anchors.setdefault(event["name"], event["t"])
            self.anchors[f"{kind}:{counts.get(kind, 0)}"] = event["t"]
            counts[kind] = counts.get(kind, 0) + 1

    def time(self, spec, extra=None):
        """Take seconds for a number or an anchor; None when this take has no such anchor."""
        if isinstance(spec, (int, float)):
            return float(spec)
        names = {**self.anchors, **(extra or {})}
        if spec in names:
            return float(names[spec])
        match = re.fullmatch(r"(.+?)([+-]\d+(?:\.\d+)?)", spec)
        if match and match.group(1) in names:
            return float(names[match.group(1)]) + float(match.group(2))
        return None

    def frame_at(self, t):
        lo, hi = 0, len(self.times) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.times[mid] <= t:
                lo = mid
            else:
                hi = mid - 1
        return int(self.frames[lo][0])

    def image(self, index):
        return Image.open(self.folder / "frames" / f"{index:05d}.png").convert("RGB")

    def pointer_at(self, t):
        path = self.pointer
        if not path:
            return None
        lo, hi = 0, len(path) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if path[mid][0] <= t:
                lo = mid
            else:
                hi = mid - 1
        a = path[lo]
        b = path[min(lo + 1, len(path) - 1)]
        if b[0] <= a[0]:
            return a[1], a[2]
        k = min(1.0, max(0.0, (t - a[0]) / (b[0] - a[0])))
        return a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k


class Timeline:
    """Output seconds to take seconds through segments, one take per part."""

    def __init__(self, parts):
        # parts: [(part index, [(start, end, speed)])]
        self.spans = []  # (part, start, end, speed, output start)
        base = 0.0
        self.boundaries = []
        for index, segments in parts:
            if self.spans:
                self.boundaries.append(base)
            for a, b, v in segments:
                self.spans.append((index, a, b, v, base))
                base += (b - a) / v
        self.length = base

    def at(self, t):
        """(part, take seconds) at output time t."""
        for part, a, b, v, base in self.spans:
            if t < base + (b - a) / v:
                return part, a + (t - base) * v
        part, _, b, _, _ = self.spans[-1]
        return part, b

    def in_part(self, t, part):
        """Take seconds of `part` at output time t, held at the part's ends for a dissolve."""
        spans = [span for span in self.spans if span[0] == part]
        for _, a, b, v, base in spans:
            if t < base + (b - a) / v:
                return a + max(0.0, t - base) * v
        return spans[-1][2]

    def output(self, src, part=None):
        for index, a, b, v, base in self.spans:
            if (part is None or index == part) and a <= src <= b:
                return base + (src - a) / v
        return None


def backdrop(size, theme):
    a, b, _ = BACKDROP[theme]
    w, h = size
    small = Image.new("RGB", (64, 40))
    px = small.load()
    for y in range(40):
        for x in range(64):
            k = (x / 63 + y / 39) / 2
            px[x, y] = tuple(round(a[i] + (b[i] - a[i]) * k) for i in range(3))
    return small.resize((w, h), Image.BICUBIC)


class Scene:
    """The window on its backdrop, in window points plus a margin, at the take's pixel scale."""

    def __init__(self, take, theme, margin, radius, crop=None):
        self.take = take
        self.margin = margin
        s = take.scale
        self.crop = crop or [0, 0, take.rect[2], take.rect[3]]  # points inside the capture
        cw, ch = self.crop[2], self.crop[3]
        self.world = (cw + 2 * margin, ch + 2 * margin)
        self.size = (round(self.world[0] * s), round(self.world[1] * s))
        self.base = backdrop(self.size, theme)
        box = (round(margin * s), round(margin * s), round((margin + cw) * s), round((margin + ch) * s))
        self.box = box
        # A rounded mask supersampled for a clean edge, slightly inside the window's own edge.
        mw, mh = box[2] - box[0], box[3] - box[1]
        big = Image.new("L", (mw * 3, mh * 3), 0)
        inset = 1
        ImageDraw.Draw(big).rounded_rectangle((inset, inset, mw * 3 - inset - 1, mh * 3 - inset - 1), radius * s * 3, fill=255)
        self.mask = big.resize((mw, mh), Image.LANCZOS)
        shadow = Image.new("L", self.size, 0)
        spread = round(14 * s)
        shadow.paste(self.mask, (box[0], box[1] + round(10 * s)))
        shadow = shadow.filter(ImageFilter.GaussianBlur(spread))
        shadow = shadow.point(lambda v: v * SHADOW_ALPHA[theme] // 255)
        ink = Image.new("RGB", self.size, BACKDROP[theme][2])
        self.base = Image.composite(ink, self.base, shadow)
        self.cache_index = None
        self.cache = None

    def at(self, index):
        if index != self.cache_index:
            s = self.take.scale
            c = self.crop
            frame = self.take.image(index).crop((round(c[0] * s), round(c[1] * s), round((c[0] + c[2]) * s), round((c[1] + c[3]) * s)))
            scene = self.base.copy()
            scene.paste(frame, self.box[:2], self.mask)
            self.cache, self.cache_index = scene, index
        return self.cache


def camera_at(keys, t):
    """keys: [t, cx, cy, w] in output seconds and window points; eased between keys."""
    if t <= keys[0][0]:
        return keys[0][1:]
    for a, b in zip(keys, keys[1:]):
        if t <= b[0]:
            k = ease((t - a[0]) / max(b[0] - a[0], 1e-6))
            return [a[i] + (b[i] - a[i]) * k for i in (1, 2, 3)]
    return keys[-1][1:]


class Pointer:
    """The macOS arrow, drawn from its outline: NSCursor.arrow has no image outside a running app."""

    OUTLINE = [(0, 0), (0, 17.6), (4.2, 13.7), (6.9, 20.1), (9.9, 18.8), (7.2, 12.5), (12.9, 12.5)]
    SUPER = 8

    def __init__(self):
        k = self.SUPER
        pad = 4
        size = (24 * k, 28 * k)
        shape = [((x + pad) * k, (y + pad) * k) for x, y in self.OUTLINE]
        image = Image.new("RGBA", size, (0, 0, 0, 0))
        shadow = Image.new("L", size, 0)
        ImageDraw.Draw(shadow).polygon([(x, y + 1.2 * k) for x, y in shape], fill=110)
        shadow = shadow.filter(ImageFilter.GaussianBlur(1.3 * k))
        image.paste((0, 0, 0, 255), (0, 0), shadow)
        draw = ImageDraw.Draw(image)
        draw.polygon(shape, fill=(255, 255, 255, 255), outline=(255, 255, 255, 255))
        draw.line(shape + shape[:1], fill=(255, 255, 255, 255), width=round(2.0 * k), joint="curve")
        inner = [((x * 0.86 + 0.95 + pad) * k, (y * 0.86 + 1.75 + pad) * k) for x, y in self.OUTLINE]
        draw.polygon(inner, fill=(18, 18, 20, 255))
        self.image = image
        self.pad = pad

    def draw(self, canvas, x, y, zoom, dip=1.0):
        # The pointer scales with the camera, as it would in the app.
        k = zoom * dip / self.SUPER
        w, h = self.image.size
        img = self.image.resize((max(1, round(w * k)), max(1, round(h * k))), Image.LANCZOS)
        canvas.alpha_composite(img, (max(0, round(x - self.pad * zoom * dip)), max(0, round(y - self.pad * zoom * dip))))


def ripple(draw, x, y, age, zoom, color):
    span = 0.42
    if age < 0 or age > span:
        return
    k = age / span
    r = (5 + 20 * (1 - (1 - k) ** 2)) * zoom
    alpha = round(150 * (1 - k))
    width = max(1, round(2.2 * zoom))
    draw.ellipse((x - r, y - r, x + r, y + r), outline=color + (alpha,), width=width)


def keycap(layer, center, label, opacity, pressed, theme, size):
    style = KEYCAP[theme]
    f = font(size)
    d = ImageDraw.Draw(layer)
    left, top, right, bottom = d.textbbox((0, 0), label, font=f)
    tw, th = right - left, bottom - top
    pad_x, pad_y = size * 0.72, size * 0.5
    w, h = tw + 2 * pad_x, th + 2 * pad_y
    x0, y0 = center[0] - w / 2, center[1] - h / 2 + (size * 0.08 if pressed else 0)
    tile = Image.new("RGBA", (math.ceil(w) + 2, math.ceil(h) + 2), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    radius = size * 0.42
    td.rounded_rectangle((0, 0, w, h), radius, fill=style["down"] if pressed else style["fill"], outline=style["line"], width=max(1, round(size / 18)))
    td.text((pad_x - left, pad_y - top), label, font=f, fill=style["text"])
    if opacity < 1:
        tile.putalpha(tile.getchannel("A").point(lambda v: round(v * opacity)))
    layer.alpha_composite(tile, (round(x0), round(y0)))


def segments_for(spec, take, extra):
    """[start, end, speed] with anchors resolved and "=seconds" speeds turned into rates."""
    out = []
    for a, b, v in spec:
        start, stop = take.time(a, extra), take.time(b, extra)
        if start is None or stop is None:
            raise SystemExit(f"no anchor for segment {[a, b]} in {take.folder}")
        stop = max(stop, start + 1e-3)
        rate = (stop - start) / float(v[1:]) if isinstance(v, str) else float(v)
        out.append((start, stop, rate))
    return out


def badge(canvas, label, opacity, cut, theme):
    size = 26 if cut == "wide" else 34
    style = KEYCAP[theme]
    f = font(size, "Medium")
    probe = ImageDraw.Draw(canvas)
    left, top, right, bottom = probe.textbbox((0, 0), label, font=f)
    pad_x, pad_y = size * 0.75, size * 0.42
    w, h = right - left + 2 * pad_x, bottom - top + 2 * pad_y
    tile = Image.new("RGBA", (math.ceil(w) + 2, math.ceil(h) + 2), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    td.rounded_rectangle((0, 0, w, h), h / 2, fill=style["fill"], outline=style["line"], width=max(1, round(size / 18)))
    td.text((pad_x - left, pad_y - top), label, font=f, fill=style["text"])
    tile.putalpha(tile.getchannel("A").point(lambda v: round(v * opacity)))
    canvas.alpha_composite(tile, (round(canvas.width - w - size * 1.2), round(size * 1.1)))


def render(args):
    edit = json.loads((HERE / "edit.json").read_text())
    clip = dict(edit["clips"][args.clip])
    cut = clip.pop("cuts")[args.cut]
    clip.update(cut)  # a cut's settings win over the clip's
    extra = clip.get("anchors", {}).get(args.theme, {})
    part_specs = clip.get("parts") or [{"take": clip["take"], "segments": clip["segments"]}]
    takes = [Take(Path(args.takes) / args.theme / part["take"]) for part in part_specs]
    timeline = Timeline([(i, segments_for(part["segments"], takes[i], extra)) for i, part in enumerate(part_specs)])
    W, H = CANVAS[args.cut]
    scenes = [Scene(take, args.theme, part.get("margin", clip.get("margin", 28)), part.get("radius", clip.get("radius", 26)),
                    part.get("crop", clip.get("crop"))) for take, part in zip(takes, part_specs)]
    pointer = Pointer() if clip.get("pointer", True) and any(take.pointer for take in takes) else None
    fade = clip.get("fade", 0.0)

    def output_time(spec):
        """Output seconds for a number or an anchor in any part."""
        if isinstance(spec, (int, float)):
            return float(spec)
        for i, take in enumerate(takes):
            src = take.time(spec, extra)
            if src is not None:
                at = timeline.output(src, i)
                if at is not None:
                    return at
        raise SystemExit(f"anchor {spec} is outside the clip's segments")

    camera = [[output_time(key[0]), *key[1:]] for key in clip["camera"]]
    keys = [[output_time(key[0]), output_time(key[1]), *key[2:]] for key in clip.get("keys", [])]
    badges = [[output_time(item[0]), output_time(item[1]), item[2]] for item in clip.get("badges", [])]
    taps = [[output_time(item[0]), item[1]] for item in clip.get("taps", [])]
    for rule in clip.get("tap_events", []):
        for i, take in enumerate(takes):
            for event in take.events:
                if event.get("kind") == rule["kind"] and event.get("key", rule.get("key")) == rule.get("key"):
                    at = timeline.output(event["t"], i)
                    if at is not None:
                        taps.append([at, rule["label"]])
    # Sized by the canvas so keycaps stay readable on a phone-width clip.
    key_size = 40 if args.cut == "wide" else 48
    key_at = clip.get("key_at")
    key_center = (W * key_at[0], H * key_at[1]) if key_at else (W / 2, H - (92 if args.cut == "wide" else 120))

    encoder = None
    if args.out:
        encoder = subprocess.Popen([
            "ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
            "-c:v", "libx264", "-preset", args.preset, "-crf", str(args.crf), "-tune", "animation", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", "-an", args.out], stdin=subprocess.PIPE)

    last = {}

    def picture(t, part):
        """The window through the camera at output time t in one part, with its pointer and ripples."""
        take, scene = takes[part], scenes[part]
        s, margin, crop = take.scale, scene.margin, scene.crop
        src = timeline.in_part(t, part)
        cx, cy, vw = camera_at(camera, t)
        index = take.frame_at(src)
        wx, wy = cx - crop[0] + margin, cy - crop[1] + margin  # camera centre in world points
        # The view stays inside the scene: past its edge there is nothing to show.
        vw = min(vw, scene.world[0], scene.world[1] * W / H)
        vh = vw * H / W
        zoom = W / vw  # canvas pixels per point
        x0 = min(max(wx - vw / 2, 0), scene.world[0] - vw)
        y0 = min(max(wy - vh / 2, 0), scene.world[1] - vh)
        cam_key = (part, index, round(x0, 2), round(y0, 2), round(vw, 2))
        if last.get("key") != cam_key:
            box = (x0 * s, y0 * s, (x0 + vw) * s, (y0 + vh) * s)
            last["frame"] = scene.at(index).resize((W, H), Image.LANCZOS, box=box)
            last["key"] = cam_key
        canvas = last["frame"].convert("RGBA")

        to_canvas = lambda px, py: ((px - crop[0] + margin - x0) * zoom, (py - crop[1] + margin - y0) * zoom)
        overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)
        dip = 1.0
        for e in take.events:
            if e.get("kind") != "click":
                continue
            at = timeline.output(e["t"], part)
            if at is None:
                continue
            age = t - at
            if pointer is not None:
                ripple(draw, *to_canvas(e["x"], e["y"]), age, zoom, RIPPLE[args.theme])
            if -0.05 <= age <= 0.1:
                dip = min(dip, 0.88)
        canvas.alpha_composite(overlay)
        start_from = part_specs[part].get("pointer_from", clip.get("pointer_from"))
        start_at = take.time(start_from, extra) if start_from is not None else 0
        if pointer is not None and src >= (start_at or 0):
            p = take.pointer_at(src)
            if p is not None:
                pointer.draw(canvas, *to_canvas(*p), zoom, dip)
        return canvas

    total = round(timeline.length * FPS)
    poster_at = output_time(clip.get("poster", 0.0))
    for n in range(total):
        t = n / FPS
        part, _ = timeline.at(t)
        canvas = picture(t, part)
        for boundary in timeline.boundaries:
            if fade and abs(t - boundary) < fade / 2:
                k = ease((t - (boundary - fade / 2)) / fade)
                before = timeline.at(boundary - 1e-3)[0]
                after = timeline.at(boundary + 1e-3)[0]
                canvas = Image.blend(picture(t, before), picture(t, after), k)
                last.clear()

        for key in keys:
            start, end, label = key[0], key[1], key[2]
            if start - 0.15 <= t <= end + 0.2:
                opacity = min(1.0, (t - start + 0.15) / 0.15, (end + 0.2 - t) / 0.2)
                pressed = len(key) > 3 and key[3] and start <= t <= end
                keycap(canvas, key_center, label, max(0.0, opacity), pressed, args.theme, key_size)
        for at, label in taps:
            # A key pressed at one moment: the cap dips for a beat at each press.
            if -0.02 <= t - at <= 0.14:
                keycap(canvas, key_center, label, 1.0, True, args.theme, key_size)
        for start, end, label in badges:
            if start - 0.15 <= t <= end + 0.15:
                badge(canvas, label, max(0.0, min(1.0, (t - start + 0.15) / 0.15, (end + 0.15 - t) / 0.15)), args.cut, args.theme)

        rgb = canvas.convert("RGB")
        if args.poster and abs(t - poster_at) < 0.5 / FPS:
            rgb.save(args.poster)
        if encoder:
            encoder.stdin.write(rgb.tobytes())
    if encoder:
        encoder.stdin.close()
        encoder.wait()
    print(f"{args.clip} {args.cut} {args.theme}: {total} frames, {timeline.length:.2f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("takes")
    parser.add_argument("clip")
    parser.add_argument("cut", choices=CANVAS)
    parser.add_argument("theme", choices=BACKDROP)
    parser.add_argument("out", nargs="?")
    parser.add_argument("--poster")
    parser.add_argument("--crf", type=int, default=22)
    parser.add_argument("--preset", default="slow")
    parsed = parser.parse_args()
    render(parsed)
