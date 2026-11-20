#!/usr/bin/env python3
"""Zero-cookie weekly traffic dashboard for LokalBot.

Combines:
  1. Cloudflare Edge Analytics (Zone GraphQL API via read-only token, server-side only)
  2. Google Search Console (sc-domain:lokalbot.com via gcloud ADC)
  3. GitHub Traffic & Latest Release Downloads (via `gh api`)

Zero client-side tracking scripts or cookies are added to lokalbot.com.

Usage:
  python3 Scripts/dev/traffic-report.py                     # print terminal summary
  python3 Scripts/dev/traffic-report.py --save              # append snapshot to Local/traffic-history.jsonl
  python3 Scripts/dev/traffic-report.py --html              # render Local/lokalbot-traffic-dashboard.html
  python3 Scripts/dev/traffic-report.py --save --html --open
  python3 Scripts/dev/traffic-report.py --from-snapshot --html
  python3 Scripts/dev/traffic-report.py --json              # print machine-readable JSON
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Mapping

ROOT = Path(__file__).resolve().parents[2]
HISTORY_PATH = ROOT / "Local" / "traffic-history.jsonl"
DASHBOARD_HTML = ROOT / "Local" / "lokalbot-traffic-dashboard.html"
TOKEN_FILE = Path.home() / ".config" / "lokalbot" / "cloudflare-analytics-token"
WRANGLER_CONFIG = Path.home() / "Library" / "Preferences" / ".wrangler" / "config" / "default.toml"
GSC_SITE = "sc-domain:lokalbot.com"
GSC_QUOTA_PROJECT = "lokalbot-512410"
GH_REPO = "stevyhacker/LokalBot"
CF_ZONE_NAME = "lokalbot.com"


def http_json(
    url: str,
    headers: dict[str, str],
    body: dict | None = None,
    method: str | None = None,
) -> tuple[int, dict | str]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req_headers = dict(headers)
    if data is not None:
        req_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(
        url,
        data=data,
        headers=req_headers,
        method=method or ("POST" if data is not None else "GET"),
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")[:400]
    except Exception as exc:  # noqa: BLE001
        return 0, str(exc)


def fetch_gsc(days: int = 28) -> dict:
    try:
        token = subprocess.check_output(
            ["gcloud", "auth", "application-default", "print-access-token"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"gcloud ADC unavailable: {exc}"}

    headers = {
        "Authorization": f"Bearer {token}",
        "x-goog-user-project": GSC_QUOTA_PROJECT,
    }
    ep = urllib.parse.quote(GSC_SITE, safe="")
    base = f"https://www.googleapis.com/webmasters/v3/sites/{ep}/searchAnalytics/query"

    end = date.today() - timedelta(days=2)
    start = end - timedelta(days=days - 1)
    start_7 = end - timedelta(days=6)
    start_90 = end - timedelta(days=89)

    def query(payload: dict) -> dict:
        st, res = http_json(base, headers, payload)
        if st != 200 or not isinstance(res, dict):
            raise RuntimeError(f"HTTP {st}: {res}")
        return res

    try:
        tot_window = (query({"startDate": start.isoformat(), "endDate": end.isoformat()}).get("rows") or [{}])[0]
        tot_7 = (query({"startDate": start_7.isoformat(), "endDate": end.isoformat()}).get("rows") or [{}])[0]
        tot_90 = (query({"startDate": start_90.isoformat(), "endDate": end.isoformat()}).get("rows") or [{}])[0]
        daily = query({"startDate": start.isoformat(), "endDate": end.isoformat(), "dimensions": ["date"]}).get("rows", [])
        pages = query({"startDate": start.isoformat(), "endDate": end.isoformat(), "dimensions": ["page"], "rowLimit": 100}).get("rows", [])
        queries = query({"startDate": start.isoformat(), "endDate": end.isoformat(), "dimensions": ["query"], "rowLimit": 100}).get("rows", [])
        countries = query({"startDate": start.isoformat(), "endDate": end.isoformat(), "dimensions": ["country"], "rowLimit": 10}).get("rows", [])
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}

    def norm_tot(row: dict) -> dict:
        return {
            "clicks": int(round(row.get("clicks", 0))),
            "impressions": int(round(row.get("impressions", 0))),
            "ctr": round(row.get("ctr", 0.0) * 100, 2),
            "position": round(row.get("position", 0.0), 1),
        }

    norm_pages = sorted(
        [
            {
                "path": r["keys"][0].replace("https://www.lokalbot.com", "") or "/",
                "clicks": int(round(r["clicks"])),
                "impressions": int(round(r["impressions"])),
                "ctr": round(r["ctr"] * 100, 1),
                "position": round(r["position"], 1),
            }
            for r in pages
        ],
        key=lambda p: (p["impressions"], p["clicks"]),
        reverse=True,
    )[:15]
    norm_queries = sorted(
        [
            {
                "query": r["keys"][0],
                "clicks": int(round(r["clicks"])),
                "impressions": int(round(r["impressions"])),
                "ctr": round(r["ctr"] * 100, 1),
                "position": round(r["position"], 1),
            }
            for r in queries
        ],
        key=lambda q: (q["impressions"], q["clicks"]),
        reverse=True,
    )[:15]

    return {
        "ok": True,
        "range": {"start": start.isoformat(), "end": end.isoformat(), "days": days},
        "totals": norm_tot(tot_window),
        "last7d": norm_tot(tot_7),
        "last90d": norm_tot(tot_90),
        "daily": [
            {
                "date": r["keys"][0],
                "clicks": int(round(r["clicks"])),
                "impressions": int(round(r["impressions"])),
                "position": round(r["position"], 1),
            }
            for r in daily
        ],
        "pages": norm_pages,
        "queries": norm_queries,
        "countries": [
            {
                "country": r["keys"][0].upper(),
                "clicks": int(round(r["clicks"])),
                "impressions": int(round(r["impressions"])),
                "position": round(r["position"], 1),
            }
            for r in countries
        ],
    }


def load_cloudflare_token(
    token_file: Path = TOKEN_FILE,
    wrangler_config: Path = WRANGLER_CONFIG,
    env: Mapping[str, str] | None = None,
) -> tuple[str | None, str]:
    environ = os.environ if env is None else env
    for env_key in ("CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"):
        val = environ.get(env_key, "").strip()
        if val:
            return val, f"env:{env_key}"
    if token_file.is_file():
        val = token_file.read_text(encoding="utf-8").strip()
        if val:
            return val, "token-file"
    if wrangler_config.is_file():
        m = re.search(r'oauth_token\s*=\s*"([^"]+)"', wrangler_config.read_text(encoding="utf-8"))
        if m:
            return m.group(1), "wrangler-oauth"
    return None, "none"


def fetch_cloudflare(days: int = 14) -> dict:
    token, source = load_cloudflare_token()
    if not token:
        return {
            "ok": False,
            "source": source,
            "error": (
                "No Cloudflare API token found. Set CLOUDFLARE_API_TOKEN or save a "
                "read-only token to ~/.config/lokalbot/cloudflare-analytics-token."
            ),
        }

    headers = {"Authorization": f"Bearer {token}"}
    st, zones = http_json(f"https://api.cloudflare.com/client/v4/zones?name={CF_ZONE_NAME}", headers)
    if st != 200 or not isinstance(zones, dict) or not zones.get("result"):
        return {"ok": False, "source": source, "error": f"Zones API HTTP {st}: {zones}"}

    zone_id = zones["result"][0]["id"]
    end = date.today()
    start = end - timedelta(days=days - 1)
    gql = {
        "query": """
        query($zoneTag: String!, $start: Date!, $end: Date!) {
          viewer {
            zones(filter: {zoneTag: $zoneTag}) {
              httpRequests1dGroups(limit: 35, filter: {date_geq: $start, date_leq: $end}, orderBy: [date_ASC]) {
                dimensions { date }
                sum {
                  requests
                  pageViews
                  bytes
                  countryMap { clientCountryName requests }
                }
                uniq { uniques }
              }
            }
          }
        }
        """,
        "variables": {"zoneTag": zone_id, "start": start.isoformat(), "end": end.isoformat()},
    }
    gst, gres = http_json("https://api.cloudflare.com/client/v4/graphql", headers, gql)
    if gst != 200 or not isinstance(gres, dict) or gres.get("errors"):
        return {"ok": False, "source": source, "error": f"GraphQL HTTP {gst}: {gres}"}

    zones_data = ((gres.get("data") or {}).get("viewer") or {}).get("zones") or []
    groups = zones_data[0].get("httpRequests1dGroups", []) if zones_data else []

    country_totals: dict[str, int] = {}
    daily = []
    for g in groups:
        s = g.get("sum") or {}
        u = g.get("uniq") or {}
        daily.append(
            {
                "date": g["dimensions"]["date"],
                "uniques": int(u.get("uniques", 0)),
                "pageViews": int(s.get("pageViews", 0)),
                "requests": int(s.get("requests", 0)),
                "bytes": int(s.get("bytes", 0)),
            }
        )
        for cm in s.get("countryMap") or []:
            code = cm.get("clientCountryName") or "??"
            country_totals[code] = country_totals.get(code, 0) + int(cm.get("requests", 0))

    top_countries = [
        {"country": code, "requests": reqs}
        for code, reqs in sorted(country_totals.items(), key=lambda kv: kv[1], reverse=True)[:10]
    ]
    last7 = daily[-7:]
    return {
        "ok": True,
        "source": source,
        "zone": CF_ZONE_NAME,
        "range": {"start": start.isoformat(), "end": end.isoformat(), "days": len(daily)},
        "totals": {
            "uniquesSum": sum(d["uniques"] for d in daily),
            "pageViews": sum(d["pageViews"] for d in daily),
            "requests": sum(d["requests"] for d in daily),
            "bytesMB": round(sum(d["bytes"] for d in daily) / 1_000_000, 1),
        },
        "last7d": {
            "uniquesSum": sum(d["uniques"] for d in last7),
            "pageViews": sum(d["pageViews"] for d in last7),
            "requests": sum(d["requests"] for d in last7),
        },
        "daily": daily,
        "countries": top_countries,
    }


def fetch_github() -> dict:
    def gh_json(endpoint: str) -> dict | list:
        raw = subprocess.check_output(["gh", "api", endpoint], text=True, stderr=subprocess.DEVNULL)
        return json.loads(raw)

    try:
        views = gh_json(f"repos/{GH_REPO}/traffic/views")
        clones = gh_json(f"repos/{GH_REPO}/traffic/clones")
        refs = gh_json(f"repos/{GH_REPO}/traffic/popular/referrers")
        latest = gh_json(f"repos/{GH_REPO}/releases/latest")
        repo_meta = gh_json(f"repos/{GH_REPO}")
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"gh api failed: {exc}"}

    assets = sorted(
        [{"name": a["name"], "downloads": a["download_count"]} for a in latest.get("assets", [])],
        key=lambda a: a["downloads"],
        reverse=True,
    )
    return {
        "ok": True,
        "stars": repo_meta.get("stargazers_count", 0),
        "views14d": {
            "count": views.get("count", 0),
            "uniques": views.get("uniques", 0),
            "daily": [
                {"date": v["timestamp"][:10], "views": v["count"], "uniques": v["uniques"]}
                for v in views.get("views", [])
            ],
        },
        "clones14d": {"count": clones.get("count", 0), "uniques": clones.get("uniques", 0)},
        "referrers": refs[:10],
        "latestRelease": {
            "tag": latest.get("tag_name"),
            "published": latest.get("published_at"),
            "assets": assets[:12],
        },
    }


def compute_wow_delta(daily: list[dict], value_key: str) -> dict | None:
    """Compare the last 7 daily buckets against the preceding 7 daily buckets."""
    if len(daily) < 14:
        return None
    recent = sum(int(row.get(value_key, 0)) for row in daily[-7:])
    prior = sum(int(row.get(value_key, 0)) for row in daily[-14:-7])
    if prior <= 0:
        return {"recent": recent, "prior": prior, "pct": None}
    pct = round(((recent - prior) / prior) * 100.0, 1)
    return {"recent": recent, "prior": prior, "pct": pct}


def sanitize_report_for_export(report: dict) -> dict:
    """Return a shallow-sanitized copy suitable for embedding in HTML (no local paths)."""
    out = json.loads(json.dumps(report))
    cf = out.get("cloudflare")
    if isinstance(cf, dict):
        src = str(cf.get("source") or "")
        if "/" in src or "\\" in src:
            cf["source"] = "token-file"
    return out


def safe_json_for_script(data: object) -> str:
    """Serialize JSON safely for inline <script> blocks (prevents </script> breakouts)."""
    raw = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return (
        raw.replace("</", "<\\/")
        .replace("<!--", "<\\!--")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def save_snapshot(report: dict, history_path: Path = HISTORY_PATH) -> None:
    history_path.parent.mkdir(parents=True, exist_ok=True)
    with history_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(sanitize_report_for_export(report)) + "\n")


def load_latest_snapshot(history_path: Path = HISTORY_PATH) -> dict:
    if not history_path.is_file():
        raise FileNotFoundError(f"Snapshot history not found: {history_path}")
    lines = [line.strip() for line in history_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not lines:
        raise ValueError(f"Snapshot history is empty: {history_path}")
    return json.loads(lines[-1])


def render_dashboard_html(report: dict) -> str:
    payload = safe_json_for_script(sanitize_report_for_export(report))
    return _DASHBOARD_TEMPLATE.replace("__REPORT_JSON__", payload)


def write_dashboard_html(report: dict, output_path: Path = DASHBOARD_HTML) -> Path:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render_dashboard_html(report), encoding="utf-8")
    return output_path


def print_report(report: dict) -> None:
    print(f"LokalBot Traffic & Search Report — {report['generatedAt']}")
    print("=" * 72)

    cf = report["cloudflare"]
    print("\n[1] Cloudflare Edge Analytics (lokalbot.com, server-side / zero cookies)")
    if cf["ok"]:
        t = cf["totals"]
        l7 = cf["last7d"]
        delta = compute_wow_delta(cf.get("daily", []), "pageViews")
        delta_txt = f" ({delta['pct']:+.1f}% WoW)" if delta and delta["pct"] is not None else ""
        print(
            f"  {cf['range']['days']}d totals: {t['pageViews']:,} pageviews | "
            f"{t['uniquesSum']:,} sum daily unique IPs | {t['requests']:,} requests | {t['bytesMB']:.1f} MB"
        )
        print(
            f"  Last 7d:   {l7['pageViews']:,} pageviews{delta_txt} | "
            f"{l7['uniquesSum']:,} sum daily unique IPs | {l7['requests']:,} requests"
        )
        for d in cf["daily"][-7:]:
            print(f"    {d['date']} | {d['uniques']:5d} unique IPs | {d['pageViews']:6d} pageviews | {d['requests']:7d} reqs")
    else:
        print(f"  Unavailable ({cf.get('source', 'none')}): {cf['error']}")

    gsc = report["gsc"]
    print("\n[2] Google Search Console (sc-domain:lokalbot.com)")
    if gsc["ok"]:
        t = gsc["totals"]
        l7 = gsc["last7d"]
        l90 = gsc["last90d"]
        delta = compute_wow_delta(gsc.get("daily", []), "impressions")
        delta_txt = f" ({delta['pct']:+.1f}% WoW)" if delta and delta["pct"] is not None else ""
        print(
            f"  {gsc['range']['days']}d ({gsc['range']['start']}..{gsc['range']['end']}): "
            f"{t['impressions']:,} impr | {t['clicks']:,} clicks | {t['ctr']:.1f}% CTR | avg pos {t['position']}"
        )
        print(
            f"  Last 7d: {l7['impressions']:,} impr{delta_txt} | {l7['clicks']:,} clicks | "
            f"{l7['ctr']:.1f}% CTR | pos {l7['position']}  (90d: {l90['impressions']:,} impr / {l90['clicks']:,} clicks)"
        )
        print("  Top pages:")
        for p in gsc["pages"][:8]:
            print(f"    {p['clicks']:4d} clk | {p['impressions']:5d} impr | {p['ctr']:5.1f}% | pos {p['position']:4.1f} | {p['path']}")
    else:
        print(f"  Unavailable: {gsc['error']}")

    gh = report["github"]
    print("\n[3] GitHub Traffic & Latest Release (stevyhacker/LokalBot)")
    if gh["ok"]:
        v = gh["views14d"]
        c = gh["clones14d"]
        rel = gh["latestRelease"]
        print(
            f"  Stars: {gh['stars']:,} | 14d views: {v['count']:,} ({v['uniques']:,} uniques) | "
            f"clones: {c['count']:,} ({c['uniques']:,} uniques)"
        )
        print("  Top referrers (14d):")
        for r in gh["referrers"][:6]:
            print(f"    {r['uniques']:4d} uniques ({r['count']:4d} views) | {r['referrer']}")
        print(f"  Latest release {rel['tag']} ({rel['published']}):")
        for a in rel["assets"][:6]:
            print(f"    {a['downloads']:4d} | {a['name']}")
    else:
        print(f"  Unavailable: {gh['error']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Pull LokalBot zero-cookie traffic metrics and render dashboard HTML.")
    parser.add_argument("--days", type=int, default=28, help="GSC window in days (default: 28)")
    parser.add_argument("--cf-days", type=int, default=14, help="Cloudflare window in days (default: 14)")
    parser.add_argument("--json", action="store_true", help="Output JSON only")
    parser.add_argument("--save", action="store_true", help="Append snapshot to Local/traffic-history.jsonl")
    parser.add_argument("--history", type=Path, default=HISTORY_PATH, help="Snapshot JSONL path")
    parser.add_argument(
        "--from-snapshot",
        nargs="?",
        const=str(HISTORY_PATH),
        default=None,
        help="Render from latest saved snapshot instead of querying live APIs",
    )
    parser.add_argument(
        "--html",
        nargs="?",
        const=str(DASHBOARD_HTML),
        default=None,
        help="Write self-contained interactive HTML report (default: Local/lokalbot-traffic-dashboard.html)",
    )
    parser.add_argument("--open", action="store_true", help="Open the rendered HTML report in the default browser")
    args = parser.parse_args(argv)

    if args.from_snapshot is not None:
        report = load_latest_snapshot(Path(args.from_snapshot))
    else:
        report = {
            "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "cloudflare": fetch_cloudflare(args.cf_days),
            "gsc": fetch_gsc(args.days),
            "github": fetch_github(),
        }

    if args.save and args.from_snapshot is None:
        save_snapshot(report, args.history)

    html_target: Path | None = None
    if args.html is not None:
        html_target = Path(args.html)
    elif args.open:
        html_target = DASHBOARD_HTML

    if html_target is not None:
        write_dashboard_html(report, html_target)

    if args.json:
        print(json.dumps(sanitize_report_for_export(report), indent=2))
    else:
        print_report(report)
        if args.save and args.from_snapshot is None:
            print(f"\nSaved snapshot to {args.history}")
        if html_target is not None:
            print(f"Wrote dashboard HTML to {html_target}")

    if args.open and html_target is not None:
        webbrowser.open(html_target.resolve().as_uri())
    return 0


_DASHBOARD_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>LokalBot Traffic &amp; Search Report</title>
<style>
  :root {
    --ease-out: cubic-bezier(0.23, 1, 0.32, 1);

    /* Standalone LokalBot dark fallback tokens (used only when no host theme defines --background) */
    --lb-bg: #080d14;
    --lb-card: #101822;
    --lb-popover: #131e2b;
    --lb-secondary: #16212f;
    --lb-border: rgba(152, 182, 206, 0.14);
    --lb-fg: #ecf3f7;
    --lb-muted-fg: #8fa3b3;
    --lb-chart-1: #5b9cf6;
    --lb-chart-2: #24c6b0;
    --lb-warning: #f59e0b;
    --lb-success: #2dd4bf;
    --lb-accent-surface: rgba(36, 198, 176, 0.14);
    --lb-warning-surface: rgba(245, 158, 11, 0.15);
    --lb-radius: 12px;
    --lb-sans: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Inter", system-ui, sans-serif;
    --lb-mono: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;

    /* Resolved semantic design tokens (host CSS vars always win) */
    --c-card: var(--card, var(--lb-card));
    --c-popover: var(--popover, var(--lb-popover));
    --c-secondary: var(--secondary, var(--lb-secondary));
    --c-border: var(--border, var(--lb-border));
    --c-fg: var(--foreground, var(--lb-fg));
    --c-muted: var(--muted-foreground, var(--lb-muted-fg));
    --c-teal: var(--chart-2, var(--lb-chart-2));
    --c-blue: var(--chart-1, var(--lb-chart-1));
    --c-warn: var(--warning, var(--lb-warning));
    --c-ok: var(--success, var(--lb-success));
    --c-accent-bg: var(--accent-surface, var(--lb-accent-surface));
    --c-warn-bg: var(--warning-surface, var(--lb-warning-surface));
    --c-radius: var(--radius, var(--lb-radius));
    --f-sans: var(--font-sans, var(--lb-sans));
    --f-mono: var(--font-mono, var(--lb-mono));
  }

  @media (prefers-color-scheme: light) {
    :root:not([data-theme="dark"]) {
      --lb-bg: #f4f7f8;
      --lb-card: #ffffff;
      --lb-popover: #ffffff;
      --lb-secondary: #edf2f5;
      --lb-border: rgba(14, 24, 36, 0.10);
      --lb-fg: #0e141c;
      --lb-muted-fg: #546674;
      --lb-chart-1: #2563eb;
      --lb-chart-2: #0c8275;
      --lb-warning: #c26d00;
      --lb-success: #0d9488;
      --lb-accent-surface: rgba(12, 130, 117, 0.10);
      --lb-warning-surface: rgba(217, 119, 6, 0.12);
    }
  }

  :root[data-theme="light"] {
    --lb-bg: #f4f7f8;
    --lb-card: #ffffff;
    --lb-popover: #ffffff;
    --lb-secondary: #edf2f5;
    --lb-border: rgba(14, 24, 36, 0.10);
    --lb-fg: #0e141c;
    --lb-muted-fg: #546674;
    --lb-chart-1: #2563eb;
    --lb-chart-2: #0c8275;
    --lb-warning: #c26d00;
    --lb-success: #0d9488;
    --lb-accent-surface: rgba(12, 130, 117, 0.10);
    --lb-warning-surface: rgba(217, 119, 6, 0.12);
  }

  *, *::before, *::after { box-sizing: border-box; }

  html, body {
    margin: 0;
    padding: 0;
    background: transparent;
    color: var(--c-fg);
    font-family: var(--f-sans);
    font-feature-settings: "cv02", "cv03", "cv04", "cv11";
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }

  /* Standalone browser presentation (never active when embedded in T3 host) */
  html.is-standalone {
    background-color: var(--lb-bg);
    background-image:
      radial-gradient(680px 360px at 14% -8%, color-mix(in srgb, var(--lb-chart-2) 12%, transparent), transparent 70%),
      radial-gradient(540px 320px at 88% 0%, color-mix(in srgb, var(--lb-chart-1) 9%, transparent), transparent 70%);
    background-repeat: no-repeat;
  }
  html.is-standalone body {
    max-width: 1020px;
    margin: 0 auto;
    padding: 28px 24px 48px;
  }

  .standalone-bar {
    display: none;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 16px;
    padding-bottom: 14px;
    border-bottom: 1px solid var(--c-border);
  }
  html.is-standalone .standalone-bar {
    display: flex;
  }
  .brand {
    display: inline-flex;
    align-items: center;
    gap: 10px;
  }
  .brand__mark {
    width: 26px;
    height: 26px;
    border-radius: 7px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: color-mix(in srgb, var(--c-teal) 16%, var(--c-card));
    border: 1px solid color-mix(in srgb, var(--c-teal) 35%, transparent);
    color: var(--c-teal);
  }
  .brand__title {
    margin: 0;
    font-size: 14.5px;
    font-weight: 650;
    letter-spacing: -0.02em;
    color: var(--c-fg);
  }
  .brand__sub {
    margin: 1px 0 0;
    font-size: 11.5px;
    color: var(--c-muted);
  }
  .theme-btn {
    appearance: none;
    border: 1px solid var(--c-border);
    background: var(--c-card);
    color: var(--c-muted);
    font: 550 11.5px/1 var(--f-sans);
    padding: 7px 11px;
    border-radius: 999px;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    transition: transform 140ms var(--ease-out), color 140ms ease, border-color 140ms ease;
  }
  .theme-btn:active { transform: scale(0.97); }
  @media (hover: hover) and (pointer: fine) {
    .theme-btn:hover {
      color: var(--c-fg);
      border-color: color-mix(in srgb, var(--c-fg) 22%, transparent);
    }
  }

  /* Main layout stack */
  .dash {
    display: flex;
    flex-direction: column;
    gap: 12px;
    width: 100%;
  }

  /* Elevated surface card */
  .card {
    background: var(--c-card);
    color: var(--c-fg);
    border: 1px solid var(--c-border);
    border-radius: var(--c-radius);
    padding: 16px;
    min-width: 0;
    box-shadow: inset 0 1px 0 color-mix(in srgb, var(--c-fg) 4%, transparent);
  }

  /* KPI Telemetry Grid */
  .kpis {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px;
  }
  @media (max-width: 620px) {
    .kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  }
  .kpi {
    position: relative;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    padding: 13px 13px 12px;
    overflow: hidden;
    transition: border-color 160ms ease;
  }
  @media (hover: hover) and (pointer: fine) {
    .kpi:hover {
      border-color: color-mix(in srgb, var(--c-fg) 18%, var(--c-border));
    }
  }
  .kpi__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    margin-bottom: 10px;
  }
  .kpi__label {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 10px;
    font-weight: 650;
    text-transform: uppercase;
    letter-spacing: 0.045em;
    color: var(--c-muted);
    margin: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .kpi__dot {
    width: 6px;
    height: 6px;
    border-radius: 99px;
    flex: 0 0 auto;
  }
  .kpi__badge {
    flex: 0 0 auto;
    font-family: var(--f-mono);
    font-size: 10px;
    font-weight: 600;
    line-height: 1;
    padding: 3px 6px;
    border-radius: 999px;
    font-variant-numeric: tabular-nums;
    background: var(--c-secondary);
    color: var(--c-muted);
  }
  .kpi__badge--up {
    background: color-mix(in srgb, var(--c-ok) 15%, transparent);
    color: var(--c-ok);
  }
  .kpi__badge--warn {
    background: color-mix(in srgb, var(--c-warn) 16%, transparent);
    color: var(--c-warn);
  }
  .kpi__main {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 8px;
    min-height: 30px;
  }
  .kpi__val {
    font-family: var(--f-sans);
    font-size: 25px;
    font-weight: 700;
    letter-spacing: -0.035em;
    line-height: 1.05;
    font-variant-numeric: tabular-nums;
    color: var(--c-fg);
    margin: 0;
  }
  .kpi__spark {
    flex: 0 0 auto;
    width: 62px;
    height: 26px;
    display: block;
    overflow: visible;
  }
  .kpi__mix {
    flex: 0 0 auto;
    width: 58px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    align-items: flex-end;
    padding-bottom: 3px;
  }
  .kpi__mixbar {
    width: 100%;
    height: 6px;
    border-radius: 99px;
    overflow: hidden;
    display: flex;
    gap: 1.5px;
    background: var(--c-secondary);
  }
  .kpi__mixseg {
    height: 100%;
    border-radius: 2px;
  }
  .kpi__mixlbl {
    font-family: var(--f-mono);
    font-size: 9.5px;
    color: var(--c-muted);
    font-variant-numeric: tabular-nums;
  }
  .kpi__foot {
    margin: 10px 0 0;
    padding-top: 8px;
    border-top: 1px solid color-mix(in srgb, var(--c-border) 72%, transparent);
    font-size: 11px;
    line-height: 1.3;
    color: var(--c-muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-variant-numeric: tabular-nums;
  }
  .kpi__foot strong {
    color: var(--c-fg);
    font-weight: 600;
  }

  /* Card Header + Compact Segmented Tabs */
  .head {
    display: flex;
    flex-direction: column;
    gap: 3px;
    margin-bottom: 12px;
  }
  .head__row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 8px 10px;
  }
  .head h2 {
    margin: 0;
    font-size: 13.5px;
    font-weight: 650;
    letter-spacing: -0.015em;
    color: var(--c-fg);
    line-height: 1.25;
  }
  .head__sub {
    margin: 0;
    font-size: 11.5px;
    line-height: 1.38;
    color: var(--c-muted);
  }
  .head__sub strong {
    color: var(--c-fg);
    font-weight: 600;
  }

  .tabs {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    gap: 2px;
    padding: 3px;
    border-radius: 9px;
    background: var(--c-secondary);
    border: 1px solid var(--c-border);
  }
  .tab {
    appearance: none;
    border: 1px solid transparent;
    background: transparent;
    color: var(--c-muted);
    font: 600 11px/1 var(--f-sans);
    padding: 5px 9px;
    border-radius: 6px;
    cursor: pointer;
    white-space: nowrap;
    transition: transform 140ms var(--ease-out), background-color 140ms ease, color 140ms ease, border-color 140ms ease;
  }
  .tab:active { transform: scale(0.97); }
  .tab:focus-visible {
    outline: 2px solid var(--c-teal);
    outline-offset: 1px;
  }
  @media (hover: hover) and (pointer: fine) {
    .tab:hover:not(.is-active):not(:disabled) { color: var(--c-fg); }
  }
  .tab.is-active {
    background: var(--c-card);
    color: var(--c-fg);
    border-color: color-mix(in srgb, var(--c-fg) 10%, var(--c-border));
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.18);
  }
  .tab:disabled {
    opacity: 0.42;
    cursor: not-allowed;
  }

  /* Summary Metric Chips inside Chart Card */
  .metrics-strip {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-bottom: 12px;
  }
  .mchip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 9px;
    border-radius: 7px;
    background: color-mix(in srgb, var(--c-secondary) 78%, transparent);
    border: 1px solid color-mix(in srgb, var(--c-border) 80%, transparent);
    font-size: 11px;
    color: var(--c-muted);
    font-variant-numeric: tabular-nums;
  }
  .mchip b {
    color: var(--c-fg);
    font-family: var(--f-mono);
    font-size: 11px;
    font-weight: 650;
  }

  /* Main Trend Chart */
  .chart-wrap {
    position: relative;
    width: 100%;
    height: 224px;
  }
  .chart-svg {
    display: block;
    width: 100%;
    height: 224px;
    overflow: visible;
  }
  .chart-bar {
    transition: opacity 130ms ease;
  }
  .chart-foot {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 8px 14px;
    margin-top: 10px;
    padding-top: 9px;
    border-top: 1px solid color-mix(in srgb, var(--c-border) 72%, transparent);
    font-size: 11px;
    color: var(--c-muted);
  }
  .chart-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
  }
  .leg-item {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .swatch {
    width: 10px;
    height: 10px;
    border-radius: 3px;
    display: inline-block;
  }
  .swatch--line {
    width: 14px;
    height: 2.5px;
    border-radius: 2px;
  }
  .swatch--partial {
    width: 10px;
    height: 10px;
    border-radius: 3px;
    border: 1px dashed var(--c-muted);
    background: color-mix(in srgb, var(--c-blue) 16%, transparent);
  }
  .chart-note {
    font-family: var(--f-mono);
    font-size: 10.5px;
    color: var(--c-muted);
  }

  /* Floating Chart Tooltip */
  .tooltip {
    position: absolute;
    top: 6px;
    left: 0;
    pointer-events: none;
    background: color-mix(in srgb, var(--c-popover) 94%, transparent);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    color: var(--c-fg);
    border: 1px solid color-mix(in srgb, var(--c-fg) 14%, var(--c-border));
    border-radius: 9px;
    padding: 8px 11px;
    font-size: 11.5px;
    line-height: 1.45;
    box-shadow: 0 10px 26px rgba(0, 0, 0, 0.28);
    opacity: 0;
    transform: translateY(2px) scale(0.98);
    transition: opacity 110ms var(--ease-out), transform 110ms var(--ease-out);
    white-space: nowrap;
    z-index: 20;
    font-variant-numeric: tabular-nums;
  }
  .tooltip.is-show {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
  .tooltip.is-instant {
    transition-duration: 0ms;
  }
  .tooltip__date {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    font-family: var(--f-mono);
    font-size: 10.5px;
    font-weight: 650;
    color: var(--c-fg);
    padding-bottom: 4px;
    margin-bottom: 4px;
    border-bottom: 1px solid var(--c-border);
  }
  .tooltip__row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    color: var(--c-muted);
    font-size: 11px;
  }
  .tooltip__row b {
    color: var(--c-fg);
    font-family: var(--f-mono);
    font-weight: 650;
  }

  /* Two-Column Analytical Breakdown */
  .split {
    display: grid;
    grid-template-columns: minmax(0, 1.08fr) minmax(0, 1fr);
    gap: 12px;
  }
  .split > * { min-width: 0; }
  @media (max-width: 640px) {
    .split { grid-template-columns: minmax(0, 1fr); }
  }

  .rows {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .drow {
    display: flex;
    flex-direction: column;
    gap: 5px;
    padding: 6px 8px;
    margin: 0 -8px;
    border-radius: 8px;
    transition: background-color 120ms ease;
  }
  @media (hover: hover) and (pointer: fine) {
    .drow:hover {
      background: color-mix(in srgb, var(--c-secondary) 72%, transparent);
    }
  }
  .drow__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-size: 12px;
    min-height: 18px;
  }
  .drow__left {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    flex: 1 1 auto;
  }
  .drow__code {
    flex: 0 0 auto;
    font-family: var(--f-mono);
    font-size: 9.5px;
    font-weight: 650;
    line-height: 1;
    padding: 3px 5px;
    border-radius: 4px;
    background: var(--c-secondary);
    color: var(--c-muted);
    letter-spacing: 0.03em;
  }
  .drow__name {
    font-weight: 550;
    color: var(--c-fg);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }
  .drow__name--mono {
    font-family: var(--f-mono);
    font-size: 11px;
    font-weight: 550;
  }
  .drow__stats {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-family: var(--f-mono);
    font-size: 10.5px;
    color: var(--c-muted);
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  .drow__primary {
    color: var(--c-fg);
    font-weight: 650;
  }
  .drow__track {
    height: 3.5px;
    border-radius: 99px;
    background: color-mix(in srgb, var(--c-secondary) 92%, transparent);
    overflow: hidden;
  }
  .drow__fill {
    height: 100%;
    border-radius: 99px;
    background: linear-gradient(90deg, color-mix(in srgb, var(--c-blue) 75%, transparent), var(--c-blue));
  }
  .drow__fill--teal {
    background: linear-gradient(90deg, color-mix(in srgb, var(--c-teal) 75%, transparent), var(--c-teal));
  }
  .drow__fill--warn {
    background: linear-gradient(90deg, color-mix(in srgb, var(--c-warn) 78%, transparent), var(--c-warn));
  }

  .pill {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    font-family: var(--f-mono);
    font-size: 9.5px;
    font-weight: 650;
    line-height: 1;
    padding: 2.5px 5.5px;
    border-radius: 5px;
    background: var(--c-secondary);
    color: var(--c-muted);
  }
  .pill--teal {
    background: color-mix(in srgb, var(--c-teal) 15%, transparent);
    color: var(--c-teal);
  }
  .pill--warn {
    background: color-mix(in srgb, var(--c-warn) 16%, transparent);
    color: var(--c-warn);
  }
  .pill--blue {
    background: color-mix(in srgb, var(--c-blue) 15%, transparent);
    color: var(--c-blue);
  }

  .empty {
    padding: 26px 12px;
    text-align: center;
    font-size: 12px;
    color: var(--c-muted);
    border: 1px dashed var(--c-border);
    border-radius: 9px;
  }

  /* Compact Telemetry Footer */
  .meta-bar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 10px 16px;
    padding: 11px 16px;
  }
  .pipes {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 12px;
  }
  .pipe {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 11.5px;
    font-weight: 550;
    color: var(--c-fg);
  }
  .pipe__sub {
    color: var(--c-muted);
    font-weight: 450;
    font-size: 11px;
  }
  .sdot {
    width: 7px;
    height: 7px;
    border-radius: 99px;
    flex: 0 0 auto;
    background: var(--c-ok);
    box-shadow: 0 0 0 2.5px color-mix(in srgb, var(--c-ok) 22%, transparent);
  }
  .sdot--off {
    background: var(--c-warn);
    box-shadow: 0 0 0 2.5px color-mix(in srgb, var(--c-warn) 22%, transparent);
  }
  .meta-right {
    display: inline-flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    font-size: 11px;
    color: var(--c-muted);
  }
  .privacy-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 8px;
    border-radius: 999px;
    background: color-mix(in srgb, var(--c-teal) 12%, transparent);
    color: var(--c-teal);
    font-size: 10.5px;
    font-weight: 600;
  }
  .cmd-pill {
    font-family: var(--f-mono);
    font-size: 10.5px;
    color: var(--c-muted);
    padding: 2.5px 7px;
    border-radius: 6px;
    background: var(--c-secondary);
    border: 1px solid var(--c-border);
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      transition-duration: 0.01ms !important;
      animation-duration: 0.01ms !important;
    }
  }
</style>
<script>
(() => {
  try {
    const hostBg = getComputedStyle(document.documentElement).getPropertyValue("--background").trim();
    if (!hostBg) document.documentElement.classList.add("is-standalone");
  } catch (_) {}
})();
</script>
</head>
<body>
<header class="standalone-bar">
  <div class="brand">
    <span class="brand__mark" aria-hidden="true">
      <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
        <path d="M2.5 11.5L6 7.5L9 9.5L13.5 4.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
        <circle cx="13.5" cy="4.5" r="1.6" fill="currentColor"/>
      </svg>
    </span>
    <div>
      <h1 class="brand__title">LokalBot Traffic &amp; Search Report</h1>
      <p class="brand__sub" id="standalone-sub">Zero-cookie telemetry · Cloudflare Edge, Google Search Console &amp; GitHub</p>
    </div>
  </div>
  <button type="button" class="theme-btn" id="theme-toggle" aria-label="Toggle color theme">Theme</button>
</header>

<div class="dash">
  <!-- KPI Telemetry Strip -->
  <section class="kpis" id="kpi-grid" aria-label="Key metrics"></section>

  <!-- Primary Interactive Trend Card -->
  <section class="card" aria-label="Daily traffic trend">
    <div class="head">
      <div class="head__row">
        <h2 id="trend-title">Daily Traffic</h2>
        <div class="tabs" role="tablist" aria-label="Traffic source" id="trend-tabs">
          <button type="button" class="tab" data-trend="cf" role="tab" aria-selected="false">Cloudflare</button>
          <button type="button" class="tab" data-trend="gsc" role="tab" aria-selected="false">Search</button>
          <button type="button" class="tab" data-trend="gh" role="tab" aria-selected="false">GitHub</button>
        </div>
      </div>
      <p class="head__sub" id="trend-sub"></p>
    </div>
    <div class="metrics-strip" id="trend-chips"></div>
    <div class="chart-wrap" id="trend-wrap">
      <svg class="chart-svg" id="trend-svg" role="img" aria-label="Daily traffic chart"></svg>
      <div class="tooltip" id="trend-tip" role="status" aria-live="polite"></div>
    </div>
    <div class="chart-foot">
      <div class="chart-legend" id="trend-legend"></div>
      <span class="chart-note" id="trend-note"></span>
    </div>
  </section>

  <!-- Dual Analytical Breakdown -->
  <section class="split">
    <div class="card" aria-label="Search and release breakdown">
      <div class="head">
        <div class="head__row">
          <h2 id="left-title">Top Pages</h2>
          <div class="tabs" role="tablist" aria-label="Left breakdown" id="left-tabs">
            <button type="button" class="tab" data-left="pages" role="tab" aria-selected="false">Pages</button>
            <button type="button" class="tab" data-left="queries" role="tab" aria-selected="false">Queries</button>
            <button type="button" class="tab" data-left="releases" role="tab" aria-selected="false">Releases</button>
          </div>
        </div>
        <p class="head__sub" id="left-sub"></p>
      </div>
      <div class="rows" id="left-list"></div>
    </div>

    <div class="card" aria-label="Geography and referrers breakdown">
      <div class="head">
        <div class="head__row">
          <h2 id="right-title">Edge Countries</h2>
          <div class="tabs" role="tablist" aria-label="Right breakdown" id="right-tabs">
            <button type="button" class="tab" data-right="cf" role="tab" aria-selected="false">Edge</button>
            <button type="button" class="tab" data-right="countries" role="tab" aria-selected="false">Search</button>
            <button type="button" class="tab" data-right="referrers" role="tab" aria-selected="false">Referrers</button>
          </div>
        </div>
        <p class="head__sub" id="right-sub"></p>
      </div>
      <div class="rows" id="right-list"></div>
    </div>
  </section>

  <!-- Compact Live Pipeline Footer -->
  <footer class="card meta-bar" id="meta-bar"></footer>
</div>

<script>
(() => {
  const REPORT = __REPORT_JSON__;

  const ISO2_NAMES = {
    US:"United States", NL:"Netherlands", BE:"Belgium", CA:"Canada", DE:"Germany",
    CH:"Switzerland", JP:"Japan", GB:"United Kingdom", ZA:"South Africa", FR:"France",
    AU:"Australia", BR:"Brazil", IN:"India", IT:"Italy", ES:"Spain", SE:"Sweden",
    NO:"Norway", DK:"Denmark", FI:"Finland", PL:"Poland", SG:"Singapore", KR:"South Korea",
    CN:"China", TW:"Taiwan", HK:"Hong Kong", AT:"Austria", IE:"Ireland", NZ:"New Zealand",
    MX:"Mexico", PT:"Portugal", CZ:"Czechia", IL:"Israel", TR:"Turkey", UA:"Ukraine",
    RU:"Russia", RO:"Romania", AR:"Argentina", CL:"Chile", CO:"Colombia", ID:"Indonesia",
    MY:"Malaysia", TH:"Thailand", VN:"Vietnam", PH:"Philippines", AE:"UAE", SA:"Saudi Arabia"
  };

  const ISO3_TO_ISO2 = {
    USA:"US", NLD:"NL", BEL:"BE", CAN:"CA", DEU:"DE", CHE:"CH", JPN:"JP", GBR:"GB",
    ZAF:"ZA", FRA:"FR", AUS:"AU", BRA:"BR", IND:"IN", ITA:"IT", ESP:"ES", SWE:"SE",
    NOR:"NO", DNK:"DK", FIN:"FI", POL:"PL", SGP:"SG", KOR:"KR", CHN:"CN", TWN:"TW",
    HKG:"HK", AUT:"AT", IRL:"IE", NZL:"NZ", MEX:"MX", PRT:"PT", CZE:"CZ", ISR:"IL",
    TUR:"TR", UKR:"UA", RUS:"RU", ROU:"RO", ARG:"AR", CHL:"CL", COL:"CO", IDN:"ID",
    MYS:"MY", THA:"TH", VNM:"VN", PHL:"PH", ARE:"AE", SAU:"SA"
  };

  const LOCALIZED_LANG = { DE:"/de", AT:"/de", CH:"/de", JP:"/ja", CN:"/zh", TW:"/zh", RU:"/ru" };
  const MONTHS = ["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

  function esc(val) {
    return String(val ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function fmtDate(iso) {
    if (!iso || typeof iso !== "string") return "";
    const parts = iso.slice(0, 10).split("-");
    if (parts.length !== 3) return iso;
    return `${MONTHS[Number(parts[1])] || parts[1]} ${Number(parts[2])}`;
  }

  function fmtStamp(iso) {
    if (!iso) return "";
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(iso);
    if (!m) return iso;
    return `${MONTHS[Number(m[2])]} ${Number(m[3])}, ${m[4]}:${m[5]} UTC`;
  }

  function fmtCompact(n) {
    const v = Number(n || 0);
    if (v >= 1000000) return `${(v / 1000000).toFixed(1)}M`;
    if (v >= 10000) return `${(v / 1000).toFixed(1)}k`;
    if (v >= 1000) return `${(v / 1000).toFixed(1)}k`;
    return String(Math.round(v));
  }

  function fmtInt(n) {
    return Number(n || 0).toLocaleString("en-US");
  }

  function wowDelta(daily, key) {
    if (!Array.isArray(daily) || daily.length < 14) return null;
    const recent = daily.slice(-7).reduce((s, r) => s + Number(r[key] || 0), 0);
    const prior = daily.slice(-14, -7).reduce((s, r) => s + Number(r[key] || 0), 0);
    if (prior <= 0) return null;
    const pct = ((recent - prior) / prior) * 100;
    return { recent, prior, pct: Math.round(pct * 10) / 10 };
  }

  function countryInfo(code) {
    const upper = String(code || "??").toUpperCase();
    const iso2 = upper.length === 3 ? (ISO3_TO_ISO2[upper] || upper.slice(0, 2)) : upper;
    return {
      iso2,
      name: ISO2_NAMES[iso2] || upper,
      lang: LOCALIZED_LANG[iso2] || ""
    };
  }

  // Monotone cubic Bezier path (Fritsch-Carlson) — smooth curves with zero overshoot
  function smoothPath(points) {
    if (!points.length) return "";
    if (points.length === 1) return `M${points[0].x.toFixed(1)},${points[0].y.toFixed(1)}`;
    const n = points.length;
    const dx = [], dy = [], m = [], t = new Array(n).fill(0);
    for (let i = 0; i < n - 1; i++) {
      dx.push(points[i + 1].x - points[i].x);
      dy.push(points[i + 1].y - points[i].y);
      m.push(dx[i] === 0 ? 0 : dy[i] / dx[i]);
    }
    t[0] = m[0];
    t[n - 1] = m[n - 2];
    for (let i = 1; i < n - 1; i++) {
      if (m[i - 1] * m[i] <= 0) {
        t[i] = 0;
      } else {
        t[i] = (m[i - 1] + m[i]) / 2;
      }
    }
    for (let i = 0; i < n - 1; i++) {
      if (m[i] === 0) {
        t[i] = 0;
        t[i + 1] = 0;
      } else {
        const a = t[i] / m[i];
        const b = t[i + 1] / m[i];
        const s = a * a + b * b;
        if (s > 9) {
          const tau = 3 / Math.sqrt(s);
          t[i] = tau * a * m[i];
          t[i + 1] = tau * b * m[i];
        }
      }
    }
    let d = `M${points[0].x.toFixed(1)},${points[0].y.toFixed(1)}`;
    for (let i = 0; i < n - 1; i++) {
      const h = dx[i] / 3;
      const c1x = points[i].x + h;
      const c1y = points[i].y + t[i] * h;
      const c2x = points[i + 1].x - h;
      const c2y = points[i + 1].y - t[i + 1] * h;
      d += ` C${c1x.toFixed(1)},${c1y.toFixed(1)} ${c2x.toFixed(1)},${c2y.toFixed(1)} ${points[i + 1].x.toFixed(1)},${points[i + 1].y.toFixed(1)}`;
    }
    return d;
  }

  function renderSparkline(values, colorVar, id) {
    if (!values || values.length < 2) return "";
    const W = 62, H = 26, padY = 3;
    const maxV = Math.max(1, ...values);
    const minV = Math.min(...values);
    const span = Math.max(1, maxV - minV * 0.65);
    const pts = values.map((v, i) => ({
      x: (i / (values.length - 1)) * (W - 4) + 2,
      y: padY + (1 - Math.max(0, (v - minV * 0.65) / span)) * (H - padY * 2)
    }));
    const lineD = smoothPath(pts);
    const areaD = `${lineD} L${pts[pts.length - 1].x.toFixed(1)},${H} L${pts[0].x.toFixed(1)},${H} Z`;
    const last = pts[pts.length - 1];
    return `
      <svg class="kpi__spark" viewBox="0 0 ${W} ${H}" aria-hidden="true">
        <defs>
          <linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="${colorVar}" stop-opacity="0.34"/>
            <stop offset="100%" stop-color="${colorVar}" stop-opacity="0.0"/>
          </linearGradient>
        </defs>
        <path d="${areaD}" fill="url(#${id})"/>
        <path d="${lineD}" fill="none" stroke="${colorVar}" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"/>
        <circle cx="${last.x.toFixed(1)}" cy="${last.y.toFixed(1)}" r="2.2" fill="${colorVar}"/>
      </svg>`;
  }

  function classifyReleaseAssets(assets) {
    let mac = 0, win = 0, mcpb = 0, apk = 0, linux = 0, appcast = 0, other = 0;
    for (const a of (assets || [])) {
      const name = String(a.name || "").toLowerCase();
      const dl = Number(a.downloads || 0);
      if (name.includes("appcast") || name.endsWith(".xml") || name.endsWith(".json") || name.endsWith(".sig")) {
        appcast += dl;
      } else if (name.endsWith(".dmg") || name.includes("mac") || name.includes("darwin")) {
        mac += dl;
      } else if (name.endsWith(".exe") || name.endsWith(".msi") || name.includes("win")) {
        win += dl;
      } else if (name.endsWith(".mcpb")) {
        mcpb += dl;
      } else if (name.endsWith(".apk") || name.includes("android")) {
        apk += dl;
      } else if (name.endsWith(".appimage") || name.endsWith(".deb") || name.includes("linux")) {
        linux += dl;
      } else {
        other += dl;
      }
    }
    return { mac, win, mcpb, apk, linux, other, installers: mac + win + mcpb + apk + linux + other, appcast };
  }

  function assetCategory(name) {
    const lower = String(name || "").toLowerCase();
    if (lower.includes("appcast") || lower.endsWith(".xml")) return { label: "Feed", cls: "" };
    if (lower.endsWith(".json") || lower.endsWith(".sig")) return { label: "Meta", cls: "" };
    if (lower.endsWith(".dmg") || lower.includes("mac")) return { label: "macOS", cls: "pill--teal" };
    if (lower.endsWith(".exe") || lower.endsWith(".msi") || lower.includes("win")) return { label: "Win", cls: "pill--blue" };
    if (lower.endsWith(".mcpb")) return { label: "MCPB", cls: "pill--warn" };
    if (lower.endsWith(".apk") || lower.includes("android")) return { label: "APK", cls: "pill--teal" };
    if (lower.endsWith(".appimage") || lower.endsWith(".deb") || lower.includes("linux")) return { label: "Linux", cls: "pill--teal" };
    return { label: "Asset", cls: "" };
  }

  function fmtPctDelta(pct, suffix) {
    const rounded = Math.abs(pct) >= 10 ? Math.round(pct) : Math.round(pct * 10) / 10;
    return `${rounded >= 0 ? "+" : ""}${rounded}%${suffix ? ` ${suffix}` : ""}`;
  }

  const cf = REPORT.cloudflare || { ok: false };
  const gsc = REPORT.gsc || { ok: false };
  const gh = REPORT.github || { ok: false };

  // Standalone theme toggle
  const subEl = document.getElementById("standalone-sub");
  if (subEl && REPORT.generatedAt) {
    subEl.textContent = `Zero-cookie telemetry · Updated ${fmtStamp(REPORT.generatedAt)}`;
  }
  const themeBtn = document.getElementById("theme-toggle");
  if (themeBtn) {
    const syncThemeLabel = () => {
      const cur = document.documentElement.getAttribute("data-theme");
      const isLight = cur === "light" || (!cur && window.matchMedia("(prefers-color-scheme: light)").matches);
      themeBtn.textContent = isLight ? "Dark mode" : "Light mode";
    };
    syncThemeLabel();
    themeBtn.addEventListener("click", () => {
      const cur = document.documentElement.getAttribute("data-theme");
      const isLight = cur === "light" || (!cur && window.matchMedia("(prefers-color-scheme: light)").matches);
      document.documentElement.setAttribute("data-theme", isLight ? "dark" : "light");
      syncThemeLabel();
    });
  }

  // 1. Render KPI Strip
  function renderKPIs() {
    const cards = [];

    // Card 1: Cloudflare
    if (cf.ok) {
      const d = wowDelta(cf.daily, "pageViews");
      const badgeTxt = d ? fmtPctDelta(d.pct, "") : `${cf.range.days}d`;
      const badgeTitle = d ? `Last 7d (${fmtInt(d.recent)}) vs prior 7d (${fmtInt(d.prior)})` : `${cf.range.days}d window`;
      const badgeCls = d ? (d.pct >= 0 ? "kpi__badge--up" : "kpi__badge--warn") : "";
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-teal)"></span>Cloudflare</p>
            <span class="kpi__badge ${badgeCls}" title="${esc(badgeTitle)}">${esc(badgeTxt)}</span>
          </div>
          <div class="kpi__main">
            <p class="kpi__val">${fmtInt(cf.totals.pageViews)}</p>
            ${renderSparkline((cf.daily || []).map(x => x.pageViews), "var(--c-teal)", "sp-cf")}
          </div>
          <p class="kpi__foot"><strong>${fmtCompact(cf.totals.requests)}</strong> reqs · <strong>${fmtInt(cf.last7d.pageViews)}</strong> 7d</p>
        </article>`);
    } else {
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-warn)"></span>Cloudflare</p>
            <span class="kpi__badge kpi__badge--warn">Offline</span>
          </div>
          <div class="kpi__main"><p class="kpi__val">—</p></div>
          <p class="kpi__foot">Set <strong>CLOUDFLARE_API_TOKEN</strong></p>
        </article>`);
    }

    // Card 2: Google Search Console
    if (gsc.ok) {
      const d = wowDelta(gsc.daily, "impressions");
      const pct90 = gsc.last90d && gsc.last90d.impressions > 0
        ? Math.round((gsc.totals.impressions / gsc.last90d.impressions) * 100)
        : null;
      const badgeTxt = d ? fmtPctDelta(d.pct, "WoW") : (pct90 !== null ? `${pct90}% 90d` : `${gsc.range.days}d`);
      const badgeTitle = d ? `Last 7d (${fmtInt(d.recent)}) vs prior 7d (${fmtInt(d.prior)})` : `${gsc.range.days}d window`;
      const badgeCls = d ? (d.pct >= 0 ? "kpi__badge--up" : "kpi__badge--warn") : "kpi__badge--up";
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-blue)"></span>Search</p>
            <span class="kpi__badge ${badgeCls}" title="${esc(badgeTitle)}">${esc(badgeTxt)}</span>
          </div>
          <div class="kpi__main">
            <p class="kpi__val">${fmtInt(gsc.totals.impressions)}</p>
            ${renderSparkline((gsc.daily || []).map(x => x.impressions), "var(--c-blue)", "sp-gsc")}
          </div>
          <p class="kpi__foot"><strong>${fmtInt(gsc.totals.clicks)}</strong> clicks · <strong>${Number(gsc.totals.ctr).toFixed(1)}%</strong> CTR · #${esc(gsc.totals.position)}</p>
        </article>`);
    } else {
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-warn)"></span>Search</p>
            <span class="kpi__badge kpi__badge--warn">Offline</span>
          </div>
          <div class="kpi__main"><p class="kpi__val">—</p></div>
          <p class="kpi__foot">Run <strong>gcloud ADC</strong> auth</p>
        </article>`);
    }

    // Card 3: GitHub Repo Views
    if (gh.ok) {
      const daily = (gh.views14d && gh.views14d.daily) || [];
      const d = wowDelta(daily, "views");
      const badgeTxt = d ? fmtPctDelta(d.pct, "7d") : `${fmtInt(gh.stars)} ★`;
      const badgeTitle = d ? `Last 7d (${fmtInt(d.recent)}) vs prior 7d (${fmtInt(d.prior)})` : "14d views";
      const badgeCls = d ? (d.pct >= 0 ? "kpi__badge--up" : "kpi__badge--warn") : "";
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-teal)"></span>GitHub</p>
            <span class="kpi__badge ${badgeCls}" title="${esc(badgeTitle)}">${esc(badgeTxt)}</span>
          </div>
          <div class="kpi__main">
            <p class="kpi__val">${fmtInt(gh.views14d.count)}</p>
            ${renderSparkline(daily.map(x => x.views), "var(--c-teal)", "sp-gh")}
          </div>
          <p class="kpi__foot"><strong>${fmtInt(gh.views14d.uniques)}</strong> uniq · <strong>${fmtInt(gh.stars)}</strong> ★ · 14d</p>
        </article>`);
    } else {
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-warn)"></span>GitHub</p>
            <span class="kpi__badge kpi__badge--warn">Offline</span>
          </div>
          <div class="kpi__main"><p class="kpi__val">—</p></div>
          <p class="kpi__foot">Authenticate <strong>gh cli</strong></p>
        </article>`);
    }

    // Card 4: Latest Release Downloads
    if (gh.ok && gh.latestRelease) {
      const rel = gh.latestRelease;
      const mix = classifyReleaseAssets(rel.assets);
      const total = Math.max(1, mix.installers);
      const parts = [
        { n: mix.mac, lbl: "Mac", color: "var(--c-teal)" },
        { n: mix.win, lbl: "Win", color: "var(--c-blue)" },
        { n: mix.mcpb, lbl: "MCP", color: "var(--c-warn)" },
        { n: mix.apk, lbl: "APK", color: "var(--c-ok)" },
        { n: mix.linux, lbl: "Linux", color: "var(--c-teal)" },
        { n: mix.other, lbl: "Other", color: "var(--c-muted)" }
      ].filter(p => p.n > 0);
      const shown = parts.slice(0, 3);
      const restCount = parts.slice(3).reduce((s, p) => s + p.n, 0);
      const footItems = shown.map(p => `<strong>${p.n}</strong> ${p.lbl}`);
      if (restCount > 0) footItems.push(`<strong>+${restCount}</strong>`);
      const footHtml = footItems.length ? footItems.join("&thinsp;·&thinsp;") : "No installer downloads yet";
      const mixTitle = parts.map(p => `${p.lbl} ${p.n}`).join(" · ");
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-blue)"></span>${esc(rel.tag || "Release")}</p>
            <span class="kpi__badge">${esc(fmtDate(rel.published) || "Latest")}</span>
          </div>
          <div class="kpi__main">
            <p class="kpi__val">${fmtInt(mix.installers)}</p>
            <div class="kpi__mix" title="${esc(mixTitle)}">
              <span class="kpi__mixlbl">${fmtInt(mix.appcast)} checks</span>
              <div class="kpi__mixbar">
                ${parts.map(p => `<span class="kpi__mixseg" style="width:${((p.n / total) * 100).toFixed(1)}%;background:${p.color}"></span>`).join("")}
              </div>
            </div>
          </div>
          <p class="kpi__foot" title="${esc(mixTitle)}">${footHtml}</p>
        </article>`);
    } else {
      cards.push(`
        <article class="card kpi">
          <div class="kpi__top">
            <p class="kpi__label"><span class="kpi__dot" style="background:var(--c-muted)"></span>Release</p>
            <span class="kpi__badge">N/A</span>
          </div>
          <div class="kpi__main"><p class="kpi__val">—</p></div>
          <p class="kpi__foot">No release metadata</p>
        </article>`);
    }

    document.getElementById("kpi-grid").innerHTML = cards.join("");
  }

  // 2. Render Main Interactive Dual-Axis Chart
  const svg = document.getElementById("trend-svg");
  const tip = document.getElementById("trend-tip");
  const wrap = document.getElementById("trend-wrap");
  const trendTitle = document.getElementById("trend-title");
  const trendSub = document.getElementById("trend-sub");
  const trendChips = document.getElementById("trend-chips");
  const trendLegend = document.getElementById("trend-legend");
  const trendNote = document.getElementById("trend-note");

  let activeTrend = cf.ok && (cf.daily || []).length ? "cf"
    : (gsc.ok && (gsc.daily || []).length ? "gsc"
    : (gh.ok && ((gh.views14d && gh.views14d.daily) || []).length ? "gh" : "cf"));
  let tipShownOnce = false;

  function trendConfig(mode) {
    if (mode === "cf" && cf.ok && (cf.daily || []).length) {
      const rows = cf.daily;
      const peak = rows.reduce((a, b) => (b.pageViews > a.pageViews ? b : a), rows[0]);
      const avg = Math.round(cf.totals.pageViews / Math.max(1, rows.length));
      const reportDay = (REPORT.generatedAt || "").slice(0, 10);
      const lastPartial = rows.length > 0 && rows[rows.length - 1].date === reportDay;
      return {
        ok: true,
        rows,
        barKey: "pageViews",
        lineKey: "uniques",
        barLabel: "Pageviews",
        lineLabel: "Daily unique IPs",
        barVar: "var(--c-blue)",
        lineVar: "var(--c-teal)",
        lastPartial,
        title: `Cloudflare Edge Daily Traffic`,
        sub: `${fmtDate(rows[0].date)} – ${fmtDate(rows[rows.length - 1].date)} · <strong>${fmtInt(cf.totals.pageViews)}</strong> pageviews across ${rows.length} days`,
        chips: [
          { k: "Daily avg", v: fmtInt(avg) },
          { k: "Peak", v: `${fmtInt(peak.pageViews)} · ${fmtDate(peak.date)}` },
          { k: "Bandwidth", v: cf.totals.bytesMB >= 1000 ? `${(cf.totals.bytesMB / 1000).toFixed(2)} GB` : `${cf.totals.bytesMB} MB` }
        ],
        note: lastPartial ? `${fmtDate(rows[rows.length - 1].date)} partial · includes bots` : "Server-side edge · includes bots",
        tooltip: (r, isPartial) => `
          <div class="tooltip__date"><span>${esc(fmtDate(r.date))}${isPartial ? " · partial" : ""}</span></div>
          <div class="tooltip__row"><span>Pageviews</span><b>${fmtInt(r.pageViews)}</b></div>
          <div class="tooltip__row"><span>Unique IPs</span><b>${fmtInt(r.uniques)}</b></div>
          <div class="tooltip__row"><span>Requests</span><b>${fmtInt(r.requests)}</b></div>`
      };
    }

    if (mode === "gsc" && gsc.ok && (gsc.daily || []).length) {
      const rows = gsc.daily;
      const peak = rows.reduce((a, b) => (b.impressions > a.impressions ? b : a), rows[0]);
      const d = wowDelta(rows, "impressions");
      const firstVal = Math.max(1, rows[0].impressions || 0);
      const lastVal = rows[rows.length - 1].impressions || 0;
      const mult = (lastVal / firstVal).toFixed(1);
      return {
        ok: true,
        rows,
        barKey: "impressions",
        lineKey: "clicks",
        barLabel: "Impressions",
        lineLabel: "Clicks",
        barVar: "var(--c-blue)",
        lineVar: "var(--c-teal)",
        lastPartial: false,
        title: `Google Search Console Daily Trend`,
        sub: `${fmtDate(rows[0].date)} – ${fmtDate(rows[rows.length - 1].date)} · <strong>${fmtInt(gsc.totals.impressions)}</strong> impressions (${mult}× start-to-end)`,
        chips: [
          { k: "Last 7d", v: `${fmtInt(gsc.last7d.impressions)} impr · ${fmtInt(gsc.last7d.clicks)} clk` },
          { k: "Peak", v: `${fmtInt(peak.impressions)} · ${fmtDate(peak.date)}` },
          { k: d ? "7d vs prior" : "90d total", v: d ? `${d.pct >= 0 ? "+" : ""}${d.pct}%` : fmtInt(gsc.last90d.impressions) }
        ],
        note: "sc-domain:lokalbot.com · ~2d GSC lag",
        tooltip: (r) => `
          <div class="tooltip__date"><span>${esc(fmtDate(r.date))}</span><span>pos #${esc(r.position)}</span></div>
          <div class="tooltip__row"><span>Impressions</span><b>${fmtInt(r.impressions)}</b></div>
          <div class="tooltip__row"><span>Clicks</span><b>${fmtInt(r.clicks)}</b></div>`
      };
    }

    if (mode === "gh" && gh.ok && ((gh.views14d && gh.views14d.daily) || []).length) {
      const rows = gh.views14d.daily;
      const peak = rows.reduce((a, b) => (b.views > a.views ? b : a), rows[0]);
      return {
        ok: true,
        rows,
        barKey: "views",
        lineKey: "uniques",
        barLabel: "Repo views",
        lineLabel: "Unique visitors",
        barVar: "var(--c-blue)",
        lineVar: "var(--c-teal)",
        lastPartial: false,
        title: `GitHub Repository Daily Traffic`,
        sub: `${fmtDate(rows[0].date)} – ${fmtDate(rows[rows.length - 1].date)} · <strong>${fmtInt(gh.views14d.count)}</strong> views (${fmtInt(gh.views14d.uniques)} uniques)`,
        chips: [
          { k: "14d Clones", v: `${fmtInt(gh.clones14d.count)} (${fmtInt(gh.clones14d.uniques)} uniq)` },
          { k: "Peak", v: `${fmtInt(peak.views)} · ${fmtDate(peak.date)}` },
          { k: "Stars", v: fmtInt(gh.stars) }
        ],
        note: "stevyhacker/LokalBot · 14d rolling",
        tooltip: (r) => `
          <div class="tooltip__date"><span>${esc(fmtDate(r.date))}</span></div>
          <div class="tooltip__row"><span>Total views</span><b>${fmtInt(r.views)}</b></div>
          <div class="tooltip__row"><span>Unique visitors</span><b>${fmtInt(r.uniques)}</b></div>`
      };
    }

    return { ok: false, mode };
  }

  function niceCeiling(raw, minCap) {
    // Pick a ceiling divisible by 4 into clean round tick steps (e.g. 400 -> 1600, 50 -> 200)
    const targetStep = Math.max(minCap / 4, (raw * 1.12) / 4);
    const mag = Math.pow(10, Math.floor(Math.log10(targetStep)));
    const norm = targetStep / mag;
    const niceUnit = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 4 ? 4 : norm <= 5 ? 5 : 10;
    return niceUnit * mag * 4;
  }

  function renderTrend(mode) {
    activeTrend = mode;
    document.querySelectorAll("#trend-tabs .tab").forEach((btn) => {
      const key = btn.getAttribute("data-trend");
      const avail = (key === "cf" && cf.ok && (cf.daily || []).length)
        || (key === "gsc" && gsc.ok && (gsc.daily || []).length)
        || (key === "gh" && gh.ok && ((gh.views14d && gh.views14d.daily) || []).length);
      btn.disabled = !avail;
      const on = key === mode;
      btn.classList.toggle("is-active", on);
      btn.setAttribute("aria-selected", on ? "true" : "false");
    });

    const cfg = trendConfig(mode);
    tip.classList.remove("is-show");
    tipShownOnce = false;

    if (!cfg.ok) {
      trendTitle.textContent = "Daily Traffic";
      trendSub.textContent = "No daily series available for this source.";
      trendChips.innerHTML = "";
      svg.innerHTML = "";
      trendLegend.innerHTML = "";
      trendNote.textContent = "";
      return;
    }

    trendTitle.textContent = cfg.title;
    trendSub.innerHTML = cfg.sub;
    trendChips.innerHTML = cfg.chips
      .map(c => `<span class="mchip">${esc(c.k)} <b>${esc(c.v)}</b></span>`)
      .join("");
    trendLegend.innerHTML = `
      <span class="leg-item"><span class="swatch" style="background:${cfg.barVar};opacity:0.62;"></span>${esc(cfg.barLabel)}</span>
      <span class="leg-item"><span class="swatch swatch--line" style="background:${cfg.lineVar};"></span>${esc(cfg.lineLabel)}</span>
      ${cfg.lastPartial ? `<span class="leg-item"><span class="swatch--partial"></span>In-progress day</span>` : ""}`;
    trendNote.textContent = cfg.note;

    const W = Math.max(300, Math.round(wrap.clientWidth || 680));
    const H = 224;
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);

    const compact = W < 440;
    const pad = { top: 14, right: compact ? 32 : 40, bottom: 26, left: compact ? 34 : 42 };
    const cw = W - pad.left - pad.right;
    const ch = H - pad.top - pad.bottom;
    const rows = cfg.rows;

    const maxBar = niceCeiling(Math.max(1, ...rows.map(r => Number(r[cfg.barKey] || 0))), 4);
    const maxLine = niceCeiling(Math.max(1, ...rows.map(r => Number(r[cfg.lineKey] || 0))), 4);

    const step = cw / rows.length;
    const barW = Math.max(6, Math.min(26, step * 0.56));
    const baseY = pad.top + ch;

    let out = `<defs>
      <linearGradient id="barGrad" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="${cfg.barVar}" stop-opacity="0.48"/>
        <stop offset="100%" stop-color="${cfg.barVar}" stop-opacity="0.09"/>
      </linearGradient>
      <linearGradient id="barGradHi" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="${cfg.barVar}" stop-opacity="0.78"/>
        <stop offset="100%" stop-color="${cfg.barVar}" stop-opacity="0.22"/>
      </linearGradient>
      <linearGradient id="areaGrad" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="${cfg.lineVar}" stop-opacity="0.22"/>
        <stop offset="100%" stop-color="${cfg.lineVar}" stop-opacity="0.0"/>
      </linearGradient>
    </defs>`;

    // Horizontal grid + axis ticks
    const ticks = 4;
    for (let k = 0; k <= ticks; k++) {
      const y = baseY - (ch * k) / ticks;
      const bVal = Math.round((maxBar * k) / ticks);
      const lVal = Math.round((maxLine * k) / ticks);
      out += `<line x1="${pad.left}" y1="${y.toFixed(1)}" x2="${(W - pad.right).toFixed(1)}" y2="${y.toFixed(1)}" stroke="var(--c-border)" stroke-opacity="${k === 0 ? "0.95" : "0.55"}" ${k === 0 ? "" : 'stroke-dasharray="2.5 3.5"'} />`;
      out += `<text x="${pad.left - 7}" y="${(y + 3.5).toFixed(1)}" text-anchor="end" fill="var(--c-muted)" font-size="10" font-family="var(--f-mono)">${fmtCompact(bVal)}</text>`;
      out += `<text x="${(W - pad.right + 7).toFixed(1)}" y="${(y + 3.5).toFixed(1)}" text-anchor="start" fill="${cfg.lineVar}" fill-opacity="0.88" font-size="10" font-family="var(--f-mono)">${fmtCompact(lVal)}</text>`;
    }

    const pts = [];
    const labelTarget = compact ? 4 : 5;
    const labelStride = Math.max(1, Math.round((rows.length - 1) / (labelTarget - 1)));

    rows.forEach((row, idx) => {
      const cx = pad.left + step * idx + step / 2;
      const bVal = Number(row[cfg.barKey] || 0);
      const lVal = Number(row[cfg.lineKey] || 0);
      const bh = Math.max(1.5, (bVal / maxBar) * ch);
      const by = baseY - bh;
      const ly = baseY - (lVal / maxLine) * ch;
      const isPartial = cfg.lastPartial && idx === rows.length - 1;
      pts.push({ x: cx, y: ly, by, bh, row, idx, isPartial });

      if (isPartial) {
        out += `<rect class="chart-bar" data-bar="${idx}" x="${(cx - barW / 2).toFixed(1)}" y="${by.toFixed(1)}" width="${barW.toFixed(1)}" height="${bh.toFixed(1)}" rx="3.5" fill="url(#barGrad)" fill-opacity="0.48" stroke="${cfg.barVar}" stroke-opacity="0.55" stroke-dasharray="3 2.5" stroke-width="1" />`;
      } else {
        out += `<rect class="chart-bar" data-bar="${idx}" x="${(cx - barW / 2).toFixed(1)}" y="${by.toFixed(1)}" width="${barW.toFixed(1)}" height="${bh.toFixed(1)}" rx="3.5" fill="url(#barGrad)" />`;
      }

      const showX = idx === 0 || idx === rows.length - 1 || (idx % labelStride === 0 && rows.length - 1 - idx >= Math.ceil(labelStride * 0.55));
      if (showX) {
        out += `<text x="${cx.toFixed(1)}" y="${H - 6}" text-anchor="middle" fill="var(--c-muted)" font-size="10" font-family="var(--f-mono)">${esc(fmtDate(row.date))}</text>`;
      }
    });

    // Smooth spline area + curve
    const lineD = smoothPath(pts);
    if (pts.length > 1) {
      const areaD = `${lineD} L${pts[pts.length - 1].x.toFixed(1)},${baseY.toFixed(1)} L${pts[0].x.toFixed(1)},${baseY.toFixed(1)} Z`;
      out += `<path d="${areaD}" fill="url(#areaGrad)" pointer-events="none" />`;
    }
    out += `<path d="${lineD}" fill="none" stroke="${cfg.lineVar}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" pointer-events="none" />`;

    // Crosshair & active highlight (hidden until hover)
    out += `<g id="chart-hover" opacity="0" pointer-events="none">
      <line id="hover-line" x1="0" y1="${pad.top}" x2="0" y2="${baseY}" stroke="var(--c-fg)" stroke-opacity="0.22" stroke-dasharray="3 3" stroke-width="1" />
      <circle id="hover-halo" cx="0" cy="0" r="8" fill="${cfg.lineVar}" fill-opacity="0.22" />
      <circle id="hover-dot" cx="0" cy="0" r="3.8" fill="var(--c-card)" stroke="${cfg.lineVar}" stroke-width="2.2" />
    </g>`;

    // Subtle terminal + peak dots (clean, uncluttered)
    const peakPt = pts.reduce((a, b) => (b.y < a.y ? b : a), pts[0]);
    const showDots = rows.length <= 16 ? pts : [pts[0], peakPt, pts[pts.length - 1]];
    const seen = new Set();
    showDots.forEach((p) => {
      if (seen.has(p.idx)) return;
      seen.add(p.idx);
      out += `<circle cx="${p.x.toFixed(1)}" cy="${p.y.toFixed(1)}" r="2.8" fill="var(--c-card)" stroke="${cfg.lineVar}" stroke-width="1.8" pointer-events="none" />`;
    });

    // Full-column hover hit zones
    pts.forEach((p) => {
      out += `<rect data-hit="${p.idx}" x="${(p.x - step / 2).toFixed(1)}" y="${pad.top}" width="${step.toFixed(1)}" height="${ch}" fill="transparent" style="cursor:crosshair;" />`;
    });

    svg.innerHTML = out;

    const hoverGroup = svg.getElementById("chart-hover");
    const hoverLine = svg.getElementById("hover-line");
    const hoverHalo = svg.getElementById("hover-halo");
    const hoverDot = svg.getElementById("hover-dot");
    let activeBarEl = null;

    function activate(idx) {
      const p = pts[idx];
      if (!p) return;
      if (activeBarEl) activeBarEl.setAttribute("fill", "url(#barGrad)");
      activeBarEl = svg.querySelector(`rect[data-bar="${idx}"]`);
      if (activeBarEl) activeBarEl.setAttribute("fill", "url(#barGradHi)");

      hoverLine.setAttribute("x1", p.x.toFixed(1));
      hoverLine.setAttribute("x2", p.x.toFixed(1));
      hoverHalo.setAttribute("cx", p.x.toFixed(1));
      hoverHalo.setAttribute("cy", p.y.toFixed(1));
      hoverDot.setAttribute("cx", p.x.toFixed(1));
      hoverDot.setAttribute("cy", p.y.toFixed(1));
      hoverGroup.setAttribute("opacity", "1");

      tip.innerHTML = cfg.tooltip(p.row, p.isPartial);
      tip.classList.toggle("is-instant", tipShownOnce);
      tip.classList.add("is-show");
      tipShownOnce = true;

      const wrapW = wrap.clientWidth || W;
      const tipW = tip.offsetWidth || 165;
      const preferRight = p.x + 14 + tipW <= wrapW - 4;
      const left = preferRight
        ? Math.min(wrapW - tipW - 4, p.x + 14)
        : Math.max(4, p.x - tipW - 14);
      tip.style.left = `${left}px`;
    }

    function clearHover() {
      if (activeBarEl) {
        activeBarEl.setAttribute("fill", "url(#barGrad)");
        activeBarEl = null;
      }
      hoverGroup.setAttribute("opacity", "0");
      tip.classList.remove("is-show", "is-instant");
      tipShownOnce = false;
    }

    svg.querySelectorAll("rect[data-hit]").forEach((hit) => {
      const idx = Number(hit.getAttribute("data-hit"));
      hit.addEventListener("mouseenter", () => activate(idx));
      hit.addEventListener("click", () => activate(idx));
    });
    svg.addEventListener("mouseleave", clearHover);
  }

  // 3. Left Breakdown Card (Pages / Queries / Releases)
  const leftTitle = document.getElementById("left-title");
  const leftSub = document.getElementById("left-sub");
  const leftList = document.getElementById("left-list");

  let activeLeft = gsc.ok && (gsc.pages || []).length ? "pages"
    : (gh.ok && gh.latestRelease && (gh.latestRelease.assets || []).length ? "releases" : "pages");

  function renderLeft(mode) {
    activeLeft = mode;
    document.querySelectorAll("#left-tabs .tab").forEach((btn) => {
      const key = btn.getAttribute("data-left");
      const avail = (key === "pages" && gsc.ok && (gsc.pages || []).length)
        || (key === "queries" && gsc.ok && (gsc.queries || []).length)
        || (key === "releases" && gh.ok && gh.latestRelease && (gh.latestRelease.assets || []).length);
      btn.disabled = !avail;
      const on = key === mode;
      btn.classList.toggle("is-active", on);
      btn.setAttribute("aria-selected", on ? "true" : "false");
    });

    if (mode === "pages" && gsc.ok && (gsc.pages || []).length) {
      const items = [...gsc.pages]
        .sort((a, b) => (Number(b.impressions || 0) - Number(a.impressions || 0)) || (Number(b.clicks || 0) - Number(a.clicks || 0)))
        .slice(0, 8);
      const maxV = Math.max(1, ...items.map(p => Number(p.impressions || 0)));
      leftTitle.textContent = "Top Pages";
      leftSub.textContent = `${gsc.range.days}d Search impressions · amber = low-CTR titles.`;
      leftList.innerHTML = items.map((p) => {
        const pct = Math.max(3, (Number(p.impressions || 0) / maxV) * 100);
        const lowCtr = Number(p.impressions || 0) >= 120 && Number(p.ctr || 0) < 1.5;
        const strongCtr = Number(p.ctr || 0) >= 4.0;
        const ctrCls = lowCtr ? "pill--warn" : strongCtr ? "pill--teal" : "";
        const fillCls = lowCtr ? "drow__fill--warn" : "";
        const isHome = p.path === "/";
        return `
          <div class="drow" title="${esc(p.path)} · pos #${esc(p.position)}">
            <div class="drow__top">
              <span class="drow__left">
                <span class="drow__name drow__name--mono">${esc(p.path)}</span>
                ${isHome ? `<span class="pill">home</span>` : ""}
              </span>
              <span class="drow__stats">
                <span class="drow__primary">${fmtInt(p.impressions)}</span>
                <span>${fmtInt(p.clicks)} clk</span>
                <span class="pill ${ctrCls}">${Number(p.ctr || 0).toFixed(1)}%</span>
              </span>
            </div>
            <div class="drow__track"><div class="drow__fill ${fillCls}" style="width:${pct.toFixed(1)}%"></div></div>
          </div>`;
      }).join("");
      return;
    }

    if (mode === "queries" && gsc.ok && (gsc.queries || []).length) {
      const items = [...gsc.queries]
        .sort((a, b) => (Number(b.impressions || 0) - Number(a.impressions || 0)) || (Number(b.clicks || 0) - Number(a.clicks || 0)))
        .slice(0, 8);
      const maxV = Math.max(1, ...items.map(q => Number(q.impressions || 0)));
      leftTitle.textContent = "Top Queries";
      leftSub.textContent = `${gsc.range.days}d Search terms by impressions, clicks, and average rank.`;
      leftList.innerHTML = items.map((q) => {
        const pct = Math.max(3, (Number(q.impressions || 0) / maxV) * 100);
        const topRank = Number(q.position || 99) <= 5.0;
        return `
          <div class="drow" title="${esc(q.query)} · ${Number(q.ctr || 0).toFixed(1)}% CTR">
            <div class="drow__top">
              <span class="drow__left">
                <span class="drow__name">${esc(q.query)}</span>
              </span>
              <span class="drow__stats">
                <span class="drow__primary">${fmtInt(q.impressions)}</span>
                <span>${fmtInt(q.clicks)} clk</span>
                <span class="pill ${topRank ? "pill--teal" : ""}">#${Number(q.position || 0).toFixed(1)}</span>
              </span>
            </div>
            <div class="drow__track"><div class="drow__fill drow__fill--teal" style="width:${pct.toFixed(1)}%"></div></div>
          </div>`;
      }).join("");
      return;
    }

    if (mode === "releases" && gh.ok && gh.latestRelease && (gh.latestRelease.assets || []).length) {
      const rel = gh.latestRelease;
      const items = rel.assets.slice(0, 8);
      const maxV = Math.max(1, ...items.map(a => Number(a.downloads || 0)));
      leftTitle.textContent = `Release ${rel.tag || "Latest"}`;
      leftSub.textContent = rel.published ? `Published ${fmtStamp(rel.published)} · asset download counts.` : "GitHub release asset downloads.";
      leftList.innerHTML = items.map((a) => {
        const pct = Math.max(3, (Number(a.downloads || 0) / maxV) * 100);
        const cat = assetCategory(a.name);
        return `
          <div class="drow" title="${esc(a.name)}">
            <div class="drow__top">
              <span class="drow__left">
                <span class="pill ${cat.cls}">${esc(cat.label)}</span>
                <span class="drow__name drow__name--mono">${esc(a.name)}</span>
              </span>
              <span class="drow__stats">
                <span class="drow__primary">${fmtInt(a.downloads)}</span>
                <span>dl</span>
              </span>
            </div>
            <div class="drow__track"><div class="drow__fill drow__fill--teal" style="width:${pct.toFixed(1)}%"></div></div>
          </div>`;
      }).join("");
      return;
    }

    leftTitle.textContent = "Search & Releases";
    leftSub.textContent = "Data unavailable for this tab.";
    leftList.innerHTML = `<div class="empty">Authenticate Google Search Console or GitHub CLI to populate this view.</div>`;
  }

  // 4. Right Breakdown Card (Edge Geo / Search Geo / GitHub Referrers)
  const rightTitle = document.getElementById("right-title");
  const rightSub = document.getElementById("right-sub");
  const rightList = document.getElementById("right-list");

  let activeRight = cf.ok && (cf.countries || []).length ? "cf"
    : (gsc.ok && (gsc.countries || []).length ? "countries"
    : (gh.ok && (gh.referrers || []).length ? "referrers" : "cf"));

  function renderRight(mode) {
    activeRight = mode;
    document.querySelectorAll("#right-tabs .tab").forEach((btn) => {
      const key = btn.getAttribute("data-right");
      const avail = (key === "cf" && cf.ok && (cf.countries || []).length)
        || (key === "countries" && gsc.ok && (gsc.countries || []).length)
        || (key === "referrers" && gh.ok && (gh.referrers || []).length);
      btn.disabled = !avail;
      const on = key === mode;
      btn.classList.toggle("is-active", on);
      btn.setAttribute("aria-selected", on ? "true" : "false");
    });

    if (mode === "cf" && cf.ok && (cf.countries || []).length) {
      const items = cf.countries.slice(0, 8);
      const totalReqs = Math.max(1, Number((cf.totals && cf.totals.requests) || 0));
      const maxV = Math.max(1, ...items.map(c => Number(c.requests || 0)));
      rightTitle.textContent = "Edge Countries";
      rightSub.textContent = `${cf.range.days}d Cloudflare requests by country (human visits & bots).`;
      rightList.innerHTML = items.map((c) => {
        const info = countryInfo(c.country);
        const share = ((Number(c.requests || 0) / totalReqs) * 100).toFixed(1);
        const pct = Math.max(3, (Number(c.requests || 0) / maxV) * 100);
        return `
          <div class="drow" title="${esc(info.name)}: ${fmtInt(c.requests)} requests (${share}%)">
            <div class="drow__top">
              <span class="drow__left">
                <span class="drow__code">${esc(info.iso2)}</span>
                <span class="drow__name">${esc(info.name)}</span>
                ${info.lang ? `<span class="pill pill--teal">${esc(info.lang)}</span>` : ""}
              </span>
              <span class="drow__stats">
                <span class="drow__primary">${fmtCompact(c.requests)}</span>
                <span>${share}%</span>
              </span>
            </div>
            <div class="drow__track"><div class="drow__fill drow__fill--teal" style="width:${pct.toFixed(1)}%"></div></div>
          </div>`;
      }).join("");
      return;
    }

    if (mode === "countries" && gsc.ok && (gsc.countries || []).length) {
      const items = gsc.countries.slice(0, 8);
      const maxV = Math.max(1, ...items.map(c => Number(c.clicks || 0)));
      rightTitle.textContent = "Search Countries";
      rightSub.textContent = `${gsc.range.days}d organic Google clicks & impressions by country.`;
      rightList.innerHTML = items.map((c) => {
        const info = countryInfo(c.country);
        const pct = Math.max(3, (Number(c.clicks || 0) / maxV) * 100);
        return `
          <div class="drow" title="${esc(info.name)}: ${fmtInt(c.clicks)} clicks, ${fmtInt(c.impressions)} impr">
            <div class="drow__top">
              <span class="drow__left">
                <span class="drow__code">${esc(info.iso2)}</span>
                <span class="drow__name">${esc(info.name)}</span>
                ${info.lang ? `<span class="pill pill--teal">${esc(info.lang)}</span>` : ""}
              </span>
              <span class="drow__stats">
                <span class="drow__primary">${fmtInt(c.clicks)} clk</span>
                <span>${fmtCompact(c.impressions)} impr</span>
              </span>
            </div>
            <div class="drow__track"><div class="drow__fill" style="width:${pct.toFixed(1)}%"></div></div>
          </div>`;
      }).join("");
      return;
    }

    if (mode === "referrers" && gh.ok && (gh.referrers || []).length) {
      const items = gh.referrers.slice(0, 8);
      const maxV = Math.max(1, ...items.map(r => Number(r.uniques || 0)));
      rightTitle.textContent = "GitHub Referrers";
      rightSub.textContent = "14d external sources sending unique visitors to the repo.";
      rightList.innerHTML = items.map((r) => {
        const ref = String(r.referrer || "");
        const pct = Math.max(3, (Number(r.uniques || 0) / maxV) * 100);
        const isSite = ref.includes("lokalbot.com");
        const isHf = ref.includes("huggingface") || ref.includes("hf.space");
        const cleanName = ref.replace(/^android-app:\/\//, "").replace(/^com\.reddit\.frontpage$/, "reddit (android)");
        return `
          <div class="drow" title="${esc(ref)}: ${fmtInt(r.uniques)} uniques, ${fmtInt(r.count)} views">
            <div class="drow__top">
              <span class="drow__left">
                <span class="drow__name">${esc(cleanName)}</span>
                ${isSite ? `<span class="pill pill--teal">site</span>` : ""}
                ${isHf ? `<span class="pill pill--blue">HF</span>` : ""}
              </span>
              <span class="drow__stats">
                <span class="drow__primary">${fmtInt(r.uniques)} uniq</span>
                <span>${fmtInt(r.count)} views</span>
              </span>
            </div>
            <div class="drow__track"><div class="drow__fill drow__fill--teal" style="width:${pct.toFixed(1)}%"></div></div>
          </div>`;
      }).join("");
      return;
    }

    rightTitle.textContent = "Reach & Referrers";
    rightSub.textContent = "Data unavailable for this tab.";
    rightList.innerHTML = `<div class="empty">Configure Cloudflare, Google Search Console, or GitHub CLI to populate this view.</div>`;
  }

  // 5. Compact Telemetry Footer
  function renderFooter() {
    const cfLabel = cf.ok ? `${cf.range.days}d live` : "offline";
    const gscLabel = gsc.ok ? `${gsc.range.days}d live` : "offline";
    const ghLabel = gh.ok ? "14d live" : "offline";
    document.getElementById("meta-bar").innerHTML = `
      <div class="pipes">
        <span class="pipe" title="${esc(cf.ok ? `Source: ${cf.source || "token"}` : (cf.error || "Unavailable"))}">
          <span class="sdot ${cf.ok ? "" : "sdot--off"}"></span>Cloudflare <span class="pipe__sub">${esc(cfLabel)}</span>
        </span>
        <span class="pipe" title="${esc(gsc.ok ? "sc-domain:lokalbot.com" : (gsc.error || "Unavailable"))}">
          <span class="sdot ${gsc.ok ? "" : "sdot--off"}"></span>Search Console <span class="pipe__sub">${esc(gscLabel)}</span>
        </span>
        <span class="pipe" title="${esc(gh.ok ? "stevyhacker/LokalBot" : (gh.error || "Unavailable"))}">
          <span class="sdot ${gh.ok ? "" : "sdot--off"}"></span>GitHub <span class="pipe__sub">${esc(ghLabel)}</span>
        </span>
      </div>
      <div class="meta-right">
        <span class="privacy-pill">
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none" aria-hidden="true">
            <path d="M8 1.5L13.5 3.6V7.8C13.5 11.1 11.1 13.7 8 14.7C4.9 13.7 2.5 11.1 2.5 7.8V3.6L8 1.5Z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>
            <path d="M5.7 8.1L7.3 9.7L10.5 6.3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
          Zero cookies
        </span>
        <span>${esc(fmtStamp(REPORT.generatedAt))}</span>
        <span class="cmd-pill">Scripts/dev/traffic-report.py</span>
      </div>`;
  }

  // Wire tab groups + keyboard navigation
  function bindTabGroup(selector, attr, onChange) {
    const tabs = Array.from(document.querySelectorAll(selector));
    tabs.forEach((btn, i) => {
      btn.addEventListener("click", () => {
        if (!btn.disabled) onChange(btn.getAttribute(attr));
      });
      btn.addEventListener("keydown", (e) => {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        e.preventDefault();
        const dir = e.key === "ArrowRight" ? 1 : -1;
        for (let step = 1; step <= tabs.length; step++) {
          const next = tabs[(i + dir * step + tabs.length) % tabs.length];
          if (!next.disabled) {
            next.focus();
            onChange(next.getAttribute(attr));
            break;
          }
        }
      });
    });
  }

  bindTabGroup("#trend-tabs .tab", "data-trend", renderTrend);
  bindTabGroup("#left-tabs .tab", "data-left", renderLeft);
  bindTabGroup("#right-tabs .tab", "data-right", renderRight);

  renderKPIs();
  renderTrend(activeTrend);
  renderLeft(activeLeft);
  renderRight(activeRight);
  renderFooter();

  // Re-render SVG crisply on container width changes (zero aspect-ratio distortion)
  if (typeof ResizeObserver === "function") {
    let lastW = wrap.clientWidth;
    const ro = new ResizeObserver(() => {
      const w = Math.round(wrap.clientWidth);
      if (w > 0 && Math.abs(w - lastW) >= 4) {
        lastW = w;
        renderTrend(activeTrend);
      }
    });
    ro.observe(wrap);
  }
})();
</script>
</body>
</html>
"""


if __name__ == "__main__":
    sys.exit(main())
