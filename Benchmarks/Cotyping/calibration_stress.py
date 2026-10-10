#!/usr/bin/env python3
"""Latency-only long-document companion; uses frozen development cutoffs.

Every pair starts with an explicit cache reset, followed by a shared document
prefix. No quality scores or equal-frequency claims are derived from this set.
"""
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

from confidence_calibration import APP, OUT, IDS, SETTINGS, LANGUAGES, read, write, rows, now, digest, percentile


def prepare():
    paragraphs={
        'en': 'This document records ordinary project work and practical decisions. We review the available information and agree on the next steps. Some tasks are quick, while others need more discussion. The team keeps a record of important changes and checks the result before moving on. Everyone should have enough context to understand the current plan. Clear examples often make a complicated explanation easier to follow. ',
        'sr_latn': 'Ovaj dokument sadrži beleške o redovnom radu i praktičnim odlukama. Zajedno pregledamo dostupne podatke i dogovaramo naredne korake. Neki zadaci se završavaju brzo, dok drugi zahtevaju više razgovora. Tim beleži važne promene i proverava rezultate pre nastavka rada. Svako treba da ima dovoljno podataka da razume trenutni plan. Jasni primeri često pomažu da složeno objašnjenje postane razumljivije. '
    }
    refs=read(OUT/'confirmation-references.json');original=read(OUT/'confirmation-input.json')['cases']
    cases=[];metadata={}
    for lang in LANGUAGES:
        selected=[c for c in original if refs[c['id']]['language']==lang and refs[c['id']]['kind']=='boundary'][:16]
        for i,case in enumerate(selected):
            identifier='long-'+case['id']
            cases.append(dict(case,id=identifier,prefix=paragraphs[lang]*5+'\n\n'+case['prefix'],resetCache=i%2==0))
            metadata[identifier]=dict(language=lang,transition='fresh' if i%2==0 else 'shared')
    write(OUT/'long-input.json',{'cases':cases});write(OUT/'long-references.json',metadata)
    write(OUT/'long-plan.json',dict(createdAtUTC=now(),cases=len(cases),rounds=3,models=IDS,
        inputSHA256=digest(OUT/'long-input.json'),settings=SETTINGS,
        purpose='Latency stress only, with development cutoffs fixed; frequency is not matched on long contexts. Production context limits remain unchanged. First request in each document pair resets the native cache; the next shares its prefix.',
        timing='Three serial counterbalanced rounds after primary timing, eight excluded warmups, load excluded. No simultaneous GPU, build or download work.'))


def run_one(model,round_index):
    directory=OUT/f'long-{round_index}-{model}'
    if (directory/'receipt.json').exists() and read(directory/'receipt.json').get('complete'):return
    directory.mkdir()
    spec=next(m for m in read(OUT/'models.json') if m['id']==model)
    assert digest(APP)==read(OUT/'binary.json')['sha256']
    refs=read(OUT/'long-references.json');cases=read(OUT/'long-input.json')['cases']
    cuts=read(OUT/'calibration.json')['models'][model]['cutoffs']
    for case in cases:
        cut=cuts[refs[case['id']]['language']]
        case.update(firstWordThreshold=cut['primary'],hybridFallbackThreshold=cut['fallback'])
    warmups=[dict(id=f'warmup-{i}',prefix=p,appName='Notes',bundleID='com.apple.Notes') for i,p in enumerate(['Please check the ', 'Hvala na pomoći, ']*4)]
    write(directory/'input.json',dict(SETTINGS,cases=warmups+cases))
    start=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='lokalbot-calibration-long-') as tmp:
        root=Path(tmp);(root/'home').mkdir()
        env=dict(os.environ,CFFIXED_USER_HOME=str(root/'home'),LOKALBOT_STORAGE_ROOT=str(root/'storage'),LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.'+root.name)
        with (directory/'raw.jsonl').open('w') as stdout,(directory/'stderr.log').open('w') as stderr:
            subprocess.run(['/usr/bin/time','-l',str(APP),'--cotyping-replay',str(directory/'input.json'),'--model-path',spec['path']],env=env,stdout=stdout,stderr=stderr,check=True,timeout=600)
    raw=rows(directory/'raw.jsonl');assert len(raw)==40 and not any(r.get('error') for r in raw)
    observations=raw[8:]
    baseline=OUT/'long-1-baseline/observations.jsonl'
    if baseline.exists():assert [(r['id'],r['prompt']) for r in observations]==[(r['id'],r['prompt']) for r in rows(baseline)]
    if round_index>1:assert [r['text'] for r in observations]==[r['text'] for r in rows(OUT/f'long-1-{model}/observations.jsonl')]
    (directory/'observations.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in observations))
    write(directory/'receipt.json',dict(complete=True,finishedAtUTC=now(),wallSeconds=time.monotonic()-start,
        modelSHA256=spec['sha256'],binarySHA256=digest(APP),inputSHA256=digest(directory/'input.json'),observationsSHA256=digest(directory/'observations.jsonl')))
    print(json.dumps({'completed':directory.name}),flush=True)


def analyze():
    refs=read(OUT/'long-references.json');report={}
    for model in IDS:
        data=[r for i in [1,2,3] for r in rows(OUT/f'long-{i}-{model}/observations.jsonl')]
        def summarize(group):
            times=[r['latencyMs'] for r in group]
            return dict(n=len(group),meanMs=statistics.mean(times),p95Ms=percentile(times,.95),shown=sum(bool(r['text']) for r in group))
        report[model]=dict(overall=summarize(data),transitions={t:summarize([r for r in data if refs[r['id']]['transition']==t]) for t in ['fresh','shared']})
    write(OUT/'long-analysis.json',report)
    print(json.dumps(report,indent=2),flush=True)


if __name__=='__main__':
    if sys.argv[1]=='prepare':prepare()
    elif sys.argv[1]=='run':
        for i,order in enumerate([IDS,list(reversed(IDS)),IDS[3:]+IDS[:3]],1):
            for model in order:run_one(model,i)
    else:analyze()
