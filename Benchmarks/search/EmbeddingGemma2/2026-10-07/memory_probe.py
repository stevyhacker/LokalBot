"""Peak llama-server RSS under app-shaped batched embedding load (content-free)."""
import json
import secrets
import subprocess
import threading
import time
from pathlib import Path

import psutil
import requests

REPO = Path(__file__).resolve().parents[4]
SERVER = REPO / 'Vendor/llama-cpp/llama-server'
MODELS = {
    'gemma': Path('/private/tmp/lokalbot-embeddinggemma2-20261007/models/embeddinggemma-2-Q8_0.gguf'),
    'harrier': Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models/harrier-oss-v1-0.6b.Q8_0.gguf',
}
PREFIX = {'gemma': 'title: none | text: ', 'harrier': 'Document from screen memory: '}
PORT = 18790


def probe(model, extra):
    token = secrets.token_hex(16)
    process = subprocess.Popen(
        [str(SERVER), '-m', str(MODELS[model]), '--host', '127.0.0.1', '--port', str(PORT),
         '--api-key', token, '-c', '2048', '-ngl', '99', '--jinja', '--no-webui', '--embeddings',
         '--parallel', '1', *extra], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    peak, active = [0], [True]

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
    try:
        for _ in range(600):
            try:
                if session.get(base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        idle = peak[0]
        rows = json.loads(Path('/private/tmp/lokalbot-embeddinggemma2-reallib/corpus/screens.json').read_text())
        texts = [PREFIX[model] + row['text'][:1500] for row in rows[:640]]
        started = time.perf_counter()
        for start in range(0, len(texts), 32):
            body = {'input': texts[start:start + 32], 'cache_prompt': False}
            response = session.post(base + '/v1/embeddings', json=body, timeout=300)
            if response.status_code != 200:
                return f'{model} {" ".join(extra)}: HTTP {response.status_code} {response.text[:120]}'
        seconds = time.perf_counter() - started
        return (f'{model:7} {" ".join(extra):28} idle RSS {idle / 2**20:5.0f} MiB  '
                f'peak under load {peak[0] / 2**20:5.0f} MiB  640 screens in {seconds:4.1f} s')
    finally:
        active[0] = False
        process.terminate()
        process.wait(timeout=15)
        session.close()


for model, extra in [
    ('harrier', ['--pooling', 'last', '--cache-ram', '256']),
    ('gemma', ['-b', '2048', '-ub', '2048']),
    ('gemma', ['-b', '2048', '-ub', '2048', '-fa', 'on']),
    ('gemma', ['-b', '1280', '-ub', '1280']),
]:
    print(probe(model, extra), flush=True)
