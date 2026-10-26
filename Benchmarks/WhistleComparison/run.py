"""Run engines serially with network denial and process memory measurement.

Usage: run.py OUT [whistle|parakeet|qwen|stream ...]. Builds/downloads are separate.
Existing named result files are not overwritten unless --replace is supplied.
"""
import argparse
import json
import os
import subprocess
from pathlib import Path

def main():
    ap=argparse.ArgumentParser();ap.add_argument('out',type=Path)
    ap.add_argument('engines',nargs='*',default=['whistle','parakeet','qwen','stream'])
    ap.add_argument('--replace',action='store_true');args=ap.parse_args();out=args.out.resolve()
    env={**os.environ,'NEEDLE_TELEMETRY':'0','DO_NOT_TRACK':'1','HF_HUB_OFFLINE':'1',
         'TRANSFORMERS_OFFLINE':'1','HF_HUB_DISABLE_TELEMETRY':'1'}
    profile=out/'offline.sb';profile.write_text('(version 1) (allow default) (deny network*)\n')
    for engine in args.engines:
        if engine not in ['whistle','parakeet','qwen','stream']:raise ValueError(engine)
        result=out/('stream-results.jsonl' if engine=='stream' else f'{engine}.jsonl')
        if result.exists() and not args.replace:raise FileExistsError(result)
        if engine in ['whistle','stream']:
            command=[str(out/'whistle-runner'),str(out/'models/whistle/whistle.cact'),
                     str(out/('stream.tsv' if engine=='stream' else 'jobs.tsv')),str(result),
                     str(out/'warmup.f32'),'1' if engine=='stream' else '3','stream' if engine=='stream' else 'batch']
        else:
            command=[str(out/'dd/Build/Products/Release/whistle-baselines'),str(out/f'{engine}-jobs.json')]
        (out/f'load-before-{engine}.txt').write_text(subprocess.check_output(['ps','-axo','pid,pcpu,rss,comm'],text=True))
        (out/f'command-{engine}.json').write_text(json.dumps(command,indent=2))
        print('Running '+engine,flush=True)
        with (out/f'{engine}.stdout').open('w') as stdout,(out/f'{engine}.log').open('w') as stderr:
            subprocess.run(['/usr/bin/time','-l','/usr/bin/sandbox-exec','-f',str(profile),*command],
                           env=env,stdout=stdout,stderr=stderr,check=True)
        print('Completed '+engine,flush=True)

if __name__=='__main__':main()
