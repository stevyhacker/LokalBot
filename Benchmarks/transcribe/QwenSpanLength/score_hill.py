"""Hill-climb the word-attribution path: decode-window layout and aligner variant.

Every candidate keeps word-level attribution (1 s tolerance) and is compared with the
first row, the path shipped first (<=14 s windows, 4-bit aligner), by paired chunk
bootstrap. Needs runs.jsonl conditions and the matching aligned-*.jsonl files
(`make_region_jobs.py align-job <condition>` then `qwen-span-harness align`).
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from score_spans import DATA, OUT, REPORT_SYSTEMS, load_runs, paired  # noqa: E402
from common import SYSTEMS, load_manifest, load_output  # noqa: E402  (CloudSTT)
from score import consensus, errors, family_weights, summarize, words  # noqa: E402  (CloudSTT)
from score_regions import cp_errors  # noqa: E402
from score_align import TOLERANCE, clipped_turns, speaker_at, supported, word_pieces  # noqa: E402
from make_region_jobs import recordings  # noqa: E402

CANDIDATES = [  # label, text condition, aligned file
    ('≤14 s windows, 4-bit aligner (first shipped)', 'engine-15', 'aligned-engine15.jsonl'),
    ('≤14 s windows, 8-bit aligner', 'engine-15', 'aligned8-engine-15.jsonl'),
    ('merge ≤15 s', 'merge-15', 'aligned-merge-15.jsonl'),
    ('merge ≤30 s, blocking off', 'merge-30-off', 'aligned-merge-30-off.jsonl'),
    ('merge ≤60 s, blocking off', 'merge-60-off', 'aligned-merge-60-off.jsonl'),
    ('merge ≤60 s from 14 s VAD, blocking off (shipped)', 'merge-60-off-v14', 'aligned-merge-60-off-v14.jsonl'),
    ('whole chunk, blocking off', 'whole-en-off', 'aligned-whole-en-off.jsonl'),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for hill-summary.json (aggregates only)')
    args = parser.parse_args()
    runs = load_runs()
    manifest = load_manifest()
    recording = recordings(manifest)
    turns_by_file = json.loads((OUT / 'turns.json').read_text())
    turns = {r['id']: clipped_turns(turns_by_file[recording(r)], r['start'], r['end']) for r in manifest}
    ami = [r for r in manifest if r['set'] == 'ami']
    ami_ids = [r['id'] for r in ami]
    meetings = [r for r in manifest if r['set'] == 'meetings'
                and all((load_output(s, r['id']) or {}).get('text') is not None for s in REPORT_SYSTEMS)]
    meet_ids = [r['id'] for r in meetings]
    voters = [v for v in REPORT_SYSTEMS if SYSTEMS[v][0] != 'qwen' and SYSTEMS[v][1] != 'production']
    meet_refs = {i: consensus({v: words(load_output(v, i)['text']) for v in voters}, family_weights(voters))
                 for i in meet_ids}
    ami_refs = {r['id']: words(r['reference']) for r in ami}
    ref_streams = {}
    for row in ami:
        utts = json.loads((DATA / 'source' / 'ami' / f'{row["source"]}.utterances.json').read_text())
        inside = [u for u in utts if row['start'] - 0.01 <= u['begin'] and u['end'] <= row['end'] + 0.01]
        streams = {}
        for u in sorted(inside, key=lambda u: (u['begin'], u['end'])):
            streams.setdefault(u['speaker'], []).append(u['text'])
        ref_streams[row['id']] = {s: words(' '.join(t)) for s, t in streams.items()}

    meet, amiw, cp, extra = {}, {}, {}, {}
    for label, cond, path in CANDIDATES:
        if not (OUT / path).exists() or not all((cond, r['id']) in runs for r in manifest):
            print(f'skip {label}: missing {path} or {cond} runs')
            continue
        aligned = {json.loads(l)['id']: json.loads(l) for l in (OUT / path).read_text().splitlines()}
        meet[label] = {i: errors(meet_refs[i], words(runs[(cond, i)]['text'])) for i in meet_ids}
        amiw[label] = {i: errors(ami_refs[i], words(runs[(cond, i)]['text'])) for i in ami_ids}
        cp[label] = {}
        for i in ami_ids:
            streams = {}
            for window in aligned[i]['windows']:
                for surface, s, e in window:
                    streams.setdefault(speaker_at(turns[i], (float(s) + float(e)) / 2, TOLERANCE), []).append(surface)
            cp[label][i] = {'sub': cp_errors(ref_streams[i], {k: words(' '.join(v)) for k, v in streams.items()}),
                            'del': 0, 'ins': 0, 'ins_run_words': 0, 'del_run_words': 0,
                            'ref_words': sum(len(v) for v in ref_streams[i].values())}
        support = {'ami': [0, 0], 'meetings': [0, 0]}
        for r in manifest:
            windows = [w for w in runs[(cond, r['id'])]['windows'] if w['text']]
            a, e = supported(turns[r['id']], word_pieces(windows, aligned[r['id']]['windows'], turns[r['id']], True))
            support[r['set']][0] += a
            support[r['set']][1] += e
        extra[label] = {'support': support,
                        'aligner_x': sum(r['duration'] for r in manifest) / sum(x['seconds'] for x in aligned.values())}

    base = CANDIDATES[0][0]

    def delta(per, label, ids):
        return None if label == base else [round(100 * x, 2) for x in paired(per, label, base, ids)[:3]]

    summary = {}
    print('| Candidate | Meetings | Δ (95% CI) | AMI WER | Δ (95% CI) | AMI cpWER | Δ (95% CI) | Speaker memory AMI, meetings | Aligner speed |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for label in meet:
        row = {'meetings': summarize(list(meet[label].values()))['wer'], 'meetings_delta': delta(meet, label, meet_ids),
               'ami_wer': summarize(list(amiw[label].values()))['wer'], 'ami_wer_delta': delta(amiw, label, ami_ids),
               'ami_cpwer': summarize(list(cp[label].values()))['wer'], 'ami_cpwer_delta': delta(cp, label, ami_ids),
               **extra[label]}
        summary[label] = row
        show = lambda d: '—' if d is None else '{:+.2f} ({:+.2f}…{:+.2f})'.format(*d)
        s = row['support']
        print(f'| {label} | {row["meetings"]:.2%} | {show(row["meetings_delta"])} | {row["ami_wer"]:.2%} | '
              f'{show(row["ami_wer_delta"])} | {row["ami_cpwer"]:.2%} | {show(row["ami_cpwer_delta"])} | '
              f'{s["ami"][0]}/{s["ami"][1]}, {s["meetings"][0]}/{s["meetings"][1]} | {row["aligner_x"]:.0f}× |')
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'hill-summary.json').write_text(json.dumps(summary, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
