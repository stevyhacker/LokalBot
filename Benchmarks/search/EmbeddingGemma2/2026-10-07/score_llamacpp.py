"""Score the llama.cpp vectors with the unchanged 6 October scorer."""
import importlib.util
import json
import os
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('baseline_score', HERE.parent / '2026-10-06/score.py')
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)

FIXTURES = baseline.ROOT / 'fixtures'
RESULTS = Path(os.environ.get('LOKALBOT_EMBEDDING_RESULTS', '/private/tmp/lokalbot-embeddinggemma2-20261007/results'))


def load(name):
    return np.load(RESULTS / (name + '.npy'))


def main():
    text = json.loads((FIXTURES / 'text.json').read_text())
    screens = json.loads((FIXTURES / 'screens.json').read_text())
    score = baseline.score
    result = {'text': {}, 'screens': {}, 'paired': {}}
    result['text']['harrier'] = score(text, load('harrier-gguf-text-documents'), load('harrier-gguf-text-queries'))
    result['screens']['harrier-ocr'] = score(
        screens, load('harrier-gguf-screen-documents'), load('harrier-gguf-screen-queries'))
    for dimension in [768, 512, 256]:
        result['text'][f'gemma-{dimension}'] = score(
            text, load('gemma-gguf-text-documents'), load('gemma-gguf-text-queries'), dimension)
        for label, documents, queries in [
            ('gemma-ocr', 'gemma-gguf-ocr-documents', 'gemma-gguf-ocr-queries'),
            ('gemma-image', 'gemma-gguf-image-documents', 'gemma-gguf-image-queries'),
            ('gemma-combined', 'gemma-gguf-combined-documents', 'gemma-gguf-image-queries'),
        ]:
            result['screens'][f'{label}-{dimension}'] = score(
                screens, load(documents), load(queries), dimension)
    result['paired']['text-gemma768-vs-harrier'] = baseline.paired_interval(
        result['text']['harrier'], result['text']['gemma-768'])
    result['paired']['screen-image768-vs-harrierOCR'] = baseline.paired_interval(
        result['screens']['harrier-ocr'], result['screens']['gemma-image-768'])
    (RESULTS / 'scores.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    for corpus in ['text', 'screens']:
        for model, data in result[corpus].items():
            print(corpus, model, json.dumps({k: v for k, v in data['summary'].items()
                                             if k in ('all', 'en', 'bcs') or not corpus == 'text'}))
    print('paired', json.dumps(result['paired']))


if __name__ == '__main__':
    main()
