"""Record explicit reviewer decisions with the corresponding raw-evidence hash."""
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent
pending = json.loads((root/'review-pending.json').read_text())
review = json.loads((root/'review.json').read_text()) if (root/'review.json').exists() else {}
decisions = json.load(sys.stdin)
for key, decision in decisions.items():
    assert key in pending and key not in review
    assert decision['reason'] and isinstance(decision['unwanted'], bool)
    assert decision['match'] is None or isinstance(decision['match'], int)
    decision['audit_record_sha256'] = pending[key]['audit_record_sha256']
    review[key] = decision
(root/'review.json').write_text(json.dumps(review, ensure_ascii=False, indent=2)+'\n')
print(f'Recorded {len(decisions)} decisions; {len(review)} proposals reviewed in total.')
