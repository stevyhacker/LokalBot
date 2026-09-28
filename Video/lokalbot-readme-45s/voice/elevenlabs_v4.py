#!/usr/bin/env python3
"""Generate the narration lines with ElevenLabs Eleven v4.

    ELEVENLABS_API_KEY=... python3 voice/elevenlabs_v4.py <out_dir> [voice_id] [line_id ...]

Writes n01.wav..n11.wav (24 kHz mono) for `VOICE=<out_dir> ./prepare_media.sh`.
Pass line ids after the voice to regenerate only those lines.
Lines match SCRIPT.md; the name is spelled "LocalBot" so it is spoken like "local".
Bracketed tags such as [warm] steer delivery and are not spoken.
Each request passes the neighbouring lines as context so the read stays continuous.
"""
import json, os, subprocess, sys, urllib.request

LIAM = "TX3LPaxmHKxFdv7VOQHJ"  # premade male voice: "Liam - Energetic, Social Media Creator" (young, American)
LINES = [
    ("n01", "You heard it in a meeting. You saw it on your screen. Then it was gone."),
    ("n02", "LocalBot keeps both: your calls, and what you saw on screen, if you turn it on."),
    ("n03", "And local AI models, like Qwen and Nemotron, do the work right on your Mac."),
    ("n04", "So when you need it? Just search."),
    ("n05", "Quick Recall searches meetings and saved screen text at once."),
    ("n06", "Every decision links back to the moment it was said."),
    ("n07", "Search any transcript, word for word."),
    ("n08", "Or ask a question, and check the sources."),
    ("n09", "Today shows what still needs you. Timeline retraces your day."),
    ("n10", "And local autocomplete helps you write, right where you type."),
    ("n11", "[warm] LocalBot. Free, open source, and running on your Mac."),
]
SEEDS = {"n04": 99}  # seeds 42 and 7 can read n04 as "meet it"

out = sys.argv[1]
voice = sys.argv[2] if len(sys.argv) > 2 else LIAM
only = set(sys.argv[3:])
key = os.environ["ELEVENLABS_API_KEY"]
os.makedirs(out, exist_ok=True)

for i, (lid, text) in enumerate(LINES):
    if only and lid not in only:
        continue
    body = {"text": text, "model_id": "eleven_v4", "seed": SEEDS.get(lid, 42)}
    if i > 0:
        body["previous_text"] = LINES[i - 1][1]
    if i + 1 < len(LINES):
        body["next_text"] = LINES[i + 1][1]
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_128",
        data=json.dumps(body).encode(),
        headers={"xi-api-key": key, "Content-Type": "application/json"},
    )
    mp3 = os.path.join(out, f"{lid}.mp3")
    with urllib.request.urlopen(req, timeout=120) as r:
        open(mp3, "wb").write(r.read())
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mp3, "-ar", "24000", "-ac", "1",
                    os.path.join(out, f"{lid}.wav")], check=True)
    print(lid)
