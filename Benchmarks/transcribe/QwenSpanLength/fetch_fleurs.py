"""Build ~5-minute multilingual pseudo-tracks from FLEURS dev utterances (CC-BY-4.0).

Streams each language's dev tarball and stops after the utterances it needs, so only a few
MB are downloaded. Utterances are joined with 0.8 s of silence. A code-switched track
alternates blocks of five English and five German utterances.
"""
import csv
import io
import json
import os
import tarfile
import wave
from pathlib import Path

import numpy as np
import requests

DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length')) / 'fleurs'
BASE = 'https://huggingface.co/datasets/google/fleurs/resolve/main/data/{lang}'
LANGS = {'de_de': 'de', 'ja_jp': 'ja', 'ru_ru': 'ru', 'sr_rs': 'sr', 'en_us': 'en'}
PER_TRACK = 30
GAP = np.zeros(int(0.8 * 16000), dtype=np.float32)


def transcripts(lang):
    text = requests.get(BASE.format(lang=lang) + '/dev.tsv', timeout=60).text
    rows = csv.reader(io.StringIO(text), delimiter='\t', quoting=csv.QUOTE_NONE)
    return {r[1]: r[2] for r in rows if len(r) > 2}  # file name -> raw transcription


def read_wav(data):
    """16 kHz mono WAV, PCM16 or IEEE float32 (FLEURS ships float)."""
    pos, fmt, rate, channels, bits = 12, None, None, None, None
    while pos + 8 <= len(data):
        tag, size = data[pos:pos + 4], int.from_bytes(data[pos + 4:pos + 8], 'little')
        body = data[pos + 8:pos + 8 + size]
        if tag == b'fmt ':
            fmt = int.from_bytes(body[0:2], 'little')
            channels = int.from_bytes(body[2:4], 'little')
            rate = int.from_bytes(body[4:8], 'little')
            bits = int.from_bytes(body[14:16], 'little')
        elif tag == b'data':
            assert rate == 16000 and channels == 1, (rate, channels)
            if fmt == 3 and bits == 32:
                return np.frombuffer(body, dtype='<f4').astype(np.float32)
            if fmt == 1 and bits == 16:
                return np.frombuffer(body, dtype='<i2').astype(np.float32) / 32768
            raise ValueError(f'unsupported WAV format {fmt}/{bits}')
        pos += 8 + size + (size & 1)
    raise ValueError('no data chunk')


def utterances(lang, count):
    names = transcripts(lang)
    got = []
    with requests.get(BASE.format(lang=lang) + '/audio/dev.tar.gz', stream=True, timeout=60) as response:
        response.raise_for_status()
        with tarfile.open(fileobj=response.raw, mode='r|gz') as tar:
            for member in tar:
                name = Path(member.name).name
                if not member.isfile() or name not in names:
                    continue
                got.append((read_wav(tar.extractfile(member).read()), names[name]))
                if len(got) >= count:
                    break
    return got


def write(path, samples):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes((np.clip(samples, -1, 1) * 32767).astype('<i2').tobytes())


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    pool = {code: utterances(lang, PER_TRACK) for lang, code in LANGS.items()}
    tracks = {code: pool[code] for code in ['de', 'ja', 'ru', 'sr']}
    mixed = []
    for k in range(0, PER_TRACK, 5):
        mixed += pool['en'][k:k + 5] + pool['de'][k:k + 5]
    tracks['en+de'] = mixed[:PER_TRACK]
    items = []
    for code, utts in tracks.items():
        audio = np.concatenate([np.concatenate([pcm, GAP]) for pcm, _ in utts])
        path = OUT / f'fleurs-{code}.wav'
        write(path, audio)
        items.append({'id': f'fleurs-{code}', 'wav': str(path), 'language': code,
                      'reference': ' '.join(t for _, t in utts), 'duration': round(len(audio) / 16000, 1)})
        print(f'fleurs-{code}: {len(utts)} utterances, {len(audio) / 16000 / 60:.1f} min')
    (OUT / 'items.json').write_text(json.dumps(items, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
