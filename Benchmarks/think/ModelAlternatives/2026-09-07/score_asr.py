"""Score both literal and standard Whisper-normalized WER without new inference."""
import json
from pathlib import Path
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer
import run as bench

normalizer=EnglishTextNormalizer(json.loads((bench.ROOT/'english-spelling.json').read_text()))
results={}
for alias in ['granite4-q4','granite4-q8','granite5']:
    data=json.loads((bench.ROOT/'results'/f'{alias}-asr.json').read_text())
    normalized=[]
    for row in data['rows']:
        ref,hyp=normalizer(row['reference']).split(),normalizer(row['text']).split()
        normalized.append({**row,'reference_words':len(ref),'edit_distance':bench.edit_distance(ref,hyp),
                           'normalized_reference':' '.join(ref),'normalized_hypothesis':' '.join(hyp)})
    summary=bench.score_asr(normalized)
    results[alias]={'literal':data['summary'],'whisper_normalized':summary,'runtime':data['runtime'],
                    'warmup_seconds':data['warmup_seconds'],'normalized_rows':normalized}
    print(alias,json.dumps(summary),flush=True)
bench.save('asr-comparison',results)
