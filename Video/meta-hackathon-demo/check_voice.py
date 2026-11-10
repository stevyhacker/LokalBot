"""Transcribe each chosen take with faster-whisper and compare it to its text."""
import json
import re
import subprocess

import numpy as np
from pathlib import Path

from faster_whisper import WhisperModel

P = Path(__file__).resolve().parent
lines = {x['id']: x for x in json.loads((P / 'narration.json').read_text())['lines']}
model = WhisperModel('base.en', device='cpu', compute_type='int8')
norm = lambda s: re.sub(r"[^a-z0-9 ]", '', s.lower().replace('-', ' '))
out = []
for path in sorted((P / 'assets/voice').glob('*.mp3')):
    lid = path.stem.split('-s')[0]
    pcm = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-ac', '1', '-ar', '16000', '-'],
                         check=True, capture_output=True).stdout
    segments, _ = model.transcribe(np.frombuffer(pcm, np.float32), beam_size=5, initial_prompt='LokalBot, Muse Spark, Muse Wonder, Ana, Marko')
    heard = ' '.join(s.text.strip() for s in segments)
    want = lines[lid]['text']
    a, b = set(norm(want).split()), set(norm(heard).split())
    missing = sorted(a - b)
    out.append({'file': path.name, 'heard': heard, 'missing': missing})
    print(f"{path.name}: {'OK' if not missing else 'CHECK ' + str(missing)} | {heard}")
(P / 'production/voice-asr.json').write_text(json.dumps(out, indent=1, ensure_ascii=False) + '\n')
