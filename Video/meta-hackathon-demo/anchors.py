"""Find the take's moments by OCR and write production/anchors.json.

Reads one frame a second of assets/footage/film.mp4 with tesseract: the call's
caption bar (who is speaking, what is typed), the floating panel, and the
Follow-through sheet. Each anchor is the first second its text shows up,
after the anchor before it. Check the result against the frames before
trusting a new take: OCR can miss a moment, and then the anchor is null.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

P = Path(__file__).resolve().parent
FILM = P / 'assets/footage/film.mp4'
REGIONS = {'cap': 'crop=920:70:180:875,scale=1840:-1', 'panel': 'crop=330:500:1100:42,scale=990:-1',
           'card': 'crop=330:300:1100:42,scale=990:-1', 'sheet': 'crop=600:780:425:120'}

# (anchor, region, pattern); searched in order, each from the previous anchor on.
RULES = [
    ('live_view', 'panel', r'Live Transcript'),
    ('call_open', 'panel', r'Live Radar'),
    ('c01', 'cap', r'Hi!'),
    ('c02', 'cap', r"send the revised"),
    ('commit', 'panel', r'COMMITMENT'),
    ('c04', 'cap', r'Great\. What'),
    ('q1_caught', 'card', r'OPEN QUESTION.*Team plan price'),
    ('c05', 'cap', r'One second'),
    ('q1_answer', 'panel', r'Answer from your work'),
    ('c03', 'cap', r'And what'),
    ('screen_answer', 'panel', r'On your screen'),
    ('c07', 'cap', r'Also, the launch'),
    ('contradiction', 'panel', r'CONTRADICTION'),
    ('c08', 'cap', r'thought it was'),
    ('c09', 'cap', r'Unrelated'),
    ('c10', 'cap', r'Hm,(?! I)'),
    ('q2_answer', 'panel', r'radar panel hidden.*Answer from your work'),
    ('ft_open', 'sheet', r'planning the next step|Read meeting'),
    ('ft_email', 'sheet', r'Email draft'),
    ('ft_invite', 'sheet', r'Meeting invitation'),
]


def ocr(image, vf):
    with tempfile.NamedTemporaryFile(suffix='.png') as crop:
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(image), '-vf', vf, crop.name], check=True)
        out = subprocess.run(['tesseract', crop.name, '-', '--psm', '6'], capture_output=True, text=True).stdout
    return ' '.join(out.split())


def main():
    frames = P / 'production/ocr'
    frames.mkdir(parents=True, exist_ok=True)
    for old in frames.glob('f*.png'):
        old.unlink()
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(FILM), '-vf', 'fps=1', str(frames / 'f%03d.png')], check=True)
    rows = []
    for image in sorted(frames.glob('f*.png')):
        rows.append({'t': int(image.stem[1:]) - 1, **{k: ocr(image, vf) for k, vf in REGIONS.items()}})
    (frames / 'timeline.json').write_text(json.dumps(rows, indent=0, ensure_ascii=False) + '\n')
    run = (P / 'assets/footage/run-id.txt').read_text().strip()
    anchors = {'run': int(run), 'note': 'Film seconds of each moment in the CI take, from anchors.py (tesseract, one frame a second).'}
    after = 0
    for name, region, pattern in RULES:
        hit = next((r['t'] for r in rows if r['t'] >= after and re.search(pattern, r[region])), None)
        anchors[name] = hit
        if hit is not None:
            after = hit
    # The settings page is up from about 11 s before the live view. The board shows once Open LokalBot
    # closes the call, the meeting page once the host relaunches on it, and Follow-through is done
    # when its last approval stops showing "planning the next step".
    anchors['settings'] = anchors['live_view'] - 11
    anchors['board'] = next((r['t'] for r in rows if r['t'] > (anchors['q2_answer'] or 0)
                             and 'Stop Recording' in r['panel']), None)
    anchors['meeting_page'] = next((r['t'] for r in rows if r['t'] > (anchors['board'] or 0)
                                    and 'Ask This Meeting' in r['panel']), None)
    planning = [r['t'] for r in rows if r['t'] > (anchors['ft_invite'] or 0) and 'planning the next step' in r['sheet']]
    anchors['ft_done'] = planning[-1] + 1 if planning else None
    # A question caught while an answer holds the spotlight never reaches the top card; set those by hand.
    manual = P / 'production/anchors-manual.json'
    if manual.exists():
        anchors.update({k: v for k, v in json.loads(manual.read_text()).items() if not k.startswith('_')})
    (P / 'production/anchors.json').write_text(json.dumps(anchors, indent=1) + '\n')
    print(json.dumps(anchors, indent=1))
    missing = [k for k, v in anchors.items() if v is None]
    if missing:
        sys.exit(f'not found: {missing}; set them by hand from production/ocr/timeline.json')


if __name__ == '__main__':
    main()
