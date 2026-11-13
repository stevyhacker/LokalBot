"""VAD gate sweep jobs: Silero entry threshold and region padding on the shipped paths.

Recall runs on the benchmark's English chunks; false alarms on make_noise.py's speech-free
meeting audio. Layout keys `vadThreshold` (FluidAudio default 0.85) and `padding` (0.1 s)
are read by the harness.
"""
import json
import os
from pathlib import Path

DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length'))


def main():
    base = json.loads((OUT / 'jobs.json').read_text())
    compact = json.loads((OUT / 'compact_jobs.json').read_text())
    english = [{'id': i['id'], 'wav': i['wav']} for i in base['items']]
    noise = [{'id': i['id'], 'wav': i['wav']} for i in json.loads((OUT / 'noise' / 'items.json').read_text())]

    def merge(n, threshold=None, padding=None):
        layout = {'kind': 'merge', 'vadMax': 14, 'gap': 5, 'maxLen': n}
        layout.update({k: v for k, v in {'vadThreshold': threshold, 'padding': padding}.items() if v is not None})
        return layout

    def vad(threshold=None):
        layout = {'kind': 'vad', 'vadMax': 14, 'split': 15}
        if threshold is not None:
            layout['vadThreshold'] = threshold
        return layout

    def cond(name, layout, ngram):
        return {'name': name, 'layout': layout, 'language': 'en', 'ngram': ngram, 'maxTokens': None, 'prefixes': None}

    def job(model, items, output, conditions):
        return {'modelDir': model['modelDir'], 'modelId': model['modelId'], 'vadModel': base['vadModel'],
                'output': str(OUT / output), 'items': items, 'conditions': conditions}

    jobs = {
        'vad_noise.json': job(base, noise, 'runs-noise.jsonl',
            [cond(f'm60-t{t}', merge(60, t), 'off') for t in [0.85, 0.7, 0.5, 0.35]]
            + [cond('m60-pad0.3', merge(60, 0.85, 0.3), 'off')]
            + [cond(f'e15-t{t}', vad(t), 'runtime') for t in [0.85, 0.7, 0.5, 0.35]]),
        'vad_noise_06b.json': job(compact, noise, 'runs-noise-06b.jsonl',
            [cond(f'm15-t{t}', merge(15, t), 'runtime') for t in [0.85, 0.5]]),
        'vad_english.json': job(base, english, 'runs.jsonl',
            [cond(f'm60-t{t}', merge(60, t), 'off') for t in [0.7, 0.5, 0.35]]
            + [cond('m60-pad0.3', merge(60, 0.85, 0.3), 'off'), cond('e15-t0.5', vad(0.5), 'runtime')]),
        'vad_english_06b.json': job(compact, english, 'runs-06b.jsonl', [cond('m15-t0.5', merge(15, 0.5), 'runtime')]),
    }
    for name, value in jobs.items():
        (OUT / name).write_text(json.dumps(value))
        print(f'{name}: {[c["name"] for c in value["conditions"]]}')


if __name__ == '__main__':
    main()
