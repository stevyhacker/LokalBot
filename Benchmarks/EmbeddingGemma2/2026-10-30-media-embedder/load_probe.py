"""Latency and memory of the media embedder under indexing-shaped load, against today's text-only embedder.

Inputs are synthetic and made here (no personal or third-party media): window-like screens, smooth photo-like
pictures, video-frame-sized pictures and 30-second WAV windows built from reference/speech.wav. Each server is a
fresh process, so its lifetime peak footprint is the peak of this run.

usage: python3 load_probe.py   (same overrides as parity.py)
"""
import io
import json
import sys
import time
import wave

import numpy as np
from PIL import Image

from common import (HERE, MMPROJ, SIZED_MEDIA_ARGS, QUERY_PREFIX, Sampler, Server, audio_part, document, footprint,
                    image_part, percentile, sized_png)

rng = np.random.default_rng(20261030)
WORDS = ('review deploy invoice budget roadmap sprint ticket retry backoff latency customer contract draft meeting '
         'agenda release notes build failed passed merge branch screen window settings export import report quarter '
         'design token schedule calendar reply thread payment declined error account login session cache').split()
COUNT = {'screens': 40, 'photos': 40, 'frames': 40, 'audio': 20, 'queries': 20, 'text_batches': 20}


def mib(value):
    return round(value / 2**20)


def synthetic_text(characters):
    words = []
    while sum(len(w) + 1 for w in words) < characters:
        words.append(WORDS[rng.integers(len(WORDS))])
    return ' '.join(words)[:characters]


def screen():
    image = np.full((900, 1440, 3), rng.integers(225, 250), np.uint8)
    image[:52] = rng.integers(200, 240, 3)
    image[52:, :int(rng.integers(180, 300))] = rng.integers(220, 245, 3)
    for row in range(int(rng.integers(10, 26))):
        y, x = 80 + row * 30, int(rng.integers(260, 400))
        image[y:y + 10, x:x + int(rng.integers(200, 1000))] = rng.integers(30, 140, 3)
    for _ in range(int(rng.integers(1, 5))):
        y, x = int(rng.integers(60, 800)), int(rng.integers(260, 1200))
        image[y:y + int(rng.integers(30, 90)), x:x + int(rng.integers(80, 240))] = rng.integers(0, 255, 3)
    return Image.fromarray(image)


def photo(width, height):
    small = rng.integers(0, 255, (6, 8, 3)).astype(np.uint8)
    image = Image.fromarray(small).resize((width, height), Image.BICUBIC)
    pixels = np.asarray(image).astype(np.int16) + rng.integers(-12, 12, (height, width, 3))
    return Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8))


def audio_window(speech, seconds=30, rate=16_000):
    tiled = np.tile(speech, int(np.ceil(seconds * rate / len(speech))))[:seconds * rate].astype(np.float64)
    tiled = tiled * rng.uniform(.3, 1.0) + rng.normal(0, 300, len(tiled))
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(np.clip(tiled, -32768, 32767).astype('<i2').tobytes())
    return buffer.getvalue()


def timed(server, inputs_list):
    """One request per item; per-request seconds, prompt tokens of the first, and the stage's peak footprint."""
    sampler = Sampler(server.pid)
    seconds, tokens = [], None
    for inputs in inputs_list:
        _, payload, elapsed = server.embed(inputs)
        seconds.append(elapsed)
        tokens = tokens or payload.get('usage', {}).get('prompt_tokens')
    peak = sampler.stop()
    return {'n': len(seconds), 'p50_ms': round(percentile(seconds, 50) * 1000, 1),
            'p95_ms': round(percentile(seconds, 95) * 1000, 1), 'total_s': round(sum(seconds), 2),
            'prompt_tokens_first': tokens, 'peak_footprint_mib': mib(peak),
            'peak_rss_mib': mib(sampler.peak_resident)}


def main():
    with wave.open(str(HERE / 'reference/speech.wav')) as source:
        speech = np.frombuffer(source.readframes(source.getnframes()), '<i2')
    queries = [[QUERY_PREFIX + synthetic_text(int(rng.integers(15, 60)))] for _ in range(COUNT['queries'])]
    ocr_batches = [[document(None, synthetic_text(1500)) for _ in range(32)] for _ in range(COUNT['text_batches'])]
    prepared = time.perf_counter()
    screens = [[image_part(sized_png(screen(), 280))] for _ in range(COUNT['screens'])]
    photos = [[image_part(sized_png(photo(1024, 768), 140))] for _ in range(COUNT['photos'])]
    frames = [[image_part(sized_png(photo(1280, 720), 70))] for _ in range(COUNT['frames'])]
    frame_batches = [[image_part(sized_png(photo(1280, 720), 70)) for _ in range(8)] for _ in range(5)]
    sounds = [[audio_part(audio_window(speech))] for _ in range(COUNT['audio'])]
    print(f'inputs ready in {time.perf_counter() - prepared:.1f} s', flush=True)
    report = {}

    with Server() as server:
        idle = footprint(server.pid)
        row = {'load_s': round(server.load_seconds, 2), 'idle_footprint_mib': mib(idle[0]),
               'idle_rss_mib': mib(idle[2]),
               'queries': timed(server, queries),
               'ocr_batches_of_32x1500_chars': timed(server, ocr_batches)}
        row['lifetime_peak_footprint_mib'] = mib(footprint(server.pid)[1])
        report['text_only'] = row
    print('text-only', json.dumps(report['text_only']), flush=True)

    with Server(['--mmproj', str(MMPROJ), *SIZED_MEDIA_ARGS]) as server:
        idle = footprint(server.pid)
        row = {'load_s': round(server.load_seconds, 2), 'idle_footprint_mib': mib(idle[0]),
               'idle_rss_mib': mib(idle[2]),
               'queries': timed(server, queries),
               'screens_280': timed(server, screens),
               'photos_140': timed(server, photos),
               'frames_70': timed(server, frames),
               'frames_70_batches_of_8': timed(server, frame_batches),
               'audio_30s': timed(server, sounds)}
        row['frames_70_batches_of_8']['per_image_ms'] = round(row['frames_70_batches_of_8']['p50_ms'] / 8, 1)
        row['lifetime_peak_footprint_mib'] = mib(footprint(server.pid)[1])
        time.sleep(5)
        after = footprint(server.pid)
        row['footprint_after_work_mib'], row['rss_after_work_mib'] = mib(after[0]), mib(after[2])
        report['media_sized'] = row
    print('media', json.dumps(report['media_sized']), flush=True)

    (HERE / 'results/load.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
