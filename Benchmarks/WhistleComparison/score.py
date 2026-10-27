"""Score paired public fixtures; write only numeric aggregates to the checkout."""
import json
import re
import sys
import unicodedata
from pathlib import Path
import numpy as np
from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer, BasicTextNormalizer

ROOT = Path(__file__).resolve().parents[2]
EN = EnglishTextNormalizer(json.loads((ROOT/'Benchmarks/ModelAlternatives/2026-09-07/english-spelling.json').read_text()))
BASIC = BasicTextNormalizer(remove_diacritics=False)
CYR = dict(zip('абвгдђежзијклљмнњопрстћуфхцчџш',
               ['a','b','v','g','d','đ','e','ž','z','i','j','k','l','lj','m','n','nj','o','p','r','s','t','ć','u','f','h','c','č','dž','š']))

def words(text, group='ami'):
    text = unicodedata.normalize('NFC', text or '').lower()
    text = re.sub(r'<\|[^>]*\|>', ' ', text)
    # Match spoken times ("three thirty" -> "330") to the written form 3:30.
    text = re.sub(r'\b(\d{1,2}):([0-5]\d)\b', r'\1\2', text)
    if group == 'fleurs-sr_rs':
        text = ''.join(CYR.get(c,c) for c in text)
    return (BASIC(text) if group.startswith('fleurs-') and group != 'fleurs-en_us' else EN(text)).split()

def counts(ref, hyp):
    result = dict(refWords=len(ref), substitutions=0, deletions=0, insertions=0)
    for op,_,_ in Levenshtein.editops(ref,hyp):
        result[{'replace':'substitutions','delete':'deletions','insert':'insertions'}[op]] += 1
    result['errors'] = sum(result[k] for k in ['substitutions','deletions','insertions'])
    return result

def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

def timing_log(path):
    if not path.exists(): return {}
    text=path.read_text()
    keys={'maximum resident set size':'maxRSSBytes','peak memory footprint':'peakFootprintBytes'}
    result={}
    for name,key in keys.items():
        m=re.search(r'(\d+)\s+'+name,text)
        if m:result[key]=int(m[1])
    return result

def main():
    out=Path(sys.argv[1]); target=Path(sys.argv[2])
    items=json.loads((out/'items.json').read_text()); by_id={r['id']:r for r in items}
    # Small scoring invariants catch a swapped reference/hypothesis or normalization regression.
    assert counts(['a','b'],['a','c','d']) == dict(refWords=2,substitutions=1,deletions=0,insertions=1,errors=2)
    assert words('THREE thirty!') == words('3:30')
    engines={}
    item_scores={}
    for engine in ['whistle','parakeet','qwen']:
        path=out/f'{engine}.jsonl'
        if not path.exists():continue
        rows=read_rows(path); decoded=[r for r in rows if 'id' in r]
        first={r['id']:r for r in decoded if r['repeat']==0}
        expected={(r['id'],n) for r in items for n in range(3)}
        actual={(r['id'],r['repeat']) for r in decoded}
        if actual != expected:raise ValueError(f'{engine}: incomplete rows ({len(actual)} / {len(expected)})')
        if len(decoded)!=len(actual):raise ValueError(f'{engine}: duplicate results')
        score={}
        for id,r in first.items():
            item=by_id[id]
            c=counts(words(item['reference'],item['group']),words(r.get('result',{}).get('text',''),item['group']))
            c.update(id=id,seconds=float(np.median([t['seconds'] for t in decoded if t['id']==id])),audioSeconds=item['duration'])
            score[id]=c
        item_scores[engine]=score
        groups={g:[r['id'] for r in items if r['group']==g] for g in sorted({r['group'] for r in items})}
        groups['human-english']=[r['id'] for r in items if r['group'] in ['ami','fleurs-en_us']]
        agg={}
        for group,ids in groups.items():
            g=[score[id] for id in ids]
            sums={k:sum(c[k] for c in g) for k in ['refWords','errors','substitutions','deletions','insertions','audioSeconds','seconds']}
            sums.update(clips=len(g),wer=(100*sums['errors']/sums['refWords'] if sums['refWords'] else None),
                        rtfx=sums['audioSeconds']/sums['seconds'],medianMs=1000*float(np.median([c['seconds'] for c in g])),
                        p95Ms=1000*float(np.percentile([c['seconds'] for c in g],95)))
            agg[group]=sums
        # Timestamp checks validate structure only, not acoustic alignment accuracy.
        timestamps=dict(words=0,invalid=0,outOfBounds=0,nonMonotonic=0)
        for id,r in first.items():
            prev=-1
            for w in r.get('result',{}).get('words',[]):
                a,b=w['start'],w['end'];timestamps['words']+=1
                timestamps['invalid']+=int(not(0<=a<=b))
                timestamps['outOfBounds']+=int(b>by_id[id]['duration']+0.1)
                timestamps['nonMonotonic']+=int(a<prev-0.001);prev=a
        changes=sum(any(words(r.get('result',{}).get('text',''),by_id[id]['group']) != words(first[id].get('result',{}).get('text',''),by_id[id]['group'])
                        for r in decoded if r['id']==id) for id in first)
        engines[engine]=dict(groups=agg,metadata=[r for r in rows if 'id' not in r],processMemory=timing_log(out/f'{engine}.log'),
                             timestampStructure=timestamps,changedAcrossRepeats=changes,failures=sum('error' in r for r in decoded))
    paired={}
    if 'whistle' in item_scores:
        for engine in ['parakeet','qwen']:
            if engine not in item_scores:continue
            for group in ['human-english','ami','fleurs-en_us','noise10']:
                ids=[r['id'] for r in items if r['group']==group or group=='human-english' and r['group'] in ['ami','fleurs-en_us']]
                a=item_scores['whistle'];b=item_scores[engine];rng=np.random.default_rng(20261009)
                deltas=[]
                for _ in range(2000):
                    picks=rng.choice(ids,len(ids),replace=True)
                    deltas.append(100*sum(a[id]['errors']-b[id]['errors'] for id in picks)/sum(a[id]['refWords'] for id in picks))
                paired[f'whistle-minus-{engine}/{group}']=dict(werPoints=100*sum(a[id]['errors']-b[id]['errors'] for id in ids)/sum(a[id]['refWords'] for id in ids),
                    bootstrap95=[float(v) for v in np.percentile(deltas,[2.5,97.5])],resamplingUnit='clip, exploratory; correlated speakers may widen uncertainty')
    stream={}
    if (out/'stream-results.jsonl').exists():
        rows=read_rows(out/'stream-results.jsonl');steps=[r for r in rows if 'id' in r]
        meta=json.loads((out/'stream.json').read_text())
        text=' '.join(r['result'].get('text','') for r in steps)
        c=counts(words(meta['reference']),words(text));c['wer']=100*c['errors']/c['refWords']
        c['firstCommitAudioSeconds']=next((r['received'] for r in steps if r['result'].get('text') and 'received' in r),None)
        c['duration']=meta['duration'];c['maxPassMs']=max(r.get('seconds',0) for r in steps)*1000
        c['totalComputeSeconds']=steps[-1]['totalSeconds'];stream=c
    result=dict(clips=len(items),audioSeconds=sum(r['duration'] for r in items),engines=engines,paired=paired,stream=stream)
    target.parent.mkdir(parents=True,exist_ok=True);target.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
