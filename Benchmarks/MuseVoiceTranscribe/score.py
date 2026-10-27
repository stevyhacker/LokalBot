"""Build speaker segments from raw Muse Voice Transcribe events and score them like the Nemotron study."""
import argparse
import datetime
import importlib.metadata
import json
import os
import pathlib
import platform
import statistics
import wave

from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate

HERE = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(os.environ.get('MUSE_BENCH_DATA', '/private/tmp/lokalbot-muse-voice-bench'))
STUDY = HERE.parent / 'NemotronDiarization/results/2026-09-23'
NAME = 'muse-voice-transcribe'
# Re-scored here from the study's checked-in predictions, so every row uses this scorer.
LOCAL = {'baseline': 'LokalBot before Nemotron (FluidAudio 0.15.8)',
         'offline': 'Nemotron 3 offline, local (LokalBot default)',
         'low': 'Nemotron 3 low, local streaming API'}


def turns(events):
    """Group events by turn. Speaker events carry no turnId, so they belong to the latest started turn."""
    found, latest = {}, None
    for event in events:
        kind = event.get('type')
        if kind == 'speechStart':
            latest = event['turnId']
            found[latest] = {'turnId': latest, 'start': event['audioProcessedMs'] / 1000, 'speakers': []}
        elif kind == 'speaker' and latest is not None:
            found[latest]['speakers'].append((event['audioProcessedMs'] / 1000, event['label'], event['wallSeconds']))
        elif kind == 'speechEnd' and event.get('turnId') in found:
            found[event['turnId']]['end'] = event['audioProcessedMs'] / 1000
        elif kind == 'speechComplete' and event.get('turnId') in found:
            turn = found[event['turnId']]
            turn['completeWallSeconds'] = event['wallSeconds']
            turn.setdefault('end', event['audioProcessedMs'] / 1000)
    return [t for t in found.values() if 'end' in t]


def segments(turn_list):
    """A speaker event labels the audio since the previous speechStart or speaker event; the rest of
    the turn keeps the last label. A turn without one gets its own label, so unattributed turns
    cannot be mapped to a reference speaker together."""
    rows = []
    for turn in turn_list:
        cursor, label = turn['start'], None
        for at, label, _ in turn['speakers']:
            end = min(max(at, cursor), turn['end'])
            if end > cursor:
                rows.append((cursor, end, label))
            cursor = end
        if turn['end'] > cursor:
            rows.append((cursor, turn['end'], label or f"unknown-{turn['turnId']}"))
    return rows


def annotation(rows, uri):
    result = Annotation(uri=uri)
    for i, (start, end, speaker) in enumerate(rows):
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


def evaluate(engine, predictions, manifest, oracle_speech=False):
    """Pooled DER with overlap scored, accumulated per condition exactly as the Nemotron study does.
    With oracle_speech, every system's output is first cut to the reference's speech regions, so
    false alarms vanish and the score isolates who was labelled, plus speech left unlabelled."""
    metrics = {(condition, collar): DiarizationErrorRate(collar=collar, skip_overlap=False)
               for condition in ['all', 'mhm', 'sdm'] for collar in [0, 0.25]}
    per_file = []
    for output in predictions:
        item = manifest[output['id']]
        ref = reference(item['reference'], output['id'])
        hyp = annotation([(x['start'], x['end'], x['speaker']) for x in output['segments']], output['id'])
        if oracle_speech:
            hyp = hyp.crop(ref.get_timeline().support(), mode='intersection')
        uem = Timeline([Segment(0, output['duration'])])
        row = {'engine': engine, 'id': output['id'], 'condition': item['condition'],
               'referenceSpeakers': len(ref.labels()),
               'predictedSpeakers': len([x for x in hyp.labels() if not str(x).startswith('unknown-')])}
        for collar in [0, 0.25]:
            details = metrics['all', collar](ref, hyp, uem=uem, detailed=True)
            condition_metric = metrics[item['condition'], collar]
            for key in condition_metric.accumulated_:
                condition_metric.accumulated_[key] += details[key]
            row['der' + str(int(collar * 1000))] = details['diarization error rate'] * 100
        per_file.append(row)
    aggregate = []
    for condition in ['all', 'mhm', 'sdm']:
        group = [r for r in per_file if condition == 'all' or r['condition'] == condition]
        if group:
            aggregate.append({'engine': engine, 'condition': condition, 'files': len(group),
                              'correctSpeakerCounts': sum(r['referenceSpeakers'] == r['predictedSpeakers'] for r in group),
                              'der0': abs(metrics[condition, 0]) * 100, 'der250': abs(metrics[condition, .25]) * 100,
                              'components0': dict(metrics[condition, 0].accumulated_)})
    return {'engine': engine, 'perFile': per_file, 'aggregate': aggregate}


def wave_seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def spread(values):
    values = sorted(values)
    if not values:
        return None
    return {'count': len(values), 'median': statistics.median(values),
            'p95': values[min(len(values) - 1, int(len(values) * .95))], 'max': values[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', default='raw', help='folder of run.py records under the data root; raw-smoke after --smoke')
    parser.add_argument('--save', type=pathlib.Path, help='copy segments and aggregates, without transcripts, here')
    args = parser.parse_args()
    manifest = {x['id']: x for x in json.loads((ROOT / 'manifest.json').read_text())}
    records = [json.loads(p.read_text()) for p in sorted((ROOT / args.raw).glob('*.json'))]
    incomplete = [r['id'] for r in records if not r.get('completed')]
    if not records or incomplete:
        raise SystemExit(f'Nothing to score, or incomplete sessions to rerun with run.py: {incomplete}')

    predictions, final_delay, label_delay, sessions = [], [], [], []
    for record in records:
        found = turns(record['events'])
        rows = segments(found)
        predictions.append({'id': record['id'], 'duration': record['duration'], 'turns': len(found),
                            'unattributedTurns': sum(not t['speakers'] for t in found),
                            'segments': [{'start': s, 'end': e, 'speaker': label} for s, e, label in rows]})
        sessions.append({k: record.get(k) for k in ['id', 'sessionId', 'duration', 'endStreamSeconds',
                                                    'endedBy', 'closeCode', 'closeReason', 'speed']})
        if record['speed'] == 1:
            # Audio at position t left the client t seconds after the first frame, so these are
            # client-side delays after the person stopped talking, network included.
            final_delay += [t['completeWallSeconds'] - t['end'] for t in found if 'completeWallSeconds' in t]
            label_delay += [t['speakers'][0][2] - t['end'] for t in found if t['speakers']]

    ids = {p['id'] for p in predictions}
    # Local rows only make sense beside whole recordings, not --smoke prefixes.
    whole = all(abs(r['duration'] - wave_seconds(manifest[r['id']]['audio'])) < 0.01 for r in records)
    published = {x['engine']: x for x in json.loads((STUDY / 'scores.json').read_text())['aggregate']
                 if x['condition'] == 'all'}
    local = {engine: [r for r in (json.loads(p.read_text()) for p in sorted((STUDY / 'predictions' / engine).glob('*.json')))
                      if r['id'] in ids] for engine in LOCAL}
    views = {}
    for view, oracle in [('full', False), ('oracleSpeech', True)]:
        views[view] = [evaluate(NAME, predictions, manifest, oracle)]
        for engine, rows in local.items():
            result = evaluate(engine, rows, manifest, oracle)
            if view == 'full' and whole and ids == set(manifest):
                ours = next(a for a in result['aggregate'] if a['condition'] == 'all')
                assert abs(ours['der0'] - published[engine]['der0']) < 0.005, (engine, ours['der0'], published[engine]['der0'])
            if whole:
                views[view].append(result)

    lengths = [t['end'] - t['start'] for r in records for t in turns(r['events'])]
    summary = {'scored': datetime.date.today().isoformat(), 'raw': args.raw, 'recordings': sorted(ids),
               'labels': dict(LOCAL, **{NAME: 'Muse Voice Transcribe 1.0, realtime DIARIZATION (cloud)'}),
               'views': views, 'sessions': sessions, 'turnSeconds': spread(lengths),
               'turns': {p['id']: {'turns': p['turns'], 'unattributedTurns': p['unattributedTurns']} for p in predictions},
               'latencySeconds': {'finalTextAfterSpeechEnd': spread(final_delay),
                                  'speakerLabelAfterSpeechEnd': spread(label_delay)},
               'versions': {name: importlib.metadata.version(name) for name in ['pyannote.metrics', 'websockets']},
               'environment': {'python': platform.python_version(), 'platform': platform.platform()}}
    (ROOT / f'scores-{args.raw}.json').write_text(json.dumps(summary, indent=2))
    for view, results in views.items():
        print(f'== {view}')
        for result in results:
            for row in result['aggregate']:
                c = row['components0']
                print(f"{row['engine']:22s} {row['condition']:4s} n={row['files']} DER0={row['der0']:6.2f}% "
                      f"DER250={row['der250']:6.2f}% miss={100 * c['missed detection'] / c['total']:5.2f} "
                      f"fa={100 * c['false alarm'] / c['total']:6.2f} conf={100 * c['confusion'] / c['total']:5.2f} "
                      f"speakers={row['correctSpeakerCounts']}/{row['files']}")
    if summary['turnSeconds']:
        print(f"turn length: median {summary['turnSeconds']['median']:.1f} s, p95 {summary['turnSeconds']['p95']:.1f} s, max {summary['turnSeconds']['max']:.1f} s")
    for name, value in summary['latencySeconds'].items():
        if value:
            print(f"{name}: median {value['median']:.2f} s, p95 {value['p95']:.2f} s, max {value['max']:.2f} s, n={value['count']}")
    if args.save:
        args.save.mkdir(parents=True, exist_ok=True)
        (args.save / 'scores.json').write_text(json.dumps(summary, indent=2))
        folder = args.save / 'predictions' / NAME
        folder.mkdir(parents=True, exist_ok=True)
        for prediction in predictions:
            (folder / f"{prediction['id']}.json").write_text(json.dumps(prediction, indent=1))
        repository = HERE.parent.parent
        portable = [dict(x, audio=pathlib.Path(x['audio']).name,
                         reference=str(pathlib.Path(x['reference']).relative_to(repository))) for x in manifest.values()]
        (args.save / 'manifest.json').write_text(json.dumps(portable, indent=2))
        print('Saved segments and aggregates to', args.save)


if __name__ == '__main__':
    main()
