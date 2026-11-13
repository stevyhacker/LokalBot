"""Transcribe the prepared chunks with each vendor's own STT API.

Keys come from the private env file named in common.KEY_FILE and are never
printed or stored. Uploaded Gemini files are deleted after each request.
"""
import argparse
import base64
import concurrent.futures
from pathlib import Path
import re
import threading
import time

import requests

from common import LANGUAGE, load_manifest, load_output, read_keys, save_output

GEMINI = 'https://generativelanguage.googleapis.com'
DASHSCOPE_DEFAULT = 'https://dashscope-intl.aliyuncs.com'
GEMINI_PROMPT = (
    'Generate a verbatim transcript of the speech in this audio. Write only the spoken words in their '
    'original language, keeping repetitions and false starts, with normal punctuation. Do not add speaker '
    'labels, timestamps, headings, descriptions of non-speech sounds, or commentary. If there is no '
    'intelligible speech, return an empty response.')

# Published list prices on 2026-09-30 (USD). Per-minute rates are the vendors' own
# estimates and are used when a response does not report billable tokens.
PRICES = {
    'gpt-transcribe': {'per_minute': 0.0045},
    'gpt-4o-transcribe': {'per_minute': 0.006},
    'gpt-4o-mini-transcribe': {'per_minute': 0.003},
    # $0.003/min audio in + $0.002/min text out; responses report no output tokens.
    'gemini-3.5-transcribe': {'per_minute': 0.005},
    'gemini-3.8-flash': {'input_per_m': 0.75, 'output_per_m': 3.75},
    'qwen3-asr-flash': {'per_second': 0.000035},
    'qwen-audio-3.1-asr-flash': {'input_per_m': 0.15, 'output_per_m': 0.47},
}

_local = threading.local()
# Client-side request pacing where the account tier's limit is known (requests/min).
RPM = {'gemini-3.5-transcribe': 9}
_pace_lock = threading.Lock()
_next_slot = {}


def pace(system):
    """Block until this system may start another request; waiting is not timed."""
    if system not in RPM:
        return
    with _pace_lock:
        now = time.monotonic()
        slot = max(now, _next_slot.get(system, now))
        _next_slot[system] = slot + 60 / RPM[system]
    time.sleep(max(0.0, slot - now))


def retry_after(exc, attempt):
    match = re.search(r'retry in (\d+(?:\.\d+)?)s', str(exc))
    return float(match.group(1)) + 1 if match else 2 ** (attempt + 1)
# Providers echo masked key fragments in auth errors; never persist them.
KEY_PATTERN = re.compile(r'(sk-[A-Za-z0-9_*\-]{4,}|AIza[0-9A-Za-z_\-]{8,})')


def session():
    if not hasattr(_local, 'session'):
        _local.session = requests.Session()
    return _local.session


class ApiError(Exception):
    def __init__(self, response):
        self.status = response.status_code
        super().__init__(f'HTTP {response.status_code}: {response.text[:500]}')


def check(response):
    if response.status_code >= 400:
        raise ApiError(response)
    return response.json()


def cost(system, usage, seconds):
    price, usage = PRICES[system], usage or {}
    if 'input_per_m' in price and usage.get('input_tokens') is not None:
        return (usage['input_tokens'] * price['input_per_m']
                + (usage.get('output_tokens') or 0) * price['output_per_m']) / 1e6, 'tokens'
    if 'per_second' in price:
        return (usage.get('seconds') or seconds) * price['per_second'], 'seconds'
    if 'per_minute' in price:
        return seconds / 60 * price['per_minute'], 'per-minute estimate'
    return 0.0, 'error response, not billed'


def openai_stt(system, path, keys):
    with open(path, 'rb') as audio:
        data = check(session().post(
            'https://api.openai.com/v1/audio/transcriptions',
            headers={'Authorization': f'Bearer {keys["OPENAI_API_KEY"]}'},
            files={'file': (Path(path).name, audio, 'audio/wav')},
            data={'model': system, 'language': LANGUAGE, 'response_format': 'json'}, timeout=600))
    usage = data.get('usage') or {}
    return data.get('text', ''), {'input_tokens': None, **usage}


def gemini_upload(path, keys):
    size = Path(path).stat().st_size
    start = check_raw(session().post(
        f'{GEMINI}/upload/v1beta/files',
        headers={'x-goog-api-key': keys['GEMINI_API_KEY'], 'X-Goog-Upload-Protocol': 'resumable',
                 'X-Goog-Upload-Command': 'start', 'X-Goog-Upload-Header-Content-Length': str(size),
                 'X-Goog-Upload-Header-Content-Type': 'audio/wav', 'Content-Type': 'application/json'},
        json={'file': {'display_name': Path(path).stem}}, timeout=120))
    upload_url = start.headers['X-Goog-Upload-URL']
    info = check(session().post(upload_url, headers={
        'X-Goog-Upload-Offset': '0', 'X-Goog-Upload-Command': 'upload, finalize',
        'Content-Length': str(size)}, data=Path(path).read_bytes(), timeout=300))['file']
    for _ in range(60):
        if info.get('state', 'ACTIVE') == 'ACTIVE':
            return info
        time.sleep(1)
        info = check(session().get(f'{GEMINI}/v1beta/{info["name"]}',
                                   headers={'x-goog-api-key': keys['GEMINI_API_KEY']}, timeout=60))
    raise RuntimeError(f'Gemini file {info["name"]} did not become active')


def check_raw(response):
    if response.status_code >= 400:
        raise ApiError(response)
    return response


def interaction_text(data):
    if isinstance(data.get('output_text'), str):
        return data['output_text']
    parts = []
    for step in data.get('steps') or data.get('outputs') or []:
        for content in step.get('content') or [step]:
            if content.get('type') == 'text' and content.get('text'):
                parts.append(content['text'])
    return ' '.join(parts)


def gemini_transcribe(system, path, keys):
    info = gemini_upload(path, keys)
    try:
        data = check(session().post(
            f'{GEMINI}/v1beta/interactions', headers={'x-goog-api-key': keys['GEMINI_API_KEY']},
            json={'model': system,
                  'input': [{'type': 'audio', 'uri': info['uri'], 'mime_type': 'audio/wav'}],
                  'generation_config': {'transcription_config': {'language_codes': ['en-US']}}},
            timeout=600))
    finally:
        session().delete(f'{GEMINI}/v1beta/{info["name"]}',
                         headers={'x-goog-api-key': keys['GEMINI_API_KEY']}, timeout=60)
    usage = data.get('usage') or {}
    tokens_in = usage.get('total_input_tokens', usage.get('input_tokens'))
    tokens_out = usage.get('total_output_tokens', usage.get('output_tokens'))
    return interaction_text(data), {'input_tokens': tokens_in, 'output_tokens': tokens_out, 'raw': usage}


def gemini_prompted(system, path, keys):
    audio = base64.b64encode(Path(path).read_bytes()).decode()
    data = check(session().post(
        f'{GEMINI}/v1beta/models/{system}:generateContent',
        headers={'x-goog-api-key': keys['GEMINI_API_KEY']},
        json={'contents': [{'parts': [{'inline_data': {'mime_type': 'audio/wav', 'data': audio}},
                                      {'text': GEMINI_PROMPT}]}]}, timeout=600))
    candidate = (data.get('candidates') or [{}])[0]
    text = ' '.join(p['text'] for p in candidate.get('content', {}).get('parts', [])
                    if p.get('text') and not p.get('thought'))
    meta = data.get('usageMetadata') or {}
    output = (meta.get('candidatesTokenCount') or 0) + (meta.get('thoughtsTokenCount') or 0)
    return text, {'input_tokens': meta.get('promptTokenCount'), 'output_tokens': output,
                  'finish_reason': candidate.get('finishReason'), 'raw': meta}


def qwen_stt(system, path, keys):
    base = keys.get('DASHSCOPE_BASE_URL', DASHSCOPE_DEFAULT).rstrip('/')
    audio = 'data:audio/wav;base64,' + base64.b64encode(Path(path).read_bytes()).decode()
    headers = {'Authorization': f'Bearer {keys["DASHSCOPE_API_KEY"]}'}
    if system.startswith('qwen-audio-'):
        # Qwen-Audio ASR is not served in OpenAI-compatible mode; the native API
        # needs the container format as a top-level parameter.
        try:
            data = check(session().post(
                f'{base}/api/v1/services/aigc/multimodal-generation/generation', headers=headers, timeout=600,
                json={'model': system, 'parameters': {'asr_options': {'language': LANGUAGE}, 'format': 'wav'},
                      'input': {'messages': [{'role': 'user', 'content': [{'audio': audio}]}]}}))
        except ApiError as exc:
            if 'ASR_RESPONSE_HAVE_NO_WORDS' in str(exc):  # its way of returning an empty transcript
                return '', {'input_tokens': None, 'output_tokens': None, 'empty_response': True}
            raise
        text = data['output'].get('text') or data['output'].get('output', {}).get('text', '')
        usage = data.get('usage') or {}
        return text, {'input_tokens': usage.get('input_tokens'), 'output_tokens': usage.get('output_tokens'),
                      'seconds': usage.get('duration'), 'raw': usage}
    data = check(session().post(
        f'{base}/compatible-mode/v1/chat/completions', headers=headers, timeout=600,
        json={'model': system, 'stream': False, 'asr_options': {'language': LANGUAGE},
              'messages': [{'role': 'user', 'content': [
                  {'type': 'input_audio', 'input_audio': {'data': audio}}]}]}))
    usage = data.get('usage') or {}
    return data['choices'][0]['message']['content'], {
        'input_tokens': usage.get('prompt_tokens'), 'output_tokens': usage.get('completion_tokens'),
        'seconds': usage.get('seconds'), 'raw': usage}


PROVIDERS = {
    'gpt-transcribe': (openai_stt, 'OPENAI_API_KEY'),
    'gpt-4o-transcribe': (openai_stt, 'OPENAI_API_KEY'),
    'gpt-4o-mini-transcribe': (openai_stt, 'OPENAI_API_KEY'),
    'gemini-3.5-transcribe': (gemini_transcribe, 'GEMINI_API_KEY'),
    'gemini-3.8-flash': (gemini_prompted, 'GEMINI_API_KEY'),
    'qwen-audio-3.1-asr-flash': (qwen_stt, 'DASHSCOPE_API_KEY'),
    'qwen3-asr-flash': (qwen_stt, 'DASHSCOPE_API_KEY'),
}


def transcribe(system, row, keys, attempts=6):
    call, _ = PROVIDERS[system]
    error, retries = None, 0
    for attempt in range(attempts):
        pace(system)
        begin = time.perf_counter()
        try:
            text, usage = call(system, row['path'], keys)
            latency = time.perf_counter() - begin
            amount, basis = cost(system, usage, row['duration'])
            return {'system': system, 'chunk': row['id'], 'text': (text or '').strip(), 'error': None,
                    'latency_seconds': round(latency, 3), 'audio_seconds': row['duration'],
                    'retries': retries, 'usage': usage, 'cost_usd': round(amount, 6), 'cost_basis': basis}
        except (ApiError, requests.RequestException, KeyError, RuntimeError) as exc:
            error = KEY_PATTERN.sub('<redacted-key>', f'{type(exc).__name__}: {exc}')
            status = getattr(exc, 'status', None)
            if status is not None and status < 500 and status != 429:
                break
            retries += 1
            time.sleep(retry_after(exc, attempt))
    return {'system': system, 'chunk': row['id'], 'text': None, 'error': error, 'retries': retries,
            'audio_seconds': row['duration'], 'cost_usd': 0.0}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('systems', nargs='*', default=list(PROVIDERS))
    parser.add_argument('--set', choices=['meetings', 'ami'], default=None)
    parser.add_argument('--limit', type=int, default=None, help='first N chunks only (smoke test)')
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    keys = read_keys()
    rows = [r for r in load_manifest() if args.set in (None, r['set'])][:args.limit]
    for system in args.systems:
        if not keys.get(PROVIDERS[system][1]):
            print(f'{system}: skipped, {PROVIDERS[system][1]} missing', flush=True)
            continue
        todo = [r for r in rows if args.force or (load_output(system, r['id']) or {}).get('text') is None]
        failures, spent = 0, 0.0
        with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
            for record in pool.map(lambda r: transcribe(system, r, keys), todo):
                save_output(system, record['chunk'], record)
                failures += record['error'] is not None
                spent += record['cost_usd']
                if record['error']:
                    print(f'{system} {record["chunk"]}: {record["error"][:300]}', flush=True)
        print(f'{system}: {len(todo)} requested, {failures} failed, ${spent:.4f}', flush=True)


if __name__ == '__main__':
    main()
