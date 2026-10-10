#!/usr/bin/env python3
"""Fixed-prompt native midword experiment, with blind judging and matched gates."""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import tempfile
import time

import claude_judge as judge
import confidence_calibration as calibration
from model_study import read, write, rows, now, percentile
from quality_replay import WORD, digest

HERE = Path(__file__).resolve().parent
OUT = HERE / 'results/2026-10-10-midword'
TEMP = Path('/private/tmp/lokalbot-midword-20261010')
ARMS = ['baseline-control', 'baseline-fixed', 'luchador-control', 'luchador-fixed']
SETTINGS = dict(selectiveOneWordHybrid=True, maxWords=4, maxTokens=6,
                temperature=.1, repeatPenalty=1.05, appContext=True)


def prepare(corpus_name='midword-corpus.json'):
    if (OUT/'plan.json').exists():
        raise ValueError('Plan is already frozen')
    corpus = read(HERE/corpus_name)
    previous = read(HERE/'calibration-corpus.json')
    old = {text for value in previous.values() if isinstance(value, list) for text in value}
    cases, refs = [], {}
    for i, pair in enumerate(corpus['pairs']):
        for language, sentence in zip(['en', 'sr_latn'], pair):
            assert sentence not in old
            words = list(WORD.finditer(sentence))
            eligible = [k for k in range(3, len(words)) if len(words[k].group()) >= 5]
            assert len(eligible) >= 2
            mid1 = min(eligible, key=lambda k: abs(k-len(words)*.53))
            mid2 = min([k for k in eligible if k != mid1], key=lambda k: abs(k-len(words)*.82))
            positions = [(round(len(words)*.35), 0)] + [
                (k, min(len(words[k].group())-1, [2, 3, 4, 6][(i+j) % 4]))
                for j, k in enumerate([mid1, mid2])]
            for k, offset in sorted(positions):
                ident = f'fresh-{language}-{i:02}-{k}-{offset}'
                prefix = sentence[:words[k].start()+offset]
                cases.append(dict(id=ident, prefix=prefix, appName='Notes', bundleID='com.apple.Notes'))
                refs[ident] = dict(language=language, kind='midword' if offset else 'boundary',
                                   phraseID=f'fresh-{i:02}', sentence=sentence,
                                   typed=words[k].group()[:offset])
    assert len(cases) == 288 and len(refs) == len(cases)
    write(OUT/'fresh-input.json', dict(cases=cases))
    write(OUT/'fresh-references.json', refs)
    write(OUT/'corpus.json', corpus)
    write(OUT/'plan.json', dict(createdAtUTC=now(), status='frozen before fresh inference',
        corpusSHA256=digest(OUT/'corpus.json'), inputSHA256=digest(OUT/'fresh-input.json'),
        settings=SETTINGS, topP=.7, topK=20, minP=.08, seed=0xC0FFEE,
        models=['baseline', 'luchador'], arms=ARMS,
        development='Previously seen 64 midword cases are diagnostic/development only. Choose the implementation before fresh inference. Never tune it using fresh judge labels.',
        corpus='48 new paired EN/Serbian Latin scenarios; 1 word boundary and 2 partial words each. Paired languages and adjacent checkpoints share a scenario bootstrap cluster.',
        spelling='Use the existing production spelling/language policy, resolve it once, then freeze its per-case verdict for all arms. No Serbian dictionary assumed.',
        frequency='Keep the prior selected fallback/primary ratio 3.1. Match word-boundary frequency to 29/48 separately per language/model using unlabeled confidence quantiles. Midword has no confidence gate: report all native outputs and verify equal counts; do not silently drop malformed outputs to manufacture equality.',
        primary='Serbian Latin midword utility for fixed versus control, per model. Also report English, all-checkpoint quality, useful/poor counts, first-word scores, and fixed E2B versus fixed Luchador.',
        uncertainty='5000 paired bootstrap draws over 48 scenario clusters, with both languages and nearby checkpoints grouped. One synthetic corpus and one judge, not measured human acceptance.',
        judge='Fresh anonymous Claude Opus 5.5, exact typed prefix and outputs only. No model labels, latency, source, future references. Include 24 reversed-option repeat cases.',
        latency='Three serial counterbalanced rounds, native generation/healing/normalization, trace disabled, actual calibrated early rejection. Eight warmups per process excluded. Excludes model load, spelling classification, debounce, accessibility and overlay UI.',
        prompt='Production raw prompt bytes fixed and checked exactly across every arm; canonical token segmentation may change as part of the decoder treatment.',
        deployment='No PR CI, installation or saved default changes in this task.'))


def run(arm, mode, round_index):
    model, treatment = arm.split('-')
    directory = OUT/f'fresh-{mode}-{round_index}-{arm}'
    if (directory/'receipt.json').exists() and read(directory/'receipt.json').get('complete'):
        print(json.dumps({'cached': directory.name}), flush=True)
        return
    directory.mkdir(exist_ok=False)
    decision = read(OUT/'decision.json')
    spec = next(m for m in read(OUT/'models.json') if m['id'] == model)
    binary = read(OUT/'binary.json')
    assert digest(binary['path']) == binary['sha256']
    assert Path(spec['path']).stat().st_size == spec['bytes']
    cases = read(OUT/'resolved-input.json')['cases']
    refs = read(OUT/'fresh-references.json')
    settings = dict(SETTINGS, healingMode='wordBoundary' if treatment == 'control' else decision['healingMode'],
                    confidenceTrace=mode == 'trace')
    if mode == 'matched':
        cuts = read(OUT/'matched.json')['arms'][arm]
        for case in cases:
            c = cuts[refs[case['id']]['language']]
            case.update(firstWordThreshold=c['primary'], hybridFallbackThreshold=c['fallback'])
    warmups = [dict(id=f'warmup-{i}', prefix=p, wordPrefixIsValidWord=True) for i, p in enumerate(
        ['Please check the ', 'We can discuss the ', 'Molim te proveri ', 'Hvala na pomoći, ']*2)]
    write(directory/'input.json', dict(cases=warmups+cases, **settings))
    receipt = dict(startedAtUTC=now(), binarySHA256=binary['sha256'], modelSHA256=spec['sha256'],
                   inputSHA256=digest(directory/'input.json'), excludedWarmups=8, settings=settings,
                   power=subprocess.check_output(['pmset', '-g', 'batt'], text=True).strip())
    write(directory/'receipt.json', receipt)
    print(json.dumps({'starting': directory.name}), flush=True)
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='lokalbot-midword-') as tmp:
        root = Path(tmp); (root/'home').mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(root/'home'), LOKALBOT_STORAGE_ROOT=str(root/'storage'),
                   LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.'+root.name)
        with (directory/'raw.jsonl').open('w') as stdout, (directory/'stderr.log').open('w') as stderr:
            completed = subprocess.run([binary['path'], '--cotyping-replay', str(directory/'input.json'),
                                        '--model-path', spec['path']], env=env, stdout=stdout, stderr=stderr, timeout=1800)
    raw = rows(directory/'raw.jsonl')
    assert completed.returncode == 0 and len(raw) == len(cases)+8
    assert [r['id'] for r in raw] == [c['id'] for c in warmups+cases]
    assert not any(r.get('error') for r in raw)
    observed = raw[8:]
    reference = OUT/'fresh-trace-1-baseline-control/observations.jsonl'
    if reference.exists():
        assert [(r['id'], r['prompt']) for r in observed] == [(r['id'], r['prompt']) for r in rows(reference)]
    if mode == 'matched':
        traced = rows(OUT/f'fresh-trace-1-{arm}/observations.jsonl')
        expected = [calibration.candidate(r, **dict(primary=cuts[refs[r['id']]['language']]['primary'],
                     fallback=cuts[refs[r['id']]['language']]['fallback'])) for r in traced]
        mismatches = [dict(id=r['id'], expected=e, actual=r['text']) for r, e in zip(observed, expected) if r['text'] != e]
        write(directory/'trace-parity.json', mismatches)
        assert not mismatches, 'Native gate/trace parity failed'
    if round_index > 1:
        first = rows(OUT/f'fresh-{mode}-1-{arm}/observations.jsonl')
        assert [r['text'] for r in first] == [r['text'] for r in observed], 'Output drift'
    (directory/'observations.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False)+'\n' for r in observed))
    receipt.update(complete=True, exitCode=completed.returncode, wallSeconds=time.monotonic()-start,
                   finishedAtUTC=now(), observationsSHA256=digest(directory/'observations.jsonl'))
    write(directory/'receipt.json', receipt)
    print(json.dumps({'done': directory.name, 'shown': sum(bool(r['text']) for r in observed),
                      'meanMs': statistics.mean(r['latencyMs'] for r in observed)}), flush=True)


def match():
    refs = read(OUT/'fresh-references.json')
    fitted = {}
    for model in ['baseline', 'luchador']:
        control = rows(OUT/f'fresh-trace-1-{model}-control/observations.jsonl')
        fixed = rows(OUT/f'fresh-trace-1-{model}-fixed/observations.jsonl')
        for a, b in zip(control, fixed):
            if refs[a['id']]['kind'] == 'boundary':
                assert a['text'] == b['text'] and a['cache'] == b['cache'], 'Boundary drift'
        for treatment, data in [('control', control), ('fixed', fixed)]:
            fitted[model+'-'+treatment] = {}
            for language in ['en', 'sr_latn']:
                group = [r for r in data if refs[r['id']]['kind'] == 'boundary' and refs[r['id']]['language'] == language]
                mid_shown = sum(bool(r['text']) for r in data if refs[r['id']]['kind'] == 'midword' and refs[r['id']]['language'] == language)
                fitted[model+'-'+treatment][language] = calibration.cutoff(group, 3.1, 125-mid_shown)
    write(OUT/'matched.json', dict(createdAtUTC=now(), ratio=3.1, targetPerLanguage=125, denominator=144,
        usesQualityLabels=False, transductive=True, arms=fitted))


def prepare_judge():
    target = OUT/'judge-fresh'; target.mkdir()
    data = {a: rows(OUT/f'fresh-matched-1-{a}/observations.jsonl') for a in ARMS}
    refs = read(OUT/'fresh-references.json')
    cases = [dict(id=item['id'], prefix=item['prefix'], **refs[item['id']],
                  policies={a: data[a][i]['text'] for a in ARMS})
             for i, item in enumerate(read(OUT/'resolved-input.json')['cases'])]
    primary = sorted([c for c in cases if any(c['policies'].values())], key=lambda c: judge.digest('midword:'+c['id']))
    mapping, batches = {}, []
    for stage, selected in [('primary', primary), ('repeat', primary[:24])]:
        public = []
        for case in selected:
            packet = judge.blind_case(case, stage == 'repeat')
            mapping[packet['id']] = dict(caseID=case['id'], stage=stage, options={o['id']: o['continuation'] for o in packet['options']})
            public.append(packet)
        for i in range(0, len(public), 12):
            name = f'{stage}-{i//12+1:02}'; directory = target/'batches'/name; directory.mkdir(parents=True)
            packet = {'cases': public[i:i+12]}; write(directory/'packet.json', packet)
            prompt = judge.RUBRIC+json.dumps(packet['cases'], ensure_ascii=False, separators=(',', ':'))
            (directory/'request.txt').write_text(prompt)
            batches.append(dict(id=name, stage=stage, cases=len(packet['cases']), requestSHA256=judge.digest(prompt)))
    write(target/'cases.json', cases); write(target/'private-mapping.json', mapping)
    write(target/'protocol.json', dict(createdAtUTC=now(), batches=batches, counts=dict(primary=len(primary), repeat=24),
        casesSHA256=digest(target/'cases.json'), model='claude-opus-5-5'))


def interval(values, refs, selection):
    groups = defaultdict(list)
    for ident in selection:
        groups[refs[ident]['phraseID']].append(values[ident])
    groups = list(groups.values()); rng = random.Random(7102026)
    samples = []
    for _ in range(5000):
        sample = [groups[rng.randrange(len(groups))] for _ in groups]
        samples.append(sum(map(sum, sample))/sum(map(len, sample)))
    samples.sort()
    return dict(delta=statistics.mean(values[i] for i in selection), ci95=[samples[125], samples[4875]], clusters=len(groups))


def analyze():
    calibration.OUT = OUT
    scores = calibration.scores('fresh')
    refs = read(OUT/'fresh-references.json')
    data = {a: rows(OUT/f'fresh-matched-1-{a}/observations.jsonl') for a in ARMS}
    utilities = {a: {r['id']: scores[r['id']][r['text']]['utility'] for r in data[a]} for a in ARMS}
    slices = {'all': list(refs)}
    for language in ['en', 'sr_latn']:
        for kind in ['all', 'midword', 'boundary']:
            slices[f'{language}-{kind}'] = [i for i, r in refs.items() if r['language'] == language and (kind == 'all' or r['kind'] == kind)]
    report = dict(arms={}, comparisons={})
    for arm in ARMS:
        measured = sum([rows(OUT/f'fresh-matched-{n}-{arm}/observations.jsonl') for n in range(1, 4)], [])
        report['arms'][arm] = {}
        for label, ids in slices.items():
            chosen = [r for r in data[arm] if r['id'] in ids]
            values = [utilities[arm][i] for i in ids]
            latencies = [r['latencyMs'] for r in measured if r['id'] in ids]
            report['arms'][arm][label] = dict(n=len(ids), shown=sum(bool(r['text']) for r in chosen),
                useful=sum(v>0 for v in values), poor=sum(v<0 for v in values), utility=statistics.mean(values),
                firstWord=statistics.mean(scores[r['id']][r['text']]['first_word'] for r in chosen),
                meanMs=statistics.mean(latencies), p50Ms=percentile(latencies,.5), p95Ms=percentile(latencies,.95), latencyCalls=len(latencies))
    for a, b in [('baseline-fixed', 'baseline-control'), ('luchador-fixed', 'luchador-control'), ('luchador-fixed', 'baseline-fixed')]:
        differences = {i: utilities[a][i]-utilities[b][i] for i in refs}
        report['comparisons'][a+'_vs_'+b] = {label: interval(differences, refs, ids) for label, ids in slices.items()}
    write(OUT/'analysis.json', report)
    write(OUT/'utilities.json', utilities)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'run', 'match', 'judge', 'analyze'])
    parser.add_argument('--arm', choices=ARMS)
    parser.add_argument('--mode', choices=['trace', 'matched'], default='trace')
    parser.add_argument('--round', type=int, default=1)
    args = parser.parse_args()
    if args.command == 'run': run(args.arm, args.mode, args.round)
    else: {'prepare': prepare, 'match': match, 'judge': prepare_judge, 'analyze': analyze}[args.command]()
