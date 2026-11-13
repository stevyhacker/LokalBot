"""POST HOC diagnostic, not part of frozen primary scoring. No inference or text edits.

Map a line field to a handle only if it exactly equals one unique source sentence.
Measure source selection, not semantic correctness, before and after this repair.
"""
import collections
import copy
import json
from pathlib import Path
from score import parse,score_case

ROOT=Path(__file__).resolve().parent
cases={c['id']:c for c in json.loads((ROOT/'cases.json').read_text())}
result={}
for path in sorted((ROOT/'results').glob('*.jsonl')):
    totals=collections.defaultdict(lambda:collections.Counter())
    repairs=[]
    for line in path.read_text().splitlines():
        raw=json.loads(line);case=cases[raw['id']]
        items,error=parse(raw)
        group='en' if case['language']=='en' else 'sr';t=totals[group];t['cases']+=1
        before=score_case(case,raw);t['source_selection_before']+=before['decision']
        if error:continue
        new_items=copy.deepcopy(items);valid={l['handle'] for l in case['lines']}
        for i,item in enumerate(new_items):
            t['proposals']+=1
            if item['line'].strip().upper() in valid:continue
            t['invalid_citations']+=1
            matches=[l['handle'] for l in case['lines'] if l['text']==item['line']]
            if len(matches)==1:
                repairs.append(dict(case=case['id'],index=i,original_line=item['line'],mapped_handle=matches[0]))
                item['line']=matches[0];t['exact_quote_repairs']+=1
        remapped=dict(raw,content=json.dumps({'items':new_items}))
        t['source_selection_after']+=score_case(case,remapped)['decision']
    result[path.stem]={'slices':dict(totals),'repairs':repairs}
(ROOT/'citation-diagnostic.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({a:r['slices'] for a,r in result.items()},indent=2))
