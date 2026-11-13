"""Score language handling: pinned vs per-window auto vs detect-once vs vote-and-pin.

English (meetings + AMI): runs are per benchmark chunk, but the app decides per track, so
track-level strategies are emulated from the auto and pinned-English runs. A window
re-decoded pinned to English is exactly the pinned run's window, because decoding is greedy
and the windows are identical. Window languages come from Apple's recognizer through
`nlid` (compile nlid.swift into SPAN_BENCH_OUT). FLEURS items are whole tracks, so
their `vote` rows are real runs.
"""
import argparse
import json
import subprocess
import sys
import unicodedata
from pathlib import Path

from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import BasicTextNormalizer

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from score_spans import OUT, REPORT_SYSTEMS, paired  # noqa: E402
from common import SYSTEMS, load_manifest, load_output  # noqa: E402  (CloudSTT)
from score import consensus, errors, family_weights, summarize, words  # noqa: E402  (CloudSTT)

QWEN = {'zh', 'en', 'yue', 'ar', 'de', 'fr', 'es', 'pt', 'id', 'it', 'ko', 'ru', 'th', 'vi', 'ja', 'tr', 'hi', 'ms',
        'nl', 'sv', 'da', 'fi', 'pl', 'cs', 'fil', 'fa', 'el', 'hu', 'mk', 'ro'}
SCRIPT = {'ja': {'HAN', 'KANA'}, 'zh': {'HAN'}, 'yue': {'HAN'}, 'ru': {'CYRILLIC'}, 'mk': {'CYRILLIC'},
          'ko': {'HANGUL'}, 'hi': {'DEVANAGARI'}, 'ar': {'ARABIC'}, 'fa': {'ARABIC'}, 'th': {'THAI'}, 'el': {'GREEK'}}
CYR = dict(zip('абвгдђежзијклљмнњопрстћуфхцчџш',
               ['a', 'b', 'v', 'g', 'd', 'đ', 'e', 'ž', 'z', 'i', 'j', 'k', 'l', 'lj', 'm', 'n', 'nj', 'o', 'p', 'r',
                's', 't', 'ć', 'u', 'f', 'h', 'c', 'č', 'dž', 'š']))
CACHE = OUT / 'nlid.json'
nl = json.loads(CACHE.read_text()) if CACHE.exists() else {}


def load(path):
    out = {}
    if (OUT / path).exists():
        for line in (OUT / path).read_text().splitlines():
            r = json.loads(line)
            out[(r['condition'], r['id'])] = r
    return out


def classify(texts):
    todo = sorted({t for t in texts if t not in nl})
    if todo:
        result = subprocess.run([str(OUT / 'nlid')], input=json.dumps(todo), capture_output=True, text=True, check=True)
        nl.update(dict(zip(todo, json.loads(result.stdout))))
    return {t: (nl[t][0].split('-')[0], float(nl[t][1])) for t in texts}


def script(text):
    counts = {}
    for ch in text:
        if ch.isalpha():
            name = unicodedata.name(ch, '')
            key = 'HAN' if 'CJK' in name else 'KANA' if 'HIRAGANA' in name or 'KATAKANA' in name else name.split(' ')[0]
            counts[key] = counts.get(key, 0) + 1
    return max(counts, key=counts.get) if counts else None


def vote(texts):
    """TranscriptLanguageVote: length-weighted shares over windows of 3+ words, confidence >= 0.5."""
    texts = [t for t in texts if len(t.split()) >= 3]
    shares, total = {}, 0
    for t, (lang, conf) in classify(texts).items():
        if conf >= 0.5:
            shares[lang] = shares.get(lang, 0) + len(t) * texts.count(t)
            total += len(t) * texts.count(t)
    return {k: v / total for k, v in shares.items()} if total else {}


def strategies(groups, auto, pinned_by_lang):
    out = {k: {} for k in ['auto', 'script repair', 'minority repair', 'vote and pin (shipped)']}
    redecoded = {k: 0 for k in out}
    for ids in groups.values():
        shares = vote([w['text'] for i in ids for w in auto[i]['windows'] if w['text']])
        dom = max(shares, key=shares.get) if shares else None
        pinned = pinned_by_lang.get(dom) if dom in QWEN else None
        present = {l for l, v in shares.items() if v >= 0.2}
        scripts = set().union(*[SCRIPT.get(l, {'LATIN'}) for l in present]) if present else {'LATIN'}
        pin = pinned is not None and shares[dom] >= 0.8
        for i in ids:
            out['auto'][i] = auto[i]['text']
            out['vote and pin (shipped)'][i] = pinned[i]['text'] if pin else auto[i]['text']
            redecoded['vote and pin (shipped)'] += len(auto[i]['windows']) if pin else 0
            for name in ['script repair', 'minority repair']:
                parts = []
                for k, w in enumerate(auto[i]['windows']):
                    text, bad = w['text'], False
                    if pinned and text:
                        s = script(text)
                        bad = s is not None and s not in scripts
                        if name == 'minority repair' and not bad and len(text.split()) >= 3:
                            lang, c = classify([text])[text]
                            bad = c >= 0.8 and lang not in present
                    if bad:
                        redecoded[name] += 1
                        text = pinned[i]['windows'][k]['text']
                    if text:
                        parts.append(text)
                out[name][i] = ' '.join(parts)
    return out, redecoded


def english(runs, auto_cond, pinned_cond, title, summary):
    manifest = load_manifest()
    auto = {r['id']: runs[(auto_cond, r['id'])] for r in manifest}
    pinned = {r['id']: runs[(pinned_cond, r['id'])] for r in manifest}
    groups = {}
    for r in manifest:
        groups.setdefault((r['source'], r['track']), []).append(r['id'])
    texts, redecoded = strategies(groups, auto, {'en': pinned})
    texts['pinned en'] = {i: pinned[i]['text'] for i in pinned}
    meet = [r for r in manifest if r['set'] == 'meetings'
            and all((load_output(s, r['id']) or {}).get('text') is not None for s in REPORT_SYSTEMS)]
    ami = [r for r in manifest if r['set'] == 'ami']
    voters = [v for v in REPORT_SYSTEMS if SYSTEMS[v][0] != 'qwen' and SYSTEMS[v][1] != 'production']
    refs = {r['id']: consensus({v: words(load_output(v, r['id'])['text']) for v in voters}, family_weights(voters))
            for r in meet}
    refs.update({r['id']: words(r['reference']) for r in ami})
    pm = {k: {r['id']: errors(refs[r['id']], words(v[r['id']])) for r in meet} for k, v in texts.items()}
    pa = {k: {r['id']: errors(refs[r['id']], words(v[r['id']])) for r in ami} for k, v in texts.items()}
    print(f'\n## {title}')
    print('| Strategy | Meetings | Δ vs auto (95% CI) | AMI WER | Invented-run words | Wrong-script windows | Windows re-decoded |')
    print('|---|---:|---:|---:|---:|---:|---:|')
    summary[title] = {}
    for k in texts:
        d = None if k == 'auto' else paired(pm, k, 'auto', [r['id'] for r in meet])[:3]
        inv = sum(e['ins_run_words'] for e in pm[k].values()) + sum(e['ins_run_words'] for e in pa[k].values())
        wrong = sum(1 for i in texts[k] for w in ([] if k != 'auto' else auto[i]['windows'])
                    if w['text'] and script(w['text']) not in (None, 'LATIN'))
        row = {'meetings': summarize(list(pm[k].values()))['wer'], 'ami_wer': summarize(list(pa[k].values()))['wer'],
               'delta_vs_auto': d, 'invented_run_words': inv, 'windows_redecoded': redecoded.get(k)}
        summary[title][k] = {**row, 'delta_vs_auto': None if d is None else [round(100 * x, 2) for x in d]}
        print(f'| {k} | {row["meetings"]:.2%} | ' + ('—' if d is None else '{:+.2f} ({:+.2f}…{:+.2f})'.format(*[100 * x for x in d]))
              + f' | {row["ami_wer"]:.2%} | {inv} | {wrong if k == "auto" else "—"} | {redecoded.get(k, "—")} |')


def fleurs_error(lang, ref, hyp):
    if lang == 'sr':
        ref, hyp = [''.join(CYR.get(c, c) for c in t.lower()) for t in (ref, hyp)]
    norm = BasicTextNormalizer(remove_diacritics=(lang == 'sr'), split_letters=False)
    r, h = norm(ref), norm(hyp)
    if lang == 'ja':
        r, h = r.replace(' ', ''), h.replace(' ', '')
        return Levenshtein.distance(r, h) / max(len(r), 1)
    r, h = r.split(), h.split()
    return Levenshtein.distance(r, h) / max(len(r), 1)


def fleurs(runs, conditions, title, summary):
    items = json.loads((OUT / 'fleurs' / 'items.json').read_text())
    print(f'\n## {title} (WER; CER for ja; language passed in brackets)')
    print('| Condition | ' + ' | '.join(i['id'].replace('fleurs-', '') for i in items) + ' |')
    print('|---|' + '---:|' * len(items))
    summary[title] = {}
    for label, cond in conditions:
        cells, row = [], {}
        for i in items:
            r = runs.get((cond, i['id']))
            if not r:
                cells.append('—')
                continue
            lang = 'en' if '+' in i['language'] else i['language']
            e = fleurs_error(lang, i['reference'], r['text'])
            row[i['id']] = {'error': round(e, 4), 'language_used': r.get('languageUsed'), 'detected': r.get('detected')}
            cells.append(f'{e:.1%} ({r.get("languageUsed") or "auto"})')
        summary[title][label] = row
        print(f'| {label} | ' + ' | '.join(cells) + ' |')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', default=None, help='folder for language-summary.json (aggregates only)')
    args = parser.parse_args()
    summary = {}
    r17, r06 = load('runs.jsonl'), load('runs-06b.jsonl')
    english(r17, 'merge-60-off-v14-auto', 'merge-60-off-v14', '1.7B, merged ≤60 s (word-attribution path), English', summary)
    english(r17, 'engine-15-auto', 'engine-15', '1.7B, ≤14 s (plain path), English', summary)
    english(r06, 'merge-15-v14-auto', 'merge-15-v14', '0.6B, merged ≤15 s, English', summary)
    modes = [('oracle code', 'oracle'), ('oracle name', 'oracle-name'), ('auto', 'auto'), ('detect once', 'detect'),
             ('vote and pin (shipped)', 'vote')]
    fleurs(load('runs-fleurs.jsonl'), [(f'{a}, merged ≤60 s', f'm60-{b}') for a, b in modes]
           + [(f'{a}, ≤14 s', f'e15-{b}') for a, b in modes if b != 'oracle-name'], '1.7B, FLEURS', summary)
    fleurs(load('runs-fleurs-06b.jsonl'), [(f'{a}, merged ≤15 s', f'm15-{b}') for a, b in modes if b != 'oracle-name'],
           '0.6B, FLEURS', summary)
    CACHE.write_text(json.dumps(nl, ensure_ascii=False))
    if args.results:
        out = ROOT / args.results
        out.mkdir(parents=True, exist_ok=True)
        (out / 'language-summary.json').write_text(json.dumps(summary, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
