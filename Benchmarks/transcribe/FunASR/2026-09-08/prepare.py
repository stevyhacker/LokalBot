import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import shutil
import urllib.parse
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).parent
os.environ['HF_HOME'] = str(ROOT / 'hf-cache')
os.environ['HF_HUB_DISABLE_XET'] = '1'
from huggingface_hub import snapshot_download
import soundfile as sf

PINS = {
    'Qwen/Qwen3-ASR-1.7B': '7278e1e70fe206f11671096ffdd38061171dd6e5',
    'Qwen/Qwen3-ForcedAligner-0.6B': 'c7cbfc2048c462b0d63a45797104fc9db3ad62b7',
    'funasr/fsmn-vad': 'df20e6b30c653645fa4ff125cacfcabd1020a669',
    'funasr/campplus': 'e4b6ede7ce16997aff4ae69fbca1f0175e2afede',
}

def fetch(url, filename):
    target = ROOT / filename
    if not target.exists():
        urllib.request.urlretrieve(url, target)
    return target

def models():
    result = []
    for name, rev in PINS.items():
        path = snapshot_download(name, revision=rev, local_dir=ROOT/'models'/name,
                                 ignore_patterns=['*.md', '*.jpg', '*.png', 'example/*', 'fig/*'],
                                 max_workers=4)
        files = []
        for p in pathlib.Path(path).rglob('*'):
            if p.is_file() and '.cache' not in p.parts:
                files.append({'name': str(p.relative_to(path)), 'bytes': p.stat().st_size,
                              'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()})
        result.append({'repo': name, 'revision': rev, 'path': path, 'files': files})
        print('MODEL READY', name, flush=True)
    (ROOT/'models.json').write_text(json.dumps(result, indent=2))

def audio():
    source = 'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/EN2002a/audio/EN2002a.Mix-Headset.wav'
    full = fetch(source, 'EN2002a.Mix-Headset.wav')
    ann_url = 'https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip'
    annotations = fetch(ann_url, 'ami_public_manual_1.6.2.zip')
    wav, rate = sf.read(full, dtype='float32')
    assert rate == 16000 and wav.ndim == 1
    words = []
    with zipfile.ZipFile(annotations) as archive:
        files = [n for n in archive.namelist() if '/EN2002a.' in n and n.endswith('.words.xml')]
        assert len(files) == 4, files
        for name in files:
            speaker = pathlib.Path(name).name.split('.')[1]
            for node in ET.fromstring(archive.read(name)).iter('w'):
                if 'starttime' not in node.attrib or 'endtime' not in node.attrib or not node.text:
                    continue
                if node.attrib.get('punc') == 'true':
                    continue
                words.append({'start': float(node.attrib['starttime']), 'end': float(node.attrib['endtime']),
                              'speaker': speaker, 'text': node.text})
    words.sort(key=lambda w: (w['start'], w['end'], w['speaker']))
    clips = []
    (ROOT/'audio').mkdir(exist_ok=True)
    # Fixed windows chosen before inference; no quality-based selection.
    for start in (120, 600, 1500):
        end = start + 90
        ident = f'EN2002a-{start}-{end}'
        p = ROOT/'audio'/f'{ident}.wav'
        sf.write(p, wav[start*rate:end*rate], rate, subtype='PCM_16')
        selected = [dict(w, start=max(0, w['start']-start), end=min(90,w['end']-start))
                    for w in words if start <= (w['start']+w['end'])/2 < end]
        clips.append({'id': ident, 'audio': str(p), 'duration': 90.0, 'kind': 'meeting',
                      'source_start': start, 'words': selected,
                      'reference': ' '.join(w['text'] for w in selected),
                      'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()})
    old = json.loads((ROOT/'short-clips-manifest.json').read_text())
    for dataset in ('edinburghcstr/ami', 'openslr/librispeech_asr'):
        matches = [c for c in old if c['dataset'] == dataset]
        if not matches and 'libri' in dataset:
            matches = [c for c in old if c['id'].startswith('libri')]
        assert len(matches) >= 12, (dataset, len(matches))
        for c in matches[:12]:
            p = ROOT/'audio'/f"{c['id']}.wav"
            if not p.exists():
                previous = pathlib.Path(c['path'])
                if previous.exists():
                    shutil.copyfile(previous,p)
                else:
                    query=urllib.parse.urlencode({'dataset':c['dataset'],'config':c['config'],
                                                'split':c['split'],'offset':c['row'],'length':1})
                    row=json.load(urllib.request.urlopen('https://datasets-server.huggingface.co/rows?'+query))['rows'][0]['row']
                    source=row['audio'][0]['src']
                    urllib.request.urlretrieve(source,p)
            assert hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==c['sha256'], c['id']
            info = sf.info(p)
            clips.append(dict(c, audio=str(p), duration=info.duration, kind='clip'))
    manifest = {'nativeModelDirectory': '/Users/0xmithrandir/Library/Application Support/me.dotenv.LokalBot/qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit',
                'audio_source': source, 'annotation_source': ann_url,
                'annotation_sha256': hashlib.file_digest(annotations.open('rb'), 'sha256').hexdigest(),
                'source_sha256': hashlib.file_digest(full.open('rb'), 'sha256').hexdigest(),
                'clips': clips}
    (ROOT/'fixture.json').write_text(json.dumps(manifest, indent=2))
    print('AUDIO READY', [(c['id'], len(c.get('words', []))) for c in clips], flush=True)

if __name__ == '__main__':
    with cf.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = [pool.submit(models), pool.submit(audio)]
        for job in jobs:
            job.result()
