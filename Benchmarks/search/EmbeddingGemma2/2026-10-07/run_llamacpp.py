"""Re-run the 6 October fixtures through llama-server; no app writes.

Reads the frozen fixtures, OCR and PyTorch vectors from the 6 October
disposable root and writes new vectors beside a pinned upstream llama.cpp
build. Every request embeds one input, matching the earlier timing method.
"""
import argparse
import base64
import hashlib
import json
import socket
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np
import psutil
import requests

BASELINE = Path('/private/tmp/lokalbot-embeddinggemma2-20261006')
ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-20261007')
RESULTS = ROOT / 'results'
BINARY = ROOT / 'bin/llama-b11469/llama-server'
GEMMA = ROOT / 'models/embeddinggemma-2-Q8_0.gguf'
MMPROJ = ROOT / 'models/mmproj-embeddinggemma-2-Q8_0.gguf'
HARRIER = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/harrier-oss-v1-0.6b.Q8_0.gguf'
CHECKSUMS = {
    GEMMA: '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135',
    MMPROJ: 'c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f',
    HARRIER: 'ba2c9408f82cfdb73aaf70aaea9f125f3fb24c5e76ce0efb469e1530e5ec53e4',
}
PORT = 18787
TOKEN = 'disposable-synthetic-embedding-benchmark'
# Production Harrier prompts, unchanged from the 6 October harness.
TEXT_DOCUMENT = 'Document for meeting search: '
TEXT_QUERY = "Instruct: Retrieve relevant meeting transcript and summary chunks for the user's query.\nQuery:"
SCREEN_DOCUMENT = 'Document from screen memory: '
SCREEN_QUERY = "Instruct: Retrieve relevant OCR text captured from the user's screen.\nQuery:"
# The checkpoint's SentenceTransformers `SearchQuery` and `Document` prompts.
GEMMA_QUERY = 'task: search result | query: '
GEMMA_DOCUMENT = 'title: none | text: '


def write(name, value):
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / (name + '.json')).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def normalize(values):
    values = np.asarray(values, dtype=np.float32)
    assert values.ndim == 2 and np.isfinite(values).all()
    norms = np.linalg.norm(values, axis=1, keepdims=True)
    assert np.all(norms > 0)
    return values / norms


def verify(path):
    with path.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == CHECKSUMS[path], path


class MemorySampler:
    def __init__(self, pid):
        self.peak = 0
        self.active = True
        self.process = psutil.Process(pid)
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while self.active:
            try:
                self.peak = max(self.peak, self.process.memory_info().rss)
            except psutil.Error:
                return
            time.sleep(.02)

    def stop(self):
        self.active = False
        self.thread.join(timeout=1)
        return self.peak


def image_part(path):
    data = base64.b64encode(Path(path).read_bytes()).decode()
    return {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + data}}


def record(name, vectors, timings, tokens):
    matrix = normalize(vectors)
    np.save(RESULTS / (name + '.npy'), matrix)
    summary = {
        'count': len(timings), 'dimension': matrix.shape[1],
        'p50_seconds': statistics.median(timings),
        'p95_seconds': float(np.percentile(timings, 95)), 'seconds': timings,
        'prompt_tokens': tokens,
    }
    reference = BASELINE / 'results' / (name.replace('-gguf', '') + '.npy')
    if name.startswith('gemma') and reference.exists():
        # Same input through the BF16 PyTorch path: per-row cosine agreement.
        torch_vectors = np.load(reference)
        if torch_vectors.shape == matrix.shape:
            agreement = np.sum(torch_vectors * matrix, axis=1)
            summary['cosine_vs_pytorch'] = {
                'min': float(agreement.min()), 'median': float(np.median(agreement)),
                'mean': float(agreement.mean())}
    write(name + '-timing', summary)
    agreement = summary.get('cosine_vs_pytorch')
    print(f'{name}: {len(matrix)} x {matrix.shape[1]}; p50 {summary["p50_seconds"]*1000:.1f} ms; '
          f'p95 {summary["p95_seconds"]*1000:.1f} ms'
          + (f'; cos vs PyTorch min {agreement["min"]:.4f} median {agreement["median"]:.4f}'
             if agreement else ''), flush=True)


def serve(label, command, batches):
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1', PORT)) == 0:
            raise RuntimeError('Disposable port occupied; refusing to stop another process')
    RESULTS.mkdir(parents=True, exist_ok=True)
    log = (RESULTS / (label + '-server.log')).open('w')
    started = time.perf_counter()
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    sampler = MemorySampler(process.pid)
    session = requests.Session()
    session.trust_env = False
    session.headers['Authorization'] = 'Bearer ' + TOKEN
    base = f'http://127.0.0.1:{PORT}'

    def encode(inputs):
        vectors, timings, tokens = [], [], []
        for item in inputs:
            begin = time.perf_counter()
            response = session.post(base + '/v1/embeddings', json={
                'model': label, 'input': [item], 'cache_prompt': False}, timeout=120)
            if response.status_code != 200:
                raise RuntimeError(f'{response.status_code}: {response.text[:500]}')
            body = response.json()
            assert len(body['data']) == 1
            vectors.append(body['data'][0]['embedding'])
            timings.append(time.perf_counter() - begin)
            tokens.append(body.get('usage', {}).get('prompt_tokens'))
        return vectors, timings, tokens

    try:
        for _ in range(600):
            if process.poll() is not None:
                raise RuntimeError(f'{label} exited; inspect {log.name}')
            try:
                if session.get(base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            raise TimeoutError(f'{label} startup timed out')
        startup = time.perf_counter() - started
        warm = batches[0][1][0]
        encode([warm])
        for name, inputs in batches:
            if isinstance(inputs[0], dict):
                encode([inputs[0]])  # first image pays one-off encoder warm-up
            record(name, *encode(inputs))
        write(label + '-runtime', {
            'runtime': subprocess.check_output([str(BINARY), '--version'], stderr=subprocess.STDOUT,
                                               text=True).strip(),
            'startup_seconds': startup, 'peak_rss_bytes': sampler.peak,
            'arguments': [arg if arg != TOKEN else '<disposable token>' for arg in command],
        })
        print(f'{label}: startup {startup:.2f} s; peak RSS {sampler.peak / 2**30:.2f} GiB', flush=True)
    finally:
        sampler.stop()
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        session.close()
        log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['harrier', 'gemma-text', 'gemma-vision'])
    # Re-qualify another build (for example the vendored source build) without
    # overwriting the published b11469 results.
    parser.add_argument('--binary', type=Path, help='llama-server to run (default: b11469 release)')
    parser.add_argument('--results', type=Path, help='output folder (default: ROOT/results)')
    arguments = parser.parse_args()
    mode = arguments.mode
    global BINARY, RESULTS
    BINARY = arguments.binary or BINARY
    RESULTS = arguments.results or RESULTS
    text = json.loads((BASELINE / 'fixtures/text.json').read_text())
    screen = json.loads((BASELINE / 'fixtures/screens.json').read_text())
    ocr = {row['id']: row['text'] for row in json.loads((BASELINE / 'ocr.json').read_text())}
    common = ['--host', '127.0.0.1', '--port', str(PORT), '-ngl', '99', '--parallel', '1',
              '--no-webui', '--embeddings', '--api-key', TOKEN]
    if mode == 'harrier':
        verify(HARRIER)
        command = [str(BINARY), '-m', str(HARRIER), '-c', '2048', '--pooling', 'last',
                   '--cache-ram', '256', *common]
        batches = [
            ('harrier-gguf-text-documents', [TEXT_DOCUMENT + d['text'] for d in text['documents']]),
            ('harrier-gguf-text-queries', [TEXT_QUERY + q['query'] for q in text['queries']]),
            ('harrier-gguf-screen-documents', [SCREEN_DOCUMENT + ocr[d['id']][:1500] for d in screen['documents']]),
            ('harrier-gguf-screen-queries', [SCREEN_QUERY + q['query'] for q in screen['queries']]),
            ('harrier-gguf-repeated-queries', [TEXT_QUERY + q['query'] for q in text['queries'][:12]] * 3),
        ]
    elif mode == 'gemma-text':
        verify(GEMMA)
        command = [str(BINARY), '-m', str(GEMMA), '-c', '8192', '-b', '8192', '-ub', '8192', *common]
        batches = [
            ('gemma-gguf-text-documents', [GEMMA_DOCUMENT + d['text'] for d in text['documents']]),
            ('gemma-gguf-text-queries', [GEMMA_QUERY + q['query'] for q in text['queries']]),
            ('gemma-gguf-ocr-documents', [GEMMA_DOCUMENT + ocr[d['id']][:1500] for d in screen['documents']]),
            ('gemma-gguf-ocr-queries', [GEMMA_QUERY + q['query'] for q in screen['queries']]),
            ('gemma-gguf-repeated-queries', [GEMMA_QUERY + q['query'] for q in text['queries'][:12]] * 3),
        ]
    else:
        verify(GEMMA)
        verify(MMPROJ)
        command = [str(BINARY), '-m', str(GEMMA), '--mmproj', str(MMPROJ), '-c', '8192',
                   '-b', '8192', '-ub', '8192', *common]
        images = {d['id']: (BASELINE / d['image'] if not Path(d['image']).is_absolute() else Path(d['image']))
                  for d in screen['documents']}
        batches = [
            ('gemma-gguf-image-queries', [GEMMA_QUERY + q['query'] for q in screen['queries']]),
            ('gemma-gguf-image-documents', [{'content': [image_part(images[d['id']])]}
                                            for d in screen['documents']]),
            ('gemma-gguf-combined-documents', [{'content': [
                {'type': 'text', 'text': GEMMA_DOCUMENT + ocr[d['id']][:1500] + ' '},
                image_part(images[d['id']])]} for d in screen['documents']]),
        ]
    serve(mode, command, batches)


if __name__ == '__main__':
    sys.exit(main())
