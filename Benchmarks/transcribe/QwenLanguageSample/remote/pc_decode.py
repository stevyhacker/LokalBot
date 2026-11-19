"""Decode benchmark windows on a llama-server away from the Mac, the way QwenASREngine does.

  python pc_decode.py <job.json>

Standard library only, so it runs on the Windows PC's Python. It starts the job's llama-server
with the app's flags (QwenLlamaASR.Weights.makeServer, LlamaServer.start), then posts each window
to `/completion` exactly as QwenLlamaASR.makeRequest does: speech-swift's prompt, a 16 kHz float
WAV, greedy decoding, and QwenASREngine.maxTokens. Text is cut after the last <asr_text> and
normalized like Transcript.normalizedText. Each (track, layout, language) decode appends one JSON
line with every window's text and time; runs resume.

The job (plan.py writes it):
  {"server": {"exe", "model", "mmproj", "port"}, "output": path,
   "tracks": [{"id", "wav", "windows": {layout: [[start, end], ...]}}],
   "decodes": [{"id", "layout", "language": null | code}, ...]}
"""
import array
import base64
import json
import os
import re
import secrets
import struct
import subprocess
import sys
import time
import urllib.request
import wave

RATE = 16_000
MARKER = '<__media__>'


def prompt(language, context=None):
    return (f'<|im_start|>system\n{context or ""}<|im_end|>\n<|im_start|>user\n{MARKER}<|im_end|>\n'
            f'<|im_start|>assistant\n{"language " + language if language else ""}<asr_text>')


def max_tokens(count):
    return min(768, max(128, int(count / RATE * 18)))


def float_wav(samples):
    data = array.array('f', samples).tobytes()
    header = b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack(
        '<IHHIIHH', 16, 3, 1, RATE, RATE * 4, 4, 32) + b'data' + struct.pack('<I', len(data))
    return header + data


def normalized(raw):
    text = re.sub(r'<\|[^>]*\|>', ' ', raw)
    text = re.sub(r'\s+', ' ', text).strip()
    return text if any(ch.isalnum() for ch in text) else ''


class Track:
    """16 kHz mono PCM16, sliced like SpanAudioReader: both frame positions floored."""

    def __init__(self, path):
        with wave.open(path) as w:
            assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, path
            self.pcm = array.array('h', w.readframes(w.getnframes()))
            if sys.byteorder == 'big':
                self.pcm.byteswap()

    def samples(self, start, end):
        first = min(int(max(0.0, start) * RATE), len(self.pcm))
        last = min(int(max(0.0, end) * RATE), len(self.pcm))
        return [s / 32768.0 for s in self.pcm[first:last]] if last > first else []


class Server:
    def __init__(self, spec):
        self.url = f'http://127.0.0.1:{spec["port"]}'
        self.key = secrets.token_hex(32)
        args = [spec['exe'], '-m', spec['model'], '--host', '127.0.0.1', '--port', str(spec['port']),
                '-c', '4096', '-ngl', '99', '--jinja', '--no-webui', '--api-key', self.key,
                '--mmproj', spec['mmproj'], '--parallel', '1', '--cache-ram', '256']
        log = open(spec.get('log', os.devnull), 'w')
        self.process = subprocess.Popen(args, env={**os.environ, 'LLAMA_MEDIA_MARKER': MARKER},
                                        stdout=log, stderr=log)
        started = time.time()
        while True:
            if self.process.poll() is not None:
                raise SystemExit(f'llama-server exited with {self.process.returncode}')
            try:
                with urllib.request.urlopen(self.url + '/health', timeout=2) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            time.sleep(0.2)
        print(f'server ready in {time.time() - started:.1f}s', flush=True)

    def transcribe(self, samples, language):
        if 0 < len(samples) < 160:
            samples = samples + [0.0] * (160 - len(samples))
        body = {'prompt': {'prompt_string': prompt(language),
                           'multimodal_data': [base64.b64encode(float_wav(samples)).decode()]},
                'n_predict': max_tokens(len(samples)), 'temperature': 0, 'top_k': 1, 'samplers': ['top_k'],
                'repeat_penalty': 1.0, 'cache_prompt': False, 'stream': False}
        request = urllib.request.Request(self.url + '/completion', data=json.dumps(body).encode(), method='POST',
                                         headers={'Content-Type': 'application/json',
                                                  'Authorization': f'Bearer {self.key}'})
        with urllib.request.urlopen(request, timeout=600) as response:
            content = json.loads(response.read())['content']
        cut = content.rfind('<asr_text>')
        return (content[cut + len('<asr_text>'):] if cut >= 0 else content).strip()

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()


def main():
    job = json.load(open(sys.argv[1], encoding='utf-8'))
    done = set()
    if os.path.exists(job['output']):
        for line in open(job['output'], encoding='utf-8'):
            if line.strip():
                r = json.loads(line)
                done.add((r['id'], r['layout'], r['language']))
    pending = [d for d in job['decodes'] if (d['id'], d['layout'], d['language']) not in done]
    if not pending:
        return
    tracks = {t['id']: t for t in job['tracks']}
    server = Server(job['server'])
    try:
        first = tracks[pending[0]['id']]
        warm = Track(first['wav'])
        server.transcribe(warm.samples(0, 5), 'en')  # shader compilation, excluded
        out = open(job['output'], 'a', encoding='utf-8')
        audio = {}
        for d in pending:
            track = tracks[d['id']]
            if track['wav'] not in audio:
                audio = {track['wav']: Track(track['wav'])}
            reader = audio[track['wav']]
            windows, started = [], time.time()
            for index, (start, end) in enumerate(track['windows'][d['layout']]):
                samples = reader.samples(start, end)
                if not samples:
                    continue
                t0 = time.time()
                raw = server.transcribe(samples, d['language'])
                windows.append({'index': index, 'text': normalized(raw), 'seconds': time.time() - t0})
            record = {**d, 'seconds': time.time() - started, 'windows': windows}
            out.write(json.dumps(record, ensure_ascii=False) + '\n')
            out.flush()
            print(f'{d["id"]} {d["layout"]} {d["language"] or "auto"}: {len(windows)} windows, '
                  f'{record["seconds"]:.1f}s', flush=True)
    finally:
        server.stop()


if __name__ == '__main__':
    main()
