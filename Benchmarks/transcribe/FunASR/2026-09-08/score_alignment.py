import collections
import json
from score import ROOT, clips, cpwer, count, normalizer

native=json.loads((ROOT/'native.json').read_text())
aligned=json.loads((ROOT/'native-alignment.json').read_text())
funasr=json.loads((ROOT/'funasr.json').read_text())
native_rows={r['id']:r for r in native['rows']}
output={'native_aligned':[], 'funasr_aligned_cam':[], 'funasr_aligned_pyannote':[]}

def assign(words, turns):
    results=[]
    for w in words:
        # Same greatest-individual-overlap rule as the existing app, now at word
        # granularity. For zero-duration aligner words, use their point timestamp.
        start,end=w['start'],w['end']
        if end <= start: end=start+0.001
        scores=[(max(0,min(t['end'],end)-max(t['start'],start)), t['speaker']) for t in turns]
        best=max(enumerate(scores),key=lambda p:(p[1][0],-p[0]))[1] if scores else (0,'unknown')
        results.append(dict(w,speaker=best[1] if best[0]>0 else 'unknown'))
    return results

def scored(row, words, turns):
    hypothesis=assign(words,turns)
    text=' '.join(w['text'] for w in words)
    original=normalizer(row['text']); aligned_text=normalizer(text)
    return {'id':row['id'], 'cpwer':cpwer(clips[row['id']]['words'],hypothesis),
            'wer':count(clips[row['id']]['reference'],text),
            'same_normalized_words':original==aligned_text,
            'normalization_edit_difference':count(row['text'],text),
            'segments':hypothesis}

for row in aligned['rows']:
    base=native_rows[row['id']]
    result=scored(base,row['words'],base['diarization'])
    result['alignment_seconds']=row['seconds']
    output['native_aligned'].append(result)

for row in funasr['rows']:
    if row['kind']!='meeting':continue
    sentences=row['result']['sentence_info']
    ordered=sorted(enumerate(sentences),key=lambda p:p[1]['end']-p[1]['start'])
    # The pinned AutoModel sorts VAD spans by duration before inference.
    # Recover that exact order; text equality is a strict correspondence check.
    assert len(ordered)==len(row['raw_alignment_seconds'])
    chunks={}
    for (index,sentence),chunk in zip(ordered,row['raw_alignment_seconds']):
        assert sentence['text']==chunk['text'], (sentence['text'],chunk['text'])
        chunks[index]=chunk['words']
    words=[]
    for index,sentence in enumerate(sentences):
        chunk=chunks[index]
        offset=sentence['start']/1000
        words += [{'text':w['text'],'start':offset+w['start_time'],'end':offset+w['end_time']} for w in chunk]
    output['funasr_aligned_cam'].append(scored(row,words,row['diarization']))
    output['funasr_aligned_pyannote'].append(scored(row,words,native_rows[row['id']]['diarization']))

summary={}
for alias,rows in output.items():
    summary[alias]={'cpwer':sum(r['cpwer']['errors'] for r in rows)/sum(r['cpwer']['reference_words'] for r in rows),
                    'wer':sum(r['wer']['errors'] for r in rows)/sum(r['wer']['reference_words'] for r in rows),
                    'same_normalized_words':all(r['same_normalized_words'] for r in rows),
                    'text_edit_differences':sum(r['normalization_edit_difference']['errors'] for r in rows),
                    'alignment_seconds':sum(r.get('alignment_seconds',0) for r in rows)}
(ROOT/'alignment-scores.json').write_text(json.dumps({'summary':summary,'rows':output},indent=2))
print(json.dumps(summary,indent=2))
