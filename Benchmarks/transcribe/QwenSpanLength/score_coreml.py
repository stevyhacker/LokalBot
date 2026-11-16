"""CoreML forced aligner vs the MLX aligner on the word-attribution path.

Conditions (text condition in runs.jsonl, aligned file from `qwen-span-harness align`):
  (a) MLX 4-bit on merge-60-off-v14, the shipped layout (baseline);
  (b) MLX 4-bit on merge-30-off-v14;
  (c) CoreML INT8 on merge-30-off-v14;
  (d) CoreML FP16 on merge-30-off-v14.
A window the aligner rejects (over 30 s or over the decoder's fixed T) is attributed as the
app does: the whole window goes to the speaker at its midpoint. Every row is compared with
(a), and (c)/(d) also with (b), the MLX aligner on identical text, by paired chunk bootstrap.

Meetings are scored against CloudSTT's leave-family-out consensus when its vendor outputs are
present; otherwise meeting text is compared with the shipped layout's text, which measures
how much the layout changes the words, not accuracy.
"""
import argparse
import json
import statistics
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

CONDITIONS = [  # key, label, text condition, aligned file, stats file of the one-chunk memory run
    ('a', 'MLX 4-bit, merged ≤60 s (shipped)', 'merge-60-off-v14', 'aligned-merge-60-off-v14.jsonl',
     'aligned-merge-60-off-v14-long.jsonl.stats.json'),
    ('b', 'MLX 4-bit, merged ≤30 s', 'merge-30-off-v14', 'aligned-merge-30-off-v14.jsonl',
     'aligned-merge-30-off-v14-long.jsonl.stats.json'),
    ('c', 'CoreML INT8, merged ≤30 s', 'merge-30-off-v14', 'aligned-coreml-int8-merge-30-off-v14.jsonl',
     'aligned-coreml-int8-merge-30-off-v14-long.jsonl.stats.json'),
    ('d', 'CoreML FP16, merged ≤30 s', 'merge-30-off-v14', 'aligned-coreml-fp16-merge-30-off-v14.jsonl',
     'aligned-coreml-fp16-merge-30-off-v14-long.jsonl.stats.json'),
    # INT8 with SPEECH_COREML_COMPUTE_UNITS=gpu / ane instead of speech-swift's defaults
    # (encoder CPU + Neural Engine, decoder all units).
    ('e', 'CoreML INT8, GPU only', 'merge-30-off-v14', 'units/int8-gpu.jsonl', None),
    ('f', 'CoreML INT8, Neural Engine only', 'merge-30-off-v14', 'units/int8-ane.jsonl', None),
]


def text_windows(runs, cond, i):
    return [w for w in runs[(cond, i)]['windows'] if w['text']]


def attributed(windows, aligned, turns):
    """Per window: (surface, speaker) words; a failed window keeps one speaker at its midpoint."""
    out = []
    for win, words_ in zip(windows, aligned['windows']):
        if words_:
            out.append([(s, speaker_at(turns, (float(a) + float(b)) / 2, TOLERANCE)) for s, a, b in words_])
        else:
            label = speaker_at(turns, (win['start'] + win['end']) / 2, TOLERANCE)
            out.append([(s, label) for s in win['text'].split()])
    return out


def pieces(windows, aligned, turns):
    """word_pieces with failed windows as one piece each, snapped like the app."""
    timed = []
    for win, words_ in zip(windows, aligned['windows']):
        timed.append(words_ or [['', str(win['start']), str(win['end'])]])
    return word_pieces(windows, timed, turns, True)


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for coreml-summary.json (aggregates only)')
    args = parser.parse_args()
    runs = load_runs()
    manifest = load_manifest()
    recording = recordings(manifest)
    turns_by_file = json.loads((OUT / 'turns.json').read_text())
    turns = {r['id']: clipped_turns(turns_by_file[recording(r)], r['start'], r['end']) for r in manifest}
    ami = [r for r in manifest if r['set'] == 'ami']
    ami_ids = [r['id'] for r in ami]
    meet_all = [r['id'] for r in manifest if r['set'] == 'meetings']
    have_consensus = all((load_output(s, i) or {}).get('text') is not None
                         for s in REPORT_SYSTEMS for i in meet_all[:3])
    if have_consensus:
        meet_ids = [i for i in meet_all if all((load_output(s, i) or {}).get('text') is not None for s in REPORT_SYSTEMS)]
        voters = [v for v in REPORT_SYSTEMS if SYSTEMS[v][0] != 'qwen' and SYSTEMS[v][1] != 'production']
        meet_refs = {i: consensus({v: words(load_output(v, i)['text']) for v in voters}, family_weights(voters))
                     for i in meet_ids}
        meet_basis = 'consensus'
    else:
        meet_ids = meet_all
        meet_refs = {i: words(runs[(CONDITIONS[0][2], i)]['text']) for i in meet_ids}
        meet_basis = 'shipped-layout text'
    ami_refs = {r['id']: words(r['reference']) for r in ami}
    ref_streams = {}
    for row in ami:
        utts = json.loads((DATA / 'source' / 'ami' / f'{row["source"]}.utterances.json').read_text())
        inside = [u for u in utts if row['start'] - 0.01 <= u['begin'] and u['end'] <= row['end'] + 0.01]
        streams = {}
        for u in sorted(inside, key=lambda u: (u['begin'], u['end'])):
            streams.setdefault(u['speaker'], []).append(u['text'])
        ref_streams[row['id']] = {s: words(' '.join(t)) for s, t in streams.items()}
    audio = sum(r['duration'] for r in manifest)

    meet, amiw, cp, rows, aligned_by = {}, {}, {}, {}, {}
    for key, label, cond, path, stats_path in CONDITIONS:
        if not (OUT / path).exists() or not all((cond, r['id']) in runs for r in manifest):
            print(f'skip {key} {label}: missing {path} or {cond} runs')
            continue
        aligned = {json.loads(l)['id']: json.loads(l) for l in (OUT / path).read_text().splitlines()}
        aligned_by[key] = aligned
        meet[key] = {i: errors(meet_refs[i], words(runs[(cond, i)]['text'])) for i in meet_ids}
        amiw[key] = {i: errors(ami_refs[i], words(runs[(cond, i)]['text'])) for i in ami_ids}
        cp[key] = {}
        for i in ami_ids:
            streams = {}
            for window in attributed(text_windows(runs, cond, i), aligned[i], turns[i]):
                for surface, spk in window:
                    streams.setdefault(spk, []).append(surface)
            cp[key][i] = {'sub': cp_errors(ref_streams[i], {k: words(' '.join(v)) for k, v in streams.items()}),
                          'del': 0, 'ins': 0, 'ins_run_words': 0, 'del_run_words': 0,
                          'ref_words': sum(len(v) for v in ref_streams[i].values())}
        support = {'ami': [0, 0], 'meetings': [0, 0]}
        failures, window_secs, window_audio, total_windows = {}, [], [], 0
        for r in manifest:
            a, e = supported(turns[r['id']], pieces(text_windows(runs, cond, r['id']), aligned[r['id']], turns[r['id']]))
            support[r['set']][0] += a
            support[r['set']][1] += e
            for info in aligned[r['id']].get('info', []):
                total_windows += 1
                window_audio.append(info['audioSeconds'])
                window_secs.append(info['seconds'])
                if info.get('error'):
                    failures[info['error']] = failures.get(info['error'], 0) + 1
        align_seconds = sum(x['seconds'] for x in aligned.values())
        stats = OUT / stats_path if stats_path else None
        memory = json.loads(stats.read_text()) if stats and stats.exists() else {}
        full_stats = OUT / (path + '.stats.json')
        full = json.loads(full_stats.read_text()) if full_stats.exists() else {}
        rows[key] = {
            'label': label, 'text_condition': cond,
            'meetings': summarize(list(meet[key].values()))['wer'],
            'ami_wer': summarize(list(amiw[key].values()))['wer'],
            'ami_cpwer': summarize(list(cp[key].values()))['wer'],
            'support': support, 'windows': total_windows, 'failures': failures,
            'longest_window_s': max(window_audio) if window_audio else None,
            'align_seconds': round(align_seconds, 1), 'align_x_realtime': round(audio / align_seconds),
            'window_ms_median': round(1000 * statistics.median(window_secs)) if window_secs else None,
            'window_ms_p95': round(1000 * pct(window_secs, 0.95)) if window_secs else None,
            'load_seconds': round(full['loadSeconds'], 1) if full else None,
            'warmup_seconds': round(full['warmupSeconds'], 1) if full else None,
            'peak_footprint_gb_full_run': round(full['peakFootprintBytes'] / 2 ** 30, 2) if full else None,
            'peak_footprint_gb_long_chunk': round(memory['peakFootprintBytes'] / 2 ** 30, 2) if memory else None,
        }

    def delta(per, key, base, ids):
        if key == base or key not in per or base not in per:
            return None
        return [round(100 * x, 2) for x in paired(per, key, base, ids)[:3]]

    for key in rows:
        rows[key]['meetings_delta_vs_a'] = delta(meet, key, 'a', meet_ids)
        rows[key]['ami_wer_delta_vs_a'] = delta(amiw, key, 'a', ami_ids)
        rows[key]['ami_cpwer_delta_vs_a'] = delta(cp, key, 'a', ami_ids)
        rows[key]['ami_cpwer_delta_vs_b'] = delta(cp, key, 'b', ami_ids) if key not in ('a', 'b') else None

    show = lambda d: '—' if d is None else '{:+.2f} ({:+.2f}…{:+.2f})'.format(*d)
    print(f'Meetings scored against {meet_basis}.\n')
    print('| Condition | Meetings | Δ vs (a) | AMI WER | Δ vs (a) | AMI cpWER | Δ vs (a) | Δ vs (b) |'
          ' Speaker memory AMI, meetings | Failures | Align speed | Peak footprint (long chunk) |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for key, r in rows.items():
        s = r['support']
        fails = ', '.join(f'{k} {v}' for k, v in sorted(r['failures'].items())) or '0'
        mem = '—' if r['peak_footprint_gb_long_chunk'] is None else f'{r["peak_footprint_gb_long_chunk"]:.2f} GB'
        print(f'| ({key}) {r["label"]} | {r["meetings"]:.2%} | {show(r["meetings_delta_vs_a"])} | {r["ami_wer"]:.2%} | '
              f'{show(r["ami_wer_delta_vs_a"])} | {r["ami_cpwer"]:.2%} | {show(r["ami_cpwer_delta_vs_a"])} | '
              f'{show(r["ami_cpwer_delta_vs_b"])} | {s["ami"][0]}/{s["ami"][1]}, {s["meetings"][0]}/{s["meetings"][1]} | '
              f'{fails} of {r["windows"]} | {r["align_x_realtime"]}× | {mem} |')
    for key, r in rows.items():
        print(f'({key}) align {r["align_seconds"]} s, per window median {r["window_ms_median"]} ms, p95 '
              f'{r["window_ms_p95"]} ms, load {r["load_seconds"]} s, warm-up {r["warmup_seconds"]} s, '
              f'peak footprint full run {r["peak_footprint_gb_full_run"]} GB, longest window {r["longest_window_s"]} s')

    # Raw word boundaries on identical text: (b) against (c) and (d).
    boundaries = {}
    if 'b' in aligned_by:
        for key in ('c', 'd', 'e', 'f'):
            if key not in aligned_by:
                continue
            starts, ends, flips, compared, mismatched = [], [], 0, 0, 0
            for r in manifest:
                i = r['id']
                windows = text_windows(runs, 'merge-30-off-v14', i)
                for win, wb, wk in zip(windows, aligned_by['b'][i]['windows'], aligned_by[key][i]['windows']):
                    if not wb or not wk:
                        continue
                    if len(wb) != len(wk) or any(x[0] != y[0] for x, y in zip(wb, wk)):
                        mismatched += 1
                        continue
                    for (_, sb, eb), (_, sk, ek) in zip(wb, wk):
                        starts.append(1000 * abs(float(sb) - float(sk)))
                        ends.append(1000 * abs(float(eb) - float(ek)))
                        mb, mk = (float(sb) + float(eb)) / 2, (float(sk) + float(ek)) / 2
                        flips += speaker_at(turns[i], mb, TOLERANCE) != speaker_at(turns[i], mk, TOLERANCE)
                        compared += 1
            both = starts + ends
            boundaries[key] = {
                'words': compared, 'windows_with_different_words': mismatched,
                'start_ms_median': round(statistics.median(starts)), 'start_ms_p95': round(pct(starts, 0.95)),
                'end_ms_median': round(statistics.median(ends)), 'end_ms_p95': round(pct(ends, 0.95)),
                'all_ms_median': round(statistics.median(both)), 'all_ms_p95': round(pct(both, 0.95)),
                'exact_share': round(sum(x == 0 for x in both) / len(both), 4),
                'within_80ms_share': round(sum(x <= 80.5 for x in both) / len(both), 4),
                'over_240ms_share': round(sum(x > 240.5 for x in both) / len(both), 4),
                'speaker_changes': flips, 'speaker_change_share': round(flips / max(compared, 1), 4),
            }
        print('\n| Word boundaries vs (b), identical text | Words | Start median / p95 | End median / p95 |'
              ' Identical | Within 80 ms | Over 240 ms | Words that change speaker |')
        print('|---|---:|---:|---:|---:|---:|---:|---:|')
        for key, b in boundaries.items():
            print(f'| ({key}) | {b["words"]:,} | {b["start_ms_median"]} / {b["start_ms_p95"]} ms | '
                  f'{b["end_ms_median"]} / {b["end_ms_p95"]} ms | {b["exact_share"]:.1%} | '
                  f'{b["within_80ms_share"]:.1%} | {b["over_240ms_share"]:.1%} | '
                  f'{b["speaker_changes"]} ({b["speaker_change_share"]:.2%}) |')
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'coreml-summary.json').write_text(json.dumps(
            {'meetings_basis': meet_basis, 'conditions': rows, 'boundaries_vs_b': boundaries},
            indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
