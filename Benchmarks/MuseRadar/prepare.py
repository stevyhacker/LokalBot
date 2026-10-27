"""Build Live Radar replay fixtures from the 12 AMI scenario meetings that
Benchmarks/SummaryQuality uses (ES2004, IS1009, TS3003, meetings a-d).

The app's live preview gives the radar one line per ~12 s chunk of each track,
with no voices told apart inside a track. The fixtures do the same with AMI's
manual transcript: the Project Manager is the microphone ("Me"), and the other
three people share the call track ("Others"). Each track's words are cut into
lines at the first utterance end at least 12 s after the line began, timed at the
line's first word, roughly as `LiveTranscriptChunker` cuts audio.

"Earlier meetings" are the decision and action sentences of AMI's human
summaries of the same team's previous meetings, standing in for the saved
outcomes LokalBot's search would find (at most six, newest first).

Writes $MUSE_RADAR_DATA/fixtures/<meeting>.json and references.json (AMI's
abstract, action, decision and problem sentences per meeting). AMI annotations
are CC BY 4.0.
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DATA = Path(os.environ.get('MUSE_RADAR_DATA', '/private/tmp/lokalbot-muse-radar'))
os.environ['SUMMARY_BENCH_DIR'] = str(DATA)  # shares the annotation download layout
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'SummaryQuality'))
from prepare import ANN, MEETINGS, annotations, words  # noqa: E402

TARGET = 12.0
NS = '{http://nite.sourceforge.net/}'
PURPOSE = {'a': 'kick-off', 'b': 'functional design', 'c': 'conceptual design', 'd': 'detailed design'}


def roles(meeting):
    tree = ET.parse(ANN / 'corpusResources' / 'meetings.xml')
    for node in tree.getroot():
        if node.get('observation') == meeting:
            return {s.get('nxt_agent'): s.get('role') for s in node if s.tag.endswith('speaker')}
    raise KeyError(meeting)


def utterances(meeting):
    """AMI's manual segments with word times, as SummaryQuality's prepare reads them."""
    out = []
    for agent in sorted({p.name.split('.')[1] for p in (ANN / 'segments').glob(f'{meeting}.*.segments.xml')}):
        w = words(meeting, agent)
        order = list(w)
        for seg in ET.parse(ANN / 'segments' / f'{meeting}.{agent}.segments.xml').getroot():
            child = seg.find(f'{NS}child')
            if child is None:
                continue
            ids = re.findall(r'id\(([^)]+)\)', child.get('href'))
            text, times = '', []
            for wid in order[order.index(ids[0]):order.index(ids[-1]) + 1]:
                item = w[wid]
                if not item or item['trunc']:
                    continue
                text += item['text'] if item['punc'] else (' ' if text else '') + item['text']
                if not item['punc']:
                    times.append((item['start'], item['end']))
            if times and re.search(r'[A-Za-z0-9]', text):
                out.append({'agent': agent, 'start': times[0][0], 'end': max(e for _, e in times), 'text': text.strip()})
    return sorted(out, key=lambda u: (u['start'], u['end']))


def chunk(track, speaker):
    lines, current = [], []
    for u in track:
        current.append(u)
        if current[-1]['end'] - current[0]['start'] >= TARGET:
            lines.append({'time': round(current[0]['start'], 2), 'speaker': speaker,
                          'text': ' '.join(x['text'] for x in current)})
            current = []
    if current:
        lines.append({'time': round(current[0]['start'], 2), 'speaker': speaker,
                      'text': ' '.join(x['text'] for x in current)})
    return lines


def summary(meeting):
    text = (ANN / 'abstractive' / f'{meeting}.abssumm.xml').read_text(encoding='latin-1')
    out = {}
    for part in ['abstract', 'actions', 'decisions', 'problems']:
        block = re.search(rf'<{part}[^>]*>(.*?)</{part}>', text, re.S)
        sentences = [re.sub(r'\s+', ' ', s).strip()
                     for s in re.findall(r'<sentence[^>]*>(.*?)</sentence>', block.group(1), re.S)] if block else []
        out[part] = [s for s in sentences if not re.fullmatch(r'(?i)n/?a\.?|none\.?', s)]
    return out


def main():
    annotations()
    (DATA / 'fixtures').mkdir(parents=True, exist_ok=True)
    references = {}
    for meeting in MEETINGS:
        series, letter = meeting[:6], meeting[6]
        manager = next(agent for agent, role in roles(meeting).items() if role == 'PM')
        spoken = utterances(meeting)
        lines = sorted(chunk([u for u in spoken if u['agent'] == manager], 'local')
                       + chunk([u for u in spoken if u['agent'] != manager], 'them'), key=lambda x: x['time'])
        earlier = []
        for previous in reversed('abcd'[:'abcd'.index(letter)]):
            parts = summary(series + previous)
            for sentence in parts['decisions'] + parts['actions']:
                earlier.append({'title': f'Remote control design: {PURPOSE[previous]} meeting',
                                'date': f'2026-10-0{1 + "abcd".index(previous)}T09:00:00Z', 'text': sentence})
        fixture = {'id': meeting, 'title': f'Remote control design: {PURPOSE[letter]} meeting',
                   'date': f'2026-10-0{1 + "abcd".index(letter)}T09:00:00Z', 'lines': lines, 'earlier': earlier[:6]}
        (DATA / 'fixtures' / f'{meeting}.json').write_text(json.dumps(fixture, indent=1))
        references[meeting] = summary(meeting)
        minutes = (lines[-1]['time'] if lines else 0) / 60
        print(f'{meeting}: {minutes:.1f} min, {len(lines)} lines ({sum(x["speaker"] == "local" for x in lines)} Me), '
              f'{len(fixture["earlier"])} earlier passages, AMI {len(references[meeting]["actions"])} actions, '
              f'{len(references[meeting]["decisions"])} decisions')
    (DATA / 'references.json').write_text(json.dumps(references, indent=1))


if __name__ == '__main__':
    main()
