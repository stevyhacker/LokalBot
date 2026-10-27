#!/usr/bin/env python3
"""Generate the music bed and sound effects with ElevenLabs.

  python3 eleven_sound.py --env-file ~/path/to/.env [--only bed-a,tab]

Python standard library only. Prompts are in sound.json. The key comes from
ELEVENLABS_API_KEY or ELEVEN_LABS_API_KEY in the environment or the --env-file
(only that line is read); it is never printed or written anywhere.

Writes assets/sound/eleven/<id>.mp3 (effects with variants get -v1, -v2, ...)
and production/eleven-sound.json (prompts, models, files; no key). Each call
costs credits, so --only regenerates just the named ones.
"""
import argparse
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
API = 'https://api.elevenlabs.io/v1'
MUSIC_MODELS = ['music_v2_5', 'music_v1']
EFFECT_MODELS = ['eleven_text_to_sound_v3', 'eleven_text_to_sound_v2']


def key_from(env_file):
    for name in ('ELEVENLABS_API_KEY', 'ELEVEN_LABS_API_KEY'):
        if os.environ.get(name):
            return os.environ[name]
    if env_file:
        for line in Path(env_file).expanduser().read_text().splitlines():
            name, _, value = line.strip().removeprefix('export ').partition('=')
            if name.strip() in ('ELEVENLABS_API_KEY', 'ELEVEN_LABS_API_KEY'):
                return value.strip().strip('"').strip("'")
    raise SystemExit('No ELEVENLABS_API_KEY or ELEVEN_LABS_API_KEY in the environment or the --env-file')


def post(key, path, body, models):
    """POST with the first model the account accepts; returns (audio, model, headers)."""
    for model in models:
        request = urllib.request.Request(f'{API}/{path}', json.dumps({**body, 'model_id': model}).encode(),
                                         {'xi-api-key': key, 'Content-Type': 'application/json'})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request, timeout=600) as response:
                    return response.read(), model, dict(response.headers)
            except urllib.error.HTTPError as e:
                message = e.read().decode(errors='replace')[:300]
                if e.code in (429, 500, 502, 503) and attempt < 2:
                    time.sleep(4 * (attempt + 1))
                    continue
                if e.code in (400, 403, 422) and model != models[-1]:
                    print(f'{model} refused ({e.code}: {message}); trying {models[models.index(model) + 1]}', flush=True)
                    break
                raise SystemExit(f'HTTP {e.code} for {path}: {message}')
    raise SystemExit(f'no model accepted {path}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--env-file')
    parser.add_argument('--only', default='')
    args = parser.parse_args()
    spec = json.loads((HERE / 'sound.json').read_text())
    key = key_from(args.env_file)
    only = set(filter(None, args.only.split(',')))
    out = HERE / 'assets' / 'sound' / 'eleven'
    out.mkdir(parents=True, exist_ok=True)
    report_path = HERE / 'production' / 'eleven-sound.json'
    report_path.parent.mkdir(exist_ok=True)
    report = json.loads(report_path.read_text()) if report_path.exists() else {'rows': []}

    def keep(row, audio):
        path = out / row['file']
        path.write_bytes(audio)
        row.update(file=str(path.relative_to(HERE)), bytes=len(audio), sha256=hashlib.sha256(audio).hexdigest())
        report['rows'] = [r for r in report['rows'] if r['file'] != row['file']] + [row]
        report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
        print(f"{row['file']}  {row['model']}  {len(audio) / 1024:.0f} KB", flush=True)

    for music in spec['music']:
        if only and music['id'] not in only:
            continue
        body = {'prompt': music['prompt'], 'music_length_ms': spec['music_length_ms'], 'force_instrumental': True}
        audio, model, headers = post(key, 'music', body, MUSIC_MODELS)
        keep({'id': music['id'], 'kind': 'music', 'model': model, 'prompt': music['prompt'],
              'length_ms': spec['music_length_ms'], 'song_id': headers.get('song-id'), 'file': f"{music['id']}.mp3"}, audio)
    for effect in spec['effects']:
        if only and effect['id'] not in only:
            continue
        n = effect.get('variants', 1)
        for v in range(1, n + 1):
            body = {'text': effect['text'], 'duration_seconds': effect['duration'], 'prompt_influence': effect['influence']}
            audio, model, _ = post(key, 'sound-generation', body, EFFECT_MODELS)
            name = f"{effect['id']}-v{v}.mp3" if n > 1 else f"{effect['id']}.mp3"
            keep({'id': effect['id'], 'kind': 'effect', 'variant': v, 'model': model, 'prompt': effect['text'],
                  'duration': effect['duration'], 'file': name}, audio)


if __name__ == '__main__':
    main()
