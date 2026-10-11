#!/usr/bin/env python3
"""Frozen E2B latency comparisons; synthetic inputs, isolated local storage."""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = HERE / 'results/2026-10-11-latency'
TMP = Path('/private/tmp/lokalbot-latency-20261011')
MODEL = Path('/Users/0xmithrandir/Library/Application Support/me.dotenv.LokalBot/models/gemma-4-E2B.i1-Q6_K.gguf')
ARMS = dict(current={}, reuse={'searchExperiment':'reuseRoot'}, memo={'searchExperiment':'memoized'},
    certified={'searchExperiment':'certified'}, width2={'searchExperiment':'widthTwo'}, budget8={'searchExperiment':'budgetEight'},
    exact={'searchExperiment':'exactOnly'}, threads2={'searchExperiment':'memoized','nativeThreads':2},
    threads4={'searchExperiment':'memoized','nativeThreads':4}, threads2_only={'nativeThreads':2}, certified_threads2={'searchExperiment':'certified','nativeThreads':2},
    split_batch14={'searchExperiment':'certified','nativeThreads':2,'nativeBatchThreads':14})
PAIRS = [
('The mechanic replaced the cracked belt before starting the engine again.', 'Mehaničar je zamenio napukli kaiš pre nego što je ponovo pokrenuo motor.'),
('Please store the spare batteries in the drawer beneath the kitchen counter.', 'Molim te ostavi rezervne baterije u fioci ispod kuhinjske radne površine.'),
('Our hiking group decided to follow the river instead of climbing the ridge.', 'Naša planinarska grupa odlučila je da prati reku umesto uspona na greben.'),
('The librarian found a translated edition of the novel on the upper shelf.', 'Bibliotekarka je pronašla prevedeno izdanje romana na gornjoj polici.'),
('I wrapped the fragile ornament in newspaper before putting it inside the suitcase.', 'Umotao sam krhki ukras u novine pre nego što sam ga stavio u kofer.'),
('We borrowed a folding ladder to reach the branches above the entrance.', 'Pozajmili smo sklopive merdevine da bismo dohvatili grane iznad ulaza.'),
('The children collected smooth stones along the beach after their swimming lesson.', 'Deca su skupljala glatke kamenčiće na plaži posle časa plivanja.'),
('Please leave the delivery instructions beside the address on the package.', 'Molim te ostavi uputstva za isporuku pored adrese na paketu.'),
('The photographer waited for the clouds to clear before taking another picture.', 'Fotograf je sačekao da se oblaci raziđu pre nego što je snimio novu fotografiju.'),
('I noticed a loose button on my jacket while getting ready for work.', 'Primetio sam labavo dugme na jakni dok sam se spremao za posao.'),
('The gardener moved the young seedlings into larger pots near the window.', 'Baštovan je presadio mlade sadnice u veće saksije blizu prozora.'),
('We folded the blankets and placed them inside the cupboard in the hallway.', 'Složili smo ćebad i stavili ih u ormar koji se nalazi u hodniku.'),
('Please verify the invoice number before approving the payment request.', 'Molim te proveri broj fakture pre nego što odobriš zahtev za plaćanje.'),
('The installer should preserve existing preferences when upgrading the application.', 'Instalacioni program treba da sačuva postojeće postavke prilikom nadogradnje aplikacije.'),
('We postponed the workshop because several participants were unable to attend.', 'Odložili smo radionicu jer nekoliko učesnika nije moglo da prisustvuje.'),
('The revised schedule leaves a short break between the afternoon presentations.', 'Izmenjeni raspored ostavlja kratku pauzu između popodnevnih prezentacija.'),
('Please describe the problem without including confidential customer information.', 'Molim te opiši problem bez uključivanja poverljivih podataka o korisnicima.'),
('The reviewer suggested separating the configuration changes into another patch.', 'Recenzent je predložio da promene podešavanja izdvojimo u zasebnu izmenu.'),
('We need a reproducible example before investigating the intermittent connection failure.', 'Potreban nam je ponovljiv primer pre istraživanja povremenog prekida veze.'),
('The spreadsheet calculates the remaining balance after subtracting the outstanding expenses.', 'Tabela izračunava preostali iznos nakon oduzimanja nepodmirenih troškova.'),
('Please confirm that the translated instructions still match the original procedure.', 'Molim te potvrdi da prevedena uputstva i dalje odgovaraju prvobitnom postupku.'),
('The registration form displays a helpful explanation beside each required field.', 'Obrazac za prijavu prikazuje korisno objašnjenje pored svakog obaveznog polja.'),
('We saved a separate copy of the recording before making any adjustments.', 'Sačuvali smo posebnu kopiju snimka pre nego što smo napravili bilo kakve izmene.'),
('The notification should disappear automatically once the operation has completed successfully.', 'Obaveštenje treba automatski da nestane kada se postupak uspešno završi.')]

def now(): return datetime.now(timezone.utc).isoformat()
def read(p): return json.loads(Path(p).read_text())
def write(p,obj): Path(p).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
def rows(p): return [json.loads(s) for s in Path(p).read_text().splitlines() if s.strip()]
def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def percentile(xs,q):
    v=sorted(xs);return v[min(len(v)-1,int((len(v)-1)*q))] if v else None

def prepare():
    inputs=OUT/'inputs';inputs.mkdir()
    prior=Path('/Users/0xmithrandir/.codex/worktrees/4d628f81-0a81-4922-926a-c8c47dc4dbec/LokalBot/Benchmarks/Cotyping/results/2026-10-10-prefix-search')
    regression=read(prior/'fresh-matched-1-baseline-fixed/input.json')
    regression['cases']=regression['cases'][8:]
    write(inputs/'regression.json',regression)
    write(inputs/'regression-meta.json',read(prior/'fresh-references.json'))
    shutil.copy2(prior/'fresh-matched-1-baseline-fixed/raw.jsonl',OUT/'prior-regression.jsonl')
    settings={k:v for k,v in regression.items() if k!='cases'}
    settings.update(firstWordThreshold=0.1,hybridFallbackThreshold=0.31,useNativeSpellingVerdicts=True)
    cases=[];meta={}
    for index,pair in enumerate(PAIRS):
        for language,sentence in zip(['en','sr_latn'],pair):
            words=list(re.finditer(r'\b[^\W\d_]{5,}\b',sentence))
            eligible=[w for w in words if w.start()>16]
            assert len(eligible)>=2,sentence
            chosen=[eligible[len(eligible)//3],eligible[min(len(eligible)-1,2*len(eligible)//3)]]
            points=[(chosen[0].start(),'boundary')]+[(w.start()+max(2,len(w.group())//2),'midword') for w in chosen]
            for point,(offset,kind) in enumerate(points):
                identifier=f'fresh-{index:02}-{language}-{point}'
                cases.append(dict(id=identifier,prefix=sentence[:offset],resetCache=point==0))
                meta[identifier]=dict(scenario=index,language=language,kind=kind,reference=sentence[offset:])
    write(inputs/'fresh.json',dict(settings,cases=cases));write(inputs/'fresh-meta.json',meta)
    write(OUT/'fresh-corpus.json',dict(pairs=PAIRS))
    old=[]
    for name in ['prefix-confirmation-corpus.json','midword-corpus.json']:
        old.extend(s for pair in read(HERE/name)['pairs'] for s in pair)
    assert not set(old)&{s for pair in PAIRS for s in pair}
    paragraphs={
      'en':'The document records practical decisions made during ordinary project work. Each entry explains what changed and why the result matters. We keep useful examples beside the relevant explanation. The team checks each result carefully before deciding what to do next. ',
      'sr_latn':'Dokument beleži praktične odluke donete tokom svakodnevnog rada. Svaka stavka objašnjava šta se promenilo i zašto je rezultat važan. Korisne primere čuvamo pored odgovarajućeg objašnjenja. Tim pažljivo proverava svaki rezultat pre odluke o narednim koracima. '}
    long=[];longmeta={};dynamic=[];dynamicmeta={}
    selected=[c for c in cases if meta[c['id']]['kind']=='midword'][:24]
    for index,case in enumerate(selected):
        language=meta[case['id']]['language'];prefix=paragraphs[language]*6+'\n\n'+case['prefix']
        for prewarm in [False,True]:
            identifier=f'long-{index:02}-'+('prewarm' if prewarm else 'cold')
            long.append(dict(id=identifier,prefix=prefix,resetCache=True,prewarmPrompt=prewarm))
            longmeta[identifier]=dict(scenario=index,language=language,kind='prewarm' if prewarm else 'cold')
    write(inputs/'long.json',dict(settings,cases=long));write(inputs/'long-meta.json',longmeta)
    for trace,(en,sr) in enumerate(PAIRS[:6]):
        for language,sentence in [('en',en),('sr_latn',sr)]:
            stem=f'dynamic-{trace}-{language}';offsets=list(range(20,min(len(sentence)-1,68),4))
            items=[(sentence[:n],'type',None) for n in offsets]
            items += [(sentence[:offsets[-1]-4],'backspace',None),(sentence[:offsets[-1]],'retype',None)]
            longprefix=paragraphs[language]*6+'\n\n'+sentence[:offsets[-1]]
            items += [(longprefix,'cancel',5),(longprefix,'recover',None),(longprefix,'coldReference',None)]
            for step,(prefix,action,cancel) in enumerate(items):
                identifier=f'{stem}-{step}'
                item=dict(id=identifier,prefix=prefix,cacheScope=stem,resetCache=action in ['cancel','coldReference'])
                if cancel is not None:item['cancelAfterMs']=cancel
                dynamic.append(item);dynamicmeta[identifier]=dict(scenario=stem,language=language,kind=action)
    write(inputs/'dynamic.json',dict(settings,cases=dynamic));write(inputs/'dynamic-meta.json',dynamicmeta)
    plan=dict(frozenAtUTC=now(),sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
      installedBinarySHA256=sha('/Applications/LokalBot.app/Contents/MacOS/LokalBot'),
      modelFile=MODEL.name,modelSHA256=sha(MODEL),arms=ARMS,
      controls='E2B weights, raw prompt, sampler, budgets, confidence thresholds fixed within each dataset. Existing matched-frequency corpus is regression/development only. Fresh uses production gates.',
      adoption='Only output-identical strategies qualify for adoption. Select on regression screening, then confirm latency on fresh, dynamic and long inputs. Require >=5% mean improvement and no material p95 regression; report paired scenario intervals. Changed-output arms are ablations only and get blind Claude judging.',
      timing='Serial runs; one screening round of all arms, then three varied-order confirmation rounds of current and finalists. Eight excluded warmups. Tracing off. Compare same binary and isolate home, defaults and storage. Record prewarm separately from generation. No UI first-visible or human-acceptance claim.',
      gaps=['Exact-only/no-overshoot ablation','Prefix-work reuse','Focus-prewarm fresh/shared cases','Cancellation and cold-reference recovery','Six skipped Qwen native tests'],
      largerDeferred=['Multi-sequence batching if single-sequence reuse wins sufficiently','Token-history booster and training require a separate synthetic learning protocol; no private data mining','EuroLLM optional alternate and large MoE ceiling do not isolate E2B latency'],
      datasets={p.stem:dict(sha256=sha(p),cases=len(read(p)['cases'])) for p in inputs.glob('*.json') if not p.stem.endswith('-meta')})
    write(OUT/'plan.json',plan);print(json.dumps(plan['datasets'],indent=2))

def pin(binary):
    if (OUT/'binary.json').exists(): raise ValueError('Use a new output directory; frozen binary metadata already exists.')
    if sha(MODEL) != read(OUT/'plan.json')['modelSHA256']: raise ValueError('The study requires its pinned E2B weights.')
    TMP.mkdir(parents=True,exist_ok=True)
    binary=binary.resolve()
    frozen=TMP/'benchmark.app'
    shutil.copytree(binary.parent.parent.parent,frozen)
    installed=TMP/'installed.app';shutil.copytree(Path('/Applications/LokalBot.app'),installed)
    target=frozen/'Contents/MacOS/LokalBot'
    write(OUT/'binary.json',dict(path=str(target),sha256=sha(target),installedPath=str(installed/'Contents/MacOS/LokalBot'),
        installedSHA256=sha(installed/'Contents/MacOS/LokalBot'),createdAtUTC=now()))
    subprocess.run(['git','diff','--','LokalBot'],cwd=ROOT,stdout=(OUT/'experiment-source.patch').open('w'),check=True)
    print('Pinned',target)

def run_one(arm,dataset,round_index=1,trace=False):
    directory=OUT/f'run-{dataset}-{arm}-{round_index}'
    if trace:directory=directory.with_name(directory.name+'-trace')
    if (directory/'receipt.json').exists():return
    directory.mkdir()
    fixture=copy.deepcopy(read(OUT/'inputs'/f'{dataset}.json'))
    if arm!='installed':
        fixture['searchExperiment']='baseline'
        fixture.update(ARMS[arm])
    if trace:fixture['healingTrace']=True
    warmups=[dict(id=f'warmup-{i}',prefix=p) for i,p in enumerate(['Please check the ','Hvala na pomoći, ']*4)]
    fixture['cases']=warmups+fixture['cases'];write(directory/'input.json',fixture)
    binary=read(OUT/('binary-threadsplit.json' if dataset.endswith('-threadsplit') else 'binary.json'));path=binary['installedPath' if arm=='installed' else 'path']
    start=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='lokalbot-latency-') as tmp:
        local=Path(tmp);(local/'home').mkdir()
        env=dict(os.environ,CFFIXED_USER_HOME=str(local/'home'),LOKALBOT_STORAGE_ROOT=str(local/'storage'),LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.'+local.name)
        with (directory/'raw.jsonl').open('w') as stdout,(directory/'stderr.log').open('w') as stderr:
            proc=subprocess.run(['/usr/bin/time','-l',path,'--cotyping-replay',str(directory/'input.json'),'--model-path',str(MODEL)],env=env,stdout=stdout,stderr=stderr,timeout=600)
    observed=rows(directory/'raw.jsonl');assert proc.returncode==0,(directory,proc.returncode)
    assert len(observed)==len(fixture['cases']) and not any(r.get('error') for r in observed),directory
    write(directory/'receipt.json',dict(complete=True,arm=arm,dataset=dataset,round=round_index,trace=trace,finishedAtUTC=now(),wallSeconds=time.monotonic()-start,
        binarySHA256=sha(path),inputSHA256=sha(directory/'input.json'),rawSHA256=sha(directory/'raw.jsonl'),modelSHA256=read(OUT/'plan.json')['modelSHA256']))
    print(json.dumps(dict(completed=directory.name,cases=len(observed)-8,meanMs=statistics.mean(r['latencyMs'] for r in observed[8:]))),flush=True)

def analyze():
    groups={};details={}
    for directory in sorted(OUT.glob('run-*')):
        if not (directory/'receipt.json').exists():continue
        receipt=read(directory/'receipt.json')
        if receipt['trace']:continue
        groups.setdefault((receipt['dataset'],receipt['arm']),[]).extend(rows(directory/'raw.jsonl')[8:])
    if not groups: raise ValueError('No raw replay receipts. Extract the evidence archive before analysis.')
    for (dataset,arm),observed in groups.items():
        base=groups.get((dataset,'current'),[]);reference={r['id']:r for r in base}
        differences=[];prompt_changes=[]
        for r in observed:
            if r['id'] not in reference:continue
            b=reference[r['id']]
            if r['prompt']!=b['prompt']:prompt_changes.append(r['id'])
            if not r.get('cancelled') and not b.get('cancelled') and (r['text'],r.get('suppression'))!=(b['text'],b.get('suppression')):differences.append(r['id'])
        meta=read(OUT/'inputs'/f'{dataset}-meta.json')
        parts={}
        for kind in sorted(set(m['kind'] for m in meta.values())):
            subset=[r for r in observed if meta[r['id']]['kind']==kind and not r.get('cancelled')]
            if subset:parts[kind]=dict(n=len(subset),meanMs=statistics.mean(r['latencyMs'] for r in subset),p95Ms=percentile([r['latencyMs'] for r in subset],.95),prewarmMeanMs=statistics.mean(r.get('prewarmMs',0) for r in subset))
        times=[r['latencyMs'] for r in observed if not r.get('cancelled')]
        details.setdefault(dataset,{})[arm]=dict(requests=len(observed),shown=sum(bool(r['text']) for r in observed),cancelled=sum(bool(r.get('cancelled')) for r in observed),
            meanMs=statistics.mean(times),p50Ms=percentile(times,.5),p95Ms=percentile(times,.95),changedIDs=sorted(set(differences)),promptChanges=sorted(set(prompt_changes)),parts=parts,
            meanDecodedTokens=statistics.mean(r.get('cache',{}).get('decodedTokens',0) for r in observed if r.get('cache')),
            meanSearchRestores=statistics.mean(r.get('cache',{}).get('searchRestores',0) for r in observed if r.get('cache')),
            meanSearchMemoHits=statistics.mean(r.get('cache',{}).get('searchMemoHits',0) for r in observed if r.get('cache')))
    write(OUT/'analysis.json',details)
    for dataset,arms in details.items():
        print(dataset)
        for arm,v in arms.items():print(arm,round(v['meanMs'],2),round(v['p95Ms'],2),'changed',len(v['changedIDs']),'shown',v['shown'],'cancelled',v['cancelled'])

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('command',choices=['prepare','pin','run','analyze']);p.add_argument('--binary',type=Path)
    p.add_argument('--arm',choices=[*ARMS,'installed']);p.add_argument('--dataset');p.add_argument('--round',type=int,default=1);p.add_argument('--trace',action='store_true')
    p.add_argument('--output',type=Path);p.add_argument('--scratch',type=Path);p.add_argument('--model',type=Path)
    a=p.parse_args()
    OUT=a.output.resolve() if a.output else OUT
    TMP=a.scratch.resolve() if a.scratch else TMP
    MODEL=a.model.resolve() if a.model else MODEL
    if a.command=='prepare':prepare()
    elif a.command=='pin':pin(a.binary)
    elif a.command=='run':run_one(a.arm,a.dataset,a.round,a.trace)
    else:analyze()
