#!/usr/bin/env python3
"""Sequential fixed-model/prompt decoder experiments with a sealed phrase split.

References never enter native replay input. Quality units are phrases, not
repeated requests. Reported character credit is reference agreement, not an
observed user acceptance or keystroke saving rate.
"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import tempfile

from candidate_benchmark import summarize, validate_observations, write_json
from quality_replay import WORD, checkpoints, digest, predicted_words


ARMS = {
    "control": {},
    "greedy": {"temperature": 0},
    "no-repeat-penalty": {"repeatPenalty": 1},
    "longer-budget": {"maxTokens": 10},
    "ungated": {"confidenceGate": False},
    "beam4": {"decoderCandidates": 4},
    "beam4-sum": {"decoderCandidates": 4, "candidateRanking": "sum"},
    "beam4-first-word": {"decoderCandidates": 4, "candidateRanking": "firstWord"},
    "gate-020": {"firstWordThreshold": 0.2},
    "gate-005": {"firstWordThreshold": 0.05},
    "word-only-observe": {"confidenceBoundaryMode": "wordOnly", "firstWordThreshold": 1e-7},
    "boundary-mass-observe": {"confidenceBoundaryMode": "boundaryMass", "firstWordThreshold": 1e-7},
    "display-stop": {"stopAtDisplayLimit": True},
}


def add_character_references(refs, phrases):
    by_id = {p["id"]: p for p in phrases}
    for ident, ref in refs.items():
        phrase_id, index, offset = ident.rsplit(":", 2)
        phrase_id = phrase_id.split(":")[-1]
        phrase = by_id[phrase_id]
        words = list(WORD.finditer(phrase["text"]))
        index, offset = int(index), int(offset)
        caret = words[index].start() + offset
        ref["matchingCharacterCredits"] = [w.end() - caret for w in words[index:]]


def confirmation_suite(corpus, excluded):
    fold = lambda text: " ".join(WORD.findall(text.casefold()))
    known = {fold(p["text"]) for p in excluded}
    selected = [dict(p, id="fresh-" + p["id"]) for p in corpus["phrases"]]
    if not selected or len({p["id"] for p in selected}) != len(selected):
        raise ValueError("Independent corpus must have unique phrase IDs")
    texts = [fold(p["text"]) for p in selected]
    if len(set(texts)) != len(texts) or any(text in known for text in texts):
        raise ValueError("Confirmation reuses an earlier phrase")
    confirmation, targets = [], {}
    for mode in ["word", "midword"]:
        cases, references = checkpoints(selected, mode)
        if mode == "midword":
            keep = set()
            for phrase in selected:
                ids = [k for k, v in references.items() if v["phraseID"] == phrase["id"]]
                keep.update(sorted(ids, key=lambda x: hashlib.sha256(f"loop-mid:{x}".encode()).hexdigest())[:2])
            cases = [c for c in cases if c["id"] in keep]
        for case in cases:
            ident = case["id"]
            targets[ident] = dict(references[ident], group=f"confirmation-{mode}")
            confirmation.append(case)
    add_character_references(targets, selected)
    return confirmation, targets, selected


def prepare(prior, output, confirmation_corpus):
    if confirmation_corpus is None:
        raise ValueError("Supply a new --confirmation-corpus; the entire public corpus was evaluated in an older study")
    output.mkdir(parents=True, exist_ok=False)
    public = json.loads((prior / "public-corpus.json").read_text())
    challenge = json.loads((prior / "challenge-corpus.json").read_text())
    dev = json.loads((prior / "round-1-width-1/input.json").read_text())["cases"]
    refs = json.loads((prior / "references.json").read_text())
    add_character_references(refs, public["phrases"] + challenge["phrases"])
    old_ids = set(json.loads((prior / "manifest.json").read_text())["phraseIDs"])
    confirmation, targets, selected = confirmation_suite(
        json.loads(confirmation_corpus.read_text()), public["phrases"] + challenge["phrases"])
    for name, cases, references in [("development", dev, refs), ("confirmation", confirmation, targets)]:
        write_json(output / f"{name}-input.json", {"cases": cases})
        write_json(output / f"{name}-references.json", references)
    plan = {"createdAtUTC": datetime.now(timezone.utc).isoformat(),
            "developmentCheckpoints": len(dev), "confirmationCheckpoints": len(confirmation),
            "confirmationPhraseIDs": [p["id"] for p in selected], "developmentPublicPhraseIDs": sorted(old_ids),
            "priorCorpusSHA256": digest(prior / "public-corpus.json"),
            "confirmationCorpusSHA256": digest(confirmation_corpus),
            "fixedModelSHA256": "20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629",
            "initialArms": ARMS,
            "selection": "Choose on development only. Prefer more matching reference characters with no more incorrect first-word suggestions; latency p95 budget <= 1.10x control. Otherwise report the tradeoff, not an overall win. Freeze chosen arms before confirmation; three counterbalanced confirmation rounds. Phrase bootstrap 95% CI excludes zero for a confirmed quality gain.",
            "limitations": "Synthetic single-reference confirmation. Exact reference matching is not human acceptability. Headless warm complete-call latency excludes UI/debounce. No default promotion without product-shaped evidence."}
    write_json(output / "plan.json", plan)
    write_json(output / "phase-2-plan.json", {
        "calibrationThresholds": [.05, .1, .15, .2, .25, .3, .35, .4, .45, .5, .6, .7, .8, .9],
        "rule": "Development only; maximize matching reference characters at no more incorrect suggestions than control.",
    })
    for source in ["public-corpus.json", "challenge-corpus.json", "ATTRIBUTION.md", "COTABBY-LICENSE.txt"]:
        (output / source).write_bytes((prior / source).read_bytes())
    (output / "independent-confirmation-corpus.json").write_bytes(confirmation_corpus.read_bytes())
    print(json.dumps({k: plan[k] for k in ["developmentCheckpoints", "confirmationCheckpoints"]}), flush=True)


def metrics(rows, refs):
    report = summarize(rows, refs)
    records = []
    for row in rows:
        ref = refs[row["id"]]
        matches = 0
        for actual, expected in zip(predicted_words(row["text"], ref["typed"]), ref["words"]):
            if actual != expected:
                break
            matches += 1
        credits = ref["matchingCharacterCredits"][matches - 1] if matches else 0
        records.append({"id": row["id"], "phraseID": ref["phraseID"], "correct": matches > 0,
                        "incorrectShown": bool(row["text"]) and not matches,
                        "matchingCharacters": credits, "matchingWords": matches})
    report["overall"]["matchingCharacters"] = sum(r["matchingCharacters"] for r in records)
    report["overall"]["matchingCharactersPerCheckpoint"] = statistics.mean(r["matchingCharacters"] for r in records)
    report["qualityRecords"] = records
    return report


def run(app, model, output, split, arm, round_index):
    cases = json.loads((output / f"{split}-input.json").read_text())["cases"]
    refs = json.loads((output / f"{split}-references.json").read_text())
    directory = output / f"{split}-{round_index}-{arm}"
    directory.mkdir()
    settings = ARMS[arm]
    write_json(directory / "input.json", {"cases": cases, **settings})
    receipt = {"appSHA256": digest(app), "modelSHA256": digest(model), "settings": settings,
               "gitHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
               "inputSHA256": digest(directory / "input.json"), "referencesSHA256": digest(output / f"{split}-references.json"),
               "sourceSHA256": {str(p): digest(p) for p in sorted(Path("LokalBot/Cotyping").rglob("*.swift"))},
               "scriptSHA256": digest(__file__), "startedAtUTC": datetime.now(timezone.utc).isoformat()}
    if receipt["modelSHA256"] != json.loads((output / "plan.json").read_text())["fixedModelSHA256"]:
        raise ValueError("Model changed")
    write_json(directory / "receipt.json", receipt)
    with tempfile.TemporaryDirectory(prefix="lokalbot-decoder-loop-") as tmp:
        root = Path(tmp)
        (root / "home").mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(root / "home"), LOKALBOT_STORAGE_ROOT=str(root / "storage"),
                   LOKALBOT_DEFAULTS_SUITE="me.dotenv.LokalBot.decoder-loop." + root.name)
        with (directory / "observations.jsonl").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
            result = subprocess.run(["/usr/bin/time", "-l", str(app), "--cotyping-replay", str(directory / "input.json"),
                                     "--model-path", str(model)], env=env, stdout=stdout, stderr=stderr, timeout=3600)
    if result.returncode:
        raise RuntimeError(f"Replay failed: {directory}")
    rows = [json.loads(line) for line in (directory / "observations.jsonl").read_text().splitlines()]
    control_path = output / f"{split}-1-control/observations.jsonl"
    control = [json.loads(line) for line in control_path.read_text().splitlines()] if control_path.exists() else None
    validate_observations(rows, refs, settings.get("decoderCandidates", 1), control)
    for key in ["candidateRanking", "firstWordThreshold", "confidenceBoundaryMode", "stopAtDisplayLimit", "selectiveOneWordHybrid"]:
        if key not in settings:
            continue
        for row in rows:
            actual, expected = row.get(key), settings[key]
            if isinstance(expected, float):
                if actual is None or not math.isclose(actual, expected, rel_tol=1e-6):
                    raise ValueError(f"Native runtime ignored {key}")
            elif actual != expected:
                raise ValueError(f"Native runtime ignored {key}")
    if control is None and arm != "control":
        raise ValueError("Run a control before treatment")
    if digest(app) != receipt["appSHA256"]:
        raise ValueError("Executable changed during inference")
    report = metrics(rows, refs)
    rss = re.search(r"(\d+)\s+maximum resident set size", (directory / "stderr.log").read_text())
    report["maximumResidentBytes"] = int(rss[1]) if rss else None
    report["promptSHA256"] = hashlib.sha256(json.dumps([(r["id"], r["prompt"]) for r in rows]).encode()).hexdigest()
    write_json(directory / "summary.json", report)
    print(json.dumps({"split": split, "arm": arm, "round": round_index, **report["overall"]}), flush=True)


def paired_bootstrap(control, treatment, resamples=5000):
    if not control or len(control) != len(treatment):
        raise ValueError("Unpaired or empty quality rows")
    grouped = defaultdict(list)
    for old, new in zip(control, treatment):
        if old["id"] != new["id"]:
            raise ValueError("Unpaired quality rows")
        grouped[old["phraseID"]].append({k: new[k] - old[k] for k in ["correct", "incorrectShown", "matchingCharacters"]})
    groups = list(grouped.values())
    rng = random.Random(20261010)
    result = {}
    for key in ["correct", "incorrectShown", "matchingCharacters"]:
        totals = [(sum(x[key] for x in g), len(g)) for g in groups]
        samples = []
        for _ in range(resamples):
            chosen = rng.choices(totals, k=len(totals))
            samples.append(sum(x[0] for x in chosen) / sum(x[1] for x in chosen))
        samples.sort()
        result[key] = {"deltaPerCheckpoint": sum(x[0] for x in totals) / sum(x[1] for x in totals),
                       "ci95": [samples[math.floor(resamples * .025)], samples[math.ceil(resamples * .975) - 1]]}
    return {"phrases": len(groups), "resamples": resamples, "pairedPhraseBootstrap": result}


def calibrate(output, thresholds=None):
    refs = json.loads((output / "development-references.json").read_text())
    budget = json.loads((output / "development-1-control/summary.json").read_text())["overall"]["incorrectShown"]
    if thresholds is None:
        thresholds = json.loads((output / "phase-2-plan.json").read_text())["calibrationThresholds"]
    if not thresholds or any(not math.isfinite(x) or not 0 < x <= 1 for x in thresholds):
        raise ValueError("Calibration thresholds must be finite and in (0, 1]")
    fitted = {"incorrectShownBudget": budget, "thresholds": thresholds, "curves": {}, "arms": {}}
    for arm, boundary_mode in [("word-only", "wordOnly"), ("boundary-mass", "boundaryMass")]:
        path = output / f"development-2-{arm}-observe/observations.jsonl"
        source = [json.loads(line) for line in path.read_text().splitlines()]
        curve = []
        for threshold in thresholds:
            rows = []
            for row in source:
                candidate = dict(row)
                probability = (row.get("cache") or {}).get("firstWordProbability")
                if row["text"] and not refs[row["id"]]["typed"] and probability is None:
                    raise ValueError("Cannot calibrate without first-word confidence")
                if probability is not None and probability < threshold:
                    candidate.update(text="", suppression="lowConfidence")
                rows.append(candidate)
            report = metrics(rows, refs)
            curve.append({"threshold": threshold, **report["overall"]})
        eligible = [p for p in curve if p["incorrectShown"] <= budget]
        if not eligible:
            raise ValueError("No calibrated threshold meets the development budget")
        chosen = max(eligible, key=lambda p: (p["matchingCharacters"], p["correct"], p["threshold"]))
        fitted["curves"][arm] = curve
        fitted["arms"][arm + "-calibrated"] = {
            "confidenceBoundaryMode": boundary_mode, "firstWordThreshold": chosen["threshold"]}
        print(json.dumps({"arm": arm, "chosen": chosen}), flush=True)
    write_json(output / "calibration.json", fitted)
    return fitted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "run", "calibrate"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prior", type=Path)
    parser.add_argument("--confirmation-corpus", type=Path, help="Independent previously unevaluated phrase fixture")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--split", choices=["development", "confirmation"], default="development")
    parser.add_argument("--arms", nargs="+", default=["control"])
    parser.add_argument("--round", type=int, default=1)
    parser.add_argument("--thresholds", nargs="+", type=float, help="Explicit development-only calibration grid")
    args = parser.parse_args()
    if args.action == "prepare":
        prepare(args.prior, args.output, args.confirmation_corpus)
    elif args.action == "calibrate":
        calibrate(args.output, args.thresholds)
    else:
        calibration = args.output / "calibration.json"
        if calibration.exists():
            for name, settings in json.loads(calibration.read_text())["arms"].items():
                ARMS[name] = settings
                ARMS[name + "-stop"] = dict(settings, stopAtDisplayLimit=True)
        for arm in args.arms:
            if arm not in ARMS:
                parser.error(f"Unknown arm {arm}")
            run(args.app.resolve(strict=True), args.model.resolve(strict=True), args.output, args.split, arm, args.round)


if __name__ == "__main__":
    main()
