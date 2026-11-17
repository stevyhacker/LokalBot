"""GBrain side of the stated-facts corrections suite, over its MCP server.

For each mode (edit = remember with replaces, restate = a new remember,
forget = forget) a fresh brain gets 40 unrelated facts and 40 facts, then the
40 corrections, then `recall` with each question. Embeddings follow the
brain's init (pass --init-args to choose).

usage: python3 gbrain_corrections.py <gbrain checkout> <facts.json> <work dir> <out.json> [--init-args "..."]
"""
import argparse, json, os, shlex, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("gbrain"); ap.add_argument("facts"); ap.add_argument("work"); ap.add_argument("out")
ap.add_argument("--init-args", default="--pglite --no-embedding")
a = ap.parse_args()
suite = json.load(open(a.facts))

class Server:
    def __init__(self, env):
        self.p = subprocess.Popen(["bun", "src/cli.ts", "serve"], cwd=a.gbrain, env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); self.p.stdin.flush()

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise SystemExit("gbrain serve exited")
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == self.n:
                return msg

    def tool(self, name, args):
        t = time.perf_counter()
        msg = self.rpc("tools/call", {"name": name, "arguments": args})
        ms = (time.perf_counter() - t) * 1000
        res = msg.get("result") or {}
        parts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
        try:
            return json.loads(parts[0]), ms
        except (ValueError, IndexError):
            return {"error": parts[0][:300] if parts else msg.get("error")}, ms

    def close(self):
        self.p.kill(); self.p.wait()

def entity_of(text):
    return text.split("'")[0].split()[1] if text.startswith("The ") else text.split("'")[0].split()[0]

results = []
for mode in ("edit", "restate", "forget"):
    env = dict(os.environ, GBRAIN_HOME=os.path.join(a.work, f"gbrain-facts-{mode}"))
    os.makedirs(env["GBRAIN_HOME"], exist_ok=True)
    subprocess.run(["bun", "src/cli.ts", "init", *shlex.split(a.init_args), "--non-interactive", "--json"], cwd=a.gbrain,
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    for cmd in (["transcripts", "archive", "off"], ["config", "set", "maintenance.auto", "false"]):
        subprocess.run(["bun", "src/cli.ts", *cmd], cwd=a.gbrain, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    s = Server(env)
    base = {"provenance": "stated by the user in chat", "content_origin": "user_said"}
    for text in suite["distractors"]:
        s.tool("remember", dict(base, fact=text, entity=entity_of(text)))
    ids = []
    for case in suite["facts"]:
        r, _ = s.tool("remember", dict(base, fact=case["original"], entity=case["entity"]))
        ids.append(str(r.get("id") or (r.get("outcome") or {}).get("id")))
    write_ms, statuses = [], []
    for case, fid in zip(suite["facts"], ids):
        if mode == "edit":
            r, ms = s.tool("remember", dict(base, fact=case["correction"], entity=case["entity"], replaces=fid))
        elif mode == "restate":
            r, ms = s.tool("remember", dict(base, fact=case["correction"], entity=case["entity"]))
        else:
            r, ms = s.tool("forget", {"id": fid, "reason": "the user withdrew it"})
        write_ms.append(ms)
        statuses.append(r.get("status") or r.get("error"))
    for case, status in zip(suite["facts"], statuses):
        r, ms = s.tool("recall", {"question": case["question"]})
        facts = r.get("facts") or []
        texts = [f.get("fact", "") for f in facts]
        cur = next((i for i, t in enumerate(texts) if case["current"] in t), None)
        sta = next((i for i, t in enumerate(texts) if case["stale"] in t), None)
        results.append({"mode": mode, "entity": case["entity"], "write_status": status,
                        "current_present": cur is not None, "stale_present": sta is not None,
                        "current_first": (cur < sta) if cur is not None and sta is not None else None,
                        "items": len(facts), "chars": sum(len(t) for t in texts), "read_ms": ms,
                        "write_ms": sum(write_ms) / len(write_ms), "error": r.get("error")})
    s.close()
    print(mode, "done", file=sys.stderr)
json.dump(results, open(a.out, "w"), indent=1)
