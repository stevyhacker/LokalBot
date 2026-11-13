#!/usr/bin/env python3
"""Rescore Cotabby and LokalBot on identical held-out checkpoints.

Inputs are completed headless runs, never UI captures. Cotabby keeps its product
prompt, runtime, sampling and length policy, so this compares products' first-word
accuracy and must not be presented as a controlled runtime/latency experiment.
"""

import argparse
import json
from pathlib import Path

from compare_quality import compare
from quality_replay import checkpoints, digest, fold, score, selected_phrases


def cotabby_observations(report, cases, references):
    expected = {case["id"]: case for case in cases}
    observations, native = {}, {}
    for phrase in report["phrases"]:
        if phrase["condition"] != "none":
            raise ValueError("Expected a no-screen-context Cotabby run")
        for observation in phrase["observations"]:
            checkpoint = observation["checkpoint"]
            ident = f"{phrase['phrase']['id']}:{checkpoint['wordIndex']}:{checkpoint['typedCharacters']}"
            if ident not in expected or ident in observations:
                raise ValueError(f"Unexpected or duplicated checkpoint: {ident}")
            if checkpoint["prefix"] != expected[ident]["prefix"]:
                raise ValueError(f"Different typed prefix: {ident}")
            scene = phrase["phrase"].get("scenario", {})
            for key, source, default in [("appName", "applicationName", "Notes"),
                                         ("bundleID", "bundleIdentifier", "com.apple.Notes"),
                                         ("windowTitle", "windowTitle", None),
                                         ("placeholder", "fieldPlaceholder", None)]:
                if scene.get(source, default) != expected[ident][key]:
                    raise ValueError(f"Different surface metadata: {ident} {key}")
            if fold(checkpoint["expectedWord"]) != references[ident]["words"][0]:
                raise ValueError(f"Different reference word: {ident}")
            observations[ident] = {
                "id": ident, "text": observation.get("shown", ""),
                "latencyMs": observation["latencyMilliseconds"], "error": observation.get("error"),
            }
            native[ident] = observation["correct"]
    if set(observations) != set(expected):
        raise ValueError("Incomplete Cotabby run")
    ordered = [observations[ident] for ident in references]
    rescored = score(ordered, references)
    if any(row["correct"] != native[row["id"]] for row in rescored["scores"]):
        raise ValueError("Common lexical scorer disagrees with Cotabby's native scorer")
    return ordered


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--cotabby", required=True, type=Path, help="Cotabby report.json")
    parser.add_argument("--lokalbot", required=True, action="append", type=Path,
                        help="Completed LokalBot run directory; repeat for each variant")
    parser.add_argument("--per-category", type=int, default=20)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    corpus_sha = digest(args.corpus)
    phrases = selected_phrases(json.loads(args.corpus.read_text()), "heldout", args.per_category)
    cases, references = checkpoints(phrases, "word")
    pairing = {"corpusSHA256": corpus_sha, "phraseIDs": [p["id"] for p in phrases],
               "mode": "word", "split": "heldout", "splitSeed": 1337,
               "context": "none (app/title/field metadata only)"}
    upstream = json.loads(args.cotabby.read_text())
    if upstream["metadata"]["corpusSHA256"] != corpus_sha:
        raise ValueError("Different Cotabby corpus")
    cotabby = score(cotabby_observations(upstream, cases, references), references)
    cotabby["manifest"] = {**pairing, "upstreamMetadata": upstream["metadata"],
                           "upstreamReportSHA256": digest(args.cotabby)}
    reports = {"cotabby": cotabby}
    for directory in args.lokalbot:
        if directory.name in reports:
            raise ValueError("Run labels must be unique")
        manifest = json.loads((directory / "manifest.json").read_text())
        for key in ["corpusSHA256", "mode", "split", "splitSeed", "context"]:
            if manifest[key] != pairing[key]:
                raise ValueError(f"Different LokalBot {key}: {directory}")
        if manifest["promptMode"] != "production" or manifest["settings"] != {"appContext": True}:
            raise ValueError(f"LokalBot run has experimental overrides: {directory}")
        actual = json.loads((directory / "input.json").read_text())["cases"]
        if [case for case in actual if case["id"] in references] != cases:
            raise ValueError(f"LokalBot input differs: {directory}")
        observations = [json.loads(line) for line in (directory / "observations.jsonl").read_text().splitlines()]
        result = score([row for row in observations if row["id"] in references], references)
        result["manifest"] = {**manifest, **pairing,
                               "sourceObservationSHA256": digest(directory / "observations.jsonl")}
        reports[directory.name] = result
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {"scope": "Exact first word; each product's prompt, sampling and output-length policy",
               "matching": pairing, "results": {}, "deltasFromCotabby": {}}
    for label, report in reports.items():
        (args.output / f"{label}.json").write_text(json.dumps(report, indent=2) + "\n")
        summary["results"][label] = report["overall"]
        if label != "cotabby":
            delta = compare(cotabby, report)
            summary["deltasFromCotabby"][label] = {
                key: value for key, value in delta.items() if key not in ["before", "after", "categories"]}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({key: value for key, value in summary.items() if key != "matching"}, indent=2))


if __name__ == "__main__":
    main()
