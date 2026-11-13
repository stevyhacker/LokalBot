"""Build the summary benchmark's meeting library from 12 AMI scenario meetings.

Each meeting gets one folder per transcript condition:
- ref: AMI's manual transcript (official segmentation, punctuation kept, truncated
  words and non-word sounds dropped). Speakers are labelled "them N" in order of
  first appearance, as the app labels unknown voices.
- new / old: the Mix-Headset recording as the meeting's system track, for two app
  builds to transcribe (the build under test and a baseline).
Every folder shares a neutral meta.json, so only the transcript differs.

Downloads the AMI manual annotations (CC BY 4.0) and audio once. Audio already
fetched for Benchmarks/transcribe/CloudSTT is reused.
"""
import json
import os
import re
import shutil
import subprocess
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

BENCH = Path(os.environ.get('SUMMARY_BENCH_DIR', '/private/tmp/lokalbot-summary-bench'))
ANN = BENCH / 'ami-ann'
AUDIO = BENCH / 'audio'
LIB = BENCH / 'library'
MEETINGS_DIR = LIB / 'meetings' / '2026' / '10'
CLOUD_AMI = Path(os.environ.get('STT_BENCH_DATA', '/private/tmp/lokalbot-cloud-stt')) / 'source' / 'ami'
MODELS = Path.home() / 'Library/Application Support/me.dotenv.LokalBot/models'
MEETINGS = [f'{s}{x}' for s in ['ES2004', 'IS1009', 'TS3003'] for x in 'abcd']
CONDITIONS = ['ref', 'new', 'old']
ANN_URL = 'https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip'
AUDIO_URL = 'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{0}/audio/{0}.Mix-Headset.wav'
NS = '{http://nite.sourceforge.net/}'


def annotations():
    if (ANN / 'abstractive').exists():
        return
    ANN.mkdir(parents=True, exist_ok=True)
    archive = ANN / 'ami_manual.zip'
    if not archive.exists():
        urllib.request.urlretrieve(ANN_URL, archive)
    with zipfile.ZipFile(archive) as z:
        z.extractall(ANN)


def words(meeting, agent):
    tree = ET.parse(ANN / 'words' / f'{meeting}.{agent}.words.xml')
    out = {}
    for el in tree.getroot():
        wid = el.get(f'{NS}id')
        if el.tag == 'w':
            out[wid] = {'text': el.text or '', 'punc': el.get('punc') == 'true', 'trunc': el.get('trunc') == 'true',
                        'start': float(el.get('starttime') or 0), 'end': float(el.get('endtime') or 0)}
        else:
            out[wid] = None  # vocalsound, disfmarker, gap
    return out


def reference(meeting):
    agents = sorted({p.name.split('.')[1] for p in (ANN / 'segments').glob(f'{meeting}.*.segments.xml')})
    utterances = []
    for agent in agents:
        w = words(meeting, agent)
        order = list(w)
        tree = ET.parse(ANN / 'segments' / f'{meeting}.{agent}.segments.xml')
        for seg in tree.getroot():
            child = seg.find(f'{NS}child')
            if child is None:
                continue
            ids = re.findall(r'id\(([^)]+)\)', child.get('href'))
            span = order[order.index(ids[0]):order.index(ids[-1]) + 1]
            text, times = '', []
            for wid in span:
                item = w[wid]
                if not item or item['trunc']:
                    continue
                text += item['text'] if item['punc'] else (' ' if text else '') + item['text']
                if not item['punc']:
                    times.append((item['start'], item['end']))
            text = text.strip()
            if not times or not re.search(r'[A-Za-z0-9]', text):
                continue
            utterances.append({'start': times[0][0], 'end': max(e for _, e in times), 'agent': agent, 'text': text})
    utterances.sort(key=lambda u: (u['start'], u['end']))
    labels = {}
    for u in utterances:
        labels.setdefault(u['agent'], f'them {len(labels) + 1}')
    return [{'start': round(u['start'], 2), 'end': round(max(u['end'], u['start'] + 0.01), 2), 'speaker': labels[u['agent']],
             'text': u['text'], 'timingPrecision': 'span',
             'attribution': {'identity': 'other', 'method': 'diarization', 'source': 'system'}} for u in utterances]


def main():
    annotations()
    AUDIO.mkdir(parents=True, exist_ok=True)
    MEETINGS_DIR.mkdir(parents=True, exist_ok=True)
    if not (LIB / 'models').exists():
        (LIB / 'models').symlink_to(MODELS)  # reuse installed models instead of downloading copies
    for meeting in MEETINGS:
        wav = AUDIO / f'{meeting}.Mix-Headset.wav'
        if not wav.exists():
            cached = CLOUD_AMI / wav.name
            if cached.exists():
                shutil.copy2(cached, wav)
            else:
                urllib.request.urlretrieve(AUDIO_URL.format(meeting), wav)
        m4a = AUDIO / f'{meeting}.system.m4a'
        if not m4a.exists():
            subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', '-c', '1', str(wav), str(m4a)], check=True)
        duration = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                         str(m4a)], capture_output=True, text=True, check=True).stdout)
        segments = reference(meeting)
        for condition in CONDITIONS:
            rel = f'meetings/2026/10/{meeting.lower()}-{condition}'
            folder = LIB / rel
            folder.mkdir(parents=True, exist_ok=True)
            meta = {'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'lokalbot-summary-bench/{meeting}/{condition}')).upper(),
                    'title': 'Product design meeting', 'appName': 'Benchmark',
                    'startedAt': '2026-10-01T09:00:00Z',
                    'endedAt': f'2026-10-01T{9 + int(duration // 3600):02d}:{int(duration % 3600 // 60):02d}:{int(duration % 60):02d}Z',
                    'relativePath': rel, 'hasSystemTrack': True}
            (folder / 'meta.json').write_text(json.dumps(meta))
            if not (folder / 'system.m4a').exists():
                os.link(m4a, folder / 'system.m4a')
            if condition == 'ref':
                (folder / 'transcript.json').write_text(json.dumps(
                    {'engine': 'AMI manual transcript', 'segments': segments}, indent=1))
        print(f'{meeting}: {duration / 60:.1f} min, reference {len(segments)} segments, '
              f'{sum(len(s["text"].split()) for s in segments)} words')


if __name__ == '__main__':
    main()
