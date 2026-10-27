import json, math, re, sys
from pathlib import Path
root=Path(sys.argv[1])
pattern=re.compile(r'model (\S+), backend (\S+), debounce (\d+) ms, (\d+) ms per key: (\d+) of (\d+) cases got a suggestion; p50 (\d+) ms, p95 (\d+) ms, max (\d+) ms')
results={}
for mode in ['master','vulkan','cuda']:
    runs=[]
    for n in range(1,4):
        log=(root/f'{mode}-{n}.log').read_text()
        m=pattern.search(log); assert m, (mode,n)
        model,backend,debounce,key_ms,suggested,total,p50,p95,maximum=m.groups()
        warmup=re.search(r'warm-up \(server start and model load\) took ([0-9.]+)s',log)
        cases=[]
        for line in log.splitlines():
            if not line.startswith('| '): continue
            latency=re.search(r'\| (\d+) ms \|$',line)
            if latency or '| (none) |' in line:
                cases.append({'name':line.split('|')[1].strip(),'latency_ms':int(latency.group(1)) if latency else None})
        latencies=[c['latency_ms'] for c in cases if c['latency_ms'] is not None]
        assert len(latencies)==int(suggested) and len(cases)==int(total)
        proof=json.loads((root/f'{mode}-{n}-gpu-proof.json').read_text())
        assert proof and all(any(f'libggml-{backend}' in l for l in p['gpuLibraries']) for p in proof)
        if backend=='cuda': assert all(p['gpuOffloaded'] for p in proof)
        runs.append(dict(run=n,model=model,backend=backend,debounce_ms=int(debounce),key_interval_ms=int(key_ms),suggestions=int(suggested),total=int(total),p50_ms=int(p50),p95_ms=int(p95),max_ms=int(maximum),startup_seconds=float(warmup.group(1)),cases=cases))
    latencies=sorted(c['latency_ms'] for r in runs for c in r['cases'] if c['latency_ms'] is not None)
    results[mode]={'runs':runs,'pooled':dict(suggestions=len(latencies),total=sum(r['total'] for r in runs),p50_ms=latencies[math.ceil(.5*len(latencies))-1],p95_ms=latencies[math.ceil(.95*len(latencies))-1],max_ms=max(latencies))}
for filename in ['source-status.txt','source-status-after.txt','master-source-status.txt','master-source-status-after.txt']:
    assert not (root/filename).read_text().strip(),filename
assert (root/'benchmark-exit-code.txt').read_text().strip()=='0'
result={'pr_revision':(root/'tested-sha.txt').read_text().strip(),'master_revision':(root/'master-tested-sha.txt').read_text().strip(),'quantiles':'nearest rank from rounded per-case millisecond logs; successful suggestions only','results':results}
for stat in ['p50_ms','p95_ms']:
    result[f'cuda_vs_pr_vulkan_{stat}_reduction_percent']=round((1-results['cuda']['pooled'][stat]/results['vulkan']['pooled'][stat])*100,1)
(root/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({m:d['pooled'] for m,d in results.items()},indent=2))
print(json.dumps({k:v for k,v in result.items() if 'reduction_percent' in k}))
