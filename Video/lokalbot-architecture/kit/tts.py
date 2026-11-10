#!/usr/bin/env python3
"""Voice one film with ElevenLabs: one request per line, with character timings.

    export ELEVEN_LABS_API_KEY="$(sed -n 's/^ELEVEN_LABS_API_KEY=//p' <main checkout>/.env)"
    python3 kit/tts.py <film folder> [--seeds 11] [--only a01,a04] [--skip a10]

Reads <film>/voice/narration.json. Each request carries its neighbours as previous_text and
next_text so the delivery runs on. Writes <film>/assets/voice/<id>-s<seed>.mp3 and
<film>/voice/generation.json (text, settings, duration and the character alignment; never the
key). ElevenLabs is a paid call: voice only the lines whose text changed.
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


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return float(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("film")
    parser.add_argument("--seeds", default="11")
    parser.add_argument("--only", default="")
    parser.add_argument("--skip", default="")
    args = parser.parse_args()
    key = os.environ.get("ELEVEN_LABS_API_KEY") or os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("ELEVEN_LABS_API_KEY is not set")
    film = Path(args.film).resolve()
    spec = json.loads((film / "voice/narration.json").read_text())
    only = set(filter(None, args.only.split(",")))
    skip = set(filter(None, args.skip.split(",")))
    out_dir = film / "assets/voice"
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = film / "voice/generation.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {"rows": []}
    report.update({"provider": "elevenlabs", "voice_id": spec["voice_id"], "model_id": spec["model_id"],
                   "voice_settings": spec["voice_settings"], "output_format": "mp3_44100_128"})
    lines = spec["lines"]
    spent = 0
    for index, line in enumerate(lines):
        if (only and line["id"] not in only) or line["id"] in skip:
            continue
        for seed in (int(s) for s in args.seeds.split(",")):
            body = {"text": line["text"], "model_id": spec["model_id"], "seed": seed,
                    "voice_settings": spec["voice_settings"]}
            if index:
                body["previous_text"] = lines[index - 1]["text"]
            if index + 1 < len(lines):
                body["next_text"] = lines[index + 1]["text"]
            url = (f"https://api.elevenlabs.io/v1/text-to-speech/{spec['voice_id']}/with-timestamps"
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
            row = {"id": line["id"], "seed": seed, "file": str(path.relative_to(film)), "text": line["text"],
                   "duration": round(duration(path), 3), "alignment": data.get("alignment")}
            report["rows"] = [r for r in report["rows"] if r["file"] != row["file"]] + [row]
            report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")
            print(f"{row['file']}  {row['duration']:.2f}s", flush=True)
    print(f"{spent} characters sent")


if __name__ == "__main__":
    main()
