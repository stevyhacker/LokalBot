"""Map LokalBot's saved production transcripts onto the benchmark's meeting chunks.

Segments are assigned to a chunk by track and midpoint. The result reflects the full
app pipeline (VAD, known-name vocabulary, diarization, echo handling), so it is
scored for reference but never votes in the consensus.
"""
import json
from pathlib import Path
import subprocess

from common import load_manifest, save_output

TRACKS = {'mic': 'microphone', 'system': 'system'}


def main():
    rows = [r for r in load_manifest() if r['set'] == 'meetings']
    transcripts = {}
    for row in rows:
        if row['source'] not in transcripts:
            folder = Path(subprocess.run(['lokalbot-cli', 'path', row['source']], check=True,
                                         capture_output=True, text=True).stdout.strip())
            transcripts[row['source']] = json.loads((folder / 'transcript.json').read_text())
        data = transcripts[row['source']]
        picked = [s for s in data['segments']
                  if (s.get('attribution') or {}).get('source') == TRACKS[row['track']]
                  and row['start'] <= (s['start'] + s['end']) / 2 < row['end']]
        text = ' '.join(s['text'] for s in sorted(picked, key=lambda s: s['start']))
        save_output('lokalbot-app', row['id'], {
            'system': 'lokalbot-app', 'chunk': row['id'], 'text': text, 'error': None,
            'latency_seconds': None, 'audio_seconds': row['duration'], 'cost_usd': 0.0,
            'model': data.get('engine'), 'segments': len(picked)})
    print(f'lokalbot-app: {len(rows)} chunks from {len(transcripts)} meetings')


if __name__ == '__main__':
    main()
