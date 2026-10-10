#!/usr/bin/env python3
"""Score production cotyping on an external synthetic phrase corpus, without UI.

Uses Cotabby's public v2 corpus format and exact next-word definition. The corpus
is supplied explicitly; only already-typed prefixes and surface metadata enter
the app. Screen text, categories and expected answers never enter inference.
With --completions-url the same production prompts go to a hosted raw-completions
endpoint instead of a local model; the key is read from the named environment variable.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata


WORD = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*", re.UNICODE)


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def fold(word):
    return unicodedata.normalize("NFC", word).lower().replace("’", "'")


def predicted_words(shown, typed=""):
    if not shown or not shown.strip() or (typed and shown[0].isspace()):
        return []
    joined = typed + shown
    matches = list(WORD.finditer(joined))
    if not matches or joined[:matches[0].start()].strip():
        return []
    result = []
    for match in matches:
        if match.end() < len(joined) and joined[match.end()] in "'’-":
            break
        result.append(fold(match.group()))
    return result


def selected_phrases(corpus, split, per_category=None):
    categories = sorted({phrase["category"] for phrase in corpus["phrases"]})
    selected = set()
    for category in categories:
        ranked = sorted((p for p in corpus["phrases"] if p["category"] == category),
                        key=lambda p: hashlib.sha256(f"1337:{p['id']}".encode()).hexdigest())
        partition = ranked[:20] if split == "screen" else ranked[20:] if split == "heldout" else ranked
        selected.update(p["id"] for p in partition[:per_category])
    return [p for p in corpus["phrases"] if p["id"] in selected]


def checkpoints(phrases, mode):
    inputs, references = [], {}
    for phrase in phrases:
        words = list(WORD.finditer(phrase["text"]))
        scene = phrase.get("scenario", {})
        for index, word in list(enumerate(words))[1:]:
            offsets = [0] if mode == "word" else range(1, len(word.group()))
            for offset in offsets:
                ident = f"{phrase['id']}:{index}:{offset}"
                prefix = scene.get("documentPrefix", "") + phrase["text"][:word.start() + offset]
                inputs.append({
                    "id": ident, "prefix": prefix, "appName": scene.get("applicationName", "Notes"),
                    "bundleID": scene.get("bundleIdentifier", "com.apple.Notes"),
                    "windowTitle": scene.get("windowTitle"), "placeholder": scene.get("fieldPlaceholder"),
                    # No oracle validity hint: production's permissive default is the control.
                    "wordPrefixIsValidWord": True,
                })
                references[ident] = {
                    "phraseID": phrase["id"], "category": phrase["category"],
                    "typed": word.group()[:offset],
                    "words": [fold(w.group()) for w in words[index:]],
                }
    return inputs, references


def score(observations, references):
    if [o["id"] for o in observations] != list(references):
        raise ValueError("Incomplete, duplicated or reordered replay")
    rows = []
    for observation in observations:
        reference = references[observation["id"]]
        prediction = predicted_words(observation["text"], reference["typed"])
        consecutive = 0
        if not observation.get("error"):
            for actual, expected in zip(prediction, reference["words"]):
                if actual != expected:
                    break
                consecutive += 1
        rows.append({"id": observation["id"], **reference, "correct": consecutive > 0,
                     "matchingWords": consecutive, "shown": bool(observation["text"]),
                     "error": observation.get("error"), "latencyMs": observation["latencyMs"],
                     "attempts": observation.get("attempts", 1)})

    def aggregate(items):
        latency = sorted(row["latencyMs"] for row in items if not row["error"])
        result = {"checkpoints": len(items), "correct": sum(row["correct"] for row in items),
                  "shown": sum(row["shown"] for row in items), "errors": sum(bool(row["error"]) for row in items),
                  "retries": sum(row["attempts"] - 1 for row in items)}
        result["accuracy"] = result["correct"] / len(items) if items else 0
        result["coverage"] = result["shown"] / len(items) if items else 0
        for length in [2, 3]:
            eligible = [row for row in items if len(row["words"]) >= length]
            result[f"{length}WordAccuracy"] = (sum(row["matchingWords"] >= length for row in eligible)
                                               / len(eligible)) if eligible else None
        for percentile in [50, 90, 95]:
            result[f"p{percentile}Ms"] = latency[math.ceil(len(latency) * percentile / 100) - 1] if latency else None
        return result

    return {"overall": aggregate(rows),
            "categories": {category: aggregate([row for row in rows if row["category"] == category])
                           for category in sorted({row["category"] for row in rows})}, "scores": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    engine = parser.add_mutually_exclusive_group(required=True)
    engine.add_argument("--model", type=Path, help="local GGUF served by the in-process runtime")
    engine.add_argument("--completions-url", help="hosted OpenAI-compatible base URL, e.g. https://api.cerebras.ai/v1")
    parser.add_argument("--completions-model", help="provider model ID for --completions-url")
    parser.add_argument("--completions-extra-body", help="JSON object merged into every hosted request")
    parser.add_argument("--api-key-env", help="environment variable holding the hosted API key")
    parser.add_argument("--completions-chat", action="store_true",
                        help="ask through /chat/completions (prompt as the user message) instead of raw completions")
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--split", choices=["screen", "heldout", "all"], default="screen")
    parser.add_argument("--per-category", type=int)
    parser.add_argument("--mode", choices=["word", "midword"], default="word")
    parser.add_argument("--prompt", choices=["production", "bare", "preserve", "topic", "instruct", "prefill"], default="production")
    parser.add_argument("--max-tokens", type=int)
    parser.add_argument("--max-prefix-characters", type=int)
    parser.add_argument("--max-prefix-words", type=int)
    parser.add_argument("--temperature", type=float)
    parser.add_argument("--repeat-penalty", type=float)
    parser.add_argument("--no-app-context", action="store_true")
    parser.add_argument("--timeout", type=int, default=7200, help="seconds before the app replay is stopped")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if args.completions_url:
        if not args.completions_model or not args.api_key_env:
            parser.error("--completions-url needs --completions-model and --api-key-env")
        if not os.environ.get(args.api_key_env):
            parser.error(f"{args.api_key_env} is not set")
        extra_body = json.loads(args.completions_extra_body or "{}")
        if not isinstance(extra_body, dict):
            parser.error("--completions-extra-body must be a JSON object")
        engine_args = ["--completions-url", args.completions_url, "--completions-model", args.completions_model]
        if args.completions_chat:
            engine_args.append("--completions-chat")
        if extra_body:
            engine_args += ["--completions-extra-body", json.dumps(extra_body, sort_keys=True)]
        engine_manifest = {"kind": "remote", "baseURL": args.completions_url, "model": args.completions_model,
                           "extraBody": extra_body, "endpoint": "chat" if args.completions_chat else "completions"}
    else:
        model = args.model.resolve(strict=True)
        engine_args = ["--model-path", str(model)]
        engine_manifest = {"kind": "local", "modelFile": model.name, "modelSHA256": digest(model)}
    corpus = json.loads(args.corpus.read_text())
    phrases = selected_phrases(corpus, args.split, args.per_category)
    cases, references = checkpoints(phrases, args.mode)
    fixture = {"cases": cases, "appContext": not args.no_app_context}
    for key, value in [("maxTokens", args.max_tokens), ("maxPrefixCharacters", args.max_prefix_characters),
                       ("maxPrefixWords", args.max_prefix_words), ("temperature", args.temperature),
                       ("repeatPenalty", args.repeat_penalty)]:
        if value is not None:
            fixture[key] = value
    if args.prompt != "production":
        for case in cases:
            prefix = case["prefix"]
            if args.prompt == "bare":
                case["promptOverride"] = prefix.rstrip()
            elif args.prompt == "preserve":
                case["promptOverride"] = prefix
            elif args.prompt == "topic":
                title = (case.get("windowTitle") or "").replace('"', '')[:80]
                label = "Subject" if case["bundleID"] == "com.apple.mail" else "Topic"
                case["promptOverride"] = (f"{label}: {title}\n\n" if title else "") + prefix
            elif args.prompt == "prefill":
                case["promptOverride"] = (
                    "<|im_start|>system\nYou are a writing assistant. Continue the text naturally, "
                    "matching its language and style.<|im_end|>\n"
                    "<|im_start|>user\nContinue this passage.<|im_end|>\n"
                    f"<|im_start|>assistant\n{prefix}")
            else:
                case["promptOverride"] = (
                    "<|im_start|>system\nContinue the user's unfinished text. Output only the next few words, "
                    "without repeating their text or explaining. Match their language and style.<|im_end|>\n"
                    f"<|im_start|>user\n{prefix}<|im_end|>\n<|im_start|>assistant\n")
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {**({key: engine_manifest[key] for key in ["modelFile", "modelSHA256"]}
                   if engine_manifest["kind"] == "local" else {}),
                "engine": engine_manifest, "appSHA256": digest(app),
                "corpusSHA256": digest(args.corpus), "scriptSHA256": digest(__file__),
                "split": args.split, "splitSeed": 1337, "screenPerCategory": 20,
                "phraseIDs": [p["id"] for p in phrases], "mode": args.mode,
                "promptMode": args.prompt, "settings": {k: v for k, v in fixture.items() if k != "cases"},
                "context": "none (app/title/field metadata only)", "checkpoints": len(cases)}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.output / "input.json").write_text(json.dumps(fixture, ensure_ascii=False) + "\n")
    with tempfile.TemporaryDirectory(prefix="lokalbot-quality-") as temp:
        root = Path(temp)
        (root / "home").mkdir()
        env = dict(os.environ, LOKALBOT_STORAGE_ROOT=str(root / "storage"), CFFIXED_USER_HOME=str(root / "home"))
        env.pop("LOKALBOT_REPLAY_API_KEY", None)
        if args.completions_url:
            env["LOKALBOT_REPLAY_API_KEY"] = os.environ[args.api_key_env]
        with (args.output / "observations.jsonl").open("w") as stdout, (args.output / "stderr.log").open("w") as stderr:
            completed = subprocess.run([str(app), "--cotyping-replay", str((args.output / "input.json").resolve()),
                                        *engine_args], env=env, stdout=stdout, stderr=stderr, timeout=args.timeout)
    observations = [json.loads(line) for line in (args.output / "observations.jsonl").read_text().splitlines()]
    if completed.returncode and len(observations) < len(cases):
        # A negative code is the signal that ended the app.
        raise SystemExit(f"replay stopped after {len(observations)} of {len(cases)} cases "
                         f"(app exit code {completed.returncode})")
    report = score(observations, references)
    report["manifest"] = manifest
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["overall"], indent=2), flush=True)
    if completed.returncode or report["overall"]["errors"]:
        raise SystemExit(completed.returncode or 1)


if __name__ == "__main__":
    main()
