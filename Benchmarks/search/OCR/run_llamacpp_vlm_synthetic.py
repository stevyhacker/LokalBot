#!/usr/bin/env python3
import argparse
import csv
import json
import time
import urllib.error
import urllib.request
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8097/v1/chat/completions")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model-label", default="paddleocr-vl-gguf")
    parser.add_argument("--max-tokens", type=int, default=1024)
    parser.add_argument("--prompt", default="Text Recognition. Return only the visible text.")
    parser.add_argument("--image-url-mode", choices=["basename", "absolute"], default="basename")
    parser.add_argument("--limit", type=int, default=0)
    return parser.parse_args()


def load_rows(path: Path, limit: int):
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            rows.append(row)
            if limit and len(rows) >= limit:
                break
    return rows


def image_url(path: str, mode: str):
    image_path = Path(path)
    if mode == "basename":
        return f"file://{image_path.name}"
    return f"file://{image_path}"


def request_completion(endpoint: str, payload: dict):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.loads(response.read().decode("utf-8"))


def main():
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("engine\tid\tapp\tinfer_ms\tchars\toutput_path\ttruth_path\tpng_path", flush=True)
    for row in load_rows(Path(args.manifest), args.limit):
        payload = {
            "model": args.model_label,
            "temperature": 0,
            "max_tokens": args.max_tokens,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": args.prompt},
                        {"type": "image_url", "image_url": {"url": image_url(row["png_path"], args.image_url_mode)}},
                    ],
                }
            ],
        }
        started = time.perf_counter()
        try:
            response = request_completion(args.endpoint, payload)
            infer_ms = (time.perf_counter() - started) * 1000
            text = response["choices"][0]["message"].get("content") or ""
        except (urllib.error.URLError, KeyError, IndexError, json.JSONDecodeError) as exc:
            infer_ms = (time.perf_counter() - started) * 1000
            text = f"ERROR: {exc}"

        output_path = output_dir / f"{row['id']}.{args.model_label}.txt"
        output_path.write_text(text, encoding="utf-8")
        print(
            f"{args.model_label}\t{row['id']}\t{row['app']}\t{infer_ms:.1f}\t"
            f"{len(text)}\t{output_path}\t{row['truth_path']}\t{row['png_path']}",
            flush=True,
        )


if __name__ == "__main__":
    main()
