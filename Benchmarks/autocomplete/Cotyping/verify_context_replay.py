#!/usr/bin/env python3
"""Regression check: synthetic replay prompts must retain the bounded caret text.

Run on quality-cases.json results. It intentionally fails on the original binary,
which flattened paragraphs and discarded caret whitespace and earlier facts.
"""

import argparse
import json
from pathlib import Path


def failures(directory):
    fixture = json.loads((directory / "input.json").read_text())
    observations = [json.loads(line) for line in (directory / "observations.jsonl").read_text().splitlines()]
    if [item["id"] for item in fixture["cases"]] != [item["id"] for item in observations]:
        raise ValueError("Incomplete replay")
    rejected = []
    for item, result in zip(fixture["cases"], observations):
        # This check owns only scenarios that fit the shipped window. Do not
        # mistake legitimate bounding of longer inputs for a context defect.
        prefix = item["prefix"]
        if len(prefix) > 2500 or len(prefix.split()) > 500:
            raise ValueError("Regression fixture exceeds the product context budget")
        if result.get("error") or not result["prompt"].endswith(prefix):
            rejected.append(item["id"])
    return rejected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    args = parser.parse_args()
    rejected = failures(args.results)
    print(json.dumps({"failedChecks": len(rejected), "caseIDs": rejected}, indent=2))
    raise SystemExit(bool(rejected))


if __name__ == "__main__":
    main()
