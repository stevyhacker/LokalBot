"""ASR diagnostic for narration takes (content check, not a listening score)."""
import json, re, subprocess
import numpy as np
from difflib import SequenceMatcher
from pathlib import Path
from faster_whisper import WhisperModel

P = Path(__file__).resolve().parent
spec = {s['id']: s for s in json.loads((P / 'narration.json').read_text())['scenes']}
model = WhisperModel('base.en', device='cpu', compute_type='int8', cpu_threads=4)

def words(t):
    t = t.lower().replace('coe-typist', 'cotypist').replace('coe-tabby', 'cotabby').replace('local bot', 'lokalbot')
    return re.findall(r"[a-z0-9']+", t)

rows = []
for wav in sorted((P / 'assets/voice/takes').glob('*.wav')):
    sid = wav.stem.rsplit('-s', 1)[0]
    pcm = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(wav), '-f', 'f32le', '-ac', '1', '-ar', '16000', '-'], check=True, capture_output=True).stdout
    segs, _ = model.transcribe(np.frombuffer(pcm, dtype=np.float32), language='en', beam_size=5, vad_filter=False)
    heard = ' '.join(s.text.strip() for s in segs)
    a, b = words(spec[sid]['text']), words(heard)
    ratio = SequenceMatcher(a=a, b=b, autojunk=False).ratio()
    rows.append({'take': wav.name, 'ratio': round(ratio, 3), 'heard': heard})
    print(f"{wav.name:24} {ratio:.3f}  {heard}", flush=True)
(P / 'production/narration-asr.json').write_text(json.dumps(rows, indent=2) + '\n')
