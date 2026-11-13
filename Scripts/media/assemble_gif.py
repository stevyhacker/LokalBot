#!/usr/bin/env python3
"""Assemble screenshot GIFs or a directed, animated product-tour MP4.

GIF exports keep the compact cross-slide treatment used by the README. The
landing-page MP4 is deliberately different: it preserves the real app capture
while adding eased camera moves, a moving pointer, click cues, and exact feature
labels. This makes the hero feel like a guided interaction instead of a deck of
screenshots.

All composition happens in a lossless sRGB/GBR working space. GIFs are
palette-quantized from that master; MP4 is converted once to tagged BT.709.

Usage:
    assemble_gif.py <out.gif|out.mp4> <width> <frame1.png> [frame2.png ...]
"""
import atexit
import html
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass

BG = "0x0e141c"
GIF_HOLD, GIF_TRANS, GIF_FPS = 1.9, 0.5, 12
VIDEO_FPS, VIDEO_TRANS = 30, 0.35
TO_BT709 = ("colorspace=ispace=gbr:irange=pc:iprimaries=bt709:itrc=srgb:"
            "space=bt709:range=tv:primaries=bt709:trc=bt709:format=yuv420p")


@dataclass(frozen=True)
class DirectedScene:
    label: str
    duration: float
    start_zoom: float
    end_zoom: float
    focus_x: float
    focus_y: float
    cursor_start: tuple[float, float]
    cursor_end: tuple[float, float]


# Labels are exact phrases already used by the landing page's video description.
# Focus and cursor coordinates are normalized to keep direction stable if the
# capture resolution changes while preserving the same app layout.
DIRECTED_SCENES = {
    "meetings-summary": DirectedScene(
        "Meeting recap", 3.15, 1.00, 1.16, 0.76, 0.31,
        (0.54, 0.68), (0.66, 0.24)),
    "meetings-transcript": DirectedScene(
        "Speaker-labeled transcript", 2.75, 1.14, 1.07, 0.77, 0.34,
        (0.66, 0.24), (0.78, 0.61)),
    "search": DirectedScene(
        "Search across every word", 2.85, 1.00, 1.19, 0.82, 0.27,
        (0.60, 0.56), (0.75, 0.18)),
    "chat": DirectedScene(
        "Answers with citations", 3.10, 1.00, 1.16, 0.70, 0.29,
        (0.72, 0.62), (0.58, 0.39)),
    "timeline": DirectedScene(
        "Private day timeline", 3.00, 1.00, 1.17, 0.69, 0.30,
        (0.48, 0.67), (0.68, 0.36)),
    "cotyping": DirectedScene(
        "Inline autocomplete", 3.25, 1.00, 1.20, 0.68, 0.53,
        (0.68, 0.34), (0.78, 0.63)),
}


def dims(path):
    output = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
        capture_output=True, text=True, check=True).stdout
    width = int([line for line in output.splitlines()
                 if "pixelWidth" in line][0].split(":")[1])
    height = int([line for line in output.splitlines()
                  if "pixelHeight" in line][0].split(":")[1])
    return width, height


def scene_key(path):
    return os.path.splitext(os.path.basename(path))[0]


def directed_scene(path, index):
    key = scene_key(path)
    if key in DIRECTED_SCENES:
        return DIRECTED_SCENES[key]
    return DirectedScene(
        key.replace("-", " ").title(), 2.8, 1.00, 1.13,
        0.50 + (0.10 if index % 2 else -0.10), 0.45,
        (0.42, 0.70), (0.62, 0.38))


def compile_svg_renderer(tmp):
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "render_svg.swift")
    output = os.path.join(tmp, "render-svg")
    subprocess.run(["xcrun", "swiftc", source, "-o", output], check=True)
    return output


def render_svg(renderer, svg, output, width, height):
    source = os.path.splitext(output)[0] + ".svg"
    with open(source, "w", encoding="utf-8") as handle:
        handle.write(svg)
    subprocess.run([
        renderer, source, output, str(width), str(height),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_pointer_assets(tmp, renderer):
    cursor = os.path.join(tmp, "pointer.png")
    click = os.path.join(tmp, "click.png")
    render_svg(renderer, """<svg xmlns="http://www.w3.org/2000/svg" width="72" height="88" viewBox="0 0 72 88">
      <path d="M8 5 L9 69 L25 54 L39 83 L53 76 L39 48 L65 47 Z"
            fill="#f7fbff" stroke="#071018" stroke-width="5" stroke-linejoin="round"/>
      <path d="M25 54 L34 48" stroke="#55e3d1" stroke-width="4" stroke-linecap="round"/>
    </svg>""", cursor, 72, 88)
    render_svg(renderer, """<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
      <circle cx="48" cy="48" r="31" fill="#55e3d1" fill-opacity="0.08"
              stroke="#55e3d1" stroke-width="6" stroke-opacity="0.92"/>
      <circle cx="48" cy="48" r="7" fill="#55e3d1" fill-opacity="0.95"/>
    </svg>""", click, 96, 96)
    return cursor, click


def make_label(tmp, renderer, index, label):
    width = max(390, min(720, 138 + len(label) * 21))
    output = os.path.join(tmp, f"label-{index}.png")
    safe = html.escape(label)
    render_svg(renderer, f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="88" viewBox="0 0 {width} 88">
      <rect x="2" y="2" width="{width - 4}" height="84" rx="25"
            fill="#08111a" fill-opacity="0.92" stroke="#55e3d1"
            stroke-opacity="0.56" stroke-width="2"/>
      <circle cx="34" cy="44" r="8" fill="#55e3d1"/>
      <text x="58" y="56" fill="#f7fbff" font-size="34" font-weight="650"
            font-family="SF Pro Display, Helvetica Neue, Helvetica, Arial, sans-serif">{safe}</text>
    </svg>""", output, width, 88)
    return output


def normalize_frames(frames, tmp):
    max_width = max(dims(frame)[0] for frame in frames)
    max_height = max(dims(frame)[1] for frame in frames)
    canvas_width, canvas_height = max_width + 80, max_height + 80
    canvas_width += canvas_width % 2
    canvas_height += canvas_height % 2
    normalized = []
    for index, frame in enumerate(frames):
        output = os.path.join(tmp, f"frame-{index}.png")
        subprocess.run([
            "ffmpeg", "-y", "-v", "error", "-i", frame, "-vf",
            f"pad={canvas_width}:{canvas_height}:(ow-iw)/2:(oh-ih)/2:color={BG}",
            output,
        ], check=True)
        normalized.append(output)
    return normalized, canvas_width, canvas_height


def split_stream(parts, input_index, prefix, count, duration, scaled_width):
    prepare = f"format=rgba,scale={scaled_width}:-1:flags=lanczos"
    if count == 1:
        parts.append(
            f"[{input_index}:v]{prepare},trim=duration={duration:.3f},"
            f"setpts=PTS-STARTPTS[{prefix}0]")
        return
    outputs = "".join(f"[{prefix}raw{index}]" for index in range(count))
    parts.append(f"[{input_index}:v]{prepare},split={count}{outputs}")
    for index in range(count):
        parts.append(
            f"[{prefix}raw{index}]trim=duration={duration:.3f},"
            f"setpts=PTS-STARTPTS[{prefix}{index}]")


def assemble_video(out, width, frames, normalized, canvas_width, canvas_height, tmp):
    scenes = [directed_scene(frame, index) for index, frame in enumerate(frames)]
    output_width = min(width, canvas_width)
    output_width -= output_width % 2
    output_height = int(round((output_width * canvas_height / canvas_width) / 2) * 2)
    max_duration = max(scene.duration for scene in scenes)
    overlay_scale = output_width / 1872
    cursor_width = max(32, int(round(72 * overlay_scale)))
    click_width = max(42, int(round(96 * overlay_scale)))
    overlay_margin = max(24, int(round(52 * overlay_scale)))
    cursor_hotspot_x = max(3, int(round(8 * overlay_scale)))
    cursor_hotspot_y = max(2, int(round(5 * overlay_scale)))

    renderer = compile_svg_renderer(tmp)
    cursor, click = make_pointer_assets(tmp, renderer)
    labels = [make_label(tmp, renderer, index, scene.label)
              for index, scene in enumerate(scenes)]

    inputs = []
    for frame, scene in zip(normalized, scenes):
        inputs += ["-loop", "1", "-framerate", str(VIDEO_FPS),
                   "-t", f"{scene.duration:.3f}", "-i", frame]
    cursor_index = len(scenes)
    inputs += ["-loop", "1", "-framerate", str(VIDEO_FPS),
               "-t", f"{max_duration:.3f}", "-i", cursor]
    click_index = cursor_index + 1
    inputs += ["-loop", "1", "-framerate", str(VIDEO_FPS),
               "-t", f"{max_duration:.3f}", "-i", click]
    label_start = click_index + 1
    for label, scene in zip(labels, scenes):
        inputs += ["-loop", "1", "-framerate", str(VIDEO_FPS),
                   "-t", f"{scene.duration:.3f}", "-i", label]

    filters = []
    split_stream(filters, cursor_index, "cursor", len(scenes),
                 max_duration, cursor_width)
    split_stream(filters, click_index, "click", len(scenes),
                 max_duration, click_width)

    for index, scene in enumerate(scenes):
        frame_count = max(2, int(round(scene.duration * VIDEO_FPS)))
        progress = f"(on/{frame_count - 1})"
        ease = f"({progress}*{progress}*(3-2*{progress}))"
        zoom = f"{scene.start_zoom:.4f}+({scene.end_zoom - scene.start_zoom:.4f})*{ease}"
        pan_x = (f"max(0\\,min(iw-iw/zoom\\,"
                 f"iw*{scene.focus_x:.4f}-iw/(2*zoom)))")
        pan_y = (f"max(0\\,min(ih-ih/zoom\\,"
                 f"ih*{scene.focus_y:.4f}-ih/(2*zoom)))")
        filters.append(
            f"[{index}:v]format=gbrp,"
            f"zoompan=z='{zoom}':x='{pan_x}':y='{pan_y}':d=1:"
            f"s={output_width}x{output_height}:fps={VIDEO_FPS},"
            f"trim=duration={scene.duration:.3f},setpts=PTS-STARTPTS[base{index}]")

        start_x = int(scene.cursor_start[0] * output_width)
        start_y = int(scene.cursor_start[1] * output_height)
        end_x = int(scene.cursor_end[0] * output_width)
        end_y = int(scene.cursor_end[1] * output_height)
        move_duration = max(0.5, scene.duration - 0.52)
        move_progress = f"min(t/{move_duration:.3f}\\,1)"
        cursor_x = f"{start_x}+({end_x - start_x})*{move_progress}"
        cursor_y = f"{start_y}+({end_y - start_y})*{move_progress}"
        filters.append(
            f"[base{index}][cursor{index}]overlay=x='{cursor_x}':y='{cursor_y}':"
            f"format=auto[pointer{index}]")

        click_start = scene.duration - 0.46
        click_end = scene.duration - 0.13
        filters.append(
            f"[pointer{index}][click{index}]overlay="
            f"x={end_x + cursor_hotspot_x - click_width // 2}:"
            f"y={end_y + cursor_hotspot_y - click_width // 2}:"
            f"enable='between(t\\,{click_start:.3f}\\,{click_end:.3f})':"
            f"format=auto[clicked{index}]")

        label_index = label_start + index
        fade_out = max(0.0, scene.duration - 0.32)
        filters.append(
            f"[{label_index}:v]format=rgba,"
            f"scale=iw*{overlay_scale:.6f}:-1:flags=lanczos,"
            f"fade=t=in:st=0:d=0.22:alpha=1,"
            f"fade=t=out:st={fade_out:.3f}:d=0.28:alpha=1[label{index}]")
        filters.append(
            f"[clicked{index}][label{index}]overlay="
            f"x={overlay_margin}:y=main_h-overlay_h-{overlay_margin}:"
            f"format=auto,format=gbrp,setpts=PTS-STARTPTS[scene{index}]")

    previous = "[scene0]"
    elapsed = scenes[0].duration
    for index in range(1, len(scenes)):
        output_label = f"[tour{index}]"
        offset = elapsed - VIDEO_TRANS
        filters.append(
            f"{previous}[scene{index}]xfade=transition=fade:duration={VIDEO_TRANS}:"
            f"offset={offset:.3f}{output_label}")
        previous = output_label
        elapsed += scenes[index].duration - VIDEO_TRANS

    filters.append(
        f"{previous}fps={VIDEO_FPS},format=gbrp,{TO_BT709}[out]")
    subprocess.run([
        "ffmpeg", "-y", "-v", "error", *inputs,
        "-filter_complex", ";".join(filters), "-map", "[out]",
        "-c:v", "libx264", "-crf", "20", "-preset", "slow",
        "-colorspace", "bt709", "-color_primaries", "bt709",
        "-color_trc", "bt709", "-color_range", "tv",
        "-movflags", "+faststart", "-an", out,
    ], check=True)

    manifest_path = os.path.splitext(out)[0] + ".manifest.json"
    manifest = {
        "version": 1,
        "output": os.path.basename(out),
        "dimensions": [output_width, output_height],
        "fps": VIDEO_FPS,
        "workingColorSpace": "sRGB IEC 61966-2-1",
        "deliveryColorSpace": "BT.709 limited range",
        "transitionSeconds": VIDEO_TRANS,
        "scenes": [dict(source=os.path.basename(frame), **asdict(scene))
                   for frame, scene in zip(frames, scenes)],
    }
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print(f"  {out} ({os.path.getsize(out) // 1024} KB, {elapsed:.1f}s)")
    print(f"  {manifest_path}")


def assemble_gif(out, width, normalized, tmp):
    inputs = []
    for frame in normalized:
        inputs += ["-loop", "1", "-t", str(GIF_HOLD + GIF_TRANS), "-i", frame]
    if len(normalized) > 1:
        steps, previous = [], "[0]"
        for index in range(1, len(normalized)):
            label = f"[v{index}]"
            steps.append(
                f"{previous}[{index}]xfade=transition=slideleft:"
                f"duration={GIF_TRANS}:offset={index * GIF_HOLD}{label}")
            previous = label
        filter_complex = ";".join(steps) + f";{previous}fps={GIF_FPS},format=gbrp[out]"
    else:
        filter_complex = f"[0]fps={GIF_FPS},format=gbrp[out]"

    master = os.path.join(tmp, "master.mkv")
    subprocess.run([
        "ffmpeg", "-y", "-v", "error", *inputs,
        "-filter_complex", filter_complex, "-map", "[out]",
        "-c:v", "ffv1", "-level", "3", "-pix_fmt", "gbrp",
        "-colorspace", "0", "-color_primaries", "bt709",
        "-color_trc", "iec61966-2-1", "-color_range", "pc", master,
    ], check=True)

    scale = f"scale=min({width}\\,iw):-1:flags=lanczos"
    palette = os.path.join(tmp, "palette.png")
    subprocess.run([
        "ffmpeg", "-y", "-v", "error", "-i", master, "-vf",
        f"fps={GIF_FPS},{scale},palettegen=stats_mode=diff", palette,
    ], check=True)
    subprocess.run([
        "ffmpeg", "-y", "-v", "error", "-i", master, "-i", palette,
        "-lavfi", f"fps={GIF_FPS},{scale}[x];"
        f"[x][1:v]paletteuse=dither=bayer:bayer_scale=3", out,
    ], check=True)
    print(f"  {out} ({os.path.getsize(out) // 1024} KB)")


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    out, width, frames = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    tmp = tempfile.mkdtemp(prefix="lokalbot-media-")
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)
    normalized, canvas_width, canvas_height = normalize_frames(frames, tmp)
    if out.endswith(".mp4"):
        assemble_video(out, width, frames, normalized,
                       canvas_width, canvas_height, tmp)
    else:
        assemble_gif(out, width, normalized, tmp)


if __name__ == "__main__":
    main()
