"""Verify installed Release outputs against frozen E2B evals and rollback.

Uses explicit replay controls matching the app factory tested by XCTest.
These timings are installation smoke measurements, not a new speed benchmark.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--baseline-app', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--latency-evidence', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--resume', action='store_true', help='Revalidate immutable completed runs and finish missing runs')
    args = parser.parse_args()
    args.output.mkdir(exist_ok=args.resume)
    installed = args.app / 'Contents/MacOS/LokalBot'
    baseline = args.baseline_app / 'Contents/MacOS/LokalBot'
    report = {
        'kind': 'Signed Release integration parity, not a new latency benchmark',
        'installedExecutableSHA256': digest(installed),
        'baselineExecutableSHA256': digest(baseline),
        'modelSHA256': digest(args.model),
        'fastProfile': {'selectiveOneWordHybrid': True, 'searchExperiment': 'certified',
                        'nativeThreads': 2, 'nativeBatchThreads': None},
        'runs': [],
    }
    keys = ['id', 'prompt', 'text', 'suppression', 'error']

    def run(name, binary, fixture, expected):
        folder = args.output / name
        start = time.monotonic()
        if folder.exists():
            assert args.resume, 'Use a new output directory or explicit --resume'
            previous = json.loads((folder / 'receipt.json').read_text())
            assert previous['inputSHA256'] == digest(folder / 'input.json')
            assert previous['rawSHA256'] == digest(folder / 'raw.jsonl')
            assert previous['binarySHA256'] == digest(binary)
            assert json.loads((folder / 'input.json').read_text()) == fixture
            elapsed = previous['wallSeconds']
        else:
            folder.mkdir()
            save(folder / 'input.json', fixture)
            with tempfile.TemporaryDirectory(prefix='lokalbot-install-parity-') as temp:
                local = Path(temp)
                (local / 'home').mkdir()
                env = dict(os.environ, CFFIXED_USER_HOME=str(local / 'home'),
                           LOKALBOT_STORAGE_ROOT=str(local / 'storage'),
                           LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.' + local.name)
                with (folder / 'raw.jsonl').open('w') as stdout, (folder / 'stderr.log').open('w') as stderr:
                    proc = subprocess.run([str(binary), '--cotyping-replay', str(folder / 'input.json'),
                                           '--model-path', str(args.model)],
                                          env=env, stdout=stdout, stderr=stderr, timeout=600)
            assert proc.returncode == 0, (name, proc.returncode)
            elapsed = time.monotonic() - start
        actual = read_rows(folder / 'raw.jsonl')
        assert len(actual) == len(fixture['cases']), name
        assert not any(row.get('error') for row in actual), name
        measured = [row for row in actual if not row['id'].startswith('warmup-')]
        non_cancelled = [row for row in measured if not row.get('cancelled')]
        differences = []
        completed_before_cancellation = []
        paired = 0
        if expected is not None:
            assert [row['id'] for row in actual] == [row['id'] for row in expected], name
            actual_by_id = {row['id']: row for row in actual}
            expected_by_id = {row['id']: row for row in expected}
            for got, wanted in zip(actual, expected):
                if wanted.get('cancelled'):
                    if not got.get('cancelled'):
                        reference_id = got['id'].removesuffix('-cancel') + '-coldReference'
                        cold = actual_by_id.get(reference_id)
                        frozen_cold = expected_by_id.get(reference_id)
                        # A timer that has not run cannot cancel completed work.
                        # Require both cold references to match; never count this
                        # event as a successful cancellation or a paired output.
                        if (got.get('cancellationRequestedAfterMs') is None and cold and frozen_cold
                                and not cold.get('cancelled') and not frozen_cold.get('cancelled')
                                and all(got.get(key) == cold.get(key) == frozen_cold.get(key)
                                        for key in keys if key != 'id')):
                            completed_before_cancellation.append(got['id'])
                        else:
                            differences.append({'id': got['id'], 'keys': ['cancelled']})
                    continue
                if not got['id'].startswith('warmup-'):
                    paired += 1
                changed = [key for key in keys if got.get(key) != wanted.get(key)]
                if got.get('cancelled'):
                    changed.append('cancelled')
                if changed:
                    differences.append({'id': got['id'], 'keys': changed})
        record = {'name': name, 'measured': len(measured), 'nonCancelled': len(non_cancelled),
                  'cancelled': len(measured) - len(non_cancelled), 'differences': differences,
                  'pairedNonCancelled': paired, 'completedBeforeCancellation': completed_before_cancellation,
                  'shown': sum(bool(row.get('text')) for row in non_cancelled),
                  'binarySHA256': digest(binary), 'inputSHA256': digest(folder / 'input.json'),
                  'rawSHA256': digest(folder / 'raw.jsonl'), 'wallSeconds': elapsed}
        if not (folder / 'receipt.json').exists():
            save(folder / 'receipt.json', record)
        save(folder / 'validated-receipt.json', record)
        report['runs'].append(record)
        save(args.output / 'parity.json', report)
        print(json.dumps(record), flush=True)
        assert not differences, name
        return actual

    for dataset in ['regression', 'fresh', 'dynamic', 'long', 'edges', 'cancellation']:
        source = args.latency_evidence / f'run-{dataset}-certified_threads2-1'
        fixture = json.loads((source / 'input.json').read_text())
        assert fixture['selectiveOneWordHybrid'] is True
        assert fixture['searchExperiment'] == 'certified' and fixture['nativeThreads'] == 2
        assert fixture.get('nativeBatchThreads') is None
        reference = args.output / f'{dataset}-reference.jsonl'
        if reference.exists():
            assert digest(reference) == digest(source / 'raw.jsonl')
        else:
            shutil.copyfile(source / 'raw.jsonl', reference)
        run(dataset, installed, fixture, read_rows(source / 'raw.jsonl'))

    fixture = copy.deepcopy(json.loads((args.latency_evidence /
        'run-regression-certified_threads2-1/input.json').read_text()))
    fixture['selectiveOneWordHybrid'] = False
    fixture['healingMode'] = 'wordBoundary'
    for key in ['searchExperiment', 'nativeThreads', 'nativeBatchThreads',
                'hybridFallbackThreshold', 'confidenceTrace', 'healingTrace']:
        fixture.pop(key, None)
    for item in fixture['cases']:
        item.pop('hybridFallbackThreshold', None)
    old = run('rollback-previous-app', baseline, fixture, None)
    run('rollback-installed', installed, fixture, old)
    assert digest(installed) == report['installedExecutableSHA256'], 'Installed binary changed during validation'
    report['complete'] = True
    report['fastNonCancelledPairs'] = sum(row['pairedNonCancelled'] for row in report['runs'][:6])
    report['rollbackPairs'] = report['runs'][-1]['pairedNonCancelled']
    save(args.output / 'parity.json', report)


if __name__ == '__main__':
    main()
