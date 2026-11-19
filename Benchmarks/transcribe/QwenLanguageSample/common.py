"""Shared loading, the engine's vote rules, and text scoring for the QwenLanguageSample scripts."""
import json
import os
import unicodedata
from pathlib import Path

from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import BasicTextNormalizer, EnglishTextNormalizer

OUT = Path(os.environ.get('QLS_OUT', '/private/tmp/lokalbot-qwen-sample'))
# QwenASREngine.supportedLanguages; the engine also pins Croatian for Serbian, Bosnian and Montenegrin.
QWEN = {'zh', 'en', 'yue', 'ar', 'de', 'fr', 'es', 'pt', 'id', 'it', 'ko', 'ru', 'th', 'vi', 'ja', 'tr', 'hi', 'ms',
        'nl', 'sv', 'da', 'fi', 'pl', 'cs', 'fil', 'fa', 'el', 'hu', 'mk', 'ro', 'hr'}
# QwenWordAligner.supportedLanguages.
ALIGNER = {'zh', 'en', 'yue', 'fr', 'de', 'it', 'ja', 'ko', 'pt', 'ru', 'es'}
CER_LANGUAGES = {'ja', 'zh'}
BCMS = {'sr', 'hr', 'bs'}
CYR = dict(zip('абвгдђежзијклљмнњопрстћуфхцчџш',
               ['a', 'b', 'v', 'g', 'd', 'đ', 'e', 'ž', 'z', 'i', 'j', 'k', 'l', 'lj', 'm', 'n', 'nj', 'o', 'p', 'r',
                's', 't', 'ć', 'u', 'f', 'h', 'c', 'č', 'dž', 'š']))
SCRIPTS = {'ru': {'CYRILLIC'}, 'sr': {'CYRILLIC'}, 'ja': {'HAN', 'KANA'}, 'zh': {'HAN'}}
basic = BasicTextNormalizer()
english = EnglishTextNormalizer({})


def runs(path=None):
    """(id, layout, mode) -> record; a later line replaces an earlier one."""
    out = {}
    for line in Path(path or OUT / 'runs.jsonl').read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            out[(r['id'], r['layout'], r['mode'])] = r
    return out


def items():
    found = {i['id']: i for i in json.loads((OUT / 'items.json').read_text())}
    if (OUT / 'meetings.json').exists():
        found.update({m['id']: {**m, 'languages': [], 'reference': None}
                      for m in json.loads((OUT / 'meetings.json').read_text())})
    return found


def vote(windows):
    """TranscriptLanguageVote.dominant over these auto windows (aliases already applied per window):
    the winning code, its share, and how many windows had text (pinnedLanguage needs two)."""
    weights, total = {}, 0
    for w in windows:
        if w.get('vote'):
            weights[w['vote']] = weights.get(w['vote'], 0) + w['weight']
            total += w['weight']
    texts = sum(1 for w in windows if w['text'])
    if not total:
        return None, 0.0, texts
    code = max(weights, key=weights.get)
    return code, weights[code] / total, texts


def pinned(windows, share=0.8):
    """QwenASREngine.pinnedLanguage for these windows, at `share`."""
    code, got, texts = vote(windows)
    return code if texts >= 2 and code in QWEN and got >= share else None


def auto_windows(record):
    """The first auto decode of every window, by index."""
    out = {}
    for w in record['windows']:
        if w.get('language') is None and w['index'] not in out:
            out[w['index']] = w
    return out


def pinned_windows(record, language):
    return {w['index']: w for w in record['windows'] if w.get('language') == language}


def script(ch):
    name = unicodedata.name(ch, '')
    if 'CJK' in name:
        return 'HAN'
    if 'HIRAGANA' in name or 'KATAKANA' in name:
        return 'KANA'
    return name.split(' ')[0]


def script_shares(text, languages):
    """(non-Latin share, off-script share) of letters. Off-script: outside Latin and the track's own
    scripts; Serbian Cyrillic counts as its own, because the app writes BCMS tracks in Latin later."""
    letters = [script(ch) for ch in text if ch.isalpha()]
    if not letters:
        return 0.0, 0.0
    allowed = {'LATIN'}.union(*(SCRIPTS.get(code, set()) for code in languages))
    non_latin = sum(1 for s in letters if s != 'LATIN')
    off = sum(1 for s in letters if s not in allowed)
    return non_latin / len(letters), off / len(letters)


def tokens(text, languages):
    text = text or ''
    if set(languages) & BCMS:
        text = ''.join(CYR.get(ch, CYR.get(ch.lower(), ch)) for ch in text.lower())
    if set(languages) <= CER_LANGUAGES and languages:
        return [ch for ch in basic(text) if not ch.isspace()]
    if languages == ['en']:
        return english(text).split()
    return basic(text).split()


def errors(reference, hypothesis, languages):
    """(edit distance, reference length) in words, or characters for Japanese and Chinese."""
    ref, hyp = tokens(reference, languages), tokens(hypothesis, languages)
    return Levenshtein.distance(ref, hyp), len(ref)
