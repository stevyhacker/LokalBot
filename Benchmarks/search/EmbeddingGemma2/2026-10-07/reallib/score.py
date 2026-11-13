"""Score known-item retrieval on the real library; write aggregates only.

Relevance is model-agnostic. Strict counts only the source passage. Lenient
also accepts transcript neighbours within 60 s in the same meeting,
identical text, and near-duplicate screens (same similarity group or
word-set Jaccard >= 0.5). Per-query rows contain private text and stay in
the disposable folder; `--publish` writes only aggregate numbers.
"""
import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

import numpy as np

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-reallib')
HARRIER_SCREEN_FLOOR = 0.45
WORD = re.compile(r'\w{3,}', re.UNICODE)


def load(name):
    return np.load(ROOT / name)


def relevant_sets(name, corpus, targets):
    index = {row['id']: i for i, row in enumerate(corpus)}
    by_text = defaultdict(set)
    for i, row in enumerate(corpus):
        by_text[row['text']].add(i)
    sets = {}
    if name == 'meetings':
        by_meeting = defaultdict(list)
        for i, row in enumerate(corpus):
            by_meeting[row['meeting_id']].append(i)
        for target in targets:
            t = index[target]
            row = corpus[t]
            lenient = {t} | by_text[row['text']]
            if row['start'] > 0:
                lenient |= {i for i in by_meeting[row['meeting_id']]
                            if corpus[i]['start'] > 0 and abs(corpus[i]['start'] - row['start']) <= 60}
            sets[target] = ({t}, lenient)
    else:
        words = [set(w.lower() for w in WORD.findall(row['text'])) for row in corpus]
        for target in targets:
            t = index[target]
            row = corpus[t]
            lenient = {t} | by_text[row['text']]
            for i, other in enumerate(corpus):
                if row['group'] and other['group'] == row['group']:
                    lenient.add(i)
                elif words[t] and len(words[t] & words[i]) / len(words[t] | words[i]) >= .5:
                    lenient.add(i)
            sets[target] = ({t}, lenient)
    return sets


def ranks(scores, relevant):
    order = np.argsort(-scores, kind='stable')
    position = np.empty_like(order)
    position[order] = np.arange(1, len(order) + 1)
    return int(min(position[i] for i in relevant))


def summarize(rows, key):
    if not rows:
        return None
    values = [row[key] for row in rows]
    return {
        'queries': len(rows),
        'top1': sum(r == 1 for r in values), 'top5': sum(r <= 5 for r in values),
        'top10': sum(r <= 10 for r in values),
        'mrr10': float(np.mean([1 / r if r <= 10 else 0 for r in values])),
    }


def paired(baseline, candidate, key):
    groups = defaultdict(list)
    for base, cand in zip(baseline, candidate):
        groups[cand['group']].append(float(cand[key] == 1) - float(base[key] == 1))
    deltas = np.asarray([np.mean(v) for v in groups.values()])
    weights = np.asarray([len(v) for v in groups.values()], dtype=float)
    rng = np.random.default_rng(61007)
    draws = rng.integers(0, len(deltas), size=(10000, len(deltas)))
    boot = (deltas[draws] * weights[draws]).sum(axis=1) / weights[draws].sum(axis=1)
    point = float((deltas * weights).sum() / weights.sum())
    return {'delta_top1_points': point * 100,
            'bootstrap_95': (np.percentile(boot, [2.5, 97.5]) * 100).tolist(),
            'clusters': len(deltas)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--publish', type=Path)
    publish = parser.parse_args().publish
    queries = json.loads((ROOT / 'queries-embedded.json').read_text())
    result = {'corpus': {}, 'configs': {}, 'paired': {}, 'screen_floor': {}}
    private_rows = {}
    for name in ('meetings', 'screens'):
        corpus = json.loads((ROOT / f'corpus/{name}.json').read_text())
        selected = [q for q in queries if q['corpus'] == name]
        sets = relevant_sets(name, corpus, {q['target'] for q in selected})
        lookup = {row['id']: row for row in corpus}
        language = {row['id']: row['language'] for row in corpus}
        configs = {
            'harrier-stored': (load(f'corpus/harrier-{name}.npy'), load(f'vectors/harrier-{name}-queries.npy')),
            'harrier': ((load('vectors/harrier-meetings-documents.npy') if name == 'meetings'
                         else load('corpus/harrier-screens.npy')), load(f'vectors/harrier-{name}-queries.npy')),
        }
        gemma_docs, gemma_queries = load(f'vectors/gemma-{name}-documents.npy'), load(f'vectors/gemma-{name}-queries.npy')
        for dimension in (768, 512):
            d = gemma_docs[:, :dimension] / np.linalg.norm(gemma_docs[:, :dimension], axis=1, keepdims=True)
            q = gemma_queries[:, :dimension] / np.linalg.norm(gemma_queries[:, :dimension], axis=1, keepdims=True)
            configs[f'gemma-{dimension}'] = (d, q)
        result['corpus'][name] = {
            'documents': len(corpus), 'queries': len(selected),
            'targets': len({q['target'] for q in selected}),
            'mean_lenient_relevant': float(np.mean([len(sets[q['target']][1]) for q in selected])),
        }
        per_config = {}
        for label, (documents, query_vectors) in configs.items():
            assert len(documents) == len(corpus) and len(query_vectors) == len(selected)
            similarity = query_vectors @ documents.T
            rows = []
            for q, scores in zip(selected, similarity):
                strict, lenient = sets[q['target']]
                rows.append({
                    'target': q['target'], 'query_language': q['language'],
                    'target_language': language[q['target']],
                    # Bootstrap clusters: queries from one meeting are not independent.
                    'group': lookup[q['target']].get('meeting_id', q['target']),
                    'strict': ranks(scores, strict), 'lenient': ranks(scores, lenient),
                    'relevant_score': float(max(scores[i] for i in lenient)),
                    'top_score': float(scores.max()),
                })
                if name == 'screens':
                    mask = np.ones(len(scores), dtype=bool)
                    mask[list(lenient)] = False
                    rows[-1]['nonrelevant_scores'] = scores[mask]
            per_config[label] = rows
            splits = {'all': rows}
            for ql in ('en', 'bcs'):
                for tl in ('en', 'bcs'):
                    splits[f'{ql}->{tl}'] = [r for r in rows if r['query_language'] == ql and r['target_language'] == tl]
            result['configs'].setdefault(name, {})[label] = {
                split: {'strict': summarize(sub, 'strict'), 'lenient': summarize(sub, 'lenient')}
                for split, sub in splits.items() if sub}
        for candidate in ('gemma-768', 'gemma-512'):
            for baseline in ('harrier', 'harrier-stored'):
                for key in ('lenient', 'strict'):
                    result['paired'][f'{name}:{candidate}-vs-{baseline}:{key}'] = paired(
                        per_config[baseline], per_config[candidate], key)
            for ql in ('en', 'bcs'):
                base = [r for r in per_config['harrier'] if r['query_language'] == ql]
                cand = [r for r in per_config[candidate] if r['query_language'] == ql]
                result['paired'][f'{name}:{candidate}-vs-harrier:lenient:query-{ql}'] = paired(base, cand, 'lenient')
        if name == 'screens':
            harrier = per_config['harrier']
            harrier_pass = float(np.mean([(r['nonrelevant_scores'] >= HARRIER_SCREEN_FLOOR).mean() for r in harrier]))
            harrier_keep = float(np.mean([r['relevant_score'] >= HARRIER_SCREEN_FLOOR for r in harrier]))
            floors = {'harrier': {'floor': HARRIER_SCREEN_FLOOR, 'relevant_kept': harrier_keep,
                                  'nonrelevant_passing': harrier_pass}}
            for label in ('gemma-768', 'gemma-512'):
                rows = per_config[label]
                pooled = np.concatenate([r['nonrelevant_scores'] for r in rows])
                matched = float(np.quantile(pooled, 1 - harrier_pass))
                floors[label] = {
                    'floor_matching_harrier_nonrelevant_rate': matched,
                    'relevant_kept_at_that_floor': float(np.mean([r['relevant_score'] >= matched for r in rows])),
                    'nonrelevant_score_p50_p90_p99': np.quantile(pooled, [.5, .9, .99]).tolist(),
                    'relevant_score_p10_p50': np.quantile([r['relevant_score'] for r in rows], [.1, .5]).tolist(),
                }
            pooled = np.concatenate([r['nonrelevant_scores'] for r in harrier])
            floors['harrier']['nonrelevant_score_p50_p90_p99'] = np.quantile(pooled, [.5, .9, .99]).tolist()
            floors['harrier']['relevant_score_p10_p50'] = np.quantile(
                [r['relevant_score'] for r in harrier], [.1, .5]).tolist()
            result['screen_floor'] = floors
        for rows in per_config.values():
            for row in rows:
                row.pop('nonrelevant_scores', None)
        private_rows[name] = per_config
    (ROOT / 'scores-private.json').write_text(json.dumps(private_rows, ensure_ascii=False))
    (ROOT / 'scores.json').write_text(json.dumps(result, indent=1))
    if publish:
        publish.write_text(json.dumps(result, indent=1) + '\n')
    for name, configs in result['configs'].items():
        for label, splits in configs.items():
            line = ' '.join(f"{split}:{v['lenient']['top1']}/{v['lenient']['queries']}"
                            for split, v in splits.items())
            a = splits['all']
            print(f"{name:8} {label:15} lenient {line} | top5 {a['lenient']['top5']} mrr {a['lenient']['mrr10']:.3f}"
                  f" | strict top1 {a['strict']['top1']} mrr {a['strict']['mrr10']:.3f}")
    for key, value in result['paired'].items():
        print(key, '%+.1f [%+.1f, %+.1f] n=%d' % (value['delta_top1_points'], *value['bootstrap_95'], value['clusters']))
    print(json.dumps(result['screen_floor'], indent=1))


if __name__ == '__main__':
    main()
