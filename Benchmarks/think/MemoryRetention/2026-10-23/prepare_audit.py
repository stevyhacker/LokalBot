"""Produce an item-by-item semantic review worksheet from immutable raw responses."""
import json
from pathlib import Path
import sys
from score import score_case,parse

ROOT=Path(__file__).resolve().parent
cases={c['id']:c for c in json.loads((ROOT/'cases.json').read_text())}
out=ROOT/'audit';out.mkdir(exist_ok=True)
for path in sorted((ROOT/'results').glob('*.jsonl')):
    if len(sys.argv)>1 and path.stem!=sys.argv[1]:continue
    raw=[json.loads(l) for l in path.read_text().splitlines()]
    lines=[f'# Review worksheet: {path.stem}', '', 'AI-assisted, not independent or blinded human review. Sources and expected meanings are shown for every emitted item.', '']
    for r in sorted(raw,key=lambda r:r['id']):
        c=cases[r['id']];s=score_case(c,r)
        lines.extend([f"## {r['id']} · {c['category']} · {c['language']}",f"Expected: {json.dumps(c['expected'],ensure_ascii=False)}"])
        if c['known']:lines.append('Known: '+json.dumps(c['known'],ensure_ascii=False))
        lines.append('Target: '+next(l['text'] for l in c['lines'] if l['handle']==c['target']))
        if s['error']:lines.append('ERROR: '+s['error'])
        if not s['items'] and not s['error']:lines.append('Output: empty')
        for item in s['items']:
            src=next((l['text'] for l in c['lines'] if l['handle']==item['line'].strip().upper()),'INVALID SOURCE HANDLE')
            lines.extend([f"- Item {item['index']} ({item['line']}, {item['kind']}, automatic match={item['match']}): {item['text']}",f'  Source: {src}'])
        lines.append('')
    (out/f'{path.stem}.md').write_text('\n'.join(lines)+'\n')
    # Compact complete worksheet, one source/output pair per line, for terminal review.
    with (out/f'{path.stem}.jsonl').open('w') as f:
        for r in sorted(raw,key=lambda r:r['id']):
            c=cases[r['id']];s=score_case(c,r)
            for item in s['items']:
                src=next((l['text'] for l in c['lines'] if l['handle']==item['line'].strip().upper()),'INVALID HANDLE')
                f.write(json.dumps(dict(id=c['id'],i=item['index'],source=src,known=c['known'],gold=[g['text'] for g in c['expected']],output=item['text'],kind=item['kind'],auto=item['match']),ensure_ascii=False)+'\n')
    print(path.stem,len(raw),'cases',sum(len(parse(r)[0] or []) for r in raw),'items')
