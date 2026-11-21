import importlib.util
import io
import json
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "Scripts" / "dev" / "traffic-report.py"

spec = importlib.util.spec_from_file_location("traffic_report", SCRIPT_PATH)
traffic_report = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(traffic_report)


def sample_report(
    *,
    cf_ok: bool = True,
    gsc_ok: bool = True,
    gh_ok: bool = True,
    malicious_query: str | None = None,
) -> dict:
    cf_daily = [
        {"date": f"2026-11-{day:02d}", "uniques": 600 + day * 10, "pageViews": 500 + day * 15, "requests": 3000 + day * 50, "bytes": 100_000_000}
        for day in range(7, 21)
    ]
    gsc_daily = [
        {"date": f"2026-11-{day:02d}", "clicks": 3 + (day % 5), "impressions": 100 + day * 6, "position": 7.4}
        for day in range(5, 19)
    ]
    gh_daily = [
        {"date": f"2026-11-{day:02d}", "views": 20 + day, "uniques": 12 + (day % 7)}
        for day in range(6, 20)
    ]
    return {
        "generatedAt": "2026-11-20T13:30:00Z",
        "cloudflare": (
            {
                "ok": True,
                "source": "/Users/example/.config/lokalbot/cloudflare-analytics-token",
                "zone": "lokalbot.com",
                "range": {"start": "2026-11-07", "end": "2026-11-20", "days": 14},
                "totals": {
                    "uniquesSum": sum(d["uniques"] for d in cf_daily),
                    "pageViews": sum(d["pageViews"] for d in cf_daily),
                    "requests": sum(d["requests"] for d in cf_daily),
                    "bytesMB": 1400.0,
                },
                "last7d": {
                    "uniquesSum": sum(d["uniques"] for d in cf_daily[-7:]),
                    "pageViews": sum(d["pageViews"] for d in cf_daily[-7:]),
                    "requests": sum(d["requests"] for d in cf_daily[-7:]),
                },
                "daily": cf_daily,
                "countries": [{"country": "US", "requests": 12000}, {"country": "DE", "requests": 3100}],
            }
            if cf_ok
            else {"ok": False, "source": "none", "error": "No token"}
        ),
        "gsc": (
            {
                "ok": True,
                "range": {"start": "2026-10-22", "end": "2026-11-18", "days": 28},
                "totals": {"clicks": 129, "impressions": 4302, "ctr": 3.0, "position": 7.7},
                "last7d": {"clicks": 42, "impressions": 1345, "ctr": 3.12, "position": 8.0},
                "last90d": {"clicks": 213, "impressions": 5775, "ctr": 3.69, "position": 8.5},
                "daily": gsc_daily,
                "pages": [
                    {"path": "/lokalbot-vs-hyprnote", "clicks": 1, "impressions": 534, "ctr": 0.2, "position": 9.1},
                    {"path": "/", "clicks": 64, "impressions": 528, "ctr": 12.1, "position": 3.7},
                ],
                "queries": [
                    {
                        "query": malicious_query or "lokalbot",
                        "clicks": 54,
                        "impressions": 124,
                        "ctr": 43.5,
                        "position": 1.0,
                    }
                ],
                "countries": [{"country": "USA", "clicks": 26, "impressions": 1058, "position": 7.2}],
            }
            if gsc_ok
            else {"ok": False, "error": "gcloud unavailable"}
        ),
        "github": (
            {
                "ok": True,
                "stars": 120,
                "views14d": {"count": 598, "uniques": 276, "daily": gh_daily},
                "clones14d": {"count": 6494, "uniques": 847},
                "referrers": [{"referrer": "lokalbot.com", "count": 34, "uniques": 31}],
                "latestRelease": {
                    "tag": "v0.13.3",
                    "published": "2026-11-19T18:20:20Z",
                    "assets": [
                        {"name": "appcast.xml", "downloads": 60},
                        {"name": "LokalBot-0.13.3-macos-arm64.dmg", "downloads": 16},
                        {"name": "LokalBot-0.13.3-windows-x86_64-setup.exe", "downloads": 6},
                        {"name": "LokalBot.mcpb", "downloads": 11},
                    ],
                },
            }
            if gh_ok
            else {"ok": False, "error": "gh unavailable"}
        ),
    }


class TokenAndMetricTests(unittest.TestCase):
    def test_load_cloudflare_token_precedence_and_sanitized_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            token_file = root / "token"
            wrangler = root / "default.toml"
            token_file.write_text("file-tok-123\n", encoding="utf-8")
            wrangler.write_text('oauth_token = "wrangler-tok-456"\n', encoding="utf-8")

            tok, src = traffic_report.load_cloudflare_token(
                token_file=token_file,
                wrangler_config=wrangler,
                env={"CLOUDFLARE_API_TOKEN": "env-tok-999"},
            )
            self.assertEqual((tok, src), ("env-tok-999", "env:CLOUDFLARE_API_TOKEN"))

            tok, src = traffic_report.load_cloudflare_token(
                token_file=token_file,
                wrangler_config=wrangler,
                env={},
            )
            self.assertEqual((tok, src), ("file-tok-123", "token-file"))
            self.assertNotIn(str(root), src)

            token_file.unlink()
            tok, src = traffic_report.load_cloudflare_token(
                token_file=token_file,
                wrangler_config=wrangler,
                env={},
            )
            self.assertEqual((tok, src), ("wrangler-tok-456", "wrangler-oauth"))

            wrangler.unlink()
            tok, src = traffic_report.load_cloudflare_token(
                token_file=token_file,
                wrangler_config=wrangler,
                env={},
            )
            self.assertEqual((tok, src), (None, "none"))

    def test_compute_wow_delta(self):
        short = [{"v": 10}] * 13
        self.assertIsNone(traffic_report.compute_wow_delta(short, "v"))

        steady_up = [{"v": 100}] * 7 + [{"v": 150}] * 7
        delta = traffic_report.compute_wow_delta(steady_up, "v")
        self.assertEqual(delta, {"recent": 1050, "prior": 700, "pct": 50.0})

        zero_prior = [{"v": 0}] * 7 + [{"v": 25}] * 7
        self.assertEqual(traffic_report.compute_wow_delta(zero_prior, "v"), {"recent": 175, "prior": 0, "pct": None})


class DashboardHtmlAndCliTests(unittest.TestCase):
    def test_render_html_sanitizes_paths_and_escapes_script_breakouts(self):
        report = sample_report(malicious_query='</script><img src=x onerror="alert(1)">\u2028')
        html = traffic_report.render_dashboard_html(report)

        self.assertIn("<!DOCTYPE html>", html)
        self.assertNotIn("/Users/example", html)
        self.assertIn('"source":"token-file"', html)
        self.assertNotIn("</script><img", html)
        self.assertIn("<\\/script>", html)
        self.assertNotIn("\u2028", html)

    def test_render_html_respects_embed_layout_and_theme_tokens(self):
        html = traffic_report.render_dashboard_html(sample_report())
        self.assertIsNone(re.search(r"\b\d+vh\b", html))
        html_body_rule = re.search(r"html,\s*body\s*\{([^}]*)\}", html)
        self.assertIsNotNone(html_body_rule)
        self.assertNotIn("height:", html_body_rule.group(1))
        self.assertIn("background: transparent", html_body_rule.group(1))
        for token in ("--card", "--foreground", "--muted-foreground", "--border", "--chart-1", "--chart-2"):
            self.assertIn(token, html)

    def test_render_html_handles_all_sources_offline(self):
        report = sample_report(cf_ok=False, gsc_ok=False, gh_ok=False)
        html = traffic_report.render_dashboard_html(report)
        self.assertIn('"cloudflare":{"ok":false', html)
        self.assertIn('"gsc":{"ok":false', html)
        self.assertIn('"github":{"ok":false', html)

    def test_snapshot_round_trip_and_cli_offline_html_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            history = root / "history.jsonl"
            html_out = root / "dashboard.html"

            traffic_report.save_snapshot(sample_report(), history)
            loaded = traffic_report.load_latest_snapshot(history)
            self.assertEqual(loaded["cloudflare"]["source"], "token-file")
            self.assertEqual(loaded["gsc"]["totals"]["impressions"], 4302)

            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = traffic_report.main(
                    ["--from-snapshot", str(history), "--html", str(html_out)]
                )
            self.assertEqual(rc, 0)
            self.assertTrue(html_out.is_file())
            rendered = html_out.read_text(encoding="utf-8")
            self.assertIn("LokalBot Traffic &amp; Search Report", rendered)
            self.assertIn("Cloudflare Edge Analytics", buf.getvalue())
            self.assertIn(str(html_out), buf.getvalue())


if __name__ == "__main__":
    unittest.main()
