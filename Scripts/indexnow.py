#!/usr/bin/env python3
"""Tell IndexNow search engines (Bing, Yandex, Naver, Seznam) which pages changed.

The key is the name and content of web/<key>.txt, which the site serves at
https://www.lokalbot.com/<key>.txt so the engines can verify ownership. Run
this after a deploy that adds or changes pages; it is never run automatically.

Usage:
    python3 Scripts/indexnow.py --dry-run            # list what would be sent
    python3 Scripts/indexnow.py                      # every URL in the sitemap
    python3 Scripts/indexnow.py about benchmarks     # only these paths
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

HOST = "www.lokalbot.com"
ENDPOINT = "https://api.indexnow.org/indexnow"
WEB = Path(__file__).resolve().parent.parent / "web"
KEY_PATTERN = re.compile(r"^[0-9a-f]{32}\.txt$")


def find_key() -> str:
    keys = [path for path in WEB.iterdir() if KEY_PATTERN.match(path.name)]
    if len(keys) != 1:
        raise SystemExit(f"Expected exactly one IndexNow key file in web/, found {len(keys)}.")
    key = keys[0].read_text(encoding="utf-8").strip()
    if key != keys[0].stem:
        raise SystemExit(f"{keys[0].name} must contain its own name without .txt.")
    return key


def sitemap_urls() -> list[str]:
    sitemap = (WEB / "sitemap.xml").read_text(encoding="utf-8")
    return re.findall(r"<loc>([^<]+)</loc>", sitemap)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("paths", nargs="*", help="Site paths to submit, such as 'about'. Defaults to the sitemap.")
    parser.add_argument("--dry-run", action="store_true", help="Print the request instead of sending it.")
    args = parser.parse_args()

    key = find_key()
    urls = [f"https://{HOST}/{path.strip('/')}" for path in args.paths] or sitemap_urls()
    payload = {
        "host": HOST,
        "key": key,
        "keyLocation": f"https://{HOST}/{key}.txt",
        "urlList": urls,
    }
    if args.dry_run:
        print(json.dumps(payload, indent=2))
        return 0

    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        # 200 and 202 both mean accepted; 202 means the key is still being verified.
        print(f"IndexNow answered HTTP {response.status} for {len(urls)} URLs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
