"""Write the corrections suite's inputs.

  facts.json            stated facts, their corrections, and 40 unrelated facts
  pairs/corpus.jsonl    20 meeting pairs a week apart (the later one changes the
                        decision) among the first 60 QMSum meetings
  pairs/queries.jsonl   one question per pair, with the older and newer meeting
  pairs/gbrain/         the same meetings as GBrain pages

usage: python3 make_corrections.py <corpus.jsonl from prepare.py> <out dir>
"""
import datetime as dt, json, os, random, sys
from corrections_data import FACTS, DISTRACTORS, PAIRS, FILLER, check

assert not check(), check()

corpus, out = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(out, "pairs/gbrain/meetings"), exist_ok=True)
json.dump({"facts": [dict(zip(("entity", "original", "correction", "question", "current", "stale"), f)) for f in FACTS],
           "distractors": DISTRACTORS}, open(os.path.join(out, "facts.json"), "w"), indent=1)

rng = random.Random(17)
meetings = [json.loads(l) for l in open(corpus)][:60]
queries = []
base = dt.datetime(2026, 9, 1, 14, 0, tzinfo=dt.timezone.utc)
for n, (topic, older, newer, question, current, stale) in enumerate(PAIRS):
    for which, line, day in (("older", older, n), ("newer", newer, n + 7)):
        turns = [{"speaker": rng.choice(["Ana", "Marko", "Ivana", "Stefan"]), "text": t} for t in rng.sample(FILLER, 4)]
        turns.insert(2, {"speaker": "Ivana", "text": line})
        meetings.append({"id": f"pair{n:02d}-{which}", "title": f"Meeting pair{n:02d}-{which}",
                         "started_at": (base + dt.timedelta(days=day)).isoformat().replace("+00:00", "Z"), "turns": turns})
    queries.append({"id": f"pair{n:02d}", "question": question, "older": f"pair{n:02d}-older",
                    "newer": f"pair{n:02d}-newer", "current": current, "stale": stale})
with open(os.path.join(out, "pairs/corpus.jsonl"), "w") as f:
    for m in meetings:
        f.write(json.dumps(m) + "\n")
with open(os.path.join(out, "pairs/queries.jsonl"), "w") as f:
    for q in queries:
        f.write(json.dumps(q) + "\n")
for m in meetings:
    body = "\n\n".join(f"{t['speaker']}: {t['text']}" for t in m["turns"])
    open(os.path.join(out, "pairs/gbrain/meetings", m["id"].lower() + ".md"), "w").write(
        f"---\ntitle: {m['title']}\ntype: meeting\ndate: {m['started_at'][:10]}\n---\n\n# {m['title']}\n\n{body}\n")
print(len(FACTS), "facts,", len(meetings), "meetings in the pairs library,", len(queries), "pair questions")
