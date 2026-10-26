#!/usr/bin/env python3
"""Diagnostic only: recheck the observed tool-boundary failure with bounded thinking."""
import argparse
import json
from pathlib import Path
from run import AGENT_SYSTEM, Server, save, score_tools

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent
case = next(c for c in json.loads((root / "cases.json").read_text())
            if c["id"] == "tool_do_not_invent")
for label, filename in (("spark", "Spark-X2.6-4B-Q4_K_M.gguf"),
                        ("qwen", "Qwen3.5-4B-Q4_K_M.gguf")):
    output = root / "results" / (label + "-reasoning-diagnostic")
    if output.exists():
        raise SystemExit(f"Refusing to overwrite {output}")
    server = Server(root / "models" / filename, args.runtime.resolve(), output)
    try:
        result = server.completion(
            [{"role": "system", "content": AGENT_SYSTEM},
             {"role": "user", "content": case["prompt"]}],
            tools=case["tools"], thinking=True, max_tokens=2048)
        result["score"] = score_tools(case, result)
        result["note"] = ("Post-result diagnostic, not part of the primary score. "
                          "Thinking enabled; 1024-token reasoning budget; 2048 total output cap; "
                          "temperature 0. Spark template defaults to high effort.")
        save(output / "probe.json", result)
        print(json.dumps({"model": label, "score": result["score"],
                          "message": result.get("message"),
                          "seconds": result["wall_seconds"]}, ensure_ascii=False), flush=True)
    finally:
        server.close()
