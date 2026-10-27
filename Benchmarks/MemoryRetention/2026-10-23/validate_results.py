"""Check complete coverage, frozen inputs, per-item review identity and chart values."""
import csv
import hashlib
import json
from pathlib import Path
from score import parse,score_case,aggregate

ROOT=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())

def main():
    frozen=load(ROOT/'frozen.json')
    assert all(sha(ROOT/f)==h for f,h in frozen['files'].items()),'Frozen input changed'
    cases=load(ROOT/'cases.json');byid={c['id']:c for c in cases}
    models=load(ROOT/'models.json');review=load(ROOT/'review.json');scores=load(ROOT/'scores.json')
    server_hashes=set();count=0
    for m in models:
        arm=m['arm'];raw=[json.loads(l) for l in (ROOT/'results'/f'{arm}.jsonl').read_text().splitlines()]
        assert len(raw)==120 and {r['id'] for r in raw}==set(byid),'Missing/duplicate cases'
        meta=load(ROOT/'results'/f'{arm}.meta.json');ident=meta['identity']
        assert ident['model_sha256']==m['sha256'] and ident['frozen_sha256']==sha(ROOT/'frozen.json')
        server_hashes.add(ident['server_sha256'])
        keys=set();rows=[]
        for r in raw:
            c=byid[r['id']];automatic=score_case(c,r)
            for item in automatic['items']:
                key=f"{c['id']}:{item['index']}";keys.add(key)
                src=next((l['text'] for l in c['lines'] if l['handle']==item['line'].strip().upper()),'INVALID HANDLE')
                rec=dict(id=c['id'],i=item['index'],source=src,known=c['known'],gold=[g['text'] for g in c['expected']],output=item['text'],kind=item['kind'],auto=item['match'])
                digest=hashlib.sha256(json.dumps(rec,ensure_ascii=False,sort_keys=True).encode()).hexdigest()
                assert review[arm][key]['audit_record_sha256']==digest,f'Review/raw mismatch {arm} {key}'
                assert review[arm][key]['reason'] and isinstance(review[arm][key]['unwanted'],bool)
            rows.append(score_case(c,r,review[arm]))
        assert keys==set(review[arm]),f'Incomplete or stale review: {arm}'
        assert aggregate(rows)==scores[arm+'/reviewed']['all']
        count+=len(keys)
    assert len(server_hashes)==1,'Different runtime binary'
    chart=list(csv.DictReader((ROOT/'chart-data.csv').open()))
    assert len(chart)==8
    for r in chart:
        s=scores[r['arm']+'/reviewed'][r['language']]
        for k,v in s.items():assert int(r[k])==v,f'Chart data mismatch {k}'
    print(f'PASS: {len(models)*len(cases)} responses, {count} reviewed items, frozen inputs, pinned weights/runtime, score aggregation and chart CSV.')

if __name__=='__main__':main()
