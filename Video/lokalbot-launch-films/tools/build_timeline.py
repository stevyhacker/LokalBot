#!/usr/bin/env python3
"""One timing source for a film's picture and sound.

    python3 build_timeline.py <film_dir> --starts 3.75,5.95,... --dur 30 [--meet 0.45] [--bars 72]

Reads vo/liam/t<i>.wav + vo/liam/words.json (and vo/meeting/t0.wav + vo/meeting1/words.json with --meet),
writes <film_dir>/timeline.js (window.TL, loaded by comp.html) and timeline.json (read by mix.py).
Word times are absolute film seconds. A diegetic line also gets bar heights and a 60 Hz loudness curve.
"""
import argparse, json, os, wave
import numpy as np


def read_wav(p):
    with wave.open(p) as w:
        n, sr, ch, sw = w.getnframes(), w.getframerate(), w.getnchannels(), w.getsampwidth()
        x = np.frombuffer(w.readframes(n), dtype={2: np.int16, 4: np.int32}[sw]).astype(np.float64)
    x = x.reshape(-1, ch).mean(1) / (32768.0 if sw == 2 else 2147483648.0)
    return x, sr


def rms_curve(x, sr, hz):
    hop = sr // hz
    n = len(x) // hop
    r = np.sqrt(np.mean(x[: n * hop].reshape(n, hop) ** 2, 1))
    return r / (r.max() or 1)


ap = argparse.ArgumentParser()
ap.add_argument("film"); ap.add_argument("--starts", required=True); ap.add_argument("--dur", type=float, required=True)
ap.add_argument("--meet", type=float); ap.add_argument("--bars", type=int, default=72)
a = ap.parse_args()

starts = [float(s) for s in a.starts.split(",")]
vo_dir = os.path.join(a.film, "vo", "liam")
words = json.load(open(os.path.join(vo_dir, "words.json")))
lines = [l.strip() for l in open(os.path.join(a.film, "vo", "lines.txt")) if l.strip()]
vo = []
for i, t0 in enumerate(starts, 1):
    x, sr = read_wav(os.path.join(vo_dir, f"t{i}.wav"))
    d = len(x) / sr
    vo.append({"i": i, "t": t0, "dur": round(d, 3), "end": round(t0 + d, 3), "text": lines[i - 1],
               "words": [[w, round(t0 + s, 3), round(t0 + e, 3)] for w, s, e in words[str(i)]]})
for p, q in zip(vo, vo[1:]):
    assert p["end"] <= q["t"], f"line {p['i']} ends at {p['end']} after line {q['i']} starts at {q['t']}"
assert vo[-1]["end"] <= a.dur, f"last line ends at {vo[-1]['end']} after the film ends"

tl = {"dur": a.dur, "vo": vo}
if a.meet is not None:
    x, sr = read_wav(os.path.join(a.film, "vo", "meeting", "t0.wav"))
    d = len(x) / sr
    mw = json.load(open(os.path.join(a.film, "vo", "meeting1", "words.json")))["1"]
    text = open(os.path.join(a.film, "vo", "meeting.txt")).read().strip()
    bars = rms_curve(x, sr, max(1, int(a.bars / d)))[: a.bars]
    bars = np.clip(bars ** 0.7, 0.06, 1)
    tl["meet"] = {"t": a.meet, "dur": round(d, 3), "end": round(a.meet + d, 3), "text": text,
                  "words": [[w, round(a.meet + s, 3), round(a.meet + e, 3)] for w, s, e in mw],
                  "bars": [round(float(b), 3) for b in bars], "rms60": [round(float(v), 3) for v in rms_curve(x, sr, 60)]}

json.dump(tl, open(os.path.join(a.film, "timeline.json"), "w"), indent=1)
open(os.path.join(a.film, "timeline.js"), "w").write("window.TL = " + json.dumps(tl) + ";\n")
for v in vo:
    print(f"VO{v['i']} {v['t']:6.2f}–{v['end']:6.2f}  {v['text']}")
if "meet" in tl:
    m = tl["meet"]; print(f"MEET  {m['t']:6.2f}–{m['end']:6.2f}  {m['text']}  ({len(m['bars'])} bars)")
