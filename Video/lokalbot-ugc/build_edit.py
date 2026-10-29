"""Builds edit.json, the over-the-top cut's timeline, from the voice takes and
the app takes.

The app is shown as its window, whole or followed by a camera that moves with
the pointer the way a screen-recording editor does: it eases towards the
pointer, zooms in for each click and out again when the screen changes, and
stays on the window. Every cue sits on a spoken word: the beat drops on
"Stop", the evidence opens on "remembers", the meeting opens as "LokalBot" is
said, "boom" opens the recap, the transcript opens on "jumps", "exact" circles
the moment, the suggestion appears on "already", and two Tabs land on each
spoken "tab".

The app's reactions play at their recorded speed. Between clicks, while the
screen sits still, the take holds or skips ahead (the frames are the same, so
it doesn't show), so each click lands on its word. Where a reaction would
have to play faster, that stretch carries a "sped up" sticker; the typing in
the autocomplete shot always does (2x, and the wait for the suggestion is cut).
The pointer is drawn: it rests where the take's pointer rested and glides
between the take's own targets, reaching each click just before it lands.

  python3 build_edit.py [--voice liam-ott] [--music hype-a]

Reads production/eleven-generation.json (tts_elevenlabs.py) for the voice's
per-character timings; without it the timings are estimated from the text,
so the picture can be laid out before the voice exists. The takes come from
prepare_footage.py (footage/<take>/take.json). The music's drop and beat grid
are measured from the file (assets/sound/eleven/<music>.mp3, from
eleven_sound.py), with the tempo from sound.json.
"""
import argparse
import json
import math
import re
import subprocess
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
FPS = 30
W, H = 1080, 1920
# The camera's centre lands here on screen; the window keeps clear of the
# title sticker above SAFE[0] and the captions below SAFE[1] when it can.
ANCHOR = (540, 885)
SAFE = (305, 1480)
SIDE = 40                    # screen pixels the window keeps from the sides
TYPE_SPEED = 2.0             # the autocomplete shot's typing
POINTER = 1.5                # the drawn pointer's size against the system's
# The windows' corner radius in footage pixels, measured on the 2x takes: the
# frame shows the take's background colour outside it.
RADIUS = {'flow': 54, 'follow-up': 28}


def strip_tags(text):
    return re.sub(r'\[[^\]]*\]\s*', '', text)


def spoken_chars(al):
    """Indices of the characters outside audio tags such as [excited]."""
    out, depth = [], 0
    for i, ch in enumerate(al['characters']):
        if ch == '[':
            depth += 1
        elif ch == ']':
            depth = max(0, depth - 1)
        elif not depth:
            out.append(i)
    return out


def words_from_alignment(al, offset):
    """[(word, start, end)] in timeline seconds from ElevenLabs character timings."""
    chars, starts, ends = al['characters'], al['character_start_times_seconds'], al['character_end_times_seconds']
    out, cur, s, e = [], '', None, None
    for i in spoken_chars(al):
        ch, a, b = chars[i], starts[i], ends[i]
        if ch.isspace():
            if cur:
                out.append([cur, s + offset, e + offset])
            cur, s, e = '', None, None
            continue
        if s is None:
            s = a
        cur += ch
        if ch.isalnum() or e is None:
            e = b  # a word ends with its last letter; punctuation holds the pauses
    if cur:
        out.append([cur, s + offset, e + offset])
    return out


def estimated_alignment(text, rate=17.5):
    chars = list(strip_tags(text))
    starts, ends, t = [], [], 0.1
    for ch in chars:
        d = 1 / rate * (2.6 if ch in '.?!' else 1.8 if ch in ',:' else 1.0)
        starts.append(t)
        ends.append(t + d)
        t += d
    return {'characters': chars, 'character_start_times_seconds': starts, 'character_end_times_seconds': ends}, t + 0.15


def decode(path, sr=16000):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-ac', '1', '-ar', str(sr), '-'],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype='<f4')


def audible_end(path, floor_db=-40.0):
    """Seconds to the end of the last 20 ms window louder than floor_db."""
    x, win = decode(path), 320
    rms = np.sqrt(np.mean(x[:len(x) // win * win].reshape(-1, win) ** 2, axis=1) + 1e-12)
    loud = np.nonzero(20 * np.log10(rms) > floor_db)[0]
    return (loud[-1] + 1) * win / 16000 if len(loud) else len(x) / 16000


def music_cues(path, bpm):
    """(drop, phase): where the full beat first hits, and the beat grid's offset.

    The drop is the biggest rise in loudness over two seconds in the first ten;
    the grid is the phase of `bpm` that best lines up with low-end onsets.
    """
    sr, hop = 16000, 160
    x = decode(path, sr)
    n = len(x) // hop
    frames = x[:n * hop].reshape(n, hop)
    rms = np.sqrt(np.mean(frames ** 2, axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    w = 200                                         # 2 s at 100 frames/s
    best, drop = -1e9, 0.0
    for i in range(30, min(n - w, 1000)):
        rise = db[i:i + w].mean() - db[max(0, i - w):i].mean()
        if rise > best + 0.5:
            best, drop = rise, i / 100
    # Low-end onsets: positive changes of a 30-band-wide low-pass energy.
    spec = np.abs(np.fft.rfft(np.hanning(512) * np.lib.stride_tricks.sliding_window_view(
        np.pad(x, (0, 512)), 512)[::hop][:n], axis=1))
    low = np.log(spec[:, 1:8].sum(axis=1) + 1e-6)
    onset = np.maximum(0, np.diff(low, prepend=low[0]))
    period = 60 / bpm
    lo, hi = int(drop * 100), min(n, int((drop + 8) * 100))
    phases = np.arange(0, period, 0.005)
    score = [onset[np.clip((np.arange(drop + p, hi / 100, period) * 100).astype(int), 0, n - 1)].sum()
             for p in phases]
    phase = (drop + phases[int(np.argmax(score))]) % period
    # Snap the drop onto the grid.
    drop = phase + round((drop - phase) / period) * period
    return round(drop, 3), round(phase, 3), period


def find(words, pattern, after=0.0, nth=0):
    hits = [(s, e) for w, s, e in words if s >= after and re.fullmatch(pattern, re.sub(r'[^\w$]', '', w), re.I)]
    if len(hits) <= nth:
        raise SystemExit(f'no word matching {pattern!r}')
    return hits[nth]


def key(word):
    return re.sub(r'[^a-z0-9]', '', word.lower())




class Take:
    """One filmed take: its frames, events and pointer path in footage pixels."""

    def __init__(self, name):
        m = json.loads((HERE / 'footage' / name / 'take.json').read_text())
        self.name, self.meta = name, m
        self.scale = m.get('scale', 1)
        self.size = m['size']
        self.count = m['count']
        self.events = m['events']
        self.changes = np.array(m.get('changes') or [[0.0] * 8], float)
        p = np.array(m.get('pointer') or [[0.0, -1e4, -1e4]], float)
        self.pt, self.px, self.py = p[:, 0], p[:, 1] * self.scale, p[:, 2] * self.scale

    def pointer(self, tau):
        return float(np.interp(tau, self.pt, self.px)), float(np.interp(tau, self.pt, self.py))

    def inside(self, x, y, pad=0):
        return -pad <= x <= self.size[0] + pad and -pad <= y <= self.size[1] + pad

    def clicks(self):
        return [(e['t'], e['x'] * self.scale, e['y'] * self.scale) for e in self.events if e['kind'] == 'click']

    def click_before(self, mark):
        """The last click before a mark event, as (t, x, y)."""
        at = self.mark(mark)
        hits = [c for c in self.clicks() if c[0] < at]
        if not hits:
            raise SystemExit(f'{self.name}: no click before {mark}')
        return hits[-1]

    def mark(self, name):
        hits = [e['t'] for e in self.events if e['kind'] == 'mark' and e.get('name') == name]
        if not hits:
            raise SystemExit(f'{self.name}: no mark {name}')
        return hits[0]

    def busy(self):
        """Take times when the app changed on screen; a blinking caret doesn't count."""
        c = self.changes
        return c[(c[:, 6] - c[:, 4] > 16) | (c[:, 7] - c[:, 5] > 48), 0]

    def settled(self, after, before, first=1.0, gap=0.6):
        """When the screen stops changing after a click at `after`: the end of
        the run of changes that starts within `first` of it, each within `gap`
        of the one before. At most `before`."""
        end = after
        for t in self.busy():
            if t <= after:
                continue
            if t > before or t - end > (first if end == after else gap):
                break
            end = t
        return min(before, end + 1 / FPS)

    def frame(self, tau):
        return int(min(self.count, max(1, round(tau * 30) + 1)))


def tinted_box(take, tau):
    """(x0, y0, x1, y1) in footage pixels of the transcript's highlighted
    segment in the frame at take time tau, found by its green tint."""
    path = HERE / 'footage' / take.name / f'{take.frame(tau):04d}.jpg'
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         check=True, capture_output=True).stdout
    im = np.frombuffer(raw, np.uint8).reshape(take.size[1], take.size[0], 3).astype(int)
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    tint = (g - r > 4) & (g > 205) & (g < 235) & (b > 200)
    rows, cols = np.nonzero(tint.sum(1) > 300)[0], np.nonzero(tint.sum(0) > 100)[0]
    if not len(rows) or not len(cols):
        raise SystemExit(f'{take.name}: no highlighted segment at {tau:.2f}')
    return int(cols.min()), int(rows.min()), int(cols.max()), int(rows.max())


def idle_map(take, anchors, end, lead=0.35):
    """Breakpoints [[edit t, take t]] through anchors [(edit t, take t)], one
    per click, holding the last screen until `end`.

    After a click the take plays at its own speed until the app has settled.
    That still screen holds until `lead` before the next click, and the take
    skips ahead to play that last stretch, where the pointer arrives and the
    target lights up, at its own speed again. Returns the breakpoints and the
    stretches, in edit time, that play faster than recorded (a reaction that
    outlasts the time to the next click).
    """
    pts, fast = [], []
    for (o0, k0), (o1, k1) in zip(anchors, anchors[1:]):
        rest = take.settled(k0, k1)
        pre = min(lead, k1 - rest)
        room = o1 - o0 - pre
        pts.append([o0, k0])
        if rest - k0 > room:
            fast.append([o0, o0 + room])
            pts.append([o0 + room, rest])
        else:
            pts += [[o0 + rest - k0, rest], [o1 - pre - 0.001, rest]]
        pts.append([o1 - pre, k1 - pre])
    o, k = anchors[-1]
    rest = take.settled(k, k + 10)
    pts += [[o, k], [o + rest - k, rest], [max(end, o + rest - k + 0.001), rest]]
    out = []
    for p in pts:
        if out and p[0] <= out[-1][0]:
            out[-1] = p
        else:
            out.append(p)
    return [[round(a, 4), round(b, 4)] for a, b in out], fast


def glide_time(d):
    """Seconds the drawn pointer takes to travel d footage pixels."""
    return min(0.75, max(0.3, 0.25 + d / 1600))


def pointer_glides(take, clicks, arrive=0.3, pause=0.25):
    """[[t0, t1, x0, y0, x1, y1]]: the drawn pointer's glides in edit time.

    `clicks` are [(edit t, take t)] for the take's clicks in order. Before each
    click the pointer goes through the take's own `move` targets since the
    click before, then to the click, arriving `arrive` before it; it starts
    where the take's pointer started. Moves that don't fit are skipped.
    """
    s = take.scale
    events = [e for e in take.events if e['kind'] in ('move', 'click')]
    x, y = take.pointer(0)
    glides, prev_k, free = [], -1.0, 0.0
    for o, k in clicks:
        stops = [(e['x'] * s, e['y'] * s) for e in events if prev_k < e['t'] < k - 1e-3 and e['kind'] == 'move']
        click = next((e['x'] * s, e['y'] * s) for e in events if e['kind'] == 'click' and abs(e['t'] - k) < 1e-3)
        while True:
            path, t1, plan = [(x, y)] + stops + [click], o - arrive, []
            for a, b in reversed(list(zip(path, path[1:]))):
                g = glide_time(math.hypot(b[0] - a[0], b[1] - a[1]))
                plan.insert(0, [t1 - g, t1, *a, *b])
                t1 -= g + pause
            if plan[0][0] >= free or not stops:
                break
            stops = stops[1:]
        if plan[0][0] < free:
            plan[0][0] = min(free, plan[0][1] - 0.15)
        glides += [[round(v, 4) for v in g] for g in plan]
        x, y = click
        free, prev_k = o + 0.05, k
    return glides


def pointer_at(glides, t, start):
    """The drawn pointer's position at edit time t: resting, or on a glide
    with a minimum-jerk ease and a slight arc."""
    x, y = start
    for i, (t0, t1, x0, y0, x1, y1) in enumerate(glides):
        if t < t0:
            break
        if t >= t1:
            x, y = x1, y1
            continue
        u = (t - t0) / (t1 - t0)
        e = u ** 3 * (10 - 15 * u + 6 * u * u)
        bend = 0.06 * math.sin(math.pi * e) * (1 if i % 2 else -1)
        return x0 + (x1 - x0) * e - (y1 - y0) * bend, y0 + (y1 - y0) * e + (x1 - x0) * bend
    return x, y


def tau_at(tmap, t):
    a = np.array(tmap)
    return float(np.interp(t, a[:, 0], a[:, 1]))


def edit_time(tmap, tau):
    """The first edit time showing take time tau."""
    for (o0, k0), (o1, k1) in zip(tmap, tmap[1:]):
        if k0 <= tau <= k1 and k1 > k0:
            return o0 + (o1 - o0) * (tau - k0) / (k1 - k0)
    return tmap[-1][0]


def spring(values, f, x0=None):
    """A critically damped spring at f Hz following `values`, one per frame."""
    w, sub = 2 * math.pi * f, 4
    dt = 1 / FPS / sub
    x = values[0] if x0 is None else x0
    v, out = 0.0, []
    for g in values:
        for _ in range(sub):
            v += (w * w * (g - x) - 2 * w * v) * dt
            x += v * dt
        out.append(x)
    return out


def bound(take, cx, cy, k):
    """Keeps the view on the window: centred when the window fits the screen,
    otherwise no further past its edges than the safe area."""
    fw, fh = take.size
    if fw * k <= W - 2 * SIDE:
        cx = fw / 2 + (ANCHOR[0] - W / 2) / k
    else:
        cx = min(max(cx, (ANCHOR[0] - SIDE) / k), fw - (W - SIDE - ANCHOR[0]) / k)
    if fh * k <= SAFE[1] - SAFE[0]:
        cy = fh / 2 + (ANCHOR[1] - (SAFE[0] + SAFE[1]) / 2) / k
    else:
        cy = min(max(cy, (ANCHOR[1] - SAFE[0]) / k), fh - (SAFE[1] - ANCHOR[1]) / k)
    return cx, cy


def overview(take):
    """The zoom that shows the whole window in the safe area."""
    fw, fh = take.size
    return min((W - 2 * SIDE) / fw, (SAFE[1] - SAFE[0]) / fh)


def camera_path(take, tmap, times, beats, focus=None, aim=None):
    """[cx, cy, k] per edit time. `beats` are (edit t, zoom, target) steps;
    a target is 'pointer' (where `aim` says the pointer is about to be), 'line'
    (where `focus` says the text being typed is), 'window', or [x, y] in
    footage pixels.
    The steps are eased with springs, so the camera glides and settles."""
    tx, ty, tk = [], [], []
    for t in times:
        b = [b for b in beats if b[0] <= t] or beats[:1]
        _, zoom, target = b[-1]
        k = overview(take) if zoom == 'fit' else zoom
        tau = tau_at(tmap, t + 0.12)
        if target == 'pointer':
            x, y = aim(t + 0.12)
            if not take.inside(x, y):
                x, y = take.size[0] / 2, take.size[1] / 2
        elif target == 'line':
            x, y = focus(tau)
        elif target == 'window':
            x, y = take.size[0] / 2, take.size[1] / 2
        else:
            x, y = target
        x, y = bound(take, x, y, k)
        tx.append(x)
        ty.append(y)
        tk.append(math.log(k))
    ks = [math.exp(v) for v in spring(tk, 0.9)]
    xs, ys = spring(tx, 1.1), spring(ty, 1.1)
    return [[round(x, 1), round(y, 1), round(k, 4)] for x, y, k in
            (list(bound(take, x, y, k)) + [k] for x, y, k in zip(xs, ys, ks))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--voice', default='')
    ap.add_argument('--seed', type=int, default=11)
    ap.add_argument('--music', default='hype-a')
    args = ap.parse_args()
    spec = json.loads((HERE / 'narration.json').read_text())
    gen_path = HERE / 'production/eleven-generation.json'
    rows = {}
    if args.voice and gen_path.exists():
        for r in json.loads(gen_path.read_text())['rows']:
            if r.get('voice_name') == args.voice and r['seed'] == args.seed:
                rows[r['id']] = r
    lines = []
    for sc in spec['scenes']:
        text = sc.get('spoken') or sc['caption']
        if sc['id'] in rows:
            r = rows[sc['id']]
            al, file = r['alignment'], 'assets/voice/' + Path(r['file']).name
        else:
            al, _ = estimated_alignment(text)
            file = None
        speech = [i for i in spoken_chars(al) if al['characters'][i].isalnum()]
        lead = al['character_start_times_seconds'][speech[0]]
        last = audible_end(HERE / file) if file else al['character_end_times_seconds'][speech[-1]]
        lines.append({'id': sc['id'], 'al': al, 'file': file, 'lead': lead, 'speech': last - lead,
                      'emphasis': sc.get('emphasis', {})})

    flow = Take('flow')
    typing = Take('follow-up')
    TYPED = typing.mark('typed') + 0.05
    GHOST = next(e['t'] for e in typing.events if e['kind'] == 'ghost')
    TABS = [e['t'] for e in typing.events if e.get('key') == 'tab']
    ACCEPTED = next(e['t'] for e in typing.events if e['kind'] == 'accepted')

    # Speech starts: no air between lines; the end line waits for the last Tab.
    t = 0.12
    for i, ln in enumerate(lines):
        if i:
            prev = lines[i - 1]
            t = prev['start'] + prev['speech'] + 0.14
        if ln['id'] == '05-end':
            t = max(t, tab_done + 0.3)
        ln['start'] = t                      # first spoken character
        ln['at'] = t - ln['lead']            # where the audio file starts
        ln['words'] = words_from_alignment(ln['al'], ln['at'])
        last = ln['words'][-1]
        last[2] = min(last[2], t + ln['speech'])
        last[1] = min(last[1], last[2] - 0.2)
        if ln['id'] == '04-tab':
            said = [find(ln['words'], 'tab', nth=k) for k in range(3)]
            # Two presses per spoken "tab": one as it starts, one halfway to the next.
            press = []
            for k, (s, e) in enumerate(said):
                nxt = said[k + 1][0] if k + 1 < len(said) else e + 0.22
                press += [s + 0.02, s + 0.02 + (nxt - s) / 2]
            press = press[:len(TABS)]
            tab_done = press[-1] + (ACCEPTED - TABS[len(press) - 1]) * 0.6
    L = {ln['id']: ln for ln in lines}
    Wd = {k: ln['words'] for k, ln in L.items()}
    end_line = L['05-end']
    duration = round(end_line['start'] + end_line['speech'] + 1.5, 2)

    def cut(id_):
        return round(L[id_]['start'] - 0.06, 3)

    punches, shakes, flashes, sfx, rings, clicks, sped = [], [], [], [], [], [], []
    c02, c04, a_end = cut('02-notes'), cut('04-tab'), cut('05-end')

    # The app: Ask answers from the meeting; the evidence opens on "remembers";
    # its first source opens the meeting as "LokalBot" is said; the recap opens
    # on "boom"; a decision's citation opens the transcript on "jumps".
    stop_s, _ = find(Wd['01-hook'], 'stop')
    rem_s, _ = find(Wd['01-hook'], 'remembers')
    bot_s, _ = find(Wd['02-notes'], 'lokalbot')
    rec_s, _ = find(Wd['02-notes'], 'records')
    boom_s, _ = find(Wd['02-notes'], 'boom')
    recap_s, _ = find(Wd['02-notes'], 'recap')
    dec_s, _ = find(Wd['02-notes'], 'decision')
    click_s, _ = find(Wd['03-cite'], 'click')
    jumps_s, _ = find(Wd['03-cite'], 'jumps')
    exact_s, _ = find(Wd['03-cite'], 'exact')
    ev, src, tab, jump = (flow.click_before(m) for m in ('evidence', 'meeting', 'summary', 'transcript'))
    anchors = [(rem_s - 0.05, ev[0]), (bot_s + 0.12, src[0]), (boom_s - 0.03, tab[0]), (jumps_s - 0.06, jump[0])]
    flow_map, fast = idle_map(flow, [(0.0, 0.0)] + anchors, c04 + 0.5)
    sped += [[float(a), float(b)] for a, b in fast]
    glides = pointer_glides(flow, anchors)
    park = flow.pointer(0)

    def aim(t):
        return pointer_at(glides, t, park)
    for (o, _), c in zip(anchors, (ev, src, tab, jump)):
        clicks.append({'take': 'flow', 't': round(o, 3), 'x': c[1], 'y': c[2]})

    def spot(x, y, w, h, px=14, py=12):
        """A ring around an element's frame in window points, as the probes'
        accessibility trees give it, in footage pixels."""
        sc = flow.scale
        return [round((x + w / 2) * sc), round((y + h / 2) * sc), round((w / 2 + px) * sc), round((h / 2 + py) * sc)]
    answer = spot(269, 183, 383, 38)
    evidence = spot(269, 269, 383, 263)
    recap = spot(276, 282, 368, 46)
    decisions = spot(278, 526, 366, 58)
    # The transcript scrolls to the cited segment, so it is found in the frame.
    x0, y0, x1, y1 = tinted_box(flow, flow.settled(jump[0], jump[0] + 5))
    moment = [round((x0 + x1) / 2), round((y0 + y1) / 2), round((x1 - x0) / 2 + 28), round((y1 - y0) / 2 + 24)]
    rings += [{'take': 'flow', 'from': round(recap_s - 0.02, 3), 'to': round(dec_s - 0.08, 3), 'ring': recap},
              {'take': 'flow', 'from': round(dec_s - 0.02, 3), 'to': round(c04 - 2.0, 3), 'ring': decisions},
              {'take': 'flow', 'from': round(exact_s - 0.02, 3), 'to': c04, 'ring': moment}]
    rings = [r for r in rings if r['to'] > r['from']]
    flow_beats = [(0, 0.95, answer[:2]), (stop_s + 0.05, 1.15, answer[:2]), (rem_s - 0.75, 1.2, 'pointer'),
                  (rem_s + 0.1, 1.1, evidence[:2]), (bot_s - 0.45, 1.25, 'pointer'),
                  (bot_s + 0.15, 'fit', 'window'), (rec_s + 0.25, 1.05, moment[:2]),
                  (boom_s - 0.85, 1.15, 'pointer'), (boom_s + 0.02, 'fit', 'window'),
                  (recap_s - 0.1, 1.25, recap[:2]), (dec_s - 0.1, 1.2, decisions[:2]),
                  (click_s - 0.05, 1.3, 'pointer'), (jumps_s + 0.05, 1.05, moment[:2]),
                  (exact_s - 0.05, 1.3, moment[:2])]
    punches += [[stop_s, 0.12], [rem_s, 0.07], [boom_s, 0.14], [exact_s, 0.1], [jumps_s, 0.06], [bot_s + 0.12, 0.05]]
    shakes += [[stop_s, 16, 0.4], [boom_s, 20, 0.45], [exact_s, 12, 0.35]]
    flashes += [[boom_s, 0.55]]
    sfx += [[stop_s, 'bassdrop', -3, 'peak'], [stop_s - 0.02, 'impact', -6, 'peak'], [boom_s, 'impact', -2, 'peak'],
            [jumps_s - 0.06, 'glitch', -9, 'start'], [exact_s, 'bassdrop', -3, 'peak'], [bot_s + 0.12, 'whoosh', -8, 'peak']]
    shots = [{'id': 'flow', 'take': 'flow', 'from': 0, 'to': c04, 'map': flow_map, 'beats': flow_beats,
              'aim': aim}]

    # Autocomplete: typing at 2x into "already", where the suggestion shows and is
    # circled; then two Tabs per spoken "tab", every word accepted.
    already_s, _ = find(Wd['04-tab'], 'already')
    ghost_t = already_s
    type_from = TYPED - (ghost_t - 0.05 - c04) * TYPE_SPEED
    tab_map = [[c04, type_from], [ghost_t - 0.05, TYPED], [ghost_t - 0.0499, GHOST - 0.05], [ghost_t, GHOST]]
    if press[0] - 0.2 > ghost_t + 0.05:
        tab_map.append([press[0] - 0.2, TABS[0] - 0.2])
    tab_map += [[p, k] for p, k in zip(press, TABS)] + [[tab_done, ACCEPTED], [tab_done + 2, ACCEPTED + 2]]
    sped.append([c04, float(round(tab_done + 0.2, 3))])
    # Where the text changed: typing changes a few glyphs; a whole-window change is a redraw.
    c = typing.changes
    focus = c[(c[:, 1] > 0) & (c[:, 1] < typing.size[0] * typing.size[1] / 16 * 0.05)][:, [0, 2, 3, 4, 5, 6, 7]]
    if not len(focus):
        focus = np.array([[0, typing.size[0] / 2, typing.size[1] / 2] + [0] * 4])

    def typing_focus(tau):
        """The middle of the text across, and the height where it last changed."""
        i = np.nonzero(focus[:, 0] <= tau)[0]
        return line_x, float(focus[i[-1] if len(i) else 0, 2])
    line_x = float(focus[:, 3].min() + focus[:, 5].max()) / 2
    near = focus[np.argmin(np.abs(focus[:, 0] - GHOST))]
    ghost_box = [round((near[3] + near[5]) / 2), round((near[4] + near[6]) / 2),
                 round((near[5] - near[3]) / 2 + 16), round((near[6] - near[4]) / 2 + 16)]
    # Whole lines while typing; in on the suggestion, then back out a little for the Tabs.
    type_beats = [(c04, 0.78, 'line'), (ghost_t - 0.1, 0.95, ghost_box[:2]),
                  (press[0] - 0.1, 0.88, [typing.size[0] / 2 - 80, ghost_box[1]])]
    shots.append({'id': 'type', 'take': 'follow-up', 'from': c04, 'to': a_end, 'map': tab_map, 'beats': type_beats,
                  'focus': True})
    punches += [[ghost_t, 0.1]] + [[p, 0.045] for p in press]
    shakes += [[ghost_t, 10, 0.3]] + [[p, 7, 0.16] for p in press]
    rings.append({'take': 'follow-up', 'from': ghost_t + 0.06, 'to': a_end, 'ring': ghost_box, 'under': True})
    sfx += [[ghost_t, 'glitch', -7, 'start'], [ghost_t + 0.02, 'pop', -6, 'start']]
    sfx += [[p, 'tab', -4, 'start'] for p in press]
    typing_span = [round(c04, 3), round(ghost_t - 0.05, 3)]

    # End card: slams in on the cut; a chip on each fact; the name on "LokalBot".
    shots.append({'id': 'end', 'take': None, 'from': a_end, 'to': duration})
    free_s, _ = find(Wd['05-end'], 'free')
    open_s, _ = find(Wd['05-end'], 'open')
    runs_s, _ = find(Wd['05-end'], 'ai')
    name_s, _ = find(Wd['05-end'], 'lokalbot')
    shakes += [[a_end, 22, 0.5], [free_s, 8, 0.2], [open_s, 8, 0.2], [runs_s, 8, 0.2], [name_s, 16, 0.4]]
    flashes += [[a_end, 0.75], [name_s, 0.35]]
    sfx += [[a_end - 1.45, 'riser', -8, 'start'], [a_end, 'slam', -2, 'peak'],
            [free_s, 'pop', -7, 'start'], [open_s, 'pop', -7, 'start'], [runs_s, 'pop', -7, 'start'],
            [name_s, 'impact', -3, 'peak']]

    # The swap from the app to TextEdit: one window flies out, the next one in.
    swaps = [c04]
    sfx += [[w - 0.06, 'whoosh', -3, 'peak'] for w in swaps]
    sfx += [[c['t'], 'click', -8, 'start'] for c in clicks]

    # Per frame: each visible window's frame, camera and pointer.
    takes = {'flow': flow, 'follow-up': typing}
    cams = {}
    for shot in shots[:2]:
        take = takes[shot['take']]
        times = [i / FPS for i in range(int((shot['from'] - 0.5) * FPS), int((shot['to'] + 0.5) * FPS) + 1)]
        cams[shot['id']] = dict(zip([round(t * FPS) for t in times],
                                    camera_path(take, shot['map'], times, shot['beats'], typing_focus,
                                                shot.get('aim'))))
    # A swap: the outgoing window starts flying out SWAP_OUT[0] before the cut
    # and is gone SWAP_OUT[1] later; the incoming one does the same with SWAP_IN.
    SWAP_OUT, SWAP_IN = (0.12, 0.32), (0.1, 0.38)
    frames = []
    for i in range(int(round(duration * FPS))):
        t = i / FPS
        layers = []
        for shot in shots[:2]:
            t0 = shot['from'] - (SWAP_IN[0] if shot['from'] in swaps else 0)
            t1 = shot['to'] + (SWAP_OUT[1] - SWAP_OUT[0] if shot['to'] in swaps else 0)
            if not t0 <= t < t1:
                continue
            take = takes[shot['take']]
            tau = tau_at(shot['map'], min(max(t, shot['from']), shot['to']))
            cx, cy, k = cams[shot['id']][i]
            layer = {'take': take.name, 'n': take.frame(tau), 'cam': [cx, cy, k]}
            x, y = aim(t)
            if take.name == 'flow' and take.inside(x, y):
                down = max([1 - abs(t - c['t']) / 0.12 for c in clicks if c['take'] == take.name] + [0])
                layer['cursor'] = [round(x, 1), round(y, 1), round(down, 3)]
            layer['ripples'] = [[c['x'], c['y'], round(t - c['t'], 3)] for c in clicks
                                if c['take'] == take.name and 0 <= t - c['t'] < 0.6]
            if shot['to'] in swaps and t >= shot['to'] - SWAP_OUT[0]:
                layer['fly'] = ['out', round((t - shot['to'] + SWAP_OUT[0]) / SWAP_OUT[1], 4)]
            elif shot['from'] in swaps and t < t0 + SWAP_IN[1]:
                layer['fly'] = ['in', round((t - t0) / SWAP_IN[1], 4)]
            layers.append(layer)
        frames.append(layers)

    # Captions: one or two words at a time (three when they are short), broken
    # after punctuation; each word pops in as it is said.
    captions, emojis = [], []
    for ln in lines:
        ws, i = ln['words'], 0
        while i < len(ws):
            j = i + 1
            while j < len(ws) and ws[j - 1][0][-1] not in ',.?!:':
                text = ' '.join(x[0] for x in ws[i:j + 1])
                if j - i >= 3 or (j - i >= 2 and len(text) > 11) or len(text) > 14:
                    break
                j += 1
            chunk = []
            for w, s, e in ws[i:j]:
                style, emoji = ln['emphasis'].get(key(w), [None, None])
                chunk.append([w, round(s, 3), round(e, 3), style])
                if emoji:
                    emojis.append({'from': round(s, 3), 'emoji': emoji})
                    sfx.append([s, 'pop', -13, 'start'])
            captions.append({'words': chunk})
            i = j
    for i, c in enumerate(captions):
        nxt = captions[i + 1]['words'][0][1] if i + 1 < len(captions) else duration
        c['from'] = 0 if i == 0 else round(c['words'][0][1] - 0.03, 3)
        c['to'] = round(min(nxt - 0.03, c['words'][-1][2] + 0.5), 3)
    if emojis and emojis[0]['from'] < 0.3:
        emojis[0]['from'] = 0  # up from the first frame, like the first caption
    cuts = [s['from'] for s in shots[1:]] + [duration]
    for i, m in enumerate(emojis):
        nxt = emojis[i + 1]['from'] if i + 1 < len(emojis) else duration
        m['to'] = round(min(nxt, m['from'] + 1.1, next(c for c in cuts if c > m['from'])), 3)

    # Music: the drop lands on "Stop"; the beat grid drives small pulses.
    music = {'file': None, 'at': 0.0, 'beats': []}
    sound = json.loads((HERE / 'sound.json').read_text())
    bpm = {m['id']: m.get('bpm') for m in sound['music']}.get(args.music)
    path = HERE / 'assets/sound/eleven' / f'{args.music}.mp3'
    if not path.exists():
        path, bpm = HERE / 'assets/music/bed-d.mp3', 116
    if path.exists() and bpm:
        drop, phase, period = music_cues(path, bpm)
        at = stop_s - drop
        beats = [round(at + phase + k * period, 3) for k in range(int(duration / period) + 4)]
        music = {'file': str(path.relative_to(HERE)), 'at': round(at, 3), 'drop': drop, 'bpm': bpm,
                 'beats': [b for b in beats if 0 <= b < duration]}

    # The pointer is drawn as a vector arrow (comp.js) at POINTER times the
    # system pointer's size, so it stays sharp when the camera zooms in.
    cursor = {'file': None, 'size': [17, 23], 'hot': [1, 1], 'scale': POINTER * flow.scale}
    edit = {'fps': FPS, 'size': [W, H], 'anchor': ANCHOR, 'duration': duration, 'voice_name': args.voice or 'estimated',
            'voice': [{'id': ln['id'], 'file': ln['file'], 'at': round(ln['at'], 3), 'start': round(ln['start'], 3),
                       'end': round(ln['start'] + ln['speech'], 3)} for ln in lines],
            'takes': {n: {'size': tk.size, 'count': tk.count, 'scale': tk.scale, 'radius': RADIUS[n]}
                      for n, tk in takes.items()},
            'shots': [{k: v for k, v in s.items() if k not in ('beats', 'aim')} for s in shots], 'swaps': swaps,
            'frames': frames, 'cursor': cursor, 'keys': [round(p, 3) for p in press], 'clicks': clicks,
            'typing': typing_span, 'sped_up': [[round(a, 3), round(b, 3)] for a, b in sped],
            'punches': [[round(t, 3), a] for t, a in punches], 'shakes': [[round(t, 3), a, d] for t, a, d in shakes],
            'flashes': [[round(t, 3), a] for t, a in flashes], 'rings': rings,
            'end_cues': {'free': free_s, 'open': open_s, 'runs': runs_s, 'name': name_s},
            'music': music, 'sfx': sorted([[round(t, 3), n, g, a] for t, n, g, a in sfx]),
            'captions': captions, 'emojis': emojis}
    (HERE / 'edit.json').write_text(json.dumps(edit, separators=(',', ':'), ensure_ascii=False) + '\n')
    print(f"{duration} s, voice {edit['voice_name']}, music {music.get('file')} at {music['at']}, shots " +
          ', '.join(f"{s['id']} {s['from']:.2f}-{s['to']:.2f}" for s in shots) +
          (f"; sped up {edit['sped_up']}" if sped else ''))


if __name__ == '__main__':
    main()
