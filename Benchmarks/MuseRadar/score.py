"""Score Live Radar replays of the AMI meetings against AMI's human summaries.

For every model under $MUSE_RADAR_DATA/raw (and LokalBot's post-meeting notes,
when --notes points at a SummaryQuality library), it reports:
- coverage: the share of AMI action sentences matched by a radar commitment,
  and of AMI decision sentences matched by a radar decision;
- support: the share of radar items that match any sentence of that meeting's
  AMI summary (abstract, actions, decisions, problems), a precision proxy;
- live cost: pass latency, when items would appear, tokens and dollars.

A match is a cosine similarity of at least τ between EmbeddingGemma 2
sentence-similarity embeddings (LokalBot's search model), where τ is the 95th
percentile of the best match between each system's items and a *different*
team's AMI summary, as in Benchmarks/SummaryQuality. One τ covers every system.

Usage: score.py --app "path/to/LokalBot Dev.app" [--notes <library>] [--save results/<date>]
"""
import argparse
import json
import os
import statistics
import subprocess
import time
import urllib.request
from pathlib import Path

import numpy as np

DATA = Path(os.environ.get('MUSE_RADAR_DATA', '/private/tmp/lokalbot-muse-radar'))
MODEL = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/embeddinggemma-2-Q8_0.gguf'
PREFIX = 'task: sentence similarity | query: '
PORT = 18766
PARTS = ['abstract', 'actions', 'decisions', 'problems']


class Embedder:
    """EmbeddingGemma 2 on a private llama-server, cached across runs."""

    def __init__(self, llama, cache):
        self.llama, self.cache_path = llama, cache
        self.cache = json.loads(cache.read_text()) if cache.exists() else {}
        self.proc = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.proc:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        self.cache_path.write_text(json.dumps(self.cache))

    def start(self):
        self.proc = subprocess.Popen([str(self.llama), '-m', str(MODEL), '--embeddings', '-b', '2048', '-ub', '2048',
                                      '--parallel', '1', '--ctx-size', '2048', '--port', str(PORT)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(120):
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health', timeout=2)
                return
            except Exception:
                time.sleep(0.5)
        raise RuntimeError('embedding server did not start')

    def __call__(self, texts):
        todo = [t for t in dict.fromkeys(texts) if t not in self.cache]
        if todo and not self.proc:
            self.start()
        for i in range(0, len(todo), 16):
            batch = todo[i:i + 16]
            body = json.dumps({'input': [PREFIX + t for t in batch]}).encode()
            request = urllib.request.Request(f'http://127.0.0.1:{PORT}/v1/embeddings', data=body,
                                             headers={'Content-Type': 'application/json'})
            data = json.loads(urllib.request.urlopen(request, timeout=120).read())['data']
            for text, item in zip(batch, sorted(data, key=lambda x: x['index'])):
                vector = np.array(item['embedding'], dtype=np.float32)
                self.cache[text] = (vector / np.linalg.norm(vector)).tolist()
        return np.array([self.cache[t] for t in texts], dtype=np.float32) if texts else np.zeros((0, 1))


def best(similarities):
    return similarities.max(axis=1) if similarities.size else np.zeros(0)


def radar_runs():
    """{system: {meeting: {'actions', 'decisions', 'items', 'passes', 'summary'}}} from replay output."""
    runs = {}
    for folder in sorted((DATA / 'raw').glob('*')):
        meetings = {}
        for path in sorted(folder.glob('*.jsonl')):
            rows = [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
            if not rows or 'summary' not in rows[-1]:
                continue
            summary = rows[-1]['summary']
            items = summary['items']
            meetings[path.stem] = {
                'actions': [x['text'] for x in items if x['kind'] == 'commitment'],
                'decisions': [x['text'] for x in items if x['kind'] == 'decision'],
                'items': [x['text'] for x in items],
                'kinds': {k: sum(x['kind'] == k for x in items) for k in ['commitment', 'decision', 'question', 'contradiction']},
                'contradictions': [x for x in items if x['kind'] == 'contradiction'],
                'passes': [r for r in rows if 'pass' in r],
                'summary': summary,
            }
        if meetings:
            runs[f'Live Radar · {folder.name}'] = meetings
    return runs


def notes_run(library):
    """LokalBot's post-meeting notes from a SummaryQuality library (ref transcripts)."""
    meetings = {}
    for folder in sorted((Path(library) / 'meetings' / '2026' / '10').glob('*-ref')):
        path = folder / 'outcomes.json'
        if not path.exists():
            continue
        outcomes = json.loads(path.read_text())
        text = lambda x: x if isinstance(x, str) else x.get('text')
        actions = [text(x) for x in outcomes.get('actionItems', []) if text(x)]
        decisions = [text(x) for x in outcomes.get('decisionRecords', []) if text(x)]
        questions = [text(x) for x in outcomes.get('openQuestions', []) if text(x)]
        meetings[folder.name[:-4].upper()] = {'actions': actions, 'decisions': decisions,
                                              'items': actions + decisions + questions,
                                              'kinds': {'commitment': len(actions), 'decision': len(decisions),
                                                        'question': len(questions), 'contradiction': 0}}
    return meetings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, help='a built LokalBot Dev.app, for its llama-server')
    parser.add_argument('--notes', help='SummaryQuality library whose -ref meetings hold post-meeting notes')
    parser.add_argument('--save', type=Path)
    args = parser.parse_args()
    references = json.loads((DATA / 'references.json').read_text())
    meetings = sorted(references)
    systems = radar_runs()
    if args.notes:
        systems['Post-meeting notes · Qwen3.5 4B (local)'] = notes_run(args.notes)
    llama = Path(args.app) / 'Contents/Resources/llama-cpp/llama-server'

    with Embedder(llama, DATA / 'embeddings.json') as embed:
        cross = []
        for name, runs in systems.items():
            for meeting, run in runs.items():
                others = [m for m in meetings if m[:6] != meeting[:6]]
                other = others[sum(map(ord, meeting)) % len(others)]
                sentences = [s for part in PARTS for s in references[other][part]]
                if run['items']:
                    cross += list(best(embed(run['items']) @ embed(sentences).T))
        tau = float(np.percentile(cross, 95))

        report = {'tau': tau, 'crossMatches': len(cross), 'systems': {}}
        for name, runs in systems.items():
            totals = {'actions': [0, 0], 'decisions': [0, 0], 'supported': [0, 0]}
            per_meeting = []
            for meeting in meetings:
                run = runs.get(meeting)
                if run is None:
                    continue
                reference = references[meeting]
                row = {'meeting': meeting, **run['kinds']}
                for key in ['actions', 'decisions']:
                    sentences = reference[key]
                    if sentences:
                        hits = int((best(embed(sentences) @ embed(run[key]).T) >= tau).sum()) if run[key] else 0
                        totals[key][0] += hits
                        totals[key][1] += len(sentences)
                        row[f'{key}Covered'] = [hits, len(sentences)]
                everything = [s for part in PARTS for s in reference[part]]
                if run['items']:
                    supported = int((best(embed(run['items']) @ embed(everything).T) >= tau).sum())
                    totals['supported'][0] += supported
                    totals['supported'][1] += len(run['items'])
                    row['supported'] = [supported, len(run['items'])]
                per_meeting.append(row)
            entry = {'meetings': len(per_meeting), 'perMeeting': per_meeting,
                     **{k: {'matched': v[0], 'of': v[1], 'rate': v[0] / v[1] if v[1] else None} for k, v in totals.items()},
                     'items': {k: sum(r.get(k, 0) for r in per_meeting) for k in ['commitment', 'decision', 'question', 'contradiction']}}
            passes = [p for m in runs.values() for p in m.get('passes', [])]
            if passes:
                seconds = sorted(p['seconds'] for p in passes)
                shown = sorted(x['shownAfter'] for p in passes for x in p['added'])
                minutes = sum(max(l['time'] for l in json.loads((DATA / 'fixtures' / f'{m}.json').read_text())['lines']) / 60
                              for m in runs)
                cost = sum(p['cost'] for p in passes)
                entry['live'] = {
                    'passes': len(passes), 'meetingMinutes': minutes,
                    'passSecondsMedian': statistics.median(seconds),
                    'passSecondsP95': seconds[min(len(seconds) - 1, int(len(seconds) * .95))],
                    'shownAfterMedian': statistics.median(shown) if shown else None,
                    'inputTokens': sum(p['inputTokens'] for p in passes),
                    'outputTokens': sum(p['outputTokens'] for p in passes),
                    'reasoningTokens': sum(p['reasoningTokens'] for p in passes),
                    'rejected': sum(p['rejected'] for p in passes),
                    'cost': cost, 'costPerHour': cost / minutes * 60 if minutes else None,
                    'failedRequests': sum(m['summary'].get('failedRequests', 0) for m in runs.values()),
                }
                entry['contradictions'] = [{'meeting': m, 'text': x['text'], 'quote': x['quote'],
                                            'earlier': x.get('earlier')}
                                           for m, run in runs.items() for x in run['contradictions']]
            report['systems'][name] = entry

    pct = lambda v: '—' if v is None else f'{v:.0%}'
    print(f'τ = {tau:.3f} (95th percentile of {len(cross)} cross-team best matches)\n')
    print('| System | Meetings | AMI actions covered | AMI decisions covered | Items supported by AMI '
          '| Commitments / decisions / questions / contradictions |')
    print('|---|---:|---:|---:|---:|---:|')
    for name, e in report['systems'].items():
        print(f"| {name} | {e['meetings']} | {e['actions']['matched']}/{e['actions']['of']} ({pct(e['actions']['rate'])}) "
              f"| {e['decisions']['matched']}/{e['decisions']['of']} ({pct(e['decisions']['rate'])}) "
              f"| {pct(e['supported']['rate'])} | {e['items']['commitment']} / {e['items']['decision']} / "
              f"{e['items']['question']} / {e['items']['contradiction']} |")
    for name, e in report['systems'].items():
        if 'live' in e:
            live = e['live']
            print(f"\n{name}: {live['passes']} passes over {live['meetingMinutes']:.0f} min, pass median "
                  f"{live['passSecondsMedian']:.2f} s (p95 {live['passSecondsP95']:.2f} s), items shown a median "
                  f"{live['shownAfterMedian']:.0f} s after they were said, ${live['cost']:.2f} "
                  f"(${live['costPerHour']:.2f} per meeting hour), {live['rejected']} items rejected, "
                  f"{live['failedRequests']} failed requests")
    if args.save:
        args.save.mkdir(parents=True, exist_ok=True)
        (args.save / 'scores.json').write_text(json.dumps(report, indent=1) + '\n')


if __name__ == '__main__':
    main()
