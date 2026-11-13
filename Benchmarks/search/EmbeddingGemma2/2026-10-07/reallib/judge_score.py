"""Judged precision at one per model, with paired cluster bootstrap."""
import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

from judge import CONFIGS, OUTPUT, ROOT, top_documents


def interval(pairs):
    """pairs: list of (cluster, baseline hit, candidate hit)."""
    groups = defaultdict(list)
    for cluster, base, cand in pairs:
        groups[cluster].append(float(cand) - float(base))
    deltas = np.asarray([np.mean(v) for v in groups.values()])
    weights = np.asarray([len(v) for v in groups.values()], dtype=float)
    draws = np.random.default_rng(61007).integers(0, len(deltas), size=(10000, len(deltas)))
    boot = (deltas[draws] * weights[draws]).sum(axis=1) / weights[draws].sum(axis=1)
    return {'delta_points': float((deltas * weights).sum() / weights.sum() * 100),
            'bootstrap_95': (np.percentile(boot, [2.5, 97.5]) * 100).tolist(), 'clusters': len(deltas)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--publish', type=Path)
    publish = parser.parse_args().publish
    queries, tops = top_documents()
    verdicts = {tuple(row['pair']): row['relevant']
                for row in map(json.loads, OUTPUT.read_text().splitlines())}
    corpus = {name: json.loads((ROOT / f'corpus/{name}.json').read_text()) for name in ('meetings', 'screens')}
    result = {}
    for name in corpus:
        selected = [q for q in queries if q['corpus'] == name]
        cluster = [corpus[name][[r['id'] for r in corpus[name]].index(q['target'])].get('meeting_id', q['target'])
                   for q in selected]
        hits = {config: [verdicts.get((name, i, tops[(name, i, config)])) for i in range(len(selected))]
                for config in CONFIGS}
        missing = sum(v is None for values in hits.values() for v in values)
        section = {'queries': len(selected), 'unjudged': missing}
        for config in CONFIGS:
            for language in ('all', 'en', 'bcs'):
                chosen = [h for h, q in zip(hits[config], selected)
                          if h is not None and language in ('all', q['language'])]
                section.setdefault(config, {})[language] = {'judged': len(chosen), 'relevant_top1': sum(chosen)}
        for candidate in ('gemma-768', 'gemma-512'):
            for language in ('all', 'en', 'bcs'):
                rows = [(c, b, k) for c, b, k, q in zip(cluster, hits['harrier'], hits[candidate], selected)
                        if b is not None and k is not None and language in ('all', q['language'])]
                section[f'{candidate}-vs-harrier:{language}'] = interval(rows)
        result[name] = section
    text = json.dumps(result, indent=1)
    (ROOT / 'judged.json').write_text(text)
    if publish:
        publish.write_text(text + '\n')
    for name, section in result.items():
        print(name, 'unjudged', section['unjudged'])
        for config in CONFIGS:
            print(' ', config.ljust(10), ' '.join(f"{lang}:{v['relevant_top1']}/{v['judged']}"
                                                  for lang, v in section[config].items()))
        for key, value in section.items():
            if '-vs-' in key:
                print('  ', key, '%+.1f [%+.1f, %+.1f]' % (value['delta_points'], *value['bootstrap_95']))


if __name__ == '__main__':
    main()
