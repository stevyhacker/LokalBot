"""Harness jobs for the MLX vs llama.cpp comparison: one job file per backend, same items,
windows, languages and context, so only the runtime differs.

English: AMI + LokalBot meeting chunks from CloudSTT's prepare.py, in the shipped 1.7B layout
(merge-60-off-v14) and the plain engine path (engine-15), language `en` as the app passes it.
FLEURS (fetch_fleurs.py): the true language code, auto, and vote-and-pin, in both layouts.
Serbian adds `sr` + a vocabulary prompt of proper nouns from its reference, joined like
TranscriptionVocabulary (", " and a final ".").
"""
import json
import os
from pathlib import Path

DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length'))
MODEL_DIR = Path(os.environ.get('QWEN_MODEL_DIR', OUT / 'models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit'))
VAD = Path.home() / 'Library/Application Support/FluidAudio/Models/silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc'
# Proper nouns that occur in the FLEURS Serbian track's reference, in Latin script as a
# Serbian user would type them in Settings.
SERBIAN_VOCABULARY = ['Moldavija', 'Japan', 'Božić', 'Isus', 'WiFi', 'Egipćani', 'Irak', 'UN', 'Argentina', 'SAD',
                      'Džordž Buš']


def main():
    manifest = json.loads((DATA / 'manifest.json').read_text())
    fleurs = json.loads((OUT / 'fleurs' / 'items.json').read_text())
    items = [{'id': r['id'], 'wav': r['path']} for r in manifest]
    items += [{'id': i['id'], 'wav': i['wav'], 'language': i['language']} for i in fleurs]
    english = ['ami-'] + sorted({r['source'] for r in manifest if r['set'] == 'meetings'})
    merge = {'kind': 'merge', 'vadMax': 14, 'gap': 5, 'maxLen': 60}
    vad = {'kind': 'vad', 'vadMax': 14, 'split': 15}
    context = ', '.join(SERBIAN_VOCABULARY) + '.'

    def c(name, layout, language, ngram, prefixes, ctx=None):
        return {'name': name, 'layout': layout, 'language': language, 'ngram': ngram, 'maxTokens': None,
                'prefixes': prefixes, 'context': ctx}

    conditions = [c('merge-60-off-v14', merge, 'en', 'off', english), c('engine-15', vad, 'en', 'runtime', english)]
    for mode in ['oracle', 'auto', 'vote']:
        language = None if mode == 'auto' else mode
        conditions += [c(f'm60-{mode}', merge, language, 'off', ['fleurs-']),
                       c(f'e15-{mode}', vad, language, 'runtime', ['fleurs-'])]
    conditions += [c('m60-sr-vocab', merge, 'sr', 'off', ['fleurs-sr'], context),
                   c('e15-sr-vocab', vad, 'sr', 'runtime', ['fleurs-sr'], context),
                   c('m60-auto-vocab', merge, None, 'off', ['fleurs-sr'], context)]
    for backend in ['mlx', 'llama']:
        job = {'modelDir': str(MODEL_DIR), 'modelId': 'aufklarer/Qwen3-ASR-1.7B-MLX-8bit', 'vadModel': str(VAD),
               'output': str(OUT / f'runs-{backend}.jsonl'), 'items': items, 'conditions': conditions}
        (OUT / f'jobs-{backend}.json').write_text(json.dumps(job, ensure_ascii=False))
    print(f'{len(items)} items, {len(conditions)} conditions; vocabulary: {context}')


if __name__ == '__main__':
    main()
