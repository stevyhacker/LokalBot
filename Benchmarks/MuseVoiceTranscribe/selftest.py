"""Check run.py and score.py against a local mock of the realtime protocol. No key or network needed."""
import asyncio
import json
import pathlib
import tempfile
import wave

import websockets

import run
import score

# (start, end, label) in seconds for the mock's three turns.
SCRIPT = [(1.0, 3.0, 'A'), (3.5, 6.0, 'B'), (6.5, 9.0, 'A')]


async def mock(ws):
    hello = json.loads(await ws.recv())
    assert hello['authorization'] == {'accessToken': 'Bearer test-key'}, hello
    assert (hello['mode'], hello['audioEncoding'], hello['model']) == ('DIARIZATION', 'PCM_16KHZ', run.MODEL), hello
    await ws.send(json.dumps({'sessionId': 'mock-session'}))
    received, sent = 0, set()
    async for message in ws:
        if isinstance(message, str):
            assert json.loads(message) == {'type': 'endStream'}, message
            break
        received += len(message)
        for turn, (start, end, label) in enumerate(SCRIPT, 1):
            for kind, at in [('speechStart', start), ('speaker', (start + end) / 2),
                             ('speechEnd', end), ('speechComplete', end + 0.2)]:
                if (turn, kind) in sent or received / 32000 < at:
                    continue
                sent.add((turn, kind))
                event = {'type': kind, 'audioProcessedMs': round(at * 1000)}
                event.update({'label': label} if kind == 'speaker' else {'turnId': turn})
                if kind == 'speechComplete':
                    event['transcript'] = f'turn {turn}'
                await ws.send(json.dumps(event))
    await ws.close(1000)


def check_segment_rules():
    events = [('speechStart', 1, None, 1000), ('speechEnd', 1, None, 2000), ('speaker', None, 'A', 2400),
              ('speechStart', 2, None, 3000), ('speaker', None, 'B', 3500), ('speaker', None, 'C', 4000),
              ('speechEnd', 2, None, 4500), ('speechStart', 3, None, 5000), ('speechEnd', 3, None, 6000)]
    events = [{'type': kind, 'audioProcessedMs': ms, 'wallSeconds': ms / 1000,
               **({'label': label} if label else {'turnId': turn})} for kind, turn, label, ms in events]
    # A late label still covers its turn, a second label splits the turn, and a turn with none stays unknown.
    expected = [(1.0, 2.0, 'A'), (3.0, 3.5, 'B'), (3.5, 4.0, 'C'), (4.0, 4.5, 'C'), (5.0, 6.0, 'unknown-3')]
    assert score.segments(score.turns(events)) == expected, score.segments(score.turns(events))


async def main():
    check_segment_rules()
    with tempfile.TemporaryDirectory() as folder:
        audio = pathlib.Path(folder) / 'silence.wav'
        with wave.open(str(audio), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(bytes(2 * 16000 * 10))
        rttm = pathlib.Path(folder) / 'mock.rttm'
        rttm.write_text(''.join(f'SPEAKER mock 1 {s} {e - s} <NA> <NA> {label.lower()} <NA> <NA>\n'
                                for s, e, label in SCRIPT))
        async with websockets.serve(mock, '127.0.0.1', 0) as server:
            port = server.sockets[0].getsockname()[1]
            record = await run.stream({'id': 'mock', 'audio': str(audio)}, 'test-key',
                                      url=f'ws://127.0.0.1:{port}/', speed=50)
        assert record['completed'] and record['endedBy'] == 'server' and record['closeCode'] == 1000, record
        assert record['sessionId'] == 'mock-session' and record['duration'] == 10, record
        rows = score.segments(score.turns(record['events']))
        assert rows == [(1.0, 2.0, 'A'), (2.0, 3.0, 'A'), (3.5, 4.75, 'B'), (4.75, 6.0, 'B'),
                        (6.5, 7.75, 'A'), (7.75, 9.0, 'A')], rows
        prediction = {'id': 'mock', 'duration': record['duration'],
                      'segments': [{'start': s, 'end': e, 'speaker': label} for s, e, label in rows]}
        result = score.evaluate('mock', [prediction], {'mock': {'condition': 'mhm', 'reference': str(rttm)}})
        assert result['aggregate'][0]['der0'] == 0 and result['perFile'][0]['predictedSpeakers'] == 2, result
        # Swapping every label must cost nothing: the scorer maps labels optimally.
        swapped = dict(prediction, segments=[dict(x, speaker={'A': 'B', 'B': 'A'}[x['speaker']]) for x in prediction['segments']])
        assert score.evaluate('mock', [swapped], {'mock': {'condition': 'mhm', 'reference': str(rttm)}})['aggregate'][0]['der0'] == 0
        # Speech outside the reference is a false alarm, and the oracle view cuts exactly that away.
        padded = dict(prediction, segments=prediction['segments'] + [{'start': 9.0, 'end': 10.0, 'speaker': 'A'}])
        manifest = {'mock': {'condition': 'mhm', 'reference': str(rttm)}}
        assert score.evaluate('mock', [padded], manifest)['aggregate'][0]['der0'] > 0
        assert score.evaluate('mock', [padded], manifest, oracle_speech=True)['aggregate'][0]['der0'] == 0
    print('selftest passed: protocol client, segment rules and scorer')


if __name__ == '__main__':
    asyncio.run(main())
