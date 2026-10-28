"""Generate the narration with ElevenLabs (eleven_v4), one request per line.

Each request carries the neighbouring lines as previous_text/next_text so the
delivery stays continuous across lines, and uses the with-timestamps endpoint
so captions and on-screen cues can be timed from the character alignment.
Writes assets/voice/eleven/<id>-s<seed>.mp3 plus production/eleven-generation.json
(settings, text and alignment; never the key).

The API key comes from ELEVENLABS_API_KEY or ELEVEN_LABS_API_KEY (the main
checkout's .env uses the latter), e.g.
  export ELEVEN_LABS_API_KEY="$(sed -n 's/^ELEVEN_LABS_API_KEY=//p' ../../.env)"
Usage: python3 tts_elevenlabs.py [--voice ID --name brian] [--seeds 11,29] [--only 05-open]
With --name, files are <id>-<name>-s<seed>.mp3, so several voices can sit side by side.
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

# CUT_DIR selects a cut (e.g. short/) that has the same layout as this folder.
P = Path(os.environ.get('CUT_DIR') or Path(__file__).resolve().parent).resolve()
SPEC = json.loads((P / 'narration.json').read_text())


def speak_text(scene):
    # ElevenLabs reads names as written; the Breeze respellings are not needed.
    # A cut can give the text to send (with audio tags) as "spoken".
    return scene.get('spoken') or scene.get('eleven_text') or scene['caption']


def duration(path):
    return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                 str(path)], check=True, capture_output=True, text=True).stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--voice', default='jBeSFLau956Zo30jykBV')
    ap.add_argument('--model', default='eleven_v4')
    ap.add_argument('--seeds', default='11,29')
    ap.add_argument('--only', default='')
    ap.add_argument('--name', default='', help='short voice name for file names, when trying other voices')
    ap.add_argument('--stability', type=float, default=0.5)
    ap.add_argument('--similarity', type=float, default=0.8)
    ap.add_argument('--speed', type=float, default=1.0)
    args = ap.parse_args()
    key = os.environ.get('ELEVENLABS_API_KEY') or os.environ.get('ELEVEN_LABS_API_KEY')
    if not key:
        sys.exit('ELEVENLABS_API_KEY (or ELEVEN_LABS_API_KEY) is not set')
    scenes = SPEC['scenes']
    only = set(filter(None, args.only.split(',')))
    out_dir = P / 'assets/voice/eleven'
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = P / 'production/eleven-generation.json'
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = json.loads(report_path.read_text()) if report_path.exists() else {'rows': []}
    report.update({'provider': 'elevenlabs', 'model_id': args.model, 'voice_id': args.voice,
                   'output_format': 'mp3_44100_128',
                   'voice_settings': {'stability': args.stability, 'similarity_boost': args.similarity,
                                      'speed': args.speed}})
    for i, scene in enumerate(scenes):
        if only and scene['id'] not in only:
            continue
        for seed in (int(s) for s in args.seeds.split(',')):
            body = {'text': speak_text(scene), 'model_id': args.model, 'seed': seed,
                    'voice_settings': report['voice_settings']}
            if i > 0:
                body['previous_text'] = speak_text(scenes[i - 1])
            if i + 1 < len(scenes):
                body['next_text'] = speak_text(scenes[i + 1])
            url = (f'https://api.elevenlabs.io/v1/text-to-speech/{args.voice}/with-timestamps'
                   '?output_format=mp3_44100_128')
            req = urllib.request.Request(url, data=json.dumps(body).encode(), method='POST',
                                         headers={'Content-Type': 'application/json', 'xi-api-key': key})
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    data = json.load(r)
            except urllib.error.HTTPError as e:
                sys.exit(f'HTTP {e.code}: {e.read().decode()[:600]}')
            path = out_dir / (f"{scene['id']}-{args.name}-s{seed}.mp3" if args.name else f"{scene['id']}-s{seed}.mp3")
            path.write_bytes(base64.b64decode(data['audio_base64']))
            row = {'id': scene['id'], 'seed': seed, 'file': str(path.relative_to(P)), 'text': body['text'],
                   **({'voice_name': args.name, 'voice_id': args.voice, 'voice_settings': report['voice_settings']} if args.name else {}),
                   'duration': round(duration(path), 3), 'alignment': data.get('alignment')}
            report['rows'] = [x for x in report['rows'] if x['file'] != row['file']] + [row]
            report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
            print(json.dumps({k: row[k] for k in ('file', 'duration')}), flush=True)


if __name__ == '__main__':
    main()
