"""Voice the narration and the call with ElevenLabs (eleven_v4), one request per line.

Narration and Stevan's lines on the call use the author's own voice clone; Ana's
lines use the "Ana" voice. Each request carries the neighbouring lines of the
same strand (narration, or the call) as previous_text/next_text, and uses the
with-timestamps endpoint so captions are timed from the character alignment.
Writes assets/voice/<id>-s<seed>.mp3 and production/voice-generation.json
(settings, text and alignment; never the key).

The key comes from ELEVEN_LABS_API_KEY (the main checkout's .env), e.g.
  export ELEVEN_LABS_API_KEY="$(sed -n 's/^ELEVEN_LABS_API_KEY=//p' ../../../LokalBot/.env)"
Usage: python3 tts.py [--seeds 11] [--only n01,c03]
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

P = Path(__file__).resolve().parent
SPEC = json.loads((P / 'narration.json').read_text())
VOICES = {'narrator': 'jBeSFLau956Zo30jykBV', 'stevan': 'jBeSFLau956Zo30jykBV', 'ana': 'ee4SYVdD1aAhcjOJPZdt'}


def spoken(line):
    return line.get('eleven_text') or line['text']


def duration(path):
    return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                 str(path)], check=True, capture_output=True, text=True).stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', default='eleven_v4')
    ap.add_argument('--seeds', default='11')
    ap.add_argument('--only', default='')
    ap.add_argument('--speed', type=float, default=1.0)
    args = ap.parse_args()
    key = os.environ.get('ELEVEN_LABS_API_KEY') or os.environ.get('ELEVENLABS_API_KEY')
    if not key:
        sys.exit('ELEVEN_LABS_API_KEY is not set')
    lines = SPEC['lines']
    only = set(filter(None, args.only.split(',')))
    out_dir = P / 'assets/voice'
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = P / 'production/voice-generation.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {'rows': []}
    settings = {'stability': 0.5, 'similarity_boost': 0.8, 'speed': args.speed}
    report.update({'provider': 'elevenlabs', 'model_id': args.model, 'voices': VOICES,
                   'output_format': 'mp3_44100_128', 'voice_settings': settings})
    for i, line in enumerate(lines):
        if only and line['id'] not in only:
            continue
        strand = [x for x in lines if (x['voice'] == 'narrator') == (line['voice'] == 'narrator')]
        k = strand.index(line)
        for seed in (int(s) for s in args.seeds.split(',')):
            body = {'text': spoken(line), 'model_id': args.model, 'seed': seed, 'voice_settings': settings}
            if k > 0:
                body['previous_text'] = spoken(strand[k - 1])
            if k + 1 < len(strand):
                body['next_text'] = spoken(strand[k + 1])
            url = (f"https://api.elevenlabs.io/v1/text-to-speech/{VOICES[line['voice']]}/with-timestamps"
                   '?output_format=mp3_44100_128')
            req = urllib.request.Request(url, data=json.dumps(body).encode(), method='POST',
                                         headers={'Content-Type': 'application/json', 'xi-api-key': key})
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    data = json.load(r)
            except urllib.error.HTTPError as e:
                sys.exit(f'HTTP {e.code}: {e.read().decode()[:600]}')
            path = out_dir / f"{line['id']}-s{seed}.mp3"
            path.write_bytes(base64.b64decode(data['audio_base64']))
            row = {'id': line['id'], 'voice': line['voice'], 'seed': seed, 'file': str(path.relative_to(P)),
                   'text': body['text'], 'duration': round(duration(path), 3), 'alignment': data.get('alignment')}
            report['rows'] = [x for x in report['rows'] if x['file'] != row['file']] + [row]
            report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
            print(json.dumps({k: row[k] for k in ('file', 'duration')}), flush=True)


if __name__ == '__main__':
    main()
