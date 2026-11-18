"""Choose the language sample's size and share from the `before` runs, without decoding again.

A `before` run (the old path) decodes every window on auto, so any sample's vote can be replayed from its
windows: each window's vote is the engine's own (TranscriptLanguageVote with the
Serbian/Croatian aliases, recorded by the replay test), and a vote over windows is the sum of
theirs. Decoding is greedy and deterministic, so a window decoded again in the same language
gives the same text.

For each sample size and share, a track's outcome is one of:
- one pass: the sample's vote holds and agrees with the old path's pin;
- fallback: the sample's vote does not hold, so the rest decodes on auto and the whole-track
  vote decides, exactly as on the old path (two passes when it pinned);
- WRONG PIN: the sample's vote holds where the old path's did not, or names another language. Only
  this changes a transcript.

Time is estimated from the recorded window times: sampled auto windows plus every window
pinned. A pin the old path never made has no pinned times, so its auto times stand in.
"""
import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ALIGNER, auto_windows, pinned, pinned_windows, runs, vote, OUT


def outcome(record, size, share):
    auto = auto_windows(record)
    count = len(record['spans'])
    before = record.get('pinned')
    word = record['layout'] == 'word'
    sample = record['samples'][str(size)]
    sample_auto = sum(auto[i]['seconds'] for i in sample if i in auto)
    all_auto = sum(w['seconds'] for w in auto.values())
    pinned_time = sum(w['seconds'] for w in pinned_windows(record, before).values()) if before else 0.0
    before_time = all_auto + (pinned_time if record['decodedTwice'] else 0.0)
    code, got, _ = vote([auto[i] for i in sample if i in auto])
    strong = pinned([auto[i] for i in sample if i in auto], share) if len(sample) < count else None
    if strong is None:
        return 'fallback', before_time, before_time, code, got
    if strong != before:
        estimate = sample_auto + (0.0 if word and strong not in ALIGNER else all_auto)
        return 'WRONG PIN', estimate, before_time, code, got
    if word and strong not in ALIGNER:
        return 'one pass', sample_auto, before_time, code, got
    return 'one pass', sample_auto + pinned_time, before_time, code, got


def resample(records, sizes, shares, draws):
    """The sampler takes the longest span of each group; any span of a group could have opened
    the track's text there. For tracks the old path left on auto, how often a random span per
    group pins anyway; for tracks it pinned, how often such a sample pins the same language."""
    rng = random.Random(7)
    out = []
    for size in sizes:
        for share in shares:
            wrong, same = [], []
            for r in records:
                count, auto = len(r['spans']), auto_windows(r)
                if count <= size:
                    continue
                hits = 0
                for _ in range(draws):
                    picks = [rng.randrange(g * count // size, (g + 1) * count // size) for g in range(size)]
                    code = pinned([auto[i] for i in picks if i in auto], share)
                    hits += code is not None if not r.get('pinned') else code == r['pinned']
                (same if r.get('pinned') else wrong).append(hits / draws)
            row = {'size': size, 'share': share, 'mixedTracks': len(wrong),
                   'wrongPinMean': round(sum(wrong) / len(wrong), 3), 'wrongPinMax': round(max(wrong), 3),
                   'pinnedTracks': len(same), 'onePassMean': round(sum(same) / len(same), 3)}
            out.append(row)
            print(f'{size:>4} {share:>5.2f}  wrong pin on {len(wrong)} mixed tracks: mean {row["wrongPinMean"]:.1%} '
                  f'max {row["wrongPinMax"]:.1%}  |  one pass on {len(same)} pinned tracks: {row["onePassMean"]:.0%}')
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--shares', nargs='+', type=float, default=[0.8, 0.85, 0.9, 0.95])
    parser.add_argument('--detail', type=int, help='print every track for this sample size')
    parser.add_argument('--share', type=float, default=0.8, help='share for --detail')
    parser.add_argument('--resample', type=int, default=0, help='random samples per track (0: skip)')
    parser.add_argument('--sizes', nargs='+', type=int, help='sample sizes (default: all recorded)')
    parser.add_argument('--results', help='also write simulation.json here')
    parser.add_argument('--runs', help='runs file (default QLS_OUT/runs.jsonl)')
    args = parser.parse_args()
    records = [r for (_, _, mode), r in sorted(runs(args.runs).items()) if mode == 'before']
    sizes = args.sizes or sorted({int(k) for r in records for k in r['samples']})
    summary = []
    for layout in ['word', 'plain']:
        group = [r for r in records if r['layout'] == layout]
        if not group:
            continue
        print(f'\n{layout} layout: {len(group)} tracks, {sum(len(r["spans"]) for r in group)} windows, '
              f'before pinned {sum(1 for r in group if r.get("pinned"))}')
        print(f'{"size":>4} {"share":>5}  {"one pass":>8} {"fallback":>8} {"wrong":>5}  {"time vs before":>14}')
        for size in sizes:
            for share in args.shares:
                results = [outcome(r, size, share) for r in group]
                new, old = sum(x[1] for x in results), sum(x[2] for x in results)
                counts = {k: sum(1 for x in results if x[0] == k) for k in ['one pass', 'fallback', 'WRONG PIN']}
                print(f'{size:>4} {share:>5.2f}  {counts["one pass"]:>8} {counts["fallback"]:>8} '
                      f'{counts["WRONG PIN"]:>5}  {new / old:>13.1%}')
                summary.append({'layout': layout, 'size': size, 'share': share, **counts,
                                'seconds': round(new, 1), 'beforeSeconds': round(old, 1)})
        if args.detail:
            print(f'\nsize {args.detail}, share {args.share}:')
            for r in group:
                kind, new, old, code, got = outcome(r, args.detail, args.share)
                full = vote(list(auto_windows(r).values()))
                print(f'  {r["id"]:<28} {len(r["spans"]):>4} windows  before {r.get("pinned") or "-":<3} '
                      f'(full {full[0]} {full[1]:.2f})  sample {code} {got:.2f}  {kind:<9} {new:6.1f}s / {old:6.1f}s')
    result = {'deterministic': summary}
    if args.resample:
        print(f'\nrandom span per group, {args.resample} samples per track:')
        result['resampled'] = resample(records, sizes, args.shares, args.resample)
    for folder in ([] if args.runs else [OUT]) + ([Path(args.results)] if args.results else []):
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'simulation.json').write_text(json.dumps(result, indent=1))


if __name__ == '__main__':
    main()
