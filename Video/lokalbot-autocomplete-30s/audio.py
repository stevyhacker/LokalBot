#!/usr/bin/env python3
"""Procedural soundtrack for the 30 s autocomplete demo.

Everything is synthesized here, so the video carries no third-party audio.
The music follows the section timeline in edit.json and the effects follow
the cue list the composition exports (node render.cjs events events.json).

  python3 audio.py edit.json events.json out.wav

Needs numpy and scipy. Loudness normalization happens later, in ffmpeg.
"""
import json
import sys

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, sosfilt, sosfilt_zi

SR = 48000
BPM = 126
BEAT = 60 / BPM
BAR = 4 * BEAT
rng = np.random.default_rng(7)


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def times(dur):
    return np.arange(int(round(dur * SR))) / SR


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


def adsr(n, a=0.005, d=0.1, s=0.0, r=0.05, hold=None):
    """Attack, exponential decay to sustain, release at the end."""
    t = np.arange(n) / SR
    e = np.where(t < a, t / max(a, 1e-6), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-6)))
    rel = int(r * SR)
    if rel and n > rel:
        e[-rel:] *= np.linspace(1, 0, rel) ** 2
    return e


class Bus:
    def __init__(self, dur):
        self.x = np.zeros((int(dur * SR), 2))

    def add(self, t, sig, gain=1.0, pan=0.0):
        i = int(round(t * SR))
        if sig.ndim == 1:
            l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
            sig = np.stack([sig * l, sig * r], 1) * np.sqrt(2)
        j0, j1 = max(i, 0), min(i + len(sig), len(self.x))
        if j1 > j0:
            self.x[j0:j1] += gain * sig[j0 - i:j1 - i]


# ---------- instruments ----------

def kick():
    n = int(0.42 * SR)
    t = np.arange(n) / SR
    f = 52 + 110 * np.exp(-t / 0.03)
    body = sine(f, n) * np.exp(-t / 0.12)
    click = filt(rng.standard_normal(n), 'band', (1800, 7000)) * np.exp(-t / 0.004) * 0.55
    return np.tanh(1.6 * (body + click)) / np.tanh(1.6)


def clap():
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    noise = filt(rng.standard_normal(n), 'band', (900, 4200))
    env = np.zeros(n)
    for k, off in enumerate((0, 0.009, 0.018)):
        env += (t >= off) * np.exp(-np.clip(t - off, 0, None) / 0.006) * (0.8 if k < 2 else 1)
    env += (t >= 0.018) * np.exp(-np.clip(t - 0.018, 0, None) / 0.09) * 0.6
    return noise * env / 3


def hat(open_=False):
    n = int((0.28 if open_ else 0.08) * SR)
    t = np.arange(n) / SR
    x = filt(rng.standard_normal(n), 'high', 6000, 2)
    return x * np.exp(-t / (0.11 if open_ else 0.022)) * 0.5


def pluck(note, dur=0.22, bright=5000):
    n = int(dur * SR)
    f = midi(note)
    x = 0.6 * saw(f, n, rng.random()) + 0.4 * sine(f * 2, n)
    x = sweep(x, 'low', lambda s: 300 + bright * np.exp(-s / 0.05), block=128)
    return x * adsr(n, 0.002, 0.09, 0.0, 0.03)


def bass(note, dur):
    n = int(dur * SR)
    f = midi(note)
    x = 0.7 * saw(f, n) + 0.4 * sine(f / 2, n)
    x = sweep(x, 'low', lambda s: 180 + 900 * np.exp(-s / 0.06), block=128)
    return np.tanh(1.4 * x * adsr(n, 0.004, 0.18, 0.35, 0.03))


def supersaw(notes, dur, voices=5, detune=0.13):
    n = int(dur * SR)
    out = np.zeros((n, 2))
    for note in notes:
        for v in range(voices):
            cents = (v - (voices - 1) / 2) * detune / ((voices - 1) / 2) * 100
            f = midi(note) * 2 ** (cents / 1200)
            s = saw(f, n, rng.random())
            pan = (v - (voices - 1) / 2) / voices * 1.6
            out[:, 0] += s * np.cos((pan + 1) * np.pi / 4)
            out[:, 1] += s * np.sin((pan + 1) * np.pi / 4)
    return out / (len(notes) * voices) * 2.2


def bell(note, dur=1.6):
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = midi(note)
    idx = 2.2 * np.exp(-t / 0.25)
    mod = np.sin(2 * np.pi * f * 3.5 * t) * idx
    x = np.sin(2 * np.pi * f * t + mod) + 0.25 * np.sin(2 * np.pi * f * 2.01 * t) * np.exp(-t / 0.3)
    return x * adsr(n, 0.002, 0.55, 0.0, 0.1)


def noise_sweep(dur, f0, f1, shape=2.0, kind='band'):
    n = int(dur * SR)
    x = rng.standard_normal(n)
    y = sweep(x, kind, lambda s: f0 * (f1 / f0) ** min(s / dur, 1))
    t = np.arange(n) / SR / dur
    return y * t ** shape


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
        x[: int(0.012 * SR)] *= np.linspace(0, 1, int(0.012 * SR))
        ir[:, c] = x
    return ir / np.sqrt((ir ** 2).sum(0)).max()


# ---------- arrangement ----------

def main(edit_path, events_path, out_path):
    edit = json.load(open(edit_path))
    events = json.load(open(events_path))
    T = edit['timeline']
    dur = edit['duration']

    drums, music, sfx, send = (Bus(dur + 3) for _ in range(4))

    # Music cues sit on the beat grid. The edit puts its sections on the same
    # grid, so this only moves a cue when the timeline drifts off it.
    def snap(t, anchor):
        return anchor + round((t - anchor) / BEAT) * BEAT

    drop = T['memory'][0]
    brk = snap(T['dive'][0], drop)
    back = snap(T['context'][0], brk)
    end = snap(T['end'][0], back)
    for name, want, got in (('dive', T['dive'][0], brk), ('context', T['context'][0], back), ('end', T['end'][0], end)):
        if abs(want - got) > 0.01:
            print(f'note: {name} cue moved {got - want:+.3f} s onto the beat grid')

    # Chords per bar: Am, F, C, G (pad voicing, bass root).
    prog = [((57, 60, 64, 69), 33), ((53, 57, 60, 64), 29), ((55, 60, 64, 67), 36), ((55, 59, 62, 67), 31)]

    def bars(t0, t1):
        k, t = 0, t0
        while t < t1 - 1e-6:
            yield k, t, min(t + BAR, t1)
            k, t = k + 1, t + BAR

    # Intro: dark pad swelling under the hook, riser into the drop.
    pad = supersaw((57, 60, 64, 69), drop + 0.4)
    cut = lambda s: 350 + 1600 * (s / drop) ** 2
    pad = np.stack([sweep(pad[:, c], 'low', cut) for c in range(2)], 1)
    pad *= adsr(len(pad), 0.9, 10, 1, 0.35)[:, None]
    music.add(0, pad, 0.34)
    send.add(0, pad, 0.18)
    music.add(drop - 1.2, noise_sweep(1.2, 400, 9000, 2.5), 0.11)
    for k in range(1, 5):
        drums.add(drop - k * BEAT, filt(kick(), 'low', 220), 0.75 - 0.08 * k)

    def groove(t0, t1, energy):
        kicks = []
        for k, b0, b1 in bars(t0, t1):
            chord, root = prog[k % 4]
            p = supersaw(chord, b1 - b0 + 0.25)
            p = np.stack([filt(p[:, c], 'low', 2200 + 1800 * energy) for c in range(2)], 1)
            p *= adsr(len(p), 0.01, 10, 1, 0.25)[:, None]
            music.add(b0, p, 0.55)
            send.add(b0, p, 0.18)
            for beat in range(4):
                bt = b0 + beat * BEAT
                if bt >= t1 - 1e-6:
                    break
                drums.add(bt, kick(), 0.7)
                kicks.append(bt)
                if beat in (1, 3):
                    c = clap()
                    drums.add(bt, c, 0.8)
                    send.add(bt, c, 0.25)
                drums.add(bt + BEAT / 2, hat(open_=energy > 0.7 and beat == 3), 0.3, 0.25)
                if energy > 0.5:
                    for s in (0.25, 0.75):
                        drums.add(bt + s * BEAT, hat(), 0.13, -0.3)
                music.add(bt + BEAT / 2, bass(root + 12 + 12 * (beat % 2 == 1 and energy > 0.5), BEAT / 2 - 0.01), 0.42)
                if energy > 0.5:
                    tones = [chord[i % 4] + 12 * (1 + (i // 4)) for i in (0, 1, 2, 3, 2, 1, 0, 2)]
                    for i in range(4):
                        n = tones[(beat * 4 + i) % 8]
                        at = bt + i * BEAT / 4
                        if at < t1:
                            pl = pluck(n, 0.2, 3500 + 2500 * energy)
                            pan = 0.35 if i % 2 else -0.35
                            music.add(at, pl, 0.2, pan)
                            # Ping-pong echo at a dotted eighth.
                            for e in range(1, 4):
                                music.add(at + e * 0.75 * BEAT, pl, 0.2 * 0.42 ** e, -pan if e % 2 else pan)
        return kicks

    kicks = groove(drop, brk, 0.45)
    kicks += groove(back, end, 0.85)

    # Break: drums out, pad holds, a riser into the explainer.
    p = supersaw((57, 60, 64, 71), back - brk + 0.3)
    p = np.stack([sweep(p[:, c], 'low', lambda s: 2600 - 1800 * min(s / (back - brk), 1) ** 0.5) for c in range(2)], 1)
    p *= adsr(len(p), 0.02, 10, 1, 0.3)[:, None]
    music.add(brk, p, 0.32)
    send.add(brk, p, 0.3)
    music.add(brk, noise_sweep(back - brk, 300, 11000, 1.6), 0.16)
    rise = sine(np.geomspace(180, 1400, int((back - brk) * SR)), int((back - brk) * SR))
    music.add(brk, rise * np.linspace(0, 1, len(rise)) ** 2, 0.05)
    shatter = filt(rng.standard_normal(int(0.9 * SR)), 'high', 4000) * adsr(int(0.9 * SR), 0.004, 0.18, 0, 0.1)
    sfx.add(brk + 0.85, shatter, 0.16)
    send.add(brk + 0.85, shatter, 0.2)

    # Downbeats that land on a section: impact.
    for t in (drop, back):
        boom, crash = impact(1.4)
        music.add(t, boom, 0.55)
        music.add(t, crash, 0.22)
        send.add(t, crash, 0.2)

    # End: final chord, impact, bell arpeggio for the logo.
    boom, crash = impact(2.6)
    music.add(end, boom, 0.6)
    music.add(end, crash, 0.25)
    send.add(end, crash, 0.3)
    fin = supersaw((48, 55, 60, 64, 67, 74), dur - end + 1.5)
    fin = np.stack([filt(fin[:, c], 'low', 3200) for c in range(2)], 1)
    fin *= adsr(len(fin), 0.01, 1.0, 0.45, 0.8)[:, None]
    music.add(end, fin, 0.4)
    send.add(end, fin, 0.3)
    music.add(end, bass(48, 2.6), 0.5)
    for i, n in enumerate((72, 76, 79, 84, 88)):
        b = bell(n, 2.0)
        sfx.add(end + 0.3 + i * 0.09, b, 0.10, -0.5 + i * 0.25)
        send.add(end + 0.3 + i * 0.09, b, 0.12)

    # ---------- effects from the composition's cue list ----------
    pent = [72, 74, 76, 79, 81, 84, 86, 88]
    last_tab, run = -9, 0
    last_tick, tick_run = -9, 0
    for t, kind in events:
        if kind == 'type':
            n = int(0.05 * SR)
            tt = np.arange(n) / SR
            click = filt(rng.standard_normal(n), 'band', (1800, 6000)) * np.exp(-tt / 0.004)
            thock = sine(380 * (0.85 + 0.3 * rng.random()), n) * np.exp(-tt / 0.012) * 0.6
            sfx.add(t, click + thock, 0.16 * (0.75 + 0.5 * rng.random()), rng.uniform(-0.25, 0.25))
        elif kind == 'tab':
            run = run + 1 if t - last_tab < 0.6 else 0
            last_tab = t
            n = int(0.16 * SR)
            tt = np.arange(n) / SR
            thock = sine(160 + 90 * np.exp(-tt / 0.01), n) * np.exp(-tt / 0.045)
            click = filt(rng.standard_normal(n), 'band', (1500, 5000)) * np.exp(-tt / 0.005) * 0.5
            sfx.add(t, thock + click, 0.42)
            note = pent[min(run, len(pent) - 1)]
            b = bell(note, 0.9)
            sfx.add(t, b, 0.07, 0.2)
            send.add(t, b, 0.1)
        elif kind == 'ghost':
            n = int(0.9 * SR)
            tt = np.arange(n) / SR
            s = sum(sine(midi(m) * (1 + 0.003 * np.sin(2 * np.pi * 5 * tt)), n) for m in (84, 88, 91, 95))
            s = s * adsr(n, 0.05, 0.3, 0.0, 0.2) / 4
            air = filt(rng.standard_normal(n), 'high', 6000) * adsr(n, 0.03, 0.15, 0, 0.1) * 0.25
            sfx.add(t - 0.03, s + air, 0.12)
            send.add(t - 0.03, s, 0.18)
        elif kind.startswith('whoosh'):
            if kind in ('whoosh:dive', 'whoosh:end', 'whoosh:context'):
                continue
            d = 0.5
            w = noise_sweep(d, 500, 5200, 0.0)
            w *= np.sin(np.pi * np.linspace(0, 1, len(w))) ** 2
            pan = np.linspace(-0.7, 0.7, len(w))
            st = np.stack([w * np.cos((pan + 1) * np.pi / 4), w * np.sin((pan + 1) * np.pi / 4)], 1) * np.sqrt(2)
            sfx.add(t - d * 0.55, st, 0.13)
            send.add(t - d * 0.55, st, 0.08)
        elif kind == 'tick':
            tick_run = tick_run + 1 if t - last_tick < 0.8 else 0
            last_tick = t
            n = int(0.09 * SR)
            tt = np.arange(n) / SR
            f = midi(pent[min(tick_run, len(pent) - 1)] + 12)
            blip = sine(f, n) * np.exp(-tt / 0.025) + 0.3 * sine(f * 2, n) * np.exp(-tt / 0.01)
            sfx.add(t, blip, 0.12, 0.15)
            send.add(t, blip, 0.12)
        elif kind == 'pulse':
            n = int(0.3 * SR)
            tt = np.arange(n) / SR
            zap = sine(2600 * np.exp(-tt / 0.03) + 120, n) * np.exp(-tt / 0.06)
            sfx.add(t, zap, 0.05)
            send.add(t, zap, 0.1)

    # ---------- mix ----------
    total = len(drums.x)
    tt = np.arange(total) / SR
    duck = np.ones(total)
    for k in kicks:
        i = int(k * SR)
        seg = tt[i:i + int(0.3 * SR)] - k
        duck[i:i + len(seg)] = np.minimum(duck[i:i + len(seg)], 1 - 0.55 * np.exp(-seg / 0.09))
    music.x *= duck[:, None]

    wet = np.stack([fftconvolve(send.x[:, c], reverb_ir()[:, c])[:total] for c in range(2)], 1)
    mix = drums.x + music.x + sfx.x + 0.35 * wet
    mix = np.stack([filt(mix[:, c], 'high', 28) for c in range(2)], 1)
    mix = mix[: int(dur * SR)]
    fade = int(0.8 * SR)
    mix[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 1.5
    peak = np.abs(mix).max()
    mix = np.tanh(1.2 * mix / peak) / np.tanh(1.2) * 0.89
    wavfile.write(out_path, SR, mix.astype(np.float32))
    print(f'wrote {out_path}: {len(mix) / SR:.2f} s, {len(kicks)} kicks, {len(events)} cues')


if __name__ == '__main__':
    main(*sys.argv[1:4])
