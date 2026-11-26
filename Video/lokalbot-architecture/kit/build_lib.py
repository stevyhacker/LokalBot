#!/usr/bin/env python3
"""Shared by the three architecture films' build.py: writes index.html and voice timings into scenes.

Supports 16:9 master plus 4:5 (1080x1350) and 9:16 (1080x1920) captioned social framing.
"""
import copy
import html
import json
import math
import re
import shutil
import struct
import subprocess
from pathlib import Path

KIT = Path(__file__).resolve().parent
FPS = 30

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
SPEECH_LEVEL = -21.0
PEAK_CEILING = -1.4

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
    '<linearGradient id="ab-bg" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#222e3d" /><stop offset="1" stop-color="#0e141c" />'
    '</linearGradient>'
    '<linearGradient id="ab-body" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#6ef2dc" /><stop offset="1" stop-color="#23c4ae" />'
    '</linearGradient>'
    '</defs>'
    '<rect x="64" y="64" width="896" height="896" rx="204" fill="url(#ab-bg)" />'
    '<rect x="372" y="206" width="36" height="86" rx="18" fill="#3a7d72" />'
    '<circle cx="390" cy="186" r="42" fill="#fbbf24" />'
    '<rect x="268" y="276" width="244" height="484" rx="62" fill="url(#ab-body)" />'
    '<rect x="268" y="592" width="492" height="168" rx="62" fill="url(#ab-body)" />'
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

CUE_BLOCK = re.compile(r"/\* cues:begin \*/.*?/\* cues:end \*/", re.S)
KIT_BLOCK = re.compile(r"/\* kit:begin \*/.*?/\* kit:end \*/", re.S)


class Cues:
    """A scene's timings, for the effects table: the same L, E and W the scene's script gets."""

    def __init__(self, length, lines):
        self.LEN = length
        self.lines = lines

    def L(self, line):
        return self.lines[line]["start"]

    def E(self, line):
        return self.lines[line]["end"]

    def W(self, line, word, nth=1):
        hits = [at for said, at in self.lines[line]["words"] if said == word.lower()]
        if len(hits) < nth:
            raise SystemExit(f"no cue {line}/{word}")
        return hits[nth - 1]


def frames(seconds):
    """Up to the next whole frame, so scenes meet on a frame."""
    return math.ceil(round(seconds * FPS, 4)) / FPS


def measure(path, fallback_duration):
    """(seconds to the last sound, gain to the shared speech level) for one take."""
    if not path.exists():
        return max(0.2, fallback_duration - 0.15), 0.9
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(path), "-ac", "1", "-ar", "8000", "-f", "s16le", "-"],
        check=True,
        capture_output=True,
    ).stdout
    data = struct.unpack(f"<{len(raw) // 2}h", raw)
    peak = max(abs(s) for s in data) or 1
    floor = peak * 0.03
    first = next(i for i, s in enumerate(data) if abs(s) > floor)
    last = max(i for i, s in enumerate(data) if abs(s) > floor)
    rms = math.sqrt(sum(s * s for s in data[first:last + 1]) / max(1, last - first + 1))
    gain_db = min(SPEECH_LEVEL - 20 * math.log10(rms / 32768), PEAK_CEILING - 20 * math.log10(peak / 32768), 0.0)
    return last / 8000, round(10 ** (gain_db / 20), 2)


def spoken_words(row):
    """[(word, seconds into the take)], lower-cased, punctuation at either end dropped."""
    alignment = row["alignment"]
    out, current, begun = [], "", None
    for char, start in zip(alignment["characters"], alignment["character_start_times_seconds"]):
        if char.isspace():
            if current:
                out.append((current, begun))
            current, begun = "", None
        else:
            if begun is None:
                begun = start
            current += char
    if current:
        out.append((current, begun))
    clean = [(re.sub(r"^\W+|\W+$", "", word.lower()), at) for word, at in out]
    return [(word, at) for word, at in clean if word]


def caption_words(row):
    """[(original_word, start_s, end_s)] from character alignment."""
    alignment = row["alignment"]
    chars = alignment["characters"]
    starts = alignment["character_start_times_seconds"]
    ends = alignment["character_end_times_seconds"]
    out = []
    cur = []
    w_start = None
    w_end = None
    for ch, st, en in zip(chars, starts, ends):
        if ch.isspace():
            if cur:
                out.append(("".join(cur), float(w_start), float(w_end)))
                cur = []
                w_start = None
                w_end = None
        else:
            if w_start is None:
                w_start = st
            cur.append(ch)
            w_end = en
    if cur:
        out.append(("".join(cur), float(w_start), float(w_end)))
    return out


def chunk_phrases(words, base_start, max_words=5, max_chars=28):
    phrases = []
    bucket = []
    char_count = 0
    for word, st, en in words:
        abs_st = round(base_start + st, 3)
        abs_en = round(base_start + en, 3)
        projected = char_count + len(word) + (1 if bucket else 0)
        if bucket and (len(bucket) >= max_words or projected > max_chars):
            phrases.append({"words": bucket})
            bucket = []
            char_count = 0
        bucket.append({"text": word, "start": abs_st, "end": max(abs_en, round(abs_st + 0.08, 3))})
        char_count += len(word) + (1 if len(bucket) > 1 else 0)
        if word.endswith((".", "!", "?", ",")) and len(bucket) >= 2:
            phrases.append({"words": bucket})
            bucket = []
            char_count = 0
    if bucket:
        phrases.append({"words": bucket})
    for p in phrases:
        p["start"] = p["words"][0]["start"]
        p["end"] = round(p["words"][-1]["end"] + 0.22, 3)
    return phrases


def build_captions(scenes, rows, total):
    phrases = []
    for scene in scenes:
        if scene.get("span") == "film":
            continue
        for line, seed, _ in scene.get("lines", []):
            cue = scene["cues"][line]
            row = rows[(line, seed)]
            abs_base = scene["start"] + cue["start"]
            phrases.extend(chunk_phrases(caption_words(row), abs_base))
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
        spans = " ".join(
            f'<span class="cap-word" id="cap-w-{p_idx}-{w_idx}">{html.escape(w["text"])}</span>'
            for w_idx, w in enumerate(phrase["words"])
        )
        blocks.append(f'        <div class="cap-phrase" id="cap-p-{p_idx}"><div class="cap-line">{spans}</div></div>')
    return "\n".join(blocks)


def render_caption_script(phrases, is_social, total):
    payload = json.dumps(phrases)
    lines = [
        "      const tl = gsap.timeline({ paused: true });",
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
        '          tl.set(wSel, { backgroundColor: "transparent", color: "#eafffa" }, clearAt);',
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


def place(film, scenes):
    """Give every scene its start, slot and cues. Returns (film length, rows)."""
    rows = {(row["id"], row["seed"]): row for row in json.loads((film / "voice/generation.json").read_text())["rows"]}
    at = 0.0
    for scene in scenes:
        if scene.get("span") == "film":
            continue
        scene["start"] = round(at, 4)
        clock = scene.get("lead", 0.4)
        scene["cues"] = {}
        for line, seed, pause in scene.get("lines", []):
            file = f"assets/voice/{line}-s{seed}.mp3"
            last, gain = measure(film / file, float(rows[(line, seed)]["duration"]))
            clock += pause
            scene["cues"][line] = {
                "start": round(clock, 3),
                "end": round(clock + last, 3),
                "file": file,
                "gain": gain,
                "clip": round(min(last + 0.2, rows[(line, seed)]["duration"]), 2),
                "words": [[word, round(clock + said, 3)] for word, said in spoken_words(rows[(line, seed)])],
            }
            clock += last
        slot = frames(scene["length"] if "length" in scene else clock + scene.get("tail", 0.5))
        scene["slot"] = slot
        scene["duration"] = round(slot + scene.get("overlap", 0), 4)
        at += slot
    total = round(at, 4)
    for scene in scenes:
        if scene.get("span") == "film":
            scene["start"], scene["slot"], scene["duration"] = 0.0, total, total
            scene["cues"] = {}
            for other in scenes:
                if other.get("span") == "film":
                    continue
                for line, cue in other["cues"].items():
                    shift = other["start"]
                    scene["cues"][line] = {
                        **cue,
                        "start": round(cue["start"] + shift, 3),
                        "end": round(cue["end"] + shift, 3),
                        "words": [[word, round(said + shift, 3)] for word, said in cue["words"]],
                    }
    return total, rows


def cue_script(scene):
    data = {
        "length": scene["duration"],
        "slot": scene["slot"],
        "lines": {
            line: {"start": cue["start"], "end": cue["end"], "words": cue["words"]}
            for line, cue in scene["cues"].items()
        },
    }
    return (
        "/* cues:begin */\n"
        f"    const CUES = {json.dumps(data)};\n"
        "    const LEN = CUES.length;\n"
        "    const SLOT = CUES.slot;\n"
        "    const L = (id) => CUES.lines[id].start;\n"
        "    const E = (id) => CUES.lines[id].end;\n"
        "    const W = (id, word, nth = 1) => {\n"
        "      const hits = CUES.lines[id].words.filter((said) => said[0] === word.toLowerCase());\n"
        "      if (hits.length < nth) throw new Error(`no cue ${id}/${word}`);\n"
        "      return hits[nth - 1][1];\n"
        "    };\n"
        "    gsap.config({ force3D: false });\n"
        "    /* cues:end */"
    )


def inject(film, scene):
    path = film / f"compositions/{scene['id']}.html"
    if scene.get("kit"):
        shutil.copyfile(KIT / f"{scene['id']}.html", path)
    text = path.read_text(encoding="utf-8")
    if not CUE_BLOCK.search(text):
        raise SystemExit(f"{path.name}: no /* cues:begin */ /* cues:end */ block in its script")
    text = CUE_BLOCK.sub(lambda _: cue_script(scene), text, count=1)
    if KIT_BLOCK.search(text):
        kit = "/* kit:begin */\n" + (KIT / "kit.css").read_text(encoding="utf-8").rstrip() + "\n    /* kit:end */"
        text = KIT_BLOCK.sub(lambda _: kit, text, count=1)
    path.write_text(text, encoding="utf-8")


def build(
    film,
    ground,
    scenes,
    fmt="16:9",
    with_captions=None,
    social_badge="5 LOCAL MODELS · UNDER 10 GB",
    social_headline="Five local AI models, <b>taking turns</b> on one Mac",
    out_path=None,
):
    film = Path(film)
    scenes = copy.deepcopy(scenes)
    spec = FORMATS[fmt]
    width = spec["width"]
    height = spec["height"]
    is_social = fmt != "16:9"
    use_captions = is_social if with_captions is None else with_captions

    total, rows = place(film, scenes)
    for scene in scenes:
        inject(film, scene)

    extra_css = ""
    if is_social:
        extra_css = f"""
      #social-shell {{
        position: absolute;
        inset: 0;
        background: radial-gradient(120% 55% at 50% 0%, #1c4c45 0%, #0e2623 62%, #0a1b19 100%);
        font-family: Inter, -apple-system, BlinkMacSystemFont, sans-serif;
        color: #eafffa;
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
        box-shadow: 0 0 0 1.5px rgba(234, 255, 250, 0.22);
      }}
      .brand-name {{
        font-size: 36px;
        font-weight: 900;
        letter-spacing: -0.04em;
        color: #eafffa;
      }}
      .brand-pill {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 19px;
        font-weight: 700;
        letter-spacing: 0.06em;
        color: #6ef2dc;
        background: rgba(14, 21, 29, 0.72);
        border: 1.5px solid rgba(110, 242, 220, 0.4);
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
        color: #eafffa;
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
        background: {ground};
        box-shadow: 0 28px 72px rgba(0, 0, 0, 0.55), 0 0 0 2px rgba(110, 242, 220, 0.28);
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
        margin-top: -78px;
        display: flex;
        flex-direction: column;
        align-items: center;
        text-align: center;
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
        color: #a9d1c9;
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
    elif use_captions:
        extra_css = """
      #social-captions {
        position: absolute;
        left: 160px;
        bottom: 42px;
        width: 1600px;
        height: 112px;
        z-index: 90;
        pointer-events: none;
      }
      .cap-phrase {
        position: absolute;
        left: 0;
        right: 0;
        bottom: 0;
        display: flex;
        justify-content: center;
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
        color: #a9d1c9;
        padding: 2px 9px 4px;
        border-radius: 8px;
      }
"""

    scene_divs = []
    for index, scene in enumerate(scenes):
        variables = ""
        if scene.get("variables"):
            variables = f"\n          data-variable-values='{json.dumps(scene['variables'])}'"
        scene_divs.append(
            f'        <div id="{scene["id"]}" data-composition-id="{scene["id"]}" '
            f'data-composition-src="compositions/{scene["id"]}.html"\n'
            f'          data-start="{scene["start"]:g}" data-duration="{scene["duration"]:g}" '
            f'data-track-index="{index + 1}" data-track-kind="graphics"{variables}\n'
            f'          data-width="1920" data-height="1080" style="z-index: {scene.get("z", index + 10)}"></div>\n'
        )

    audio_tags = []
    spoken = 0
    for scene in scenes:
        if scene.get("span") == "film":
            continue
        for line, cue in scene["cues"].items():
            spoken += 1
            audio_tags.append(
                f'      <audio id="voice-{line}" class="clip" data-start="{round(scene["start"] + cue["start"], 3):g}" '
                f'data-duration="{cue["clip"]:g}" data-track-index="{40 + spoken % 2}" data-volume="{cue["gain"]:g}" '
                f'src="{cue["file"]}"></audio>\n'
            )
    track = 0
    for scene in scenes:
        cues = Cues(scene["duration"], scene["cues"])
        for name, file, when, volume in scene.get("effects", []):
            local = when(cues) if callable(when) else when
            start = round(scene["start"] + local + 1 / FPS - PEAK[file], 3)
            track += 1
            audio_tags.append(
                f'      <audio id="sfx-{name}" class="clip" data-start="{max(start, 0):g}" data-duration="{LENGTH[file]:g}" '
                f'data-track-index="{42 + track % 2}" data-volume="{volume:g}" src="assets/sfx/{file}.mp3"></audio>\n'
            )
        for name, when, seconds, volume in scene.get("loops", []):
            local = when(cues) if callable(when) else when
            audio_tags.append(
                f'      <audio id="sfx-{name}" class="clip" data-start="{round(scene["start"] + local, 3):g}" '
                f'data-duration="{seconds:g}" data-track-index="44" data-volume="{volume:g}" data-media-start="0.45" '
                'data-fade-out="0.08" src="assets/sfx/typing.mp3"></audio>\n'
            )

    phrases = build_captions(scenes, rows, total) if use_captions else []

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
        background: {ground};
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
          <div class="brand-pill">{html.escape(social_badge)}</div>
        </div>
        <div id="social-headline">{social_headline}</div>
        <div id="stage-frame" data-layout-allow-overflow>
          <div id="stage-scale" data-layout-allow-overflow>
{''.join(scene_divs)}          </div>
        </div>
        <div id="social-progress" data-layout-ignore><div id="social-progress-fill"></div></div>
        <div id="social-captions" data-layout-allow-overflow>
{render_caption_markup(phrases)}
        </div>
        <div id="social-footer"><span>lokalbot.com</span><span>v0.14.0 Apache-2.0 fine-tunes · GPLv3</span></div>
      </div>
"""
        )
    else:
        out.extend(scene_divs)
        if use_captions:
            out.append(
                f"""      <div id="social-captions" data-layout-allow-overflow>
{render_caption_markup(phrases)}
      </div>
"""
            )

    out.append("\n")
    out.extend(audio_tags)

    if use_captions or is_social:
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

    target = Path(out_path) if out_path else (film / "index.html")
    target.write_text("".join(out), encoding="utf-8")

    report = [f"{total:g} s ({fmt}, captions={use_captions})"]
    for scene in scenes:
        report.append(f"\n{scene['id']}: starts {scene['start']:g}, slot {scene['slot']:g}, host {scene['duration']:g}")
        for line, cue in scene["cues"].items():
            words = "  ".join(f"{word}@{said:g}" for word, said in cue["words"])
            report.append(
                f"  {line}  {cue['start']:6.2f} to {cue['end']:6.2f}  "
                f"(film {scene['start'] + cue['start']:6.2f})  gain {cue['gain']:g}"
            )
            report.append(f"      {words}")
    (film / "cues.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(line for line in report if not line.startswith("      ")))
    return total
