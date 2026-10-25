"""Display unreviewed, completed proposals during the remote run."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent
sys.path.insert(0, str(BASE))
from score import score_case

cases = {c['id']: c for c in json.loads((BASE/'cases.json').read_text())}
review = json.loads((ROOT/'review.json').read_text()) if (ROOT/'review.json').exists() else {}
pending = {}
raw = [json.loads(line) for line in (ROOT/'results/memt-nano-nf4-offload.jsonl').read_text().splitlines()]
for response in raw:
    case = cases[response['id']]
    row = score_case(case, response)
    for item in row['items']:
        key = f"{case['id']}:{item['index']}"
        record = dict(id=case['id'], i=item['index'],
            source=next((line['text'] for line in case['lines'] if line['handle']==item['line'].strip().upper()), 'INVALID HANDLE'),
            known=case['known'], gold=[g['text'] for g in case['expected']],
            output=item['text'], kind=item['kind'], auto=item['match'])
        record['audit_record_sha256'] = hashlib.sha256(json.dumps(record, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
        if key in review:
            assert review[key]['audit_record_sha256'] == record['audit_record_sha256']
        else:
            pending[key] = record
            print(json.dumps(dict(key=key, **record), ensure_ascii=False))
(ROOT/'review-pending.json').write_text(json.dumps(pending, ensure_ascii=False, indent=2)+'\n')
print(f'{len(raw)}/120 responses; {len(review)} reviewed proposals; {len(pending)} pending proposals.')
