#!/usr/bin/env python3
"""AB/BA typing and real cancellation replay for the display-stop experiment."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from cache_benchmark import dynamic_cases, paired_dynamic, timing, trace_bootstrap, validate_dynamic
from candidate_benchmark import write_json
from quality_replay import digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--confidence-threshold", type=float, help="Also test frozen boundary-mass confidence, with and without display stopping")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    fixture_path = Path(__file__).with_name("cache-typing-cases.json")
    cases, metadata = dynamic_cases(json.loads(fixture_path.read_text()))
    write_json(args.output / "metadata.json", metadata)
    settings = {"control": {"stopAtDisplayLimit": False}, "display-stop": {"stopAtDisplayLimit": True}}
    if args.confidence_threshold is not None:
        settings["boundary-mass"] = {"confidenceBoundaryMode": "boundaryMass", "firstWordThreshold": args.confidence_threshold}
        settings["boundary-mass-stop"] = dict(settings["boundary-mass"], stopAtDisplayLimit=True)
    orders = [list(settings), list(reversed(settings))]
    write_json(args.output / "manifest.json", {
        "appSHA256": digest(args.app), "modelSHA256": digest(args.model), "scriptSHA256": digest(__file__),
        "fixtureSHA256": digest(fixture_path), "orders": orders, "settings": settings,
        "boundary": "Warm complete native requests; delays excluded. Existing synthetic regression traces, not fresh quality holdout. Cancellation is host request return, not independently measured GPU quiescence.",
    })
    runs = {arm: [] for arm in settings}
    for round_index, order in enumerate(orders, 1):
        for arm in order:
            directory = args.output / f"round-{round_index}-{arm}"
            directory.mkdir()
            write_json(directory / "input.json", {"cases": cases, **settings[arm]})
            with tempfile.TemporaryDirectory(prefix="lokalbot-decoder-dynamic-") as temp:
                root = Path(temp)
                (root / "home").mkdir()
                env = dict(os.environ, CFFIXED_USER_HOME=str(root / "home"), LOKALBOT_STORAGE_ROOT=str(root / "storage"),
                           LOKALBOT_DEFAULTS_SUITE="me.dotenv.LokalBot.decoder-dynamic." + root.name)
                with (directory / "observations.jsonl").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
                    process = subprocess.run([str(args.app.resolve()), "--cotyping-replay", str(directory / "input.json"),
                                              "--model-path", str(args.model.resolve())], env=env, stdout=stdout,
                                             stderr=stderr, timeout=3600)
            if process.returncode:
                raise RuntimeError(f"Dynamic replay failed: {directory}")
            rows = [json.loads(line) for line in (directory / "observations.jsonl").read_text().splitlines()]
            validate_dynamic(rows, cases, False)
            if any(r.get("stopAtDisplayLimit") != settings[arm].get("stopAtDisplayLimit", False) for r in rows):
                raise ValueError("Early-stop control ignored")
            if "firstWordThreshold" in settings[arm]:
                if any(r.get("confidenceBoundaryMode") != "boundaryMass"
                       or abs(r.get("firstWordThreshold", -1) - args.confidence_threshold) > 1e-6 for r in rows):
                    raise ValueError("Confidence control ignored")
            runs[arm].append(rows)
            print(json.dumps({"round": round_index, "arm": arm, **timing([r for r in rows if not r.get("cancelled")])}), flush=True)
    control = [r for rows in runs["control"] for r in rows]
    treatment = [r for rows in runs["display-stop"] for r in rows]
    result = {"parity": {"control-vs-stop": paired_dynamic(control, treatment, metadata)},
              "latencyBootstrap": {}, "arms": {}}
    if "boundary-mass" in runs:
        mass = [r for rows in runs["boundary-mass"] for r in rows]
        stopped = [r for rows in runs["boundary-mass-stop"] for r in rows]
        result["parity"]["mass-vs-mass-stop"] = paired_dynamic(mass, stopped, metadata)
    for arm, rounds in runs.items():
        rows = [r for run in rounds for r in run]
        result["latencyBootstrap"][arm] = trace_bootstrap(control, rows, metadata)
        if any(a["prompt"] != b["prompt"] for a, b in zip(control, rows)):
            raise ValueError("Dynamic prompts changed between arms")
        result["arms"][arm] = {
            "noncancelled": timing([r for r in rows if not r.get("cancelled")]),
            "heldoutTraceSubset": timing([r for r in rows if not r.get("cancelled") and metadata[r["id"]]["split"] == "heldout"]),
            "cancellationReturn": timing([r for r in rows if r.get("cancelled")], "cancellationLatencyMs"),
            "actions": {action: timing([r for r in rows if metadata[r["id"]]["action"] == action])
                        for action in sorted({m["action"] for m in metadata.values()})},
        }
    write_json(args.output / "summary.json", result)


if __name__ == "__main__":
    main()
