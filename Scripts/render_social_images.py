#!/usr/bin/env python3
"""Render the website's share images (og:image) with headless Google Chrome.

- web/assets/og-image.png: the default image for guides, comparisons, and
  other pages without their own.
- web/assets/blog/og/<slug>.png: one per post in Scripts/blog_posts.py, with
  the post's title, kind, and date. render_web.py refuses to render a post
  whose image is missing.

The homepage's og-home.png has its own source in Assets/social-preview/.

Each image is drawn at 2x and downscaled to 1200x630 with sips (macOS).

Usage:
    python3 Scripts/render_social_images.py              # everything
    python3 Scripts/render_social_images.py --only default
    python3 Scripts/render_social_images.py --only <post-slug>
"""

from __future__ import annotations

import argparse
import html
import subprocess
import sys
import tempfile
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from blog_posts import POSTS  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ICON = ROOT / "web" / "assets" / "lokalbot-icon.svg"

BASE_CSS = """
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { width: 1200px; height: 630px; overflow: hidden; }
  body {
    position: relative;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif;
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
  .brand span { display: block; margin-top: 4px; color: #8fa6b4; font-size: 14px; font-weight: 600; letter-spacing: 0.16em; text-transform: uppercase; }
  .foot { position: absolute; left: 72px; right: 72px; bottom: 48px; display: flex; justify-content: space-between; color: #8fa6b4; font-size: 18px; }
  .foot strong { color: #6ef2dc; font-weight: 600; }
"""

DEFAULT_PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>{css}
  h1 {{ position: absolute; top: 176px; left: 72px; font-size: 84px; font-weight: 750; line-height: 1.02; letter-spacing: -0.045em; }}
  h1 em {{ font-style: normal; color: #6ef2dc; }}
  .sub {{ position: absolute; top: 378px; left: 72px; right: 72px; color: #b9c9d3; font-size: 24px; line-height: 1.45; }}
  .row {{ position: absolute; left: 72px; right: 72px; bottom: 112px; display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }}
  .row div {{ padding: 14px 18px; border: 1px solid rgba(110, 242, 220, 0.18); border-radius: 14px; background: rgba(255, 255, 255, 0.03); }}
  .row b {{ display: block; font-size: 19px; font-weight: 650; }}
  .row span {{ display: block; margin-top: 3px; color: #8fa6b4; font-size: 15px; }}
</style></head><body>
  <div class="brand"><img src="{icon}" alt=""><div><b>LokalBot</b><span>Private work memory · Mac, Windows, Linux</span></div></div>
  <h1>Your personal<br><em>context engine.</em></h1>
  <p class="sub">Meeting notes, screen memory, dictation, and autocomplete, running locally by default.</p>
  <div class="row">
    <div><b>Remember</b><span>meetings + your day</span></div>
    <div><b>Recall</b><span>answers + sources</span></div>
    <div><b>Write</b><span>dictation + autocomplete</span></div>
    <div><b>Agents</b><span>read-only CLI + MCP</span></div>
  </div>
  <div class="foot"><strong>lokalbot.com</strong><span>Free and open source · Windows and Linux in alpha</span></div>
</body></html>"""

POST_PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>{css}
  .eyebrow {{ position: absolute; top: 218px; left: 72px; color: #6ef2dc; font-size: 20px; font-weight: 650; letter-spacing: 0.14em; text-transform: uppercase; }}
  h1 {{ position: absolute; top: 264px; left: 72px; right: 72px; font-size: {size}px; font-weight: 750; line-height: 1.06; letter-spacing: -0.04em; text-wrap: balance; }}
</style></head><body>
  <div class="brand"><img src="{icon}" alt=""><div><b>LokalBot</b><span>Blog</span></div></div>
  <p class="eyebrow">{eyebrow} · {date}</p>
  <h1>{title}</h1>
  <div class="foot"><strong>lokalbot.com/blog</strong><span>Mac · Windows and Linux (alpha) · Free and open source</span></div>
</body></html>"""


def long_date(iso: str) -> str:
    day = date.fromisoformat(iso)
    return f"{day:%B} {day.day}, {day.year}"


def title_size(title: str) -> int:
    if len(title) <= 40:
        return 76
    if len(title) <= 64:
        return 64
    return 54


def render(page: str, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "page.html"
        shot = Path(tmp) / "shot.png"
        source.write_text(page, encoding="utf-8")
        chrome = subprocess.Popen(
            # A throwaway profile keeps this away from a Chrome you have open.
            [CHROME, "--headless=new", f"--user-data-dir={Path(tmp) / 'profile'}", "--hide-scrollbars", "--force-device-scale-factor=2",
             "--window-size=1200,630", "--allow-file-access-from-files", f"--screenshot={shot}", source.as_uri()],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        # Headless Chrome doesn't always exit after writing the screenshot.
        for _ in range(60):
            if shot.exists() and shot.stat().st_size > 0:
                time.sleep(0.5)
                break
            time.sleep(0.5)
        chrome.kill()
        if not shot.exists():
            raise SystemExit(f"Chrome did not write a screenshot for {out}")
        subprocess.run(["sips", "-Z", "1200", str(shot), "--out", str(out)], check=True, stdout=subprocess.DEVNULL)
    print(f"Rendered {out.relative_to(ROOT)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render LokalBot's share images.")
    parser.add_argument("--only", help='"default" or a post slug')
    args = parser.parse_args()
    icon = ICON.as_uri()

    if args.only in (None, "default"):
        render(DEFAULT_PAGE.format(css=BASE_CSS, icon=icon), ROOT / "web" / "assets" / "og-image.png")
    for post in POSTS:
        if args.only not in (None, post["slug"]):
            continue
        page = POST_PAGE.format(
            css=BASE_CSS,
            icon=icon,
            eyebrow=html.escape(post["eyebrow"]),
            date=long_date(post["published"]),
            title=html.escape(post["h1"]),
            size=title_size(post["h1"]),
        )
        render(page, ROOT / "web" / "assets" / "blog" / "og" / f"{post['slug']}.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
