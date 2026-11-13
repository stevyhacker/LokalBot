#!/usr/bin/env python3
"""Benchmark LokalBot's cotyping llama-server stream.

This is a backend microbenchmark, not a UI/accessibility test. It posts the
same short cotyping prompts used by the in-app quality check to the dedicated
OpenAI-compatible llama-server and records:

- time to first non-empty streamed text chunk,
- time to the final returned text,
- raw model text.

Use `Scripts/cotyping/compare-cotyping.sh` for screenshot parity against Cotypist. Use
this script when changing prompt, sampling, server, or early-stop behavior and
you need repeatable latency/output evidence from the Gemma Q5 XL backend.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Iterable


DEFAULT_BASE_URL = "http://127.0.0.1:17874/v1"
DEFAULT_MODEL = "gemma-4-E4B-UD-Q5_K_XL.gguf"
COFFEE_SEED = 0x00C0FFEE


@dataclass(frozen=True)
class Scenario:
    id: str
    app_name: str
    bundle_id: str
    window_title: str | None
    placeholder: str | None
    prefix: str


SCENARIOS = [
    Scenario(
        id="email-follow-up",
        app_name="Mail",
        bundle_id="com.apple.mail",
        window_title="Re: Q3 planning",
        placeholder=None,
        prefix="Hi Sarah,\nThanks for sending this over. I wanted to follow",
    ),
    Scenario(
        id="chat-ownership",
        app_name="Slack",
        bundle_id="com.tinyspeck.slackmacgap",
        window_title="project-launch",
        placeholder="Message #project-launch",
        prefix="Sounds good, I can take",
    ),
    Scenario(
        id="browser-prose",
        app_name="Safari",
        bundle_id="com.apple.Safari",
        window_title="Design note",
        placeholder="Leave a comment",
        prefix="The main tradeoff is",
    ),
    Scenario(
        id="mid-word",
        app_name="Notes",
        bundle_id="com.apple.Notes",
        window_title="Project notes",
        placeholder=None,
        prefix="Please rec",
    ),
]


def surface_lines(scenario: Scenario) -> list[str]:
    bundle = scenario.bundle_id.lower()
    if bundle.startswith("com.apple.mail"):
        lines = [f"An email being written in {scenario.app_name}."]
    elif bundle.startswith("com.tinyspeck.slackmacgap"):
        lines = [f"A chat message being typed in {scenario.app_name}."]
    else:
        lines = [f"Text being typed in {scenario.app_name}."]
    if scenario.window_title:
        lines.append(f'The window is titled "{scenario.window_title}".')
    if scenario.placeholder:
        lines.append(f'The text field is labeled "{scenario.placeholder}".')
    return lines


def prompt_for(scenario: Scenario, include_surface_context: bool) -> str:
    prefix = scenario.prefix.rstrip()
    if not include_surface_context:
        return prefix
    preface = "\n".join(surface_lines(scenario))
    return f"{preface}\n\n{prefix}"


def request_json(
    scenario: Scenario,
    args: argparse.Namespace,
) -> dict:
    return {
        "model": args.model,
        "prompt": prompt_for(scenario, args.surface_context),
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "top_p": args.top_p,
        "top_k": args.top_k,
        "min_p": args.min_p,
        "repeat_penalty": args.repeat_penalty,
        "seed": args.seed,
        "stream": True,
        "stop": [] if args.multiline else ["\n"],
    }


def stream_completion(
    base_url: str,
    body: dict,
    timeout: float,
    early_stop: bool,
) -> dict:
    url = base_url.rstrip("/") + "/completions"
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    first_text_at: float | None = None
    accumulated = ""
    chunks = 0
    stop_reason: str | None = None

    with urllib.request.urlopen(request, timeout=timeout) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[len("data:") :].strip()
            if not payload or payload == "[DONE]":
                break
            chunk = json.loads(payload)
            text = chunk.get("choices", [{}])[0].get("text", "")
            if not text:
                continue
            if first_text_at is None:
                first_text_at = time.perf_counter()
            accumulated += text
            chunks += 1
            if early_stop:
                stop_reason = early_stop_reason(accumulated, chunks)
                if stop_reason:
                    break

    finished = time.perf_counter()
    return {
        "first_ms": None
        if first_text_at is None
        else round((first_text_at - started) * 1000),
        "final_ms": round((finished - started) * 1000),
        "chunks": chunks,
        "stop_reason": stop_reason,
        "raw": accumulated,
    }


def early_stop_reason(text: str, chunks: int) -> str | None:
    if any(marker in text for marker in ("<|im_end|>", "<|endoftext|>", "<|end|>", "<end_of_turn>", "<|eot_id|>")):
        return "scaffolding_marker"
    if chunks < 2:
        return None
    stripped = text.rstrip()
    if stripped.endswith(("!", "?")):
        return "sentence_boundary"
    if stripped.endswith(".") and is_terminal_period(stripped):
        return "sentence_boundary"
    return None


def is_terminal_period(text: str) -> bool:
    if not text.endswith("."):
        return False
    stem = text[:-1]
    if not stem:
        return True
    previous = stem[-1]
    if previous.isdigit():
        return False
    letters = []
    for char in reversed(stem):
        if not char.isalpha():
            break
        letters.append(char)
    trailing = "".join(reversed(letters)).lower()
    if len(trailing) == 1:
        return False
    abbreviations = {
        "mr",
        "mrs",
        "ms",
        "dr",
        "st",
        "vs",
        "eg",
        "ie",
        "etc",
        "no",
        "fig",
        "approx",
        "inc",
        "ltd",
    }
    return trailing not in abbreviations


def summarize(results: Iterable[dict]) -> dict:
    rows = list(results)
    first = [row["first_ms"] for row in rows if row["first_ms"] is not None]
    final = [row["final_ms"] for row in rows]
    return {
        "count": len(rows),
        "avg_first_ms": round(statistics.fmean(first)) if first else None,
        "avg_final_ms": round(statistics.fmean(final)) if final else None,
        "max_first_ms": max(first) if first else None,
        "max_final_ms": max(final) if final else None,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--max-tokens", type=int, default=26)
    parser.add_argument("--temperature", type=float, default=0.1)
    parser.add_argument("--top-p", type=float, default=0.7)
    parser.add_argument("--top-k", type=int, default=20)
    parser.add_argument("--min-p", type=float, default=0.08)
    parser.add_argument("--repeat-penalty", type=float, default=1.05)
    parser.add_argument("--seed", type=int, default=COFFEE_SEED)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--surface-context", action="store_true")
    parser.add_argument("--multiline", action="store_true")
    parser.add_argument(
        "--no-early-stop",
        action="store_true",
        help="Let llama-server stream until max_tokens/stop instead of applying LokalBot's client boundary stop.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    all_rows: list[dict] = []
    try:
        for repetition in range(1, args.repetitions + 1):
            for scenario in SCENARIOS:
                body = request_json(scenario, args)
                result = stream_completion(
                    args.base_url,
                    body,
                    timeout=args.timeout,
                    early_stop=not args.no_early_stop,
                )
                row = {
                    "repetition": repetition,
                    "scenario": scenario.id,
                    **result,
                }
                all_rows.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
    except urllib.error.URLError as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        return 1

    print(json.dumps({"summary": summarize(all_rows)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
