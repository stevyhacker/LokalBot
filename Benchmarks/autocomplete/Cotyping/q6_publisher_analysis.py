"""Validate and analyze all saved E2B Q6 study outputs without inference."""
import argparse
from collections import defaultdict
from pathlib import Path
import q6_publisher_experiment as experiment
import quantization_analysis as analysis

study=experiment.study

def calibration_pairs(root):
    cases,scores,_=analysis.load_scores(root)
    comparisons={}
    for baseline,candidate in [('local_static','english'),('local_static','bilingual'),('english','bilingual'),('static','sporky')]:
        key=candidate+'-vs-'+baseline;comparisons[key]={}
        for language in ['all','en','sr_latn']:
            selected=[case for case in cases if language=='all' or case['language']==language]
            groups=defaultdict(list)
            for case in selected:
                row=scores['primary'][case['id']]
                groups[case['scenario']].append((row[baseline+'-matched']['utility'],row[candidate+'-matched']['utility']))
            comparisons[key][language]=analysis.paired(groups)
    return comparisons

def validate(root):
    plan=study.read(root/'plan.json')
    assert study.sha(root/'corpus.json')==plan['corpusSHA256']
    assert study.sha(root/'quantization_experiment.py')==plan['runnerSHA256']
    assert study.sha(root/'q6_publisher_experiment.py')==plan['wrapperSHA256']
    for name,digest in plan['inputSHA256'].items(): assert study.sha(root/'inputs'/name)==digest
    binary=study.read(root/'binary.json'); models={m['id']:m for m in study.read(root/'models.json')}
    receipts=sorted((root/'runs').glob('*/receipt.json'))
    assert len(receipts)==plan['expectedProcesses']
    measured=stable=warmups=0
    for path in receipts:
        receipt=study.read(path); folder=path.parent
        assert receipt['complete'] and receipt['exitCode']==0
        assert receipt['binarySHA256']==binary['sha256'] and receipt['modelSHA256']==models[receipt['arm']]['sha256']
        assert receipt['rawSHA256']==study.sha(folder/'raw.jsonl') and receipt['inputSHA256']==study.sha(folder/'input.json')
        fixture=study.read(folder/'input.json'); raw=study.rows(folder/'raw.jsonl')
        assert [r['id'] for r in raw]==[c['id'] for c in fixture['cases']]
        assert len({r['id'] for r in raw})==len(raw)
        assert all(not r.get('error') and not r['usedPromptOverride'] for r in raw)
        assert all(not r.get('memoryIDs') and not r.get('visibleIDs') and not r.get('visibleTextReadIDs') for r in raw)
        assert all(r['confidenceTrace']==(receipt['mode']=='trace') and r['nativeThreads']==2 and r['nativeBatchThreads']==2
                   and r['searchExperiment']=='certified' and r['selectiveOneWordHybrid'] and r['healingMode']=='prefixSearch' for r in raw)
        baseline=study.rows(root/'runs'/f"production-{receipt['dataset']}-q6-1/raw.jsonl")
        assert [(r['id'],r['prompt']) for r in raw]==[(r['id'],r['prompt']) for r in baseline]
        if receipt['round']>1 and receipt['dataset']!='cancellation':
            previous=study.rows(root/'runs'/f"{receipt['mode']}-{receipt['dataset']}-{receipt['arm']}-1/raw.jsonl")
            assert [(r['text'],r.get('suppression')) for r in raw]==[(r['text'],r.get('suppression')) for r in previous]
            stable+=len(raw)-8
        measured+=len(raw)-8; warmups+=8
    assert measured==plan['expectedMeasuredObservations'] and warmups==len(receipts)*8
    current=study.observed(root,'production','fresh','q6')
    matched=study.observed(root,'matched','fresh','q6')
    baseline_changes=sum(current[i]['text']!=matched[i]['text'] for i in current)
    return dict(processes=len(receipts),measured=measured,excludedWarmups=warmups,byteIdenticalPromptComparisons=measured,
                deterministicRepeatedOutputs=stable,allComplete=True,noReplayErrors=True,fixedBinaryAndModelPins=True,
                noMeetingOrScreenContext=True,baselineMatchingChangedOutputs=baseline_changes)

def main():
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--without-judge',action='store_true')
    args=p.parse_args(); root=args.root
    result=dict(validation=validate(root),timing=analysis.timing(root),outputs=analysis.output_summary(root),
                models=study.read(root/'models.json'),matching=study.read(root/'matched.json'))
    if not args.without_judge:
        result['quality']=analysis.quality(root)
        result['calibrationQualityPairs']=calibration_pairs(root)
    study.write(root/'summary.json',result)
    print(result['validation'])
    for arm in experiment.IDS:
        print(arm,result['timing']['normal']['steady']['fresh'][arm]['all']['paired'])

if __name__=='__main__': main()
