#!/usr/bin/env python3
"""Render release explainers to PDF, PNG, or 1200x1500 (4:5) social carousels with headless Chrome.

Release notes link one explainer per major feature from Website/public/explainers/
(RELEASING.md, "Explainers for major features"). Supports macOS and Linux Chrome/Chromium.

Usage:
    python3 Website/generator/render_explainer.py explainer.html Website/public/explainers/tailscale-mobile-sync.pdf
    python3 Website/generator/render_explainer.py explainer.html Website/public/explainers/tailscale-mobile-sync.png --size 1200x1500
    python3 Website/generator/render_explainer.py Docs/explainers/ Local/social-renders/explainers/ --social-4x5 --linkedin-deck Local/social-renders/explainers/lokalbot-explainers-linkedin-4x5.pdf
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CHROME_CANDIDATES = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
)
NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\.(?:png|pdf)")
MAX_BYTES = 10 * 1024 * 1024
PAGE_OPEN_RE = re.compile(r'<section\b[^>]*\bclass="[^"]*\bpage\b[^"]*"[^>]*>', re.I)


def find_chrome(override: str | None = None) -> str:
    candidates: list[str] = []
    if override:
        candidates.append(override)
    env_chrome = os.environ.get("CHROME_BIN")
    if env_chrome:
        candidates.append(env_chrome)
    candidates.extend(CHROME_CANDIDATES)
    for candidate in candidates:
        if Path(candidate).exists():
            return candidate
    for binary in ("google-chrome", "chromium", "chromium-browser"):
        resolved = shutil.which(binary)
        if resolved:
            return resolved
    raise SystemExit("Google Chrome or Chromium is required (set --chrome or CHROME_BIN)")


def chrome_base_args(chrome_bin: str, profile_dir: Path) -> list[str]:
    args = [
        chrome_bin,
        "--headless=new",
        f"--user-data-dir={profile_dir}",
        "--hide-scrollbars",
        "--allow-file-access-from-files",
        "--run-all-compositor-stages-before-draw",
        "--virtual-time-budget=4000",
    ]
    if sys.platform.startswith("linux"):
        args += ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"]
    return args


def run_chrome(chrome_bin: str, uri: str, out: Path, size: tuple[int, int], scale_factor: int) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / out.name
        args = chrome_base_args(chrome_bin, Path(tmp) / "profile")
        if out.suffix == ".pdf":
            args += ["--no-pdf-header-footer", f"--print-to-pdf={target}"]
        else:
            args += [
                f"--force-device-scale-factor={scale_factor}",
                f"--window-size={size[0]},{size[1]}",
                f"--screenshot={target}",
            ]
        chrome = subprocess.Popen([*args, uri], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(90):
                if target.exists() and target.stat().st_size > 0:
                    time.sleep(0.4)
                    break
                time.sleep(0.3)
        finally:
            chrome.kill()
            chrome.wait()
        if not target.exists() or target.stat().st_size == 0:
            raise SystemExit(f"Chrome did not write {out}")
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(target, out)


def count_pages(html_text: str) -> int:
    matches = PAGE_OPEN_RE.findall(html_text)
    return max(1, len(matches))


def inject_social_css(html_text: str, page_index: int | None, width: int, height: int, pdf_mode: bool) -> str:
    scale = min((width - 120) / 793.7, (height - 80) / 1122.5)
    if pdf_mode:
        css = f"""
<style id="lb-social-4x5">
@page {{ size: {width}px {height}px; margin: 0; }}
html, body {{
  margin: 0 !important;
  padding: 0 !important;
  background: #080d14 !important;
}}
body {{
  display: block !important;
}}
.page {{
  width: 210mm !important;
  height: 297mm !important;
  margin: 0 auto !important;
  transform: scale({scale:.5f});
  transform-origin: top center;
  border-radius: 18px !important;
  box-shadow: 0 0 0 1px rgba(110, 242, 220, 0.25) !important;
  break-after: page !important;
}}
.page:last-child {{
  break-after: auto !important;
}}
.lb-slide {{
  width: {width}px;
  height: {height}px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: radial-gradient(120% 55% at 50% 0%, #102430 0%, #080d14 64%);
  overflow: hidden;
  page-break-after: always;
  break-after: page;
}}
.lb-slide:last-child {{
  page-break-after: auto;
  break-after: auto;
}}
.lb-slide > .page {{
  margin: 0 !important;
  transform: scale({scale:.5f});
  transform-origin: center center;
  break-after: auto !important;
}}
</style>
"""
    else:
        hide_rules = ""
        if page_index is not None:
            hide_rules = (
                "section.page { display: none !important; }\n"
                f"section.page:nth-of-type({page_index + 1}) {{ display: flex !important; }}\n"
            )
        css = f"""
<style id="lb-social-4x5">
html, body {{
  margin: 0 !important;
  padding: 0 !important;
  width: {width}px !important;
  height: {height}px !important;
  overflow: hidden !important;
  background: radial-gradient(120% 55% at 50% 0%, #102430 0%, #080d14 64%) !important;
}}
body {{
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
}}
{hide_rules}
.page {{
  margin: 0 !important;
  transform: scale({scale:.5f});
  transform-origin: center center;
  border-radius: 18px !important;
  box-shadow: 0 28px 80px rgba(0, 0, 0, 0.55), 0 0 0 1.5px rgba(110, 242, 220, 0.26) !important;
}}
</style>
"""
    if "</head>" in html_text:
        return html_text.replace("</head>", css + "\n</head>", 1)
    return css + html_text


def wrap_pages_for_pdf(html_text: str) -> str:
    body_match = re.search(r"(<body[^>]*>)(.*)(</body>)", html_text, flags=re.S | re.I)
    if not body_match:
        return html_text
    prefix, inner, suffix = body_match.groups()
    wrapped = re.sub(
        r'(<section\b[^>]*\bclass="[^"]*\bpage\b[^"]*"[^>]*>.*?</section>)',
        r'<div class="lb-slide">\1</div>',
        inner,
        flags=re.S | re.I,
    )
    return html_text[: body_match.start()] + prefix + wrapped + suffix + html_text[body_match.end() :]


def render_social_4x5_one(
    chrome_bin: str,
    source: Path,
    out_dir: Path,
    width: int,
    height: int,
    emit_pdf: bool,
) -> list[Path]:
    raw_html = source.read_text(encoding="utf-8")
    pages = count_pages(raw_html)
    slug = source.stem
    produced: list[Path] = []
    for idx in range(pages):
        png_name = f"{slug}.png" if idx == 0 else f"{slug}-p{idx + 1}.png"
        png_out = out_dir / png_name
        styled = inject_social_css(raw_html, idx, width, height, pdf_mode=False)
        temp_html = source.parent / f".render-social-{os.getpid()}-{slug}-p{idx + 1}.html"
        try:
            temp_html.write_text(styled, encoding="utf-8")
            run_chrome(chrome_bin, temp_html.resolve().as_uri(), png_out, (width, height), scale_factor=1)
        finally:
            if temp_html.exists():
                temp_html.unlink()
        produced.append(png_out)
    if emit_pdf:
        pdf_out = out_dir / f"{slug}-4x5.pdf"
        styled_pdf = inject_social_css(wrap_pages_for_pdf(raw_html), None, width, height, pdf_mode=True)
        temp_pdf_html = source.parent / f".render-social-pdf-{os.getpid()}-{slug}.html"
        try:
            temp_pdf_html.write_text(styled_pdf, encoding="utf-8")
            run_chrome(chrome_bin, temp_pdf_html.resolve().as_uri(), pdf_out, (width, height), scale_factor=1)
        finally:
            if temp_pdf_html.exists():
                temp_pdf_html.unlink()
        produced.append(pdf_out)
    return produced


def render_linkedin_deck(chrome_bin: str, png_paths: list[Path], out_pdf: Path, width: int, height: int) -> None:
    slides = "\n".join(
        f'<div class="slide"><img src="{p.resolve().as_uri()}" alt="{p.stem}" /></div>'
        for p in png_paths
    )
    doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
@page {{ size: {width}px {height}px; margin: 0; }}
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ margin: 0; padding: 0; background: #080d14; }}
.slide {{ width: {width}px; height: {height}px; overflow: hidden; page-break-after: always; break-after: page; }}
.slide:last-child {{ page-break-after: auto; break-after: auto; }}
.slide img {{ display: block; width: {width}px; height: {height}px; }}
</style>
</head>
<body>
{slides}
</body>
</html>
"""
    with tempfile.TemporaryDirectory() as tmp:
        deck_html = Path(tmp) / "deck.html"
        deck_html.write_text(doc, encoding="utf-8")
        run_chrome(chrome_bin, deck_html.resolve().as_uri(), out_pdf, (width, height), scale_factor=1)


def render(source: Path, out: Path, size: tuple[int, int], chrome_bin: str) -> None:
    if out.suffix == ".png" and size == (1200, 1500):
        raw_html = source.read_text(encoding="utf-8")
        styled = inject_social_css(raw_html, 0, size[0], size[1], pdf_mode=False)
        temp_html = source.parent / f".render-single-{os.getpid()}-{source.stem}.html"
        try:
            temp_html.write_text(styled, encoding="utf-8")
            run_chrome(chrome_bin, temp_html.resolve().as_uri(), out, size, scale_factor=1)
        finally:
            if temp_html.exists():
                temp_html.unlink()
        return
    run_chrome(chrome_bin, source.resolve().as_uri(), out, size, scale_factor=2)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a release explainer to PDF, PNG, or 4:5 social cards.")
    parser.add_argument("source", type=Path, help="explainer HTML file or folder of explainers")
    parser.add_argument("out", type=Path, help="output .pdf/.png file, or output directory with --social-4x5")
    parser.add_argument("--size", default="1200x2400", help="PNG canvas in CSS pixels, WIDTHxHEIGHT")
    parser.add_argument("--chrome", default=None, help="explicit Chrome or Chromium binary path")
    parser.add_argument("--social-4x5", action="store_true", help="export 1200x1500 (4:5) PNG slides and 4:5 PDFs")
    parser.add_argument("--no-per-doc-pdf", action="store_true", help="skip per-explainer 4:5 PDFs in --social-4x5 mode")
    parser.add_argument("--linkedin-deck", type=Path, default=None, help="combined 4:5 LinkedIn PDF deck output path")
    args = parser.parse_args()

    chrome_bin = find_chrome(args.chrome)

    if args.social_4x5:
        size_str = "1200x1500" if args.size == "1200x2400" else args.size
        if not re.fullmatch(r"\d+x\d+", size_str):
            parser.error("--size takes WIDTHxHEIGHT, for example 1200x1500")
        width, height = map(int, size_str.split("x"))
        sources = sorted(args.source.glob("*.html")) if args.source.is_dir() else [args.source]
        if not sources:
            raise SystemExit(f"No explainer HTML files found in {args.source}")
        args.out.mkdir(parents=True, exist_ok=True)
        cover_pngs: list[Path] = []
        for src in sources:
            produced = render_social_4x5_one(
                chrome_bin,
                src,
                args.out,
                width,
                height,
                emit_pdf=not args.no_per_doc_pdf,
            )
            cover_pngs.append(produced[0])
            print(f"Rendered {src.name}: {', '.join(p.name for p in produced)}")
        if args.linkedin_deck:
            render_linkedin_deck(chrome_bin, cover_pngs, args.linkedin_deck, width, height)
            deck_mb = args.linkedin_deck.stat().st_size / 1_048_576
            print(f"Rendered LinkedIn deck {args.linkedin_deck} ({deck_mb:.2f} MB, {len(cover_pngs)} slides)")
        return 0

    if not NAME.fullmatch(args.out.name):
        parser.error("name the explainer after its feature: lowercase words joined by dashes, ending in .pdf or .png")
    if not re.fullmatch(r"\d+x\d+", args.size):
        parser.error("--size takes WIDTHxHEIGHT, for example 1200x2400")
    width, height = map(int, args.size.split("x"))
    if args.out.suffix == ".png" and width < 1200:
        parser.error("make PNG explainers at least 1200 pixels wide")
    render(args.source, args.out, (width, height), chrome_bin)
    size = args.out.stat().st_size
    if size > MAX_BYTES:
        raise SystemExit(f"{args.out} is {size / 1_048_576:.1f} MB; release explainers must be under 10 MB")
    print(f"Rendered {args.out} ({size / 1_048_576:.1f} MB). "
          f"Link it as https://www.lokalbot.com/explainers/{args.out.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
