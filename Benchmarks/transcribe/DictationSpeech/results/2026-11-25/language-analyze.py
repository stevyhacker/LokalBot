import json, os, sys, collections
sys.path.insert(0, os.environ.get('QLS_SRC', '../../../QwenLanguageSample'))
from common import errors, items
def load(p): return {(r['id'], r['layout'], r['mode']): r for r in map(json.loads, open(p))}
M = load('runs-master.jsonl'); B = load('runs-branch.jsonl'); known = items()
old = {(t,l): r for (t,l,m), r in M.items() if m == 'before'}
mas = {(t,l): r for (t,l,m), r in M.items() if m == 'after'}
bra = {(t,l): r for (t,l,m), r in B.items()}
keys = sorted(old)
out = {}
def cmp(name, a, b):
    same = 0; diffs = []
    for k in keys:
        x, y = a[k], b[k]
        ok = x['text'] == y['text'] and x.get('pinned') == y.get('pinned')
        same += ok
        if not ok: diffs.append({'track': k[0], 'layout': k[1], 'pin': [x.get('pinned'), y.get('pinned')], 'textsame': x['text']==y['text'], 'regions': [x['needsSpeakerRegions'], y['needsSpeakerRegions']], 'decodes': [len(x['windows']), len(y['windows'])], 'twice': [x['decodedTwice'], y['decodedTwice']]})
    out[name] = {'same_pin_and_text': same, 'of': len(keys), 'differs': diffs}
    print(name, same, 'of', len(keys))
    for d in diffs: print('  ', d)
cmp('branch_vs_old', old, bra); cmp('branch_vs_master', mas, bra); cmp('master_vs_old', old, mas)
print('\n%-26s %-5s %-4s %8s %8s %8s   errors old/master/branch   | decodes   | seconds' % ('track','lay','pin','old','master','branch'))
rows = []
tot = collections.defaultdict(float)
for k in keys:
    item = known[k[0]]; x, y, z = old[k], mas[k], bra[k]
    cell = {}
    if item.get('reference') and not z['needsSpeakerRegions'] and not x['needsSpeakerRegions'] and not y['needsSpeakerRegions']:
        for n, r in (('old', x), ('master', y), ('branch', z)):
            e, c = errors(item['reference'], r['text'], item.get('languages') or []); cell[n] = (e, c)
    row = {'track': k[0], 'layout': k[1], 'pin_old': x.get('pinned'), 'pin_master': y.get('pinned'), 'pin_branch': z.get('pinned'),
           'errors': {n: v[0] for n, v in cell.items()}, 'units': next(iter(cell.values()))[1] if cell else None,
           'decodes': [len(x['windows']), len(y['windows']), len(z['windows'])], 'seconds': [round(x['decodeSeconds'],1), round(y['decodeSeconds'],1), round(z['decodeSeconds'],1)],
           'windows': len(z['spans']), 'regions': z['needsSpeakerRegions'], 'twice': [x['decodedTwice'], y['decodedTwice'], z['decodedTwice']]}
    rows.append(row)
    for i, n in enumerate(('old','master','branch')):
        tot[(k[1], n, 'dec')] += row['decodes'][i]; tot[(k[1], n, 'sec')] += row['seconds'][i]
    es = row['errors']
    print('%-26s %-5s %-4s %s | errs %s of %s | dec %s | s %s' % (k[0], k[1], row['pin_branch'], 'rgn' if row['regions'] else '', [es.get(n) for n in ('old','master','branch')], row['units'], row['decodes'], row['seconds']))
out['rows'] = rows
out['totals'] = {f'{l}-{n}': {'decodes': tot[(l,n,'dec')], 'seconds': round(tot[(l,n,'sec')],1)} for l in ('plain','word') for n in ('old','master','branch')}
for k_, v in out['totals'].items(): print(k_, v)
# pooled errors where comparable
pool = collections.defaultdict(lambda: [0,0])
for r in rows:
    if r['errors']:
        for n,v in r['errors'].items(): pool[n][0]+=v
        pool['units'][0]+=r['units']
print('pooled errors', dict(pool))
# window-level independence: auto text of a window identical across old/branch
eq=ne=0
for k in keys:
    ba={w['index']:w['text'] for w in old[k]['windows'] if w.get('language') is None}
    bp={w['index']:w['text'] for w in old[k]['windows'] if w.get('language') is not None}
    for w in bra[k]['windows']:
        ref = ba if w.get('language') is None else bp
        if w['index'] in ref: eq+= ref[w['index']]==w['text']; ne+= ref[w['index']]!=w['text']
print('window independence old vs branch: compared', eq+ne, 'identical', eq)
out['window_independence'] = {'compared': eq+ne, 'identical': eq}
json.dump(out, open('aggregates.json','w'), indent=1)
