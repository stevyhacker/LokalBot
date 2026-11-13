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


def replay_input(corpus, cases, variant):
    visible, meetings, screens = VARIANTS[variant]
    allowed = {'id', 'speech', 'visible', 'transcribe'}
    return {'cases': [{k: v for k, v in case.items() if k in allowed} for case in cases],
            'memoryItems': corpus['memoryItems'], 'now': corpus['now'],
            'useVisibleContext': visible, 'useMeetingMemory': meetings, 'useScreenMemory': screens}


def score(cases, runs):
    ids = [case['id'] for case in cases]
    if set(runs) != set(VARIANTS):
        raise ValueError('All context conditions are required')
    rows = []
    for variant, (visible, meetings, screens) in VARIANTS.items():
        if [row['id'] for row in runs[variant]] != ids:
            raise ValueError('Missing, reordered, duplicate or unexpected observations')
        for case, output in zip(cases, runs[variant]):
            transcribe = case['transcribe']
            source = case['memorySource']
            permitted = (meetings if source == 'meeting' else screens if source == 'screen' else meetings and screens)
            permitted = permitted and (visible or not case['memoryRequiresVisible']) and not transcribe
            expected_memory = case['expectedMemoryIDs'] if permitted else []
            expected_visible = case['expectedVisibleIDs'] if visible and not transcribe else []
            allowed_reads = case['permittedTextReadIDs'] if visible and not transcribe else []
            forbidden = [word for word in case['forbidden'] if contains(output['text'], word)]
            correct = output['text'] == case['speech'] if transcribe else (
                all(contains(output['text'], word) for word in case['required']) and not forbidden)
            rows.append({'id': case['id'], 'kind': case['kind'], 'variant': variant, 'text': output['text'],
                         'correct': bool(correct) and not output.get('error'), 'forbiddenFacts': forbidden,
                         'memorySelectionCorrect': output['memoryIDs'] == expected_memory,
                         'visibleSelectionCorrect': output['visibleIDs'] == expected_visible,
                         'forbiddenReads': sorted(set(output['textReadIDs']) - set(allowed_reads)),
                         'modelCallsCorrect': output['modelCalls'] == (0 if transcribe else 1),
                         'error': output.get('error'), 'latencyMs': output['latencyMs']})
    controls = []
    for i, case in enumerate(cases):
        if case['kind'] not in {'control', 'transcribe'}:
            continue
        base = runs['neither'][i]
        controls.append({'id': case['id'], 'unchanged': all(
            (run[i]['text'], run[i]['prompt'], run[i]['system']) == (base['text'], base['prompt'], base['system'])
            for run in runs.values())})
    summary = {}
    for variant in VARIANTS:
        own = [r for r in rows if r['variant'] == variant]
        summary[variant] = {'cases': len(own), 'errors': sum(bool(r['error']) for r in own),
                            'selectionFailures': sum(not r['memorySelectionCorrect'] or not r['visibleSelectionCorrect'] for r in own),
                            'forbiddenReads': sum(bool(r['forbiddenReads']) for r in own),
                            'modelCallFailures': sum(not r['modelCallsCorrect'] for r in own),
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
    args = parser.parse_args()
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
            for variant in VARIANTS:
                fixture = args.output / f'{variant}-input.json'
                fixture.write_text(json.dumps(replay_input(corpus, cases, variant), ensure_ascii=False) + '\n')
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
    report = score(cases, runs)
    report['manifest'] = manifest
    (args.output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report['summary'], indent=2), flush=True)
    if any(r['error'] or r['forbiddenReads'] or not r['memorySelectionCorrect'] or not r['visibleSelectionCorrect']
           or not r['modelCallsCorrect'] for r in report['cases']) or not all(c['unchanged'] for c in report['controls']):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
