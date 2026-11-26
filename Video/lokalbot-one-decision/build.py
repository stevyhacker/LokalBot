#!/usr/bin/env python3
"""Write index.html: where each scene starts, every sound against the picture, and optional social framing with burned-in captions.

    python3 build.py
    python3 build.py --format 4:5
    python3 build.py --format 9:16
"""
import argparse
import html
import json
import struct
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent

SCENES = [
    ("call", 6.2, 0),
    ("notes", 5.8, 5.15 + 0.55),
    ("search", 5.15, 0.55),
    ("autocomplete", 5.55, 0.55),
    ("dictation", 7.2, 0.45),
    ("agent", 5.2, 0.55),
    ("timeline", 5.3, 0.5),
    ("endcard", 8.0, 0),
]

VOICE = {
    "call": [("01-call", 11, 0.35)],
    "notes": [("02-notes", 11, 0.25)],
    "search": [("03-search", 11, 0.2)],
    "autocomplete": [("04-type", 29, 0.2)],
    "dictation": [("05-say", 11, 0.1), ("request", 11, 1.17)],
    "agent": [("06-agent", 11, 0.55)],
    "timeline": [("07-day", 29, 0.4)],
    "endcard": [("08-end", 11, 0.62)],
}

PEAK = {
    "pop": 0.119,
    "click-soft": 0.072,
    "whoosh-short": 0.162,
    "whoosh": 0.162,
    "key-press": 0.077,
    "impact-bass-1": 0.073,
}
LENGTH = {
    "pop": 0.72,
    "click-soft": 0.37,
    "whoosh-short": 0.57,
    "whoosh": 0.57,
    "key-press": 0.4,
    "impact-bass-1": 2.12,
}
EFFECTS = {
    "call": [("mark", "pop", 3.65, 0.25)],
    "notes": [("click", "click-soft", 3.295, 0.5)],
    "search": [("panel", "whoosh-short", 0.07, 0.3)]
              + [(f"down-{i}", "key-press", at, 0.3) for i, at in enumerate([2.08, 2.56, 3.05, 3.53], 1)]
              + [("swipe", "whoosh", 5.40, 0.3)],
    "autocomplete": [(f"tab-{i}", "key-press", at, 0.35)
                     for i, at in enumerate([2.508, 2.82, 3.14, 3.45, 3.77, 4.08, 4.40], 1)]
                    + [("page", "whoosh-short", 5.8, 0.22)],
    "dictation": [("flood", "whoosh-short", 7.4, 0.3)],
    "agent": [("return", "key-press", 2.05, 0.35)],
    "timeline": [("swipe-day", "whoosh", 0.25, 0.3), ("click-day", "click-soft", 1.23, 0.5)],
    "endcard": [("lockup", "impact-bass-1", 0.68, 0.3)],
}
TYPING = {
    "search": [("type-search", 0.476, 0.78)],
    "autocomplete": [("type-doc", 0.47, 0.95)],
    "agent": [("type-agent", 0.75, 1.05)],
}
VOICE_GAIN = {
    "01-call": 0.99,
    "02-notes": 1.02,
    "03-search": 0.83,
    "04-type": 0.87,
    "05-say": 0.62,
    "06-agent": 0.78,
    "07-day": 0.81,
    "08-end": 0.95,
    "request": 0.83,
}

FORMATS = {
    "16:9": {"width": 1920, "height": 1080},
    "4:5": {
        "width": 1080,
        "height": 1350,
        "header_top": 46,
        "headline_top": 122,
        "headline_size": 46,
        "stage_left": 32,
        "stage_top": 258,
        "stage_w": 1016,
        "stage_h": 572,
        "scale": 1016 / 1920,
        "progress_top": 848,
        "caption_top": 886,
        "caption_height": 340,
        "caption_left": 48,
        "caption_width": 984,
        "caption_font": 46,
        "footer_top": 1272,
    },
    "9:16": {
        "width": 1080,
        "height": 1920,
        "header_top": 152,
        "headline_top": 236,
        "headline_size": 52,
        "stage_left": 28,
        "stage_top": 424,
        "stage_w": 1024,
        "stage_h": 576,
        "scale": 1024 / 1920,
        "progress_top": 1022,
        "caption_top": 1074,
        "caption_height": 420,
        "caption_left": 56,
        "caption_width": 888,
        "caption_font": 48,
        "footer_top": 1554,
    },
}

ICON_SVG = (
    '<svg class="brand-icon" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">'
    '<defs>'
    '<linearGradient id="sb-bg" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#222e3d" /><stop offset="1" stop-color="#0e141c" />'
    '</linearGradient>'
    '<linearGradient id="sb-body" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#6ef2dc" /><stop offset="1" stop-color="#23c4ae" />'
    '</linearGradient>'
    '</defs>'
    '<rect x="64" y="64" width="896" height="896" rx="204" fill="url(#sb-bg)" />'
    '<rect x="372" y="206" width="36" height="86" rx="18" fill="#3a7d72" />'
    '<circle cx="390" cy="186" r="42" fill="#fbbf24" />'
    '<rect x="268" y="276" width="244" height="484" rx="62" fill="url(#sb-body)" />'
    '<rect x="268" y="592" width="492" height="168" rx="62" fill="url(#sb-body)" />'
    '<rect x="312" y="326" width="156" height="118" rx="38" fill="#0e141c" />'
    '<circle cx="390" cy="385" r="34" fill="#6ef2dc" />'
    '<circle cx="402" cy="373" r="10" fill="#eafffa" />'
    '<rect x="206" y="430" width="44" height="180" rx="22" fill="#3a7d72" />'
    '<g fill="#0e141c">'
    '<rect x="556" y="646" width="26" height="60" rx="13" />'
    '<rect x="602" y="624" width="26" height="104" rx="13" />'
    '<rect x="648" y="638" width="26" height="76" rx="13" />'
    '<rect x="694" y="654" width="26" height="44" rx="13" />'
    '</g></svg>'
)


def speech_end(path, fallback_duration):
    if not path.exists():
        return max(0.2, fallback_duration - 0.15)
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(path), "-ac", "1", "-ar", "8000", "-f", "s16le", "-"],
        check=True,
        capture_output=True,
    ).stdout
    samples = struct.unpack(f"<{len(raw) // 2}h", raw)
    floor = max(abs(s) for s in samples) * 0.03
    last = max(i for i, s in enumerate(samples) if abs(s) > floor)
    return last / 8000


def aligned_words(row, fallback_text):
    alignment = row.get("alignment") if row else None
    if not alignment:
        tokens = fallback_text.split()
        duration = float(row["duration"]) if row else 3.0
        step = duration / max(1, len(tokens))
        return [(tok, round(i * step, 3), round((i + 1) * step, 3)) for i, tok in enumerate(tokens)]
    chars = alignment["characters"]
    starts = alignment["character_start_times_seconds"]
    ends = alignment["character_end_times_seconds"]
    words = []
    cur = []
    w_start = None
    w_end = None
    for ch, st, en in zip(chars, starts, ends):
        if ch.isspace():
            if cur:
                words.append(("".join(cur), float(w_start), float(w_end)))
                cur = []
                w_start = None
                w_end = None
        else:
            if w_start is None:
                w_start = st
            cur.append(ch)
            w_end = en
    if cur:
        words.append(("".join(cur), float(w_start), float(w_end)))
    return words


def chunk_phrases(words, base_start, tag=None, max_words=5, max_chars=28):
    phrases = []
    bucket = []
    char_count = 0
    for word, st, en in words:
        abs_st = round(base_start + st, 3)
        abs_en = round(base_start + en, 3)
        projected = char_count + len(word) + (1 if bucket else 0)
        if bucket and (len(bucket) >= max_words or projected > max_chars):
            phrases.append({"tag": tag, "words": bucket})
            bucket = []
            char_count = 0
        bucket.append({"text": word, "start": abs_st, "end": max(abs_en, round(abs_st + 0.08, 3))})
        char_count += len(word) + (1 if len(bucket) > 1 else 0)
        if word.endswith((".", "!", "?", ",")) and len(bucket) >= 2:
            phrases.append({"tag": tag, "words": bucket})
            bucket = []
            char_count = 0
    if bucket:
        phrases.append({"tag": tag, "words": bucket})
    for p in phrases:
        p["start"] = p["words"][0]["start"]
        p["end"] = round(p["words"][-1]["end"] + 0.22, 3)
    return phrases


def build_captions(starts, narration_data, generation_rows, total):
    text_by_id = {}
    for entry in narration_data.get("lines", []) + narration_data.get("spoken", []):
        text_by_id[entry["id"]] = entry["text"]
    phrases = []
    for scene, _, _ in SCENES:
        for line_id, seed, local in VOICE.get(scene, []):
            row = generation_rows.get((line_id, seed))
            abs_base = starts[scene] + local
            words = aligned_words(row, text_by_id.get(line_id, ""))
            tag = "DICTATED LIVE" if line_id == "request" else None
            phrases.extend(chunk_phrases(words, abs_base, tag=tag))
    phrases.sort(key=lambda p: p["start"])
    for idx, phrase in enumerate(phrases):
        if idx + 1 < len(phrases):
            next_start = phrases[idx + 1]["start"]
            phrase["end"] = min(phrase["end"], round(max(phrase["start"] + 0.1, next_start - 0.02), 3))
        else:
            phrase["end"] = min(phrase["end"], total)
    return phrases


def render_caption_markup(phrases):
    blocks = []
    for p_idx, phrase in enumerate(phrases):
        tag_html = f'<div class="cap-tag">{html.escape(phrase["tag"])}</div>' if phrase.get("tag") else ""
        spans = " ".join(
            f'<span class="cap-word" id="cap-w-{p_idx}-{w_idx}">{html.escape(w["text"])}</span>'
            for w_idx, w in enumerate(phrase["words"])
        )
        blocks.append(f'        <div class="cap-phrase" id="cap-p-{p_idx}">{tag_html}<div class="cap-line">{spans}</div></div>')
    return "\n".join(blocks)


def render_caption_script(phrases, is_social, total):
    payload = json.dumps(phrases)
    lines = [
        f"      const tl = gsap.timeline({{ paused: true }});",
        f"      const CAPTIONS = {payload};",
        '      gsap.set(".cap-phrase", { opacity: 0 });',
        "      CAPTIONS.forEach((phrase, pIdx) => {",
        "        const pSel = `#cap-p-${pIdx}`;",
        "        tl.set(pSel, { opacity: 1 }, phrase.start);",
        "        phrase.words.forEach((word, wIdx) => {",
        "          const wSel = `#cap-w-${pIdx}-${wIdx}`;",
        "          const nextWord = phrase.words[wIdx + 1];",
        "          const clearAt = nextWord ? nextWord.start : phrase.end;",
        '          tl.set(wSel, { backgroundColor: "#fbbf24", color: "#0e141c" }, word.start);',
        '          tl.set(wSel, { backgroundColor: "transparent", color: "#f2f7f5" }, clearAt);',
        "        });",
        "        tl.set(pSel, { opacity: 0 }, phrase.end);",
        "      });",
    ]
    if is_social:
        lines.append(
            f'      tl.fromTo("#social-progress-fill", {{ scaleX: 0 }}, {{ scaleX: 1, duration: {total:g}, ease: "none" }}, 0);'
        )
    lines.extend([
        f"      tl.set({{}}, {{}}, {total:g});",
        '      window.__timelines["main"] = tl;',
        "      tl.seek(0);",
    ])
    return "\n".join(lines)


def build_html(fmt, with_captions):
    spec = FORMATS[fmt]
    width = spec["width"]
    height = spec["height"]
    is_social = fmt != "16:9"

    narration_data = json.loads((HERE / "voice/narration.json").read_text(encoding="utf-8"))
    gen_rows = {
        (row["id"], row["seed"]): row
        for row in json.loads((HERE / "voice/generation.json").read_text(encoding="utf-8"))["rows"]
    }

    starts, at = {}, 0.0
    for scene, slot, _ in SCENES:
        starts[scene] = round(at, 3)
        at += slot
    total = round(at, 3)
    backdrop = {"floodAt": starts["agent"], "exitAt": starts["endcard"], "length": total}

    extra_css = ""
    if is_social:
        extra_css = f"""
      #social-shell {{
        position: absolute;
        inset: 0;
        background: radial-gradient(120% 55% at 50% 0%, #172736 0%, #0e151d 60%);
        font-family: Inter, -apple-system, BlinkMacSystemFont, sans-serif;
        color: #f2f7f5;
      }}
      #social-header {{
        position: absolute;
        left: {spec['caption_left']}px;
        top: {spec['header_top']}px;
        width: {width - spec['caption_left'] * 2}px;
        display: flex;
        align-items: center;
        justify-content: space-between;
      }}
      .brand-lockup {{
        display: flex;
        align-items: center;
        gap: 14px;
      }}
      .brand-icon {{
        width: 54px;
        height: 54px;
        border-radius: 13px;
        box-shadow: 0 0 0 1.5px rgba(242, 247, 245, 0.2);
      }}
      .brand-name {{
        font-size: 36px;
        font-weight: 900;
        letter-spacing: -0.04em;
        color: #f2f7f5;
      }}
      .brand-pill {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 19px;
        font-weight: 700;
        letter-spacing: 0.06em;
        color: #6ef2dc;
        background: rgba(35, 196, 174, 0.14);
        border: 1.5px solid rgba(110, 242, 220, 0.38);
        border-radius: 999px;
        padding: 8px 18px;
      }}
      #social-headline {{
        position: absolute;
        left: {spec['caption_left']}px;
        top: {spec['headline_top']}px;
        width: {width - spec['caption_left'] * 2}px;
        font-size: {spec['headline_size']}px;
        font-weight: 900;
        letter-spacing: -0.035em;
        line-height: 1.12;
        color: #f2f7f5;
      }}
      #social-headline b {{
        color: #0e141c;
        background: #fbbf24;
        border-radius: 10px;
        padding: 1px 12px 3px;
      }}
      #stage-frame {{
        position: absolute;
        left: {spec['stage_left']}px;
        top: {spec['stage_top']}px;
        width: {spec['stage_w']}px;
        height: {spec['stage_h']}px;
        border-radius: 24px;
        overflow: hidden;
        background: #0e151d;
        box-shadow: 0 28px 72px rgba(0, 0, 0, 0.55), 0 0 0 2px rgba(110, 242, 220, 0.24);
      }}
      #stage-scale {{
        position: absolute;
        left: 0;
        top: 0;
        width: 1920px;
        height: 1080px;
        transform: scale({spec['scale']:.7f});
        transform-origin: 0 0;
      }}
      #social-progress {{
        position: absolute;
        left: {spec['stage_left']}px;
        top: {spec['progress_top']}px;
        width: {spec['stage_w']}px;
        height: 6px;
        border-radius: 999px;
        background: rgba(234, 255, 250, 0.16);
        overflow: hidden;
      }}
      #social-progress-fill {{
        width: 100%;
        height: 100%;
        background: linear-gradient(90deg, #23c4ae, #6ef2dc, #fbbf24);
        transform-origin: 0 50%;
      }}
      #social-captions {{
        position: absolute;
        left: {spec['caption_left']}px;
        top: {spec['caption_top']}px;
        width: {spec['caption_width']}px;
        height: {spec['caption_height']}px;
        display: flex;
        align-items: center;
        justify-content: center;
      }}
      .cap-phrase {{
        position: absolute;
        left: 0;
        right: 0;
        top: 50%;
        margin-top: -86px;
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 14px;
        text-align: center;
      }}
      .cap-tag {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 20px;
        font-weight: 700;
        letter-spacing: 0.08em;
        color: #fbbf24;
        background: rgba(251, 191, 36, 0.16);
        border: 1.5px solid rgba(251, 191, 36, 0.5);
        border-radius: 999px;
        padding: 4px 16px;
      }}
      .cap-line {{
        display: flex;
        flex-wrap: wrap;
        justify-content: center;
        gap: 8px 10px;
        font-family: Inter, -apple-system, BlinkMacSystemFont, sans-serif;
        font-size: {spec['caption_font']}px;
        font-weight: 800;
        letter-spacing: -0.025em;
        line-height: 1.28;
      }}
      .cap-word {{
        color: #b7cec9;
        padding: 4px 12px 6px;
        border-radius: 12px;
      }}
      #social-footer {{
        position: absolute;
        left: {spec['caption_left']}px;
        top: {spec['footer_top']}px;
        width: {width - spec['caption_left'] * 2}px;
        display: flex;
        justify-content: space-between;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 22px;
        font-weight: 600;
        color: #9ec5be;
      }}
"""
    elif with_captions:
        extra_css = """
      #social-captions {
        position: absolute;
        left: 160px;
        bottom: 42px;
        width: 1600px;
        height: 124px;
        z-index: 90;
        pointer-events: none;
      }
      .cap-phrase {
        position: absolute;
        left: 0;
        right: 0;
        bottom: 0;
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 8px;
      }
      .cap-tag {
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 18px;
        font-weight: 700;
        letter-spacing: 0.08em;
        color: #fbbf24;
        background: rgba(14, 21, 29, 0.92);
        border: 1.5px solid rgba(251, 191, 36, 0.55);
        border-radius: 999px;
        padding: 3px 14px;
      }
      .cap-line {
        display: inline-flex;
        flex-wrap: wrap;
        justify-content: center;
        gap: 6px 8px;
        background: rgba(14, 21, 29, 0.9);
        border: 1.5px solid rgba(110, 242, 220, 0.3);
        border-radius: 18px;
        padding: 12px 22px;
        font-family: Inter, -apple-system, BlinkMacSystemFont, sans-serif;
        font-size: 38px;
        font-weight: 800;
        letter-spacing: -0.02em;
        line-height: 1.25;
      }
      .cap-word {
        color: #b7cec9;
        padding: 2px 9px 4px;
        border-radius: 8px;
      }
"""

    scene_divs = [
        '        <div id="backdrop" data-composition-id="backdrop" data-composition-src="compositions/backdrop.html"\n'
        f'          data-start="0" data-duration="{total:g}" data-track-index="1" data-track-kind="graphics"\n'
        f"          data-variable-values='{json.dumps(backdrop)}'\n"
        '          data-width="1920" data-height="1080" style="z-index: 1"></div>\n'
    ]
    for index, (scene, slot, tail) in enumerate(SCENES):
        scene_divs.append(
            f'        <div id="{scene}" data-composition-id="{scene}" data-composition-src="compositions/{scene}.html"\n'
            f'          data-start="{starts[scene]:g}" data-duration="{round(slot + tail, 3):g}" '
            f'data-track-index="{index + 2}" data-track-kind="graphics"\n'
            f'          data-width="1920" data-height="1080" style="z-index: {index + 10}"></div>\n'
        )

    audio_tags = []
    spoken = 0
    for scene, _, _ in SCENES:
        for line, seed, local in VOICE.get(scene, []):
            file = f"assets/voice/{line}-s{seed}.mp3"
            row = gen_rows.get((line, seed))
            fallback_dur = float(row["duration"]) if row else 4.0
            length = round(speech_end(HERE / file, fallback_dur) + 0.2, 2)
            spoken += 1
            audio_tags.append(
                f'      <audio id="voice-{line}" class="clip" data-start="{round(starts[scene] + local, 3):g}" '
                f'data-duration="{length:g}" data-track-index="{19 + spoken % 2}" data-volume="{VOICE_GAIN[line]:g}" '
                f'src="{file}"></audio>\n'
            )
    track = 0
    for scene, _, _ in SCENES:
        for name, file, local, volume in EFFECTS.get(scene, []):
            start = round(starts[scene] + local + 1 / 30 - PEAK[file], 3)
            track += 1
            audio_tags.append(
                f'      <audio id="sfx-{name}" class="clip" data-start="{start:g}" data-duration="{LENGTH[file]:g}" '
                f'data-track-index="{21 + track % 2}" data-volume="{volume:g}" src="assets/sfx/{file}.mp3"></audio>\n'
            )
        for name, local, seconds in TYPING.get(scene, []):
            audio_tags.append(
                f'      <audio id="sfx-{name}" class="clip" data-start="{round(starts[scene] + local, 3):g}" '
                f'data-duration="{seconds:g}" data-track-index="23" data-volume="0.35" data-media-start="0.45" '
                'data-fade-out="0.08" src="assets/sfx/typing.mp3"></audio>\n'
            )

    phrases = build_captions(starts, narration_data, gen_rows, total) if with_captions else []

    out = [
        f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width={width}, height={height}" />
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
      * {{
        margin: 0;
        padding: 0;
        box-sizing: border-box;
      }}
      html,
      body {{
        margin: 0;
        width: {width}px;
        height: {height}px;
        overflow: hidden;
        background: #0e151d;
      }}{extra_css}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{total:g}" data-width="{width}" data-height="{height}">
"""
    ]

    if is_social:
        out.append(
            f"""      <div id="social-shell" data-layout-allow-overflow>
        <div id="social-header">
          <div class="brand-lockup">{ICON_SVG}<span class="brand-name">LokalBot</span></div>
          <div class="brand-pill">LOCAL · NO MEETING BOT</div>
        </div>
        <div id="social-headline">One decision, <b>everywhere</b> you need it</div>
        <div id="stage-frame" data-layout-allow-overflow>
          <div id="stage-scale" data-layout-allow-overflow>
{''.join(scene_divs)}          </div>
        </div>
        <div id="social-progress" data-layout-ignore><div id="social-progress-fill"></div></div>
        <div id="social-captions" data-layout-allow-overflow>
{render_caption_markup(phrases)}
        </div>
        <div id="social-footer"><span>lokalbot.com</span><span>Local by default · GPLv3</span></div>
      </div>
"""
        )
    else:
        out.extend(scene_divs)
        if with_captions:
            out.append(
                f"""      <div id="social-captions" data-layout-allow-overflow>
{render_caption_markup(phrases)}
      </div>
"""
            )

    out.append("\n")
    out.extend(audio_tags)

    if with_captions or is_social:
        script_body = render_caption_script(phrases, is_social, total)
    else:
        script_body = (
            f"      const tl = gsap.timeline({{ paused: true }});\n"
            f"      tl.set({{}}, {{}}, {total:g});\n"
            '      window.__timelines["main"] = tl;\n'
            "      tl.seek(0);"
        )

    out.append(
        f"""    </div>
    <script>
{script_body}
    </script>
  </body>
</html>
"""
    )
    return "".join(out), total, starts


def main():
    parser = argparse.ArgumentParser(description="Build LokalBot One Decision HyperFrames composition.")
    parser.add_argument("--format", choices=["16:9", "4:5", "9:16"], default="16:9")
    parser.add_argument("--captions", dest="captions", action="store_true", default=None)
    parser.add_argument("--no-captions", dest="captions", action="store_false")
    parser.add_argument("--out", type=Path, default=HERE / "index.html")
    args = parser.parse_args()
    if args.out.resolve().parent != HERE.resolve():
        parser.error(f"--out must name a file in {HERE}, because the composition's asset paths are relative to it")
    with_captions = (args.format != "16:9") if args.captions is None else args.captions
    content, total, starts = build_html(args.format, with_captions)
    args.out.write_text(content, encoding="utf-8")
    print(f"{args.format} captions={with_captions} {total:g} s -> {args.out}")
    for scene, _, _ in SCENES:
        print(f"  {starts[scene]:6.2f}  {scene}")


if __name__ == "__main__":
    main()
