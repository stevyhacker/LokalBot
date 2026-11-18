"""Turn QMSum into one neutral corpus both systems ingest.

Writes, under --out:
  corpus.jsonl   one meeting per line: id, title, started_at, turns[{speaker, text}]
  queries.jsonl  one QMSum specific query per line: id, meeting, question, spans [[first, last]] (turn indices)
  gbrain/        one Markdown page per meeting for `gbrain import`

QMSum (Zhong et al., NAACL 2021, MIT) has no timestamps, so turn i becomes a
LokalBot transcript segment starting at 10*i seconds, and meetings get one
synthetic day each, newest first, so neither system can use dates.
"""
import argparse, datetime as dt, glob, json, os, re

p = argparse.ArgumentParser()
p.add_argument("--qmsum", required=True, help="QMSum checkout")
p.add_argument("--out", required=True)
a = p.parse_args()

meetings, queries = [], []
for split in ("train", "val", "test"):
    for path in sorted(glob.glob(os.path.join(a.qmsum, "data/ALL", split, "*.json"))):
        mid = os.path.splitext(os.path.basename(path))[0]
        d = json.load(open(path))
        turns = [{"speaker": t["speaker"].strip() or "Speaker", "text": re.sub(r"\s+", " ", t["content"]).strip()}
                 for t in d["meeting_transcripts"]]
        meetings.append({"id": mid, "split": split, "turns": turns})
        for n, q in enumerate(d["specific_query_list"]):
            spans = [[int(s), int(e)] for s, e in q["relevant_text_span"]]
            queries.append({"id": f"{mid}#{n}", "split": split, "meeting": mid,
                            "question": q["query"].strip(), "spans": spans})

meetings.sort(key=lambda m: m["id"])
base = dt.datetime(2026, 11, 1, 9, 0, tzinfo=dt.timezone.utc)
for n, m in enumerate(meetings):
    m["title"] = f"Meeting {m['id']}"
    m["started_at"] = (base - dt.timedelta(days=n)).isoformat().replace("+00:00", "Z")

os.makedirs(os.path.join(a.out, "gbrain/meetings"), exist_ok=True)
with open(os.path.join(a.out, "corpus.jsonl"), "w") as f:
    for m in meetings:
        f.write(json.dumps(m) + "\n")
with open(os.path.join(a.out, "queries.jsonl"), "w") as f:
    for q in queries:
        f.write(json.dumps(q) + "\n")
for m in meetings:
    slug = m["id"].lower()
    body = "\n\n".join(f"{t['speaker']}: {t['text']}" for t in m["turns"])
    page = (f"---\ntitle: {m['title']}\ntype: meeting\ndate: {m['started_at'][:10]}\n---\n\n"
            f"# {m['title']}\n\n{body}\n")
    open(os.path.join(a.out, "gbrain/meetings", slug + ".md"), "w").write(page)
words = sum(len(t["text"].split()) for m in meetings for t in m["turns"])
print(f"{len(meetings)} meetings, {sum(len(m['turns']) for m in meetings)} turns, {words} words, {len(queries)} queries")
