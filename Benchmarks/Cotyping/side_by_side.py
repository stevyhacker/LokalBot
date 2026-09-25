#!/usr/bin/env python3
"""Merge two Scripts/compare-cotyping.sh capture directories (Cotypist vs
LokalBot) into one side-by-side report, and optionally fold in a
`LokalBot --cotyping-bench` JSON for engine-level latency.

Each capture directory holds, per prompt slug:
  <slug>.txt           the prompt that was typed
  <slug>.document.txt  TextEdit text after the suggestion wait
  <slug>.accepted.txt  TextEdit text after one Tab accept (COTYPING_COMPARE_ACCEPT=1)

The inserted suggestion chunk is `accepted - document` (both normalized for
TextEdit smart quotes/dashes). For `word-completion` prompts the insertion must
extend the typed fragment: first inserted character is a letter/digit, no
leading whitespace.

Usage:
  Benchmarks/Cotyping/side_by_side.py \
      --cotypist-dir /tmp/cotyping-cotypist \
      --lokalbot-dir /tmp/cotyping-lokalbot \
      [--engine-json /tmp/lokalbot-cotyping-bench.json] \
      [--output Benchmarks/Cotyping/results/<date>.md]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

SMART_MAP = str.maketrans({
    "\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"',
    "\u2013": "-", "\u2014": "-", "\u00a0": " ",
})


def normalize(text: str) -> str:
    return unicodedata.normalize("NFC", text.translate(SMART_MAP)).rstrip("\n")


@dataclass
class Capture:
    prompt: str
    document: str | None
    accepted: str | None

    @property
    def insertion(self) -> str | None:
        """Text the Tab accept inserted, or None when nothing was accepted."""
        if self.accepted is None or self.document is None:
            return None
        doc, acc = normalize(self.document), normalize(self.accepted)
        if acc == doc:
            return ""
        if acc.startswith(doc):
            return acc[len(doc):]
        return None  # document changed in an unexpected way; flag for review

    @property
    def suggested(self) -> bool | None:
        insertion = self.insertion
        if insertion is None:
            return None
        # A literal tab means the host received the keystroke with no active
        # suggestion (TextEdit inserted \t).
        return bool(insertion) and not insertion.startswith("\t")


def load_capture(directory: Path, slug: str) -> Capture | None:
    prompt_file = directory / f"{slug}.txt"
    if not prompt_file.exists():
        return None
    def read(name: str) -> str | None:
        path = directory / name
        return path.read_text(encoding="utf-8") if path.exists() else None
    return Capture(
        prompt=prompt_file.read_text(encoding="utf-8").rstrip("\n"),
        document=read(f"{slug}.document.txt"),
        accepted=read(f"{slug}.accepted.txt"),
    )


def parse_manifest(path: Path) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        rows.append((parts[0], parts[1], parts[2]))
    return rows


def completion_fields(path: Path) -> dict[str, str]:
    if not path.is_file() or not path.stat().st_size:
        raise ValueError(f"capture completion marker is missing: {path}")
    fields = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            raise ValueError(f"malformed capture completion marker: {path}")
        key, value = line.split("=", 1)
        fields[key] = value
    return fields


def validate_capture_directory(directory: Path, target: str,
                               rows: list[tuple[str, str, str]], manifest: Path) -> None:
    fields = completion_fields(directory / "capture.complete")
    if fields.get("target") != target:
        raise ValueError(f"{target} capture marker names {fields.get('target')!r}")
    try:
        count = int(fields.get("prompt_count", ""))
    except ValueError as error:
        raise ValueError(f"{target} capture marker has an invalid prompt count") from error
    if count != len(rows) or not rows:
        raise ValueError(f"{target} capture is incomplete: {count}/{len(rows)} prompts")
    if fields.get("input_mode") != "keys" or fields.get("accept") != "1":
        raise ValueError(f"{target} capture lacks keyboard acceptance evidence")

    copied_manifest = directory / "prompts.tsv"
    if not copied_manifest.is_file():
        raise ValueError(f"{target} capture has no copied manifest")
    digest = hashlib.sha256(copied_manifest.read_bytes()).hexdigest()
    if fields.get("manifest_sha256") != digest:
        raise ValueError(f"{target} capture manifest does not match its completion marker")
    if copied_manifest.read_bytes() != manifest.read_bytes():
        raise ValueError(f"{target} capture used a different prompt manifest")

    for slug, _, prompt in rows:
        required = [f"{slug}.png", f"{slug}.rect", f"{slug}.txt",
                    f"{slug}.document.txt", f"{slug}.accepted.txt"]
        missing = [name for name in required
                   if not (directory / name).is_file()
                   or (name != f"{slug}.accepted.txt" and not (directory / name).stat().st_size)]
        if missing:
            raise ValueError(f"{target} capture is missing evidence for {slug}: {', '.join(missing)}")
        capture = load_capture(directory, slug)
        if capture is None or capture.prompt != prompt:
            raise ValueError(f"{target} captured the wrong prompt for {slug}")
        if capture.insertion is None:
            raise ValueError(f"{target} acceptance evidence is unusable for {slug}")


def word_completion_ok(insertion: str | None) -> bool | None:
    if insertion is None:
        return None
    if not insertion or insertion.startswith("\t"):
        return False
    first = insertion[0]
    return first.isalpha() or first.isdigit()


def cell(value: str | None, limit: int = 46) -> str:
    if value is None:
        return "—"
    flat = value.replace("\n", "⏎").replace("\t", "⇥").replace("|", "\\|")
    return f"`{flat[:limit]}…`" if len(flat) > limit else (f"`{flat}`" if flat else "∅ (no suggestion)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cotypist-dir", type=Path, required=True)
    parser.add_argument("--lokalbot-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=None,
                        help="prompts.tsv; defaults to the copy inside --cotypist-dir")
    parser.add_argument("--engine-json", type=Path, default=None,
                        help="output of `LokalBot --cotyping-bench` for latency context")
    parser.add_argument("--output", type=Path, default=None,
                        help="markdown report path (default: stdout); a .json sibling is written too")
    args = parser.parse_args()

    manifest = args.manifest or args.cotypist_dir / "prompts.tsv"
    if not manifest.exists():
        print(f"manifest not found: {manifest}", file=sys.stderr)
        return 66
    rows = parse_manifest(manifest)
    try:
        validate_capture_directory(args.cotypist_dir, "cotypist", rows, manifest)
        validate_capture_directory(args.lokalbot_dir, "lokalbot", rows, manifest)
    except (OSError, ValueError) as error:
        print(f"incomplete side-by-side evidence: {error}", file=sys.stderr)
        return 65

    engine: dict[str, dict] = {}
    engine_summary: dict | None = None
    if args.engine_json and args.engine_json.exists():
        payload = json.loads(args.engine_json.read_text(encoding="utf-8"))
        engine_summary = {k: v for k, v in payload.items() if k != "scenarios"}
        engine = {case["id"]: case for case in payload.get("scenarios", [])}

    report_rows = []
    totals = {"cotypist": {"suggested": 0, "wc_ok": 0, "wc_total": 0, "captured": 0},
              "lokalbot": {"suggested": 0, "wc_ok": 0, "wc_total": 0, "captured": 0}}

    for slug, kind, prompt in rows:
        entry = {"slug": slug, "kind": kind, "prompt": prompt, "apps": {}}
        for app, directory in (("cotypist", args.cotypist_dir), ("lokalbot", args.lokalbot_dir)):
            capture = load_capture(directory, slug)
            insertion = capture.insertion if capture else None
            suggested = capture.suggested if capture else None
            wc_ok = word_completion_ok(insertion) if kind == "word-completion" else None
            if capture is not None:
                totals[app]["captured"] += 1
                if suggested:
                    totals[app]["suggested"] += 1
                if kind == "word-completion":
                    totals[app]["wc_total"] += 1
                    if wc_ok:
                        totals[app]["wc_ok"] += 1
            entry["apps"][app] = {
                "insertion": insertion,
                "suggested": suggested,
                "word_completion_ok": wc_ok,
            }
        report_rows.append(entry)

    lines = ["# Cotypist vs LokalBot — cotyping side-by-side", ""]
    lines.append(f"Prompts: {len(rows)} (from `{manifest.name}`). "
                 "Insertion = TextEdit text delta after one Tab accept; "
                 "∅ = Tab landed with no suggestion; — = capture missing.")
    lines.append("")
    if engine_summary:
        lines.append("## LokalBot engine benchmark (`--cotyping-bench`)")
        lines.append("")
        lines.append(f"- scenarios passed: {engine_summary.get('passed')}/{engine_summary.get('total')}"
                     f" (safety {engine_summary.get('safetyPassed')}/{engine_summary.get('total')})")
        lines.append(f"- word completions extending the typed word: "
                     f"{engine_summary.get('wordCompletionPassed')}/{engine_summary.get('wordCompletionTotal')}")
        lines.append(f"- latency: avg {engine_summary.get('averageLatencyMs')} ms · "
                     f"p95 {engine_summary.get('p95LatencyMs')} ms")
        lines.append("")
    lines.append("## Per-prompt insertions")
    lines.append("")
    lines.append("| # | Kind | Prompt tail | Cotypist inserted | LokalBot inserted | WC ok (C/L) |")
    lines.append("|---|------|-------------|-------------------|-------------------|-------------|")
    for entry in report_rows:
        tail = entry["prompt"][-34:]
        c = entry["apps"]["cotypist"]
        l = entry["apps"]["lokalbot"]
        if entry["kind"] == "word-completion":
            def mark(value):
                return "—" if value is None else ("✓" if value else "✗")
            wc = f"{mark(c['word_completion_ok'])}/{mark(l['word_completion_ok'])}"
        else:
            wc = ""
        lines.append(
            f"| {entry['slug']} | {entry['kind']} | `…{tail}` "
            f"| {cell(c['insertion'])} | {cell(l['insertion'])} | {wc} |")
    lines.append("")
    lines.append("## Totals")
    lines.append("")
    for app in ("cotypist", "lokalbot"):
        t = totals[app]
        lines.append(f"- **{app}**: suggestions on {t['suggested']}/{t['captured']} prompts; "
                     f"word completions {t['wc_ok']}/{t['wc_total']}")
    lines.append("")

    markdown = "\n".join(lines)
    payload = {"manifest": str(manifest), "totals": totals, "rows": report_rows,
               "engine_summary": engine_summary}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(markdown, encoding="utf-8")
        args.output.with_suffix(".json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        print(args.output)
    else:
        print(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
