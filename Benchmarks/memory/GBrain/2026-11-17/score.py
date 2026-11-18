"""Score the runs. Every number in REPORT.md comes from this script.

usage: python3 score.py <work dir> <results dir> run_name=file:kind ...
  kind lb  = lokalbot-memory-bench query output
  kind gb  = gbrain_run.py output (the `query` tool)
Reads <work>/corpus.jsonl, <work>/queries.jsonl, and the corrections files
(lb-facts.json, gb-facts.json, *-pairs-before/after.jsonl) when present.
Writes <results>/summary.json and prints Markdown tables.
"""
import json, os, random, statistics, sys

work, results = sys.argv[1], sys.argv[2]
runs = {}
for arg in sys.argv[3:]:
    name, rest = arg.split("=", 1)
    path, kind = rest.rsplit(":", 1)
    runs[name] = (path if os.path.isabs(path) else os.path.join(work, path), kind)

corpus = {}
for line in open(os.path.join(work, "corpus.jsonl")):
    m = json.loads(line)
    corpus[m["id"].lower()] = [len(t["speaker"]) + 2 + len(t["text"]) for t in m["turns"]]
queries = {q["id"]: q for q in map(json.loads, open(os.path.join(work, "queries.jsonl")))}

def window(meeting, turn, chars=2000):
    """Turns of a ~2,000-character passage centred on one turn."""
    sizes = corpus.get(meeting, [])
    if not sizes:
        return set()
    lo = hi = min(turn, len(sizes) - 1)
    total = sizes[lo]
    while total < chars and (lo > 0 or hi < len(sizes) - 1):
        if hi < len(sizes) - 1:
            hi += 1; total += sizes[hi]
        if total < chars and lo > 0:
            lo -= 1; total += sizes[lo]
    return set(range(lo, hi + 1))

def gold(q):
    return {i for s, e in q["spans"] for i in range(s, e + 1)}

def load(path, kind):
    rows = {}
    for line in open(path):
        r = json.loads(line)
        x = r if kind == "lb" else r["query"]
        if kind == "lb":
            pointers = [(p["meeting"].lower(), window(p["meeting"].lower(), p["turn"])) for p in x["pointers"]]
        else:
            pointers = [(p["meeting"].lower(), set(p["turns"])) for p in x["pointers"]]
        rows[r["id"]] = {
            "ms": x["ms"],
            "meetings": [m.lower() for m in x["meetings"]],
            "evidence": [(e["meeting"].lower(), set(e["turns"]), e["chars"]) for e in x["evidence"]],
            "pointers": pointers,
            "unmapped": sum(1 for e in x["evidence"] if not e["turns"]) + sum(1 for p in pointers if not p[1]),
        }
    return rows

def per_query(row, q):
    target, g = q["meeting"].lower(), gold(q)
    rank = row["meetings"].index(target) + 1 if target in row["meetings"] else None
    hit_ev = any(m == target and (t & g) for m, t, _ in row["evidence"])
    hits_ptr = [m == target and bool(t & g) for m, t in row["pointers"]]
    return {
        "r1": rank == 1, "r4": rank is not None and rank <= 4, "r10": rank is not None and rank <= 10,
        "rr": 1 / rank if rank and rank <= 20 else 0.0,
        "evidence_hit": hit_ev, "evidence_chars": sum(c for _, _, c in row["evidence"]),
        "p1": any(hits_ptr[:1]), "p5": any(hits_ptr[:5]),
    }

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]

def boot(a, b, n=2000, seed=7):
    """95% paired bootstrap interval of mean(a) - mean(b)."""
    rng = random.Random(seed)
    k = len(a)
    diffs = []
    for _ in range(n):
        idx = [rng.randrange(k) for _ in range(k)]
        diffs.append(sum(a[i] - b[i] for i in idx) / k)
    diffs.sort()
    return diffs[int(0.025 * n)], diffs[int(0.975 * n)]

summary = {"retrieval": {}, "paired": {}, "facts": {}, "pairs": {}}
scored = {}
for name, (path, kind) in runs.items():
    if not os.path.exists(path):
        continue
    rows = load(path, kind)
    ids = [i for i in queries if i in rows]
    s = {i: per_query(rows[i], queries[i]) for i in ids}
    scored[name] = s
    def mean(k):
        return sum(float(s[i][k]) for i in ids) / len(ids)
    ms = [rows[i]["ms"] for i in ids]
    summary["retrieval"][name] = {
        "questions": len(ids), "meeting_r1": mean("r1"), "meeting_r4": mean("r4"), "meeting_r10": mean("r10"),
        "mrr": mean("rr"), "gold_in_evidence": mean("evidence_hit"),
        "evidence_chars_median": statistics.median(s[i]["evidence_chars"] for i in ids),
        "passage_hit1": mean("p1"), "passage_hit5": mean("p5"),
        "ms_p50": pct(ms, 50), "ms_p95": pct(ms, 95), "ms_mean": sum(ms) / len(ms),
        "unmapped_rows": sum(rows[i]["unmapped"] for i in ids),
    }

names = list(scored)
for i, a in enumerate(names):
    for b in names[i + 1:]:
        common = [q for q in scored[a] if q in scored[b]]
        if not common:
            continue
        out = {}
        for k in ("r1", "r4", "evidence_hit", "p5"):
            xa = [float(scored[a][q][k]) for q in common]
            xb = [float(scored[b][q][k]) for q in common]
            lo, hi = boot(xa, xb)
            out[k] = {"diff": sum(xa) / len(xa) - sum(xb) / len(xb), "ci95": [lo, hi]}
        summary["paired"][f"{a} - {b}"] = out

for system in ("lb", "gb"):
    path = os.path.join(work, f"{system}-facts.json")
    if not os.path.exists(path):
        continue
    by = {}
    for x in json.load(open(path)):
        by.setdefault(x["mode"], []).append(x)
    summary["facts"][system] = {m: {
        "cases": len(xs),
        "current_present": sum(x["current_present"] for x in xs),
        "stale_present": sum(x["stale_present"] for x in xs),
        "both_present": sum(1 for x in xs if x["current_first"] is not None),
        "current_first_when_both": sum(1 for x in xs if x["current_first"]),
        "items_mean": sum(x["items"] for x in xs) / len(xs),
        "chars_mean": sum(x["chars"] for x in xs) / len(xs),
        "read_ms_p50": pct([x["read_ms"] for x in xs], 50),
        "write_ms_mean": xs[0]["write_ms"],
    } for m, xs in by.items()}

texts = {}
pq = os.path.join(work, "corr/pairs/queries.jsonl")
if os.path.exists(pq):
    for line in open(os.path.join(work, "corr/pairs/corpus.jsonl")):
        m = json.loads(line)
        texts[m["id"].lower()] = [t["text"] for t in m["turns"]]
    pairs = [json.loads(l) for l in open(pq)]
    for system, kind in (("lb", "lb"), ("gb", "gb")):
        for phase in ("before", "after"):
            path = os.path.join(work, f"{system}-pairs-{phase}.jsonl")
            if not os.path.exists(path):
                continue
            rows = {}
            for line in open(path):
                r = json.loads(line)
                rows[r["id"]] = r if kind == "lb" else r["query"]
            res = []
            for q in pairs:
                r = rows[q["id"]]
                ms = [m.lower() for m in r["meetings"]]
                ev = []
                for e in r["evidence"]:
                    ev += [texts.get(e["meeting"].lower(), [""] * 99)[t] for t in e["turns"]
                           if t < len(texts.get(e["meeting"].lower(), []))]
                blob = "\n".join(ev)
                c, st = blob.find(q["current"]), blob.find(q["stale"])
                newer, older = q["newer"], q["older"]
                res.append({
                    "newer_top4": newer in ms[:4], "older_top4": older in ms[:4],
                    "newer_above_older": newer in ms and (older not in ms or ms.index(newer) < ms.index(older)),
                    "current_in_evidence": c >= 0, "stale_in_evidence": st >= 0,
                    "current_first": c >= 0 and (st < 0 or c < st),
                })
            summary["pairs"][f"{system}-{phase}"] = {k: sum(x[k] for x in res) for k in res[0]} | {"cases": len(res)}

os.makedirs(results, exist_ok=True)
json.dump(summary, open(os.path.join(results, "summary.json"), "w"), indent=1)

def f(x):
    return f"{x:.3f}" if isinstance(x, float) else str(x)
print("| run | questions | meeting R@1 | R@4 | R@10 | MRR | gold turn in Ask/agent evidence | median evidence chars | passage hit@1 | hit@5 | p50 ms | p95 ms |")
print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for n, r in summary["retrieval"].items():
    print(f"| {n} | {r['questions']} | {f(r['meeting_r1'])} | {f(r['meeting_r4'])} | {f(r['meeting_r10'])} | {f(r['mrr'])} | "
          f"{f(r['gold_in_evidence'])} | {r['evidence_chars_median']:.0f} | {f(r['passage_hit1'])} | {f(r['passage_hit5'])} | "
          f"{r['ms_p50']:.0f} | {r['ms_p95']:.0f} |")
for k, v in summary["paired"].items():
    print(f"\n{k}: " + ", ".join(f"{m} {d['diff']:+.3f} [{d['ci95'][0]:+.3f}, {d['ci95'][1]:+.3f}]" for m, d in v.items()))
print("\n| system | mode | current shown | stale shown | both shown, current first | items | chars | read p50 ms |")
print("|---|---|---:|---:|---:|---:|---:|---:|")
for system, modes in summary["facts"].items():
    for m, r in modes.items():
        print(f"| {system} | {m} | {r['current_present']}/{r['cases']} | {r['stale_present']}/{r['cases']} | "
              f"{r['current_first_when_both']}/{r['both_present']} | {r['items_mean']:.1f} | {r['chars_mean']:.0f} | {r['read_ms_p50']:.2f} |")
print("\n| run | newer in top 4 | older in top 4 | newer ranked above older | current in evidence | stale in evidence | current before stale |")
print("|---|---:|---:|---:|---:|---:|---:|")
for k, r in summary["pairs"].items():
    n = r["cases"]
    print(f"| {k} | {r['newer_top4']}/{n} | {r['older_top4']}/{n} | {r['newer_above_older']}/{n} | {r['current_in_evidence']}/{n} | {r['stale_in_evidence']}/{n} | {r['current_first']}/{n} |")
