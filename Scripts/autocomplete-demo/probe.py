#!/usr/bin/env python3
"""Ask the autocomplete model what it weighed at the end of each take.

    probe.py <debug.log> <llama-server> <model.gguf> <out.json>

With --lokalbot-film-ghost the app logs every prompt it builds
(`film: request {...}`). For each shot, this finds the last prompt whose text
before the caret ends with everything the shot typed, then runs it through
the app's bundled llama-server with the same model, greedily, asking for the
top candidates and their probabilities at each step. The launch video charts
these. The server path has no token healing, so a shot that ends mid-word
reads differently from what the app did there.
"""
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PORT = 18765


def typed(shot):
    return "".join(action.get("type", "") for action in shot["actions"])


def requests(log):
    found = []
    for line in Path(log).read_text(errors="replace").splitlines():
        marker = line.find("film: request ")
        if marker >= 0:
            try:
                found.append(json.loads(line[marker + len("film: request "):]))
            except ValueError:
                pass
    return found


def post(path, body):
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.load(response)


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    log, server, model, out = sys.argv[1:]
    logged = requests(log)
    prompts = {}
    for path in sorted((HERE / "shots").glob("*.json")):
        if path.stem == "warmup":
            continue
        text = typed(json.loads(path.read_text()))
        matches = [r for r in logged if r["prefix"].endswith(text)]
        if matches:
            prompts[path.stem] = matches[-1]
    print(f"{len(logged)} logged prompts; probing {sorted(prompts)}")
    if not prompts:
        return
    process = subprocess.Popen([server, "-m", model, "--port", str(PORT), "-c", "4096", "--log-disable"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(1)
        results = {}
        for name, request in prompts.items():
            began = time.time()
            reply = post("/completion", {
                # Probabilities before sampling: the model's own softmax over its vocabulary.
                "prompt": request["prompt"], "n_predict": 10, "n_probs": 6, "temperature": 0,
                "cache_prompt": False, "stop": ["\n"],
            })
            results[name] = {
                "prefix": request["prefix"], "prompt": request["prompt"], "content": reply.get("content"),
                "seconds": round(time.time() - began, 2),
                "probabilities": reply.get("completion_probabilities"),
            }
            print(f"{name}: {request['prefix'][-40:]!r} → {reply.get('content')!r}")
        Path(out).write_text(json.dumps(results, indent=2, ensure_ascii=False))
    finally:
        process.terminate()
        process.wait(timeout=30)


if __name__ == "__main__":
    main()
