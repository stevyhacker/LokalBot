"""Assemble index.html from edit.json, the chosen voice takes and the CI film.

Every footage card shows the CI film unchanged; a camera keyframe gives the
card's box on the canvas and the part of the film it shows, so a wide view of
the call can turn into a close-up of the panel. Text, titles and the diagram
are drawn here. Run after editing edit.json, then mix.py, then `npm run check`.
"""
import html
import json
import subprocess
from pathlib import Path

P = Path(__file__).resolve().parent
E = json.loads((P / 'edit.json').read_text())
LINES = {x['id']: x for x in json.loads((P / 'narration.json').read_text())['lines']}
ROWS = {r['file']: r for r in json.loads((P / 'production/voice-generation.json').read_text())['rows']}
TOTAL = E['duration']
SRC_W, SRC_H = E['source_size']


def take(line_id):
    return E.get('takes', {}).get(line_id, f'assets/voice/{line_id}-s11.mp3')


def media_duration(path):
    return round(float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                       str(P / path)], check=True, capture_output=True, text=True).stdout), 3)


def caption_chunks(line_id, start):
    """Split a voiced line into caption chunks at sentence ends, timed from the alignment."""
    a = ROWS[take(line_id)]['alignment']
    chars, starts, ends = a['characters'], a['character_start_times_seconds'], a['character_end_times_seconds']
    chunks, begin = [], 0
    for i, ch in enumerate(chars):
        last = i == len(chars) - 1
        if last or (ch in '.?!' and i + 1 < len(chars) and chars[i + 1] == ' ' and i - begin > 24):
            text = ''.join(chars[begin:i + 1]).strip()
            if text:
                chunks.append((round(start + starts[begin], 3), round(start + ends[i], 3), text))
            begin = i + 1
    # Each chunk stays up until the next one starts, or briefly after the line.
    out = []
    for k, (a0, a1, text) in enumerate(chunks):
        b = chunks[k + 1][0] - 0.05 if k + 1 < len(chunks) else a1 + 0.5
        out.append((a0, round(b - a0, 3), text))
    return out


def call_on_screen(t):
    """True while a wide shot of the call shows its own caption bar."""
    return any(s.get('call') and s['start'] <= t < s['end'] for s in E['shots'])


voices, captions = [], []
for line_id, start in E['voice']:
    line = LINES[line_id]
    voices.append({'id': line_id, 'start': start, 'file': take(line_id), 'dur': media_duration(take(line_id))})
    speaker = {'ana': 'Ana', 'stevan': 'Stevan'}.get(line['voice'])
    if speaker and call_on_screen(start):
        continue
    for a0, dur, text in caption_chunks(line_id, start):
        captions.append({'start': a0, 'dur': dur, 'text': text, 'speaker': speaker})
captions.sort(key=lambda c: c['start'])
for i, c in enumerate(captions[:-1]):
    c['dur'] = round(min(c['dur'], captions[i + 1]['start'] - c['start'] - 0.04), 3)

shots_html = []
for i, s in enumerate(E['shots']):
    dur = round(s['end'] - s['start'], 3)
    rate = f' data-playback-rate="{s["rate"]}"' if s.get('rate', 1) != 1 else ''
    speed = ''
    if s.get('rate', 1) >= 1.25 and not s.get('call'):
        x, y, w, _ = s['cam'][0][1]
        speed = f'<div class="speed" id="speed-{s["id"]}" style="left:{x + w - 170}px;top:{y + 18}px">{s["rate"]:.1f}× speed</div>'
    shots_html.append(f'''{speed}
      <div class="card" id="card-{s['id']}" data-layout-allow-overflow>
        <video id="v-{s['id']}" class="clip footage" src="{E['footage']}" muted playsinline
          data-start="{s['start']}" data-duration="{dur}" data-media-start="{s['media_start']}"
          data-track-index="{1 + i % 2}"{rate}></video>
      </div>''')

beats_html = []
for b in E['beats']:
    chips = ''.join(f'<span class="chip">{html.escape(c)}</span>' for c in b.get('chips', []))
    beats_html.append(f'''
      <div class="beat" id="beat-{b['id']}" style="width:{b.get('width', 420)}px">
        <div class="kicker">{html.escape(b['kicker'])}</div>
        <div class="headline">{html.escape(b['headline'])}</div>
        {f'<div class="detail">{html.escape(b["detail"])}</div>' if b.get('detail') else ''}
        {f'<div class="chips">{chips}</div>' if chips else ''}
      </div>''')

caps_html = '\n'.join(
    f'      <div class="clip cap" id="cap-{i + 1:02d}" data-start="{c["start"]}" data-duration="{c["dur"]}" data-track-index="20">'
    + (f'<span class="who who-{c["speaker"].lower()}">{c["speaker"]}</span>' if c['speaker'] else '')
    + f'<span class="cap-text">{html.escape(c["text"])}</span></div>'
    for i, c in enumerate(captions))

MIX = 'assets/sound/final-mix.wav'
mix_dur = media_duration(MIX) if (P / MIX).exists() else TOTAL
config = {'shots': E['shots'], 'beats': E['beats'], 'scenes': E['scenes'], 'src': [SRC_W, SRC_H], 'total': TOTAL,
          'badge': E.get('badge')}

page = f'''<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <title>From meeting to done — LokalBot × Meta Muse</title>
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
      @font-face {{ font-family: "Big Shoulders Display"; src: url("assets/fonts/BigShouldersDisplay-VF.ttf"); font-weight: 100 900; }}
      @font-face {{ font-family: "Hanken Grotesk"; src: url("assets/fonts/HankenGrotesk-VF.ttf"); font-weight: 100 900; }}
      @font-face {{ font-family: "JetBrains Mono"; src: url("assets/fonts/JetBrainsMono-VF.ttf"); font-weight: 100 800; }}
      :root {{
        --bg: #091216; --panel: #12232a; --line: #22404a; --fg: #e6f2ef; --muted: #8ba7a3;
        --teal: #2fd3bd; --spark: #63aaff; --wonder: #6be38f; --voice: #ffcf5c; --clash: #ffa046; --ana: #7fd0ff;
      }}
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: var(--bg); }}
      #root {{ position: relative; width: 100%; height: 100%; overflow: hidden; color: var(--fg);
        background: radial-gradient(1200px 760px at 78% 10%, #12302f 0%, rgba(9,18,22,0) 62%), var(--bg);
        font-family: "Hanken Grotesk", Helvetica, sans-serif; }}
      #grid {{ position: absolute; inset: 0; opacity: 0.35;
        background-image: linear-gradient(rgba(47,211,189,0.06) 1px, transparent 1px),
          linear-gradient(90deg, rgba(47,211,189,0.06) 1px, transparent 1px);
        background-size: 48px 48px; }}
      .card {{ position: absolute; overflow: hidden; border-radius: 18px; opacity: 0; background: #000;
        box-shadow: 0 40px 90px -30px rgba(0,0,0,0.75), 0 0 0 1px rgba(47,211,189,0.25); }}
      .footage {{ position: absolute; left: 0; top: 0; width: {SRC_W}px; height: {SRC_H}px; transform-origin: 0 0; }}
      .speed {{ position: absolute; z-index: 5; width: 150px; text-align: center; opacity: 0; font-family: "JetBrains Mono", monospace;
        font-size: 18px; font-weight: 700; color: #091216; background: var(--voice); border-radius: 999px; padding: 6px 0; }}
      .beat {{ position: absolute; left: 72px; top: 0; height: 930px; opacity: 0; display: flex; flex-direction: column; gap: 22px;
        justify-content: center; }}
      .kicker {{ font-family: "JetBrains Mono", monospace; font-size: 20px; font-weight: 600; letter-spacing: 0.14em;
        text-transform: uppercase; color: var(--teal); }}
      .headline {{ font-family: "Big Shoulders Display", sans-serif; font-size: 84px; line-height: 0.92; font-weight: 800;
        text-transform: uppercase; letter-spacing: 0.01em; text-wrap: balance; }}
      .detail {{ font-size: 29px; line-height: 1.4; color: #cfe2de; }}
      .chips {{ display: flex; flex-wrap: wrap; gap: 10px; }}
      .chip {{ font-family: "JetBrains Mono", monospace; font-size: 17px; font-weight: 600; padding: 9px 14px;
        border-radius: 999px; border: 1px solid var(--line); color: var(--muted); background: rgba(18,35,42,0.75); }}
      .cap {{ position: absolute; left: 72px; right: 72px; bottom: 40px; display: flex; gap: 16px; align-items: baseline;
        justify-content: center; }}
      .cap-text {{ font-size: 32px; line-height: 1.25; font-weight: 560; color: #f4fbf9; text-align: center;
        max-width: 1600px; text-shadow: 0 2px 14px rgba(0,0,0,0.85); opacity: 0; }}
      .who {{ font-family: "JetBrains Mono", monospace; font-size: 20px; font-weight: 700; letter-spacing: 0.08em;
        text-transform: uppercase; padding: 6px 10px; border-radius: 8px; opacity: 0; white-space: nowrap; }}
      .who-ana {{ color: #08202a; background: var(--ana); }}
      .who-stevan {{ color: #052520; background: var(--teal); }}
      #badge {{ position: absolute; left: 72px; top: 7px; opacity: 0; font-family: "JetBrains Mono", monospace;
        font-size: 14px; color: #b4c8c4; padding: 5px 10px; border: 1px dashed var(--line); border-radius: 8px;
        background: rgba(9,18,22,0.75); }}
      .scene {{ position: absolute; inset: 0; opacity: 0; display: flex; flex-direction: column; justify-content: center;
        padding: 0 0 40px 150px; }}
      #title .eyebrow {{ font-family: "JetBrains Mono", monospace; font-size: 26px; letter-spacing: 0.16em; color: var(--teal);
        text-transform: uppercase; }}
      #title .big {{ font-family: "Big Shoulders Display", sans-serif; font-weight: 900; font-size: 210px; line-height: 0.85;
        text-transform: uppercase; margin-top: 26px; }}
      #title .big .to {{ color: var(--teal); text-shadow: 0 0 40px rgba(47,211,189,0.5); }}
      #title .sub {{ font-size: 34px; color: #cfe2de; margin-top: 34px; }}
      #models .row {{ display: flex; gap: 28px; margin-top: 40px; }}
      #models h2 {{ font-family: "Big Shoulders Display", sans-serif; font-size: 92px; font-weight: 800; text-transform: uppercase;
        line-height: 0.95; }}
      .model {{ width: 500px; padding: 30px 30px 34px; border-radius: 20px; background: var(--panel); border: 1px solid var(--line);
        display: flex; flex-direction: column; gap: 14px; opacity: 0; }}
      .model .name {{ font-family: "Big Shoulders Display", sans-serif; font-size: 52px; font-weight: 800; text-transform: uppercase; }}
      .model .does {{ font-size: 26px; line-height: 1.4; color: #cfe2de; }}
      .model .dot {{ width: 16px; height: 16px; border-radius: 50%; }}
      #models .local {{ margin-top: 34px; font-size: 28px; color: var(--muted); opacity: 0; }}
      #models .local b {{ color: var(--fg); }}
      #endcard .brand {{ display: flex; align-items: center; gap: 34px; }}
      #endcard .brand img {{ width: 150px; height: 150px; }}
      #endcard .word {{ font-family: "Big Shoulders Display", sans-serif; font-size: 170px; font-weight: 900; text-transform: uppercase; }}
      #endcard .line {{ font-family: "Big Shoulders Display", sans-serif; font-size: 72px; font-weight: 800; color: var(--teal);
        text-transform: uppercase; margin-top: 18px; }}
      #endcard .url {{ font-family: "JetBrains Mono", monospace; font-size: 38px; margin-top: 46px; color: var(--fg); }}
      #endcard .note {{ font-size: 24px; color: var(--muted); margin-top: 30px; max-width: 1350px; line-height: 1.45; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-width="1920" data-height="1080" data-duration="{TOTAL}">
      <div id="grid"></div>
{''.join(shots_html)}
{''.join(beats_html)}
      <div id="badge">{html.escape(E.get('badge', {}).get('text', ''))}</div>
      <div class="scene" id="title">
        <div class="eyebrow">LokalBot × Meta Muse</div>
        <div class="big">From meeting<br/><span class="to">to done</span></div>
        <div class="sub">Built during the Meta Global AI Developer Hackathon</div>
      </div>
      <div class="scene" id="models">
        <h2>Three Meta models</h2>
        <div class="row">
          <div class="model" id="m-voice"><div class="dot" style="background:var(--voice)"></div><div class="name">Voice Transcribe</div>
            <div class="does">Realtime speech to text, turn by turn, for the live transcript.</div></div>
          <div class="model" id="m-spark"><div class="dot" style="background:var(--spark)"></div><div class="name">Muse Spark</div>
            <div class="does">Live Radar every few seconds, and screen answers from crops of earlier captures.</div></div>
          <div class="model" id="m-wonder"><div class="dot" style="background:var(--wonder)"></div><div class="name">Muse Wonder</div>
            <div class="does">Live answers from your work, and Follow-through with your approval.</div></div>
        </div>
        <div class="local">On your Mac: <b>recording, speaker separation, meeting and screen search.</b></div>
      </div>
      <div class="scene" id="endcard">
        <div class="brand"><img src="assets/brand/lokalbot-mark-brand.svg" alt="" /><div class="word">LokalBot</div></div>
        <div class="line">From meeting to done</div>
        <div class="url">github.com/stevyhacker/lokalbot</div>
        <div class="note">{html.escape(E['endcard_note'])}</div>
      </div>
{caps_html}
      <audio id="mix" src="{MIX}" data-start="0" data-duration="{mix_dur}" data-track-index="30"></audio>
    </div>
    <script>
      const C = {json.dumps(config, separators=(',', ':'))};
      const tl = gsap.timeline({{ paused: true }});
      tl.fromTo("#grid", {{ backgroundPosition: "0px 0px" }}, {{ backgroundPosition: "-96px -48px", duration: C.total, ease: "none" }}, 0);
      // A camera keyframe is [time, [box x, y, w, h], [film x, y, w]]: the card's place on the canvas and
      // the part of the film it shows, as wide as w and as tall as the box's shape allows.
      const view = (box, src) => {{
        const k = box[2] / src[2];
        return {{ card: {{ left: box[0], top: box[1], width: box[2], height: box[3] }},
                 video: {{ x: -src[0] * k, y: -src[1] * k, scale: k }} }};
      }};
      for (const s of C.shots) {{
        const card = "#card-" + s.id, video = "#v-" + s.id;
        const first = view(s.cam[0][1], s.cam[0][2]);
        tl.set(card, first.card, 0);
        tl.set(video, first.video, 0);
        const fadeIn = s.fade_in ?? 0.35, fadeOut = s.fade_out ?? 0.35;
        if (s.start === 0 || fadeIn === 0) tl.set(card, {{ opacity: 1 }}, s.start);
        else tl.fromTo(card, {{ opacity: 0 }}, {{ opacity: 1, duration: fadeIn, ease: "power1.out" }}, s.start);
        if (fadeOut === 0) tl.set(card, {{ opacity: 0 }}, s.end);
        else tl.to(card, {{ opacity: 0, duration: fadeOut, ease: "power1.in" }}, s.end - fadeOut);
        if (document.querySelector("#speed-" + s.id)) {{
          tl.fromTo("#speed-" + s.id, {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3 }}, s.start + 0.3);
          tl.to("#speed-" + s.id, {{ opacity: 0, duration: 0.3 }}, s.end - 0.4);
        }}
        for (let i = 1; i < s.cam.length; i++) {{
          const [t0] = s.cam[i - 1], [t1, box, src] = s.cam[i];
          const v = view(box, src), ease = s.cam[i][3] || "power2.inOut";
          tl.to(card, {{ ...v.card, duration: t1 - t0, ease }}, s.start + t0);
          tl.to(video, {{ ...v.video, duration: t1 - t0, ease }}, s.start + t0);
        }}
      }}
      for (const b of C.beats) {{
        const el = "#beat-" + b.id;
        tl.fromTo(el, {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.6, ease: "power3.out" }}, b.start);
        if (b.chips && b.chips.length)
          tl.fromTo(el + " .chip", {{ opacity: 0, y: 8 }}, {{ opacity: 1, y: 0, duration: 0.35, stagger: 0.12, ease: "power2.out" }}, b.start + 0.4);
        tl.to(el, {{ opacity: 0, y: -10, duration: 0.4, ease: "power1.in" }}, b.end - 0.4);
      }}
      if (C.badge) {{
        tl.fromTo("#badge", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.5 }}, C.badge.start);
        tl.to("#badge", {{ opacity: 0, duration: 0.5 }}, C.badge.end - 0.5);
      }}
      const sc = C.scenes;
      tl.fromTo("#title", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.5 }}, sc.title.start);
      tl.fromTo("#title .big", {{ y: 40, scale: 1.04 }}, {{ y: 0, scale: 1, duration: 1.2, ease: "expo.out" }}, sc.title.start);
      tl.fromTo("#title .sub", {{ opacity: 0, y: 12 }}, {{ opacity: 1, y: 0, duration: 0.6 }}, sc.title.start + 0.8);
      tl.to("#title", {{ opacity: 0, duration: 0.5 }}, sc.title.end - 0.5);
      tl.fromTo("#models", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.5 }}, sc.models.start);
      ["#m-voice", "#m-spark", "#m-wonder"].forEach((m, i) =>
        tl.fromTo(m, {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.6, ease: "back.out(1.4)" }}, sc.models.cues[i]));
      tl.fromTo("#models .local", {{ opacity: 0, y: 10 }}, {{ opacity: 1, y: 0, duration: 0.6 }}, sc.models.cues[3]);
      tl.to("#models", {{ opacity: 0, duration: 0.5 }}, sc.models.end - 0.5);
      tl.fromTo("#endcard", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.7 }}, sc.endcard.start);
      tl.fromTo("#endcard .brand", {{ y: 24 }}, {{ y: 0, duration: 1.0, ease: "power3.out" }}, sc.endcard.start);
      tl.fromTo("#endcard .url", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.6 }}, sc.endcard.start + 1.2);
      tl.fromTo("#endcard .note", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.6 }}, sc.endcard.start + 1.8);
      document.querySelectorAll(".cap").forEach(el => {{
        const start = parseFloat(el.dataset.start), dur = parseFloat(el.dataset.duration);
        const parts = el.querySelectorAll(".cap-text, .who");
        tl.fromTo(parts, {{ opacity: 0, y: 6 }}, {{ opacity: 1, y: 0, duration: 0.2, ease: "power1.out" }}, start);
        tl.to(parts, {{ opacity: 0, duration: 0.15 }}, start + dur - 0.15);
      }});
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
'''
(P / 'index.html').write_text(page)
print(f'Built index.html: {TOTAL:.2f}s, {len(E["shots"])} shots, {len(voices)} voice lines, {len(captions)} captions')
