"""Fixed-E2B cancellation study, serial native replays with frozen synthetic inputs."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import statistics
import subprocess
import tempfile
import os
import time

MODEL_SHA = '20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629'
ARMS = {
    'default': {},
    'early128': {'nativePrefillChunkSize': 2048, 'nativePrefillFirstChunkSize': 128,
                 'nativeFinalPrefillLogitsOnly': True},
    'early128sync': {'nativePrefillChunkSize': 2048, 'nativePrefillFirstChunkSize': 128,
                     'nativeFinalPrefillLogitsOnly': True, 'nativeSynchronizePrefillChunks': True},
    'early192sync': {'nativePrefillChunkSize': 2048, 'nativePrefillFirstChunkSize': 192,
                     'nativeFinalPrefillLogitsOnly': True, 'nativeSynchronizePrefillChunks': True},
    'early64sync': {'nativePrefillChunkSize': 2048, 'nativePrefillFirstChunkSize': 64,
                    'nativeFinalPrefillLogitsOnly': True, 'nativeSynchronizePrefillChunks': True},
    'batch4': {'nativeBatchThreads': 4},
    'batch8': {'nativeBatchThreads': 8},
    'batch14': {'nativeBatchThreads': 14},
    'chunk128': {'nativePrefillChunkSize': 128},
    'chunk64': {'nativePrefillChunkSize': 64},
    'last256': {'nativeFinalPrefillLogitsOnly': True},
    'last128': {'nativePrefillChunkSize': 128, 'nativeFinalPrefillLogitsOnly': True},
    'last64': {'nativePrefillChunkSize': 64, 'nativeFinalPrefillLogitsOnly': True},
    'sync128': {'nativePrefillChunkSize': 128, 'nativeFinalPrefillLogitsOnly': True,
                'nativeSynchronizePrefillChunks': True},
    'sync64': {'nativePrefillChunkSize': 64, 'nativeFinalPrefillLogitsOnly': True,
               'nativeSynchronizePrefillChunks': True},
}
PAIRS = [
    ('The electrician checked the damaged socket before reconnecting the power supply.',
     'Električar je proverio oštećenu utičnicu pre ponovnog uključivanja napajanja.'),
    ('We labelled the storage boxes before moving them into the basement.',
     'Obeležili smo kutije za odlaganje pre nego što smo ih odneli u podrum.'),
    ('Please tighten the handle on the cupboard before installing the remaining shelves.',
     'Molim te pričvrsti ručku na ormariću pre nego što postaviš preostale police.'),
    ('The receptionist wrote the appointment details on a small piece of paper.',
     'Recepcionarka je zapisala podatke o zakazanom sastanku na malom parčetu papira.'),
    ('The baker left the dough beside the radiator while preparing the filling.',
     'Pekar je ostavio testo pored radijatora dok je pripremao nadev.'),
    ('We compared the measurements before ordering new curtains for the bedroom.',
     'Uporedili smo dimenzije pre nego što smo naručili nove zavese za spavaću sobu.'),
    ('The volunteer returned the borrowed equipment after cleaning the community hall.',
     'Volonter je vratio pozajmljenu opremu nakon čišćenja zajedničke sale.'),
    ('Please attach the updated diagram to the maintenance instructions for tomorrow.',
     'Molim te priloži ažuriranu šemu uz uputstva za sutrašnje održavanje.'),
    ('The carpenter sanded the wooden frame before applying a protective coating.',
     'Stolar je izbrusio drveni okvir pre nanošenja zaštitnog premaza.'),
    ('Please place the reusable containers beside the refrigerator after washing them.',
     'Molim te stavi posude za višekratnu upotrebu pored frižidera nakon pranja.'),
    ('Our neighbour brought a replacement wheel for the broken garden trolley.',
     'Naš komšija je doneo rezervni točak za pokvarena baštenska kolica.'),
    ('The technician disconnected the faulty sensor before checking the control panel.',
     'Tehničar je isključio neispravan senzor pre provere kontrolne table.'),
    ('We reserved a quiet corner of the restaurant for the family celebration.',
     'Rezervisali smo miran kutak restorana za porodičnu proslavu.'),
    ('The museum guide explained how the original photographs had been restored.',
     'Muzejski vodič je objasnio kako su originalne fotografije obnovljene.'),
    ('Please rinse the paintbrushes thoroughly before putting them back in the cabinet.',
     'Molim te dobro isperi četkice pre nego što ih vratiš u ormarić.'),
    ('We transferred the seedlings into the greenhouse before the temperature dropped.',
     'Premestili smo sadnice u staklenik pre nego što je temperatura pala.'),
    ('The delivery notice explains where to collect the parcel on Saturday morning.',
     'Obaveštenje o isporuci objašnjava gde možemo preuzeti paket u subotu ujutru.'),
    ('The swimming instructor demonstrated the breathing exercise before entering the pool.',
     'Instruktor plivanja je pokazao vežbu disanja pre ulaska u bazen.'),
    ('Please separate the damaged tiles from the ones we can use again.',
     'Molim te odvoji oštećene pločice od onih koje možemo ponovo upotrebiti.'),
    ('The shop assistant located the missing receipt in the afternoon transaction records.',
     'Prodavac je pronašao nedostajući račun u evidenciji popodnevnih transakcija.'),
    ('We reviewed the accessibility requirements before approving the navigation design.',
     'Pregledali smo zahteve za pristupačnost pre odobravanja dizajna navigacije.'),
    ('The migration should preserve every custom shortcut configured by existing users.',
     'Migracija treba da sačuva svaku prilagođenu prečicu koju su podesili postojeći korisnici.'),
    ('Please document the recovery procedure beside the instructions for creating backups.',
     'Molim te zabeleži postupak oporavka pored uputstava za pravljenje rezervnih kopija.'),
    ('The monthly report includes a separate breakdown of outstanding support requests.',
     'Mesečni izveštaj sadrži poseban pregled nerešenih zahteva za podršku.'),
    ('We adjusted the workshop materials after receiving comments from the participants.',
     'Prilagodili smo materijale za radionicu nakon komentara učesnika.'),
    ('The application should discard an outdated result when another request replaces it.',
     'Aplikacija treba da odbaci zastareli rezultat kada ga zameni drugi zahtev.'),
    ('Please add the missing translation before publishing the installation instructions.',
     'Molim te dodaj prevod koji nedostaje pre objavljivanja uputstava za instalaciju.'),
    ('The reviewer verified that the correction also covers previously saved preferences.',
     'Recenzent je proverio da ispravka obuhvata i ranije sačuvana podešavanja.'),
    ('We repeated the measurement after closing the applications running in the background.',
     'Ponovili smo merenje nakon zatvaranja aplikacija koje rade u pozadini.'),
    ('The revised checklist makes the responsibilities clearer for everyone on the project.',
     'Izmenjena kontrolna lista jasnije opisuje odgovornosti svih učesnika projekta.'),
    ('Please include the reproduction steps when reporting an unexpected connection error.',
     'Molim te navedi korake za ponavljanje kada prijavljuješ neočekivanu grešku u povezivanju.'),
    ('The archive contains the original measurements alongside the final comparison report.',
     'Arhiva sadrži izvorna merenja zajedno sa konačnim uporednim izveštajem.'),
]
PARAGRAPH = {
    'en': 'These notes describe routine work on a shared project. We record each decision and keep the explanation beside the example. The next review will check the details carefully. Everyone should be able to follow the procedure and understand the result. ',
    'sr_latn': 'Ove beleške opisuju svakodnevni rad na zajedničkom projektu. Beležimo svaku odluku i čuvamo objašnjenje pored primera. Prilikom sledeće provere pažljivo ćemo pregledati detalje. Svi treba da mogu da prate postupak i razumeju rezultat. ',
}
SETTINGS = dict(selectiveOneWordHybrid=True, searchExperiment='certified', nativeThreads=2,
                maxWords=4, maxTokens=6, temperature=0.1, repeatPenalty=1.05, appContext=True,
                healingMode='prefixSearch', confidenceTrace=False, firstWordThreshold=0.1,
                hybridFallbackThreshold=0.31, useNativeSpellingVerdicts=True)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def prepare(root):
    inputs = root / 'inputs'
    inputs.mkdir()
    meta = {}
    for phase, selection in [('screen', range(8)), ('confirmation', range(8, 32))]:
        fresh, long, dynamic, cancellation = [], [], [], []
        sources = []
        for scenario in selection:
            for language, sentence in zip(['en', 'sr_latn'], PAIRS[scenario]):
                words = [m for m in re.finditer(r'\b[^\W\d_]{5,}\b', sentence) if m.start() > 16]
                chosen = [words[len(words)//3], words[min(len(words)-1, 2*len(words)//3)]]
                points = [(chosen[0].start(), 'boundary')] + [
                    (word.start()+max(2, len(word.group())//2), 'midword') for word in chosen]
                for point, (offset, kind) in enumerate(points):
                    identifier = f'{phase}-fresh-{scenario:02}-{language}-{point}'
                    fresh.append(dict(id=identifier, prefix=sentence[:offset], resetCache=point == 0))
                    meta[identifier] = dict(scenario=scenario, language=language, kind=kind)
                offset = points[-1][0]
                sources.append((scenario, language, sentence, offset))
                prefix = PARAGRAPH[language]*6 + '\n\n' + sentence[:offset]
                for prewarm in [False, True]:
                    identifier = f'{phase}-long-{scenario:02}-{language}-{int(prewarm)}'
                    long.append(dict(id=identifier, prefix=prefix, resetCache=True, prewarmPrompt=prewarm))
                    meta[identifier] = dict(scenario=scenario, language=language, kind='warm' if prewarm else 'cold')
        # Smaller screening keeps unsuccessful alternatives cheap; confirmation
        # uses untouched scenarios and a wider range of interruption lengths.
        selected = sources[:8] if phase == 'screen' else sources[:24]
        for scenario, language, sentence, offset in selected:
            for length, repeat in [('medium', 2), ('long', 6)] + ([] if phase == 'screen' else [('short', 0)]):
                prefix = (PARAGRAPH[language]*repeat + '\n\n' if repeat else '') + sentence[:offset]
                replacement = (PARAGRAPH[language]*repeat + '\n\n' if repeat else '') + sentence[:offset+2]
                for delay in [5, 20]:
                    stem = f'{phase}-interrupt-{scenario:02}-{language}-{length}-{delay}'
                    for action in ['cancel', 'replacement', 'cold']:
                        identifier = stem + '-' + action
                        item = dict(id=identifier, prefix=prefix if action == 'cancel' else replacement,
                                    resetCache=action != 'replacement')
                        if action == 'cancel':
                            item['cancelAfterMs'] = delay
                        cancellation.append(item)
                        meta[identifier] = dict(scenario=scenario, language=language, kind=action,
                                                length=length, delay=delay, event=stem)
        for scenario, language, sentence, offset in selected:
            stem = f'{phase}-typing-{scenario:02}-{language}'
            for step, end in enumerate([offset-4, offset-2, offset, offset+1, offset-2, offset+2]):
                identifier = stem + f'-{step}'
                dynamic.append(dict(id=identifier, prefix=sentence[:end], cacheScope=stem))
                meta[identifier] = dict(scenario=scenario, language=language, kind='typeOrBackspace')
        for name, cases in [('fresh', fresh), ('long', long), ('dynamic', dynamic), ('cancellation', cancellation)]:
            warmups = [dict(id=f'warmup-{i}', prefix=['Please check the ', 'Hvala na pomoći, '][i % 2]) for i in range(8)]
            write(inputs / f'{phase}-{name}.json', dict(SETTINGS, cases=warmups+cases))
    write(root / 'case-meta.json', meta)
    write(root / 'corpus.json', {'pairs': PAIRS, 'contextParagraphs': PARAGRAPH})
    plan = dict(frozenAtUTC=datetime.now(timezone.utc).isoformat(), modelSHA256=MODEL_SHA,
                sourceBase='1d39a5ea796d90ed391290ce260eb08370ab8c0b', arms=ARMS,
                settings=SETTINGS, inputSHA256={p.name: sha(p) for p in inputs.iterdir()},
                screening='One pass per alternative, default bracketing controls; choose before opening holdout outputs.',
                confirmation='Four serial counterbalanced rounds on untouched scenarios: AB, BA, BA, AB.',
                adoptionGate={
                    'quality': 'Exact text, suppression and prompt parity for all non-cancelled paired normal/replacement requests; recovery equals its cold reference.',
                    'normalSpeed': 'No worse mean or p95 on fresh, long and dynamic; paired scenario bootstrap upper 95% bound for mean difference <= 0 ms on each workload. Per-language mean must also not worsen.',
                    'cancellation': 'At least 100 paired delivered cancellations; upper 95% bound < 0 for both cancellation-return and cancellation-through-replacement mean differences. Report shown-only replacement timing and coverage separately.',
                    'ifUncertain': 'Keep the installed default. Do not treat a noisy/inconclusive result as non-regression.'},
                timing='Monotonic issuance to returned cancellation and next completed replacement; includes cleanup, intervening replay output and request/spelling preparation. Not UI latency.',
                fixed='E2B weights, request/prompt, confidence gates, sampler, search width/budget, normalization; no inference concurrent with builds/tests.')
    write(root / 'plan.json', plan)
    print(json.dumps({'prepared':str(root),'cases':{p.name:len(read(p)['cases'])-8 for p in inputs.iterdir()}}, indent=2))


def pin(root, app, model):
    assert sha(model) == MODEL_SHA
    target = root / 'candidate.app'
    assert not target.exists()
    shutil.copytree(app, target, symlinks=True)
    record = dict(path=str(target), executableSHA256=sha(target/'Contents/MacOS/LokalBot'), modelSHA256=sha(model))
    write(root/'binary.json', record)
    print(json.dumps(record))


def run(root, model, phase, arm, round_number, dataset, baseline=False):
    plan = read(root/'plan.json')
    source = root/'inputs'/f'{phase}-{dataset}.json'
    assert sha(source) == plan['inputSHA256'][source.name]
    fixture = read(source)
    fixture.update(ARMS[arm])
    name = f'{phase}-{dataset}-{arm}-{round_number}' + ('-installed' if baseline else '')
    folder = root/'runs'/name
    folder.mkdir(parents=True)
    write(folder/'input.json', fixture)
    app = root/('baseline.app' if baseline else 'candidate.app')
    exe = app/'Contents/MacOS/LokalBot'
    binary_hash = sha(exe)
    assert binary_hash == read(root/('baseline.json' if baseline else 'binary.json'))['executableSHA256']
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='lokalbot-cancel-replay-') as temp:
        local = Path(temp)
        (local/'home').mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(local/'home'), LOKALBOT_STORAGE_ROOT=str(local/'storage'),
                   LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.'+local.name)
        with (folder/'raw.jsonl').open('w') as stdout, (folder/'stderr.log').open('w') as stderr:
            proc = subprocess.run([str(exe),'--cotyping-replay',str(folder/'input.json'),'--model-path',str(model)],
                                  env=env,stdout=stdout,stderr=stderr,timeout=600)
    actual = rows(folder/'raw.jsonl')
    measured = [row for row in actual if not row['id'].startswith('warmup-')]
    receipt = dict(name=name,phase=phase,arm=arm,round=round_number,dataset=dataset,installed=baseline,
                   exitCode=proc.returncode,binarySHA256=binary_hash,inputSHA256=sha(folder/'input.json'),
                   rawSHA256=sha(folder/'raw.jsonl'),rows=len(actual),measured=len(measured),
                   cancelled=sum(row.get('cancelled',False) for row in measured),
                   shown=sum(bool(row['text']) for row in measured),
                   meanMs=statistics.mean(row['latencyMs'] for row in measured),wallSeconds=time.monotonic()-start)
    write(folder/'receipt.json',receipt)
    print(json.dumps(receipt),flush=True)
    assert proc.returncode == 0 and len(actual)==len(fixture['cases'])
    assert not any(row.get('error') for row in actual)
    return actual


def screen(root, model, selected=None):
    installed = run(root,model,'screen','default',0,'fresh',baseline=True)
    order = selected if selected is not None else list(ARMS)[1:]
    random.Random(11021).shuffle(order)
    order = ['default'] + order + ['default']
    write(root/'screen-order.json',order)
    for index,arm in enumerate(order):
        for dataset in ['fresh','long','cancellation']:
            actual = run(root,model,'screen',arm,2 if index==len(order)-1 else 1,dataset)
            if arm == 'default' and dataset == 'fresh':
                keys = ['id', 'prompt', 'text', 'suppression', 'error', 'cancelled']
                assert all(all(a.get(k) == b.get(k) for k in keys) for a,b in zip(actual,installed)), 'Installed default A/A parity'


def confirm(root, model, arm):
    selection = dict(selectedAtUTC=datetime.now(timezone.utc).isoformat(), arm=arm,
                     order=[['default',arm],[arm,'default'],[arm,'default'],['default',arm]])
    write(root/'confirmation-selection.json',selection)
    for round_number, order in enumerate(selection['order'],1):
        for selected in order:
            for dataset in ['fresh','long','dynamic','cancellation']:
                run(root,model,'confirmation',selected,round_number,dataset)


def metrics(values):
    values=sorted(values)
    if not values: return None
    return dict(n=len(values),mean=statistics.mean(values),p50=values[int((len(values)-1)*0.5)],
                p95=values[int((len(values)-1)*0.95)])


def paired(groups):
    # Group all languages, prefix checkpoints, lengths, delays and rounds from
    # each original bilingual source; do not count correlated rows as samples.
    all_pairs=[pair for group in groups.values() for pair in group]
    if not all_pairs: return None
    rng=random.Random(20261011)
    keys=sorted(groups)
    sums={key:(sum(y-x for x,y in group),len(group)) for key,group in groups.items()}
    deltas=[]
    for _ in range(5000):
        draw=[sums[key] for key in rng.choices(keys,k=len(keys))]
        deltas.append(sum(total for total,count in draw)/sum(count for total,count in draw))
    deltas.sort()
    return dict(default=metrics([x for x,y in all_pairs]),candidate=metrics([y for x,y in all_pairs]),
                deltaMs=statistics.mean(y-x for x,y in all_pairs),
                delta95CI=[deltas[125],deltas[4874]],scenarioCount=len(keys))


def load_run(root, phase, dataset, arm, round_number):
    folder=root/'runs'/f'{phase}-{dataset}-{arm}-{round_number}'
    receipt=read(folder/'receipt.json')
    assert receipt['rawSHA256']==sha(folder/'raw.jsonl')
    return {row['id']:row for row in rows(folder/'raw.jsonl') if not row['id'].startswith('warmup-')}


def analyze(root, phase, arm, rounds):
    meta=read(root/'case-meta.json')
    result=dict(phase=phase,arm=arm,rounds=rounds,normal={},qualityDifferences=[],recoveryDifferences=[],
                interruptionCounts={'default':defaultdict(int),'candidate':defaultdict(int)})
    cancel_groups=defaultdict(list); replacement_groups=defaultdict(list); shown_groups=defaultdict(list)
    delay_groups=defaultdict(lambda: defaultdict(list))
    for dataset in (['fresh','long'] if phase=='screen' else ['fresh','long','dynamic'])+['cancellation']:
        groups=defaultdict(list); langs={lang:defaultdict(list) for lang in ['en','sr_latn']}
        for round_number in rounds:
            base=load_run(root,phase,dataset,'default',round_number)
            candidate=load_run(root,phase,dataset,arm,round_number)
            assert base.keys()==candidate.keys()
            for identifier,b in base.items():
                c=candidate[identifier]; info=meta[identifier]
                if info['kind']=='cancel':
                    for label,row in [('default',b),('candidate',c)]:
                        result['interruptionCounts'][label]['attempted']+=1
                        issued=row.get('cancellationRequestedAfterMs')
                        result['interruptionCounts'][label]['issued']+=issued is not None
                        result['interruptionCounts'][label]['cancelled']+=row.get('cancelled',False)
                    if not all(row.get('cancelled') and row.get('cancellationRequestedAfterMs') is not None for row in [b,c]):
                        continue
                    following=identifier.removesuffix('-cancel')+'-replacement'
                    recovery=[base[following],candidate[following]]
                    returns=[row['latencyMs']-row['cancellationRequestedAfterMs'] for row in [b,c]]
                    totals=[nextrow['replayCompletedAtMs']-(row['generationStartedAtMs']+row['cancellationRequestedAfterMs'])
                            for row,nextrow in zip([b,c],recovery)]
                    cancel_groups[info['scenario']].append(tuple(returns))
                    replacement_groups[info['scenario']].append(tuple(totals))
                    delay_groups[str(info['delay'])][info['scenario']].append(tuple(totals))
                    if all(row['text'] for row in recovery): shown_groups[info['scenario']].append(tuple(totals))
                    continue
                keys=['prompt','text','suppression','error','cancelled']
                changed=[key for key in keys if b.get(key)!=c.get(key)]
                if changed: result['qualityDifferences'].append(dict(dataset=dataset,round=round_number,id=identifier,keys=changed))
                if info['kind']=='replacement':
                    cold=identifier.removesuffix('-replacement')+'-cold'
                    for label,rows_by_id,row in [('default',base,b),('candidate',candidate,c)]:
                        if any(row.get(key)!=rows_by_id[cold].get(key) for key in keys):
                            result['recoveryDifferences'].append(dict(arm=label,round=round_number,id=identifier))
                if dataset!='cancellation':
                    pair=(b['latencyMs'],c['latencyMs'])
                    groups[info['scenario']].append(pair); langs[info['language']][info['scenario']].append(pair)
        if dataset!='cancellation':
            result['normal'][dataset]=paired(groups)
            result['normal'][dataset]['languages']={language:paired(g) for language,g in langs.items()}
    result['cancellationReturn']=paired(cancel_groups)
    result['cancellationThroughReplacement']=paired(replacement_groups)
    result['cancellationThroughShownReplacement']=paired(shown_groups)
    result['cancellationThroughReplacementByDelay']={delay:paired(groups) for delay,groups in delay_groups.items()}
    result['passesQuality']=not result['qualityDifferences'] and not result['recoveryDifferences']
    result['passesNormalSpeed']=all(
        row['delta95CI'][1]<=0 and row['candidate']['p95']<=row['default']['p95']
        and all(x['deltaMs']<=0 for x in row['languages'].values()) for row in result['normal'].values())
    result['passesCancellation']=all(result[key] and result[key]['default']['n']>=100 and result[key]['delta95CI'][1]<0
                                     and result[key]['candidate']['p95']<=result[key]['default']['p95']
                                     for key in ['cancellationReturn','cancellationThroughReplacement'])
    result['passesAdoptionGate']=phase=='confirmation' and all(result[key] for key in ['passesQuality','passesNormalSpeed','passesCancellation'])
    write(root/f'{phase}-{arm}-analysis.json',result)
    print(json.dumps(result,ensure_ascii=False,indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--model',type=Path)
    sub=parser.add_subparsers(dest='command',required=True)
    sub.add_parser('prepare')
    p=sub.add_parser('pin');p.add_argument('--app',type=Path,required=True)
    p=sub.add_parser('screen');p.add_argument('--arms')
    p=sub.add_parser('confirm');p.add_argument('--arm',choices=list(ARMS),required=True)
    p=sub.add_parser('analyze');p.add_argument('--phase',choices=['screen','confirmation'],required=True)
    p.add_argument('--arm',choices=list(ARMS),required=True);p.add_argument('--rounds',default='1')
    args=parser.parse_args()
    if args.command=='prepare':prepare(args.root)
    elif args.command=='pin':pin(args.root,args.app,args.model)
    elif args.command=='screen':screen(args.root,args.model,args.arms.split(',') if args.arms else None)
    elif args.command=='confirm':confirm(args.root,args.model,args.arm)
    else:analyze(args.root,args.phase,args.arm,[int(x) for x in args.rounds.split(',')])


if __name__=='__main__':main()
