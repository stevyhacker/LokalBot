#!/usr/bin/env python3
"""Build a 30-second seek-safe HyperFrames clip comparing cloud STT hallucinations vs Qwen3-ASR v3.

    python3 build.py --format 4:5
    python3 build.py --format 9:16
"""
import argparse
import html
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
DURATION = 30.0

FORMATS = {
    "4:5": {
        "width": 1080,
        "height": 1350,
        "pad_x": 52,
        "top_header": 44,
        "stage_top": 122,
        "stage_height": 890,
        "caption_top": 1044,
        "caption_height": 208,
        "caption_width": 976,
        "caption_font": 42,
        "footer_top": 1280,
        "hook_size": 92,
        "split_gap": 24,
        "split_card_h": 374,
        "bar_row_gap": 15,
        "bar_h": 30,
        "stat_gap": 22,
        "end_top": 148,
    },
    "9:16": {
        "width": 1080,
        "height": 1920,
        "pad_x": 56,
        "top_header": 148,
        "stage_top": 242,
        "stage_height": 1010,
        "caption_top": 1296,
        "caption_height": 236,
        "caption_width": 890,
        "caption_font": 46,
        "footer_top": 1564,
        "hook_size": 98,
        "split_gap": 32,
        "split_card_h": 426,
        "bar_row_gap": 22,
        "bar_h": 36,
        "stat_gap": 28,
        "end_top": 330,
    },
}

CAPTIONS = [
    (0.25, 2.35, "We fed a quiet 1.2-second meeting clip"),
    (2.40, 4.70, "to cloud APIs and LokalBot's local model."),
    (4.95, 8.20, "Gemini Flash invented a 30-word sentence on silence."),
    (8.28, 12.05, "Qwen3-ASR v3 returned 100% clean silence and 0 words."),
    (12.35, 14.80, "Zero hallucinated words. Zero API fees."),
    (14.88, 17.35, "Zero bytes uploaded in 2.52 GB GGUF Q8_0."),
    (17.75, 21.20, "On AMI far-field meetings, local Qwen3-ASR hits 17.6% WER,"),
    (21.28, 24.80, "beating OpenAI GPT-4o and GPT Transcribe cloud APIs."),
    (25.45, 29.60, "LokalBot. Local by default, free and open source."),
]

AMI_ROWS = [
    {"name": "Qwen3-ASR 1.7B (Local)", "wer": 17.6, "meta": "44x RT · $0/hr", "local": True},
    {"name": "Qwen3-ASR Flash (Cloud)", "wer": 18.1, "meta": "$0.13/hr", "local": False},
    {"name": "Qwen-Audio 3.1 Flash", "wer": 18.5, "meta": "$0.02/hr", "local": False},
    {"name": "GPT-4o mini Transcribe", "wer": 21.8, "meta": "$0.18/hr", "local": False},
    {"name": "GPT Transcribe", "wer": 22.2, "meta": "$0.27/hr", "local": False},
    {"name": "GPT-4o Transcribe", "wer": 23.0, "meta": "$0.36/hr", "local": False},
]

SFX_EVENTS = [
    ("hook", "pop", 0.35, 0.72, 0.24),
    ("split", "whoosh-short", 4.75, 0.57, 0.24),
    ("hallucinate-1", "typing", 6.45, 1.05, 0.26),
    ("hallucinate-2", "typing", 7.50, 1.05, 0.26),
    ("clean-lock", "click-soft", 6.55, 0.37, 0.36),
    ("stats", "whoosh-short", 12.15, 0.57, 0.22),
    ("stat-1", "pop", 12.60, 0.72, 0.20),
    ("stat-2", "pop", 13.45, 0.72, 0.20),
    ("stat-3", "pop", 14.30, 0.72, 0.20),
    ("chart", "whoosh-short", 17.45, 0.57, 0.24),
    ("beat-openai", "pop", 20.90, 0.72, 0.26),
    ("endcard", "impact-bass-1", 25.35, 2.12, 0.28),
]

ICON_SVG = (
    '<svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">'
    '<defs>'
    '<linearGradient id="lb-bg" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#222e3d" /><stop offset="1" stop-color="#0e141c" />'
    '</linearGradient>'
    '<linearGradient id="lb-body" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#6ef2dc" /><stop offset="1" stop-color="#23c4ae" />'
    '</linearGradient>'
    '</defs>'
    '<rect x="64" y="64" width="896" height="896" rx="204" fill="url(#lb-bg)" />'
    '<rect x="372" y="206" width="36" height="86" rx="18" fill="#3a7d72" />'
    '<circle id="end-light" cx="390" cy="186" r="42" fill="#fbbf24" />'
    '<rect x="268" y="276" width="244" height="484" rx="62" fill="url(#lb-body)" />'
    '<rect x="268" y="592" width="492" height="168" rx="62" fill="url(#lb-body)" />'
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

MINI_ICON_SVG = (
    '<svg class="brand-icon" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">'
    '<defs>'
    '<linearGradient id="mb-bg" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#222e3d" /><stop offset="1" stop-color="#0e141c" />'
    '</linearGradient>'
    '<linearGradient id="mb-body" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#6ef2dc" /><stop offset="1" stop-color="#23c4ae" />'
    '</linearGradient>'
    '</defs>'
    '<rect x="64" y="64" width="896" height="896" rx="204" fill="url(#mb-bg)" />'
    '<rect x="372" y="206" width="36" height="86" rx="18" fill="#3a7d72" />'
    '<circle cx="390" cy="186" r="42" fill="#fbbf24" />'
    '<rect x="268" y="276" width="244" height="484" rx="62" fill="url(#mb-body)" />'
    '<rect x="268" y="592" width="492" height="168" rx="62" fill="url(#mb-body)" />'
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


def build_caption_entries():
    entries = []
    for start, end, text in CAPTIONS:
        tokens = text.split()
        span = max(0.2, end - start - 0.12)
        weights = [max(2, len(t)) for t in tokens]
        total_w = sum(weights)
        cursor = start
        words = []
        for tok, w in zip(tokens, weights):
            step = span * (w / total_w)
            words.append({"text": tok, "start": round(cursor, 3), "end": round(cursor + step, 3)})
            cursor += step
        entries.append({"start": start, "end": end, "words": words})
    return entries


def build_html(fmt):
    s = FORMATS[fmt]
    w, h = s["width"], s["height"]
    inner_w = w - 2 * s["pad_x"]
    cap_entries = build_caption_entries()

    cap_blocks = []
    for p_idx, phrase in enumerate(cap_entries):
        spans = " ".join(
            f'<span class="cap-word" id="cap-w-{p_idx}-{w_idx}">{html.escape(word["text"])}</span>'
            for w_idx, word in enumerate(phrase["words"])
        )
        cap_blocks.append(f'          <div class="cap-phrase" id="cap-p-{p_idx}"><div class="cap-line">{spans}</div></div>')

    ami_markup = []
    for idx, row in enumerate(AMI_ROWS):
        cls = "ami-row ami-local" if row["local"] else "ami-row"
        badge = '<span class="ami-badge">LOCAL · $0/HR</span>' if row["local"] else ""
        pct = round((row["wer"] / 25.0) * 100, 1)
        ami_markup.append(
            f'          <div class="{cls}" id="ami-r-{idx}">\n'
            f'            <div class="ami-head"><span class="ami-name">{html.escape(row["name"])}{badge}</span>'
            f'<span class="ami-right"><span class="ami-meta">{html.escape(row["meta"])}</span>'
            f'<span class="ami-val">{row["wer"]:.1f}% WER</span></span></div>\n'
            f'            <div class="ami-track"><div class="ami-fill" id="ami-f-{idx}" style="width:{pct}%"></div></div>\n'
            f'          </div>'
        )

    audio_tags = []
    sfx_dir = HERE / "assets/sfx"
    for idx, (name, filename, start, dur, vol) in enumerate(SFX_EVENTS):
        if (sfx_dir / f"{filename}.mp3").exists():
            media_attr = ' data-media-start="0.45" data-fade-out="0.08"' if filename == "typing" else ""
            audio_tags.append(
                f'      <audio id="sfx-{name}" class="clip" data-start="{start:g}" data-duration="{dur:g}" '
                f'data-track-index="{20 + idx % 3}" data-volume="{vol:g}"{media_attr} src="assets/sfx/{filename}.mp3"></audio>'
            )

    token_chips = "".join(
        f'<span class="tok-chip" id="tok-{i}">{i + 1:02d}</span>'
        for i in range(30)
    )

    page = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width={w}, height={h}" />
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
        width: {w}px;
        height: {h}px;
        overflow: hidden;
        background: #0e151d;
        font-family: Inter, -apple-system, BlinkMacSystemFont, sans-serif;
        color: #f2f7f5;
      }}
      #root {{
        position: relative;
        width: {w}px;
        height: {h}px;
        overflow: hidden;
        background: radial-gradient(120% 55% at 50% 0%, #162635 0%, #0e151d 58%, #0a1017 100%);
      }}
      .mono {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
      }}
      #grid-bg {{
        position: absolute;
        inset: 0;
        background-image:
          linear-gradient(rgba(110, 242, 220, 0.045) 1px, transparent 1px),
          linear-gradient(90deg, rgba(110, 242, 220, 0.045) 1px, transparent 1px);
        background-size: 64px 64px;
      }}
      #top-bar {{
        position: absolute;
        left: {s['pad_x']}px;
        top: {s['top_header']}px;
        width: {inner_w}px;
        display: flex;
        align-items: center;
        justify-content: space-between;
        z-index: 20;
      }}
      .brand-lockup {{
        display: flex;
        align-items: center;
        gap: 14px;
      }}
      .brand-icon {{
        width: 50px;
        height: 50px;
        border-radius: 12px;
        box-shadow: 0 0 0 1.5px rgba(242, 247, 245, 0.22);
      }}
      .brand-name {{
        font-size: 34px;
        font-weight: 900;
        letter-spacing: -0.04em;
        color: #f2f7f5;
      }}
      .top-pill {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 19px;
        font-weight: 700;
        letter-spacing: 0.06em;
        color: #6ef2dc;
        background: rgba(35, 196, 174, 0.14);
        border: 1.5px solid rgba(110, 242, 220, 0.4);
        border-radius: 999px;
        padding: 8px 18px;
      }}
      #stage {{
        position: absolute;
        left: {s['pad_x']}px;
        top: {s['stage_top']}px;
        width: {inner_w}px;
        height: {s['stage_height']}px;
        z-index: 10;
      }}
      .beat {{
        position: absolute;
        inset: 0;
        display: flex;
        flex-direction: column;
        justify-content: center;
      }}
      .eyebrow {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 22px;
        font-weight: 700;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        color: #6ef2dc;
        margin-bottom: 20px;
      }}
      #b1-title {{
        font-size: {s['hook_size']}px;
        font-weight: 900;
        letter-spacing: -0.045em;
        line-height: 1.06;
        color: #f2f7f5;
      }}
      #b1-title .hl-coral {{
        display: inline-block;
        color: #0e141c;
        background: #ff8a80;
        border-radius: 16px;
        padding: 2px 22px 8px;
        margin-top: 8px;
      }}
      .wave-card {{
        margin-top: 42px;
        background: #141f2b;
        border: 2px solid #2b3f52;
        border-radius: 24px;
        padding: 26px 28px;
      }}
      .wave-meta {{
        display: flex;
        justify-content: space-between;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 22px;
        font-weight: 700;
        color: #a9c4c0;
        margin-bottom: 18px;
      }}
      .wave-meta .db-badge {{
        color: #fbbf24;
      }}
      .wave-box {{
        position: relative;
        height: 146px;
        background: #0c131c;
        border-radius: 16px;
        border: 1.5px solid #233344;
        overflow: hidden;
      }}
      .wave-bars {{
        position: absolute;
        inset: 0;
      }}
      .wave-bars i {{
        position: absolute;
        top: 50%;
        width: 8px;
        border-radius: 4px;
      }}
      .scan-head {{
        position: absolute;
        top: 10px;
        bottom: 10px;
        left: 0;
        width: 5px;
        border-radius: 3px;
        background: #fbbf24;
        box-shadow: 0 0 18px rgba(251, 191, 36, 0.8);
      }}
      .wave-axis {{
        display: flex;
        justify-content: space-between;
        margin-top: 14px;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 20px;
        color: #9bb7b4;
      }}
      #beat2 {{
        gap: {s['split_gap']}px;
      }}
      .split-card {{
        height: {s['split_card_h']}px;
        background: #141f2b;
        border-radius: 26px;
        padding: 26px 28px;
        display: flex;
        flex-direction: column;
        justify-content: space-between;
      }}
      .split-cloud {{
        border: 2.5px solid rgba(255, 138, 128, 0.65);
        box-shadow: 0 18px 48px rgba(0, 0, 0, 0.4);
      }}
      .split-local {{
        border: 2.5px solid rgba(110, 242, 220, 0.7);
        box-shadow: 0 18px 48px rgba(0, 0, 0, 0.4);
      }}
      .split-head {{
        display: flex;
        justify-content: space-between;
        align-items: center;
      }}
      .split-title {{
        font-size: 34px;
        font-weight: 900;
        letter-spacing: -0.03em;
      }}
      .split-cloud .split-title {{
        color: #ff9e96;
      }}
      .split-local .split-title {{
        color: #6ef2dc;
      }}
      .split-cost {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 21px;
        font-weight: 700;
        padding: 6px 14px;
        border-radius: 999px;
      }}
      .split-cloud .split-cost {{
        color: #ffaba4;
        background: rgba(255, 138, 128, 0.16);
      }}
      .split-local .split-cost {{
        color: #6ef2dc;
        background: rgba(110, 242, 220, 0.15);
      }}
      .mini-wave {{
        position: relative;
        height: 68px;
        background: #0b121b;
        border-radius: 12px;
        border: 1px solid #253647;
        overflow: hidden;
      }}
      .tok-grid {{
        display: flex;
        flex-wrap: wrap;
        gap: 7px 8px;
        align-content: flex-start;
        min-height: 112px;
      }}
      .tok-chip {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 19px;
        font-weight: 700;
        padding: 4px 10px;
        border-radius: 8px;
        background: rgba(255, 138, 128, 0.22);
        border: 1px solid rgba(255, 138, 128, 0.55);
        color: #ffd0cc;
      }}
      .split-status {{
        display: flex;
        justify-content: space-between;
        align-items: center;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 22px;
        font-weight: 700;
      }}
      .status-bad {{
        color: #ff9e96;
      }}
      .status-good {{
        color: #6ef2dc;
      }}
      .silence-box {{
        background: rgba(35, 196, 174, 0.12);
        border: 2px solid rgba(110, 242, 220, 0.45);
        border-radius: 16px;
        padding: 24px 26px;
        display: flex;
        justify-content: space-between;
        align-items: center;
      }}
      .silence-tag {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 36px;
        font-weight: 800;
        color: #6ef2dc;
      }}
      .silence-sub {{
        font-size: 26px;
        font-weight: 700;
        color: #eafffa;
      }}
      #beat3 {{
        gap: {s['stat_gap']}px;
      }}
      .b3-heading {{
        font-size: 52px;
        font-weight: 900;
        letter-spacing: -0.035em;
        line-height: 1.1;
      }}
      .stat-card {{
        background: #141f2b;
        border: 2px solid #2b3f52;
        border-left: 10px solid #6ef2dc;
        border-radius: 22px;
        padding: 28px 32px;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 24px;
      }}
      .stat-card.amber {{
        border-left-color: #fbbf24;
      }}
      .stat-num {{
        font-size: 86px;
        font-weight: 900;
        letter-spacing: -0.045em;
        line-height: 1;
        color: #6ef2dc;
        white-space: nowrap;
      }}
      .stat-card.amber .stat-num {{
        color: #fbbf24;
      }}
      .stat-copy {{
        flex: 1;
        text-align: right;
      }}
      .stat-title {{
        font-size: 34px;
        font-weight: 800;
        color: #f2f7f5;
      }}
      .stat-sub {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 21px;
        color: #a9c4c0;
        margin-top: 6px;
      }}
      #beat4 {{
        justify-content: center;
      }}
      .b4-title {{
        font-size: 44px;
        font-weight: 900;
        letter-spacing: -0.035em;
        line-height: 1.08;
      }}
      .b4-sub {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 20px;
        color: #a9c4c0;
        margin-top: 8px;
        margin-bottom: 20px;
      }}
      .ami-list {{
        display: flex;
        flex-direction: column;
        gap: {s['bar_row_gap']}px;
      }}
      .ami-row {{
        display: flex;
        flex-direction: column;
        gap: 6px;
      }}
      .ami-head {{
        display: flex;
        justify-content: space-between;
        align-items: center;
      }}
      .ami-right {{
        display: flex;
        align-items: baseline;
        gap: 14px;
      }}
      .ami-name {{
        font-size: 25px;
        font-weight: 700;
        color: #d3e5e2;
        display: flex;
        align-items: center;
        gap: 10px;
      }}
      .ami-local .ami-name {{
        color: #f2f7f5;
        font-weight: 900;
      }}
      .ami-badge {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 16px;
        font-weight: 800;
        color: #0e141c;
        background: #fbbf24;
        padding: 3px 9px;
        border-radius: 7px;
      }}
      .ami-val {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 26px;
        font-weight: 800;
        color: #c2dad6;
      }}
      .ami-local .ami-val {{
        color: #6ef2dc;
      }}
      .ami-track {{
        height: {s['bar_h']}px;
        background: #141f2b;
        border-radius: 10px;
        overflow: hidden;
        border: 1.5px solid #26384a;
      }}
      .ami-fill {{
        height: 100%;
        border-radius: 8px;
        background: #557379;
        transform-origin: 0 50%;
      }}
      .ami-local .ami-fill {{
        background: linear-gradient(90deg, #23c4ae, #6ef2dc);
      }}
      #ami-r-3 .ami-fill,
      #ami-r-4 .ami-fill,
      #ami-r-5 .ami-fill {{
        background: #a56468;
      }}
      .ami-meta {{
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 18px;
        color: #9bb7b4;
      }}
      #ami-callout {{
        margin-top: 20px;
        background: rgba(251, 191, 36, 0.14);
        border: 2px solid #fbbf24;
        border-radius: 16px;
        padding: 15px 22px;
        font-size: 26px;
        font-weight: 800;
        color: #fde68a;
        text-align: center;
      }}
      #end-overlay {{
        position: absolute;
        inset: 0;
        z-index: 30;
        pointer-events: none;
      }}
      #end-ground {{
        position: absolute;
        inset: 0;
        background: #c9f1e7;
      }}
      #end-spark {{
        position: absolute;
        left: {w // 2 - 26}px;
        top: {h // 2 - 26}px;
        width: 52px;
        height: 52px;
        border-radius: 26px;
        background: #fbbf24;
      }}
      #end-content {{
        position: absolute;
        left: {s['pad_x']}px;
        right: {s['pad_x']}px;
        top: {s['end_top']}px;
        display: flex;
        flex-direction: column;
        align-items: center;
        text-align: center;
        color: #0e141c;
      }}
      #end-icon-wrap {{
        width: 176px;
        height: 176px;
        margin-bottom: 20px;
      }}
      #end-name {{
        font-size: 102px;
        font-weight: 900;
        letter-spacing: -0.045em;
        line-height: 1.05;
        color: #0e141c;
      }}
      #end-model {{
        margin-top: 16px;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 28px;
        font-weight: 700;
        color: #16403a;
        background: rgba(14, 20, 28, 0.08);
        padding: 9px 22px;
        border-radius: 999px;
      }}
      #end-tag {{
        margin-top: 22px;
        font-size: 40px;
        font-weight: 800;
        letter-spacing: -0.025em;
        color: #0e141c;
      }}
      #end-url {{
        margin-top: 18px;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 32px;
        font-weight: 800;
        color: #0e141c;
      }}
      #end-note {{
        margin-top: 24px;
        font-size: 21px;
        font-weight: 600;
        color: #29504a;
        max-width: 820px;
        line-height: 1.35;
      }}
      #progress-bar {{
        position: absolute;
        left: {s['pad_x']}px;
        top: {s['caption_top'] - 20}px;
        width: {inner_w}px;
        height: 6px;
        border-radius: 999px;
        background: rgba(234, 255, 250, 0.16);
        overflow: hidden;
        z-index: 40;
      }}
      #progress-fill {{
        width: 100%;
        height: 100%;
        background: linear-gradient(90deg, #23c4ae, #6ef2dc, #fbbf24);
        transform-origin: 0 50%;
      }}
      #captions {{
        position: absolute;
        left: {s['pad_x']}px;
        top: {s['caption_top']}px;
        width: {s['caption_width']}px;
        height: {s['caption_height']}px;
        z-index: 45;
      }}
      .cap-phrase {{
        position: absolute;
        left: 0;
        right: 0;
        top: 50%;
        margin-top: -64px;
        display: flex;
        justify-content: center;
      }}
      .cap-line {{
        display: flex;
        flex-wrap: wrap;
        justify-content: center;
        gap: 8px 10px;
        font-size: {s['caption_font']}px;
        font-weight: 800;
        letter-spacing: -0.025em;
        line-height: 1.28;
        text-align: center;
      }}
      .cap-word {{
        color: #b7cec9;
        padding: 4px 11px 6px;
        border-radius: 11px;
      }}
      #cap-p-8 .cap-line {{
        background: #0e151d;
        padding: 14px 22px;
        border-radius: 20px;
        box-shadow: 0 12px 32px rgba(0, 0, 0, 0.25);
      }}
      #footer {{
        position: absolute;
        left: {s['pad_x']}px;
        top: {s['footer_top']}px;
        width: {inner_w}px;
        display: flex;
        justify-content: space-between;
        font-family: "JetBrains Mono", ui-monospace, monospace;
        font-size: 21px;
        font-weight: 600;
        color: #9ec5be;
        z-index: 25;
      }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{DURATION:g}" data-width="{w}" data-height="{h}">
      <div id="grid-bg" data-layout-ignore></div>
      <div id="top-bar">
        <div class="brand-lockup">{MINI_ICON_SVG}<span class="brand-name">LokalBot</span></div>
        <div class="top-pill">CLOUD STT VS LOCAL ASR</div>
      </div>

      <div id="stage">
        <div class="beat" id="beat1">
          <div class="eyebrow">REAL MEETING BENCHMARK · SEP 2026</div>
          <div id="b1-title">1.2s quiet clip.<br />Cloud AI invented<br /><span class="hl-coral">30 words.</span></div>
          <div class="wave-card">
            <div class="wave-meta"><span>MIC CLIP · 16 kHz MONO WAV</span><span class="db-badge">-46 dB · QUIET</span></div>
            <div class="wave-box">
              <div class="wave-bars" id="wave-hook" data-layout-ignore></div>
              <div class="scan-head" id="scan-hook" data-layout-ignore></div>
            </div>
            <div class="wave-axis"><span>0.0 s</span><span>0.4 s</span><span>0.8 s</span><span>1.2 s</span></div>
          </div>
        </div>

        <div class="beat" id="beat2">
          <div class="split-card split-cloud" id="card-cloud">
            <div class="split-head">
              <div class="split-title">Gemini 3.8 Flash</div>
              <div class="split-cost">CLOUD · $0.33/hr</div>
            </div>
            <div class="mini-wave">
              <div class="wave-bars" id="wave-cloud" data-layout-ignore></div>
              <div class="scan-head" id="scan-cloud" style="background:#ff8a80" data-layout-ignore></div>
            </div>
            <div class="tok-grid" id="tok-grid">{token_chips}</div>
            <div class="split-status">
              <span class="status-bad" id="cloud-count">30 invented words on 1.2s clip</span>
              <span class="mono" style="color:#c9a9a7;font-size:19px">115 invented in 15 clips</span>
            </div>
          </div>

          <div class="split-card split-local" id="card-local">
            <div class="split-head">
              <div class="split-title">Qwen3-ASR 1.7B LokalBot v3</div>
              <div class="split-cost">LOCAL · $0/hr</div>
            </div>
            <div class="mini-wave">
              <div class="wave-bars" id="wave-local" data-layout-ignore></div>
              <div class="scan-head" id="scan-local" style="background:#6ef2dc" data-layout-ignore></div>
            </div>
            <div class="silence-box" id="silence-box">
              <div class="silence-tag">[silence]</div>
              <div class="silence-sub">100% clean · 0 hallucinated words</div>
            </div>
            <div class="split-status">
              <span class="status-good">0 bytes uploaded</span>
              <span class="mono" style="color:#a9c4c0;font-size:19px">2.52 GB GGUF Q8_0</span>
            </div>
          </div>
        </div>

        <div class="beat" id="beat3">
          <div class="eyebrow">V0.14.0 DEFAULT · APACHE-2.0 FINE-TUNE</div>
          <div class="b3-heading">Qwen3-ASR 1.7B LokalBot v3</div>
          <div class="stat-card" id="stat-1">
            <div class="stat-num">0</div>
            <div class="stat-copy">
              <div class="stat-title">Hallucinated words</div>
              <div class="stat-sub">100% clean silence vs 115 invented by Gemini Flash</div>
            </div>
          </div>
          <div class="stat-card amber" id="stat-2">
            <div class="stat-num">$0/hr</div>
            <div class="stat-copy">
              <div class="stat-title">API cost forever</div>
              <div class="stat-sub">Cloud STT APIs ran $0.13 to $0.36 per audio hour</div>
            </div>
          </div>
          <div class="stat-card" id="stat-3">
            <div class="stat-num">0 B</div>
            <div class="stat-copy">
              <div class="stat-title">Audio uploaded</div>
              <div class="stat-sub">2.52 GB GGUF Q8_0 runs locally on llama.cpp</div>
            </div>
          </div>
        </div>

        <div class="beat" id="beat4">
          <div class="eyebrow">PUBLIC AMI FAR-FIELD MEETINGS</div>
          <div class="b4-title">Lower Word Error Rate wins</div>
          <div class="b4-sub">16 Mix-Headset windows · 27.4 min · 4,160 reference words</div>
          <div class="ami-list">
{chr(10).join(ami_markup)}
          </div>
          <div id="ami-callout">17.6% WER locally, beating all 3 OpenAI cloud APIs</div>
        </div>
      </div>

      <div id="end-overlay" data-layout-allow-overflow>
        <div id="end-ground" data-layout-ignore></div>
        <div id="end-spark" data-layout-ignore></div>
        <div id="end-content">
          <div id="end-icon-wrap">{ICON_SVG}</div>
          <div id="end-name">LokalBot</div>
          <div id="end-model">Qwen3-ASR 1.7B LokalBot v3</div>
          <div id="end-tag">Local by default. Free and open source.</div>
          <div id="end-url">lokalbot.com/benchmarks</div>
          <div id="end-note">Direct vendor APIs tested Sep 2026 on Apple M4 Max (48 GB). Full report in Benchmarks/transcribe/CloudSTT.</div>
        </div>
      </div>

      <div id="progress-bar" data-layout-ignore><div id="progress-fill"></div></div>
      <div id="captions" data-layout-allow-overflow>
{chr(10).join(cap_blocks)}
      </div>
      <div id="footer"><span>lokalbot.com/benchmarks</span><span>GPLv3 · No cloud upload</span></div>
{chr(10).join(audio_tags)}
    </div>
    <script>
      gsap.config({{ force3D: false }});
      const tl = gsap.timeline({{ paused: true }});
      const CAPTIONS = {json.dumps(cap_entries)};
      let rngState = 20260930;
      const rnd = () => {{
        rngState = (rngState * 1664525 + 1013904223) >>> 0;
        return rngState / 4294967296;
      }};
      const fillWave = (hostId, count, widthPx, color) => {{
        const host = document.getElementById(hostId);
        const step = widthPx / count;
        for (let i = 0; i < count; i++) {{
          const bar = document.createElement("i");
          const quietSpike = i === 18 || i === 19 ? 28 : 8 + Math.round(rnd() * 14);
          bar.style.left = `${{Math.round(i * step + 4)}}px`;
          bar.style.height = `${{quietSpike}}px`;
          bar.style.marginTop = `${{-quietSpike / 2}}px`;
          bar.style.background = color;
          host.appendChild(bar);
        }}
      }};
      fillWave("wave-hook", 56, {inner_w - 60}, "#6ef2dc");
      fillWave("wave-cloud", 52, {inner_w - 60}, "#ff8a80");
      fillWave("wave-local", 52, {inner_w - 60}, "#6ef2dc");

      gsap.set(["#beat2", "#beat3", "#beat4", "#end-content"], {{ opacity: 0 }});
      gsap.set("#end-ground", {{ clipPath: "circle(0px at 50% 50%)" }});
      gsap.set("#end-spark", {{ opacity: 0, scale: 0.4 }});
      gsap.set(".tok-chip", {{ opacity: 0, scale: 0.7 }});
      gsap.set("#silence-box", {{ opacity: 0, y: 12 }});
      gsap.set(["#stat-1", "#stat-2", "#stat-3"], {{ opacity: 0, y: 24 }});
      gsap.set(".ami-fill", {{ scaleX: 0 }});
      gsap.set("#ami-callout", {{ opacity: 0, y: 16 }});
      gsap.set(".cap-phrase", {{ opacity: 0 }});

      tl.fromTo("#b1-title", {{ opacity: 0, y: 24 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: "power3.out" }}, 0.15);
      tl.fromTo("#scan-hook", {{ x: 10 }}, {{ x: {inner_w - 78}, duration: 3.1, ease: "none" }}, 0.7);
      tl.to("#beat1", {{ opacity: 0, y: -20, duration: 0.3, ease: "power2.in" }}, 4.5);

      tl.fromTo("#beat2", {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.35, ease: "power2.out" }}, 4.8);
      tl.fromTo("#scan-cloud", {{ x: 8 }}, {{ x: {inner_w - 78}, duration: 1.4, ease: "none" }}, 5.1);
      tl.fromTo("#scan-local", {{ x: 8 }}, {{ x: {inner_w - 78}, duration: 1.4, ease: "none" }}, 5.1);
      for (let i = 0; i < 30; i++) {{
        tl.to(`#tok-${{i}}`, {{ opacity: 1, scale: 1, duration: 0.12, ease: "back.out(1.6)" }}, 6.45 + i * 0.105);
      }}
      tl.to("#silence-box", {{ opacity: 1, y: 0, duration: 0.35, ease: "power3.out" }}, 6.55);
      tl.to("#beat2", {{ opacity: 0, y: -20, duration: 0.3, ease: "power2.in" }}, 11.9);

      tl.fromTo("#beat3", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3, ease: "power2.out" }}, 12.2);
      tl.to("#stat-1", {{ opacity: 1, y: 0, duration: 0.38, ease: "power3.out" }}, 12.55);
      tl.to("#stat-2", {{ opacity: 1, y: 0, duration: 0.38, ease: "power3.out" }}, 13.40);
      tl.to("#stat-3", {{ opacity: 1, y: 0, duration: 0.38, ease: "power3.out" }}, 14.25);
      tl.to("#beat3", {{ opacity: 0, y: -20, duration: 0.3, ease: "power2.in" }}, 17.2);

      tl.fromTo("#beat4", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3, ease: "power2.out" }}, 17.5);
      for (let i = 0; i < 6; i++) {{
        tl.to(`#ami-f-${{i}}`, {{ scaleX: 1, duration: 0.65, ease: "power3.out" }}, 17.9 + i * 0.24);
      }}
      tl.to("#ami-callout", {{ opacity: 1, y: 0, duration: 0.4, ease: "back.out(1.4)" }}, 20.85);
      tl.to("#beat4", {{ opacity: 0, duration: 0.25, ease: "power2.in" }}, 24.75);
      tl.to(["#top-bar", "#progress-bar", "#footer"], {{ opacity: 0, duration: 0.2, ease: "power2.in" }}, 24.9);

      tl.to("#end-spark", {{ opacity: 1, scale: 1, duration: 0.22, ease: "back.out(2)" }}, 24.9);
      tl.to("#end-ground", {{ clipPath: "circle(1350px at 50% 50%)", duration: 0.55, ease: "power2.inOut" }}, 25.05);
      tl.to("#end-spark", {{ opacity: 0, scale: 0.3, duration: 0.2, ease: "power2.in" }}, 25.45);
      tl.fromTo("#end-content", {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: "power3.out" }}, 25.4);

      CAPTIONS.forEach((phrase, pIdx) => {{
        const pSel = `#cap-p-${{pIdx}}`;
        tl.set(pSel, {{ opacity: 1 }}, phrase.start);
        phrase.words.forEach((word, wIdx) => {{
          const wSel = `#cap-w-${{pIdx}}-${{wIdx}}`;
          const nextWord = phrase.words[wIdx + 1];
          const clearAt = nextWord ? nextWord.start : phrase.end;
          tl.set(wSel, {{ backgroundColor: "#fbbf24", color: "#0e141c" }}, word.start);
          tl.set(wSel, {{ backgroundColor: "transparent", color: "#f2f7f5" }}, clearAt);
        }});
        tl.set(pSel, {{ opacity: 0 }}, phrase.end);
      }});

      tl.fromTo("#progress-fill", {{ scaleX: 0 }}, {{ scaleX: 1, duration: {DURATION:g}, ease: "none" }}, 0);
      tl.set({{}}, {{}}, {DURATION:g});
      window.__timelines["main"] = tl;
      tl.seek(0);
    </script>
  </body>
</html>
"""
    return page


def main():
    parser = argparse.ArgumentParser(description="Build Cloud STT Hallucination vs Qwen3-ASR v3 30s social clip.")
    parser.add_argument("--format", choices=["4:5", "9:16"], default="4:5")
    parser.add_argument("--out", type=Path, default=HERE / "index.html")
    args = parser.parse_args()
    args.out.write_text(build_html(args.format), encoding="utf-8")
    print(f"Built {args.format} ({FORMATS[args.format]['width']}x{FORMATS[args.format]['height']}, {DURATION:g}s) -> {args.out}")


if __name__ == "__main__":
    main()
