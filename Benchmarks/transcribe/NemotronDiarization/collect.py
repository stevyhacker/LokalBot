"""Validate completeness and retain compact evidence in the repository."""
import hashlib
import json
import math
import pathlib
import shutil
import statistics

ROOT = pathlib.Path('/private/tmp/lokalbot-nemotron-bench')
DEST = pathlib.Path(__file__).resolve().parent / 'results/2026-09-23'
VARIANTS = ['baseline', 'baseline-overlap', 'community-overlap', 'offline', 'fast128', 'c128-split-w8a8', 'low']
manifest = json.loads((ROOT/'manifest.json').read_text())
expected = {x['id'] for x in manifest}
scores = json.loads((ROOT/'scores.json').read_text())
DEST.mkdir(parents=True, exist_ok=True)
for variant in VARIANTS:
    files = list((ROOT/'results'/variant).glob('*.json'))
    assert {p.stem for p in files} == expected, variant
    rows = [x for x in scores['perFile'] if x['engine'] == variant]
    assert {x['id'] for x in rows} == expected, variant
    for path in files:
        output = json.loads(path.read_text())
        assert output['processingSeconds'] > 0
        assert output['segments'], path
        for segment in output['segments']:
            assert 0 <= segment['start'] < segment['end'] <= output['duration'] + 10, (path, segment)
            assert math.isfinite(segment['start']) and math.isfinite(segment['end'])
    shutil.copytree(ROOT/'results'/variant, DEST/'predictions'/variant, dirs_exist_ok=True)

timings = []
for path in sorted((ROOT/'perf').iterdir()):
    runs = [json.loads(p.read_text()) for p in sorted(path.glob('*.json'))]
    assert len(runs) == 4, path
    warm = runs[1:]
    median = statistics.median(x['processingSeconds'] for x in warm)
    segment_hashes = [hashlib.sha256(json.dumps(r['segments'],sort_keys=True).encode()).hexdigest() for r in runs]
    timings.append({'engine':path.name,'audioSeconds':runs[0]['duration'],
        'warmSeconds':[x['processingSeconds'] for x in warm], 'medianSeconds':median,
        'medianRTFx':runs[0]['duration']/median,'loadSeconds':runs[0]['modelLoadSeconds'],
        'firstRunSeconds':runs[0]['processingSeconds'],'peakRSSBytes':max(x['peakRSSBytes'] for x in runs),
        'allFourPredictionsIdentical':len(set(segment_hashes))==1})
    shutil.copytree(path, DEST/'repeats'/path.name, dirs_exist_ok=True)
(DEST/'timings.json').write_text(json.dumps(timings,indent=2))

low = [json.loads(p.read_text()) for p in (ROOT/'results/low').glob('*.json')]
chunks = sorted(t for r in low for t in r['chunkSeconds'])
streaming = {'calls':len(chunks), 'medianSeconds':statistics.median(chunks),
    'p95Seconds':chunks[int(len(chunks)*.95)],'maxSeconds':max(chunks),
    'callsExceedingChunkDuration':sum(t>.72 for t in chunks),
    'bufferLatencySeconds':1.04,'audioChunkSeconds':.72}
(DEST/'streaming.json').write_text(json.dumps(streaming,indent=2))
for name in ['scores.json','manifest.json','downloads.json','baseline-models.json','environment.json',
             'run.log','controls.log','repeats.log','scoring.log']:
    shutil.copy(ROOT/name, DEST/name)
for meeting in sorted({x['meeting'] for x in manifest}):
    target=DEST/'references';target.mkdir(exist_ok=True)
    shutil.copy(ROOT/'references/AMI/test'/f'{meeting}.rttm',target)
print(json.dumps({'timings':timings,'streaming':streaming},indent=2))
print('Validated 56 full-recording predictions, saved evidence to', DEST)
