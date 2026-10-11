"""Audit frozen replays and summarize paired, scenario-clustered latency."""
import importlib.util, statistics, random, json
from collections import defaultdict
from pathlib import Path
p=Path(__file__).resolve().with_name('latency_experiment.py')
spec=importlib.util.spec_from_file_location('study',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def signature(row): return (row['prompt'],row['text'],row.get('suppression'))
def cluster(dataset,metadata):
 scenario=metadata.get('scenario',metadata.get('phraseID'))
 if dataset.startswith('dynamic'):return str(scenario).split('-')[1]
 if dataset.startswith('long'):return str(int(scenario)//4)
 if dataset.startswith('cancellation'):return str(scenario).split('-')[2]
 return str(scenario)
def interval(base,treat,clusters):
 groups=defaultdict(list)
 for a,b,c in zip(base,treat,clusters):groups[c].append((a,b))
 values=list(groups.values());totals=[(sum(a for a,b in v),sum(b for a,b in v),len(v)) for v in values]
 rng=random.Random(11102026);means=[];ratios=[]
 for _ in range(5000):
  draw=rng.choices(totals,k=len(totals));a=sum(v[0] for v in draw);b=sum(v[1] for v in draw);n=sum(v[2] for v in draw)
  means.append((b-a)/n);ratios.append(100*(b/a-1))
 return dict(clusters=len(groups),resamples=5000,deltaMeanMs=statistics.mean(treat)-statistics.mean(base),
  deltaMeanMsCI95=[m.percentile(means,.025),m.percentile(means,.975)],relativePercent=100*(sum(treat)/sum(base)-1),
  relativePercentCI95=[m.percentile(ratios,.025),m.percentile(ratios,.975)])

def main():
 runs={};receipts={};summary={};integrity={}
 for d in sorted(m.OUT.glob('run-*')):
  if not (d/'receipt.json').exists():continue
  r=m.read(d/'receipt.json')
  if r['trace']:continue
  assert m.sha(d/'raw.jsonl')==r['rawSHA256'] and m.sha(d/'input.json')==r['inputSHA256']
  k=(r['dataset'],r['arm'],r['round']);runs[k]=m.rows(d/'raw.jsonl')[8:];receipts[k]=r
 if not runs: raise ValueError('No raw replay receipts. Extract the evidence archive before analysis.')
 for dataset,arm in sorted({(a,b) for a,b,c in runs}):
  meta=m.read(m.OUT/'inputs'/f'{dataset}-meta.json');observed=[];pairs=[];changed=[];cancelled=[];recovery=[];warm=[];rss=[]
  for key,rs in runs.items():
   if key[:2]!=(dataset,arm):continue
   n=key[2];baseline={r['id']:r for r in runs.get((dataset,'current',n),runs.get((dataset,'current',1),[]))}
   byid={r['id']:r for r in rs};observed.extend(rs)
   for r in rs:
    if r.get('cancelled'):cancelled.append(r['id']);continue
    if r['id'] in baseline and not baseline[r['id']].get('cancelled'):
     b=baseline[r['id']];assert r['prompt']==b['prompt'],(key,r['id'],'prompt changed')
     if signature(r)!=signature(b):changed.append(r['id'])
     pairs.append((b,r))
   if dataset.startswith(('dynamic','cancellation')):
    for scenario in {v['scenario'] for v in meta.values()}:
     selected={meta[k]['kind']:r for k,r in byid.items() if meta[k]['scenario']==scenario}
     cancel=selected['cancel'];cache=cancel.get('cache',{})
     recovery.append(dict(scenario=scenario,round=n,cancelled=cancel.get('cancelled',False),cancelLatencyMs=cancel['latencyMs'],
       cancellationRequestedAfterMs=cancel.get('cancellationRequestedAfterMs'),
       cacheAtCancel=cache,recoveredExactly=signature(selected['recover'])==signature(selected['coldReference'])))
   if dataset.startswith('long'):
    for scenario in {v['scenario'] for v in meta.values()}:
     selected={meta[k]['kind']:r for k,r in byid.items() if meta[k]['scenario']==scenario}
     a,b=selected['cold'],selected['prewarm']
     warm.append(dict(scenario=scenario,round=n,sameOutput=signature(a)==signature(b),coldMs=a['latencyMs'],
       readyMs=b['latencyMs'],prewarmMs=b.get('prewarmMs',0),totalMs=b['latencyMs']+b.get('prewarmMs',0)))
   stderr=(m.OUT/f'run-{dataset}-{arm}-{n}'/'stderr.log').read_text()
   for line in stderr.splitlines():
    if 'maximum resident set size' in line:rss.append(int(line.split()[0]))
  parts={}
  for part in ['all','en','sr_latn']:
   subset=[r for r in observed if not r.get('cancelled') and (part=='all' or meta[r['id']]['language']==part)]
   xs=[r['latencyMs'] for r in subset]
   if not xs:continue
   selected=[(a,b) for a,b in pairs if part=='all' or meta[b['id']]['language']==part]
   parts[part]=dict(n=len(xs),meanMs=statistics.mean(xs),p50Ms=m.percentile(xs,.5),p95Ms=m.percentile(xs,.95),p99Ms=m.percentile(xs,.99),
     shown=sum(bool(r['text']) for r in subset),
     paired=interval([a['latencyMs'] for a,b in selected],[b['latencyMs'] for a,b in selected],
       [cluster(dataset,meta[b['id']]) for a,b in selected]) if selected else None)
  stages=['decodedTokens','decodeCalls','searchRestoreSkips','searchMemoHits','searchExpansions','certifiedSkips','prefillMs','prefixSearchMs','afterSearchMs','baselinePathMs','explorationMs','searchRestoreMs']
  summary.setdefault(dataset,{})[arm]=dict(parts=parts,changedUniqueIDs=sorted(set(changed)),changedObservations=len(changed),
    cancelled=len(cancelled),rounds=len({k[2] for k in runs if k[:2]==(dataset,arm)}),
    meanStages={s:statistics.mean(r.get('cache',{}).get(s,0) for r in observed) for s in stages},peakRSSBytes=max(rss) if rss else None)
  integrity.setdefault(dataset,{})[arm]=dict(recovery=recovery,prewarm=warm)
 m.write(m.OUT/'paired-analysis.json',summary);m.write(m.OUT/'state-integrity.json',integrity)
 for ds,arms in summary.items():
  print(ds)
  for arm,r in arms.items():
   v=r['parts']['all'];print(arm,round(v['meanMs'],2),round(v['p95Ms'],2),len(r['changedUniqueIDs']),v['paired'])
if __name__=='__main__':main()
