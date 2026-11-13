#!/usr/bin/env python3
"""Ablate visible screen context and saved memory on the native completion path.

Synthetic AX trees go through the production selection policy. Answers and scores
stay in this process. No user library, screen, clipboard, or learned text is read.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import uuid

from quality_replay import digest, fold, predicted_words

VARIANTS = {"neither": (False, False), "visible": (True, False),
            "memory": (False, True), "both": (True, True)}


def replay_input(corpus, cases, variant):
    visible, memory = VARIANTS[variant]
    allowed = {"id", "prefix", "trailing", "appName", "bundleID", "windowTitle", "placeholder", "visibleContext"}
    return {"cases": [{k: v for k, v in case.items() if k in allowed} for case in cases],
            "memoryItems": corpus["memoryItems"], "memoryNow": corpus["asOf"],
            "useMeetingMemory": memory, "useScreenMemory": False, "useVisibleContext": visible}


def contains_fact(text, expected):
    actual, wanted = predicted_words(text), predicted_words(expected or "")
    return bool(wanted) and any(actual[i:i + len(wanted)] == wanted for i in range(len(actual)))


def score(cases, observations):
    ids = [c["id"] for c in cases]
    if set(observations) != set(VARIANTS):
        raise ValueError("All four ablations are required")
    rows = []
    for variant, (visible, memory) in VARIANTS.items():
        output = observations[variant]
        if [o["id"] for o in output] != ids:
            raise ValueError("Incomplete, reordered or duplicate observations")
        if any(o.get("usedPromptOverride") for o in output):
            raise ValueError("Requires the production prompt")
        for case, observation in zip(cases, output):
            expected = case.get("expected")
            permitted_reads = case["permittedTextReadIDs"] if visible else []
            expects_memory = memory and (visible or not case.get("memoryRequiresVisibleContext", False))
            rows.append({"id": case["id"], "kind": case["kind"], "variant": variant,
                         "text": observation["text"], "expected": expected,
                         "correct": not observation.get("error") and contains_fact(observation["text"], expected),
                         "firstWordCorrect": bool(expected) and predicted_words(observation["text"])[:1] == [fold(expected)],
                         "staleFact": contains_fact(observation["text"], case.get("stale")),
                         "visibleIDs": observation.get("visibleIDs", []),
                         "memoryIDs": observation.get("memoryIDs", []),
                         "visibleSelectionCorrect": observation.get("visibleIDs", []) == (case["expectedVisibleIDs"] if visible else []),
                         "memorySelectionCorrect": observation.get("memoryIDs", []) == (case["expectedMemoryIDs"] if expects_memory else []),
                         "forbiddenReads": sorted(set(observation.get("visibleTextReadIDs", [])) - set(permitted_reads)),
                         "latencyMs": observation["latencyMs"], "error": observation.get("error"),
                         "suppression": observation.get("suppression")})
    controls = []
    for index, case in enumerate(cases):
        if case["kind"] != "control":
            continue
        base = observations["neither"][index]
        unchanged = all((v[index]["text"], v[index]["prompt"]) == (base["text"], base["prompt"])
                        for v in observations.values())
        controls.append({"id": case["id"], "unchanged": unchanged})
    summaries = {}
    for variant in VARIANTS:
        own = [r for r in rows if r["variant"] == variant]
        factual = [r for r in own if r["kind"] not in {"control", "generic"}]
        grouped = {}
        for kind in sorted({r["kind"] for r in factual} | {"generic"}):
            subset = [r for r in own if r["kind"] == kind]
            grouped[kind] = {"cases": len(subset), "correct": sum(r["correct"] for r in subset),
                             "staleFact": sum(r["staleFact"] for r in subset)}
        summaries[variant] = {"factualCases": len(factual), "correct": sum(r["correct"] for r in factual),
                              "firstWordCorrect": sum(r["firstWordCorrect"] for r in factual),
                              "visibleSelectionsCorrect": sum(r["visibleSelectionCorrect"] for r in own),
                              "memorySelectionsCorrect": sum(r["memorySelectionCorrect"] for r in own),
                              "totalCases": len(own), "errors": sum(bool(r["error"]) for r in own),
                              "suppressed": sum(bool(r["suppression"]) for r in own),
                              "forbiddenReads": sum(bool(r["forbiddenReads"]) for r in own),
                              "medianMs": statistics.median(r["latencyMs"] for r in own), "byKind": grouped}
    return {"summary": summaries, "controls": controls, "cases": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, default=Path(__file__).with_name("visible-context-cases.json"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--split", choices=["development", "heldout"], required=True)
    args = parser.parse_args()
    corpus = json.loads(args.corpus.read_text())
    cases = [c for c in corpus["cases"] if c["split"] == args.split]
    if not cases or len({c["id"] for c in cases}) != len(cases):
        raise ValueError("Empty or duplicate cases")
    args.output.mkdir(parents=True, exist_ok=False)
    app, model = args.app.resolve(strict=True), args.model.resolve(strict=True)
    manifest = {"appSHA256": digest(app), "modelFile": model.name, "modelSHA256": digest(model),
                "corpusSHA256": digest(args.corpus), "scriptSHA256": digest(__file__), "split": args.split,
                "caseIDs": [c["id"] for c in cases], "settings": "production defaults (3 words, 5 tokens)",
                "context": "synthetic AX regions and saved facts; no live user data",
                "metric": "expected fact occurs as complete lexical words in the emitted continuation"}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    observations = {}
    for variant in VARIANTS:
        fixture = args.output / f"{variant}-input.json"
        fixture.write_text(json.dumps(replay_input(corpus, cases, variant), ensure_ascii=False) + "\n")
        with tempfile.TemporaryDirectory(prefix="lokalbot-visible-eval-") as temp:
            root = Path(temp)
            (root / "home").mkdir()
            (root / "storage").mkdir()
            env = dict(os.environ, CFFIXED_USER_HOME=str(root / "home"), LOKALBOT_STORAGE_ROOT=str(root / "storage"),
                       LOKALBOT_DEFAULTS_SUITE=f"me.dotenv.LokalBot.visible-replay.{uuid.uuid4()}")
            with (args.output / f"{variant}.jsonl").open("w") as out, (args.output / f"{variant}-stderr.log").open("w") as err:
                subprocess.run([str(app), "--cotyping-replay", str(fixture.resolve()), "--model-path", str(model)],
                               env=env, stdout=out, stderr=err, timeout=900, check=True)
        observations[variant] = [json.loads(line) for line in (args.output / f"{variant}.jsonl").read_text().splitlines()]
        print(f"{variant}: {len(observations[variant])} observations", flush=True)
    report = score(cases, observations)
    report["manifest"] = manifest
    (args.output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2), flush=True)
    if any(r["error"] or r["forbiddenReads"] or not r["visibleSelectionCorrect"] or not r["memorySelectionCorrect"] for r in report["cases"]):
        raise SystemExit(1)
    if not all(c["unchanged"] for c in report["controls"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
