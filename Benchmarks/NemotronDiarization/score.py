"""Score complete recordings with pyannote.metrics, overlap included."""
import json
import pathlib
import sys
from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/private/tmp/lokalbot-nemotron-bench')

def annotation(segments, uri):
    result = Annotation(uri=uri)
    for i, (start, end, speaker) in enumerate(segments):
        if end > start:
            result[Segment(start, end), i] = speaker
    return result

def reference(path, uri):
    rows = []
    for line in pathlib.Path(path).read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == 'SPEAKER':
            rows.append((float(fields[3]), float(fields[3]) + float(fields[4]), fields[7]))
    return annotation(rows, uri)

# Sanity-check the scorer: arbitrary speaker IDs must not change DER,
# and simultaneous speech must remain represented.
ref = annotation([(0, 2, 'a'), (1, 3, 'b')], 'sanity')
hyp = annotation([(0, 2, 'z'), (1, 3, 'y')], 'sanity')
sanity_uem = Timeline([Segment(0, 3)])
assert DiarizationErrorRate(collar=0, skip_overlap=False)(ref, hyp, uem=sanity_uem) == 0
assert DiarizationErrorRate(collar=0, skip_overlap=False)(ref, Annotation(uri='sanity'), uem=sanity_uem) == 1

manifest = {x['id']: x for x in json.loads((ROOT / 'manifest.json').read_text())}
all_results = []
aggregates = []
for directory in sorted((ROOT / 'results').iterdir()):
    if not directory.is_dir():
        continue
    metrics = {(condition, collar): DiarizationErrorRate(collar=collar, skip_overlap=False)
        for condition in ['all', 'mhm', 'sdm'] for collar in [0, 0.25]}
    rows = []
    for path in sorted(directory.glob('*.json')):
        output = json.loads(path.read_text())
        item = manifest[output['id']]
        ref = reference(item['reference'], item['id'])
        hyp = annotation([(x['start'], x['end'], x['speaker']) for x in output['segments']], item['id'])
        uem = Timeline([Segment(0, output['duration'])])
        row = {k: v for k, v in output.items() if k not in ['segments', 'chunkSeconds']}
        row.update(engine=directory.name, condition=item['condition'], referenceSpeakers=len(ref.labels()),
            predictedSpeakers=len(hyp.labels()), rtfx=output['duration'] / output['processingSeconds'])
        for collar in [0, 0.25]:
            metric = metrics['all', collar]
            details = metric(ref, hyp, uem=uem, detailed=True)
            # Each component is additive; avoid scoring the same recording twice.
            condition_metric = metrics[item['condition'], collar]
            for key in condition_metric.accumulated_:
                condition_metric.accumulated_[key] += details[key]
            row['score_' + str(collar)] = details
        chunks = sorted(output['chunkSeconds'])
        if chunks:
            row['chunkMedianSeconds'] = chunks[len(chunks) // 2]
            row['chunkP95Seconds'] = chunks[min(len(chunks)-1, int(len(chunks)*.95))]
            row['chunkMaxSeconds'] = max(chunks)
            row['chunkCount'] = len(chunks)
        rows.append(row)
        print(f"Scored {directory.name}/{output['id']}: {row['score_0']['diarization error rate']*100:.2f}%", flush=True)
    all_results.extend(rows)
    for condition in ['all', 'mhm', 'sdm']:
        group = [r for r in rows if condition == 'all' or r['condition'] == condition]
        if not group:
            continue
        total_duration = sum(r['duration'] for r in group)
        total_time = sum(r['processingSeconds'] for r in group)
        aggregates.append({'engine': directory.name, 'condition': condition, 'files': len(group),
            'audioSeconds': total_duration, 'processingSeconds': total_time, 'rtfx': total_duration/total_time,
            'peakRSSBytes': max(r['peakRSSBytes'] for r in group),
            'correctSpeakerCounts': sum(r['referenceSpeakers'] == r['predictedSpeakers'] for r in group),
            'der0': abs(metrics[condition, 0]) * 100,
            'der250': abs(metrics[condition, .25]) * 100,
            'components0': dict(metrics[condition, 0].accumulated_)})
summary = {'perFile': all_results, 'aggregate': aggregates}
(ROOT / 'scores.json').write_text(json.dumps(summary, indent=2))
for row in aggregates:
    print(f"{row['engine']:24s} {row['condition']:4s} n={row['files']} DER0={row['der0']:.2f}% DER250={row['der250']:.2f}% RTFx={row['rtfx']:.1f} RSS={row['peakRSSBytes']/2**30:.2f}GiB count={row['correctSpeakerCounts']}/{row['files']}")
