"""Score day-digest benchmark results against the items in cases.json.

    python3 Benchmarks/think/DayDigest/score.py results/<label>.json [more.json ...]

A digest covers an item when one of its task lines (the "### Tasks" list)
contains any of the item's keywords, and gives it its own line when a line
mentions that item and no other. A line counts as a duplicate when every
item it mentions was already covered by an earlier line, as merged when it
mentions two or more items, and as noise when it mentions none (the day's
"noise" keywords mark leisure browsing).
"""
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def task_lines(summary):
    lines, inside = [], False
    for line in summary.splitlines():
        if line.startswith("### "):
            inside = line.strip() == "### Tasks"
            continue
        if inside and line.startswith("- "):
            lines.append(line.lower())
    return lines


def score_entry(entry, day):
    items = day["items"]
    lines = task_lines(entry.get("summary", ""))
    covered, own, duplicates, merged, noise, leisure = set(), set(), 0, 0, 0, 0
    for line in lines:
        hits = {item["id"] for item in items if any(word in line for word in item["keywords"])}
        if not hits:
            if any(word in line for word in day.get("noise", [])):
                leisure += 1
            else:
                noise += 1
            continue
        if len(hits) > 1:
            merged += 1
        else:
            own |= hits
        if hits <= covered:
            duplicates += 1
        covered |= hits
    segment_calls = sum(1 for call in entry.get("calls", []) if call["stage"] == "segment")
    return {
        "covered": sorted(covered),
        "own_line": sorted(own),
        "missed": [item["id"] for item in items if item["id"] not in covered],
        "recall": len(covered) / len(items),
        "lines": len(lines),
        "duplicates": duplicates,
        "merged": merged,
        "noise": noise,
        "leisure": leisure,
        "seconds": entry.get("seconds", 0.0),
        "segment_calls": segment_calls,
        "error": entry.get("error"),
    }


def main(paths):
    cases = {day["id"]: day for day in json.loads((HERE / "cases.json").read_text())["days"]}
    report = {}
    for path in paths:
        data = json.loads(Path(path).read_text())
        rows = []
        for entry in data["results"]:
            row = score_entry(entry, cases[entry["day"]])
            row.update(day=entry["day"], run=entry["run"])
            rows.append(row)
        total_items = sum(len(cases[row["day"]]["items"]) for row in rows)
        runs = sorted({row["run"] for row in rows})
        per_run = [sum(len(row["covered"]) for row in rows if row["run"] == run) for run in runs]
        own_per_run = [sum(len(row["own_line"]) for row in rows if row["run"] == run) for run in runs]
        summary = {
            "model": data.get("model"),
            "runs": len(runs),
            "items_per_run": total_items // max(1, len(runs)),
            "covered_per_run": per_run,
            "recall_mean": statistics.mean(per_run) / (total_items / len(runs)),
            "own_line_per_run": own_per_run,
            "own_line_recall_mean": statistics.mean(own_per_run) / (total_items / len(runs)),
            "lines_per_run": statistics.mean(
                sum(row["lines"] for row in rows if row["run"] == run) for run in runs),
            "duplicates": sum(row["duplicates"] for row in rows),
            "merged": sum(row["merged"] for row in rows),
            "noise": sum(row["noise"] for row in rows),
            "leisure": sum(row["leisure"] for row in rows),
            "errors": sum(1 for row in rows if row["error"]),
            "seconds_per_day": statistics.mean(row["seconds"] for row in rows),
            "missed": {},
        }
        for row in rows:
            for item in row["missed"]:
                summary["missed"][item] = summary["missed"].get(item, 0) + 1
        report[Path(path).stem] = {"summary": summary, "rows": rows}
        print(f"{Path(path).stem}: covered {per_run} of {summary['items_per_run']} per run, "
              f"recall {summary['recall_mean']:.2f}; own line {own_per_run} "
              f"({summary['own_line_recall_mean']:.2f}); {summary['lines_per_run']:.1f} task lines/run, "
              f"duplicates {summary['duplicates']}, merged {summary['merged']}, noise {summary['noise']}, "
              f"leisure {summary['leisure']}, errors {summary['errors']}, "
              f"{summary['seconds_per_day']:.1f} s/day")
        print(f"  missed: {summary['missed']}")
    return report


if __name__ == "__main__":
    out = main(sys.argv[1:])
    target = HERE / "results" / "scores.json"
    previous = json.loads(target.read_text()) if target.exists() else {}
    previous.update(out)
    target.write_text(json.dumps(previous, indent=2, sort_keys=True))
