"""Harness jobs for the MLX vs llama.cpp comparison: one job file per backend, same items,
windows, languages and context, so only the runtime differs.

English: AMI + LokalBot meeting chunks from CloudSTT's prepare.py, in the shipped 1.7B layout
(merge-60-off-v14) and the plain engine path (engine-15), language `en` as the app passes it.
FLEURS (fetch_fleurs.py): the true language code, auto, and vote-and-pin, in both layouts.
Serbian adds `sr` + a vocabulary prompt of proper nouns from its reference, joined like
TranscriptionVocabulary (", " and a final ".").

TIER=0.6b writes jobs-<backend>-06b.json for Qwen3-ASR 0.6B instead: the app's 0.6B
word-attribution layout (merge-15-v14: 14 s VAD regions merged across <=5 s pauses into
<=15 s windows, speech-swift's default decoding, whose repetition block only starts above
15 s) and engine-15, with the same FLEURS conditions on both layouts.
"""
import json
import os
from pathlib import Path

DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length'))
TIER = os.environ.get('TIER', '1.7b')
MODEL_ID = 'aufklarer/Qwen3-ASR-0.6B-MLX-4bit' if TIER == '0.6b' else 'aufklarer/Qwen3-ASR-1.7B-MLX-8bit'
MODEL_DIR = Path(os.environ.get('QWEN_MODEL_DIR', OUT / ('qwen06' if TIER == '0.6b' else '') / 'models' / MODEL_ID))
SUFFIX = '-06b' if TIER == '0.6b' else ''
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

    if TIER == '0.6b':
        merge, tag, ngram = {'kind': 'merge', 'vadMax': 14, 'gap': 5, 'maxLen': 15}, 'm15', 'runtime'
        conditions = [c('merge-15-v14', merge, 'en', ngram, english)]
    else:
        tag, ngram = 'm60', 'off'
        conditions = [c('merge-60-off-v14', merge, 'en', ngram, english)]
    conditions += [c('engine-15', vad, 'en', 'runtime', english)]
    for mode in ['oracle', 'auto', 'vote']:
        language = None if mode == 'auto' else mode
        conditions += [c(f'{tag}-{mode}', merge, language, ngram, ['fleurs-']),
                       c(f'e15-{mode}', vad, language, 'runtime', ['fleurs-'])]
    conditions += [c(f'{tag}-sr-vocab', merge, 'sr', ngram, ['fleurs-sr'], context),
                   c('e15-sr-vocab', vad, 'sr', 'runtime', ['fleurs-sr'], context),
                   c(f'{tag}-auto-vocab', merge, None, ngram, ['fleurs-sr'], context)]
    for backend in ['mlx', 'llama']:
        job = {'modelDir': str(MODEL_DIR), 'modelId': MODEL_ID, 'vadModel': str(VAD),
               'output': str(OUT / f'runs-{backend}{SUFFIX}.jsonl'), 'items': items, 'conditions': conditions}
        (OUT / f'jobs-{backend}{SUFFIX}.json').write_text(json.dumps(job, ensure_ascii=False))
    print(f'{len(items)} items, {len(conditions)} conditions; vocabulary: {context}')


if __name__ == '__main__':
    main()
