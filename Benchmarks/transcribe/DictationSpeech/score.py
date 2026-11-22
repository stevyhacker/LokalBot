"""Score the runs: English word error rate on the first pass, latency from the median of each recording's passes."""
import argparse
import json
import random
import re
import statistics
import unicodedata
from pathlib import Path

from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

ROOT = Path(__file__).resolve().parents[3]
EN = EnglishTextNormalizer(json.loads((ROOT / 'Benchmarks/think/ModelAlternatives/2026-09-07/english-spelling.json').read_text()))
BUCKETS = [(0, 45, '30 s'), (45, 75, '60 s'), (75, 105, '90 s'), (105, 1e9, '120 s')]


def words(text):
    text = unicodedata.normalize('NFC', text or '').lower()
    text = re.sub(r'\b(\d{1,2}):([0-5]\d)\b', r'\1\2', text)
    return EN(text).split()


def errors(reference, hypothesis):
    return len(Levenshtein.editops(reference, hypothesis))


def bucket(seconds):
    return next(name for low, high, name in BUCKETS if low <= seconds < high)


def load(folder):
    rows = [json.loads(line) for line in (folder / 'replay.jsonl').read_text().splitlines() if line.strip()]
    return [row for row in rows if 'id' in row]


def summarize(cases, rows, passes):
    by_case = {case['id']: case for case in cases}
    expected = {(case['id'], n) for case in cases for n in range(passes)}
    actual = {(row['id'], row['pass']) for row in rows}
    if actual != expected:
        raise SystemExit(f'incomplete run: {len(actual)} of {len(expected)} outputs')
    first = {row['id']: row for row in rows if row['pass'] == 0}
    per_case = {}
    for case_id, case in by_case.items():
        reference = words(case['reference'])
        seconds = statistics.median(row['seconds'] for row in rows if row['id'] == case_id)
        per_case[case_id] = {'refWords': len(reference), 'errors': errors(reference, words(first[case_id]['text'])),
                             'seconds': seconds, 'audioSeconds': case['seconds'], 'subset': case['subset'],
                             'bucket': bucket(case['seconds']), 'text': first[case_id]['text']}
    return per_case


def wer(items):
    return 100 * sum(i['errors'] for i in items) / sum(i['refWords'] for i in items)


def table(per_case, keys):
    items = [per_case[k] for k in keys]
    return {'wer': round(wer(items), 2), 'refWords': sum(i['refWords'] for i in items),
            'medianSeconds': round(statistics.median(i['seconds'] for i in items), 3),
            'speedX': round(sum(i['audioSeconds'] for i in items) / sum(i['seconds'] for i in items), 1)}


def paired_interval(a, b, keys, draws=2000, seed=7):
    rng = random.Random(seed)
    diffs = []
    for _ in range(draws):
        sample = [rng.choice(keys) for _ in keys]
        diffs.append(wer([a[k] for k in sample]) - wer([b[k] for k in sample]))
    diffs.sort()
    return round(diffs[int(0.025 * draws)], 2), round(diffs[int(0.975 * draws)], 2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cases', type=Path, required=True)
    parser.add_argument('--runs', type=Path, required=True)
    parser.add_argument('--baseline', default='qwen-auto')
    parser.add_argument('--out', type=Path, help='summary.json (aggregates only)')
    args = parser.parse_args()
    assert errors(['a', 'b'], ['a', 'c', 'd']) == 2 and words('THREE thirty!') == words('3:30')
    cases = json.loads(args.cases.read_text())['cases']
    configs = {}
    for folder in sorted(p for p in args.runs.iterdir() if (p / 'replay.jsonl').exists()):
        manifest = json.loads((folder / 'manifest.json').read_text())
        configs[folder.name] = summarize(cases, load(folder), manifest['passes'])
    keys = sorted(configs[args.baseline])
    summary = {}
    for name, per_case in configs.items():
        entry = {'all': table(per_case, keys)}
        for subset in sorted({c['subset'] for c in per_case.values()}):
            entry[subset] = table(per_case, [k for k in keys if per_case[k]['subset'] == subset])
        for _, _, name_bucket in BUCKETS:
            picked = [k for k in keys if per_case[k]['bucket'] == name_bucket]
            if picked:
                entry[name_bucket] = table(per_case, picked)
        if name != args.baseline:
            entry['werMinusBaseline'] = round(entry['all']['wer'] - wer([configs[args.baseline][k] for k in keys]), 2)
            entry['werMinusBaselineInterval'] = paired_interval(per_case, configs[args.baseline], keys)
            entry['identicalTextToBaseline'] = sum(per_case[k]['text'] == configs[args.baseline][k]['text'] for k in keys)
        summary[name] = entry
    text = json.dumps({'recordings': len(keys), 'audioMinutes': round(sum(c['seconds'] for c in cases) / 60, 1),
                       'baseline': args.baseline, 'configs': summary}, indent=1)
    if args.out:
        args.out.write_text(text + '\n')
    print(text)


if __name__ == '__main__':
    main()
