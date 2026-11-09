"""Shared helpers: start the vendored llama-server like the app does, size images like DigUp, read memory."""
import base64
import ctypes
import io
import math
import os
import secrets
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
import requests
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
# Scripts/fetch-llama.sh builds it (v0.7.0, b11669). LLAMA_SERVER points at another build, such as a worktree's
# main checkout.
SERVER = Path(os.environ.get('LLAMA_SERVER', REPO / 'Vendor/llama-cpp/llama-server'))
APP_MODELS = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models'
# Read only: the app's verified text model. MMPROJ is the projector downloaded per model-checksums.txt.
TEXT_MODEL = Path(os.environ.get('TEXT_MODEL', APP_MODELS / 'embeddinggemma-2-Q8_0.gguf'))
MMPROJ = Path(os.environ.get('MMPROJ', '/private/tmp/lokalbot-media-embedder-20261030/models/'
                                       'mmproj-embeddinggemma-2-Q8_0.gguf'))
PORT = 18791

# `LlamaServer.start` plus the embedder role's `extraArgs` (LlamaServer.swift), without the port and token.
APP_EMBEDDER_ARGS = ['-c', '2048', '-ngl', '99', '--jinja', '--no-webui',
                     '--embeddings', '-b', '2048', '-ub', '2048', '--parallel', '1']
# DigUp's media context (LlamaEmbedder.swift): images arrive at their final size, so mtmd never rescales them.
SIZED_MEDIA_ARGS = ['--image-min-tokens', '1', '--image-max-tokens', '1120']

QUERY_PREFIX = 'task: search result | query: '


def document(title, text):
    return f"title: {title or 'none'} | text: {text}"


# MARK: Memory

class _RUsage(ctypes.Structure):
    # rusage_info_v4 (<sys/resource.h>): a 16-byte UUID, then 64-bit counters. Index 6 is ri_resident_size, 7
    # ri_phys_footprint and 28 ri_lifetime_max_phys_footprint; the tail is padding in case a later flavor writes more.
    _fields_ = [('uuid', ctypes.c_uint8 * 16), ('values', ctypes.c_uint64 * 64)]


_libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
_RUSAGE_INFO_V4 = 4


def footprint(pid):
    """(current, lifetime peak) physical footprint and current RSS, in bytes. The footprint is what Activity Monitor
    calls Memory: it leaves out clean file-backed pages, such as the mapped model, which RSS counts."""
    info = _RUsage()
    if _libproc.proc_pid_rusage(pid, _RUSAGE_INFO_V4, ctypes.byref(info)) != 0:
        return None
    return info.values[7], info.values[28], info.values[6]


class Sampler:
    """Polls the server's footprint and RSS every 20 ms, for their peaks during one stretch of work."""

    def __init__(self, pid):
        self.pid, self.peak, self.peak_resident, self._active = pid, 0, 0, True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        while self._active:
            sample = footprint(self.pid)
            if sample is None:
                return
            self.peak = max(self.peak, sample[0])
            self.peak_resident = max(self.peak_resident, sample[2])
            time.sleep(.02)

    def stop(self):
        self._active = False
        self._thread.join()
        return self.peak


# MARK: Server

class Server:
    """The vendored llama-server on a private port, with a bearer token, as `LlamaServer.start` runs it."""

    def __init__(self, extra=(), model=TEXT_MODEL, binary=SERVER):
        self.token = secrets.token_hex(16)
        self.base = f'http://127.0.0.1:{PORT}'
        # A file, not a pipe: the server logs every request, and an unread pipe fills and stalls it.
        self.log = tempfile.TemporaryFile(mode='w+')
        self.process = subprocess.Popen(
            [str(binary), '-m', str(model), '--host', '127.0.0.1', '--port', str(PORT),
             '--api-key', self.token, *APP_EMBEDDER_ARGS, *extra],
            stdout=subprocess.DEVNULL, stderr=self.log)
        self.session = requests.Session()
        self.session.trust_env = False
        self.session.headers['Authorization'] = 'Bearer ' + self.token
        started = time.perf_counter()
        while time.perf_counter() - started < 120:
            if self.process.poll() is not None:
                self.log.seek(0)
                raise RuntimeError('llama-server exited: ' + self.log.read()[-2000:])
            try:
                if self.session.get(self.base + '/health', timeout=1).status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            self.close()
            raise RuntimeError('llama-server did not become healthy')
        self.load_seconds = time.perf_counter() - started

    @property
    def pid(self):
        return self.process.pid

    def post(self, path, body, timeout=300):
        started = time.perf_counter()
        response = self.session.post(self.base + path, json=body, timeout=timeout)
        return response, time.perf_counter() - started

    def embed(self, inputs, path='/v1/embeddings'):
        """One request; returns (vectors in input order, response JSON, seconds). Raises on HTTP errors."""
        response, seconds = self.post(path, {'input': inputs, 'model': 'embeddinggemma-2-q8', 'cache_prompt': False})
        if response.status_code != 200:
            raise RuntimeError(f'HTTP {response.status_code}: {response.text[:300]}')
        payload = response.json()
        rows = sorted(payload['data'], key=lambda row: row['index'])
        return [normalized(row['embedding']) for row in rows], payload, seconds

    def close(self):
        self.session.close()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def normalized(values):
    vector = np.asarray(values, dtype=np.float64)
    norm = np.linalg.norm(vector)
    return vector / norm if norm > 0 else vector


def cosine(a, b):
    return float(np.dot(normalized(a), normalized(b)))


# MARK: Media inputs

def target_size(height, width, budget):
    """DigUp's `ImageSizing.targetSize`: transformers' Gemma 4 processor fills `budget` soft tokens (each 3 × 3
    patches of 16 px), keeping the aspect ratio, each side rounded down to a multiple of 48 px."""
    if height <= 0 or width <= 0:
        return None
    patch, pooling = 16, 3
    max_patches = budget * pooling * pooling
    factor = math.sqrt(max_patches * patch * patch / (height * width))
    side = pooling * patch
    target_height = int(math.floor(factor * height / side)) * side
    target_width = int(math.floor(factor * width / side)) * side
    if target_height == 0 and target_width == 0:
        return None
    max_side = (max_patches // (pooling * pooling)) * side
    if target_height == 0:
        target_height, target_width = side, min(width // height * side, max_side)
    elif target_width == 0:
        target_width, target_height = side, min(height // width * side, max_side)
    return target_height, target_width


def sized_png(image, budget):
    """The image resized for `budget` with Pillow's bicubic filter (DigUp's Swift port matches it bit for bit),
    as PNG bytes, so the server decodes exactly these pixels."""
    image = image.convert('RGB')
    target = target_size(image.height, image.width, budget)
    if target is None:
        raise ValueError('image too thin to embed')
    if (image.height, image.width) != target:
        image = image.resize((target[1], target[0]), Image.BICUBIC)
    buffer = io.BytesIO()
    image.save(buffer, 'PNG')
    return buffer.getvalue()


def image_part(data, mime='image/png'):
    return {'content': [{'type': 'image_url',
                         'image_url': {'url': f'data:{mime};base64,' + base64.b64encode(data).decode()}}]}


def audio_part(wav_bytes):
    return {'content': [{'type': 'input_audio',
                         'input_audio': {'data': base64.b64encode(wav_bytes).decode(), 'format': 'wav'}}]}


def percentile(values, q):
    return float(np.percentile(np.asarray(values), q)) if values else float('nan')
