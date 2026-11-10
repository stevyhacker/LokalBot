"""Stream each AMI recording through Muse Voice Transcribe's realtime DIARIZATION mode, like a live call."""
import argparse
import asyncio
import json
import os
import pathlib
import time
import uuid
import wave

import websockets

ROOT = pathlib.Path(os.environ.get('MUSE_BENCH_DATA', '/private/tmp/lokalbot-muse-voice-bench'))
KEY_FILE = pathlib.Path(os.environ.get('STT_BENCH_KEYS', pathlib.Path.home() / '.config/lokalbot-stt-bench.env'))
URL = 'wss://api.meta.ai/v1/asr/realtime'
MODEL = 'muse-voice-transcribe-1.0'
FRAME_MS = 100
IDLE_AFTER_END_SECONDS = 30


def api_key():
    """Read META_API_KEY from the environment or the CloudSTT key file without echoing it."""
    if os.environ.get('META_API_KEY'):
        return os.environ['META_API_KEY']
    if KEY_FILE.exists():
        for line in KEY_FILE.read_text().splitlines():
            name, _, value = line.strip().removeprefix('export ').partition('=')
            if name.strip() == 'META_API_KEY' and value.strip():
                return value.strip().strip('"').strip("'")
    raise SystemExit(f'Set META_API_KEY in the environment or in {KEY_FILE}')


def read_pcm(path, seconds=None):
    with wave.open(str(path)) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2), path
        frames = w.getnframes() if seconds is None else min(w.getnframes(), int(seconds * 16000))
        return w.readframes(frames)


async def exchange(ws, pcm, record, speed):
    """Send audio on a real-time schedule while keeping every server event with its arrival time."""
    frame = 16000 * 2 * FRAME_MS // 1000
    start = time.monotonic()
    last = start

    async def send():
        # Absolute schedule: frame k leaves k frame-durations after the first, like a microphone.
        for k, offset in enumerate(range(0, len(pcm), frame)):
            delay = start + k * FRAME_MS / 1000 / speed - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
            await ws.send(pcm[offset:offset + frame])
        await ws.send(json.dumps({'type': 'endStream'}))
        record['endStreamSeconds'] = time.monotonic() - start

    sender = asyncio.create_task(send())
    try:
        while True:
            try:
                message = await asyncio.wait_for(ws.recv(), 1)
            except TimeoutError:
                if sender.done():
                    sender.result()
                    if time.monotonic() - max(last, start + record['endStreamSeconds']) > IDLE_AFTER_END_SECONDS:
                        record['endedBy'] = 'idle'
                        return
                continue
            except websockets.ConnectionClosedOK:
                record['endedBy'] = 'server'
                return
            if isinstance(message, bytes):
                continue
            last = time.monotonic()
            event = json.loads(message)
            event['wallSeconds'] = last - start
            record['events'].append(event)
            if event.get('type') == 'error':
                raise RuntimeError(event.get('message', 'server error'))
    finally:
        sender.cancel()
        await asyncio.gather(sender, return_exceptions=True)


async def stream(item, key, url=URL, speed=1.0, seconds=None):
    pcm = read_pcm(item['audio'], seconds)
    record = {'id': item['id'], 'model': MODEL, 'mode': 'DIARIZATION', 'audioEncoding': 'PCM_16KHZ',
              'endpoint': url, 'frameMs': FRAME_MS, 'speed': speed, 'duration': len(pcm) / 32000, 'events': []}
    session = f"lokalbot-bench-{item['id']}-{uuid.uuid4().hex[:8]}"
    async with websockets.connect(f'{url}?sessionId={session}', max_size=None) as ws:
        await ws.send(json.dumps({'authorization': {'accessToken': 'Bearer ' + key},
                                  'audioEncoding': 'PCM_16KHZ', 'model': MODEL, 'mode': 'DIARIZATION',
                                  'languageBias': ['English']}))
        ack = json.loads(await asyncio.wait_for(ws.recv(), 10))
        if 'sessionId' not in ack:
            raise RuntimeError(f"handshake rejected: {ack.get('message', ack)}")
        record['sessionId'] = ack['sessionId']
        try:
            await exchange(ws, pcm, record, speed)
        except Exception as error:
            record['error'] = f'{type(error).__name__}: {error}'
    record['closeCode'], record['closeReason'] = ws.close_code, ws.close_reason
    record['completed'] = 'error' not in record and 'endStreamSeconds' in record
    return record


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ids', nargs='*', help='recording ids from the manifest; default: all')
    parser.add_argument('--smoke', type=float, metavar='SECONDS',
                        help='stream only the first SECONDS of each recording, saved under raw-smoke/')
    parser.add_argument('--force', action='store_true', help='rerun recordings that already completed')
    args = parser.parse_args()
    key = api_key()
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    items = [x for x in manifest if not args.ids or x['id'] in args.ids]
    out = ROOT / ('raw-smoke' if args.smoke else 'raw')
    out.mkdir(parents=True, exist_ok=True)

    async def one(item):
        path = out / f"{item['id']}.json"
        if path.exists() and json.loads(path.read_text()).get('completed') and not args.force:
            print(f"{item['id']}: already complete", flush=True)
            return
        try:
            record = await stream(item, key, seconds=args.smoke)
        except Exception as error:
            print(f"{item['id']}: FAILED before streaming: {type(error).__name__}: {error}", flush=True)
            return
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(record))
        temporary.replace(path)
        kinds = [e.get('type') for e in record['events']]
        labels = sorted({e['label'] for e in record['events'] if e.get('type') == 'speaker'})
        print(f"{item['id']}: {'complete' if record['completed'] else 'INCOMPLETE ' + record.get('error', '')}, "
              f"{kinds.count('speechComplete')} turns, speakers {labels}, ended by {record.get('endedBy')}, "
              f"close {record['closeCode']}", flush=True)

    await asyncio.gather(*(one(x) for x in items))


if __name__ == '__main__':
    asyncio.run(main())
