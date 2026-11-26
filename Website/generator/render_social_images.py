#!/usr/bin/env python3
"""Render LokalBot's share images (og:image) and GitHub social preview with headless Chrome.

- Website/public/assets/og-image.png: default 1200x630 image for guides and fallback pages.
- Website/public/assets/og-home.png: homepage 1200x630 share card from Assets/social-preview/og-home.html.
- Assets/social-preview/lokalbot-social-preview.png: 1280x640 GitHub preview from Assets/social-preview/social-preview.html.
- Website/public/assets/blog/og/<slug>.png: one 1200x630 card per post in Website/generator/blog_posts.py.
- Website/public/assets/compare/og/<slug>.png: one 1200x630 card per comparison in Website/generator/comparison_pages.py.

Works on both macOS (sips + Google Chrome.app) and Linux (Pillow + /usr/bin/google-chrome).

Usage:
    python3 Website/generator/render_social_images.py
    python3 Website/generator/render_social_images.py --only default
    python3 Website/generator/render_social_images.py --only compare
    python3 Website/generator/render_social_images.py --only og-home
    python3 Website/generator/render_social_images.py --only social-preview
    python3 Website/generator/render_social_images.py --only <slug>
"""

from __future__ import annotations

import argparse
import html
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from blog_posts import POSTS  # noqa: E402
from comparison_pages import PAGES  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "Website" / "public" / "assets" / "lokalbot-icon.svg"

BASE_CSS = """
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { width: 1200px; height: 630px; overflow: hidden; }
  body {
    position: relative;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", "DejaVu Sans", sans-serif;
    color: #eff6fa;
    background:
      radial-gradient(60% 70% at 85% 110%, rgba(35, 196, 174, 0.28), transparent 70%),
      radial-gradient(45% 55% at 0% 0%, rgba(76, 104, 255, 0.16), transparent 70%),
      #070b12;
    -webkit-font-smoothing: antialiased;
  }
  body::before { content: ""; position: absolute; inset: 0 0 auto; height: 4px; background: linear-gradient(90deg, #6ef2dc, #23c4ae); }
  .brand { position: absolute; top: 56px; left: 72px; display: flex; gap: 18px; align-items: center; }
  .brand img { width: 64px; height: 64px; }
  .brand b { display: block; font-size: 30px; font-weight: 650; letter-spacing: -0.02em; }
  .brand span { display: block; margin-top: 4px; color: #8fa6b4; font-size: 14px; font-weight: 600; letter-spacing: 0.14em; text-transform: uppercase; }
  .foot { position: absolute; left: 72px; right: 72px; bottom: 48px; display: flex; justify-content: space-between; color: #8fa6b4; font-size: 18px; }
  .foot strong { color: #6ef2dc; font-weight: 600; }
"""

DEFAULT_PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>{css}
  h1 {{ position: absolute; top: 170px; left: 72px; font-size: 78px; font-weight: 750; line-height: 1.04; letter-spacing: -0.04em; }}
  h1 em {{ font-style: normal; color: #6ef2dc; }}
  .sub {{ position: absolute; top: 364px; left: 72px; right: 72px; color: #b9c9d3; font-size: 24px; line-height: 1.45; }}
  .row {{ position: absolute; left: 72px; right: 72px; bottom: 112px; display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }}
  .row div {{ padding: 14px 18px; border: 1px solid rgba(110, 242, 220, 0.18); border-radius: 14px; background: rgba(255, 255, 255, 0.03); }}
  .row b {{ display: block; font-size: 19px; font-weight: 650; }}
  .row span {{ display: block; margin-top: 3px; color: #8fa6b4; font-size: 15px; }}
</style></head><body>
  <div class="brand"><img src="{icon}" alt=""><div><b>LokalBot</b><span>Mac · Windows · Linux · iOS · Android</span></div></div>
  <h1>Local AI<br><em>meeting notes &amp; recall.</em></h1>
  <p class="sub">Bot-free meetings, screen recall, dictation, autocomplete, and MCP on v0.14.0 Apache-2.0 fine-tunes.</p>
  <div class="row">
    <div><b>Meetings</b><span>Qwen3-ASR v3</span></div>
    <div><b>Notes</b><span>Qwen3.5 4B v4</span></div>
    <div><b>Write</b><span>Gemma 4 E2B v4</span></div>
    <div><b>Agents</b><span>read-only MCP</span></div>
  </div>
  <div class="foot"><strong>lokalbot.com</strong><span>Free &amp; GPLv3 · Zero meeting bots · No account</span></div>
</body></html>"""

POST_PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>{css}
  .eyebrow {{ position: absolute; top: 212px; left: 72px; color: #6ef2dc; font-size: 20px; font-weight: 650; letter-spacing: 0.14em; text-transform: uppercase; }}
  h1 {{ position: absolute; top: 258px; left: 72px; right: 72px; font-size: {size}px; font-weight: 750; line-height: 1.06; letter-spacing: -0.04em; text-wrap: balance; }}
</style></head><body>
  <div class="brand"><img src="{icon}" alt=""><div><b>LokalBot</b><span>Blog</span></div></div>
  <p class="eyebrow">{eyebrow} · {date}</p>
  <h1>{title}</h1>
  <div class="foot"><strong>lokalbot.com/blog</strong><span>Mac · Windows &amp; Linux (alpha) · iOS &amp; Android · GPLv3</span></div>
</body></html>"""

COMPARE_PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>{css}
  .eyebrow {{ position: absolute; top: 186px; left: 72px; color: #6ef2dc; font-size: 20px; font-weight: 650; letter-spacing: 0.14em; text-transform: uppercase; }}
  h1 {{ position: absolute; top: 230px; left: 72px; right: 72px; font-size: {size}px; font-weight: 750; line-height: 1.06; letter-spacing: -0.04em; text-wrap: balance; }}
  .sub {{ position: absolute; top: 374px; left: 72px; right: 96px; color: #b9c9d3; font-size: 24px; line-height: 1.45; }}
  .pills {{ position: absolute; left: 72px; bottom: 112px; display: flex; gap: 12px; }}
  .pills span {{ padding: 8px 16px; border: 1px solid rgba(110, 242, 220, 0.24); border-radius: 999px; background: rgba(35, 196, 174, 0.10); color: #bff8ee; font-size: 16px; font-weight: 600; }}
</style></head><body>
  <div class="brand"><img src="{icon}" alt=""><div><b>LokalBot</b><span>Honest Side-by-Side Comparison</span></div></div>
  <p class="eyebrow">Compare · Verified 2026</p>
  <h1>{title}</h1>
  <p class="sub">{subtitle}</p>
  <div class="pills">
    <span>100% Local Default</span>
    <span>Free &amp; GPLv3</span>
    <span>No Meeting Bot</span>
    <span>Mac · Win · Linux</span>
  </div>
  <div class="foot"><strong>lokalbot.com/{slug}</strong><span>Apache-2.0 fine-tuned models · Read-only MCP</span></div>
</body></html>"""


def find_chrome() -> str:
    candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome"),
        shutil.which("chromium"),
        shutil.which("chromium-browser"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit("Google Chrome or Chromium not found.")


def long_date(iso: str) -> str:
    day = date.fromisoformat(iso)
    return f"{day:%B} {day.day}, {day.year}"


def title_size(title: str) -> int:
    if len(title) <= 32:
        return 76
    if len(title) <= 52:
        return 64
    return 52


def downscale(shot: Path, out: Path, width: int, height: int) -> None:
    if shutil.which("sips"):
        subprocess.run(["sips", "-Z", str(width), str(shot), "--out", str(out)], check=True, stdout=subprocess.DEVNULL)
        return
    from PIL import Image

    with Image.open(shot) as img:
        resized = img.resize((width, height), Image.Resampling.LANCZOS)
        resized.save(out, format="PNG", optimize=True)


def screenshot_uri(uri: str, out: Path, width: int = 1200, height: int = 630, scale: int = 2) -> None:
    chrome_bin = find_chrome()
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        shot = Path(tmp) / "shot.png"
        chrome = subprocess.Popen(
            [
                chrome_bin,
                "--headless=new",
                "--no-sandbox",
                "--disable-gpu",
                f"--user-data-dir={Path(tmp) / 'profile'}",
                "--hide-scrollbars",
                f"--force-device-scale-factor={scale}",
                f"--window-size={width},{height}",
                "--allow-file-access-from-files",
                f"--screenshot={shot}",
                uri,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(60):
            if shot.exists() and shot.stat().st_size > 0:
                time.sleep(0.4)
                break
            time.sleep(0.25)
        chrome.kill()
        chrome.wait()
        if not shot.exists():
            raise SystemExit(f"Chrome did not write a screenshot for {out}")
        if scale > 1:
            downscale(shot, out, width, height)
        else:
            shutil.copyfile(shot, out)
    print(f"Rendered {out.relative_to(ROOT)}")


def render_html(page: str, out: Path, width: int = 1200, height: int = 630) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "page.html"
        source.write_text(page, encoding="utf-8")
        screenshot_uri(source.as_uri(), out, width=width, height=height, scale=2)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render LokalBot's share images.")
    parser.add_argument("--only", help='"default", "og-home", "social-preview", "posts", "compare", or a slug')
    args = parser.parse_args()
    icon = ICON.as_uri()

    if args.only in (None, "default"):
        render_html(DEFAULT_PAGE.format(css=BASE_CSS, icon=icon), ROOT / "Website" / "public" / "assets" / "og-image.png")

    if args.only in (None, "og-home"):
        og_home = ROOT / "Assets" / "social-preview" / "og-home.html"
        screenshot_uri(og_home.as_uri(), ROOT / "Website" / "public" / "assets" / "og-home.png", width=1200, height=630, scale=2)

    if args.only in (None, "social-preview"):
        social = ROOT / "Assets" / "social-preview" / "social-preview.html"
        screenshot_uri(social.as_uri(), ROOT / "Assets" / "social-preview" / "lokalbot-social-preview.png", width=1280, height=640, scale=2)

    for post in POSTS:
        if args.only not in (None, "posts", post["slug"]):
            continue
        page = POST_PAGE.format(
            css=BASE_CSS,
            icon=icon,
            eyebrow=html.escape(post["eyebrow"]),
            date=long_date(post["published"]),
            title=html.escape(post["h1"]),
            size=title_size(post["h1"]),
        )
        render_html(page, ROOT / "Website" / "public" / "assets" / "blog" / "og" / f"{post['slug']}.png")

    for comp in PAGES:
        if args.only not in (None, "compare", comp["slug"]):
            continue
        heading = html.unescape(comp["h1"])
        subtitle = html.unescape(comp["og_description"])
        page = COMPARE_PAGE.format(
            css=BASE_CSS,
            icon=icon,
            title=html.escape(heading),
            subtitle=html.escape(subtitle),
            slug=html.escape(comp["slug"]),
            size=title_size(heading),
        )
        render_html(page, ROOT / "Website" / "public" / "assets" / "compare" / "og" / f"{comp['slug']}.png")

    return 0


if __name__ == "__main__":
    sys.exit(main())
