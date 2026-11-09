"""Compose the film's warm piano bed procedurally (numpy only, deterministic).

Felt-piano arpeggios over a soft pad at 72 BPM, F major (Fmaj7 · Dm9 · B♭maj7 ·
Csus4→C). Writes assets/bgm/bed.wav, 48 kHz stereo, peak-normalized; the mix
step sets loudness under the voice.

Usage: uv run --no-project --with numpy --with scipy python compose_bed.py [seconds]
"""
import sys
import wave
import os
from pathlib import Path

import numpy as np
from scipy.signal import lfilter

SR = 48_000
# CUT_DIR selects a cut (e.g. short/) that has the same layout as this folder.
P = Path(os.environ.get('CUT_DIR') or Path(__file__).resolve().parent).resolve()
LENGTH = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
BPM = float(sys.argv[2]) if len(sys.argv) > 2 else 72
BEAT = 60 / BPM
rng = np.random.default_rng(20261012)


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def one_pole_lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    return lfilter([1 - a], [1, -a], x)


def felt_note(freq, dur, vel):
    n = int(SR * (dur + 2.5))
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(1, 9):
        fk = k * freq * np.sqrt(1 + 0.0004 * k * k)
        if fk > 9000:
            break
        decay = 0.9 + 0.55 * k
        out += (1 / k ** 1.6) * np.exp(-t * decay) * np.sin(2 * np.pi * fk * t + rng.uniform(0, 2 * np.pi))
    attack = np.minimum(1, t / 0.012)
    release = np.clip(1 - (t - dur) / 0.9, 0, 1)
    out *= attack * np.where(t < dur, 1, release)
    # A soft hammer-on-felt thump.
    thump = rng.normal(0, 1, int(SR * 0.04)) * np.exp(-np.arange(int(SR * 0.04)) / (SR * 0.008))
    out[:thump.size] += 0.04 * thump
    return out * vel


def pad_chord(notes, dur):
    n = int(SR * (dur + 1.5))
    t = np.arange(n) / SR
    out = np.zeros(n)
    for note in notes:
        for detune in (-0.07, 0.0, 0.06):
            f = midi(note + detune)
            for k, amp in ((1, 1.0), (2, 0.35), (3, 0.12)):
                out += amp * np.sin(2 * np.pi * f * k * t + rng.uniform(0, 2 * np.pi))
    env = np.minimum(1, t / 1.4) * np.clip(1 - (t - dur) / 1.5, 0, 1)
    return out * env / (len(notes) * 3)


def place(buf, sig, start):
    i = max(0, int(start * SR))
    j = min(buf.size, i + sig.size)
    if i < buf.size:
        buf[i:j] += sig[: j - i]


# Chords: (pad notes, arpeggio notes), one bar each.
progression = [
    ([53, 57, 60, 64], [65, 69, 72, 76, 72, 69]),   # Fmaj7
    ([50, 53, 57, 60], [62, 65, 69, 72, 76, 72]),   # Dm9-ish
    ([46, 50, 53, 57], [58, 62, 65, 69, 74, 69]),   # B♭maj7
    ([48, 53, 55, 60], [60, 65, 67, 72, 67, 64]),   # Csus4 → C
]
bar = 4 * BEAT
total = int(SR * (LENGTH + 3))
piano = np.zeros(total)
pad = np.zeros(total)
bass = np.zeros(total)
bars = int(np.ceil(LENGTH / bar))
for b in range(bars):
    pad_notes, arp = progression[b % 4]
    start = b * bar
    place(pad, pad_chord(pad_notes, bar), start)
    place(bass, felt_note(midi(pad_notes[0] - 12), bar * 0.9, 0.55), start)
    # Sparse at first, a little fuller in the middle, sparse again at the end.
    density = 4 if b < 2 or b >= bars - 2 else 6
    steps = [0, 1.5, 2, 3, 3.5, 2.75][:density]
    for idx, beat in enumerate(sorted(steps)):
        note = arp[idx % len(arp)]
        vel = 0.42 + 0.12 * rng.random() - (0.08 if idx % 2 else 0)
        timing = rng.normal(0, 0.012)
        place(piano, felt_note(midi(note), BEAT * 1.6, vel), start + beat * BEAT + timing)

pad = one_pole_lowpass(pad, 1400)
piano = one_pole_lowpass(piano, 5200)
dry = 0.62 * piano + 0.16 * pad + 0.32 * one_pole_lowpass(bass, 900)

# Small-room reverb: decaying stereo noise impulse response, FFT-convolved.
ir_len = int(SR * 2.4)
decay = np.exp(-np.arange(ir_len) / (SR * 0.55))
irs = [one_pole_lowpass(rng.normal(0, 1, ir_len) * decay, 3800) for _ in range(2)]
size = 1 << int(np.ceil(np.log2(dry.size + ir_len)))
spec = np.fft.rfft(dry, size)
wet = [np.fft.irfft(spec * np.fft.rfft(ir, size), size)[: dry.size] for ir in irs]
wet = [w / np.max(np.abs(w)) * np.max(np.abs(dry)) for w in wet]
left = dry + 0.38 * wet[0]
right = dry + 0.38 * wet[1]
stereo = np.stack([left, right], axis=1)[: int(SR * LENGTH)]

# Fade in over 1.2 s, out over the last 3.5 s.
t = np.arange(stereo.shape[0]) / SR
fade = np.minimum(1, t / 1.2) * np.clip((LENGTH - t) / 3.5, 0, 1)
stereo *= fade[:, None]
stereo /= np.max(np.abs(stereo)) / 0.85

out = P / 'assets/bgm/bed.wav'
out.parent.mkdir(parents=True, exist_ok=True)
pcm = (stereo * 32767).astype('<i2')
with wave.open(str(out), 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print(out, f'{LENGTH:.1f}s')
