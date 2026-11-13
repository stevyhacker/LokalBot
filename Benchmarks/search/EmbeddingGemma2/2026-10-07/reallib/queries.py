"""Write one English and one BCS search query per target with a local model.

Runs the installed Qwen3.5-4B on a disposable llama-server port, so passages
never leave the Mac. Qwen is a different model family from EmbeddingGemma;
Harrier is Qwen-derived, so any generator bias favours the incumbent.
Resumable: finished targets are kept, and `--limit` caps one batch.
"""
import argparse
import json
import secrets
import socket
import subprocess
import time
from pathlib import Path

import requests

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-reallib')
REPO = Path(__file__).resolve().parents[5]
SERVER = REPO / 'Vendor/llama-cpp/llama-server'
MODEL = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/Qwen3.5-4B-Q4_K_M.gguf'
PORT = 18973
OUTPUT = ROOT / 'queries.jsonl'
LANGUAGES = {'en': 'English', 'bcs': 'Serbian/Montenegrin in Latin script'}
KIND = {'meetings': 'a meeting transcript or meeting summary',
        'screens': 'text read by OCR from a screenshot of the user\'s screen'}
SCHEMA = {
    'type': 'object',
    'properties': {
        'skip': {'type': 'boolean'},
        'query_en': {'type': 'string'},
        'query_bcs': {'type': 'string'},
    },
    'required': ['skip', 'query_en', 'query_bcs'],
}
SYSTEM = (
    'You write evaluation queries for a private, local search engine over a person\'s own meetings '
    'and screen history. Given one passage, write what that person might type weeks later to find '
    'this exact passage again.')


def prompt(kind, text):
    return (
        f'The passage below is {KIND[kind]}.\n\n'
        'Write two search queries for it, each 4 to 12 words: `query_en` in English and `query_bcs` '
        'in Serbian/Montenegrin (Latin script). Both should ask for the same thing.\n'
        '- Target the specific facts, decisions, names, numbers or problems that make this passage '
        'different from other passages, not a generic topic.\n'
        '- Phrase it the way someone recalls it from memory: paraphrase, and do not copy phrases of '
        'more than three words from the passage.\n'
        '- Ignore window chrome, menus and navigation text.\n'
        '- Set `skip` to true, with empty queries, only if the passage has nothing anyone would '
        'search for later (pure small talk, noise, or UI chrome only).\n\n'
        f'Passage:\n"""\n{text}\n"""')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--limit', type=int, default=140)
    limit = parser.parse_args().limit
    corpus = {row['id']: row for name in ('meetings', 'screens')
              for row in json.loads((ROOT / f'corpus/{name}.json').read_text())}
    targets = json.loads((ROOT / 'corpus/targets.json').read_text())
    done = set()
    if OUTPUT.exists():
        done = {json.loads(line)['target'] for line in OUTPUT.read_text().splitlines()}
    pending = [t for t in targets if t['target'] not in done][:limit]
    if not pending:
        print(f'all {len(targets)} targets done')
        return
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1', PORT)) == 0:
            raise RuntimeError('Disposable port occupied; refusing to stop another process')
    token = secrets.token_hex(16)
    log = (ROOT / 'qwen-server.log').open('a')
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
                raise RuntimeError('Qwen server exited; inspect qwen-server.log')
            try:
                if session.get(base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            raise TimeoutError('Qwen startup timed out')
        with OUTPUT.open('a') as output:
            for index, target in enumerate(pending, 1):
                row = corpus[target['target']]
                response = session.post(base + '/v1/chat/completions', json={
                    'messages': [{'role': 'system', 'content': SYSTEM},
                                 {'role': 'user', 'content': prompt(target['corpus'], row['text'])}],
                    'temperature': 0.2, 'seed': 61007, 'max_tokens': 200,
                    'response_format': {'type': 'json_schema', 'json_schema': {'schema': SCHEMA}},
                    'chat_template_kwargs': {'enable_thinking': False},
                }, timeout=120)
                response.raise_for_status()
                content = json.loads(response.json()['choices'][0]['message']['content'])
                output.write(json.dumps({**target, **content}, ensure_ascii=False) + '\n')
                output.flush()
                if index % 25 == 0:
                    print(f'{index}/{len(pending)} in {time.perf_counter() - started:.0f} s', flush=True)
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
