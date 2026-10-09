#!/usr/bin/env python3
"""Compose the README hero image from two UI Test Host captures.

The hero places a meeting window (1400x880 pt at 2x) behind Quick Recall
(660x512 pt at 4x) under the tagline, and labels Quick Recall's Screens and
Meetings groups "saw" and "said". The captures stay unedited; only the
background, headline and labels are drawn here. Headless Google Chrome renders
the page at 2x into a 3200x1800 PNG.

Usage:
    python3 Scripts/render_readme_hero.py --theme light \
        --meetings meetings.png --recall quick-recall.png \
        --out Assets/hero/lokalbot-hero-light.png

See Assets/hero/README.md for how the published images were captured.
"""
import argparse, os, shutil, subprocess, tempfile, time
from pathlib import Path

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ICON = Path(__file__).resolve().parent.parent / "Assets" / "lokalbot-icon.svg"

THEMES = {
    "dark": """
  :root { --text:#eff6fa; --dim:#9fb3c1; --a1:#6ef2dc; --a2:#23c4ae; --line:rgba(110,242,220,.6); }
  html, body { background:#070b12; }
  .canvas { background:
      radial-gradient(50% 55% at 70% 64%, rgba(35,196,174,.30), transparent 70%),
      radial-gradient(40% 45% at 8% 6%, rgba(76,104,255,.15), transparent 70%),
      radial-gradient(35% 35% at 95% 4%, rgba(110,242,220,.09), transparent 70%),
      linear-gradient(180deg, #0a111b 0%, #070b12 55%, #061013 100%); }
  .grid { background-image: radial-gradient(rgba(255,255,255,.07) 1px, transparent 1.4px); }
  .noise { opacity:.45; mix-blend-mode:overlay; }
  .win { box-shadow: 0 0 0 1px rgba(0,0,0,.75), 0 60px 120px -30px rgba(0,0,0,.85), 0 24px 48px -24px rgba(0,0,0,.7); }
  .win::after { box-shadow: inset 0 0 0 1px rgba(255,255,255,.11); }
  .meetings img { filter: brightness(.94); }
  .recall { box-shadow: 0 0 0 1px rgba(0,0,0,.8), 0 70px 140px -20px rgba(0,0,0,.9), 0 0 140px -10px rgba(35,196,174,.40); }
  .fade { background: linear-gradient(180deg, rgba(7,11,18,0), rgba(7,11,18,.55)); }
  .brand img { filter: drop-shadow(0 6px 14px rgba(0,0,0,.5)); }
""",
    "light": """
  :root { --text:#1d1d1f; --dim:#6e6e73; --a1:#12b39e; --a2:#0a7a6c; --line:rgba(10,122,108,.5); }
  html, body { background:#f2f4f7; }
  .canvas { background:
      radial-gradient(50% 55% at 70% 64%, rgba(35,196,174,.24), transparent 70%),
      radial-gradient(42% 48% at 6% 4%, rgba(96,128,255,.13), transparent 70%),
      radial-gradient(38% 40% at 96% 2%, rgba(176,140,255,.10), transparent 70%),
      linear-gradient(180deg, #fbfbfd 0%, #f2f4f7 55%, #eaf1f1 100%); }
  .grid { background-image: radial-gradient(rgba(20,30,45,.08) 1px, transparent 1.4px); }
  .noise { opacity:.35; mix-blend-mode:multiply; filter: invert(1); }
  .win { box-shadow: 0 0 0 1px rgba(0,0,0,.09), 0 50px 100px -30px rgba(20,40,60,.32), 0 20px 40px -20px rgba(20,40,60,.18); }
  .win::after { box-shadow: inset 0 0 0 1px rgba(0,0,0,.05); }
  .recall { box-shadow: 0 0 0 1px rgba(0,0,0,.10), 0 70px 130px -30px rgba(20,40,60,.42), 0 0 130px -20px rgba(35,196,174,.38); }
  .fade { background: linear-gradient(180deg, rgba(234,241,241,0), rgba(234,241,241,.7)); }
  .brand img { filter: drop-shadow(0 6px 12px rgba(20,40,60,.25)); }
""",
}

# Positions are in CSS px on a 1600x900 page. Quick Recall's 4x capture is
# cropped 104 px at the top (24.4 CSS px), and the brackets follow its two
# result groups when each holds two rows.
PAGE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { width: 1600px; height: 900px; overflow: hidden; }
  body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif;
         color: var(--text); -webkit-font-smoothing: antialiased; }
  .canvas { position: relative; width: 1600px; height: 900px; overflow: hidden; }
  .grid { position: absolute; inset: 0; background-size: 22px 22px;
          -webkit-mask-image: linear-gradient(180deg, rgba(0,0,0,.9), rgba(0,0,0,.25) 34%, transparent 55%); }
  .noise { position: absolute; inset: 0; pointer-events: none;
    background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='240' height='240'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 .09 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>"); }
  header { position: absolute; top: 34px; left: 0; right: 0;
           display: flex; flex-direction: column; align-items: center; text-align: center; }
  .brand { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; }
  .brand img { width: 44px; height: 44px; margin: -6px; }
  .brand span { font-size: 22px; font-weight: 650; letter-spacing: -.01em; margin-left: 6px; }
  h1 { font-size: 64px; line-height: 1.04; font-weight: 760; letter-spacing: -.035em; }
  h1 em, .tag { font-style: normal; background: linear-gradient(135deg, var(--a1), var(--a2));
                -webkit-background-clip: text; background-clip: text; color: transparent; }
  .sub { margin-top: 12px; font-size: 20px; line-height: 1.4; color: var(--dim); letter-spacing: -.005em; }
  .win { position: absolute; border-radius: 14px; overflow: hidden; }
  .win img { display: block; width: 100%; }
  .win::after { content: ""; position: absolute; inset: 0; border-radius: inherit; pointer-events: none; }
  .meetings { left: 60px; top: 262px; width: 1060px; }
  .recall { left: 820px; top: 330px; width: 620px; height: 456px; border-radius: 18px; }
  .recall img { margin-top: -24.4px; }
  .bracket { position: absolute; left: 1454px; width: 12px; border: 1.5px solid var(--line);
             border-left: none; border-radius: 0 6px 6px 0; }
  .bracket .tag { position: absolute; left: 22px; top: 50%; transform: translateY(-50%);
                  font-size: 22px; font-weight: 700; letter-spacing: -.01em; }
  .b-saw { top: 404px; height: 154px; }
  .b-said { top: 573px; height: 153px; }
  .fade { position: absolute; left: 0; right: 0; bottom: 0; height: 110px; pointer-events: none; }
__THEME__
</style>
</head>
<body>
<div class="canvas">
  <div class="grid"></div>
  <header>
    <div class="brand"><img src="__ICON__" alt=""><span>LokalBot</span></div>
    <h1>Find what you <em>said</em> or <em>saw</em> on your Mac.</h1>
    <p class="sub">Meeting transcripts and opt-in screen text in one search. Free and open source.</p>
  </header>
  <div class="win meetings"><img src="__MEETINGS__" alt=""></div>
  <div class="win recall"><img src="__RECALL__" alt=""></div>
  <div class="bracket b-saw"><span class="tag">saw</span></div>
  <div class="bracket b-said"><span class="tag">said</span></div>
  <div class="fade"></div>
  <div class="noise"></div>
</div>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--theme", choices=sorted(THEMES), required=True)
    parser.add_argument("--meetings", required=True, help="meeting window capture, 2800x1760")
    parser.add_argument("--recall", required=True, help="Quick Recall capture, 2640x2048")
    parser.add_argument("--out", required=True)
    parser.add_argument("--chrome", default=os.environ.get("CHROME", CHROME))
    args = parser.parse_args()

    out = Path(args.out).resolve()
    page = (PAGE.replace("__THEME__", THEMES[args.theme])
            .replace("__ICON__", ICON.as_uri())
            .replace("__MEETINGS__", Path(args.meetings).resolve().as_uri())
            .replace("__RECALL__", Path(args.recall).resolve().as_uri()))
    with tempfile.TemporaryDirectory(prefix="lokalbot-hero-") as work:
        html = Path(work) / "hero.html"
        html.write_text(page, encoding="utf-8")
        shot = Path(work) / "hero.png"
        chrome = subprocess.Popen(
            [args.chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=2", "--window-size=1600,900",
             f"--user-data-dir={Path(work) / 'profile'}", "--virtual-time-budget=3000",
             f"--screenshot={shot}", html.as_uri()],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Headless Chrome keeps running after it writes the screenshot.
        deadline = time.monotonic() + 30
        while not (shot.exists() and shot.stat().st_size) and time.monotonic() < deadline:
            time.sleep(0.25)
        time.sleep(1)
        chrome.terminate()
        chrome.wait(timeout=10)
        if not shot.exists():
            raise SystemExit("Chrome did not write the screenshot")
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(shot, out)
    print(out)


if __name__ == "__main__":
    main()
