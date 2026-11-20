#!/usr/bin/env python3
"""Render benchmark-summary.md into the static Hugging Face Space."""

import argparse
import html
import re
from pathlib import Path
from urllib.parse import urlparse

import markdown

HF_DIR = Path(__file__).resolve().parents[1]
SOURCE = HF_DIR / "benchmark-summary.md"
SPACE_DIR = HF_DIR / "space"
README_TEMPLATE = SPACE_DIR / "README.template.md"
README_OUTPUT = SPACE_DIR / "README.md"
HTML_OUTPUT = SPACE_DIR / "index.html"
GITHUB_BLOB_ROOT = "https://github.com/stevyhacker/lokalbot/blob/master"


def link_source_paths(source: str) -> str:
    pattern = re.compile(r"`((?:README\.md|Benchmarks/[^`]+|Docs/[^`]+))`")

    def replacement(match: re.Match[str]) -> str:
        path = match.group(1)
        return f"[`{path}`]({GITHUB_BLOB_ROOT}/{path})"

    return pattern.sub(replacement, source)


def collection_url(value: str) -> str:
    parsed = urlparse(value)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "huggingface.co"
        or not parsed.path.startswith("/collections/")
    ):
        raise argparse.ArgumentTypeError(
            "expected an https://huggingface.co/collections/... URL"
        )
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--collection-url", required=True, type=collection_url)
    args = parser.parse_args()

    source = link_source_paths(SOURCE.read_text(encoding="utf-8"))
    body = markdown.markdown(source, extensions=["tables", "fenced_code"])
    escaped_collection_url = html.escape(args.collection_url, quote=True)

    document = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Measured on-device model benchmarks behind LokalBot on an Apple M4 Max.">
  <title>LokalBot local-stack benchmarks</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="hero">
    <p class="eyebrow">Measured locally · synced from lokalbot.com/benchmarks</p>
    <h1>LokalBot — Local Desktop AI Leaderboard</h1>
    <p class="lede">7 desktop AI workloads and 17 reproducible suites: speech-to-text vs. cloud APIs, speaker diarization, memory recall vs. restraint, 56 ms inline autocomplete, hybrid QMSum retrieval, structured extraction, OCR, and local TTS. No estimates and no rehosted model weights.</p>
    <nav aria-label="Project links">
      <a href="https://www.lokalbot.com/benchmarks">Interactive leaderboard</a>
      <a href="https://www.lokalbot.com/benchmarks.json">JSON dataset</a>
      <a href="https://github.com/stevyhacker/lokalbot">GitHub repository</a>
      <a href="{escaped_collection_url}">Recommended model collection</a>
    </nav>
  </header>
  <main>{body}</main>
  <footer>
    Generated from <a href="{GITHUB_BLOB_ROOT}/Distribution/huggingface/benchmark-summary.md"><code>Distribution/huggingface/benchmark-summary.md</code></a>.
  </footer>
</body>
</html>
"""
    readme_template = README_TEMPLATE.read_text(encoding="utf-8")
    if readme_template.count("__COLLECTION_URL__") != 1:
        raise RuntimeError(
            "Space README template must contain one Collection URL placeholder"
        )
    readme = readme_template.replace("__COLLECTION_URL__", args.collection_url)

    README_OUTPUT.write_text(readme, encoding="utf-8")
    HTML_OUTPUT.write_text(document, encoding="utf-8")
    print(README_OUTPUT)
    print(HTML_OUTPUT)


if __name__ == "__main__":
    main()
