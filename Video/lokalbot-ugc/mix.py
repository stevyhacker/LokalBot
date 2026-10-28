"""Mixes the soundtrack: the voice lines where edit.json puts them, the music bed
ducked under the voice, and small synthesized clicks for the pointer, the typing
and each Tab.

  python3 mix.py [out.wav]      default: renders/soundtrack.wav

The voice files come from tts_elevenlabs.py (assets/voice/, gitignored). The
bed is bed-d from the autocomplete demo's ElevenLabs music (assets/music/,
gitignored); MUSIC picks another file there.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
SR = 48000
MUSIC = os.environ.get('MUSIC', 'bed-d.mp3')
MUSIC_DB, DUCK_DB = -15.0, -19.0     # bed level alone and under the voice
VOICE_DB = 0.0


def load(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-ac', '2', '-ar', str(SR), '-'],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype='<f4').reshape(-1, 2).copy()


def db(x):
    return 10 ** (x / 20)


def place(track, clip, at, gain=1.0):
    i = int(round(at * SR))
    if i < 0:
        clip, i = clip[-i:], 0
    n = min(len(clip), len(track) - i)
    if n > 0:
        track[i:i + n] += clip[:n] * gain


def click(rng, length=0.035, tone=2600, decay=180, level=0.5):
    """A short, dry click: a noise burst and a quick tone, high-passed."""
    n = int(length * SR)
    t = np.arange(n) / SR
    env = np.exp(-t * decay) * np.minimum(1, t / 0.0008)
    x = rng.standard_normal(n) * 0.6 + np.sin(2 * np.pi * tone * t) * 0.5
    x = np.diff(np.concatenate([[0], x])) * env * level
    return np.stack([x, x], axis=1)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / 'renders/soundtrack.wav'
    out.parent.mkdir(parents=True, exist_ok=True)
    edit = json.loads((HERE / 'edit.json').read_text())
    n = int(edit['duration'] * SR)
    voice = np.zeros((n, 2), np.float32)
    for ln in edit['voice']:
        if ln['file']:
            place(voice, load(HERE / ln['file']), ln['at'], db(VOICE_DB))

    # Music: ducked smoothly wherever someone is speaking.
    music = np.zeros((n, 2), np.float32)
    bed = load(HERE / 'assets/music' / MUSIC)
    place(music, bed[:n], 0.0)
    gain = np.full(n, db(MUSIC_DB))
    for ln in edit['voice']:
        a, b = int((ln['start'] - 0.12) * SR), int((ln['end'] + 0.18) * SR)
        gain[max(0, a):min(n, b)] = db(DUCK_DB)
    k = int(0.12 * SR)
    gain = np.convolve(gain, np.ones(k) / k, mode='same')
    fade_out = int(1.4 * SR)
    gain[-fade_out:] *= np.linspace(1, 0, fade_out) ** 2
    gain[:int(0.03 * SR)] *= np.linspace(0, 1, int(0.03 * SR))
    music *= gain[:, None]

    # Effects: pointer clicks, soft typing while the typing plays, a firmer Tab.
    fx = np.zeros((n, 2), np.float32)
    rng = np.random.default_rng(11)
    for t in edit['clicks']:
        place(fx, click(rng, 0.03, 3200, 220, 0.20), t)
    a, b = edit['typing']
    t = a + 0.05
    while t < b - 0.05:
        place(fx, click(rng, 0.025, 1800 + rng.uniform(-300, 300), 260, 0.08 + rng.uniform(0, 0.03)), t)
        t += rng.uniform(0.07, 0.12)
    for t in edit['keys']:
        place(fx, click(rng, 0.05, 1300, 120, 0.17), t)

    mix = voice + music + fx
    peak = np.abs(mix).max()
    if peak > 0.98:
        mix *= 0.98 / peak
    pcm = (np.clip(mix, -1, 1) * 32767).astype('<i2')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 's16le', '-ar', str(SR), '-ac', '2', '-i', '-', str(out)],
                   input=pcm.tobytes(), check=True)
    print('wrote', out, f'{edit["duration"]} s')


if __name__ == '__main__':
    main()
