"""Blind quality judgments for changed outputs from the fresh latency ablations."""
import sys, json, random, statistics
from pathlib import Path
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'Benchmarks/Cotyping'))
import latency_experiment as m
import claude_judge as judge
from model_study import bootstrap
out=m.OUT/'claude-quality'
arms=['current','certified','certified_threads2','exact','width2','budget8','memo','threads2','threads2_only','threads4']

def prepare():
 out.mkdir()
 observed={a:{r['id']:r for r in m.rows(m.OUT/f'run-fresh-{a}-1/raw.jsonl')[8:]} for a in arms}
 inputs={r['id']:r for r in m.read(m.OUT/'inputs/fresh.json')['cases']};meta=m.read(m.OUT/'inputs/fresh-meta.json')
 cases=[];changed=[];shared=[]
 for key,item in inputs.items():
  values={a:observed[a][key]['text'] for a in arms}
  assert all(observed[a][key]['prompt']==observed['current'][key]['prompt'] for a in arms)
  case=dict(id=key,prefix=item['prefix'],policies=values,scenario=meta[key]['scenario'],language=meta[key]['language'])
  cases.append(case)
  if len(set(values.values()))>1:changed.append(case)
  elif any(values.values()):shared.append(case)
 rng=random.Random(11102026)
 controls=[]
 for language in ['en','sr_latn']:
  group=[c for c in shared if c['language']==language];rng.shuffle(group);controls+=group[:12]
 selected=changed+controls;rng.shuffle(selected)
 repeats=changed.copy();rng.shuffle(repeats);repeats=repeats[:16]+controls[:8]
 batches=[];mapping={}
 for kind,cs in [('primary',selected),('repeat',repeats)]:
  public=[]
  for case in cs:
   q=judge.blind_case(case,repetition=kind=='repeat');public.append(q)
   mapping[q['id']]=dict(id=case['id'],kind=kind,options={v['id']:v['continuation'] for v in q['options']})
  for start in range(0,len(public),20):
   bid=f'{kind}-{start//20:02}';d=out/'batches'/bid;d.mkdir(parents=True)
   packet=dict(cases=public[start:start+20]);m.write(d/'packet.json',packet)
   prompt=judge.RUBRIC+json.dumps(packet,ensure_ascii=False);(d/'request.txt').write_text(prompt)
   batches.append(dict(id=bid,kind=kind,requestSHA256=judge.digest(prompt)))
 m.write(out/'cases.json',cases);m.write(out/'private-mapping.json',mapping)
 m.write(out/'protocol.json',dict(frozenAtUTC=m.now(),arms=arms,batches=batches,changedCases=len(changed),sharedControls=len(controls),repeatCases=len(repeats),
  quality='Every changed fresh checkpoint plus a stratified shared-output control sample. Silence=0. Anonymous unique outputs, no model labels, timing, future references, or personal text. Paired scenario bootstrap includes all 144 checkpoints; unchanged deltas are zero.',
  limitation='One model judge and one synthetic fresh corpus; no human acceptance or equal-frequency retuning for changed-output ablations. Exact-output finalists preserve frequency automatically.',
  models='claude-opus-5-5',systemSHA256=judge.digest(judge.SYSTEM),schemaSHA256=judge.digest(json.dumps(judge.SCHEMA))))
 print('Prepared',len(changed),'changed',len(controls),'shared',len(batches),'batches',flush=True)

def analyze():
 cases=m.read(out/'cases.json');mapping=m.read(out/'private-mapping.json');scores={};repeated={};models=set();disagreements=0
 for batch in m.read(out/'protocol.json')['batches']:
  d=out/'batches'/batch['id'];models.update(m.read(d/'receipt.json')['models']);disagreements+=len(m.read(d/'preference-disagreements.json'))
  for item in m.read(d/'ratings.json')['cases']:
   q=mapping[item['id']];dest=scores if q['kind']=='primary' else repeated
   dest[q['id']]={q['options'][r['id']]:r for r in item['ratings']}
 result=dict(models=sorted(models),preferenceDisagreements=disagreements,comparisons={})
 for arm in arms:
  result['comparisons'][arm]={}
  for language in ['all','en','sr_latn']:
   selected=[c for c in cases if language=='all' or c['language']==language]
   differences=[];wins=losses=ties=0
   for c in selected:
    a,b=c['policies']['current'],c['policies'][arm]
    if a==b:delta=0
    else:
     sa=scores[c['id']][a]['utility'] if a else 0;sb=scores[c['id']][b]['utility'] if b else 0;delta=sb-sa
    differences.append(delta);wins+=delta>0;losses+=delta<0;ties+=delta==0
   result['comparisons'][arm][language]=dict(utilityDelta=bootstrap(differences,[c['scenario'] for c in selected]),wins=wins,losses=losses,ties=ties,shown=sum(bool(c['policies'][arm]) for c in selected))
 pairs=[(scores[k][t]['utility'],v['utility']) for k,rs in repeated.items() for t,v in rs.items()]
 result['repeatStability']=dict(optionRatings=len(pairs),exactAgreement=sum(a==b for a,b in pairs),meanAbsoluteDifference=statistics.mean(abs(a-b) for a,b in pairs))
 m.write(out/'summary.json',result)
 # Auditable side-by-side examples selected by largest absolute judged effect.
 examples=[]
 for c in cases:
  for arm in ['exact','width2','budget8']:
   a,b=c['policies']['current'],c['policies'][arm]
   if a==b:continue
   ra=scores[c['id']].get(a,{'utility':0,'reason':'Silence'});rb=scores[c['id']].get(b,{'utility':0,'reason':'Silence'})
   examples.append(dict(id=c['id'],language=c['language'],prefix=c['prefix'],arm=arm,current=a,candidate=b,currentRating=ra,candidateRating=rb,delta=rb['utility']-ra['utility']))
 m.write(out/'examples.json',examples)
 print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 if sys.argv[1]=='prepare':prepare()
 elif sys.argv[1]=='run':judge.run(out,3,None,'claude-opus-5-5')
 else:analyze()
