#!/usr/bin/env python3
"""Compare hosted autocomplete models with the local one on identical replays.

Runs quality_replay.py once per engine over the same checkpoints: the local model
first, then the hosted candidates in remote-candidates.json, side by side. Hosted
runs send the corpus's synthetic prompts to each provider; nothing from the
user's library is read. Keys come from a private env file, and each one reaches
only its own provider's replay.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

from compare_quality import compare


HERE = Path(__file__).resolve().parent
CHALLENGE = HERE / "quality-cases.json"
OPENROUTER_URL = "https://openrouter.ai/api/v1"
OPENROUTER_KEY = "OPENROUTER_API_KEY"
METRICS = ["checkpoints", "accuracy", "2WordAccuracy", "3WordAccuracy", "coverage",
           "errors", "retries", "p50Ms", "p90Ms", "p95Ms"]


def read_env_file(path):
    if path.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        print(f"warning: {path} is readable by other users; chmod 600 it", file=sys.stderr)
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("\"'")
        if value:
            values[key.strip()] = value
    return values


def candidate_env(base, keys, candidate=None):
    """The replay environment: no provider key at all, or only this candidate's."""
    names = {name for name in keys} | {"LOKALBOT_REPLAY_API_KEY"}
    env = {key: value for key, value in base.items() if key not in names}
    if candidate:
        env[candidate["apiKeyEnv"]] = keys[candidate["apiKeyEnv"]]
    return env


def suites(args):
    corpus = ["--corpus", str(args.corpus.resolve(strict=True)), "--split", args.split]
    sample = ["--per-category", str(args.per_category)] if args.per_category else []
    yield "corpus", [*corpus, *sample]
    if not args.skip_challenge:
        yield "challenge", ["--corpus", str(CHALLENGE), "--split", "all"]
    if args.midword_per_category:
        # Every internal character of later words: the caret partway through a word.
        yield "midword", [*corpus, "--per-category", str(args.midword_per_category), "--mode", "midword"]


def replay(args, suite_args, output, engine_args, env):
    if getattr(args, "resume", False):
        if (output / "report.json").exists():
            return load_finished(output)
        if output.exists():
            # An unfinished attempt is kept beside the new one, never scored.
            output.rename(output.with_name(f"{output.name}.stopped"))
    command = [sys.executable, "-S", str(HERE / "quality_replay.py"), "--app", str(args.app.resolve(strict=True)),
               "--output", str(output), "--timeout", str(args.timeout), *suite_args, *engine_args]
    with (output.parent / f"{output.name}.log").open("w") as log:
        completed = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
    report = output / "report.json"
    return {"returncode": completed.returncode,
            "report": json.loads(report.read_text()) if report.exists() else None,
            "promptCharacters": sum(len(json.loads(line)["prompt"])
                                    for line in (output / "observations.jsonl").read_text().splitlines())
            if (output / "observations.jsonl").exists() else 0}


def via_openrouter(candidate):
    """The same model behind one OpenRouter key, pinned to `openRouterProvider`.
    Fallbacks are off, so a request never lands on another provider, and providers
    that keep or train on prompts are excluded. None when there is no usable route."""
    if not candidate.get("openRouterProvider"):
        return None
    routing = {"order": [candidate["openRouterProvider"]], "allow_fallbacks": False, "data_collection": "deny"}
    return {**candidate, "label": candidate.get("openRouterLabel") or f"{candidate['label']} (via OpenRouter)",
            "chat": candidate.get("openRouterChat", candidate.get("chat", False)),
            "baseURL": OPENROUTER_URL, "model": candidate["openRouterModel"], "apiKeyEnv": OPENROUTER_KEY,
            "extraBody": {**candidate.get("openRouterExtraBody", candidate.get("extraBody", {})), "provider": routing}}


def load_finished(output):
    observations = output / "observations.jsonl"
    return {"returncode": 0, "report": json.loads((output / "report.json").read_text()),
            "promptCharacters": sum(len(json.loads(line)["prompt"]) for line in observations.read_text().splitlines())}


def remote_engine_args(candidate):
    engine = ["--completions-url", candidate["baseURL"], "--completions-model", candidate["model"],
              "--api-key-env", candidate["apiKeyEnv"]]
    if candidate.get("extraBody"):
        engine += ["--completions-extra-body", json.dumps(candidate["extraBody"], sort_keys=True)]
    if candidate.get("chat"):
        engine.append("--completions-chat")
    return engine


def summarize(config, runs, skipped):
    local_id = config["local"]["id"]
    labels = {config["local"]["id"]: config["local"]["label"], **{c["id"]: c["label"] for c in config["remote"]}}
    prices = {c["id"]: c.get("openRouter", {}) for c in config["remote"]}
    summary = {"skipped": skipped, "suites": {}}
    for (suite, engine_id), result in runs.items():
        entry = {"label": labels[engine_id], "returncode": result["returncode"]}
        report = result["report"]
        if report:
            entry.update({key: report["overall"].get(key) for key in METRICS})
            price = prices.get(engine_id, {}).get("usdPerMillionInput")
            if price and report["overall"]["checkpoints"]:
                # About four characters per token; output tokens are a rounding error here.
                entry["approxUSDPer1000Suggestions"] = (
                    result["promptCharacters"] / 4 / report["overall"]["checkpoints"] * 1000 * price / 1e6)
            baseline = runs.get((suite, local_id), {}).get("report")
            if baseline and engine_id != local_id:
                delta = compare(baseline, report)
                entry["deltaVsLocalPoints"] = delta["deltaPercentagePoints"]
                entry["deltaVsLocal95PercentCI"] = delta["phraseBootstrap95PercentCI"]
        summary["suites"].setdefault(suite, {})[engine_id] = entry
    return summary


def percent(value):
    return "–" if value is None else f"{100 * value:.2f}%"


def milliseconds(value):
    return "–" if value is None else f"{value:.0f} ms"


def markdown(summary):
    lines = ["# Remote autocomplete comparison", "",
             "Local latency is warm in-process generation. Remote latency is the full HTTPS",
             "request from this Mac, timing only the attempt that answered.", ""]
    for suite, engines in summary["suites"].items():
        lines += [f"## {suite}", "",
                  "| Engine | Next word | Δ vs local (95% CI) | 2 words | 3 words | Shown | Errors | Retries "
                  "| p50 | p90 | p95 | ≈ $ / 1k |",
                  "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for entry in engines.values():
            if "accuracy" not in entry:
                lines.append(f"| {entry['label']} | failed (exit {entry['returncode']}) |" + " |" * 10)
                continue
            delta = "–"
            if "deltaVsLocalPoints" in entry:
                low, high = entry["deltaVsLocal95PercentCI"]
                delta = f"{entry['deltaVsLocalPoints']:+.2f} ({low:+.2f} to {high:+.2f})"
            cost = entry.get("approxUSDPer1000Suggestions")
            lines.append(
                f"| {entry['label']} | {percent(entry['accuracy'])} | {delta} | {percent(entry['2WordAccuracy'])} "
                f"| {percent(entry['3WordAccuracy'])} | {percent(entry['coverage'])} | {entry['errors']} "
                f"| {entry['retries']} | {milliseconds(entry['p50Ms'])} | {milliseconds(entry['p90Ms'])} "
                f"| {milliseconds(entry['p95Ms'])} | {'–' if cost is None else f'{cost:.2f}'} |")
        lines.append("")
    for engine_id, reason in summary["skipped"].items():
        lines.append(f"Skipped {engine_id}: {reason.rstrip('.')}.")
    return "\n".join(lines).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Release LokalBot executable")
    parser.add_argument("--local-model", type=Path, required=True, help="the local GGUF to compare against")
    parser.add_argument("--corpus", type=Path, required=True, help="Cotabby phrase-prediction-1337.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--env-file", type=Path, help="private KEY=VALUE file with provider keys")
    parser.add_argument("--candidates", type=Path, default=HERE / "remote-candidates.json")
    parser.add_argument("--only", help="comma-separated candidate IDs")
    parser.add_argument("--via-openrouter", action="store_true",
                        help=f"route every candidate through OpenRouter with {OPENROUTER_KEY}, pinned to its provider")
    parser.add_argument("--split", choices=["screen", "heldout", "all"], default="heldout")
    parser.add_argument("--per-category", type=int, default=30, help="phrases per category; 0 for the whole split")
    parser.add_argument("--skip-challenge", action="store_true", help="skip the 32-scenario quality-cases.json")
    parser.add_argument("--midword-per-category", type=int, default=0,
                        help="also score mid-word completion on this many phrases per category")
    parser.add_argument("--timeout", type=int, default=1800, help="seconds per replay")
    parser.add_argument("--resume", action="store_true",
                        help="reuse finished replays already in --output, e.g. the local baseline")
    args = parser.parse_args()

    config = json.loads(args.candidates.read_text())
    wanted = set(args.only.split(",")) if args.only else None
    config["remote"] = [c for c in config["remote"] if wanted is None or c["id"] in wanted]
    skipped = {}
    if args.via_openrouter:
        skipped = {c["id"]: c.get("openRouterNote", "no OpenRouter route")
                   for c in config["remote"] if not via_openrouter(c)}
        config["remote"] = [via_openrouter(c) for c in config["remote"] if via_openrouter(c)]
    candidates = config["remote"]
    file_keys = read_env_file(args.env_file) if args.env_file else {}
    keys = {c["apiKeyEnv"]: file_keys.get(c["apiKeyEnv"]) or os.environ.get(c["apiKeyEnv"])
            for c in config["remote"]}
    skipped |= {c["id"]: f"{c['apiKeyEnv']} is not set" for c in candidates if not keys[c["apiKeyEnv"]]}
    ready = [c for c in candidates if c["id"] not in skipped]
    args.output.mkdir(parents=True, exist_ok=args.resume)

    runs = {}
    for suite, suite_args in suites(args):
        (args.output / suite).mkdir(exist_ok=args.resume)
        local_id = config["local"]["id"]
        print(f"[{suite}] {local_id} …", flush=True)
        runs[(suite, local_id)] = replay(args, suite_args, args.output / suite / local_id,
                                         ["--model", str(args.local_model.resolve(strict=True))],
                                         candidate_env(os.environ, keys))
        # Hosted runs share no local resources, so the providers go side by side.
        with ThreadPoolExecutor(max_workers=max(len(ready), 1)) as pool:
            jobs = {pool.submit(replay, args, suite_args, args.output / suite / c["id"], remote_engine_args(c),
                                candidate_env(os.environ, keys, c)): c["id"] for c in ready}
            for future in as_completed(jobs):
                runs[(suite, jobs[future])] = future.result()
                print(f"[{suite}] {jobs[future]} done", flush=True)

    summary = summarize(config, runs, skipped)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    report = markdown(summary)
    (args.output / "REPORT.md").write_text(report)
    print(report)


if __name__ == "__main__":
    main()
