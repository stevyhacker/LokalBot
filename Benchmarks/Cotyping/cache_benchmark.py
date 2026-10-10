#!/usr/bin/env python3
"""Fixed-prompt quality regression and sequential headless typing/cache replay.

Includes independent cold scope starts, midword typing, backspace, divergence,
explicit invalidation and real in-flight cancellation. Not a UI/debounce test.
"""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import tempfile

from candidate_benchmark import summarize, validate_observations, write_json
from quality_replay import WORD, digest
from ranking_audit import audit


MODES = {"sampled": (1, False), "cache": (1, True), "beam2": (2, False), "beam4": (4, False)}
QUALITY_ORDERS = [["sampled", "cache", "beam2", "beam4"], ["cache", "beam4", "sampled", "beam2"],
                  ["beam2", "sampled", "beam4", "cache"], ["beam4", "beam2", "cache", "sampled"]]


def dynamic_cases(fixture):
    cases, metadata = [], {}
    for phrase in fixture["phrases"]:
        text = phrase["text"]
        words = list(WORD.finditer(text))
        word = words[2]
        lead = ("The workshop notes describe project schedules, test results and next steps. " * 70
                if phrase.get("longContext") else "")
        steps = [("start", word.start())]
        steps += [("forward", offset) for offset in range(word.start() + 1, word.end() + 1)]
        steps += [("forward", words[3].start() + 1), ("backspace", word.end() - 1),
                  ("backspace", word.start() + 1), ("retype", word.end()), ("repeat", word.end()),
                  ("branch", word.start()), ("recover", word.end()), ("scope-change", word.end()),
                  ("clear", word.end()), ("unscoped", word.end()), ("cancel", word.start()),
                  ("recover-after-cancel", word.end())]
        for index, (action, offset) in enumerate(steps):
            ident = f"{phrase['id']}:{index}:{action}"
            prefix = lead + text[:offset]
            if action == "branch":
                prefix += "different"
            if action == "cancel":
                prefix = "Synthetic cancellation prefill with a separate token history. " * 90 + text[:offset]
            case = {"id": ident, "prefix": prefix, "appName": "Notes", "bundleID": "com.apple.Notes",
                    "windowTitle": "Synthetic cache evaluation", "wordPrefixIsValidWord": True,
                    "cacheScope": phrase["id"] + (":other" if action == "scope-change" else ""),
                    "delayBeforeMs": [0, 8, 20][index % 3]}
            if action in {"start", "clear", "cancel"}:
                case["resetCache"] = True
            if action == "unscoped":
                case.pop("cacheScope")
            if action == "cancel":
                case["cancelAfterMs"] = 2
            cases.append(case)
            metadata[ident] = {"trace": phrase["id"], "split": phrase["split"], "action": action,
                               "longContext": phrase.get("longContext", False)}
    return cases, metadata


def timing(rows, key="latencyMs"):
    values = sorted(row[key] for row in rows if row.get(key) is not None)
    if not values:
        return {"count": 0}
    return {"count": len(values), "meanMs": statistics.mean(values),
            **{f"p{p}Ms": values[max(0, math.ceil(len(values) * p / 100) - 1)] for p in [50, 95, 99]}}


def validate_dynamic(rows, cases, enabled):
    if [r["id"] for r in rows] != [c["id"] for c in cases]:
        raise ValueError("Incomplete dynamic trace")
    previous_scope = None
    for row, case in zip(rows, cases):
        if row.get("error") or row.get("usedPromptOverride") or row.get("decoderCandidates") != 1:
            raise ValueError(f"Failed/nonproduction dynamic request: {row['id']}")
        if not math.isfinite(row["latencyMs"]) or row["latencyMs"] < 0:
            raise ValueError("Invalid timing")
        if row.get("cancelled") and (row["text"] or case.get("cancelAfterMs") is None):
            raise ValueError("Cancelled request published text or unexpected cancellation")
        if case.get("cancelAfterMs") is not None and not row.get("cancelled"):
            raise ValueError("Expected in-flight cancellation did not occur")
        cache = row.get("cache")
        if row.get("suppression") != "pre-generation-gate":
            if not cache or cache["enabled"] != enabled:
                raise ValueError("Missing/wrong cache arm")
            if cache["entries"] > 16 or cache["bytes"] > 32 * 1024 * 1024:
                raise ValueError("Cache exceeded memory bounds")
            if enabled and (case.get("resetCache") or not case.get("cacheScope") or case.get("cacheScope") != previous_scope) and cache["hits"]:
                raise ValueError("Cache reused state after invalidation")
            if row.get("cancelled") and enabled and (cache["entries"] or cache["bytes"]):
                raise ValueError("Cancelled request retained memoized state")
        previous_scope = case.get("cacheScope")


def paired_dynamic(control, treatment, metadata):
    changes, prompt_changes = [], []
    for old, new in zip(control, treatment):
        if old["id"] != new["id"]:
            raise ValueError("Unpaired trace")
        if old["prompt"] != new["prompt"]:
            prompt_changes.append(old["id"])
        if metadata[old["id"]]["action"] != "cancel" and (old["text"], old.get("suppression")) != (new["text"], new.get("suppression")):
            changes.append(old["id"])
    return {"outputChanges": changes, "promptChanges": prompt_changes}


def run(app, model, directory, cases, mode):
    directory.mkdir()
    width, enabled = MODES[mode]
    write_json(directory / "input.json", {"cases": cases, "decoderCandidates": width, "logitCache": enabled})
    with tempfile.TemporaryDirectory(prefix="lokalbot-cache-replay-") as temp:
        root = Path(temp)
        (root / "home").mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(root / "home"), LOKALBOT_STORAGE_ROOT=str(root / "storage"),
                   LOKALBOT_DEFAULTS_SUITE="me.dotenv.LokalBot.cache-replay." + root.name)
        with (directory / "observations.jsonl").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
            result = subprocess.run(["/usr/bin/time", "-l", str(app), "--cotyping-replay", str(directory / "input.json"),
                                     "--model-path", str(model)], env=env, stdout=stdout, stderr=stderr, timeout=3600)
    if result.returncode:
        raise RuntimeError(f"Replay failed: {directory}")
    rows = [json.loads(line) for line in (directory / "observations.jsonl").read_text().splitlines()]
    rss = re.search(r"(\d+)\s+maximum resident set size", (directory / "stderr.log").read_text())
    return rows, int(rss[1]) if rss else None


def cache_stats(rows):
    stats = [r["cache"] for r in rows if r.get("cache")]
    return {"hits": sum(r["hits"] for r in stats), "misses": sum(r["misses"] for r in stats),
            "decodedTokens": sum(r["decodedTokens"] for r in stats),
            "maxEntries": max((r["entries"] for r in stats), default=0),
            "maxBytes": max((r["bytes"] for r in stats), default=0)}


def trace_bootstrap(control, treatment, metadata):
    differences = defaultdict(list)
    for old, new in zip(control, treatment):
        meta = metadata[old["id"]]
        if meta["split"] == "heldout" and meta["action"] != "cancel":
            differences[meta["trace"]].append(new["latencyMs"] - old["latencyMs"])
    groups = list(differences.values())
    rng = random.Random(20261010)
    resamples = sorted(statistics.mean(x for group in rng.choices(groups, k=len(groups)) for x in group) for _ in range(3000))
    return {"heldoutTraces": len(groups), "meanDifferenceMs": statistics.mean(x for group in groups for x in group),
            "meanDifference95CI": [resamples[75], resamples[2924]], "resamples": 3000,
            "unit": "whole trace; repetitions are not independent quality examples"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--prior", type=Path, required=True, help="Extracted previous native benchmark directory")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=4)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("rounds must be positive")
    app, model, output = args.app.resolve(strict=True), args.model.resolve(strict=True), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    refs = json.loads((args.prior / "references.json").read_text())
    quality = json.loads((args.prior / "round-1-width-1/input.json").read_text())["cases"]
    # Scope tags are replay controls only, never included in rendered prompts.
    for case in quality:
        case["cacheScope"] = refs[case["id"]]["phraseID"]
    fixture_path = Path(__file__).with_name("cache-typing-cases.json")
    dynamic, metadata = dynamic_cases(json.loads(fixture_path.read_text()))
    write_json(output / "references.json", refs)
    write_json(output / "dynamic-metadata.json", metadata)
    manifest = {"startedAtUTC": datetime.now(timezone.utc).isoformat(), "appSHA256": digest(app),
                "modelFile": model.name, "modelSHA256": digest(model), "scriptSHA256": digest(__file__),
                "dynamicFixtureSHA256": digest(fixture_path), "rounds": args.rounds,
                "priorInputSHA256": digest(args.prior / "round-1-width-1/input.json"),
                "referenceSHA256": digest(args.prior / "references.json"),
                "benchmarkSourceSHA256": {str(p): digest(p) for p in sorted(Path(__file__).parent.glob("*.py"))},
                "qualityCheckpoints": len(quality), "dynamicSteps": len(dynamic),
                "gitHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                "sourceSHA256": {str(p): digest(p) for p in sorted(Path("LokalBot/Cotyping").rglob("*.swift"))},
                "cache": {"capacity": 16, "byteLimit": 32 * 1024 * 1024, "lifetimeSeconds": 30},
                "runtimeReceipt": Path("Vendor/llama-cpp/.lokalbot-build").read_text(),
                "machine": {"platform": platform.platform(),
                            "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                            "memoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))},
                "settings": "Same production prompt, model, sampler, healing, confidence and normalization. No saved settings, personal data or remote inference.",
                "boundary": "Complete warm engine request; excludes model load, delay between requests, debounce, accessibility and overlay. Cancellation-to-quiescence is measured separately.",
                "goNoGo": "Cache requires identical noncancelled output/suppression, no invalidation violations, and improved heldout p95 within 32MiB logit storage. No default promotion without end-to-end UI evidence.",
                "powerAtStart": subprocess.check_output(["pmset", "-g", "batt"], text=True).strip()}
    prior_manifest = json.loads((args.prior / "manifest.json").read_text())
    if manifest["modelSHA256"] != prior_manifest["modelSHA256"] or manifest["runtimeReceipt"] != prior_manifest["runtimeReceipt"]:
        raise ValueError("Model weights or pinned runtime differ from the prior experiment")
    manifest["priorAppSHA256"] = prior_manifest["appSHA256"]
    write_json(output / "manifest.json", manifest)
    quality_runs, dynamic_runs = defaultdict(list), defaultdict(list)
    all_control = None
    for round_index in range(args.rounds):
        for mode in QUALITY_ORDERS[round_index % 4]:
            directory = output / f"quality-{round_index + 1}-{mode}"
            print(f"START {directory.name}", flush=True)
            rows, rss = run(app, model, directory, quality, mode)
            validate_observations(rows, refs, MODES[mode][0], all_control)
            if MODES[mode][0] == 1:
                for row in rows:
                    if row.get("suppression") != "pre-generation-gate" and (row.get("cache") or {}).get("enabled") != MODES[mode][1]:
                        raise ValueError("Missing/wrong cache mode in quality replay")
            if all_control is None:
                all_control = rows
                manifest["renderedPromptsSHA256"] = hashlib.sha256(json.dumps([(r["id"], r["prompt"]) for r in rows], ensure_ascii=False).encode()).hexdigest()
                if manifest["renderedPromptsSHA256"] != prior_manifest["renderedPromptsSHA256"]:
                    raise ValueError("Production prompts changed from the prior experiment")
                write_json(output / "manifest.json", manifest)
            report = summarize(rows, refs)
            report.update(peakRSSBytes=rss, cache=cache_stats(rows))
            write_json(directory / "report.json", report)
            write_json(directory / "ranking-audit.json", audit(rows, refs))
            quality_runs[mode].append((rows, report))
            print(json.dumps({"mode": mode, "quality": report["overall"], "cache": report["cache"]}), flush=True)
        for mode in (["sampled", "cache"] if round_index % 2 == 0 else ["cache", "sampled"]):
            directory = output / f"dynamic-{round_index + 1}-{mode}"
            print(f"START {directory.name}", flush=True)
            rows, rss = run(app, model, directory, dynamic, mode)
            validate_dynamic(rows, dynamic, MODES[mode][1])
            report = {"timing": timing([r for r in rows if not r.get("cancelled")]), "peakRSSBytes": rss,
                      "cache": cache_stats(rows), "cancelled": sum(r.get("cancelled", False) for r in rows),
                      "cancellationTiming": timing(rows, "cancellationLatencyMs")}
            write_json(directory / "report.json", report)
            dynamic_runs[mode].append((rows, report))
            print(json.dumps({"mode": mode, **report}), flush=True)
    summary = {"manifest": manifest, "quality": {}, "dynamic": {}, "dynamicPairs": []}
    for mode, runs in quality_runs.items():
        pooled = [r for rows, _ in runs for r in rows]
        first = runs[0][0]
        summary["quality"][mode] = {"runs": [report for _, report in runs], "timing": timing(pooled),
            "changedFromControl": sum((r["text"], r.get("suppression")) != (c["text"], c.get("suppression")) for r, c in zip(first, all_control)),
            "repeatVariations": sum(any((r["text"], r.get("suppression")) != (rows[i]["text"], rows[i].get("suppression")) for rows, _ in runs[1:]) for i, r in enumerate(first))}
        summary["quality"][mode]["runs"] = [{key: report[key] for key in ["overall", "groups", "peakRSSBytes", "cache"]} for _, report in runs]
    for mode, runs in dynamic_runs.items():
        pooled = [r for rows, _ in runs for r in rows]
        usable = [r for r in pooled if metadata[r["id"]]["action"] != "cancel"]
        summary["dynamic"][mode] = {"runs": [report for _, report in runs], "timing": timing(usable),
            "heldoutTiming": timing([r for r in usable if metadata[r["id"]]["split"] == "heldout"]),
            "byAction": {action: timing([r for r in usable if metadata[r["id"]]["action"] == action]) for action in sorted({m["action"] for m in metadata.values()})},
            "cache": cache_stats(pooled), "cancellationTiming": timing(pooled, "cancellationLatencyMs")}
    for (old, _), (new, _) in zip(dynamic_runs["sampled"], dynamic_runs["cache"]):
        summary["dynamicPairs"].append(paired_dynamic(old, new, metadata))
    summary["dynamicPairedBootstrap"] = trace_bootstrap(
        [r for rows, _ in dynamic_runs["sampled"] for r in rows], [r for rows, _ in dynamic_runs["cache"] for r in rows], metadata)
    unchanged = summary["quality"]["cache"]["changedFromControl"] == 0 and all(
        summary["quality"][mode]["repeatVariations"] == 0 for mode in ["sampled", "cache"])
    unchanged = unchanged and all(not p["outputChanges"] and not p["promptChanges"] for p in summary["dynamicPairs"])
    improved_tail = summary["dynamic"]["cache"]["heldoutTiming"]["p95Ms"] < summary["dynamic"]["sampled"]["heldoutTiming"]["p95Ms"]
    summary["cacheGate"] = {"identicalOutputs": unchanged, "invalidationAndBoundsPassed": True,
                            "heldoutP95Improved": improved_tail, "passed": unchanged and improved_tail,
                            "productionPromotion": False, "requiresUIValidation": True}
    frozen_sources = {**manifest["sourceSHA256"], **manifest["benchmarkSourceSHA256"]}
    if digest(app) != manifest["appSHA256"] or digest(model) != manifest["modelSHA256"] or any(digest(p) != sha for p, sha in frozen_sources.items()):
        raise RuntimeError("App/source changed during frozen benchmark")
    write_json(output / "summary.json", summary)
    print(f"COMPLETE {output / 'summary.json'}", flush=True)


if __name__ == "__main__":
    main()
