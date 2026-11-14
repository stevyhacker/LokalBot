"""Score MLX (speech-swift) vs llama.cpp runs of Qwen3-ASR 1.7B on identical windows.

AMI: WER against the human reference (CloudSTT normalizer), paired chunk bootstrap.
Meetings: CloudSTT's vendor consensus is not regenerated here, so meetings report how much the
two backends disagree (llama.cpp scored against MLX), plus inserted/deleted runs.
FLEURS: score_language.fleurs_error per track (CER for Japanese, Cyrillic folded to Latin for
Serbian); the 95% intervals bootstrap the 30 reference utterances of each track.
Only aggregates are written to --results.
"""
import argparse
import json
import random
import re
import sys
import unicodedata
from pathlib import Path

from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import BasicTextNormalizer

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / 'QwenSpanLength'))
from score_language import CYR, fleurs_error  # noqa: E402
from score_spans import OUT  # noqa: E402
from common import load_manifest  # noqa: E402  (CloudSTT)
from score import errors, summarize, words  # noqa: E402  (CloudSTT)

BOOT = 2000
BACKENDS = ['mlx', 'llama']
VOCAB_STEMS = ['moldavij', 'japan', 'bozic', 'isus', 'wifi', 'egipcan', 'irak', 'argentin', 'dzordz', 'bus']


def load(backend):
    runs = {}
    path = OUT / f'runs-{backend}.jsonl'
    for line in path.read_text().splitlines() if path.exists() else []:
        r = json.loads(line)
        runs[(r['condition'], r['id'])] = r
    return runs


def boot(per_a, per_b, ids, rate, seed=11):
    """Paired bootstrap of rate(b) - rate(a) over ids; returns (delta, lo, hi, P(b better))."""
    rng = random.Random(seed)
    diffs = []
    for _ in range(BOOT):
        pick = [rng.choice(ids) for _ in ids]
        diffs.append(rate([per_b[i] for i in pick]) - rate([per_a[i] for i in pick]))
    diffs.sort()
    point = rate([per_b[i] for i in ids]) - rate([per_a[i] for i in ids])
    return point, diffs[int(0.025 * BOOT)], diffs[int(0.975 * BOOT) - 1], sum(d < 0 for d in diffs) / BOOT


def wer(chunks):
    return summarize(chunks)['wer']


def speed(runs, cond, ids):
    audio = sum(runs[(cond, i)]['audioSeconds'] for i in ids)
    decode = sum(runs[(cond, i)]['decodeSeconds'] for i in ids)
    return {'audio_s': round(audio, 1), 'decode_s': round(decode, 1), 'rtfx': round(audio / decode, 1)}


def english(runs, summary):
    manifest = load_manifest()
    ami = [r['id'] for r in manifest if r['set'] == 'ami']
    meet = [r['id'] for r in manifest if r['set'] == 'meetings']
    refs = {r['id']: words(r['reference']) for r in manifest if r['set'] == 'ami'}
    print('\n## AMI Mix-Headset (27.4 min, human reference): WER')
    print('| Layout | MLX | llama.cpp | Δ llama − MLX (95% CI) | P(llama better) | MLX speed | llama speed |')
    print('|---|---:|---:|---:|---:|---:|---:|')
    summary['ami'] = {}
    for cond in ['merge-60-off-v14', 'engine-15']:
        if not all((cond, i) in runs[b] for b in BACKENDS for i in ami):
            continue
        per = {b: {i: errors(refs[i], words(runs[b][(cond, i)]['text'])) for i in ami} for b in BACKENDS}
        d = boot(per['mlx'], per['llama'], ami, wer)
        sp = {b: speed(runs[b], cond, ami) for b in BACKENDS}
        row = {b: {k: round(v, 5) for k, v in summarize(list(per[b].values())).items() if isinstance(v, float)}
               | {'ins_run_words': summarize(list(per[b].values()))['ins_run_words'],
                  'del_run_words': summarize(list(per[b].values()))['del_run_words'], **sp[b]} for b in BACKENDS}
        row['delta'] = [round(x, 5) for x in d[:3]]
        row['p_llama_better'] = d[3]
        summary['ami'][cond] = row
        print(f'| {cond} | {row["mlx"]["wer"]:.2%} | {row["llama"]["wer"]:.2%} | '
              f'{d[0]:+.2%} ({d[1]:+.2%}…{d[2]:+.2%}) | {d[3]:.2f} | {sp["mlx"]["rtfx"]}x | {sp["llama"]["rtfx"]}x |')

    print('\n## Cross-backend disagreement (llama.cpp scored against MLX as reference)')
    print('| Set | Layout | Disagreement | Sub | Del | Ins | Ins-run words | Del-run words | Identical chunks | MLX speed | llama speed |')
    print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    summary['agreement'] = {}
    for name, ids in [('AMI', ami), ('Meetings', meet)]:
        for cond in ['merge-60-off-v14', 'engine-15']:
            if not all((cond, i) in runs[b] for b in BACKENDS for i in ids):
                continue
            per = [errors(words(runs['mlx'][(cond, i)]['text']), words(runs['llama'][(cond, i)]['text'])) for i in ids]
            ok = [e for e in per if e['ref_words']]
            t = summarize(ok)
            same = sum(runs['mlx'][(cond, i)]['text'] == runs['llama'][(cond, i)]['text'] for i in ids)
            sp = {b: speed(runs[b], cond, ids) for b in BACKENDS}
            summary['agreement'][f'{name}/{cond}'] = {
                'disagreement': round(t['wer'], 5), 'sub': round(t['sub_rate'], 5), 'del': round(t['del_rate'], 5),
                'ins': round(t['ins_rate'], 5), 'ins_run_words': t['ins_run_words'],
                'del_run_words': t['del_run_words'], 'identical_chunks': same, 'chunks': len(ids),
                'mlx_words': t['ref_words'] if 'ref_words' in t else sum(e['ref_words'] for e in ok),
                'speed': sp}
            print(f'| {name} | {cond} | {t["wer"]:.2%} | {t["sub_rate"]:.2%} | {t["del_rate"]:.2%} | {t["ins_rate"]:.2%} | '
                  f'{t["ins_run_words"]} | {t["del_run_words"]} | {same}/{len(ids)} | {sp["mlx"]["rtfx"]}x | {sp["llama"]["rtfx"]}x |')


def tokens(lang, text):
    if lang == 'sr':
        text = ''.join(CYR.get(c, c) for c in text.lower())
    norm = BasicTextNormalizer(remove_diacritics=(lang == 'sr'), split_letters=False)(text)
    return list(norm.replace(' ', '')) if lang == 'ja' else norm.split()


def per_utterance(lang, utterances, hyp):
    """Edit operations charged to reference utterances (insertions to the preceding one)."""
    ref, owner = [], []
    for k, u in enumerate(utterances):
        t = tokens(lang, u)
        ref += t
        owner += [k] * len(t)
    out = [{'err': 0, 'n': 0} for _ in utterances]
    for k in owner:
        out[k]['n'] += 1
    for op in Levenshtein.editops(ref, tokens(lang, hyp)):
        pos = op.src_pos if op.tag != 'insert' else max(op.src_pos - 1, 0)
        out[owner[min(pos, len(owner) - 1)]]['err'] += 1
    return out


def rate(chunks):
    return sum(c['err'] for c in chunks) / max(sum(c['n'] for c in chunks), 1)


def vocab_hits(text):
    t = BasicTextNormalizer(remove_diacritics=True)(''.join(CYR.get(c, c) for c in text.lower())).split()
    return {s: sum(w.startswith(s) for w in t) for s in VOCAB_STEMS}


def fleurs(runs, summary):
    items = json.loads((OUT / 'fleurs' / 'items.json').read_text())
    conds = [c for c in dict.fromkeys(c for c, i in runs['mlx'] if i.startswith('fleurs-'))]
    print('\n## FLEURS: error rate (WER; CER for ja), MLX → llama.cpp, Δ (95% CI over utterances)')
    print('| Condition | ' + ' | '.join(i['id'].replace('fleurs-', '') for i in items) + ' |')
    print('|---|' + '---:|' * len(items))
    summary['fleurs'] = {}
    for cond in conds:
        cells, row = [], {}
        for it in items:
            if not all((cond, it['id']) in runs[b] for b in BACKENDS):
                cells.append('—')
                continue
            lang = 'en' if '+' in it['language'] else it['language']
            per = {b: per_utterance(lang, it['utterances'], runs[b][(cond, it['id'])]['text']) for b in BACKENDS}
            ids = list(range(len(it['utterances'])))
            d = boot(dict(enumerate(per['mlx'])), dict(enumerate(per['llama'])), ids, rate)
            row[it['id']] = {b: {'error': round(rate(per[b]), 4),
                                 'error_check': round(fleurs_error(lang, it['reference'], runs[b][(cond, it['id'])]['text']), 4),
                                 'language_used': runs[b][(cond, it['id'])].get('languageUsed'),
                                 'detected': runs[b][(cond, it['id'])].get('detected'),
                                 **speed(runs[b], cond, [it['id']])} for b in BACKENDS}
            row[it['id']]['delta'] = [round(x, 4) for x in d[:3]]
            if it['id'] == 'fleurs-sr':
                ref = vocab_hits(it['reference'])
                for b in BACKENDS:
                    hyp = vocab_hits(runs[b][(cond, it['id'])]['text'])
                    row[it['id']][b]['vocab_hits'] = sum(min(ref[s], hyp[s]) for s in VOCAB_STEMS)
                    row[it['id']][b]['vocab_total'] = sum(ref.values())
            used = row[it['id']]['mlx']['language_used']
            cells.append(f'{rate(per["mlx"]):.1%} → {rate(per["llama"]):.1%}, {d[0]:+.1%} ({d[1]:+.1%}…{d[2]:+.1%})'
                         + (f' [{used}]' if used not in (None, lang) else ''))
        summary['fleurs'][cond] = row
        print(f'| {cond} | ' + ' | '.join(cells) + ' |')

    sr = [(c, summary['fleurs'][c].get('fleurs-sr')) for c in conds]
    print('\n## Serbian (FLEURS, 5.3 min): error and vocabulary terms recovered')
    print('| Condition | MLX | llama.cpp | Δ (95% CI) | Vocab MLX | Vocab llama | Language used (MLX / llama) |')
    print('|---|---:|---:|---:|---:|---:|---|')
    for c, r in sr:
        if not r:
            continue
        print(f'| {c} | {r["mlx"]["error"]:.1%} | {r["llama"]["error"]:.1%} | {r["delta"][0]:+.1%} ({r["delta"][1]:+.1%}…{r["delta"][2]:+.1%}) | '
              f'{r["mlx"]["vocab_hits"]}/{r["mlx"]["vocab_total"]} | {r["llama"]["vocab_hits"]}/{r["llama"]["vocab_total"]} | '
              f'{r["mlx"]["language_used"]} {r["mlx"]["detected"] or ""} / {r["llama"]["language_used"]} {r["llama"]["detected"] or ""} |')


def perf(summary):
    out = {}
    for b in BACKENDS:
        folder = OUT / f'perf-{b}'
        if not folder.exists():
            continue
        harness = (folder / 'harness.txt').read_text()
        row = {}
        m = re.search(r'(\d+)\s+maximum resident set size', harness)
        row['harness_max_rss_gib'] = round(int(m.group(1)) / 2**30, 2) if m else None
        m = re.search(r'(\d+)\s+peak memory footprint', harness)
        row['harness_peak_footprint_gib'] = round(int(m.group(1)) / 2**30, 2) if m else None
        m = re.search(r'([\d.]+) real', harness)
        row['process_wall_s'] = float(m.group(1)) if m else None
        m = re.search(r'loaded in ([\d.]+)s', harness)
        row['harness_load_s'] = float(m.group(1)) if m else None
        m = re.search(r'mlx peak memory ([\d.]+) GiB', harness)
        row['mlx_peak_memory_gib'] = float(m.group(1)) if m else None
        m = re.search(r'run wall ([\d.]+)s', harness)
        row['decode_wall_s'] = float(m.group(1)) if m else None
        load = folder / 'load.txt'
        if load.exists():
            text = load.read_text()
            m = re.search(r'server ready in ([\d.]+)s', text)
            row['server_load_s'] = float(m.group(1)) if m else None
            m = re.search(r'server peak RSS ([\d.]+) GiB', text)
            row['server_peak_rss_gib'] = float(m.group(1)) if m else None
            m = re.search(r'phys_footprint_peak:\s*([\d.]+)\s*(MB|GB|KB)', text)
            if m:
                row['server_peak_footprint_gib'] = round(float(m.group(1)) / {'KB': 2**20, 'MB': 1024, 'GB': 1}[m.group(2)], 2)
        out[b] = row
    summary['perf'] = out
    print('\n## Process', json.dumps(out, indent=1))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for summary.json (aggregates only)')
    args = parser.parse_args()
    runs = {b: load(b) for b in BACKENDS}
    summary = {}
    english(runs, summary)
    fleurs(runs, summary)
    perf(summary)
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'summary.json').write_text(json.dumps(summary, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
