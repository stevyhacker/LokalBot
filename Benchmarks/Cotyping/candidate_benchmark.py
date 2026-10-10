#!/usr/bin/env python3
"""Paired native decoder experiment: fixed model, production prompts and gates.

Synthetic corpus only. No UI, live writing, saved settings or remote inference.
Quality is exact reference-word agreement, not human acceptance. Repetitions are
serial and counterbalanced; elapsed request time excludes model cold loading.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile
import time

from compare_quality import compare
from quality_replay import checkpoints, digest, predicted_words, score, selected_phrases


def build_suite(public_path, challenge_path, per_category=8):
    public = json.loads(Path(public_path).read_text())
    challenge = json.loads(Path(challenge_path).read_text())
    phrases = selected_phrases(public, "heldout", per_category)
    cases, references = [], {}
    groups = [("public-word", phrases, "word"), ("challenge-word", challenge["phrases"], "word"),
              ("public-midword", phrases, "midword")]
    for group, items, mode in groups:
        inputs, targets = checkpoints(items, mode)
        if mode == "midword":
            # Two internal checkpoints per phrase, fixed before observing output.
            retained = set()
            for phrase in items:
                ids = [key for key, ref in targets.items() if ref["phraseID"] == phrase["id"]]
                retained.update(sorted(ids, key=lambda key: hashlib.sha256(f"20261010:{key}".encode()).hexdigest())[:2])
            inputs = [item for item in inputs if item["id"] in retained]
        for item in inputs:
            old_id = item["id"]
            item["id"] = f"{group}:{old_id}"
            source = "challenge" if group == "challenge-word" else "public"
            ref = dict(targets[old_id], phraseID=f"{source}:{targets[old_id]['phraseID']}", group=group)
            references[item["id"]] = ref
            cases.append(item)
    if not cases or len(references) != len(cases):
        raise ValueError("Suite must contain unique checkpoints")
    return cases, references, [p["id"] for p in phrases]


def validate_observations(observations, references, width, control=None):
    if [row["id"] for row in observations] != list(references):
        raise ValueError("Incomplete, duplicated or reordered replay")
    for index, row in enumerate(observations):
        if row.get("error") or row.get("decoderCandidates") != width:
            raise ValueError(f"Wrong decoder or failed request: {row['id']}")
        if row["usedPromptOverride"] or not math.isfinite(row["latencyMs"]) or row["latencyMs"] < 0:
            raise ValueError("Invalid timing or non-production prompt")
        if control is not None and row["prompt"] != control[index]["prompt"]:
            raise ValueError(f"Rendered prompt differs: {row['id']}")
        if width > 1 and row.get("suppression") != "pre-generation-gate":
            diagnostics = row.get("search")
            if not diagnostics or diagnostics["width"] != width:
                raise ValueError("Missing native search diagnostics (fallback is forbidden)")
            if not 1 <= diagnostics["peakActiveCandidates"] <= width:
                raise ValueError("Search exceeded its width or did not run")
            if len(diagnostics["candidateTexts"]) > width:
                raise ValueError("Too many finalists")


def summarize(observations, references):
    report = score(observations, references)
    overall = report["overall"]
    overall["incorrectShown"] = overall["shown"] - overall["correct"]
    overall["precisionWhenShown"] = overall["correct"] / overall["shown"] if overall["shown"] else None
    overall["meanMs"] = statistics.mean(row["latencyMs"] for row in observations)
    oracle = 0
    for row in observations:
        ref = references[row["id"]]
        texts = (row.get("search") or {}).get("candidateTexts", [row["text"]])
        oracle += any(predicted_words(text, ref["typed"])[:1] == ref["words"][:1] for text in texts)
    overall["oracleFirstWordMatches"] = oracle
    report["groups"] = {}
    for group in sorted({ref["group"] for ref in references.values()}):
        selected = {key: ref for key, ref in references.items() if ref["group"] == group}
        rows = [row for row in observations if row["id"] in selected]
        report["groups"][group] = score(rows, selected)["overall"]
    return report


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--challenge", type=Path, default=Path(__file__).with_name("quality-cases.json"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--per-category", type=int, default=8)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.per_category < 1 or args.rounds < 1:
        parser.error("Sample and repetition counts must be positive")
    app, model = args.app.resolve(strict=True), args.model.resolve(strict=True)
    cases, references, phrase_ids = build_suite(args.corpus, args.challenge, args.per_category)
    args.output.mkdir(parents=True, exist_ok=False)
    orders = [[1, 2, 4], [2, 4, 1], [4, 1, 2]]
    manifest = {
        "startedAtUTC": datetime.now(timezone.utc).isoformat(),
        "appSHA256": digest(app), "modelFile": model.name, "modelSHA256": digest(model),
        "corpusSHA256": digest(args.corpus), "challengeSHA256": digest(args.challenge),
        "scriptSHA256": digest(__file__), "scorerSHA256": digest(Path(__file__).with_name("quality_replay.py")),
        "phraseIDs": phrase_ids, "split": "heldout-public-plus-frozen-original-challenge", "splitSeed": 1337,
        "mode": "word-and-two-midword-per-public-phrase", "checkpoints": len(cases),
        "rounds": args.rounds, "orders": [orders[i % 3] for i in range(args.rounds)],
        "context": "synthetic typed prefix and app/title/field metadata only",
        "settings": "production defaults; only decoderCandidates changes; no prompt override",
        "boundary": "warm complete engine request, including tokenization, prefill, decode and normalization; excludes load, debounce, AX and overlay",
        "machine": {"platform": platform.platform(), "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                    "memoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))},
        "sourceSHA256": {str(p): digest(p) for p in sorted(Path("LokalBot/Cotyping").rglob("*.swift"))},
        "runtimeReceipt": Path("Vendor/llama-cpp/.lokalbot-build").read_text(),
        "runtimeManifestSHA256": digest("Vendor/llama-cpp/.lokalbot-runtime.sha256"),
        "powerAtStart": subprocess.check_output(["pmset", "-g", "batt"], text=True).strip(),
        "thermalAtStart": subprocess.check_output(["pmset", "-g", "therm"], text=True).strip(),
        "gitHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    }
    write_json(args.output / "manifest.json", manifest)
    write_json(args.output / "references.json", references)
    control = None
    runs = {1: [], 2: [], 4: []}
    for round_index in range(args.rounds):
        for width in orders[round_index % 3]:
            run_dir = args.output / f"round-{round_index + 1}-width-{width}"
            run_dir.mkdir()
            write_json(run_dir / "input.json", {"cases": cases, "decoderCandidates": width})
            print(f"START round={round_index + 1} width={width} checkpoints={len(cases)}", flush=True)
            started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="lokalbot-candidate-replay-") as temp:
                root = Path(temp)
                (root / "home").mkdir()
                env = dict(os.environ, CFFIXED_USER_HOME=str(root / "home"), LOKALBOT_STORAGE_ROOT=str(root / "storage"),
                           LOKALBOT_DEFAULTS_SUITE="me.dotenv.LokalBot.candidate-replay." + root.name)
                with (run_dir / "observations.jsonl").open("w") as stdout, (run_dir / "stderr.log").open("w") as stderr:
                    result = subprocess.run(["/usr/bin/time", "-l", str(app), "--cotyping-replay", str((run_dir / "input.json").resolve()),
                                             "--model-path", str(model)], env=env, stdout=stdout, stderr=stderr, timeout=3600)
            if result.returncode:
                raise RuntimeError(f"Native replay failed ({result.returncode}); inspect {run_dir}")
            observations = [json.loads(line) for line in (run_dir / "observations.jsonl").read_text().splitlines()]
            validate_observations(observations, references, width, control)
            if control is None:
                control = observations
                manifest["renderedPromptsSHA256"] = hashlib.sha256(json.dumps([(o["id"], o["prompt"]) for o in control], ensure_ascii=False).encode()).hexdigest()
                write_json(args.output / "manifest.json", manifest)
            report = summarize(observations, references)
            rss = re.search(r"(\d+)\s+maximum resident set size", (run_dir / "stderr.log").read_text())
            report["peakRSSBytes"] = int(rss[1]) if rss else None
            report["wallSecondsIncludingLoad"] = time.monotonic() - started
            report["manifest"] = {**manifest, "width": width, "round": round_index + 1}
            write_json(run_dir / "report.json", report)
            runs[width].append((report, observations))
            print(json.dumps({"round": round_index + 1, "width": width, **report["overall"]}), flush=True)
    # Quality repeats are not independent new examples. Use first-round paired
    # phrase bootstrap; show every run's timing/quality and output instability.
    comparisons = {str(width): compare(runs[1][0][0], runs[width][0][0]) for width in [2, 4]}
    summary = {"manifest": manifest, "comparisons": comparisons, "widths": {}}
    for width, entries in runs.items():
        first = entries[0][1]
        changed = sum(any((obs[i]["text"], obs[i].get("suppression")) != (item["text"], item.get("suppression"))
                          for _, obs in entries[1:]) for i, item in enumerate(first))
        summary["widths"][str(width)] = {"runs": [{"overall": r["overall"], "groups": r["groups"], "peakRSSBytes": r["peakRSSBytes"]} for r, _ in entries],
                                             "checkpointsWithRepeatVariation": changed}
    if digest(app) != manifest["appSHA256"] or any(digest(p) != sha for p, sha in manifest["sourceSHA256"].items()):
        raise RuntimeError("App or source changed during frozen benchmark")
    write_json(args.output / "summary.json", summary)
    print(f"COMPLETE {args.output / 'summary.json'}", flush=True)


if __name__ == "__main__":
    main()
