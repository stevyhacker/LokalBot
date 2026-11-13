"""Judge whether each model's top result answers its query, blind to model.

Known-item scoring treats every other passage as wrong, but summaries repeat
transcript facts and screens repeat across captures. A local Qwen3.5-4B
judges each unique (query, top passage) pair once, without seeing which
model retrieved it. Resumable; `--limit` caps one batch.
"""
import argparse
import json
import secrets
import socket
import subprocess
import time
from pathlib import Path

import numpy as np
import requests

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-reallib')
REPO = Path(__file__).resolve().parents[5]
SERVER = REPO / 'Vendor/llama-cpp/llama-server'
MODEL = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/Qwen3.5-4B-Q4_K_M.gguf'
PORT = 18974
OUTPUT = ROOT / 'judgments.jsonl'
CONFIGS = ('harrier', 'gemma-768', 'gemma-512')
KIND = {'meetings': 'an excerpt of a meeting transcript or meeting summary',
        'screens': 'text read by OCR from a screenshot of the user\'s screen'}
SCHEMA = {'type': 'object', 'properties': {'answer': {'type': 'string', 'enum': ['yes', 'partly', 'no']}},
          'required': ['answer']}
SYSTEM = ('You judge search results for a private search engine over a person\'s own meetings and '
          'screen history.')
# A first version (boolean, "be strict and literal") rejected 143 of 181
# passages the queries were written from, so it could not be used.


def top_documents():
    """(corpus, query index, config) -> top-1 document index, from saved vectors."""
    queries = json.loads((ROOT / 'queries-embedded.json').read_text())
    tops = {}
    for name in ('meetings', 'screens'):
        selected = [q for q in queries if q['corpus'] == name]
        documents = {
            'harrier': np.load(ROOT / ('vectors/harrier-meetings-documents.npy' if name == 'meetings'
                                       else 'corpus/harrier-screens.npy')),
            'gemma': np.load(ROOT / f'vectors/gemma-{name}-documents.npy'),
        }
        query_vectors = {'harrier': np.load(ROOT / f'vectors/harrier-{name}-queries.npy'),
                         'gemma': np.load(ROOT / f'vectors/gemma-{name}-queries.npy')}
        for config in CONFIGS:
            family = 'harrier' if config == 'harrier' else 'gemma'
            d, q = documents[family], query_vectors[family]
            if config == 'gemma-512':
                d = d[:, :512] / np.linalg.norm(d[:, :512], axis=1, keepdims=True)
                q = q[:, :512] / np.linalg.norm(q[:, :512], axis=1, keepdims=True)
            for index, best in enumerate(np.argmax(q @ d.T, axis=1)):
                tops[(name, index, config)] = int(best)
    return queries, tops


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--limit', type=int, default=450)
    parser.add_argument('--calibrate', action='store_true',
                        help='judge 40 source and 40 random passages per corpus instead')
    arguments = parser.parse_args()
    limit = arguments.limit
    queries, tops = top_documents()
    corpus = {name: json.loads((ROOT / f'corpus/{name}.json').read_text()) for name in ('meetings', 'screens')}
    selected = {name: [q for q in queries if q['corpus'] == name] for name in corpus}
    pairs = sorted({(name, index, doc) for (name, index, _), doc in tops.items()})
    output_path = OUTPUT
    if arguments.calibrate:
        # A usable judge accepts the passage a query was written from and
        # rejects a random passage from the same corpus.
        rng = np.random.default_rng(61007)
        output_path = ROOT / 'judge-calibration.jsonl'
        pairs = []
        for name, rows in selected.items():
            position = {row['id']: i for i, row in enumerate(corpus[name])}
            for index in rng.choice(len(rows), 40, replace=False):
                pairs.append((name, int(index), position[rows[index]['target']]))
                pairs.append((name, int(index), int(rng.integers(len(corpus[name])))))
    done = set()
    if output_path.exists():
        done = {tuple(json.loads(line)['pair']) for line in output_path.read_text().splitlines()}
    pending = [pair for pair in pairs if pair not in done][:limit]
    print(f'{len(pairs)} unique pairs; {len(done)} judged; running {len(pending)}', flush=True)
    if not pending:
        return
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1', PORT)) == 0:
            raise RuntimeError('Disposable port occupied; refusing to stop another process')
    token = secrets.token_hex(16)
    log = (ROOT / 'judge-server.log').open('a')
    process = subprocess.Popen([
        str(SERVER), '-m', str(MODEL), '--host', '127.0.0.1', '--port', str(PORT), '-c', '8192',
        '-ngl', '99', '--parallel', '1', '--jinja', '--no-webui', '--reasoning', 'off',
        '--api-key', token], stdout=log, stderr=subprocess.STDOUT)
    session = requests.Session()
    session.trust_env = False
    session.headers['Authorization'] = 'Bearer ' + token
    base = f'http://127.0.0.1:{PORT}'
    started = time.perf_counter()
    try:
        for _ in range(600):
            if process.poll() is not None:
                raise RuntimeError('judge server exited; inspect judge-server.log')
            try:
                if session.get(base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            raise TimeoutError('judge startup timed out')
        with output_path.open("a") as output:
            for count, (name, index, doc) in enumerate(pending, 1):
                query = selected[name][index]['query']
                text = corpus[name][doc]['text'][:1500]
                content = (
                    f'Search query: {query}\n\n'
                    f'Top result, {KIND[name]}:\n"""\n{text}\n"""\n\n'
                    'Is this the passage the person was looking for? Answer `yes` if it contains what the '
                    'query describes, `partly` if it contains some of it, and `no` if it is about '
                    'something else. The query and result may be in different languages; judge the '
                    'meaning, not the wording.')
                response = session.post(base + '/v1/chat/completions', json={
                    'messages': [{'role': 'system', 'content': SYSTEM}, {'role': 'user', 'content': content}],
                    'temperature': 0, 'seed': 61007, 'max_tokens': 20,
                    'response_format': {'type': 'json_schema', 'json_schema': {'schema': SCHEMA}},
                    'chat_template_kwargs': {'enable_thinking': False},
                }, timeout=120)
                response.raise_for_status()
                answer = json.loads(response.json()['choices'][0]['message']['content'])['answer']
                output.write(json.dumps({'pair': [name, index, doc], 'answer': answer,
                                         'relevant': answer != 'no'}) + '\n')
                output.flush()
                if count % 100 == 0:
                    print(f'{count}/{len(pending)} in {time.perf_counter() - started:.0f} s', flush=True)
        print(f'batch of {len(pending)} done in {time.perf_counter() - started:.0f} s')
    finally:
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
