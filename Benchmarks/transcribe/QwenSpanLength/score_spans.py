"""Score harness runs with the CloudSTT benchmark's own normalizer, aligner and consensus.

AMI: WER against the human reference. Meetings: disagreement with the qwen-family
leave-family-out consensus (openai + google + nvidia voters), i.e. exactly the reference
the 2026-09-30 report used for `local-qwen3-asr-1.7b` and `lokalbot-app`.
"""
import argparse
import json
import os
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt'))
OUT = Path(os.environ.get('SPAN_BENCH_OUT', DATA / 'span-length'))
MODEL_DIR = Path(os.environ.get('QWEN_MODEL_DIR', OUT / 'models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit'))
CLOUD = Path(os.environ.get('CLOUDSTT_DIR', ROOT.parent / 'CloudSTT'))
os.environ['STT_BENCH_DATA'] = str(DATA)
sys.path.insert(0, str(CLOUD))
from common import SYSTEMS, load_manifest, load_output  # noqa: E402
from score import consensus, errors, family_weights, summarize, words  # noqa: E402

REPORT_SYSTEMS = ['gpt-transcribe', 'gpt-4o-transcribe', 'gpt-4o-mini-transcribe', 'gemini-3.5-transcribe',
                  'gemini-3.8-flash', 'qwen-audio-3.1-asr-flash', 'qwen3-asr-flash', 'local-qwen3-asr-1.7b',
                  'local-parakeet-v3', 'lokalbot-app']
BOOT = 2000


def load_runs():
    runs = {}
    for line in (OUT / 'runs.jsonl').read_text().splitlines():
        r = json.loads(line)
        runs[(r['condition'], r['id'])] = r
    return runs


def token_hits(runs):
    """Windows whose re-tokenized text reaches the cap (EOS never emitted)."""
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(str(MODEL_DIR))
    out = {}
    for key, r in runs.items():
        hits, total, peak = 0, 0, 0.0
        for w in r['windows']:
            n = len(tok.encode(w['text'], add_special_tokens=False))
            total += 1
            hits += n + 1 >= w['cap']
            peak = max(peak, n / w['cap'])
        out[key] = (hits, total, peak)
    return out


def paired(per, a, b, ids, seed=11):
    """Bootstrap the WER difference a - b over chunks; returns (delta, lo, hi, P(a<b))."""
    rng = random.Random(seed)
    diffs = []
    for _ in range(BOOT):
        pick = [rng.choice(ids) for _ in ids]
        ref = max(sum(per[a][i]['ref_words'] for i in pick), 1)
        ea = sum(per[a][i]['sub'] + per[a][i]['del'] + per[a][i]['ins'] for i in pick) / ref
        eb = sum(per[b][i]['sub'] + per[b][i]['del'] + per[b][i]['ins'] for i in pick) / ref
        diffs.append(ea - eb)
    diffs.sort()
    point = (summarize([per[a][i] for i in ids])['wer'] - summarize([per[b][i] for i in ids])['wer'])
    return point, diffs[int(0.025 * BOOT)], diffs[int(0.975 * BOOT) - 1], sum(d < 0 for d in diffs) / BOOT


def window_stats(runs, cond, ids):
    lens = sorted(w['end'] - w['start'] for i in ids if (cond, i) in runs for w in runs[(cond, i)]['windows'])
    if not lens:
        return '—'
    return f'{len(lens)} / med {lens[len(lens) // 2]:.1f}s / max {lens[-1]:.0f}s'


def speed(runs, cond, ids):
    audio = sum(runs[(cond, i)]['audioSeconds'] for i in ids if (cond, i) in runs)
    decode = sum(runs[(cond, i)]['decodeSeconds'] for i in ids if (cond, i) in runs)
    return f'{audio / decode:.0f}x' if decode else '—'


def table(name, rows, hyps, refs, baseline, runs, hits):
    ids = [r['id'] for r in rows]
    per = {s: {i: errors(refs[i], hyps[s][i]) for i in ids} for s in hyps}
    print(f'\n## {name}: {len(ids)} chunks, {sum(r["duration"] for r in rows) / 60:.1f} min, '
          f'{sum(len(refs[i]) for i in ids)} reference words')
    print('| Condition | WER | Sub | Del | Ins | Ins runs | Del runs | Δ vs baseline (95% CI) | P(better) | Windows | Cap hits | Speed |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    summary = {'chunks': len(ids), 'audio_minutes': round(sum(r['duration'] for r in rows) / 60, 1),
               'reference_words': sum(len(refs[i]) for i in ids), 'baseline': baseline, 'conditions': {}}
    for s in hyps:
        t = summarize(list(per[s].values()))
        d, lo, hi, p = paired(per, s, baseline, ids) if s != baseline else (0, 0, 0, float('nan'))
        parts = [hits[(s, i)] for i in ids if (s, i) in hits]
        h = (sum(p[0] for p in parts), sum(p[1] for p in parts), max(p[2] for p in parts)) if parts else None
        print(f'| {s} | {t["wer"]:.2%} | {t["sub_rate"]:.2%} | {t["del_rate"]:.2%} | {t["ins_rate"]:.2%} | '
              f'{t["ins_run_words"]} | {t["del_run_words"]} | {d:+.2%} ({lo:+.2%}…{hi:+.2%}) | {p:.2f} | '
              f'{window_stats(runs, s, ids)} | {f"{h[0]}/{h[1]} (peak {h[2]:.0%})" if h else "—"} | '
              f'{speed(runs, s, ids)} |')
        lens = [w['end'] - w['start'] for i in ids if (s, i) in runs for w in runs[(s, i)]['windows']]
        summary['conditions'][s] = {
            **{k: round(t[k], 5) for k in ['wer', 'sub_rate', 'del_rate', 'ins_rate']},
            'ins_run_words': t['ins_run_words'], 'del_run_words': t['del_run_words'],
            'delta_vs_baseline': round(d, 5), 'delta_ci95': [round(lo, 5), round(hi, 5)],
            'p_better_than_baseline': None if s == baseline else p,
            'windows': len(lens), 'median_window_s': round(sorted(lens)[len(lens) // 2], 2) if lens else None,
            'max_window_s': round(max(lens), 2) if lens else None,
            'cap_hits': h[0] if h else None, 'peak_cap_use': round(h[2], 3) if h else None}
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for summary.json (aggregates only)')
    args = parser.parse_args()
    runs = load_runs()
    conditions = list(dict.fromkeys(c for c, _ in runs))
    hits = token_hits(runs)
    manifest = load_manifest()

    ami = [r for r in manifest if r['set'] == 'ami']
    refs = {r['id']: words(r['reference']) for r in ami}
    hyps = {'mlx-audio (benchmark)': {r['id']: words(load_output('local-qwen3-asr-1.7b', r['id'])['text']) for r in ami}}
    for c in conditions:
        if all((c, r['id']) in runs for r in ami):
            hyps[c] = {r['id']: words(runs[(c, r['id'])]['text']) for r in ami}
    baseline = 'engine-15' if 'engine-15' in hyps else next(iter(hyps))
    summary = {'ami': table('AMI Mix-Headset, human reference', ami, hyps, refs, baseline, runs, hits)}

    meetings = [r for r in manifest if r['set'] == 'meetings']
    common = [r for r in meetings
              if all((load_output(s, r['id']) or {}).get('text') is not None for s in REPORT_SYSTEMS)]
    refs = {}
    for r in common:
        voters = [v for v in REPORT_SYSTEMS if SYSTEMS[v][0] != 'qwen' and SYSTEMS[v][1] != 'production']
        refs[r['id']] = consensus({v: words(load_output(v, r['id'])['text']) for v in voters}, family_weights(voters))
    hyps = {'mlx-audio (benchmark)': {r['id']: words(load_output('local-qwen3-asr-1.7b', r['id'])['text']) for r in common},
            'saved app transcript': {r['id']: words(load_output('lokalbot-app', r['id'])['text']) for r in common}}
    for c in conditions:
        if all((c, r['id']) in runs for r in common):
            hyps[c] = {r['id']: words(runs[(c, r['id'])]['text']) for r in common}
    baseline = 'engine-15' if 'engine-15' in hyps else 'saved app transcript'
    summary['meetings'] = table('LokalBot meetings, leave-family-out consensus', common, hyps, refs, baseline, runs, hits)
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'summary.json').write_text(json.dumps(summary, indent=1))


if __name__ == '__main__':
    main()
