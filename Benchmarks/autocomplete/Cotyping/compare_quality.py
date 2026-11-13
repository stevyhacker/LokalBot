#!/usr/bin/env python3
"""Paired quality deltas with category-stratified, whole-phrase bootstrap CIs."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import random


def compare(before, after, repetitions=3000):
    for key in ["corpusSHA256", "phraseIDs", "mode", "split", "splitSeed", "context"]:
        if before["manifest"][key] != after["manifest"][key]:
            raise ValueError(f"Unpaired benchmark: {key} differs")
    if [row["id"] for row in before["scores"]] != [row["id"] for row in after["scores"]]:
        raise ValueError("Unpaired checkpoints")
    phrases = defaultdict(lambda: [0, 0])
    gained = lost = 0
    for old, new in zip(before["scores"], after["scores"]):
        difference = int(new["correct"]) - int(old["correct"])
        group = phrases[(old["category"], old["phraseID"])]
        group[0] += difference
        group[1] += 1
        gained += difference > 0
        lost += difference < 0
    strata = defaultdict(list)
    for (category, _), values in phrases.items():
        strata[category].append(values)
    generator = random.Random(20261002)
    deltas = []
    for _ in range(repetitions):
        difference = total = 0
        for values in strata.values():
            for _ in values:
                change, count = generator.choice(values)
                difference += change
                total += count
        deltas.append(100 * difference / total)
    deltas.sort()
    return {
        "before": before["overall"], "after": after["overall"],
        "deltaPercentagePoints": 100 * (after["overall"]["accuracy"] - before["overall"]["accuracy"]),
        "pairedGains": gained, "pairedLosses": lost,
        "phraseBootstrap95PercentCI": [deltas[int(repetitions * .025)], deltas[int(repetitions * .975)]],
        "bootstrap": {"unit": "whole phrase, paired, stratified by category", "repetitions": repetitions, "seed": 20261002},
        "categories": {category: {"before": before["categories"][category], "after": after["categories"][category]}
                       for category in before["categories"]},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(json.loads(args.before.read_text()), json.loads(args.after.read_text()))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "categories"}, indent=2))


if __name__ == "__main__":
    main()
