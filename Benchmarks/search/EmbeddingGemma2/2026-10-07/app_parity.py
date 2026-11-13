"""Check the app's embedder configuration reproduces the benchmark vectors.

Launches the vendored llama-server with the same arguments as
`LlamaServer.embedder` (2,048 context and batch, no pooling flag) and sends
requests shaped like `EmbeddingIndex.embeddingRequestBody`: many inputs per
request with `cache_prompt: false`. Vectors must match the reference vectors
made one input at a time with an 8K batch. Optionally repeats the real-library
corpus (private; only aggregate numbers are printed) and compares prompt
caching on and off.
"""
import argparse
import json
import secrets
import socket
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
import psutil
import requests

REPO = Path(__file__).resolve().parents[4]
SERVER = REPO / 'Vendor/llama-cpp/llama-server'
GEMMA = Path('/private/tmp/lokalbot-embeddinggemma2-20261007/models/embeddinggemma-2-Q8_0.gguf')
FIXTURES = Path('/private/tmp/lokalbot-embeddinggemma2-20261006')
REFERENCE = Path('/private/tmp/lokalbot-embeddinggemma2-20261007/results-b11474')
REAL = Path('/private/tmp/lokalbot-embeddinggemma2-reallib')
PORT = 18789
DOCUMENT = 'title: none | text: '
QUERY = 'task: search result | query: '
# Mirrors LlamaServer.embedder plus the shared launch arguments.
APP_ARGUMENTS = ['-c', '2048', '-ngl', '99', '--jinja', '--no-webui',
                 '--embeddings', '-b', '2048', '-ub', '2048', '--parallel', '1']


def normalize(values):
    values = np.asarray(values, dtype=np.float32)
    return values / np.linalg.norm(values, axis=1, keepdims=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--real-library', action='store_true')
    real = parser.parse_args().real_library
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1', PORT)) == 0:
            raise RuntimeError('Disposable port occupied; refusing to stop another process')
    token = secrets.token_hex(16)
    log = open('/private/tmp/lokalbot-embeddinggemma2-20261007/app-parity-server.log', 'w')
    process = subprocess.Popen(
        [str(SERVER), '-m', str(GEMMA), '--host', '127.0.0.1', '--port', str(PORT),
         '--api-key', token, *APP_ARGUMENTS], stdout=log, stderr=subprocess.STDOUT)
    peak = [0]
    active = [True]

    def sample():
        handle = psutil.Process(process.pid)
        while active[0]:
            try:
                peak[0] = max(peak[0], handle.memory_info().rss)
            except psutil.Error:
                return
            time.sleep(.02)

    threading.Thread(target=sample, daemon=True).start()
    session = requests.Session()
    session.trust_env = False
    session.headers['Authorization'] = 'Bearer ' + token
    base = f'http://127.0.0.1:{PORT}'

    def embed(texts, prefix, batch, cache=False):
        vectors = []
        for start in range(0, len(texts), batch):
            body = {'input': [prefix + t for t in texts[start:start + batch]],
                    'model': 'embeddinggemma-2-q8'}
            if not cache:
                body['cache_prompt'] = False
            response = session.post(base + '/v1/embeddings', json=body, timeout=300)
            if response.status_code != 200:
                raise RuntimeError(f'{response.status_code}: {response.text[:300]}')
            rows = sorted(response.json()['data'], key=lambda row: row['index'])
            vectors.extend(row['embedding'] for row in rows)
        return normalize(vectors)

    def compare(label, vectors, reference):
        agreement = np.sum(vectors * reference, axis=1)
        print(f'{label}: {len(agreement)} vectors x {vectors.shape[1]}; '
              f'cosine vs reference min {agreement.min():.6f} median {np.median(agreement):.6f}', flush=True)
        return float(agreement.min())

    try:
        for _ in range(600):
            if process.poll() is not None:
                raise RuntimeError('server exited; inspect app-parity-server.log')
            try:
                if session.get(base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        text = json.loads((FIXTURES / 'fixtures/text.json').read_text())
        screens = json.loads((FIXTURES / 'fixtures/screens.json').read_text())
        ocr = {row['id']: row['text'] for row in json.loads((FIXTURES / 'ocr.json').read_text())}
        minimum = [
            # A whole "meeting" in one request, as EmbeddingIndex.index sends it.
            compare('synthetic documents, one request', embed([d['text'] for d in text['documents']], DOCUMENT, 60),
                    np.load(REFERENCE / 'gemma-gguf-text-documents.npy')),
            compare('synthetic queries, one per request', embed([q['query'] for q in text['queries']], QUERY, 1),
                    np.load(REFERENCE / 'gemma-gguf-text-queries.npy')),
            # Screen backfill batches 32 OCR rows of up to 1,500 characters.
            compare('synthetic OCR, batches of 32', embed([ocr[d['id']][:1500] for d in screens['documents']],
                                                          DOCUMENT, 32),
                    np.load(REFERENCE / 'gemma-gguf-ocr-documents.npy')),
        ]
        cached = embed([d['text'] for d in text['documents']], DOCUMENT, 60, cache=True)
        compare('synthetic documents with prompt cache ON', cached, np.load(REFERENCE / 'gemma-gguf-text-documents.npy'))
        if real:
            for name, batch in (('screens', 32), ('meetings', 64)):
                corpus = json.loads((REAL / f'corpus/{name}.json').read_text())
                started = time.perf_counter()
                vectors = embed([row['text'] for row in corpus], DOCUMENT, batch)
                seconds = time.perf_counter() - started
                minimum.append(compare(f'real {name} ({seconds:.0f} s)', vectors,
                                       np.load(REAL / f'vectors/gemma-{name}-documents.npy')))
        print(f'peak server RSS {peak[0] / 2**20:.0f} MiB; model file {GEMMA.stat().st_size / 2**20:.0f} MiB')
        print('PASS' if min(minimum) >= 0.999 else 'FAIL')
    finally:
        active[0] = False
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        session.close()
        log.close()


if __name__ == '__main__':
    main()
