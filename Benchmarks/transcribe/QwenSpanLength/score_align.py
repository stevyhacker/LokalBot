"""Transcribe first, attribute after: scored against production's speaker regions.

Text comes from the engine path (`engine-15`) with Qwen3 forced-aligner word timings
(`qwen-span-harness align`). Each word takes the Nemotron speaker active at its midpoint,
or the nearest turn within a tolerance. Reports:
- AMI WER of the aligned words (alignment must not change the text);
- AMI cpWER against production regions (`diar-prod`) and a no-aligner baseline;
- speaker-memory support: diarizer turns that `AttributedTrackTranscriber.turns()` would
  accept (one diarized label covering >= 95% of the turn), with and without snapping.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from score_spans import DATA, OUT, load_runs, paired  # noqa: E402
from common import load_manifest  # noqa: E402  (CloudSTT)
from score import errors, summarize, words  # noqa: E402  (CloudSTT)
from score_regions import REGION, cp_errors  # noqa: E402
from make_region_jobs import recordings  # noqa: E402

TOLERANCE = 1.0  # AttributedTrackTranscriber.wordGapTolerance
PAUSE_SPLIT = 0.75  # AttributedTrackTranscriber.wordPauseSplit
MAX_SEGMENT = 15.0  # AttributedTrackTranscriber.maxSegmentSeconds


def clipped_turns(turns, lo, hi):
    return [(max(t['start'], lo) - lo, min(t['end'], hi) - lo, t['speaker'])
            for t in turns if min(t['end'], hi) > max(t['start'], lo)]


def speaker_at(turns, t, tolerance):
    active = {s for a, b, s in turns if a <= t < b}
    if len(active) == 1:
        return next(iter(active))
    if active:
        return 'unclear'
    if tolerance <= 0 or not turns:
        return 'none'
    gap, speaker = min((max(a - t, t - b), s) for a, b, s in turns)
    return speaker if gap <= tolerance else 'none'


def majority(turns, start, end):
    overlap = {}
    for a, b, s in turns:
        o = min(b, end) - max(a, start)
        if o > 0:
            overlap[s] = overlap.get(s, 0) + o
    return max(overlap, key=overlap.get) if overlap else 'none'


def word_pieces(windows, aligned_windows, turns, snap):
    """Mirror of AttributedTrackTranscriber.attribute's piece timing (labels and bounds):
    a new piece at a speaker change, a pause of PAUSE_SPLIT, or past MAX_SEGMENT."""
    out = []
    for win, words_ in zip(windows, aligned_windows):
        local = []
        for _, s, e in words_:
            s, e = float(s), float(e)
            label = speaker_at(turns, (s + e) / 2, TOLERANCE)
            if local and local[-1][2] == label and s - local[-1][1] < PAUSE_SPLIT and e - local[-1][0] <= MAX_SEGMENT:
                local[-1][1] = e
            else:
                local.append([s, e, label])
        for p in local:
            p[0], p[1] = min(max(p[0], win['start']), win['end']), min(max(p[1], win['start']), win['end'])
        out += local
    out.sort(key=lambda p: p[0])
    if snap:
        for k, p in enumerate(out):
            if p[2] in ('none', 'unclear'):
                continue
            floor = out[k - 1][1] if k else float('-inf')
            ceiling = out[k + 1][0] if k + 1 < len(out) else float('inf')
            start, end = p[0], p[1]
            for a, b, spk in turns:
                if spk == p[2] and a < end and b > start:
                    start, end = max(floor, min(start, a)), min(ceiling, max(end, b))
            if end > start:
                p[0], p[1] = start, end
    return out


def supported(turns, segments):
    """Turns `AttributedTrackTranscriber.turns()` accepts, out of those without overlap."""
    accepted = eligible = 0
    for a, b, spk in turns:
        if any(s2 != spk and a2 < b and b2 > a for a2, b2, s2 in turns):
            continue
        eligible += 1
        overlapping = sorted((max(s, a), min(e, b)) for s, e, lab in segments if s < b and e > a)
        labels = {lab for s, e, lab in segments if s < b and e > a}
        covered, cur = 0.0, None
        for s, e in overlapping:
            if cur and s <= cur[1]:
                cur[1] = max(cur[1], e)
            else:
                covered += (cur[1] - cur[0]) if cur else 0
                cur = [s, e]
        covered += (cur[1] - cur[0]) if cur else 0
        if len(labels) == 1 and next(iter(labels)) not in ('none', 'unclear') and covered >= 0.95 * (b - a):
            accepted += 1
    return accepted, eligible


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for align-summary.json (aggregates only)')
    args = parser.parse_args()
    runs = load_runs()
    labels = json.loads((OUT / 'region_labels.json').read_text())
    turns_by_file = json.loads((OUT / 'turns.json').read_text())
    aligned = {json.loads(l)['id']: json.loads(l) for l in (OUT / 'aligned-engine15.jsonl').read_text().splitlines()}
    manifest = load_manifest()
    recording = recordings(manifest)
    ami = [r for r in manifest if r['set'] == 'ami']
    ids = [r['id'] for r in ami]
    turns = {r['id']: clipped_turns(turns_by_file[recording(r)], r['start'], r['end']) for r in manifest}

    ref_streams = {}
    for row in ami:
        utts = json.loads((DATA / 'source' / 'ami' / f'{row["source"]}.utterances.json').read_text())
        inside = [u for u in utts if row['start'] - 0.01 <= u['begin'] and u['end'] <= row['end'] + 0.01]
        streams = {}
        for u in sorted(inside, key=lambda u: (u['begin'], u['end'])):
            streams.setdefault(u['speaker'], []).append(u['text'])
        ref_streams[row['id']] = {s: words(' '.join(t)) for s, t in streams.items()}

    def cp_record(i, streams):
        return {'sub': cp_errors(ref_streams[i], {k: words(' '.join(v)) for k, v in streams.items()}),
                'del': 0, 'ins': 0, 'ins_run_words': 0, 'del_run_words': 0,
                'ref_words': sum(len(v) for v in ref_streams[i].values())}

    def region_segments(i):
        out = []
        for w in runs[('diar-prod', i)]['windows']:
            if w['text']:
                mid = (w['start'] + w['end']) / 2
                out.append((w['start'], w['end'],
                            next((lab for s, e, lab in labels[REGION['diar-prod']][i] if s <= mid <= e), 'none'),
                            w['text']))
        return out

    def text_windows(i):
        return [w for w in runs[('engine-15', i)]['windows'] if w['text']]

    cp = {'production regions': {}, 'engine windows, majority speaker': {}}
    for i in ids:
        streams = {}
        for s, e, lab, text in region_segments(i):
            streams.setdefault(lab, []).append(text)
        cp['production regions'][i] = cp_record(i, streams)
        streams = {}
        for w in text_windows(i):
            streams.setdefault(majority(turns[i], w['start'], w['end']), []).append(w['text'])
        cp['engine windows, majority speaker'][i] = cp_record(i, streams)
    for tol in [0, 0.5, 1.0, 2.0, float('inf')]:
        name = f'aligned words, gap tolerance {tol:g} s'
        cp[name] = {}
        for i in ids:
            streams = {}
            for window in aligned[i]['windows']:
                for surface, start, end in window:
                    streams.setdefault(speaker_at(turns[i], (float(start) + float(end)) / 2, tol), []).append(surface)
            cp[name][i] = cp_record(i, streams)

    refs = {r['id']: words(r['reference']) for r in ami}
    wer = {'engine-15': summarize([errors(refs[i], words(runs[('engine-15', i)]['text'])) for i in ids])['wer'],
           'aligned words': summarize([errors(refs[i], words(' '.join(s for w in aligned[i]['windows'] for s, _, _ in w)))
                                       for i in ids])['wer']}
    print(f'AMI WER: engine-15 text {wer["engine-15"]:.2%}, aligned words {wer["aligned words"]:.2%}')
    summary = {'ami_wer': {k: round(v, 5) for k, v in wer.items()}, 'ami_cpwer': {}, 'speaker_memory_support': {}}
    base = 'production regions'
    print('\n| Attribution | AMI cpWER | Δ vs production regions (95% CI) | P(better) |')
    print('|---|---:|---:|---:|')
    for name in cp:
        t = summarize(list(cp[name].values()))['wer']
        d, lo, hi, p = (0, 0, 0, None) if name == base else paired(cp, name, base, ids)
        print(f'| {name} | {t:.2%} | ' + ('— | — |' if name == base else f'{d:+.2%} ({lo:+.2%}…{hi:+.2%}) | {p:.2f} |'))
        summary['ami_cpwer'][name] = {'cpwer': round(t, 5), 'delta': round(d, 5), 'ci95': [round(lo, 5), round(hi, 5)],
                                      'p_better': p}

    print('\n| Speaker-memory support | AMI | Meetings |')
    print('|---|---:|---:|')
    rows = {}
    for subset in ['ami', 'meetings']:
        chunk_ids = [r['id'] for r in manifest if r['set'] == subset]
        for name, build in [('production regions', lambda i: [(s, e, lab) for s, e, lab, _ in region_segments(i)]),
                            ('aligned words', lambda i: word_pieces(text_windows(i), aligned[i]['windows'], turns[i], False)),
                            ('aligned words, snapped to turns (as shipped)',
                             lambda i: word_pieces(text_windows(i), aligned[i]['windows'], turns[i], True))]:
            ok = el = 0
            for i in chunk_ids:
                a, e = supported(turns[i], build(i))
                ok, el = ok + a, el + e
            rows.setdefault(name, {})[subset] = (ok, el)
    for name, by in rows.items():
        print(f'| {name} | {by["ami"][0]}/{by["ami"][1]} | {by["meetings"][0]}/{by["meetings"][1]} |')
        summary['speaker_memory_support'][name] = {k: {'accepted': v[0], 'eligible': v[1]} for k, v in by.items()}

    seconds = sum(a['seconds'] for a in aligned.values())
    audio = sum(r['duration'] for r in manifest)
    print(f'\naligner: {seconds:.1f}s for {audio / 60:.0f} min of audio ({audio / seconds:.0f}x real time)')
    summary['aligner_speed_x_realtime'] = round(audio / seconds)
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'align-summary.json').write_text(json.dumps(summary, indent=1))


if __name__ == '__main__':
    main()
