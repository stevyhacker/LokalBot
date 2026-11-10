"""Find the take's moments by OCR and write production/anchors.json.

Reads one frame a second of assets/footage/film.mp4 with tesseract: the call's
caption bar (who is speaking, what is typed), the floating panel, and the
Follow-through sheet. Each anchor is the first second its text shows up
after the anchor it follows. Check the result against the frames before
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
REGIONS = {'cap': 'crop=1965:115:245:1725', 'panel': 'crop=756:1150:2430:76', 'card': 'crop=756:700:2430:76',
           'sheet': 'crop=1280:1640:960:200', 'settings': 'crop=1460:900:1290:470'}

# (anchor, region, pattern, anchor it comes after): the first second the text shows up after that anchor.
RULES = [
    ('live_view', 'panel', r'Live Transcript', None),
    ('call_open', 'panel', r'Live Radar', 'live_view'),
    ('c01', 'cap', r'Hi!', 'call_open'),
    ('c02', 'cap', r'send the revised', 'c01'),
    ('commit', 'panel', r'COMMITMENT', 'c01'),
    ('c04', 'cap', r'Great\. What', 'c02'),
    ('c05', 'cap', r'One second', 'c04'),
    ('q1_caught', 'card', r'OPEN QUESTION.*Team plan price', 'c04'),
    ('q1_answer', 'card', r'Team plan price.*Answer from your work', 'q1_caught'),
    ('c03', 'cap', r'And what', 'c05'),
    ('screen_answer', 'panel', r'4\.1%', 'c03'),
    ('c07', 'cap', r'Also, the launch', 'c03'),
    ('c08', 'cap', r'thought it was', 'c07'),
    ('contradiction', 'panel', r'CONTRADICTION', 'c07'),
    ('c09', 'cap', r'Unrelated', 'c08'),
    ('c10', 'cap', r'Hm,(?! I)', 'c09'),
    # A caught question's row carries its time; the transcript strip's copy of the line doesn't.
    ('q2_caught', 'panel', r'radar panel hidden.{0,60}0\d:\d\d', 'c09'),
    ('q2_answer', 'card', r'radar panel hidden.*Answer from your work', 'c09'),
    ('board', 'panel', r'Stop Recording', 'q2_answer'),
    ('meeting_page', 'panel', r'Ask\s*This\s*Meeting', 'board'),
    ('ft_open', 'sheet', r'Muse Wonder', 'meeting_page'),
    ('ft_email', 'sheet', r'Email draft', 'ft_open'),
    ('ft_invite', 'sheet', r'Meeting invitation', 'ft_email'),
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
    for name, region, pattern, after in RULES:
        since = anchors.get(after) or 0
        anchors[name] = next((r['t'] for r in rows if r['t'] >= since and re.search(pattern, r[region])), None)
    # The settings page has settled on the Meta Muse switches once they all show. Follow-through
    # is done when its last approval stops showing "planning the next step".
    settled = [r['t'] for r in rows if r['t'] < anchors['live_view'] and 'Folders and repositories' in r['settings']]
    anchors['settings'] = settled[-1] - 10 if settled else anchors['live_view'] - 11
    planning = [r['t'] for r in rows if r['t'] > (anchors['ft_invite'] or 0) and 'planning the next step' in r['sheet']]
    anchors['ft_done'] = planning[-1] + 1 if planning else None
    # A question caught while an answer holds the top card has no row OCR can always read. Its answer card
    # states the real seconds, so set q2_caught by hand from that when this comes up empty.
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
