import dataclasses
import json
import os
import pathlib
import time

ROOT = pathlib.Path(__file__).parent
os.environ['HF_HOME'] = str(ROOT/'hf-cache')
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
import soundfile as sf
import torch
from qwen_asr import Qwen3ForcedAligner
from measure_memory import measure

assert torch.backends.mps.is_available()
fixture = json.loads((ROOT/'fixture.json').read_text())
native = json.loads((ROOT/'native.json').read_text())
clips = {c['id']:c for c in fixture['clips']}
start = time.perf_counter()
model = Qwen3ForcedAligner.from_pretrained(str(ROOT/'models/Qwen/Qwen3-ForcedAligner-0.6B'),
                                          device_map='mps', dtype=torch.bfloat16)
torch.mps.synchronize()
report = {'load_seconds':time.perf_counter()-start,'rows':[]}
for row in native['rows']:
    clip = clips[row['id']]
    if clip['kind'] != 'meeting': continue
    audio, sr = sf.read(clip['audio'],dtype='float32')
    words=[]; starts=time.perf_counter()
    for segment in row['segments']:
        chunk = audio[round(segment['start']*sr):round(segment['end']*sr)]
        result=model.align(audio=(chunk,sr),text=segment['text'],language='English')[0]
        for word in result.items:
            words.append({'text':word.text,'start':segment['start']+word.start_time,
                          'end':segment['start']+word.end_time})
    torch.mps.synchronize()
    seconds=time.perf_counter()-starts
    report['rows'].append({'id':row['id'],'seconds':seconds,'words':words})
    report['os_memory']=measure(os.getpid())
    (ROOT/'native-alignment.json').write_text(json.dumps(report,indent=2))
    print('ALIGNED',row['id'],len(words),'words',round(seconds,3),'seconds',flush=True)
