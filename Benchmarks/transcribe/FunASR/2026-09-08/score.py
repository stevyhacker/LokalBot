import collections
import copy
import json
import pathlib
import numpy as np
from jiwer import process_words
from scipy.optimize import linear_sum_assignment
from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

ROOT = pathlib.Path(__file__).parent
normalizer = EnglishTextNormalizer(json.loads((ROOT/'english-spelling.json').read_text()))
fixture = json.loads((ROOT/'fixture.json').read_text())
clips = {c['id']: c for c in fixture['clips']}

def count(ref, hyp):
    r = process_words(normalizer(ref), normalizer(hyp))
    return {'errors': r.substitutions+r.deletions+r.insertions,
            'reference_words': r.hits+r.substitutions+r.deletions, 'wer': r.wer,
            'substitutions': r.substitutions, 'deletions': r.deletions, 'insertions': r.insertions}

def annotation(rows, uri):
    out = Annotation(uri=uri)
    for i, s in enumerate(rows):
        if s['end'] > s['start']:
            out[Segment(s['start'], s['end']), i] = s['speaker']
    # Merge contiguous same-speaker words before collars, otherwise each word
    # would incorrectly remove another 500ms from the scoring region.
    return out.support(collar=0)

def cpwer(reference, hypothesis):
    ref = collections.defaultdict(list); hyp = collections.defaultdict(list)
    for s in reference: ref[s['speaker']].append(s['text'])
    for s in hypothesis: hyp[s['speaker']].append(s['text'])
    refs = [' '.join(ref[k]) for k in sorted(ref)]
    hyps = [' '.join(hyp[k]) for k in sorted(hyp)]
    size = max(len(refs), len(hyps)); refs += ['']*(size-len(refs)); hyps += ['']*(size-len(hyps))
    costs = np.array([[count(r,h)['errors'] for h in hyps] for r in refs])
    ri, hi = linear_sum_assignment(costs)
    errors = int(costs[ri,hi].sum())
    words = sum(len(normalizer(r).split()) for r in refs)
    return {'errors': errors, 'reference_words': words, 'cpwer': errors/words,
            'reference_speakers': len(ref), 'hypothesis_speakers': len(hyp)}

def one(row, alias):
    clip = clips[row['id']]
    result = {'id':row['id'], 'kind':clip['kind'], 'seconds':row['seconds'],
              'duration':clip['duration'], 'wer':count(clip['reference'],row['text'])}
    if clip['kind'] != 'meeting': return result
    if alias == 'native': segments = row['segments']
    else:
        segments = [{'start':s['start']/1000,'end':s['end']/1000,'speaker':str(s['spk']),'text':s['text']}
                    for s in row['result']['sentence_info']]
    result['cpwer'] = cpwer(clip['words'], segments)
    reference = annotation(clip['words'], row['id'])
    hypothesis = annotation(row['diarization'], row['id'])
    uem = Timeline([Segment(0, clip['duration'])])
    result['der'] = {}
    for collar in (0.0, 0.25):
        metric = DiarizationErrorRate(collar=collar, skip_overlap=False)
        value = metric(reference,hypothesis,uem=uem,detailed=True)
        result['der'][str(collar)] = {k:float(v) for k,v in value.items()}
    return result

def aggregate(rows):
    result = {}
    for kind in ('clip','meeting'):
        selected = [r for r in rows if r['kind']==kind]
        if not selected: continue
        errors=sum(r['wer']['errors'] for r in selected); words=sum(r['wer']['reference_words'] for r in selected)
        seconds=sum(r['seconds'] for r in selected); duration=sum(r['duration'] for r in selected)
        item={'count':len(selected),'wer':errors/words,'errors':errors,'reference_words':words,
              'seconds':seconds,'audio_seconds':duration,'rtfx':duration/seconds}
        if kind=='meeting':
            item['cpwer']=sum(r['cpwer']['errors'] for r in selected)/sum(r['cpwer']['reference_words'] for r in selected)
            item['der']={}
            for collar in ('0.0','0.25'):
                stats=collections.Counter()
                for r in selected:
                    stats.update({k:v for k,v in r['der'][collar].items() if k!='diarization error rate'})
                item['der'][collar]={'fraction':sum(stats[k] for k in ['false alarm','missed detection','confusion'])/stats['total'], **stats}
        result[kind]=item
    return result

if __name__=='__main__':
    output={}
    for alias in ('native','funasr'):
        p=ROOT/f'{alias}.json'
        if not p.exists(): continue
        data=json.loads(p.read_text())
        rows=[one(r,alias) for r in data.get('rows',[])]
        output[alias]={'summary':aggregate(rows),'rows':rows}
    (ROOT/'scores.json').write_text(json.dumps(output,indent=2))
    print(json.dumps({k:v['summary'] for k,v in output.items()},indent=2))
