"""Cloud reference transcripts for the meeting windows, one Gemini request per decode window.

Gemini 3.5 Transcribe rejected every request on 2026-10-07 ("Thinking is not enabled for this
model"), so `--model gemini-3.8-flash` prompts a general Gemini model for a verbatim transcript
at temperature 0 instead. That model invented speech on short quiet clips in Benchmarks/transcribe/CloudSTT,
so it is calibrated on the FLEURS windows before its meeting references are used.

Also transcribes the FLEURS Serbian and mostly-Serbian windows, whose human references
measure how far the cloud reference itself can be trusted. Keys come from
~/.config/lokalbot-stt-bench.env (GEMINI_API_KEY), as in Benchmarks/transcribe/CloudSTT. Window audio
is written to the private output folder only. Resumable.
Usage: make_refs.py [--limit N]
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np
import requests

OUT = Path(os.environ['DUAL_ASR_OUT'])
GEMINI = 'https://generativelanguage.googleapis.com'
MODEL = sys.argv[sys.argv.index('--model') + 1] if '--model' in sys.argv else 'gemini-3.5-transcribe'
PROMPT = ('Generate a verbatim transcript of the speech in this audio. Write only the spoken words in their '
          'original language, keeping repetitions and false starts, with normal punctuation. Do not translate. '
          'Do not add speaker labels, timestamps, headings, descriptions of non-speech sounds, or commentary. '
          'If there is no intelligible speech, return an empty response.')
CALIBRATION = ('fleurs-sr', 'fleurs-sr+en')
KEY_PATTERN = re.compile(r'(AIza[0-9A-Za-z_\-]{8,})')


def key():
    env = Path.home() / '.config/lokalbot-stt-bench.env'
    for line in env.read_text().splitlines() if env.exists() else []:
        if line.startswith('GEMINI_API_KEY='):
            return line.split('=', 1)[1].strip().strip('"')
    return os.environ['GEMINI_API_KEY']


def pcm16(path):
    if path.suffix != '.wav':
        wav = OUT / 'clips' / (path.parent.name + '-' + path.stem + '.wav')
        if not wav.exists():
            wav.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(path), str(wav)], check=True)
        path = wav
    with wave.open(str(path)) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
        return np.frombuffer(w.readframes(w.getnframes()), dtype='<i2')


def write(path, samples):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(samples.tobytes())


def check(response):
    if response.status_code >= 400:
        raise RuntimeError(f'{response.status_code}: {KEY_PATTERN.sub("<key>", response.text[:400])}')
    return response


def prompted(path, api_key):
    audio = base64.b64encode(path.read_bytes()).decode()
    data = check(requests.post(
        f'{GEMINI}/v1beta/models/{MODEL}:generateContent', headers={'x-goog-api-key': api_key},
        json={'contents': [{'parts': [{'inline_data': {'mime_type': 'audio/wav', 'data': audio}}, {'text': PROMPT}]}],
              'generationConfig': {'temperature': 0}}, timeout=600)).json()
    candidate = (data.get('candidates') or [{}])[0]
    return ' '.join(p['text'] for p in candidate.get('content', {}).get('parts', [])
                    if p.get('text') and not p.get('thought'))


def transcribe(path, api_key, language_codes):
    if MODEL != 'gemini-3.5-transcribe':
        return prompted(path, api_key)
    size = path.stat().st_size
    start = check(requests.post(
        f'{GEMINI}/upload/v1beta/files',
        headers={'x-goog-api-key': api_key, 'X-Goog-Upload-Protocol': 'resumable', 'X-Goog-Upload-Command': 'start',
                 'X-Goog-Upload-Header-Content-Length': str(size), 'X-Goog-Upload-Header-Content-Type': 'audio/wav',
                 'Content-Type': 'application/json'},
        json={'file': {'display_name': path.stem}}, timeout=120))
    info = check(requests.post(start.headers['X-Goog-Upload-URL'], headers={
        'X-Goog-Upload-Offset': '0', 'X-Goog-Upload-Command': 'upload, finalize', 'Content-Length': str(size)},
        data=path.read_bytes(), timeout=300)).json()['file']
    for _ in range(60):
        if info.get('state', 'ACTIVE') == 'ACTIVE':
            break
        time.sleep(1)
        info = check(requests.get(f'{GEMINI}/v1beta/{info["name"]}', headers={'x-goog-api-key': api_key}, timeout=60)).json()
    try:
        body = {'model': MODEL, 'input': [{'type': 'audio', 'uri': info['uri'], 'mime_type': 'audio/wav'}]}
        if language_codes:
            body['generation_config'] = {'transcription_config': {'language_codes': language_codes}}
        data = check(requests.post(f'{GEMINI}/v1beta/interactions', headers={'x-goog-api-key': api_key},
                                   json=body, timeout=600)).json()
    finally:
        requests.delete(f'{GEMINI}/v1beta/{info["name"]}', headers={'x-goog-api-key': api_key}, timeout=60)
    if isinstance(data.get('output_text'), str):
        return data['output_text']
    parts = [c['text'] for step in data.get('steps') or data.get('outputs') or []
             for c in step.get('content') or [step] if c.get('type') == 'text' and c.get('text')]
    return ' '.join(parts)


def main():
    limit = int(sys.argv[sys.argv.index('--limit') + 1]) if '--limit' in sys.argv else None
    runs = [json.loads(l) for l in (OUT / 'runs.jsonl').read_text().splitlines()]
    jobs = json.loads((OUT / 'jobs-qwen-1.json').read_text())
    wavs = {i['id']: Path(i['wav']) for i in jobs['items']}
    windows = {}
    for r in runs:
        if (r['id'].startswith('meeting-') and '--only-fleurs' not in sys.argv) or r['id'] in CALIBRATION:
            windows.setdefault(r['id'], [(w['start'], w['end']) for w in r['windows']])
    out_path = OUT / 'refs.jsonl'
    done = {(r['id'], r['window']) for r in map(json.loads, out_path.read_text().splitlines())} if out_path.exists() else set()
    api_key = key()
    codes = ['sr-RS', 'en-US']
    sent = 0
    for item, spans in sorted(windows.items()):
        audio = pcm16(wavs[item])
        for k, (start, end) in enumerate(spans):
            if (item, k) in done or (limit is not None and sent >= limit):
                continue
            clip = OUT / 'clips' / f'{item}-{k:03d}.wav'
            clip.parent.mkdir(parents=True, exist_ok=True)
            write(clip, audio[int(start * 16000):int(end * 16000)])
            for attempt in range(6):
                try:
                    text = transcribe(clip, api_key, codes)
                    break
                except RuntimeError as exc:
                    if 'language' in str(exc).lower() and codes and MODEL == 'gemini-3.5-transcribe':
                        print(f'language codes rejected, retrying without: {exc}')
                        codes = None
                        continue
                    wait = 2 ** (attempt + 2)
                    print(f'{item} {k}: {exc}; retry in {wait}s', flush=True)
                    time.sleep(wait)
            else:
                text = None
            with open(out_path, 'a') as f:
                f.write(json.dumps({'id': item, 'window': k, 'start': start, 'end': end, 'model': MODEL,
                                    'languageCodes': codes, 'text': text}, ensure_ascii=False) + '\n')
            sent += 1
            print(f'{item} {k}: {(text or "")[:80]}', flush=True)
            time.sleep(60 / 9)


if __name__ == '__main__':
    main()
