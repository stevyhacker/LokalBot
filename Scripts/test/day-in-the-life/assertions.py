#!/usr/bin/env python3
"""User-visible assertions for the day-in-the-life run."""
import json
from pathlib import Path
import re
import sys


def health_problems(report):
    problems = []
    for finding in report["findings"]:
        if finding["status"] == "fail":
            problems.append(f"health {finding['check']} failed: {finding.get('summary', '')}")
        if finding["check"] == "digestCoverage":
            coverage = finding.get("measurements", {}).get("coverage", 0)
            if coverage < 0.6:
                problems.append(f"digest covers only {coverage:.0%} of tracked activity")
    return problems


def has_action_owned_by_me(folder):
    data = json.loads((Path(folder) / "outcomes.json").read_text())
    return any(action.get("isForUser") is True or str(action.get("owner", "")).lower() == "me"
               for action in data.get("actionItems", []))


def has_finished_notes(folder):
    """Real-ASR runs: notes completed with at least one action, any owner."""
    path = Path(folder) / "outcomes.json"
    return path.exists() and bool(json.loads(path.read_text()).get("actionItems"))


def words(text):
    # Hyphens, punctuation, and case are not recognition errors.
    return re.sub(r"[^a-z0-9' ]+", " ", text.lower().replace("-", " ")).split()


def spoken_words(segments):
    return [word for segment in sorted(segments, key=lambda s: s["start"]) for word in words(segment["text"])]


def word_edits(reference, hypothesis):
    """Word edit distance. A compound heard split or joined ("cleanup" as
    "clean up", or the reverse) is spelling, not a recognition error."""
    rows = [list(range(len(hypothesis) + 1))]
    for i in range(1, len(reference) + 1):
        row = [i]
        for j in range(1, len(hypothesis) + 1):
            best = min(rows[i - 1][j] + 1, row[j - 1] + 1,
                       rows[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]))
            if j > 1 and reference[i - 1] == hypothesis[j - 2] + hypothesis[j - 1]:
                best = min(best, rows[i - 1][j - 2])
            if i > 1 and reference[i - 2] + reference[i - 1] == hypothesis[j - 1]:
                best = min(best, rows[i - 2][j - 1])
            row.append(best)
        rows.append(row)
    return rows[-1][-1]


def word_error_rate(reference, hypothesis):
    return word_edits(reference, hypothesis) / max(1, len(reference))


def golden_words(golden):
    segments = []
    for track in sorted(Path(golden).glob("*.json")):
        segments += json.loads(track.read_text())["segments"]
    return spoken_words(segments)


def heard_words(folder):
    return spoken_words(json.loads((Path(folder) / "transcript.json").read_text())["segments"])


def transcript_word_error_rate(folder, golden):
    """WER of a processed meeting against the golden transcripts of its tracks."""
    return word_error_rate(golden_words(golden), heard_words(folder))


def day_word_error_rate(meetings):
    """Edits across the day's (folder, golden) meetings over all their golden
    words, so one misheard word in a short meeting cannot decide the run."""
    edits = total = 0
    for folder, golden in meetings:
        reference = golden_words(golden)
        edits += word_edits(reference, heard_words(folder))
        total += len(reference)
    return edits / max(1, total)


if __name__ == "__main__":
    mode, target = sys.argv[1], sys.argv[2]
    if mode == "health":
        problems = health_problems(json.loads(Path(target).read_text()))
        print("\n".join(problems))
        sys.exit(1 if problems else 0)
    if mode == "owned-action":
        sys.exit(0 if has_action_owned_by_me(target) else 1)
    if mode == "finished-notes":
        sys.exit(0 if has_finished_notes(target) else 1)
    if mode == "wer-day":
        # wer-day <max> <folder> <golden> [<folder> <golden> ...]
        meetings = list(zip(sys.argv[3::2], sys.argv[4::2]))
        for folder, golden in meetings:
            reference, heard = golden_words(golden), heard_words(folder)
            rate = word_error_rate(reference, heard)
            print(f"    {Path(folder).name}: {rate:.1%}", file=sys.stderr)
            if rate:
                # Synthetic meetings only: show the words so drift can be read
                # from the log without the artifact.
                print(f"      expected: {' '.join(reference)}", file=sys.stderr)
                print(f"      heard: {' '.join(heard)}", file=sys.stderr)
        rate = day_word_error_rate(meetings)
        print(f"{rate:.1%}")
        sys.exit(0 if rate <= float(target) else 1)
