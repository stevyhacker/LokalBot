"""Compare installed hybrid outputs with the previous signed app's frozen outputs.

Replay controls explicitly match the app factory covered by XCTest. This is an
integration parity check, not a latency benchmark or an end-to-end UI test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir()
    binary = args.app / 'Contents/MacOS/LokalBot'
    report = {'kind': 'Installed Release output parity; no new speed or quality claim',
              'installedExecutableSHA256': digest(binary), 'modelSHA256': digest(args.model),
              'runs': [], 'complete': False}
    assert report['modelSHA256'] == '20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629'
    keys = ['id', 'prompt', 'text', 'suppression', 'error', 'cancelled', 'healingMode',
            'selectiveOneWordHybrid', 'searchExperiment', 'nativeThreads', 'nativeBatchThreads',
            'firstWordThreshold', 'hybridFallbackThreshold', 'confidenceTrace',
            'nativeSpellVerdictsApply', 'wordPrefixIsValidWord', 'usedPromptOverride']
    for dataset in ['fresh', 'edges']:
        reference = args.reference / dataset
        old = json.loads((reference / 'receipt.json').read_text())
        assert old['binarySHA256'] == 'f4cfd2a81c9aaac0a7763a10f00e72fdc831c4c83371b46c719fdeab0a0b2a5e'
        assert old['inputSHA256'] == digest(reference / 'input.json')
        assert old['rawSHA256'] == digest(reference / 'raw.jsonl')
        folder = args.output / dataset
        folder.mkdir()
        shutil.copyfile(reference / 'input.json', folder / 'input.json')
        shutil.copyfile(reference / 'raw.jsonl', folder / 'reference.jsonl')
        shutil.copyfile(reference / 'receipt.json', folder / 'reference-receipt.json')
        fixture = json.loads((folder / 'input.json').read_text())
        assert fixture['selectiveOneWordHybrid'] is True and fixture['healingMode'] == 'prefixSearch'
        assert fixture['searchExperiment'] == 'certified' and fixture['nativeThreads'] == 2
        assert fixture.get('nativeBatchThreads') is None and fixture['confidenceTrace'] is False
        with tempfile.TemporaryDirectory(prefix='lokalbot-always-hybrid-parity-') as temp:
            local = Path(temp)
            (local / 'home').mkdir()
            env = dict(os.environ, CFFIXED_USER_HOME=str(local / 'home'),
                       LOKALBOT_STORAGE_ROOT=str(local / 'storage'),
                       LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.' + local.name)
            with (folder / 'raw.jsonl').open('w') as stdout, (folder / 'stderr.log').open('w') as stderr:
                subprocess.run([str(binary), '--cotyping-replay', str(folder / 'input.json'),
                                '--model-path', str(args.model)], env=env, stdout=stdout,
                               stderr=stderr, timeout=600, check=True)
        actual, expected = rows(folder / 'raw.jsonl'), rows(folder / 'reference.jsonl')
        assert len(actual) == len(expected) == len(fixture['cases'])
        differences = [{'id': got['id'], 'keys': changed} for got, wanted in zip(actual, expected)
                       if (changed := [key for key in keys if got.get(key) != wanted.get(key)])]
        assert not any(row.get('error') or row.get('cancelled') for row in actual)
        measured = [row for row in actual if not row['id'].startswith('warmup-')]
        record = {'dataset': dataset, 'measuredPairs': len(measured),
                  'warmupPairs': len(actual) - len(measured),
                  'shown': sum(bool(row.get('text')) for row in measured), 'differences': differences,
                  'inputSHA256': digest(folder / 'input.json'), 'rawSHA256': digest(folder / 'raw.jsonl'),
                  'referenceSHA256': digest(folder / 'reference.jsonl'), 'comparedFields': keys}
        save(folder / 'receipt.json', record)
        report['runs'].append(record)
        save(args.output / 'parity.json', report)
        print(json.dumps(record), flush=True)
        assert not differences, dataset
    assert digest(binary) == report['installedExecutableSHA256']
    report['complete'] = True
    report['measuredPairs'] = sum(row['measuredPairs'] for row in report['runs'])
    save(args.output / 'parity.json', report)


if __name__ == '__main__':
    main()
