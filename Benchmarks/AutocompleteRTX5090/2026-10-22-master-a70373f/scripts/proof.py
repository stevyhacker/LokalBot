import json, subprocess, time, sys
from pathlib import Path
root = Path('/workspace/5090-validation')
run = sys.argv[1]
for attempt in range(450):
    proof = []
    for p in (root / 'autocomplete-vulkan').glob('llama-server-*.json'):
        try:
            marker = json.loads(p.read_text())
            pid = marker['pid']
            proc = Path('/proc') / str(pid)
            maps = (proc / 'maps').read_text()
            if 'libggml-vulkan' not in maps or 'libnvidia' not in maps:
                continue
            item = {key: marker.get(key) for key in ['pid', 'binaryPath', 'modelPath', 'contextTokens', 'extraArgs']}
            argv = (proc / 'cmdline').read_bytes().decode().split('\0')
            for i in range(len(argv)-1):
                if argv[i] == '--api-key':
                    argv[i+1] = '[redacted]'
            item['arguments'] = argv
            item['gpuLibraries'] = sorted(set(line.split()[-1] for line in maps.splitlines() if 'libggml-vulkan' in line or 'libnvidia' in line))
            proof.append(item)
        except (OSError, ValueError, KeyError):
            pass
    run_log = root / f'run-{run}.log'
    warmed = run_log.exists() and 'warm-up (server start and model load) took' in run_log.read_text()
    if proof and warmed:
        (root / f'run-{run}-gpu-proof.json').write_text(json.dumps(proof, indent=2))
        (root / f'run-{run}-nvidia-smi.txt').write_text(subprocess.check_output(['nvidia-smi'], text=True))
        sys.exit(0)
    time.sleep(2)
sys.exit('No live Vulkan/NVIDIA model process found')
