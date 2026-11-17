"""Run a command; print wall seconds and the peak resident set of its largest process.

usage: python3 measure.py <label> <out.json> -- cmd args...
Appends {"label", "seconds", "peak_rss_mb", "exit"} to out.json (a JSON list).
"""
import json, os, resource, subprocess, sys, time

label, out = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index("--") + 1:]
t = time.perf_counter()
code = subprocess.call(cmd)
seconds = time.perf_counter() - t
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
rss_mb = rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024  # bytes on macOS, KiB on Linux
rows = json.load(open(out)) if os.path.exists(out) else []
rows.append({"label": label, "seconds": round(seconds, 2), "peak_rss_mb": round(rss_mb, 1), "exit": code})
json.dump(rows, open(out, "w"), indent=1)
print(json.dumps(rows[-1]), file=sys.stderr)
sys.exit(code)
