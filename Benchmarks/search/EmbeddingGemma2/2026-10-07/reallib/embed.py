"""Embed the real-library corpus and queries; reuse stored Harrier documents.

Harrier document vectors come straight from the snapshot (production
contract `harrier-oss-v1-0.6b-q8-last-chunks-v1`). A spot check re-embeds a
sample with the production prefixes to confirm they match. Gemma embeds
every document with its checkpoint prompts. Both models embed queries.
"""
import argparse
import json
import random
import secrets
import socket
import subprocess
import time
from pathlib import Path

import numpy as np
import requests

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-reallib')
BENCH = Path('/private/tmp/lokalbot-embeddinggemma2-20261007')
SERVER = BENCH / 'bin/llama-b11469/llama-server'
GEMMA = BENCH / 'models/embeddinggemma-2-Q8_0.gguf'
HARRIER = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/harrier-oss-v1-0.6b.Q8_0.gguf'
PORT = 18788
PREFIX = {
    'harrier': {
        'meetings': ('Document for meeting search: ',
                     "Instruct: Retrieve relevant meeting transcript and summary chunks for the user's query.\nQuery:"),
        'screens': ('Document from screen memory: ',
                    "Instruct: Retrieve relevant OCR text captured from the user's screen.\nQuery:"),
    },
    'gemma': {
        'meetings': ('title: none | text: ', 'task: search result | query: '),
        'screens': ('title: none | text: ', 'task: search result | query: '),
    },
}


def normalize(values):
    values = np.asarray(values, dtype=np.float32)
    assert values.ndim == 2 and np.isfinite(values).all()
    return values / np.linalg.norm(values, axis=1, keepdims=True)


class Server:
    def __init__(self, arguments):
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', PORT)) == 0:
                raise RuntimeError('Disposable port occupied; refusing to stop another process')
        token = secrets.token_hex(16)
        self.log = (ROOT / 'embed-server.log').open('a')
        self.process = subprocess.Popen(
            [str(SERVER), *arguments, '--host', '127.0.0.1', '--port', str(PORT), '-ngl', '99',
             '--parallel', '1', '--no-webui', '--embeddings', '--api-key', token],
            stdout=self.log, stderr=subprocess.STDOUT)
        self.session = requests.Session()
        self.session.trust_env = False
        self.session.headers['Authorization'] = 'Bearer ' + token
        self.base = f'http://127.0.0.1:{PORT}'
        for _ in range(600):
            if self.process.poll() is not None:
                raise RuntimeError('embedding server exited; inspect embed-server.log')
            try:
                if self.session.get(self.base + '/health', timeout=1).status_code == 200:
                    return
            except requests.RequestException:
                pass
            time.sleep(.1)
        raise TimeoutError('embedding server startup timed out')

    def embed(self, texts, batch=8):
        vectors = []
        for start in range(0, len(texts), batch):
            response = self.session.post(self.base + '/v1/embeddings', json={
                'input': texts[start:start + batch], 'cache_prompt': False}, timeout=300)
            if response.status_code != 200:
                raise RuntimeError(f'{response.status_code}: {response.text[:300]}')
            rows = sorted(response.json()['data'], key=lambda row: row['index'])
            vectors.extend(row['embedding'] for row in rows)
        return normalize(vectors)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.session.close()
        self.log.close()


def load_queries():
    rows = [json.loads(line) for line in (ROOT / 'queries.jsonl').read_text().splitlines()]
    queries = []
    for row in rows:
        if row['skip']:
            continue
        for language in ('en', 'bcs'):
            text = row[f'query_{language}'].strip()
            if text:
                queries.append({'corpus': row['corpus'], 'target': row['target'],
                                'language': language, 'query': text})
    return queries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('model', choices=['harrier', 'gemma'])
    model = parser.parse_args().model
    corpus = {name: json.loads((ROOT / f'corpus/{name}.json').read_text()) for name in ('meetings', 'screens')}
    queries = load_queries()
    (ROOT / 'vectors').mkdir(exist_ok=True)
    if model == 'harrier':
        server = Server(['-m', str(HARRIER), '-c', '2048', '--pooling', 'last', '--cache-ram', '256'])
    else:
        server = Server(['-m', str(GEMMA), '-c', '8192', '-b', '8192', '-ub', '8192'])
    started = time.perf_counter()
    try:
        report = {}
        for name in ('meetings', 'screens'):
            document_prefix, query_prefix = PREFIX[model][name]
            selected = [q for q in queries if q['corpus'] == name]
            np.save(ROOT / f'vectors/{model}-{name}-queries.npy',
                    server.embed([query_prefix + q['query'] for q in selected], batch=16))
            if model == 'gemma':
                np.save(ROOT / f'vectors/gemma-{name}-documents.npy',
                        server.embed([document_prefix + row['text'] for row in corpus[name]]))
            elif name == 'meetings':
                # Meetings indexed by 0a0265a stored a 300-character preview
                # beside a full-chunk vector, so re-embed the stored text to
                # give Harrier exactly the input Gemma sees.
                stored = np.load(ROOT / 'corpus/harrier-meetings.npy')
                fresh = server.embed([document_prefix + row['text'] for row in corpus[name]], batch=16)
                np.save(ROOT / 'vectors/harrier-meetings-documents.npy', fresh)
                agreement = np.sum(fresh * stored, axis=1)
                report[name] = {'stored_vectors_reproduced': int((agreement >= .999).sum()),
                                'preview_rows': sum(len(row['text']) == 300 for row in corpus[name])}
            else:
                stored = np.load(ROOT / f'corpus/harrier-{name}.npy')
                sample = random.Random(61007).sample(range(len(corpus[name])), 40)
                fresh = server.embed([document_prefix + corpus[name][i]['text'] for i in sample])
                agreement = np.sum(fresh * stored[sample], axis=1)
                report[name] = {'spot_check_min_cosine': float(agreement.min()),
                                'spot_check_median_cosine': float(np.median(agreement))}
            report[f'{name}_queries'] = len(selected)
        (ROOT / 'queries-embedded.json').write_text(json.dumps(queries, ensure_ascii=False))
        report['seconds'] = time.perf_counter() - started
        print(model, json.dumps(report))
    finally:
        server.close()


if __name__ == '__main__':
    main()
