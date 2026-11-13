#!/usr/bin/env python3
"""Reject capture traces that were not scrubbed by the current scrubber.

Scrubbed text replaces letters with consonants, so any vowel in a text field
(outside the shared allowlist) or any non-ASCII letter means unscrubbed text.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
ALLOW = json.loads((ROOT / "Scripts/test/record-capture/scrub-allowlist.json").read_text())
VOCABULARY = {word.lower() for word in ALLOW["vocabulary"]}
APP_NAMES = set(ALLOW["appNames"])
HOSTS = set(ALLOW["meetingHosts"])
BUNDLE_IDS = set(ALLOW.get("bundleIDs", []))
BUNDLE_PREFIXES = tuple(ALLOW.get("bundlePrefixes", []))
TOKEN = re.compile(r"[^\W_]+", re.UNICODE)
VOWEL = re.compile(r"[aeiouy]", re.IGNORECASE)


def text_ok(value):
    for token in TOKEN.findall(value):
        if token.lower() in VOCABULARY:
            continue
        if not token.isascii() or VOWEL.search(token):
            return False
    return True


def url_ok(value):
    for host in sorted(HOSTS, key=len, reverse=True):
        value = value.replace(host, "")
    return text_ok(value)


def bundle_ok(value):
    """Detection apps, their helpers, and allowed prefixes stay verbatim."""
    return (any(value == allowed or value.startswith(allowed + ".") for allowed in BUNDLE_IDS)
            or value.startswith(BUNDLE_PREFIXES))


def violations(trace, name):
    problems = []
    header = trace.get("header", {})
    if header.get("scrubberVersion") != ALLOW["scrubberVersion"]:
        problems.append(f"{name}: scrubberVersion {header.get('scrubberVersion')} != {ALLOW['scrubberVersion']}")

    def check(value, kind, where):
        if value is None:
            return
        if kind == "bundle":
            ok = bundle_ok(value) or text_ok(value)
        else:
            ok = url_ok(value) if kind == "url" else (value in APP_NAMES or text_ok(value)) if kind == "app" else text_ok(value)
        if not ok:
            problems.append(f"{name}: unscrubbed {where}: {value[:40]!r}")

    for index, event in enumerate(trace.get("events", [])):
        where = f"event {index}"
        for app in ([event.get("app")] if event.get("app") else []) + (event.get("apps") or []):
            check(app.get("localizedName"), "app", f"{where} app name")
            check(app.get("bundleIdentifier"), "bundle", f"{where} bundle id")
        check(event.get("title"), "text", f"{where} title")
        snapshot = (event.get("read") or {}).get("snapshot") or {}
        for field in ("text", "documentName", "windowTitle"):
            check(snapshot.get(field), "text", f"{where} {field}")
        check(snapshot.get("sourceURL"), "url", f"{where} sourceURL")
        for url in snapshot.get("framedURLs") or []:
            check(url, "url", f"{where} framedURLs")
        check((event.get("browser") or {}).get("url"), "url", f"{where} browser url")
        for window in event.get("windows") or []:
            check(window.get("title"), "text", f"{where} window title")
            check(window.get("appName"), "app", f"{where} window app")
        for process in event.get("processes") or []:
            check(process.get("name"), "app", f"{where} process name")
            check(process.get("bundleID"), "bundle", f"{where} process bundle id")
    return problems


def main(paths):
    problems = []
    for root in paths:
        for path in sorted(Path(root).rglob("*.json")):
            problems += violations(json.loads(path.read_text()), str(path))
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or [str(ROOT / "LokalBotTests/Fixtures/capture-traces")]))
