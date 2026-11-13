"""Run inference sequentially so the engines do not contend with one another."""
import datetime
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path('/private/tmp/lokalbot-nemotron-bench')
repeats = '--repeats' in sys.argv
selected = [arg for arg in sys.argv[1:] if arg != '--repeats']
jobs = [('baseline', 'baseline', []), ('baseline', 'baseline-overlap', []),
        ('baseline', 'community-overlap', []), ('nemotron', 'offline', []),
        ('nemotron', 'fast128', []), ('nemotron', 'c128-split-w8a8', []),
        ('nemotron', 'low', ['streaming'])]
if selected:
    jobs = [job for job in jobs if job[1] in selected]
if repeats:
    manifest = json.loads((ROOT/'manifest.json').read_text())
    item = next(x for x in manifest if x['id'] == 'ES2004a_mhm')
    (ROOT/'repeats.json').write_text(json.dumps([dict(item, id=f"ES2004a_mhm_{i}") for i in range(4)], indent=2))
for engine, variant, extra in jobs:
    output = ROOT / ('perf' if repeats else 'results') / variant
    output.mkdir(parents=True, exist_ok=True)
    binary = ROOT / f'build-{engine}/out/Products/Release/DiarBench'
    command = [str(binary), str(ROOT/('repeats.json' if repeats else 'manifest.json')), str(ROOT/'models'/engine), variant, str(output), *extra]
    print(datetime.datetime.now().isoformat(), 'START', variant, flush=True)
    (output/'command.txt').write_text(json.dumps(command, indent=2))
    with (ROOT/f'{variant}{"-repeats" if repeats else ""}.log').open('w') as log:
        subprocess.run(['/usr/bin/time', '-l', *command], stdout=log, stderr=log, check=True)
    print(datetime.datetime.now().isoformat(), 'FINISHED', variant, flush=True)
