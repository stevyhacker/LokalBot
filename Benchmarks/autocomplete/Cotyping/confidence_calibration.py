#!/usr/bin/env python3
"""Native, fixed-prompt calibration; separate fitting, matching, timing and judging.

The exact-frequency holdout is explicitly transductive: it uses holdout scores,
never quality labels, to set a cutoff. The frozen development cutoff is reported
separately. Neither raw confidence nor Claude utility is an acceptance probability.
"""
import argparse
from collections import defaultdict
import json
import math
import os
from pathlib import Path
import random
import statistics
import struct
import subprocess
import tempfile
import time

import claude_judge as judge
from model_study import read, write, rows, now, percentile, bootstrap
from quality_replay import WORD, digest

HERE = Path(__file__).resolve().parent
OUT = HERE / 'results/2026-10-10-calibration'
TEMP = Path('/private/tmp/lokalbot-calibration-20261010')
APP = TEMP / 'replay-LokalBot.app/Contents/MacOS/LokalBot'
IDS = ['baseline', 'luchador', 'gemma4_it', 'qwen3_base4', 'salamandra2', 'yugogpt7']
RATIOS = [.5, 1., 2., 3.1, 5., 10., 1000000.]
SETTINGS = dict(selectiveOneWordHybrid=True, maxWords=4, maxTokens=6,
                temperature=.1, repeatPenalty=1.05, appContext=True)
LANGUAGES = ['en', 'sr_latn']
COVERAGE = .60


def f32(value):
    return struct.unpack('f', struct.pack('f', value))[0]


def make_cases(corpus, split):
    cases, refs = [], {}
    for language in LANGUAGES:
        phrases = corpus[f'{split}_{language}']
        assert len(phrases) == 32
        for i, sentence in enumerate(phrases):
            words = list(WORD.finditer(sentence))
            boundary_indices = [round(len(words) * x) for x in [.4, .7]]
            candidates = [k for k in range(2, len(words)-1) if len(words[k].group()) >= 4]
            mid_index = min(candidates, key=lambda k: (abs(k-len(words)*.55), k))
            positions = [(k, 0) for k in boundary_indices] + [(mid_index, len(words[mid_index].group())//2)]
            for k, offset in sorted(positions):
                ident = f'{split}-{language}-{i:02}-{k}-{offset}'
                prefix = sentence[:words[k].start()+offset]
                kind = 'midword' if offset else 'boundary'
                cases.append(dict(id=ident, prefix=prefix, appName='Notes', bundleID='com.apple.Notes',
                                  wordPrefixIsValidWord=True))
                refs[ident] = dict(language=language, kind=kind, phraseID=f'{split}-{i:02}',
                                  sentence=sentence, typed=words[k].group()[:offset])
    return cases, refs


def prepare():
    OUT.mkdir(parents=True, exist_ok=False)
    corpus = read(HERE/'calibration-corpus.json')
    write(OUT/'corpus.json', corpus)
    old_sentences = []
    old = read(HERE/'model-study-corpus.json')
    for values in old['categories'].values():
        old_sentences.extend(values)
    for split in ['development', 'confirmation']:
        cases, refs = make_cases(corpus, split)
        assert not any(ref['sentence'] in old_sentences for ref in refs.values())
        write(OUT/f'{split}-input.json', {'cases': cases})
        write(OUT/f'{split}-references.json', refs)
    existing = read(HERE/'results/2026-10-10-models/models.json')
    models = [m for m in existing if m['id'] in ['baseline', 'luchador']]
    for m in read(HERE/'results/2026-10-10-models/claude-test-list.json')['models']:
        q = m['quantization']
        models.append(dict(id=m['id'], path=str(TEMP/'models'/q['filename']), sha256=q['publishedSHA256'],
                           bytes=q['bytes'], url=q['downloadURL'], source=m['sourceRepo']))
    write(OUT/'models.json', models)
    write(OUT/'plan.json', dict(createdAtUTC=now(), status='frozen before inference', models=IDS,
        settings=SETTINGS, topP=.7, topK=20, minP=.08, seed=0xC0FFEE, ratioGrid=RATIOS,
        corpusSHA256=digest(OUT/'corpus.json'), scriptSHA256=digest(__file__), targetCoverage=COVERAGE,
        split='32 paired everyday/work scenarios per split, each in EN and Serbian Latin. Two word boundaries and one midword per sentence. The cross-language pairs share a bootstrap cluster.',
        primary='Equal frequency at word boundaries, separately within English and Serbian Latin (38/64 per language, 59.375%). Midword healing is ungated and reported separately, never silently suppressed to force a match.',
        fit='On development only, choose one fallback/primary threshold ratio per model from a frozen 7-point grid, maximizing balanced mean Claude utility at equal frequency; ties: fewer poor outputs, then closest to existing ratio 3.1. Fit language cutoffs from scores.',
        confirmation='Freeze ratio and development cutoffs before confirmation inference. Report frozen-cutoff generalization. For the equal-frequency comparison only, recompute the cutoff from unlabeled confirmation scores, preserving the frozen ratio. This is a transductive diagnostic, not a deployable fixed policy.',
        judge='Claude Opus 5.5, anonymous options, no model names, future/reference, latency or source. Full and one-word candidates deduplicated. 16 reversed-option repeat cases each split. One judge, synthetic text, no human acceptance claims.',
        timing='Three serial rounds in counterbalanced model order. Trace disabled and actual calibrated early exits enabled. Eight excluded warmups. Measures native generation plus normalization; excludes load, UI/debounce and first visible latency. Do not time during downloads, builds or another GPU run.',
        production='No prompt, token budget, sampler, cache policy or midword gate changes. Replay-only thresholds and tracing. No PR CI or UI tests.',
        selection='Compare all six at equal EN/SR Latin frequency. Report uncertainty versus Luchador and E2B. Cyrillic does not enter selection. A small synthetic judged study cannot establish real user acceptance.'))
    print(json.dumps({'prepared':str(OUT)}), flush=True)


def candidate(row, primary, fallback, hybrid=True):
    if not row['text']:
        return ''
    cache = row.get('cache') or {}
    if not cache.get('confidenceGateEligible'):
        return row['text']
    p, b = cache.get('firstWordProbability', 1.), cache.get('hybridFallbackProbability', 0.)
    if p >= primary:
        return row['text']
    return row['oneWordText'] if hybrid and b >= fallback else ''


def cutoff(group, ratio, count, hybrid=True):
    scored = []
    for row in group:
        if not row['text']:
            continue
        c = row['cache']
        assert c['confidenceGateEligible']
        score = c.get('firstWordProbability', 1.)
        if hybrid and row['oneWordText']:
            score = max(score, c.get('hybridFallbackProbability', 0.) / ratio)
        scored.append(score)
    scored.sort(reverse=True)
    if len(scored) <= count:
        raise ValueError(f'Insufficient candidates for strict coverage: {len(scored)} <= {count}')
    if scored[count-1] <= scored[count]:
        raise ValueError('Confidence tie at cutoff; cannot claim exact native frequency')
    raw_cut = (scored[count-1] + scored[count]) / 2
    # A gate above probability 1 is equivalent to disabling that branch for
    # scores below 1. The exact-count assertion also catches any unit-score tie.
    a = f32(min(1., raw_cut))
    b = f32(min(1., ratio*raw_cut))
    assert 0 < a <= 1 and 0 < b <= 1
    assert sum(bool(candidate(r, a, b, hybrid)) for r in group) == count
    return dict(primary=a, fallback=b)


def trace_rows(split, model):
    return rows(OUT/f'{split}-trace-1-{model}/observations.jsonl')


def run_one(split, mode, model, round_index=1):
    if split == 'confirmation' and mode == 'trace':
        assert (OUT/'calibration.json').exists(), 'Lock development fit first'
    directory = OUT/f'{split}-{mode}-{round_index}-{model}'
    if (directory/'receipt.json').exists() and read(directory/'receipt.json').get('complete'):
        print(json.dumps({'cached':directory.name}), flush=True)
        return
    directory.mkdir(exist_ok=False)
    model_id = 'baseline' if model == 'original' else model
    spec = next(m for m in read(OUT/'models.json') if m['id'] == model_id)
    app_receipt = read(OUT/'binary.json')
    assert digest(APP) == app_receipt['sha256']
    assert Path(spec['path']).stat().st_size == spec['bytes']
    assert read(OUT/'verified-models.json')[model_id] == spec['sha256']
    cases = read(OUT/f'{split}-input.json')['cases']
    refs = read(OUT/f'{split}-references.json')
    settings = dict(SETTINGS, confidenceTrace=mode == 'trace')
    if model == 'original':
        settings['selectiveOneWordHybrid'] = False
    config = None
    if mode in ['matched', 'frozen']:
        config = read(OUT/('matched.json' if mode == 'matched' else 'calibration.json'))['models'][model]
        for case in cases:
            cuts = config['cutoffs'][refs[case['id']]['language']]
            case['firstWordThreshold'] = cuts['primary']
            if model != 'original':
                case['hybridFallbackThreshold'] = cuts['fallback']
    warmups = [dict(id=f'warmup-{i}',prefix=p,appName='Notes',bundleID='com.apple.Notes') for i,p in enumerate(
        ['Please check the ', 'We can discuss the ', 'Molim te proveri ', 'Hvala na pomoći, ']*2)]
    write(directory/'input.json', dict(cases=warmups+cases, **settings))
    receipt = dict(startedAtUTC=now(), binarySHA256=app_receipt['sha256'], modelSHA256=spec['sha256'],
                   inputSHA256=digest(directory/'input.json'), settings=settings, excludedWarmups=len(warmups),
                   power=subprocess.check_output(['pmset','-g','batt'],text=True).strip())
    write(directory/'receipt.json', receipt)
    print(json.dumps({'starting':directory.name}),flush=True)
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='lokalbot-calibration-') as tmp:
        root=Path(tmp); (root/'home').mkdir()
        env=dict(os.environ,CFFIXED_USER_HOME=str(root/'home'),LOKALBOT_STORAGE_ROOT=str(root/'storage'),
                 LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.'+root.name)
        with (directory/'raw.jsonl').open('w') as stdout, (directory/'stderr.log').open('w') as stderr:
            result=subprocess.run(['/usr/bin/time','-l',str(APP),'--cotyping-replay',str(directory/'input.json'),
                                   '--model-path',spec['path']],env=env,stdout=stdout,stderr=stderr,timeout=1800)
    receipt.update(exitCode=result.returncode, wallSeconds=time.monotonic()-start)
    write(directory/'receipt.json',receipt)
    assert result.returncode == 0, directory
    raw=rows(directory/'raw.jsonl')
    assert [r['id'] for r in raw] == [c['id'] for c in warmups+cases]
    assert not any(r.get('error') for r in raw)
    observed=raw[len(warmups):]
    assert all(not r['usedPromptOverride'] and not r['stopAtDisplayLimit'] for r in observed)
    baseline=OUT/f'{split}-trace-1-baseline/observations.jsonl'
    if baseline.exists():
        assert [(r['id'],r['prompt']) for r in observed] == [(r['id'],r['prompt']) for r in rows(baseline)], 'Prompt drift'
    if mode != 'trace':
        trace=trace_rows(split,model_id)
        expected=[]
        for row in trace:
            cuts=config['cutoffs'][refs[row['id']]['language']] if config else dict(primary=.1,fallback=.31)
            expected.append(candidate(row,cuts['primary'],cuts['fallback'],model!='original'))
        mismatch=[dict(id=r['id'],expected=e,actual=r['text']) for r,e in zip(observed,expected) if r['text']!=e]
        write(directory/'trace-parity.json',mismatch)
        assert not mismatch, f'Counterfactual parity failed: {directory}'
    repeated=OUT/f'{split}-{mode}-1-{model}/observations.jsonl'
    if round_index>1:
        assert [r['text'] for r in observed] == [r['text'] for r in rows(repeated)], 'Timing output drift'
    (directory/'observations.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in observed))
    receipt.update(complete=True,finishedAtUTC=now(),observationsSHA256=digest(directory/'observations.jsonl'))
    write(directory/'receipt.json',receipt)
    print(json.dumps({'finished':directory.name,'n':len(observed),'shown':sum(bool(r['text']) for r in observed),
                      'meanMs':statistics.mean(r['latencyMs'] for r in observed)}),flush=True)


def prepare_judge(split):
    target=OUT/f'judge-{split}'; target.mkdir()
    data={m:trace_rows(split,m) for m in IDS}
    refs=read(OUT/f'{split}-references.json')
    cases=[]
    for i,item in enumerate(read(OUT/f'{split}-input.json')['cases']):
        policies={}
        for model in IDS:
            row=data[model][i]; assert row['id']==item['id']
            policies[model]=row['text']; policies[model+'-one']=row['oneWordText']
        cases.append(dict(id=item['id'],prefix=item['prefix'],phraseID=refs[item['id']]['phraseID'],
                          language=refs[item['id']]['language'],kind=refs[item['id']]['kind'],policies=policies))
    primary=sorted([c for c in cases if any(c['policies'].values())],key=lambda c:judge.digest('calibration:'+c['id']))
    mapping,batches={},[]
    for stage,selected in [('primary',primary),('repeat',primary[:16])]:
        public=[]
        for case in selected:
            packet=judge.blind_case(case,stage=='repeat')
            mapping[packet['id']]=dict(caseID=case['id'],stage=stage,options={o['id']:o['continuation'] for o in packet['options']})
            public.append(packet)
        for i in range(0,len(public),10):
            name=f'{stage}-{i//10+1:02}'; directory=target/'batches'/name; directory.mkdir(parents=True)
            packet={'cases':public[i:i+10]}; write(directory/'packet.json',packet)
            prompt=judge.RUBRIC+json.dumps(packet['cases'],ensure_ascii=False,separators=(',',':'))
            (directory/'request.txt').write_text(prompt)
            batches.append(dict(id=name,stage=stage,cases=len(packet['cases']),requestSHA256=judge.digest(prompt)))
    write(target/'cases.json',cases); write(target/'private-mapping.json',mapping)
    write(target/'protocol.json',dict(createdAtUTC=now(),batches=batches,counts=dict(primary=len(primary),repeat=16),
                                     casesSHA256=digest(target/'cases.json'),model='claude-opus-5-5'))
    print(json.dumps({'judgePrepared':split,'batches':len(batches)}),flush=True)


def scores(split):
    target=OUT/f'judge-{split}'; mapping=read(target/'private-mapping.json')
    result={stage:defaultdict(dict) for stage in ['primary','repeat']}
    models=set()
    for batch in read(target/'protocol.json')['batches']:
        directory=target/'batches'/batch['id']
        receipt=read(directory/'receipt.json'); assert not receipt['isError']; models.update(receipt['models'])
        ratings=judge.validate_judgments(read(directory/'packet.json'),read(directory/'ratings.json'),strict_preference=False)
        for case in ratings['cases']:
            m=mapping[case['id']]
            for rating in case['ratings']:
                result[m['stage']][m['caseID']][m['options'][rating['id']]]=rating
    for case in read(target/'cases.json'):
        result['primary'][case['id']]['']=dict(utility=0,first_word=0,flags=[],reason='Silence')
    repeats=[(result['primary'][k][text]['utility'],v['utility']) for k,options in result['repeat'].items() for text,v in options.items()]
    write(target/'stability.json',dict(models=sorted(models),options=len(repeats),exactAgreement=sum(a==b for a,b in repeats),
        signAgreement=sum((a>0,a<0)==(b>0,b<0) for a,b in repeats)))
    write(target/'scores.json',result['primary'])
    return result['primary']


def fit_group(data,refs,ratio,hybrid=True):
    cuts={}
    for language in LANGUAGES:
        group=[r for r in data if refs[r['id']]['language']==language and refs[r['id']]['kind']=='boundary']
        cuts[language]=cutoff(group,ratio,round(len(group)*COVERAGE),hybrid)
    return cuts


def fit():
    assert not (OUT/'calibration.json').exists()
    values=scores('development'); refs=read(OUT/'development-references.json')
    result=dict(createdAtUTC=now(),models={},candidates={})
    for model in IDS+['original']:
        data=trace_rows('development','baseline' if model=='original' else model)
        trials=[]
        for ratio in ([1000000.] if model=='original' else RATIOS):
            cuts=fit_group(data,refs,ratio,model!='original')
            outputs={r['id']:candidate(r,**cuts[refs[r['id']]['language']],hybrid=model!='original') for r in data}
            utilities=[values[k][text]['utility'] for k,text in outputs.items() if refs[k]['kind']=='boundary']
            trials.append(dict(ratio=ratio,cutoffs=cuts,meanUtility=statistics.mean(utilities),poor=sum(v<0 for v in utilities)))
        best=sorted(trials,key=lambda t:(-t['meanUtility'],t['poor'],abs(math.log(t['ratio']/3.1))))[0]
        result['models'][model]=best;result['candidates'][model]=trials
    result['developmentJudgmentsSHA256']=digest(OUT/'judge-development/scores.json')
    write(OUT/'calibration.json',result)
    print(json.dumps(result['models'],indent=2),flush=True)


def match():
    assert not (OUT/'matched.json').exists()
    fitted=read(OUT/'calibration.json'); refs=read(OUT/'confirmation-references.json')
    result=dict(createdAtUTC=now(),method='Unlabeled holdout score quantiles; ratios frozen on development',models={})
    for model,fit in fitted['models'].items():
        data=trace_rows('confirmation','baseline' if model=='original' else model)
        result['models'][model]=dict(ratio=fit['ratio'],cutoffs=fit_group(data,refs,fit['ratio'],model!='original'))
    write(OUT/'matched.json',result)
    print(json.dumps(result,indent=2),flush=True)


def analyze():
    values=scores('confirmation');refs=read(OUT/'confirmation-references.json')
    fitted=read(OUT/'calibration.json'); matched=read(OUT/'matched.json')
    report=dict(createdAtUTC=now(),arms={},comparisons={})
    utilities={}
    for mode in ['matched','frozen','asis']:
        for model in IDS+['original']:
            data=trace_rows('confirmation','baseline' if model=='original' else model)
            outputs={}
            for row in data:
                cuts=(matched if mode=='matched' else fitted)['models'][model]['cutoffs'][refs[row['id']]['language']] if mode!='asis' else dict(primary=.1,fallback=.31)
                outputs[row['id']]=candidate(row,**cuts,hybrid=model!='original')
            key=f'{mode}-{model}'; utilities[key]={k:values[k][v]['utility'] for k,v in outputs.items()}
            def group_summary(keys):
                vs=[utilities[key][k] for k in keys]
                shown=sum(bool(outputs[k]) for k in keys)
                return dict(n=len(keys),shown=shown,coverage=shown/len(keys),useful=sum(v>0 for v in vs),poor=sum(v<0 for v in vs),
                            meanUtility=statistics.mean(vs),usefulFractionOfShown=sum(v>0 for v in vs)/shown if shown else None,
                            helpfulFirstWords=sum(values[k][outputs[k]]['first_word']>0 for k in keys),
                            meanShownCharacters=statistics.mean(len(outputs[k]) for k in keys if outputs[k]) if shown else 0,
                            oneWordShown=sum(bool(outputs[k]) and len(WORD.findall(outputs[k]))==1 for k in keys),
                            utilityIgnoringPositiveTinySuggestions=statistics.mean(0 if len(outputs[k].strip())<=3 and utilities[key][k]>0 else utilities[key][k] for k in keys))
            arm={'overall':group_summary(list(refs)),
                 'boundary':group_summary([k for k in refs if refs[k]['kind']=='boundary']),
                 'midword':group_summary([k for k in refs if refs[k]['kind']=='midword']),
                 'allLanguages':{lang:group_summary([k for k in refs if refs[k]['language']==lang]) for lang in LANGUAGES},
                 'languages':{lang:group_summary([k for k in refs if refs[k]['kind']=='boundary' and refs[k]['language']==lang]) for lang in LANGUAGES}}
            if mode=='matched':
                runs=[rows(OUT/f'confirmation-matched-{i}-{model}/observations.jsonl') for i in [1,2,3]]
                for run in runs:
                    assert all(r['text']==outputs[r['id']] for r in run)
                def latency(kind=None,language=None):
                    times=[r['latencyMs'] for run in runs for r in run if (kind is None or refs[r['id']]['kind']==kind) and (language is None or refs[r['id']]['language']==language)]
                    return dict(requests=len(times),meanMs=statistics.mean(times),p50Ms=percentile(times,.5),p95Ms=percentile(times,.95))
                arm['latency']=dict(overall=latency(),boundary=latency('boundary'),midword=latency('midword'),
                                   languages={lang:latency('boundary',lang) for lang in LANGUAGES},
                                   allLanguages={lang:latency(language=lang) for lang in LANGUAGES})
            report['arms'][key]=arm
    boundary=[k for k in refs if refs[k]['kind']=='boundary']
    for model in IDS+['original']:
        key='matched-'+model
        report['comparisons'][model]={}
        for base in ['baseline','luchador']:
            ds=[utilities[key][k]-utilities['matched-'+base][k] for k in boundary]
            report['comparisons'][model][base]=dict(utilityDelta=bootstrap(ds,[refs[k]['phraseID'] for k in boundary]),
                wins=sum(d>0 for d in ds),ties=sum(d==0 for d in ds),losses=sum(d<0 for d in ds))
            all_ds=[utilities[key][k]-utilities['matched-'+base][k] for k in refs]
            report['comparisons'][model][base]['overallUtilityDelta']=bootstrap(all_ds,[refs[k]['phraseID'] for k in refs])
    write(OUT/'analysis.json',report)
    write(OUT/'confirmation-utilities.json',utilities)
    print(json.dumps({k:v for k,v in report['arms'].items() if k.startswith('matched-')},indent=2),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['prepare','run','prepare-judge','judge','fit','match','analyze'])
    parser.add_argument('--split',choices=['development','confirmation'],default='development')
    parser.add_argument('--mode',choices=['trace','matched','frozen','asis'],default='trace')
    parser.add_argument('--models',nargs='+',default=IDS)
    parser.add_argument('--round',type=int,default=1)
    args=parser.parse_args()
    if args.action=='prepare':prepare()
    elif args.action=='run':
        for model in args.models:run_one(args.split,args.mode,model,args.round)
    elif args.action=='prepare-judge':prepare_judge(args.split)
    elif args.action=='judge':judge.run(OUT/f'judge-{args.split}',3,None,'claude-opus-5-5')
    elif args.action=='fit':fit()
    elif args.action=='match':match()
    elif args.action=='analyze':analyze()


if __name__=='__main__':main()
