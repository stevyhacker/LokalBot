"""Score LokalBot's meeting notes against AMI's human abstractive summaries.

For each transcript condition (a folder suffix such as ref, new or old):
- Completion: share of meetings whose notes finished. A failed run still leaves
  partial notes, which are what the user sees, so those are scored too.
- ROUGE-1/2/Lsum F1 of the app's bullets against AMI's abstract, decisions,
  actions and problems.
- Semantic coverage with Harrier embeddings (the app's search model): the share
  of AMI abstract, decision and action sentences matched by an app item, and the
  share of app items supported by any AMI sentence. A match must beat τ, the 95th
  percentile of best-match similarity between app items and a *different*
  scenario's AMI summary, i.e. what an unrelated design meeting would score.
- For app transcripts: word error rate against AMI's manual transcript, and how
  much of the summary of that manual transcript the app-transcript summary keeps.

Usage: score_summaries.py --app "path/to/LokalBot Dev.app" [--conditions ref,new] [--out results.json]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np
from rouge_score import rouge_scorer

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'transcribe' / 'CloudSTT'))
from score import errors, words  # noqa: E402  (shared WER normalization)

BENCH = Path(os.environ.get('SUMMARY_BENCH_DIR', '/private/tmp/lokalbot-summary-bench'))
ANN = BENCH / 'ami-ann'
MEETINGS_DIR = BENCH / 'library' / 'meetings' / '2026' / '10'
MEETINGS = [f'{s}{x}' for s in ['ES2004', 'IS1009', 'TS3003'] for x in 'abcd']
HARRIER = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/harrier-oss-v1-0.6b.Q8_0.gguf'
PORT = 18765
INSTRUCT = 'Instruct: Identify statements that describe the same meeting content.\nQuery: '
SECTIONS = ['TL;DR', 'Key points', 'Decisions', 'Action items', 'Open questions']


def ami(meeting):
    text = (ANN / 'abstractive' / f'{meeting}.abssumm.xml').read_text(encoding='latin-1')
    out = {}
    for part in ['abstract', 'actions', 'decisions', 'problems']:
        block = re.search(rf'<{part}[^>]*>(.*?)</{part}>', text, re.S)
        sentences = [re.sub(r'\s+', ' ', s).strip()
                     for s in re.findall(r'<sentence[^>]*>(.*?)</sentence>', block.group(1), re.S)] if block else []
        # Annotators write "NA." for a meeting without, say, decisions.
        out[part] = [s for s in sentences if not re.fullmatch(r'(?i)n/?a\.?|none\.?', s)]
    return out


def artifact(folder, name, partial):
    """The final artifact, or the partial one a failed run left behind."""
    final = folder / name
    return final if final.exists() else folder / partial


def summary_items(folder):
    sections, current = {}, None
    for line in artifact(folder, 'summary.md', 'summary.partial.md').read_text().splitlines():
        if line.startswith('## '):
            current = line[3:].strip()
            sections[current] = []
        elif current and line.lstrip().startswith(('- ', '* ')):
            item = line.lstrip()[2:]
            item = re.sub(r'^\*\*[^*]+:\*\*\s*', '', item)       # speaker prefix
            item = re.sub(r'\s*—\s*\[[0-9:]+\]\s*$', '', item)   # timestamp suffix
            item = re.sub(r'[*_`]', '', item).strip()
            if item and not item.lower().startswith(('none', 'no ')):
                sections[current].append(item)
    return sections


def outcome_items(folder):
    o = json.loads(artifact(folder, 'outcomes.json', 'outcomes.partial.json').read_text())
    text = lambda x: x if isinstance(x, str) else x.get('text')
    items = {k: [text(x) for x in o.get(k, []) if text(x)] for k in ['actionItems', 'decisionRecords', 'openQuestions']}
    items['ownerUnclear'] = sum(1 for x in o.get('actionItems', []) if isinstance(x, dict)
                                and ((x.get('attribution') or {}).get('resolution') == 'unresolved' or not x.get('owner')))
    return items


def load(meeting, condition):
    folder = MEETINGS_DIR / f'{meeting.lower()}-{condition}'
    if not artifact(folder, 'summary.md', 'summary.partial.md').exists() or not (folder / 'transcript.json').exists():
        return None
    sections, outcomes = summary_items(folder), outcome_items(folder)
    metrics_path = folder / 'notes-generation-metrics.json'
    metrics = json.loads(metrics_path.read_text()) if metrics_path.exists() else {}
    segments = sorted(json.loads((folder / 'transcript.json').read_text())['segments'], key=lambda s: s['start'])
    return {'complete': (folder / 'summary.md').exists(), 'sections': sections, 'outcomes': outcomes,
            'bullets': list(dict.fromkeys(b for k in SECTIONS for b in sections.get(k, []))),
            'requests': metrics.get('requests'), 'seconds': metrics.get('elapsedSeconds'),
            'transcript': ' '.join(s['text'] for s in segments)}


class Embedder:
    """Harrier embeddings from a private llama-server, cached across runs."""

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
        self.proc = subprocess.Popen([str(self.llama), '-m', str(HARRIER), '--embeddings', '--pooling', 'last',
                                      '--port', str(PORT), '--ctx-size', '2048', '--parallel', '1'],
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
            body = json.dumps({'input': [INSTRUCT + t for t in batch]}).encode()
            req = urllib.request.Request(f'http://127.0.0.1:{PORT}/v1/embeddings', data=body,
                                         headers={'Content-Type': 'application/json'})
            data = json.loads(urllib.request.urlopen(req, timeout=120).read())['data']
            for t, d in zip(batch, sorted(data, key=lambda x: x['index'])):
                v = np.array(d['embedding'], dtype=np.float32)
                self.cache[t] = (v / np.linalg.norm(v)).tolist()
        return np.array([self.cache[t] for t in texts], dtype=np.float32) if texts else np.zeros((0, 1))


def best(sims):
    return sims.max(axis=1) if sims.size else np.zeros(0)


def pooled(rows, key):
    """Mean of a per-meeting value, or a rate pooled over items for (rate, count) pairs."""
    vals = [r[key] for r in rows if r.get(key) is not None]
    if not vals:
        return None
    if isinstance(vals[0], (list, tuple)):
        return sum(v * n for v, n in vals) / max(sum(n for _, n in vals), 1)
    return sum(vals) / len(vals)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, help='a built LokalBot Dev.app, for its llama-server')
    parser.add_argument('--conditions', default='ref,new,old')
    parser.add_argument('--reference', default='ref', help='condition whose transcript is AMI\'s manual one')
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    conditions = args.conditions.split(',')
    llama = Path(args.app) / 'Contents/Resources/llama-cpp/llama-server'
    scorer = rouge_scorer.RougeScorer(['rouge1', 'rouge2', 'rougeLsum'], use_stemmer=True)
    data = {m: {'ami': ami(m), **{c: load(m, c) for c in conditions + [args.reference]}} for m in MEETINGS}

    with Embedder(llama, BENCH / 'embeddings.json') as embed:
        cross = []
        for m in MEETINGS:
            others = [x for x in MEETINGS if x[:6] != m[:6]]
            other = others[sum(map(ord, m)) % len(others)]
            ref_sents = [s for part in data[other]['ami'].values() for s in part]
            for c in conditions:
                if data[m][c] and data[m][c]['bullets']:
                    cross += list(best(embed(data[m][c]['bullets']) @ embed(ref_sents).T))
        tau = float(np.percentile(cross, 95))

        rows = {c: [] for c in conditions}
        for m in MEETINGS:
            a = data[m]['ami']
            all_ref = [s for part in a.values() for s in part]
            reference = data[m][args.reference]
            for c in conditions:
                d = data[m][c]
                if not d:
                    continue
                r = scorer.score('\n'.join(all_ref), '\n'.join(d['bullets']))
                bullets = embed(d['bullets'])
                actions = d['outcomes']['actionItems'] or d['sections'].get('Action items', [])
                decisions = d['outcomes']['decisionRecords'] or d['sections'].get('Decisions', [])
                row = {'meeting': m, 'complete': d['complete'], 'requests': d['requests'], 'seconds': d['seconds'],
                       'rouge1': r['rouge1'].fmeasure, 'rouge2': r['rouge2'].fmeasure, 'rougeLsum': r['rougeLsum'].fmeasure,
                       'items': len(d['bullets']), 'actions': len(actions), 'decisions': len(decisions),
                       'owner_unclear': d['outcomes']['ownerUnclear'], 'ami_decisions': len(a['decisions'])}
                for key, ref_sents, hyp in [('abstract', a['abstract'], d['bullets']),
                                            ('decisions', a['decisions'], decisions), ('actions', a['actions'], actions)]:
                    if ref_sents:
                        covered = float((best(embed(ref_sents) @ embed(hyp).T) >= tau).mean()) if hyp else 0.0
                        row[f'{key}_covered'] = (covered, len(ref_sents))
                support = best(bullets @ embed(all_ref).T) if d['bullets'] else np.zeros(0)
                row['supported'] = (float((support >= tau).mean()) if len(support) else 0.0, len(support))
                if c != args.reference and reference:
                    e = errors(words(reference['transcript']), words(d['transcript']))
                    row['wer'] = (sum(e[k] for k in ('sub', 'del', 'ins')) / e['ref_words'], e['ref_words'])
                    kept = best(embed(reference['bullets']) @ bullets.T) if len(bullets) else np.zeros(0)
                    row['reference_summary_kept'] = float((kept >= tau).mean()) if len(kept) else 0.0
                rows[c].append(row)

    pct = lambda v: '—' if v is None else f'{v:.1%}'
    print(f'τ = {tau:.3f} (95th percentile of {len(cross)} cross-scenario best matches)\n')
    print('| Condition | Meetings | Notes completed | Transcript WER | ROUGE-1 | ROUGE-2 | ROUGE-Lsum | AMI summary covered '
          '| AMI decisions covered | AMI actions covered | App items supported | Items / actions / decisions per meeting '
          '| Owner-unclear tasks | Reference-summary items kept |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for c in conditions:
        rs = rows[c]
        if not rs:
            continue
        print(f'| {c} | {len(rs)} | {sum(r["complete"] for r in rs)} of {len(rs)} | {pct(pooled(rs, "wer"))} '
              f'| {pooled(rs, "rouge1"):.3f} | {pooled(rs, "rouge2"):.3f} | {pooled(rs, "rougeLsum"):.3f} '
              f'| {pct(pooled(rs, "abstract_covered"))} | {pct(pooled(rs, "decisions_covered"))} '
              f'| {pct(pooled(rs, "actions_covered"))} | {pct(pooled(rs, "supported"))} '
              f'| {pooled(rs, "items"):.1f} / {pooled(rs, "actions"):.1f} / {pooled(rs, "decisions"):.1f} '
              f'| {sum(r["owner_unclear"] for r in rs)} | {pct(pooled(rs, "reference_summary_kept"))} |')
    if args.out:
        args.out.write_text(json.dumps({'tau': tau, 'rows': rows}, indent=1, default=float) + '\n')


if __name__ == '__main__':
    main()
