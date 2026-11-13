"""Language-handling jobs: pinned vs per-window auto vs detect-once vs vote-and-pin.

English uses the benchmark's meeting and AMI chunks (runs.jsonl / runs-06b.jsonl); the
multilingual check uses FLEURS pseudo-tracks from fetch_fleurs.py. Language modes in the
harness: a code or name is passed verbatim, null is Qwen auto-detection, `oracle` /
`oracle-name` use each item's true language, `detect` probes the longest windows, and
`vote` decodes with auto, votes per window and re-decodes pinned at >= 80%.
"""
import json
import os
from pathlib import Path

DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length'))


def main():
    base = json.loads((OUT / 'jobs.json').read_text())
    compact = json.loads((OUT / 'compact_jobs.json').read_text())
    fleurs = [{'id': i['id'], 'wav': i['wav'], 'language': i['language']}
              for i in json.loads((OUT / 'fleurs' / 'items.json').read_text())]
    english = [{'id': i['id'], 'wav': i['wav']} for i in base['items']]
    merge = lambda n: {'kind': 'merge', 'vadMax': 14, 'gap': 5, 'maxLen': n}
    vad = {'kind': 'vad', 'vadMax': 14, 'split': 15}
    cond = lambda name, layout, language, ngram: {'name': name, 'layout': layout, 'language': language,
                                                  'ngram': ngram, 'maxTokens': None, 'prefixes': None}

    def job(model, items, output, conditions):
        return {'modelDir': model['modelDir'], 'modelId': model['modelId'], 'vadModel': base['vadModel'],
                'output': str(OUT / output), 'items': items, 'conditions': conditions}

    mode = lambda m: None if m == 'auto' else m
    jobs = {
        'language_english.json': job(base, english, 'runs.jsonl', [
            cond('merge-60-off-v14-auto', merge(60), None, 'off'),
            cond('merge-60-off-v14-detect', merge(60), 'detect', 'off'),
            cond('engine-15-detect', vad, 'detect', 'runtime')]),
        'language_fleurs.json': job(base, fleurs, 'runs-fleurs.jsonl',
            [cond(f'm60-{m}', merge(60), mode(m), 'off') for m in ['oracle', 'oracle-name', 'auto', 'detect', 'vote']]
            + [cond(f'e15-{m}', vad, mode(m), 'runtime') for m in ['oracle', 'auto', 'detect', 'vote']]),
        'language_english_06b.json': job(compact, english, 'runs-06b.jsonl', [
            cond('merge-15-v14-auto', merge(15), None, 'runtime'),
            cond('merge-15-v14-detect', merge(15), 'detect', 'runtime')]),
        'language_fleurs_06b.json': job(compact, fleurs, 'runs-fleurs-06b.jsonl',
            [cond(f'm15-{m}', merge(15), mode(m), 'runtime') for m in ['oracle', 'auto', 'detect', 'vote']]),
    }
    for name, value in jobs.items():
        (OUT / name).write_text(json.dumps(value))
        print(f'{name}: {[c["name"] for c in value["conditions"]]}')


if __name__ == '__main__':
    main()
