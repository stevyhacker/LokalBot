"""Fixed-decoder E2B quantization study on synthetic EN/Serbian Latin text."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import statistics
import struct
import subprocess
import tempfile
import time

import cancellation_experiment as cancel
import claude_judge as judge

IDS = ['q6', 'q4', 'iq4', 'q5', 'q8']
ORDERS = [['q6', 'q4', 'q8', 'q5', 'iq4'], ['iq4', 'q5', 'q8', 'q4', 'q6']]
SETTINGS = dict(selectiveOneWordHybrid=True, searchExperiment='certified', nativeThreads=2,
                nativeBatchThreads=2, maxWords=4, maxTokens=6, temperature=.1, repeatPenalty=1.05,
                appContext=True, healingMode='prefixSearch', firstWordThreshold=.1,
                hybridFallbackThreshold=.31, useNativeSpellingVerdicts=True, confidenceTrace=False)
WORD = re.compile(r"[^\W\d_]+(?:[-’'][^\W\d_]+)*")
PARAGRAPHS = {
    'en': 'The working notes explain each step of the project. We keep the examples together with the decisions so that everyone can follow the discussion. Before making a change, we check the assumptions and compare the available measurements. A clear description helps the next person understand what still needs attention. ',
    'sr_latn': 'Radne beleške objašnjavaju svaki korak projekta. Čuvamo primere zajedno sa odlukama kako bi svi mogli da prate razgovor. Pre svake izmene proveravamo pretpostavke i upoređujemo dostupna merenja. Jasan opis pomaže sledećoj osobi da razume šta još zahteva pažnju. '
}

def read(path):
    return json.loads(Path(path).read_text())

def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def sha(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()

def rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]

def now():
    return datetime.now(timezone.utc).isoformat()

def prepare(root, app):
    assert not (root / 'plan.json').exists()
    corpus = read(root / 'corpus.json')['pairs']
    assert len(corpus) == 48 and len({s for pair in corpus for s in pair}) == 96
    inputs = root / 'inputs'; inputs.mkdir(exist_ok=True)
    meta = {}; fresh = []; long = []; dynamic = []; cancellation = []
    for scenario, pair in enumerate(corpus):
        for language, sentence in zip(['en', 'sr_latn'], pair):
            words = list(WORD.finditer(sentence))
            eligible = [k for k in range(3, len(words)) if len(words[k].group()) >= 5]
            assert len(eligible) >= 2
            first = min(eligible, key=lambda k: abs(k - len(words)*.53))
            second = min([k for k in eligible if k != first], key=lambda k: abs(k - len(words)*.82))
            points = [(round(len(words)*.35), 0)] + [
                (k, min(len(words[k].group()) - 1, [2, 3, 4, 6][(scenario+j) % 4]))
                for j, k in enumerate([first, second])]
            for step, (k, length) in enumerate(sorted(points)):
                identifier = f'fresh-{scenario:02}-{language}-{step}'
                offset = words[k].start() + length
                fresh.append(dict(id=identifier, prefix=sentence[:offset], resetCache=step == 0))
                meta[identifier] = dict(scenario=scenario, language=language, kind='midword' if length else 'boundary',
                    typed=words[k].group()[:length], referenceWord=words[k].group(), reference=sentence[offset:], offset=offset)
            offset = words[second].start() + min(3, len(words[second].group()) - 1)
            if scenario < 12:
                for prewarm in [False, True]:
                    identifier = f'long-{scenario:02}-{language}-{int(prewarm)}'
                    long.append(dict(id=identifier, prefix=PARAGRAPHS[language]*6 + '\n\n' + sentence[:offset],
                                     resetCache=True, prewarmPrompt=prewarm))
                    meta[identifier] = dict(scenario=scenario, language=language, kind='warm' if prewarm else 'cold')
            if scenario < 8:
                stem = f'dynamic-{scenario:02}-{language}'
                for step, end in enumerate([offset-2, offset, offset+1, offset-1, offset+2, offset+3]):
                    identifier = stem + f'-{step}'
                    dynamic.append(dict(id=identifier, prefix=sentence[:end], cacheScope=stem))
                    meta[identifier] = dict(scenario=scenario, language=language, kind='typing')
            if scenario < 4:
                for length, repeat in [('short', 0), ('long', 6)]:
                    context = PARAGRAPHS[language]*repeat + '\n\n' if repeat else ''
                    for delay in [5, 20, 60]:
                        stem = f'interrupt-{scenario:02}-{language}-{length}-{delay}'
                        for action in ['cancel', 'replacement', 'cold']:
                            identifier = stem + '-' + action
                            item = dict(id=identifier, prefix=context + sentence[:offset if action == 'cancel' else offset+2],
                                        resetCache=action != 'replacement')
                            if action == 'cancel': item['cancelAfterMs'] = delay
                            cancellation.append(item)
                            meta[identifier] = dict(scenario=scenario, language=language, kind=action, delay=delay, length=length)
    for dataset, cases in [('fresh', fresh), ('long', long), ('dynamic', dynamic), ('cancellation', cancellation)]:
        write(inputs / f'{dataset}.json', dict(SETTINGS, cases=cases))
    write(root / 'case-meta.json', meta)
    binary = dict(path=str(app), sha256=sha(app), sourceCommit='ea3970204e0831d6a76a533f6daec0b9a7a67c5d',
                  installedSHA256=sha('/Applications/LokalBot.app/Contents/MacOS/LokalBot'),
                  note='Unchanged Release replay binary from the cancellation study; source runtime hashes verified before reuse.')
    write(root / 'binary.json', binary)
    write(root / 'plan.json', dict(frozenAtUTC=now(), corpusSHA256=sha(root/'corpus.json'), models=IDS,
        settings=SETTINGS, seed=0xC0FFEE, topP=.7, topK=20, minP=.08, orders=ORDERS,
        inputSHA256={p.name:sha(p) for p in inputs.iterdir()}, runnerSHA256=sha(__file__),
        primary='Drop-in production thresholds 0.1/0.31, every quantization, fixed prompt/decoder/native runtime. No parameter tuning.',
        matched='Separate diagnostic: preserve every native midword output. Per language match total shown count to Q6 production (or the greatest lower common feasible count) using only unlabeled boundary confidence and ratio3.1. No quality labels determine cutoffs. Actual native matched runs are timed; traced outputs are not timed.',
        quality='Anonymous Claude usefulness rubric, all unique nonempty production/matched suggestions; silence=0. 24 reversed-option repeats, 5000 scenario-cluster paired bootstrap draws. Reference-word agreement is secondary. If external judging is unavailable, report that limit and do not infer subjective quality from exact-reference score alone.',
        timing='Two serial reverse-order rounds for production fresh/long/dynamic/cancellation, plus two for matched fresh. Eight excluded warmups. No builds, native tests or downloads during inference. Peak process RSS/footprint and launch-to-first-output are separate from native latency.',
        cancellation='Use actual issued time, require both arms cancelled for paired latency, also measure through the next completed replacement; compare recovery with a cold reference. Report unmatched/undelivered timers.',
        decision='Keep Q6 unless quality is non-regressing in each language at both production and matched frequency (including poor counts), and normal/cancellation mean and p95 do not regress. A worthwhile speed upgrade should improve fresh mean by at least10%; a Q8 quality upgrade requires a positive quality interval and no normal-speed regression. Otherwise retain Q6 and describe optional tradeoffs. No installed model changes during measurement.',
        scope='48 new bilingual scenarios, 288 fresh checkpoints; long/dynamic/cancellation subsets identified in metadata. One machine, one synthetic corpus, model-judge opinion rather than human acceptance. No UI tests or CI actions.',
        hardware={k:subprocess.check_output(command,text=True).strip() for k,command in [
            ('chip',['sysctl','-n','machdep.cpu.brand_string']),('memoryBytes',['sysctl','-n','hw.memsize']),
            ('os',['sw_vers']),('power',['pmset','-g','batt'])]}))
    print(json.dumps({'prepared':str(root),'cases':{p.stem:len(read(p)['cases']) for p in inputs.iterdir()}}),flush=True)

def run_one(root, arm, mode, round_number, dataset):
    source = root/'inputs'/f'{dataset}.json'
    assert sha(source) == read(root/'plan.json')['inputSHA256'][source.name]
    fixture = read(source)
    if mode == 'trace': fixture['confidenceTrace'] = True
    if mode == 'matched':
        cuts = read(root/'matched.json')['cutoffs'][arm]; meta = read(root/'case-meta.json')
        for case in fixture['cases']:
            case.update(firstWordThreshold=cuts[meta[case['id']]['language']]['primary'],
                        hybridFallbackThreshold=cuts[meta[case['id']]['language']]['fallback'])
    warmups = [dict(id=f'warmup-{i}',prefix=p) for i,p in enumerate(['Please check the ', 'Hvala na pomoći, ']*4)]
    fixture['cases'] = warmups + fixture['cases']
    folder = root/'runs'/f'{mode}-{dataset}-{arm}-{round_number}'; folder.mkdir(parents=True)
    write(folder/'input.json',fixture)
    model = next(m for m in read(root/'models.json') if m['id'] == arm)
    assert Path(model['path']).stat().st_size == model['bytes']
    assert read(root/f'model-{arm}.json')['sha256'] == model['sha256']
    binary = read(root/'binary.json'); assert sha(binary['path']) == binary['sha256']
    started = time.monotonic(); first = None
    receipt = dict(startedAtUTC=now(), arm=arm, mode=mode, dataset=dataset, round=round_number,
                   inputSHA256=sha(folder/'input.json'), binarySHA256=binary['sha256'], modelSHA256=model['sha256'],
                   power=subprocess.check_output(['pmset','-g','batt'],text=True).strip())
    write(folder/'receipt.json',receipt)
    with tempfile.TemporaryDirectory(prefix='lokalbot-quant-replay-') as tmp:
        storage = Path(tmp); (storage/'home').mkdir()
        env = dict(os.environ,CFFIXED_USER_HOME=str(storage/'home'),LOKALBOT_STORAGE_ROOT=str(storage/'storage'),
                   LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.'+storage.name)
        with (folder/'raw.jsonl').open('w') as stdout, (folder/'stderr.log').open('w') as stderr:
            process = subprocess.Popen(['/usr/bin/time','-l',binary['path'],'--cotyping-replay',str(folder/'input.json'),
                                        '--model-path',model['path']],env=env,stdout=subprocess.PIPE,stderr=stderr,text=True)
            for line in process.stdout:
                if first is None: first = time.monotonic()-started
                stdout.write(line); stdout.flush()
            code = process.wait(timeout=600)
    raw = rows(folder/'raw.jsonl'); measured = raw[8:]
    assert code == 0 and [r['id'] for r in raw] == [r['id'] for r in fixture['cases']]
    assert not any(r.get('error') for r in raw)
    assert all(not r['usedPromptOverride'] for r in raw)
    if mode == 'matched':
        trace=observed(root,'trace',dataset,arm)
        meta=read(root/'case-meta.json')
        config=read(root/'matched.json')
        assert all(row['text']==candidate(trace[row['id']],**config['cutoffs'][arm][meta[row['id']]['language']])
                   for row in measured), 'Trace/matched native parity'
        for language,frequency in config['frequencies'].items():
            assert sum(bool(row['text']) for row in measured if meta[row['id']]['language']==language)==frequency['matched']
    baseline = root/'runs'/f'production-{dataset}-q6-1/raw.jsonl'
    if baseline.exists():
        assert [(r['id'],r['prompt']) for r in raw] == [(r['id'],r['prompt']) for r in rows(baseline)], 'Prompt drift'
    if round_number > 1 and dataset != 'cancellation':
        old = rows(root/'runs'/f'{mode}-{dataset}-{arm}-1/raw.jsonl')
        assert [(r['text'],r.get('suppression')) for r in raw] == [(r['text'],r.get('suppression')) for r in old], 'Output drift'
    log = (folder/'stderr.log').read_text(errors='replace')
    def memory(label):
        match = re.search(r'(\d+)\s+'+label,log)
        return int(match.group(1)) if match else None
    receipt.update(complete=True,exitCode=code,finishedAtUTC=now(),wallSeconds=time.monotonic()-started,
        launchToFirstObservationSeconds=first, measured=len(measured),excludedWarmups=8,
        shown=sum(bool(r['text']) for r in measured),cancelled=sum(r.get('cancelled',False) for r in measured),
        meanMs=statistics.mean(r['latencyMs'] for r in measured),rawSHA256=sha(folder/'raw.jsonl'),
        maximumResidentBytes=memory('maximum resident set size'),peakFootprintBytes=memory('peak memory footprint'))
    write(folder/'receipt.json',receipt)
    print(json.dumps(receipt),flush=True)

def run(root, mode):
    orders = [IDS] if mode == 'trace' else ORDERS
    for round_number,order in enumerate(orders,1):
        for arm in order:
            for dataset in ['fresh','long','dynamic','cancellation'] if mode == 'production' else ['fresh']:
                run_one(root,arm,mode,round_number,dataset)

def observed(root, mode, dataset, arm, round_number=1):
    folder=root/'runs'/f'{mode}-{dataset}-{arm}-{round_number}'
    assert sha(folder/'raw.jsonl') == read(folder/'receipt.json')['rawSHA256']
    return {r['id']:r for r in rows(folder/'raw.jsonl') if not r['id'].startswith('warmup-')}

def candidate(row, primary, fallback):
    if not row['text']: return ''
    cache=row.get('cache') or {}
    if not cache.get('confidenceGateEligible'): return row['text']
    if cache.get('firstWordProbability',1.) >= primary: return row['text']
    return row['oneWordText'] if cache.get('hybridFallbackProbability',0.) >= fallback else ''

def cutoff(group, count):
    scores=sorted([max(r['cache'].get('firstWordProbability',1.),
                       r['cache'].get('hybridFallbackProbability',0.)/3.1 if r['oneWordText'] else 0)
                   for r in group if r['text']],reverse=True)
    assert 0<count<len(scores) and scores[count-1]>scores[count], 'Unmatchable quota or confidence tie'
    midpoint=(scores[count-1]+scores[count])/2
    f32=lambda x:struct.unpack('f',struct.pack('f',min(1.,x)))[0]
    cut=dict(primary=f32(midpoint),fallback=f32(midpoint*3.1))
    assert sum(bool(candidate(row,**cut)) for row in group)==count
    return cut

def match(root):
    meta=read(root/'case-meta.json'); cuts={arm:{} for arm in IDS}; frequencies={}
    trace={arm:observed(root,'trace','fresh',arm) for arm in IDS}
    prod={arm:observed(root,'production','fresh',arm) for arm in IDS}
    for arm in IDS:
        assert all(candidate(row,.1,.31)==prod[arm][identifier]['text'] for identifier,row in trace[arm].items()), 'Trace/production parity'
    for language in ['en','sr_latn']:
        identifiers=[i for i in trace['q6'] if meta[i]['language']==language]
        desired=sum(bool(prod['q6'][i]['text']) for i in identifiers)
        counts={arm:sum(bool(row['text']) for i,row in trace[arm].items() if i in identifiers) for arm in IDS}
        target=min(desired,min(counts.values())-1)
        frequencies[language]=dict(baselineProduction=desired,matched=target,total=len(identifiers))
        for arm in IDS:
            ungated=[row for i,row in trace[arm].items() if i in identifiers and not (row.get('cache') or {}).get('confidenceGateEligible')]
            gated=[row for i,row in trace[arm].items() if i in identifiers and (row.get('cache') or {}).get('confidenceGateEligible')]
            quota=target-sum(bool(row['text']) for row in ungated)
            cuts[arm][language]=cutoff(gated,quota)
    write(root/'matched.json',dict(createdAtUTC=now(),frequencies=frequencies,cutoffs=cuts,
                                  note='Transductive equal-frequency diagnostic only; no quality labels or production setting changes.'))
    print(json.dumps(frequencies),flush=True)

def prepare_judge(root):
    target=root/'judge'; target.mkdir()
    meta=read(root/'case-meta.json'); inputs=read(root/'inputs/fresh.json')['cases']
    policies={f'{arm}-{mode}':observed(root,mode,'fresh',arm) for arm in IDS for mode in ['production','matched']}
    cases=[dict(id=item['id'],prefix=item['prefix'],scenario=meta[item['id']]['scenario'],
                language=meta[item['id']]['language'],kind=meta[item['id']]['kind'],
                policies={policy:data[item['id']]['text'] for policy,data in policies.items()}) for item in inputs]
    primary=sorted([case for case in cases if any(case['policies'].values())],key=lambda case:judge.digest('quant:'+case['id']))
    repeat=sorted(primary,key=lambda case:judge.digest('quant-repeat:'+case['id']))[:24]
    mapping={}; batches=[]
    for stage,selected in [('primary',primary),('repeat',repeat)]:
        packets=[]
        for case in selected:
            packet=judge.blind_case(case,stage=='repeat')
            mapping[packet['id']]=dict(caseID=case['id'],stage=stage,options={o['id']:o['continuation'] for o in packet['options']})
            packets.append(packet)
        for offset in range(0,len(packets),12):
            name=f'{stage}-{offset//12+1:02}'; folder=target/'batches'/name; folder.mkdir(parents=True)
            packet=dict(cases=packets[offset:offset+12]); write(folder/'packet.json',packet)
            request=judge.RUBRIC+json.dumps(packet['cases'],ensure_ascii=False,separators=(',',':'))
            (folder/'request.txt').write_text(request)
            batches.append(dict(id=name,stage=stage,cases=len(packet['cases']),requestSHA256=judge.digest(request)))
    write(target/'cases.json',cases);write(target/'private-mapping.json',mapping)
    (target/'system.txt').write_text(judge.SYSTEM);write(target/'schema.json',judge.SCHEMA)
    write(target/'protocol.json',dict(createdAtUTC=now(),batches=batches,primaryCases=len(primary),repeatCases=len(repeat),
          packetContents='Only fictional typed prefixes and anonymous continuations. No model names, code, timing, personal text or intended futures.',
          casesSHA256=sha(target/'cases.json')))
    print(json.dumps({'judgeCases':len(primary),'repeats':len(repeat),'batches':len(batches)}),flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--root',type=Path,required=True)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('prepare');p.add_argument('--app',type=Path,required=True)
    p=sub.add_parser('run');p.add_argument('--mode',choices=['production','trace','matched'],required=True)
    sub.add_parser('match');sub.add_parser('judge-prepare')
    args=parser.parse_args()
    if args.command=='prepare':prepare(args.root,args.app)
    elif args.command=='run':run(args.root,args.mode)
    elif args.command=='match':match(args.root)
    else:prepare_judge(args.root)

if __name__=='__main__':main()
