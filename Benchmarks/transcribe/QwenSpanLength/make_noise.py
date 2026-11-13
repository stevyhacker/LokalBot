"""Speech-free audio from real meeting tracks: the gaps between benchmark chunks.

prepare.py cut chunks where Silero (threshold 0.5) found speech, merging pauses <= 5 s, so the
gaps between chunks are stretches that more sensitive VAD judged speech-free. Every word an
engine decodes here is a false alarm. Gaps of 6 s or more, trimmed 0.5 s per side, up to 10
minutes per track.
"""
import json
import os
import subprocess
import wave
from pathlib import Path

import numpy as np

DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length')) / 'noise'
OUT.mkdir(exist_ok=True)
manifest = [r for r in json.loads((DATA / 'manifest.json').read_text()) if r['set'] == 'meetings']
items = []
for m in sorted({r['source'] for r in manifest}):
    folder = subprocess.run(['lokalbot-cli', 'path', m], check=True, capture_output=True, text=True).stdout.strip()
    for track in ['mic', 'system']:
        raw = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', f'{folder}/{track}.m4a', '-ac', '1', '-ar', '16000',
                              '-f', 'f32le', '-'], check=True, capture_output=True).stdout
        audio = np.frombuffer(raw, dtype='<f4')
        total = len(audio) / 16000
        chunks = sorted((r['start'], r['end']) for r in manifest if r['source'] == m and r['track'] == track)
        edges = [0.0] + [x for c in chunks for x in c] + [total]
        gaps = [(a + 0.5, b - 0.5) for a, b in zip(edges[0::2], edges[1::2]) if b - a >= 6]
        pieces, seconds = [], 0.0
        for a, b in gaps:
            if seconds >= 600: break
            b = min(b, a + 600 - seconds)
            pieces.append(audio[int(a * 16000):int(b * 16000)])
            seconds += b - a
        if seconds < 5: continue
        clip = np.concatenate(pieces)
        path = OUT / f'noise-{m}-{track}.wav'
        with wave.open(str(path), 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes((np.clip(clip, -1, 1) * 32767).astype('<i2').tobytes())
        rms = float(np.sqrt(np.mean(clip ** 2)))
        items.append({'id': f'noise-{m}-{track}', 'wav': str(path), 'duration': round(seconds, 1), 'rms': rms})
        print(f'{m} {track}: {len(gaps)} gaps, {seconds / 60:.1f} min kept, rms {20 * np.log10(max(rms, 1e-9)):.0f} dBFS')
(OUT / 'items.json').write_text(json.dumps(items, indent=1))
