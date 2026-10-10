#!/usr/bin/env python3
"""Frozen native selective-hybrid confirmation and blinded Claude packets.

All inputs are synthetic. Reference continuations never reach either model.
The one-word fallback is implemented in Swift; Python only verifies its output.
"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import random
import subprocess
import tempfile

import claude_judge as judge
import decoder_loop as loop
from cache_benchmark import dynamic_cases, timing, validate_dynamic
from candidate_benchmark import write_json
from quality_replay import digest


MODEL_SHA = "20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629"
SETTINGS = {
    "control": {},
    "hybrid": {"selectiveOneWordHybrid": True},
    "mass-reference": {"confidenceBoundaryMode": "boundaryMass", "firstWordThreshold": 0.31},
}
ORDERS = [["control", "hybrid"], ["hybrid", "control"], ["hybrid", "control"], ["control", "hybrid"]]


def read(path):
    return json.loads(Path(path).read_text())


def rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def parity(control, mass, hybrid):
    if not control or len(control) != len(mass) or len(control) != len(hybrid):
        raise ValueError("Empty or unpaired observations")
    added = 0
    for old, alternative, actual in zip(control, mass, hybrid):
        if len({row["id"] for row in [old, alternative, actual]}) != 1:
            raise ValueError("Unpaired IDs")
        if len({row["prompt"] for row in [old, alternative, actual]}) != 1:
            raise ValueError("Model prompts changed")
        if any(row.get("cancelled") for row in [old, alternative, actual]):
            continue
        expected = old["text"] or judge.first_word(alternative["text"])
        if actual["text"] != expected:
            raise ValueError(f"Native hybrid differs from frozen composition: {old['id']}")
        if old["text"] and actual.get("suppression") != old.get("suppression"):
            raise ValueError("Changed an existing suggestion suppression")
        added += bool(actual["text"]) and not old["text"]
    return {"pairedRequests": len(control), "textMismatches": 0, "newlyShown": added}


def same_outputs(a, b):
    if len(a) != len(b):
        raise ValueError("Unpaired repeated outputs")
    changed = 0
    for left, right in zip(a, b):
        if left["id"] != right["id"] or left["prompt"] != right["prompt"]:
            raise ValueError("Repeated input/prompt changed")
        if not left.get("cancelled") and not right.get("cancelled"):
            changed += (left["text"], left.get("suppression")) != (right["text"], right.get("suppression"))
    return changed


def latency_delta(control_runs, hybrid_runs, group_for_id, resamples=3000):
    groups = defaultdict(list)
    if len(control_runs) != len(hybrid_runs):
        raise ValueError("Unpaired latency rounds")
    for control, hybrid in zip(control_runs, hybrid_runs):
        if len(control) != len(hybrid):
            raise ValueError("Unpaired latency rows")
        for old, new in zip(control, hybrid):
            if old["id"] != new["id"]:
                raise ValueError("Unpaired latency IDs")
            if not old.get("cancelled") and not new.get("cancelled"):
                groups[group_for_id[old["id"]]].append(new["latencyMs"] - old["latencyMs"])
    totals = [(sum(group), len(group)) for group in groups.values()]
    if not totals:
        raise ValueError("Empty latency sample")
    rng = random.Random(10102026)
    draws = []
    for _ in range(resamples):
        sample = rng.choices(totals, k=len(totals))
        draws.append(sum(s for s, _ in sample) / sum(n for _, n in sample))
    draws.sort()
    return {"meanDifferenceMs": sum(s for s, _ in totals) / sum(n for _, n in totals),
            "ci95": [draws[int(.025 * resamples)], draws[int(.975 * resamples)]],
            "groups": len(totals), "resamples": resamples,
            "unit": "whole phrase or typing trace, retaining all paired rounds; not independent repetitions"}


def prepare(prior, output):
    output.mkdir(parents=True, exist_ok=False)
    fixture = Path(__file__).with_name("hybrid-confirmation-cases.json")
    excluded = []
    for name in ["public-corpus.json", "challenge-corpus.json", "independent-confirmation-corpus.json"]:
        excluded.extend(read(prior / name)["phrases"])
    cases, refs, phrases = loop.confirmation_suite(read(fixture), excluded)
    write_json(output / "fresh-input.json", {"cases": cases})
    write_json(output / "fresh-references.json", refs)
    (output / fixture.name).write_bytes(fixture.read_bytes())
    for split, original in [("development", "development"), ("regression", "confirmation")]:
        for kind in ["input", "references"]:
            (output / f"{split}-{kind}.json").write_bytes((prior / f"{original}-{kind}.json").read_bytes())
    dynamic_fixture = Path(__file__).with_name("cache-typing-cases.json")
    dynamic, metadata = dynamic_cases(read(dynamic_fixture))
    write_json(output / "dynamic-input.json", {"cases": dynamic})
    write_json(output / "dynamic-metadata.json", metadata)
    plan = {
        "createdAtUTC": datetime.now(timezone.utc).isoformat(), "status": "frozen before native evaluation",
        "fixedModelSHA256": MODEL_SHA, "settings": SETTINGS, "freshOrders": ORDERS,
        "freshPhrases": len(phrases), "freshCheckpoints": len(cases), "dynamicRequests": len(dynamic),
        "regression": "All 600 development and 1361 old confirmation checkpoints, once per arm; now regression only.",
        "latency": "Four fresh-corpus rounds AB/BA/BA/AB; two dynamic rounds AB/BA. Mass reference once, excluded from speed comparison.",
        "primaryQuality": "Blinded Claude utility delta for actual native hybrid versus current on every changed fresh checkpoint. Unchanged outputs contribute zero. Whole-phrase bootstrap, ordinal utility -2..2 with silence=0.",
        "judgeSelection": "Fresh: all differences plus up to 8 shared shown per category, 16 changed + 8 shared blind repeats. Regression: all differences plus 4 shared per category, same repeat rule. Every new fallback is judged; no reference future or algorithm identities sent.",
        "success": "Exact native equivalence to current if nonempty else first complete normalized mass-reference word. No loss/change of current nonempty outputs. Quality improvement requires positive phrase-bootstrap CI; report measured latency tradeoff independently.",
        "policy": "One sampled stream; selected-token .1 primary and boundary-mass .31 fallback. Cap only after unchanged full normalization. No early-stop, cache, sampler, model or prompt changes. No tuning on fresh corpus.",
        "limitations": "Synthetic corpus written by implementing assistant; one model judge, not user acceptance. Complete warm headless calls exclude load/debounce/AX/overlay and first-visible timing. Hybrid waits for final normalization before publishing. Defaults remain current.",
        "inputSHA256": {p.name: digest(p) for p in sorted(output.glob("*.json"))},
    }
    write_json(output / "plan.json", plan)
    print(json.dumps({k: plan[k] for k in ["freshPhrases", "freshCheckpoints", "dynamicRequests"]}), flush=True)


def run_dynamic(app, model, output, arm, round_index):
    directory = output / f"dynamic-{round_index}-{arm}"
    directory.mkdir()
    cases = read(output / "dynamic-input.json")["cases"]
    write_json(directory / "input.json", {"cases": cases, **SETTINGS[arm]})
    with tempfile.TemporaryDirectory(prefix="lokalbot-native-hybrid-") as temp:
        root = Path(temp)
        (root / "home").mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(root / "home"), LOKALBOT_STORAGE_ROOT=str(root / "storage"),
                   LOKALBOT_DEFAULTS_SUITE="me.dotenv.LokalBot.hybrid." + root.name)
        with (directory / "observations.jsonl").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
            process = subprocess.run(["/usr/bin/time", "-l", str(app), "--cotyping-replay", str(directory / "input.json"),
                                      "--model-path", str(model)], env=env, stdout=stdout, stderr=stderr, timeout=3600)
    if process.returncode:
        raise RuntimeError(f"Dynamic native replay failed: {directory}")
    result = rows(directory / "observations.jsonl")
    validate_dynamic(result, cases, False)
    for row in result:
        if row.get("selectiveOneWordHybrid") != (arm == "hybrid") or row.get("stopAtDisplayLimit"):
            raise ValueError("Native controls ignored")
    print(json.dumps({"dynamicRound": round_index, "arm": arm,
                      **timing([r for r in result if not r.get("cancelled")])}), flush=True)


def run(app, model, prior, output):
    plan = read(output / "plan.json")
    if plan["settings"] != SETTINGS or plan["freshOrders"] != ORDERS or digest(model) != MODEL_SHA:
        raise ValueError("Frozen model or plan changed")
    for name, expected in plan["inputSHA256"].items():
        if digest(output / name) != expected:
            raise ValueError("Frozen input changed")
    receipt = {"startedAtUTC": datetime.now(timezone.utc).isoformat(), "appSHA256": digest(app), "modelSHA256": digest(model),
               "gitHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
               "sourceSHA256": {str(p): digest(p) for p in sorted(Path("LokalBot/Cotyping").rglob("*.swift"))},
               "scriptSHA256": {p.name: digest(p) for p in sorted(Path(__file__).parent.glob("*.py"))},
               "runtimeReceipt": Path("Vendor/llama-cpp/.lokalbot-build").read_text(),
               "machine": {"platform": platform.platform(),
                           "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                           "memoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))},
               "powerAtStart": subprocess.check_output(["pmset", "-g", "batt"], text=True).strip()}
    write_json(output / "execution.json", receipt)
    loop.ARMS.update(SETTINGS)
    for split in ["development", "regression"]:
        for arm in SETTINGS:
            loop.run(app, model, output, split, arm, 1)
        parity(*(rows(output / f"{split}-1-{arm}/observations.jsonl") for arm in ["control", "mass-reference", "hybrid"]))
    for index, order in enumerate(ORDERS, 1):
        for arm in order:
            loop.run(app, model, output, "fresh", arm, index)
    loop.run(app, model, output, "fresh", "mass-reference", 1)
    parity(*(rows(output / f"fresh-1-{arm}/observations.jsonl") for arm in ["control", "mass-reference", "hybrid"]))
    for index, order in enumerate(ORDERS[:2], 1):
        for arm in order:
            run_dynamic(app, model, output, arm, index)
    run_dynamic(app, model, output, "mass-reference", 1)
    if digest(app) != receipt["appSHA256"] or digest(model) != MODEL_SHA:
        raise ValueError("Executable or model changed")
    receipt["finishedAtUTC"] = datetime.now(timezone.utc).isoformat()
    receipt["powerAtEnd"] = subprocess.check_output(["pmset", "-g", "batt"], text=True).strip()
    write_json(output / "execution.json", receipt)
    analyze(output, prior)


def analyze(output, prior):
    report = {"static": {}, "dynamic": {}}
    for split in ["development", "regression", "fresh"]:
        references = read(output / f"{split}-references.json")
        rounds = 4 if split == "fresh" else 1
        arm_rows = {arm: [rows(output / f"{split}-{i}-{arm}/observations.jsonl") for i in range(1, rounds + 1)]
                    for arm in ["control", "hybrid"]}
        mass = rows(output / f"{split}-1-mass-reference/observations.jsonl")
        result = {"parity": parity(arm_rows["control"][0], mass, arm_rows["hybrid"][0]), "arms": {}}
        for arm, runs in arm_rows.items():
            metrics = loop.metrics(runs[0], references)
            result["arms"][arm] = {"quality": metrics["overall"], "groups": metrics["groups"],
                                    "timing": timing([r for run in runs for r in run]),
                                    "roundTiming": [timing(run) for run in runs],
                                    "repeatDifferences": sum(same_outputs(runs[0], run) for run in runs[1:])}
        result["qualityDelta"] = loop.paired_bootstrap(
            loop.metrics(arm_rows["control"][0], references)["qualityRecords"],
            loop.metrics(arm_rows["hybrid"][0], references)["qualityRecords"])
        result["latencyDelta"] = latency_delta(arm_rows["control"], arm_rows["hybrid"],
                                               {ident: ref["phraseID"] for ident, ref in references.items()})
        old_paths = {"development": "development-4-control", "regression": "confirmation-1-control"}
        if split in old_paths:
            result["controlDifferencesFromPriorBinary"] = same_outputs(
                rows(prior / old_paths[split] / "observations.jsonl"), arm_rows["control"][0])
        report["static"][split] = result
    dynamic = {arm: [rows(output / f"dynamic-{i}-{arm}/observations.jsonl") for i in [1, 2]] for arm in ["control", "hybrid"]}
    metadata = read(output / "dynamic-metadata.json")
    mass = rows(output / "dynamic-1-mass-reference/observations.jsonl")
    report["dynamic"]["parity"] = parity(dynamic["control"][0], mass, dynamic["hybrid"][0])
    report["dynamic"]["arms"] = {}
    for arm, runs in dynamic.items():
        all_rows = [r for run in runs for r in run]
        report["dynamic"]["arms"][arm] = {
            "timing": timing([r for r in all_rows if not r.get("cancelled")]),
            "roundTiming": [timing([r for r in run if not r.get("cancelled")]) for run in runs],
            "cancelled": sum(bool(r.get("cancelled")) for r in all_rows),
            "cancellationReturn": timing([r for r in all_rows if r.get("cancelled")], "cancellationLatencyMs"),
            "repeatDifferences": same_outputs(*runs)}
    report["dynamic"]["latencyDelta"] = latency_delta(dynamic["control"], dynamic["hybrid"],
                                                       {ident: ref["trace"] for ident, ref in metadata.items()})
    write_json(output / "analysis.json", report)
    print(json.dumps({"analysis": str(output / "analysis.json")}), flush=True)


def prepare_judge(source, output, split):
    output.mkdir(parents=True, exist_ok=False)
    current_path = source / f"{split}-1-control/observations.jsonl"
    hybrid_path = source / f"{split}-1-hybrid/observations.jsonl"
    current, hybrid = rows(current_path), rows(hybrid_path)
    inputs = {c["id"]: c for c in read(source / f"{split}-input.json")["cases"]}
    refs = read(source / f"{split}-references.json")
    cases, shared_by_category = [], defaultdict(list)
    if len(current) != len(hybrid):
        raise ValueError("Unpaired judge outputs")
    for old, new in zip(current, hybrid):
        if old["id"] != new["id"] or old["prompt"] != new["prompt"]:
            raise ValueError("Unpaired judge inputs")
        ident = old["id"]
        case = {"id": ident, "phraseID": refs[ident]["phraseID"], "category": refs[ident]["category"],
                "prefix": inputs[ident]["prefix"], "kind": "unchanged" if old["text"] == new["text"] else "newly_shown",
                "policies": {"current": old["text"], "hybrid_one_word": new["text"]}}
        if old["text"] and old["text"] != new["text"]:
            raise ValueError("Hybrid changed an existing suggestion")
        cases.append(case)
        if case["kind"] == "unchanged" and old["text"]:
            shared_by_category[case["category"]].append(case)
    changed = [c for c in cases if c["kind"] != "unchanged"]
    key = lambda c: judge.digest("native-hybrid-20261010:" + c["id"])
    shared = [c for category in sorted(shared_by_category)
              for c in sorted(shared_by_category[category], key=key)[:8 if split == "fresh" else 4]]
    primary = sorted(changed + shared, key=key)
    repeated = sorted(changed, key=key)[:16] + sorted(shared, key=key)[:8]
    mapping, batches = {}, []
    for stage, selected in [("primary", primary), ("repeat", repeated)]:
        blinded = []
        for case in selected:
            packet = judge.blind_case(case, stage == "repeat")
            mapping[packet["id"]] = {"caseID": case["id"], "stage": stage,
                                      "options": {o["id"]: o["continuation"] for o in packet["options"]}}
            blinded.append(packet)
        for start in range(0, len(blinded), 24):
            name = f"{stage}-{start // 24 + 1:02d}"
            directory = output / "batches" / name
            directory.mkdir(parents=True)
            packet = {"cases": blinded[start:start + 24]}
            write_json(directory / "packet.json", packet)
            prompt = judge.RUBRIC + json.dumps(packet["cases"], ensure_ascii=False, separators=(",", ":"))
            (directory / "request.txt").write_text(prompt)
            batches.append({"id": name, "stage": stage, "cases": len(packet["cases"]), "requestSHA256": judge.digest(prompt)})
    write_json(output / "cases.json", cases)
    write_json(output / "private-mapping.json", mapping)
    (output / "system.txt").write_text(judge.SYSTEM)
    write_json(output / "schema.json", judge.SCHEMA)
    write_json(output / "protocol.json", {
        "createdAtUTC": datetime.now(timezone.utc).isoformat(), "status": "frozen before rejudging",
        "policies": ["current", "hybrid_one_word"], "split": split,
        "qualityStatus": "fresh confirmation" if split == "fresh" else "previously evaluated regression",
        "counts": {"all": len(cases), "changed": len(changed), "sharedShownSample": len(shared), "repeat": len(repeated)},
        "selection": "All actual native differences plus frozen hash-selected shared suggestions and repeats.",
        "scoring": "Same prior rubric; all-checkpoint phrase bootstrap. Silent current utility 0. Synthetic model opinion, not acceptance.",
        "blind": "No references, future words, decoder names, timings or product source in public packets.",
        "sourceSHA256": {"current": digest(current_path), "hybrid": digest(hybrid_path)},
        "casesSHA256": digest(output / "cases.json"), "systemSHA256": judge.digest(judge.SYSTEM),
        "schemaSHA256": digest(output / "schema.json"), "batches": batches})
    print(json.dumps(read(output / "protocol.json")["counts"]), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "run", "analyze", "prepare-judge"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prior", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--split", choices=["fresh", "regression"], default="fresh")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--model", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.prior.resolve(), args.output.resolve())
    elif args.command == "run":
        run(args.app.resolve(), args.model.resolve(), args.prior.resolve(), args.output.resolve())
    elif args.command == "analyze":
        analyze(args.output.resolve(), args.prior.resolve())
    else:
        prepare_judge(args.source.resolve(), args.output.resolve(), args.split)


if __name__ == "__main__":
    main()
