import json, subprocess, time, sys
from pathlib import Path
root = Path('/workspace/pr354-validation')
backend, run = sys.argv[1:]
name=f'{backend}-{run}'
for attempt in range(450):
    proof=[]
    for p in (root/f'autocomplete-{backend}').glob('llama-server-*.json'):
        try:
            m=json.loads(p.read_text())
            proc=Path('/proc')/str(m['pid'])
            maps=(proc/'maps').read_text()
            if f'libggml-{backend}' not in maps or not ('libnvidia' in maps or (backend == 'cuda' and 'libcuda.so' in maps)):
                continue
            if backend == 'cuda' and not m.get('gpuOffloaded'):
                continue
            item={key:m.get(key) for key in ['pid','binaryPath','modelPath','contextTokens','extraArgs','gpuOffloaded']}
            args=(proc/'cmdline').read_bytes().decode().split('\0')
            for i in range(len(args)-1):
                if args[i]=='--api-key': args[i+1]='[redacted]'
            item['arguments']=args
            item['gpuLibraries']=sorted(set(line.split()[-1] for line in maps.splitlines() if f'libggml-{backend}' in line or 'libnvidia' in line or 'libcuda.so' in line))
            proof.append(item)
        except (OSError,ValueError,KeyError): pass
    log=root/f'{name}.log'
    if proof and log.exists() and 'warm-up (server start and model load) took' in log.read_text():
        (root/f'{name}-gpu-proof.json').write_text(json.dumps(proof,indent=2))
        (root/f'{name}-nvidia-smi.txt').write_text(subprocess.check_output(['nvidia-smi'],text=True))
        sys.exit(0)
    time.sleep(2)
sys.exit('No verified live GPU model process found')
