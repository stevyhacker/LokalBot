#!/usr/bin/env python3
"""Generate the voiceover with OpenAI's text-to-speech.

  python3 tts_openai.py --env-file ~/path/to/.env [--voices cedar,marin] [--takes 2] [--only 01-hook]

Python standard library only. Reads OPENAI_API_KEY from the environment, or
from the --env-file (only that one line is read; the key is never printed or
written anywhere). Each line of narration.json is spoken with the voice
direction, in each voice, a few times, so the best take can be picked.

Writes assets/voice/openai/<voice>/<id>-t<take>.wav and
production/openai-generation.json (text, voice, take, file, duration; no key).
Word timings come afterwards from word_timings.py.
"""
import argparse
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = 'gpt-4o-mini-tts'
URL = 'https://api.openai.com/v1/audio/speech'


def key_from(env_file):
    if os.environ.get('OPENAI_API_KEY'):
        return os.environ['OPENAI_API_KEY']
    if env_file:
        for line in Path(env_file).expanduser().read_text().splitlines():
            name, _, value = line.strip().removeprefix('export ').partition('=')
            if name.strip() == 'OPENAI_API_KEY':
                return value.strip().strip('"').strip("'")
    raise SystemExit('No OPENAI_API_KEY in the environment or the --env-file')


def speak(key, text, voice, direction):
    # Raw 24 kHz 16-bit mono; the WAV header is written here, since a streamed one has no length.
    payload = {'model': MODEL, 'input': text, 'voice': voice, 'instructions': direction, 'response_format': 'pcm'}
    request = urllib.request.Request(URL, json.dumps(payload).encode(),
                                     {'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors='replace')[:300]
            if e.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise SystemExit(f'HTTP {e.code} for {voice}: {body}')
        except urllib.error.URLError:
            if attempt == 3:
                raise
            time.sleep(2 ** (attempt + 1))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--env-file')
    parser.add_argument('--voices', default='cedar,marin')
    parser.add_argument('--takes', type=int, default=2)
    parser.add_argument('--only', default='')
    args = parser.parse_args()
    spec = json.loads((HERE / 'narration.json').read_text())
    key = key_from(args.env_file)
    only = set(filter(None, args.only.split(',')))
    report_path = HERE / 'production' / 'openai-generation.json'
    report_path.parent.mkdir(exist_ok=True)
    report = json.loads(report_path.read_text()) if report_path.exists() else {'rows': []}
    report.update({'model': MODEL, 'voice_direction': spec['voice_direction']})
    for voice in args.voices.split(','):
        folder = HERE / 'assets' / 'voice' / 'openai' / voice
        folder.mkdir(parents=True, exist_ok=True)
        for scene in spec['scenes']:
            if only and scene['id'] not in only:
                continue
            text = scene.get('spoken', scene['caption'])
            for take in range(1, args.takes + 1):
                path = folder / f"{scene['id']}-t{take}.wav"
                pcm = speak(key, text, voice, spec['voice_direction'])
                with wave.open(str(path), 'wb') as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(24000)
                    w.writeframes(pcm)
                duration = len(pcm) / 2 / 24000
                row = {'id': scene['id'], 'voice': voice, 'take': take, 'text': text,
                       'file': str(path.relative_to(HERE)), 'duration': round(duration, 3),
                       'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                report['rows'] = [r for r in report['rows'] if (r['id'], r['voice'], r['take']) != (scene['id'], voice, take)]
                report['rows'].append(row)
                print(f"{voice:6s} {scene['id']:11s} t{take}  {duration:5.2f} s", flush=True)
    report['rows'].sort(key=lambda r: (r['voice'], r['id'], r['take']))
    report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
