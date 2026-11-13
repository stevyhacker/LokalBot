"""GPU phase: write queries with Qwen3-VL, then embed queries, screen text and
screenshots with EmbeddingGemma 2. Everything stops at a wall-clock budget
(default 300 s, model loads included); the corpus is whatever got embedded.

    python run.py [--budget 300] [--smoke IMAGE]

`--smoke` runs one synthetic image through both servers and writes nothing.
Outputs stay under ROOT/private.
"""
import argparse
import base64
import json
import secrets
import socket
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import requests

ROOT = Path('/private/tmp/lokalbot-screen-images-20261013')
PRIVATE = ROOT / 'private'
REPO = Path(__file__).resolve().parents[4]
BINARY = REPO / 'Vendor/llama-cpp/llama-server'
GEMMA = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/embeddinggemma-2-Q8_0.gguf'
GEMMA_MMPROJ = ROOT / 'mmproj/mmproj-embeddinggemma-2-Q8_0.gguf'
QWEN_DIR = next((Path.home() / '.cache/huggingface/hub/models--unsloth--Qwen3-VL-8B-Instruct-GGUF/snapshots').iterdir())
QWEN = QWEN_DIR / 'Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf'
QWEN_MMPROJ = QWEN_DIR / 'mmproj-F16.gguf'
GEMMA_QUERY = 'task: search result | query: '      # EmbeddingIndex.queryPrefix
GEMMA_DOCUMENT = 'title: none | text: '            # EmbeddingIndex.documentPrefix
PORT = 18461
WRITER_SHARE = 0.40  # of the budget, model load included

WRITER_PROMPT = """This is a screenshot of someone's Mac screen, captured by a screen-memory app days ago.
Write three search queries this person might type later to find this exact moment again.

- content_en: what the screen was about (topic, task, document, conversation, names), in English, 3 to 10 words, the way a person remembers it. Do not copy long strings from the screen.
- appearance_en: what the screen looked like (kind of app or page, layout, charts, photos, diagrams, icons, colours), in English, 3 to 10 words. Avoid quoting on-screen text.
- content_bcs: the content query written in Serbian/Montenegrin, Latin script.

Set skip to true only if the screen is blank, a lock screen, or has nothing to remember."""

WRITER_SCHEMA = {
    'type': 'object',
    'properties': {
        'skip': {'type': 'boolean'},
        'content_en': {'type': 'string'},
        'appearance_en': {'type': 'string'},
        'content_bcs': {'type': 'string'},
    },
    'required': ['skip', 'content_en', 'appearance_en', 'content_bcs'],
}


def image_url(path):
    return {'url': 'data:image/png;base64,' + base64.b64encode(Path(path).read_bytes()).decode()}


class Server:
    def __init__(self, label, arguments, deadline):
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', PORT)) == 0:
                raise RuntimeError(f'port {PORT} occupied; refusing to touch another process')
        self.token = secrets.token_hex(16)
        self.log = (PRIVATE / f'{label}-server.log').open('w')
        self.process = subprocess.Popen(
            [str(BINARY), '--host', '127.0.0.1', '--port', str(PORT), '-ngl', '99', '--parallel', '1',
             '--no-webui', '--api-key', self.token, *arguments],
            stdout=self.log, stderr=subprocess.STDOUT)
        self.session = requests.Session()
        self.session.trust_env = False
        self.session.headers['Authorization'] = 'Bearer ' + self.token
        self.base = f'http://127.0.0.1:{PORT}'
        started = time.perf_counter()
        while time.perf_counter() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f'{label} exited; see {self.log.name}')
            try:
                if self.session.get(self.base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            self.close()
            raise TimeoutError(f'{label} did not start before the budget ran out')
        self.startup = time.perf_counter() - started

    def post(self, path, body):
        response = self.session.post(self.base + path, json=body, timeout=60)
        if response.status_code != 200:
            raise RuntimeError(f'{response.status_code}: {response.text[:300]}')
        return response.json()

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.session.close()
        self.log.close()


def writer_server(deadline):
    return Server('writer', ['-m', str(QWEN), '--mmproj', str(QWEN_MMPROJ), '-c', '4096',
                             '--jinja', '--image-max-tokens', '768', '--cache-ram', '0'], deadline)


def embed_server(deadline):
    # App embedder arguments (EmbeddingGemma 2 report, 7 Oct) plus the projector.
    return Server('embedder', ['-m', str(GEMMA), '--mmproj', str(GEMMA_MMPROJ), '-c', '2048',
                               '-b', '2048', '-ub', '2048', '--embeddings', '--jinja',
                               '--cache-ram', '0'], deadline)


def write_queries(server, image):
    body = server.post('/v1/chat/completions', {
        'messages': [{'role': 'user', 'content': [
            {'type': 'image_url', 'image_url': image_url(image)},
            {'type': 'text', 'text': WRITER_PROMPT}]}],
        'temperature': 0, 'max_tokens': 220, 'cache_prompt': False,
        'response_format': {'type': 'json_schema', 'json_schema': {'name': 'queries', 'schema': WRITER_SCHEMA}},
    })
    return json.loads(body['choices'][0]['message']['content']), body.get('usage', {})


def embed(server, inputs):
    body = server.post('/v1/embeddings', {'input': inputs, 'cache_prompt': False})
    data = sorted(body['data'], key=lambda item: item['index'])
    vectors = np.array([item['embedding'] for item in data], dtype=np.float32)
    return vectors / np.linalg.norm(vectors, axis=1, keepdims=True), body.get('usage', {})


def smoke(image):
    deadline = time.perf_counter() + 120
    server = writer_server(deadline)
    try:
        queries, usage = write_queries(server, image)
        print('writer ok:', sorted(queries), usage.get('prompt_tokens'), 'prompt tokens')
    finally:
        server.close()
    server = embed_server(deadline)
    try:
        text, _ = embed(server, [GEMMA_QUERY + 'a bar chart'])
        picture, usage = embed(server, [{'content': [{'type': 'image_url', 'image_url': image_url(image)}]}])
        print('embedder ok:', text.shape, picture.shape, usage.get('prompt_tokens'), 'image tokens',
              f'cosine {float(text[0] @ picture[0]):.3f}')
    finally:
        server.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--budget', type=float, default=300)
    parser.add_argument('--smoke', type=Path)
    arguments = parser.parse_args()
    if arguments.smoke:
        return smoke(arguments.smoke)

    begin = time.perf_counter()
    deadline = begin + arguments.budget
    corpus = json.loads((PRIVATE / 'corpus.json').read_text())
    targets = [shot for shot in corpus if shot['role'] == 'target']
    meta = {'budget_seconds': arguments.budget, 'runtime': subprocess.check_output(
        [str(BINARY), '--version'], stderr=subprocess.STDOUT, text=True).strip().splitlines()[-2:]}

    # Phase 1: queries from pixels only.
    writer_deadline = begin + arguments.budget * WRITER_SHARE
    server = writer_server(writer_deadline)
    meta['writer_startup_seconds'] = server.startup
    queries, writer_times, writer_tokens = [], [], []
    try:
        for shot in targets:
            if time.perf_counter() > writer_deadline:
                break
            started = time.perf_counter()
            try:
                answer, usage = write_queries(server, shot['image'])
            except (RuntimeError, ValueError, KeyError) as error:
                print(f"writer error on target {len(writer_times)}: {str(error)[:120]}", file=sys.stderr)
                continue
            writer_times.append(time.perf_counter() - started)
            writer_tokens.append(usage.get('prompt_tokens'))
            if answer.get('skip'):
                continue
            for kind in ('content_en', 'appearance_en', 'content_bcs'):
                text = answer.get(kind, '').strip()
                if text:
                    queries.append({'target': shot['id'], 'kind': kind, 'text': text})
    finally:
        server.close()
    meta.update(writer_calls=len(writer_times), writer_seconds=sum(writer_times),
                writer_prompt_tokens_median=float(np.median([t for t in writer_tokens if t] or [0])),
                queries=len(queries), targets_with_queries=len({q['target'] for q in queries}))
    (PRIVATE / 'queries.json').write_text(json.dumps(queries, ensure_ascii=False))
    print(f"writer: {meta['targets_with_queries']} targets, {len(queries)} queries, "
          f"{time.perf_counter() - begin:.0f} s elapsed", flush=True)

    # Phase 2: query + screen-text vectors, then screenshots until the budget ends.
    server = embed_server(deadline)
    meta['embedder_startup_seconds'] = server.startup
    try:
        query_vectors = np.concatenate([embed(server, [GEMMA_QUERY + q['text'] for q in queries[i:i + 32]])[0]
                                        for i in range(0, len(queries), 32)])
        text_started = time.perf_counter()
        text_vectors = np.concatenate([
            embed(server, [GEMMA_DOCUMENT + (shot['text'] or ' ') for shot in corpus[i:i + 32]])[0]
            for i in range(0, len(corpus), 32)])
        meta['text_document_seconds'] = time.perf_counter() - text_started
        image_vectors, image_times, image_tokens = [], [], []
        for shot in corpus:
            if time.perf_counter() > deadline - 1:
                break
            started = time.perf_counter()
            vector, usage = embed(server, [{'content': [{'type': 'image_url', 'image_url': image_url(shot['image'])}]}])
            image_times.append(time.perf_counter() - started)
            image_tokens.append(usage.get('prompt_tokens'))
            image_vectors.append(vector[0])
    finally:
        server.close()
    embedded = len(image_vectors)
    np.save(PRIVATE / 'query-vectors.npy', query_vectors)
    np.save(PRIVATE / 'text-vectors.npy', text_vectors[:embedded])
    np.save(PRIVATE / 'image-vectors.npy', np.stack(image_vectors))
    (PRIVATE / 'embedded-ids.json').write_text(json.dumps([shot['id'] for shot in corpus[:embedded]]))
    meta.update(
        images_embedded=embedded,
        image_seconds_p50=float(np.median(image_times)), image_seconds_p95=float(np.percentile(image_times, 95)),
        image_tokens=dict(zip(*map(lambda a: a.tolist(), np.unique(
            [t for t in image_tokens if t is not None], return_counts=True)))),
        total_seconds=time.perf_counter() - begin)
    (PRIVATE / 'run-meta.json').write_text(json.dumps(meta, indent=1, default=str))
    print(json.dumps(meta, indent=1, default=str))


if __name__ == '__main__':
    main()
