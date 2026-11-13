#!/usr/bin/env python3
"""Descriptive audit of saved candidates. Never tunes a ranker on references.

Exact-word agreement is a reference proxy, not correctness or user acceptance.
No generation, prompt edits or inference-time oracle access occur here.
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics

from quality_replay import predicted_words


def matches(text, reference):
    return bool(reference["words"]) and predicted_words(text, reference["typed"])[:1] == reference["words"][:1]


def audit(rows, references):
    if [r["id"] for r in rows] != list(references):
        raise ValueError("Incomplete or reordered replay")
    totals = dict(checkpoints=len(rows), shown=0, selectedMatches=0, oracleMatches=0,
                  missedOracleSelections=0, duplicateNonemptyFinalists=0, dedupTopOneChanges=0,
                  randomFinalistExpectedMatches=0.0, referenceAvailableButControlSuppressed=0)
    margins, lengths, confidence, missed = defaultdict(list), defaultdict(list), defaultdict(list), []
    for row in rows:
        if row.get("error"):
            raise ValueError("Cannot audit a failed request")
        ref, search = references[row["id"]], row.get("search") or {}
        texts = search.get("candidateTexts", [row["text"]])
        ranking = search.get("ranking", "mean")
        score_fields = {"mean": "candidateScores", "sum": "candidateLogProbabilities",
                        "firstWord": "candidateFirstWordProbabilities"}
        if ranking not in score_fields:
            raise ValueError("Unknown candidate ranking")
        scores = search.get(score_fields[ranking], [])
        if ranking != "mean" and len(scores) != len(texts):
            raise ValueError("Missing scores for the selected ranking")
        nonempty = [(i, t) for i, t in enumerate(texts) if t]
        hit = matches(row["text"], ref)
        any_hit = any(matches(t, ref) for _, t in nonempty)
        totals["shown"] += bool(row["text"])
        totals["selectedMatches"] += hit
        totals["oracleMatches"] += any_hit
        totals["missedOracleSelections"] += any_hit and not hit
        totals["referenceAvailableButControlSuppressed"] += any_hit and not row["text"]
        unique = list(dict.fromkeys(t for _, t in nonempty))
        totals["duplicateNonemptyFinalists"] += len(unique) < len(nonempty)
        totals["dedupTopOneChanges"] += bool(nonempty) and unique[0] != nonempty[0][1]
        if nonempty:
            totals["randomFinalistExpectedMatches"] += sum(matches(t, ref) for _, t in nonempty) / len(nonempty)
            lengths[str(len(predicted_words(row["text"], ref["typed"])))].append(hit)
        if len(nonempty) > 1 and scores:
            gap = scores[nonempty[0][0]] - scores[nonempty[1][0]]
            bucket = "0-0.05" if gap < .05 else "0.05-0.2" if gap < .2 else "0.2+"
            margins[bucket].append(hit)
        cache = row.get("cache") or {}
        probability = cache.get("firstWordProbability")
        if probability is not None:
            bucket = "below-0.1" if probability < .1 else "0.1-0.25" if probability < .25 else "0.25-0.5" if probability < .5 else "0.5+"
            confidence[bucket].append(hit)
        if any_hit and not hit:
            missed.append({"id": row["id"], "selected": row["text"], "candidates": texts,
                           "scores": scores, "referenceFirstWord": ref["words"][0],
                           "tokenCounts": search.get("candidateTokenCounts"),
                           "healingTokenCounts": search.get("candidateHealingTokenCounts")})

    def bins(values):
        return {key: {"count": len(hits), "referenceAgreement": statistics.mean(hits)} for key, hits in sorted(values.items())}

    return {"totals": totals, "scoreMarginBins": bins(margins), "visibleWordCountBins": bins(lengths),
            "candidateRankings": sorted({r["search"].get("ranking", "mean") for r in rows if r.get("search")}),
            "confidenceBoundaryModes": sorted({r.get("confidenceBoundaryMode", "selectedToken") for r in rows if r.get("cache")}),
            "firstWordProbabilityBins": bins(confidence), "missedSelections": missed,
            "interpretation": "Descriptive only. Oracle is unattainable without future reference access. Random expectation samples nonempty finalists uniformly, including duplicates. Bins are fixed, not tuned. First-word gate is disabled midword. Suppressed candidates were pruned, so their alternatives cannot be reconstructed.",
            "missingDiagnostics": [] if all("candidateTokenCounts" in (r.get("search") or {}) for r in rows if r.get("search"))
            else ["candidate token counts", "healing token counts", "raw first-word probabilities"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--observations", type=Path, required=True)
    parser.add_argument("--references", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.observations.read_text().splitlines()]
    result = audit(rows, json.loads(args.references.read_text()))
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["totals"]))


if __name__ == "__main__":
    main()
