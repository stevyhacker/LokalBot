#!/usr/bin/env python3
"""Fixed-runtime, fixed-prompt model selection with sealed confirmation.

Only synthetic prefixes enter native inference and Claude. Reference futures,
model identities and latency never enter blinded judging. All GPU runs are
serial. This script neither changes app preferences nor installs models.
"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import tempfile
import time

import claude_judge as judge
from quality_replay import WORD, digest, fold, predicted_words


APP = Path('/private/tmp/lokalbot-model-study-20261010/benchmark-LokalBot.app/Contents/MacOS/LokalBot')
APP_SHA = '29a8cec1971d86b877dfa910f01b82fddd587a42e2532712b5841551e7612eeb'
BASE_MODEL = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/gemma-4-E2B.i1-Q6_K.gguf'
BASE_SHA = '20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629'
IDS = ['baseline', 'lfm12', 'qwen2', 'lfm26', 'gemma4', 'luchador']
ORDERS = [IDS, list(reversed(IDS)), ['gemma4', 'lfm26', 'baseline', 'luchador', 'lfm12', 'qwen2']]
SETTINGS = dict(selectiveOneWordHybrid=True, maxWords=4, maxTokens=6,
                temperature=0.1, repeatPenalty=1.05, appContext=True)
ROOT = Path('/private/tmp/lokalbot-model-study-20261010')
DEFAULT_OUTPUT = Path(__file__).resolve().parent / 'results/2026-10-10-models'


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def now():
    return datetime.now(timezone.utc).isoformat()


def make_cases(corpus):
    result = {s: ([], {}) for s in ['screen', 'confirmation']}
    for category, sentences in corpus['categories'].items():
        assert len(sentences) == 12
        for number, sentence in enumerate(sentences):
            split = 'screen' if number < 8 else 'confirmation'
            cases, refs = result[split]
            phrase_id = f'{category}-{number:02}'
            words = list(WORD.finditer(sentence))
            positions = []
            for fraction in [.25, .5, .75]:
                index = max(2, min(len(words) - 2, round(fraction * len(words))))
                positions.append((index, 0))
            for fraction in [.4, .7]:
                candidates = [i for i in range(2, len(words) - 1) if len(words[i].group()) >= 4]
                index = min(candidates, key=lambda i: (abs(i - fraction * len(words)), i))
                positions.append((index, max(1, len(words[index].group()) // 2)))
            assert len(set(positions)) == 5, phrase_id
            for index, offset in sorted(positions):
                caret = words[index].start() + offset
                ident = f'{phrase_id}:{index}:{offset}'
                cases.append({'id': ident, 'prefix': sentence[:caret],
                              'appName': 'Mail' if category == 'email' else 'Notes',
                              'bundleID': 'com.apple.mail' if category == 'email' else 'com.apple.Notes',
                              'wordPrefixIsValidWord': True})
                refs[ident] = {'phraseID': phrase_id, 'category': category,
                               'language': 'sr' if category.startswith('sr_') else 'en',
                               'kind': 'midword' if offset else 'boundary',
                               'typed': words[index].group()[:offset],
                               'words': [fold(w.group()) for w in words[index:]],
                               'matchingCharacterCredits': [w.end() - caret for w in words[index:]]}
    return result


def prepare(output):
    output.mkdir(parents=True, exist_ok=False)
    corpus_path = Path(__file__).with_name('model-study-corpus.json')
    corpus = read(corpus_path)
    (output / corpus_path.name).write_bytes(corpus_path.read_bytes())
    for split, (cases, refs) in make_cases(corpus).items():
        write(output / f'{split}-input.json', {'cases': cases})
        write(output / f'{split}-references.json', refs)
    manifest = read(ROOT / 'model-manifest.json')
    manifest.insert(0, {'id': 'baseline', 'path': str(BASE_MODEL), 'sha256': BASE_SHA,
                        'bytes': BASE_MODEL.stat().st_size, 'file': BASE_MODEL.name,
                        'upstream': 'google/gemma-4-E2B', 'description': 'Installed model, hybrid enabled'})
    write(output / 'models.json', manifest)
    write(output / 'plan.json', {
        'createdAtUTC': now(), 'status': 'frozen before any model inference',
        'app': str(APP), 'appSHA256': APP_SHA, 'settings': SETTINGS,
        'implicitFixedSettings': {'topP': .7, 'topK': 20, 'minP': .08, 'seed': 0xC0FFEE,
                                 'selectedTokenGate': .1, 'fallbackBoundaryMass': .31},
        'models': IDS, 'screenOrders': ORDERS, 'screenPhrases': 64, 'confirmationPhrases': 32,
        'screenCheckpoints': 320, 'confirmationCheckpoints': 160,
        'quality': 'Judge every nonempty unique suggestion across all models, silence=0. Exact reference agreement is secondary. Phrase-cluster paired bootstrap (5000 samples).',
        'judge': 'Claude Opus, same prior inline-writing rubric, no futures, identities, latency or source. 32 blind reversed-option repeats on screen and 16 on confirmation.',
        'selection': 'Choose the non-baseline model with highest mean Claude utility on screen. Tie: fewer negative outputs, then lower warm mean latency. Confirm without tuning on sealed second split against installed hybrid and original current decoder.',
        'timing': 'Three serial rounds, reordered across models; 10 excluded warmup calls per process. All per-request latencies include native generation, healing, gating and normalization. Exclude cold load, debounce, AX and overlay. Process launch to first observation is reported separately, including load and warmup; not a pure load timer.',
        'failurePolicy': 'A runtime load failure is an integration failure, never a low-quality score. Keep evidence and use a separately documented compatible runtime only if necessary.',
        'fixedGateLimitation': 'Current .1/.31 gates were calibrated for Gemma, not each vocabulary. Primary tests are drop-in compatibility, not the intrinsic model ceiling. Report coverage and language separately.',
        'scope': 'Synthetic model research; no app default changes, no local UI tests, no CI changes.',
        'inputsSHA256': {p.name: digest(p) for p in output.glob('*.json')},
        'scriptSHA256': digest(__file__), 'hardware': {
            'chip': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
            'memoryBytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
            'os': subprocess.check_output(['sw_vers'], text=True).strip()},
        'power': subprocess.check_output(['pmset', '-g', 'batt'], text=True).strip()})
    print(json.dumps({'prepared': str(output), 'screen': 320, 'confirmation': 160}), flush=True)


def percentile(values, q):
    return sorted(values)[max(0, math.ceil(len(values) * q) - 1)]


def metrics(observations, refs):
    assert [r['id'] for r in observations] == list(refs)
    detail = []
    for row in observations:
        ref = refs[row['id']]
        matches = 0
        for predicted, expected in zip(predicted_words(row['text'], ref['typed']), ref['words']):
            if predicted != expected:
                break
            matches += 1
        detail.append({**ref, 'id': row['id'], 'shown': bool(row['text']), 'correct': bool(matches),
                       'matchingWords': matches, 'matchingCharacters': ref['matchingCharacterCredits'][matches - 1] if matches else 0,
                       'latencyMs': row['latencyMs'], 'error': row.get('error')})
    def aggregate(group):
        times = [x['latencyMs'] for x in group]
        return {'n': len(group), 'shown': sum(x['shown'] for x in group),
                'correctFirstWord': sum(x['correct'] for x in group),
                'matchingCharacters': sum(x['matchingCharacters'] for x in group),
                'errors': sum(bool(x['error']) for x in group), 'meanMs': statistics.mean(times),
                'p50Ms': percentile(times, .5), 'p95Ms': percentile(times, .95)}
    return {'overall': aggregate(detail),
            **{key: {name: aggregate([x for x in detail if x[key] == name]) for name in sorted({x[key] for x in detail})}
               for key in ['language', 'category', 'kind']}}


def run_one(output, split, model_id, round_index, mode='hybrid'):
    tag = model_id if mode == 'hybrid' else model_id + '-' + mode
    directory = output / f'{split}-{round_index}-{tag}'
    if (directory / 'receipt.json').exists() and read(directory / 'receipt.json').get('complete'):
        print(json.dumps({'cached': directory.name}), flush=True)
        return
    if directory.exists():
        raise RuntimeError(f'Incomplete run preserved for inspection: {directory}')
    models = {m['id']: m for m in read(output / 'models.json')}
    model = models[model_id]
    path = Path(model['path'])
    assert digest(APP) == APP_SHA and digest(path) == model['sha256']
    directory.mkdir()
    cases = read(output / f'{split}-input.json')['cases']
    refs = read(output / f'{split}-references.json')
    warmups = [{'id': f'warmup-{i}', 'prefix': p, 'appName': 'Notes', 'bundleID': 'com.apple.Notes'}
               for i, p in enumerate(['Please review the ', 'I will send you the ', 'We can discuss this ',
                                      'Hvala na pomoći, ', 'Хвала на помоћи, '] * 2)]
    settings = dict(SETTINGS)
    if mode == 'current':
        settings['selectiveOneWordHybrid'] = False
    elif mode == 'ungated':
        settings.update(selectiveOneWordHybrid=False, confidenceGate=False)
    write(directory / 'input.json', {'cases': warmups + cases, **settings})
    receipt = {'startedAtUTC': now(), 'appSHA256': APP_SHA, 'modelSHA256': model['sha256'],
               'inputSHA256': digest(directory / 'input.json'), 'settings': settings, 'excludedWarmups': 10,
               'power': subprocess.check_output(['pmset', '-g', 'batt'], text=True).strip()}
    write(directory / 'receipt.json', receipt)
    print(json.dumps({'starting': directory.name}), flush=True)
    started = time.monotonic()
    first_output = None
    with tempfile.TemporaryDirectory(prefix='lokalbot-model-eval-') as tmp:
        root = Path(tmp)
        (root / 'home').mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(root / 'home'),
                   LOKALBOT_STORAGE_ROOT=str(root / 'storage'), LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.' + root.name)
        with (directory / 'raw-observations.jsonl').open('w') as stdout, (directory / 'stderr.log').open('w') as stderr:
            process = subprocess.Popen(['/usr/bin/time', '-l', str(APP), '--cotyping-replay',
                                        str(directory / 'input.json'), '--model-path', str(path)],
                                       env=env, stdout=subprocess.PIPE, stderr=stderr, text=True)
            for line in process.stdout:
                if first_output is None:
                    first_output = time.monotonic() - started
                stdout.write(line)
                stdout.flush()
            code = process.wait(timeout=1800)
    receipt.update(exitCode=code, wallSeconds=time.monotonic() - started, launchToFirstObservationSeconds=first_output)
    log = (directory / 'stderr.log').read_text(errors='replace')
    rss = re.search(r'(\d+)\s+maximum resident set size', log)
    receipt['maximumResidentBytes'] = int(rss.group(1)) if rss else None
    write(directory / 'receipt.json', receipt)
    if code:
        raise RuntimeError(f'Native replay failed: {directory.name}, exit {code}')
    raw = rows(directory / 'raw-observations.jsonl')
    assert [r['id'] for r in raw] == [c['id'] for c in warmups + cases]
    observations = raw[10:]
    assert not any(r.get('error') for r in raw), 'Errors in replay'
    assert all(r.get('selectiveOneWordHybrid') == settings['selectiveOneWordHybrid'] for r in raw)
    assert all(not r.get('usedPromptOverride') and not r.get('stopAtDisplayLimit') for r in raw)
    base_path = output / f'{split}-1-baseline/observations.jsonl'
    if base_path.exists():
        base = rows(base_path)
        assert [(r['id'], r['prompt']) for r in observations] == [(r['id'], r['prompt']) for r in base], 'Prompt drift'
    repeated_path = output / f'{split}-1-{tag}/observations.jsonl'
    if round_index > 1:
        previous = rows(repeated_path)
        receipt['repeatedOutputDifferences'] = sum((a['text'], a.get('suppression')) != (b['text'], b.get('suppression'))
                                                  for a, b in zip(observations, previous))
    (directory / 'observations.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in observations))
    report = metrics(observations, refs)
    write(directory / 'metrics.json', report)
    receipt.update(complete=True, finishedAtUTC=now(), observationsSHA256=digest(directory / 'observations.jsonl'))
    write(directory / 'receipt.json', receipt)
    print(json.dumps({'finished': directory.name, **report['overall']}), flush=True)


def prepare_judge(output, split, arms):
    target = output / f'judge-{split}'
    target.mkdir()
    all_rows = {arm: rows(output / f'{split}-1-{arm}/observations.jsonl') for arm in arms}
    refs = read(output / f'{split}-references.json')
    inputs = read(output / f'{split}-input.json')['cases']
    cases = []
    for i, item in enumerate(inputs):
        case = {'id': item['id'], 'prefix': item['prefix'], **{k: refs[item['id']][k] for k in ['phraseID', 'category', 'language', 'kind']},
                'policies': {arm: all_rows[arm][i]['text'] for arm in arms}}
        assert all(all_rows[arm][i]['id'] == item['id'] for arm in arms)
        cases.append(case)
    primary = sorted([c for c in cases if any(c['policies'].values())], key=lambda c: judge.digest('model-study:' + c['id']))
    repeated = primary[:32 if split == 'screen' else 16]
    mapping, batches = {}, []
    for stage, selected in [('primary', primary), ('repeat', repeated)]:
        blinded = []
        for case in selected:
            packet = judge.blind_case(case, stage == 'repeat')
            mapping[packet['id']] = {'caseID': case['id'], 'stage': stage,
                                     'options': {o['id']: o['continuation'] for o in packet['options']}}
            blinded.append(packet)
        for start in range(0, len(blinded), 12):
            name = f'{stage}-{start // 12 + 1:02}'
            directory = target / 'batches' / name
            directory.mkdir(parents=True)
            packet = {'cases': blinded[start:start + 12]}
            write(directory / 'packet.json', packet)
            request = judge.RUBRIC + json.dumps(packet['cases'], ensure_ascii=False, separators=(',', ':'))
            (directory / 'request.txt').write_text(request)
            batches.append({'id': name, 'stage': stage, 'cases': len(packet['cases']), 'requestSHA256': judge.digest(request)})
    write(target / 'cases.json', cases)
    write(target / 'private-mapping.json', mapping)
    (target / 'system.txt').write_text(judge.SYSTEM)
    write(target / 'schema.json', judge.SCHEMA)
    write(target / 'protocol.json', {'createdAtUTC': now(), 'arms': arms, 'split': split,
                                    'counts': {'all': len(cases), 'primary': len(primary), 'repeat': len(repeated)},
                                    'blinding': 'Every nonempty unique option, randomized anonymous order. No future references, model labels, latency or source code.',
                                    'casesSHA256': digest(target / 'cases.json'), 'batches': batches})
    print(json.dumps({'judgePrepared': split, 'batches': len(batches), 'primary': len(primary)}), flush=True)


def bootstrap(values, phrase_ids, samples=5000):
    groups = defaultdict(list)
    for value, phrase in zip(values, phrase_ids):
        groups[phrase].append(value)
    totals = [(sum(v), len(v)) for v in groups.values()]
    rng = random.Random(10102026)
    draws = []
    for _ in range(samples):
        picked = rng.choices(totals, k=len(totals))
        draws.append(sum(x[0] for x in picked) / sum(x[1] for x in picked))
    return {'mean': statistics.mean(values), 'low95': percentile(draws, .025), 'high95': percentile(draws, .975),
            'phrases': len(groups), 'resamples': samples}


def analyze(output, split):
    target = output / f'judge-{split}'
    protocol, cases, mapping = (read(target / name) for name in ['protocol.json', 'cases.json', 'private-mapping.json'])
    ratings = {'primary': {}, 'repeat': {}}
    judge_models = set()
    discrepancies = 0
    for batch in protocol['batches']:
        directory = target / 'batches' / batch['id']
        result = read(directory / 'ratings.json')
        judge_models.update(read(directory / 'receipt.json')['models'])
        discrepancies += len(read(directory / 'preference-disagreements.json'))
        for case in result['cases']:
            info = mapping[case['id']]
            ratings[info['stage']][info['caseID']] = {info['options'][r['id']]: r for r in case['ratings']}
    default = {'utility': 0, 'first_word': 0, 'flags': [], 'reason': 'No suggestion'}
    scores = {c['id']: {a: ratings['primary'].get(c['id'], {}).get(t, default) if not t else ratings['primary'][c['id']][t]
                        for a, t in c['policies'].items()} for c in cases}
    result = {'split': split, 'judgeModels': sorted(judge_models), 'n': len(cases), 'arms': {},
              'preferenceDisagreements': discrepancies, 'comparison': {}}
    for arm in protocol['arms']:
        def summarize(group):
            values = [scores[c['id']][arm]['utility'] for c in group]
            return {'n': len(group), 'meanUtility': statistics.mean(values),
                    'useful': sum(v > 0 for v in values), 'bad': sum(v < 0 for v in values),
                    'neutralShown': sum(scores[c['id']][arm]['utility'] == 0 and bool(c['policies'][arm]) for c in group),
                    'silence': sum(not c['policies'][arm] for c in group)}
        result['arms'][arm] = {'overall': summarize(cases),
                                **{key: {v: summarize([c for c in cases if c[key] == v]) for v in sorted({c[key] for c in cases})}
                                   for key in ['language', 'category', 'kind']}}
        runs = sorted(output.glob(f'{split}-*-{arm}/observations.jsonl'))
        times = [r['latencyMs'] for path in runs for r in rows(path)]
        result['arms'][arm]['latency'] = {'rounds': len(runs), 'requests': len(times), 'meanMs': statistics.mean(times),
                                          'p50Ms': percentile(times, .5), 'p95Ms': percentile(times, .95)}
        reference = read(output / f'{split}-1-{arm}/metrics.json')
        result['arms'][arm]['reference'] = reference
        result['arms'][arm]['repeatedOutputDifferences'] = sum(read(p.parent / 'receipt.json').get('repeatedOutputDifferences', 0) for p in runs)
        if arm != 'baseline':
            deltas = [scores[c['id']][arm]['utility'] - scores[c['id']]['baseline']['utility'] for c in cases]
            result['comparison'][arm] = {'utilityDelta': bootstrap(deltas, [c['phraseID'] for c in cases]),
                                         'wins': sum(d > 0 for d in deltas), 'ties': sum(d == 0 for d in deltas), 'losses': sum(d < 0 for d in deltas)}
            paired_runs = min(len(runs), len(list(output.glob(f'{split}-*-baseline/observations.jsonl'))))
            latency_deltas = []
            phrases = []
            for round_index in range(1, paired_runs + 1):
                a = rows(output / f'{split}-{round_index}-{arm}/observations.jsonl')
                b = rows(output / f'{split}-{round_index}-baseline/observations.jsonl')
                for case, x, y in zip(cases, a, b):
                    assert case['id'] == x['id'] == y['id']
                    latency_deltas.append(x['latencyMs'] - y['latencyMs'])
                    phrases.append(case['phraseID'])
            result['comparison'][arm]['latencyDeltaMs'] = bootstrap(latency_deltas, phrases)
    repeated = []
    for ident, by_text in ratings['repeat'].items():
        for text, rating in by_text.items():
            old = ratings['primary'][ident][text]
            repeated.append({'case': ident, 'text': text, 'original': old['utility'], 'repeat': rating['utility']})
    result['reliability'] = {'options': len(repeated), 'exactAgreement': sum(r['original'] == r['repeat'] for r in repeated),
                              'signAgreement': sum((r['original'] > 0, r['original'] < 0) == (r['repeat'] > 0, r['repeat'] < 0) for r in repeated)}
    result['shortSuggestionSensitivity'] = {}
    for arm in protocol['arms']:
        adjusted = [0 if len(c['policies'][arm].strip()) <= 3 and scores[c['id']][arm]['utility'] > 0
                    else scores[c['id']][arm]['utility'] for c in cases]
        result['shortSuggestionSensitivity'][arm] = statistics.mean(adjusted)
    write(target / 'scores.json', scores)
    write(target / 'repeat-agreement.json', repeated)
    write(output / f'{split}-analysis.json', result)
    print(json.dumps({arm: {'quality': data['overall'], 'latency': data['latency']} for arm, data in result['arms'].items()}, indent=2))
    if split == 'screen':
        candidates = [a for a in protocol['arms'] if a not in ['baseline', 'baseline-current']]
        best = sorted(candidates, key=lambda a: (-result['arms'][a]['overall']['meanUtility'], result['arms'][a]['overall']['bad'], result['arms'][a]['latency']['meanMs']))[0]
        write(output / 'selection.json', {'selectedAtUTC': now(), 'model': best, 'rule': read(output / 'plan.json')['selection'],
                                          'screenAnalysisSHA256': digest(output / 'screen-analysis.json')})
        print(json.dumps({'selected': best}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'run', 'judge-prepare', 'judge-run', 'analyze'])
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--split', choices=['screen', 'confirmation'], default='screen')
    parser.add_argument('--model', choices=IDS)
    parser.add_argument('--round', type=int, default=1)
    parser.add_argument('--mode', choices=['hybrid', 'current', 'ungated'], default='hybrid')
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args()
    output = args.output.resolve()
    if args.action == 'prepare':
        prepare(output)
    elif args.action == 'run':
        if args.model:
            run_one(output, args.split, args.model, args.round, args.mode)
        else:
            orders = ORDERS if args.split == 'screen' else [
                ['baseline', read(output / 'selection.json')['model']],
                [read(output / 'selection.json')['model'], 'baseline'],
                ['baseline', read(output / 'selection.json')['model']]]
            for index, order in enumerate(orders, 1):
                for model in order:
                    run_one(output, args.split, model, index)
            for index in range(1, 4 if args.split == 'confirmation' else 2):
                run_one(output, args.split, 'baseline', index, 'current')
    elif args.action == 'judge-prepare':
        arms = IDS + ['baseline-current'] if args.split == 'screen' else ['baseline', read(output / 'selection.json')['model'], 'baseline-current']
        prepare_judge(output, args.split, arms)
    elif args.action == 'judge-run':
        judge.run(output / f'judge-{args.split}', args.jobs, [], 'claude-opus-5-5')
    elif args.action == 'analyze':
        analyze(output, args.split)


if __name__ == '__main__':
    main()
