import argparse
import copy
import dataclasses
import json
import os
import pathlib
import resource
import time
import traceback

ROOT = pathlib.Path(__file__).parent
os.environ['HF_HOME'] = str(ROOT/'hf-cache')
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['MODELSCOPE_CACHE'] = str(ROOT/'modelscope-cache')
os.environ['MPLCONFIGDIR'] = str(ROOT/'mpl-cache')
import numpy as np
import soundfile as sf
import torch
from funasr import AutoModel
import funasr.auto.auto_model as auto_module

parser = argparse.ArgumentParser()
parser.add_argument('--smoke', action='store_true')
parser.add_argument('--memory-probe', action='store_true')
args = parser.parse_args()
assert torch.backends.mps.is_available(), 'Apple GPU unavailable; refuse CPU fallback comparison'
fixture = json.loads((ROOT/'fixture.json').read_text())
report = {'torch': torch.__version__, 'device': 'mps', 'dtype': 'bf16', 'rows': []}
report_path = ROOT/('funasr-smoke.json' if args.smoke else 'funasr.json')
if args.memory_probe:
    report_path = ROOT/'funasr-memory-probe.json'

def save():
    report_path.write_text(json.dumps(report, indent=2))

def sync():
    torch.mps.synchronize()

captured = {'turns': [], 'alignment': [], 'qwen_seconds': 0.0, 'align_seconds': 0.0}
original_postprocess = auto_module.postprocess
def postprocess(*a, **kw):
    result = original_postprocess(*a, **kw)
    captured['turns'] = result
    return result
auto_module.postprocess = postprocess

try:
    started = time.perf_counter()
    model = AutoModel(
        model='Qwen3ASR', model_conf={}, model_path=str(ROOT/'models/Qwen/Qwen3-ASR-1.7B'),
        device='mps', dtype='bf16', hub='hf', ncpu=4,
        max_inference_batch_size=1, max_new_tokens=512,
        forced_aligner=str(ROOT/'models/Qwen/Qwen3-ForcedAligner-0.6B'),
        vad_model=str(ROOT/'models/funasr/fsmn-vad'),
        vad_kwargs={'max_single_segment_time': 15000},
        spk_model=str(ROOT/'models/funasr/campplus'), spk_mode='vad_segment',
        disable_update=True, disable_pbar=True, log_level='WARNING')
    sync()
    report['load_seconds'] = time.perf_counter()-started
    qwen = model.model.qwen3_asr_model
    report['actual_model_device'] = str(qwen.model.device)
    report['actual_model_dtype'] = str(qwen.model.dtype)
    original_transcribe = qwen.transcribe
    original_align = qwen.forced_aligner.align
    def align(*a, **kw):
        t = time.perf_counter(); result = original_align(*a, **kw); sync()
        captured['align_seconds'] += time.perf_counter()-t
        return result
    qwen.forced_aligner.align = align
    def transcribe(*a, **kw):
        t = time.perf_counter(); result = original_transcribe(*a, **kw); sync()
        captured['qwen_seconds'] += time.perf_counter()-t
        for r in result:
            if r.time_stamps is not None:
                captured['alignment'].append({'text': r.text, 'words': [dataclasses.asdict(w) for w in r.time_stamps.items]})
        return result
    qwen.transcribe = transcribe

    def run(clip, warmup=False):
        captured.update(turns=[], alignment=[], qwen_seconds=0.0, align_seconds=0.0)
        audio, sr = sf.read(clip['audio'], dtype='float32'); assert sr == 16000
        sync(); started = time.perf_counter()
        if clip['kind'] == 'meeting':
            results = model.generate(input=audio, language='English', batch_size_s=15,
                                     return_time_stamps=True, return_spk_res=True, merge_vad=False)
            result = results[0]
        else:
            # Reuse the exact native VAD spans to isolate recognition/runtime effects.
            native = json.loads((ROOT/'native.json').read_text())
            spans = next(r['spans'] for r in native['rows'] if r['id'] == clip['id'])
            parts = []
            for span in spans:
                chunk = audio[round(span['start']*sr):round(span['end']*sr)]
                if not len(chunk): continue
                qwen.max_new_tokens = min(768, max(128, int(len(chunk)/sr*18)))
                out = model.inference(input=chunk, model=model.model, kwargs=copy.deepcopy(model.kwargs),
                                      language='English', return_time_stamps=False, output_timestamp=False)
                parts.append(out[0]['text'])
            result = {'text': ' '.join(parts)}
        sync(); seconds = time.perf_counter()-started
        row = {'id': clip['id'], 'kind': clip['kind'], 'warmup': warmup, 'duration': clip['duration'],
               'seconds': seconds, 'qwen_seconds': captured['qwen_seconds'],
               'align_seconds': captured['align_seconds'],
               'max_rss_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
               'mps_current_bytes': torch.mps.current_allocated_memory(),
               'mps_driver_bytes': torch.mps.driver_allocated_memory(),
               'text': result['text'], 'result': result,
               'diarization': [{'start': float(t[0]), 'end': float(t[1]), 'speaker': str(t[2])} for t in captured['turns']],
               'raw_alignment_seconds': captured['alignment']}
        print('FUNASR', clip['id'], round(seconds,3), 'seconds', len(result['text']), 'characters', flush=True)
        return row

    if args.smoke:
        first = next(c for c in fixture['clips'] if c['kind']=='clip')
        audio, sr = sf.read(first['audio'], dtype='float32')
        t = time.perf_counter()
        result = model.inference(input=audio, language='English', return_time_stamps=True)
        sync()
        report['smoke'] = {'id': first['id'], 'seconds': time.perf_counter()-t,
                           'result': result, 'raw_alignment_seconds': captured['alignment']}
        save()
        print('SMOKE', json.dumps(report['smoke']), flush=True)
    else:
        report['warmup'] = run(fixture['clips'][0], True); save()
        for clip in fixture['clips'][:1] if args.memory_probe else fixture['clips']:
            report['rows'].append(run(clip)); save()
    from measure_memory import measure
    report['os_memory'] = measure(os.getpid()); save()
except Exception:
    report['error'] = traceback.format_exc(); save()
    raise
