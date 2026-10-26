"""Select a fixed small sample, before candidate inference; never write to the library.

Usage: prepare.py OUT BCMS_MEETING_FOLDER ENGLISH_MEETING_FOLDER
All clips and ASR references are private and stay in OUT. Stored transcripts are
machine-generated comparison references, not human-verified ground truth.
"""
import hashlib
import json
import subprocess
import sys
import re
import wave
from pathlib import Path

out = Path(sys.argv[1])
(out / 'clips').mkdir(parents=True, exist_ok=True)
clips = []
for group, folder in zip(('bcms', 'english'), map(Path, sys.argv[2:4])):
    transcript = json.loads((folder / 'transcript.json').read_text())
    for source, track in [('microphone', 'mic'), ('system', 'system')]:
        # At least 10 seconds and 20 words; distribute picks through eligible
        # speech, without inspecting or selecting any candidate model output.
        eligible = sorted([
            s for s in transcript['segments']
            if s.get('attribution', {}).get('source') == source
            and 10 <= s['end'] - s['start'] <= 25
            and len(s['text'].split()) >= 20
        ], key=lambda s: s['start'])
        if len(eligible) < 2:
            raise RuntimeError(f'Not enough speech in {group}/{track}')
        for i, index in enumerate([len(eligible) // 3, 2 * len(eligible) // 3]):
            s = eligible[index]
            clip_id = f'{group}-{track}-{i + 1}'
            wav = out / 'clips' / f'{clip_id}.wav'
            subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y',
                '-ss', str(s['start']), '-i', str(folder / f'{track}.m4a'),
                '-t', str(s['end'] - s['start']), '-ac', '1', '-ar', '16000',
                '-c:a', 'pcm_s16le', str(wav)], check=True)
            clips.append({'id': clip_id, 'group': group, 'wav': str(wav),
                'source': str(folder / f'{track}.m4a'), 'start': s['start'], 'end': s['end'],
                'reference': s['text'], 'referenceEngine': transcript['engine'],
                'referenceKind': 'stored ASR output, not ground truth',
                'sha256': hashlib.sha256(wav.read_bytes()).hexdigest()})
fixture = Path(__file__).resolve().parents[2] / 'LokalBotTests/Fixtures/LiveTranscript'
control = fixture / 'continuous-speech.wav'
reference = re.search(r'Text: “(.+?)”', (fixture / 'README.md').read_text()).group(1)
with wave.open(str(control)) as audio:
    duration = audio.getnframes() / audio.getframerate()
clips.append({'id': 'english-synthetic-control', 'group': 'control', 'wav': str(control),
    'source': str(control), 'start': 0, 'end': duration, 'reference': reference,
    'referenceEngine': 'known macOS say script', 'referenceKind': 'known synthetic speech script',
    'sha256': hashlib.sha256(control.read_bytes()).hexdigest()})
(out / 'clips.json').write_text(json.dumps(clips, indent=2, ensure_ascii=False))
print(json.dumps({'clips': len(clips), 'seconds': sum(c['end'] - c['start'] for c in clips),
                  'manifest': str(out / 'clips.json')}))
