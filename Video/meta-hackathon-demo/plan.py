"""Write edit.json: the film's beats laid out on the output timeline.

Each beat names a stretch of the CI film by the take's anchor times
(production/anchors.json), the camera for it, and the voice line it carries.
A beat lasts as long as its line needs; its footage plays at whatever rate
fits that, so a new take only needs new anchors. Slowed footage is UI waiting
for the next event; sped-up footage carries a speed badge.
"""
import json
import subprocess
from pathlib import Path

P = Path(__file__).resolve().parent
A = json.loads((P / 'production/anchors.json').read_text())
TAKES = {'n08': 'assets/voice/n08-s47.mp3'}
# Live replies land at different moments: the commitment's close-up holds until it has landed, and the
# call picks up from there, whichever comes first.
A['commit_end'] = A['commit'] + 1.4
A['c04_from'] = max(A['c04'], A['commit_end'])
A['contra_from'] = max(A['contradiction'], A['c08']) + 2.2
# The press lands just after the narration says it, and the approved email just as it says "approve".
PRESS_AT, PRESS_RATE = 3.4, 0.42
APPROVE_AT, APPROVE_LEN = 2.1, 3.9
APPROVE_RATE = 0.286
A['press_from'] = A['press_flip'] - PRESS_AT * PRESS_RATE
A['approve_from'] = A['email_flip'] - APPROVE_AT * APPROVE_RATE
A['approve_to'] = A['approve_from'] + APPROVE_LEN * APPROVE_RATE


def voice_len(line_id):
    path = P / TAKES.get(line_id, f'assets/voice/{line_id}-s11.mp3')
    return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(path)],
                                check=True, capture_output=True, text=True).stdout)


# Cameras: [box x, y, w, h on the 1920x1080 canvas], [film x, y, w]; the film rect's height follows the box.
CALL = [[500, 60, 1370, 829], [0, 62, 3200]]
PANEL = [[1279, 44, 581, 890], [2440, 88, 736]]
CARD = [[1100, 110, 760, 780], [2440, 88, 736]]
SETTINGS = [[500, 60, 1370, 829], [1290, 470, 1460]]
BOARD = [[500, 60, 1370, 829], [100, 450, 2420]]
FT = [[1170, 44, 690, 890], [945, 190, 1310]]
APPROVE = [[1100, 250, 760, 440], [1000, 1240, 800]]
# Taller than CARD for the long code answer, and still short of the panel's transcript strip.
CARD_TALL = [[1100, 60, 760, 870], [2440, 88, 736]]


def ring(at, film_box, camera, hold=0.7):
    """Mark a click the capture can't show: film_box seen through camera, at a beat's time."""
    box, src = camera
    k = box[2] / src[2]
    x, y, w, h = film_box
    return dict(at=at, hold=hold, box=[round(box[0] + (x - src[0]) * k - 8, 1), round(box[1] + (y - src[1]) * k - 8, 1),
                                       round(w * k + 16, 1), round(h * k + 16, 1)])


def cam(*keys):
    """[(t, camera)] → [[t, box, src]]"""
    return [[t, c[0], c[1]] for t, c in keys]


# (id, footage from, footage to, length or voice line, cameras, voice lines [(id, offset)], beat text, flags)
BEATS = [
    dict(id='cold-a', f=('c03', -0.6, 'c03', 4.6), length=5.2, cam=cam((0, CALL)), voice=[('c03', 0.5)], call=True),
    dict(id='cold-b', f=('c03', 4.6, 'screen_answer', 4.0), length=9.6, cam=cam((0, CALL), (2.6, PANEL), (5.2, PANEL), (7.2, CARD)),
         voice=[('n01', 0.9)], fade_out=0.5,
         text=dict(at=5.6, kicker='Screen answer · Muse Spark', headline='4.1%, from my screen',
                   detail='Found in screen memory on my Mac, cropped by Apple Vision, read by Spark.', width=880)),
    dict(id='title', scene='title', length=3.2),
    dict(id='settings', f=('settings', 0, 'settings', 10), length=9.9, cam=cam((0, SETTINGS)),
         voice=[('n02', 0.3)], fade_in=0.5,
         text=dict(at=0.4, kicker='Settings · Meta Muse', headline='Three models, each opt-in',
                   chips=['Fast live text', 'Screen answers', 'Live answers', 'Floating panel'], width=400)),
    dict(id='start', f=('press_from', 0, 'press_from', 7.34 * PRESS_RATE), voice_fit='n03', pad=0.3, cam=cam((0, CALL)), voice=[('n03', 0.1)],
         fade_in=0.5, rings=[ring(PRESS_AT - 0.45, [2292, 464, 186, 50], CALL, hold=0.6)],
         text=dict(at=0.3, kicker='Live Radar', headline='One press, then back to the call', width=400)),
    dict(id='c01', f=('c01', 0, 'c02', -0.4), voice_fit='c01', pad=0.25, cam=cam((0, CALL)), voice=[('c01', 0.1)], call=True),
    dict(id='c02', f=('c02', -0.4, 'commit', -1.2), voice_fit='c02', pad=0.15, cam=cam((0, CALL)), voice=[('c02', 0.05)], call=True),
    dict(id='commit', f=('commit', -1.2, 'commit_end', 0), voice_fit='n04', pad=0.4, cam=cam((0, CALL), (2.6, CARD)),
         voice=[('n04', 0.2)],
         text=dict(at=1.8, kicker='Voice Transcribe → Muse Spark', headline='Caught as it’s said',
                   detail='Every item has to quote a line from the call, or it’s dropped.',
                   chips=['This take: scripted transcript'], width=880)),
    dict(id='c04', f=('c04_from', 0, 'c05', -0.4), voice_fit='c04', pad=0.2, cam=cam((0, CARD), (2.0, CALL)), voice=[('c04', 0.15)],
         call=True),
    dict(id='c05', f=('c05', -0.4, 'c05', 2.6), voice_fit='c05', pad=0.2, cam=cam((0, CALL), (0.3, CALL), (2.9, PANEL)), voice=[('c05', 0.15)],
         call=True),
    dict(id='q1-look', f=('c05', 2.6, 'q1_answer', 0.6), at_least='n05', pad=0.8, cam=cam((0, PANEL)), voice=[('n05', 0.3)],
         text=dict(at=0.3, kicker='Live answers · Muse Wonder', headline='It looks it up in my work',
                   detail='What LokalBot remembers comes first, then my documents, sheets, PDFs and code.',
                   width=880)),
    dict(id='q1-answer', f=('q1_answer', 0.6, 'q1_answer', 3.4), voice_fit='n06', pad=0.4, cam=cam((0, PANEL), (1.8, CARD)),
         voice=[('n06', 0.2)], fade_out=0.4,
         text=dict(at=0.4, kicker='Quote checked', headline='$12 per seat, from the sheet’s own row',
                   chips=['Northwind pricing v2.xlsx', 'caught → answered: {q1} s'], width=880)),
    dict(id='c07', f=('c07', -0.4, 'c08', -0.2), voice_fit='c07', pad=0.1, cam=cam((0, CALL)), voice=[('c07', 0.0)],
         call=True, fade_in=0.4),
    dict(id='c08', f=('c08', -0.2, 'contra_from', 0), voice_fit='c08', pad=0.1, cam=cam((0, CALL), (0.6, CALL), (3.4, CARD)),
         voice=[('c08', 0.0)], call=True),
    dict(id='contra', f=('contra_from', 0, 'contra_from', 0.5), voice_fit='n08', pad=0.3, cam=cam((0, CARD)), voice=[('n08', 0.1)],
         fade_out=0.4,
         text=dict(at=0.2, kicker='Contradiction · Muse Spark', headline='We agreed on Monday the 3rd',
                   detail='Quoted from the Launch planning meeting, October 25, found by search on my Mac.', width=880)),
    dict(id='c13', f=('c13', -0.3, 'c14', -0.4), voice_fit='c13', pad=0.2, cam=cam((0, CALL)), voice=[('c13', 0.05)],
         call=True, fade_in=0.4),
    dict(id='c14', f=('c14', -0.4, 'c09', 0), voice_fit='c14', pad=0.2, cam=cam((0, CALL), (2.2, CALL), (3.64, CARD_TALL)),
         voice=[('c14', 0.05)], call=True),
    # The capture stalls from 122 to 135 with Ana's line half typed. The close-up leaves that caption out,
    # the voice's own caption takes over, and the stalled seconds are cut.
    dict(id='c09', f=('c09', 0.8, 'c09', 2.7), voice_fit='c09', pad=0.05, cam=cam((0, CARD_TALL)), voice=[('c09', 0.03)],
         text=dict(at=1.9, kicker='Commitment · Muse Spark', headline='Free tier: decide tomorrow',
                   detail='Caught from my line, ready for after the call.', width=880)),
    dict(id='c10', f=('stall_end', 0, 'stall_end', 2.4), voice_fit='c10', pad=0.1, cam=cam((0, CARD_TALL)), voice=[('c10', 0.0)]),
    dict(id='q2-look', f=('stall_end', 2.4, 'q2_answer', 0.3), length=6.0, cam=cam((0, CARD_TALL)), voice=[('n09', 0.4)],
         text=dict(at=0.3, kicker='Live answers · code', headline='It reads the repository too',
                   detail='Tracked files only. Never .env files or keys.', width=880)),
    dict(id='q2-answer', f=('q2_answer', 0.3, 'q2_answer', 4.3), length=5.4, cam=cam((0, CARD_TALL)), fade_out=0.5,
         text=dict(at=0.9, kicker='Quote checked', headline='Yes, hidden by default',
                   detail='AppSettings.swift, line 176, linked on GitHub at the commit it read.',
                   chips=['caught → answered: {q2} s'], width=880)),
    dict(id='board', f=('board', -0.3, 'board', 8.7), voice_fit='n10', pad=0.9, cam=cam((0, BOARD)), voice=[('n10', 0.4)],
         fade_in=0.5,
         text=dict(at=0.3, kicker='After the call', headline='All of it, on the board', width=400)),
    dict(id='ft-a', f=('ft_open', -0.15, 'email_flip', -APPROVE_AT * APPROVE_RATE), voice_fit='n11', pad=0.8, cam=cam((0, FT)),
         voice=[('n11', 0.5)], fade_in=0.3,
         text=dict(at=0.4, until='ft-d', kicker='Follow-through · Muse Wonder', headline='It drafts. I approve.',
                   detail='The email and the invitation open as drafts in Mail and Calendar. LokalBot never sends them.',
                   width=880)),
    dict(id='ft-b', f=('approve_from', 0, 'approve_to', 0), length=APPROVE_LEN,
         cam=cam((0, FT), (0.9, APPROVE), (2.4, APPROVE), (3.2, FT)), voice=[('n11b', 0.1)],
         rings=[ring(APPROVE_AT - 0.35, [1024, 1386, 198, 50], APPROVE, hold=0.5),
                ring(3.2, [1990, 680, 176, 28], FT, hold=0.7)]),
    dict(id='ft-c', f=('approve_to', 0, 'invite_flip', -0.5), length=4.9, cam=cam((0, FT)), voice=[('n11c', 0.1)]),
    dict(id='ft-d', f=('invite_flip', -0.5, 'invite_flip', 1.7), length=2.4, cam=cam((0, FT)), fade_out=0.6,
         rings=[ring(0.2, [1024, 1524, 258, 50], FT, hold=0.5)]),
    dict(id='models', scene='models', voice_fit='n12', pad=0.8, voice=[('n12', 0.4)]),
    dict(id='endcard', scene='endcard', length=7.5, voice=[('n13', 0.6)]),
]


def word_time(line_id, word):
    """Seconds into a line's take where a word starts, from the ElevenLabs alignment."""
    rows = json.loads((P / 'production/voice-generation.json').read_text())['rows']
    path = TAKES.get(line_id, f'assets/voice/{line_id}-s11.mp3')
    a = next(r for r in rows if r['file'] == path)['alignment']
    text = ''.join(a['characters']).lower()
    return a['character_start_times_seconds'][text.index(word.lower())]


def film(anchor, offset):
    return round(A[anchor] + offset, 3)


def main():
    t = 0.0
    shots, voice, beats, scenes, rings = [], [], [], {}, []
    for b in BEATS:
        if 'at_least' in b:
            f0, f1 = film(*b['f'][:2]), film(*b['f'][2:])
            length = max(f1 - f0, voice_len(b['at_least']) + b.get('pad', 0.3))
        elif 'length' in b and b['length']:
            length = b['length']
        elif 'voice_fit' in b:
            length = voice_len(b['voice_fit']) + b.get('pad', 0.3)
        else:
            length = None
        if 'f' in b:
            f0, f1 = film(*b['f'][:2]), film(*b['f'][2:])
            if length is None:
                length = (f1 - f0) / b.get('rate', 1.0)
            rate = round((f1 - f0) / length, 4)
            shots.append({'id': b['id'], 'start': round(t, 3), 'end': round(t + length, 3), 'media_start': f0, 'rate': rate,
                          'cam': b['cam'], 'fade_in': b.get('fade_in', 0), 'fade_out': b.get('fade_out', 0),
                          'call': b.get('call', False)})
        else:
            scenes[b['scene']] = {'start': round(t, 3), 'end': round(t + length, 3)}
        for line_id, offset in b.get('voice', []):
            voice.append([line_id, round(t + offset, 3)])
        if 'text' in b:
            x = dict(b['text'])
            fill = {'q1': round(A['q1_answer'] - A['q1_caught']), 'q2': round(A['q2_answer'] - A['q2_caught'])}
            x['chips'] = [c.format(**fill) for c in x.get('chips', [])]
            x.update({'id': b['id'], 'start': round(t + x.pop('at'), 3), 'end': round(t + length - 0.1, 3)})
            beats.append(x)
        for r in b.get('rings', []):
            rings.append({'start': round(t + r['at'], 3), 'end': round(t + r['at'] + r['hold'], 3), 'box': r['box']})
        t += length
    ends = {s['id']: s['end'] for s in shots}
    for x in beats:
        if 'until' in x:
            x['end'] = round(ends[x.pop('until')] - 0.1, 3)
    # The model cards come in as n12 names them.
    n12 = next(start for lid, start in voice if lid == 'n12')
    scenes['models']['cues'] = [round(n12 + word_time('n12', w) - 0.15, 3)
                                for w in ('realtime', 'fast reading', 'careful', 'search')]
    edit = {'fps': 60, 'duration': round(t, 3), 'footage': 'assets/footage/film.mp4', 'source_size': [3200, 2000],
            'takes': TAKES, 'shots': shots, 'voice': voice, 'beats': beats, 'rings': rings, 'scenes': scenes,
            'endcard_note': 'Real app on sample data, driven by an automated test. The call and all voices are staged and '
                            'synthetic, so Voice Transcribe didn’t run in this take. Muse Spark and Muse Wonder replies are live.',
            'anchors_run': A['run']}
    (P / 'edit.json').write_text(json.dumps(edit, indent=1, ensure_ascii=False) + '\n')
    for s in shots:
        print(f"{s['id']:10} {s['start']:7.2f}–{s['end']:7.2f}  film {s['media_start']:6.1f}  rate {s['rate']}")
    print('scenes', scenes, 'total', round(t, 2))


if __name__ == '__main__':
    main()
