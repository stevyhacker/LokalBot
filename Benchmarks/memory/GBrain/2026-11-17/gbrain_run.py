"""GBrain side of the comparison: questions go to a `gbrain serve` stdio MCP
server, the way an agent calls it, so process start-up is paid once.

usage: python3 gbrain_run.py <gbrain checkout> <corpus.jsonl> <queries.jsonl> <out.jsonl> [--tools query,search]

Per question it records, for each tool:
  meetings  page ranking (QMSum ids, first appearance order)
  evidence  each returned row mapped back to the transcript turns it holds,
            with its character count (default return_unit "auto", as shipped)
  pointers  the same question with return_unit "chunk": one passage per row
  ms        round-trip time of the default call; op_ms is GBrain's own timing
"""
import argparse, json, re, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("gbrain"); ap.add_argument("corpus"); ap.add_argument("queries"); ap.add_argument("out")
ap.add_argument("--tools", default="query,search")
ap.add_argument("--limit", type=int, default=0, help="only the first N questions")
a = ap.parse_args()

# line text -> turn index, for lines that occur once in their meeting
unique = {}
for line in open(a.corpus):
    m = json.loads(line)
    seen = {}
    for i, t in enumerate(m["turns"]):
        key = f"{t['speaker']}: {t['text']}"
        seen.setdefault(key, []).append(i)
    unique[m["id"].lower()] = {k: v[0] for k, v in seen.items() if len(v) == 1 and len(k) >= 30}
ids = {k: k for k in unique}

def turns_in(slug, text):
    mid = slug.split("/")[-1]
    table = unique.get(mid, {})
    hits = [table[l.strip()] for l in text.split("\n") if l.strip() in table]
    if not hits:
        return mid, []
    return mid, list(range(min(hits), max(hits) + 1))

proc = subprocess.Popen(["bun", "src/cli.ts", "serve"], cwd=a.gbrain, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
counter = [0]
def rpc(method, params):
    counter[0] += 1
    i = counter[0]
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("gbrain serve exited")
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == i:
            return msg

rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}})
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); proc.stdin.flush()

def tool(name, args):
    t = time.perf_counter()
    msg = rpc("tools/call", {"name": name, "arguments": args})
    ms = (time.perf_counter() - t) * 1000
    res = msg.get("result", {})
    payload = res.get("structuredContent")
    if payload is None:
        # The first text part is the result JSON; later parts are notices.
        parts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
        try:
            payload = json.loads(parts[0])
        except (ValueError, IndexError):
            payload = {"error": (parts[0][:500] if parts else None) or msg.get("error")}
    if isinstance(payload, list):
        payload = {"results": payload}
    meta = res.get("_meta") or {}
    payload.setdefault("timings_ms", meta.get("timings_ms") or (meta.get("gbrain") or {}).get("timings_ms"))
    return payload, ms

def rows_of(payload):
    if isinstance(payload, list):
        return payload
    return payload.get("results") or []

def rss_mb():
    try:  # Linux: the kernel's high-water mark
        for l in open(f"/proc/{proc.pid}/status"):
            if l.startswith("VmHWM:"):
                return int(l.split()[1]) / 1024
    except OSError:  # macOS: current resident size, sampled every 25 questions
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(proc.pid)]).strip()
        return int(out or 0) / 1024
    return 0.0

tools = a.tools.split(",")
peak = 0.0
out = open(a.out, "w")
for n, line in enumerate(open(a.queries)):
    if a.limit and n >= a.limit:
        break
    q = json.loads(line)
    row = {"id": q["id"]}
    for name in tools:
        base = {"query": q["question"], "snippet_chars": 0, "fields": "full"}
        payload, ms = tool(name, dict(base))
        rows = rows_of(payload)
        meetings, evidence = [], []
        for r in rows:
            mid, turns = turns_in(r.get("slug", ""), r.get("chunk_text", ""))
            if mid not in meetings:
                meetings.append(mid)
            evidence.append({"meeting": mid, "turns": turns, "chars": len(r.get("chunk_text", ""))})
        timings = payload.get("timings_ms") if isinstance(payload, dict) else None
        cpay, _ = tool(name, dict(base, return_unit="chunk", limit=20))
        pointers = []
        for r in rows_of(cpay):
            mid, turns = turns_in(r.get("slug", ""), r.get("chunk_text", ""))
            pointers.append({"meeting": mid, "turns": turns, "chars": len(r.get("chunk_text", ""))})
        row[name] = {"ms": ms, "op_ms": (timings or {}).get("op"), "meetings": meetings, "evidence": evidence,
                     "pointers": pointers, "error": payload.get("error") if isinstance(payload, dict) else None}
    out.write(json.dumps(row) + "\n"); out.flush()
    if n % 25 == 0:
        peak = max(peak, rss_mb())
    if n % 50 == 0:
        print(n, {k: round(row[k]["ms"]) for k in tools}, file=sys.stderr)
peak = max(peak, rss_mb())
print(json.dumps({"server_peak_rss_mb": round(peak, 1)}), file=sys.stderr)
proc.kill(); proc.wait()
