"""Score the speaker-region variants: WER on AMI and meetings, cpWER on AMI.

cpWER (concatenated minimum-permutation WER): each hypothesis speaker's words are
concatenated in time order and matched one-to-one to a reference speaker so total
errors are minimal; unmatched streams count as insertions/deletions. Words placed in an
unlabeled or overlap region form their own stream. Matching is per AMI window.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from score_spans import DATA, OUT, REPORT_SYSTEMS, load_runs, paired, speed, window_stats  # noqa: E402
from common import SYSTEMS, load_manifest, load_output  # noqa: E402
from score import consensus, errors, family_weights, summarize, words  # noqa: E402  (CloudSTT)
from make_region_jobs import labeled, stride  # noqa: E402

REGION = {'diar-prod': 'prod', 'diar-trackvad': 'prod', 'diar-nostride': 'nostride', 'diar-absorb': 'absorb',
          'diar-combined': 'combined', 'diar-combined-60off': 'combined', 'oracle-regions': 'oracle'}
BASELINE = 'diar-prod'


def err(c):
    return c['sub'] + c['del'] + c['ins']


def cp_errors(refs, hyps):
    """Minimum total errors over one-to-one speaker assignments (dummy rows/cols = unmatched)."""
    r, h = list(refs), list(hyps)
    n = len(r) + len(h)
    cost = np.zeros((n, n))
    for i, hs in enumerate(h):
        for j, rs in enumerate(r):
            cost[i, j] = err(errors(refs[rs], hyps[hs]))
        cost[i, len(r):] = len(hyps[hs])          # hypothesis stream left unmatched
    for j, rs in enumerate(r):
        cost[len(h):, j] = len(refs[rs])          # reference speaker left unmatched
    rows, cols = linear_sum_assignment(cost)
    return int(cost[rows, cols].sum())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for regions-summary.json (aggregates only)')
    args = parser.parse_args()
    summary = {}
    runs = load_runs()
    labels = json.loads((OUT / 'region_labels.json').read_text())
    manifest = load_manifest()
    ami = [r for r in manifest if r['set'] == 'ami']

    # Oracle-turn region labels, rebuilt exactly as make_jobs.py built the oracle layout.
    labels['oracle'] = {}
    ref_streams = {}
    for row in ami:
        utts = json.loads((DATA / 'source' / 'ami' / f'{row["source"]}.utterances.json').read_text())
        near = [u for u in utts if u['end'] > row['start'] and u['begin'] < row['end']]
        turns = [{'start': u['begin'] - row['start'], 'end': u['end'] - row['start'], 'speaker': u['speaker']}
                 for u in near]
        labels['oracle'][row['id']] = [[round(s, 4), round(e, 4), lab] for s, e, lab
                                       in stride(labeled(row['duration'], turns))]
        inside = [u for u in utts if row['start'] - 0.01 <= u['begin'] and u['end'] <= row['end'] + 0.01]
        streams = {}
        for u in sorted(inside, key=lambda u: (u['begin'], u['end'])):
            streams.setdefault(u['speaker'], []).append(u['text'])
        ref_streams[row['id']] = {s: words(' '.join(t)) for s, t in streams.items()}

    def hyp_streams(cond, row_id):
        regions = labels[REGION[cond]][row_id]
        streams = {}
        for w in sorted(runs[(cond, row_id)]['windows'], key=lambda w: w['start']):
            if not w['text']:
                continue
            mid = (w['start'] + w['end']) / 2
            label = next((lab for s, e, lab in regions if s <= mid <= e), 'none')
            streams.setdefault(label, []).append(w['text'])
        return {k: words(' '.join(v)) for k, v in streams.items()}

    order = ['engine-15', 'oracle-regions', 'diar-prod', 'diar-trackvad', 'diar-nostride', 'diar-absorb',
             'diar-combined', 'diar-combined-60off']
    conds = [c for c in order if all((c, r['id']) in runs for r in ami)]
    ids = [r['id'] for r in ami]
    refs = {r['id']: words(r['reference']) for r in ami}
    per = {c: {i: errors(refs[i], words(runs[(c, i)]['text'])) for i in ids} for c in conds}
    cp = {}
    for c in conds:
        if c in REGION:
            cp[c] = {i: {'sub': cp_errors(ref_streams[i], hyp_streams(c, i)), 'del': 0, 'ins': 0,
                         'ins_run_words': 0, 'del_run_words': 0,
                         'ref_words': sum(len(v) for v in ref_streams[i].values())} for i in ids}
    base = BASELINE if BASELINE in conds else conds[0]
    print(f'\n## AMI, Nemotron 3 turns: {len(ids)} windows, {sum(len(refs[i]) for i in ids)} reference words')
    print('| Condition | WER | Sub | Del | Ins | ΔWER vs diar-prod (95% CI) | cpWER | ΔcpWER vs diar-prod (95% CI) | Windows | Speed |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for c in conds:
        t = summarize(list(per[c].values()))
        d = '—' if c == base else '{:+.2%} ({:+.2%}…{:+.2%})'.format(*paired(per, c, base, ids)[:3])
        cw = f'{summarize(list(cp[c].values()))["wer"]:.2%}' if c in cp else '—'
        cd = ('{:+.2%} ({:+.2%}…{:+.2%})'.format(*paired(cp, c, base, ids)[:3])
              if c in cp and c != base and base in cp else '—')
        print(f'| {c} | {t["wer"]:.2%} | {t["sub_rate"]:.2%} | {t["del_rate"]:.2%} | {t["ins_rate"]:.2%} | {d} | '
              f'{cw} | {cd} | {window_stats(runs, c, ids)} | {speed(runs, c, ids)} |')
        summary.setdefault('ami', {})[c] = {
            **{k: round(t[k], 5) for k in ['wer', 'sub_rate', 'del_rate', 'ins_rate']},
            'cpwer': round(summarize(list(cp[c].values()))['wer'], 5) if c in cp else None,
            'windows': window_stats(runs, c, ids)}

    meetings = [r for r in manifest if r['set'] == 'meetings']
    common = [r for r in meetings
              if all((load_output(s, r['id']) or {}).get('text') is not None for s in REPORT_SYSTEMS)]
    ids = [r['id'] for r in common]
    voters = [v for v in REPORT_SYSTEMS if SYSTEMS[v][0] != 'qwen' and SYSTEMS[v][1] != 'production']
    refs = {i: consensus({v: words(load_output(v, i)['text']) for v in voters}, family_weights(voters)) for i in ids}
    hyps = {'saved app transcript': {i: words(load_output('lokalbot-app', i)['text']) for i in ids}}
    for c in ['app-spans'] + order:
        if all((c, i) in runs for i in ids):
            hyps[c] = {i: words(runs[(c, i)]['text']) for i in ids}
    per = {c: {i: errors(refs[i], hyps[c][i]) for i in ids} for c in hyps}
    print(f'\n## Meetings, Nemotron 3 turns: {len(ids)} chunks, {sum(len(refs[i]) for i in ids)} consensus words')
    print('| Condition | Disagreement | Sub | Del | Ins | Ins runs | Δ vs diar-prod (95% CI) | Windows | Speed |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for c in hyps:
        t = summarize(list(per[c].values()))
        d = '—' if c == base or base not in hyps else '{:+.2%} ({:+.2%}…{:+.2%})'.format(*paired(per, c, base, ids)[:3])
        print(f'| {c} | {t["wer"]:.2%} | {t["sub_rate"]:.2%} | {t["del_rate"]:.2%} | {t["ins_rate"]:.2%} | '
              f'{t["ins_run_words"]} | {d} | {window_stats(runs, c, ids)} | {speed(runs, c, ids)} |')
        summary.setdefault('meetings', {})[c] = {
            **{k: round(t[k], 5) for k in ['wer', 'sub_rate', 'del_rate', 'ins_rate']},
            'ins_run_words': t['ins_run_words'], 'windows': window_stats(runs, c, ids)}
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'regions-summary.json').write_text(json.dumps(summary, indent=1))


if __name__ == '__main__':
    main()
