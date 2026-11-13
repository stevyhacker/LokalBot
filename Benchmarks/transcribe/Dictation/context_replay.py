#!/usr/bin/env python3
"""Evaluate the production post-ASR Compose path with synthetic context only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import tempfile
import time
import unicodedata
import urllib.request
import uuid

VARIANTS = {'neither': (False, False, False), 'visible': (True, False, False),
            'memory': (False, True, False), 'both': (True, True, False), 'all': (True, True, True)}
# The focused-window (OCR) option, with the first 12,000 characters (the policy
# before 2026-10-08) or the last 2,000 (the policy since), alone and with every
# other grant. Both are passed explicitly, so either build reproduces both.
WINDOW_POLICIES = {'head': {'limit': 12000, 'keepsEnd': False}, 'tail': {'limit': 2000, 'keepsEnd': True}}
WINDOW_VARIANTS = {'window': ((False, False, False), 'head'), 'window-tail': ((False, False, False), 'tail'),
                   'all-window': ((True, True, True), 'head'), 'all-window-tail': ((True, True, True), 'tail')}
VARIANT_SETS = {'context': list(VARIANTS), 'full': list(VARIANTS) + list(WINDOW_VARIANTS)}


def flags(variant):
    """(visible, meetings, screens, window policy name or None) for a variant."""
    if variant in WINDOW_VARIANTS:
        grants, policy = WINDOW_VARIANTS[variant]
        return (*grants, policy)
    return (*VARIANTS[variant], None)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def words(text):
    return re.findall(r'[^\W_]+', unicodedata.normalize('NFC', text).casefold())


def contains(text, phrase):
    actual, expected = words(text), words(phrase)
    return bool(expected) and any(actual[i:i + len(expected)] == expected for i in range(len(actual)))


def replay_input(corpus, cases, variant, routing=None, cleanup=None):
    visible, meetings, screens, window = flags(variant)
    allowed = {'id', 'speech', 'visible', 'transcribe', 'screen'}
    data = {'cases': [{k: v for k, v in case.items() if k in allowed} for case in cases],
            'memoryItems': corpus['memoryItems'], 'now': corpus['now'],
            'useVisibleContext': visible, 'useMeetingMemory': meetings, 'useScreenMemory': screens}
    if window:
        data.update(useScreenContext=True, windowTextPolicy=WINDOW_POLICIES[window])
    if routing:
        data['routing'] = routing
    if cleanup:
        data['cleanupPrompt'] = cleanup
    return data


def score(cases, runs, variants=None):
    variants = list(VARIANTS) if variants is None else variants
    ids = [case['id'] for case in cases]
    if any(type(case.get('contextEligible')) is not bool for case in cases):
        raise ValueError('Every case needs an external context-eligibility reference label')
    if set(runs) != set(variants):
        raise ValueError('All context conditions are required')
    rows = []
    for variant in variants:
        visible, meetings, screens, window = flags(variant)
        if [row['id'] for row in runs[variant]] != ids:
            raise ValueError('Missing, reordered, duplicate or unexpected observations')
        for case, output in zip(cases, runs[variant]):
            transcribe = case['transcribe']
            eligible = case['contextEligible'] and not transcribe
            source = case['memorySource']
            permitted = (meetings if source == 'meeting' else screens if source == 'screen' else meetings and screens)
            permitted = permitted and (visible or not case['memoryRequiresVisible']) and eligible
            expected_memory = case['expectedMemoryIDs'] if permitted else []
            expected_visible = case['expectedVisibleIDs'] if visible and eligible else []
            allowed_reads = case['permittedTextReadIDs'] if visible and eligible else []
            forbidden = [word for word in case['forbidden'] if contains(output['text'], word)]
            correct = output['text'] == case['speech'] if transcribe else (
                all(contains(output['text'], word) for word in case['required']) and not forbidden)
            rows.append({'id': case['id'], 'kind': case['kind'], 'variant': variant, 'text': output['text'],
                         'correct': bool(correct) and not output.get('error'), 'forbiddenFacts': forbidden,
                         'memorySelectionCorrect': output['memoryIDs'] == expected_memory,
                         'visibleSelectionCorrect': output['visibleIDs'] == expected_visible,
                         'forbiddenReads': sorted(set(output['textReadIDs']) - set(allowed_reads)),
                         'modelCallsCorrect': output['modelCalls'] == (0 if transcribe else 1),
                         'screenReadsCorrect': output.get('screenReads', 0) == (1 if window and eligible else 0),
                         'routedAsRequest': output.get('routedAsRequest'),
                         'routingCorrect': transcribe or output.get('routedAsRequest') is None
                         or output.get('routedAsRequest') == case['contextEligible'],
                         'error': output.get('error'), 'latencyMs': output['latencyMs']})
    controls = []
    for i, case in enumerate(cases):
        if case['kind'] not in {'control', 'transcribe'} and case['contextEligible']:
            continue
        base = runs['neither'][i]
        controls.append({'id': case['id'], 'unchanged': all(
            (run[i]['text'], run[i]['prompt'], run[i]['system']) == (base['text'], base['prompt'], base['system'])
            for run in runs.values())})
    summary = {}
    for variant in variants:
        own = [r for r in rows if r['variant'] == variant]
        summary[variant] = {'cases': len(own), 'errors': sum(bool(r['error']) for r in own),
                            'selectionFailures': sum(not r['memorySelectionCorrect'] or not r['visibleSelectionCorrect'] for r in own),
                            'forbiddenReads': sum(bool(r['forbiddenReads']) for r in own),
                            'modelCallFailures': sum(not r['modelCallsCorrect'] for r in own),
                            'screenReadFailures': sum(not r['screenReadsCorrect'] for r in own),
                            'routingFailures': sum(not r['routingCorrect'] for r in own),
                            'medianMs': statistics.median(r['latencyMs'] for r in own if r['kind'] != 'transcribe'),
                            'byKind': {kind: {'correct': sum(r['correct'] for r in own if r['kind'] == kind),
                                             'cases': sum(r['kind'] == kind for r in own)}
                                       for kind in sorted({r['kind'] for r in own})}}
    return {'summary': summary, 'controls': controls, 'cases': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--split', choices=['development', 'heldout'], required=True)
    parser.add_argument('--corpus', type=Path, default=Path(__file__).with_name('context-cases.json'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--variant-set', choices=sorted(VARIANT_SETS), default='context',
                        help='context: the five grant conditions; full: also the focused-window option')
    parser.add_argument('--routing', choices=['commands', 'relays', 'referencedRelays'],
                        help='writing-request rule to evaluate (default: the build\'s production rule)')
    parser.add_argument('--cleanup-prompt', choices=['composeDecides', 'transcriptAsData'],
                        help='cleanup prompt for direct speech (default: the build\'s production prompt)')
    args = parser.parse_args()
    variants = VARIANT_SETS[args.variant_set]
    args.output.mkdir(parents=True, exist_ok=False)
    corpus = json.loads(args.corpus.read_text())
    cases = [c for c in corpus['cases'] if c['split'] == args.split]
    if not cases or len({c['id'] for c in cases}) != len(cases):
        raise ValueError('Empty or duplicate cases')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    command = [str(args.server.resolve()), '-m', str(args.model.resolve()), '--host', '127.0.0.1', '--port', str(port),
               '-c', '32768', '-ngl', '99', '--parallel', '1', '--jinja', '--no-webui', '--seed', '12648430']
    manifest = {'appSHA256': digest(args.app), 'serverSHA256': digest(args.server), 'modelSHA256': digest(args.model),
                'modelFile': args.model.name, 'corpusSHA256': digest(args.corpus), 'scriptSHA256': digest(__file__),
                'split': args.split, 'caseIDs': [c['id'] for c in cases], 'serverArguments': command,
                'variants': variants, 'windowPolicies': WINDOW_POLICIES, 'routing': args.routing or 'production',
                'cleanupPrompt': args.cleanup_prompt or 'production',
                'settings': 'Production Compose: temperature 0.2, max 4096 output tokens, reasoning disabled; fixed server seed',
                'scope': 'Synthetic recognized speech, AX trees and saved facts. No microphone, live screen or user library.'}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    runs = {}
    with (args.output / 'server.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 180
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f'Local server exited {process.returncode}')
                try:
                    with opener.open(base + '/health', timeout=1) as response:
                        if response.status == 200:
                            break
                except (OSError, urllib.error.URLError):
                    pass
                if time.monotonic() > deadline:
                    raise TimeoutError('Local model did not become ready')
                time.sleep(0.2)
            for variant in variants:
                fixture = args.output / f'{variant}-input.json'
                fixture.write_text(json.dumps(replay_input(corpus, cases, variant, args.routing, args.cleanup_prompt), ensure_ascii=False) + '\n')
                with tempfile.TemporaryDirectory(prefix='lokalbot-dictation-eval-') as temporary:
                    root = Path(temporary)
                    (root / 'home').mkdir()
                    (root / 'storage').mkdir()
                    env = dict(os.environ, CFFIXED_USER_HOME=str(root / 'home'), LOKALBOT_STORAGE_ROOT=str(root / 'storage'),
                               LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.dictation-replay.' + uuid.uuid4().hex)
                    with (args.output / f'{variant}.jsonl').open('w') as out, (args.output / f'{variant}-stderr.log').open('w') as err:
                        subprocess.run([str(args.app.resolve()), '--dictation-replay', str(fixture.resolve()), '--server-url', base + '/v1'],
                                       env=env, stdout=out, stderr=err, timeout=900, check=True)
                runs[variant] = [json.loads(line) for line in (args.output / f'{variant}.jsonl').read_text().splitlines()]
                print(variant, len(runs[variant]), 'observations', flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    report = score(cases, runs, variants)
    report['manifest'] = manifest
    (args.output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report['summary'], indent=2), flush=True)
    if any(r['error'] or r['forbiddenReads'] or not r['memorySelectionCorrect'] or not r['visibleSelectionCorrect']
           or not r['modelCallsCorrect'] or not r['screenReadsCorrect'] for r in report['cases']) \
            or not all(c['unchanged'] for c in report['controls']):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
