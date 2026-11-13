"""Speaker-region variants built from real Nemotron 3 turns (turns.json from `harness diarize`).

Regions are built on each recording's full timeline, exactly as AttributedTrackTranscriber
does for a track, then clipped to each benchmark chunk. Variants:
- prod:     AttributedTrackTranscriber.regions (turn/gap/overlap boundaries + 30 s stride)
- nostride: same boundaries, no 30 s stride
- absorb:   unlabeled gaps <= ABSORB s folded into the neighbouring regions, 30 s stride kept
- combined: absorb + no stride
Writes region_jobs.json (harness input) and region_labels.json (window -> speaker label).

`make_region_jobs.py diarize-job` first writes diarize.json for `qwen-span-harness diarize`.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length'))
# Clone of the app's Models/NemotronDiarization/<revision> folder.
NEMOTRON_DIR = Path(os.environ.get('NEMOTRON_MODEL_DIR', OUT / 'nemotron'))
# Hub-style folder holding the pinned Qwen3-ForcedAligner-0.6B-4bit files.
ALIGNER_DIR = Path(os.environ.get('ALIGNER_MODEL_DIR', OUT / 'aligner/models/aufklarer/Qwen3-ForcedAligner-0.6B-4bit'))
# Hub-style folder holding the pinned Qwen3-ASR-0.6B-MLX-4bit files (compact tier).
COMPACT_DIR = Path(os.environ.get('QWEN06_MODEL_DIR', OUT / 'qwen06/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit'))
ABSORB = 2.0
TRACKS = ['mic', 'system']


def duration_of(path):
    out = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path],
                         check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def labeled(duration, turns):
    """AttributedTrackTranscriber.regions before the stride, with labels."""
    valid = sorted((t for t in turns if t['end'] > t['start'] and t['end'] > 0 and t['start'] < duration),
                   key=lambda t: t['start'])
    bounds = sorted({0.0, duration, *[max(0.0, t['start']) for t in valid], *[min(duration, t['end']) for t in valid]})
    out = []
    for start, end in zip(bounds, bounds[1:]):
        if end <= start:
            continue
        speakers = {t['speaker'] for t in valid if t['start'] < end and t['end'] > start}
        label = next(iter(speakers)) if len(speakers) == 1 else ('unclear' if speakers else 'none')
        if out and out[-1][2] == label:
            out[-1][1] = end
        else:
            out.append([start, end, label])
    return out


def absorb(regions, limit=ABSORB):
    """Fold short unlabeled gaps into their neighbours (merge if both sides share a label)."""
    out = [list(r) for r in regions]
    i = 0
    while i < len(out):
        start, end, label = out[i]
        if label != 'none' or end - start > limit:
            i += 1
            continue
        prev = out[i - 1] if i > 0 else None
        nxt = out[i + 1] if i + 1 < len(out) else None
        if prev and nxt and prev[2] == nxt[2]:
            prev[1] = nxt[1]
            del out[i:i + 2]
            continue
        if prev and nxt:
            mid = (start + end) / 2
            prev[1], nxt[0] = mid, mid
        elif prev:
            prev[1] = end
        elif nxt:
            nxt[0] = start
        else:
            i += 1
            continue
        del out[i]
    return out


def stride(regions, step=30):
    out = []
    for start, end, label in regions:
        s = start
        while s < end:
            out.append([s, min(s + step, end), label])
            s += step
    return out


def clip(regions, lo, hi):
    return [[round(max(s, lo) - lo, 4), round(min(e, hi) - lo, 4), label]
            for s, e, label in regions if min(e, hi) > max(s, lo)]


def recordings(manifest):
    """Full recording behind each chunk: AMI Mix-Headset WAVs and meeting tracks (read only)."""
    folders = {m: subprocess.run(['lokalbot-cli', 'path', m], check=True, capture_output=True, text=True).stdout.strip()
               for m in sorted({r['source'] for r in manifest if r['set'] == 'meetings'})}

    def recording(row):
        if row['set'] == 'ami':
            return str(DATA / 'source' / 'ami' / f'{row["source"]}.Mix-Headset.wav')
        return f'{folders[row["source"]]}/{row["track"]}.m4a'
    return recording


def main():
    manifest = json.loads((DATA / 'manifest.json').read_text())
    recording = recordings(manifest)
    if sys.argv[1:2] == ['align-job']:
        # Word timings for a condition's windows in runs.jsonl (default engine-15).
        # ALIGNER_VARIANT=8bit uses the 8-bit aligner in ALIGNER_MODEL_DIR instead.
        # RUNS_FILE=runs-06b.jsonl ALIGNED_PREFIX=aligned06 aligns the compact-tier runs.
        items = [{'id': r['id'], 'wav': r['path']} for r in manifest]
        variant = os.environ.get('ALIGNER_VARIANT', '4bit')
        runs_file = os.environ.get('RUNS_FILE', 'runs.jsonl')
        prefix = os.environ.get('ALIGNED_PREFIX', 'aligned' if variant == '4bit' else 'aligned8')
        for condition in sys.argv[2:] or ['engine-15']:
            name = 'aligned-engine15' if (prefix, condition) == ('aligned', 'engine-15') else f'{prefix}-{condition}'
            path = OUT / ('align.json' if name == 'aligned-engine15' else
                          f'align-{variant}-{condition}.json' if prefix in ('aligned', 'aligned8') else
                          f'align-{prefix}-{condition}.json')
            path.write_text(json.dumps({
                'modelId': f'aufklarer/Qwen3-ForcedAligner-0.6B-{variant}', 'modelDir': str(ALIGNER_DIR),
                'runs': str(OUT / runs_file), 'condition': condition, 'language': 'English',
                'items': items, 'output': str(OUT / f'{name}.jsonl')}))
            print(f'{path.name}: {len(items)} items -> {name}.jsonl')
        return
    if sys.argv[1:] == ['compact-job']:
        # Qwen3-ASR 0.6B on the same items: production regions plus word-attribution windows.
        base = json.loads((OUT / 'region_jobs.json').read_text())
        vad = {'kind': 'vad', 'vadMax': 14, 'split': 15}
        merge = lambda n: {'kind': 'merge', 'vadMax': 14, 'gap': 5, 'maxLen': n}
        c = lambda name, layout, ngram='runtime': {'name': name, 'layout': layout, 'language': 'en',
                                                   'ngram': ngram, 'maxTokens': None, 'prefixes': None}
        (OUT / 'compact_jobs.json').write_text(json.dumps({
            'modelDir': str(COMPACT_DIR), 'modelId': 'aufklarer/Qwen3-ASR-0.6B-MLX-4bit',
            'vadModel': base['vadModel'], 'output': str(OUT / 'runs-06b.jsonl'), 'items': base['items'],
            'conditions': [c('engine-15', vad), c('merge-15-v14', merge(15)),
                           c('merge-30-off-v14', merge(30), 'off'), c('merge-60-off-v14', merge(60), 'off'),
                           c('merge-60-v14', merge(60)),
                           c('diar-prod', {'kind': 'regions', 'key': 'prod', 'vadMax': 14, 'split': 15})]}))
        print('compact_jobs.json: 6 conditions')
        return
    if sys.argv[1:] == ['diarize-job']:
        files = sorted({recording(r) for r in manifest})
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / 'diarize.json').write_text(json.dumps(
            {'modelDir': str(NEMOTRON_DIR), 'files': files, 'output': str(OUT / 'turns.json')}))
        print(f'{len(files)} recordings')
        return
    turns = json.loads((OUT / 'turns.json').read_text())

    full = {}
    for path in {recording(r) for r in manifest}:
        base = labeled(duration_of(path), turns[path])
        full[path] = {'prod': stride(base), 'nostride': base, 'absorb': stride(absorb(base)),
                      'combined': absorb(base)}

    items, labels = [], {k: {} for k in ['prod', 'nostride', 'absorb', 'combined']}
    for row in manifest:
        item = {'id': row['id'], 'wav': row['path'], 'layouts': {}}
        for key, regions in full[recording(row)].items():
            clipped = clip(regions, row['start'], row['end'])
            item['layouts'][key] = [[s, e] for s, e, _ in clipped]
            labels[key][row['id']] = clipped
        items.append(item)

    def c(name, layout, ngram='runtime'):
        return {'name': name, 'layout': layout, 'language': 'en', 'ngram': ngram, 'maxTokens': None, 'prefixes': None}

    conditions = [
        c('diar-prod', {'kind': 'regions', 'key': 'prod', 'vadMax': 14, 'split': 15}),
        c('diar-trackvad', {'kind': 'intersect', 'key': 'prod', 'vadMax': 14, 'split': 15}),
        c('diar-nostride', {'kind': 'regions', 'key': 'nostride', 'vadMax': 14, 'split': 15}),
        c('diar-absorb', {'kind': 'regions', 'key': 'absorb', 'vadMax': 14, 'split': 15}),
        c('diar-combined', {'kind': 'intersect', 'key': 'combined', 'vadMax': 14, 'split': 15}),
        c('diar-combined-60off', {'kind': 'intersect', 'key': 'combined', 'vadMax': 60, 'split': 60,
                                  'gap': 5, 'maxLen': 60}, ngram='off'),
    ]
    base = json.loads((OUT / 'jobs.json').read_text())
    jobs = {k: base[k] for k in ['modelDir', 'modelId', 'vadModel', 'output']}
    jobs.update(items=items, conditions=conditions)
    (OUT / 'region_jobs.json').write_text(json.dumps(jobs))
    (OUT / 'region_labels.json').write_text(json.dumps(labels))
    for key in labels:
        lens = sorted(e - s for per in labels[key].values() for s, e, _ in per)
        print(f'{key}: {len(lens)} regions in chunks, median {lens[len(lens) // 2]:.2f}s, '
              f'under 1 s {sum(x < 1 for x in lens) / len(lens):.0%}')


if __name__ == '__main__':
    main()
