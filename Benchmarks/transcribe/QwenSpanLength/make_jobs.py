"""Build the harness job file from the CloudSTT benchmark's prepared chunks (read-only).

Items are the benchmark's own 16 kHz chunk WAVs, so every condition hears the audio
the vendors and mlx-audio heard. Two explicit layouts are attached:
- meetings `app`: the saved production transcript's decode windows (segment start/end),
  assigned by track + midpoint like import_app.py, clipped to the chunk.
- AMI `oracle`: AttributedTrackTranscriber.regions() applied to the reference speaker
  turns (single-speaker / overlap / unlabeled regions, then a 30 s stride).
"""
import json
import os
import subprocess
import sys
from pathlib import Path

# CloudSTT's private data folder (manifest.json, chunk WAVs, AMI utterances). Read only.
DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
# Private outputs for this benchmark: jobs.json and runs.jsonl (transcripts).
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length'))
# Hub-style model directory. Clone the app's copy (`cp -c -R`) rather than pointing at it.
MODEL_DIR = Path(os.environ.get('QWEN_MODEL_DIR', OUT / 'models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit'))
TRACKS = {'mic': 'microphone', 'system': 'system'}


def regions(duration, turns):
    """Port of AttributedTrackTranscriber.regions (labels only matter for merging)."""
    valid = sorted((t for t in turns if t[1] > t[0] and t[1] > 0 and t[0] < duration), key=lambda t: t[0])
    bounds = sorted({0.0, duration, *[max(0.0, t[0]) for t in valid], *[min(duration, t[1]) for t in valid]})
    out = []
    for start, end in zip(bounds, bounds[1:]):
        if end <= start:
            continue
        speakers = {t[2] for t in valid if t[0] < end and t[1] > start}
        label = next(iter(speakers)) if len(speakers) == 1 else ('unclear' if speakers else 'none')
        if out and out[-1][2] == label:
            out[-1][1] = end
        else:
            out.append([start, end, label])
    strided = []
    for start, end, _ in out:
        s = start
        while s < end:
            strided.append([round(s, 4), round(min(s + 30, end), 4)])
            s += 30
    return strided


def main():
    manifest = json.loads((DATA / 'manifest.json').read_text())
    transcripts = {}
    items = []
    for row in manifest:
        item = {'id': row['id'], 'wav': row['path'], 'layouts': {}}
        duration = row['duration']
        if row['set'] == 'ami':
            utts = json.loads((DATA / 'source' / 'ami' / f'{row["source"]}.utterances.json').read_text())
            turns = [(u['begin'] - row['start'], u['end'] - row['start'], u['speaker']) for u in utts
                     if u['end'] > row['start'] and u['begin'] < row['end']]
            item['layouts']['oracle'] = regions(duration, turns)
        else:
            if row['source'] not in transcripts:
                folder = Path(subprocess.run(['lokalbot-cli', 'path', row['source']], check=True,
                                             capture_output=True, text=True).stdout.strip())
                transcripts[row['source']] = json.loads((folder / 'transcript.json').read_text())['segments']
            picked = sorted((s for s in transcripts[row['source']]
                             if (s.get('attribution') or {}).get('source') == TRACKS[row['track']]
                             and row['start'] <= (s['start'] + s['end']) / 2 < row['end']),
                            key=lambda s: s['start'])
            item['layouts']['app'] = [[round(max(0.0, s['start'] - row['start']), 4),
                                       round(min(duration, s['end'] - row['start']), 4)] for s in picked]
        items.append(item)

    def c(name, layout, language='en', ngram='runtime', max_tokens=None, prefixes=None):
        return {'name': name, 'layout': layout, 'language': language, 'ngram': ngram,
                'maxTokens': max_tokens, 'prefixes': prefixes}

    vad = lambda cap, split: {'kind': 'vad', 'vadMax': cap, 'split': split}
    merge = lambda n: {'kind': 'merge', 'vadMax': n, 'gap': 5, 'maxLen': n}
    meetings = sorted({r['source'] for r in manifest if r['set'] == 'meetings'})
    conditions = [
        # Production layouts and today's engine path.
        c('app-spans', {'kind': 'explicit', 'key': 'app'}, prefixes=meetings),
        c('oracle-regions', {'kind': 'regions', 'key': 'oracle', 'vadMax': 14, 'split': 15}, prefixes=['ami-']),
        c('engine-15', vad(14, 15)),
        # Runtime/weights control: identical input to mlx-audio.
        c('whole-English-off-8192', {'kind': 'whole'}, language='English', ngram='off', max_tokens=8192),
        c('whole-en', {'kind': 'whole'}),
        c('whole-en-off', {'kind': 'whole'}, ngram='off'),
        # Literal knob: VAD cap + maxSegmentSeconds raised together.
        c('vadcap-30', vad(30, 30)),
        c('vadcap-60', vad(60, 60)),
        c('vadcap-120', vad(120, 120)),
        # Context merge sweep (VAD regions merged across <=5 s gaps).
        c('merge-15', merge(15)),
        c('merge-30', merge(30)),
        c('merge-60', merge(60)),
        c('merge-120', merge(120)),
        c('merge-30-off', merge(30), ngram='off'),
        c('merge-60-off', merge(60), ngram='off'),
        c('merge-120-off', merge(120), ngram='off'),
        c('merge-120-off-4096', merge(120), ngram='off', max_tokens=4096),
        # App-implementable long windows: default 14 s VAD regions merged across <=5 s pauses.
        c('merge-60-off-v14', {'kind': 'merge', 'vadMax': 14, 'gap': 5, 'maxLen': 60}, ngram='off'),
        # Language hint.
        c('engine-15-English', vad(14, 15), language='English'),
        c('engine-15-auto', vad(14, 15), language=None),
        c('merge-120-English-off', merge(120), language='English', ngram='off'),
    ]
    only = set(sys.argv[1:])
    if only:
        conditions = [x for x in conditions if x['name'] in only]
    jobs = {
        'modelDir': str(MODEL_DIR),
        'modelId': 'aufklarer/Qwen3-ASR-1.7B-MLX-8bit',
        'vadModel': str(Path.home() / 'Library/Application Support/FluidAudio/Models/silero-vad/'
                        'silero-vad-unified-256ms-v6.2.1.mlmodelc'),
        'output': str(OUT / 'runs.jsonl'),
        'items': items,
        'conditions': conditions,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'jobs.json').write_text(json.dumps(jobs))
    app = [w for i in items for w in i['layouts'].get('app', [])]
    oracle = [w for i in items for w in i['layouts'].get('oracle', [])]
    print(f'{len(items)} items; app windows {len(app)}, median {sorted(b - a for a, b in app)[len(app) // 2]:.2f}s; '
          f'oracle regions {len(oracle)}, median {sorted(b - a for a, b in oracle)[len(oracle) // 2]:.2f}s; '
          f'{len(conditions)} conditions')


if __name__ == '__main__':
    main()
