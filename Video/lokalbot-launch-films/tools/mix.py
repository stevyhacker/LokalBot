#!/usr/bin/env python3
"""The film's soundtrack: sound effects from events.json on onetake's palette (one room), the narration from
timeline.json, and any diegetic line, mastered to -16 LUFS with a -3.5 dBTP ceiling.

    ONETAKE=<onetake checkout> python3 tools/mix.py <film_dir>          → <film_dir>/mix.wav (48 kHz stereo)

Each film maps its event kinds to materials in KITS below. Fewer sounds than events is fine: a kind with no
entry is silent. The effects duck 4 dB under the voice.
"""
import json, os, subprocess, sys, wave
import numpy as np
from scipy import signal

ONETAKE = os.environ.get("ONETAKE") or sys.exit("set ONETAKE to a checkout of github.com/feitangyuan/onetake (see README)")
sys.path.insert(0, os.path.join(ONETAKE, "scripts"))
from sfx_palette import Score, air, glass, wood, sub, bubble, SR, hp, lp, bp  # noqa: E402

rng = np.random.default_rng(11)


def k_pullout(e):
    t, k, v, pan = e["t"], e["kind"], e.get("v", 1), e.get("pan", 0) * 0.6
    if k == "pull":    return [(air(1.3, 160, 1500, 1.1, 0.35), t, 0.24 * v, pan, 0.55)]
    if k == "punch":   return [(glass(880, 0.9, 0.7), t, 0.16, 0, 0.45), (sub(74, 0.45), t, 0.20, 0, 0.2)]
    if k == "tick":    return [(glass(1318, 0.5, 0.5), t, 0.08 * v, pan, 0.4)]
    if k == "pop":     return [(bubble(560, 0.2), t, 0.22 * v, pan, 0.3)]
    if k == "fold":    return [(air(0.5, 2600, 380, 1.4, 0.7), t, 0.20, pan, 0.4)]
    if k == "click":   return [(wood(250, 0.08), t, 0.30, pan, 0.2), (wood(195, 0.07), t + 0.06, 0.20, pan, 0.2)]
    if k == "ring":    return [(glass(988, 1.1, 0.55), t, 0.11 * v, pan, 0.55)]
    if k == "switch":  return [(wood(270, 0.07), t, 0.28, pan, 0.2), (glass(1480, 0.35, 0.4), t + 0.05, 0.07, pan, 0.4)]
    if k == "scan":    return [(air(1.25, 500, 4200, 1.6, 0.5), t, 0.20, -0.6, 0.5, 0.6)]
    if k == "drop":    return [(bubble(380, 0.28), t, 0.26, 0, 0.3), (sub(58, 0.5), t, 0.16, 0, 0.2)]
    if k == "key":     return [(wood(170 + rng.uniform(-20, 20), 0.09), t + rng.uniform(0, 0.004), 0.10 * v, pan, 0.15)]
    if k == "results": return [(glass(f, 0.8, 0.45), t + i * 0.07, 0.07, pan, 0.5) for i, f in enumerate((659, 784, 988))]
    if k == "lift":    return [(air(0.75, 300, 2800, 1.2, 0.6), t, 0.22, 0, 0.5)]
    if k == "land":    return [(sub(55, 0.9), t, 0.30, 0, 0.25)] + [(glass(f, 1.8, 0.7), t + 0.04 + i * 0.05, 0.10, 0, 0.6) for i, f in enumerate((523, 784, 1046))]
    return []


def k_streams(e):
    t, k, v, pan = e["t"], e["kind"], e.get("v", 1), e.get("pan", 0) * 0.6
    if k == "trace":   return [(air(1.4, 120, 900, 1.0, 0.25), t, 0.16 * v, -0.6, 0.5, 0.6)]
    if k == "swell":   return [(air(0.9, 200, 1400, 1.1, 0.4), t, 0.14, pan, 0.5), (glass(440, 1.2, 0.4), t, 0.05, pan, 0.6)]
    if k == "pop":     return [(bubble(620, 0.18), t, 0.14 * v, pan, 0.3)]
    if k == "switch":  return [(wood(270, 0.07), t, 0.28, pan, 0.2), (glass(1480, 0.35, 0.4), t + 0.05, 0.07, pan, 0.4)]
    if k == "ignite":  return [(air(1.0, 400, 3600, 1.5, 0.4), t, 0.18, -0.6, 0.5, 0.6)]
    if k == "stop":    return [(sub(50, 0.8), t + 0.35, 0.16, 0, 0.3), (glass(392, 1.8, 0.5), t + 0.4, 0.07, 0, 0.7)]
    if k == "tick":    return [(glass(1318, 0.5, 0.5), t, 0.08 * v, pan, 0.4)]
    if k == "land":    return [(bubble(420, 0.26), t, 0.22, pan, 0.3), (glass(784, 1.2, 0.6), t + 0.02, 0.08, pan, 0.6), (sub(62, 0.5), t, 0.12, pan, 0.2)]
    if k == "open":    return [(air(0.5, 300, 2600, 1.3, 0.3), t, 0.18, pan, 0.4)]
    if k == "key":     return [(wood(170 + rng.uniform(-20, 20), 0.09), t + rng.uniform(0, 0.004), 0.10 * v, pan, 0.15)]
    if k == "fly":     return [(air(0.45, 900, 3000, 1.6, 0.5), t, 0.11, -0.4, 0.4, 0.5)]
    if k == "row":     return [(glass((659, 784, 880, 988)[int(v)], 0.8, 0.45), t, 0.08, pan, 0.5)]
    if k == "click":   return [(wood(250, 0.08), t, 0.30, pan, 0.2), (wood(195, 0.07), t + 0.06, 0.20, pan, 0.2)]
    if k == "card":    return [(air(0.6, 200, 1800, 1.2, 0.4), t, 0.18, 0, 0.5), (sub(58, 0.6), t + 0.1, 0.12, 0, 0.2)]
    if k == "jump":    return [(glass(1174, 0.6, 0.5), t, 0.09, pan, 0.4)]
    if k == "fold":    return [(air(0.6, 2400, 300, 1.4, 0.7), t, 0.20, 0, 0.4)]
    if k == "name":    return [(sub(55, 0.9), t, 0.28, 0, 0.25)] + [(glass(f, 1.8, 0.7), t + 0.04 + i * 0.05, 0.09, 0, 0.6) for i, f in enumerate((523, 659, 784))]
    return []


def bed_streams(curves, n):
    """the streams' rush: band noise that follows the flow speed and stops dead on 'keeps'"""
    hz = curves["hz"]; sp = np.array(curves["flow"]) * np.array(curves["vis"])
    env = np.interp(np.arange(n) / SR, np.arange(len(sp)) / hz, sp)
    x = rng.standard_normal((n, 2))
    lo = np.stack([bp(x[:, c], 420, 0.8) for c in (0, 1)], 1); hi = np.stack([bp(x[:, c], 2200, 1.4) for c in (0, 1)], 1)
    return (lo * 0.8 + hi * 0.25) * env[:, None] * 0.05


def k_machine(e):
    t, k, v, pan = e["t"], e["kind"], e.get("v", 1), e.get("pan", 0) * 0.6
    if k == "thud":    return [(sub(60, 0.7), t, 0.34, pan, 0.2), (wood(120, 0.14), t, 0.30, pan, 0.25)]
    if k == "ring":    return [(glass(523, 1.0, 0.4), t, 0.06 * v, pan, 0.6)]
    if k == "roll":    return [(air(0.95, 120, 700, 0.9, 0.85), t, 0.20, -0.4, 0.3, 0.3)]
    if k == "hit":     return [(wood(160, 0.14), t, 0.34, pan, 0.25), (sub(70, 0.4), t, 0.2, pan, 0.2)]
    if k == "type":    return [(wood(300 + rng.uniform(-40, 40), 0.07), t + rng.uniform(0, 0.004), 0.08 * v, pan, 0.15)]
    if k == "lamp":    return [(glass(1318, 0.6, 0.5), t, 0.08, pan, 0.4)]
    if k == "badge":   return [(bubble(560, 0.2), t, 0.20 * v, pan, 0.3), (wood(220, 0.06), t, 0.12, pan, 0.2)]
    if k == "slam":    return [(sub(48, 1.0), t, 0.40, pan, 0.3), (wood(95, 0.2), t, 0.36, pan, 0.3), (air(0.25, 3000, 600, 1.5, 0.2), t - 0.12, 0.12, pan, 0.2)]
    if k == "eject":   return [(air(0.35, 800, 2600, 1.4, 0.3), t, 0.13, pan, 0.3)]
    if k == "land":    return [(wood(180 + 30 * v, 0.1), t, 0.26 * v, pan, 0.25)]
    if k == "thread":  return [(air(0.5, 2600, 5200, 2.0, 0.3), t, 0.10, pan, 0.4)]
    if k == "arrive":  return [(glass(880 + 220 * (v - 0.6) * 5, 0.8, 0.5), t, 0.08, pan, 0.5)]
    if k == "key":     return [(wood(170 + rng.uniform(-20, 20), 0.09), t + rng.uniform(0, 0.004), 0.10 * v, pan, 0.15)]
    if k == "enter":   return [(wood(240, 0.08), t, 0.30, pan, 0.2), (wood(190, 0.07), t + 0.06, 0.2, pan, 0.2)]
    if k == "hop":     return [(air(0.5, 400, 2400, 1.3, 0.4), t, 0.15, pan, 0.4)]
    if k == "lever":   return [(wood(260, 0.08), t, 0.32, pan, 0.2), (glass(1480, 0.35, 0.4), t + 0.05, 0.07, pan, 0.4)]
    if k == "gate":    return [(wood(140, 0.12), t + 0.08, 0.18, pan, 0.25)]
    if k == "slide":   return [(air(0.7, 200, 900, 1.0, 0.6), t, 0.16, -0.3, 0.3, 0.1)]
    if k == "pull":    return [(air(1.2, 1800, 250, 1.1, 0.4), t, 0.2, 0, 0.5)]
    if k == "letter":  return [(wood(150 + 40 * v, 0.1), t, 0.16 * v, pan, 0.3)]
    if k == "tile":    return [(wood(200, 0.1), t, 0.24, pan, 0.25)] + ([(sub(55, 0.9), t, 0.24, 0, 0.25)] + [(glass(f, 1.8, 0.7), t + 0.03 + i * 0.05, 0.08, 0, 0.6) for i, f in enumerate((523, 659, 784))] if v > 0.95 else [])
    return []


def bed_machine(curves, n):
    """the belt motor: a low hum and slat ticks that follow the belt's speed"""
    hz = curves["hz"]; sp = np.array(curves["belt"]); env = np.interp(np.arange(n) / SR, np.arange(len(sp)) / hz, sp)
    tt = np.arange(n) / SR; hum = np.sin(2 * np.pi * 58 * tt) * 0.6 + np.sin(2 * np.pi * 116 * tt) * 0.25
    noise = lp(rng.standard_normal(n), 900) * 0.5
    ph = np.cumsum(env * 500 / 48 / SR); ticks = (np.diff(np.floor(ph), prepend=0) > 0).astype(float)
    tick = np.convolve(ticks, np.exp(-np.arange(int(0.012 * SR)) / (0.002 * SR)) * np.sin(2 * np.pi * 2400 * np.arange(int(0.012 * SR)) / SR), "same")
    m = (hum + noise) * env * 0.035 + tick * 0.02
    return np.stack([m, m], 1)


def k_tech(e):
    k, t, pan = e["kind"], e["t"], e.get("pan", 0) * 0.6
    if k == "probe":   return [(air(0.5, 1200, 4200, 1.8, 0.3), t, 0.12 * e.get("v", 1), pan, 0.4)]
    if k == "row":     return [(glass((659, 784, 988)[int(e.get("v", 0))], 0.8, 0.45), t, 0.08, pan, 0.5)]
    if k == "click":   return [(wood(250, 0.08), t, 0.26 * e.get("v", 1), pan, 0.2), (wood(195, 0.07), t + 0.06, 0.18, pan, 0.2)]
    return k_machine(e)


KITS = {"pullout": k_pullout, "streams": k_streams, "machine": k_machine, "tech": k_tech}
BEDS = {"streams": bed_streams, "machine": bed_machine, "tech": bed_machine}


def read_mono(p):
    with wave.open(p) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float64) / 32768
        assert w.getframerate() == SR and w.getnchannels() == 1, p
    return x


def main(film):
    name = os.path.basename(os.path.abspath(film))
    tl = json.load(open(os.path.join(film, "timeline.json")))
    ev = json.load(open(os.path.join(film, "events.json")))["events"]
    dur = tl["dur"]; n = int(SR * dur)
    s = Score(dur=dur, T60=1.0)
    for e in ev:
        for item in KITS[name](e):
            sig, t, gain, pan, send, *rest = item
            s.place(sig, t, gain, pan, send, pan_to=rest[0] if rest else None)
    fx = s.mix(peak_db=-12.0)
    curves = json.load(open(os.path.join(film, "events.json"))).get("curves")
    if name in BEDS and curves:
        bed = BEDS[name](curves, len(fx)); fx = fx + bed[:len(fx)] * (np.abs(fx).max() / 0.25)
    # voice bus
    voice = np.zeros(n + SR)
    for v in tl["vo"]:
        x = read_mono(os.path.join(film, "vo", "liam", f"t{v['i']}.wav")); i0 = int(v["t"] * SR); voice[i0:i0 + len(x)] += x
    if "meet" in tl:                                   # the meeting, heard as a call: band-limited, a little lower
        m = tl["meet"]; x = read_mono(os.path.join(film, "vo", "meeting", "t0.wav"))
        x = lp(hp(x, 170), 5200) * 0.8; i0 = int(m["t"] * SR); voice[i0:i0 + len(x)] += x
    voice = voice[:n]
    env = np.convolve(np.abs(voice), np.ones(int(0.05 * SR)) / int(0.05 * SR), "same")
    duck = 1 - 0.37 * np.clip(env / (env.max() * 0.25 + 1e-9), 0, 1)          # about -4 dB under speech
    duck = signal.filtfilt(*signal.butter(1, 4 / (SR / 2)), duck)
    mixd = fx * duck[:, None] + voice[:, None] * np.array([1.0, 1.0])
    fade = np.ones(n); fl = int(0.25 * SR); fade[-fl:] = np.linspace(1, 0, fl); mixd *= fade[:, None]
    raw = os.path.join(film, "mix.raw.wav"); out = os.path.join(film, "mix.wav")
    with wave.open(raw, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(mixd / (np.abs(mixd).max() + 1e-9) * 0.7, -1, 1) * 32767).astype(np.int16).tobytes())
    # two-pass loudnorm → -16 LUFS, -3.5 dBTP
    meas = subprocess.run(["ffmpeg", "-hide_banner", "-i", raw, "-af", "loudnorm=I=-16:TP=-3.5:LRA=11:print_format=json", "-f", "null", "-"],
                          capture_output=True, text=True).stderr
    j = json.loads(meas[meas.rindex("{"): meas.rindex("}") + 1])
    af = (f"loudnorm=I=-16:TP=-3.5:LRA=11:measured_I={j['input_i']}:measured_TP={j['input_tp']}:measured_LRA={j['input_lra']}"
          f":measured_thresh={j['input_thresh']}:offset={j['target_offset']}:linear=true")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", raw, "-af", af, "-ar", str(SR), out], check=True)
    os.remove(raw)
    chk = subprocess.run(["ffmpeg", "-hide_banner", "-i", out, "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True).stderr
    summ = chk[chk.rindex("Summary:"):]
    I = [l for l in summ.splitlines() if l.strip().startswith("I:")][0].split()[1]
    P = [l for l in summ.splitlines() if l.strip().startswith("Peak:")][0].split()[1]
    print(f"{out}: {len(ev)} events, {I} LUFS, true peak {P} dBFS")


main(sys.argv[1])
