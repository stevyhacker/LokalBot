#!/usr/bin/env python3
"""Render a release explainer from an HTML page with headless Google Chrome (macOS).

Release notes link one explainer per major feature from web/explainers/
(RELEASING.md, "Explainers for major features"). A PDF prints the whole page;
give it `print-color-adjust: exact` so backgrounds print. A PNG captures a
fixed canvas at 2x, so design the page at the size you pass.

Usage:
    python3 Scripts/render_explainer.py explainer.html web/explainers/gmail-meeting-briefs.pdf
    python3 Scripts/render_explainer.py explainer.html web/explainers/gmail-meeting-briefs.png --size 1200x2400
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\.(?:png|pdf)")
MAX_BYTES = 10 * 1024 * 1024


def render(source: Path, out: Path, size: tuple[int, int]) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / out.name
        args = [CHROME, "--headless=new", f"--user-data-dir={Path(tmp) / 'profile'}", "--hide-scrollbars",
                "--allow-file-access-from-files"]
        if out.suffix == ".pdf":
            args += ["--no-pdf-header-footer", f"--print-to-pdf={target}"]
        else:
            args += ["--force-device-scale-factor=2", f"--window-size={size[0]},{size[1]}", f"--screenshot={target}"]
        # A throwaway profile keeps this away from a Chrome you have open.
        chrome = subprocess.Popen([*args, source.resolve().as_uri()],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Headless Chrome doesn't always exit after writing its output.
        for _ in range(60):
            if target.exists() and target.stat().st_size > 0:
                time.sleep(0.5)
                break
            time.sleep(0.5)
        chrome.kill()
        if not target.exists() or target.stat().st_size == 0:
            raise SystemExit(f"Chrome did not write {out}")
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(target, out)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a release explainer to PDF or PNG.")
    parser.add_argument("source", type=Path, help="the explainer's HTML page")
    parser.add_argument("out", type=Path, help="web/explainers/<feature-slug>.pdf or .png")
    parser.add_argument("--size", default="1200x2400", help="PNG canvas in CSS pixels, WIDTHxHEIGHT")
    args = parser.parse_args()
    if not NAME.fullmatch(args.out.name):
        parser.error("name the explainer after its feature: lowercase words joined by dashes, ending in .pdf or .png")
    if not re.fullmatch(r"\d+x\d+", args.size):
        parser.error("--size takes WIDTHxHEIGHT, for example 1200x2400")
    width, height = map(int, args.size.split("x"))
    if args.out.suffix == ".png" and width < 1200:
        parser.error("make PNG explainers at least 1200 pixels wide")
    if not Path(CHROME).exists():
        raise SystemExit(f"Google Chrome is required: {CHROME}")
    render(args.source, args.out, (width, height))
    size = args.out.stat().st_size
    if size > MAX_BYTES:
        raise SystemExit(f"{args.out} is {size / 1_048_576:.1f} MB; release explainers must be under 10 MB")
    print(f"Rendered {args.out} ({size / 1_048_576:.1f} MB). "
          f"Link it as https://www.lokalbot.com/explainers/{args.out.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
