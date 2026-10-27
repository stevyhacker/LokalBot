#!/usr/bin/env python3
"""Generate the voiceover with a text-to-speech API.

  python3 tts.py --env-file ~/path/to/.env --engine drama3 [--voices adrian,delia] [--takes 2] [--only 01-hook]

Python standard library only (ffprobe, if present, for mp3 durations).
Engines:
  openai  OpenAI gpt-4o-mini-tts, OPENAI_API_KEY, voices cedar and marin.
          The voice direction goes in `instructions`.
  drama3  Fish Audio Drama 3 through OpenRouter, OPENROUTER_API_KEY, Fish's
          stock voices Adrian and Delia. The direction goes in brackets
          before the line, as Drama 3 expects.
The key comes from the environment or the --env-file (only its one line is
read); it is never printed or written anywhere. Each line of narration.json
is spoken in each voice a few times, so the best take can be picked.

Writes assets/voice/<engine>/<voice>/<id>-t<take>.<wav|mp3> and
production/<engine>-generation.json (text, voice, take, file, duration; no
key). Word timings come afterwards from word_timings.py.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINES = {
    'openai': {'url': 'https://api.openai.com/v1/audio/speech', 'key': 'OPENAI_API_KEY', 'model': 'gpt-4o-mini-tts',
               'format': 'pcm', 'voices': {'cedar': 'cedar', 'marin': 'marin'}},
    'drama3': {'url': 'https://openrouter.ai/api/v1/audio/speech', 'key': 'OPENROUTER_API_KEY', 'model': 'fish-audio/drama-3',
               'format': 'mp3', 'voices': {'adrian': 'bf322df2096a46f18c579d0baa36f41d', 'delia': 'c70cfb98867a4bfb9ae20d2401257b92'}},
}


def key_from(name, env_file):
    if os.environ.get(name):
        return os.environ[name]
    if env_file:
        for line in Path(env_file).expanduser().read_text().splitlines():
            key, _, value = line.strip().removeprefix('export ').partition('=')
            if key.strip() == name:
                return value.strip().strip('"').strip("'")
    raise SystemExit(f'No {name} in the environment or the --env-file')


def speak(engine, key, payload):
    request = urllib.request.Request(engine['url'], json.dumps(payload).encode(),
                                     {'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors='replace')[:300]
            if e.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise SystemExit(f'HTTP {e.code} for {payload["voice"]}: {body}')
        except urllib.error.URLError:
            if attempt == 3:
                raise
            time.sleep(2 ** (attempt + 1))


def duration_of(path):
    if path.suffix == '.wav':
        with wave.open(str(path)) as w:
            return w.getnframes() / w.getframerate()
    if shutil.which('ffprobe'):
        out = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(path)],
                             capture_output=True, text=True).stdout.strip()
        return float(out) if out else None
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--env-file')
    parser.add_argument('--engine', choices=ENGINES, default='drama3')
    parser.add_argument('--voices', default='')
    parser.add_argument('--takes', type=int, default=2)
    parser.add_argument('--only', default='')
    args = parser.parse_args()
    engine = ENGINES[args.engine]
    spec = json.loads((HERE / 'narration.json').read_text())
    key = key_from(engine['key'], args.env_file)
    only = set(filter(None, args.only.split(',')))
    voices = args.voices.split(',') if args.voices else list(engine['voices'])
    report_path = HERE / 'production' / f'{args.engine}-generation.json'
    report_path.parent.mkdir(exist_ok=True)
    report = json.loads(report_path.read_text()) if report_path.exists() else {'rows': []}
    report.update({'model': engine['model'], 'voice_direction': spec['voice_direction']})
    for voice in voices:
        folder = HERE / 'assets' / 'voice' / args.engine / voice
        folder.mkdir(parents=True, exist_ok=True)
        for scene in spec['scenes']:
            if only and scene['id'] not in only:
                continue
            text = scene.get('spoken', scene['caption'])
            payload = {'model': engine['model'], 'voice': engine['voices'].get(voice, voice), 'response_format': engine['format']}
            if args.engine == 'openai':
                payload.update(input=text, instructions=spec['voice_direction'])
            else:
                payload['input'] = f"[{spec['drama_direction']}] {text}"
            for take in range(1, args.takes + 1):
                audio = speak(engine, key, payload)
                if engine['format'] == 'pcm':
                    # Raw 24 kHz 16-bit mono; the WAV header is written here, since a streamed one has no length.
                    path = folder / f"{scene['id']}-t{take}.wav"
                    with wave.open(str(path), 'wb') as w:
                        w.setnchannels(1)
                        w.setsampwidth(2)
                        w.setframerate(24000)
                        w.writeframes(audio)
                else:
                    path = folder / f"{scene['id']}-t{take}.{engine['format']}"
                    path.write_bytes(audio)
                duration = duration_of(path)
                row = {'id': scene['id'], 'voice': voice, 'take': take, 'text': payload['input'],
                       'file': str(path.relative_to(HERE)), 'duration': duration and round(duration, 3),
                       'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                report['rows'] = [r for r in report['rows'] if (r['id'], r['voice'], r['take']) != (scene['id'], voice, take)]
                report['rows'].append(row)
                print(f"{voice:6s} {scene['id']:11s} t{take}  {duration or 0:5.2f} s", flush=True)
    report['rows'].sort(key=lambda r: (r['voice'], r['id'], r['take']))
    report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
