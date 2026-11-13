#!/usr/bin/env python3
"""Autocomplete engine benchmark: safety checks, next-word accuracy and typing latency.

Runs the production autocomplete runtime on one local GGUF. Every part is a
headless app process that starts before the app itself, so it reads no
settings, library or learned writing, and opens no window or menu-bar icon.

1. checks    `--cotyping-bench --model-path`: the 28 scenarios in
             CotypingBenchmark.swift, repeated. Each result is shown, allowed
             silence, withheld, a wrong word, unsafe or an error; model loading,
             the first pass and the warm passes are timed separately.
2. accuracy  `--cotyping-replay` at every word boundary of the checked-in
             original phrases: exact next-word accuracy, how often a suggestion
             shows, and how often a shown suggestion is right.
3. typing    `--cotyping-replay` one keystroke at a time through a subset of
             those phrases, so the prompt cache is reused the way typing reuses it.

Replay settings mirror `LlamaCotypingRuntime.forAutocomplete()`; every
observation is checked against them.
"""

import argparse
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from quality_replay import checkpoints, digest, score


HERE = Path(__file__).resolve().parent
CORPORA = [HERE / "quality-cases.json", HERE / "hybrid-confirmation-cases.json"]
# What the app's autocomplete runtime uses (LlamaCotypingRuntime.forAutocomplete).
PRODUCTION = {"selectiveOneWordHybrid": True, "searchExperiment": "certified", "nativeThreads": 2}
TYPING_PHRASES = ["quality-email-01", "quality-email-07", "quality-formatting-02",
                  "quality-long-context-01", "quality-long-context-03", "quality-multilingual-03",
                  "hybrid-conversation-01", "hybrid-work-01"]
ENGLISH = {"email", "formatting", "long-context", "conversation", "work", "technology",
           "everyday", "travel", "science"}
# Untimed, unscored requests that settle the runtime before measurement, as the
# earlier latency studies did.
WARMUP = ["Thanks for the ", "Let me know if ", "I will send the ", "See you ",
          "Could you please ", "The meeting is ", "We should ", "Best "]


def load_phrases():
    phrases = []
    for path in CORPORA:
        phrases += json.loads(path.read_text())["phrases"]
    if len({p["id"] for p in phrases}) != len(phrases):
        raise SystemExit("Duplicate phrase IDs across corpora")
    return phrases


def warmup_cases():
    return [{"id": f"warmup-{i}", "prefix": prefix, "appName": "Notes", "bundleID": "com.apple.Notes"}
            for i, prefix in enumerate(WARMUP)]


def typing_cases(phrases):
    """One request per typed character of each phrase, after its document prefix."""
    by_id = {p["id"]: p for p in phrases}
    cases = []
    for phrase_id in TYPING_PHRASES:
        phrase = by_id[phrase_id]
        scene = phrase.get("scenario", {})
        for end in range(1, len(phrase["text"]) + 1):
            cases.append({
                "id": f"{phrase_id}:{end}", "prefix": scene.get("documentPrefix", "") + phrase["text"][:end],
                "appName": scene.get("applicationName", "Notes"),
                "bundleID": scene.get("bundleIdentifier", "com.apple.Notes"),
                "windowTitle": scene.get("windowTitle"), "placeholder": scene.get("fieldPlaceholder"),
            })
    return cases


def stats(values):
    if not values:
        return None
    ordered = sorted(values)

    def rank(p):
        return ordered[max(0, math.ceil(len(ordered) * p) - 1)]

    return {"count": len(ordered), "meanMs": round(sum(ordered) / len(ordered), 1),
            "medianMs": round(rank(0.5), 1), "p90Ms": round(rank(0.9), 1),
            "p95Ms": round(rank(0.95), 1), "maxMs": round(ordered[-1], 1)}


def check_production(observations):
    for row in observations:
        actual = {key: row.get(key) for key in PRODUCTION}
        if actual != PRODUCTION or row.get("healingMode") != "prefixSearch":
            raise SystemExit(f"{row['id']} did not use the production runtime settings: {actual}")


def run_app(app, args, output, name, timeout):
    """Run one app process in a disposable home and library; return its exit code."""
    with tempfile.TemporaryDirectory(prefix="lokalbot-engine-bench-") as temp:
        root = Path(temp)
        (root / "home").mkdir()
        env = dict(os.environ, LOKALBOT_STORAGE_ROOT=str(root / "storage"), CFFIXED_USER_HOME=str(root / "home"))
        env.pop("LOKALBOT_REPLAY_API_KEY", None)
        with (output / f"{name}.out").open("w") as stdout, (output / f"{name}.stderr.log").open("w") as stderr:
            try:
                return subprocess.run([str(app), *args], env=env, stdout=stdout, stderr=stderr,
                                      timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                raise SystemExit(f"{name} timed out after {timeout} s; inspect {output / (name + '.stderr.log')}") from None


def replay(app, model, cases, output, name, timeout, extra=None):
    fixture = {"cases": warmup_cases() + cases, **PRODUCTION, **(extra or {})}
    path = output / f"{name}-input.json"
    path.write_text(json.dumps(fixture, ensure_ascii=False) + "\n")
    code = run_app(app, ["--cotyping-replay", str(path.resolve()), "--model-path", str(model)], output, name, timeout)
    rows = [json.loads(line) for line in (output / f"{name}.out").read_text().splitlines()]
    if code or len(rows) != len(fixture["cases"]):
        raise SystemExit(f"{name}: {len(rows)} of {len(fixture['cases'])} cases (exit {code})")
    check_production(rows)
    return [row for row in rows if not row["id"].startswith("warmup-")]


def accuracy(observations, references):
    report = score(observations, references)
    groups = {"english": [r for r in report["scores"] if r["category"] in ENGLISH],
              "otherLanguages": [r for r in report["scores"] if r["category"] not in ENGLISH]}

    def summarize(rows):
        shown = sum(r["shown"] for r in rows)
        correct = sum(r["correct"] for r in rows)
        return {"checkpoints": len(rows), "correct": correct, "shown": shown,
                "accuracy": round(correct / len(rows), 4) if rows else None,
                "coverage": round(shown / len(rows), 4) if rows else None,
                "precision": round(correct / shown, 4) if shown else None,
                "errors": sum(bool(r["error"]) for r in rows)}

    return {"overall": summarize(report["scores"]),
            **{name: summarize(rows) for name, rows in groups.items()},
            "categories": {c: summarize([r for r in report["scores"] if r["category"] == c])
                           for c in sorted({r["category"] for r in report["scores"]})},
            "latency": stats([r["latencyMs"] for r in report["scores"] if not r["error"]]),
            "scores": [{key: r[key] for key in ["id", "category", "correct", "shown", "latencyMs"]}
                       for r in report["scores"]]}


def typing(observations):
    generated = [r for r in observations if r.get("suppression") != "pre-generation-gate" and not r.get("error")]
    return {"keystrokes": len(observations), "generated": len(generated),
            "shown": sum(bool(r["text"].strip()) for r in observations),
            "errors": sum(bool(r.get("error")) for r in observations),
            "latency": stats([r["latencyMs"] for r in generated]),
            "latencies": [round(r["latencyMs"], 1) for r in generated]}


def source_state():
    def git(*args):
        result = subprocess.run(["git", "-C", str(HERE), *args], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    status = git("status", "--porcelain")
    return {"commit": git("rev-parse", "HEAD"), "dirty": bool(status) if status is not None else None}


def hardware():
    def sysctl(key):
        return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True).stdout.strip()
    return {"chip": sysctl("machdep.cpu.brand_string"), "memoryBytes": int(sysctl("hw.memsize") or 0),
            "macOS": platform.mac_ver()[0]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", type=Path, required=True, help="LokalBot executable from a Release build")
    parser.add_argument("--model", type=Path, required=True, help="local GGUF")
    parser.add_argument("--output", type=Path, required=True, help="new result directory")
    parser.add_argument("--passes", type=int, default=5, help="passes over the 28 checks (first one is reported apart)")
    parser.add_argument("--parts", default="checks,accuracy,typing")
    args = parser.parse_args()
    parts = set(args.parts.split(","))
    if not parts <= {"checks", "accuracy", "typing"} or not 2 <= args.passes <= 20:
        parser.error("--parts takes checks, accuracy, typing; --passes must be 2-20")
    app, model = args.app.resolve(strict=True), args.model.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {"modelFile": model.name, "modelSHA256": digest(model), "appSHA256": digest(app),
                "scriptSHA256": digest(__file__), "source": source_state(), "hardware": hardware(),
                "corpora": {path.name: digest(path) for path in CORPORA}, "replaySettings": PRODUCTION,
                "passes": args.passes, "warmupRequests": len(WARMUP), "typingPhrases": TYPING_PHRASES,
                "boundary": "Engine only: excludes input monitoring, debounce, AX reads, screen and memory "
                            "context, learning and the overlay"}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    summary = {"modelFile": model.name}
    phrases = load_phrases()

    if "checks" in parts:
        code = run_app(app, ["--cotyping-bench", "--model-path", str(model), "--passes", str(args.passes)],
                       args.output, "checks", timeout=240)
        try:
            checks = json.loads((args.output / "checks.out").read_text())
        except json.JSONDecodeError:
            raise SystemExit(f"checks: no JSON (exit {code}); inspect {args.output / 'checks.stderr.log'}") from None
        (args.output / "checks.json").write_text(json.dumps(checks, indent=2, ensure_ascii=False) + "\n")
        first = checks["firstPass"]
        summary["checks"] = {
            "exitCode": code, "loadMs": checks["loadMs"], "maxWords": checks["maxWords"],
            "consistentAcrossPasses": checks["consistentAcrossPasses"],
            "outcomes": first["outcomes"], "wordCompletions": [first["wordCompletionPassed"], first["wordCompletionTotal"]],
            "keywordHits": [first["keywordHits"], first["keywordTotal"]],
            "firstPassLatency": checks["firstPassLatency"], "warmLatency": checks["warmLatency"]}
        print(json.dumps({"checks": summary["checks"]}), flush=True)

    if "accuracy" in parts:
        cases, references = checkpoints(phrases, "word")
        observations = replay(app, model, cases, args.output, "accuracy", timeout=600)
        result = accuracy(observations, references)
        (args.output / "accuracy.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        summary["accuracy"] = {key: result[key] for key in ["overall", "english", "otherLanguages", "latency"]}
        print(json.dumps({"accuracy": summary["accuracy"]}), flush=True)

    if "typing" in parts:
        observations = replay(app, model, typing_cases(phrases), args.output, "typing", timeout=600,
                              extra={"useNativeSpellingVerdicts": True})
        result = typing(observations)
        (args.output / "typing.json").write_text(json.dumps(result, indent=2) + "\n")
        summary["typing"] = {key: value for key, value in result.items() if key != "latencies"}
        print(json.dumps({"typing": summary["typing"]}), flush=True)

    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
