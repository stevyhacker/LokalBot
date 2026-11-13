#!/usr/bin/env python3
"""Separate factual accuracy from exact-string formatting on saved responses.

These allowances were added after manual review, and apply equally to all models.
They accept documented equivalent date wording/translations and a harmless ID prefix.
Original exact scores remain in each case result and summary.json.
"""
import json
from pathlib import Path
import statistics

HERE = Path(__file__).resolve().parent
EQUIVALENTS = {
    "owner_acceptance": {"release_notes_due": ["Friday", "by Friday"]},
    "accepted_context": {"due": ["Friday", "by Friday"]},
    "cross_meeting_provenance": {"meeting_id": ["A-104", "Meeting A-104"]},
    "serbian_latin": {"installation_due": ["do petka", "petka", "petak", "Friday", "by Friday"],
                       "report_due": ["u ponedjeljak", "ponedjeljak", "Monday", "on Monday"]},
    "serbian_cyrillic": {"guide_due": ["до сриједе", "сриједе", "сриједа"]},
}


def norm(value):
    return " ".join(value.split()).rstrip(".").casefold() if isinstance(value, str) else value


def main():
    cases = {c["id"]: c for c in json.loads((HERE/"cases.json").read_text())}
    report = {"scoring_review": "Manual acceptance of semantically equivalent wording; raw exact scores preserved.",
              "accepted_equivalents": EQUIVALENTS, "models": {}}
    for folder in sorted((HERE/"results").iterdir()):
        if not (folder/"summary.json").exists():
            continue
        reviewed, rows = [], []
        for file in sorted(folder.glob("case-*.json")):
            data = json.loads(file.read_text())
            case = cases[data["id"]]
            row = {"id": data["id"], "repeat": data["repeat"], "group": data["group"],
                   "seconds": data["wall_seconds"], "exact_pass": data["score"]["passed"]}
            if data["group"] == "tools":
                row["factual_pass"] = row["exact_pass"]
            else:
                try:
                    answer = json.loads(data.get("message", {}).get("content") or "")
                    wrong = {}
                    for key, expected in case["expected"].items():
                        allowed = EQUIVALENTS.get(data["id"], {}).get(key, [expected])
                        if key not in answer or norm(answer[key]) not in [norm(x) for x in allowed]:
                            wrong[key] = {"expected": expected, "actual": answer.get(key)}
                    row.update(factual_pass=not wrong and data.get("finish_reason") == "stop",
                               correct_fields=len(case["expected"])-len(wrong), fields=len(case["expected"]), errors=wrong)
                except (ValueError, TypeError):
                    row.update(factual_pass=False, correct_fields=0, fields=len(case["expected"]), errors={"json": "invalid"})
            if row["factual_pass"] != row["exact_pass"]:
                reviewed.append({"id": row["id"], "repeat": row["repeat"], "reason": EQUIVALENTS.get(row["id"])})
            rows.append(row)
        groups = {}
        for group in sorted({r["group"] for r in rows}):
            selected = [r for r in rows if r["group"] == group]
            unique = sorted({r["id"] for r in selected})
            groups[group] = {"trials": len(selected), "factual_passes": sum(r["factual_pass"] for r in selected),
                "exact_passes": sum(r["exact_pass"] for r in selected), "unique_cases": len(unique),
                "cases_passing_every_repeat": sum(all(r["factual_pass"] for r in selected if r["id"] == key) for key in unique),
                "correct_fields": sum(r.get("correct_fields", 0) for r in selected),
                "total_fields": sum(r.get("fields", 0) for r in selected),
                "median_seconds": statistics.median(r["seconds"] for r in selected)}
        report["models"][folder.name] = {"groups": groups, "reviews": reviewed, "cases": rows}
    (HERE/"reviewed-scores.json").write_text(json.dumps(report, indent=2, ensure_ascii=False)+"\n")
    print(json.dumps({name: data["groups"] for name, data in report["models"].items()}, indent=2))


if __name__ == "__main__":
    main()
