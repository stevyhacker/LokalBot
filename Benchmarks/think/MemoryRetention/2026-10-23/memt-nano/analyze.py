"""Apply the unchanged original scorer and prepare complete semantic-review evidence."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent
sys.path.insert(0, str(BASE))
from score import aggregate, score_case

ARM = "memt-nano-nf4-offload"


def main():
    cases = json.loads((BASE / "cases.json").read_text())
    raw = [json.loads(line) for line in (ROOT / "results" / f"{ARM}.jsonl").read_text().splitlines()]
    assert len(raw) == len(cases) and {r['id'] for r in raw} == {c['id'] for c in cases}
    by_id = {r['id']: r for r in raw}
    automatic = [score_case(c, by_id[c['id']]) for c in cases]
    audit = []
    for case, row in zip(cases, automatic):
        for item in row['items']:
            source = next((line['text'] for line in case['lines']
                           if line['handle'] == item['line'].strip().upper()), 'INVALID HANDLE')
            record = dict(id=case['id'], i=item['index'], source=source, known=case['known'],
                          gold=[g['text'] for g in case['expected']], output=item['text'],
                          kind=item['kind'], auto=item['match'])
            record['audit_record_sha256'] = hashlib.sha256(
                json.dumps(record, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
            audit.append(record)
    (ROOT / 'audit.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False)+'\n' for r in audit))
    results = {}
    details = {'automatic': automatic}
    if (ROOT / 'review.json').exists():
        review = json.loads((ROOT / 'review.json').read_text())
        assert set(review) == {f"{r['id']}:{r['i']}" for r in audit}
        for record in audit:
            decision = review[f"{record['id']}:{record['i']}"]
            assert decision['audit_record_sha256'] == record['audit_record_sha256']
            assert decision['reason'] and isinstance(decision['unwanted'], bool)
        details['reviewed'] = [score_case(c, by_id[c['id']], review) for c in cases]
    for mode, rows in details.items():
        results[ARM+'/'+mode] = {language: aggregate([r for r in rows if predicate(r)])
            for language, predicate in {'all': lambda r: True, 'en': lambda r: r['language']=='en',
                                        'sr': lambda r: r['language']!='en'}.items()}
    (ROOT / 'scores.json').write_text(json.dumps(results, indent=2)+'\n')
    (ROOT / 'details.json').write_text(json.dumps(details, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
