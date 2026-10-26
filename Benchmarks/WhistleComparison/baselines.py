"""Clone cached baseline assets, verify them, and write local inference jobs."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out', type=Path)
    ap.add_argument('--qwen-source', type=Path, default=Path.home()/'Library/Application Support/me.dotenv.LokalBot/qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit')
    ap.add_argument('--parakeet-source', type=Path, default=Path.home()/'Library/Application Support/FluidAudio/Models/parakeet-ultra')
    args = ap.parse_args();out=args.out.resolve()
    qroot=out/'qwen/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit'
    proot=out/'models/parakeet-ultra'
    for source,dest in [(args.qwen_source,qroot),(args.parakeet_source,proot)]:
        if not dest.exists():
            dest.parent.mkdir(parents=True,exist_ok=True)
            subprocess.run(['cp','-cR',str(source),str(dest)],check=True)
    catalog=next(x for x in json.loads((ROOT/'LokalBot/Resources/ModelAssets/pinned-speech-models.json').read_text()) if x['name']=='parakeetUltra')
    if catalog['revision']!='95eaa59a39d4394f047a4dc5cce480388a60d1b6':
        raise ValueError('The app catalog changed; review and repin this benchmark before running')
    records=[]
    for spec in catalog['files']:
        b=(proot/spec['path']).read_bytes()
        digest=hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest() if spec['isGitBlob'] else hashlib.sha256(b).hexdigest()
        if digest!=spec['digest']:raise ValueError(f"Parakeet hash mismatch: {spec['path']}")
        records.append(dict(file=spec['path'],bytes=len(b),sha256=hashlib.sha256(b).hexdigest()))
    qrecords=[]
    for metadata in sorted((qroot/'.cache/huggingface/download').glob('*.metadata')):
        name=metadata.name.removesuffix('.metadata');revision,expected,*_=metadata.read_text().splitlines()
        if revision!='e5450a26d1fd417c45fc9c405651ddc3180a27a6':raise ValueError('Qwen revision changed')
        b=(qroot/name).read_bytes()
        digest=hashlib.sha256(b).hexdigest() if len(expected)==64 else hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest()
        if digest!=expected:raise ValueError(f'Qwen hash mismatch: {name}')
        qrecords.append(dict(file=name,revision=revision,bytes=len(b),sha256=hashlib.sha256(b).hexdigest()))
    assert len(qrecords)==6 and len(records)==18
    result=dict(parakeet=dict(repository=catalog['repository'],revision=catalog['revision'],files=records),
                qwen=dict(repository='aufklarer/Qwen3-ASR-1.7B-MLX-8bit',files=qrecords))
    (out/'baseline-assets.json').write_text(json.dumps(result,indent=2)+'\n')
    for engine,model_path in [('qwen',qroot),('parakeet',proot)]:
        items=json.loads((out/'items.json').read_text())
        for item in items:
            if item['hints']:item['hints']=item['hints'].replace('|',', ')
        job=dict(engine=engine,modelPath=str(model_path),modelID='aufklarer/Qwen3-ASR-1.7B-MLX-8bit',
                 output=str(out/f'{engine}.jsonl'),warmup=str(out/'warmup.f32'),repeats=3,items=items)
        (out/f'{engine}-jobs.json').write_text(json.dumps(job,indent=2)+'\n')
    print(f'Verified {len(records)} Parakeet files and {len(qrecords)} Qwen files')

if __name__=='__main__':main()
