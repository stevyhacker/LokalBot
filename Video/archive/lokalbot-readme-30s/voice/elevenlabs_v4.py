#!/usr/bin/env python3
"""Generate the narration lines with ElevenLabs Eleven v4.

    ELEVENLABS_API_KEY=... python3 voice/elevenlabs_v4.py <out_dir> [voice_id]

Writes v1.wav..v8.wav (24 kHz mono) for `VOICE=<out_dir> ./prepare_media.sh`.
Lines match SCRIPT.md; the name is spelled "LocalBot" so it is spoken like "local".
Each request passes the neighbouring lines as context so the read stays continuous.
"""
import json, os, subprocess, sys, urllib.request

ERIC = "cjVigY5qzO86Huf0OWal"  # premade male voice: "Eric - Smooth, Trustworthy"
LINES = [
    ("v1", "[curious] You said it in a meeting. You saw it on screen."),
    ("v2", "[confident] LocalBot finds it in seconds."),
    ("v3", "One search covers your meetings and the screen text you choose to keep."),
    ("v4", "Every decision links back to the moment it was said."),
    ("v5", "Search the transcript, or ask, and check the sources."),
    ("v6", "Today and Timeline show what still needs you."),
    ("v7", "Dictate and autocomplete, right where you type."),
    ("v8", "[warm] AI that runs on your Mac. Free and open source."),
]

out = sys.argv[1]
voice = sys.argv[2] if len(sys.argv) > 2 else ERIC
key = os.environ["ELEVENLABS_API_KEY"]
os.makedirs(out, exist_ok=True)

for i, (lid, text) in enumerate(LINES):
    body = {"text": text, "model_id": "eleven_v4", "seed": 42}
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
