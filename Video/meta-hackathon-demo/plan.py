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


def voice_len(line_id):
    path = P / TAKES.get(line_id, f'assets/voice/{line_id}-s11.mp3')
    return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(path)],
                                check=True, capture_output=True, text=True).stdout)


# Cameras: [box x, y, w, h on the 1920x1080 canvas], [film x, y, w]; the film rect's height follows the box.
CALL = [[542, 44, 1318, 890], [0, 28, 1440]]
PANEL = [[1279, 44, 581, 890], [1098, 38, 334]]
CARD = [[1100, 110, 760, 780], [1098, 58, 334]]
SETTINGS = [[542, 44, 1318, 890], [560, 190, 720]]
SETTINGS_IN = [[542, 44, 1318, 890], [585, 200, 640]]
MEETING = [[542, 44, 1318, 890], [440, 190, 980]]
FT = [[1170, 44, 690, 890], [425, 120, 590]]


def cam(*keys):
    """[(t, camera)] → [[t, box, src]]"""
    return [[t, c[0], c[1]] for t, c in keys]


# (id, footage from, footage to, length or voice line, cameras, voice lines [(id, offset)], beat text, flags)
BEATS = [
    dict(id='cold-a', f=('c03', -0.6, 'c03', 4.6), length=5.2, cam=cam((0, CALL)), voice=[('c03', 0.5)], call=True),
    dict(id='cold-b', f=('c03', 4.6, 'screen_answer', 4.0), length=9.6, cam=cam((0, CALL), (2.2, PANEL), (5.2, PANEL), (6.6, CARD)),
         voice=[('n01', 0.9)], fade_out=0.5,
         text=dict(at=5.6, kicker='Screen answer · Muse Spark', headline='4.1%, from my screen last week',
                   detail='Found in screen memory on my Mac, cropped by Vision, read by Spark.', width=880)),
    dict(id='title', scene='title', length=5.0),
    dict(id='settings', f=('settings', 0, 'settings', 10), length=10.2, cam=cam((0, SETTINGS), (9.0, SETTINGS_IN)),
         voice=[('n02', 0.3)], fade_in=0.5,
         text=dict(at=0.4, kicker='Settings · Meta Muse', headline='Each one is opt-in',
                   chips=['Fast live text', 'Screen answers', 'Live answers', 'Floating panel'], width=400)),
    dict(id='start', f=('live_view', 0, 'call_open', 1.0), voice_fit='n03', pad=0.3, cam=cam((0, CALL)), voice=[('n03', 0.1)],
         fade_in=0.5,
         text=dict(at=0.3, kicker='Live Radar', headline='One press, then back to the call', width=400)),
    dict(id='c01', f=('call_open', 1.0, 'c02', -0.4), voice_fit='c01', pad=0.25, cam=cam((0, CALL)), voice=[('c01', 0.1)], call=True),
    dict(id='c02', f=('c02', -0.4, 'commit', -1.2), voice_fit='c02', pad=0.15, cam=cam((0, CALL)), voice=[('c02', 0.05)], call=True),
    dict(id='commit', f=('commit', -1.2, 'c04', 0), voice_fit='n04', pad=0.4, cam=cam((0, CALL), (1.3, PANEL)),
         voice=[('n04', 0.2)],
         text=dict(at=1.5, kicker='Voice Transcribe → Muse Spark', headline='Caught as it’s said',
                   detail='Every item has to quote a line from the call, or it’s dropped.', width=880)),
    dict(id='c04', f=('c04', 0, 'c05', -0.4), voice_fit='c04', pad=0.2, cam=cam((0, PANEL), (0.9, CALL)), voice=[('c04', 0.15)],
         call=True),
    dict(id='c05', f=('c05', -0.4, 'c05', 2.6), voice_fit='c05', pad=0.5, cam=cam((0, CALL), (1.6, PANEL)), voice=[('c05', 0.15)],
         call=True),
    dict(id='q1-look', f=('c05', 2.6, 'q1_answer', 0.6), length=None, rate=1.0, cam=cam((0, PANEL)), voice=[('n05', 0.3)],
         text=dict(at=0.3, kicker='Live answers · Muse Wonder', headline='It looks it up in my work',
                   detail='What LokalBot remembers comes first, then my documents, sheets, PDFs and code. Real time.',
                   width=880)),
    dict(id='q1-answer', f=('q1_answer', 0.6, 'q1_answer', 3.4), voice_fit='n06', pad=0.4, cam=cam((0, PANEL), (1.0, CARD)),
         voice=[('n06', 0.2)], fade_out=0.4,
         text=dict(at=0.4, kicker='Quote checked', headline='$12 per seat, from the sheet’s own row',
                   chips=['Northwind pricing v2.xlsx', 'question → answer: {q1} s'], width=880)),
    dict(id='c07', f=('c07', -0.4, 'contradiction', 0.2), voice_fit='c07', pad=0.1, cam=cam((0, CALL)), voice=[('c07', 0.0)],
         call=True, fade_in=0.4),
    dict(id='c08', f=('contradiction', 0.2, 'c08', 2.4), voice_fit='c08', pad=0.1, cam=cam((0, CALL), (1.4, CARD)),
         voice=[('c08', 0.0)], call=True),
    dict(id='contra', f=('c08', 2.4, 'c08', 4.9), voice_fit='n08', pad=0.3, cam=cam((0, CARD)), voice=[('n08', 0.1)],
         fade_out=0.4,
         text=dict(at=0.2, kicker='Contradiction · Muse Spark', headline='We agreed on Monday the 3rd',
                   detail='Quoted from the Launch planning meeting, October 21, found by search on my Mac.', width=880)),
    dict(id='c09', f=('c09', -0.4, 'c10', -0.2), voice_fit='c09', pad=0.05, cam=cam((0, CALL)), voice=[('c09', 0.03)],
         call=True, fade_in=0.4),
    dict(id='c10', f=('c10', -0.2, 'c10', 2.4), voice_fit='c10', pad=0.1, cam=cam((0, CALL)), voice=[('c10', 0.0)], call=True),
    # Wonder searches the code while another answer holds the panel's top card, so this runs wide, at speed.
    dict(id='q2-look', f=('c10', 2.4, 'q2_answer', 0.3), length=6.0, cam=cam((0, CALL), (5.0, CALL), (6.0, PANEL)),
         voice=[('n09', 0.4)],
         text=dict(at=0.3, kicker='Live answers · code', headline='It reads the repository too',
                   detail='Tracked files only. Never .env files or keys.', width=400)),
    dict(id='q2-answer', f=('q2_answer', 0.3, 'q2_answer', 4.3), length=6.6, cam=cam((0, PANEL), (0.9, CARD)), fade_out=0.5,
         text=dict(at=0.9, kicker='Quote checked', headline='Yes, hidden by default',
                   detail='AppSettings.swift, line 176, linked on GitHub at the commit it read.',
                   chips=['question → answer: {q2} s'], width=880)),
    dict(id='board', f=('board', -0.3, 'board', 8.7), voice_fit='n10', pad=1.8, cam=cam((0, CALL)), voice=[('n10', 0.8)],
         fade_in=0.5,
         text=dict(at=0.6, kicker='After the call', headline='All of it, on the board', width=400)),
    dict(id='meeting', f=('meeting_page', 1, 'meeting_page', 4.4), length=3.4, cam=cam((0, MEETING)), fade_in=0.4),
    dict(id='ft', f=('ft_open', -0.4, 'ft_done', 1), voice_fit='n11', pad=6.0, cam=cam((0, FT)), voice=[('n11', 1.0)],
         fade_in=0.3, fade_out=0.6,
         text=dict(at=0.6, kicker='Follow-through · Muse Wonder', headline='It drafts. I approve.',
                   detail='The email and the invitation open as drafts in Mail and Calendar. LokalBot never sends them.',
                   width=880)),
    dict(id='models', scene='models', voice_fit='n12', pad=1.4, voice=[('n12', 0.4)]),
    dict(id='endcard', scene='endcard', length=6.0, voice=[('n13', 0.6)]),
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
    shots, voice, beats, scenes = [], [], [], {}
    for b in BEATS:
        if 'length' in b and b['length']:
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
        t += length
    # The model cards come in as n12 names them.
    n12 = next(start for lid, start in voice if lid == 'n12')
    scenes['models']['cues'] = [round(n12 + word_time('n12', w) - 0.15, 3)
                                for w in ('realtime', 'fast reading', 'careful', 'search')]
    edit = {'fps': 30, 'duration': round(t, 3), 'footage': 'assets/footage/film.mp4', 'source_size': [1440, 1080],
            'takes': TAKES, 'shots': shots, 'voice': voice, 'beats': beats, 'scenes': scenes,
            'badge': {'text': 'Filmed by the CI test · scripted call · live Muse replies',
                      'start': shots[0]['start'], 'end': scenes['endcard']['start']},
            'endcard_note': 'Filmed on a hosted Mac by the hackathon UI test: the call’s words are scripted, '
                            'and Muse Spark and Muse Wonder answer live through the Meta Model API.',
            'anchors_run': A['run']}
    (P / 'edit.json').write_text(json.dumps(edit, indent=1, ensure_ascii=False) + '\n')
    for s in shots:
        print(f"{s['id']:10} {s['start']:7.2f}–{s['end']:7.2f}  film {s['media_start']:6.1f}  rate {s['rate']}")
    print('scenes', scenes, 'total', round(t, 2))


if __name__ == '__main__':
    main()
