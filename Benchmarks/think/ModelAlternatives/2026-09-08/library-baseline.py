"""Compare Qwen to native Harrier retrieval using a temporary library snapshot.

All transcripts, queries, vectors and plaintext checks stay under --work. The
native XCTest must finish first. Requires the September 7 benchmark environment.
The corpus is reconstructed using the production chunking rules, then checked
against every row written by Swift before any baseline inference runs.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sqlite3
import statistics

import numpy as np
import regex

parser = argparse.ArgumentParser()
parser.add_argument('--work', type=Path, default=Path('/private/tmp/lokalbot-model-integration-20260908'))
args = parser.parse_args()
fixture = json.loads((args.work/'native-embedding-fixture.json').read_text())
library = Path(fixture['libraryRoot'])


def characters(text):
    return regex.findall(r'\X', text)


def chunks(transcript):
    result, current, start = [], '', 0
    aliases = transcript.get('speakerAliases', {})
    for segment in transcript['segments']:
        key = segment['speaker'].strip().lower()
        speaker = aliases.get(key, segment['speaker'].strip().title() or 'Speaker')
        line = f'{speaker}: {segment["text"]}\n'
        chars = characters(line)
        if len(chars) > 1800:
            if current:
                result.append((start, current))
                current = ''
            while len(chars) > 500:
                candidates = [i for i in range(250, 500) if chars[i].isspace()]
                end = candidates[-1] + 1 if candidates else 500
                result.append((segment['start'], ''.join(chars[:end])))
                chars = chars[end:]
            if chars:
                result.append((segment['start'], ''.join(chars)))
            continue
        if current and len(characters(current)) + len(chars) > 1800:
            result.append((start, current))
            current = ''
        if not current:
            start = segment['start']
        current += line
        if len(characters(current)) > 500:
            result.append((start, current))
            current = ''
    if current:
        result.append((start, current))
    return result


documents = []
for path in sorted((library/'meetings').rglob('meta.json')):
    meta = json.loads(path.read_text())
    transcript = json.loads(path.with_name('transcript.json').read_text())
    extracted = chunks(transcript)
    summary = path.with_name('summary.md')
    if summary.exists():
        for section in summary.read_text().split('\n## '):
            chars = characters(section)
            if len(chars) > 40:
                extracted.append((0, ''.join(chars[:700])))
    for start, text in extracted:
        documents.append({'meeting': meta['id'].lower(), 'start': start, 'text': text})

with sqlite3.connect(f'file:{library}/harrier-validation.sqlite?mode=ro', uri=True) as connection:
    native = connection.execute('SELECT meeting_id,start,text FROM embeddings').fetchall()


def key(meeting, start, text):
    return meeting.lower(), float(start), ''.join(characters(text)[:300])


from collections import Counter
expected = Counter(key(d['meeting'], d['start'], d['text']) for d in documents)
actual = Counter(key(*row) for row in native)
if expected != actual:
    raise RuntimeError(f'Corpus mismatch: {sum((expected-actual).values())} missing, '
                       f'{sum((actual-expected).values())} extra. Refusing an unequal comparison.')
print(f'Confirmed all {len(documents)} chunks match the native rebuilt index.', flush=True)

previous = Path(__file__).parents[1]/'2026-09-07/run.py'
spec = importlib.util.spec_from_file_location('model_benchmark', previous)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
with runner.server('qwen-embedding', 'embedding', run_label='qwen-real-library'):
    vectors, times = runner.embeddings(['Document for meeting search: '+d['text'] for d in documents])
    queries = fixture['queries']
    query_vectors, query_times = runner.embeddings([
        "Instruct: Retrieve relevant meeting transcript and summary chunks for the user's query.\nQuery:"+q['query']
        for q in queries])
    rows = []
    for query, scores, seconds in zip(queries, query_vectors @ vectors.T, query_times):
        order = [int(i) for i in np.argsort(-scores) if scores[i] > 0.45][:10]
        meeting_ids = [documents[i]['meeting'][:8] for i in order]
        rank = next((i+1 for i, mid in enumerate(meeting_ids) if mid in query['relevant_meetings']), 0)
        rows.append({'id': query['id'], 'language': query['language'], 'rank': rank,
                     'top10': meeting_ids, 'seconds': seconds})
    report = {'model': 'Qwen3-Embedding-0.6B-Q8_0', 'vectors': len(documents),
              'document_seconds': sum(times), 'query_median_seconds': statistics.median(query_times), 'rows': rows}
    (args.work/'qwen-library-baseline.json').write_text(json.dumps(report, indent=2))
    print('Baseline top1:', sum(row['rank'] == 1 for row in rows), '/', len(rows), flush=True)
