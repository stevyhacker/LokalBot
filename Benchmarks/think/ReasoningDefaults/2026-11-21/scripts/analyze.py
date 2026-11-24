import json, re, sys, unicodedata
from pathlib import Path
root = Path(sys.argv[1]); repo = Path(sys.argv[2])
def norm(t): return unicodedata.normalize("NFKC", t).lower()
keys = {"sample-en": "en", "sample-sr": "sr-Latn"}
expected_by_lang = {
    lang: json.loads((repo / f"LokalBot/Resources/SampleMeeting/expected.{lang}.json").read_text())
    for lang in keys.values()
}
aliases_by_index = {}
for exp in expected_by_lang.values():
    for idx, ent in enumerate(exp["entities"]):
        aliases_by_index.setdefault(idx, set()).update(ent["any"])
rows = []
for cond in ["qwen-off", "qwen-default", "inkling-default"]:
    reqs = [json.loads(l) for l in open(root / f"requests-{cond}.jsonl")]
    groups, current = [], []
    for r in reqs:
        if r.get("boundary"):
            groups.append((r["meeting"], current)); current = []
        else:
            current.append(r)
    for meeting, calls in groups:
        out = root / cond / meeting
        replay = json.loads((out / "replay.json").read_text())
        summary = (out / "summary.md").read_text() if (out / "summary.md").exists() else ""
        claims_path = out / "claims.json"
        if claims_path.exists():
            claims = json.loads(claims_path.read_text())
            claims = claims.get("claims", claims) if isinstance(claims, dict) else claims
            claims_count = len(claims) if isinstance(claims, list) else "?"
        else:
            claims_count = "N/A"
        outcomes_path = out / "outcomes.json"
        if outcomes_path.exists():
            outcomes = json.loads(outcomes_path.read_text())
            actions = len(outcomes.get("actionItems", outcomes.get("action_items", [])) or []) if isinstance(outcomes, dict) else "?"
        else:
            actions = "N/A"
        comp = sum((c.get("usage") or {}).get("completion_tokens", 0) for c in calls)
        think_chars = sum(c.get("reasoning_chars", 0) for c in calls)
        content_chars = sum(c.get("content_chars", 0) for c in calls)
        lengths = sum(1 for c in calls if c.get("finish") == "length")
        offs = sum(1 for c in calls if (c.get("chat_template_kwargs") or {}).get("enable_thinking") is False)
        gen_s = sum((c.get("timings") or {}).get("predicted_ms", 0) for c in calls) / 1000
        tps = [round((c.get("timings") or {}).get("predicted_per_second", 0)) for c in calls if c.get("timings")]
        recall = ""
        if meeting in keys:
            exp = expected_by_lang[keys[meeting]]
            text = norm(summary)
            hit = [
                e["label"]
                for idx, e in enumerate(exp["entities"])
                if any(norm(a) in text for a in aliases_by_index.get(idx, e["any"]))
            ]
            recall = f"{len(hit)}/{len(exp['entities'])}"
        rows.append((cond, meeting, replay["outcome"], round(replay["seconds"], 1), len(calls), lengths, offs, comp,
                     think_chars, content_chars, round(gen_s, 1), tps, claims_count, actions, recall,
                     [ (c.get("max_tokens"), c.get("thinking_budget_tokens")) for c in calls]))
hdr = ("condition","meeting","outcome","sec","reqs","len","off","compl_tok","think_ch","answer_ch","gen_s","tok/s","claims","actions","entities","max/think per req")
print("\t".join(hdr))
for r in rows: print("\t".join(str(x) for x in r))
