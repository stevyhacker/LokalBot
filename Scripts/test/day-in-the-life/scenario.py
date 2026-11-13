#!/usr/bin/env python3
"""Stub scenario for the day-in-the-life run, built from committed recordings.

Recorded answers replay in order per purpose; a catch-all per purpose repeats
the last recorded usable answer, so a day with more segments than the
recording still gets valid responses.

With --real-asr, notes repairs also get an answer. The recorded notes answer
quotes the golden transcripts exactly, so real Parakeet wording (for example
"eviction policy" for "eviction-policy") sends ownership to a repair that was
never recorded. The repair answers like a model that finds nothing to fix.
Golden runs keep no repair rule, so an unexpected repair still fails loudly.
"""
import json
from pathlib import Path
import sys


EMPTY_REPAIR = json.dumps({"notes": [], "actions": [], "has_more": False})


def build(recordings_root, model, real_asr=False):
    root = Path(recordings_root)
    markers = json.loads((root / "purpose-markers.json").read_text())
    folder = root / model.replace("/", "__")
    rules, last = [], {}
    for case in ["digest-day", "notes-design-review"]:
        recording = json.loads((folder / f"{case}.json").read_text())
        seen = {}
        for call in recording["calls"]:
            purpose = call["purpose"]
            seen[purpose] = seen.get(purpose, 0) + 1
            behaviour = ({"kind": "truncate", "content": call["content"], "keep": 1}
                         if call["finishReason"] == "length" else {"kind": "reply", "content": call["content"]})
            rules.append({"match": {"systemIncludes": markers[purpose], "nth": seen[purpose]}, "behaviour": behaviour})
            if call["finishReason"] != "length":
                last[purpose] = call["content"]
    for purpose, content in last.items():
        rules.append({"match": {"systemIncludes": markers[purpose]}, "behaviour": {"kind": "reply", "content": content}})
    if real_asr:
        rules.append({"match": {"systemIncludes": markers["notesRepair"]},
                      "behaviour": {"kind": "reply", "content": EMPTY_REPAIR}})
    return rules


if __name__ == "__main__":
    print(json.dumps({"rules": build(sys.argv[1], sys.argv[2], real_asr="--real-asr" in sys.argv[3:])}))
