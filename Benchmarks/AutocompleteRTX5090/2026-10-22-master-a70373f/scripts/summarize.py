import json, math, re, sys
from pathlib import Path
root = Path(sys.argv[1])
runs = []
all_latencies = []
pattern = re.compile(r'model (\S+), backend (\S+), debounce (\d+) ms, (\d+) ms per key: (\d+) of (\d+) cases got a suggestion; p50 (\d+) ms, p95 (\d+) ms, max (\d+) ms')
for number in range(1, 4):
    log = (root / f'run-{number}.log').read_text()
    match = pattern.search(log)
    assert match, f'Missing summary in run {number}'
    model, backend, debounce, key_ms, suggested, total, p50, p95, maximum = match.groups()
    warmup = re.search(r'warm-up \(server start and model load\) took ([0-9.]+)s', log)
    latencies = [int(m.group(1)) for line in log.splitlines() if line.startswith('|') and (m := re.search(r'\| (\d+) ms \|$', line))]
    assert len(latencies) == int(suggested), (number, len(latencies), suggested)
    all_latencies.extend(latencies)
    proof = json.loads((root / f'run-{number}-gpu-proof.json').read_text())
    assert proof and all(any('libggml-vulkan' in s for s in x['gpuLibraries']) and any('libnvidia' in s for s in x['gpuLibraries']) for x in proof)
    runs.append(dict(run=number, model=model, backend=backend, debounce_ms=int(debounce), key_interval_ms=int(key_ms), suggestions=int(suggested), cases=int(total), p50_ms=int(p50), p95_ms=int(p95), max_ms=int(maximum), startup_seconds=float(warmup.group(1)), latencies_ms=latencies))
all_latencies.sort()
def pct(p):
    return all_latencies[math.ceil(p*len(all_latencies))-1]
result = dict(revision=(root/'tested-sha.txt').read_text().strip(), runs=runs, pooled=dict(successful_suggestions=len(all_latencies), scenarios=sum(r['cases'] for r in runs), p50_ms=pct(.5), p95_ms=pct(.95), max_ms=max(all_latencies), precision='Derived from rounded per-case millisecond values'))
assert (root/'validation-exit-code.txt').read_text().strip() == '0'
assert not (root/'source-status.txt').read_text().strip()
assert not (root/'source-status-after.txt').read_text().strip()
(root/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result, indent=2))
