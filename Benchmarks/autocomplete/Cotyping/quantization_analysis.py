"""Analyze the fixed-decoder quantization replay; never invokes inference."""
import argparse
from collections import Counter, defaultdict
from pathlib import Path
import statistics

import quantization_experiment as study
import cancellation_experiment as cancel
import claude_judge as judge


def paired(values):
    result = cancel.paired(values)
    if result is None:
        return None
    result['delta'] = result.pop('deltaMs')
    return result


def reference_match(text, info):
    """Complete the typed fragment before comparing the first whole word."""
    if not text:
        return False
    first = study.WORD.match((info['typed'] + text).lstrip())
    return bool(first and first.group().casefold() == info['referenceWord'].casefold())


def paired_cancellation(base, candidate, metadata):
    returned = defaultdict(list)
    replacement = defaultdict(list)
    counts = {arm: Counter() for arm in ['default', 'candidate']}
    recovery = []
    for identifier, info in metadata.items():
        if identifier not in base or info['kind'] != 'cancel':
            continue
        following = identifier.removesuffix('-cancel') + '-replacement'
        cold = identifier.removesuffix('-cancel') + '-cold'
        a, b = base[identifier], candidate[identifier]
        for arm, row, data in [('default', a, base), ('candidate', b, candidate)]:
            counts[arm]['attempted'] += 1
            counts[arm]['issued'] += row.get('cancellationRequestedAfterMs') is not None
            counts[arm]['cancelled'] += bool(row.get('cancelled'))
            keys = ['prompt', 'text', 'suppression', 'error', 'cancelled']
            if any(data[following].get(k) != data[cold].get(k) for k in keys):
                recovery.append(dict(arm=arm, id=following))
        if not all(row.get('cancelled') and row.get('cancellationRequestedAfterMs') is not None for row in [a, b]):
            continue
        returned[info['scenario']].append(tuple(row['latencyMs'] - row['cancellationRequestedAfterMs'] for row in [a, b]))
        replacement[info['scenario']].append(tuple(
            data[following]['replayCompletedAtMs'] - (row['generationStartedAtMs'] + row['cancellationRequestedAfterMs'])
            for row, data in [(a, base), (b, candidate)]))
    return returned, replacement, counts, recovery


def subsets(meta, identifiers):
    yield 'all', list(identifiers)
    for language in ['en', 'sr_latn']:
        yield language, [i for i in identifiers if meta[i]['language'] == language]
    for kind in ['boundary', 'midword', 'cold', 'warm']:
        selected = [i for i in identifiers if meta[i]['kind'] == kind]
        if selected:
            yield kind, selected


def timing(root):
    meta = study.read(root/'case-meta.json')
    report = dict(normal={}, cancellation={}, resources={})
    for mode in ['production', 'matched', 'steady']:
        report['normal'][mode] = {}
        for dataset in ['fresh', 'long', 'dynamic'] if mode == 'production' else ['fresh']:
            output = report['normal'][mode][dataset] = {}
            for arm in study.IDS:
                run_mode = 'production' if mode == 'steady' else mode
                round_numbers = [3, 4] if mode == 'steady' else [1, 2]
                rounds = [(study.observed(root, run_mode, dataset, 'q6', r), study.observed(root, run_mode, dataset, arm, r)) for r in round_numbers]
                output[arm] = {}
                for category, identifiers in subsets(meta, rounds[0][0]):
                    groups = defaultdict(list); both_shown = defaultdict(list)
                    shown = {'default': [], 'candidate': []}
                    for baseline, candidate in rounds:
                        assert baseline.keys() == candidate.keys()
                        for identifier in identifiers:
                            a, b = baseline[identifier], candidate[identifier]
                            assert a['prompt'] == b['prompt']
                            pair = (a['latencyMs'], b['latencyMs'])
                            groups[meta[identifier]['scenario']].append(pair)
                            if a['text'] and b['text']:
                                both_shown[meta[identifier]['scenario']].append(pair)
                            for name, row in [('default', a), ('candidate', b)]:
                                if row['text']:
                                    shown[name].append(row['latencyMs'])
                    output[arm][category] = dict(paired=paired(groups), bothShown=paired(both_shown),
                        shownOnly={name:cancel.metrics(vals) if vals else None for name, vals in shown.items()})
    for arm in study.IDS:
        groups = defaultdict(list); replacements = defaultdict(list)
        counts = {'default': Counter(), 'candidate': Counter()}; failures = []
        for r in [1, 2]:
            a = study.observed(root, 'production', 'cancellation', 'q6', r)
            b = study.observed(root, 'production', 'cancellation', arm, r)
            g, rep, c, errors = paired_cancellation(a, b, meta)
            for key, vals in g.items(): groups[key].extend(vals)
            for key, vals in rep.items(): replacements[key].extend(vals)
            for key, vals in c.items(): counts[key].update(vals)
            failures.extend(dict(error, round=r) for error in errors)
        report['cancellation'][arm] = dict(returned=paired(groups), throughReplacement=paired(replacements),
                                          counts=counts, recoveryMismatches=failures)
        receipts = [study.read(p) for p in sorted((root/'runs').glob(f'production-*-{arm}-*/receipt.json'))]
        assert len(receipts) == 10 and all(r['complete'] for r in receipts)
        report['resources'][arm] = dict(processes=len(receipts), **{
            key:dict(median=statistics.median(r[key] for r in receipts), maximum=max(r[key] for r in receipts))
            for key in ['maximumResidentBytes', 'peakFootprintBytes', 'launchToFirstObservationSeconds']})
    return report


def output_summary(root):
    meta = study.read(root/'case-meta.json'); report = {}
    for mode in ['production', 'matched']:
        report[mode] = {}
        baseline = study.observed(root, mode, 'fresh', 'q6')
        for arm in study.IDS:
            data = study.observed(root, mode, 'fresh', arm)
            report[mode][arm] = {}
            for category, identifiers in subsets(meta, data):
                report[mode][arm][category] = dict(n=len(identifiers), shown=sum(bool(data[i]['text']) for i in identifiers),
                    sameAsQ6=sum(data[i]['text'] == baseline[i]['text'] for i in identifiers),
                    referenceFirstWord=sum(reference_match(data[i]['text'], meta[i]) for i in identifiers),
                    suppression=dict(Counter(data[i].get('suppression', 'shown') for i in identifiers)))
    return report


def load_scores(root):
    folder = root/'judge'; protocol = study.read(folder/'protocol.json')
    assert study.sha(folder/'cases.json') == protocol['casesSHA256']
    cases = study.read(folder/'cases.json'); by_id = {c['id']:c for c in cases}
    mapping = study.read(folder/'private-mapping.json')
    zero = dict(utility=0, first_word=0, flags=[], reason='No suggestion.')
    scores = {'primary': {}, 'repeat': {}}; model_names = set(); inconsistent = defaultdict(list)
    for batch in protocol['batches']:
        path = folder/'batches'/batch['id']
        receipt = study.read(path/'receipt.json')
        assert receipt['requestSHA256'] == batch['requestSHA256'] == study.sha(path/'request.txt')
        assert receipt['responseSHA256'] == study.sha(path/'response.json')
        assert not receipt['isError'] and not receipt['toolsEnabled']
        response = judge.parse_response(study.read(path/'response.json'))
        result = judge.validate_judgments(study.read(path/'packet.json'), study.read(path/'ratings.json'), strict_preference=False)
        assert response == result
        model_names.update(receipt['models'])
        inconsistent[batch['stage']].extend(mapping[r['id']]['caseID'] for r in judge.preference_disagreements(result))
        for row in result['cases']:
            info = mapping[row['id']]
            text_scores = {info['options'][r['id']]:r for r in row['ratings']}
            scores[info['stage']][info['caseID']] = {policy:(text_scores[text] if text else zero)
                for policy, text in by_id[info['caseID']]['policies'].items()}
    for case in cases:
        if not any(case['policies'].values()):
            scores['primary'][case['id']] = {policy:zero for policy in case['policies']}
    assert set(scores['primary']) == set(by_id)
    return cases, scores, dict(models=sorted(model_names), preferenceInconsistencies=inconsistent)


def rate_subset(cases, scores, arm, mode):
    policy = f'{arm}-{mode}'; baseline = f'q6-{mode}'
    groups = defaultdict(list); values = []; first = []; flags = Counter(); diffs = []
    for case in cases:
        rating = scores[case['id']][policy]
        value = rating['utility']; base = scores[case['id']][baseline]['utility']
        groups[case['scenario']].append((base, value))
        values.append(value); diffs.append(value-base); first.append(rating['first_word']); flags.update(rating['flags'])
    return dict(n=len(cases), shown=sum(bool(c['policies'][policy]) for c in cases),
                meanUtility=statistics.mean(values), utilityTotal=sum(values), firstWordTotal=sum(first),
                helpful=sum(v>0 for v in values), poor=sum(v<0 for v in values),
                wins=sum(v>0 for v in diffs), losses=sum(v<0 for v in diffs), ties=sum(v==0 for v in diffs),
                delta=paired(groups), flags=dict(flags))


def quality(root):
    cases, scores, report = load_scores(root)
    report['policies'] = {}
    metadata = {c['id']:c for c in cases}
    for mode in ['production', 'matched']:
        report['policies'][mode] = {}
        for arm in study.IDS:
            report['policies'][mode][arm] = {category:rate_subset([metadata[i] for i in identifiers], scores['primary'], arm, mode)
                for category, identifiers in subsets(metadata, metadata)}
    repeated = []
    for identifier, ratings in scores['repeat'].items():
        seen = set()
        for policy, text in metadata[identifier]['policies'].items():
            if not text or text in seen: continue
            seen.add(text)
            repeated.append(dict(id=identifier, text=text, primary=scores['primary'][identifier][policy]['utility'], repeat=ratings[policy]['utility']))
    report['repeat'] = dict(cases=len(scores['repeat']), options=len(repeated),
        exactUtilityAgreement=statistics.mean(r['primary']==r['repeat'] for r in repeated),
        showVsSilenceAgreement=statistics.mean((r['primary']>0)==(r['repeat']>0) for r in repeated),
        meanAbsoluteDifference=statistics.mean(abs(r['primary']-r['repeat']) for r in repeated), comparisons=repeated)
    inconsistent = set(report['preferenceInconsistencies'].get('primary', []))
    consistent_cases = [c for c in cases if c['id'] not in inconsistent]
    report['consistentPreferenceSensitivity'] = {f'{arm}-{mode}':rate_subset(consistent_cases, scores['primary'], arm, mode)
        for arm in study.IDS for mode in ['production', 'matched']}
    study.write(root/'quality-examples.json', [dict(c, ratings=scores['primary'][c['id']]) for c in cases])
    return report


def validate_saved(root):
    plan = study.read(root/'plan.json')
    assert study.sha(root/'corpus.json') == plan['corpusSHA256']
    assert study.sha(root/'quantization_experiment.py') == plan['runnerSHA256']
    for name, digest in plan['inputSHA256'].items():
        assert study.sha(root/'inputs'/name) == digest
    binary = study.read(root/'binary.json')
    models = {m['id']:m for m in study.read(root/'models.json')}
    receipts = sorted((root/'runs').glob('*/receipt.json'))
    assert len(receipts) == 65
    measured = warmups = stable = prompt_pairs = 0
    for path in receipts:
        receipt = study.read(path); folder = path.parent
        assert receipt['complete'] and receipt['exitCode'] == 0
        assert receipt['binarySHA256'] == binary['sha256']
        assert receipt['modelSHA256'] == models[receipt['arm']]['sha256']
        assert receipt['rawSHA256'] == study.sha(folder/'raw.jsonl')
        assert receipt['inputSHA256'] == study.sha(folder/'input.json')
        fixture = study.read(folder/'input.json'); raw = study.rows(folder/'raw.jsonl')
        assert [r['id'] for r in raw] == [c['id'] for c in fixture['cases']]
        assert len(set(r['id'] for r in raw)) == len(raw)
        assert all(not r.get('error') and not r['usedPromptOverride'] for r in raw)
        assert all(r['confidenceTrace'] == (receipt['mode'] == 'trace') and r['nativeThreads'] == 2
                   and r['nativeBatchThreads'] == 2 and r['searchExperiment'] == 'certified'
                   and r['selectiveOneWordHybrid'] and r['healingMode'] == 'prefixSearch' for r in raw)
        baseline = study.rows(root/'runs'/f"production-{receipt['dataset']}-q6-1/raw.jsonl")
        assert [(r['id'],r['prompt']) for r in raw] == [(r['id'],r['prompt']) for r in baseline]
        prompt_pairs += len(raw)-8
        if receipt['round'] > 1 and receipt['dataset'] != 'cancellation':
            previous = study.rows(root/'runs'/f"{receipt['mode']}-{receipt['dataset']}-{receipt['arm']}-1/raw.jsonl")
            assert [(r['text'],r.get('suppression')) for r in raw] == [(r['text'],r.get('suppression')) for r in previous]
            stable += len(raw)-8
        measured += len(raw)-8; warmups += 8
    assert measured == 12960 and warmups == 520
    return dict(processes=len(receipts), measured=measured, excludedWarmups=warmups,
                byteIdenticalPromptComparisons=prompt_pairs, deterministicRepeatedOutputs=stable,
                allComplete=True, noReplayErrors=True, fixedBinaryAndModelPins=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--without-judge', action='store_true')
    args=parser.parse_args(); root=args.root
    report=dict(validation=validate_saved(root), timing=timing(root), outputs=output_summary(root), models=study.read(root/'models.json'),
                matching=study.read(root/'matched.json'))
    if not args.without_judge: report['quality']=quality(root)
    study.write(root/'summary.json', report)
    for arm in study.IDS:
        print(arm, report['timing']['normal']['production']['fresh'][arm]['all']['paired'])


if __name__ == '__main__':
    main()
