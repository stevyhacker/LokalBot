"""Hill-climb Qwen3-ASR 0.6B (compact tier) on the word-attribution path.

Compares each candidate with 0.6B production regions (`diar-prod` in runs-06b.jsonl) by paired
chunk bootstrap, and counts degeneration: words in invented runs and windows that reach the
token cap. The shipped 1.7B path is a reference row. Inputs come from `make_region_jobs.py
compact-job` and `align-job` with RUNS_FILE=runs-06b.jsonl ALIGNED_PREFIX=aligned06.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from score_spans import DATA, MODEL_DIR, OUT, REPORT_SYSTEMS, paired  # noqa: E402
from common import SYSTEMS, load_manifest, load_output  # noqa: E402
from score import consensus, errors, family_weights, summarize, words  # noqa: E402
from score_regions import REGION, cp_errors  # noqa: E402
from score_align import TOLERANCE, clipped_turns, speaker_at, supported, word_pieces  # noqa: E402
from make_region_jobs import recordings  # noqa: E402


def load(path):
    out = {}
    for line in (OUT / path).read_text().splitlines():
        r = json.loads(line)
        out[(r['condition'], r['id'])] = r
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for compact-summary.json (aggregates only)')
    args = parser.parse_args()
    runs06, runs17 = load('runs-06b.jsonl'), load('runs.jsonl')
    candidates = [  # label, runs, condition, aligned file (None = production regions)
        ('0.6B production regions (today)', runs06, 'diar-prod', None),
        ('0.6B words, ≤14 s windows', runs06, 'engine-15', 'aligned06-engine-15.jsonl'),
        ('0.6B words, merged ≤15 s', runs06, 'merge-15-v14', 'aligned06-merge-15-v14.jsonl'),
        ('0.6B words, merged ≤30 s, blocking off', runs06, 'merge-30-off-v14', 'aligned06-merge-30-off-v14.jsonl'),
        ('0.6B words, merged ≤60 s, blocking off', runs06, 'merge-60-off-v14', 'aligned06-merge-60-off-v14.jsonl'),
        ('0.6B words, merged ≤60 s, blocking on', runs06, 'merge-60-v14', 'aligned06-merge-60-v14.jsonl'),
        ('1.7B shipped (reference)', runs17, 'merge-60-off-v14', 'aligned-merge-60-off-v14.jsonl'),
    ]
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(str(MODEL_DIR))
    manifest = load_manifest()
    recording = recordings(manifest)
    labels = json.loads((OUT / 'region_labels.json').read_text())
    turns_by_file = json.loads((OUT / 'turns.json').read_text())
    turns = {r['id']: clipped_turns(turns_by_file[recording(r)], r['start'], r['end']) for r in manifest}
    ami = [r for r in manifest if r['set'] == 'ami']
    ami_ids = [r['id'] for r in ami]
    meet_ids = [r['id'] for r in manifest if r['set'] == 'meetings'
                and all((load_output(s, r['id']) or {}).get('text') is not None for s in REPORT_SYSTEMS)]
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

    def cp_record(i, streams):
        return {'sub': cp_errors(ref_streams[i], {k: words(' '.join(v)) for k, v in streams.items()}),
                'del': 0, 'ins': 0, 'ins_run_words': 0, 'del_run_words': 0,
                'ref_words': sum(len(v) for v in ref_streams[i].values())}

    meet, amiw, cp, extra = {}, {}, {}, {}
    for label, runs, cond, path in candidates:
        if not all((cond, r['id']) in runs for r in manifest) or (path and not (OUT / path).exists()):
            print(f'skip {label}')
            continue
        meet[label] = {i: errors(meet_refs[i], words(runs[(cond, i)]['text'])) for i in meet_ids}
        amiw[label] = {i: errors(ami_refs[i], words(runs[(cond, i)]['text'])) for i in ami_ids}
        support = {'ami': [0, 0], 'meetings': [0, 0]}
        cp[label] = {}
        if path is None:
            def region_segs(i):
                out = []
                for w in runs[(cond, i)]['windows']:
                    if w['text']:
                        mid = (w['start'] + w['end']) / 2
                        out.append((w['start'], w['end'], next((l for s, e, l in labels[REGION[cond]][i]
                                                                if s <= mid <= e), 'none'), w['text']))
                return out
            for i in ami_ids:
                streams = {}
                for s, e, lab, text in region_segs(i):
                    streams.setdefault(lab, []).append(text)
                cp[label][i] = cp_record(i, streams)
            for r in manifest:
                a, e = supported(turns[r['id']], [(s, e2, lab) for s, e2, lab, _ in region_segs(r['id'])])
                support[r['set']][0] += a
                support[r['set']][1] += e
        else:
            aligned = {json.loads(l)['id']: json.loads(l) for l in (OUT / path).read_text().splitlines()}
            for i in ami_ids:
                streams = {}
                for window in aligned[i]['windows']:
                    for surface, s, e in window:
                        streams.setdefault(speaker_at(turns[i], (float(s) + float(e)) / 2, TOLERANCE), []).append(surface)
                cp[label][i] = cp_record(i, streams)
            for r in manifest:
                wins = [w for w in runs[(cond, r['id'])]['windows'] if w['text']]
                a, e = supported(turns[r['id']], word_pieces(wins, aligned[r['id']]['windows'], turns[r['id']], True))
                support[r['set']][0] += a
                support[r['set']][1] += e
        hits = sum(len(tok.encode(w['text'], add_special_tokens=False)) + 1 >= w['cap']
                   for r in manifest for w in runs[(cond, r['id'])]['windows'])
        invented = sum(meet[label][i]['ins_run_words'] for i in meet_ids) + sum(amiw[label][i]['ins_run_words'] for i in ami_ids)
        audio = sum(runs[(cond, r['id'])]['audioSeconds'] for r in manifest)
        decode = sum(runs[(cond, r['id'])]['decodeSeconds'] for r in manifest)
        extra[label] = {'support': support, 'cap_hits': hits, 'invented': invented, 'speed': audio / decode}

    base = candidates[0][0]
    show = lambda per, lab, ids: '—' if lab == base else '{:+.2f} ({:+.2f}…{:+.2f})'.format(
        *[100 * x for x in paired(per, lab, base, ids)[:3]])
    summary = {}
    print('| Candidate | Meetings | Δ vs today | AMI WER | Δ | AMI cpWER | Δ | Speaker memory AMI, meetings | Invented-run words | Cap hits | ASR speed |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for label in meet:
        x = extra[label]
        print(f'| {label} | {summarize(list(meet[label].values()))["wer"]:.2%} | {show(meet, label, meet_ids)} | '
              f'{summarize(list(amiw[label].values()))["wer"]:.2%} | {show(amiw, label, ami_ids)} | '
              f'{summarize(list(cp[label].values()))["wer"]:.2%} | {show(cp, label, ami_ids)} | '
              f'{x["support"]["ami"][0]}/{x["support"]["ami"][1]}, {x["support"]["meetings"][0]}/{x["support"]["meetings"][1]} | '
              f'{x["invented"]} | {x["cap_hits"]} | {x["speed"]:.0f}× |')
        summary[label] = {
            'meetings': round(summarize(list(meet[label].values()))['wer'], 5),
            'ami_wer': round(summarize(list(amiw[label].values()))['wer'], 5),
            'ami_cpwer': round(summarize(list(cp[label].values()))['wer'], 5),
            **{k: (None if label == base else [round(100 * v, 2) for v in paired(per, label, base, ids)[:3]])
               for k, per, ids in [('meetings_delta', meet, meet_ids), ('ami_wer_delta', amiw, ami_ids),
                                   ('ami_cpwer_delta', cp, ami_ids)]},
            'support': x['support'], 'invented_run_words': x['invented'], 'cap_hits': x['cap_hits'],
            'asr_speed_x_realtime': round(x['speed'], 1)}
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'compact-summary.json').write_text(json.dumps(summary, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
