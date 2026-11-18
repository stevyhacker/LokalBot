"""Run the benchmark's decodes on another machine (pc_decode.py) and replay both paths here.

When the model must not run on the Mac, the decodes go to a remote llama-server and only the
language vote, Apple's text recognizer through vote.swift, runs here, exactly as the engine
casts it. Decoding is greedy, so the two paths can be rebuilt from one set of decodes: every
window on auto, then every window pinned in each language either path chose. The rebuilt runs
have the replay test's format, so score.py and simulate.py read them unchanged.

  plan.py auto    --tier 0.6b       # job-auto.json: every window on auto
  plan.py pins    --tier 0.6b       # vote here; job-pins.json: the pinned decodes either path needs
  plan.py records --tier 0.6b       # runs-<tier>.jsonl with `before` and `after` records

Windows come from the 1.7B replay's VAD spans in QLS_OUT/runs.jsonl, merged for word attribution
with the tier's own limits (QwenASREngine.wordAttributionWindows), so no VAD runs again. The
decode times are window times from the remote run, summed per path: a work estimate measured
in one process, not a paired wall-time run.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path, PureWindowsPath

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from common import ALIGNER, OUT, QWEN, pinned, runs  # noqa: E402

SAMPLE_SIZES = [2, 3, 4, 5, 6, 8, 10, 12, 16, 24]
SAMPLE_SIZE, SAMPLE_SHARE = 12, 0.9  # QwenASREngine.languageSampleSize, .sampleShare
WORD_LIMITS = {'1.7b': (30, 5), '0.6b': (15, 5)}  # maxSeconds, maxGapSeconds
# The remote machine's working folder (Windows paths): models\, tracks\, out\ and the llama.cpp runtime.
REMOTE = PureWindowsPath(os.environ.get('QLS_REMOTE', r'C:\qls'))
SERVER = {'exe': str(REMOTE / 'llama-b12359-vulkan' / 'llama-server.exe'), 'port': 18677}
MODELS = {'0.6b': 'Qwen3-ASR-0.6B-Q8_0.gguf', '1.7b': 'Qwen3-ASR-1.7B-Q8_0.gguf'}


def merged(spans, max_gap, max_length):
    """QwenASREngine.merged."""
    out = []
    for start, end in spans:
        if out and start - out[-1][1] <= max_gap and end - out[-1][0] <= max_length:
            out[-1] = [out[-1][0], end]
        else:
            out.append([start, end])
    return out


def language_sample(spans, count):
    """QwenASREngine.languageSample: the longest span of each of `count` groups, earliest on ties."""
    if count <= 0 or len(spans) <= count:
        return list(range(len(spans)))
    picks = []
    for group in range(count):
        lo, hi = group * len(spans) // count, (group + 1) * len(spans) // count
        best = lo
        for i in range(lo + 1, hi):
            if spans[i][1] - spans[i][0] > spans[best][1] - spans[best][0]:
                best = i
        picks.append(best)
    return picks


def tracks(tier):
    """Public tracks only: FLEURS, code-switched FLEURS and AMI, with plain and word windows."""
    items = {i['id']: i for i in json.loads((OUT / 'items.json').read_text())}
    max_seconds, max_gap = WORD_LIMITS[tier]
    out = []
    for (track, layout, mode), record in sorted(runs().items()):
        if layout != 'plain' or mode != 'before' or track not in items:
            continue
        plain = record['spans']
        out.append({'id': track, 'wav': str(REMOTE / 'tracks' / Path(items[track]['wav']).name),
                    'local': items[track]['wav'],
                    'windows': {'plain': plain, 'word': merged(plain, max_gap, max_seconds)}})
    return out


def job(tier, decodes, name):
    server = {**SERVER, 'model': str(REMOTE / 'models' / MODELS[tier]),
              'mmproj': str(REMOTE / 'models' / f'mmproj-{MODELS[tier]}'),
              'log': str(REMOTE / 'out' / f'server-{tier}-{name}.log')}
    body = {'server': server, 'output': str(REMOTE / 'out' / f'decodes-{tier}.jsonl'),
            'tracks': [{k: t[k] for k in ['id', 'wav', 'windows']} for t in tracks(tier)], 'decodes': decodes}
    path = OUT / f'job-{tier}-{name}.json'
    path.write_text(json.dumps(body))
    print(f'{len(decodes)} decodes -> {path}')


def decodes(tier):
    out = {}
    path = OUT / f'decodes-{tier}.jsonl'
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.strip():
            r = json.loads(line)
            out[(r['id'], r['layout'], r['language'])] = r
    return out


def votes(tier):
    """Each auto window's own vote, cast by vote.swift, keyed by (track, layout)."""
    auto = {(t, l): r for (t, l, lang), r in decodes(tier).items() if lang is None}
    texts = [w['text'] for r in auto.values() for w in r['windows']]
    cast = json.loads(subprocess.run([str(OUT / 'vote')], input=json.dumps(texts).encode(), capture_output=True,
                                     check=True).stdout)
    out, k = {}, 0
    for key, r in auto.items():
        windows = []
        for w in r['windows']:
            windows.append({**w, 'language': None, 'vote': cast[k][0], 'weight': cast[k][1]})
            k += 1
        out[key] = windows
    return out


def paths(spans, auto, layout):
    """Both paths' decisions on one track: (before pin, before twice, before regions), and the after
    path's (pin, sampled, twice, regions, sampled indices, one pass)."""
    by_index = {w['index']: w for w in auto}
    word = layout == 'word'
    full = pinned(auto)
    before = (full, bool(full) and not (word and full not in ALIGNER), bool(full) and word and full not in ALIGNER)
    sample = language_sample(spans, SAMPLE_SIZE)
    strong = pinned([by_index[i] for i in sample if i in by_index], SAMPLE_SHARE) if len(sample) < len(spans) else None
    if strong:
        regions = word and strong not in ALIGNER
        return before, (strong, len(sample), False, regions, sample, True)
    return before, (full, len(sample), before[1], before[2], sample, False)


def plan_pins(tier):
    need = set()
    for t in tracks(tier):
        for layout, spans in t['windows'].items():
            auto = votes_cache[(t['id'], layout)]
            before, after = paths(spans, auto, layout)
            for code, regions in [(before[0], before[2]), (after[0], after[3])]:
                if code and not regions:
                    need.add((t['id'], layout, code))
    job(tier, [{'id': i, 'layout': l, 'language': c} for i, l, c in sorted(need)], 'pins')


def build_records(tier):
    found = decodes(tier)
    out = []
    for t in tracks(tier):
        for layout, spans in t['windows'].items():
            auto = votes_cache[(t['id'], layout)]
            by_index = {w['index']: w for w in auto}
            before, after = paths(spans, auto, layout)

            def pinned_windows(code):
                return [{**w, 'language': code} for w in found[(t['id'], layout, code)]['windows']]

            def record(mode, windows, code, sampled, twice, regions, final):
                return {'id': t['id'], 'layout': layout, 'mode': mode, 'spans': spans,
                        'audioSeconds': spans[-1][1] if spans else 0, 'vadSeconds': 0,
                        'decodeSeconds': sum(w['seconds'] for w in windows), 'pinned': code, 'sampled': sampled,
                        'decodedTwice': twice, 'needsSpeakerRegions': regions,
                        'text': ' '.join(w['text'] for w in final if w['text']), 'windows': windows,
                        'samples': {str(k): language_sample(spans, k) for k in SAMPLE_SIZES}}

            code, twice, regions = before
            pins = pinned_windows(code) if twice else []
            out.append(record('before', auto + pins, code, len(spans), twice, regions, pins or auto))
            code, sampled, twice, regions, sample, one_pass = after
            if one_pass:
                first = [by_index[i] for i in sample if i in by_index]
                pins = [] if regions else pinned_windows(code)
                out.append(record('after', first + pins, code, sampled, False, regions, pins or first))
            else:
                pins = pinned_windows(code) if twice else []
                out.append(record('after', auto + pins, code, sampled, twice, regions, pins or auto))
    path = OUT / f'runs-{tier}.jsonl'
    path.write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in out))
    print(f'{len(out)} records -> {path}')


def main():
    global votes_cache
    parser = argparse.ArgumentParser()
    parser.add_argument('step', choices=['auto', 'pins', 'records'])
    parser.add_argument('--tier', default='0.6b', choices=sorted(WORD_LIMITS))
    args = parser.parse_args()
    if args.step == 'auto':
        job(args.tier, [{'id': t['id'], 'layout': layout, 'language': None}
                        for t in tracks(args.tier) for layout in ['word', 'plain']], 'auto')
        return
    votes_cache = votes(args.tier)
    (plan_pins if args.step == 'pins' else build_records)(args.tier)


votes_cache = {}

if __name__ == '__main__':
    main()
