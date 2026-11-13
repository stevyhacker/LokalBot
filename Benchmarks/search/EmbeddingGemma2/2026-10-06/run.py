"""Serial, offline inference against frozen synthetic inputs; no app writes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import threading
import time

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'

import numpy as np
import psutil
import requests

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-20261006')
RESULTS = ROOT / 'results'
REPO = Path(__file__).resolve().parents[4]
BINARY = Path('/Applications/LokalBot.app/Contents/Resources/llama-cpp/llama-server')
HARRIER = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/harrier-oss-v1-0.6b.Q8_0.gguf'
PORT = 18786
TOKEN = 'disposable-synthetic-embedding-benchmark'
TEXT_DOCUMENT = 'Document for meeting search: '
TEXT_QUERY = "Instruct: Retrieve relevant meeting transcript and summary chunks for the user's query.\nQuery:"
SCREEN_DOCUMENT = 'Document from screen memory: '
SCREEN_QUERY = "Instruct: Retrieve relevant OCR text captured from the user's screen.\nQuery:"


def write(name, value):
    RESULTS.mkdir(parents=True, exist_ok=True)
    target = RESULTS / (name + '.json')
    partial = target.with_suffix('.json.part')
    partial.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    partial.replace(target)


def check_freeze():
    hashes = json.loads((ROOT / 'fixture-freeze.json').read_text())
    for name, digest in hashes.items():
        assert hashlib.sha256((ROOT / 'fixtures' / name).read_bytes()).hexdigest() == digest, name


def normalize(values):
    values = np.asarray(values, dtype=np.float32)
    assert values.ndim == 2 and np.isfinite(values).all()
    norms = np.linalg.norm(values, axis=1, keepdims=True)
    assert np.all(norms > 0)
    return values / norms


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


def record_vectors(name, vectors, timings):
    matrix = normalize(vectors)
    np.save(RESULTS / (name + '.npy'), matrix)
    assert len(matrix) == len(timings)
    write(name + '-timing', {
        'count': len(timings), 'dimension': matrix.shape[1],
        'total_seconds': sum(timings), 'p50_seconds': statistics.median(timings),
        'p95_seconds': float(np.percentile(timings, 95)), 'seconds': timings,
        'vectors_sha256': hashlib.sha256((RESULTS / (name + '.npy')).read_bytes()).hexdigest(),
    })
    print(f'{name}: {len(matrix)} embeddings; p50 {statistics.median(timings)*1000:.1f} ms; '
          f'p95 {np.percentile(timings,95)*1000:.1f} ms', flush=True)


def harrier():
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1', PORT)) == 0:
            raise RuntimeError('Disposable port occupied; refusing to stop another process')
    with HARRIER.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    assert digest == 'ba2c9408f82cfdb73aaf70aaea9f125f3fb24c5e76ce0efb469e1530e5ec53e4'
    command = [str(BINARY), '-m', str(HARRIER), '--host', '127.0.0.1', '--port', str(PORT),
               '-c', '2048', '-ngl', '99', '--parallel', '1', '--no-webui',
               '--embeddings', '--pooling', 'last', '--cache-ram', '256', '--api-key', TOKEN]
    log = (RESULTS / 'harrier-server.log').open('w')
    start = time.perf_counter()
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    sampler = MemorySampler(process.pid)
    session = requests.Session()
    session.trust_env = False
    session.headers['Authorization'] = 'Bearer ' + TOKEN
    base = f'http://127.0.0.1:{PORT}'

    def encode(inputs):
        vectors, timings = [], []
        for item in inputs:
            started = time.perf_counter()
            response = session.post(base + '/v1/embeddings', json={
                'model': 'harrier-oss-v1-0.6b-q8', 'input': [item], 'cache_prompt': False,
            }, timeout=120)
            response.raise_for_status()
            rows = response.json()['data']
            assert len(rows) == 1
            vectors.append(rows[0]['embedding'])
            timings.append(time.perf_counter() - started)
        return vectors, timings

    try:
        for _ in range(600):
            if process.poll() is not None:
                raise RuntimeError('Harrier exited; inspect isolated server log')
            try:
                if session.get(base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            raise TimeoutError('Harrier startup timed out')
        startup = time.perf_counter() - start
        encode([TEXT_QUERY + 'Warm up using this unrelated sentence.'])
        text = json.loads((ROOT / 'fixtures/text.json').read_text())
        screen = json.loads((ROOT / 'fixtures/screens.json').read_text())
        ocr = {row['id']: row['text'] for row in json.loads((ROOT / 'ocr.json').read_text())}
        batches = {
            'harrier-text-documents': [TEXT_DOCUMENT + doc['text'] for doc in text['documents']],
            'harrier-text-queries': [TEXT_QUERY + query['query'] for query in text['queries']],
            'harrier-screen-documents': [SCREEN_DOCUMENT + ocr[doc['id']][:1500] for doc in screen['documents']],
            'harrier-screen-queries': [SCREEN_QUERY + query['query'] for query in screen['queries']],
            'harrier-repeated-queries': [TEXT_QUERY + query['query'] for query in text['queries'][:12]] * 3,
        }
        for name, inputs in batches.items():
            vectors, timings = encode(inputs)
            record_vectors(name, vectors, timings)
        write('harrier-runtime', {
            'runtime': subprocess.check_output([str(BINARY), '--version'], stderr=subprocess.STDOUT, text=True).strip(),
            'binary_sha256': hashlib.sha256(BINARY.read_bytes()).hexdigest(),
            'model_sha256': digest, 'model_bytes': HARRIER.stat().st_size,
            'context_tokens': 2048, 'pooling': 'last', 'quantization': 'Q8_0',
            'startup_seconds': startup, 'peak_rss_bytes': sampler.peak,
            'arguments': [arg if arg != TOKEN else '<disposable token>' for arg in command],
        })
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


def gemma(vision=False):
    import torch
    from sentence_transformers import SentenceTransformer
    from importlib.metadata import version
    assert torch.backends.mps.is_available(), 'MPS unavailable: run with authorized Metal access'
    torch.set_num_threads(8)
    torch.manual_seed(61006)
    sampler = MemorySampler(os.getpid())
    started = time.perf_counter()
    config = {'audio_config': None}
    if not vision:
        config['vision_config'] = None
    model = SentenceTransformer(
        str(ROOT / 'model'), device='mps', trust_remote_code=False, local_files_only=True,
        config_kwargs=config, model_kwargs={'dtype': torch.bfloat16, 'attn_implementation': 'eager'},
    )
    # The published tokenizer uses an unbounded sentinel. Apply the documented
    # 8K shared input window explicitly rather than inheriting that sentinel.
    model.max_seq_length = 8192
    model.eval()
    torch.mps.synchronize()
    startup = time.perf_counter() - started
    label = 'gemma-vision' if vision else 'gemma-text'
    print(f'{label}: loaded {sum(p.numel() for p in model.parameters()):,} parameters', flush=True)

    def encode(inputs, prompt_name=None):
        vectors, timings = [], []
        for index, item in enumerate(inputs):
            torch.mps.synchronize()
            start = time.perf_counter()
            with torch.inference_mode():
                vector = model.encode(item, prompt_name=prompt_name, batch_size=1,
                                      normalize_embeddings=True, show_progress_bar=False)
            torch.mps.synchronize()
            timings.append(time.perf_counter() - start)
            vectors.append(np.asarray(vector, dtype=np.float32))
            if (index + 1) % 20 == 0:
                print(f'{label}: {index+1}/{len(inputs)} inputs', flush=True)
        return vectors, timings

    encode(['Warm up using this unrelated sentence.'], 'SearchQuery')
    text = json.loads((ROOT / 'fixtures/text.json').read_text())
    screen = json.loads((ROOT / 'fixtures/screens.json').read_text())
    ocr = {row['id']: row['text'] for row in json.loads((ROOT / 'ocr.json').read_text())}
    if vision:
        encode([{'image': screen['documents'][0]['image']}])
        batches = [
            ('gemma-image-documents', [{'image': doc['image']} for doc in screen['documents']], None),
            ('gemma-image-queries', [query['query'] for query in screen['queries']], 'SearchQuery'),
            ('gemma-combined-documents', [{'text': 'title: none | text: ' + ocr[doc['id']][:1500] + ' <|image|>',
                                          'image': doc['image']} for doc in screen['documents']], None),
        ]
    else:
        batches = [
            ('gemma-text-documents', [doc['text'] for doc in text['documents']], 'Document'),
            ('gemma-text-queries', [query['query'] for query in text['queries']], 'SearchQuery'),
            ('gemma-ocr-documents', [ocr[doc['id']][:1500] for doc in screen['documents']], 'Document'),
            ('gemma-ocr-queries', [query['query'] for query in screen['queries']], 'SearchQuery'),
            ('gemma-repeated-queries', [query['query'] for query in text['queries'][:12]] * 3, 'SearchQuery'),
        ]
    try:
        for name, inputs, prompt in batches:
            vectors, timings = encode(inputs, prompt)
            record_vectors(name, vectors, timings)
        write(label + '-runtime', {
            'runtime': 'SentenceTransformers / PyTorch MPS', 'precision': 'BF16',
            'parameters': sum(p.numel() for p in model.parameters()),
            'startup_seconds': startup, 'peak_rss_bytes': sampler.peak,
            'mps_allocated_bytes': torch.mps.current_allocated_memory(),
            'mps_driver_bytes': torch.mps.driver_allocated_memory(),
            'config_overrides': config, 'attention': 'eager', 'device': 'mps',
            'packages': {name: version(name) for name in ['torch', 'transformers', 'sentence-transformers', 'numpy']},
            'prompts': model.prompts, 'maximum_sequence_length': model.max_seq_length,
        })
    finally:
        sampler.stop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['harrier', 'gemma-text', 'gemma-vision'])
    args = parser.parse_args()
    RESULTS.mkdir(parents=True, exist_ok=True)
    check_freeze()
    write(args.mode + '-environment', {
        'platform': platform.platform(), 'python': platform.python_version(),
        'repository_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
        'fixture_freeze_sha256': hashlib.sha256((ROOT / 'fixture-freeze.json').read_bytes()).hexdigest(),
        'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'hardware': {'chip': 'Apple M4 Max', 'ram_gib': 48},
    })
    if args.mode == 'harrier':
        harrier()
    else:
        gemma(vision=args.mode == 'gemma-vision')
