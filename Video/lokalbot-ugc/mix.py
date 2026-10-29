"""Mixes the soundtrack: the voice lines where edit.json puts them, the hype beat
with its drop on "Stop" (ducked a little under the voice), and every effect in
edit.json's "sfx" list: whooshes on the whips, booms on the hits, a riser and a
slam into the end card, pops for the emoji, keyboard and Tab sounds.

  python3 mix.py [out.wav]      default: renders/soundtrack.wav

The voice comes from tts_elevenlabs.py (assets/voice/), the beat and effects
from eleven_sound.py (assets/sound/eleven/); all are gitignored. An effect
whose file is missing is synthesized, so a rough mix works before they exist.
"""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
SR = 48000
SOUND = HERE / 'assets/sound/eleven'
MUSIC_DB, DUCK_DB = -9.0, -17.0     # beat level alone and under the voice
VOICE_DB = 0.0
SFX_DB = 0.0
# The effects API makes nothing under 0.5 s; these are cut to their first moments.
SHORT = {'tab': 0.22, 'click': 0.15, 'pop': 0.3}


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


def stereo(x):
    return np.stack([x, x], axis=1).astype(np.float32)


def synth(name, rng):
    """A stand-in for an effect file that is not there yet."""
    def noise(sec):
        return rng.standard_normal(int(sec * SR))
    def env(n, attack, decay):
        t = np.arange(n) / SR
        return np.minimum(1, t / max(attack, 1e-4)) * np.exp(-t * decay)
    if name in ('impact', 'bassdrop', 'slam'):
        n = int(1.2 * SR); t = np.arange(n) / SR
        f = 40 + 90 * np.exp(-t * 18)
        x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 3.5) + 0.3 * noise(1.2) * np.exp(-t * 30)
        return stereo(0.8 * x)
    if name in ('whoosh', 'riser'):
        sec = 0.6 if name == 'whoosh' else 1.6
        n = int(sec * SR); t = np.arange(n) / SR
        x = np.cumsum(noise(sec)); x -= np.convolve(x, np.ones(64) / 64, mode='same')
        shape = np.sin(np.pi * t / sec) ** 2 if name == 'whoosh' else (t / sec) ** 2
        return stereo(0.05 * x * shape / (np.abs(x).max() / 20 + 1e-9))
    if name == 'pop':
        n = int(0.08 * SR); t = np.arange(n) / SR
        return stereo(0.5 * np.sin(2 * np.pi * (700 - 3000 * t) * t) * env(n, 0.002, 40))
    if name == 'glitch':
        n = int(0.3 * SR); t = np.arange(n) / SR
        return stereo(0.25 * np.sign(np.sin(2 * np.pi * 180 * t)) * (np.sin(2 * np.pi * 23 * t) > 0) * env(n, 0.001, 8))
    length = {'tab': 0.05, 'click': 0.03, 'typing': 0.025}.get(name, 0.04)
    n = int(length * SR)
    x = np.diff(np.concatenate([[0], noise(length) * 0.6 + np.sin(2 * np.pi * 1500 * np.arange(n) / SR) * 0.5]))
    return stereo(x * env(n, 0.0008, 150) * 0.5)


def effect(name, k, rng, cache={}):
    files = sorted(SOUND.glob(f'{name}.mp3')) + sorted(SOUND.glob(f'{name}-v*.mp3'))
    if not files:
        return synth(name, rng), False
    path = files[k % len(files)]
    if path not in cache:
        cache[path] = load(path)
    return cache[path], True


def envelope(clip):
    mono = np.abs(clip).mean(axis=1)
    win = SR // 100
    return np.convolve(mono, np.ones(win) / win, mode='same')


def peak_time(clip):
    """Seconds to the loudest 10 ms in the clip, where its hit is."""
    return int(np.argmax(envelope(clip))) / SR


def onset_time(clip):
    """Seconds of near-silence before the clip's sound starts."""
    env = envelope(clip)
    return max(0, int(np.argmax(env > env.max() * 0.15)) - SR // 200) / SR


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / 'renders/soundtrack.wav'
    out.parent.mkdir(parents=True, exist_ok=True)
    edit = json.loads((HERE / 'edit.json').read_text())
    n = int(edit['duration'] * SR)
    voice = np.zeros((n, 2), np.float32)
    for ln in edit['voice']:
        if ln['file']:
            place(voice, load(HERE / ln['file']), ln['at'], db(VOICE_DB))

    # The beat: its drop on "Stop", ducked wherever someone is speaking.
    music = np.zeros((n, 2), np.float32)
    if edit['music']['file']:
        place(music, load(HERE / edit['music']['file']), edit['music']['at'])
    gain = np.full(n, db(MUSIC_DB))
    for ln in edit['voice']:
        a, b = int((ln['start'] - 0.08) * SR), int((ln['end'] + 0.12) * SR)
        gain[max(0, a):min(n, b)] = db(DUCK_DB)
    k = int(0.08 * SR)
    gain = np.convolve(gain, np.ones(k) / k, mode='same')
    fade_out = int(0.9 * SR)
    gain[-fade_out:] *= np.linspace(1, 0, fade_out) ** 2
    music *= gain[:, None]

    # Effects, in the order edit.json lists them; variants take turns.
    fx = np.zeros((n, 2), np.float32)
    rng = np.random.default_rng(11)
    turns = {}
    for t, name, g, align in edit['sfx']:
        clip, real = effect(name, turns.get(name, 0), rng)
        turns[name] = turns.get(name, 0) + 1
        lead = peak_time(clip) if align == 'peak' else onset_time(clip) if real else 0.0
        if real and name in SHORT:
            clip = clip[int(lead * SR):int((lead + SHORT[name]) * SR)].copy()
            fade = int(0.04 * SR)
            clip[-fade:] *= np.linspace(1, 0, fade)[:, None]
            lead = 0.0
        place(fx, clip, t - lead, db(g + SFX_DB))
    a, b = edit['typing']
    clip, real = effect('typing', 0, rng)
    if real:
        span = clip[:int((b - a) * SR)].copy()
        fade = min(len(span) // 4, int(0.06 * SR))
        span[:fade] *= np.linspace(0, 1, fade)[:, None]
        span[-fade:] *= np.linspace(1, 0, fade)[:, None]
        place(fx, span, a, db(0))
    else:
        t = a + 0.04
        while t < b - 0.04:
            place(fx, synth('typing', rng), t, 0.4)
            t += rng.uniform(0.05, 0.09)

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
