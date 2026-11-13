#!/usr/bin/env python3
"""Download one variant of FluidInference's Core ML conversion of NVIDIA Nemotron 3.5 ASR Streaming
(compiled models only, about 660 MB) into its own folder, for
LiveTurnLatencyBenchmarkTests/testStreamingRecognizerDelay. The app does not use this model.

Usage: fetch_stream_model.py <variant, e.g. multilingual/560ms> <output folder>
"""
import json
import os
import sys
import urllib.request

REPOSITORY = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
REVISION = "a70b9d1c33594f1f4cf3f4eca9b4a0a8f44a9f59"
AGENT = {"User-Agent": "model-fetch"}


def main():
    variant, out = sys.argv[1], sys.argv[2]
    url = f"https://huggingface.co/api/models/{REPOSITORY}/tree/{REVISION}/{variant}?recursive=1&limit=1000"
    items = []
    while url:
        with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=60) as response:
            items += json.load(response)
            link = response.headers.get("Link", "")
        url = link.split(";")[0].strip("<> ") if 'rel="next"' in link else None
    total = 0
    for item in items:
        if item.get("type") != "file" or ".mlpackage" in item["path"]:
            continue
        target = os.path.join(out, item["path"][len(variant) + 1:])
        size = item.get("lfs", {}).get("size") or item.get("size", 0)
        total += size
        if os.path.exists(target) and os.path.getsize(target) == size:
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        source = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{item['path']}"
        request = urllib.request.Request(source, headers=AGENT)
        with urllib.request.urlopen(request, timeout=120) as response, open(target + ".part", "wb") as file:
            while block := response.read(1 << 20):
                file.write(block)
        os.replace(target + ".part", target)
    print(f"{variant}: {total / 1e6:.0f} MB in {out}")


if __name__ == "__main__":
    main()
