"""Score Qwen / Whisper conditions per decode window, and the best-of-two oracle.

References: FLEURS utterances assigned to windows by midpoint; meeting windows use a cloud
reference (refs.jsonl, see make_refs.py) when present. Text is transliterated from Serbian
Cyrillic to Latin, lowercased and stripped of punctuation (Whisper's BasicTextNormalizer,
diacritics kept), so script choice alone never counts as an error. `windows.jsonl` keeps the
per-window table for judge experiments.
Usage: score.py [conditionA,conditionB ...]   (pairs for the oracle)
"""
import collections
import json
import os
import subprocess
import sys
import unicodedata
from pathlib import Path

from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import BasicTextNormalizer

OUT = Path(os.environ['DUAL_ASR_OUT'])
CYR = dict(zip('абвгдђежзијклљмнњопрстћуфхцчџш',
               ['a', 'b', 'v', 'g', 'd', 'đ', 'e', 'ž', 'z', 'i', 'j', 'k', 'l', 'lj', 'm', 'n', 'nj', 'o', 'p', 'r',
                's', 't', 'ć', 'u', 'f', 'h', 'c', 'č', 'dž', 'š']))
normalizer = BasicTextNormalizer()
EXPECTED = {'hr', 'bs', 'sr', 'en'}
nl_cache_path = OUT / 'nlid.json'
nl_cache = json.loads(nl_cache_path.read_text()) if nl_cache_path.exists() else {}


def words(text):
    return normalizer(''.join(CYR.get(c, c) for c in text.lower())).split()


def errors(ref, hyp):
    return Levenshtein.distance(ref, hyp)


def language(texts):
    todo = sorted({t for t in texts if t not in nl_cache})
    if todo:
        out = subprocess.run([str(OUT / 'nlid')], input=json.dumps(todo), capture_output=True, text=True, check=True)
        nl_cache.update(dict(zip(todo, json.loads(out.stdout))))
        nl_cache_path.write_text(json.dumps(nl_cache, ensure_ascii=False))
    return {t: (nl_cache[t][0].split('-')[0], float(nl_cache[t][1])) for t in texts}


def scripts(text):
    counts = collections.Counter()
    for ch in text:
        if ch.isalpha():
            name = unicodedata.name(ch, '')
            counts['CJK' if 'CJK' in name else name.split(' ')[0]] += 1
    return counts


def load_runs():
    runs = {}
    for line in (OUT / 'runs.jsonl').read_text().splitlines():
        r = json.loads(line)
        runs[(r['condition'], r['id'])] = r
    return runs


def references(runs):
    """(item id, window index) -> reference text, for windows that have one."""
    refs = {}
    fleurs = {i['id']: i for i in json.loads((OUT / 'fleurs/items.json').read_text())}
    windows = {}
    for (condition, item), r in runs.items():
        windows.setdefault(item, [(w['start'], w['end']) for w in r['windows']])
    for item, spans in windows.items():
        if item in fleurs:
            parts = collections.defaultdict(list)
            for u in fleurs[item]['utterances']:
                mid = (u['start'] + u['end']) / 2
                k = min(range(len(spans)), key=lambda i: 0 if spans[i][0] <= mid <= spans[i][1]
                        else min(abs(mid - spans[i][0]), abs(mid - spans[i][1])))
                parts[k].append(u['text'])
            for k in range(len(spans)):
                refs[(item, k)] = ' '.join(parts.get(k, []))
    if (OUT / 'refs.jsonl').exists():
        for line in (OUT / 'refs.jsonl').read_text().splitlines():
            r = json.loads(line)
            # FLEURS windows keep their human reference; cloud rows there only calibrate.
            if r.get('text') is None or not r['id'].startswith('meeting-'):
                continue
            # Gemini Flash turns short Serbian clips into Russian and truncates some windows, so
            # meeting windows count only when at least 5 s long, with 5+ reference words that are
            # mostly in Latin script.
            letters = scripts(r['text'])
            latin = letters['LATIN'] / max(1, sum(letters.values()))
            if r['end'] - r['start'] >= 5 and len(words(r['text'])) >= 5 and latin >= 0.8:
                refs[(r['id'], r['window'])] = r['text']
    return refs


GROUPS = [('Serbian', ['fleurs-sr']), ('Croatian', ['fleurs-hr']), ('Bosnian', ['fleurs-bs']),
          ('Mostly Serbian + English', ['fleurs-sr+en']), ('Mostly English + Serbian', ['fleurs-en+sr']),
          ('Meeting (cloud ref)', ['meeting-'])]


def in_group(item, prefixes):
    return any(item == p or (p.endswith('-') and item.startswith(p)) for p in prefixes)


def main():
    runs = load_runs()
    refs = references(runs)
    conditions = sorted({c for c, _ in runs}, key=lambda c: (c[0], c))
    items = sorted({i for _, i in runs})
    texts = [w['text'] for r in runs.values() for w in r['windows'] if len(w['text'].split()) >= 3]
    lang = language(texts)
    table = []
    for item in items:
        n = max(len(r['windows']) for (c, i), r in runs.items() if i == item)
        for k in range(n):
            row = {'id': item, 'window': k, 'ref': refs.get((item, k))}
            if row['ref'] is not None and item.startswith('meeting-'):
                # A cloud reference far shorter than every local transcript was truncated.
                lengths = sorted(len(words(r['windows'][k]['text'])) for (c, i), r in runs.items()
                                 if i == item and k < len(r['windows']))
                if lengths and len(words(row['ref'])) < 0.5 * lengths[len(lengths) // 2]:
                    row['ref'] = None
            for c in conditions:
                r = runs.get((c, item))
                if r and k < len(r['windows']):
                    w = r['windows'][k]
                    row.update(start=w['start'], end=w['end'])
                    row[c] = {key: w.get(key) for key in ('text', 'avgLogprob', 'noSpeechProb', 'compressionRatio', 'detected')}
                    if row['ref'] is not None:
                        row[c]['errors'] = errors(words(row['ref']), words(w['text']))
            table.append(row)
    with open(OUT / 'windows.jsonl', 'w') as f:
        for row in table:
            f.write(json.dumps(row, ensure_ascii=False) + '\n')

    print('WER (%) by condition; ref words in brackets')
    header = f'{"condition":14s}' + ''.join(f'{g[:24]:>26s}' for g, _ in GROUPS) + f'{"stray win":>11s}{"non-Latin":>11s}'
    print(header)
    for c in conditions:
        line = f'{c:14s}'
        for g, prefixes in GROUPS:
            rows = [r for r in table if in_group(r['id'], prefixes) and r['ref'] is not None and c in r]
            ref_words = sum(len(words(r['ref'])) for r in rows)
            err = sum(r[c]['errors'] for r in rows)
            line += f'{(100 * err / ref_words if ref_words else float("nan")):>19.1f} [{ref_words:4d}]'
        hyps = [r[c]['text'] for r in table if c in r]
        stray = sum(1 for t in hyps if t in lang and lang[t][1] >= 0.5 and lang[t][0] not in EXPECTED)
        letters = sum((scripts(t) for t in hyps), collections.Counter())
        non_latin = 1 - letters['LATIN'] / max(1, sum(letters.values()))
        line += f'{stray:>11d}{100 * non_latin:>10.1f}%'
        print(line)
    for pair in sys.argv[1:]:
        a, b = pair.split(',')
        print(f'\nOracle best of {a} / {b} per window:')
        for g, prefixes in GROUPS:
            rows = [r for r in table if in_group(r['id'], prefixes) and r['ref'] is not None and a in r and b in r]
            ref_words = sum(len(words(r['ref'])) for r in rows)
            if not ref_words:
                continue
            ea, eb = sum(r[a]['errors'] for r in rows), sum(r[b]['errors'] for r in rows)
            eo = sum(min(r[a]['errors'], r[b]['errors']) for r in rows)
            picks = sum(1 for r in rows if r[b]['errors'] < r[a]['errors'])
            print(f'  {g:26s} {a} {100 * ea / ref_words:5.1f}  {b} {100 * eb / ref_words:5.1f}  '
                  f'oracle {100 * eo / ref_words:5.1f}  ({picks}/{len(rows)} windows prefer {b})')


if __name__ == '__main__':
    main()
