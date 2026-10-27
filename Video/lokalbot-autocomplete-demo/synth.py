"""Synthesized sound design from the first cut, for audio.py.

The intro (a dark pad swelling under the hook, a riser and a kick build into
the first clip), impacts on the drops and the logo, and the interface sounds:
key clicks, a Tab thock, a breath of air when the suggestion appears, swishes
on the cuts and blips for the model's picks. No bells. Everything pitched is
in the music bed's key (E major), so it sits with the bed.
"""
import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt, sosfilt_zi

SR = 48000
rng = np.random.default_rng(11)
PENT = [76, 78, 80, 83, 85, 88, 90, 92]  # E major pentatonic, from E5
PAD = (56, 61, 64, 68)                    # C#m over G#, resolving to the bed's E at the drop


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def sos(kind, f, order=2):
    if kind == 'band':
        lo, hi = f
        return butter(order, [max(lo, 20) / (SR / 2), min(hi, SR / 2 - 100) / (SR / 2)], 'bandpass', output='sos')
    return butter(order, min(f, SR / 2 - 100) / (SR / 2), kind, output='sos')


def filt(x, kind, f, order=2):
    return sosfilt(sos(kind, f, order), x)


def sweep(x, kind, freq_at, block=256, order=2):
    """Filter whose corner moves over time, applied in short blocks."""
    out = np.zeros_like(x)
    zi = None
    for i in range(0, len(x), block):
        f = freq_at(i / SR)
        s = sos('band', (f / 1.6, f * 1.6), order) if kind == 'band' else sos(kind, f, order)
        if zi is None:
            zi = sosfilt_zi(s) * 0
        out[i:i + block], zi = sosfilt(s, x[i:i + block], zi=zi)
    return out


def saw(freq, n, phase=0.0):
    """Band-limited sawtooth (polyBLEP)."""
    f = np.broadcast_to(np.asarray(freq, float), (n,))
    dt = f / SR
    p = (phase + np.cumsum(dt)) % 1.0
    y = 2 * p - 1
    a = p < dt
    t = p[a] / dt[a]
    y[a] -= t + t - t * t - 1
    b = p > 1 - dt
    t = (p[b] - 1) / dt[b]
    y[b] -= t * t + t + t + 1
    return y


def sine(freq, n, phase=0.0):
    f = np.broadcast_to(np.asarray(freq, float), (n,))
    return np.sin(2 * np.pi * (phase + np.cumsum(f) / SR))


def adsr(n, a=0.005, d=0.1, s=0.0, r=0.05):
    """Attack, exponential decay to sustain, release at the end."""
    t = np.arange(n) / SR
    e = np.where(t < a, t / max(a, 1e-6), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-6)))
    rel = int(r * SR)
    if rel and n > rel:
        e[-rel:] *= np.linspace(1, 0, rel) ** 2
    return e


def kick():
    n = int(0.42 * SR)
    t = np.arange(n) / SR
    body = sine(52 + 110 * np.exp(-t / 0.03), n) * np.exp(-t / 0.12)
    click = filt(rng.standard_normal(n), 'band', (1800, 7000)) * np.exp(-t / 0.004) * 0.55
    return np.tanh(1.6 * (body + click)) / np.tanh(1.6)


def supersaw(notes, dur, voices=5, detune=0.13):
    n = int(dur * SR)
    out = np.zeros((n, 2))
    for note in notes:
        for v in range(voices):
            cents = (v - (voices - 1) / 2) * detune / ((voices - 1) / 2) * 100
            s = saw(midi(note) * 2 ** (cents / 1200), n, rng.random())
            pan = (v - (voices - 1) / 2) / voices * 1.6
            out[:, 0] += s * np.cos((pan + 1) * np.pi / 4)
            out[:, 1] += s * np.sin((pan + 1) * np.pi / 4)
    return out / (len(notes) * voices) * 2.2


def noise_sweep(dur, f0, f1, shape=2.0):
    n = int(dur * SR)
    y = sweep(rng.standard_normal(n), 'band', lambda s: f0 * (f1 / f0) ** min(s / dur, 1))
    return y * (np.arange(n) / n) ** shape


def impact(dur=1.8):
    n = int(dur * SR)
    t = np.arange(n) / SR
    boom = sine(42 + 90 * np.exp(-t / 0.05), n) * np.exp(-t / 0.5)
    crash = filt(rng.standard_normal(n), 'high', 3000) * np.exp(-t / 0.45) * 0.35
    return np.tanh(1.3 * boom) * 0.9, crash


def reverb_ir(dur=2.4, tau=0.55):
    n = int(dur * SR)
    t = np.arange(n) / SR
    ir = np.zeros((n, 2))
    for c in range(2):
        x = rng.standard_normal(n) * np.exp(-t / tau)
        x = 0.6 * filt(x, 'low', 5200) + 0.4 * filt(x, 'low', 1800)
        x[:int(0.012 * SR)] *= np.linspace(0, 1, int(0.012 * SR))
        ir[:, c] = x
    return ir / np.sqrt((ir ** 2).sum(0)).max()


def add(bus, t, sig, gain=1.0, pan=0.0):
    """Add a mono or stereo signal to a stereo bus at time t."""
    i = int(round(t * SR))
    if sig.ndim == 1:
        left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        sig = np.stack([sig * left, sig * right], 1) * np.sqrt(2)
    j0, j1 = max(i, 0), min(i + len(sig), len(bus))
    if j1 > j0:
        bus[j0:j1] += gain * sig[j0 - i:j1 - i]


def intro(n, drop, beat):
    """Under the hook: the pad swells and opens, a riser and four kicks lead into the drop. (music, hits)"""
    music, hits = np.zeros((n, 2)), np.zeros((n, 2))
    pad = supersaw(PAD, drop + 0.4)
    pad = np.stack([sweep(pad[:, c], 'low', lambda s: 350 + 1600 * (s / drop) ** 2) for c in range(2)], 1)
    pad *= adsr(len(pad), 0.9, 10, 1, 0.35)[:, None]
    add(music, 0, pad, 0.55)
    add(music, drop - 1.2, noise_sweep(1.2, 400, 9000, 2.5), 0.11)
    for k in range(1, 5):
        add(hits, drop - k * beat, filt(kick(), 'low', 220), 0.75 - 0.08 * k)
    return music, hits


def cues(n, events, drops, end=None):
    """Impacts on the drops and the logo (at end), and a sound for each cue the composition exports."""
    bus, send = np.zeros((n, 2)), np.zeros((n, 2))
    for t in drops:
        boom, crash = impact(1.4)
        add(bus, t, boom, 0.55)
        add(bus, t, crash, 0.22)
        add(send, t, crash, 0.2)
    if end is not None:
        boom, crash = impact(2.6)
        add(bus, end, boom, 0.45)
        add(bus, end, crash, 0.2)
        add(send, end, crash, 0.3)
    last_tick, tick_run = -9, 0
    for t, kind in events:
        if kind == 'type':
            m = int(0.05 * SR)
            tt = np.arange(m) / SR
            click = filt(rng.standard_normal(m), 'band', (1800, 6000)) * np.exp(-tt / 0.004)
            thock = sine(380 * (0.85 + 0.3 * rng.random()), m) * np.exp(-tt / 0.012) * 0.6
            add(bus, t, click + thock, 0.16 * (0.75 + 0.5 * rng.random()), rng.uniform(-0.25, 0.25))
        elif kind == 'tab':
            m = int(0.16 * SR)
            tt = np.arange(m) / SR
            thock = sine(160 + 90 * np.exp(-tt / 0.01), m) * np.exp(-tt / 0.045)
            click = filt(rng.standard_normal(m), 'band', (1500, 5000)) * np.exp(-tt / 0.005) * 0.5
            add(bus, t, thock + click, 0.32)
        elif kind == 'ghost':
            m = int(0.6 * SR)
            air = filt(rng.standard_normal(m), 'band', (3000, 9000)) * adsr(m, 0.06, 0.15, 0, 0.15)
            add(bus, t - 0.05, air, 0.05)
            add(send, t - 0.05, air, 0.04)
        elif kind.startswith('whoosh'):
            if kind in ('whoosh:memory', 'whoosh:context'):
                continue  # the drops have their impacts
            d = 0.5
            w = noise_sweep(d, 500, 5200, 0.0) * np.sin(np.pi * np.linspace(0, 1, int(d * SR))) ** 2
            pan = np.linspace(-0.7, 0.7, len(w))
            st = np.stack([w * np.cos((pan + 1) * np.pi / 4), w * np.sin((pan + 1) * np.pi / 4)], 1) * np.sqrt(2)
            add(bus, t - d * 0.55, st, 0.13)
            add(send, t - d * 0.55, st, 0.08)
        elif kind in ('tick', 'token'):
            if kind == 'tick':
                tick_run = tick_run + 1 if t - last_tick < 0.8 else 0
                last_tick = t
            m = int(0.09 * SR)
            tt = np.arange(m) / SR
            f = midi(PENT[min(tick_run, len(PENT) - 1)] + 12) if kind == 'tick' else midi(PENT[0] + 12)
            blip = sine(f, m) * np.exp(-tt / 0.025) + 0.3 * sine(f * 2, m) * np.exp(-tt / 0.01)
            add(bus, t, blip, 0.12 if kind == 'tick' else 0.05, 0.15)
            add(send, t, blip, 0.12 if kind == 'tick' else 0.04)
    ir = reverb_ir()
    wet = np.stack([fftconvolve(send[:, c], ir[:, c])[:n] for c in range(2)], 1)
    return bus + 0.35 * wet
