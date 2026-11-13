"""Judges that pick one of two transcripts per decode window, scored against the oracle.

Reads windows.jsonl from score.py. A pair is <qwen condition>,<whisper condition>; only windows
with a reference count. Judges:
  - always A / always B, and the per-window oracle;
  - rule: keep A unless A's text is in an unexpected language or script and B's is not;
  - logistic: a small logistic regression on window features, trained leave-one-item-out;
  - llm: a local model asked "A or B" at temperature 0, P(B) read from the answer token's
    log-probabilities and averaged over both presentation orders (llm.jsonl cache, see --llm).
Usage: judges.py <A>,<B> [--llm http://127.0.0.1:PORT]
"""
import json
import math
import os
import subprocess
import sys
import unicodedata
from pathlib import Path

import numpy as np
import requests

sys.path.insert(0, str(Path(__file__).parent))
import score  # noqa: E402

OUT = Path(os.environ['DUAL_ASR_OUT'])
EXPECTED = {'hr', 'bs', 'sr', 'en'}
PROMPT = (
    'Two speech recognizers transcribed the same short stretch of a meeting. The participants speak '
    'Serbian and sometimes English. Which transcript is more likely to be exactly what was said? Prefer '
    'the one whose words and language fit the conversation. Watch for words from unrelated languages, '
    'translation into another language, repeated phrases, and text that seems invented.\n\n'
    'Before: {before}\n\nA: {a}\n\nB: {b}\n\nAfter: {after}\n\nAnswer with the single letter A or B.')


def features(row, a, b, lang):
    def side(text):
        letters = score.scripts(text)
        total = max(1, sum(letters.values()))
        code, conf = lang.get(text, ('', 0.0))
        unexpected = 1.0 if (len(text.split()) >= 3 and conf >= 0.5 and code not in EXPECTED) else 0.0
        return [unexpected, 1 - letters['LATIN'] / total, len(text.split())]
    ta, tb = row[a]['text'], row[b]['text']
    duration = max(0.5, row['end'] - row['start'])
    fa, fb = side(ta), side(tb)
    agree = score.errors(score.words(ta), score.words(tb)) / max(1, len(score.words(ta)), len(score.words(tb)))
    lp = row[b].get('avgLogprob')
    nsp = row[b].get('noSpeechProb')
    cr = row[b].get('compressionRatio')
    return [fa[0], fb[0], fa[1], fb[1], fa[2] / duration, fb[2] / duration, agree,
            lp if lp is not None else -1.0, nsp if nsp is not None else 0.5, min(cr, 4.0) if cr is not None else 1.5]


def fit_logistic(x, y, l2=1.0, steps=2000, lr=0.1):
    mu, sd = x.mean(0), x.std(0) + 1e-6
    z = (x - mu) / sd
    w, b0 = np.zeros(z.shape[1]), 0.0
    for _ in range(steps):
        p = 1 / (1 + np.exp(-(z @ w + b0)))
        w -= lr * (z.T @ (p - y) / len(y) + l2 * w / len(y))
        b0 -= lr * float(np.mean(p - y))
    return lambda q: 1 / (1 + np.exp(-(((q - mu) / sd) @ w + b0)))


def llm_prob(url, before, ta, tb, after, cache):
    key = json.dumps([before, ta, tb, after], ensure_ascii=False)
    if key in cache:
        return cache[key]
    probs = []
    for first, second, b_letter in ((ta, tb, 'B'), (tb, ta, 'A')):
        body = {'messages': [{'role': 'user', 'content': PROMPT.format(before=before or '-', a=first or '(empty)',
                                                                        b=second or '(empty)', after=after or '-')}],
                'max_tokens': 1, 'temperature': 0, 'logprobs': True, 'top_logprobs': 10,
                'chat_template_kwargs': {'enable_thinking': False}}
        data = requests.post(f'{url}/v1/chat/completions', json=body, timeout=300).json()
        top = data['choices'][0]['logprobs']['content'][0]['top_logprobs']
        weights = {'A': 0.0, 'B': 0.0}
        for t in top:
            letter = t['token'].strip().upper()
            if letter in weights:
                weights[letter] += math.exp(t['logprob'])
        total = weights['A'] + weights['B']
        probs.append(weights[b_letter] / total if total else 0.5)
    cache[key] = sum(probs) / 2
    with open(OUT / 'llm.jsonl', 'a') as f:
        f.write(json.dumps({'key': key, 'p': cache[key]}, ensure_ascii=False) + '\n')
    return cache[key]


def main():
    a, b = sys.argv[1].split(',')
    url = sys.argv[sys.argv.index('--llm') + 1] if '--llm' in sys.argv else None
    table = [json.loads(l) for l in (OUT / 'windows.jsonl').read_text().splitlines()]
    rows = [r for r in table if r['ref'] is not None and a in r and b in r and 'errors' in r[a] and 'errors' in r[b]]
    lang = score.language([r[c]['text'] for r in rows for c in (a, b) if len(r[c]['text'].split()) >= 3])
    items = sorted({r['id'] for r in rows})
    x = np.array([features(r, a, b, lang) for r in rows], dtype=float)
    ea = np.array([r[a]['errors'] for r in rows])
    eb = np.array([r[b]['errors'] for r in rows])
    y = (eb < ea).astype(float)
    ref_words = {r['id']: 0 for r in rows}
    for r in rows:
        ref_words[r['id']] += len(score.words(r['ref']))

    picks = {'always A': np.zeros(len(rows)), 'always B': np.ones(len(rows)), 'oracle': y.copy()}
    picks['rule'] = np.array([1.0 if (f[0] == 1 or f[2] > 0.2) and f[1] == 0 and f[3] <= 0.2 else 0.0 for f in x])
    logistic = np.zeros(len(rows))
    for item in items:
        train = np.array([r['id'] != item for r in rows])
        test = ~train
        decided = train & (ea != eb)
        if decided.sum() >= 4 and len(set(y[decided])) == 2:
            logistic[test] = (fit_logistic(x[decided], y[decided])(x[test]) > 0.5).astype(float)
    picks['logistic'] = logistic
    if url:
        cache_path = OUT / 'llm.jsonl'
        cache = {}
        if cache_path.exists():
            for line in cache_path.read_text().splitlines():
                entry = json.loads(line)
                cache[entry['key']] = entry['p']
        by_item = {}
        for i, r in enumerate(table):
            by_item.setdefault(r['id'], []).append((r['window'], i))
        llm = np.zeros(len(rows))
        for i, r in enumerate(rows):
            neighbours = {w: table[j] for w, j in by_item[r['id']]}
            before = neighbours.get(r['window'] - 1, {}).get(a, {}).get('text', '')
            after = neighbours.get(r['window'] + 1, {}).get(a, {}).get('text', '')
            llm[i] = 1.0 if llm_prob(url, before, r[a]['text'], r[b]['text'], after, cache) > 0.5 else 0.0
        picks['llm'] = llm

    groups = [('FLEURS Serbian/Croatian/Bosnian', ('fleurs-sr', 'fleurs-hr', 'fleurs-bs')),
              ('FLEURS code-switched', ('fleurs-sr+en', 'fleurs-en+sr')), ('Meeting (cloud ref)', ('meeting-',))]
    print(f'A = {a}, B = {b}; WER % per judge (windows choosing B in brackets)')
    print(f'{"judge":12s}' + ''.join(f'{g:>36s}' for g, _ in groups))
    for name, pick in picks.items():
        line = f'{name:12s}'
        for g, prefixes in groups:
            mask = np.array([any(r['id'].startswith(p) for p in prefixes) for r in rows])
            if not mask.any():
                line += f'{"-":>36s}'
                continue
            err = float(np.where(pick[mask] > 0.5, eb[mask], ea[mask]).sum())
            words = sum(ref_words[i] for i in {r['id'] for r, m in zip(rows, mask) if m})
            line += f'{100 * err / words:>28.1f} [{int(pick[mask].sum()):2d}/{int(mask.sum()):2d}]'
        print(line)


if __name__ == '__main__':
    main()
