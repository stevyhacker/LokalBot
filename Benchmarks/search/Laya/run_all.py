"""Sequential runs so benchmark processes do not contend with one another."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
out = root / 'results/2026-09-24'
env = dict(os.environ, HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
           HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
for backend, dtype in [('mps','float32'), ('mlx','float32'), ('mlx','float16')]:
    for model in ['laya-multilingual', 'laya', 'laya-typed-decisions']:
        name = f'{backend}-{dtype}-{model}'
        if (out / f'{name}-metrics.json').exists():
            print(f'Skipping completed {name}', flush=True)
            continue
        with (out / f'{name}.log').open('w') as log:
            print(f'Starting {name}', flush=True)
            result = subprocess.run([sys.executable, str(root / 'run.py'), '--model', model,
                                     '--backend', backend, '--dtype', dtype], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
            print(f'Finished {name}: exit {result.returncode}', flush=True)
            if result.returncode:
                print(log.name, flush=True)
                sys.exit(result.returncode)
