#!/usr/bin/env python3
"""Generate Distribution/huggingface/benchmark-summary.md from Website/public/benchmarks.json.

Keeps the Hugging Face static Space and the interactive Local Desktop AI Leaderboard
at https://www.lokalbot.com/benchmarks in exact lockstep from one structured JSON source.

Usage:
    python3 Distribution/huggingface/scripts/sync_from_leaderboard.py
    python3 Distribution/huggingface/scripts/sync_from_leaderboard.py --check
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SOURCE_JSON = REPO_ROOT / "Website" / "public" / "benchmarks.json"
OUTPUT_MD = REPO_ROOT / "Distribution" / "huggingface" / "benchmark-summary.md"
GITHUB_BLOB_PREFIX = "https://github.com/stevyhacker/LokalBot/blob/master/"

STATUS_LABELS = {
    "default": "Default",
    "option": "Local option",
    "cloud": "Cloud API",
    "rejected": "Not adopted",
    "experimental": "Experimental",
    "baseline": "Baseline",
}


def repo_relative_report(url: str) -> str:
    if url.startswith(GITHUB_BLOB_PREFIX):
        return f"`{url[len(GITHUB_BLOB_PREFIX):]}`"
    return f"[report]({url})"


def render_summary(data: dict) -> str:
    lines: list[str] = [
        "# LokalBot — Local Desktop AI Leaderboard (synced benchmark summary)",
        "",
        f"Updated **{data['updated']}**. Generated from `Website/public/benchmarks.json` — every number comes verbatim from a checked-in report under `Benchmarks/README.md`. Nothing here is estimated or invented.",
        "",
        f"- **Interactive sortable leaderboard:** {data['url']}",
        f"- **Machine-readable JSON:** {data['dataUrl']}",
        "- **Full harnesses & raw outputs:** `Benchmarks/README.md`",
        f"- **Hardware scope:** {data['hardwareSummary']}",
        "",
        "## Current local reference stack (~9.6 GB total)",
        "",
        "| Role | Default model | Format | Size (GB) | Headline result | Interactive view |",
        "| --- | --- | --- | ---: | --- | --- |",
    ]

    for item in data.get("referenceStack", []):
        size = f"{item['sizeGb']:.2f}" if isinstance(item.get("sizeGb"), (int, float)) else "Built-in"
        lines.append(
            f"| {item['role']} | **{item['model']}** | {item['format']} | {size} | {item['headline']} | [View suite]({data['url']}#{item['suiteId']}) |"
        )

    for cat in data.get("categories", []):
        lines.extend(["", f"## {cat['label']}", "", cat["summary"]])
        for suite in cat.get("suites", []):
            lines.extend(
                [
                    "",
                    f"### {suite['label']}",
                    "",
                    f"**Run date:** {suite['runDate']} · **Hardware:** {suite['hardware']}  ",
                    f"**Dataset:** {suite['dataset']}  ",
                    f"**Source:** {repo_relative_report(suite['reportUrl'])} · [Interactive table]({data['url']}#{suite['id']})",
                    "",
                ]
            )
            cols = suite.get("columns", [])
            headers = ["Model", "Status", "Runtime / Quant"] + [c["label"] for c in cols]
            sep = ["---", "---", "---"] + [
                "---:" if c.get("align") == "right" else "---" for c in cols
            ]
            lines.append("| " + " | ".join(headers) + " |")
            lines.append("| " + " | ".join(sep) + " |")

            for row in suite.get("rows", []):
                model_cell = f"**{row['model']}**" if row.get("status") == "default" else row["model"]
                status_cell = STATUS_LABELS.get(row.get("status", ""), row.get("status", ""))
                rt_parts = [p for p in (row.get("runtime"), row.get("quant")) if p]
                rt_cell = " · ".join(rt_parts)
                cells = [model_cell, status_cell, rt_cell]
                for col in cols:
                    val = (row.get("values") or {}).get(col["key"])
                    if val:
                        text = val["display"]
                        if val.get("sub"):
                            text = f"{text} ({val['sub']})"
                        cells.append(text)
                    else:
                        cells.append("—")
                lines.append("| " + " | ".join(cells) + " |")

            lines.extend(
                [
                    "",
                    f"- **Notes:** {suite['note']}",
                    f"- **Caveat:** {suite['caveat']}",
                ]
            )

    lines.extend(
        [
            "",
            "## Honest gaps — what is NOT yet measured",
            "",
            "| Gap | Status & needed run |",
            "| --- | --- |",
        ]
    )
    for gap in data.get("gaps", []):
        lines.append(f"| **{gap['area']}** | {gap['detail']} |")

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify benchmark-summary.md matches Website/public/benchmarks.json without writing.",
    )
    args = parser.parse_args()

    data = json.loads(SOURCE_JSON.read_text(encoding="utf-8"))
    rendered = render_summary(data)

    if args.check:
        on_disk = OUTPUT_MD.read_text(encoding="utf-8") if OUTPUT_MD.is_file() else None
        if on_disk != rendered:
            print(
                "Out of date: Distribution/huggingface/benchmark-summary.md. "
                "Run `python3 Distribution/huggingface/scripts/sync_from_leaderboard.py` and re-render the Space.",
                file=sys.stderr,
            )
            return 1
        print("Distribution/huggingface/benchmark-summary.md is in sync with Website/public/benchmarks.json.")
        return 0

    OUTPUT_MD.write_text(rendered, encoding="utf-8")
    print(f"Synced {OUTPUT_MD.relative_to(REPO_ROOT)} from {SOURCE_JSON.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
