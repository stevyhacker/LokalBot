#!/usr/bin/env python3
"""Voice the film with ElevenLabs: one request per line, with character timings.

    export ELEVEN_LABS_API_KEY="$(sed -n 's/^ELEVEN_LABS_API_KEY=//p' <main checkout>/.env)"
    python3 voice/tts.py [--seeds 11,29] [--only 01-call,request]

`lines` in narration.json are the narrator's; each request carries its neighbours as
previous_text and next_text so the delivery runs on. `spoken` are things said inside a
scene (the dictated request) and are voiced on their own. Writes
assets/voice/<id>-s<seed>.mp3 and voice/generation.json (text, settings, duration and the
character alignment; never the key). ElevenLabs is a paid call: voice only lines whose
text changed.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
SPEC = json.loads((HERE / "narration.json").read_text())


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return float(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seeds", default="11,29")
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    key = os.environ.get("ELEVEN_LABS_API_KEY") or os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("ELEVEN_LABS_API_KEY is not set")
    only = set(filter(None, args.only.split(",")))
    out_dir = PROJECT / "assets/voice"
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = HERE / "generation.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {"rows": []}
    report.update({"provider": "elevenlabs", "voice_id": SPEC["voice_id"], "model_id": SPEC["model_id"],
                   "voice_settings": SPEC["voice_settings"], "output_format": "mp3_44100_128"})
    lines = SPEC["lines"]
    jobs = [(line, lines[i - 1]["text"] if i else None, lines[i + 1]["text"] if i + 1 < len(lines) else None)
            for i, line in enumerate(lines)]
    jobs += [(line, None, None) for line in SPEC.get("spoken", [])]
    spent = 0
    for line, before, after in jobs:
        if only and line["id"] not in only:
            continue
        for seed in (int(s) for s in args.seeds.split(",")):
            body = {"text": line["text"], "model_id": SPEC["model_id"], "seed": seed,
                    "voice_settings": SPEC["voice_settings"]}
            if before:
                body["previous_text"] = before
            if after:
                body["next_text"] = after
            url = (f"https://api.elevenlabs.io/v1/text-to-speech/{SPEC['voice_id']}/with-timestamps"
                   "?output_format=mp3_44100_128")
            request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                             headers={"Content-Type": "application/json", "xi-api-key": key})
            try:
                with urllib.request.urlopen(request, timeout=180) as response:
                    data = json.load(response)
            except urllib.error.HTTPError as error:
                sys.exit(f"HTTP {error.code}: {error.read().decode()[:600]}")
            path = out_dir / f"{line['id']}-s{seed}.mp3"
            path.write_bytes(base64.b64decode(data["audio_base64"]))
            spent += len(line["text"])
            row = {"id": line["id"], "seed": seed, "file": str(path.relative_to(PROJECT)), "text": line["text"],
                   "duration": round(duration(path), 3), "alignment": data.get("alignment")}
            report["rows"] = [r for r in report["rows"] if r["file"] != row["file"]] + [row]
            report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")
            print(f"{row['file']}  {row['duration']:.2f}s")
    print(f"{spent} characters sent")


if __name__ == "__main__":
    main()
