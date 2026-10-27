"""Deterministic public/synthetic speech sample, selected before inference.

Usage: prepare.py OUT. Downloads public audio only. No meeting-library access.
"""
import csv
import hashlib
import io
import json
import re
import subprocess
import sys
import tarfile
import wave
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import requests

ROOT = Path(__file__).resolve().parents[2]
FLEURS_REV = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
RATE = 16000

def decode(path):
    return np.frombuffer(subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(path),
        '-ac', '1', '-ar', str(RATE), '-f', 'f32le', '-'], check=True, capture_output=True).stdout, dtype='<f4').copy()

def fetch(url, path):
    if not path.exists():
        r = requests.get(url, timeout=60)
        r.raise_for_status()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(r.content)
    return path

def main():
    out = Path(sys.argv[1])
    (out / 'source').mkdir(parents=True, exist_ok=True)
    (out / 'clips').mkdir(exist_ok=True)
    items = []
    def add(id, group, audio, reference, source, hints=None, language=None, **extra):
        duration = len(audio) / RATE
        if not 0 < duration <= 30:
            raise ValueError(f'{id}: {duration} seconds exceeds batch window')
        pcm = out / 'clips' / f'{id}.f32'
        pcm.write_bytes(np.asarray(audio, dtype='<f4').tobytes())
        items.append(dict(id=id, group=group, pcm=str(pcm), duration=duration, reference=reference,
                          source=source, sha256=hashlib.sha256(pcm.read_bytes()).hexdigest(),
                          hints=hints, language=language, **extra))

    # Existing fixed 24 AMI utterances from several positions in the test split.
    old = json.loads((ROOT / 'Benchmarks/FunASR/2026-09-08/short-clips-manifest.json').read_text())
    ami = [r for r in old if r['dataset'] == 'edinburghcstr/ami']
    def download_ami(row):
        path = out / 'source' / f"{row['id']}.wav"
        try:
            fetch(row['source_url'], path)
        except requests.HTTPError:
            url = f"https://datasets-server.huggingface.co/rows?dataset=edinburghcstr%2Fami&config=ihm&split=test&offset={row['row']}&length=1"
            response = requests.get(url, timeout=60)
            response.raise_for_status()
            fresh = response.json()['rows'][0]['row']
            assert fresh['text'] == row['reference']
            fetch(fresh['audio'][0]['src'], path)
        return row, decode(path)
    with ThreadPoolExecutor(max_workers=4) as pool:
        for row, pcm in pool.map(download_ami, ami):
            add(row['id'], 'ami', pcm, row['reference'], row['source_url'])
    print(f'AMI: {len(ami)} clips', flush=True)

    # First eligible tar entries, by fixed test archive order; no model-output selection.
    for lang, count in [('en_us', 20), ('de_de', 8), ('fr_fr', 8), ('pl_pl', 8), ('sr_rs', 8)]:
        base = f'https://huggingface.co/datasets/google/fleurs/resolve/{FLEURS_REV}/data/{lang}'
        tsv = fetch(base + '/test.tsv', out / 'source' / f'{lang}-test.tsv').read_text()
        refs = {r[1]: r[2] for r in csv.reader(io.StringIO(tsv), delimiter='\t', quoting=csv.QUOTE_NONE) if len(r) > 2}
        cache = out / 'source' / f'{lang}-selected.json'
        if cache.exists():
            selected = json.loads(cache.read_text())
        else:
            selected = []
            with requests.get(base + '/audio/test.tar.gz', stream=True, timeout=60) as response:
                response.raise_for_status()
                with tarfile.open(fileobj=response.raw, mode='r|gz') as archive:
                    for member in archive:
                        name = Path(member.name).name
                        if not member.isfile() or name not in refs:
                            continue
                        path = out / 'source' / f'{lang}-{name}'
                        path.write_bytes(archive.extractfile(member).read())
                        pcm = decode(path)
                        if not 3 <= len(pcm) / RATE <= 25:
                            continue
                        selected.append(dict(name=name, path=str(path), reference=refs[name]))
                        if len(selected) == count:
                            break
            assert len(selected) == count, (lang, len(selected))
            cache.write_text(json.dumps(selected, indent=2))
        for i, row in enumerate(selected):
            add(f'fleurs-{lang}-{i:02}', f'fleurs-{lang}', decode(row['path']), row['reference'],
                base + '/audio/test.tar.gz#' + row['name'])
        print(f'FLEURS {lang}: {len(selected)} clips', flush=True)

    # Six noisy versions: deterministic white noise at 10 dB whole-clip SNR.
    rng = np.random.default_rng(20261009)
    english = [r for r in items if r['group'] == 'fleurs-en_us']
    for row in english[:6]:
        pcm = np.fromfile(row['pcm'], dtype='<f4')
        noise = rng.normal(size=len(pcm))
        noise *= np.sqrt(np.mean(pcm**2) / (10 * np.mean(noise**2)))
        add(row['id'] + '-noise10', 'noise10', (pcm + noise).clip(-1, 1), row['reference'],
            row['source'], parent=row['id'], snrDB=10)

    fixture = ROOT / 'LokalBotTests/Fixtures/LiveTranscript'
    text = re.search(r'Text: “(.+?)”', (fixture / 'README.md').read_text()).group(1)
    add('continuous-synthetic', 'synthetic', decode(fixture / 'continuous-speech.wav'), text, 'LokalBot LiveTranscript fixture')
    scripts = [
        ('names-1', "Please ask Siobhan O'Connor to review LokalBot and send the Acme report to Krzysztof.", "Siobhan O'Connor|LokalBot|Acme|Krzysztof"),
        ('names-2', 'The Kubernetes deployment needs a PostgreSQL migration and a Grafana dashboard before Friday.', 'Kubernetes|PostgreSQL|Grafana'),
        ('names-3', 'Tell Mila Novak that the Orion launch is scheduled for Thursday at three thirty.', 'Mila Novak|Orion'),
    ]
    for id, text, hints in scripts:
        path = out / 'source' / (id + '.aiff')
        if not path.exists():
            subprocess.run(['say', '-v', 'Samantha', '-r', '180', '-o', str(path), text], check=True)
        pcm = decode(path)
        add(id, 'names', pcm, text, 'macOS say Samantha 180wpm')
        add(id + '-hinted', 'names-hinted', pcm, text, 'macOS say Samantha 180wpm', hints=hints)
    for duration in [1, 5, 15, 30]:
        add(f'silence-{duration}', 'silence', np.zeros(duration*RATE, dtype=np.float32), '', 'synthetic zero PCM')
    t = np.arange(10*RATE) / RATE
    add('steady-tone', 'silence', 0.02*np.sin(2*np.pi*440*t), '', 'synthetic 440Hz tone')
    add('steady-noise', 'silence', rng.normal(0, 0.01, 10*RATE), '', 'synthetic Gaussian noise')

    # Same speech at different levels tests the silence gate without introducing new words.
    row = english[0]
    original = np.fromfile(row['pcm'], dtype='<f4')
    for db in [20, 40]:
        add(f'quiet-minus{db}', 'quiet', original*10**(-db/20), row['reference'], row['source'], attenuationDB=db)

    # >30s real-time-stream input with known transcript and utterance boundaries.
    parts, utterances, cursor = [], [], 0.0
    for row in english[:6]:
        pcm = np.fromfile(row['pcm'], dtype='<f4')
        parts += [pcm, np.zeros(RATE//2)]
        utterances.append(dict(start=cursor, end=cursor+row['duration'], text=row['reference'], id=row['id']))
        cursor += row['duration'] + 0.5
    stream = np.concatenate(parts).astype('<f4')
    (out / 'stream.f32').write_bytes(stream.tobytes())
    (out / 'stream.json').write_text(json.dumps(dict(duration=cursor, reference=' '.join(r['reference'] for r in english[:6]), utterances=utterances), indent=2))
    (out / 'stream.tsv').write_text(f'stream-en\t{out}/stream.f32\t\t\n')
    np.fromfile(english[0]['pcm'], dtype='<f4')[:5*RATE].tofile(out / 'warmup.f32')
    (out / 'items.json').write_text(json.dumps(items, indent=2, ensure_ascii=False))
    (out / 'jobs.tsv').write_text(''.join(f"{r['id']}\t{r['pcm']}\t{r['language'] or ''}\t{r['hints'] or ''}\n" for r in items))
    print(json.dumps(dict(clips=len(items), seconds=sum(r['duration'] for r in items), streamSeconds=cursor)), flush=True)

if __name__ == '__main__':
    main()
