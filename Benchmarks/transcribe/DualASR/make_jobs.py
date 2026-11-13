"""Write the harness jobs: FLEURS tracks plus the owner's meeting tracks, Qwen and Whisper conditions.

Meeting audio is read in place from LokalBot's library (read only); nothing is copied.
Usage: make_jobs.py <qwen|whisper> [condition ...]
"""
import json
import os
import sys
from pathlib import Path

OUT = Path(os.environ['DUAL_ASR_OUT'])
LIBRARY = Path.home() / 'Library/Application Support/me.dotenv.LokalBot'
MEETINGS = os.environ.get('DUAL_ASR_MEETINGS', '2026/10/07-google-chrome-meeting').split(',')
QWEN = {'q-en': 'en', 'q-auto': None, 'q-vote': 'vote', 'q-vote-bcms': 'vote-bcms',
        'q-sr': 'sr', 'q-Serbian': 'Serbian', 'q-hr': 'hr'}
WHISPER = {'w-auto': None, 'w-sr': 'sr', 'w-hr': 'hr', 'w-bs': 'bs'}


def items():
    rows = [{'id': i['id'], 'wav': i['wav']} for i in json.loads((OUT / 'fleurs/items.json').read_text())]
    for meeting in MEETINGS:
        for track in ('mic', 'system'):
            path = LIBRARY / 'meetings' / meeting / f'{track}.m4a'
            if path.exists():
                rows.append({'id': f'meeting-{meeting.replace("/", "-")}-{track}', 'wav': str(path)})
    return rows


def main():
    engine, names = sys.argv[1], sys.argv[2:]
    table = QWEN if engine == 'qwen' else WHISPER
    conditions = [{'name': n, 'engine': engine, 'language': table[n]} for n in names or table]
    jobs = {
        'vadModel': str(Path.home() / 'Library/Application Support/FluidAudio/Models/silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc'),
        'output': str(OUT / 'runs.jsonl'),
        'qwenModelDir': str(LIBRARY / 'qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit'),
        'qwenModelId': 'aufklarer/Qwen3-ASR-1.7B-MLX-8bit',
        'whisperModelFolder': str(OUT / 'whisper/openai_whisper-large-v3-v20240930'),
        'whisperTokenizerFolder': str(OUT / 'whisper/tokenizer'),
        'items': items(), 'conditions': conditions,
    }
    path = OUT / f'jobs-{engine}.json'
    path.write_text(json.dumps(jobs, indent=1))
    print(f'{path}: {len(jobs["items"])} items, {len(conditions)} conditions')


if __name__ == '__main__':
    main()
