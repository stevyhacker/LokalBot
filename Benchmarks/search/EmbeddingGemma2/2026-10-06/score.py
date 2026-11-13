"""Score frozen labels with cosine ranking and paired passage-level intervals."""
import json
from pathlib import Path

import numpy as np

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-20261006')
RESULTS = ROOT / 'results'


def load(name):
    return np.load(RESULTS / (name + '.npy'))


def shorten(vectors, dimension):
    shortened = vectors[:, :dimension]
    return shortened / np.linalg.norm(shortened, axis=1, keepdims=True)


def score(fixture, documents, queries, dimension=None):
    assert len(documents) == len(fixture['documents'])
    assert len(queries) == len(fixture['queries'])
    if dimension is not None:
        documents, queries = shorten(documents, dimension), shorten(queries, dimension)
    assert documents.shape[1] == queries.shape[1]
    scores = queries @ documents.T
    rows = []
    for query, similarities in zip(fixture['queries'], scores):
        order = np.argsort(-similarities, kind='stable')
        rank = next(index + 1 for index, doc_index in enumerate(order)
                    if fixture['documents'][doc_index]['id'] in query['relevant'])
        rows.append({**query, 'rank': rank,
                     'top5': [fixture['documents'][index]['id'] for index in order[:5]],
                     'top_score': float(similarities[order[0]]),
                     'relevant_score': max(float(similarities[index])
                                           for index, doc in enumerate(fixture['documents'])
                                           if doc['id'] in query['relevant'])})

    def summary(selected):
        return {'queries': len(selected), 'top1': sum(row['rank'] == 1 for row in selected),
                'top5': sum(row['rank'] <= 5 for row in selected),
                'mrr': float(np.mean([1 / row['rank'] for row in selected]))}

    summaries = {'all': summary(rows)}
    for language in ['en', 'bcs']:
        summaries[language] = summary([row for row in rows if row['language'] == language])
    for category in sorted({row.get('category') for row in rows} - {None}):
        summaries[category] = summary([row for row in rows if row.get('category') == category])
    return {'dimension': documents.shape[1], 'summary': summaries, 'rows': rows}


def paired_interval(baseline, candidate):
    base = {row['id']: row for row in baseline['rows']}
    groups = sorted({row['group'] for row in candidate['rows']})
    deltas = np.asarray([
        np.mean([float(row['rank'] == 1) - float(base[row['id']]['rank'] == 1)
                 for row in candidate['rows'] if row['group'] == group])
        for group in groups
    ])
    rng = np.random.default_rng(61006)
    bootstrap = deltas[rng.integers(0, len(groups), size=(10000, len(groups)))].mean(axis=1)
    return {'delta_percentage_points': float(deltas.mean() * 100),
            'paired_group_bootstrap_95_percent': (np.percentile(bootstrap, [2.5, 97.5]) * 100).tolist(),
            'independent_groups': len(groups), 'bootstrap_draws': 10000}


def main():
    text = json.loads((ROOT / 'fixtures/text.json').read_text())
    screens = json.loads((ROOT / 'fixtures/screens.json').read_text())
    result = {'text': {}, 'screens': {}, 'paired': {}}
    result['text']['harrier'] = score(text, load('harrier-text-documents'), load('harrier-text-queries'))
    result['screens']['harrier-ocr'] = score(screens, load('harrier-screen-documents'), load('harrier-screen-queries'))
    for dimension in [768, 512, 256, 128]:
        result['text'][f'gemma-{dimension}'] = score(
            text, load('gemma-text-documents'), load('gemma-text-queries'), dimension)
        for label, documents, queries in [
            ('gemma-ocr', 'gemma-ocr-documents', 'gemma-ocr-queries'),
            ('gemma-image', 'gemma-image-documents', 'gemma-image-queries'),
            ('gemma-combined', 'gemma-combined-documents', 'gemma-image-queries'),
        ]:
            result['screens'][f'{label}-{dimension}'] = score(screens, load(documents), load(queries), dimension)
    result['paired']['text-gemma768-vs-harrier'] = paired_interval(
        result['text']['harrier'], result['text']['gemma-768'])
    result['paired']['screen-image768-vs-harrierOCR'] = paired_interval(
        result['screens']['harrier-ocr'], result['screens']['gemma-image-768'])
    result['paired']['screen-combined768-vs-harrierOCR'] = paired_interval(
        result['screens']['harrier-ocr'], result['screens']['gemma-combined-768'])
    (RESULTS / 'scores.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    for corpus in ['text', 'screens']:
        print(corpus)
        for model, data in result[corpus].items():
            print(model, json.dumps(data['summary']))
    print('paired', json.dumps(result['paired']))


if __name__ == '__main__':
    main()
