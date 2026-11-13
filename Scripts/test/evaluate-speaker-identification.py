#!/usr/bin/env python3
"""Evaluate held-out speaker/meeting decisions. No audio, vectors or names leave this process.

Input is a JSON object with `assignments`, optional `measurements`, and explicit
`holdout_reviewed` / `independence_reviewed` booleans. See the validation document.
Synthetic fixtures exercise rules; they cannot establish recognition accuracy.
"""

import argparse
import json
import math
from pathlib import Path


def lower_precision_bound(correct, total, alpha=0.05):
    """One-sided exact binomial (Clopper-Pearson) lower confidence bound."""
    if not 0 <= correct <= total or total < 0:
        raise ValueError("Invalid success/assignment counts")
    if correct == 0:
        return 0.0
    if correct == total:
        return alpha ** (1 / total)

    def upper_tail(p):
        terms = [
            math.lgamma(total + 1) - math.lgamma(k + 1) - math.lgamma(total - k + 1)
            + k * math.log(p) + (total - k) * math.log1p(-p)
            for k in range(correct, total + 1)
        ]
        peak = max(terms)
        return math.exp(peak) * sum(math.exp(term - peak) for term in terms)

    low, high = 0.0, 1.0
    for _ in range(64):
        middle = (low + high) / 2
        if upper_tail(middle) < alpha:
            low = middle
        else:
            high = middle
    return (low + high) / 2


def fraction(numerator, denominator):
    return {"count": numerator, "denominator": denominator,
            "fraction": numerator / denominator if denominator else None}


def percentile95(values):
    if not values:
        return None
    ordered = sorted(values)
    if any(not math.isfinite(value) or value < 0 for value in ordered):
        raise ValueError("Measurements must be finite and nonnegative")
    return ordered[math.ceil(len(ordered) * 0.95) - 1]


def evaluate(document):
    rows = document.get("assignments", [])
    seen = set()
    for row in rows:
        key = (row["meeting_id"], row["speaker_id"])
        if key in seen:
            raise ValueError("Repeated speaker/meeting assignment; frames and retries are not independent trials")
        seen.add(key)
        if row["path"] not in {"visual", "profile", "combined", "none"}:
            raise ValueError("Unrecognized evidence path")
        if len(row.get("suggestions", [])) > 3:
            raise ValueError("At most three identity suggestions per speaker")
        if row["meeting_id"] in row.get("enrollment_meeting_ids", []):
            raise ValueError("Enrollment and query meetings overlap")
        if row.get("audio_sha256") and row["audio_sha256"] in row.get("enrollment_audio_sha256", []):
            raise ValueError("An enrollment clip was reused as a recognition query")
    tuning = set(document.get("tuning_people", []))
    evaluation_people = {row.get("person_id") for row in rows if row.get("person_id")}
    if tuning & evaluation_people:
        raise ValueError("Threshold-tuning people overlap held-out evaluation people")

    reviewed = document.get("holdout_reviewed") is True and document.get("independence_reviewed") is True
    paths = {}
    for path in ["visual", "profile", "combined"]:
        automatic = [row for row in rows if row["path"] == path and row.get("assigned_identity") is not None]
        correct = sum(row.get("expected_identity") is not None and row["assigned_identity"] == row["expected_identity"] for row in automatic)
        bound = lower_precision_bound(correct, len(automatic)) if automatic else None
        paths[path] = {
            "precision": fraction(correct, len(automatic)), "errors": len(automatic) - correct,
            "one_sided_95_lower_bound": bound,
            "distinct_meetings": len({row["meeting_id"] for row in automatic}),
            "distinct_people": len({row.get("person_id") for row in automatic if row.get("person_id")}),
            "gate_met": bool(reviewed and bound is not None and bound >= 0.99),
        }

    uncertain = [row for row in rows if row.get("eligible") and row.get("expected_identity") is not None
                 and row.get("assigned_identity") is None]
    suggested = [row for row in uncertain if row.get("suggestions")]
    recall = fraction(sum(row["expected_identity"] in row.get("suggestions", []) for row in uncertain), len(uncertain))
    top_one = fraction(sum(row["suggestions"][0] == row["expected_identity"] for row in suggested), len(suggested))

    def useful(row):
        expected = row.get("expected_identity")
        return expected is not None and (row.get("assigned_identity") == expected or expected in row.get("suggestions", []))

    eligible = [row for row in rows if row.get("eligible") and row.get("clear_visible_turns", 0) >= 3]
    coverage = fraction(sum(useful(row) for row in eligible), len(eligible))
    unknown = [row for row in rows if row.get("enrolled") is False and row["path"] in {"profile", "combined"}]
    known = [row for row in rows if row.get("enrolled") is True and row["path"] in {"profile", "combined"}]
    one_profile_unknown = [row for row in unknown if row.get("saved_profile_count") == 1]
    measurements = document.get("measurements", {})
    timing = percentile95(measurements.get("clock_mapping_error_ms", []))
    indicators = percentile95(measurements.get("indicator_lag_ms", []))
    performance_limits = {"incremental_cpu_percent_one_core": 5, "extra_peak_memory_mib": 64, "evidence_mib_per_hour": 2}
    performance = {name: {"measured": measurements.get(name), "target_maximum": maximum,
                          "gate_met": measurements.get(name) is not None and 0 <= measurements[name] <= maximum}
                   for name, maximum in performance_limits.items()}
    gates = {
        **{f"automatic_{path}": result["gate_met"] for path, result in paths.items()},
        "unknown_voice_rejection": bool(reviewed and unknown and lower_precision_bound(sum(row.get("assigned_identity") is None for row in unknown), len(unknown)) >= 0.99),
        "single_profile_unknown_rejection": bool(reviewed and one_profile_unknown and lower_precision_bound(sum(row.get("assigned_identity") is None for row in one_profile_unknown), len(one_profile_unknown)) >= 0.99),
        "suggestion_recall": bool(reviewed and recall["fraction"] is not None and recall["fraction"] >= 0.95),
        "eligible_coverage": bool(reviewed and coverage["fraction"] is not None and coverage["fraction"] >= 0.70),
        "clock_mapping": timing is not None and timing <= 250,
        **{name: value["gate_met"] for name, value in performance.items()},
        "recording_reliability": measurements.get("observer_induced_audio_drops") == 0,
        "privacy_lifecycle": measurements.get("forbidden_writes_or_payloads") == 0,
        "hosted_ui": document.get("hosted_ui_passed") is True,
        "live_provider_compatibility": document.get("live_provider_validated") is True,
    }
    return {
        "release_ready": all(gates.values()), "gates": gates, "automatic_paths": paths,
        "suggestions": {"top_three_recall": recall, "top_one_precision": top_one,
                        "candidate_count": sum(len(row.get("suggestions", [])) for row in uncertain),
                        "unresolved": sum(not row.get("suggestions") for row in uncertain)},
        "coverage": {"eligible_three_visible_turns": coverage,
                     "all_recorded_speakers": fraction(sum(useful(row) for row in rows), len(rows)),
                     "correct_automatic": fraction(sum(row.get("assigned_identity") is not None and row.get("assigned_identity") == row.get("expected_identity") for row in rows), len(rows)),
                     "usable_visual_seconds": measurements.get("usable_visual_seconds")},
        "unknown_voice_false_acceptance": fraction(sum(row.get("assigned_identity") is not None for row in unknown), len(unknown)),
        "single_profile_unknown_false_acceptance": fraction(sum(row.get("assigned_identity") is not None for row in one_profile_unknown), len(one_profile_unknown)),
        "enrolled_identity_confusion": fraction(sum(row.get("assigned_identity") is not None and row["assigned_identity"] != row.get("expected_identity") for row in known), len(known)),
        "enrolled_false_rejection": fraction(sum(row.get("assigned_identity") is None for row in known), len(known)),
        "clock_mapping_p95_ms": timing, "indicator_lag_p95_ms": indicators, "performance": performance,
        "profile_cost": {key: measurements.get(key) for key in ["profile_processing_seconds", "profile_peak_memory_mib", "encrypted_profile_bytes"]},
        "design_reviewed": reviewed,
        "limitations": "Binomial bounds assume independent assignments. Repeated people/meetings can be correlated. Hold out entire meetings and tuning participants; review that design separately. Missing measurements never pass a gate.",
    }


def self_test():
    assert lower_precision_bound(299, 299) >= 0.99
    assert lower_precision_bound(298, 298) < 0.99
    assert lower_precision_bound(99, 100) < 0.99
    assert not evaluate({})["release_ready"]
    assert percentile95(list(range(1, 101))) == 95
    row = {"meeting_id": "fixture", "speaker_id": "fixture", "path": "visual"}
    try:
        evaluate({"assignments": [row, row]})
    except ValueError:
        pass
    else:
        raise AssertionError("Duplicate assignment accepted")
    print("6 evaluator checks passed; no recognition accuracy was measured.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.input:
        print(json.dumps(evaluate(json.loads(args.input.read_text())), indent=2, allow_nan=False))
    else:
        parser.error("Provide a held-out evaluation JSON file or --self-test")
