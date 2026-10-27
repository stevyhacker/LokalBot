#!/usr/bin/env python3
"""Time the edit to the voiceover.

  python3 timeline.py

Reads narration.json and, once the voice exists, the takes tts.py made and
their word timings from word_timings.py. narration.json's "take" picks the
engine, voice and take (a scene can override it). Each section of the film
lasts as long as its line needs plus room to breathe, and edit.json gets the
section times, where each line plays, word-timed captions, the hook's typing,
the explainer's beats and the camera path. Without the voice, line lengths
are estimated from their words, so the layout can be previewed before the
voice is made.

Run build_edit.py afterwards: the footage maps depend on the slot lengths.
"""
import difflib
import json
import math
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
OVERLAP = 0.3     # cross-fade between sections
WORDS_PER_SECOND = 3.0
CAPTION_CHARS = 44
NO_CAPTIONS = {'hook', 'dive', 'end'}  # the screen already says the line
TAIL = 1.1        # after the music's final hit, before the film ends
X_WORD, X_LANG, CX = 24, 48, 48  # where comp.js puts the second clip, the languages and the explainer

# Per section: (where the line starts after the section does, the least the
# section lasts, room after the line). The voice starts on the first frame and
# the lines follow each other closely; the footage and the model's picks get
# the room they need to be read.
SECTIONS = {
    'hook': (0.12, 3.0, 1.1),
    'memory': (0.3, 5.6, 0.8),
    'word': (0.2, 3.0, 0.4),
    'langs': (0.1, 4.5, 0.5),
    'dive': (0.2, 1.8, 0.4),
    'context': (0.35, 4.6, 0.8),
    'model': (0.35, 4.6, 0.6),
    'pick': (0.35, 5.0, 1.0),
    'ghost': (0.3, 4.6, 0.8),
    'end': (0.35, 3.8, 1.2),
}


def estimated(text):
    """Word timings for a line nobody has recorded yet."""
    words = text.split()
    per = len(words) / WORDS_PER_SECOND
    step = per / len(words)
    return [(w, i * step, (i + 0.85) * step) for i, w in enumerate(words)]


def norm(word):
    return re.sub(r'[^a-z0-9]', '', word.lower().replace('lokalbot', 'localbot'))


def aligned(caption, heard):
    """The caption's words with the times the recognizer heard them at.

    The recognizer spells some words its own way ("Gemma 4", "LocalBot"), so
    the two are matched as sequences, and a caption word it heard differently
    gets times shared out from its neighbours'.
    """
    words = caption.split()
    a, b = [norm(w) for w in words], [norm(w[0]) for w in heard]
    times, match = [None] * len(words), {}
    for block in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
        for k in range(block.size):
            times[block.a + k] = heard[block.b + k][1:]
            match[block.a + k] = block.b + k
    known = [i for i, t in enumerate(times) if t]
    if not known:
        raise SystemExit(f'no words of {caption!r} in the take')
    for i, t in enumerate(times):
        if t:
            continue
        before = max((k for k in known if k < i), default=None)
        after = min((k for k in known if k > i), default=None)
        # The words heard between the two matched neighbours are this run's.
        lo = match[before] + 1 if before is not None else 0
        hi = match[after] - 1 if after is not None else len(heard) - 1
        if lo <= hi:
            t0, t1 = heard[lo][1], heard[hi][2]
        else:
            t0 = times[before][1] if before is not None else heard[0][1]
            t1 = times[after][0] if after is not None else heard[-1][2]
        run = [k for k in range(len(words)) if (before is None or k > before) and (after is None or k < after)]
        share = (t1 - t0) / len(run)
        j = run.index(i)
        times[i] = (t0 + j * share, t0 + (j + 1) * share)
    return [(w, *t) for w, t in zip(words, times)]


def from_alignment(alignment):
    """[[word, start, end], ...] from ElevenLabs' character alignment."""
    chars = alignment['characters']
    starts, ends = alignment['character_start_times_seconds'], alignment['character_end_times_seconds']
    words, current, t0, t1 = [], '', None, None
    for c, a, b in zip(chars, starts, ends):
        if c.isspace():
            if current:
                words.append([current, t0, t1])
            current, t0 = '', None
            continue
        if t0 is None:
            t0 = a
        current += c
        t1 = b
    if current:
        words.append([current, t0, t1])
    return words


def takes():
    """(scene, take settings, the take's row or None, its words as heard) for each line of narration.json."""
    spec = json.loads((HERE / 'narration.json').read_text())
    timings_path = HERE / 'production' / 'word-timings.json'
    timings = json.loads(timings_path.read_text()) if timings_path.exists() else {}
    for scene in spec['scenes']:
        pick = {**spec['take'], **scene.get('take', {})}
        report_path = HERE / 'production' / f"{pick['engine']}-generation.json"
        rows = json.loads(report_path.read_text())['rows'] if report_path.exists() else []
        if pick['engine'] == 'eleven':  # tts_elevenlabs.py: takes by seed, timed by ElevenLabs itself
            row = next((r for r in rows if r['id'] == scene['id'] and r['seed'] == pick['seed']
                        and r.get('voice_name') == pick.get('voice')), None)
            heard = from_alignment(row['alignment']) if row and row.get('alignment') else None
        else:
            row = next((r for r in rows if r['id'] == scene['id'] and r['voice'] == pick['voice'] and r['take'] == pick['take']), None)
            heard = timings.get(row['file']) if row else None
        yield scene, pick, row, heard


def lines():
    """Each scene's words with times from the start of its speech, the take used and its offset."""
    tight_path = HERE / 'production' / 'tight.json'
    tight = json.loads(tight_path.read_text()) if tight_path.exists() else {}
    out = []
    for scene, pick, row, heard in takes():
        file = row['file'] if row else None
        # tighten.py's version of the take, when the take asks for one: shorter pauses, a quicker read.
        if row and pick.get('tighten') and row['file'] in tight and (HERE / tight[row['file']]['file']).exists():
            file, heard = tight[row['file']]['file'], tight[row['file']]['words']
        if heard and (HERE / file).exists():
            words = aligned(scene['caption'], heard)
            lead = max(words[0][1] - 0.04, 0)  # silence before the first word, less a breath
            words = [(w, s - lead, e - lead) for w, s, e in words]
            out.append({**scene, 'file': file, 'trim': round(lead, 3), 'words': words})
        else:
            out.append({**scene, 'file': None, 'trim': 0, 'words': estimated(scene['caption'])})
    return out


def captions(words, start):
    """Caption chunks of at most CAPTION_CHARS, each up until the next one starts."""
    chunks, current = [], []
    for w in words:
        text = ' '.join(x[0] for x in current + [w])
        if current and re.search(r'[.?!]$', current[-1][0]):
            chunks.append(current)
            current = []
        elif current and len(text) > CAPTION_CHARS:
            # Break after the last comma when there is one, else before this word.
            commas = [i for i, x in enumerate(current[:-1]) if x[0].endswith(',') and i >= 1]
            cut = commas[-1] + 1 if commas else len(current)
            chunks.append(current[:cut])
            current = current[cut:]
        current.append(w)
    if current:
        chunks.append(current)
    out = []
    for i, chunk in enumerate(chunks):
        t0 = start + chunk[0][1]
        t1 = start + chunk[-1][2] + 0.35
        if i + 1 < len(chunks):
            t1 = min(t1 + 0.4, start + chunks[i + 1][0][1])
        out.append([round(t0, 3), round(t1, 3), ' '.join(w[0] for w in chunk),
                    [round(start + w[1], 3) for w in chunk]])
    return out


def grid():
    """The music's beat in film time, from sound.json's "music_edit": (first beat, beat length, final hit), or None.

    The first beat is where the bed comes in; before it, under the hook, plays
    the synthesized intro, so the hook cuts to the first clip right there.
    """
    edit = json.loads((HERE / 'sound.json').read_text())['mix'].get('music_edit')
    if not edit:
        return None
    beat = 60 / edit['bpm']
    before = sum(b - a for a, b in edit['bars'][:-1])
    hit = edit['at'] + (before + edit['button'] - edit['bars'][-1][0]) * 4 * beat
    return edit['at'], beat, hit


def on_beat(t, g, step=1.0, up=False):
    """t moved to the nearest beat (or the next one, with up); step 0.5 for eighth notes."""
    first, beat, _ = g
    k = (t - first) / (beat * step)
    return first + (math.ceil(k - 1e-6) if up else round(k)) * beat * step


def word_time(words, start, pattern, edge=1):
    """Film time of the first word matching `pattern`: its start (edge 1) or end (edge 2)."""
    for w in words:
        if re.match(pattern, w[0], re.I):
            return start + w[edge]
    raise SystemExit(f'no word {pattern!r} in the line')


def main():
    edit = json.loads((HERE / 'edit.json').read_text())
    T, voice, caps, subs = {}, [], [], []
    t = 0.0
    spoken = {line['section']: line for line in lines()}
    g = grid()
    for name, (lead, least, room) in SECTIONS.items():
        line = spoken[name]
        need = lead + line['words'][-1][2]
        length = max(least, need + room)
        if g and name == 'end':
            # The film ends as the music's last chord rings out.
            length = max(need + 0.3, g[2] + TAIL - t)
        elif g and t == 0 and g[0] > 1:
            # The music drops on the first cut.
            if g[0] - t < need:
                raise SystemExit(f'the {name} line ({need:.2f} s) runs past the drop at {g[0]:.2f} s')
            length = g[0] + OVERLAP
        elif g:
            # Each cut lands on a beat of the music.
            cut = on_beat(t + length - OVERLAP, g)
            if cut + OVERLAP - t < need + room * 0.5:
                cut = on_beat(t + length - OVERLAP, g, up=True)
            length = cut + OVERLAP - t
        T[name] = [round(t, 3), round(t + length, 3)]
        start = t + lead
        voice.append({'id': line['id'], 'file': line['file'], 'trim': line['trim'], 'at': round(start, 3),
                      'end': round(start + line['words'][-1][2], 3)})
        subs += [c[:3] for c in captions(line['words'], start)]
        if name not in NO_CAPTIONS:
            caps += captions(line['words'], start)
        line['start'] = start
        t += length - OVERLAP
    duration = round(T['end'][1], 2)
    edit.update({'duration': duration, 'timeline': T, 'voice': voice, 'captions': caps, 'subtitles': subs})

    # The hook types its headline from the first moments, as the first cut did;
    # the suggestion shows, and Tab takes each word as the voice says it.
    hook = spoken['hook']
    edit['hook'].update({
        'logoAt': round(word_time(hook['words'], hook['start'], 'Lokal') - 0.25, 3),
        'typeFrom': 0.25, 'typeTo': 1.0, 'ghostAt': 1.12,
        'presses': [round(word_time(hook['words'], hook['start'], w) - 0.03, 3) for w in ('your', 'whole', 'Mac')],
    })
    # Tab presses on the music's eighth notes when there is a beat to follow.
    eighth = (lambda t: on_beat(t, g, 0.5, up=True)) if g else (lambda t: t)

    # Languages share their section evenly, each coming in on a beat.
    l0, l1 = T['langs']
    L = l1 - l0
    beat = (lambda t: on_beat(t, g)) if g else (lambda t: t)
    edit['langStarts'] = [0.15] + [round(beat(l0 + k * L / 3) - l0, 3) for k in (1, 2)]

    # The explainer's beats land on the words that name them.
    def at(section, pattern, edge=1, offset=0.0):
        return round(word_time(spoken[section]['words'], spoken[section]['start'], pattern, edge) + offset, 3)
    stream = eighth(at('model', 'runs'))
    edit['beats'] = {
        'ctxText': at('context', 'text', offset=-0.2), 'ctxNotes': at('context', 'saved', offset=-0.2),
        'ctxMark': at('context', 'pricing', offset=-0.1),
        'modelStream': [round(stream + i * (g[1] / 2 if g else 0.22), 3) for i in range(len(edit['ghostScene']['chunks']))],
        'modelPills': [at('model', 'inside', offset=-0.1), at('model', 'No', offset=-0.1)],
        'pickGate': at('pick', 'When', offset=-0.1),
    }

    # The model's picks, one a beat, from when the voice says it weighs them.
    P0, P1 = T['pick']
    n = len(edit['candidates'])
    first = beat(at('pick', 'weighs')) - P0
    step = g[1] if g else min((P1 - P0 - 1.2 - first) / max(n - 1, 1), 0.7)
    edit['pickSteps'] = [round(first + i * step, 3) for i in range(n)]

    # Ghost text shows when the voice says so; Tab takes a word every eighth note.
    ghost = spoken['ghost']
    g0 = T['ghost'][0]
    edit['ghostScene']['ghostAt'] = round(word_time(ghost['words'], ghost['start'], 'gray') - 0.15 - g0, 3)
    tab = eighth(word_time(ghost['words'], ghost['start'], 'Tab') + 0.15) - g0
    edit['ghostScene']['presses'] = [round(tab + i * (g[1] / 2 if g else 0.3), 3) for i in range(len(edit['ghostScene']['chunks']))]

    edit['camera'] = camera(T)
    (HERE / 'edit.json').write_text(json.dumps(edit, indent=1, ensure_ascii=False) + '\n')
    for name, (a, b) in T.items():
        print(f'{name:8s} {a:6.2f} – {b:6.2f}  ({b - a:4.2f} s)')
    print(f'duration {duration} s; voice {"recorded" if all(v["file"] for v in voice) else "estimated"}'
          + (f'; music on the beat, final hit at {g[2]:.2f} s' if g else ''))


def camera(T):
    """Keys [time, position, look-at, fov, ease] for each section: quick moves, then a slow push in."""
    s = {k: v[0] for k, v in T.items()}
    e = {k: v[1] for k, v in T.items()}
    keys = [
        (0.0, [0, 0, 40], [0, 0, 0], 38, 'linear'),
        (s['memory'] - 0.05, [0, 0, 37], [0, 0, 0], 38, 'linear'),
        (s['memory'] + 0.9, [0.8, 0.3, 19], [0, -0.6, 0], 38, 'inOutCubic'),
        (e['memory'] - 0.5, [1.6, 0.2, 16.6], [0.6, -0.8, 0], 37, 'linear'),
        (s['word'] + 0.7, [X_WORD, 1.5, 13], [X_WORD, 1.5, -6], 38, 'inOutCubic'),
        (e['word'] - 0.5, [X_WORD + 0.4, 1.6, 11.4], [X_WORD, 1.4, -6], 37, 'linear'),
        (s['langs'] + 0.7, [X_LANG, 0, 10.6], [X_LANG, 0, -8], 38, 'inOutCubic'),
        (e['langs'] - 0.3, [X_LANG, 0, 9.4], [X_LANG, 0, -8], 38, 'linear'),
        (s['context'] + 0.4, [CX, 0, -34], [CX, 0.5, -62], 38, 'inOutCubic'),
        (e['context'] - 0.45, [CX - 0.4, 0.3, -36.5], [CX, 0.5, -62], 38, 'linear'),
        (s['model'] + 0.7, [CX, 0, -110], [CX, 0, -160], 38, 'inOutCubic'),
        (e['model'] - 0.3, [CX, 0, -150], [CX, 0, -200], 38, 'linear'),
        (s['pick'] + 0.7, [CX, 0, -193.5], [CX, 0, -205], 38, 'inOutCubic'),
        (e['pick'] - 0.3, [CX, 0, -194.5], [CX, 0, -205], 38, 'linear'),
        (s['ghost'] + 0.6, [CX, 0, -200], [CX, 0, -215], 38, 'inOutCubic'),
        (e['ghost'] - 0.2, [CX, 0, -203.5], [CX, 0, -215], 38, 'linear'),
        (s['end'] + 0.7, [CX, 2, -232], [CX, 3, -250], 38, 'inOutCubic'),
        (e['end'], [CX, 2, -230], [CX, 3, -250], 38, 'linear'),
    ]
    return [[round(t, 3), p, look, fov, ease] for t, p, look, fov, ease in keys]


if __name__ == '__main__':
    main()
