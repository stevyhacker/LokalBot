#!/usr/bin/env python3
"""Independent confirmation after rejecting atomic healing on the first corpus."""
import argparse
from pathlib import Path
import shutil
import os
import json
import statistics
import subprocess
import tempfile

import midword_experiment as experiment

experiment.OUT = experiment.HERE/'results/2026-10-10-prefix-search'
experiment.TEMP = Path('/private/tmp/lokalbot-prefix-search-20261010')


def prepare():
    experiment.OUT.mkdir(exist_ok=False)
    shutil.copy2(experiment.HERE/'results/2026-10-10-midword/models.json', experiment.OUT/'models.json')
    experiment.prepare('prefix-confirmation-corpus.json')
    plan = experiment.read(experiment.OUT/'plan.json')
    plan.update(
        development='The old calibration cases and rejected atomic experiment corpus are development only. Neither is heldout evidence for prefix-path search.',
        frequency='125/144 shown per language/arm. Preserve all native midword outputs. Allocate the remaining quota to word boundaries using unlabeled confidence, ratio3.1. No quality labels set cutoffs.',
        selection='Before fresh inference, freeze the candidate chosen on development. Accept only if Serbian Latin usefulness increases with no more poor suggestions, and English useful count falls by no more than 2/96 midword cases. Report clustered intervals; these point guards are not a formal noninferiority trial.',
        latencyGuard='Report both the cost and the quality. An all-case mean above 1.5 times control or p95 above250ms fails the interactive-latency guard. No UI latency claim.',
        rejectedPredecessor='../2026-10-10-midword/REPORT.md')
    experiment.write(experiment.OUT/'plan.json', plan)
    previous = experiment.read(experiment.HERE/'midword-corpus.json')['pairs']
    current = experiment.read(experiment.OUT/'corpus.json')['pairs']
    assert not ({s for p in previous for s in p} & {s for p in current for s in p})


def stress():
    """Latency diagnostic only: one fresh/shared round, without quality claims."""
    e = experiment; out = e.OUT
    paragraphs = {
        'en': 'This document records ordinary project work and practical decisions. We review the available information and agree on the next steps. Some tasks are quick, while others need more discussion. The team keeps a record of important changes and checks the result before moving on. Everyone should have enough context to understand the current plan. Clear examples often make a complicated explanation easier to follow. ',
        'sr_latn': 'Ovaj dokument sadrži beleške o redovnom radu i praktičnim odlukama. Zajedno pregledamo dostupne podatke i dogovaramo naredne korake. Neki zadaci se završavaju brzo, dok drugi zahtevaju više razgovora. Tim beleži važne promene i proverava rezultate pre nastavka rada. Svako treba da ima dovoljno podataka da razume trenutni plan. Jasni primeri često pomažu da složeno objašnjenje postane razumljivije. '}
    refs = e.read(out/'fresh-references.json'); original = e.read(out/'resolved-input.json')['cases']
    cases, metadata = [], {}
    for language in ['en', 'sr_latn']:
        selected = [c for c in original if refs[c['id']]['language'] == language and refs[c['id']]['kind'] == 'midword'][:16]
        for index, case in enumerate(selected):
            identifier = 'long-'+case['id']
            cases.append(dict(case, id=identifier, prefix=paragraphs[language]*5+'\n\n'+case['prefix'], resetCache=index%2 == 0))
            metadata[identifier] = dict(language=language, transition='fresh' if index%2 == 0 else 'shared')
    e.write(out/'long-input.json', dict(cases=cases)); e.write(out/'long-references.json', metadata)
    e.write(out/'long-plan.json', dict(createdAtUTC=e.now(), cases=32, rounds=1, arms=e.ARMS,
        inputSHA256=e.digest(out/'long-input.json'), purpose='Latency diagnostic only. Production context limits. All midword; no equal-frequency or quality ranking claim. Eight excluded warmups. First request of each pair resets cache; second shares the document.'))
    binary = e.read(out/'binary.json'); report = {}
    for arm in e.ARMS:
        model, treatment = arm.split('-'); spec = next(m for m in e.read(out/'models.json') if m['id'] == model)
        directory = out/f'long-{arm}'; directory.mkdir()
        warmups = [dict(id=f'warmup-{i}', prefix=p) for i, p in enumerate(['Please check the ', 'Hvala na pomoći, ']*4)]
        e.write(directory/'input.json', dict(e.SETTINGS, cases=warmups+cases,
            healingMode='wordBoundary' if treatment == 'control' else 'prefixSearch'))
        with tempfile.TemporaryDirectory(prefix='prefix-long-') as tmp:
            root = Path(tmp); (root/'home').mkdir()
            env = dict(os.environ, CFFIXED_USER_HOME=str(root/'home'), LOKALBOT_STORAGE_ROOT=str(root/'storage'),
                       LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.'+root.name)
            with (directory/'raw.jsonl').open('w') as stdout, (directory/'stderr.log').open('w') as stderr:
                subprocess.run([binary['path'], '--cotyping-replay', str(directory/'input.json'), '--model-path', spec['path']],
                               env=env, stdout=stdout, stderr=stderr, check=True, timeout=600)
        raw = e.rows(directory/'raw.jsonl'); assert len(raw) == 40 and not any(r.get('error') for r in raw)
        observed = raw[8:]; assert all(not r['cache']['confidenceGateEligible'] for r in observed)
        reference = out/'long-baseline-control/observations.jsonl'
        if reference.exists():
            assert [(r['id'], r['prompt']) for r in observed] == [(r['id'], r['prompt']) for r in e.rows(reference)]
        (directory/'observations.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False)+'\n' for r in observed))
        e.write(directory/'receipt.json', dict(complete=True, finishedAtUTC=e.now(), binarySHA256=binary['sha256'],
            modelSHA256=spec['sha256'], inputSHA256=e.digest(directory/'input.json')))
        report[arm] = {}
        for transition in ['fresh', 'shared']:
            subset = [r for r in observed if metadata[r['id']]['transition'] == transition]
            times = [r['latencyMs'] for r in subset]
            report[arm][transition] = dict(n=len(subset), meanMs=statistics.mean(times), p95Ms=e.percentile(times,.95),
                shown=sum(bool(r['text']) for r in subset), meanDecodedTokens=statistics.mean(r['cache']['decodedTokens'] for r in subset))
        print(json.dumps({'longCompleted': arm}), flush=True)
    e.write(out/'long-analysis.json', report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'run', 'match', 'judge', 'analyze', 'stress'])
    parser.add_argument('--arm', choices=experiment.ARMS)
    parser.add_argument('--mode', choices=['trace', 'matched'], default='trace')
    parser.add_argument('--round', type=int, default=1)
    args = parser.parse_args()
    if args.command == 'run': experiment.run(args.arm, args.mode, args.round)
    else: {'prepare': prepare, 'match': experiment.match, 'judge': experiment.prepare_judge,
           'analyze': experiment.analyze, 'stress': stress}[args.command]()
