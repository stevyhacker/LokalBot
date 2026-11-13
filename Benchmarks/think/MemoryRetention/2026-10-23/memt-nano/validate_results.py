"""Validate the added arm without modifying the original frozen evidence."""
import csv
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent
sys.path.insert(0, str(BASE))
from score import aggregate, score_case

ARM = 'memt-nano-nf4-offload'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    original = read(BASE/'frozen.json')
    for name, digest in original['files'].items():
        assert sha(BASE/name) == digest, name
    spec = read(ROOT/'model.json')
    for name, digest in spec['baseline_inputs'].items():
        assert sha(BASE/name) == digest, name
    metadata = read(ROOT/'results'/f'{ARM}.meta.json')
    identity = metadata['identity']
    assert identity['inputs'] == spec['baseline_inputs']
    assert identity['model_revision'] == spec['revision']
    for name, digest in identity['software'].items():
        assert sha(ROOT/name) == digest, name
    weights = read(ROOT/'verified-model-files.json')
    assert all(weights[w['file']] == w['sha256'] for w in spec['weights'])
    for name, digest in spec['source_files'].items():
        assert sha(ROOT/'sources'/name) == digest, name
        if name in weights:
            assert weights[name] == digest, name
    assert read(ROOT/'adapter-model-validation.json')['status'] == 'passed'
    assert read(ROOT/'tokenizer-validation.json')['status'] == 'passed'
    smoke = read(ROOT/'smoke-result.json')
    assert smoke['id'] == 'NON_BENCHMARK_SMOKE' and smoke['finish'] == 'stop'
    assert json.loads(smoke['content']) == {'items': []}
    initial_smoke = read(ROOT/'resume-evidence/initial-smoke-result.json')
    assert initial_smoke['finish'] == 'stop' and json.loads(initial_smoke['content']) == {'items': []}
    cases = read(BASE/'cases.json')
    raw = [json.loads(line) for line in (ROOT/'results'/f'{ARM}.jsonl').read_text().splitlines()]
    assert len(raw) == 120 and {r['id'] for r in raw} == {c['id'] for c in cases}
    assert all(r['started'] >= metadata['frozen_before_inference'] for r in raw)
    resume = read(ROOT/'resume-evidence/preflight.json')
    prefix = (ROOT/'resume-evidence/initial-30.jsonl').read_bytes()
    assert len(prefix) == resume['retained_bytes']
    assert hashlib.sha256(prefix).hexdigest() == resume['retained_sha256']
    assert (ROOT/'results'/f'{ARM}.jsonl').read_bytes().startswith(prefix)
    assert [r['id'] for r in raw] == [p['id'] for p in read(BASE/'prompts.json')]
    assert [r['id'] for r in raw[:30]] == resume['retained_ids']
    assert all(r['started'] >= resume['time'] for r in raw[30:])
    completed = read(ROOT/'resume-evidence/completion.json')
    assert completed['status'] == 'complete' and completed['activeBenchmarkProcesses'] == 0
    assert completed['responses'] == completed['uniqueIds'] == len(raw)
    assert completed['rawSha256'] == sha(ROOT/'results'/f'{ARM}.jsonl')
    initial_review = read(ROOT/'resume-evidence/initial-review.json')
    final_review = read(ROOT/'review.json')
    assert all(final_review[key] == decision for key, decision in initial_review.items())
    assert (ROOT/'results/COMPLETE').exists()
    assert all(r.get('reasoning', '') == '' for r in raw)
    assert all(r.get('usage', {}).get('prompt_tokens', 0) + r.get('usage', {}).get('completion_tokens', 0) <= 8192 for r in raw)
    by_id = {r['id']: r for r in raw}
    review = read(ROOT/'review.json')
    audit = [json.loads(line) for line in (ROOT/'audit.jsonl').read_text().splitlines()]
    assert set(review) == {f"{r['id']}:{r['i']}" for r in audit}
    for record in audit:
        digest = record.pop('audit_record_sha256')
        assert hashlib.sha256(json.dumps(record, ensure_ascii=False, sort_keys=True).encode()).hexdigest() == digest
        assert review[f"{record['id']}:{record['i']}"]['audit_record_sha256'] == digest
    rows = [score_case(c, by_id[c['id']], review) for c in cases]
    scores = read(ROOT/'scores.json')
    for language, selected in [('all', rows), ('en', [r for r in rows if r['language']=='en']),
                                ('sr', [r for r in rows if r['language']!='en'])]:
        assert aggregate(selected) == scores[ARM+'/reviewed'][language]
    combined = {**read(BASE/'scores.json'), **scores}
    chart = list(csv.DictReader((ROOT/'chart-data.csv').open()))
    assert len(chart) == 10
    for row in chart:
        for name, value in combined[row['arm']+'/reviewed'][row['language']].items():
            assert int(row[name]) == value
    print(f'PASS: original frozen inputs unchanged; 120 added responses; {len(audit)} reviewed proposals; '
          'pinned checkpoint and adapter; validated smoke; matching score aggregates and ten chart rows.')


if __name__ == '__main__':
    main()
