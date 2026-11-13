"""Shared paths, system registry and helpers for the cloud STT benchmark."""
import json
import os
from pathlib import Path
import wave

import numpy as np

ROOT = Path(__file__).resolve().parent
# Private audio, transcripts and raw responses live outside the repository.
DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
KEY_FILE = Path(os.environ.get('STT_BENCH_KEYS', Path.home() / '.config/lokalbot-stt-bench.env'))
SAMPLE_RATE = 16_000
LANGUAGE = 'en'

# id -> (family, kind, label). Families group correlated systems for the
# leave-family-out consensus used on unlabeled meeting audio.
SYSTEMS = {
    'gpt-transcribe': ('openai', 'api', 'OpenAI GPT Transcribe'),
    'gpt-4o-transcribe': ('openai', 'api', 'OpenAI GPT-4o Transcribe'),
    'gpt-4o-mini-transcribe': ('openai', 'api', 'OpenAI GPT-4o mini Transcribe'),
    'gemini-3.5-transcribe': ('google', 'api', 'Google Gemini 3.5 Transcribe'),
    'gemini-3.8-flash': ('google', 'api', 'Google Gemini 3.8 Flash (prompted)'),
    'qwen-audio-3.1-asr-flash': ('qwen', 'api', 'Alibaba Qwen-Audio 3.1 ASR Flash'),
    'qwen3-asr-flash': ('qwen', 'api', 'Alibaba Qwen3-ASR Flash'),
    'local-qwen3-asr-1.7b': ('qwen', 'local', 'Qwen3-ASR 1.7B 8-bit, local (LokalBot default)'),
    'local-parakeet-v3': ('nvidia', 'local', 'Parakeet TDT 0.6B v3, local'),
    # Scored on meetings only; never a consensus voter.
    'lokalbot-app': ('qwen', 'production', 'LokalBot app transcript (Qwen3-ASR 1.7B, full pipeline)'),
}


def load_manifest():
    return json.loads((DATA / 'manifest.json').read_text())


def output_path(system, chunk_id):
    return DATA / 'outputs' / system / f'{chunk_id}.json'


def load_output(system, chunk_id):
    path = output_path(system, chunk_id)
    return json.loads(path.read_text()) if path.exists() else None


def save_output(system, chunk_id, record):
    path = output_path(system, chunk_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(record, indent=1, ensure_ascii=False))
    tmp.replace(path)


def write_wav(path, samples):
    """Write float samples in [-1, 1] as 16 kHz mono 16-bit PCM."""
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(samples, -1, 1) * 32767).astype('<i2')
    with wave.open(str(path), 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(pcm.tobytes())


def read_keys():
    """Load API keys from the private env file without echoing them."""
    keys = {}
    if KEY_FILE.exists():
        for line in KEY_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            name, value = line.split('=', 1)
            name = name.removeprefix('export ').strip()
            keys[name] = value.strip().strip('"').strip("'")
    for name in ['OPENAI_API_KEY', 'GEMINI_API_KEY', 'DASHSCOPE_API_KEY', 'DASHSCOPE_BASE_URL']:
        if os.environ.get(name):
            keys[name] = os.environ[name]
    return keys
