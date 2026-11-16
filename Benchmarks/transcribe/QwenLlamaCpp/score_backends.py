"""Score MLX (speech-swift) vs llama.cpp runs of Qwen3-ASR 1.7B on identical windows.

AMI: WER against the human reference (CloudSTT normalizer), paired chunk bootstrap.
Meetings: CloudSTT's vendor consensus is not regenerated here, so meetings report how much the
two backends disagree (llama.cpp scored against MLX), plus inserted/deleted runs.
FLEURS: score_language.fleurs_error per track (CER for Japanese, Cyrillic folded to Latin for
Serbian); the 95% intervals bootstrap the 30 reference utterances of each track.
Only aggregates are written to --results.

TIER=0.6b scores runs-<backend>-06b.jsonl (merge-15-v14 and engine-15) and adds:
- token-cap hits: windows whose re-tokenized text reaches the app's cap;
- agreement with Qwen3-ASR 1.7B's shipped text (PROXY_RUNS, PROXY_CONDITION) as a stronger
  model's stand-in reference on meetings, which have no human transcript;
- attribution: AMI cpWER and speaker-memory turns from CoreML-aligned words
  (aligned-coreml-int8-merge-15-v14-<backend>06b.jsonl from `qwen-span-harness align`).
"""
import argparse
import json
import os
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

TIER = os.environ.get('TIER', '1.7b')
SUFFIX = '-06b' if TIER == '0.6b' else ''
LAYOUTS = ['merge-15-v14', 'engine-15'] if TIER == '0.6b' else ['merge-60-off-v14', 'engine-15']

BOOT = 2000
BACKENDS = ['mlx', 'llama']
VOCAB_STEMS = ['moldavij', 'japan', 'bozic', 'isus', 'wifi', 'egipcan', 'irak', 'argentin', 'dzordz', 'bus']


def load(backend):
    runs = {}
    path = OUT / f'runs-{backend}{SUFFIX}.jsonl'
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
    for cond in LAYOUTS:
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
        for cond in LAYOUTS:
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
        folder = OUT / f'perf-{b}{SUFFIX}'
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


def cap_hits(runs, summary):
    """Windows whose re-tokenized text reaches min(768, max(128, 18 * seconds)) tokens."""
    from transformers import AutoTokenizer
    model_dir = OUT / ('qwen06/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit' if TIER == '0.6b'
                       else 'models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit')
    tok = AutoTokenizer.from_pretrained(str(model_dir))
    out = {}
    for b in BACKENDS:
        for (cond, i), r in runs[b].items():
            row = out.setdefault(cond, {}).setdefault(b, {'windows': 0, 'cap_hits': 0, 'peak_share': 0.0})
            for w in r['windows']:
                n = len(tok.encode(w['text'], add_special_tokens=False))
                row['windows'] += 1
                row['cap_hits'] += n + 1 >= w['cap']
                row['peak_share'] = round(max(row['peak_share'], n / w['cap']), 3)
    summary['cap_hits'] = out
    print('\n## Token-cap hits (windows whose output reaches the cap)')
    for cond, by in out.items():
        print(f'{cond}: ' + ', '.join(f'{b} {v["cap_hits"]}/{v["windows"]} (peak {v["peak_share"]:.0%})' for b, v in by.items()))


def proxy(runs, summary):
    """Meetings and AMI scored against Qwen3-ASR 1.7B's shipped text, a stronger model's stand-in."""
    path = Path(os.environ.get('PROXY_RUNS', OUT / 'runs.jsonl'))
    cond_ref = os.environ.get('PROXY_CONDITION', 'merge-30-off-v14')
    if not path.exists():
        return
    ref = {}
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if r['condition'] == cond_ref:
            ref[r['id']] = words(r['text'])
    manifest = load_manifest()
    summary['vs_17b'] = {}
    print(f'\n## Agreement with Qwen3-ASR 1.7B ({cond_ref}) as the reference')
    print('| Set | Layout | MLX | llama.cpp | Δ (95% CI) | Ins-run words MLX / llama |')
    print('|---|---|---:|---:|---:|---:|')
    for name in ['ami', 'meetings']:
        ids = [r['id'] for r in manifest if r['set'] == name and r['id'] in ref and ref[r['id']]]
        for cond in LAYOUTS:
            if not all((cond, i) in runs[b] for b in BACKENDS for i in ids):
                continue
            per = {b: {i: errors(ref[i], words(runs[b][(cond, i)]['text'])) for i in ids} for b in BACKENDS}
            d = boot(per['mlx'], per['llama'], ids, wer)
            t = {b: summarize(list(per[b].values())) for b in BACKENDS}
            summary['vs_17b'][f'{name}/{cond}'] = {b: {'wer': round(t[b]['wer'], 5), 'ins_run_words': t[b]['ins_run_words']}
                                                   for b in BACKENDS} | {'delta': [round(x, 5) for x in d[:3]]}
            print(f'| {name} | {cond} | {t["mlx"]["wer"]:.2%} | {t["llama"]["wer"]:.2%} | '
                  f'{d[0]:+.2%} ({d[1]:+.2%}…{d[2]:+.2%}) | {t["mlx"]["ins_run_words"]} / {t["llama"]["ins_run_words"]} |')


def attribution(runs, summary):
    """AMI cpWER and speaker-memory turns from CoreML-aligned words of each backend's text."""
    from score_align import TOLERANCE, clipped_turns, speaker_at, supported  # noqa: E402
    from score_coreml import attributed, pieces  # noqa: E402
    from score_regions import cp_errors  # noqa: E402
    from make_region_jobs import recordings  # noqa: E402
    from score_spans import DATA  # noqa: E402
    cond = LAYOUTS[0]
    files = {b: OUT / f'aligned-coreml-int8-{cond}-{b}{SUFFIX.strip("-")}.jsonl' for b in BACKENDS}
    if not all(f.exists() for f in files.values()) or not (OUT / 'turns.json').exists():
        return
    manifest = load_manifest()
    recording = recordings(manifest)
    turns_by_file = json.loads((OUT / 'turns.json').read_text())
    turns = {r['id']: clipped_turns(turns_by_file[recording(r)], r['start'], r['end']) for r in manifest}
    ami = [r for r in manifest if r['set'] == 'ami']
    ids = [r['id'] for r in ami]
    ref_streams = {}
    for row in ami:
        utts = json.loads((DATA / 'source' / 'ami' / f'{row["source"]}.utterances.json').read_text())
        inside = [u for u in utts if row['start'] - 0.01 <= u['begin'] and u['end'] <= row['end'] + 0.01]
        streams = {}
        for u in sorted(inside, key=lambda u: (u['begin'], u['end'])):
            streams.setdefault(u['speaker'], []).append(u['text'])
        ref_streams[row['id']] = {k: words(' '.join(v)) for k, v in streams.items()}
    cp, rows = {}, {}
    for b in BACKENDS:
        aligned = {json.loads(l)['id']: json.loads(l) for l in files[b].read_text().splitlines()}
        text = lambda i: [w for w in runs[b][(cond, i)]['windows'] if w['text']]
        cp[b] = {}
        for i in ids:
            streams = {}
            for window in attributed(text(i), aligned[i], turns[i]):
                for surface, spk in window:
                    streams.setdefault(spk, []).append(surface)
            cp[b][i] = {'err': cp_errors(ref_streams[i], {k: words(' '.join(v)) for k, v in streams.items()}),
                        'n': sum(len(v) for v in ref_streams[i].values())}
        support = {'ami': [0, 0], 'meetings': [0, 0]}
        for r in manifest:
            a, e = supported(turns[r['id']], pieces(text(r['id']), aligned[r['id']], turns[r['id']]))
            support[r['set']][0] += a
            support[r['set']][1] += e
        fails = sum(1 for x in aligned.values() for w in x.get('info', []) if w.get('error'))
        rows[b] = {'cpwer': round(rate(list(cp[b].values())), 5), 'support': support, 'align_failures': fails}
    d = boot(cp['mlx'], cp['llama'], ids, rate)
    rows['delta'] = [round(x, 5) for x in d[:3]]
    summary['attribution'] = {cond: rows}
    print(f'\n## Attribution ({cond}, CoreML INT8 aligner): AMI cpWER, speaker memory')
    for b in BACKENDS:
        s = rows[b]['support']
        print(f'{b}: cpWER {rows[b]["cpwer"]:.2%}, speaker memory AMI {s["ami"][0]}/{s["ami"][1]}, '
              f'meetings {s["meetings"][0]}/{s["meetings"][1]}, align failures {rows[b]["align_failures"]}')
    print(f'Δ llama − MLX {d[0]:+.2%} ({d[1]:+.2%}…{d[2]:+.2%})')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for summary.json (aggregates only)')
    args = parser.parse_args()
    runs = {b: load(b) for b in BACKENDS}
    summary = {}
    english(runs, summary)
    if TIER == '0.6b':
        proxy(runs, summary)
        attribution(runs, summary)
        cap_hits(runs, summary)
    fleurs(runs, summary)
    perf(summary)
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'summary.json').write_text(json.dumps(summary, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
