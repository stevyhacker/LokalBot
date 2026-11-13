#!/usr/bin/env python3
"""Copy only synthetic replay artifacts and score retained action provenance."""
import argparse
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--temporary-root", type=Path, required=True)
    args = parser.parse_args()
    gold = json.loads((HERE/"fixtures/expected-actions.json").read_text())
    report = {}
    for name in ("minicpm", "qwen", "minicpm-q8"):
        source = args.temporary_root/("production-"+name)
        if not (source/"measurements.json").exists():
            continue
        target = HERE/"results"/("production-"+name)
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source/"measurements.json", target/"measurements.json")
        measurements = json.loads((source/"measurements.json").read_text())
        model = {"measurements": measurements, "runs": []}
        for run in ("cold", "warm"):
            folder = source/run
            destination = target/run
            destination.mkdir(exist_ok=True)
            for pattern in ("*.json", "model-response-*.txt", "*.md"):
                for file in folder.glob(pattern):
                    shutil.copy2(file, destination/file.name)
            outcome_file = folder/"outcomes.json"
            if not outcome_file.exists():
                outcome_file = folder/"outcomes.partial.json"
            outcomes = json.loads(outcome_file.read_text())
            items = outcomes.get("actionItems", [])
            matches, used = [], set()
            for expected in gold:
                candidates = [(i, item) for i, item in enumerate(items) if all(
                    word.rstrip("s") in item["text"].lower() for word in expected["keywords"])]
                checks = []
                for index, item in candidates:
                    owner = "Alex" if item.get("isForUser") else item.get("owner")
                    owner_ok = owner == expected["owner"] and bool(item.get("isForUser")) == expected["user"]
                    citation_ok = any(abs(c["start"]-expected["source_start"]) < 0.01 for c in item.get("citations", []))
                    checks.append({"text": item["text"], "owner": owner, "owner_correct": owner_ok,
                        "primary_commitment_cited": citation_ok, "correct": owner_ok and citation_ok,
                        "citation_starts": [c["start"] for c in item.get("citations", [])]})
                    used.add(index)
                matches.append({"expected": expected, "found": bool(candidates), "correct": any(c["correct"] for c in checks), "candidates": checks})
            commitments = [m for m in matches if m["expected"]["owner"] is not None]
            user_tasks = [m for m in matches if m["expected"]["user"]]
            metrics = json.loads((folder/"notes-generation-metrics.json").read_text())
            scored = {"run": run, "pipeline_outcome": metrics["outcome"], "elapsed_seconds": metrics["elapsedSeconds"],
                "retained_actions": len(items), "committed_tasks_expected": len(commitments),
                "committed_tasks_found": sum(m["found"] for m in commitments),
                "committed_tasks_correct_owner_and_citation": sum(m["correct"] for m in commitments),
                "user_commitments_expected": len(user_tasks), "user_commitments_correct": sum(m["correct"] for m in user_tasks),
                "unassigned_request_retained_correctly": next(m["correct"] for m in matches if m["expected"]["owner"] is None),
                "unmatched_actions": [item for i, item in enumerate(items) if i not in used], "details": matches}
            model["runs"].append(scored)
        report[name] = model
    (HERE/"replay-scores.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({name: [{k:v for k,v in run.items() if k not in ("details", "unmatched_actions")} for run in data["runs"]]
                      for name, data in report.items()}, indent=2))


if __name__ == "__main__":
    main()
