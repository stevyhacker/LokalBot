"""Summarize frozen evaluation rows without changing labels, prompts or models."""
import hashlib
import json
from pathlib import Path
import statistics

from run import OUT, QUESTIONS, ROOT, rows, write

def read(path):
    return [json.loads(line) for line in path.read_text().splitlines()]

def percentile(values, q):
    a = sorted(values)
    index = (len(a) - 1) * q
    lo = int(index)
    return a[lo] + (a[min(lo+1, len(a)-1)] - a[lo]) * (index-lo)

CASES = {row['id']: row for row in rows()}
MAIN = {k: v for k, v in CASES.items() if v['suite'] == 'main'}

def summarize(predictions):
    result = {}
    for language in ['all', 'en', 'sr-Latn', 'sr-Cyrl']:
        cases = [v for v in MAIN.values() if language == 'all' or v['language'] == language]
        if not all(v['id'] in predictions for v in cases):
            continue
        confusion = {a: {b: 0 for b in ['ask','search']} for a in ['ask','search']}
        mistakes, times, conf_wrong = [], [], []
        for case in cases:
            p = predictions[case['id']]
            choice = p['choice']
            confusion[case['expected']][choice] += 1
            times.append(p['wall_ms'])
            if choice != case['expected']:
                mistakes.append(dict(case, predicted=choice, probability=p.get('probability')))
                if p.get('probability') is not None:
                    conf_wrong.append(p['probability'])
        n = len(cases)
        ask = sum(confusion['ask'].values())
        search = sum(confusion['search'].values())
        correct = n - len(mistakes)
        result[language] = dict(n=n, correct=correct, accuracy=correct/n,
            confusion=confusion, ask_recall=confusion['ask']['ask']/ask,
            search_to_ask_rate=confusion['search']['ask']/search,
            p50_ms=statistics.median(times), p95_ms=percentile(times,.95),
            mistakes=mistakes, errors_with_p_at_least_09=sum(p>=.9 for p in conf_wrong))
    regression = [c for c in CASES.values() if c['suite']=='regression']
    if all(c['id'] in predictions for c in regression):
        errors = [dict(c, predicted=predictions[c['id']]['choice']) for c in regression
                  if predictions[c['id']]['choice'] != c['expected']]
        result['regression'] = dict(n=len(regression), errors=errors)
    if 'all' in result:
        result['quality_gate_pass'] = (result['all']['accuracy'] >= .95 and
           min(result[l]['accuracy'] for l in ['en','sr-Latn','sr-Cyrl']) >= .90 and
           result['all']['search_to_ask_rate'] <= .02 and not result['regression']['errors'])
    return result

def main():
    baseline = read(OUT/'baseline.jsonl')
    summary = {'baseline': {}, 'models': {}, 'routes': {}, 'fallback': {}, 'parity': {}}
    baseline_maps = {}
    for variant in ['current','expanded']:
        predictions = {r['id']:r['predictions'][variant] for r in baseline}
        baseline_maps[variant] = predictions
        summary['baseline'][variant] = summarize(predictions)
    maps = {}
    for path in sorted(OUT.glob('*.jsonl')):
        if not path.stem.startswith(('mps-', 'mlx-')):
            continue
        model_rows = read(path)
        if len(model_rows) != 2 * len(CASES):
            continue
        variants = {}
        for order in ['primary','reversed']:
            variants[order] = {
                r['id']:dict(choice=r['answer']['choice'], wall_ms=r['wall_ms'],
                             probabilities=r['answer']['probabilities'],
                             probability=r['answer']['probabilities'][r['answer']['choice']])
                for r in model_rows if r['order']==order}
        predictions = variants['primary']
        maps[path.stem] = variants
        scored = summarize(predictions)
        scored['reversed'] = summarize(variants['reversed'])
        scored['option_order_flips'] = [dict(MAIN[k], primary=predictions[k]['choice'],
            reversed=variants['reversed'][k]['choice']) for k in MAIN
            if predictions[k]['choice'] != variants['reversed'][k]['choice']]
        metrics_path = path.with_name(path.stem+'-metrics.json')
        scored['runtime'] = json.loads(metrics_path.read_text()) if metrics_path.exists() else None
        summary['models'][path.stem] = scored
        for threshold in [.7,.8,.9,.95,.99]:
            combined = {}
            used = 0
            for key, prediction in predictions.items():
                confident = prediction['probability'] >= threshold
                used += int(confident and key in MAIN)
                choice = prediction['choice'] if confident else baseline_maps['current'][key]['choice']
                combined[key] = dict(prediction, choice=choice)
            fallback = summarize(combined)
            fallback['model_coverage'] = used/len(MAIN)
            summary['fallback'][f'{path.stem}@{threshold}'] = fallback

    # Run upstream routing without loading weights; compose its selected cached predictions.
    from laya import Router
    router = Router()
    decisions = {}
    for key, case in CASES.items():
        decisions[key] = {mode:dict(router.route(case['query'], QUESTIONS, **kwargs)) for mode, kwargs in [
            ('default', {}), ('language_hint', {'lang': case['language']})]}
    write('routing-decisions.json', decisions)
    names = {'english':'laya', 'multilingual':'laya-multilingual', 'typed-decisions':'laya-typed-decisions'}
    for backend in ['mps-float32','mlx-float32','mlx-float16']:
        if not all(f'{backend}-{m}' in maps for m in ['laya','laya-multilingual']):
            continue
        for route in ['default','language_hint']:
            predictions = {key:maps[f'{backend}-{names[decisions[key][route]["model"]]}']['primary'][key]
                           for key in CASES}
            scored = summarize(predictions)
            scored['latency_note'] = 'Selected direct-model times only; routing overhead, dual residency and cold switching not measured.'
            scored['selected_models'] = {lang: {m: sum(1 for k,c in MAIN.items() if c['language']==lang
                    and decisions[k][route]['model']==m) for m in names} for lang in ['en','sr-Latn','sr-Cyrl']}
            summary['routes'][f'{backend}-{route}'] = scored

    for mode in ['default','language_hint']:
        path = OUT/f'router-mps-{mode}.jsonl'
        if not path.exists():
            continue
        actual = read(path)
        if len(actual) != len(CASES):
            continue
        predictions = {r['id']:dict(choice=r['answer']['choice'], wall_ms=r['wall_ms'],
                    probability=r['answer']['probabilities'][r['answer']['choice']]) for r in actual}
        key = f'mps-float32-{mode}'
        scored = summarize(predictions)
        scored['selected_models'] = summary['routes'][key]['selected_models']
        scored['measured_live_router'] = True
        scored['reconstruction_mismatches'] = [r['id'] for r in actual if r['answer']['choice'] !=
            maps[f'mps-float32-{names[decisions[r["id"]][mode]["model"]]}']['primary'][r['id']]['choice']]
        scored['runtime'] = json.loads((OUT/'router-mps-metrics.json').read_text())
        summary['routes'][key] = scored

    # Compare identical fixtures and weight revisions across runtimes.
    for name, variants in maps.items():
        if not name.startswith('mlx-'):
            continue
        ref = 'mps-float32-' + name.split('-',2)[2]
        if ref not in maps:
            continue
        flips, deltas = [], []
        for order in ['primary','reversed']:
            for key in CASES:
                a, b = maps[ref][order][key], variants[order][key]
                deltas.extend(abs(a['probabilities'][label]-b['probabilities'][label]) for label in ['ask','search'])
                if a['choice'] != b['choice']:
                    flips.append(dict(id=key, order=order, upstream=a, mlx=b))
        summary['parity'][name] = dict(reference=ref, calls=2*len(CASES), flips=flips,
                                      max_probability_delta=max(deltas),
                                      mean_probability_delta=statistics.mean(deltas))
    write('summary.json', summary)
    for group in ['baseline','models','routes']:
        for name, s in summary[group].items():
            print(group, name, json.dumps({k:s['all'][k] for k in ['accuracy','search_to_ask_rate','p50_ms','p95_ms']}),
                  'langs', [round(s[l]['accuracy'],3) for l in ['en','sr-Latn','sr-Cyrl']],
                  'order_flips', len(s.get('option_order_flips', [])))
    print('parity', json.dumps(summary['parity']))

if __name__ == '__main__':
    main()
