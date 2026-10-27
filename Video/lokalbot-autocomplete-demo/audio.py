#!/usr/bin/env python3
"""Mix the autocomplete demo's soundtrack: voice, music bed and effects.

  python3 audio.py edit.json events.json out.wav

The voice takes and their placement come from edit.json (timeline.py), the
effect cues from the composition (node render.cjs events events.json), and
the music and effects from assets/sound/eleven/ (eleven_sound.py), picked in
sound.json's "mix". The music ducks under the voice; loudness normalization
happens later, in ffmpeg.

Needs numpy, scipy and ffmpeg.
"""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

SR = 48000
HERE = Path(__file__).resolve().parent
rng = np.random.default_rng(7)


def load(path):
    """Any audio file as float mono at SR."""
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-ac', '1', '-ar', str(SR), '-'],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def db(x):
    return 10 ** (x / 20)


def fade(x, fin=0.01, fout=0.05):
    x = x.copy()
    a, b = int(fin * SR), int(fout * SR)
    if a:
        x[:a] *= np.linspace(0, 1, a)
    if b:
        x[-b:] *= np.linspace(1, 0, b)
    return x


def envelope(x, attack, release):
    """Peak follower with separate attack and release, in seconds."""
    a, r = np.exp(-1 / (attack * SR)), np.exp(-1 / (release * SR))
    out = np.zeros_like(x)
    level = 0.0
    for i, v in enumerate(np.abs(x)):
        k = a if v > level else r
        level = k * level + (1 - k) * v
        out[i] = level
    return out


def place(bus, clip, t, gain=1.0, pan=0.0):
    """Add a mono clip to a stereo bus at time t, panned -1..1."""
    i = int(round(t * SR))
    if i >= len(bus) or len(clip) == 0:
        return
    if i < 0:
        clip, i = clip[-i:], 0
    n = min(len(clip), len(bus) - i)
    left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    bus[i:i + n, 0] += clip[:n] * gain * left * np.sqrt(2)
    bus[i:i + n, 1] += clip[:n] * gain * right * np.sqrt(2)


def from_onset(x):
    """The clip from just before it starts sounding, so it lands on its cue."""
    i = np.flatnonzero(np.abs(x) > np.abs(x).max() * 0.05)
    return x[max(i[0] - int(0.002 * SR), 0):] if len(i) else x


def peak_time(x):
    """When a swell is loudest, in seconds from its start."""
    return float(np.argmax(envelope(x, 0.005, 0.05))) / SR


def keystrokes(typing):
    """Single key clicks cut from a recording of typing, at its onsets."""
    env = envelope(typing, 0.001, 0.03)
    threshold = env.max() * 0.25
    hits, last = [], -SR
    for i in np.flatnonzero((env[1:] > threshold) & (env[:-1] <= threshold)):
        if i - last > 0.09 * SR:
            start = max(i - int(0.004 * SR), 0)
            hits.append(fade(typing[start:start + int(0.09 * SR)], 0.002, 0.04))
            last = i
    return hits or [fade(typing[:int(0.09 * SR)])]


def voice_bus(edit, n):
    bus = np.zeros(n)
    hp = butter(2, 70 / (SR / 2), 'highpass', output='sos')
    for line in edit['voice']:
        if not line['file']:
            continue
        x = sosfilt(hp, load(HERE / line['file']))
        # From the first word to just after the last, so a breath or click after it is left out.
        a = int(line['trim'] * SR)
        b = a + int((line['end'] - line['at'] + 0.18) * SR)
        x = fade(x[a:b], 0.012, 0.09)
        speech = x[np.abs(x) > np.abs(x).max() * 0.05]
        x *= db(-20) / max(np.sqrt(np.mean(speech ** 2)), 1e-6)  # every line at the same level
        i = int(round(line['at'] * SR))
        m = min(len(x), n - i)
        bus[i:i + m] += x[:m]
    return bus


def music_bed(path, n, duration):
    """The bed, placed so its own ending lands on the film's last frame."""
    bed = load(path)
    env = envelope(bed, 0.01, 0.3)
    end = np.flatnonzero(env > env.max() * 0.01)[-1] + int(0.5 * SR)  # where the last chord has rung out
    start = max(end - n, 0)
    x = bed[start:end]
    x = np.pad(x, (n - len(x), 0)) if len(x) < n else x[:n]
    x = fade(x, 1.2 if start > 0 else 0.05, 0.3)
    return x


def main():
    edit = json.loads(Path(sys.argv[1]).read_text())
    events = json.loads(Path(sys.argv[2]).read_text())
    out = Path(sys.argv[3])
    mix = json.loads((HERE / 'sound.json').read_text())['mix']
    sound = HERE / 'assets' / 'sound' / 'eleven'
    n = int(round(edit['duration'] * SR))

    voice = voice_bus(edit, n)
    music = music_bed(sound / f"{mix['music']}.mp3", n, edit['duration'])
    # Duck the music about 7 dB under speech, easing back between lines.
    duck = envelope(voice, 0.08, 0.5)
    duck = 1 - 0.55 * np.clip(duck / max(duck.max() * 0.3, 1e-9), 0, 1)
    music *= duck * db(mix.get('music_db', -11))

    fx = np.zeros((n, 2))
    clips = {name: load(sound / f'{file}.mp3') for name, file in mix['effects'].items()}
    keys = keystrokes(clips.pop('type'))
    for name in ('tab', 'ghost', 'tick'):
        clips[name] = from_onset(clips[name])
    # Swells peak on their cue: the whoosh on the cut, the reveal as the logo settles.
    whoosh_peak, reveal_peak = peak_time(clips['whoosh']), peak_time(clips['reveal'])
    gains = {k: db(v) for k, v in mix['effect_db'].items()}
    for t, kind in events:
        name = kind.split(':')[0]
        if name == 'type':
            place(fx, keys[rng.integers(len(keys))], t - 0.004, gains['type'] * rng.uniform(0.75, 1.0), rng.uniform(-0.2, 0.2))
        elif name == 'whoosh':
            place(fx, fade(clips['whoosh'], 0.05, 0.3), t - whoosh_peak, gains['whoosh'], rng.uniform(-0.3, 0.3))
        elif name == 'reveal':
            place(fx, fade(clips['reveal'], 0.05, 0.4), t + 1.0 - reveal_peak, gains['reveal'])
        elif name == 'token':
            place(fx, clips['tick'], t, gains['token'], 0.15)
        elif name in clips:
            place(fx, clips[name], t, gains[name])

    stereo = fx + music[:, None] + voice[:, None]
    peak = np.abs(stereo).max()
    if peak > 0.98:
        stereo *= 0.98 / peak
    wavfile.write(out, SR, (stereo * 32767).astype(np.int16))
    print(f'{out}: {edit["duration"]:.2f} s, {len(events)} cues, '
          f'{sum(1 for v in edit["voice"] if v["file"])} lines, music {mix["music"]}')


if __name__ == '__main__':
    main()
