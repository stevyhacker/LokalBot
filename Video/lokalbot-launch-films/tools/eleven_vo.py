#!/usr/bin/env python3
"""Narration with ElevenLabs Eleven v4, laid out for onetake's vo_tools (t<i>.wav, 48 kHz mono, edges trimmed).

    ELEVENLABS_API_KEY=... python3 eleven_vo.py <read.txt> <out_dir> [--voice ID] [--seed N] [--lines 2,4] [--first 0]

One line of read.txt = one VO line, spelled as it should be spoken ("LocalBot", "Qwen three A S R").
Neighbouring lines go in as previous_text / next_text so the read stays continuous.
--first sets the number of the first line (0 for a lone diegetic line written as t0.wav).
"""
import argparse, json, os, subprocess, urllib.request

LIAM = "TX3LPaxmHKxFdv7VOQHJ"  # premade "Liam", young American male, the README demo's narrator

ap = argparse.ArgumentParser()
ap.add_argument("read"); ap.add_argument("out")
ap.add_argument("--voice", default=LIAM); ap.add_argument("--seed", type=int, default=42)
ap.add_argument("--lines", default=""); ap.add_argument("--first", type=int, default=1)
a = ap.parse_args()

lines = [l.strip() for l in open(a.read, encoding="utf-8") if l.strip()]
pick = {int(i) for i in a.lines.split(",")} if a.lines else None
key = os.environ["ELEVENLABS_API_KEY"]
os.makedirs(a.out, exist_ok=True)
trim = ("silenceremove=start_periods=1:start_threshold=-45dB,areverse,"
        "silenceremove=start_periods=1:start_threshold=-45dB,areverse,apad=pad_dur=0.05")

for k, text in enumerate(lines):
    n = a.first + k
    if pick and n not in pick:
        continue
    body = {"text": text, "model_id": "eleven_v4", "seed": a.seed}
    if k > 0:
        body["previous_text"] = lines[k - 1]
    if k + 1 < len(lines):
        body["next_text"] = lines[k + 1]
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{a.voice}?output_format=mp3_44100_128",
        data=json.dumps(body).encode(), headers={"xi-api-key": key, "Content-Type": "application/json"})
    mp3 = os.path.join(a.out, f"t{n}.mp3")
    with urllib.request.urlopen(req, timeout=120) as r:
        open(mp3, "wb").write(r.read())
    wav = os.path.join(a.out, f"t{n}.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mp3, "-af", trim, "-ar", "48000", "-ac", "1", wav], check=True)
    d = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav],
                       capture_output=True, text=True).stdout.strip()
    print(f"t{n} {float(d):.2f}s  {text}")
