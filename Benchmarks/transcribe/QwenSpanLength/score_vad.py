"""VAD gate sweep: recall on the benchmark sets, false alarms on speech-free meeting audio."""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from score_spans import OUT, REPORT_SYSTEMS, paired  # noqa: E402
from common import SYSTEMS, load_manifest, load_output  # noqa: E402  (CloudSTT)
from score import consensus, errors, family_weights, summarize, words  # noqa: E402  (CloudSTT)
from score_language import load  # noqa: E402

SUMMARY = {}


def english(runs, conditions, base, title):
    m = load_manifest()
    meet = [r for r in m if r['set'] == 'meetings' and all((load_output(s, r['id']) or {}).get('text') is not None for s in REPORT_SYSTEMS)]
    ami = [r for r in m if r['set'] == 'ami']
    voters = [v for v in REPORT_SYSTEMS if SYSTEMS[v][0] != 'qwen' and SYSTEMS[v][1] != 'production']
    refs = {r['id']: consensus({v: words(load_output(v, r['id'])['text']) for v in voters}, family_weights(voters)) for r in meet}
    refs.update({r['id']: words(r['reference']) for r in ami})
    pm, pa = {}, {}
    print(f'\n## {title}')
    print('| Condition | Meetings | Δ (95% CI) | AMI WER | Δ (95% CI) | AMI sub / del / ins | Invented-run words | Chunk audio in windows (meetings / AMI) |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|')
    for label, cond in conditions:
        if not all((cond, r['id']) in runs for r in m):
            print(f'| {label} | missing |'); continue
        pm[label] = {r['id']: errors(refs[r['id']], words(runs[(cond, r['id'])]['text'])) for r in meet}
        pa[label] = {r['id']: errors(refs[r['id']], words(runs[(cond, r['id'])]['text'])) for r in ami}
        tm, ta = summarize(list(pm[label].values())), summarize(list(pa[label].values()))
        inv = tm['ins_run_words'] + ta['ins_run_words']
        cov = []
        for rows in ([r for r in m if r['set'] == 'meetings'], ami):
            cov.append(sum(w['end'] - w['start'] for r in rows for w in runs[(cond, r['id'])]['windows']) / sum(r['duration'] for r in rows))
        d = lambda per, ids: '—' if label == base else '{:+.2f} ({:+.2f}…{:+.2f})'.format(*[100 * x for x in paired(per, label, base, ids)[:3]])
        SUMMARY.setdefault(title, {})[label] = {'meetings': round(tm['wer'], 5), 'ami_wer': round(ta['wer'], 5),
                                                'ami_del_rate': round(ta['del_rate'], 5), 'invented_run_words': inv,
                                                'coverage': [round(x, 3) for x in cov]}
        print(f'| {label} | {tm["wer"]:.2%} | {d(pm, [r["id"] for r in meet])} | {ta["wer"]:.2%} | {d(pa, [r["id"] for r in ami])} | '
              f'{ta["sub_rate"]:.2%} / {ta["del_rate"]:.2%} / {ta["ins_rate"]:.2%} | {inv} | {cov[0]:.0%} / {cov[1]:.0%} |')


def noise(runs, conditions, title):
    items = json.loads((OUT / 'noise' / 'items.json').read_text())
    minutes = sum(i['duration'] for i in items) / 60
    print(f'\n## {title}: {minutes:.0f} min of speech-free meeting audio')
    print('| Condition | Words invented | per 10 min | Passed as speech | Mic words | System words |')
    print('|---|---:|---:|---:|---:|---:|')
    for label, cond in conditions:
        rows = [runs.get((cond, i['id'])) for i in items]
        if not all(rows):
            print(f'| {label} | missing |'); continue
        n = [len(words(r['text'])) for r in rows]
        passed = sum(w['end'] - w['start'] for r in rows for w in r['windows']) / 60
        mic = sum(k for k, i in zip(n, items) if i['id'].endswith('mic'))
        SUMMARY.setdefault(title, {})[label] = {'words': sum(n), 'per_10_min': round(10 * sum(n) / minutes, 1),
                                                'passed_minutes': round(passed, 2)}
        print(f'| {label} | {sum(n)} | {10 * sum(n) / minutes:.1f} | {passed:.1f} min | {mic} | {sum(n) - mic} |')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for vad-summary.json (aggregates only)')
    args = parser.parse_args()
    r17, r06, nz, nz06 = load('runs.jsonl'), load('runs-06b.jsonl'), load('runs-noise.jsonl'), load('runs-noise-06b.jsonl')
    english(r17, [('0.85, pad 0.1 (shipped)', 'merge-60-off-v14'), ('0.7', 'm60-t0.7'), ('0.5', 'm60-t0.5'), ('0.35', 'm60-t0.35'),
                  ('0.85, pad 0.3', 'm60-pad0.3'), ('no gate (whole chunk)', 'whole-en-off')],
            '0.85, pad 0.1 (shipped)', '1.7B word-attribution path (merged ≤60 s)')
    english(r17, [('0.85 (shipped)', 'engine-15'), ('0.5', 'e15-t0.5')], '0.85 (shipped)', '1.7B plain path (≤14 s)')
    english(r06, [('0.85 (shipped)', 'merge-15-v14'), ('0.5', 'm15-t0.5')], '0.85 (shipped)', '0.6B word-attribution path (merged ≤15 s)')
    noise(nz, [(f'1.7B merged ≤60 s, {t}', f'm60-t{t}') for t in ['0.85', '0.7', '0.5', '0.35']]
          + [('1.7B merged ≤60 s, 0.85 pad 0.3', 'm60-pad0.3')]
          + [(f'1.7B plain ≤14 s, {t}', f'e15-t{t}') for t in ['0.85', '0.7', '0.5', '0.35']], 'False alarms')
    noise(nz06, [(f'0.6B merged ≤15 s, {t}', f'm15-t{t}') for t in ['0.85', '0.5']], 'False alarms, 0.6B')
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'vad-summary.json').write_text(json.dumps(SUMMARY, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
