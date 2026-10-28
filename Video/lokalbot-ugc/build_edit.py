"""Builds edit.json, the cut's timeline, from the voice takes.

Every cue is placed against a spoken word: the meeting citation is clicked as
the voice says "links", the suggestion appears on "already", and the first Tab
lands as "Tab" ends. Footage plays at its recorded speed except in the autocomplete
shot: the typing before the suggestion plays at 1.5x, the wait for it is cut,
and the Tabs play at 1.35x; the picture carries a "sped up" note over it.

  python3 build_edit.py [--voice liam]

Reads production/eleven-generation.json (written by tts_elevenlabs.py) for the
chosen voice's per-character timings. Without it, the timings are estimated
from the text so the picture can be laid out before the voice exists.
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
TYPE_SPEED = 1.5
TAB_SPEED = 1.35
# README hero loop at 43d72b9, frame numbers at 20 fps.
ASK_FIRST, ASK_EXPAND, ASK_LAST = 151, 196, 216
ASK_CLICK = 195
MEET_STILL, MEET_MOVE, MEET_CLICK, MEET_SWITCH, MEET_LAST = 61, 84, 105, 108, 150


def words_from_alignment(text, al, offset):
    """[(word, start, end)] in timeline seconds from ElevenLabs character timings."""
    chars, starts, ends = al['characters'], al['character_start_times_seconds'], al['character_end_times_seconds']
    out, cur, s, e = [], '', None, None
    for ch, a, b in zip(chars, starts, ends):
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


def estimated_alignment(text, rate=15.5):
    chars = list(text)
    starts, ends, t = [], [], 0.12
    for ch in chars:
        d = 1 / rate * (3.2 if ch in '.?!' else 2.0 if ch == ',' else 1.0)
        starts.append(t)
        ends.append(t + d)
        t += d
    return {'characters': chars, 'character_start_times_seconds': starts, 'character_end_times_seconds': ends}, t + 0.15


def audible_end(path, floor_db=-40.0):
    """Seconds to the end of the last 20 ms window louder than floor_db."""
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-ac', '1', '-ar', '16000', '-'],
                         check=True, capture_output=True).stdout
    x = np.frombuffer(raw, dtype='<f4')
    win = 320
    rms = np.sqrt(np.mean(x[:len(x) // win * win].reshape(-1, win) ** 2, axis=1) + 1e-12)
    loud = np.nonzero(20 * np.log10(rms) > floor_db)[0]
    return (loud[-1] + 1) * win / 16000 if len(loud) else len(x) / 16000


def find(words, pattern, after=0.0):
    for w, s, e in words:
        if s >= after and re.fullmatch(pattern, re.sub(r'[^\w$]', '', w), re.I):
            return s, e
    raise SystemExit(f'no word matching {pattern!r}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--voice', default='')
    ap.add_argument('--seed', type=int, default=11)
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
            al, dur, file = r['alignment'], r['duration'], 'assets/voice/' + Path(r['file']).name
        else:
            al, dur = estimated_alignment(text)
            file = None
        # Speech runs from the first character to the last letter: the closing
        # punctuation's timing spans the take's trailing silence.
        speech = [i for i, c in enumerate(al['characters']) if c.isalnum()]
        lead = al['character_start_times_seconds'][speech[0]]
        last = audible_end(HERE / file) if file else al['character_end_times_seconds'][speech[-1]]
        lines.append({'id': sc['id'], 'caption': sc['caption'], 'text': text, 'al': al, 'dur': dur, 'file': file,
                      'lead': lead, 'speech': last - lead})

    # Speech starts: tight, creator-paced gaps; the end line waits for the last Tab.
    gaps = {'02-notes': 0.30, '03-cite': 0.22, '04-tab': 0.30}
    t = 0.25
    for i, ln in enumerate(lines):
        if i:
            prev = lines[i - 1]
            t = prev['start'] + prev['speech'] + gaps.get(ln['id'], 0.3)
        if ln['id'] == '05-end':
            t = max(t, tab_done + 0.45)
        ln['start'] = t                      # first spoken character
        ln['at'] = t - ln['lead']            # where the audio file starts
        ln['words'] = words_from_alignment(ln['text'], ln['al'], ln['at'])
        # The alignment can run the last word past the audio; end it where the
        # voice falls silent and give it at least a quarter second.
        last = ln['words'][-1]
        last[2] = min(last[2], t + ln['speech'])
        last[1] = min(last[1], last[2] - 0.25)
        if ln['id'] == '04-tab':
            _, tab_word_end = find(ln['words'], 'tab')
            first_tab = tab_word_end + 0.06
            tab_done = first_tab + (ACCEPTED - TABS[0]) / TAB_SPEED
    L = {ln['id']: ln for ln in lines}
    end_line = L['05-end']
    duration = round(end_line['start'] + end_line['speech'] + 1.6, 2)

    def cut(id_):
        return round(L[id_]['start'] - 0.08, 3)

    shots = []
    # Hook: Ask shows the decision; the evidence opens as the voice says "Your Mac".
    your_s, _ = find(L['01-hook']['words'], 'your')
    expand_t = your_s - 0.05
    shots.append({'id': 'ask', 'src': 'hero', 'from': 0, 'to': cut('02-notes'), 'fps': HERO_FPS,
                  'map': [[expand_t - (ASK_EXPAND - ASK_FIRST) / HERO_FPS, ASK_FIRST], [expand_t, ASK_EXPAND],
                          [expand_t + (ASK_LAST - ASK_EXPAND) / HERO_FPS, ASK_LAST]],
                  'clamp': [ASK_FIRST, ASK_LAST],
                  'cam': [[0, 760, 300, 1.75], [your_s - 0.75, 790, 330, 1.62], [your_s - 0.05, 945, 420, 1.22],
                          [cut('02-notes'), 960, 470, 1.16]]})
    # Meeting: the summary holds while the voice names it; the pointer reaches the
    # 00:00:14 citation and the transcript opens on "links".
    links_s, _ = find(L['03-cite']['words'], 'links')
    moment_s, _ = find(L['03-cite']['words'], 'exact')
    said_s, _ = find(L['03-cite']['words'], 'said')
    switch_t = links_s - 0.04
    click_t = switch_t - (MEET_SWITCH - MEET_CLICK) / HERO_FPS
    move_t = switch_t - (MEET_SWITCH - MEET_MOVE) / HERO_FPS
    m_start = cut('02-notes')
    recap_s, _ = find(L['02-notes']['words'], 'then')
    decision_s, _ = find(L['02-notes']['words'], 'every')
    shots.append({'id': 'meeting', 'src': 'hero', 'from': m_start, 'to': cut('04-tab'), 'fps': HERO_FPS,
                  'map': [[m_start, MEET_STILL], [move_t, MEET_STILL], [move_t + 0.0001, MEET_MOVE],
                          [switch_t, MEET_SWITCH], [switch_t + (MEET_LAST - MEET_SWITCH) / HERO_FPS, MEET_LAST]],
                  'clamp': [MEET_STILL, MEET_LAST],
                  'cam': [[m_start, 868, 380, 1.46], [recap_s - 0.3, 868, 420, 1.4], [recap_s + 0.35, 962, 600, 1.2],
                          [decision_s - 0.1, 962, 600, 1.2], [decision_s + 0.5, 1078, 590, 0.98],
                          [switch_t, 1078, 590, 0.98], [moment_s - 0.1, 980, 760, 1.34], [said_s, 980, 775, 1.34],
                          [cut('04-tab'), 1205, 790, 1.36]]})
    # Autocomplete: the last of the typing at 1.5x, the wait cut, the suggestion on
    # "already", the first Tab as "Tab" ends, then every Tab at recorded speed.
    a_start = cut('04-tab')
    already_s, _ = find(L['04-tab']['words'], 'already')
    ghost_t = already_s
    type_from = TYPED - (ghost_t - 0.05 - a_start) * TYPE_SPEED
    tab_map = [[a_start, type_from], [ghost_t - 0.05, TYPED], [ghost_t - 0.0499, GHOST - 0.05], [ghost_t, GHOST]]
    hold_until = first_tab - 0.25
    if hold_until > ghost_t + 0.05:
        tab_map += [[hold_until, TABS[0] - 0.25]]
    tab_map += [[first_tab, TABS[0]], [tab_done, ACCEPTED], [tab_done + 1.6, ACCEPTED + 1.6]]
    a_end = cut('05-end')
    shots.append({'id': 'tab', 'src': 'tab', 'from': a_start, 'to': a_end, 'fps': TAB_FPS, 'time_map': tab_map,
                  'clamp': [TYPED - 4.9, ACCEPTED + 1.9],
                  'cam': [[a_start, 790, 230, 1.0], [ghost_t - 0.1, 840, 230, 1.0], [ghost_t + 0.5, 1140, 215, 1.0],
                          [a_end, 1145, 215, 1.01]]})
    shots.append({'id': 'end', 'src': None, 'from': a_end, 'to': duration})

    keys = [round(first_tab + (k - TABS[0]) / TAB_SPEED, 3) for k in TABS]
    clicks = [round(expand_t - (ASK_EXPAND - ASK_CLICK) / HERO_FPS, 3), round(click_t, 3)]
    typing = [round(a_start, 3), round(ghost_t - 0.05, 3)]

    # Captions: short chunks of up to three words (four when that reaches the end of
    # a phrase), broken after punctuation, never leaving one word on its own.
    captions = []
    for ln in lines:
        ws, i = ln['words'], 0
        while i < len(ws):
            j = i
            while j < len(ws):
                j += 1
                text = ' '.join(x[0] for x in ws[i:j])
                if ws[j - 1][0][-1] in ',.?!':
                    break
                if j - i >= 3 or len(text) >= 15:
                    if j < len(ws) and ws[j][0][-1] in ',.?!' and len(text + ws[j][0]) <= 20:
                        j += 1
                    break
            if len(ws) - j == 1 and ws[-1][0][-1] in '.?!' and len(ws[-1][0]) <= 5 and j - i < 4:
                j += 1
            captions.append({'words': [[x[0], round(x[1], 3), round(x[2], 3)] for x in ws[i:j]]})
            i = j
    for i, c in enumerate(captions):
        nxt = captions[i + 1]['words'][0][1] if i + 1 < len(captions) else duration
        # The first caption is up from the first frame, which is the thumbnail on some sites.
        c['from'] = 0 if i == 0 else round(c['words'][0][1] - 0.05, 3)
        c['to'] = round(min(nxt - 0.05, c['words'][-1][2] + 0.6), 3)

    edit = {'fps': FPS, 'size': [1080, 1920], 'duration': duration, 'voice_name': args.voice or 'estimated',
            'voice': [{'id': ln['id'], 'file': ln['file'], 'at': round(ln['at'], 3), 'start': round(ln['start'], 3),
                       'end': round(ln['start'] + ln['speech'], 3)} for ln in lines],
            'shots': shots, 'keys': keys, 'clicks': clicks, 'typing': typing,
            'sped_up': [round(a_start, 3), round(tab_done + 0.2, 3)], 'captions': captions}
    (HERE / 'edit.json').write_text(json.dumps(edit, indent=1) + '\n')
    print(f"{duration} s, voice {edit['voice_name']}, shots " +
          ', '.join(f"{s['id']} {s['from']:.2f}-{s['to']:.2f}" for s in shots))


if __name__ == '__main__':
    main()
