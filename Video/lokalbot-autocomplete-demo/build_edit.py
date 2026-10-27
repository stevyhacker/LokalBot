#!/usr/bin/env python3
"""Turn the filmed takes into the edit: footage frames, time maps and cues.

  python3 build_edit.py <footage-dir> [appearance]

<footage-dir> holds what the "Autocomplete demo" workflow publishes (clips/,
logs/, takes/). For each clip this writes the source frames the edit shows to
footage/<clip>/NNNN.jpg and updates edit.json in place: the map from the
clip's slot time to recording time, and when each key press, the suggestion
and each Tab land in the slot. The explainer gets the memory take's prompt,
the model's candidates at each step and the suggestion as the app showed it,
split where each Tab accepted it.

The edit speeds the recording up but never reorders it: typing plays 2 to 4
times faster, the wait for the suggestion is shortened, and the suggestion
itself plays at close to real time. The real wait is printed so it can be
quoted honestly.
"""
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHOTS = HERE.parent.parent / 'Scripts' / 'autocomplete-demo' / 'shots'
FPS = 30
# The part of each 1760 x 420 take the edit shows: the text lines, without the
# empty page below them or the scroll bar on the right. PAD widens the page on
# the left, where the card's rounded corner would clip the first letters.
CROP = (1720, 330)
PAD = 36


def slots(edit):
    """Each clip's time on screen and, for the quick language cuts, how long its typing plays."""
    T = edit['timeline']
    starts = [T['langs'][0] + s for s in edit['langStarts']] + [T['dive'][0] + 0.3]
    langs = {name: (starts[i + 1] - starts[i], 0.3) for i, name in enumerate(('german', 'french', 'spanish'))}
    return {'memory': (T['memory'][1] - T['memory'][0], None),
            edit['wordClip']: (T['word'][1] - T['word'][0], None), **langs}


def key_times(events, shot):
    """Each typed character's recording time: the rig logs the start of a run and types at its cps."""
    runs = [a for a in shot['actions'] if 'type' in a]
    out = []
    for e in (e for e in events if e['kind'] == 'type'):
        cps = next((a.get('cps', 9) for a in runs if a['type'] == e['text']), 9)
        out += [e['t'] + i / cps for i in range(len(e['text']))]
    return out


def plan(events, shot, length, typing=None, lead=0.12, tail=0.35):
    """Piecewise map [[slot time, recording time], ...] that fits the take into `length` seconds.

    With `typing`, the typing gets that long and the accepts run past the slot:
    a quick cut that shows the end of the sentence, the suggestion and a few Tabs.
    """
    first = next(e['t'] for e in events if e['kind'] == 'type')
    typed = next(e['t'] for e in events if e['kind'] == 'mark' and e.get('name') == 'typed')
    ghost = next(e['t'] for e in events if e['kind'] == 'ghost')
    tabs = [e['t'] for e in events if e['kind'] == 'key' and e.get('key') == 'tab' and e['t'] >= ghost]
    done = next((e['t'] for e in events if e['kind'] == 'accepted'), tabs[-1] if tabs else ghost + 1)
    if not tabs:
        raise SystemExit('take has no accepted suggestion')
    if typing is not None:
        lead = 0.0
    wait_out = min(ghost - typed, 0.12 if typing else 0.22)
    show_out = min(tabs[0] - ghost, 0.25 if typing else 0.5)
    accept_out = (done + 0.2 - tabs[0]) / 1.5
    typing_out = typing or length - lead - tail - wait_out - show_out - accept_out
    if typing is None and typing_out < 0.6:
        raise SystemExit(f'slot of {length:.2f}s is too short for this take')
    start = first - 0.1
    speed = (typed - start) / typing_out
    if speed > 3.6:
        speed = 3.6
        start = typed - speed * typing_out  # Open mid-sentence rather than type faster.
    elif speed < 2.0:
        speed = 2.0
        lead += typing_out - (typed - start) / speed
        typing_out = (typed - start) / speed
    o = lead
    points = [[0.0, start], [o, start]]
    for dur, src in ((typing_out, typed), (wait_out, ghost), (show_out, tabs[0]), (accept_out, done + 0.2)):
        o += dur
        points.append([round(o, 4), round(src, 4)])
    stats = {'typing speed': round(speed, 2), 'real wait': round(ghost - typed, 3),
             'shown wait': round(wait_out, 3), 'accepts': len(tabs)}
    return points, ghost, tabs, stats


def to_slot(points, src):
    """Slot time at which recording time `src` plays."""
    for (o0, s0), (o1, s1) in zip(points, points[1:]):
        if s0 <= src <= s1 and s1 > s0:
            return o0 + (src - s0) / (s1 - s0) * (o1 - o0)
    return None


def source_time(points, t):
    if t <= points[0][0]:
        return points[0][1]
    for (o0, s0), (o1, s1) in zip(points, points[1:]):
        if t <= o1:
            return s1 if o1 == o0 else s0 + (s1 - s0) * (t - o0) / (o1 - o0)
    return points[-1][1]


def probe_size(mp4):
    out = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_packets',
                          '-show_entries', 'stream=width,height,nb_read_packets', '-of', 'json', str(mp4)],
                         check=True, capture_output=True, text=True).stdout
    s = json.loads(out)['streams'][0]
    return int(s['width']), int(s['height']), int(s['nb_read_packets'])


def extract(mp4, dest, needed, background):
    """Write only the frames the edit shows, named by their 1-based index in the clip."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    lo, hi = min(needed), max(needed)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(mp4),
                        '-vf', f'crop={CROP[0]}:{CROP[1]}:0:0,pad=iw+{PAD}:ih:{PAD}:0:color={background},'
                        f'select=between(n\\,{lo}\\,{hi})',
                        '-vsync', '0', '-q:v', '2', '-start_number', str(lo + 1), f'{tmp}/%04d.jpg'], check=True)
        for n in needed:
            shutil.move(f'{tmp}/{n + 1:04d}.jpg', dest / f'{n + 1:04d}.jpg')


def steps(probabilities):
    """[(chosen token, [(token, p), ...]), ...] from llama-server's completion_probabilities."""
    out = []
    for step in probabilities or []:
        if 'top_logprobs' in step:
            options = [(o['token'], math.exp(o['logprob'])) for o in step['top_logprobs']]
            out.append((step['token'], options))
        else:  # Older servers report probabilities directly.
            out.append((step['content'], [(o['tok_str'], o['prob']) for o in step['probs']]))
    return out


def swift_string(literal):
    """The value of a Swift string literal as `String(reflecting:)` writes it."""
    escapes = {'0': '\0', 't': '\t', 'n': '\n', 'r': '\r'}
    return re.sub(r'\\(u\{([0-9a-fA-F]+)\}|.)',
                  lambda m: chr(int(m.group(2), 16)) if m.group(2) else escapes.get(m.group(1), m.group(1)),
                  literal[1:-1])


def suggestions(states_log):
    """(prefix, suggestion) for each suggestion the app showed, from the filming log."""
    shown, prefix = [], None
    for line in Path(states_log).read_text(errors='replace').splitlines():
        if 'film: request ' in line:
            prefix = json.loads(line.split('film: request ', 1)[1])['prefix']
        elif m := re.search(r'film: cotyping ready\(text: (".*")\)$', line):
            shown.append((prefix, swift_string(m.group(1))))
    return shown


def chunks(shown, prefix, ghost):
    """The suggestion for `prefix` split where each Tab accepted it: each accept leaves a suffix."""
    texts = [text for p, text in shown if p == prefix]
    run = texts[texts.index(ghost):]
    out = []
    for text, rest in zip(run, run[1:] + ['']):
        if rest and not text.endswith(rest) or rest == text:
            rest = ''
        out.append(text[:len(text) - len(rest)])
        if not rest:
            break
    return out


def explainer(edit, logs):
    """The prompt, candidates and accepted chunks of the memory take, as the app and model had them."""
    memory = json.loads((logs / 'probabilities.json').read_text())['memory']
    facts = re.search(r'Relevant saved facts: (.*?)\n\n', memory['prompt'], re.S)
    edit['prompt'][0]['text'] = facts.group(1)
    edit['prompt'][1]['text'] = re.sub(r'\n+', '\n', memory['prefix'])
    edit['candidates'] = [{'chosen': token, 'options': [[o, round(p, 3)] for o, p in options[:5]]}
                          for token, options in steps(memory['probabilities'])]
    edit.pop('placeholderCandidates', None)
    shown = suggestions(logs / 'autocomplete-states.log')
    ghost = next(text for prefix, text in shown if prefix == memory['prefix'])
    if ghost != memory['content']:
        print(f'note: the app showed {ghost!r}, the replayed prompt gave {memory["content"]!r}')
    parts = chunks(shown, memory['prefix'], ghost)
    beat = 60 / edit['bpm']
    edit['ghostScene'].update({'ghost': ghost, 'chunks': parts,
                               'presses': [round(2 * beat + i * beat / 2, 3) for i in range(len(parts))]})
    print(f'explainer: {len(edit["candidates"])} steps, accepted as {parts}')


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    root = Path(sys.argv[1])
    appearance = sys.argv[2] if len(sys.argv) > 2 else 'light'
    edit = json.loads((HERE / 'edit.json').read_text())
    for name, (length, typing) in slots(edit).items():
        mp4 = root / 'clips' / f'{appearance}-{name}.mp4'
        meta = json.loads(mp4.with_suffix('.json').read_text())
        shot = json.loads((SHOTS / f'{name}.json').read_text())
        points, ghost, tabs, stats = plan(meta['events'], shot, length, typing)
        width, height, frames = probe_size(mp4)
        width, height = min(width, CROP[0]) + PAD, min(height, CROP[1])
        # Every frame in the span the map plays: a squeezed wait can land on any of them.
        span = [min(max(round(p[1] * FPS), 0), frames - 1) for p in points]
        needed = list(range(min(span), max(span) + 1))
        extract(mp4, HERE / 'footage' / f'{appearance}-{name}', needed, meta.get('background') or '#FFFFFF')
        keys = [to_slot(points, k) for k in key_times(meta['events'], shot)]
        keys = [k for k in keys if k is not None]
        thinned = []
        for k in keys:  # A sped-up burst would buzz; keep clicks at least 45 ms apart.
            if not thinned or k - thinned[-1] >= 0.045:
                thinned.append(round(k, 3))
        clip = edit['clips'][name]
        clip.update({
            'src': f'footage/{appearance}-{name}', 'frames': frames, 'size': [width, height], 'map': points,
            'ghostAt': round(to_slot(points, ghost), 3), 'accepts': [round(to_slot(points, t), 3) for t in tabs],
            'keys': thinned, 'background': meta.get('background'),
        })
        print(f'{name}: {len(needed)} frames, {stats}')
    explainer(edit, root / 'logs')
    (HERE / 'edit.json').write_text(json.dumps(edit, indent=1, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
