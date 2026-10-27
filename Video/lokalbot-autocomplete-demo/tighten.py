#!/usr/bin/env python3
"""Tighten the voice takes the edit uses: shorter pauses and a quicker read.

  python3 tighten.py

For each line whose take in narration.json has "tighten" ({"pause": s,
"tempo": x}), this trims the silence around the take, shortens every pause
inside it to `pause` seconds, and speeds it up by `tempo` with Rubber Band
(formants kept, so the voice stays itself). Writes assets/voice/tight/<take>.wav
and production/tight.json: for each take, the new file and its word timings
moved onto it. timeline.py then uses those instead of the original take.

Needs numpy, scipy and an ffmpeg built with librubberband.
"""
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from scipy.io import wavfile

from timeline import HERE, takes

SR = 44100
FRAME = 0.01


def load(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-ac', '1', '-ar', str(SR), '-'],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def voiced(x):
    """Per 10 ms frame: is the voice sounding? Within 30 dB of the loudest frame, small gaps filled."""
    hop = int(FRAME * SR)
    n = len(x) // hop
    rms = np.sqrt(np.mean(x[:n * hop].reshape(n, hop) ** 2, axis=1))
    v = rms > rms.max() * 10 ** (-30 / 20)
    on = np.flatnonzero(v)
    for i, j in zip(on, on[1:]):
        if 1 < j - i <= 6:  # a stop consonant's closure is not a pause
            v[i:j] = True
    return v


def pieces(v, pause):
    """[(start, end), ...] in seconds of the take to keep: the speech, with each pause cut down to `pause`."""
    on = np.flatnonzero(v)
    first, last = on[0] * FRAME, (on[-1] + 1) * FRAME
    keep, start = [], max(first - 0.03, 0)
    i = on[0]
    while i <= on[-1]:
        if v[i]:
            i += 1
            continue
        j = i
        while not v[j]:
            j += 1
        a, b = i * FRAME, j * FRAME
        if b - a > pause:
            keep.append((start, a + pause / 2))
            start = b - pause / 2
        i = j
    keep.append((start, last + 0.12))
    return keep, last


def main():
    out_dir = HERE / 'assets' / 'voice' / 'tight'
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = HERE / 'production' / 'tight.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    for scene, pick, row, heard in takes():
        opts = pick.get('tighten')
        if not opts or not row or not heard:
            continue
        pause, tempo = opts.get('pause', 0.2), opts.get('tempo', 1.0)
        x = load(HERE / row['file'])
        keep, last = pieces(voiced(x), pause)
        fade = int(0.004 * SR)
        parts = []
        for a, b in keep:
            part = x[int(a * SR):int(b * SR)].copy()
            part[:fade] *= np.linspace(0, 1, fade)
            part[-fade:] *= np.linspace(1, 0, fade)
            parts.append(part)

        def moved(t):
            """Where time t of the take lands in the tightened one; inside a cut pause, at the cut."""
            o = 0.0
            for a, b in keep:
                if t < a:
                    return o / tempo
                if t <= b:
                    return (o + t - a) / tempo
                o += b - a
            return o / tempo
        end = moved(last)
        words = [[w, round(moved(s), 3), round(min(moved(e), end), 3)] for w, s, e in heard]
        name = Path(row['file']).stem
        dest = out_dir / f'{name}.wav'
        with tempfile.TemporaryDirectory() as tmp:
            cut = Path(tmp) / 'cut.wav'
            wavfile.write(cut, SR, (np.concatenate(parts) * 32767).astype(np.int16))
            subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', str(cut), '-af',
                            f'rubberband=tempo={tempo}:pitchq=quality:formant=preserved', str(dest)], check=True)
        report[row['file']] = {'file': str(dest.relative_to(HERE)), 'pause': pause, 'tempo': tempo, 'words': words}
        before, after = len(x) / SR, sum(b - a for a, b in keep) / tempo
        print(f'{name}: {before:.2f} s -> {after:.2f} s')
    report_path.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
