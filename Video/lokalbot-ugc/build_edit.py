"""Builds edit.json, the over-the-top cut's timeline, from the voice takes.

Every cue sits on a spoken word: the beat drops on "Stop", the evidence opens
on "remembers", "boom" hits the recap, the transcript opens on "jumps", a red
circle and a bass hit land on "exact", the suggestion appears on "already",
and two Tabs land on each spoken "tab". Footage plays at its recorded speed
except in the autocomplete shot (typing at 2x, the wait cut, the Tabs as
fast as they are said), which carries a "sped up" sticker.

  python3 build_edit.py [--voice liam-ott] [--music hype-a]

Reads production/eleven-generation.json (tts_elevenlabs.py) for the voice's
per-character timings; without it the timings are estimated from the text,
so the picture can be laid out before the voice exists. The music's drop and
beat grid are measured from the file (assets/sound/eleven/<music>.mp3, from
eleven_sound.py), with the tempo from sound.json.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
FPS = 30
HERO_FPS = 20
TAB_FPS = 30

# Live autocomplete take light-memory (pr-assets/392-autocomplete-demo), from
# its event log: "$15" typed, the suggestion appearing, each Tab, all accepted.
EVENTS = json.loads((HERE / 'footage/tab/events.json').read_text())['events']
TYPED = next(e['t'] for e in EVENTS if e.get('name') == 'typed') + 0.05
GHOST = next(e['t'] for e in EVENTS if e['kind'] == 'ghost')
TABS = [e['t'] for e in EVENTS if e.get('key') == 'tab']
ACCEPTED = next(e['t'] for e in EVENTS if e['kind'] == 'accepted')
TYPE_SPEED = 2.0
# README hero loop at 43d72b9, frame numbers at 20 fps.
ASK_FIRST, ASK_EXPAND, ASK_LAST = 151, 196, 216
ASK_CLICK = 195
MEET_STILL, MEET_MOVE, MEET_CLICK, MEET_SWITCH, MEET_LAST = 61, 84, 105, 108, 150

# Red circles, in footage pixels: [cx, cy, rx, ry].
RING_PRICE = [680, 370, 205, 52]         # Ask: "$15 per seat, billed annually"
RING_DECISION = [744, 932, 196, 46]      # Summary: the first decision
RING_STAMP = [1566, 932, 82, 38]         # Summary: its 00:00:14 citation
RING_MOMENT = [626, 773, 86, 40]         # Transcript: the 00:00:14 row
RING_GHOST = [1352, 165, 268, 56]        # TextEdit: the suggestion


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
            tab_done = press[-1] + (ACCEPTED - TABS[-1]) * 0.6
    L = {ln['id']: ln for ln in lines}
    W = {k: ln['words'] for k, ln in L.items()}
    end_line = L['05-end']
    duration = round(end_line['start'] + end_line['speech'] + 1.5, 2)

    def cut(id_):
        return round(L[id_]['start'] - 0.06, 3)

    punches, shakes, flashes, sfx, rings = [], [], [], [], []

    # Hook: Ask, tight on the question; the beat drops on "Stop"; the evidence
    # opens and the answer is circled on "remembers".
    stop_s, _ = find(W['01-hook'], 'stop')
    rem_s, _ = find(W['01-hook'], 'remembers')
    expand_t = rem_s - 0.05
    c02 = cut('02-notes')
    shots = [{'id': 'ask', 'src': 'hero', 'from': 0, 'to': c02,
              'map': [[expand_t - (ASK_EXPAND - ASK_FIRST) / HERO_FPS, ASK_FIRST], [expand_t, ASK_EXPAND],
                      [expand_t + (ASK_LAST - ASK_EXPAND) / HERO_FPS, ASK_LAST]],
              'clamp': [ASK_FIRST, ASK_LAST],
              'cam': [[0, 742, 262, 1.85], [rem_s - 0.2, 760, 300, 1.7], [rem_s + 0.12, 930, 470, 1.18],
                      [c02, 945, 500, 1.12]]}]
    punches += [[stop_s, 0.12], [rem_s, 0.07]]
    shakes += [[stop_s, 16, 0.4]]
    sfx += [[stop_s, 'bassdrop', -3, 'peak'], [stop_s - 0.02, 'impact', -6, 'peak']]
    rings.append({'shot': 'ask', 'from': rem_s + 0.08, 'to': c02, 'ring': RING_PRICE})
    clicks = [round(expand_t - (ASK_EXPAND - ASK_CLICK) / HERO_FPS, 3)]

    # Meeting: the title on "records", "boom" punches into the recap, the
    # decisions on "decision"; the pointer reaches the citation on "click" and
    # the transcript opens on "jumps", where "exact" circles the moment.
    rec_s, _ = find(W['02-notes'], 'records')
    nobot_s, _ = find(W['02-notes'], 'no')
    boom_s, _ = find(W['02-notes'], 'boom')
    recap_s, _ = find(W['02-notes'], 'recap')
    dec_s, _ = find(W['02-notes'], 'decision')
    click_s, _ = find(W['03-cite'], 'click')
    jumps_s, _ = find(W['03-cite'], 'jumps')
    exact_s, _ = find(W['03-cite'], 'exact')
    switch_t = jumps_s - 0.04
    click_t = switch_t - (MEET_SWITCH - MEET_CLICK) / HERO_FPS
    move_t = switch_t - (MEET_SWITCH - MEET_MOVE) / HERO_FPS
    c04 = cut('04-tab')
    shots.append({'id': 'meeting', 'src': 'hero', 'from': c02, 'to': c04,
                  'map': [[c02, MEET_STILL], [move_t, MEET_STILL], [move_t + 0.0001, MEET_MOVE],
                          [switch_t, MEET_SWITCH], [switch_t + (MEET_LAST - MEET_SWITCH) / HERO_FPS, MEET_LAST]],
                  'clamp': [MEET_STILL, MEET_LAST],
                  'cam': [[c02, 820, 200, 1.62], [rec_s + 0.3, 862, 215, 1.5], [nobot_s - 0.1, 1000, 290, 1.3],
                          [boom_s - 0.05, 1010, 330, 1.22], [boom_s + 0.12, 1000, 520, 1.3],
                          [dec_s - 0.15, 1000, 560, 1.22], [dec_s + 0.2, 1098, 915, 0.98],
                          [click_s, 1110, 915, 0.98], [click_s + 0.35, 1190, 910, 1.08], [switch_t - 0.02, 1190, 900, 1.08],
                          [switch_t + 0.12, 1060, 770, 1.04], [exact_s, 1060, 780, 1.02],
                          [c04, 1090, 790, 1.0]]})
    punches += [[boom_s, 0.14], [exact_s, 0.1], [switch_t, 0.06]]
    shakes += [[boom_s, 20, 0.45], [exact_s, 12, 0.35]]
    flashes += [[boom_s, 0.55]]
    sfx += [[boom_s, 'impact', -2, 'peak'], [switch_t, 'glitch', -9, 'start'], [exact_s, 'bassdrop', -3, 'peak']]
    rings += [{'shot': 'meeting', 'from': dec_s + 0.12, 'to': switch_t, 'ring': RING_DECISION},
              {'shot': 'meeting', 'from': click_s + 0.05, 'to': switch_t, 'ring': RING_STAMP},
              {'shot': 'meeting', 'from': exact_s + 0.02, 'to': c04, 'ring': RING_MOMENT}]
    clicks.append(round(click_t, 3))

    # Autocomplete: typing at 2x into "already", where the suggestion shows and is
    # circled; then two Tabs per spoken "tab", every word accepted.
    a_start = c04
    already_s, _ = find(W['04-tab'], 'already')
    ghost_t = already_s
    type_from = TYPED - (ghost_t - 0.05 - a_start) * TYPE_SPEED
    tab_map = [[a_start, type_from], [ghost_t - 0.05, TYPED], [ghost_t - 0.0499, GHOST - 0.05], [ghost_t, GHOST]]
    if press[0] - 0.2 > ghost_t + 0.05:
        tab_map.append([press[0] - 0.2, TABS[0] - 0.2])
    tab_map += [[p, k] for p, k in zip(press, TABS)] + [[tab_done, ACCEPTED], [tab_done + 2, ACCEPTED + 2]]
    a_end = cut('05-end')
    shots.append({'id': 'tab', 'src': 'tab', 'from': a_start, 'to': a_end, 'time_map': tab_map,
                  'clamp': [TYPED - 4.9, ACCEPTED + 1.9],
                  'cam': [[a_start, 640, 170, 1.95], [ghost_t - 0.08, 840, 170, 1.95],
                          [ghost_t + 0.3, 1322, 168, 1.72], [a_end, 1330, 168, 1.76]]})
    punches += [[ghost_t, 0.1]] + [[p, 0.045] for p in press]
    shakes += [[ghost_t, 10, 0.3]] + [[p, 7, 0.16] for p in press]
    rings.append({'shot': 'tab', 'from': ghost_t + 0.06, 'to': a_end, 'ring': RING_GHOST})
    sfx += [[ghost_t, 'glitch', -7, 'start'], [ghost_t + 0.02, 'pop', -6, 'start']]
    sfx += [[p, 'tab', -4, 'start'] for p in press]
    typing = [round(a_start, 3), round(ghost_t - 0.05, 3)]

    # End card: slams in on the cut; a chip on each fact; the name on "LokalBot".
    shots.append({'id': 'end', 'src': None, 'from': a_end, 'to': duration})
    free_s, _ = find(W['05-end'], 'free')
    open_s, _ = find(W['05-end'], 'open')
    runs_s, _ = find(W['05-end'], 'ai')
    name_s, _ = find(W['05-end'], 'lokalbot')
    punches += [[a_end, 0.0]]
    shakes += [[a_end, 22, 0.5], [free_s, 8, 0.2], [open_s, 8, 0.2], [runs_s, 8, 0.2], [name_s, 16, 0.4]]
    flashes += [[a_end, 0.75], [name_s, 0.35]]
    sfx += [[a_end - 1.45, 'riser', -8, 'start'], [a_end, 'slam', -2, 'peak'],
            [free_s, 'pop', -7, 'start'], [open_s, 'pop', -7, 'start'], [runs_s, 'pop', -7, 'start'],
            [name_s, 'impact', -3, 'peak']]

    # Whips between shots, each with a whoosh.
    whips = [c02, c04]
    sfx += [[w - 0.1, 'whoosh', -3, 'peak'] for w in whips]
    sfx += [[c, 'click', -8, 'start'] for c in clicks]

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

    edit = {'fps': FPS, 'size': [1080, 1920], 'duration': duration, 'voice_name': args.voice or 'estimated',
            'voice': [{'id': ln['id'], 'file': ln['file'], 'at': round(ln['at'], 3), 'start': round(ln['start'], 3),
                       'end': round(ln['start'] + ln['speech'], 3)} for ln in lines],
            'shots': shots, 'whips': whips, 'keys': [round(p, 3) for p in press], 'clicks': clicks,
            'typing': typing, 'sped_up': [round(a_start, 3), round(tab_done + 0.2, 3)],
            'punches': [[round(t, 3), a] for t, a in punches], 'shakes': [[round(t, 3), a, d] for t, a, d in shakes],
            'flashes': [[round(t, 3), a] for t, a in flashes], 'rings': rings,
            'end_cues': {'free': free_s, 'open': open_s, 'runs': runs_s, 'name': name_s},
            'music': music, 'sfx': sorted([[round(t, 3), n, g, a] for t, n, g, a in sfx]),
            'captions': captions, 'emojis': emojis}
    (HERE / 'edit.json').write_text(json.dumps(edit, indent=1, ensure_ascii=False) + '\n')
    print(f"{duration} s, voice {edit['voice_name']}, music {music.get('file')} at {music['at']}, shots " +
          ', '.join(f"{s['id']} {s['from']:.2f}-{s['to']:.2f}" for s in shots))


if __name__ == '__main__':
    main()
